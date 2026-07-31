import 'package:flutter/foundation.dart';
import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/runtime_string_validation.dart';

@immutable
class ModelRef {
  ModelRef({required String providerId, required String modelId})
    : providerId = providerId,
      modelId = modelId {
    if (!isCanonicalRuntimeId(providerId)) {
      throw ArgumentError.value(providerId, 'providerId');
    }
    if (!isSafeRuntimeIdentifier(modelId, maxUtf8Bytes: 256)) {
      throw ArgumentError.value(modelId, 'modelId');
    }
  }

  final String providerId;
  final String modelId;

  @override
  bool operator ==(Object other) =>
      other is ModelRef &&
      other.providerId == providerId &&
      other.modelId == modelId;

  @override
  int get hashCode => Object.hash(providerId, modelId);

  @override
  String toString() => '$providerId/$modelId';
}

enum ChatRole { system, user, assistant }

@immutable
class ChatMessage {
  ChatMessage({required this.role, required this.content}) {
    if (content.trim().isEmpty) {
      throw ArgumentError.value(content, 'content');
    }
  }

  final ChatRole role;
  final String content;

  Map<String, Object?> toJson() => {'role': role.name, 'content': content};
}

@immutable
class ChatRequest {
  ChatRequest({
    required String requestId,
    required this.model,
    required List<ChatMessage> messages,
    this.temperature,
    this.maxOutputTokens,
    Map<String, Object?> metadata = const {},
    this.cancellationToken,
  }) : requestId = requestId,
       messages = List.unmodifiable(messages),
       metadata = Map.unmodifiable(metadata) {
    if (!isSafeRuntimeIdentifier(requestId, maxUtf8Bytes: 256)) {
      throw ArgumentError.value(requestId, 'requestId');
    }
    if (this.messages.isEmpty) {
      throw ArgumentError.value(messages, 'messages');
    }
    final value = temperature;
    if (value != null && (!value.isFinite || value < 0 || value > 2)) {
      throw ArgumentError.value(value, 'temperature');
    }
    final tokens = maxOutputTokens;
    if (tokens != null && (tokens <= 0 || tokens > maximumOutputTokens)) {
      throw ArgumentError.value(tokens, 'maxOutputTokens');
    }
  }

  static const maximumOutputTokens = 1000000;

  final String requestId;
  final ModelRef model;
  final List<ChatMessage> messages;
  final double? temperature;
  final int? maxOutputTokens;
  final Map<String, Object?> metadata;
  final CancellationToken? cancellationToken;

  ChatRequest withCancellationToken(CancellationToken token) => ChatRequest(
    requestId: requestId,
    model: model,
    messages: messages,
    temperature: temperature,
    maxOutputTokens: maxOutputTokens,
    metadata: metadata,
    cancellationToken: token,
  );
}

void requireActiveChatRequest(ChatRequest request) {
  if (request.cancellationToken?.isCancelled ?? false) {
    throw const ModelRuntimeException(
      code: ModelRuntimeErrorCode.streamInterrupted,
      safeMessage: '模型请求已取消',
      retryable: false,
    );
  }
}

@immutable
class ModelCapabilities {
  const ModelCapabilities({
    required this.textGeneration,
    required this.systemMessages,
    required this.maxOutputTokens,
    this.supportsTemperature = true,
  });

  const ModelCapabilities.text({
    this.systemMessages = true,
    this.maxOutputTokens = 16384,
    this.supportsTemperature = true,
  }) : textGeneration = true;

  final bool textGeneration;
  final bool systemMessages;
  final int maxOutputTokens;
  final bool supportsTemperature;
}

@immutable
class ModelDescriptor {
  ModelDescriptor({
    required this.ref,
    required String displayName,
    required this.capabilities,
    Set<String> declaredModalities = const {},
  }) : displayName = displayName,
       declaredModalities = Set.unmodifiable(
         declaredModalities.map((type) => type.toLowerCase()),
       ) {
    if (!isSafeRuntimeDisplayText(displayName)) {
      throw ArgumentError.value(displayName, 'displayName');
    }
    if (capabilities.maxOutputTokens <= 0) {
      throw ArgumentError.value(
        capabilities.maxOutputTokens,
        'capabilities.maxOutputTokens',
      );
    }
  }

  final ModelRef ref;
  final String displayName;
  final ModelCapabilities capabilities;

  /// Endpoint types the provider declared for this model, lowercased and
  /// otherwise verbatim. Empty means the provider declared nothing, which is
  /// not a claim that the model is text-only.
  final Set<String> declaredModalities;
}

enum ChatFinishReason { completed, length, contentFiltered, unknown }

@immutable
class ChatUsage {
  const ChatUsage({required this.inputTokens, required this.outputTokens});

  final int inputTokens;
  final int outputTokens;
  int get totalTokens => inputTokens + outputTokens;

  @override
  bool operator ==(Object other) =>
      other is ChatUsage &&
      other.inputTokens == inputTokens &&
      other.outputTokens == outputTokens;

  @override
  int get hashCode => Object.hash(inputTokens, outputTokens);
}

@immutable
class ChatResponse {
  ChatResponse({
    required String requestId,
    required this.model,
    required this.outputText,
    required this.finishReason,
    required this.usage,
    String? providerRequestId,
  }) : requestId = requestId,
       providerRequestId = providerRequestId {
    if (!isSafeRuntimeIdentifier(requestId, maxUtf8Bytes: 256)) {
      throw ArgumentError.value(requestId, 'requestId');
    }
    if (providerRequestId != null &&
        !isSafeRuntimeIdentifier(providerRequestId, maxUtf8Bytes: 256)) {
      throw ArgumentError.value(providerRequestId, 'providerRequestId');
    }
  }

  final String requestId;
  final ModelRef model;
  final String outputText;
  final ChatFinishReason finishReason;
  final ChatUsage usage;
  final String? providerRequestId;
}
