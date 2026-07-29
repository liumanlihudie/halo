import 'package:halo_mobile/model_runtime/chat_stream_models.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/stream_normalizer_support.dart';

final class GeminiStreamNormalizer extends SafeStructuredSseNormalizer {
  @override
  Iterable<ChatStreamEvent> handleData(
    Map<String, Object?> data,
    StreamNormalizationState state,
  ) sync* {
    state.startIfNeeded();
    final candidates = data['candidates'] as List<Object?>?;
    if (candidates != null && candidates.isNotEmpty) {
      for (final rawCandidate in candidates) {
        final candidate = rawCandidate as Map<String, Object?>;
        final content = candidate['content'] as Map<String, Object?>?;
        final parts = content?['parts'] as List<Object?>? ?? const [];
        for (final rawPart in parts) {
          final part = rawPart as Map<String, Object?>;
          final text = part['text'];
          if (text is String && text.isNotEmpty) {
            yield state.delta(text);
          }
        }

        final rawFinishReason = candidate['finishReason'];
        if (rawFinishReason != null) {
          state.markFinish(_finishReason(rawFinishReason as String));
        }
      }
    } else {
      final promptFeedback = data['promptFeedback'] as Map<String, Object?>?;
      final blockReason = promptFeedback?['blockReason'];
      if (blockReason is! String || blockReason.isEmpty) {
        throw const SafeStreamFailure.malformed();
      }
      state.markFinish(ChatFinishReason.contentFiltered);
    }

    final usage = data['usageMetadata'] as Map<String, Object?>?;
    if (usage != null) {
      final promptTokens = _counterFromSnapshot(
        state,
        'prompt',
        usage['promptTokenCount'],
      );
      final candidateTokens = _counterFromSnapshot(
        state,
        'candidates',
        usage['candidatesTokenCount'],
      );
      final thoughtTokens = _counterFromSnapshot(
        state,
        'thoughts',
        usage['thoughtsTokenCount'],
      );
      final event = state.cumulativeUsage(
        ChatUsage(
          inputTokens: promptTokens,
          outputTokens: candidateTokens + thoughtTokens,
        ),
      );
      if (event != null) yield event;
    }
    if (state.hasPendingFinish) {
      state.markEnd();
    }
  }

  int _counterFromSnapshot(
    StreamNormalizationState state,
    String key,
    Object? value,
  ) {
    if (value == null) return state.protocolCounter(key);
    final count = _requiredToken(value);
    state.setProtocolCounter(key, count);
    return count;
  }

  int _requiredToken(Object? value) {
    if (value is! int || value < 0) {
      throw const SafeStreamFailure.malformed();
    }
    return value;
  }

  ChatFinishReason _finishReason(String value) => switch (value) {
    'STOP' => ChatFinishReason.completed,
    'MAX_TOKENS' => ChatFinishReason.length,
    'SAFETY' ||
    'RECITATION' ||
    'LANGUAGE' ||
    'BLOCKLIST' ||
    'PROHIBITED_CONTENT' ||
    'SPII' ||
    'IMAGE_SAFETY' ||
    'IMAGE_PROHIBITED_CONTENT' ||
    'IMAGE_OTHER' ||
    'NO_IMAGE' ||
    'IMAGE_RECITATION' => ChatFinishReason.contentFiltered,
    _ => ChatFinishReason.unknown,
  };
}
