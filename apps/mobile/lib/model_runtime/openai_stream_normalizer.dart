import 'package:halo_mobile/model_runtime/chat_stream_models.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/stream_normalizer_support.dart';

final class OpenAICompatibleStreamNormalizer extends _OpenAIStreamNormalizer {}

final class OpenAINativeStreamNormalizer extends _OpenAIStreamNormalizer {}

base class _OpenAIStreamNormalizer extends SafeStructuredSseNormalizer {
  @override
  Iterable<ChatStreamEvent> handleData(
    Map<String, Object?> data,
    StreamNormalizationState state,
  ) sync* {
    state.startIfNeeded();
    final choices = data['choices'] as List<Object?>?;
    if (choices != null) {
      for (final rawChoice in choices) {
        final choice = rawChoice as Map<String, Object?>;
        final delta = choice['delta'] as Map<String, Object?>?;
        if (delta != null) {
          yield* _contentEvents(delta, state);
        }
        final rawFinishReason = choice['finish_reason'];
        if (rawFinishReason != null) {
          state.markFinish(_finishReason(rawFinishReason as String));
        }
      }
    }

    final usage = data['usage'] as Map<String, Object?>?;
    if (usage != null) {
      final previous = state.currentUsage;
      final event = state.cumulativeUsage(
        ChatUsage(
          inputTokens: _tokenOrPrevious(
            usage['prompt_tokens'],
            previous.inputTokens,
          ),
          outputTokens: _tokenOrPrevious(
            usage['completion_tokens'],
            previous.outputTokens,
          ),
        ),
      );
      if (event != null) yield event;
    }

    if (choices == null && usage == null) {
      throw const SafeStreamFailure.malformed();
    }
  }

  Iterable<ChatStreamEvent> _contentEvents(
    Map<String, Object?> delta,
    StreamNormalizationState state,
  ) sync* {
    final content = delta['content'];
    if (content is String && content.isNotEmpty) {
      yield state.delta(content);
    } else if (content is List<Object?>) {
      for (final rawPart in content) {
        final part = rawPart as Map<String, Object?>;
        switch (part['type']) {
          case 'text':
            final text = part['text']! as String;
            if (text.isNotEmpty) yield state.delta(text);
          case 'refusal':
            state.markContentFiltered();
            final refusal = part['refusal'] ?? part['text'];
            if (refusal is String && refusal.isNotEmpty) {
              yield state.delta(refusal);
            }
        }
      }
    } else if (content != null) {
      throw const SafeStreamFailure.malformed();
    }

    final refusal = delta['refusal'];
    if (refusal is String && refusal.isNotEmpty) {
      state.markContentFiltered();
      yield state.delta(refusal);
    } else if (refusal != null) {
      throw const SafeStreamFailure.malformed();
    }
  }

  int _tokenOrPrevious(Object? value, int previous) {
    if (value == null) return previous;
    if (value is! int || value < 0) {
      throw const SafeStreamFailure.malformed();
    }
    return value;
  }

  ChatFinishReason _finishReason(String value) => switch (value) {
    'stop' => ChatFinishReason.completed,
    'length' => ChatFinishReason.length,
    'content_filter' => ChatFinishReason.contentFiltered,
    _ => ChatFinishReason.unknown,
  };
}
