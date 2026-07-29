import 'package:halo_mobile/model_runtime/chat_stream_models.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/stream_normalizer_support.dart';

final class AnthropicStreamNormalizer extends SafeStructuredSseNormalizer {
  @override
  Iterable<ChatStreamEvent> handleData(
    Map<String, Object?> data,
    StreamNormalizationState state,
  ) sync* {
    switch (data['type']) {
      case 'message_start':
        state.start();
        final message = data['message']! as Map<String, Object?>;
        final usage = message['usage']! as Map<String, Object?>;
        final event = state.cumulativeUsage(
          ChatUsage(
            inputTokens:
                _requiredToken(usage['input_tokens']) +
                _optionalToken(usage['cache_creation_input_tokens']) +
                _optionalToken(usage['cache_read_input_tokens']),
            outputTokens: _optionalToken(usage['output_tokens']),
          ),
        );
        if (event != null) yield event;
      case 'content_block_start':
        state.startContentBlock(_requiredIndex(data['index']));
      case 'content_block_delta':
        if (!state.hasStarted) {
          throw const SafeStreamFailure.malformed();
        }
        state.ensureContentBlockActive(_requiredIndex(data['index']));
        final delta = data['delta']! as Map<String, Object?>;
        if (delta['type'] != 'text_delta') {
          throw const SafeStreamFailure.malformed();
        }
        final text = delta['text']! as String;
        if (text.isNotEmpty) yield state.delta(text);
      case 'content_block_stop':
        state.stopContentBlock(_requiredIndex(data['index']));
      case 'message_delta':
        if (!state.hasStarted) {
          throw const SafeStreamFailure.malformed();
        }
        final delta = data['delta']! as Map<String, Object?>;
        final stopReason = delta['stop_reason'];
        final usage = data['usage'] as Map<String, Object?>?;
        if (usage != null) {
          final previous = state.currentUsage;
          final event = state.cumulativeUsage(
            ChatUsage(
              inputTokens: previous.inputTokens,
              outputTokens: usage.containsKey('output_tokens')
                  ? _requiredToken(usage['output_tokens'])
                  : previous.outputTokens,
            ),
          );
          if (event != null) yield event;
        }
        if (stopReason != null) {
          state.ensureNoOpenContentBlocks();
          state.markFinish(_finishReason(stopReason as String));
        }
      case 'message_stop':
        state.ensureNoOpenContentBlocks();
        state.markEnd();
      case 'ping':
        if (!state.hasStarted) {
          throw const SafeStreamFailure.malformed();
        }
      case 'error':
        throw const SafeStreamFailure(
          ModelRuntimeException(
            code: ModelRuntimeErrorCode.transportFailure,
            safeMessage: '模型流连接失败',
            retryable: true,
          ),
        );
      default:
        // Anthropic may add new informational event types. Ignoring them
        // preserves forward compatibility without mutating stream state.
        return;
    }
  }

  int _requiredToken(Object? value) {
    if (value is! int || value < 0) {
      throw const SafeStreamFailure.malformed();
    }
    return value;
  }

  int _requiredIndex(Object? value) {
    if (value is! int || value < 0) {
      throw const SafeStreamFailure.malformed();
    }
    return value;
  }

  int _optionalToken(Object? value) =>
      value == null ? 0 : _requiredToken(value);

  ChatFinishReason _finishReason(String value) => switch (value) {
    'end_turn' || 'stop_sequence' => ChatFinishReason.completed,
    'max_tokens' || 'model_context_window_exceeded' => ChatFinishReason.length,
    'refusal' => ChatFinishReason.contentFiltered,
    _ => ChatFinishReason.unknown,
  };
}
