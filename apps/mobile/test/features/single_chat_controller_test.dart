import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/single_chat/chat_message_repository.dart';
import 'package:halo_mobile/features/single_chat/drift_chat_message_repository.dart';
import 'package:halo_mobile/features/single_chat/single_chat_controller.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'one submit projects one user message and duplicate submits reuse the command',
    () async {
      final service = _FakeConversationApplicationService();
      final repository = InMemoryChatMessageRepository();
      final controller = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: service,
        repository: repository,
        commandIdFactory: () => 'command-1',
      );
      await controller.initialize();

      final first = controller.submit('分析本周漏斗');
      final duplicate = controller.submit('分析本周漏斗');

      expect(controller.state.status, SingleChatRunStatus.running);
      expect(
        controller.state.messages
            .where((message) => message.kind == ChatMessageKind.userText)
            .map((message) => message.text),
        ['分析本周漏斗'],
      );
      await Future<void>.delayed(Duration.zero);
      expect(service.requests, hasLength(1));
      expect(service.requests.single.clientCommandId, 'command-1');
      expect(service.requests.single.expertId, 'data-analyst');
      expect(service.requests.single.mode, SingleAgentRunMode.mentioned);
      expect(service.requests.single.memberExpertIds, ['data-analyst']);

      service.completeNext(
        const SingleAgentRunOutcome.completed(
          answer: '转化率需要按渠道拆分。',
          sourceType: ChatMessageSourceType.userVisibleSummary,
          uncertainty: '样本仅覆盖最近七天',
          evidenceReferences: ['metric://weekly-funnel'],
        ),
      );
      await Future.wait([first, duplicate]);

      expect(controller.state.status, SingleChatRunStatus.completed);
      expect(controller.state.messages.last.text, '转化率需要按渠道拆分。');
      expect(
        controller.state.messages.last.sourceType,
        ChatMessageSourceType.userVisibleSummary,
      );
      expect(controller.state.messages.last.uncertainty, '样本仅覆盖最近七天');
      expect(controller.state.messages.last.evidenceReferences, isEmpty);
    },
  );

  test('stop cancels the active run and ignores its late completion', () async {
    final service = _FakeConversationApplicationService();
    final repository = InMemoryChatMessageRepository();
    final controller = SingleChatController(
      conversationId: 'conversation-data',
      expertId: 'data-analyst',
      service: service,
      repository: repository,
      commandIdFactory: () => 'command-stop',
    );
    await controller.initialize();

    final submission = controller.submit('停止这个请求');
    await Future<void>.delayed(Duration.zero);
    await controller.stop();

    expect(controller.state.status, SingleChatRunStatus.stopped);
    expect(service.stoppedRunIds, ['run-1']);

    service.completeNext(
      const SingleAgentRunOutcome.completed(answer: '不应展示的迟到回复'),
    );
    await submission;
    expect(
      controller.state.messages.where(
        (message) => message.kind == ChatMessageKind.agentText,
      ),
      isEmpty,
    );
  });

  test(
    'retryable failure retries with the same command and user message',
    () async {
      final service = _FakeConversationApplicationService();
      final controller = SingleChatController(
        conversationId: 'conversation-research',
        expertId: 'industry-researcher',
        service: service,
        repository: InMemoryChatMessageRepository(),
        commandIdFactory: () => 'command-retry',
      );
      await controller.initialize();

      final first = controller.submit('核验来源');
      await Future<void>.delayed(Duration.zero);
      service.completeNext(
        const SingleAgentRunOutcome.failed(
          failure: SingleAgentRunFailure.retryable,
        ),
      );
      await first;

      expect(controller.state.status, SingleChatRunStatus.failed);
      expect(controller.state.canRetry, isTrue);

      final retry = controller.retry();
      await Future<void>.delayed(Duration.zero);
      expect(service.requests, hasLength(2));
      expect(service.requests.map((request) => request.clientCommandId), [
        'command-retry',
        'command-retry',
      ]);
      expect(
        controller.state.messages.where(
          (message) => message.kind == ChatMessageKind.userText,
        ),
        hasLength(1),
      );

      service.completeNext(
        const SingleAgentRunOutcome.completed(answer: '两个来源一致。'),
      );
      await retry;
      expect(controller.state.status, SingleChatRunStatus.completed);
    },
  );

  for (final scenario in <(SingleAgentRunFailure, SingleChatRunStatus)>[
    (SingleAgentRunFailure.quotaLimited, SingleChatRunStatus.quotaLimited),
    (SingleAgentRunFailure.authentication, SingleChatRunStatus.authentication),
    (SingleAgentRunFailure.contentFiltered, SingleChatRunStatus.filtered),
  ]) {
    test('${scenario.$1.name} maps to a safe non-retryable state', () async {
      final service = _FakeConversationApplicationService();
      final controller = SingleChatController(
        conversationId: 'conversation-contract',
        expertId: 'legal-risk-advisor',
        service: service,
        repository: InMemoryChatMessageRepository(),
        commandIdFactory: () => 'command-${scenario.$1.name}',
      );
      await controller.initialize();

      final submission = controller.submit('审阅条款');
      await Future<void>.delayed(Duration.zero);
      service.completeNext(SingleAgentRunOutcome.failed(failure: scenario.$1));
      await submission;

      expect(controller.state.status, scenario.$2);
      expect(controller.state.canRetry, isFalse);
    });
  }

  test(
    'malformedOutput maps to its own retryable state, not filtered',
    () async {
      final service = _FakeConversationApplicationService();
      final controller = SingleChatController(
        conversationId: 'conversation-malformed',
        expertId: 'legal-risk-advisor',
        service: service,
        repository: InMemoryChatMessageRepository(),
        commandIdFactory: () => 'command-malformed',
      );
      await controller.initialize();

      final submission = controller.submit('审阅条款');
      await Future<void>.delayed(Duration.zero);
      service.completeNext(
        const SingleAgentRunOutcome.failed(
          failure: SingleAgentRunFailure.malformedOutput,
        ),
      );
      await submission;

      expect(controller.state.status, SingleChatRunStatus.malformedOutput);
      expect(controller.state.status, isNot(SingleChatRunStatus.filtered));
      expect(controller.state.canRetry, isTrue);
    },
  );

  test(
    'dispose lets the run finish, persists it, and stays silent',
    () async {
      // The regression this pins: a user who left the chat while an image was
      // generating came back to nothing — the answer rolled back and the
      // downloaded asset was orphaned on disk. Closing the page must not
      // cancel the run; only stop() does.
      final service = _FakeConversationApplicationService();
      final repository = InMemoryChatMessageRepository();
      final controller = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: service,
        repository: repository,
        commandIdFactory: () => 'command-dispose',
      );
      await controller.initialize();
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      final submission = controller.submit('等待回复');
      await Future<void>.delayed(Duration.zero);
      controller.dispose();
      await Future<void>.delayed(Duration.zero);

      expect(service.stoppedRunIds, isEmpty);
      final notificationsAtDispose = notifications;
      service.completeNext(
        const SingleAgentRunOutcome.completed(
          answer: '迟到回复',
          toolFailures: ['图片没有生成：测试原因'],
          generatedAssetPaths: ['/tmp/gen-late.png'],
        ),
      );
      await submission;
      expect(notifications, notificationsAtDispose);
      final persisted = await repository.load('conversation-data');
      expect(
        persisted.map((message) => message.text),
        containsAll(['等待回复', '迟到回复', '图片没有生成：测试原因']),
      );
      expect(
        persisted.map((message) => message.imageUrl),
        contains('/tmp/gen-late.png'),
      );
      final command = repository.commandOutbox.read(
        'conversation-data',
        'command-dispose',
      );
      expect(command?.status, SingleChatCommandStatus.completed);
    },
  );

  test('a generation invocation persists the model prompt immediately', () async {
    // Per spec the model's refined prompt is the first visible reply: it
    // lands as its own message the moment the tool is invoked — before any
    // network work — and the placeholder appears beside it.
    final service = _ProgressSingleChatPort();
    final repository = InMemoryChatMessageRepository();
    final controller = SingleChatController(
      conversationId: 'conversation-data',
      expertId: 'data-analyst',
      service: service,
      repository: repository,
      commandIdFactory: () => 'command-genprompt',
    );
    await controller.initialize();
    final submission = controller.submit('生图测试');
    await Future<void>.delayed(Duration.zero);

    service.progress.add(
      const GenerationProgress.invoked(
        id: 'gen-1',
        prompt: '一只戴帽子的橘猫，简笔画',
        isVideo: false,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(
      controller.state.messages.map((message) => message.text),
      contains('一只戴帽子的橘猫，简笔画'),
    );
    expect(controller.activeGenerations, hasLength(1));
    expect(
      (await repository.load(
        'conversation-data',
      )).map((message) => message.text),
      contains('一只戴帽子的橘猫，简笔画'),
    );

    service.complete(const SingleAgentRunOutcome.completed(answer: '画好了'));
    await submission;
    expect(
      controller.state.messages.map((message) => message.text),
      containsAll(['一只戴帽子的橘猫，简笔画', '画好了']),
    );
    controller.dispose();
  });

  test('a reopened page shows a detached run and its committed result', () async {
    // The regression: leaving the chat mid-generation and coming back showed
    // neither the placeholder nor, later, the image — the run was alive but
    // no page knew. The shared board carries both across pages.
    final registry = ActiveGenerationRegistry();
    final service = _ProgressSingleChatPort();
    final repository = InMemoryChatMessageRepository();
    final first = SingleChatController(
      conversationId: 'conversation-data',
      expertId: 'data-analyst',
      service: service,
      repository: repository,
      commandIdFactory: () => 'command-board',
      generationRegistry: registry,
    );
    await first.initialize();
    final submission = first.submit('画一张图');
    await Future<void>.delayed(Duration.zero);
    service.progress.add(
      const GenerationProgress.invoked(
        id: 'gen-board',
        prompt: '一只猫',
        isVideo: false,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    first.dispose();

    final second = SingleChatController(
      conversationId: 'conversation-data',
      expertId: 'data-analyst',
      service: _FakeConversationApplicationService(),
      repository: repository,
      commandIdFactory: () => 'command-board-second',
      generationRegistry: registry,
    );
    await second.initialize();
    expect(second.activeGenerations, hasLength(1));
    expect(second.activeGenerations.single.prompt, '一只猫');

    service.complete(
      const SingleAgentRunOutcome.completed(
        answer: '这是你的图',
        generatedAssetPaths: ['/tmp/gen-board.png'],
      ),
    );
    await submission;
    for (var i = 0; i < 4; i += 1) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(second.activeGenerations, isEmpty);
    expect(
      second.state.messages.map((message) => message.text),
      containsAll(['画一张图', '一只猫', '这是你的图']),
    );
    expect(
      second.state.messages.map((message) => message.imageUrl),
      contains('/tmp/gen-board.png'),
    );
    second.dispose();
  });

  test('dispose does not stop a delayed run handle', () async {
    final service = _DelayedStartSingleChatPort();
    final controller = SingleChatController(
      conversationId: 'conversation-data',
      expertId: 'data-analyst',
      service: service,
      repository: InMemoryChatMessageRepository(),
      commandIdFactory: () => 'command-delayed-dispose',
    );
    await controller.initialize();

    final submission = controller.submit('等待启动');
    await service.started;
    controller.dispose();
    service.releaseStart();
    await Future<void>.delayed(Duration.zero);
    service.complete(
      const SingleAgentRunOutcome.completed(answer: '页面关了也要送达'),
    );
    await submission;

    expect(service.stoppedRunIds, isEmpty);
  });

  test(
    'a disposed run retains dispatch ownership until it finishes',
    () async {
      // A new page opening the same conversation must not double-dispatch the
      // command a closed page's run still owns; the run finishes and marks
      // the command terminal itself.
      final outbox = InMemorySingleChatCommandOutbox();
      final firstService = _FakeConversationApplicationService();
      final firstController = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: firstService,
        repository: InMemoryChatMessageRepository(commandOutbox: outbox),
        commandIdFactory: () => 'command-dispose-fence',
      );
      await firstController.initialize();

      final firstSubmission = firstController.submit('停止确认前不可重启');
      await Future<void>.delayed(Duration.zero);
      firstController.dispose();

      final restartedService = _FakeConversationApplicationService();
      final restartedController = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: restartedService,
        repository: InMemoryChatMessageRepository(commandOutbox: outbox),
        commandIdFactory: () => 'must-reuse-dispose-command',
      );
      await restartedController.initialize();
      final restartedSubmission = restartedController.submit('停止确认前不可重启');
      await Future<void>.delayed(Duration.zero);
      expect(restartedService.requests, isEmpty);

      firstService.completeNext(
        const SingleAgentRunOutcome.completed(answer: '第一轮的答案'),
      );
      await firstSubmission;
      await restartedSubmission;
      expect(
        outbox.read('conversation-data', 'command-dispose-fence')?.status,
        SingleChatCommandStatus.completed,
      );
      restartedController.dispose();
    },
  );

  test(
    'stop returns before a delayed handle and cancels it when it arrives',
    () async {
      final service = _DelayedStartSingleChatPort();
      final controller = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: service,
        repository: InMemoryChatMessageRepository(),
        commandIdFactory: () => 'command-delayed-stop',
      );
      await controller.initialize();

      final submission = controller.submit('等待迟到句柄');
      await service.started;
      await controller.stop().timeout(const Duration(milliseconds: 200));
      expect(service.stoppedRunIds, isEmpty);

      service.releaseStart();
      await submission;
      await Future<void>.delayed(Duration.zero);

      expect(service.stoppedRunIds, ['run-delayed']);
      expect(controller.state.status, SingleChatRunStatus.stopped);
    },
  );

  test('stop during answer persistence cannot resurrect the run', () async {
    final service = _FakeConversationApplicationService();
    final repository = _DelayedAnswerRepository();
    final controller = SingleChatController(
      conversationId: 'conversation-data',
      expertId: 'data-analyst',
      service: service,
      repository: repository,
      commandIdFactory: () => 'command-answer-race',
    );
    await controller.initialize();

    final submission = controller.submit('分析数据');
    await Future<void>.delayed(Duration.zero);
    service.completeNext(
      const SingleAgentRunOutcome.completed(answer: '迟到的分析'),
    );
    await repository.answerAppendStarted;

    await controller.stop();
    repository.releaseAnswerAppend();
    await submission;

    expect(controller.state.status, SingleChatRunStatus.stopped);
    expect(
      controller.state.messages.where(
        (message) => message.kind == ChatMessageKind.agentText,
      ),
      isEmpty,
    );
    expect(
      (await repository.load(
        'conversation-data',
      )).where((message) => message.kind == ChatMessageKind.agentText),
      isEmpty,
    );
  });

  test(
    'stop after commit but before append return rolls back stale answer',
    () async {
      final service = _FakeConversationApplicationService();
      final repository = _CommittedButDelayedReturnRepository();
      final controller = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: service,
        repository: repository,
        commandIdFactory: () => 'command-commit-return-race',
      );
      await controller.initialize();

      final submission = controller.submit('分析提交窗口');
      await Future<void>.delayed(Duration.zero);
      service.completeNext(
        const SingleAgentRunOutcome.completed(answer: '必须回滚的迟到答案'),
      );
      await repository.answerCommitted;

      await controller.stop();
      repository.releaseAppendReturn();
      await submission;

      expect(controller.state.status, SingleChatRunStatus.stopped);
      expect(
        (await repository.load(
          'conversation-data',
        )).where((message) => message.kind == ChatMessageKind.agentText),
        isEmpty,
      );
    },
  );

  test(
    'history reconciliation cannot steal a live answer commit claim',
    () async {
      final outbox = InMemorySingleChatCommandOutbox();
      final repository = _CommittedButDelayedReturnRepository(
        commandOutbox: outbox,
      );
      final firstService = _FakeConversationApplicationService();
      final firstController = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: firstService,
        repository: repository,
        commandIdFactory: () => 'command-live-reconciliation-fence',
      );
      await firstController.initialize();

      final submission = firstController.submit('并发提交窗口');
      await Future<void>.delayed(Duration.zero);
      firstService.completeNext(
        const SingleAgentRunOutcome.completed(answer: '只能保留一次的答案'),
      );
      await repository.answerCommitted;

      final observer = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: _FakeConversationApplicationService(),
        repository: repository,
        commandIdFactory: () => 'unused-observer-command',
      );
      await observer.initialize();
      expect(
        outbox
            .read('conversation-data', 'command-live-reconciliation-fence')
            ?.status,
        SingleChatCommandStatus.pending,
      );

      repository.releaseAppendReturn();
      await submission;

      expect(firstController.state.status, SingleChatRunStatus.completed);
      expect(
        (await repository.load('conversation-data')).where(
          (message) => message.id == 'command-live-reconciliation-fence:answer',
        ),
        hasLength(1),
      );
      expect(
        outbox
            .read('conversation-data', 'command-live-reconciliation-fence')
            ?.status,
        SingleChatCommandStatus.completed,
      );
      observer.dispose();
    },
  );

  test('stop releases a stuck outcome so a new submit can start', () async {
    final service = _FakeConversationApplicationService();
    var command = 0;
    final controller = SingleChatController(
      conversationId: 'conversation-data',
      expertId: 'data-analyst',
      service: service,
      repository: InMemoryChatMessageRepository(),
      commandIdFactory: () => 'command-${++command}',
    );
    await controller.initialize();

    controller.submit('第一个请求');
    await Future<void>.delayed(Duration.zero);
    await controller.stop();
    controller.submit('第二个请求');
    await Future<void>.delayed(Duration.zero);

    expect(service.requests, hasLength(2));
    expect(service.requests.last.text, '第二个请求');
  });

  test('repository load failure becomes a bounded retryable state', () async {
    final controller = SingleChatController(
      conversationId: 'conversation-data',
      expertId: 'data-analyst',
      service: _FakeConversationApplicationService(),
      repository: _ThrowingChatMessageRepository(throwOnLoad: true),
      commandIdFactory: () => 'command-load-error',
    );

    await controller.initialize();

    expect(controller.state.status, SingleChatRunStatus.idle);
    expect(controller.state.canRetry, isFalse);
    expect(controller.state.historyLoadFailed, isTrue);
    await controller.retry();
  });

  test('user projection failure does not dispatch or escape', () async {
    final service = _FakeConversationApplicationService();
    final controller = SingleChatController(
      conversationId: 'conversation-data',
      expertId: 'data-analyst',
      service: service,
      repository: _ThrowingChatMessageRepository(throwOnAppend: true),
      commandIdFactory: () => 'command-write-error',
    );
    await controller.initialize();

    await controller.submit('不会被调度');

    expect(controller.state.status, SingleChatRunStatus.failed);
    expect(service.requests, isEmpty);
  });

  test('non-throwing answer commit refusal becomes bounded failure', () async {
    final service = _FakeConversationApplicationService();
    final controller = SingleChatController(
      conversationId: 'conversation-data',
      expertId: 'data-analyst',
      service: service,
      repository: _RefusingAnswerRepository(),
      commandIdFactory: () => 'command-refused-answer',
    );
    await controller.initialize();

    final submission = controller.submit('拒绝提交答案');
    await Future<void>.delayed(Duration.zero);
    service.completeNext(
      const SingleAgentRunOutcome.completed(answer: '不会卡在运行中'),
    );
    await submission;

    expect(controller.state.status, SingleChatRunStatus.failed);
    expect(controller.state.canRetry, isTrue);
    expect(
      controller.state.messages.where(
        (message) => message.kind == ChatMessageKind.agentText,
      ),
      isEmpty,
    );
  });

  test('retry persists the same user projection before dispatch', () async {
    final service = _FakeConversationApplicationService();
    final repository = _ThrowingChatMessageRepository(failedAppends: 1);
    final controller = SingleChatController(
      conversationId: 'conversation-data',
      expertId: 'data-analyst',
      service: service,
      repository: repository,
      commandIdFactory: () => 'command-persist-retry',
    );
    await controller.initialize();
    await controller.submit('先持久化我');

    final retry = controller.retry();
    await Future<void>.delayed(Duration.zero);

    expect(service.requests, hasLength(1));
    expect(
      (await repository.load('conversation-data'))
          .where((message) => message.kind == ChatMessageKind.userText)
          .map((message) => message.id),
      ['command-persist-retry:user'],
    );
    service.completeNext(
      const SingleAgentRunOutcome.completed(answer: '已安全完成'),
    );
    await retry;
  });

  test(
    'delayed history load cannot overwrite a concurrent user message',
    () async {
      final service = _FakeConversationApplicationService();
      final repository = _DelayedLoadRepository();
      final controller = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: service,
        repository: repository,
        commandIdFactory: () => 'command-load-race',
      );

      final initializing = controller.initialize();
      controller.submit('加载期间发送');
      await Future<void>.delayed(Duration.zero);
      repository.releaseLoad();
      await initializing;

      expect(
        controller.state.messages
            .where((message) => message.kind == ChatMessageKind.userText)
            .map((message) => message.text),
        ['加载期间发送'],
      );
    },
  );

  test('delayed history failure cannot overwrite a completed run', () async {
    final service = _FakeConversationApplicationService();
    final repository = _DelayedFailingLoadRepository();
    final controller = SingleChatController(
      conversationId: 'conversation-data',
      expertId: 'data-analyst',
      service: service,
      repository: repository,
      commandIdFactory: () => 'command-history-failure-race',
    );

    final initializing = controller.initialize();
    final submission = controller.submit('加载失败期间发送');
    await Future<void>.delayed(Duration.zero);
    service.completeNext(const SingleAgentRunOutcome.completed(answer: '正常完成'));
    await submission;
    expect(controller.state.status, SingleChatRunStatus.completed);

    repository.failLoad();
    await initializing;

    expect(controller.state.status, SingleChatRunStatus.completed);
    expect(controller.state.messages.last.text, '正常完成');
  });

  test('stop transport failure stays stopped and does not escape', () async {
    final service = _FakeConversationApplicationService(throwOnStop: true);
    final controller = SingleChatController(
      conversationId: 'conversation-data',
      expertId: 'data-analyst',
      service: service,
      repository: InMemoryChatMessageRepository(),
      commandIdFactory: () => 'command-stop-error',
    );
    await controller.initialize();
    controller.submit('停止失败');
    await Future<void>.delayed(Duration.zero);

    await controller.stop();

    expect(controller.state.status, SingleChatRunStatus.stopped);
  });

  test('stop absorbs a delayed start failure', () async {
    final service = _FailingDelayedStartPort();
    final controller = SingleChatController(
      conversationId: 'conversation-data',
      expertId: 'data-analyst',
      service: service,
      repository: InMemoryChatMessageRepository(),
      commandIdFactory: () => 'command-start-error',
    );
    await controller.initialize();
    controller.submit('启动失败');
    await service.started;

    final stopping = controller.stop();
    service.failStart();
    await stopping;

    expect(controller.state.status, SingleChatRunStatus.stopped);
  });

  test('a restarted controller reuses the persisted pending command', () async {
    final directory = Directory.systemTemp.createTempSync(
      'single-chat-outbox-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final outboxPath = '${directory.path}/commands.json';
    final firstOutbox = FileSingleChatCommandOutbox(outboxPath);
    final firstRepository = InMemoryChatMessageRepository(
      commandOutbox: firstOutbox,
    );
    final firstService = _FakeConversationApplicationService();
    final firstController = SingleChatController(
      conversationId: 'conversation-data',
      expertId: 'data-analyst',
      service: firstService,
      repository: firstRepository,
      commandIdFactory: () => '01JFIRSTCOMMAND00000000000',
    );
    await firstController.initialize();
    firstController.submit('恢复同一用户意图');
    await Future<void>.delayed(Duration.zero);
    final originalCommandId = firstService.requests.single.clientCommandId;
    firstController.dispose();

    final restartedOutbox = FileSingleChatCommandOutbox(outboxPath);
    final restartedService = _FakeConversationApplicationService();
    // A restart takes over only once the dead process's dispatch lease has
    // expired — dispose deliberately no longer releases it, because the run
    // it guards may still be delivering. The restarted clock sits past the
    // lease to model that expiry.
    final restartedController = SingleChatController(
      conversationId: 'conversation-data',
      expertId: 'data-analyst',
      service: restartedService,
      repository: InMemoryChatMessageRepository(commandOutbox: restartedOutbox),
      commandIdFactory: () => '01JSECONDCOMMAND0000000000',
      nowEpochMs: () =>
          DateTime.now().millisecondsSinceEpoch +
          const Duration(minutes: 10).inMilliseconds,
    );
    await restartedController.initialize();
    restartedController.submit('恢复同一用户意图');
    await Future<void>.delayed(Duration.zero);

    expect(restartedService.requests.single.clientCommandId, originalCommandId);
  });

  test(
    'restart reconciles a persisted answer before redispatching pending command',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'single-chat-completion-reconcile-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/commands.json';
      const trustedNowEpochMs = 1500;
      final outbox = FileSingleChatCommandOutbox(
        path,
        nowEpochMs: () => trustedNowEpochMs,
      );
      final command = outbox.reserve(
        conversationId: 'conversation-data',
        normalizedIntent: '崩溃窗口恢复',
        createCommandId: () => '01JRECONCILECOMMAND00000000',
      );
      final dispatchClaim = outbox.claimForDispatch(
        conversationId: 'conversation-data',
        commandId: command.commandId,
        ownerId: 'crashed-controller',
        nowEpochMs: 1000,
        leaseExpiresAtEpochMs: 2000,
      )!;
      final repository = InMemoryChatMessageRepository(
        commandOutbox: outbox,
        seed: {
          'conversation-data': [
            ChatMessageProjection(
              id: '${command.commandId}:answer',
              kind: ChatMessageKind.agentText,
              text: '已持久化的唯一答案',
              sourceType: ChatMessageSourceType.modelOutput,
              uncertainty: '恢复自提交窗口',
              dispatchClaimOwner: dispatchClaim.ownerId,
              dispatchClaimGeneration: dispatchClaim.generation,
            ),
          ],
        },
      );
      final service = _FakeConversationApplicationService();
      final restarted = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: service,
        repository: repository,
        commandIdFactory: () => 'unused-command',
      );

      await restarted.initialize();

      expect(service.requests, isEmpty);
      expect(
        FileSingleChatCommandOutbox(
          path,
        ).read('conversation-data', command.commandId)?.status,
        SingleChatCommandStatus.completed,
      );
      expect(
        restarted.state.messages.where(
          (message) => message.id == '${command.commandId}:answer',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'expired claimed answer recovers only with matching provenance on one clock',
    () async {
      var nowEpochMs = 1000;
      final outbox = InMemorySingleChatCommandOutbox(
        nowEpochMs: () => nowEpochMs,
      );
      final command = outbox.reserve(
        conversationId: 'conversation-data',
        normalizedIntent: '崩溃窗口恢复',
        createCommandId: () => 'command-expired-recovery',
      );
      final claim = outbox.claimForDispatch(
        conversationId: 'conversation-data',
        commandId: command.commandId,
        ownerId: 'crashed-controller',
        nowEpochMs: 1000,
        leaseExpiresAtEpochMs: 2000,
      )!;
      final repository = InMemoryChatMessageRepository(
        commandOutbox: outbox,
        seed: {
          'conversation-data': [
            ChatMessageProjection(
              id: '${command.commandId}:answer',
              kind: ChatMessageKind.agentText,
              text: '崩溃前已持久化的答案',
              dispatchClaimOwner: claim.ownerId,
              dispatchClaimGeneration: claim.generation,
            ),
          ],
        },
      );
      nowEpochMs = 2000;
      final controller = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: _FakeConversationApplicationService(),
        repository: repository,
        commandIdFactory: () => 'unused-command',
        nowEpochMs: () => nowEpochMs,
      );

      await controller.initialize();

      expect(
        outbox.read('conversation-data', command.commandId)?.status,
        SingleChatCommandStatus.completed,
      );
      expect(controller.state.historyLoadFailed, isFalse);
      expect(
        controller.state.messages.single.id,
        '${command.commandId}:answer',
      );
    },
  );

  test(
    'reconciliation removes a stale answer before a reclaimed live claim runs',
    () async {
      var nowEpochMs = 1000;
      final outbox = InMemorySingleChatCommandOutbox(
        nowEpochMs: () => nowEpochMs,
      );
      final command = outbox.reserve(
        conversationId: 'conversation-data',
        normalizedIntent: 'reclaimed claim',
        createCommandId: () => 'command-reclaimed-recovery',
      );
      final originalClaim = outbox.claimForDispatch(
        conversationId: 'conversation-data',
        commandId: command.commandId,
        ownerId: 'crashed-controller',
        nowEpochMs: 1000,
        leaseExpiresAtEpochMs: 2000,
      )!;
      final repository = InMemoryChatMessageRepository(
        commandOutbox: outbox,
        seed: {
          'conversation-data': [
            ChatMessageProjection(
              id: '${command.commandId}:answer',
              kind: ChatMessageKind.agentText,
              text: '旧 claim 的答案',
              dispatchClaimOwner: originalClaim.ownerId,
              dispatchClaimGeneration: originalClaim.generation,
            ),
          ],
        },
      );
      nowEpochMs = 2000;
      outbox.claimForDispatch(
        conversationId: 'conversation-data',
        commandId: command.commandId,
        ownerId: 'new-controller',
        nowEpochMs: 2000,
        leaseExpiresAtEpochMs: 3000,
      );
      final controller = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: _FakeConversationApplicationService(),
        repository: repository,
        commandIdFactory: () => 'unused-command',
        nowEpochMs: () => nowEpochMs,
      );

      await controller.initialize();

      expect(
        outbox.read('conversation-data', command.commandId)?.status,
        SingleChatCommandStatus.pending,
      );
      expect(controller.state.historyLoadFailed, isTrue);
      expect(controller.state.messages, isEmpty);
      final newCommit = await repository.appendIf(
        'conversation-data',
        const ChatMessageProjection(
          id: 'command-reclaimed-recovery:answer',
          kind: ChatMessageKind.agentText,
          text: '新 owner 的答案',
          dispatchClaimOwner: 'new-controller',
          dispatchClaimGeneration: 2,
        ),
        ChatMessageCommitToken('new-owner-commit', generation: 2),
        () => true,
      );
      expect(newCommit.committed, isTrue);
      expect(newCommit.inserted, isTrue);
      expect(
        (await repository.load('conversation-data')).single.text,
        '新 owner 的答案',
      );
    },
  );

  test(
    'initialize quarantines a pending answer without dispatch provenance',
    () async {
      final outbox = InMemorySingleChatCommandOutbox();
      final command = outbox.reserve(
        conversationId: 'conversation-data',
        normalizedIntent: '伪造恢复答案',
        createCommandId: () => 'command-ownerless-answer',
      );
      final repository = InMemoryChatMessageRepository(
        commandOutbox: outbox,
        seed: {
          'conversation-data': [
            ChatMessageProjection(
              id: '${command.commandId}:answer',
              kind: ChatMessageKind.agentText,
              text: '没有 dispatch provenance 的答案',
            ),
          ],
        },
      );
      final controller = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: _FakeConversationApplicationService(),
        repository: repository,
        commandIdFactory: () => 'unused-ownerless-answer',
      );

      await controller.initialize();

      expect(
        outbox.read('conversation-data', command.commandId)?.status,
        SingleChatCommandStatus.pending,
      );
      expect(controller.state.historyLoadFailed, isTrue);
      expect(
        controller.state.messages.where(
          (message) => message.id == '${command.commandId}:answer',
        ),
        isEmpty,
      );
    },
  );

  test('reconciliation cannot complete a command without a claim', () {
    final outbox = InMemorySingleChatCommandOutbox();
    final command = outbox.reserve(
      conversationId: 'conversation-data',
      normalizedIntent: '无 claim 恢复',
      createCommandId: () => 'command-claimless-reconciliation',
    );

    expect(
      () => outbox.markTerminal(
        'conversation-data',
        command.commandId,
        SingleChatCommandStatus.completed,
        reconcilePersistedAnswer: true,
      ),
      throwsStateError,
    );
    expect(
      outbox.read('conversation-data', command.commandId)?.status,
      SingleChatCommandStatus.pending,
    );
  });

  test(
    'fixture repository is empty and in-memory unless explicitly seeded',
    () async {
      final repository = FixtureChatMessageRepository();

      expect(repository.commandOutbox, isA<InMemorySingleChatCommandOutbox>());
      expect(await repository.load('general-assistant'), isEmpty);
    },
  );

  test(
    'file outbox fails closed when canonical is corrupt without commit marker',
    () {
      final directory = Directory.systemTemp.createTempSync(
        'single-chat-outbox-recovery-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/commands.json';
      final first = FileSingleChatCommandOutbox(path);
      final original = first.reserve(
        conversationId: 'conversation-data',
        normalizedIntent: '恢复崩溃写入',
        createCommandId: () => '01JRECOVEREDCOMMAND00000000',
      );
      File(path).copySync('$path.tmp');
      File(path).writeAsStringSync('{truncated');

      expect(
        () => FileSingleChatCommandOutbox(path),
        throwsA(isA<FormatException>()),
      );
      expect(original.commandId, '01JRECOVEREDCOMMAND00000000');
    },
  );

  test('file outbox ignores uncommitted temp beside valid canonical state', () {
    final directory = Directory.systemTemp.createTempSync(
      'single-chat-outbox-crash-window-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/commands.json';
    final stagingPath = '${directory.path}/staging.json';
    FileSingleChatCommandOutbox(path).reserve(
      conversationId: 'conversation-data',
      normalizedIntent: '旧意图',
      createCommandId: () => '01JOLDCOMMAND000000000000',
    );
    final staging = FileSingleChatCommandOutbox(stagingPath);
    staging.reserve(
      conversationId: 'conversation-data',
      normalizedIntent: '旧意图',
      createCommandId: () => '01JOLDCOMMAND000000000000',
    );
    final pending = staging.reserve(
      conversationId: 'conversation-data',
      normalizedIntent: '崩溃窗口新意图',
      createCommandId: () => '01JNEWPENDING000000000000',
    );
    File(stagingPath).copySync('$path.tmp');

    final recovered = FileSingleChatCommandOutbox(path).reserve(
      conversationId: 'conversation-data',
      normalizedIntent: '崩溃窗口新意图',
      createCommandId: () => '01JSHOULDNOTBEUSED0000000',
    );

    expect(recovered.commandId, isNot(pending.commandId));
  });

  test(
    'ULID command ids stay unique and monotonic when the clock regresses',
    () {
      final timestamps = <int>[2000, 1900, 1900];
      var index = 0;
      final generator = MonotonicUlidGenerator(
        nowMilliseconds: () => timestamps[index++],
        randomBytes: (length) => List<int>.filled(length, 0),
      );

      final ids = [generator.next(), generator.next(), generator.next()];

      expect(ids.toSet(), hasLength(3));
      expect([...ids]..sort(), ids);
      for (final id in ids) {
        expect(id, matches(RegExp(r'^[0-9A-HJKMNP-TV-Z]{26}$')));
      }
    },
  );

  test(
    'self-reported verified evidence is downgraded without a trusted receipt',
    () async {
      final service = _FakeConversationApplicationService();
      final controller = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: service,
        repository: InMemoryChatMessageRepository(),
        commandIdFactory: () => 'command-forged-verification',
      );
      await controller.initialize();

      final submission = controller.submit('给出结论');
      await Future<void>.delayed(Duration.zero);
      service.completeNext(
        const SingleAgentRunOutcome.completed(
          answer: '伪造的已核验结论',
          sourceType: ChatMessageSourceType.verifiedEvidence,
          evidenceReferences: [' HTTPS://EXAMPLE.COM/report#claim '],
        ),
      );
      await submission;

      expect(
        controller.state.messages.last.sourceType,
        ChatMessageSourceType.modelOutput,
      );
    },
  );

  test(
    'trusted verifier receipt enables verified canonical evidence',
    () async {
      final service = _FakeConversationApplicationService();
      final verifier = InMemoryTrustedVerifierReceiptRegistry(
        randomBytes: (length) => List<int>.generate(length, (index) => index),
      );
      final repository = InMemoryChatMessageRepository();
      final controller = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: service,
        repository: repository,
        commandIdFactory: () => 'command-trusted-verification',
        verifier: verifier,
      );
      await controller.initialize();

      final submission = controller.submit('核验结论');
      await Future<void>.delayed(Duration.zero);
      final token = verifier.issue(
        const SingleChatVerificationClaim(
          conversationId: 'conversation-data',
          expertId: 'data-analyst',
          runId: 'run-1',
          commandId: 'command-trusted-verification',
          answer: '合法核验结论',
          canonicalEvidenceReferences: ['https://example.com/report'],
          uncertainty: '样本存在地区限制',
        ),
        validFor: const Duration(minutes: 5),
      );
      service.completeNext(
        SingleAgentRunOutcome.completed(
          answer: '合法核验结论',
          sourceType: ChatMessageSourceType.modelOutput,
          uncertainty: '样本存在地区限制',
          evidenceReferences: [
            ' HTTPS://EXAMPLE.COM/report ',
            'https://example.com/report',
          ],
          verifierToken: token,
        ),
      );
      await submission;

      final answer = controller.state.messages.last;
      expect(answer.sourceType, ChatMessageSourceType.verifiedEvidence);
      expect(answer.evidenceReferences, ['https://example.com/report']);
      expect(answer.uncertainty, '样本存在地区限制');

      final restarted = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: _FakeConversationApplicationService(),
        repository: repository,
        commandIdFactory: () => 'unused-command',
        verifier: verifier,
      );
      await restarted.initialize();
      expect(
        restarted.state.messages.last.sourceType,
        ChatMessageSourceType.verifiedEvidence,
      );
    },
  );

  test('verifier receipt is one-shot, expires, and binds uncertainty', () {
    var now = DateTime.utc(2026, 7, 29, 10);
    final verifier = InMemoryTrustedVerifierReceiptRegistry(
      now: () => now,
      randomBytes: (length) => List<int>.filled(length, 7),
    );
    const claim = SingleChatVerificationClaim(
      conversationId: 'conversation-data',
      expertId: 'data-analyst',
      runId: 'run-1',
      commandId: 'command-verifier-binding',
      answer: '绑定结论',
      canonicalEvidenceReferences: ['https://example.com/report'],
      uncertainty: '样本有限',
    );
    final replayToken = verifier.issue(
      claim,
      validFor: const Duration(minutes: 1),
    );

    expect(
      verifier.verifyAndConsume(
        const SingleChatVerificationClaim(
          conversationId: 'conversation-data',
          expertId: 'data-analyst',
          runId: 'run-1',
          commandId: 'command-verifier-binding',
          answer: '绑定结论',
          canonicalEvidenceReferences: ['https://example.com/report'],
          uncertainty: ' 样本有限 ',
        ),
        replayToken,
      ),
      isNull,
    );
    final consumedReceipt = verifier.verifyAndConsume(claim, replayToken);
    expect(consumedReceipt, isNotNull);
    final consumedReceiptId = consumedReceipt!;
    expect(verifier.validateConsumed(claim, consumedReceiptId), isTrue);
    expect(verifier.verifyAndConsume(claim, replayToken), isNull);

    final expiredToken = verifier.issue(
      claim,
      validFor: const Duration(minutes: 1),
    );
    now = now.add(const Duration(minutes: 1));
    expect(verifier.verifyAndConsume(claim, expiredToken), isNull);
    expect(verifier.validateConsumed(claim, consumedReceiptId), isFalse);
  });

  test('verifier receipt binds every controller and answer claim field', () {
    const original = SingleChatVerificationClaim(
      conversationId: 'conversation-data',
      expertId: 'data-analyst',
      runId: 'run-1',
      commandId: 'command-binding',
      answer: '完整绑定结论',
      canonicalEvidenceReferences: ['https://example.com/report'],
      uncertainty: '样本有限',
    );
    final mutations = <SingleChatVerificationClaim>[
      const SingleChatVerificationClaim(
        conversationId: 'other-conversation',
        expertId: 'data-analyst',
        runId: 'run-1',
        commandId: 'command-binding',
        answer: '完整绑定结论',
        canonicalEvidenceReferences: ['https://example.com/report'],
        uncertainty: '样本有限',
      ),
      const SingleChatVerificationClaim(
        conversationId: 'conversation-data',
        expertId: 'other-expert',
        runId: 'run-1',
        commandId: 'command-binding',
        answer: '完整绑定结论',
        canonicalEvidenceReferences: ['https://example.com/report'],
        uncertainty: '样本有限',
      ),
      const SingleChatVerificationClaim(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        runId: 'run-2',
        commandId: 'command-binding',
        answer: '完整绑定结论',
        canonicalEvidenceReferences: ['https://example.com/report'],
        uncertainty: '样本有限',
      ),
      const SingleChatVerificationClaim(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        runId: 'run-1',
        commandId: 'other-command',
        answer: '完整绑定结论',
        canonicalEvidenceReferences: ['https://example.com/report'],
        uncertainty: '样本有限',
      ),
      const SingleChatVerificationClaim(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        runId: 'run-1',
        commandId: 'command-binding',
        answer: '被替换的结论',
        canonicalEvidenceReferences: ['https://example.com/report'],
        uncertainty: '样本有限',
      ),
      const SingleChatVerificationClaim(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        runId: 'run-1',
        commandId: 'command-binding',
        answer: '完整绑定结论',
        canonicalEvidenceReferences: ['https://example.com/other'],
        uncertainty: '样本有限',
      ),
      const SingleChatVerificationClaim(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        runId: 'run-1',
        commandId: 'command-binding',
        answer: '完整绑定结论',
        canonicalEvidenceReferences: ['https://example.com/report'],
        uncertainty: '样本已被替换',
      ),
    ];

    for (var index = 0; index < mutations.length; index += 1) {
      final verifier = InMemoryTrustedVerifierReceiptRegistry(
        randomBytes: (length) => List<int>.filled(length, index + 1),
      );
      final token = verifier.issue(
        original,
        validFor: const Duration(minutes: 5),
      );
      expect(
        verifier.verifyAndConsume(mutations[index], token),
        isNull,
        reason: 'mutation $index',
      );
      expect(
        verifier.verifyAndConsume(original, token),
        isNotNull,
        reason: 'mismatch must not consume token $index',
      );
    }
  });

  test(
    'controller replay of a consumed verifier token is downgraded',
    () async {
      final verifier = InMemoryTrustedVerifierReceiptRegistry(
        randomBytes: (length) => List<int>.filled(length, 9),
      );
      const claim = SingleChatVerificationClaim(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        runId: 'run-1',
        commandId: 'command-replay',
        answer: '一次性核验',
        canonicalEvidenceReferences: ['https://example.com/report'],
        uncertainty: '样本有限',
      );
      final token = verifier.issue(claim, validFor: const Duration(minutes: 5));
      final firstService = _FakeConversationApplicationService();
      final secondService = _FakeConversationApplicationService();
      final first = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: firstService,
        repository: InMemoryChatMessageRepository(),
        commandIdFactory: () => 'command-replay',
        verifier: verifier,
      );
      final second = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: secondService,
        repository: InMemoryChatMessageRepository(),
        commandIdFactory: () => 'command-replay',
        verifier: verifier,
      );
      await Future.wait([first.initialize(), second.initialize()]);
      final firstSubmission = first.submit('首次消费');
      await Future<void>.delayed(Duration.zero);
      firstService.completeNext(
        SingleAgentRunOutcome.completed(
          answer: '一次性核验',
          uncertainty: '样本有限',
          evidenceReferences: const ['https://example.com/report'],
          verifierToken: token,
        ),
      );
      await firstSubmission;

      final replaySubmission = second.submit('重放消费');
      await Future<void>.delayed(Duration.zero);
      secondService.completeNext(
        SingleAgentRunOutcome.completed(
          answer: '一次性核验',
          sourceType: ChatMessageSourceType.verifiedEvidence,
          uncertainty: '样本有限',
          evidenceReferences: const ['https://example.com/report'],
          verifierToken: token,
        ),
      );
      await replaySubmission;

      expect(
        first.state.messages.last.sourceType,
        ChatMessageSourceType.verifiedEvidence,
      );
      expect(
        second.state.messages.last.sourceType,
        ChatMessageSourceType.modelOutput,
      );
    },
  );

  test('forged verified non-text history is always downgraded', () async {
    final repository = InMemoryChatMessageRepository(
      seed: const {
        'conversation-data': [
          ChatMessageProjection(
            id: 'forged-progress',
            kind: ChatMessageKind.progress,
            sourceType: ChatMessageSourceType.verifiedEvidence,
            uncertainty: '伪造披露',
            evidenceReferences: ['https://example.com/progress'],
          ),
          ChatMessageProjection(
            id: 'forged-file',
            kind: ChatMessageKind.file,
            sourceType: ChatMessageSourceType.verifiedEvidence,
            uncertainty: '伪造披露',
            evidenceReferences: ['https://example.com/file'],
          ),
          ChatMessageProjection(
            id: 'forged-quote',
            kind: ChatMessageKind.quote,
            sourceType: ChatMessageSourceType.verifiedEvidence,
            uncertainty: '伪造披露',
            evidenceReferences: ['https://example.com/quote'],
          ),
        ],
      },
    );
    final controller = SingleChatController(
      conversationId: 'conversation-data',
      expertId: 'data-analyst',
      service: _FakeConversationApplicationService(),
      repository: repository,
      commandIdFactory: () => 'unused-command',
    );

    await controller.initialize();

    expect(
      controller.state.messages.map((message) => message.sourceType),
      everyElement(ChatMessageSourceType.modelOutput),
    );
    expect(
      () => controller.state.messages.add(
        const ChatMessageProjection(
          id: 'injected',
          kind: ChatMessageKind.agentText,
          sourceType: ChatMessageSourceType.verifiedEvidence,
        ),
      ),
      throwsUnsupportedError,
    );
  });

  test(
    'trusted history copies canonical evidence before publishing state',
    () async {
      final verifier = InMemoryTrustedVerifierReceiptRegistry(
        randomBytes: (length) => List<int>.filled(length, 6),
      );
      const claim = SingleChatVerificationClaim(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        runId: 'run-history-copy',
        commandId: 'command-history-copy',
        answer: '不可变历史',
        canonicalEvidenceReferences: ['https://example.com/report'],
        uncertainty: '样本有限',
      );
      final token = verifier.issue(claim, validFor: const Duration(minutes: 5));
      final receiptId = verifier.verifyAndConsume(claim, token)!;
      final mutableEvidence = <String>['https://example.com/report'];
      final repository = InMemoryChatMessageRepository(
        seed: {
          'conversation-data': [
            ChatMessageProjection(
              id: 'command-history-copy:answer',
              kind: ChatMessageKind.agentText,
              text: '不可变历史',
              sourceType: ChatMessageSourceType.verifiedEvidence,
              uncertainty: '样本有限',
              evidenceReferences: mutableEvidence,
              verificationAttestation: ChatMessageVerificationAttestation(
                receiptId: receiptId,
                expertId: 'data-analyst',
                runId: 'run-history-copy',
                commandId: 'command-history-copy',
              ),
            ),
          ],
        },
      );
      final controller = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: _FakeConversationApplicationService(),
        repository: repository,
        commandIdFactory: () => 'unused-command',
        verifier: verifier,
      );
      await controller.initialize();

      mutableEvidence.add('https://attacker.example/mutated');

      expect(controller.state.messages.single.evidenceReferences, [
        'https://example.com/report',
      ]);
      expect(
        controller.state.messages.single.sourceType,
        ChatMessageSourceType.verifiedEvidence,
      );
    },
  );

  test('visually blank uncertainty cannot be signed', () {
    final verifier = InMemoryTrustedVerifierReceiptRegistry(
      randomBytes: (length) => List<int>.filled(length, 4),
    );
    for (final invisible in <String>[
      '\u00ad',
      '\u034f',
      '\u061c',
      '\u070f',
      '\u115f',
      '\u200b',
      '\u2800',
      '\u3164',
      '\uffa0',
      '\ufe0f',
      '\ufeff',
      '样本\u202e',
      '\n样本有限',
      '\t样本有限',
      '\r样本有限',
      '\u2028样本有限',
      '\u2029样本有限',
      '\u{e0080}',
      '${List<String>.filled(300, '\n').join()}样本有限',
      '样本  有限',
      List<String>.filled(281, '样').join(),
    ]) {
      expect(
        () => verifier.issue(
          SingleChatVerificationClaim(
            conversationId: 'conversation-data',
            expertId: 'data-analyst',
            runId: 'run-invisible',
            commandId: 'command-invisible',
            answer: '不可隐藏',
            canonicalEvidenceReferences: const ['https://example.com/report'],
            uncertainty: invisible,
          ),
          validFor: const Duration(minutes: 5),
        ),
        throwsArgumentError,
        reason: invisible.runes.first.toRadixString(16),
      );
    }
    expect(
      () => verifier.issue(
        SingleChatVerificationClaim(
          conversationId: 'conversation-data',
          expertId: 'data-analyst',
          runId: 'run-boundary',
          commandId: 'command-boundary',
          answer: '长度边界',
          canonicalEvidenceReferences: const ['https://example.com/report'],
          uncertainty: List<String>.filled(280, '样').join(),
        ),
        validFor: const Duration(minutes: 5),
      ),
      returnsNormally,
    );
  });

  test(
    'token invalidation removes stale answer even when rollback throws',
    () async {
      final service = _FakeConversationApplicationService();
      final repository = _FailingRollbackRepository();
      final controller = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: service,
        repository: repository,
        commandIdFactory: () => 'command-failing-rollback',
      );
      await controller.initialize();

      final submission = controller.submit('测试撤销失败');
      await Future<void>.delayed(Duration.zero);
      service.completeNext(
        const SingleAgentRunOutcome.completed(answer: '不能残留'),
      );
      await repository.answerCommitted;
      await controller.stop();
      repository.releaseAppendReturn();
      await submission;

      expect(controller.state.status, SingleChatRunStatus.stopped);
      expect(
        (await repository.load(
          'conversation-data',
        )).where((message) => message.kind == ChatMessageKind.agentText),
        isEmpty,
      );
    },
  );

  test(
    'stop invalidates committed answer before fallible outbox persistence',
    () async {
      final service = _FakeConversationApplicationService();
      final repository = _CommittedButDelayedReturnRepository(
        commandOutbox: _ThrowingTerminalOutbox(),
      );
      final controller = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: service,
        repository: repository,
        commandIdFactory: () => 'command-terminal-outbox-failure',
      );
      await controller.initialize();

      final submission = controller.submit('终止落盘失败');
      await Future<void>.delayed(Duration.zero);
      service.completeNext(
        const SingleAgentRunOutcome.completed(answer: '不能复活'),
      );
      await repository.answerCommitted;
      await controller.stop();
      repository.releaseAppendReturn();
      await submission;

      expect(controller.state.status, SingleChatRunStatus.stopped);
      expect(
        (await repository.load(
          'conversation-data',
        )).where((message) => message.kind == ChatMessageKind.agentText),
        isEmpty,
      );
    },
  );

  test(
    'completed terminal failure compensates its answer before retry',
    () async {
      final service = _FakeConversationApplicationService();
      final outbox = _ThrowingCompletedOnceOutbox();
      final repository = InMemoryChatMessageRepository(commandOutbox: outbox);
      final controller = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: service,
        repository: repository,
        commandIdFactory: () => 'command-completion-transaction',
      );
      await controller.initialize();

      final first = controller.submit('原子完成');
      await Future<void>.delayed(Duration.zero);
      service.completeNext(
        const SingleAgentRunOutcome.completed(answer: '第一次不得残留'),
      );
      await first;

      expect(controller.state.status, SingleChatRunStatus.failed);
      expect(controller.state.canRetry, isTrue);
      expect(
        (await repository.load(
          'conversation-data',
        )).where((message) => message.kind == ChatMessageKind.agentText),
        isEmpty,
      );

      final retry = controller.retry();
      await Future<void>.delayed(Duration.zero);
      service.completeNext(
        const SingleAgentRunOutcome.completed(answer: '第二次原子完成'),
      );
      await retry;

      expect(controller.state.status, SingleChatRunStatus.completed);
      expect(
        (await repository.load(
          'conversation-data',
        )).where((message) => message.kind == ChatMessageKind.agentText),
        hasLength(1),
      );
      expect(service.requests.map((request) => request.clientCommandId), [
        'command-completion-transaction',
        'command-completion-transaction',
      ]);
    },
  );

  test(
    'retry refuses a command that became terminal after compensation',
    () async {
      final service = _FakeConversationApplicationService();
      final outbox = _ThrowingCompletedOnceOutbox();
      final repository = InMemoryChatMessageRepository(commandOutbox: outbox);
      final controller = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: service,
        repository: repository,
        commandIdFactory: () => 'command-terminal-before-retry',
      );
      await controller.initialize();

      final first = controller.submit('补偿后终态');
      await Future<void>.delayed(Duration.zero);
      service.completeNext(
        const SingleAgentRunOutcome.completed(answer: '已回滚答案'),
      );
      await first;
      expect(controller.state.canRetry, isTrue);
      outbox.markTerminal(
        'conversation-data',
        'command-terminal-before-retry',
        SingleChatCommandStatus.stopped,
      );

      final retry = controller.retry();
      await Future<void>.delayed(Duration.zero);
      if (service.requests.length > 1) {
        service.completeNext(
          const SingleAgentRunOutcome.failed(
            failure: SingleAgentRunFailure.retryable,
          ),
        );
      }
      await retry;

      expect(service.requests, hasLength(1));
      expect(controller.state.status, SingleChatRunStatus.failed);
      expect(controller.state.canRetry, isFalse);
    },
  );

  test(
    'completed terminal failure compensates before controller restart',
    () async {
      final outbox = _ThrowingCompletedOnceOutbox();
      final repository = InMemoryChatMessageRepository(commandOutbox: outbox);
      final firstService = _FakeConversationApplicationService();
      final firstController = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: firstService,
        repository: repository,
        commandIdFactory: () => 'command-before-restart',
      );
      await firstController.initialize();
      final first = firstController.submit('重启恢复完成');
      await Future<void>.delayed(Duration.zero);
      firstService.completeNext(
        const SingleAgentRunOutcome.completed(answer: '失败窗口答案'),
      );
      await first;
      expect(firstController.state.status, SingleChatRunStatus.failed);
      firstController.dispose();

      final restartedService = _FakeConversationApplicationService();
      final restartedController = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: restartedService,
        repository: repository,
        commandIdFactory: () => 'command-must-not-replace-pending',
      );
      await restartedController.initialize();
      final restarted = restartedController.submit('重启恢复完成');
      await Future<void>.delayed(Duration.zero);
      restartedService.completeNext(
        const SingleAgentRunOutcome.completed(answer: '重启后唯一答案'),
      );
      await restarted;

      expect(
        restartedService.requests.single.clientCommandId,
        'command-before-restart',
      );
      expect(
        (await repository.load(
          'conversation-data',
        )).where((message) => message.kind == ChatMessageKind.agentText),
        hasLength(1),
      );
    },
  );

  test(
    'completed terminal acknowledgement loss is read back as success',
    () async {
      final outbox = _CommitThenThrowCompletedOutbox();
      final repository = InMemoryChatMessageRepository(commandOutbox: outbox);
      final service = _FakeConversationApplicationService();
      final controller = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: service,
        repository: repository,
        commandIdFactory: () => 'command-terminal-ack-loss',
      );
      await controller.initialize();

      final submission = controller.submit('提交成功但回执丢失');
      await Future<void>.delayed(Duration.zero);
      service.completeNext(
        const SingleAgentRunOutcome.completed(answer: '仍应完成'),
      );
      await submission;

      expect(controller.state.status, SingleChatRunStatus.completed);
      expect(controller.state.canRetry, isFalse);
      expect(
        (await repository.load(
          'conversation-data',
        )).where((message) => message.kind == ChatMessageKind.agentText),
        hasLength(1),
      );
    },
  );

  test(
    'answer commit acknowledgement loss cannot lend its answer to retry',
    () async {
      final service = _FakeConversationApplicationService();
      final repository = _CommitThenThrowAnswerRepository();
      final controller = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: service,
        repository: repository,
        commandIdFactory: () => 'command-answer-ack-loss',
      );
      await controller.initialize();

      final first = controller.submit('答案确认丢失');
      await Future<void>.delayed(Duration.zero);
      service.completeNext(
        const SingleAgentRunOutcome.completed(answer: '第一次未确认答案'),
      );
      await first;
      expect(controller.state.status, SingleChatRunStatus.failed);

      final retry = controller.retry();
      await Future<void>.delayed(Duration.zero);
      service.completeNext(
        const SingleAgentRunOutcome.completed(answer: '第二次确认答案'),
      );
      await retry;

      final answers = (await repository.load(
        'conversation-data',
      )).where((message) => message.kind == ChatMessageKind.agentText).toList();
      expect(answers, hasLength(1));
      expect(answers.single.text, '第二次确认答案');
      expect(answers.single.dispatchClaimOwner, isNotNull);
      expect(controller.state.status, SingleChatRunStatus.completed);
    },
  );

  test(
    'stop while user append is pending never starts an upstream run',
    () async {
      final service = _FakeConversationApplicationService();
      final repository = _DelayedUserAppendRepository();
      final controller = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: service,
        repository: repository,
        commandIdFactory: () => 'command-user-append-stop',
      );
      await controller.initialize();

      final submission = controller.submit('写用户消息时停止');
      await repository.userAppendStarted;
      await controller.stop();
      repository.releaseUserAppend();
      await submission;

      expect(controller.state.status, SingleChatRunStatus.stopped);
      expect(service.requests, isEmpty);
      expect(service.stoppedRunIds, isEmpty);
    },
  );

  test('failed stop journaling blocks command redispatch', () async {
    final service = _FakeConversationApplicationService();
    final outbox = _ThrowingTerminalOutbox();
    final controller = SingleChatController(
      conversationId: 'conversation-data',
      expertId: 'data-analyst',
      service: service,
      repository: InMemoryChatMessageRepository(commandOutbox: outbox),
      commandIdFactory: () => 'command-stop-journal-failure',
    );
    await controller.initialize();

    final first = controller.submit('停止必须持久');
    await Future<void>.delayed(Duration.zero);
    await controller.stop();
    service.completeNext(
      const SingleAgentRunOutcome.completed(answer: '停止后的迟到答案'),
    );
    await first;

    final second = controller.submit('停止必须持久');
    await Future<void>.delayed(Duration.zero);
    if (service.requests.length > 1) {
      service.completeNext(
        const SingleAgentRunOutcome.failed(
          failure: SingleAgentRunFailure.retryable,
        ),
      );
    }
    await second;

    expect(service.requests, hasLength(1));
    expect(controller.state.status, SingleChatRunStatus.stopped);

    final restartedService = _FakeConversationApplicationService();
    final restartedController = SingleChatController(
      conversationId: 'conversation-data',
      expertId: 'data-analyst',
      service: restartedService,
      repository: InMemoryChatMessageRepository(commandOutbox: outbox),
      commandIdFactory: () => 'must-not-replace-stopped-command',
    );
    await restartedController.initialize();
    final restartedSubmission = restartedController.submit('停止必须持久');
    await Future<void>.delayed(Duration.zero);
    final restartedRequestCount = restartedService.requests.length;
    if (restartedService.requests.isNotEmpty) {
      restartedService.completeNext(
        const SingleAgentRunOutcome.failed(
          failure: SingleAgentRunFailure.retryable,
        ),
      );
    }
    await restartedSubmission;

    expect(restartedRequestCount, 0);
    restartedController.dispose();
  });

  test('two file outbox instances reserve one command for the same intent', () {
    final directory = Directory.systemTemp.createTempSync(
      'single-chat-outbox-same-intent-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/commands.json';
    final first = FileSingleChatCommandOutbox(path);
    final second = FileSingleChatCommandOutbox(path);

    final firstRecord = first.reserve(
      conversationId: 'conversation-data',
      normalizedIntent: '同一意图',
      createCommandId: () => '01JCONCURRENTFIRST00000000',
    );
    final secondRecord = second.reserve(
      conversationId: 'conversation-data',
      normalizedIntent: '同一意图',
      createCommandId: () => '01JCONCURRENTSECOND0000000',
    );

    expect(secondRecord.commandId, firstRecord.commandId);
  });

  test('two file outbox instances merge different intents without loss', () {
    final directory = Directory.systemTemp.createTempSync(
      'single-chat-outbox-different-intent-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/commands.json';
    final first = FileSingleChatCommandOutbox(path);
    final second = FileSingleChatCommandOutbox(path);

    final firstRecord = first.reserve(
      conversationId: 'conversation-data',
      normalizedIntent: '第一个意图',
      createCommandId: () => '01JDIFFERENTFIRST000000000',
    );
    final secondRecord = second.reserve(
      conversationId: 'conversation-data',
      normalizedIntent: '第二个意图',
      createCommandId: () => '01JDIFFERENTSECOND00000000',
    );
    final restarted = FileSingleChatCommandOutbox(path);

    expect(
      restarted
          .reserve(
            conversationId: 'conversation-data',
            normalizedIntent: '第一个意图',
            createCommandId: () => '01JLOSTFIRST0000000000000',
          )
          .commandId,
      firstRecord.commandId,
    );
    expect(
      restarted
          .reserve(
            conversationId: 'conversation-data',
            normalizedIntent: '第二个意图',
            createCommandId: () => '01JLOSTSECOND000000000000',
          )
          .commandId,
      secondRecord.commandId,
    );
  });

  for (final backend in ['memory', 'file']) {
    test(
      '$backend terminal CAS rejects expired claims using an injected clock',
      () {
        var nowEpochMs = 1000;
        final directory = backend == 'file'
            ? Directory.systemTemp.createTempSync('single-chat-terminal-clock-')
            : null;
        if (directory != null) {
          addTearDown(() => directory.deleteSync(recursive: true));
        }
        SingleChatCommandOutbox? outbox;
        Object? constructionFailure;
        try {
          outbox =
              Function.apply(
                    backend == 'memory'
                        ? InMemorySingleChatCommandOutbox.new
                        : FileSingleChatCommandOutbox.new,
                    backend == 'memory'
                        ? const <Object?>[]
                        : <Object?>['${directory!.path}/commands.json'],
                    <Symbol, Object?>{#nowEpochMs: () => nowEpochMs},
                  )
                  as SingleChatCommandOutbox;
        } catch (error) {
          constructionFailure = error;
        }
        expect(
          constructionFailure,
          isNull,
          reason: 'The outbox must accept a trusted terminal-CAS clock.',
        );
        if (outbox == null) {
          return;
        }

        final liveCommand = outbox.reserve(
          conversationId: 'conversation-data',
          normalizedIntent: '有效 lease',
          createCommandId: () => 'command-live-lease-$backend',
        );
        final liveClaim = outbox.claimForDispatch(
          conversationId: 'conversation-data',
          commandId: liveCommand.commandId,
          ownerId: 'controller-live',
          nowEpochMs: 1000,
          leaseExpiresAtEpochMs: 2000,
        )!;
        nowEpochMs = 1999;
        outbox.markTerminal(
          'conversation-data',
          liveCommand.commandId,
          SingleChatCommandStatus.completed,
          dispatchClaim: liveClaim,
        );

        nowEpochMs = 2500;
        outbox.markTerminal(
          'conversation-data',
          liveCommand.commandId,
          SingleChatCommandStatus.completed,
          dispatchClaim: liveClaim,
        );

        final expiredCommand = outbox.reserve(
          conversationId: 'conversation-data',
          normalizedIntent: '过期 lease',
          createCommandId: () => 'command-expired-lease-$backend',
        );
        final expiredClaim = outbox.claimForDispatch(
          conversationId: 'conversation-data',
          commandId: expiredCommand.commandId,
          ownerId: 'controller-expired',
          nowEpochMs: 2500,
          leaseExpiresAtEpochMs: 3000,
        )!;
        nowEpochMs = 3000;

        expect(
          () => outbox!.markTerminal(
            'conversation-data',
            expiredCommand.commandId,
            SingleChatCommandStatus.completed,
            dispatchClaim: expiredClaim,
          ),
          throwsStateError,
        );
        expect(
          outbox.read('conversation-data', expiredCommand.commandId)?.status,
          SingleChatCommandStatus.pending,
        );

        final reclaimedClaim = outbox.claimForDispatch(
          conversationId: 'conversation-data',
          commandId: expiredCommand.commandId,
          ownerId: 'controller-reclaimed',
          nowEpochMs: 3000,
          leaseExpiresAtEpochMs: 4000,
        )!;
        expect(
          () => outbox!.markTerminal(
            'conversation-data',
            expiredCommand.commandId,
            SingleChatCommandStatus.completed,
            dispatchClaim: expiredClaim,
          ),
          throwsStateError,
        );
        nowEpochMs = 4000;
        expect(
          () => outbox!.markTerminal(
            'conversation-data',
            expiredCommand.commandId,
            SingleChatCommandStatus.completed,
            dispatchClaim: reclaimedClaim,
          ),
          throwsStateError,
        );
      },
    );
  }

  test(
    'file dispatch claim CAS owns terminal transition and expires safely',
    () {
      final directory = Directory.systemTemp.createTempSync(
        'single-chat-dispatch-claim-cas-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      var trustedNowEpochMs = 1000;
      final outbox = FileSingleChatCommandOutbox(
        '${directory.path}/commands.json',
        nowEpochMs: () => trustedNowEpochMs,
      );
      final command = outbox.reserve(
        conversationId: 'conversation-data',
        normalizedIntent: '原子启动授权',
        createCommandId: () => 'command-dispatch-claim-cas',
      );
      final firstClaim = outbox.claimForDispatch(
        conversationId: 'conversation-data',
        commandId: command.commandId,
        ownerId: 'controller-a',
        nowEpochMs: 1000,
        leaseExpiresAtEpochMs: 2000,
      )!;

      expect(
        () => outbox.markTerminal(
          'conversation-data',
          command.commandId,
          SingleChatCommandStatus.stopped,
        ),
        throwsStateError,
      );
      expect(
        outbox.claimForDispatch(
          conversationId: 'conversation-data',
          commandId: command.commandId,
          ownerId: 'controller-b',
          nowEpochMs: 1500,
          leaseExpiresAtEpochMs: 2500,
        ),
        isNull,
      );

      final recoveredClaim = outbox.claimForDispatch(
        conversationId: 'conversation-data',
        commandId: command.commandId,
        ownerId: 'controller-b',
        nowEpochMs: 2000,
        leaseExpiresAtEpochMs: 3000,
      )!;
      expect(recoveredClaim.generation, greaterThan(firstClaim.generation));
      expect(outbox.releaseDispatchClaim(firstClaim), isFalse);
      expect(
        outbox.renewDispatchClaim(
          claim: firstClaim,
          nowEpochMs: 2100,
          leaseExpiresAtEpochMs: 3100,
        ),
        isFalse,
      );
      expect(
        outbox.renewDispatchClaim(
          claim: recoveredClaim,
          nowEpochMs: 2100,
          leaseExpiresAtEpochMs: 4000,
        ),
        isTrue,
      );
      expect(outbox.releaseDispatchClaim(recoveredClaim), isTrue);
      expect(
        () => outbox.markTerminal(
          'conversation-data',
          command.commandId,
          SingleChatCommandStatus.completed,
          dispatchClaim: firstClaim,
        ),
        throwsStateError,
      );
      final terminalClaim = outbox.claimForDispatch(
        conversationId: 'conversation-data',
        commandId: command.commandId,
        ownerId: 'controller-c',
        nowEpochMs: 2200,
        leaseExpiresAtEpochMs: 4200,
      )!;
      trustedNowEpochMs = 2200;
      outbox.markTerminal(
        'conversation-data',
        command.commandId,
        SingleChatCommandStatus.stopped,
        dispatchClaim: terminalClaim,
      );
      expect(
        () => outbox.markTerminal(
          'conversation-data',
          command.commandId,
          SingleChatCommandStatus.stopped,
          dispatchClaim: firstClaim,
        ),
        throwsStateError,
      );
      outbox.markTerminal(
        'conversation-data',
        command.commandId,
        SingleChatCommandStatus.stopped,
        dispatchClaim: terminalClaim,
      );
      expect(
        outbox.read('conversation-data', command.commandId)?.status,
        SingleChatCommandStatus.stopped,
      );
    },
  );

  test('a live same-process mutex is never reaped by wall-clock age', () async {
    final directory = Directory.systemTemp.createTempSync(
      'single-chat-outbox-stale-mutex-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/commands.json';
    final staleMutexPath = '$path.mutex';
    File(staleMutexPath).writeAsStringSync('dead-process');
    File('$path.mutex.${pid + 1000000}').writeAsStringSync('dead-process');
    final currentPidMutexPath = '$path.mutex.$pid';
    File(currentPidMutexPath)
      ..writeAsStringSync('dead-isolate')
      ..setLastModifiedSync(
        DateTime.now().subtract(const Duration(minutes: 1)),
      );
    final release = Isolate.run(() {
      sleep(const Duration(milliseconds: 250));
      for (final path in [staleMutexPath, currentPidMutexPath]) {
        final staleMutex = File(path);
        if (staleMutex.existsSync()) {
          staleMutex.deleteSync();
        }
      }
    });
    final elapsed = Stopwatch()..start();

    FileSingleChatCommandOutbox(path);
    elapsed.stop();
    await release;

    expect(
      elapsed.elapsed,
      greaterThanOrEqualTo(const Duration(milliseconds: 200)),
    );
    expect(elapsed.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('stale temp file never overwrites a newer canonical generation', () {
    final directory = Directory.systemTemp.createTempSync(
      'single-chat-outbox-stale-temp-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/commands.json';
    final outbox = FileSingleChatCommandOutbox(path);
    outbox.reserve(
      conversationId: 'conversation-data',
      normalizedIntent: '旧意图',
      createCommandId: () => '01JSTALEOLD000000000000000',
    );
    File(path).copySync('$path.tmp');
    final newest = outbox.reserve(
      conversationId: 'conversation-data',
      normalizedIntent: '新意图',
      createCommandId: () => '01JSTALENEW000000000000000',
    );

    final recovered = FileSingleChatCommandOutbox(path).reserve(
      conversationId: 'conversation-data',
      normalizedIntent: '新意图',
      createCommandId: () => '01JSTALEOVERWRITE000000000',
    );

    expect(recovered.commandId, newest.commandId);
  });

  test(
    'stale committed temp generation cannot replace newer canonical state',
    () {
      final directory = Directory.systemTemp.createTempSync(
        'single-chat-outbox-stale-marker-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/commands.json';
      final outbox = FileSingleChatCommandOutbox(path);
      outbox.reserve(
        conversationId: 'conversation-data',
        normalizedIntent: '旧代际',
        createCommandId: () => '01JSTALEMARKEROLD000000000',
      );
      final stalePayload = File(path).readAsStringSync();
      final staleEnvelope = jsonDecode(stalePayload) as Map<String, Object?>;
      final newest = outbox.reserve(
        conversationId: 'conversation-data',
        normalizedIntent: '新代际',
        createCommandId: () => '01JSTALEMARKERNEW000000000',
      );
      File('$path.tmp').writeAsStringSync(stalePayload, flush: true);
      File('$path.commit').writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'generation': staleEnvelope['generation'],
          'txId': staleEnvelope['txId'],
          'payloadSha256': sha256.convert(utf8.encode(stalePayload)).toString(),
        }),
        flush: true,
      );

      final recovered = FileSingleChatCommandOutbox(path).reserve(
        conversationId: 'conversation-data',
        normalizedIntent: '新代际',
        createCommandId: () => 'must-not-overwrite-new-generation',
      );

      expect(recovered.commandId, newest.commandId);
      expect(File('$path.tmp').existsSync(), isFalse);
      expect(File('$path.commit').existsSync(), isFalse);
    },
  );

  test('typed non-map outbox corruption fails closed as FormatException', () {
    final directory = Directory.systemTemp.createTempSync(
      'single-chat-outbox-corrupt-type-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/commands.json';
    File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync('[42]');

    expect(
      () => FileSingleChatCommandOutbox(path),
      throwsA(isA<FormatException>()),
    );
  });

  test('typed field corruption is normalized to FormatException', () {
    final directory = Directory.systemTemp.createTempSync(
      'single-chat-outbox-corrupt-field-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/commands.json';
    File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'generation': 1,
          'txId': 'typed-corruption',
          'records': [
            {
              'conversationId': 42,
              'commandId': 'command',
              'normalizedIntent': '意图',
              'status': 'pending',
              'revision': 0,
            },
          ],
        }),
      );

    expect(
      () => FileSingleChatCommandOutbox(path),
      throwsA(isA<FormatException>()),
    );
  });

  test('partial dispatch claim corruption fails closed', () {
    final directory = Directory.systemTemp.createTempSync(
      'single-chat-outbox-corrupt-claim-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/commands.json';
    File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'generation': 1,
          'txId': 'typed-claim-corruption',
          'records': [
            {
              'conversationId': 'conversation-data',
              'commandId': 'command-corrupt-claim',
              'normalizedIntent': '损坏授权',
              'status': 'pending',
              'revision': 1,
              'dispatchClaimOwner': 'controller',
            },
          ],
        }),
      );

    expect(
      () => FileSingleChatCommandOutbox(path),
      throwsA(isA<FormatException>()),
    );
  });

  test('invalid commit marker generation fails closed', () {
    final directory = Directory.systemTemp.createTempSync(
      'single-chat-outbox-invalid-marker-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/commands.json';
    FileSingleChatCommandOutbox(path).reserve(
      conversationId: 'conversation-data',
      normalizedIntent: '合法状态',
      createCommandId: () => '01JINVALIDMARKERBASE0000000',
    );
    final payload = File(path).readAsStringSync();
    final envelope = jsonDecode(payload) as Map<String, Object?>;
    File('$path.tmp').writeAsStringSync(payload, flush: true);
    File('$path.commit').writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'generation': -1,
        'txId': envelope['txId'],
        'payloadSha256': sha256.convert(utf8.encode(payload)).toString(),
      }),
      flush: true,
    );

    expect(
      () => FileSingleChatCommandOutbox(path),
      throwsA(isA<FormatException>()),
    );
  });

  test('matching commit marker recovers only its flushed generation', () {
    final directory = Directory.systemTemp.createTempSync(
      'single-chat-outbox-commit-marker-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/commands.json';
    final stagedPath = '${directory.path}/staged.json';
    FileSingleChatCommandOutbox(path).reserve(
      conversationId: 'conversation-data',
      normalizedIntent: '旧状态',
      createCommandId: () => '01JMARKEROLD00000000000000',
    );
    final staged = FileSingleChatCommandOutbox(stagedPath);
    staged.reserve(
      conversationId: 'conversation-data',
      normalizedIntent: '旧状态',
      createCommandId: () => '01JMARKEROLD00000000000000',
    );
    final newest = staged.reserve(
      conversationId: 'conversation-data',
      normalizedIntent: '已提交的新状态',
      createCommandId: () => '01JMARKERNEW00000000000000',
    );
    final stagedPayload = File(stagedPath).readAsStringSync();
    final stagedEnvelope = jsonDecode(stagedPayload) as Map<String, Object?>;
    File('$path.tmp').writeAsStringSync(stagedPayload, flush: true);
    File('$path.commit').writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'generation': stagedEnvelope['generation'],
        'txId': stagedEnvelope['txId'],
        'payloadSha256': sha256.convert(utf8.encode(stagedPayload)).toString(),
      }),
      flush: true,
    );
    File(path).writeAsStringSync('{truncated');

    final recovered = FileSingleChatCommandOutbox(path).reserve(
      conversationId: 'conversation-data',
      normalizedIntent: '已提交的新状态',
      createCommandId: () => '01JMARKERSHOULDNOTRUN000000',
    );

    expect(recovered.commandId, newest.commandId);
    expect(File('$path.commit').existsSync(), isFalse);
    expect(File('$path.tmp').existsSync(), isFalse);
  });

  test(
    'application support provider and sensitive file policy are injected',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'single-chat-outbox-policy-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final policy = _RecordingOutboxStoragePolicy();
      final outbox = await FileSingleChatCommandOutbox.openInApplicationSupport(
        directoryProvider: () async => directory,
        storagePolicy: policy,
      );

      outbox.reserve(
        conversationId: 'conversation-data',
        normalizedIntent: '受保护写入',
        createCommandId: () => '01JPOLICYCOMMAND00000000000',
      );

      final canonicalDirectory = directory.resolveSymbolicLinksSync();
      expect(policy.preparedDirectories, contains(canonicalDirectory));
      expect(
        policy.protectedPaths,
        contains('$canonicalDirectory/single-chat-commands.json.tmp'),
      );
      expect(
        policy.protectedPaths,
        contains('$canonicalDirectory/single-chat-commands.json'),
      );
      expect(policy.syncedDirectories, contains(canonicalDirectory));
      expect(
        policy.syncedDirectories
            .where((path) => path == canonicalDirectory)
            .length,
        greaterThanOrEqualTo(3),
      );
    },
  );

  test(
    'drift durable repository survives restart and exact ownership rollback',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'single-chat-drift-restart-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final databasePath = '${directory.path}/history.sqlite';
      final outboxPath = '${directory.path}/commands.json';
      const conversations = {
        'conversation-data': SingleChatConversationProjection(
          conversationId: 'conversation-data',
          expertId: 'data-analyst',
          title: '数据分析',
          agentName: '数据分析师',
          modelLabel: 'Provider / model',
          avatarLetter: '数',
        ),
      };
      final first = await DriftChatMessageRepository.open(
        databasePath: databasePath,
        commandOutbox: FileSingleChatCommandOutbox(outboxPath),
        conversations: conversations,
      );
      const user = ChatMessageProjection(
        id: 'command-durable:user',
        kind: ChatMessageKind.userText,
        text: '持久化用户意图',
      );
      const answer = ChatMessageProjection(
        id: 'command-durable:answer',
        kind: ChatMessageKind.agentText,
        text: '持久化答案',
        sourceType: ChatMessageSourceType.verifiedEvidence,
        uncertainty: '样本存在时间范围限制',
        evidenceReferences: ['https://example.com/report'],
        verificationAttestation: ChatMessageVerificationAttestation(
          receiptId: 'receipt-durable',
          expertId: 'data-analyst',
          runId: 'run-durable',
          commandId: 'command-durable',
        ),
        dispatchClaimOwner: 'controller-durable',
        dispatchClaimGeneration: 7,
      );
      await first.append('conversation-data', user);
      final commit = await first.appendIf(
        'conversation-data',
        answer,
        ChatMessageCommitToken('commit-durable', generation: 9),
        () => true,
      );
      expect(commit.committed, isTrue);
      expect(commit.inserted, isTrue);
      expect(commit.storageRevision, isNotNull);
      await first.close();

      final restarted = await DriftChatMessageRepository.open(
        databasePath: databasePath,
        commandOutbox: FileSingleChatCommandOutbox(outboxPath),
        conversations: conversations,
      );
      final loaded = await restarted.load('conversation-data');
      expect(loaded, hasLength(2));
      expect(loaded[0].text, '持久化用户意图');
      expect(loaded[1].text, '持久化答案');
      expect(loaded[1].verificationAttestation?.receiptId, 'receipt-durable');
      expect(loaded[1].evidenceReferences, ['https://example.com/report']);
      expect(loaded[1].dispatchClaimOwner, 'controller-durable');
      expect(loaded[1].dispatchClaimGeneration, 7);
      expect(
        await restarted.rollbackOwned('conversation-data', commit),
        ChatMessageRollbackDisposition.removedOwnedRevision,
      );
      await restarted.close();

      final finalRepository = await DriftChatMessageRepository.open(
        databasePath: databasePath,
        commandOutbox: FileSingleChatCommandOutbox(outboxPath),
        conversations: conversations,
      );
      final remaining = await finalRepository.load('conversation-data');
      expect(remaining, hasLength(1));
      expect(remaining.single.id, 'command-durable:user');
      await finalRepository.close();
    },
  );

  test(
    'drift removes an exact stale answer before the reclaimed owner commits',
    () async {
      var nowEpochMs = 1000;
      final directory = Directory.systemTemp.createTempSync(
        'single-chat-drift-reclaimed-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final outbox = FileSingleChatCommandOutbox(
        '${directory.path}/commands.json',
        nowEpochMs: () => nowEpochMs,
      );
      final command = outbox.reserve(
        conversationId: 'conversation-data',
        normalizedIntent: 'drift reclaimed claim',
        createCommandId: () => 'command-drift-reclaimed',
      );
      final oldClaim = outbox.claimForDispatch(
        conversationId: 'conversation-data',
        commandId: command.commandId,
        ownerId: 'old-owner',
        nowEpochMs: 1000,
        leaseExpiresAtEpochMs: 2000,
      )!;
      final repository = await DriftChatMessageRepository.open(
        databasePath: '${directory.path}/history.sqlite',
        commandOutbox: outbox,
        conversations: const {},
      );
      await repository.appendIf(
        'conversation-data',
        ChatMessageProjection(
          id: '${command.commandId}:answer',
          kind: ChatMessageKind.agentText,
          text: '旧 owner 的答案',
          dispatchClaimOwner: oldClaim.ownerId,
          dispatchClaimGeneration: oldClaim.generation,
        ),
        ChatMessageCommitToken('old-owner-commit', generation: 1),
        () => true,
      );
      nowEpochMs = 2000;
      final newClaim = outbox.claimForDispatch(
        conversationId: 'conversation-data',
        commandId: command.commandId,
        ownerId: 'new-owner',
        nowEpochMs: 2000,
        leaseExpiresAtEpochMs: 3000,
      )!;
      final controller = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: _FakeConversationApplicationService(),
        repository: repository,
        commandIdFactory: () => 'unused-command',
        nowEpochMs: () => nowEpochMs,
      );

      await controller.initialize();

      expect(controller.state.historyLoadFailed, isTrue);
      expect(controller.state.messages, isEmpty);
      final newCommit = await repository.appendIf(
        'conversation-data',
        ChatMessageProjection(
          id: '${command.commandId}:answer',
          kind: ChatMessageKind.agentText,
          text: '新 owner 的答案',
          dispatchClaimOwner: newClaim.ownerId,
          dispatchClaimGeneration: newClaim.generation,
        ),
        ChatMessageCommitToken('new-owner-commit', generation: 2),
        () => true,
      );
      expect(newCommit.committed, isTrue);
      expect(newCommit.inserted, isTrue);
      expect(
        (await repository.load('conversation-data')).single.text,
        '新 owner 的答案',
      );
      await repository.close();
    },
  );

  test(
    'drift durable repository idempotently appends exact duplicates and closes',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'single-chat-drift-cas-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final databasePath = '${directory.path}/history.sqlite';
      final outboxPath = '${directory.path}/commands.json';
      const conversations = {
        'conversation-data': SingleChatConversationProjection(
          conversationId: 'conversation-data',
          expertId: 'data-analyst',
          title: '数据分析',
          agentName: '数据分析师',
          modelLabel: 'Provider / model',
          avatarLetter: '数',
        ),
      };
      final repository = await DriftChatMessageRepository.open(
        databasePath: databasePath,
        commandOutbox: FileSingleChatCommandOutbox(outboxPath),
        conversations: conversations,
      );
      const firstMessage = ChatMessageProjection(
        id: 'concurrent:user-a',
        kind: ChatMessageKind.userText,
        text: '并发消息 A',
      );
      const secondMessage = ChatMessageProjection(
        id: 'concurrent:user-b',
        kind: ChatMessageKind.userText,
        text: '并发消息 B',
      );
      const conflict = ChatMessageProjection(
        id: 'concurrent:user-a',
        kind: ChatMessageKind.userText,
        text: '冲突覆盖 A',
      );

      await repository.append('conversation-data', firstMessage);
      await repository.append('conversation-data', secondMessage);
      await repository.append('conversation-data', firstMessage);
      expect(
        () => repository.append('conversation-data', conflict),
        throwsStateError,
      );
      expect(await repository.load('conversation-data'), hasLength(2));

      await repository.close();
      await repository.close();
      expect(() => repository.commandOutbox, throwsStateError);
      expect(repository.load('conversation-data'), throwsStateError);
    },
  );

  test(
    'drift durable repository rejects unsupported schema versions',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'single-chat-drift-version-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final databasePath = '${directory.path}/history.sqlite';
      final database = sqlite3.open(databasePath);
      database.execute('PRAGMA user_version = 2');
      database.close();

      await expectLater(
        DriftChatMessageRepository.open(
          databasePath: databasePath,
          commandOutbox: FileSingleChatCommandOutbox(
            '${directory.path}/commands.json',
          ),
          conversations: const {},
        ),
        throwsStateError,
      );
    },
  );

  test(
    'drift existing-id writes fail closed when their digest is corrupt',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'single-chat-drift-corrupt-existing-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final databasePath = '${directory.path}/history.sqlite';
      final repository = await DriftChatMessageRepository.open(
        databasePath: databasePath,
        commandOutbox: FileSingleChatCommandOutbox(
          '${directory.path}/commands.json',
        ),
        conversations: const {},
      );
      const message = ChatMessageProjection(
        id: 'corrupt-existing',
        kind: ChatMessageKind.userText,
        text: '不可绕过的摘要',
      );
      await repository.append('conversation-data', message);
      await repository.close();
      final database = sqlite3.open(databasePath);
      database.execute("""
      UPDATE single_chat_messages
      SET projection_sha256 = '0000000000000000000000000000000000000000000000000000000000000000'
      WHERE message_id = 'corrupt-existing'
    """);
      database.close();
      final reopened = await DriftChatMessageRepository.open(
        databasePath: databasePath,
        commandOutbox: FileSingleChatCommandOutbox(
          '${directory.path}/commands.json',
        ),
        conversations: const {},
      );

      await expectLater(
        reopened.append('conversation-data', message),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        reopened.appendIf(
          'conversation-data',
          message,
          ChatMessageCommitToken('corrupt-owner', generation: 1),
          () => true,
        ),
        throwsA(isA<FormatException>()),
      );
      await reopened.close();
    },
  );

  test('drift rollback refuses stale owner generation and revision', () async {
    final directory = Directory.systemTemp.createTempSync(
      'single-chat-drift-stale-rollback-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final repository = await DriftChatMessageRepository.open(
      databasePath: '${directory.path}/history.sqlite',
      commandOutbox: FileSingleChatCommandOutbox(
        '${directory.path}/commands.json',
      ),
      conversations: const {},
    );
    const message = ChatMessageProjection(
      id: 'owned-answer',
      kind: ChatMessageKind.agentText,
      text: '只有拥有者可删除',
    );
    final commit = await repository.appendIf(
      'conversation-data',
      message,
      ChatMessageCommitToken('owner-a', generation: 3),
      () => true,
    );
    for (final stale in [
      ChatMessageCommitResult(
        messageId: commit.messageId,
        committed: true,
        inserted: true,
        ownerId: 'owner-b',
        ownerGeneration: commit.ownerGeneration,
        storageRevision: commit.storageRevision,
      ),
      ChatMessageCommitResult(
        messageId: commit.messageId,
        committed: true,
        inserted: true,
        ownerId: commit.ownerId,
        ownerGeneration: 4,
        storageRevision: commit.storageRevision,
      ),
      ChatMessageCommitResult(
        messageId: commit.messageId,
        committed: true,
        inserted: true,
        ownerId: commit.ownerId,
        ownerGeneration: commit.ownerGeneration,
        storageRevision: commit.storageRevision! + 1,
      ),
    ]) {
      expect(
        await repository.rollbackOwned('conversation-data', stale),
        ChatMessageRollbackDisposition.ownershipMismatch,
      );
    }
    expect(
      (await repository.load('conversation-data')).map((item) => item.id),
      ['owned-answer'],
    );
    await repository.close();
  });

  test('drift repository rejects every operation after close', () async {
    final directory = Directory.systemTemp.createTempSync(
      'single-chat-drift-closed-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final repository = await DriftChatMessageRepository.open(
      databasePath: '${directory.path}/history.sqlite',
      commandOutbox: FileSingleChatCommandOutbox(
        '${directory.path}/commands.json',
      ),
      conversations: const {
        'conversation-data': SingleChatConversationProjection(
          conversationId: 'conversation-data',
          expertId: 'data-analyst',
          title: '数据分析',
          agentName: '数据分析师',
          modelLabel: 'Provider / model',
          avatarLetter: '数',
        ),
      },
    );
    await repository.close();
    const message = ChatMessageProjection(
      id: 'closed-message',
      kind: ChatMessageKind.userText,
      text: '关闭后不得写入',
    );
    expect(() => repository.describe('conversation-data'), throwsStateError);
    await expectLater(repository.load('conversation-data'), throwsStateError);
    await expectLater(
      repository.append('conversation-data', message),
      throwsStateError,
    );
    await expectLater(
      repository.appendIf(
        'conversation-data',
        message,
        ChatMessageCommitToken('closed-owner', generation: 1),
        () => true,
      ),
      throwsStateError,
    );
    await expectLater(
      repository.rollbackOwned(
        'conversation-data',
        const ChatMessageCommitResult(
          messageId: 'closed-message',
          committed: true,
          inserted: true,
          ownerId: 'closed-owner',
          ownerGeneration: 1,
          storageRevision: 1,
        ),
      ),
      throwsStateError,
    );
  });

  test(
    'two drift connections race an exact duplicate without double insertion',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'single-chat-drift-race-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final databasePath = '${directory.path}/history.sqlite';
      final priorWarningSetting =
          driftRuntimeOptions.dontWarnAboutMultipleDatabases;
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      addTearDown(
        () => driftRuntimeOptions.dontWarnAboutMultipleDatabases =
            priorWarningSetting,
      );
      final first = await DriftChatMessageRepository.open(
        databasePath: databasePath,
        commandOutbox: FileSingleChatCommandOutbox(
          '${directory.path}/first.json',
        ),
        conversations: const {},
      );
      final second = await DriftChatMessageRepository.open(
        databasePath: databasePath,
        commandOutbox: FileSingleChatCommandOutbox(
          '${directory.path}/second.json',
        ),
        conversations: const {},
      );
      const message = ChatMessageProjection(
        id: 'raced-message',
        kind: ChatMessageKind.userText,
        text: '完全相同的竞态写入',
      );

      await Future.wait([
        first.append('conversation-data', message),
        second.append('conversation-data', message),
      ]);

      expect(await first.load('conversation-data'), hasLength(1));
      expect(await second.load('conversation-data'), hasLength(1));
      await first.close();
      await second.close();
    },
  );

  test('isolated file outbox writers serialize the same intent', () async {
    final directory = Directory.systemTemp.createTempSync(
      'single-chat-outbox-isolates-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/commands.json';

    final commandIds = await Future.wait([
      Isolate.run(
        () => FileSingleChatCommandOutbox(path)
            .reserve(
              conversationId: 'conversation-data',
              normalizedIntent: '隔离并发意图',
              createCommandId: () => '01JISOLATEFIRST00000000000',
            )
            .commandId,
      ),
      Isolate.run(
        () => FileSingleChatCommandOutbox(path)
            .reserve(
              conversationId: 'conversation-data',
              normalizedIntent: '隔离并发意图',
              createCommandId: () => '01JISOLATESECOND0000000000',
            )
            .commandId,
      ),
    ]);

    expect(commandIds.toSet(), hasLength(1));
  });

  test(
    'two controllers share same intent and preserve different intents',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'single-chat-outbox-two-controllers-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/commands.json';
      final firstService = _FakeConversationApplicationService();
      final secondService = _FakeConversationApplicationService();
      final first = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: firstService,
        repository: InMemoryChatMessageRepository(
          commandOutbox: FileSingleChatCommandOutbox(path),
        ),
        commandIdFactory: () => '01JCONTROLLERFIRST000000000',
      );
      final second = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: secondService,
        repository: InMemoryChatMessageRepository(
          commandOutbox: FileSingleChatCommandOutbox(path),
        ),
        commandIdFactory: () => '01JCONTROLLERSECOND00000000',
      );
      await Future.wait([first.initialize(), second.initialize()]);

      first.submit('控制器同一意图');
      second.submit('控制器同一意图');
      await Future<void>.delayed(Duration.zero);

      expect(firstService.requests, hasLength(1));
      expect(secondService.requests, isEmpty);
      expect(
        firstService.requests.single.clientCommandId,
        FileSingleChatCommandOutbox(path)
            .reserve(
              conversationId: 'conversation-data',
              normalizedIntent: '控制器同一意图',
              createCommandId: () => 'must-not-replace-shared-command',
            )
            .commandId,
      );
      await first.stop();
      await second.stop();

      final thirdService = _FakeConversationApplicationService();
      final fourthService = _FakeConversationApplicationService();
      final third = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: thirdService,
        repository: InMemoryChatMessageRepository(
          commandOutbox: FileSingleChatCommandOutbox(path),
        ),
        commandIdFactory: () => '01JCONTROLLERTHIRD000000000',
      );
      final fourth = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: fourthService,
        repository: InMemoryChatMessageRepository(
          commandOutbox: FileSingleChatCommandOutbox(path),
        ),
        commandIdFactory: () => '01JCONTROLLERFOURTH00000000',
      );
      await Future.wait([third.initialize(), fourth.initialize()]);
      third.submit('控制器不同意图 A');
      fourth.submit('控制器不同意图 B');
      await Future<void>.delayed(Duration.zero);

      expect(
        thirdService.requests.single.clientCommandId,
        isNot(fourthService.requests.single.clientCommandId),
      );
      final restarted = FileSingleChatCommandOutbox(path);
      expect(
        restarted
            .reserve(
              conversationId: 'conversation-data',
              normalizedIntent: '控制器不同意图 A',
              createCommandId: () => 'must-not-replace-a',
            )
            .commandId,
        thirdService.requests.single.clientCommandId,
      );
      expect(
        restarted
            .reserve(
              conversationId: 'conversation-data',
              normalizedIntent: '控制器不同意图 B',
              createCommandId: () => 'must-not-replace-b',
            )
            .commandId,
        fourthService.requests.single.clientCommandId,
      );
      await third.stop();
      await fourth.stop();
    },
  );

  test(
    'old commit ownership cannot roll back a newer same-id message',
    () async {
      final repository = InMemoryChatMessageRepository();
      const message = ChatMessageProjection(
        id: 'stable-answer',
        kind: ChatMessageKind.agentText,
        text: '答案',
      );
      final oldToken = ChatMessageCommitToken('old-owner');
      final oldCommit = await repository.appendIf(
        'conversation-data',
        message,
        oldToken,
        () => true,
      );
      oldToken.invalidate();
      final newToken = ChatMessageCommitToken('new-owner');
      await repository.appendIf(
        'conversation-data',
        message,
        newToken,
        () => true,
      );

      final rollback = await repository.rollbackOwned(
        'conversation-data',
        oldCommit,
      );

      expect(rollback, ChatMessageRollbackDisposition.ownershipMismatch);
      expect(await repository.load('conversation-data'), [message]);
    },
  );

  test(
    'existing answer id requires exact dispatch claim and content',
    () async {
      final repository = InMemoryChatMessageRepository();
      final firstToken = ChatMessageCommitToken('commit-a', generation: 1);
      final secondToken = ChatMessageCommitToken('commit-b', generation: 2);
      const first = ChatMessageProjection(
        id: 'command-existing-answer:answer',
        kind: ChatMessageKind.agentText,
        text: 'owner A answer',
        dispatchClaimOwner: 'controller-a',
        dispatchClaimGeneration: 1,
      );
      const second = ChatMessageProjection(
        id: 'command-existing-answer:answer',
        kind: ChatMessageKind.agentText,
        text: 'owner B answer',
        dispatchClaimOwner: 'controller-b',
        dispatchClaimGeneration: 2,
      );
      expect(
        (await repository.appendIf(
          'conversation-data',
          first,
          firstToken,
          () => true,
        )).committed,
        isTrue,
      );

      final mismatched = await repository.appendIf(
        'conversation-data',
        second,
        secondToken,
        () => true,
      );

      expect(mismatched.committed, isFalse);
      expect(
        (await repository.load('conversation-data')).single.text,
        'owner A answer',
      );
    },
  );

  test('user message id is idempotent only for exact content', () async {
    final repository = InMemoryChatMessageRepository();
    const original = ChatMessageProjection(
      id: 'command-user-cas:user',
      kind: ChatMessageKind.userText,
      text: '原始用户意图',
    );
    const conflicting = ChatMessageProjection(
      id: 'command-user-cas:user',
      kind: ChatMessageKind.userText,
      text: '被替换的用户意图',
    );

    await repository.append('conversation-data', original);
    await repository.append('conversation-data', original);

    expect(
      () => repository.append('conversation-data', conflicting),
      throwsStateError,
    );
    final messages = await repository.load('conversation-data');
    expect(messages, hasLength(1));
    expect(messages.single.text, '原始用户意图');
  });

  test(
    'unsafe evidence set fails closed instead of filtering attacks',
    () async {
      final attacks = <String>[
        'http://example.com/report',
        'javascript:alert(1)',
        'data:text/plain,secret',
        'file:///private/secret',
        'https://user:password@example.com/report',
        'https://example.com/report?token=secret',
        'https://example.com/report?',
        'https://example.com:443/report',
        'https://例子.测试/report',
        'https://xn--fsqu00a.xn--0zwm56d/report',
        'https://example.com/report#claim',
        'https://example.com/report#',
        'https://localhost/report',
        'https://127.0.0.1/report',
        'https://example.com./report',
        'https://%65xample.com/report',
      ];

      for (final attack in attacks) {
        final service = _FakeConversationApplicationService();
        final controller = SingleChatController(
          conversationId: 'conversation-data',
          expertId: 'data-analyst',
          service: service,
          repository: InMemoryChatMessageRepository(),
          commandIdFactory: () => 'command-evidence-${attacks.indexOf(attack)}',
        );
        await controller.initialize();
        final submission = controller.submit('攻击证据');
        await Future<void>.delayed(Duration.zero);
        service.completeNext(
          SingleAgentRunOutcome.completed(
            answer: '不可核验',
            sourceType: ChatMessageSourceType.verifiedEvidence,
            uncertainty: '存在限制',
            evidenceReferences: ['https://example.com/safe', attack],
          ),
        );
        await submission;

        expect(
          controller.state.messages.last.evidenceReferences,
          isEmpty,
          reason: attack,
        );
      }
    },
  );

  test(
    'synchronous command reservation failure is a bounded UI state',
    () async {
      final controller = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: _FakeConversationApplicationService(),
        repository: InMemoryChatMessageRepository(
          commandOutbox: _ThrowingReserveOutbox(),
        ),
        commandIdFactory: () => 'command-never-created',
      );
      await controller.initialize();

      await expectLater(controller.submit('安全失败'), completes);

      expect(controller.state.status, SingleChatRunStatus.failed);
      expect(controller.state.canRetry, isFalse);
    },
  );

  test(
    'reserve failure after completion never revives the prior command',
    () async {
      final service = _FakeConversationApplicationService();
      final controller = SingleChatController(
        conversationId: 'conversation-data',
        expertId: 'data-analyst',
        service: service,
        repository: InMemoryChatMessageRepository(
          commandOutbox: _FailSecondReserveOutbox(),
        ),
        commandIdFactory: () => 'command-prior',
      );
      await controller.initialize();
      final first = controller.submit('相同文本');
      await Future<void>.delayed(Duration.zero);
      service.completeNext(
        const SingleAgentRunOutcome.completed(answer: '第一次已完成'),
      );
      await first;

      await controller.submit('相同文本');
      await controller.retry();

      expect(controller.state.status, SingleChatRunStatus.failed);
      expect(controller.state.canRetry, isFalse);
      expect(controller.activeText, isNull);
      expect(service.requests, hasLength(1));
    },
  );

  test(
    'streaming partials update state.streamingAnswer and clear on completion',
    () async {
      final service = _StreamingSingleChatPort();
      // Real clock on purpose: the repository's dispatch-claim lease also uses
      // wall time, and a fake near-zero clock makes every commit look expired.
      // The asserts read state directly, so notify throttling is irrelevant.
      final controller = SingleChatController(
        conversationId: 'conversation-stream',
        expertId: 'data-analyst',
        service: service,
        repository: InMemoryChatMessageRepository(),
        commandIdFactory: () => 'command-stream',
      );
      await controller.initialize();

      final submission = controller.submit('流式预览');
      await pumpEventQueue();
      expect(controller.state.status, SingleChatRunStatus.running);
      expect(controller.state.streamingAnswer, isEmpty);

      service.partials.add('先把');
      await pumpEventQueue();
      expect(controller.state.streamingAnswer, '先把');

      service.partials.add('先把需求澄清');
      await pumpEventQueue();
      expect(controller.state.streamingAnswer, '先把需求澄清');

      service.complete(
        const SingleAgentRunOutcome.completed(
          answer: '先把需求澄清清楚。',
          sourceType: ChatMessageSourceType.modelOutput,
        ),
      );
      await submission;

      expect(controller.state.status, SingleChatRunStatus.completed);
      expect(controller.state.streamingAnswer, isEmpty);
      expect(controller.state.messages.last.text, '先把需求澄清清楚。');
      controller.dispose();
    },
  );

  test(
    'streaming notifications are throttled by the 100ms timestamp check',
    () async {
      final service = _StreamingSingleChatPort();
      final controller = SingleChatController(
        conversationId: 'conversation-stream-throttle',
        expertId: 'data-analyst',
        service: service,
        repository: InMemoryChatMessageRepository(),
        commandIdFactory: () => 'command-stream-throttle',
        // A frozen clock: the first partial notifies (1000 - 0 >= 100), every
        // later one within the same instant does not.
        nowEpochMs: () => 1000,
      );
      await controller.initialize();

      unawaited(controller.submit('限流预览'));
      await pumpEventQueue();
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      service.partials
        ..add('部')
        ..add('部分')
        ..add('部分回答');
      await pumpEventQueue();

      expect(notifications, 1);
      // The state still tracks the latest snapshot even when unnotified.
      expect(controller.state.streamingAnswer, '部分回答');
      await controller.stop();
      expect(controller.state.streamingAnswer, isEmpty);
      controller.dispose();
    },
  );

  test('stop clears the streaming preview and unsubscribes', () async {
    final service = _StreamingSingleChatPort();
    var epochMs = 0;
    final controller = SingleChatController(
      conversationId: 'conversation-stream-stop',
      expertId: 'data-analyst',
      service: service,
      repository: InMemoryChatMessageRepository(),
      commandIdFactory: () => 'command-stream-stop',
      nowEpochMs: () => epochMs += 1000,
    );
    await controller.initialize();

    final submission = controller.submit('停止流');
    await pumpEventQueue();
    service.partials.add('中途');
    await pumpEventQueue();
    expect(controller.state.streamingAnswer, '中途');

    await controller.stop();
    expect(controller.state.status, SingleChatRunStatus.stopped);
    expect(controller.state.streamingAnswer, isEmpty);

    // Late partials after stop can no longer touch state.
    service.partials.add('迟到的片段');
    await pumpEventQueue();
    expect(controller.state.streamingAnswer, isEmpty);

    service.complete(
      const SingleAgentRunOutcome.completed(answer: '不应展示的迟到回复'),
    );
    await submission;
    expect(controller.state.streamingAnswer, isEmpty);
    controller.dispose();
  });
}

class _StreamingSingleChatPort implements SingleChatPort {
  final partials = StreamController<String>.broadcast();
  final _outcome = Completer<SingleAgentRunOutcome>();
  final stoppedRunIds = <String>[];

  @override
  Future<SingleAgentRunHandle> startSingleAgentRun(
    StartSingleAgentRunRequest request,
  ) async {
    return SingleAgentRunHandle(
      runId: 'run-streaming',
      outcome: _outcome.future,
      partialAnswers: partials.stream,
    );
  }

  void complete(SingleAgentRunOutcome outcome) => _outcome.complete(outcome);

  @override
  Future<void> stopSingleAgentRun(String runId) async {
    stoppedRunIds.add(runId);
  }
}

class _FakeConversationApplicationService
    implements ConversationApplicationService {
  _FakeConversationApplicationService({this.throwOnStop = false});

  final bool throwOnStop;
  final requests = <StartSingleAgentRunRequest>[];
  final stoppedRunIds = <String>[];
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
  Future<void> stopSingleAgentRun(String runId) async {
    if (throwOnStop) {
      throw StateError('sensitive upstream stop error');
    }
    stoppedRunIds.add(runId);
  }
}

class _ProgressSingleChatPort implements SingleChatPort {
  final progress = StreamController<GenerationProgress>.broadcast();
  final _outcome = Completer<SingleAgentRunOutcome>();

  @override
  Future<SingleAgentRunHandle> startSingleAgentRun(
    StartSingleAgentRunRequest request,
  ) async => SingleAgentRunHandle(
    runId: 'run-progress',
    outcome: _outcome.future,
    generationProgress: progress.stream,
  );

  void complete(SingleAgentRunOutcome outcome) => _outcome.complete(outcome);

  @override
  Future<void> stopSingleAgentRun(String runId) async {}
}

class _DelayedStartSingleChatPort implements SingleChatPort {
  final stoppedRunIds = <String>[];
  final _start = Completer<void>();
  final _outcome = Completer<SingleAgentRunOutcome>();
  final _started = Completer<void>();
  Future<void> get started => _started.future;

  @override
  Future<SingleAgentRunHandle> startSingleAgentRun(
    StartSingleAgentRunRequest request,
  ) async {
    _started.complete();
    await _start.future;
    return SingleAgentRunHandle(runId: 'run-delayed', outcome: _outcome.future);
  }

  void releaseStart() => _start.complete();

  void complete(SingleAgentRunOutcome outcome) => _outcome.complete(outcome);

  @override
  Future<void> stopSingleAgentRun(String runId) async {
    stoppedRunIds.add(runId);
  }
}

class _DelayedStopSingleChatPort implements SingleChatPort {
  final _outcome = Completer<SingleAgentRunOutcome>();
  final _started = Completer<void>();
  final _stopRequested = Completer<void>();
  final _releaseStop = Completer<void>();

  Future<void> get started => _started.future;
  Future<void> get stopRequested => _stopRequested.future;

  @override
  Future<SingleAgentRunHandle> startSingleAgentRun(
    StartSingleAgentRunRequest request,
  ) async {
    _started.complete();
    return SingleAgentRunHandle(
      runId: 'run-delayed-stop',
      outcome: _outcome.future,
    );
  }

  void releaseStop() {
    _releaseStop.complete();
    _outcome.complete(
      const SingleAgentRunOutcome.failed(
        failure: SingleAgentRunFailure.retryable,
      ),
    );
  }

  @override
  Future<void> stopSingleAgentRun(String runId) async {
    if (!_stopRequested.isCompleted) {
      _stopRequested.complete();
    }
    await _releaseStop.future;
  }
}

class _DelayedAnswerRepository extends InMemoryChatMessageRepository {
  final _answerAppendStarted = Completer<void>();
  final _releaseAnswerAppend = Completer<void>();

  Future<void> get answerAppendStarted => _answerAppendStarted.future;

  void releaseAnswerAppend() => _releaseAnswerAppend.complete();

  @override
  Future<ChatMessageCommitResult> appendIf(
    String conversationId,
    ChatMessageProjection message,
    ChatMessageCommitToken token,
    bool Function() shouldAppend,
  ) async {
    if (message.kind == ChatMessageKind.agentText) {
      _answerAppendStarted.complete();
      await _releaseAnswerAppend.future;
    }
    return super.appendIf(conversationId, message, token, shouldAppend);
  }
}

class _RefusingAnswerRepository extends InMemoryChatMessageRepository {
  @override
  Future<ChatMessageCommitResult> appendIf(
    String conversationId,
    ChatMessageProjection message,
    ChatMessageCommitToken token,
    bool Function() shouldAppend,
  ) async {
    return ChatMessageCommitResult(
      messageId: message.id,
      committed: false,
      inserted: false,
      ownerId: token.value,
      ownerGeneration: token.generation,
    );
  }
}

class _CommittedButDelayedReturnRepository
    extends InMemoryChatMessageRepository {
  _CommittedButDelayedReturnRepository({super.commandOutbox});

  final _answerCommitted = Completer<void>();
  final _releaseAppendReturn = Completer<void>();

  Future<void> get answerCommitted => _answerCommitted.future;

  void releaseAppendReturn() => _releaseAppendReturn.complete();

  @override
  Future<ChatMessageCommitResult> appendIf(
    String conversationId,
    ChatMessageProjection message,
    ChatMessageCommitToken token,
    bool Function() shouldAppend,
  ) async {
    final appended = await super.appendIf(
      conversationId,
      message,
      token,
      shouldAppend,
    );
    if (message.kind == ChatMessageKind.agentText) {
      _answerCommitted.complete();
      await _releaseAppendReturn.future;
    }
    return appended;
  }
}

class _FailingRollbackRepository extends _CommittedButDelayedReturnRepository {
  @override
  Future<ChatMessageRollbackDisposition> rollbackOwned(
    String conversationId,
    ChatMessageCommitResult commit,
  ) {
    throw StateError('simulated durable rollback failure');
  }
}

class _ThrowingTerminalOutbox extends InMemorySingleChatCommandOutbox {
  @override
  void markTerminal(
    String conversationId,
    String commandId,
    SingleChatCommandStatus status, {
    SingleChatDispatchClaim? dispatchClaim,
    bool reconcilePersistedAnswer = false,
  }) {
    if (status == SingleChatCommandStatus.stopped) {
      throw StateError('simulated outbox persistence failure');
    }
    super.markTerminal(
      conversationId,
      commandId,
      status,
      dispatchClaim: dispatchClaim,
      reconcilePersistedAnswer: reconcilePersistedAnswer,
    );
  }
}

class _ThrowingCompletedOnceOutbox extends InMemorySingleChatCommandOutbox {
  var _remainingFailures = 1;

  @override
  void markTerminal(
    String conversationId,
    String commandId,
    SingleChatCommandStatus status, {
    SingleChatDispatchClaim? dispatchClaim,
    bool reconcilePersistedAnswer = false,
  }) {
    if (status == SingleChatCommandStatus.completed &&
        _remainingFailures-- > 0) {
      throw StateError('simulated completed terminal failure');
    }
    super.markTerminal(
      conversationId,
      commandId,
      status,
      dispatchClaim: dispatchClaim,
      reconcilePersistedAnswer: reconcilePersistedAnswer,
    );
  }
}

class _CommitThenThrowCompletedOutbox extends InMemorySingleChatCommandOutbox {
  var _didThrow = false;

  @override
  void markTerminal(
    String conversationId,
    String commandId,
    SingleChatCommandStatus status, {
    SingleChatDispatchClaim? dispatchClaim,
    bool reconcilePersistedAnswer = false,
  }) {
    super.markTerminal(
      conversationId,
      commandId,
      status,
      dispatchClaim: dispatchClaim,
      reconcilePersistedAnswer: reconcilePersistedAnswer,
    );
    if (status == SingleChatCommandStatus.completed && !_didThrow) {
      _didThrow = true;
      throw StateError('simulated lost terminal acknowledgement');
    }
  }
}

class _CommitThenThrowAnswerRepository extends InMemoryChatMessageRepository {
  var _didThrow = false;

  @override
  Future<ChatMessageCommitResult> appendIf(
    String conversationId,
    ChatMessageProjection message,
    ChatMessageCommitToken token,
    bool Function() shouldAppend,
  ) async {
    final result = await super.appendIf(
      conversationId,
      message,
      token,
      shouldAppend,
    );
    if (message.kind == ChatMessageKind.agentText && !_didThrow) {
      _didThrow = true;
      throw StateError('simulated answer commit acknowledgement loss');
    }
    return result;
  }
}

class _ThrowingReserveOutbox extends InMemorySingleChatCommandOutbox {
  @override
  SingleChatCommandRecord reserve({
    required String conversationId,
    required String normalizedIntent,
    required String Function() createCommandId,
  }) {
    throw StateError('simulated reserve failure');
  }
}

class _FailSecondReserveOutbox extends InMemorySingleChatCommandOutbox {
  var _reservations = 0;

  @override
  SingleChatCommandRecord reserve({
    required String conversationId,
    required String normalizedIntent,
    required String Function() createCommandId,
  }) {
    _reservations += 1;
    if (_reservations == 2) {
      throw StateError('simulated second reserve failure');
    }
    return super.reserve(
      conversationId: conversationId,
      normalizedIntent: normalizedIntent,
      createCommandId: createCommandId,
    );
  }
}

class _RecordingOutboxStoragePolicy implements SingleChatOutboxStoragePolicy {
  final preparedDirectories = <String>[];
  final protectedPaths = <String>[];
  final syncedDirectories = <String>[];

  @override
  void prepareDirectory(Directory directory) {
    preparedDirectories.add(directory.absolute.path);
    directory.createSync(recursive: true);
  }

  @override
  void protectAndExcludeFromBackup(File file) {
    protectedPaths.add(file.absolute.path);
  }

  @override
  void syncDirectory(Directory directory) {
    syncedDirectories.add(directory.absolute.path);
  }
}

class _ThrowingChatMessageRepository extends InMemoryChatMessageRepository {
  _ThrowingChatMessageRepository({
    this.throwOnLoad = false,
    this.throwOnAppend = false,
    this.failedAppends = 0,
  }) : _remainingFailedAppends = failedAppends;

  final bool throwOnLoad;
  final bool throwOnAppend;
  final int failedAppends;
  int _remainingFailedAppends;

  @override
  Future<List<ChatMessageProjection>> load(String conversationId) {
    if (throwOnLoad) {
      throw StateError('sensitive database load error');
    }
    return super.load(conversationId);
  }

  @override
  Future<void> append(String conversationId, ChatMessageProjection message) {
    if (throwOnAppend || _remainingFailedAppends-- > 0) {
      throw StateError('sensitive database write error');
    }
    return super.append(conversationId, message);
  }
}

class _DelayedLoadRepository extends InMemoryChatMessageRepository {
  final _release = Completer<void>();

  void releaseLoad() => _release.complete();

  @override
  Future<List<ChatMessageProjection>> load(String conversationId) async {
    await _release.future;
    return const [];
  }
}

class _DelayedUserAppendRepository extends InMemoryChatMessageRepository {
  final _userAppendStarted = Completer<void>();
  final _releaseUserAppend = Completer<void>();

  Future<void> get userAppendStarted => _userAppendStarted.future;

  void releaseUserAppend() => _releaseUserAppend.complete();

  @override
  Future<void> append(
    String conversationId,
    ChatMessageProjection message,
  ) async {
    if (message.kind == ChatMessageKind.userText) {
      _userAppendStarted.complete();
      await _releaseUserAppend.future;
    }
    await super.append(conversationId, message);
  }
}

class _DelayedFailingLoadRepository extends InMemoryChatMessageRepository {
  final _load = Completer<List<ChatMessageProjection>>();

  void failLoad() {
    _load.completeError(StateError('sensitive delayed history failure'));
  }

  @override
  Future<List<ChatMessageProjection>> load(String conversationId) {
    return _load.future;
  }
}

class _FailingDelayedStartPort implements SingleChatPort {
  final _handle = Completer<SingleAgentRunHandle>();
  final _started = Completer<void>();

  Future<void> get started => _started.future;

  @override
  Future<SingleAgentRunHandle> startSingleAgentRun(
    StartSingleAgentRunRequest request,
  ) {
    _started.complete();
    return _handle.future;
  }

  void failStart() {
    _handle.completeError(StateError('sensitive upstream start error'));
  }

  @override
  Future<void> stopSingleAgentRun(String runId) async {}
}
