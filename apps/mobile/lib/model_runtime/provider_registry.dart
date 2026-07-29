import 'dart:async';

import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';

abstract interface class ChatModelRuntime {
  Future<ChatResponse> chat(ChatRequest request);
}

abstract interface class ProviderRegistryView implements ChatModelRuntime {
  Iterable<ProviderConfig> get configs;
  ModelDescriptor resolveModel(ModelRef ref);
}

abstract interface class ModelProvider implements ChatModelRuntime {
  ProviderConfig get config;
  Iterable<ModelDescriptor> get modelCatalog;
}

class ProviderRegistry implements ProviderRegistryView {
  ProviderRegistry()
    : _mutable = true,
      _lifecycle = null,
      _immutableConfigs = null;

  ProviderRegistry.snapshot(
    Iterable<ModelProvider> providers, {
    Duration shutdownTimeout = const Duration(seconds: 2),
  }) : _mutable = false,
       _lifecycle = _RegistryLifecycle(shutdownTimeout),
       _immutableConfigs = <ProviderConfig>[] {
    for (final provider in providers) {
      _register(provider);
    }
    _immutableConfigs = List<ProviderConfig>.unmodifiable(
      _providers.values.map((provider) => provider.config),
    );
  }

  final bool _mutable;
  final _RegistryLifecycle? _lifecycle;
  List<ProviderConfig>? _immutableConfigs;
  final Map<String, ModelProvider> _providers = {};
  final Map<String, Map<String, ModelDescriptor>> _catalogs = {};

  @override
  Iterable<ProviderConfig> get configs {
    _lifecycle?.requireOpen();
    final immutableConfigs = _immutableConfigs;
    if (immutableConfigs != null) return immutableConfigs;
    return List<ProviderConfig>.unmodifiable(
      _providers.values.map((provider) => provider.config),
    );
  }

  void register(ModelProvider provider) {
    if (!_mutable) {
      throw StateError('Provider registry snapshot is immutable');
    }
    _register(provider);
  }

  void _register(ModelProvider provider) {
    final providerId = provider.config.providerId;
    if (_providers.containsKey(providerId)) {
      throw const ModelRuntimeException(
        code: ModelRuntimeErrorCode.invalidConfiguration,
        safeMessage: '模型服务配置重复',
        retryable: false,
      );
    }

    final catalog = <String, ModelDescriptor>{};
    for (final model in provider.modelCatalog) {
      if (model.ref.providerId != providerId ||
          catalog.containsKey(model.ref.modelId)) {
        throw const ModelRuntimeException(
          code: ModelRuntimeErrorCode.invalidConfiguration,
          safeMessage: '模型目录配置无效',
          retryable: false,
        );
      }
      catalog[model.ref.modelId] = model;
    }
    _providers[providerId] = provider;
    _catalogs[providerId] = Map.unmodifiable(catalog);
  }

  ModelProvider _resolveProvider(String providerId) {
    final provider = _providers[providerId];
    if (provider == null) {
      throw const ModelRuntimeException(
        code: ModelRuntimeErrorCode.providerNotFound,
        safeMessage: '模型服务不可用',
        retryable: false,
      );
    }
    if (!provider.config.enabled) {
      throw const ModelRuntimeException(
        code: ModelRuntimeErrorCode.providerDisabled,
        safeMessage: '模型服务已停用',
        retryable: false,
      );
    }
    return provider;
  }

  @override
  ModelDescriptor resolveModel(ModelRef ref) {
    _lifecycle?.requireOpen();
    return _resolveModel(ref);
  }

  ModelDescriptor _resolveModel(ModelRef ref) {
    _resolveProvider(ref.providerId);
    final model = _catalogs[ref.providerId]?[ref.modelId];
    if (model == null) {
      throw const ModelRuntimeException(
        code: ModelRuntimeErrorCode.modelNotFound,
        safeMessage: '当前模型不在可用目录中',
        retryable: false,
      );
    }
    return model;
  }

  void _validateCapabilities(ChatRequest request, ModelDescriptor descriptor) {
    final capabilities = descriptor.capabilities;
    final usesSystemMessage = request.messages.any(
      (message) => message.role == ChatRole.system,
    );
    final exceedsOutputLimit =
        request.maxOutputTokens != null &&
        request.maxOutputTokens! > capabilities.maxOutputTokens;
    if (!capabilities.textGeneration ||
        (usesSystemMessage && !capabilities.systemMessages) ||
        (request.temperature != null && !capabilities.supportsTemperature) ||
        exceedsOutputLimit) {
      throw const ModelRuntimeException(
        code: ModelRuntimeErrorCode.unsupportedCapability,
        safeMessage: '当前模型不支持这项文字请求',
        retryable: false,
      );
    }
  }

  @override
  Future<ChatResponse> chat(ChatRequest request) {
    final activeLifecycle = _lifecycle;
    if (activeLifecycle != null) {
      return activeLifecycle.run(() => _chat(request));
    }
    return _chat(request);
  }

  Future<ChatResponse> _chat(ChatRequest request) async {
    final provider = _resolveProvider(request.model.providerId);
    final descriptor = _resolveModel(request.model);
    _validateCapabilities(request, descriptor);
    final activeLifecycle = _lifecycle;
    final sources = <CancellationToken>[
      if (request.cancellationToken != null) request.cancellationToken!,
      if (activeLifecycle != null) activeLifecycle.cancellationToken,
    ];
    if (sources.isEmpty) return provider.chat(request);
    final linked = LinkedCancellationScope(sources);
    try {
      if (linked.token.isCancelled) throw _cancelledChat();
      final response = await provider.chat(
        request.withCancellationToken(linked.token),
      );
      if (linked.token.isCancelled) throw _cancelledChat();
      return response;
    } on Object {
      if (linked.token.isCancelled) throw _cancelledChat();
      rethrow;
    } finally {
      linked.dispose();
    }
  }

  ModelRuntimeException _cancelledChat() => const ModelRuntimeException(
    code: ModelRuntimeErrorCode.streamInterrupted,
    safeMessage: '模型请求已取消',
    retryable: false,
  );

  Future<void> close() => _lifecycle?.close() ?? Future<void>.value();

  bool get shutdownForced => _lifecycle?.shutdownForced ?? false;
}

enum _RegistryState { open, closing, closed }

final class _RegistryLifecycle {
  _RegistryLifecycle(this._shutdownTimeout);

  final Duration _shutdownTimeout;
  final CancellationToken _cancellationToken = CancellationToken();
  _RegistryState _state = _RegistryState.open;
  int _activeOperations = 0;
  Completer<void>? _drained;
  Future<void>? _closeFuture;
  bool shutdownForced = false;

  CancellationToken get cancellationToken => _cancellationToken;

  void requireOpen() {
    if (_state != _RegistryState.open) {
      throw StateError('Provider registry is closed');
    }
  }

  Future<T> run<T>(Future<T> Function() operation) async {
    requireOpen();
    _activeOperations++;
    try {
      final result = await operation();
      if (_state != _RegistryState.open) {
        throw _closedDuringOperation();
      }
      return result;
    } on Object {
      if (_state != _RegistryState.open) {
        throw _closedDuringOperation();
      }
      rethrow;
    } finally {
      _activeOperations--;
      if (_activeOperations == 0) {
        _drained?.complete();
        _drained = null;
      }
    }
  }

  ModelRuntimeException _closedDuringOperation() => const ModelRuntimeException(
    code: ModelRuntimeErrorCode.streamInterrupted,
    safeMessage: '模型服务运行时已关闭',
    retryable: false,
  );

  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    final closeFuture = _close();
    _closeFuture = closeFuture;
    return closeFuture;
  }

  Future<void> _close() async {
    _state = _RegistryState.closing;
    _cancellationToken.cancel();
    if (_activeOperations > 0) {
      _drained = Completer<void>();
      try {
        await _drained!.future.timeout(_shutdownTimeout);
      } on TimeoutException {
        shutdownForced = true;
        _drained = null;
      }
    }
    _state = _RegistryState.closed;
  }
}
