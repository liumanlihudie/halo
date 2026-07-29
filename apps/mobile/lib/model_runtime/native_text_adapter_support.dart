import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';

Map<String, ModelDescriptor> buildNativeModelCatalog(
  ProviderConfig config,
  Iterable<ModelDescriptor> models,
) {
  final catalog = <String, ModelDescriptor>{};
  for (final model in models) {
    if (model.ref.providerId != config.providerId ||
        catalog.containsKey(model.ref.modelId)) {
      throw const ModelRuntimeException(
        code: ModelRuntimeErrorCode.invalidConfiguration,
        safeMessage: '模型目录配置无效',
        retryable: false,
      );
    }
    catalog[model.ref.modelId] = model;
  }
  return Map.unmodifiable(catalog);
}

ModelDescriptor validateNativeTextRequest(
  ChatRequest request,
  ProviderConfig config,
  Map<String, ModelDescriptor> catalog,
) {
  if (request.model.providerId != config.providerId) {
    throw const ModelRuntimeException(
      code: ModelRuntimeErrorCode.invalidRequest,
      safeMessage: '模型与服务不匹配',
      retryable: false,
    );
  }
  if (!config.enabled) {
    throw const ModelRuntimeException(
      code: ModelRuntimeErrorCode.providerDisabled,
      safeMessage: '模型服务已停用',
      retryable: false,
    );
  }
  final model = catalog[request.model.modelId];
  if (model == null) {
    throw const ModelRuntimeException(
      code: ModelRuntimeErrorCode.modelNotFound,
      safeMessage: '当前模型不在可用目录中',
      retryable: false,
    );
  }
  final capabilities = model.capabilities;
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
  return model;
}

Future<EphemeralCredential> resolveRequiredNativeCredential(
  ProviderConfig config,
  SecretResolver resolver,
) async {
  final ref = config.secretRef;
  if (ref == null) {
    throw const ModelRuntimeException(
      code: ModelRuntimeErrorCode.invalidCredential,
      safeMessage: '模型服务凭证不可用',
      retryable: false,
    );
  }
  try {
    final credential = await resolver.resolve(ref);
    if (credential == null || !credential.isValidAt(DateTime.now())) {
      throw const ModelRuntimeException(
        code: ModelRuntimeErrorCode.invalidCredential,
        safeMessage: '模型服务凭证不可用',
        retryable: false,
      );
    }
    return credential;
  } catch (_) {
    throw const ModelRuntimeException(
      code: ModelRuntimeErrorCode.invalidCredential,
      safeMessage: '模型服务凭证不可用',
      retryable: false,
    );
  }
}

ModelRuntimeException nativeTransportFailure() => const ModelRuntimeException(
  code: ModelRuntimeErrorCode.transportFailure,
  safeMessage: '无法连接模型服务',
  retryable: true,
);
