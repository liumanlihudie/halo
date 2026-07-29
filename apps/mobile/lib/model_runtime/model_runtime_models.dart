import 'package:flutter/foundation.dart';

@immutable
class ModelRef {
  ModelRef({required String providerId, required String modelId})
    : providerId = providerId.trim(),
      modelId = modelId.trim() {
    if (this.providerId.isEmpty) {
      throw ArgumentError.value(providerId, 'providerId');
    }
    if (this.modelId.isEmpty) {
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
  }) : requestId = requestId.trim(),
       messages = List.unmodifiable(messages),
       metadata = Map.unmodifiable(metadata) {
    if (this.requestId.isEmpty) {
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
  }) : displayName = displayName.trim() {
    if (this.displayName.isEmpty) {
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
  const ChatResponse({
    required this.requestId,
    required this.model,
    required this.outputText,
    required this.finishReason,
    required this.usage,
    this.providerRequestId,
  });

  final String requestId;
  final ModelRef model;
  final String outputText;
  final ChatFinishReason finishReason;
  final ChatUsage usage;
  final String? providerRequestId;
}
