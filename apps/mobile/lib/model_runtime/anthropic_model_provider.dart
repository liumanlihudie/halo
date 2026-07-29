import 'dart:math' as math;

import 'package:halo_mobile/model_runtime/anthropic_transport.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/native_text_adapter_support.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_registry.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';

class AnthropicModelProvider implements ModelProvider {
  AnthropicModelProvider({
    required this.config,
    required Iterable<ModelDescriptor> modelCatalog,
    required this.secretResolver,
    required this.transport,
  }) {
    if (config.protocol != ProviderProtocol.anthropic) {
      throw const ModelRuntimeException(
        code: ModelRuntimeErrorCode.unsupportedProtocol,
        safeMessage: '该模型服务不是 Anthropic 原生协议',
        retryable: false,
      );
    }
    _catalog = buildNativeModelCatalog(config, modelCatalog);
  }

  static const apiVersion = '2023-06-01';

  @override
  final ProviderConfig config;
  final SecretResolver secretResolver;
  final AnthropicHttpTransport transport;
  late final Map<String, ModelDescriptor> _catalog;

  @override
  Iterable<ModelDescriptor> get modelCatalog => _catalog.values;

  @override
  Future<ChatResponse> chat(ChatRequest request) async {
    final descriptor = validateNativeTextRequest(request, config, _catalog);
    final temperature = request.temperature;
    if (temperature != null && temperature > 1) {
      throw const ModelRuntimeException(
        code: ModelRuntimeErrorCode.unsupportedCapability,
        safeMessage: '当前模型不支持这项文字请求',
        retryable: false,
      );
    }
    final credential = await resolveRequiredNativeCredential(
      config,
      secretResolver,
    );
    final system = request.messages
        .where((message) => message.role == ChatRole.system)
        .map((message) => message.content)
        .join('\n\n');
    final body = <String, Object?>{
      'model': request.model.modelId,
      if (system.isNotEmpty) 'system': system,
      'messages': request.messages
          .where((message) => message.role != ChatRole.system)
          .map((message) => message.toJson())
          .toList(),
      if (request.temperature != null) 'temperature': request.temperature,
      'max_tokens':
          request.maxOutputTokens ??
          math.min(1024, descriptor.capabilities.maxOutputTokens),
    };

    late final AnthropicTransportResponse transportResponse;
    try {
      transportResponse = await transport.sendMessage(
        AnthropicTransportRequest(
          endpoint: _messageEndpoint(config.baseUri),
          body: body,
          credential: credential,
          apiVersion: apiVersion,
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
    final blocks = body['content']! as List<Object?>;
    final finishReason = switch (body['stop_reason'] as String?) {
      'end_turn' || 'stop_sequence' => ChatFinishReason.completed,
      'max_tokens' ||
      'model_context_window_exceeded' => ChatFinishReason.length,
      'refusal' => ChatFinishReason.contentFiltered,
      _ => ChatFinishReason.unknown,
    };
    final text = blocks
        .cast<Map<String, Object?>>()
        .where((block) => block['type'] == 'text')
        .map((block) => block['text']! as String)
        .join();
    final usage = body['usage']! as Map<String, Object?>;
    return ChatResponse(
      requestId: request.requestId,
      model: request.model,
      outputText: text,
      finishReason: finishReason,
      usage: ChatUsage(
        inputTokens:
            _requiredTokenCount(usage['input_tokens']) +
            _optionalTokenCount(usage['cache_creation_input_tokens']) +
            _optionalTokenCount(usage['cache_read_input_tokens']),
        outputTokens: usage['output_tokens']! as int,
      ),
      providerRequestId: body['id'] as String?,
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

  Uri _messageEndpoint(Uri baseUri) {
    final path = baseUri.path.endsWith('/')
        ? baseUri.path.substring(0, baseUri.path.length - 1)
        : baseUri.path;
    return baseUri.replace(path: '$path/messages');
  }
}
