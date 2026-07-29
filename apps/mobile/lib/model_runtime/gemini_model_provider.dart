import 'package:halo_mobile/model_runtime/gemini_transport.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/native_text_adapter_support.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_registry.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';

class GeminiModelProvider implements ModelProvider {
  GeminiModelProvider({
    required this.config,
    required Iterable<ModelDescriptor> modelCatalog,
    required this.secretResolver,
    required this.transport,
  }) {
    if (config.protocol != ProviderProtocol.gemini) {
      throw const ModelRuntimeException(
        code: ModelRuntimeErrorCode.unsupportedProtocol,
        safeMessage: '该模型服务不是 Gemini 原生协议',
        retryable: false,
      );
    }
    _catalog = buildNativeModelCatalog(config, modelCatalog);
  }

  @override
  final ProviderConfig config;
  final SecretResolver secretResolver;
  final GeminiHttpTransport transport;
  late final Map<String, ModelDescriptor> _catalog;

  @override
  Iterable<ModelDescriptor> get modelCatalog => _catalog.values;

  @override
  Future<ChatResponse> chat(ChatRequest request) async {
    validateNativeTextRequest(request, config, _catalog);
    requireActiveChatRequest(request);
    final credential = await resolveRequiredNativeCredential(
      config,
      secretResolver,
    );
    requireActiveChatRequest(request);
    final system = request.messages
        .where((message) => message.role == ChatRole.system)
        .map((message) => message.content)
        .join('\n\n');
    final generationConfig = <String, Object?>{
      if (request.temperature != null) 'temperature': request.temperature,
      if (request.maxOutputTokens != null)
        'maxOutputTokens': request.maxOutputTokens,
    };
    final body = <String, Object?>{
      if (system.isNotEmpty)
        'systemInstruction': {
          'parts': [
            {'text': system},
          ],
        },
      'contents': request.messages
          .where((message) => message.role != ChatRole.system)
          .map(
            (message) => {
              'role': message.role == ChatRole.assistant ? 'model' : 'user',
              'parts': [
                {'text': message.content},
              ],
            },
          )
          .toList(),
      if (generationConfig.isNotEmpty) 'generationConfig': generationConfig,
    };

    late final GeminiTransportResponse transportResponse;
    try {
      transportResponse = await transport.generateContent(
        GeminiTransportRequest(
          endpoint: _generateEndpoint(config.baseUri, request.model.modelId),
          body: body,
          credential: credential,
          cancellationToken: request.cancellationToken,
        ),
      );
    } catch (_) {
      throw nativeTransportFailure();
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

  ChatResponse _parseResponse(ChatRequest request, Map<String, Object?> body) {
    final usage = body['usageMetadata']! as Map<String, Object?>;
    final inputTokens = _requiredTokenCount(usage['promptTokenCount']);
    final outputTokens =
        _optionalTokenCount(usage['candidatesTokenCount']) +
        _optionalTokenCount(usage['thoughtsTokenCount']);
    final candidates = body['candidates'] as List<Object?>?;
    if (candidates == null || candidates.isEmpty) {
      final promptFeedback = body['promptFeedback'] as Map<String, Object?>?;
      final blockReason = promptFeedback?['blockReason'];
      if (blockReason is! String || blockReason.isEmpty) {
        throw const FormatException();
      }
      return ChatResponse(
        requestId: request.requestId,
        model: request.model,
        outputText: '',
        finishReason: ChatFinishReason.contentFiltered,
        usage: ChatUsage(inputTokens: inputTokens, outputTokens: outputTokens),
        providerRequestId: body['responseId'] as String?,
      );
    }
    final candidate = candidates.first! as Map<String, Object?>;
    final finishReason = switch (candidate['finishReason'] as String?) {
      'STOP' => ChatFinishReason.completed,
      'MAX_TOKENS' => ChatFinishReason.length,
      'SAFETY' ||
      'RECITATION' ||
      'BLOCKLIST' ||
      'PROHIBITED_CONTENT' => ChatFinishReason.contentFiltered,
      _ => ChatFinishReason.unknown,
    };
    final content = candidate['content'] as Map<String, Object?>?;
    final parts = content?['parts'] as List<Object?>? ?? const [];
    final text = parts
        .cast<Map<String, Object?>>()
        .where((part) => part['text'] is String)
        .map((part) => part['text']! as String)
        .join();
    if (text.isEmpty && finishReason != ChatFinishReason.contentFiltered) {
      throw const FormatException();
    }
    return ChatResponse(
      requestId: request.requestId,
      model: request.model,
      outputText: text,
      finishReason: finishReason,
      usage: ChatUsage(inputTokens: inputTokens, outputTokens: outputTokens),
      providerRequestId: body['responseId'] as String?,
    );
  }

  int _requiredTokenCount(Object? value) {
    if (value is! int || value < 0) {
      throw const FormatException();
    }
    return value;
  }

  int _optionalTokenCount(Object? value) {
    if (value == null) {
      return 0;
    }
    return _requiredTokenCount(value);
  }

  Uri _generateEndpoint(Uri baseUri, String modelId) {
    final path = baseUri.path.endsWith('/')
        ? baseUri.path.substring(0, baseUri.path.length - 1)
        : baseUri.path;
    return baseUri.replace(path: '$path/models/$modelId:generateContent');
  }
}
