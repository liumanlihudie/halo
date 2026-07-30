import 'package:flutter/foundation.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';

enum ChatStreamEventType { delta, usage, finish, error }

@immutable
class ChatStreamEvent {
  ChatStreamEvent._({
    required this.seq,
    required this.type,
    this.text,
    this.usage,
    this.finishReason,
    this.errorCode,
    this.safeMessage,
    this.retryable,
  }) {
    if (seq <= 0) {
      throw ArgumentError.value(seq, 'seq');
    }
  }

  factory ChatStreamEvent.delta({required int seq, required String text}) {
    if (text.isEmpty) {
      throw ArgumentError.value(text, 'text');
    }
    return ChatStreamEvent._(
      seq: seq,
      type: ChatStreamEventType.delta,
      text: text,
    );
  }

  factory ChatStreamEvent.usage({required int seq, required ChatUsage usage}) =>
      ChatStreamEvent._(
        seq: seq,
        type: ChatStreamEventType.usage,
        usage: usage,
      );

  factory ChatStreamEvent.finish({
    required int seq,
    required ChatFinishReason finishReason,
  }) => ChatStreamEvent._(
    seq: seq,
    type: ChatStreamEventType.finish,
    finishReason: finishReason,
  );

  factory ChatStreamEvent.error({
    required int seq,
    required ModelRuntimeErrorCode code,
    required String safeMessage,
    required bool retryable,
  }) {
    if (safeMessage.trim().isEmpty) {
      throw ArgumentError.value(safeMessage, 'safeMessage');
    }
    return ChatStreamEvent._(
      seq: seq,
      type: ChatStreamEventType.error,
      errorCode: code,
      safeMessage: safeMessage.trim(),
      retryable: retryable,
    );
  }

  final int seq;
  final ChatStreamEventType type;
  final String? text;
  final ChatUsage? usage;
  final ChatFinishReason? finishReason;
  final ModelRuntimeErrorCode? errorCode;
  final String? safeMessage;
  final bool? retryable;

  bool get isTerminal =>
      type == ChatStreamEventType.finish || type == ChatStreamEventType.error;

  @override
  String toString() => switch (type) {
    ChatStreamEventType.delta => 'ChatStreamEvent.delta(seq: $seq)',
    ChatStreamEventType.usage => 'ChatStreamEvent.usage(seq: $seq)',
    ChatStreamEventType.finish =>
      'ChatStreamEvent.finish(seq: $seq, reason: ${finishReason?.name})',
    ChatStreamEventType.error =>
      'ChatStreamEvent.error(seq: $seq, code: ${errorCode?.name})',
  };
}
