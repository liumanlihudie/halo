import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/single_chat/chat_message_repository.dart';
import 'package:halo_mobile/features/single_chat/single_chat_controller.dart';

/// Restart recovery for commands that died without any terminal state.
///
/// Field evidence (2026-07-30, simulator container): outbox records stuck in
/// `pending` forever with a persisted `:user` message, no `:answer`, no
/// failure surface — the message silently dies. A pending command with no
/// persisted answer and no live dispatch claim must resurface as a retryable
/// failure after restart instead of vanishing.
void main() {
  SingleChatController restartedController({
    required InMemorySingleChatCommandOutbox outbox,
    required InMemoryChatMessageRepository repository,
    required _FakeService service,
  }) => SingleChatController(
    conversationId: 'general-assistant',
    expertId: 'general-assistant',
    service: service,
    repository: repository,
    commandIdFactory: () => 'unused-new-command',
  );

  Future<SingleChatCommandRecord> seedAnswerlessPending({
    required InMemorySingleChatCommandOutbox outbox,
    required InMemoryChatMessageRepository repository,
    required String commandId,
    required String text,
  }) async {
    final record = outbox.reserve(
      conversationId: 'general-assistant',
      normalizedIntent: text,
      createCommandId: () => commandId,
    );
    await repository.append(
      'general-assistant',
      ChatMessageProjection(
        id: '$commandId:user',
        kind: ChatMessageKind.userText,
        text: text,
      ),
    );
    return record;
  }

  test(
    'answerless pending command resurfaces as retryable after restart',
    () async {
      final outbox = InMemorySingleChatCommandOutbox();
      final repository = InMemoryChatMessageRepository(commandOutbox: outbox);
      await seedAnswerlessPending(
        outbox: outbox,
        repository: repository,
        commandId: 'stuck-command',
        text: '内容未通过审查是什么意思',
      );
      final service = _FakeService();
      final controller = restartedController(
        outbox: outbox,
        repository: repository,
        service: service,
      );
      addTearDown(controller.dispose);

      await controller.initialize();

      expect(controller.state.status, SingleChatRunStatus.failed);
      expect(controller.state.canRetry, isTrue);
      expect(controller.state.historyLoadFailed, isFalse);

      final retry = controller.retry();
      await Future<void>.delayed(Duration.zero);
      expect(service.requests, hasLength(1));
      service.completeNext(
        const SingleAgentRunOutcome.failed(
          failure: SingleAgentRunFailure.retryable,
        ),
      );
      await retry;

      // The retry reuses the stuck command and never duplicates the user bubble.
      final userMessages = controller.state.messages.where(
        (message) => message.kind == ChatMessageKind.userText,
      );
      expect(userMessages, hasLength(1));
      expect(
        outbox.read('general-assistant', 'stuck-command')?.status,
        SingleChatCommandStatus.pending,
      );
    },
  );

  test(
    'only the newest answerless pending is armed; older ones stop',
    () async {
      final outbox = InMemorySingleChatCommandOutbox();
      final repository = InMemoryChatMessageRepository(commandOutbox: outbox);
      await seedAnswerlessPending(
        outbox: outbox,
        repository: repository,
        commandId: 'stuck-older',
        text: '第一条被吞的消息',
      );
      await seedAnswerlessPending(
        outbox: outbox,
        repository: repository,
        commandId: 'stuck-newer',
        text: '第二条被吞的消息',
      );
      final service = _FakeService();
      final controller = restartedController(
        outbox: outbox,
        repository: repository,
        service: service,
      );
      addTearDown(controller.dispose);

      await controller.initialize();

      expect(
        outbox.read('general-assistant', 'stuck-older')?.status,
        SingleChatCommandStatus.stopped,
      );
      expect(
        outbox.read('general-assistant', 'stuck-newer')?.status,
        SingleChatCommandStatus.pending,
      );
      expect(controller.state.status, SingleChatRunStatus.failed);
      expect(controller.state.canRetry, isTrue);

      final retry = controller.retry();
      await Future<void>.delayed(Duration.zero);
      expect(service.requests.single.clientCommandId, 'stuck-newer');
      service.completeNext(
        const SingleAgentRunOutcome.failed(
          failure: SingleAgentRunFailure.retryable,
        ),
      );
      await retry;
    },
  );

  test(
    'a pending command with a live dispatch claim is left running',
    () async {
      final outbox = InMemorySingleChatCommandOutbox();
      final repository = InMemoryChatMessageRepository(commandOutbox: outbox);
      await seedAnswerlessPending(
        outbox: outbox,
        repository: repository,
        commandId: 'claimed-command',
        text: '仍在租约内的运行',
      );
      final claim = outbox.claimForDispatch(
        conversationId: 'general-assistant',
        commandId: 'claimed-command',
        ownerId: 'other-process',
        nowEpochMs: DateTime.now().millisecondsSinceEpoch,
        leaseExpiresAtEpochMs:
            DateTime.now().millisecondsSinceEpoch + 60 * 60 * 1000,
      );
      expect(claim, isNotNull);
      final service = _FakeService();
      final controller = restartedController(
        outbox: outbox,
        repository: repository,
        service: service,
      );
      addTearDown(controller.dispose);

      await controller.initialize();

      // Not ours to touch: the lease holder is still responsible for it.
      expect(controller.state.status, isNot(SingleChatRunStatus.failed));
      expect(controller.state.canRetry, isFalse);
      expect(
        outbox.read('general-assistant', 'claimed-command')?.status,
        SingleChatCommandStatus.pending,
      );
    },
  );
}

class _FakeService implements ConversationApplicationService {
  final requests = <StartSingleAgentRunRequest>[];
  final _outcomes = <Completer<SingleAgentRunOutcome>>[];

  @override
  Future<SingleAgentRunHandle> startSingleAgentRun(
    StartSingleAgentRunRequest request,
  ) async {
    requests.add(request);
    final outcome = Completer<SingleAgentRunOutcome>();
    _outcomes.add(outcome);
    return SingleAgentRunHandle(
      runId: 'run-${requests.length}',
      outcome: outcome.future,
    );
  }

  void completeNext(SingleAgentRunOutcome result) {
    _outcomes.firstWhere((outcome) => !outcome.isCompleted).complete(result);
  }

  @override
  Future<void> stopSingleAgentRun(String runId) async {}
}
