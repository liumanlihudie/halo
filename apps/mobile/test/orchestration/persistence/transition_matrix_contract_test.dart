import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';
import 'package:halo_mobile/orchestration/persistence/sqlite_run_event_store.dart';
import 'package:halo_mobile/orchestration/run_event_store.dart';

void main() {
  for (final storeKind in ['memory', 'sqlite']) {
    group('$storeKind transition matrix contract', () {
      late _StoreHarness harness;
      late RunEventStore store;
      late String runId;

      setUp(() {
        harness = _StoreHarness.create(storeKind);
        store = harness.store;
        runId = store.createRun(_command('command-a')).snapshot.runId;
      });

      tearDown(() => harness.dispose());

      test('accepts the legal checkpoint chain and responding self-loops', () {
        var seq = 1;
        _commit(
          store,
          runId,
          seq: seq++,
          key: 'selecting',
          type: OrchestrationEventType.stageChanged,
          stage: ConversationStage.selectingAgents,
          checkpoint: RunCheckpoint.selectingAgents,
        );
        _commit(
          store,
          runId,
          seq: seq++,
          key: 'selected',
          type: OrchestrationEventType.agentsSelected,
          stage: ConversationStage.collectingOpinions,
          checkpoint: RunCheckpoint.responding,
          executableAgentIds: const ['agent-a', 'agent-b'],
          selectedAgentIds: const ['agent-a', 'agent-b'],
          nextAgentIndex: 0,
        );
        _commit(
          store,
          runId,
          seq: seq++,
          key: 'agent-a-started',
          type: OrchestrationEventType.agentMessageStarted,
          stage: ConversationStage.collectingOpinions,
          agentId: 'agent-a',
        );
        _commit(
          store,
          runId,
          seq: seq++,
          key: 'agent-a-completed',
          type: OrchestrationEventType.agentMessageCompleted,
          stage: ConversationStage.collectingOpinions,
          agentId: 'agent-a',
          nextAgentIndex: 1,
        );
        _commit(
          store,
          runId,
          seq: seq++,
          key: 'agent-b-started',
          type: OrchestrationEventType.agentMessageStarted,
          stage: ConversationStage.collectingOpinions,
          agentId: 'agent-b',
        );
        _commit(
          store,
          runId,
          seq: seq++,
          key: 'agent-b-failed',
          type: OrchestrationEventType.agentMessageFailed,
          stage: ConversationStage.collectingOpinions,
          agentId: 'agent-b',
          nextAgentIndex: 2,
        );
        _commit(
          store,
          runId,
          seq: seq++,
          key: 'summarizing',
          type: OrchestrationEventType.stageChanged,
          stage: ConversationStage.summarizing,
          checkpoint: RunCheckpoint.summarizing,
        );
        _commit(
          store,
          runId,
          seq: seq++,
          key: 'summary',
          type: OrchestrationEventType.summaryCompleted,
          stage: ConversationStage.summarizing,
          checkpoint: RunCheckpoint.finalizing,
        );
        _commit(
          store,
          runId,
          seq: seq,
          key: 'completed',
          type: OrchestrationEventType.runCompleted,
          stage: ConversationStage.completed,
          checkpoint: RunCheckpoint.terminal,
          newStatus: OrchestrationRunStatus.completed,
        );

        expect(store.getRun(runId).status, OrchestrationRunStatus.completed);
        expect(store.getWorkItem(runId).checkpoint, RunCheckpoint.terminal);
        expect(store.getWorkItem(runId).nextAgentIndex, 2);
      });

      test('rejects checkpoint skips and backwards transitions', () {
        final invalidFromCreated = [
          RunCheckpoint.responding,
          RunCheckpoint.summarizing,
          RunCheckpoint.finalizing,
        ];
        for (final checkpoint in invalidFromCreated) {
          expect(
            () => _commit(
              store,
              runId,
              seq: 1,
              key: 'created-to-${checkpoint.name}',
              type: OrchestrationEventType.stageChanged,
              stage: ConversationStage.summarizing,
              checkpoint: checkpoint,
            ),
            throwsA(isA<TransitionConflict>()),
          );
        }

        _advanceToResponding(store, runId);
        for (final checkpoint in [
          RunCheckpoint.created,
          RunCheckpoint.selectingAgents,
          RunCheckpoint.finalizing,
        ]) {
          expect(
            () => _commit(
              store,
              runId,
              seq: 3,
              key: 'responding-to-${checkpoint.name}',
              type: OrchestrationEventType.stageChanged,
              stage: ConversationStage.summarizing,
              checkpoint: checkpoint,
            ),
            throwsA(isA<TransitionConflict>()),
          );
        }
      });

      test('rejects event, stage, and checkpoint mismatches', () {
        final invalid = [
          (
            type: OrchestrationEventType.agentsSelected,
            stage: ConversationStage.selectingAgents,
            checkpoint: RunCheckpoint.selectingAgents,
          ),
          (
            type: OrchestrationEventType.stageChanged,
            stage: ConversationStage.responding,
            checkpoint: RunCheckpoint.selectingAgents,
          ),
          (
            type: OrchestrationEventType.stageChanged,
            stage: ConversationStage.summarizing,
            checkpoint: RunCheckpoint.selectingAgents,
          ),
        ];
        for (var index = 0; index < invalid.length; index++) {
          final value = invalid[index];
          expect(
            () => _commit(
              store,
              runId,
              seq: 1,
              key: 'mismatch-$index',
              type: value.type,
              stage: value.stage,
              checkpoint: value.checkpoint,
            ),
            throwsA(isA<TransitionConflict>()),
          );
        }
      });

      test(
        'rejects nextAgentIndex regressions, skips, and bounds violations',
        () {
          _advanceToResponding(store, runId);

          final invalid = [
            (
              key: 'index-skip',
              agentId: 'agent-a',
              type: OrchestrationEventType.agentMessageCompleted,
              next: 2,
            ),
            (
              key: 'index-out-of-bounds',
              agentId: 'agent-a',
              type: OrchestrationEventType.agentMessageCompleted,
              next: 3,
            ),
            (
              key: 'wrong-agent',
              agentId: 'agent-b',
              type: OrchestrationEventType.agentMessageCompleted,
              next: 1,
            ),
            (
              key: 'started-advances',
              agentId: 'agent-a',
              type: OrchestrationEventType.agentMessageStarted,
              next: 1,
            ),
          ];
          for (final value in invalid) {
            expect(
              () => _commit(
                store,
                runId,
                seq: 3,
                key: value.key,
                type: value.type,
                stage: ConversationStage.collectingOpinions,
                agentId: value.agentId,
                nextAgentIndex: value.next,
              ),
              throwsA(isA<TransitionConflict>()),
            );
          }

          _commit(
            store,
            runId,
            seq: 3,
            key: 'agent-a-started',
            type: OrchestrationEventType.agentMessageStarted,
            stage: ConversationStage.collectingOpinions,
            agentId: 'agent-a',
          );
          _commit(
            store,
            runId,
            seq: 4,
            key: 'agent-a-completed',
            type: OrchestrationEventType.agentMessageCompleted,
            stage: ConversationStage.collectingOpinions,
            agentId: 'agent-a',
            nextAgentIndex: 1,
          );
          expect(
            () => _commit(
              store,
              runId,
              seq: 5,
              key: 'index-regression',
              type: OrchestrationEventType.agentMessageCompleted,
              stage: ConversationStage.collectingOpinions,
              agentId: 'agent-b',
              nextAgentIndex: 0,
            ),
            throwsA(isA<TransitionConflict>()),
          );
        },
      );

      test('requires all responding work before summarizing or completion', () {
        _advanceToResponding(store, runId);

        expect(
          () => _commit(
            store,
            runId,
            seq: 3,
            key: 'premature-cross-discussion',
            type: OrchestrationEventType.stageChanged,
            stage: ConversationStage.crossDiscussion,
          ),
          throwsA(isA<TransitionConflict>()),
        );
        expect(
          () => _commit(
            store,
            runId,
            seq: 3,
            key: 'premature-summary',
            type: OrchestrationEventType.stageChanged,
            stage: ConversationStage.summarizing,
            checkpoint: RunCheckpoint.summarizing,
          ),
          throwsA(isA<TransitionConflict>()),
        );
        expect(
          () => _commit(
            store,
            runId,
            seq: 3,
            key: 'premature-complete',
            type: OrchestrationEventType.runCompleted,
            stage: ConversationStage.completed,
            checkpoint: RunCheckpoint.terminal,
            newStatus: OrchestrationRunStatus.completed,
          ),
          throwsA(isA<TransitionConflict>()),
        );
      });

      test('all mode cannot complete without the summary path', () {
        _advanceToResponding(store, runId);
        _commit(
          store,
          runId,
          seq: 3,
          key: 'agent-a-started',
          type: OrchestrationEventType.agentMessageStarted,
          stage: ConversationStage.collectingOpinions,
          agentId: 'agent-a',
        );
        _commit(
          store,
          runId,
          seq: 4,
          key: 'agent-a-completed',
          type: OrchestrationEventType.agentMessageCompleted,
          stage: ConversationStage.collectingOpinions,
          agentId: 'agent-a',
          nextAgentIndex: 1,
        );
        _commit(
          store,
          runId,
          seq: 5,
          key: 'agent-b-started',
          type: OrchestrationEventType.agentMessageStarted,
          stage: ConversationStage.collectingOpinions,
          agentId: 'agent-b',
        );
        _commit(
          store,
          runId,
          seq: 6,
          key: 'agent-b-completed',
          type: OrchestrationEventType.agentMessageCompleted,
          stage: ConversationStage.collectingOpinions,
          agentId: 'agent-b',
          nextAgentIndex: 2,
        );

        expect(
          () => _commit(
            store,
            runId,
            seq: 7,
            key: 'all-mode-direct-complete',
            type: OrchestrationEventType.runCompleted,
            stage: ConversationStage.completed,
            checkpoint: RunCheckpoint.terminal,
            newStatus: OrchestrationRunStatus.completed,
          ),
          throwsA(isA<TransitionConflict>()),
        );
      });

      test('non-all mode cannot enter discussion or summary', () {
        final autoRunId = store
            .createRun(
              _command('auto-command', replyMode: ConversationReplyMode.auto),
            )
            .snapshot
            .runId;
        _advanceToRespondingWithStage(
          store,
          autoRunId,
          responseStage: ConversationStage.responding,
        );

        for (final value in [
          (
            key: 'auto-cross',
            stage: ConversationStage.crossDiscussion,
            checkpoint: null,
          ),
          (
            key: 'auto-summary',
            stage: ConversationStage.summarizing,
            checkpoint: RunCheckpoint.summarizing,
          ),
        ]) {
          expect(
            () => _commit(
              store,
              autoRunId,
              seq: 3,
              key: value.key,
              type: OrchestrationEventType.stageChanged,
              stage: value.stage,
              checkpoint: value.checkpoint,
            ),
            throwsA(isA<TransitionConflict>()),
          );
        }
      });

      test('rejects an empty agentsSelected executable set', () {
        final emptyRunId = store
            .createRun(_command('empty-selection-command'))
            .snapshot
            .runId;
        _commit(
          store,
          emptyRunId,
          seq: 1,
          key: 'empty-selecting',
          type: OrchestrationEventType.stageChanged,
          stage: ConversationStage.selectingAgents,
          checkpoint: RunCheckpoint.selectingAgents,
        );

        expect(
          () => _commit(
            store,
            emptyRunId,
            seq: 2,
            key: 'empty-selected',
            type: OrchestrationEventType.agentsSelected,
            stage: ConversationStage.collectingOpinions,
            checkpoint: RunCheckpoint.responding,
            executableAgentIds: const [],
            selectedAgentIds: const [],
            nextAgentIndex: 0,
          ),
          throwsA(isA<TransitionConflict>()),
        );
      });

      test('terminal failure and stop cannot smuggle cursor changes', () {
        for (final terminal in [
          (
            suffix: 'failed',
            type: OrchestrationEventType.runFailed,
            stage: ConversationStage.failed,
            status: OrchestrationRunStatus.failed,
          ),
          (
            suffix: 'stopped',
            type: OrchestrationEventType.runStopped,
            stage: ConversationStage.stopped,
            status: OrchestrationRunStatus.stopped,
          ),
        ]) {
          final terminalRunId = store
              .createRun(_command('terminal-${terminal.suffix}'))
              .snapshot
              .runId;
          _advanceToResponding(store, terminalRunId);
          expect(
            () => _commit(
              store,
              terminalRunId,
              seq: 3,
              key: 'terminal-${terminal.suffix}',
              type: terminal.type,
              stage: terminal.stage,
              checkpoint: RunCheckpoint.terminal,
              newStatus: terminal.status,
              nextAgentIndex: 1,
            ),
            throwsA(isA<TransitionConflict>()),
          );
        }

        final membershipRunId = store
            .createRun(_command('terminal-membership'))
            .snapshot
            .runId;
        _advanceToResponding(store, membershipRunId);
        expect(
          () => _commit(
            store,
            membershipRunId,
            seq: 3,
            key: 'terminal-membership-change',
            type: OrchestrationEventType.runStopped,
            stage: ConversationStage.stopped,
            checkpoint: RunCheckpoint.terminal,
            newStatus: OrchestrationRunStatus.stopped,
            executableAgentIds: const ['agent-a'],
          ),
          throwsA(isA<TransitionConflict>()),
        );
      });

      test('agent completion requires a persisted unmatched start', () {
        _advanceToResponding(store, runId);

        expect(
          () => _commit(
            store,
            runId,
            seq: 3,
            key: 'completed-without-start',
            type: OrchestrationEventType.agentMessageCompleted,
            stage: ConversationStage.collectingOpinions,
            agentId: 'agent-a',
            nextAgentIndex: 1,
          ),
          throwsA(isA<TransitionConflict>()),
        );
      });

      test('stageChanged rejects unrelated selectedAgentIds', () {
        _advanceToResponding(store, runId);

        expect(
          () => _commit(
            store,
            runId,
            seq: 3,
            key: 'stage-with-selection-payload',
            type: OrchestrationEventType.stageChanged,
            stage: ConversationStage.collectingOpinions,
            selectedAgentIds: const ['agent-a', 'agent-b'],
          ),
          throwsA(isA<EventPayloadRejected>()),
        );
      });
    });

    group('$storeKind external call intent identity contract', () {
      late _StoreHarness harness;
      late RunEventStore store;

      setUp(() {
        harness = _StoreHarness.create(storeKind);
        store = harness.store;
      });

      tearDown(() => harness.dispose());

      test('requires an existing run', () {
        expect(
          () => store.ensureExternalCallIntent(
            _intent(runId: 'missing-run', intentId: 'intent-a', key: 'key-a'),
          ),
          throwsStateError,
        );
      });

      test('treats idempotencyKey as a globally unique identity', () {
        final firstRun = store.createRun(_command('command-a')).snapshot.runId;
        final secondRun = store.createRun(_command('command-b')).snapshot.runId;
        final first = _intent(
          runId: firstRun,
          intentId: 'intent-a',
          key: 'global-key',
        );

        expect(store.ensureExternalCallIntent(first).intentId, 'intent-a');
        expect(store.ensureExternalCallIntent(first).intentId, 'intent-a');
        expect(
          () => store.ensureExternalCallIntent(
            _intent(runId: firstRun, intentId: 'intent-b', key: 'global-key'),
          ),
          throwsA(isA<ExternalCallIdentityConflict>()),
        );
        expect(
          () => store.ensureExternalCallIntent(
            _intent(runId: secondRun, intentId: 'intent-c', key: 'global-key'),
          ),
          throwsA(isA<ExternalCallIdentityConflict>()),
        );
      });
    });
  }
}

void _advanceToResponding(RunEventStore store, String runId) {
  _advanceToRespondingWithStage(
    store,
    runId,
    responseStage: ConversationStage.collectingOpinions,
  );
}

void _advanceToRespondingWithStage(
  RunEventStore store,
  String runId, {
  required ConversationStage responseStage,
}) {
  _commit(
    store,
    runId,
    seq: 1,
    key: 'selecting',
    type: OrchestrationEventType.stageChanged,
    stage: ConversationStage.selectingAgents,
    checkpoint: RunCheckpoint.selectingAgents,
  );
  _commit(
    store,
    runId,
    seq: 2,
    key: 'selected',
    type: OrchestrationEventType.agentsSelected,
    stage: responseStage,
    checkpoint: RunCheckpoint.responding,
    executableAgentIds: const ['agent-a', 'agent-b'],
    selectedAgentIds: const ['agent-a', 'agent-b'],
    nextAgentIndex: 0,
  );
}

TransitionCommit _commit(
  RunEventStore store,
  String runId, {
  required int seq,
  required String key,
  required OrchestrationEventType type,
  required ConversationStage stage,
  RunCheckpoint? checkpoint,
  OrchestrationRunStatus? newStatus,
  String? agentId,
  List<String>? executableAgentIds,
  List<String> selectedAgentIds = const [],
  int? nextAgentIndex,
}) {
  return store.commitTransition(
    RunTransitionRequest(
      runId: runId,
      expectedLastSeq: seq,
      expectedStatus: OrchestrationRunStatus.running,
      causationId: '$runId:$key',
      dedupeKey: key,
      eventType: type,
      stage: stage,
      checkpoint: checkpoint,
      newStatus: newStatus,
      agentId: agentId,
      executableAgentIds: executableAgentIds,
      selectedAgentIds: selectedAgentIds,
      nextAgentIndex: nextAgentIndex,
    ),
  );
}

ExternalCallIntentRequest _intent({
  required String runId,
  required String intentId,
  required String key,
}) {
  return ExternalCallIntentRequest(
    intentId: intentId,
    idempotencyKey: key,
    runId: runId,
    kind: ExternalCallKind.respond,
    agentId: 'agent-a',
  );
}

StartConversationRunCommand _command(
  String commandId, {
  ConversationReplyMode replyMode = ConversationReplyMode.all,
}) {
  return StartConversationRunCommand(
    clientCommandId: commandId,
    conversationId: 'conversation-$commandId',
    hostAgentId: 'agent-a',
    input: 'input',
    inputRef: 'message://$commandId/input',
    replyMode: replyMode,
    memberAgentIds: const ['agent-a', 'agent-b'],
  );
}

final class _StoreHarness {
  _StoreHarness(this.store, this.directory);

  factory _StoreHarness.create(String kind) {
    if (kind == 'memory') {
      return _StoreHarness(InMemoryRunEventStore(), null);
    }
    final directory = Directory.systemTemp.createTempSync(
      'halo-transition-matrix-',
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
