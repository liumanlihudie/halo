import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/native_text_adapter_support.dart';
import 'package:halo_mobile/model_runtime/openai_native_transport.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_registry.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';

class OpenAINativeModelProvider implements ModelProvider {
  OpenAINativeModelProvider({
    required this.config,
    required Iterable<ModelDescriptor> modelCatalog,
    required this.secretResolver,
    required this.transport,
  }) {
    if (config.protocol != ProviderProtocol.openAI) {
      throw const ModelRuntimeException(
        code: ModelRuntimeErrorCode.unsupportedProtocol,
        safeMessage: '该模型服务不是 OpenAI 原生协议',
        retryable: false,
      );
    }
    _catalog = buildNativeModelCatalog(config, modelCatalog);
  }

  @override
  final ProviderConfig config;
  final SecretResolver secretResolver;
  final OpenAINativeHttpTransport transport;
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
    final body = <String, Object?>{
      'model': request.model.modelId,
      'messages': request.messages.map((message) => message.toJson()).toList(),
      if (request.temperature != null) 'temperature': request.temperature,
      if (request.maxOutputTokens != null)
        'max_completion_tokens': request.maxOutputTokens,
    };

    late final OpenAINativeTransportResponse transportResponse;
    try {
      transportResponse = await transport.sendChat(
        OpenAINativeTransportRequest(
          endpoint: _chatEndpoint(config.baseUri),
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
    final choices = body['choices']! as List<Object?>;
    final choice = choices.first! as Map<String, Object?>;
    final message = choice['message']! as Map<String, Object?>;
    var finishReason = switch (choice['finish_reason'] as String?) {
      'stop' => ChatFinishReason.completed,
      'length' => ChatFinishReason.length,
      'content_filter' => ChatFinishReason.contentFiltered,
      _ => ChatFinishReason.unknown,
    };
    final parsedContent = _parseAssistantMessage(message);
    if (parsedContent.refused) {
      finishReason = ChatFinishReason.contentFiltered;
    }
    final text = parsedContent.text;
    if (text.isEmpty && finishReason != ChatFinishReason.contentFiltered) {
      throw const FormatException();
    }
    final usage = body['usage'] as Map<String, Object?>?;
    return ChatResponse(
      requestId: request.requestId,
      model: request.model,
      outputText: text,
      finishReason: finishReason,
      usage: ChatUsage(
        inputTokens: _optionalTokenCount(usage?['prompt_tokens']),
        outputTokens: _optionalTokenCount(usage?['completion_tokens']),
      ),
      providerRequestId: body['id'] as String?,
    );
  }

  _OpenAIMessageContent _parseAssistantMessage(Map<String, Object?> message) {
    final pieces = <String>[];
    var refused = false;
    final content = message['content'];
    if (content is String) {
      pieces.add(content);
    } else if (content is List<Object?>) {
      for (final rawPart in content) {
        final part = rawPart as Map<String, Object?>;
        switch (part['type']) {
          case 'text':
            pieces.add(part['text']! as String);
          case 'refusal':
            refused = true;
            final refusal = part['refusal'] ?? part['text'];
            if (refusal is String) {
              pieces.add(refusal);
            }
        }
      }
    } else if (content != null) {
      throw const FormatException();
    }

    final refusal = message['refusal'];
    if (refusal is String && refusal.isNotEmpty) {
      refused = true;
      pieces.add(refusal);
    } else if (refusal != null) {
      throw const FormatException();
    }
    return _OpenAIMessageContent(text: pieces.join(), refused: refused);
  }

  int _optionalTokenCount(Object? value) {
    if (value == null) {
      return 0;
    }
    if (value is! int || value < 0) {
      throw const FormatException();
    }
    return value;
  }

  Uri _chatEndpoint(Uri baseUri) {
    final path = baseUri.path.endsWith('/')
        ? baseUri.path.substring(0, baseUri.path.length - 1)
        : baseUri.path;
    return baseUri.replace(path: '$path/chat/completions');
  }
}

class _OpenAIMessageContent {
  const _OpenAIMessageContent({required this.text, required this.refused});

  final String text;
  final bool refused;
}
