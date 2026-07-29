import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/openai_compatible_transport.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_registry.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';

class OpenAICompatibleModelProvider implements ModelProvider {
  OpenAICompatibleModelProvider({
    required this.config,
    required Iterable<ModelDescriptor> modelCatalog,
    required this.secretResolver,
    required this.transport,
  }) {
    if (config.protocol != ProviderProtocol.openAICompatible) {
      throw const ModelRuntimeException(
        code: ModelRuntimeErrorCode.unsupportedProtocol,
        safeMessage: '该模型服务需要原生协议适配器',
        retryable: false,
      );
    }
    final catalog = <String, ModelDescriptor>{};
    for (final model in modelCatalog) {
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
    _catalog = Map.unmodifiable(catalog);
  }

  @override
  final ProviderConfig config;
  final SecretResolver secretResolver;
  final OpenAICompatibleHttpTransport transport;
  late final Map<String, ModelDescriptor> _catalog;

  @override
  Iterable<ModelDescriptor> get modelCatalog => _catalog.values;

  @override
  Future<ChatResponse> chat(ChatRequest request) async {
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
    final model = _catalog[request.model.modelId];
    if (model == null) {
      throw const ModelRuntimeException(
        code: ModelRuntimeErrorCode.modelNotFound,
        safeMessage: '当前模型不在可用目录中',
        retryable: false,
      );
    }
    _validateCapabilities(request, model.capabilities);
    requireActiveChatRequest(request);

    final credential = await _resolveCredential(config.secretRef);
    final headerCredentials = <String, EphemeralCredential>{};
    for (final entry in config.headerSecretRefs.entries) {
      headerCredentials[entry.key] = await _requiredCredential(entry.value);
    }
    requireActiveChatRequest(request);

    final body = <String, Object?>{
      'model': request.model.modelId,
      'messages': request.messages.map((message) => message.toJson()).toList(),
      if (request.temperature != null) 'temperature': request.temperature,
      if (request.maxOutputTokens != null)
        'max_tokens': request.maxOutputTokens,
      'stream': false,
    };

    late final OpenAICompatibleTransportResponse transportResponse;
    try {
      transportResponse = await transport.sendChat(
        OpenAICompatibleTransportRequest(
          endpoint: _chatEndpoint(config.baseUri),
          body: body,
          credential: credential,
          headerCredentials: headerCredentials,
          cancellationToken: request.cancellationToken,
        ),
      );
    } catch (_) {
      throw const ModelRuntimeException(
        code: ModelRuntimeErrorCode.transportFailure,
        safeMessage: '无法连接模型服务',
        retryable: true,
      );
    }

    if (transportResponse.statusCode < 200 ||
        transportResponse.statusCode >= 300) {
      throw ModelRuntimeErrorMapper.fromHttpStatus(
        transportResponse.statusCode,
        retryAfter: transportResponse.retryAfter,
      );
    }

    try {
      return _parseResponse(request, transportResponse.body);
    } catch (_) {
      throw const ModelRuntimeException(
        code: ModelRuntimeErrorCode.malformedResponse,
        safeMessage: '模型服务返回了无法识别的数据',
        retryable: false,
      );
    }
  }

  void _validateCapabilities(
    ChatRequest request,
    ModelCapabilities capabilities,
  ) {
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

  Future<EphemeralCredential?> _resolveCredential(SecretRef? ref) async {
    if (ref == null) return null;
    return _requiredCredential(ref);
  }

  Future<EphemeralCredential> _requiredCredential(SecretRef ref) async {
    final credential = await secretResolver.resolve(ref);
    if (credential == null || !credential.isValidAt(DateTime.now())) {
      throw const ModelRuntimeException(
        code: ModelRuntimeErrorCode.invalidCredential,
        safeMessage: '模型服务凭证不可用',
        retryable: false,
      );
    }
    return credential;
  }

  ChatResponse _parseResponse(ChatRequest request, Map<String, Object?> body) {
    final choices = body['choices']! as List<Object?>;
    final choice = choices.first! as Map<String, Object?>;
    final message = choice['message']! as Map<String, Object?>;
    final outputText = message['content']! as String;
    final usage = body['usage'] as Map<String, Object?>?;

    return ChatResponse(
      requestId: request.requestId,
      model: request.model,
      outputText: outputText,
      finishReason: _finishReason(choice['finish_reason'] as String?),
      usage: ChatUsage(
        inputTokens: usage?['prompt_tokens'] as int? ?? 0,
        outputTokens: usage?['completion_tokens'] as int? ?? 0,
      ),
      providerRequestId: body['id'] as String?,
    );
  }

  ChatFinishReason _finishReason(String? value) => switch (value) {
    'stop' => ChatFinishReason.completed,
    'length' => ChatFinishReason.length,
    'content_filter' => ChatFinishReason.contentFiltered,
    _ => ChatFinishReason.unknown,
  };

  Uri _chatEndpoint(Uri baseUri) {
    final basePath = baseUri.path.endsWith('/')
        ? baseUri.path.substring(0, baseUri.path.length - 1)
        : baseUri.path;
    return baseUri.replace(path: '$basePath/chat/completions');
  }
}
