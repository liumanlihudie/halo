import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';
import 'package:halo_mobile/orchestration/persistence/sqlite_run_event_store.dart';
import 'package:halo_mobile/orchestration/run_event_store.dart';

void main() {
  for (final storeKind in ['memory', 'sqlite']) {
    group('$storeKind terminal transition policy', () {
      late _StoreHarness harness;
      late RunEventStore store;
      late String runId;

      setUp(() {
        harness = _StoreHarness.create(storeKind);
        store = harness.store;
        runId = store.createRun(_command()).snapshot.runId;
        _prepareCompletable(store, runId);
      });

      tearDown(() => harness.dispose());

      test('rejects resurrection from completed to running', () {
        _complete(store, runId);

        expect(
          () => store.commitTransition(
            _request(
              runId: runId,
              expectedLastSeq: store.getRun(runId).lastSeq,
              expectedStatus: OrchestrationRunStatus.completed,
              dedupeKey: 'resurrect',
              eventType: OrchestrationEventType.stageChanged,
              stage: ConversationStage.responding,
              newStatus: OrchestrationRunStatus.running,
              checkpoint: RunCheckpoint.responding,
            ),
          ),
          throwsA(isA<TransitionConflict>()),
        );
        expect(store.getRun(runId).status, OrchestrationRunStatus.completed);
        expect(store.getRun(runId).lastSeq, 6);
      });

      test('rejects a terminal event with mismatched state fields', () {
        final invalid = [
          (
            type: OrchestrationEventType.runCompleted,
            stage: ConversationStage.completed,
            status: OrchestrationRunStatus.running,
            checkpoint: RunCheckpoint.terminal,
          ),
          (
            type: OrchestrationEventType.runFailed,
            stage: ConversationStage.completed,
            status: OrchestrationRunStatus.failed,
            checkpoint: RunCheckpoint.terminal,
          ),
          (
            type: OrchestrationEventType.stageChanged,
            stage: ConversationStage.completed,
            status: OrchestrationRunStatus.completed,
            checkpoint: RunCheckpoint.terminal,
          ),
          (
            type: OrchestrationEventType.runStopped,
            stage: ConversationStage.failed,
            status: OrchestrationRunStatus.stopped,
            checkpoint: RunCheckpoint.terminal,
          ),
        ];

        for (var index = 0; index < invalid.length; index++) {
          final value = invalid[index];
          expect(
            () => store.commitTransition(
              _request(
                runId: runId,
                expectedLastSeq: store.getRun(runId).lastSeq,
                expectedStatus: OrchestrationRunStatus.running,
                dedupeKey: 'invalid-terminal-$index',
                eventType: value.type,
                stage: value.stage,
                newStatus: value.status,
                checkpoint: value.checkpoint,
              ),
            ),
            throwsA(isA<TransitionConflict>()),
          );
        }
        expect(store.getRun(runId).lastSeq, 5);
      });

      test('rejects every new append after a terminal transition', () {
        _complete(store, runId);

        expect(
          () => store.commitTransition(
            _request(
              runId: runId,
              expectedLastSeq: store.getRun(runId).lastSeq,
              expectedStatus: OrchestrationRunStatus.completed,
              dedupeKey: 'post-terminal',
              eventType: OrchestrationEventType.stageChanged,
              stage: ConversationStage.completed,
            ),
          ),
          throwsA(isA<TransitionConflict>()),
        );
        expect(store.loadEvents(runId), hasLength(6));
      });

      test('returns the exact terminal duplicate without mutating state', () {
        final terminal = _terminalRequest(runId);
        final first = store.commitTransition(terminal);
        final duplicate = store.commitTransition(terminal);

        expect(first.committed, isTrue);
        expect(duplicate.committed, isFalse);
        expect(duplicate.event, first.event);
        expect(store.loadEvents(runId), hasLength(6));
      });
    });
  }
}

void _complete(RunEventStore store, String runId) {
  store.commitTransition(_terminalRequest(runId));
}

RunTransitionRequest _terminalRequest(String runId) {
  return _request(
    runId: runId,
    expectedLastSeq: 5,
    expectedStatus: OrchestrationRunStatus.running,
    dedupeKey: 'run-completed',
    eventType: OrchestrationEventType.runCompleted,
    stage: ConversationStage.completed,
    newStatus: OrchestrationRunStatus.completed,
    checkpoint: RunCheckpoint.terminal,
  );
}

void _prepareCompletable(RunEventStore store, String runId) {
  store.commitTransition(
    _request(
      runId: runId,
      expectedLastSeq: 1,
      expectedStatus: OrchestrationRunStatus.running,
      dedupeKey: 'selecting',
      eventType: OrchestrationEventType.stageChanged,
      stage: ConversationStage.selectingAgents,
      checkpoint: RunCheckpoint.selectingAgents,
    ),
  );
  store.commitTransition(
    RunTransitionRequest(
      runId: runId,
      expectedLastSeq: 2,
      expectedStatus: OrchestrationRunStatus.running,
      causationId: '$runId:selected',
      dedupeKey: 'selected',
      eventType: OrchestrationEventType.agentsSelected,
      stage: ConversationStage.responding,
      selectedAgentIds: const ['product-manager'],
      executableAgentIds: const ['product-manager'],
      checkpoint: RunCheckpoint.responding,
      nextAgentIndex: 0,
    ),
  );
  store.commitTransition(
    RunTransitionRequest(
      runId: runId,
      expectedLastSeq: 3,
      expectedStatus: OrchestrationRunStatus.running,
      causationId: '$runId:agent-started',
      dedupeKey: 'agent-started',
      eventType: OrchestrationEventType.agentMessageStarted,
      stage: ConversationStage.responding,
      agentId: 'product-manager',
    ),
  );
  store.commitTransition(
    RunTransitionRequest(
      runId: runId,
      expectedLastSeq: 4,
      expectedStatus: OrchestrationRunStatus.running,
      causationId: '$runId:agent-completed',
      dedupeKey: 'agent-completed',
      eventType: OrchestrationEventType.agentMessageCompleted,
      stage: ConversationStage.responding,
      agentId: 'product-manager',
      checkpoint: RunCheckpoint.responding,
      nextAgentIndex: 1,
    ),
  );
}

RunTransitionRequest _request({
  required String runId,
  required int expectedLastSeq,
  required OrchestrationRunStatus expectedStatus,
  required String dedupeKey,
  required OrchestrationEventType eventType,
  required ConversationStage stage,
  OrchestrationRunStatus? newStatus,
  RunCheckpoint? checkpoint,
}) {
  return RunTransitionRequest(
    runId: runId,
    expectedLastSeq: expectedLastSeq,
    expectedStatus: expectedStatus,
    causationId: '$runId:$dedupeKey',
    dedupeKey: dedupeKey,
    eventType: eventType,
    stage: stage,
    newStatus: newStatus,
    checkpoint: checkpoint,
  );
}

StartConversationRunCommand _command() {
  return const StartConversationRunCommand(
    clientCommandId: 'terminal-policy-command',
    conversationId: 'terminal-policy-conversation',
    hostAgentId: 'product-manager',
    input: '分析风险',
    inputRef: 'message://terminal-policy/input',
    replyMode: ConversationReplyMode.auto,
    memberAgentIds: ['product-manager'],
  );
}

final class _StoreHarness {
  _StoreHarness(this.store, this.directory);

  factory _StoreHarness.create(String kind) {
    if (kind == 'memory') {
      return _StoreHarness(InMemoryRunEventStore(), null);
    }
    final directory = Directory.systemTemp.createTempSync(
      'halo-terminal-policy-',
    );
    return _StoreHarness(
      SqliteRunEventStore.open('${directory.path}/orchestration.sqlite'),
      directory,
    );
  }

  final RunEventStore store;
  final Directory? directory;

  Future<void> dispose() async {
    await store.close();
    directory?.deleteSync(recursive: true);
  }
}
