import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/orchestration/basic_durable_runner.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';
import 'package:halo_mobile/orchestration/run_event_store.dart';

void main() {
  test('auto freezes one or two selected current group members', () async {
    final runner = BasicDurableRunner(
      store: InMemoryRunEventStore(),
      selector: const _FixedSelector([
        'technical-architect',
        'product-manager',
      ]),
      runtime: const _EchoRuntime(),
    );

    final handle = await runner.startRun(
      const StartConversationRunCommand(
        clientCommandId: 'command-auto',
        conversationId: 'group-product',
        hostAgentId: 'product-manager',
        input: '评估 iOS MVP',
        replyMode: ConversationReplyMode.auto,
        memberAgentIds: [
          'product-manager',
          'technical-architect',
          'growth-advisor',
        ],
      ),
    );
    final events = await _collectCompletedRun(runner, handle.runId);
    final selection = events.singleWhere(
      (event) => event.type == OrchestrationEventType.agentsSelected,
    );
    final respondingAgents = events
        .where(
          (event) => event.type == OrchestrationEventType.agentMessageCompleted,
        )
        .map((event) => event.agentId)
        .toList();

    expect(selection.selectedAgentIds, [
      'technical-architect',
      'product-manager',
    ]);
    expect(respondingAgents, selection.selectedAgentIds);
    expect(
      selection.selectedAgentIds.every(
        const [
          'product-manager',
          'technical-architect',
          'growth-advisor',
        ].contains,
      ),
      isTrue,
    );
  });

  test('duplicate client command returns the existing run', () async {
    final runner = BasicDurableRunner(
      store: InMemoryRunEventStore(),
      selector: const _FixedSelector(['product-manager']),
      runtime: const _EchoRuntime(),
    );
    const command = StartConversationRunCommand(
      clientCommandId: 'command-idempotent',
      conversationId: 'group-product',
      hostAgentId: 'product-manager',
      input: '压缩 MVP',
      replyMode: ConversationReplyMode.auto,
      memberAgentIds: ['product-manager'],
    );

    final first = await runner.startRun(command);
    final second = await runner.startRun(command);
    await _collectCompletedRun(runner, first.runId);

    expect(second.runId, first.runId);
    final replay = await runner.watchRun(first.runId).take(8).toList();
    expect(
      replay.where((event) => event.type == OrchestrationEventType.runCreated),
      hasLength(1),
    );
  });

  test('mentioned mode executes only the named current member', () async {
    final runner = BasicDurableRunner(
      store: InMemoryRunEventStore(),
      selector: const _FixedSelector(['product-manager']),
      runtime: const _EchoRuntime(),
    );

    final handle = await runner.startRun(
      const StartConversationRunCommand(
        clientCommandId: 'command-mentioned',
        conversationId: 'group-product',
        hostAgentId: 'product-manager',
        input: '只检查工程风险',
        replyMode: ConversationReplyMode.mentioned,
        memberAgentIds: [
          'product-manager',
          'technical-architect',
          'growth-advisor',
        ],
        mentionedAgentIds: ['technical-architect'],
      ),
    );
    final events = await _collectCompletedRun(runner, handle.runId);

    expect(
      events
          .where(
            (event) =>
                event.type == OrchestrationEventType.agentMessageCompleted,
          )
          .map((event) => event.agentId),
      ['technical-architect'],
    );
  });

  test(
    'all mode preserves member order and completes with a summary',
    () async {
      final runner = BasicDurableRunner(
        store: InMemoryRunEventStore(),
        selector: const _FixedSelector(['growth-advisor']),
        runtime: const _EchoRuntime(),
      );
      const members = [
        'product-manager',
        'technical-architect',
        'growth-advisor',
      ];

      final handle = await runner.startRun(
        const StartConversationRunCommand(
          clientCommandId: 'command-all',
          conversationId: 'group-product',
          hostAgentId: 'product-manager',
          input: '大家讨论这个 MVP',
          replyMode: ConversationReplyMode.all,
          memberAgentIds: members,
        ),
      );
      final events = await _collectCompletedRun(runner, handle.runId);

      expect(
        events
            .where(
              (event) =>
                  event.type == OrchestrationEventType.agentMessageCompleted,
            )
            .map((event) => event.agentId),
        members,
      );
      expect(
        events
            .where((event) => event.type == OrchestrationEventType.stageChanged)
            .map((event) => event.stage),
        containsAllInOrder([
          ConversationStage.collectingOpinions,
          ConversationStage.crossDiscussion,
          ConversationStage.summarizing,
          ConversationStage.completed,
        ]),
      );
      expect(
        events
            .singleWhere(
              (event) => event.type == OrchestrationEventType.summaryCompleted,
            )
            .text,
        contains('product-manager:大家讨论这个 MVP'),
      );
    },
  );

  test('all mode keeps completed opinions when one member fails', () async {
    final runner = BasicDurableRunner(
      store: InMemoryRunEventStore(),
      selector: const _FixedSelector(['product-manager']),
      runtime: const _FailingRuntime('technical-architect'),
    );

    final handle = await runner.startRun(
      const StartConversationRunCommand(
        clientCommandId: 'command-partial',
        conversationId: 'group-product',
        hostAgentId: 'product-manager',
        input: '大家讨论恢复策略',
        replyMode: ConversationReplyMode.all,
        memberAgentIds: [
          'product-manager',
          'technical-architect',
          'growth-advisor',
        ],
      ),
    );
    final events = await _collectCompletedRun(runner, handle.runId);

    expect(
      events
          .where(
            (event) =>
                event.type == OrchestrationEventType.agentMessageCompleted,
          )
          .map((event) => event.agentId),
      ['product-manager', 'growth-advisor'],
    );
    expect(
      events
          .singleWhere(
            (event) => event.type == OrchestrationEventType.agentMessageFailed,
          )
          .agentId,
      'technical-architect',
    );
    expect(events.last.type, OrchestrationEventType.runCompleted);
  });

  test('single-agent failure closes the message with a safe error', () async {
    final runner = BasicDurableRunner(
      store: InMemoryRunEventStore(),
      selector: const _FixedSelector(['product-manager']),
      runtime: const _FailingRuntime('product-manager'),
    );

    final handle = await runner.startRun(
      const StartConversationRunCommand(
        clientCommandId: 'command-safe-failure',
        conversationId: 'group-product',
        hostAgentId: 'product-manager',
        input: '分析风险',
        replyMode: ConversationReplyMode.auto,
        memberAgentIds: ['product-manager'],
      ),
    );
    final events = await _collectCompletedRun(runner, handle.runId);
    final failedMessage = events.singleWhere(
      (event) => event.type == OrchestrationEventType.agentMessageFailed,
    );
    final failedRun = events.singleWhere(
      (event) => event.type == OrchestrationEventType.runFailed,
    );

    expect(failedMessage.errorCode, 'agent_runtime_failed');
    expect(failedMessage.text, isNot(contains('runtime unavailable')));
    expect(failedRun.text, isNot(contains('runtime unavailable')));
  });

  test('selector failure falls back to the frozen group host', () async {
    final runner = BasicDurableRunner(
      store: InMemoryRunEventStore(),
      selector: const _ThrowingSelector(),
      runtime: const _EchoRuntime(),
    );

    final handle = await runner.startRun(
      const StartConversationRunCommand(
        clientCommandId: 'command-selector-fallback',
        conversationId: 'group-product',
        hostAgentId: 'product-manager',
        input: '分析风险',
        replyMode: ConversationReplyMode.auto,
        memberAgentIds: ['technical-architect', 'product-manager'],
      ),
    );
    final events = await _collectCompletedRun(runner, handle.runId);

    expect(
      events
          .singleWhere(
            (event) => event.type == OrchestrationEventType.agentsSelected,
          )
          .selectedAgentIds,
      ['product-manager'],
    );
    expect(events.last.type, OrchestrationEventType.runCompleted);
  });

  test('invalid selector output falls back to the frozen group host', () async {
    final runner = BasicDurableRunner(
      store: InMemoryRunEventStore(),
      selector: const _FixedSelector(['outsider']),
      runtime: const _EchoRuntime(),
    );

    final handle = await runner.startRun(
      const StartConversationRunCommand(
        clientCommandId: 'command-invalid-selector-fallback',
        conversationId: 'group-product',
        hostAgentId: 'product-manager',
        input: '分析风险',
        replyMode: ConversationReplyMode.auto,
        memberAgentIds: ['technical-architect', 'product-manager'],
      ),
    );
    final events = await _collectCompletedRun(runner, handle.runId);

    expect(
      events
          .singleWhere(
            (event) => event.type == OrchestrationEventType.agentsSelected,
          )
          .selectedAgentIds,
      ['product-manager'],
    );
  });

  test(
    'run freezes caller member lists before asynchronous selection',
    () async {
      final members = ['product-manager', 'technical-architect'];
      final selector = _InspectingSelector();
      final runner = BasicDurableRunner(
        store: InMemoryRunEventStore(),
        selector: selector,
        runtime: const _EchoRuntime(),
      );

      final handle = await runner.startRun(
        StartConversationRunCommand(
          clientCommandId: 'command-frozen-members',
          conversationId: 'group-product',
          hostAgentId: 'product-manager',
          input: '分析风险',
          replyMode: ConversationReplyMode.auto,
          memberAgentIds: members,
        ),
      );
      members
        ..clear()
        ..add('outsider');
      final events = await _collectCompletedRun(runner, handle.runId);

      expect(selector.candidates, ['product-manager', 'technical-architect']);
      expect(selector.mutationWasRejected, isTrue);
      expect(
        events
            .singleWhere(
              (event) => event.type == OrchestrationEventType.agentsSelected,
            )
            .selectedAgentIds,
        ['product-manager'],
      );
    },
  );

  test('all-mode summary receives successful and failed outcomes', () async {
    final runtime = _CapturingSummaryRuntime('technical-architect');
    final runner = BasicDurableRunner(
      store: InMemoryRunEventStore(),
      selector: const _FixedSelector(['product-manager']),
      runtime: runtime,
    );

    final handle = await runner.startRun(
      const StartConversationRunCommand(
        clientCommandId: 'command-summary-outcomes',
        conversationId: 'group-product',
        hostAgentId: 'product-manager',
        input: '大家讨论',
        replyMode: ConversationReplyMode.all,
        memberAgentIds: ['product-manager', 'technical-architect'],
      ),
    );
    await _collectCompletedRun(runner, handle.runId);

    expect(runtime.outcomes.map((outcome) => outcome.agentId), [
      'product-manager',
      'technical-architect',
    ]);
    expect(runtime.outcomes.last.errorCode, 'agent_runtime_failed');
  });

  test('watchRun replays only events after the requested sequence', () async {
    final runner = BasicDurableRunner(
      store: InMemoryRunEventStore(),
      selector: const _FixedSelector(['product-manager']),
      runtime: const _EchoRuntime(),
    );
    final handle = await runner.startRun(
      const StartConversationRunCommand(
        clientCommandId: 'command-after-seq',
        conversationId: 'group-product',
        hostAgentId: 'product-manager',
        input: '分析风险',
        replyMode: ConversationReplyMode.auto,
        memberAgentIds: ['product-manager'],
      ),
    );
    final allEvents = await _collectCompletedRun(runner, handle.runId);
    final replay = await runner
        .watchRun(handle.runId, afterSeq: 3)
        .take(allEvents.length - 3)
        .toList();

    expect(
      replay.map((event) => event.seq),
      allEvents.skip(3).map((e) => e.seq),
    );
  });

  test('stop during an agent call prevents a later completion', () async {
    final runtime = _BlockingRuntime();
    final runner = BasicDurableRunner(
      store: InMemoryRunEventStore(),
      selector: const _FixedSelector(['product-manager']),
      runtime: runtime,
    );

    final handle = await runner.startRun(
      const StartConversationRunCommand(
        clientCommandId: 'command-stop',
        conversationId: 'group-product',
        hostAgentId: 'product-manager',
        input: '开始分析',
        replyMode: ConversationReplyMode.auto,
        memberAgentIds: ['product-manager'],
      ),
    );
    await runner
        .watchRun(handle.runId)
        .firstWhere(
          (event) => event.type == OrchestrationEventType.agentMessageStarted,
        );
    await runner.requestStop(handle.runId);
    runtime.complete('迟到的回复');
    await Future<void>.delayed(Duration.zero);

    final snapshot = await runner.getRun(handle.runId);
    final replay = await runner
        .watchRun(handle.runId)
        .take(snapshot.lastSeq)
        .toList();

    expect(snapshot.status, OrchestrationRunStatus.stopped);
    expect(
      replay.where(
        (event) => event.type == OrchestrationEventType.runCompleted,
      ),
      isEmpty,
    );
  });

  test(
    'immediate stop is terminal before scheduled execution starts',
    () async {
      final runner = BasicDurableRunner(
        store: InMemoryRunEventStore(),
        selector: const _FixedSelector(['product-manager']),
        runtime: const _EchoRuntime(),
      );
      final handle = await runner.startRun(
        const StartConversationRunCommand(
          clientCommandId: 'command-immediate-stop',
          conversationId: 'group-product',
          hostAgentId: 'product-manager',
          input: '开始分析',
          replyMode: ConversationReplyMode.auto,
          memberAgentIds: ['product-manager'],
        ),
      );

      await runner.requestStop(handle.runId);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final snapshot = await runner.getRun(handle.runId);
      final replay = await runner
          .watchRun(handle.runId)
          .take(snapshot.lastSeq)
          .toList();
      final stoppedIndex = replay.indexWhere(
        (event) => event.type == OrchestrationEventType.runStopped,
      );
      expect(snapshot.status, OrchestrationRunStatus.stopped);
      expect(stoppedIndex, isNonNegative);
      expect(replay.skip(stoppedIndex + 1), isEmpty);
    },
  );

  test('stop while selector is blocked prevents selection events', () async {
    final selector = _BlockingSelector();
    final runner = BasicDurableRunner(
      store: InMemoryRunEventStore(),
      selector: selector,
      runtime: const _EchoRuntime(),
    );
    final handle = await runner.startRun(
      const StartConversationRunCommand(
        clientCommandId: 'command-selector-stop',
        conversationId: 'group-product',
        hostAgentId: 'product-manager',
        input: '开始分析',
        replyMode: ConversationReplyMode.auto,
        memberAgentIds: ['product-manager'],
      ),
    );
    await runner
        .watchRun(handle.runId)
        .firstWhere(
          (event) => event.stage == ConversationStage.selectingAgents,
        );

    await runner.requestStop(handle.runId);
    selector.complete(['product-manager']);
    await Future<void>.delayed(Duration.zero);

    final snapshot = await runner.getRun(handle.runId);
    final replay = await runner
        .watchRun(handle.runId)
        .take(snapshot.lastSeq)
        .toList();
    expect(snapshot.status, OrchestrationRunStatus.stopped);
    expect(
      replay.where(
        (event) => event.type == OrchestrationEventType.agentsSelected,
      ),
      isEmpty,
    );
  });

  test('stop while summary is blocked prevents summary completion', () async {
    final runtime = _BlockingSummaryRuntime();
    final runner = BasicDurableRunner(
      store: InMemoryRunEventStore(),
      selector: const _FixedSelector(['product-manager']),
      runtime: runtime,
    );
    final handle = await runner.startRun(
      const StartConversationRunCommand(
        clientCommandId: 'command-summary-stop',
        conversationId: 'group-product',
        hostAgentId: 'product-manager',
        input: '大家讨论',
        replyMode: ConversationReplyMode.all,
        memberAgentIds: ['product-manager'],
      ),
    );
    await runner
        .watchRun(handle.runId)
        .firstWhere((event) => event.stage == ConversationStage.summarizing);

    await runner.requestStop(handle.runId);
    runtime.complete('迟到的总结');
    await Future<void>.delayed(Duration.zero);

    final snapshot = await runner.getRun(handle.runId);
    final replay = await runner
        .watchRun(handle.runId)
        .take(snapshot.lastSeq)
        .toList();
    expect(snapshot.status, OrchestrationRunStatus.stopped);
    expect(
      replay.where(
        (event) => event.type == OrchestrationEventType.summaryCompleted,
      ),
      isEmpty,
    );
    expect(
      replay.where(
        (event) => event.type == OrchestrationEventType.runCompleted,
      ),
      isEmpty,
    );
  });
}

Future<List<OrchestrationEvent>> _collectCompletedRun(
  BasicDurableRunner runner,
  String runId,
) async {
  final events = <OrchestrationEvent>[];
  await for (final event
      in runner.watchRun(runId).timeout(const Duration(seconds: 2))) {
    events.add(event);
    if (event.type == OrchestrationEventType.runCompleted ||
        event.type == OrchestrationEventType.runFailed) {
      break;
    }
  }
  return events;
}

class _FixedSelector implements AgentSelector {
  const _FixedSelector(this.selected);

  final List<String> selected;

  @override
  Future<List<String>> select(AgentSelectionRequest request) async => selected;
}

class _ThrowingSelector implements AgentSelector {
  const _ThrowingSelector();

  @override
  Future<List<String>> select(AgentSelectionRequest request) {
    throw StateError('provider leaked secret');
  }
}

class _InspectingSelector implements AgentSelector {
  List<String> candidates = const [];
  bool mutationWasRejected = false;

  @override
  Future<List<String>> select(AgentSelectionRequest request) async {
    candidates = List.of(request.candidateAgentIds);
    try {
      request.candidateAgentIds.add('outsider');
    } on UnsupportedError {
      mutationWasRejected = true;
    }
    return [request.candidateAgentIds.first];
  }
}

class _EchoRuntime implements AgentRuntime {
  const _EchoRuntime();

  @override
  Future<String> respond(AgentTurnRequest request) async {
    return '${request.agentId}:${request.input}';
  }

  @override
  Future<String> summarize(DiscussionSummaryRequest request) async {
    return request.responses.join('|');
  }
}

class _FailingRuntime extends _EchoRuntime {
  const _FailingRuntime(this.failedAgentId);

  final String failedAgentId;

  @override
  Future<String> respond(AgentTurnRequest request) {
    if (request.agentId == failedAgentId) {
      throw StateError('runtime unavailable');
    }
    return super.respond(request);
  }
}

class _BlockingRuntime extends _EchoRuntime {
  final _response = Completer<String>();

  void complete(String value) => _response.complete(value);

  @override
  Future<String> respond(AgentTurnRequest request) => _response.future;
}

class _BlockingSelector implements AgentSelector {
  final _selection = Completer<List<String>>();

  void complete(List<String> value) => _selection.complete(value);

  @override
  Future<List<String>> select(AgentSelectionRequest request) =>
      _selection.future;
}

class _BlockingSummaryRuntime extends _EchoRuntime {
  final _summary = Completer<String>();

  void complete(String value) => _summary.complete(value);

  @override
  Future<String> summarize(DiscussionSummaryRequest request) => _summary.future;
}

class _CapturingSummaryRuntime extends _FailingRuntime {
  _CapturingSummaryRuntime(super.failedAgentId);

  List<AgentTurnOutcome> outcomes = const [];

  @override
  Future<String> summarize(DiscussionSummaryRequest request) async {
    outcomes = List.of(request.outcomes);
    return '总结完成';
  }
}
