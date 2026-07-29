import 'dart:async';
import 'dart:math';

// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/secure_credential_store.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';

final Object _providerSettingsMutationZoneKey = Object();

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
    required this.modelId,
    required this.apiKey,
    required this.enabled,
  });

  final String providerId;
  final String modelId;
  final String apiKey;
  final bool enabled;
}

@immutable
class ProviderSettingsSnapshot {
  const ProviderSettingsSnapshot({required this.config, required this.model});

  final ProviderConfig config;
  final ModelRef model;
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

  Future<void> finalizeReplace(
    ProviderSettingsSnapshot? previous,
    ProviderSettingsSnapshot next,
  );

  Future<void> remove(ProviderSettingsSnapshot snapshot);

  Future<void> restore(ProviderSettingsSnapshot snapshot);

  Future<void> finalizeRemoval(ProviderSettingsSnapshot snapshot);
}

abstract interface class ProviderRuntimeReloader {
  Future<void> reload();
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
    required ProviderSettingsPersistence persistence,
    required ProviderRuntimeReloader runtime,
    ProviderSecretRefFactory? secretRefs,
  }) : _credentials = credentials,
       _persistence = persistence,
       _runtime = runtime,
       _secretRefs = secretRefs ?? SecureUuidProviderSecretRefFactory();

  final SecureCredentialStore _credentials;
  final ProviderSettingsPersistence _persistence;
  final ProviderRuntimeReloader _runtime;
  final ProviderSecretRefFactory _secretRefs;

  ProviderSettingsState _state = ProviderSettingsState.idle;
  ProviderSettingsState get state => _state;
  final Map<String, ProviderSettingsState> _states = {};
  ProviderSettingsState stateFor(String providerId) =>
      _states[providerId] ?? ProviderSettingsState.idle;
  bool _hasConfiguration = false;
  bool get hasConfiguration => _hasConfiguration;
  final Map<String, bool> _configured = {};
  bool hasConfigurationFor(String providerId) =>
      _configured[providerId] ?? false;
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
      newRef = _secretRefs.next();
      await _credentials.set(newRef, draft.apiKey);
      final next = ProviderSettingsSnapshot(
        config: _buildConfig(draft, newRef),
        model: ModelRef(providerId: draft.providerId, modelId: draft.modelId),
      );
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

      _setConfigured(draft.providerId, true);
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
      try {
        await _persistence.finalizeReplace(previous, next);
      } catch (_) {
        _setState(draft.providerId, ProviderSettingsState.cleanupPending);
        return;
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

  Future<void> remove(String providerId) =>
      _enqueueMutation(providerId, () => _remove(providerId));

  Future<void> _remove(String providerId) async {
    _setState(providerId, ProviderSettingsState.deleting);
    try {
      final previous = await _persistence.load(providerId);
      if (previous == null) {
        _setConfigured(providerId, false);
        _setState(providerId, ProviderSettingsState.idle);
        return;
      }
      await _persistence.remove(previous);
      _setConfigured(providerId, false);
      final oldRef = previous.config.secretRef;
      try {
        await _runtime.reload();
        if (oldRef != null) {
          final deleted = await _credentials.delete(oldRef);
          if (!deleted) throw StateError('Credential was not deleted');
        }
      } catch (_) {
        try {
          await _persistence.restore(previous);
          await _runtime.reload();
          _setConfigured(providerId, true);
          _setState(providerId, ProviderSettingsState.deleteFailed);
        } catch (_) {
          _setConfigured(providerId, false);
          _setState(providerId, ProviderSettingsState.orphanedCredential);
        }
        throw const ProviderSettingsException('移除失败，请稍后重试');
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
    _ => throw const ProviderSettingsException('当前 Provider 暂不可用'),
  };

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
        await runZoned(
          mutation,
          zoneValues: {_providerSettingsMutationZoneKey: contextToken},
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

  void _setState(String providerId, ProviderSettingsState value) {
    _states[providerId] = value;
    _state = value;
    notifyListeners();
  }
}
