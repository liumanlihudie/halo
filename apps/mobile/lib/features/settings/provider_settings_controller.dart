import 'dart:async';
import 'dart:math';

// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/secure_credential_store.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';

final Object _providerSettingsMutationZoneKey = Object();

/// Outcome of a read-only connection test. Never persists anything.
enum ProviderConnectionResult {
  untested,
  testing,
  reachable,
  notConfigured,
  authFailed,
  quotaExceeded,
  unreachable,
}

enum ProviderSettingsState {
  idle,
  saving,
  ready,
  cleanupPending,
  recoveryPending,
  saveFailed,
  deleting,
  deleteFailed,
  orphanedCredential,
}

@immutable
class ProviderSettingsDraft {
  const ProviderSettingsDraft({
    required this.providerId,
    required this.apiKey,
    required this.enabled,
  });

  final String providerId;
  final String apiKey;
  final bool enabled;
}

@immutable
class ProviderSettingsSnapshot {
  const ProviderSettingsSnapshot({required this.config, required this.catalog});

  final ProviderConfig config;
  final PersistedProviderModelCatalog? catalog;
}

abstract interface class ProviderModelCatalogFetcher {
  Future<PersistedProviderModelCatalog> fetch(ProviderConfig config);
}

abstract interface class ProviderSettingsPersistence {
  Future<ProviderSettingsSnapshot?> load(String providerId);

  /// Atomically switches the Provider config and every affected model binding.
  ///
  /// Implementations must either publish [next] completely or leave [previous]
  /// untouched.
  Future<void> replace(
    ProviderSettingsSnapshot? previous,
    ProviderSettingsSnapshot next,
  );

  Future<void> rollbackReplace(
    ProviderSettingsSnapshot? previous,
    ProviderSettingsSnapshot next,
  );

  Future<void> markReplaceRuntimePublished(
    ProviderSettingsSnapshot? previous,
    ProviderSettingsSnapshot next,
  );

  Future<void> finalizeReplace(
    ProviderSettingsSnapshot? previous,
    ProviderSettingsSnapshot next,
  );

  Future<void> remove(ProviderSettingsSnapshot snapshot);

  Future<void> restore(ProviderSettingsSnapshot snapshot);

  Future<void> markRemovalRuntimePublished(ProviderSettingsSnapshot snapshot);

  Future<void> finalizeRemoval(ProviderSettingsSnapshot snapshot);
}

/// Read/write access to the global default model binding.
///
/// [setGlobalDefault] accepts `null` so a failed auto-default publish can be
/// rolled back to "no default".
abstract interface class ModelBindingDefaults {
  Future<ModelRef?> loadGlobalDefault();

  Future<void> setGlobalDefault(ModelRef? model);
}

abstract interface class ProviderRuntimeReloader {
  Future<void> reload();
}

abstract interface class ProviderMutationCoordinator {
  Future<T> runExclusive<T>(Future<T> Function() operation);
}

final class SerializedProviderMutationCoordinator
    implements ProviderMutationCoordinator {
  Future<void> _tail = Future<void>.value();

  @override
  Future<T> runExclusive<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

abstract interface class ProviderSecretRefFactory {
  SecretRef next();
}

final class SecureUuidProviderSecretRefFactory
    implements ProviderSecretRefFactory {
  SecureUuidProviderSecretRefFactory({Random? random})
    : _random = random ?? Random.secure();

  final Random _random;

  @override
  SecretRef next() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String pair(int index) => bytes[index].toRadixString(16).padLeft(2, '0');
    String span(int start, int end) =>
        [for (var index = start; index < end; index++) pair(index)].join();
    final account =
        '${span(0, 4)}-${span(4, 6)}-${span(6, 8)}-'
        '${span(8, 10)}-${span(10, 16)}';
    final ref = SecretRef.parse(
      'keychain://${ProviderSecretRefPolicy.service}/$account',
    );
    ProviderSecretRefPolicy.validate(ref);
    return ref;
  }
}

final class ProviderSettingsException implements Exception {
  const ProviderSettingsException(this.safeMessage);

  final String safeMessage;

  @override
  String toString() => 'ProviderSettingsException($safeMessage)';
}

final class ProviderSettingsController extends ChangeNotifier {
  ProviderSettingsController({
    required SecureCredentialStore credentials,
    required ProviderModelCatalogFetcher catalogFetcher,
    required ProviderSettingsPersistence persistence,
    required ProviderRuntimeReloader runtime,
    ProviderSecretRefFactory? secretRefs,
    ProviderMutationCoordinator? mutationCoordinator,
    ModelBindingDefaults? bindingDefaults,
  }) : _credentials = credentials,
       _catalogFetcher = catalogFetcher,
       _persistence = persistence,
       _runtime = runtime,
       _secretRefs = secretRefs ?? SecureUuidProviderSecretRefFactory(),
       _mutationCoordinator =
           mutationCoordinator ?? SerializedProviderMutationCoordinator(),
       _bindingDefaults = bindingDefaults;

  final SecureCredentialStore _credentials;
  final ProviderModelCatalogFetcher _catalogFetcher;
  final ProviderSettingsPersistence _persistence;
  final ProviderRuntimeReloader _runtime;
  final ProviderSecretRefFactory _secretRefs;
  final ProviderMutationCoordinator _mutationCoordinator;
  final ModelBindingDefaults? _bindingDefaults;

  ProviderSettingsState _state = ProviderSettingsState.idle;
  ProviderSettingsState get state => _state;
  final Map<String, ProviderSettingsState> _states = {};
  ProviderSettingsState stateFor(String providerId) =>
      _states[providerId] ?? ProviderSettingsState.idle;
  final Map<String, ProviderConnectionResult> _connectionResults = {};
  ProviderConnectionResult connectionResultFor(String providerId) =>
      _connectionResults[providerId] ?? ProviderConnectionResult.untested;
  bool _hasConfiguration = false;
  bool get hasConfiguration => _hasConfiguration;
  final Map<String, bool> _configured = {};
  bool hasConfigurationFor(String providerId) =>
      _configured[providerId] ?? false;
  final Map<String, ProviderSettingsSnapshot> _snapshots = {};
  ProviderSettingsSnapshot? snapshotFor(String providerId) =>
      _snapshots[providerId];
  final Set<String> _busyProviders = {};
  final Map<String, Completer<void>> _providerIdleWaiters = {};
  final Set<Object> _activeMutationContextTokens = {};
  Future<void> _mutationTail = Future<void>.value();
  int _activeOperations = 0;
  bool _closed = false;
  Completer<void>? _drained;
  Future<void>? _closeFuture;

  Future<ProviderSettingsSnapshot?> load(String providerId) async {
    _enter(providerId);
    try {
      final snapshot = await _persistence.load(providerId);
      _setSnapshot(providerId, snapshot);
      _setConfigured(providerId, snapshot != null);
      _setState(
        providerId,
        snapshot == null
            ? ProviderSettingsState.idle
            : ProviderSettingsState.ready,
      );
      return snapshot;
    } finally {
      _leave(providerId);
    }
  }

  Future<void> save(ProviderSettingsDraft draft) =>
      _enqueueMutation(draft.providerId, () => _save(draft));

  Future<void> _save(ProviderSettingsDraft draft) async {
    _setState(draft.providerId, ProviderSettingsState.saving);
    ProviderSettingsSnapshot? previous;
    SecretRef? newRef;
    var preserveNewRefForRecovery = false;
    try {
      previous = await _persistence.load(draft.providerId);
      _setSnapshot(draft.providerId, previous);
      newRef = _secretRefs.next();
      await _credentials.set(newRef, draft.apiKey);
      final config = _buildConfig(draft, newRef);
      final catalog = _requireCompleteCatalog(
        config,
        await _catalogFetcher.fetch(config),
      );
      final next = ProviderSettingsSnapshot(config: config, catalog: catalog);
      try {
        await _persistence.replace(previous, next);
        try {
          await _runtime.reload();
        } catch (_) {
          try {
            await _persistence.rollbackReplace(previous, next);
          } catch (_) {
            preserveNewRefForRecovery = true;
            _setConfigured(draft.providerId, previous != null);
            _setState(draft.providerId, ProviderSettingsState.recoveryPending);
            throw const ProviderSettingsException('配置恢复中，请稍后重试');
          }
          rethrow;
        }
      } catch (_) {
        var newRefDeleted = true;
        if (!preserveNewRefForRecovery) {
          newRefDeleted = await _deleteNewRefFailSafe(newRef);
        }
        if (preserveNewRefForRecovery) {
          throw const ProviderSettingsException('配置恢复中，请稍后重试');
        }
        _setConfigured(draft.providerId, previous != null);
        _setState(
          draft.providerId,
          newRefDeleted
              ? ProviderSettingsState.saveFailed
              : ProviderSettingsState.orphanedCredential,
        );
        throw const ProviderSettingsException('保存失败，原配置仍然有效');
      }

      try {
        await _persistence.markReplaceRuntimePublished(previous, next);
      } catch (_) {
        preserveNewRefForRecovery = true;
        _setConfigured(draft.providerId, true);
        _setSnapshot(draft.providerId, next);
        _setState(draft.providerId, ProviderSettingsState.recoveryPending);
        throw const ProviderSettingsException('配置恢复中，请稍后重试');
      }
      _setConfigured(draft.providerId, true);
      _setSnapshot(draft.providerId, next);
      try {
        await _persistence.finalizeReplace(previous, next);
      } catch (_) {
        _setState(draft.providerId, ProviderSettingsState.cleanupPending);
        return;
      }
      await _applyAutoDefaultModel(catalog);
      final oldRef = previous?.config.secretRef;
      if (oldRef != null && oldRef != newRef) {
        try {
          final deleted = await _credentials.delete(oldRef);
          if (!deleted) {
            _setState(draft.providerId, ProviderSettingsState.cleanupPending);
            return;
          }
        } catch (_) {
          _setState(draft.providerId, ProviderSettingsState.cleanupPending);
          return;
        }
      }
      _setState(draft.providerId, ProviderSettingsState.ready);
    } catch (error) {
      if (error is ProviderSettingsException) rethrow;
      var newRefDeleted = true;
      if (newRef != null && !preserveNewRefForRecovery) {
        newRefDeleted = await _deleteNewRefFailSafe(newRef);
      }
      if (preserveNewRefForRecovery) {
        _setState(draft.providerId, ProviderSettingsState.recoveryPending);
        throw const ProviderSettingsException('配置恢复中，请稍后重试');
      }
      _setConfigured(draft.providerId, previous != null);
      _setState(
        draft.providerId,
        newRefDeleted
            ? ProviderSettingsState.saveFailed
            : ProviderSettingsState.orphanedCredential,
      );
      throw const ProviderSettingsException('保存失败，原配置仍然有效');
    }
  }

  Future<void> refreshCatalog(String providerId) =>
      _enqueueMutation(providerId, () => _refreshCatalog(providerId));

  Future<void> _refreshCatalog(String providerId) async {
    _setState(providerId, ProviderSettingsState.saving);
    final previous = await _persistence.load(providerId);
    _setSnapshot(providerId, previous);
    if (previous == null) {
      _setConfigured(providerId, false);
      _setState(providerId, ProviderSettingsState.saveFailed);
      throw const ProviderSettingsException('请先配置模型服务');
    }

    late final ProviderSettingsSnapshot next;
    try {
      final catalog = _requireCompleteCatalog(
        previous.config,
        await _catalogFetcher.fetch(previous.config),
      );
      next = ProviderSettingsSnapshot(
        config: previous.config,
        catalog: catalog,
      );
      await _persistence.replace(previous, next);
      try {
        await _runtime.reload();
      } catch (_) {
        try {
          await _persistence.rollbackReplace(previous, next);
        } catch (_) {
          _setConfigured(providerId, true);
          _setSnapshot(providerId, next);
          _setState(providerId, ProviderSettingsState.recoveryPending);
          throw const ProviderSettingsException('配置恢复中，请稍后重试');
        }
        rethrow;
      }
    } on ProviderSettingsException {
      rethrow;
    } catch (_) {
      _setConfigured(providerId, true);
      _setSnapshot(providerId, previous);
      _setState(providerId, ProviderSettingsState.saveFailed);
      throw const ProviderSettingsException('刷新失败，原模型目录仍然有效');
    }

    try {
      await _persistence.markReplaceRuntimePublished(previous, next);
    } catch (_) {
      _setConfigured(providerId, true);
      _setSnapshot(providerId, next);
      _setState(providerId, ProviderSettingsState.recoveryPending);
      throw const ProviderSettingsException('配置恢复中，请稍后重试');
    }
    _setConfigured(providerId, true);
    _setSnapshot(providerId, next);
    try {
      await _persistence.finalizeReplace(previous, next);
    } catch (_) {
      _setState(providerId, ProviderSettingsState.cleanupPending);
      return;
    }
    _setState(providerId, ProviderSettingsState.ready);
  }

  Future<void> remove(String providerId) =>
      _enqueueMutation(providerId, () => _remove(providerId));

  Future<void> _remove(String providerId) async {
    _setState(providerId, ProviderSettingsState.deleting);
    try {
      final previous = await _persistence.load(providerId);
      _setSnapshot(providerId, previous);
      if (previous == null) {
        _setConfigured(providerId, false);
        _setState(providerId, ProviderSettingsState.idle);
        return;
      }
      await _persistence.remove(previous);
      _setConfigured(providerId, false);
      _setSnapshot(providerId, null);
      final oldRef = previous.config.secretRef;
      try {
        await _runtime.reload();
      } catch (_) {
        try {
          await _persistence.restore(previous);
          await _runtime.reload();
          _setConfigured(providerId, true);
          _setSnapshot(providerId, previous);
          _setState(providerId, ProviderSettingsState.deleteFailed);
        } catch (_) {
          _setConfigured(providerId, false);
          _setState(providerId, ProviderSettingsState.orphanedCredential);
        }
        throw const ProviderSettingsException('移除失败，请稍后重试');
      }
      try {
        await _persistence.markRemovalRuntimePublished(previous);
      } catch (_) {
        _setState(providerId, ProviderSettingsState.recoveryPending);
        throw const ProviderSettingsException('配置恢复中，请稍后重试');
      }
      if (oldRef != null) {
        try {
          final deleted = await _credentials.delete(oldRef);
          if (!deleted) {
            _setState(providerId, ProviderSettingsState.cleanupPending);
            return;
          }
        } catch (_) {
          _setState(providerId, ProviderSettingsState.cleanupPending);
          return;
        }
      }
      try {
        await _persistence.finalizeRemoval(previous);
        _setState(providerId, ProviderSettingsState.idle);
      } catch (_) {
        _setState(providerId, ProviderSettingsState.cleanupPending);
      }
    } on ProviderSettingsException {
      rethrow;
    } catch (_) {
      _setState(providerId, ProviderSettingsState.deleteFailed);
      throw const ProviderSettingsException('移除失败，请稍后重试');
    }
  }

  /// Read-only reachability check against the saved provider key.
  ///
  /// Reuses the catalog fetcher to hit `/models`, persists nothing, and never
  /// runs through the mutation FIFO because it changes no state. Errors map to
  /// an actionable result rather than a generic failure.
  Future<void> testConnection(String providerId) async {
    if (_closed) throw StateError('Provider settings are closed');
    _connectionResults[providerId] = ProviderConnectionResult.testing;
    notifyListeners();
    ProviderConnectionResult result;
    try {
      final snapshot = await _persistence.load(providerId);
      if (snapshot == null) {
        result = ProviderConnectionResult.notConfigured;
      } else {
        await _catalogFetcher.fetch(snapshot.config);
        result = ProviderConnectionResult.reachable;
      }
    } on ModelRuntimeException catch (error) {
      result = switch (error.code) {
        ModelRuntimeErrorCode.invalidCredential =>
          ProviderConnectionResult.authFailed,
        ModelRuntimeErrorCode.insufficientBalance ||
        ModelRuntimeErrorCode.rateLimited =>
          ProviderConnectionResult.quotaExceeded,
        _ => ProviderConnectionResult.unreachable,
      };
    } catch (_) {
      result = ProviderConnectionResult.unreachable;
    }
    if (_closed) return;
    _connectionResults[providerId] = result;
    notifyListeners();
  }

  ProviderConfig _buildConfig(
    ProviderSettingsDraft draft,
    SecretRef secretRef,
  ) => switch (draft.providerId) {
    'toapis' => ProviderConfig.toApis(
      enabled: draft.enabled,
      secretRef: secretRef,
    ),
    'deepseek' => ProviderConfig.deepSeek(
      enabled: draft.enabled,
      secretRef: secretRef,
    ),
    _ => throw StateError('Provider is not supported'),
  };

  /// Auto-selects a global default model after a successful save.
  ///
  /// When no global default is bound yet, the first model of the freshly
  /// persisted [catalog] becomes the default so every expert (which follows
  /// `override ?? global`) immediately routes to the newly configured
  /// provider. An existing default is never overwritten, and failures here
  /// never fail the save itself — the key is already persisted; the worst
  /// outcome is remaining without a default. Runs inside the same mutation
  /// critical section as the save, so it cannot interleave with another
  /// provider mutation.
  Future<void> _applyAutoDefaultModel(
    PersistedProviderModelCatalog catalog,
  ) async {
    final defaults = _bindingDefaults;
    if (defaults == null) return;
    try {
      final existing = await defaults.loadGlobalDefault();
      if (existing != null) return;
      await defaults.setGlobalDefault(catalog.models.first.ref);
      try {
        await _runtime.reload();
      } catch (_) {
        // Only a live runtime may keep the binding: roll the default back so
        // persisted state and runtime state never diverge.
        await defaults.setGlobalDefault(null);
      }
    } catch (_) {
      // Best effort: leaving no default is safe (the UI prompts for model
      // configuration), whereas failing the save would discard a valid key.
    }
  }

  PersistedProviderModelCatalog _requireCompleteCatalog(
    ProviderConfig config,
    PersistedProviderModelCatalog catalog,
  ) {
    if (catalog.providerId != config.providerId || catalog.models.isEmpty) {
      throw StateError('Provider model catalog is incomplete');
    }
    return catalog;
  }

  Future<bool> _deleteNewRefFailSafe(SecretRef ref) async {
    try {
      return await _credentials.delete(ref);
    } catch (_) {
      return false;
    }
  }

  void _enter(String providerId, {bool allowClosed = false}) {
    if (_closed && !allowClosed) {
      throw StateError('Provider settings are closed');
    }
    if (!_busyProviders.add(providerId)) {
      throw StateError('A provider settings operation is already active');
    }
    _activeOperations++;
  }

  Future<void> _enqueueMutation(
    String providerId,
    Future<void> Function() mutation,
  ) {
    _rejectReentrantMutationCall();
    if (_closed) {
      throw StateError('Provider settings are closed');
    }
    final operation = _mutationTail.then((_) async {
      await _waitUntilProviderIdle(providerId);
      _enter(providerId, allowClosed: true);
      final contextToken = Object();
      _activeMutationContextTokens.add(contextToken);
      try {
        await _mutationCoordinator.runExclusive(
          () => runZoned(
            mutation,
            zoneValues: {_providerSettingsMutationZoneKey: contextToken},
          ),
        );
      } finally {
        _activeMutationContextTokens.remove(contextToken);
        _leave(providerId);
      }
    });
    _mutationTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _waitUntilProviderIdle(String providerId) async {
    while (_busyProviders.contains(providerId)) {
      await (_providerIdleWaiters[providerId] ??= Completer<void>()).future;
    }
  }

  void _rejectReentrantMutationCall() {
    final contextToken = Zone.current[_providerSettingsMutationZoneKey];
    if (contextToken != null &&
        _activeMutationContextTokens.contains(contextToken)) {
      throw StateError(
        'Reentrant provider settings mutation calls are not allowed',
      );
    }
  }

  void _leave(String providerId) {
    _busyProviders.remove(providerId);
    _providerIdleWaiters.remove(providerId)?.complete();
    _activeOperations--;
    if (_activeOperations == 0) {
      _drained?.complete();
      _drained = null;
    }
  }

  Future<void> close() {
    _rejectReentrantMutationCall();
    final existing = _closeFuture;
    if (existing != null) return existing;
    _closed = true;
    final future = _close();
    _closeFuture = future;
    return future;
  }

  Future<void> _close() async {
    await _mutationTail;
    if (_activeOperations > 0) {
      await (_drained ??= Completer<void>()).future;
    }
    super.dispose();
  }

  void _setConfigured(String providerId, bool value) {
    _configured[providerId] = value;
    _hasConfiguration = value;
  }

  void _setSnapshot(String providerId, ProviderSettingsSnapshot? snapshot) {
    if (snapshot == null) {
      _snapshots.remove(providerId);
    } else {
      _snapshots[providerId] = snapshot;
    }
  }

  void _setState(String providerId, ProviderSettingsState value) {
    _states[providerId] = value;
    _state = value;
    notifyListeners();
  }
}
