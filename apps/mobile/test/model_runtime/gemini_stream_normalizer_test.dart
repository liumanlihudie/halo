import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/model_runtime.dart';
import 'package:halo_mobile/model_runtime/testing/fake_structured_sse_transport.dart';

void main() {
  test('Gemini stream maps text and cumulative usage snapshots', () async {
    final events = await _events([
      _geminiFrame(
        text: 'Ge',
        usage: const {
          'promptTokenCount': 10,
          'candidatesTokenCount': 1,
          'thoughtsTokenCount': 2,
        },
      ),
      _geminiFrame(
        text: 'mini',
        finishReason: 'STOP',
        usage: const {
          'promptTokenCount': 10,
          'candidatesTokenCount': 3,
          'thoughtsTokenCount': 4,
        },
      ),
    ]);

    expect(events.map((event) => event.type), [
      ChatStreamEventType.delta,
      ChatStreamEventType.usage,
      ChatStreamEventType.delta,
      ChatStreamEventType.usage,
      ChatStreamEventType.finish,
    ]);
    expect(events.map((event) => event.seq), [1, 2, 3, 4, 5]);
    expect(events[1].usage, const ChatUsage(inputTokens: 10, outputTokens: 3));
    expect(events[3].usage, const ChatUsage(inputTokens: 10, outputTokens: 7));
    expect(events.last.finishReason, ChatFinishReason.completed);
  });

  test('Gemini prompt block may finish without candidates or text', () async {
    final events = await _events([
      StructuredSseFrame.data({
        'promptFeedback': {'blockReason': 'SAFETY'},
        'usageMetadata': {'promptTokenCount': 5},
      }),
    ]);

    expect(
      events.where((event) => event.type == ChatStreamEventType.delta),
      isEmpty,
    );
    expect(events.last.type, ChatStreamEventType.finish);
    expect(events.last.finishReason, ChatFinishReason.contentFiltered);
  });

  test('Gemini first terminal finish ignores later frames', () async {
    final events = await _events([
      _geminiFrame(finishReason: 'STOP'),
      _geminiFrame(finishReason: 'MAX_TOKENS'),
    ]);

    expect(events, hasLength(1));
    expect(events.single.type, ChatStreamEventType.finish);
    expect(events.single.finishReason, ChatFinishReason.completed);
  });

  test(
    'Gemini usage fields independently retain prior cumulative values',
    () async {
      final events = await _events([
        _geminiFrame(
          text: 'one',
          usage: const {
            'promptTokenCount': 10,
            'candidatesTokenCount': 2,
            'thoughtsTokenCount': 5,
          },
        ),
        _geminiFrame(text: 'two', usage: const {'candidatesTokenCount': 3}),
        _geminiFrame(
          finishReason: 'STOP',
          usage: const {'thoughtsTokenCount': 6},
        ),
      ]);

      final usages = events
          .where((event) => event.type == ChatStreamEventType.usage)
          .map((event) => event.usage)
          .toList();
      expect(usages, [
        const ChatUsage(inputTokens: 10, outputTokens: 7),
        const ChatUsage(inputTokens: 10, outputTokens: 8),
        const ChatUsage(inputTokens: 10, outputTokens: 9),
      ]);
      expect(events.last.type, ChatStreamEventType.finish);
    },
  );

  test(
    'Gemini official filtering reasons allow an empty terminal stream',
    () async {
      for (final reason in ['SPII', 'LANGUAGE', 'IMAGE_SAFETY']) {
        final events = await _events([_geminiFrame(finishReason: reason)]);

        expect(
          events.single.finishReason,
          ChatFinishReason.contentFiltered,
          reason: reason,
        );
      }
    },
  );
}

Future<List<ChatStreamEvent>> _events(Iterable<StructuredSseFrame> frames) {
  final transport = FakeStructuredSseTransport.fromFrames(frames);
  return GeminiStreamNormalizer()
      .normalize(
        transport.openFrameStream(),
        cancellationToken: CancellationToken(),
      )
      .toList();
}

StructuredSseFrame _geminiFrame({
  String? text,
  String? finishReason,
  Map<String, Object?>? usage,
}) => StructuredSseFrame.data({
  'candidates': [
    {
      if (text != null)
        'content': {
          'parts': [
            {'text': text},
          ],
        },
      'finishReason': ?finishReason,
    },
  ],
  'usageMetadata': ?usage,
});
