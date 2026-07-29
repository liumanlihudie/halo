import 'dart:async';

// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';
import 'package:halo_mobile/features/settings/provider_settings_controller.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_configuration_store.dart';

@immutable
class AvailableModelOption {
  const AvailableModelOption({
    required this.ref,
    required this.providerName,
    required this.modelName,
  });

  final ModelRef ref;
  final String providerName;
  final String modelName;
}

abstract interface class ModelRoutingPersistence {
  Future<List<AvailableModelOption>> loadAvailableModels();
  Future<ModelRef?> loadGlobalDefault();
  Future<void> setGlobalDefault(ModelRef model);
  Future<ModelRef?> loadExpertOverride(String expertId);
  Future<void> setExpertOverride(String expertId, ModelRef? model);
}

/// Internal recovery capability kept separate so normal global selection can
/// only persist a concrete model.
abstract interface class ModelRoutingRollbackPersistence {
  Future<void> restoreGlobalDefault(ModelRef? model);
}

final class SqliteModelRoutingPersistence
    implements ModelRoutingPersistence, ModelRoutingRollbackPersistence {
  const SqliteModelRoutingPersistence(this._store);

  final ProviderConfigurationStore _store;

  @override
  Future<List<AvailableModelOption>> loadAvailableModels() async {
    final catalogStore = _store is ProviderModelCatalogStore
        ? _store as ProviderModelCatalogStore
        : null;
    if (catalogStore == null) {
      throw StateError('Provider model catalog persistence is unavailable');
    }
    final enabledProviders = await _store.loadEnabled();
    final options = <AvailableModelOption>[];
    final seen = <ModelRef>{};
    for (final provider in enabledProviders) {
      final catalog = await catalogStore.loadProviderModelCatalog(
        provider.providerId,
      );
      if (catalog == null) continue;
      for (final model in catalog.models) {
        if (!seen.add(model.ref)) {
          throw StateError('Duplicate persisted provider model');
        }
        options.add(
          AvailableModelOption(
            ref: model.ref,
            providerName: provider.displayName,
            modelName: model.displayName,
          ),
        );
      }
    }
    return List.unmodifiable(options);
  }

  @override
  Future<ModelRef?> loadGlobalDefault() => _store.loadGlobalDefaultModel();

  @override
  Future<void> setGlobalDefault(ModelRef model) =>
      _store.setGlobalDefaultModel(model);

  @override
  Future<void> restoreGlobalDefault(ModelRef? model) =>
      _store.setGlobalDefaultModel(model);

  @override
  Future<ModelRef?> loadExpertOverride(String expertId) =>
      _store.loadAgentModelOverride(expertId);

  @override
  Future<void> setExpertOverride(String expertId, ModelRef? model) =>
      _store.setAgentModelOverride(expertId, model);
}

final class ModelRoutingException implements Exception {
  const ModelRoutingException(this.safeMessage);

  final String safeMessage;

  @override
  String toString() => 'ModelRoutingException($safeMessage)';
}

final class SerializedProviderRuntimeReloader
    implements ProviderRuntimeReloader {
  SerializedProviderRuntimeReloader(this._delegate);

  final ProviderRuntimeReloader _delegate;
  Future<void> _tail = Future<void>.value();

  @override
  Future<void> reload() {
    final operation = _tail.then((_) => _delegate.reload());
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }
}

final class ModelRoutingController extends ChangeNotifier {
  ModelRoutingController({
    required ModelRoutingPersistence persistence,
    required ProviderRuntimeReloader runtime,
    ProviderMutationCoordinator? mutationCoordinator,
  }) : _persistence = persistence,
       _runtime = runtime,
       _mutationCoordinator =
           mutationCoordinator ?? SerializedProviderMutationCoordinator();

  final ModelRoutingPersistence _persistence;
  final ProviderRuntimeReloader _runtime;
  final ProviderMutationCoordinator _mutationCoordinator;

  List<AvailableModelOption> _availableModels = const [];
  List<AvailableModelOption> get availableModels => _availableModels;

  ModelRef? _globalDefault;
  ModelRef? get globalDefault => _globalDefault;

  final Map<String, ModelRef?> _expertOverrides = {};
  Future<void> _mutationTail = Future<void>.value();
  bool _closing = false;
  bool _disposed = false;
  Future<void>? _closeFuture;

  /// Bumped when a mutation enters and leaves its critical section so a read
  /// that overlapped it can never publish a pre-mutation snapshot.
  int _mutationEpoch = 0;
  int _activeReads = 0;
  Completer<void>? _readsDrained;

  bool _recoveryPending = false;

  /// True when a rollback failed, so persistence may hold a binding the live
  /// runtime never adopted. Cleared by the next successful mutation.
  bool get recoveryPending => _recoveryPending;

  Future<void> load() async {
    _requireAcceptingOperations();
    final epoch = _mutationEpoch;
    _beginRead();
    try {
      final List<Object?> values;
      try {
        values = await Future.wait<Object?>([
          _persistence.loadAvailableModels(),
          _persistence.loadGlobalDefault(),
        ]);
      } catch (_) {
        throw const ModelRoutingException('模型列表加载失败，请稍后重试');
      }
      if (_disposed || epoch != _mutationEpoch) return;
      _availableModels = List.unmodifiable(
        values[0]! as List<AvailableModelOption>,
      );
      _globalDefault = values[1] as ModelRef?;
      notifyListeners();
    } finally {
      _endRead();
    }
  }

  Future<ModelRef?> loadExpertOverride(String expertId) async {
    _requireCanonicalExpertId(expertId);
    _requireAcceptingOperations();
    final epoch = _mutationEpoch;
    _beginRead();
    try {
      final ModelRef? override;
      try {
        override = await _persistence.loadExpertOverride(expertId);
      } catch (_) {
        throw const ModelRoutingException('模型绑定加载失败，请稍后重试');
      }
      if (_disposed || epoch != _mutationEpoch) {
        return _expertOverrides[expertId];
      }
      _expertOverrides[expertId] = override;
      notifyListeners();
      return override;
    } finally {
      _endRead();
    }
  }

  void _beginRead() {
    _activeReads += 1;
  }

  void _endRead() {
    _activeReads -= 1;
    if (_activeReads > 0) return;
    final drained = _readsDrained;
    _readsDrained = null;
    if (drained != null && !drained.isCompleted) drained.complete();
  }

  ModelRef? expertOverrideFor(String expertId) => _expertOverrides[expertId];

  ModelRef? effectiveModelFor(String expertId) =>
      expertOverrideFor(expertId) ?? _globalDefault;

  AvailableModelOption? optionFor(ModelRef? ref) {
    if (ref == null) return null;
    for (final option in _availableModels) {
      if (option.ref == ref) return option;
    }
    return null;
  }

  Future<void> setGlobalDefault(ModelRef model) =>
      _enqueue(() => _setGlobalDefault(model));

  Future<void> _setGlobalDefault(ModelRef model) async {
    await _refreshAndRequireModel(model);
    final ModelRef? previous;
    try {
      previous = await _persistence.loadGlobalDefault();
      await _persistence.setGlobalDefault(model);
    } catch (_) {
      throw const ModelRoutingException('模型切换失败，原配置仍然有效');
    }
    try {
      await _runtime.reload();
    } catch (_) {
      await _rollback(() => _restoreGlobal(previous));
      _globalDefault = previous;
      notifyListeners();
      throw const ModelRoutingException('模型切换失败，原配置仍然有效');
    }
    _globalDefault = model;
    _recoveryPending = false;
    notifyListeners();
  }

  Future<void> setExpertOverride(String expertId, ModelRef? model) {
    _requireCanonicalExpertId(expertId);
    return _enqueue(() => _setExpertOverride(expertId, model));
  }

  Future<void> _setExpertOverride(String expertId, ModelRef? model) async {
    if (model != null) await _refreshAndRequireModel(model);
    final ModelRef? previous;
    try {
      previous = await _persistence.loadExpertOverride(expertId);
      await _persistence.setExpertOverride(expertId, model);
    } catch (_) {
      throw const ModelRoutingException('模型切换失败，原配置仍然有效');
    }
    try {
      await _runtime.reload();
    } catch (_) {
      await _rollback(() => _persistence.setExpertOverride(expertId, previous));
      _expertOverrides[expertId] = previous;
      notifyListeners();
      throw const ModelRoutingException('模型切换失败，原配置仍然有效');
    }
    _expertOverrides[expertId] = model;
    _recoveryPending = false;
    notifyListeners();
  }

  /// Restores the previous binding after a failed reload.
  ///
  /// A rollback that itself fails leaves persistence ahead of the live runtime,
  /// so it must never surface as “原配置仍然有效”.
  Future<void> _rollback(Future<void> Function() restore) async {
    try {
      await restore();
    } catch (_) {
      _recoveryPending = true;
      notifyListeners();
      throw const ModelRoutingException('模型配置未能恢复，请重启应用后重试');
    }
  }

  Future<void> _refreshAndRequireModel(ModelRef model) async {
    final List<AvailableModelOption> available;
    try {
      available = List<AvailableModelOption>.unmodifiable(
        await _persistence.loadAvailableModels(),
      );
    } catch (_) {
      throw const ModelRoutingException('模型列表加载失败，请稍后重试');
    }
    _availableModels = available;
    if (!available.any((option) => option.ref == model)) {
      notifyListeners();
      throw const ModelRoutingException('所选模型已不可用，请重新选择');
    }
  }

  Future<void> _restoreGlobal(ModelRef? previous) {
    final persistence = _persistence;
    if (persistence is ModelRoutingRollbackPersistence) {
      return (persistence as ModelRoutingRollbackPersistence)
          .restoreGlobalDefault(previous);
    }
    if (previous != null) return persistence.setGlobalDefault(previous);
    throw StateError('Global model rollback is unavailable');
  }

  Future<void> _enqueue(Future<void> Function() action) {
    _requireAcceptingOperations();
    final operation = _mutationTail.then((_) {
      _requireNotDisposed();
      _mutationEpoch += 1;
      return _mutationCoordinator
          .runExclusive(action)
          .whenComplete(() => _mutationEpoch += 1);
    });
    _mutationTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    _closing = true;
    final future = _mutationTail.whenComplete(_awaitReadsDrained).whenComplete(
      () {
        if (_disposed) return;
        _disposed = true;
        super.dispose();
      },
    );
    _closeFuture = future;
    return future;
  }

  Future<void> _awaitReadsDrained() {
    if (_activeReads == 0) return Future<void>.value();
    return (_readsDrained ??= Completer<void>()).future;
  }

  void _requireAcceptingOperations() {
    if (_closing) {
      throw StateError('Model routing controller is closing');
    }
    _requireNotDisposed();
  }

  void _requireNotDisposed() {
    if (_disposed) throw StateError('Model routing controller is closed');
  }

  void _requireCanonicalExpertId(String expertId) {
    if (!isCanonicalRuntimeId(expertId)) {
      throw ArgumentError.value(expertId, 'expertId');
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _closing = true;
    _disposed = true;
    super.dispose();
  }
}
