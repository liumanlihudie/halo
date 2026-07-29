import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/model_runtime.dart';
import 'package:halo_mobile/model_runtime/testing/fake_structured_sse_transport.dart';

void main() {
  test(
    'OpenAI compatible and native streams normalize deltas usage and finish',
    () async {
      for (final normalizer in [
        OpenAICompatibleStreamNormalizer(),
        OpenAINativeStreamNormalizer(),
      ]) {
        final events = await _events(normalizer, [
          _openAIFrame(delta: 'Hel'),
          _openAIFrame(
            delta: 'lo',
            finishReason: 'stop',
            usage: const {'prompt_tokens': 6, 'completion_tokens': 2},
          ),
          StructuredSseFrame.done(),
        ]);

        expect(events.map((event) => event.type), [
          ChatStreamEventType.delta,
          ChatStreamEventType.delta,
          ChatStreamEventType.usage,
          ChatStreamEventType.finish,
        ]);
        expect(events.map((event) => event.seq), [1, 2, 3, 4]);
        expect(events[0].text, 'Hel');
        expect(events[1].text, 'lo');
        expect(
          events[2].usage,
          const ChatUsage(inputTokens: 6, outputTokens: 2),
        );
        expect(events[3].finishReason, ChatFinishReason.completed);
      }
    },
  );

  test(
    'OpenAI duplicate finish fails closed without emitting finish',
    () async {
      final events = await _events(OpenAINativeStreamNormalizer(), [
        _openAIFrame(finishReason: 'stop'),
        _openAIFrame(finishReason: 'length'),
        StructuredSseFrame.done(),
      ]);

      expect(events, hasLength(1));
      expect(events.single.type, ChatStreamEventType.error);
      expect(events.single.errorCode, ModelRuntimeErrorCode.malformedResponse);
    },
  );

  test('OpenAI delta after finish fails closed', () async {
    final events = await _events(OpenAINativeStreamNormalizer(), [
      _openAIFrame(finishReason: 'stop'),
      _openAIFrame(delta: 'too late'),
      StructuredSseFrame.done(),
    ]);

    expect(events.last.type, ChatStreamEventType.error);
    expect(
      events.where((event) => event.type == ChatStreamEventType.finish),
      isEmpty,
    );
  });

  test('OpenAI cumulative usage cannot move backwards', () async {
    final events = await _events(OpenAINativeStreamNormalizer(), [
      _openAIFrame(usage: const {'prompt_tokens': 8, 'completion_tokens': 4}),
      _openAIFrame(
        finishReason: 'stop',
        usage: const {'prompt_tokens': 8, 'completion_tokens': 3},
      ),
      StructuredSseFrame.done(),
    ]);

    expect(events.first.type, ChatStreamEventType.usage);
    expect(events.last.type, ChatStreamEventType.error);
    expect(events.last.seq, 2);
  });

  test('OpenAI content filtering may finish without a delta', () async {
    final events = await _events(OpenAICompatibleStreamNormalizer(), [
      _openAIFrame(finishReason: 'content_filter'),
      StructuredSseFrame.done(),
    ]);

    expect(events, hasLength(1));
    expect(events.single.type, ChatStreamEventType.finish);
    expect(events.single.finishReason, ChatFinishReason.contentFiltered);
  });

  test('OpenAI transport error body is never exposed', () async {
    final events = await _events(OpenAINativeStreamNormalizer(), [
      StructuredSseFrame.error(
        statusCode: 401,
        unsafeBody: 'Authorization Bearer sk-stream-private',
      ),
    ]);

    expect(events.single.type, ChatStreamEventType.error);
    expect(events.single.errorCode, ModelRuntimeErrorCode.invalidCredential);
    expect(events.single.toString(), isNot(contains('sk-stream-private')));
    expect(events.single.safeMessage, isNot(contains('Authorization')));
  });

  test('cancellation immediately closes an OpenAI stream', () async {
    final transport = FakeStructuredSseTransport.controlled();
    final token = CancellationToken();
    final firstEvent = Completer<ChatStreamEvent>();
    final completed = Completer<void>();
    final subscription = OpenAINativeStreamNormalizer()
        .normalize(transport.openFrameStream(), cancellationToken: token)
        .listen((event) {
          if (!firstEvent.isCompleted) firstEvent.complete(event);
        }, onDone: completed.complete);

    transport.add(_openAIFrame(delta: 'first'));
    expect((await firstEvent.future).text, 'first');
    token.cancel();

    await completed.future.timeout(const Duration(seconds: 1));
    await subscription.cancel();
    await transport.close();
  });

  test('normalizer propagates Dart Stream backpressure upstream', () async {
    final transport = FakeStructuredSseTransport.controlled();
    final firstEvent = Completer<void>();
    late final StreamSubscription<ChatStreamEvent> subscription;
    subscription = OpenAINativeStreamNormalizer()
        .normalize(
          transport.openFrameStream(),
          cancellationToken: CancellationToken(),
        )
        .listen((_) {
          if (!firstEvent.isCompleted) {
            firstEvent.complete();
            subscription.pause();
          }
        });

    transport.add(_openAIFrame(delta: 'first'));
    await firstEvent.future;
    await Future<void>.delayed(Duration.zero);

    expect(transport.pauseCount, greaterThan(0));

    subscription.resume();
    transport.add(_openAIFrame(finishReason: 'stop'));
    transport.add(StructuredSseFrame.done());
    await transport.close();
    await subscription.asFuture<void>();
  });

  test('source exceptions become fixed safe terminal errors', () async {
    final transport = FakeStructuredSseTransport.controlled();
    final future = OpenAINativeStreamNormalizer()
        .normalize(
          transport.openFrameStream(),
          cancellationToken: CancellationToken(),
        )
        .toList();

    transport.addError(
      StateError('Authorization Bearer sk-sensitive upstream body'),
    );
    await transport.close();
    final events = await future;

    expect(events.single.type, ChatStreamEventType.error);
    expect(events.single.errorCode, ModelRuntimeErrorCode.streamInterrupted);
    expect(events.single.safeMessage, isNot(contains('sk-sensitive')));
  });

  test('OpenAI done emits finish immediately and cancels upstream', () async {
    var cancelCount = 0;
    final controller = StreamController<StructuredSseFrame>(
      sync: true,
      onCancel: () => cancelCount++,
    );
    final future = OpenAINativeStreamNormalizer()
        .normalize(controller.stream, cancellationToken: CancellationToken())
        .toList();

    controller.add(_openAIFrame(finishReason: 'stop'));
    controller.add(StructuredSseFrame.done());

    final events = await future.timeout(const Duration(seconds: 1));
    expect(events.single.type, ChatStreamEventType.finish);
    expect(cancelCount, 1);
    await controller.close();
  });

  test('terminal success ignores queued source data and errors', () async {
    final controller = StreamController<StructuredSseFrame>(sync: true);
    final future = OpenAINativeStreamNormalizer()
        .normalize(controller.stream, cancellationToken: CancellationToken())
        .toList();

    controller.add(_openAIFrame(finishReason: 'stop'));
    controller.add(StructuredSseFrame.done());
    controller.add(_openAIFrame(delta: 'must be ignored'));
    controller.addError(StateError('sk-after-terminal'));

    final events = await future.timeout(const Duration(seconds: 1));
    expect(events.single.type, ChatStreamEventType.finish);
    await controller.close();
  });

  test(
    'cancellation after first event suppresses the rest of one frame',
    () async {
      final token = CancellationToken();
      final events = <ChatStreamEvent>[];
      final completed = Completer<void>();
      OpenAINativeStreamNormalizer()
          .normalize(
            Stream.fromIterable([
              _openAIFrame(
                delta: 'first',
                finishReason: 'stop',
                usage: const {'prompt_tokens': 5, 'completion_tokens': -1},
              ),
              StructuredSseFrame.done(),
            ]),
            cancellationToken: token,
          )
          .listen((event) {
            events.add(event);
            token.cancel();
          }, onDone: completed.complete);

      await completed.future;
      expect(events, hasLength(1));
      expect(events.single.type, ChatStreamEventType.delta);
    },
  );

  test('upstream cancel failures never override a successful finish', () async {
    final controller = StreamController<StructuredSseFrame>(
      sync: true,
      onCancel: () => throw StateError('Authorization Bearer sk-cancel-secret'),
    );
    final future = OpenAINativeStreamNormalizer()
        .normalize(controller.stream, cancellationToken: CancellationToken())
        .toList();

    controller.add(_openAIFrame(finishReason: 'stop'));
    controller.add(StructuredSseFrame.done());

    final events = await future.timeout(const Duration(seconds: 1));
    expect(events.single.type, ChatStreamEventType.finish);
  });
}

Future<List<ChatStreamEvent>> _events(
  ChatStreamNormalizer normalizer,
  Iterable<StructuredSseFrame> frames,
) {
  final transport = FakeStructuredSseTransport.fromFrames(frames);
  return normalizer
      .normalize(
        transport.openFrameStream(),
        cancellationToken: CancellationToken(),
      )
      .toList();
}

StructuredSseFrame _openAIFrame({
  String? delta,
  String? finishReason,
  Map<String, Object?>? usage,
}) => StructuredSseFrame.data({
  'choices': [
    {
      'delta': {'content': ?delta},
      'finish_reason': finishReason,
    },
  ],
  'usage': ?usage,
});
