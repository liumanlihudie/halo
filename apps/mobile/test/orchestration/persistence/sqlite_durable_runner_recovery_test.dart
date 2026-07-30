import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/orchestration/basic_durable_runner.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';
import 'package:halo_mobile/orchestration/persistence/sqlite_run_event_store.dart';
import 'package:halo_mobile/orchestration/run_event_store.dart';

void main() {
  test(
    'recovery reuses the logical idempotency key after return-before-receipt crash',
    () async {
      final fixture = _DatabaseFixture.create();
      final runtime = _IdempotentRuntime();
      final firstStore = SqliteRunEventStore.open(fixture.path);
      var injected = false;
      final firstRunner = BasicDurableRunner(
        store: firstStore,
        selector: const _FixedSelector(['product-manager']),
        runtime: runtime,
        inputResolver: const _FixedInputResolver('分析风险'),
        runnerId: 'runner-a',
        externalCallLeaseDuration: const Duration(milliseconds: 1),
        failureInjector: (point) {
          if (!injected) {
            injected = true;
            throw const DurableRunnerCrash();
          }
        },
      );
      final handle = await firstRunner.startRun(_command());
      await _waitUntil(() => runtime.physicalAttempts == 1);
      await firstStore.close();

      final reopened = SqliteRunEventStore.open(fixture.path);
      final secondRunner = BasicDurableRunner(
        store: reopened,
        selector: const _ThrowingSelector(),
        runtime: runtime,
        inputResolver: const _FixedInputResolver('分析风险'),
        runnerId: 'runner-b',
        clock: () => DateTime.now().add(const Duration(seconds: 1)),
      );
      try {
        expect((await secondRunner.resumeRun(handle.runId)).resumed, isTrue);
        final events = await _collectTerminalRun(secondRunner, handle.runId);

        expect(events.last.type, OrchestrationEventType.runCompleted);
        expect(runtime.physicalAttempts, 2);
        expect(runtime.logicalInvocations, 1);
        expect(runtime.keys.toSet(), {('${handle.runId}:respond:0')});
      } finally {
        await reopened.close();
        fixture.delete();
      }
    },
  );

  test('durable runner fails closed for a non-idempotent runtime', () async {
    final fixture = _DatabaseFixture.create();
    final store = SqliteRunEventStore.open(fixture.path);
    final runner = BasicDurableRunner(
      store: store,
      selector: const _FixedSelector(['product-manager']),
      runtime: const _NonIdempotentRuntime(),
      inputResolver: const _FixedInputResolver('分析风险'),
    );
    try {
      await expectLater(runner.startRun(_command()), throwsUnsupportedError);
    } finally {
      await store.close();
      fixture.delete();
    }
  });

  test('two runners produce one logical external invocation', () async {
    final fixture = _DatabaseFixture.create();
    final setup = SqliteRunEventStore.open(fixture.path);
    final runId = setup.createRun(_command()).snapshot.runId;
    await setup.close();

    final firstStore = SqliteRunEventStore.open(fixture.path);
    final secondStore = SqliteRunEventStore.open(fixture.path);
    final runtime = _IdempotentRuntime(delay: const Duration(milliseconds: 20));
    final firstRunner = BasicDurableRunner(
      store: firstStore,
      selector: const _FixedSelector(['product-manager']),
      runtime: runtime,
      inputResolver: const _FixedInputResolver('分析风险'),
      runnerId: 'runner-a',
    );
    final secondRunner = BasicDurableRunner(
      store: secondStore,
      selector: const _FixedSelector(['product-manager']),
      runtime: runtime,
      inputResolver: const _FixedInputResolver('分析风险'),
      runnerId: 'runner-b',
    );
    try {
      await Future.wait([
        firstRunner.resumeRun(runId),
        secondRunner.resumeRun(runId),
      ]);
      final events = await _collectTerminalRun(firstRunner, runId);

      expect(events.last.type, OrchestrationEventType.runCompleted);
      expect(runtime.logicalInvocations, 1);
      expect(runtime.physicalAttempts, 1);
    } finally {
      await firstStore.close();
      await secondStore.close();
      fixture.delete();
    }
  });

  test('resumeRun continues a created run after reopening', () async {
    final fixture = _DatabaseFixture.create();
    final firstStore = SqliteRunEventStore.open(fixture.path);
    final runId = firstStore.createRun(_command()).snapshot.runId;
    await firstStore.close();

    final reopened = SqliteRunEventStore.open(fixture.path);
    final runtime = _RecordingRuntime();
    final runner = BasicDurableRunner(
      store: reopened,
      selector: const _FixedSelector(['product-manager']),
      runtime: runtime,
      inputResolver: const _FixedInputResolver('分析风险'),
    );
    try {
      final result = await runner.resumeRun(runId);
      final events = await _collectTerminalRun(runner, runId);

      expect(result.resumed, isTrue);
      expect(events.last.type, OrchestrationEventType.runCompleted);
      expect(runtime.respondedAgentIds, ['product-manager']);
      expect(runtime.inputs, ['分析风险']);
    } finally {
      await reopened.close();
      fixture.delete();
    }
  });

  test(
    'resumeRun continues from next agent without replaying completed work',
    () async {
      final fixture = _DatabaseFixture.create();
      final setup = SqliteRunEventStore.open(fixture.path);
      final command = _command(
        replyMode: ConversationReplyMode.all,
        memberAgentIds: const ['product-manager', 'technical-architect'],
      );
      final runId = setup.createRun(command).snapshot.runId;
      setup.commitTransition(
        _checkpointTransition(
          runId: runId,
          expectedLastSeq: 1,
          dedupeKey: 'stage-selecting',
          stage: ConversationStage.selectingAgents,
          checkpoint: RunCheckpoint.selectingAgents,
        ),
      );
      setup.commitTransition(
        RunTransitionRequest(
          runId: runId,
          expectedLastSeq: 2,
          expectedStatus: OrchestrationRunStatus.running,
          causationId: 'selection',
          dedupeKey: 'agents-selected',
          eventType: OrchestrationEventType.agentsSelected,
          stage: ConversationStage.collectingOpinions,
          selectedAgentIds: const ['product-manager', 'technical-architect'],
          executableAgentIds: const ['product-manager', 'technical-architect'],
          checkpoint: RunCheckpoint.responding,
          nextAgentIndex: 0,
        ),
      );
      setup.commitTransition(
        RunTransitionRequest(
          runId: runId,
          expectedLastSeq: 3,
          expectedStatus: OrchestrationRunStatus.running,
          causationId: 'agent-0-started',
          dedupeKey: 'agent-started-0',
          eventType: OrchestrationEventType.agentMessageStarted,
          stage: ConversationStage.collectingOpinions,
          agentId: 'product-manager',
        ),
      );
      setup.commitTransition(
        RunTransitionRequest(
          runId: runId,
          expectedLastSeq: 4,
          expectedStatus: OrchestrationRunStatus.running,
          causationId: 'agent-0',
          dedupeKey: 'agent-completed-0',
          eventType: OrchestrationEventType.agentMessageCompleted,
          stage: ConversationStage.collectingOpinions,
          agentId: 'product-manager',
          text: PublicEventText.trustedApplication('已完成的产品意见'),
          checkpoint: RunCheckpoint.responding,
          nextAgentIndex: 1,
        ),
      );
      await setup.close();

      final reopened = SqliteRunEventStore.open(fixture.path);
      final runtime = _RecordingRuntime();
      final runner = BasicDurableRunner(
        store: reopened,
        selector: const _ThrowingSelector(),
        runtime: runtime,
        inputResolver: const _FixedInputResolver('分析风险'),
      );
      try {
        expect((await runner.resumeRun(runId)).resumed, isTrue);
        final events = await _collectTerminalRun(runner, runId);

        expect(events.last.type, OrchestrationEventType.runCompleted);
        expect(runtime.respondedAgentIds, ['technical-architect']);
        expect(runtime.summaryOutcomes.map((outcome) => outcome.text), [
          '已完成的产品意见',
          'reply:technical-architect',
        ]);
      } finally {
        await reopened.close();
        fixture.delete();
      }
    },
  );

  test(
    'starting the same command continues its incomplete persisted run',
    () async {
      final fixture = _DatabaseFixture.create();
      final setup = SqliteRunEventStore.open(fixture.path);
      final command = _command();
      final runId = setup.createRun(command).snapshot.runId;
      await setup.close();

      final reopened = SqliteRunEventStore.open(fixture.path);
      final runner = BasicDurableRunner(
        store: reopened,
        selector: const _FixedSelector(['product-manager']),
        runtime: _RecordingRuntime(),
        inputResolver: const _FixedInputResolver('分析风险'),
      );
      try {
        final handle = await runner.startRun(command);
        final events = await _collectTerminalRun(runner, runId);

        expect(handle.runId, runId);
        expect(
          events
              .where((event) => event.type == OrchestrationEventType.runCreated)
              .length,
          1,
        );
        expect(events.last.type, OrchestrationEventType.runCompleted);
        expect(events.every((event) => event.causationId.isNotEmpty), isTrue);
        expect(events.every((event) => event.dedupeKey.isNotEmpty), isTrue);
        expect(
          events.map((event) => event.dedupeKey).toSet().length,
          events.length,
        );
      } finally {
        await reopened.close();
        fixture.delete();
      }
    },
  );

  test('resumeRun restarts selection from selecting checkpoint', () async {
    final fixture = _DatabaseFixture.create();
    final setup = SqliteRunEventStore.open(fixture.path);
    final runId = setup.createRun(_command()).snapshot.runId;
    setup.commitTransition(
      _checkpointTransition(
        runId: runId,
        expectedLastSeq: 1,
        dedupeKey: 'stage-selecting',
        stage: ConversationStage.selectingAgents,
        checkpoint: RunCheckpoint.selectingAgents,
      ),
    );
    await setup.close();

    final reopened = SqliteRunEventStore.open(fixture.path);
    final runtime = _RecordingRuntime();
    final runner = BasicDurableRunner(
      store: reopened,
      selector: const _FixedSelector(['product-manager']),
      runtime: runtime,
      inputResolver: const _FixedInputResolver('分析风险'),
    );
    try {
      expect((await runner.resumeRun(runId)).resumed, isTrue);
      expect(
        (await _collectTerminalRun(runner, runId)).last.type,
        OrchestrationEventType.runCompleted,
      );
      expect(runtime.respondedAgentIds, ['product-manager']);
    } finally {
      await reopened.close();
      fixture.delete();
    }
  });

  test('resumeRun summarizes without replaying agents', () async {
    final fixture = _DatabaseFixture.create();
    final setup = SqliteRunEventStore.open(fixture.path);
    final runId = setup
        .createRun(_command(replyMode: ConversationReplyMode.all))
        .snapshot
        .runId;
    setup.commitTransition(
      _checkpointTransition(
        runId: runId,
        expectedLastSeq: 1,
        dedupeKey: 'stage-selecting',
        stage: ConversationStage.selectingAgents,
        checkpoint: RunCheckpoint.selectingAgents,
      ),
    );
    setup.commitTransition(
      RunTransitionRequest(
        runId: runId,
        expectedLastSeq: 2,
        expectedStatus: OrchestrationRunStatus.running,
        causationId: 'selection',
        dedupeKey: 'agents-selected',
        eventType: OrchestrationEventType.agentsSelected,
        stage: ConversationStage.collectingOpinions,
        selectedAgentIds: const ['product-manager'],
        executableAgentIds: const ['product-manager'],
        checkpoint: RunCheckpoint.responding,
        nextAgentIndex: 0,
      ),
    );
    setup.commitTransition(
      RunTransitionRequest(
        runId: runId,
        expectedLastSeq: 3,
        expectedStatus: OrchestrationRunStatus.running,
        causationId: 'agent-0-started',
        dedupeKey: 'agent-started-0',
        eventType: OrchestrationEventType.agentMessageStarted,
        stage: ConversationStage.collectingOpinions,
        agentId: 'product-manager',
      ),
    );
    setup.commitTransition(
      RunTransitionRequest(
        runId: runId,
        expectedLastSeq: 4,
        expectedStatus: OrchestrationRunStatus.running,
        causationId: 'agent-0',
        dedupeKey: 'agent-completed-0',
        eventType: OrchestrationEventType.agentMessageCompleted,
        stage: ConversationStage.collectingOpinions,
        agentId: 'product-manager',
        text: PublicEventText.trustedApplication('已持久化意见'),
        checkpoint: RunCheckpoint.responding,
        nextAgentIndex: 1,
      ),
    );
    setup.commitTransition(
      _checkpointTransition(
        runId: runId,
        expectedLastSeq: 5,
        dedupeKey: 'stage-summarizing',
        stage: ConversationStage.summarizing,
        checkpoint: RunCheckpoint.summarizing,
      ),
    );
    await setup.close();

    final reopened = SqliteRunEventStore.open(fixture.path);
    final runtime = _RecordingRuntime();
    final runner = BasicDurableRunner(
      store: reopened,
      selector: const _ThrowingSelector(),
      runtime: runtime,
      inputResolver: const _FixedInputResolver('分析风险'),
    );
    try {
      expect((await runner.resumeRun(runId)).resumed, isTrue);
      expect(
        (await _collectTerminalRun(runner, runId)).last.type,
        OrchestrationEventType.runCompleted,
      );
      expect(runtime.respondedAgentIds, isEmpty);
      expect(runtime.summaryOutcomes.single.text, '已持久化意见');
    } finally {
      await reopened.close();
      fixture.delete();
    }
  });

  test('resumeRun finalizes without selector or runtime calls', () async {
    final fixture = _DatabaseFixture.create();
    final setup = SqliteRunEventStore.open(fixture.path);
    final runId = setup
        .createRun(_command(replyMode: ConversationReplyMode.all))
        .snapshot
        .runId;
    setup.commitTransition(
      _checkpointTransition(
        runId: runId,
        expectedLastSeq: 1,
        dedupeKey: 'stage-selecting',
        stage: ConversationStage.selectingAgents,
        checkpoint: RunCheckpoint.selectingAgents,
      ),
    );
    setup.commitTransition(
      RunTransitionRequest(
        runId: runId,
        expectedLastSeq: 2,
        expectedStatus: OrchestrationRunStatus.running,
        causationId: 'selection',
        dedupeKey: 'agents-selected',
        eventType: OrchestrationEventType.agentsSelected,
        stage: ConversationStage.collectingOpinions,
        selectedAgentIds: const ['product-manager'],
        executableAgentIds: const ['product-manager'],
        checkpoint: RunCheckpoint.responding,
        nextAgentIndex: 0,
      ),
    );
    setup.commitTransition(
      RunTransitionRequest(
        runId: runId,
        expectedLastSeq: 3,
        expectedStatus: OrchestrationRunStatus.running,
        causationId: 'agent-0-started',
        dedupeKey: 'agent-started-0',
        eventType: OrchestrationEventType.agentMessageStarted,
        stage: ConversationStage.collectingOpinions,
        agentId: 'product-manager',
      ),
    );
    setup.commitTransition(
      RunTransitionRequest(
        runId: runId,
        expectedLastSeq: 4,
        expectedStatus: OrchestrationRunStatus.running,
        causationId: 'agent-0',
        dedupeKey: 'agent-completed-0',
        eventType: OrchestrationEventType.agentMessageCompleted,
        stage: ConversationStage.collectingOpinions,
        agentId: 'product-manager',
        checkpoint: RunCheckpoint.responding,
        nextAgentIndex: 1,
      ),
    );
    setup.commitTransition(
      _checkpointTransition(
        runId: runId,
        expectedLastSeq: 5,
        dedupeKey: 'stage-summarizing',
        stage: ConversationStage.summarizing,
        checkpoint: RunCheckpoint.summarizing,
      ),
    );
    setup.commitTransition(
      RunTransitionRequest(
        runId: runId,
        expectedLastSeq: 6,
        expectedStatus: OrchestrationRunStatus.running,
        causationId: '$runId:summary-completed',
        dedupeKey: 'summary-completed',
        eventType: OrchestrationEventType.summaryCompleted,
        stage: ConversationStage.summarizing,
        checkpoint: RunCheckpoint.finalizing,
      ),
    );
    await setup.close();

    final reopened = SqliteRunEventStore.open(fixture.path);
    final runner = BasicDurableRunner(
      store: reopened,
      selector: const _ThrowingSelector(),
      runtime: const _ThrowingRuntime(),
      inputResolver: const _FixedInputResolver('分析风险'),
    );
    try {
      expect((await runner.resumeRun(runId)).resumed, isTrue);
      expect(
        (await _collectTerminalRun(runner, runId)).last.type,
        OrchestrationEventType.runCompleted,
      );
    } finally {
      await reopened.close();
      fixture.delete();
    }
  });
}

RunTransitionRequest _checkpointTransition({
  required String runId,
  required int expectedLastSeq,
  required String dedupeKey,
  required ConversationStage stage,
  required RunCheckpoint checkpoint,
}) {
  return RunTransitionRequest(
    runId: runId,
    expectedLastSeq: expectedLastSeq,
    expectedStatus: OrchestrationRunStatus.running,
    causationId: '$runId:$dedupeKey',
    dedupeKey: dedupeKey,
    eventType: OrchestrationEventType.stageChanged,
    stage: stage,
    checkpoint: checkpoint,
  );
}

Future<List<OrchestrationEvent>> _collectTerminalRun(
  BasicDurableRunner runner,
  String runId,
) async {
  final events = <OrchestrationEvent>[];
  await for (final event
      in runner.watchRun(runId).timeout(const Duration(seconds: 3))) {
    events.add(event);
    if (event.type == OrchestrationEventType.runCompleted ||
        event.type == OrchestrationEventType.runFailed ||
        event.type == OrchestrationEventType.runStopped) {
      break;
    }
  }
  return events;
}

StartConversationRunCommand _command({
  ConversationReplyMode replyMode = ConversationReplyMode.auto,
  List<String> memberAgentIds = const ['product-manager'],
}) {
  return StartConversationRunCommand(
    clientCommandId: 'resume-command',
    conversationId: 'group-product',
    hostAgentId: 'product-manager',
    input: '分析风险',
    inputRef: 'message://group-product/resume-input',
    contextRef: 'context://group-product/current',
    replyMode: replyMode,
    memberAgentIds: memberAgentIds,
  );
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
    throw StateError('selector must not run during responding recovery');
  }
}

class _RecordingRuntime
    implements AgentRuntime, IdempotentAgentRuntimeCapability {
  final respondedAgentIds = <String>[];
  final inputs = <String>[];
  List<AgentTurnOutcome> summaryOutcomes = const [];

  @override
  bool get supportsIdempotency => true;

  @override
  Future<String> respond(AgentTurnRequest request) async {
    respondedAgentIds.add(request.agentId);
    inputs.add(request.input);
    return 'reply:${request.agentId}';
  }

  @override
  Future<String> summarize(DiscussionSummaryRequest request) async {
    summaryOutcomes = List.unmodifiable(request.outcomes);
    return 'summary';
  }
}

class _ThrowingRuntime
    implements AgentRuntime, IdempotentAgentRuntimeCapability {
  const _ThrowingRuntime();

  @override
  bool get supportsIdempotency => true;

  @override
  Future<String> respond(AgentTurnRequest request) {
    throw StateError('runtime must not respond from finalizing checkpoint');
  }

  @override
  Future<String> summarize(DiscussionSummaryRequest request) {
    throw StateError('runtime must not summarize from finalizing checkpoint');
  }
}

class _FixedInputResolver implements RunInputResolver {
  const _FixedInputResolver(this.input);

  final String input;

  @override
  Future<String> resolve({required String inputRef, String? contextRef}) async {
    return input;
  }
}

class _IdempotentRuntime
    implements AgentRuntime, IdempotentAgentRuntimeCapability {
  _IdempotentRuntime({this.delay = Duration.zero});

  final Duration delay;
  final _results = <String, String>{};
  final keys = <String>[];
  var physicalAttempts = 0;

  int get logicalInvocations => _results.length;

  @override
  bool get supportsIdempotency => true;

  @override
  Future<String> respond(AgentTurnRequest request) async {
    physicalAttempts++;
    keys.add(request.idempotencyKey);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return _results.putIfAbsent(
      request.idempotencyKey,
      () => 'reply:${request.agentId}',
    );
  }

  @override
  Future<String> summarize(DiscussionSummaryRequest request) async {
    physicalAttempts++;
    keys.add(request.idempotencyKey);
    return _results.putIfAbsent(request.idempotencyKey, () => 'summary');
  }
}

class _NonIdempotentRuntime implements AgentRuntime {
  const _NonIdempotentRuntime();

  @override
  Future<String> respond(AgentTurnRequest request) async => 'unsafe';

  @override
  Future<String> summarize(DiscussionSummaryRequest request) async => 'unsafe';
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition was not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

final class _DatabaseFixture {
  _DatabaseFixture._(this.directory, this.path);

  factory _DatabaseFixture.create() {
    final directory = Directory.systemTemp.createTempSync(
      'halo-runner-recovery-',
    );
    return _DatabaseFixture._(
      directory,
      '${directory.path}/orchestration.sqlite',
    );
  }

  final Directory directory;
  final String path;

  void delete() {
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  }
}
