import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';

abstract interface class ChatModelRuntime {
  Future<ChatResponse> chat(ChatRequest request);
}

abstract interface class ModelProvider implements ChatModelRuntime {
  ProviderConfig get config;
  Iterable<ModelDescriptor> get modelCatalog;
}

class ProviderRegistry implements ChatModelRuntime {
  final Map<String, ModelProvider> _providers = {};
  final Map<String, Map<String, ModelDescriptor>> _catalogs = {};

  Iterable<ProviderConfig> get configs =>
      _providers.values.map((provider) => provider.config);

  void register(ModelProvider provider) {
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

  ModelDescriptor resolveModel(ModelRef ref) {
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
        exceedsOutputLimit) {
      throw const ModelRuntimeException(
        code: ModelRuntimeErrorCode.unsupportedCapability,
        safeMessage: '当前模型不支持这项文字请求',
        retryable: false,
      );
    }
  }

  @override
  Future<ChatResponse> chat(ChatRequest request) async {
    final provider = _resolveProvider(request.model.providerId);
    final descriptor = resolveModel(request.model);
    _validateCapabilities(request, descriptor);
    return provider.chat(request);
  }
}
