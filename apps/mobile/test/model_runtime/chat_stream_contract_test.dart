import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/model_runtime.dart';

void main() {
  test('stream events expose one typed payload with a positive sequence', () {
    final events = [
      ChatStreamEvent.delta(seq: 1, text: 'Hello'),
      ChatStreamEvent.usage(
        seq: 2,
        usage: const ChatUsage(inputTokens: 4, outputTokens: 1),
      ),
      ChatStreamEvent.finish(seq: 3, finishReason: ChatFinishReason.completed),
      ChatStreamEvent.error(
        seq: 4,
        code: ModelRuntimeErrorCode.streamInterrupted,
        safeMessage: '模型流已中断',
        retryable: true,
      ),
    ];

    expect(events.map((event) => event.type), ChatStreamEventType.values);
    expect(events[0].text, 'Hello');
    expect(events[1].usage, const ChatUsage(inputTokens: 4, outputTokens: 1));
    expect(events[2].finishReason, ChatFinishReason.completed);
    expect(events[3].errorCode, ModelRuntimeErrorCode.streamInterrupted);
    expect(
      () => ChatStreamEvent.delta(seq: 0, text: 'invalid'),
      throwsArgumentError,
    );
  });

  test(
    'cancellation token changes state once and completes immediately',
    () async {
      final token = CancellationToken();
      var notifications = 0;
      token.whenCancelled.then((_) => notifications++);

      expect(token.isCancelled, isFalse);
      token.cancel();
      token.cancel();
      await token.whenCancelled;

      expect(token.isCancelled, isTrue);
      expect(notifications, 1);
    },
  );

  test('structured error frame string never exposes its body', () {
    final frame = StructuredSseFrame.error(
      statusCode: 401,
      unsafeBody: 'Authorization Bearer sk-stream-secret',
    );

    expect(frame.kind, StructuredSseFrameKind.error);
    expect(frame.toString(), isNot(contains('sk-stream-secret')));
    expect(frame.toString(), isNot(contains('Authorization')));
  });
}
