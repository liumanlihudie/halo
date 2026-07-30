import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/model_runtime.dart';
import 'package:halo_mobile/model_runtime/testing/fake_structured_sse_transport.dart';

void main() {
  test(
    'Anthropic stream maps start delta cumulative usage and finish',
    () async {
      final events = await _events([
        StructuredSseFrame.data({
          'type': 'message_start',
          'message': {
            'usage': {
              'input_tokens': 10,
              'cache_creation_input_tokens': 2,
              'cache_read_input_tokens': 3,
              'output_tokens': 0,
            },
          },
        }),
        StructuredSseFrame.data({
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'text', 'text': ''},
        }),
        StructuredSseFrame.data({
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': 'Claude'},
        }),
        StructuredSseFrame.data({
          'type': 'future_metadata_event',
          'private_future_field': 'ignored',
        }),
        StructuredSseFrame.data({'type': 'content_block_stop', 'index': 0}),
        StructuredSseFrame.data({
          'type': 'message_delta',
          'delta': {'stop_reason': 'max_tokens'},
          'usage': {'output_tokens': 4},
        }),
        StructuredSseFrame.data({'type': 'message_stop'}),
      ]);

      expect(events.map((event) => event.type), [
        ChatStreamEventType.usage,
        ChatStreamEventType.delta,
        ChatStreamEventType.usage,
        ChatStreamEventType.finish,
      ]);
      expect(events.map((event) => event.seq), [1, 2, 3, 4]);
      expect(
        events[0].usage,
        const ChatUsage(inputTokens: 15, outputTokens: 0),
      );
      expect(events[1].text, 'Claude');
      expect(
        events[2].usage,
        const ChatUsage(inputTokens: 15, outputTokens: 4),
      );
      expect(events[3].finishReason, ChatFinishReason.length);
    },
  );

  test('Anthropic requires message start and message stop', () async {
    final badStart = await _events([
      StructuredSseFrame.data({
        'type': 'content_block_delta',
        'delta': {'type': 'text_delta', 'text': 'early'},
      }),
    ]);
    final missingStop = await _events([
      StructuredSseFrame.data({
        'type': 'message_start',
        'message': {
          'usage': {'input_tokens': 1, 'output_tokens': 0},
        },
      }),
      StructuredSseFrame.data({
        'type': 'message_delta',
        'delta': {'stop_reason': 'end_turn'},
        'usage': {'output_tokens': 1},
      }),
    ]);

    expect(badStart.single.type, ChatStreamEventType.error);
    expect(missingStop.last.type, ChatStreamEventType.error);
    expect(
      missingStop.where((event) => event.type == ChatStreamEventType.finish),
      isEmpty,
    );
  });

  test('Anthropic filtered empty stream is a valid finish', () async {
    final events = await _events([
      StructuredSseFrame.data({
        'type': 'message_start',
        'message': {
          'usage': {'input_tokens': 0, 'output_tokens': 0},
        },
      }),
      StructuredSseFrame.data({
        'type': 'message_delta',
        'delta': {'stop_reason': 'refusal'},
        'usage': {'output_tokens': 0},
      }),
      StructuredSseFrame.data({'type': 'message_stop'}),
    ]);

    expect(
      events.where((event) => event.type == ChatStreamEventType.delta),
      isEmpty,
    );
    expect(events.single.type, ChatStreamEventType.finish);
    expect(events.single.finishReason, ChatFinishReason.contentFiltered);
  });

  test('Anthropic content block boundaries must be balanced', () async {
    final events = await _events([
      StructuredSseFrame.data({
        'type': 'message_start',
        'message': {
          'usage': {'input_tokens': 1, 'output_tokens': 0},
        },
      }),
      StructuredSseFrame.data({'type': 'content_block_stop', 'index': 0}),
      StructuredSseFrame.data({
        'type': 'message_delta',
        'delta': {'stop_reason': 'end_turn'},
        'usage': {'output_tokens': 0},
      }),
      StructuredSseFrame.data({'type': 'message_stop'}),
    ]);

    expect(events.last.type, ChatStreamEventType.error);
    expect(events.last.errorCode, ModelRuntimeErrorCode.malformedResponse);
    expect(
      events.where((event) => event.type == ChatStreamEventType.finish),
      isEmpty,
    );
  });

  test('Anthropic message stop emits finish without source close', () async {
    var cancelCount = 0;
    final controller = StreamController<StructuredSseFrame>(
      sync: true,
      onCancel: () => cancelCount++,
    );
    final future = AnthropicStreamNormalizer()
        .normalize(controller.stream, cancellationToken: CancellationToken())
        .toList();

    controller.add(
      StructuredSseFrame.data({
        'type': 'message_start',
        'message': {
          'usage': {'input_tokens': 1, 'output_tokens': 0},
        },
      }),
    );
    controller.add(
      StructuredSseFrame.data({
        'type': 'message_delta',
        'delta': {'stop_reason': 'end_turn'},
        'usage': {'output_tokens': 1},
      }),
    );
    controller.add(StructuredSseFrame.data({'type': 'message_stop'}));

    final events = await future.timeout(const Duration(seconds: 1));
    expect(events.last.type, ChatStreamEventType.finish);
    expect(cancelCount, 1);
    await controller.close();
  });
}

Future<List<ChatStreamEvent>> _events(Iterable<StructuredSseFrame> frames) {
  final transport = FakeStructuredSseTransport.fromFrames(frames);
  return AnthropicStreamNormalizer()
      .normalize(
        transport.openFrameStream(),
        cancellationToken: CancellationToken(),
      )
      .toList();
}
