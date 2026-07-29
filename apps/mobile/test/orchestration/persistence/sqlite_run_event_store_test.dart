import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';
import 'package:halo_mobile/orchestration/persistence/sqlite_run_event_store.dart';
import 'package:halo_mobile/orchestration/run_event_store.dart';

void main() {
  test('createRun atomically creates snapshot event and work item', () async {
    final fixture = _DatabaseFixture.create();
    final store = SqliteRunEventStore.open(fixture.path);
    try {
      final creation = store.createRun(_command());
      final events = store.loadEvents(creation.snapshot.runId);
      final work = store.getWorkItem(creation.snapshot.runId);

      expect(creation.snapshot.lastSeq, 1);
      expect(events.single.type, OrchestrationEventType.runCreated);
      expect(events.single.causationId, 'command:command-persisted');
      expect(events.single.dedupeKey, 'run-created');
      expect(work.checkpoint, RunCheckpoint.created);
      expect(work.inputRef, 'message://group-product/input-1');
      expect(work.contextRef, 'context://group-product/current');
    } finally {
      await store.close();
      fixture.delete();
    }
  });

  test('same command id with different request identity is rejected', () async {
    final fixture = _DatabaseFixture.create();
    final store = SqliteRunEventStore.open(fixture.path);
    try {
      store.createRun(_command());
      expect(
        () => store.createRun(_command(inputRef: 'message://other')),
        throwsA(isA<CommandIdentityConflict>()),
      );
      expect(
        () => store.createRun(_command(input: '不同的请求正文')),
        throwsA(isA<CommandIdentityConflict>()),
      );
    } finally {
      await store.close();
      fixture.delete();
    }
  });

  test('recovery records never persist the full command input', () async {
    const privateInput = 'FULL_PRIVATE_PROMPT_SENTINEL_7f4e6c';
    final fixture = _DatabaseFixture.create();
    final store = SqliteRunEventStore.open(fixture.path);
    try {
      store.createRun(_command(input: privateInput));
      await store.close();

      final bytes = File(fixture.path).readAsBytesSync();
      final searchable = utf8.decode(bytes, allowMalformed: true);
      expect(searchable, isNot(contains(privateInput)));
    } finally {
      await store.close();
      fixture.delete();
    }
  });

  test(
    'commitTransition atomically updates snapshot event and work item',
    () async {
      final fixture = _DatabaseFixture.create();
      final store = SqliteRunEventStore.open(fixture.path);
      try {
        final runId = store.createRun(_command()).snapshot.runId;
        _advanceToSelecting(store, runId);
        final result = store.commitTransition(
          _transition(
            runId: runId,
            expectedLastSeq: 2,
            type: OrchestrationEventType.agentsSelected,
            stage: ConversationStage.responding,
            dedupeKey: 'agents-selected',
            selectedAgentIds: const ['product-manager'],
            executableAgentIds: const ['product-manager'],
            checkpoint: RunCheckpoint.responding,
            nextAgentIndex: 0,
          ),
        );

        expect(result.committed, isTrue);
        expect(result.snapshot.lastSeq, 3);
        expect(result.snapshot.executableAgentIds, ['product-manager']);
        expect(store.getWorkItem(runId).checkpoint, RunCheckpoint.responding);
      } finally {
        await store.close();
        fixture.delete();
      }
    },
  );

  test('commitTransition enforces sequence and status CAS', () async {
    final fixture = _DatabaseFixture.create();
    final store = SqliteRunEventStore.open(fixture.path);
    try {
      final runId = store.createRun(_command()).snapshot.runId;
      expect(
        () => store.commitTransition(
          _transition(
            runId: runId,
            expectedLastSeq: 0,
            type: OrchestrationEventType.stageChanged,
            stage: ConversationStage.selectingAgents,
            dedupeKey: 'stale-seq',
          ),
        ),
        throwsA(isA<TransitionConflict>()),
      );
      expect(
        () => store.commitTransition(
          _transition(
            runId: runId,
            expectedLastSeq: 1,
            expectedStatus: OrchestrationRunStatus.completed,
            type: OrchestrationEventType.stageChanged,
            stage: ConversationStage.selectingAgents,
            dedupeKey: 'stale-status',
          ),
        ),
        throwsA(isA<TransitionConflict>()),
      );
    } finally {
      await store.close();
      fixture.delete();
    }
  });

  test('duplicate transition does not append another event', () async {
    final fixture = _DatabaseFixture.create();
    final store = SqliteRunEventStore.open(fixture.path);
    try {
      final runId = store.createRun(_command()).snapshot.runId;
      final request = _transition(
        runId: runId,
        expectedLastSeq: 1,
        type: OrchestrationEventType.stageChanged,
        stage: ConversationStage.selectingAgents,
        dedupeKey: 'selecting',
        checkpoint: RunCheckpoint.selectingAgents,
      );
      final first = store.commitTransition(request);
      final duplicate = store.commitTransition(request);

      expect(first.committed, isTrue);
      expect(duplicate.committed, isFalse);
      expect(duplicate.event, first.event);
      expect(store.loadEvents(runId).length, 2);
    } finally {
      await store.close();
      fixture.delete();
    }
  });

  test('same transition key with different payload is rejected', () async {
    final fixture = _DatabaseFixture.create();
    final store = SqliteRunEventStore.open(fixture.path);
    try {
      final runId = store.createRun(_command()).snapshot.runId;
      store.commitTransition(
        _transition(
          runId: runId,
          expectedLastSeq: 1,
          type: OrchestrationEventType.stageChanged,
          stage: ConversationStage.selectingAgents,
          dedupeKey: 'same-key',
          checkpoint: RunCheckpoint.selectingAgents,
        ),
      );
      expect(
        () => store.commitTransition(
          _transition(
            runId: runId,
            expectedLastSeq: 1,
            type: OrchestrationEventType.stageChanged,
            stage: ConversationStage.responding,
            dedupeKey: 'same-key',
          ),
        ),
        throwsA(isA<TransitionIdentityConflict>()),
      );
    } finally {
      await store.close();
      fixture.delete();
    }
  });

  for (final point in [
    SqliteFailurePoint.afterRunInserted,
    SqliteFailurePoint.afterRunCreatedInserted,
    SqliteFailurePoint.afterWorkItemInserted,
    SqliteFailurePoint.afterCommandMappingInserted,
    SqliteFailurePoint.beforeCreateCommit,
  ]) {
    test('createRun rolls back at $point', () async {
      final fixture = _DatabaseFixture.create();
      final failing = SqliteRunEventStore.open(
        fixture.path,
        failureInjector: (candidate) {
          if (candidate == point) throw StateError('injected crash');
        },
      );
      try {
        expect(() => failing.createRun(_command()), throwsStateError);
      } finally {
        await failing.close();
      }

      final reopened = SqliteRunEventStore.open(fixture.path);
      try {
        final creation = reopened.createRun(_command());
        expect(creation.created, isTrue);
        expect(creation.snapshot.runId, 'run-1');
        expect(reopened.loadEvents(creation.snapshot.runId).length, 1);
      } finally {
        await reopened.close();
        fixture.delete();
      }
    });
  }

  for (final point in [
    SqliteFailurePoint.afterTransitionEventInserted,
    SqliteFailurePoint.afterSnapshotUpdated,
    SqliteFailurePoint.afterWorkItemUpdated,
    SqliteFailurePoint.beforeTransitionCommit,
  ]) {
    test('commitTransition rolls back at $point', () async {
      final fixture = _DatabaseFixture.create();
      final setup = SqliteRunEventStore.open(fixture.path);
      final runId = setup.createRun(_command()).snapshot.runId;
      _advanceToSelecting(setup, runId);
      await setup.close();

      final failing = SqliteRunEventStore.open(
        fixture.path,
        failureInjector: (candidate) {
          if (candidate == point) throw StateError('injected crash');
        },
      );
      final request = _transition(
        runId: runId,
        expectedLastSeq: 2,
        type: OrchestrationEventType.agentsSelected,
        stage: ConversationStage.responding,
        dedupeKey: 'agents-selected',
        selectedAgentIds: const ['product-manager'],
        executableAgentIds: const ['product-manager'],
        checkpoint: RunCheckpoint.responding,
        nextAgentIndex: 0,
      );
      try {
        expect(() => failing.commitTransition(request), throwsStateError);
      } finally {
        await failing.close();
      }

      final reopened = SqliteRunEventStore.open(fixture.path);
      try {
        expect(reopened.getRun(runId).lastSeq, 2);
        expect(reopened.getRun(runId).executableAgentIds, isEmpty);
        expect(
          reopened.getWorkItem(runId).checkpoint,
          RunCheckpoint.selectingAgents,
        );
        expect(reopened.loadEvents(runId).length, 2);
        expect(reopened.commitTransition(request).committed, isTrue);
      } finally {
        await reopened.close();
        fixture.delete();
      }
    });
  }

  test('payload policy allows bounded user-visible text', () async {
    final fixture = _DatabaseFixture.create();
    final store = SqliteRunEventStore.open(fixture.path);
    try {
      final runId = store.createRun(_command()).snapshot.runId;
      _advanceToResponding(store, runId);
      store.commitTransition(
        _transition(
          runId: runId,
          expectedLastSeq: 3,
          type: OrchestrationEventType.agentMessageStarted,
          stage: ConversationStage.responding,
          dedupeKey: 'agent-started-0',
          agentId: 'product-manager',
        ),
      );
      final result = store.commitTransition(
        _transition(
          runId: runId,
          expectedLastSeq: 4,
          type: OrchestrationEventType.agentMessageCompleted,
          stage: ConversationStage.responding,
          dedupeKey: 'agent-completed-0',
          text: '这是安全的专家回复。',
          agentId: 'product-manager',
          checkpoint: RunCheckpoint.responding,
          nextAgentIndex: 1,
        ),
      );
      expect(result.event.text, '这是安全的专家回复。');
    } finally {
      await store.close();
      fixture.delete();
    }
  });

  for (final forbiddenText in [
    'api_key=secret',
    'apiKey=secret',
    'full_prompt: hidden',
    'Full Prompt: hidden',
    'private_memory: personal',
    'private-memory: personal',
    'raw_tool_result: unfiltered',
    'toolRawResult: unfiltered',
  ]) {
    test('payload policy rejects $forbiddenText', () async {
      final fixture = _DatabaseFixture.create();
      final store = SqliteRunEventStore.open(fixture.path);
      try {
        final runId = store.createRun(_command()).snapshot.runId;
        expect(
          () => store.commitTransition(
            _transition(
              runId: runId,
              expectedLastSeq: 1,
              type: OrchestrationEventType.agentMessageCompleted,
              stage: ConversationStage.responding,
              dedupeKey: 'unsafe',
              text: forbiddenText,
              agentId: 'product-manager',
            ),
          ),
          throwsA(isA<EventPayloadRejected>()),
        );
      } finally {
        await store.close();
        fixture.delete();
      }
    });
  }

  test('payload policy rejects oversized text', () async {
    final fixture = _DatabaseFixture.create();
    final store = SqliteRunEventStore.open(fixture.path);
    try {
      final runId = store.createRun(_command()).snapshot.runId;
      expect(
        () => store.commitTransition(
          _transition(
            runId: runId,
            expectedLastSeq: 1,
            type: OrchestrationEventType.agentMessageCompleted,
            stage: ConversationStage.responding,
            dedupeKey: 'oversized',
            text: 'x' * 4097,
            agentId: 'product-manager',
          ),
        ),
        throwsA(isA<EventPayloadRejected>()),
      );
    } finally {
      await store.close();
      fixture.delete();
    }
  });

  for (final invalidPayload in [
    (
      type: OrchestrationEventType.runCompleted,
      agentId: 'product-manager',
      selectedAgentIds: const <String>[],
      errorCode: null,
    ),
    (
      type: OrchestrationEventType.agentMessageCompleted,
      agentId: 'product-manager',
      selectedAgentIds: const ['product-manager'],
      errorCode: null,
    ),
    (
      type: OrchestrationEventType.stageChanged,
      agentId: null,
      selectedAgentIds: const <String>[],
      errorCode: 'not_allowed',
    ),
  ]) {
    test(
      'payload fields follow allowlist for ${invalidPayload.type}',
      () async {
        final fixture = _DatabaseFixture.create();
        final store = SqliteRunEventStore.open(fixture.path);
        try {
          final runId = store.createRun(_command()).snapshot.runId;
          expect(
            () => store.commitTransition(
              RunTransitionRequest(
                runId: runId,
                expectedLastSeq: 1,
                expectedStatus: OrchestrationRunStatus.running,
                causationId: 'allowlist',
                dedupeKey: 'allowlist',
                eventType: invalidPayload.type,
                stage: ConversationStage.responding,
                agentId: invalidPayload.agentId,
                selectedAgentIds: invalidPayload.selectedAgentIds,
                errorCode: invalidPayload.errorCode,
              ),
            ),
            throwsA(isA<EventPayloadRejected>()),
          );
        } finally {
          await store.close();
          fixture.delete();
        }
      },
    );
  }

  test('connection enables WAL and a bounded busy timeout', () async {
    final fixture = _DatabaseFixture.create();
    final store = SqliteRunEventStore.open(fixture.path);
    try {
      expect(store.runtimeConfiguration.journalMode, 'wal');
      expect(store.runtimeConfiguration.busyTimeoutMilliseconds, 5000);
    } finally {
      await store.close();
      fixture.delete();
    }
  });

  test('watch observes another SQLite connection', () async {
    final fixture = _DatabaseFixture.create();
    final writer = SqliteRunEventStore.open(
      fixture.path,
      watchPollInterval: const Duration(milliseconds: 5),
    );
    final runId = writer.createRun(_command()).snapshot.runId;
    final reader = SqliteRunEventStore.open(
      fixture.path,
      watchPollInterval: const Duration(milliseconds: 5),
    );
    try {
      final observed = reader
          .watch(runId, afterSeq: 1)
          .first
          .timeout(const Duration(seconds: 2));
      writer.commitTransition(
        _transition(
          runId: runId,
          expectedLastSeq: 1,
          type: OrchestrationEventType.stageChanged,
          stage: ConversationStage.selectingAgents,
          dedupeKey: 'cross-connection',
          checkpoint: RunCheckpoint.selectingAgents,
        ),
      );
      expect((await observed).dedupeKey, 'cross-connection');
    } finally {
      await reader.close();
      await writer.close();
      fixture.delete();
    }
  });

  test('close is idempotent ends watchers and rejects operations', () async {
    final fixture = _DatabaseFixture.create();
    final store = SqliteRunEventStore.open(
      fixture.path,
      watchPollInterval: const Duration(milliseconds: 5),
    );
    final runId = store.createRun(_command()).snapshot.runId;
    final done = Completer<void>();
    final subscription = store
        .watch(runId, afterSeq: 1)
        .listen((_) {}, onDone: done.complete);

    await store.close();
    await store.close();

    await done.future.timeout(const Duration(seconds: 2));
    expect(() => store.getRun(runId), throwsStateError);
    expect(() => store.watch(runId), throwsStateError);
    await subscription.cancel();
    fixture.delete();
  });
}

StartConversationRunCommand _command({
  String inputRef = 'message://group-product/input-1',
  String input = '分析风险',
}) {
  return StartConversationRunCommand(
    clientCommandId: 'command-persisted',
    conversationId: 'group-product',
    hostAgentId: 'product-manager',
    input: input,
    inputRef: inputRef,
    contextRef: 'context://group-product/current',
    replyMode: ConversationReplyMode.auto,
    memberAgentIds: const ['product-manager', 'technical-architect'],
  );
}

RunTransitionRequest _transition({
  required String runId,
  required int expectedLastSeq,
  required OrchestrationEventType type,
  required ConversationStage stage,
  required String dedupeKey,
  OrchestrationRunStatus expectedStatus = OrchestrationRunStatus.running,
  OrchestrationRunStatus? newStatus,
  String? agentId,
  String? text,
  List<String> selectedAgentIds = const [],
  List<String>? executableAgentIds,
  RunCheckpoint? checkpoint,
  int? nextAgentIndex,
}) {
  return RunTransitionRequest(
    runId: runId,
    expectedLastSeq: expectedLastSeq,
    expectedStatus: expectedStatus,
    causationId: 'cause:$dedupeKey',
    dedupeKey: dedupeKey,
    eventType: type,
    stage: stage,
    newStatus: newStatus,
    agentId: agentId,
    text: text == null ? null : PublicEventText.trustedApplication(text),
    selectedAgentIds: selectedAgentIds,
    executableAgentIds: executableAgentIds,
    checkpoint: checkpoint,
    nextAgentIndex: nextAgentIndex,
  );
}

void _advanceToSelecting(RunEventStore store, String runId) {
  store.commitTransition(
    _transition(
      runId: runId,
      expectedLastSeq: 1,
      type: OrchestrationEventType.stageChanged,
      stage: ConversationStage.selectingAgents,
      dedupeKey: 'stage-selecting',
      checkpoint: RunCheckpoint.selectingAgents,
    ),
  );
}

void _advanceToResponding(RunEventStore store, String runId) {
  _advanceToSelecting(store, runId);
  store.commitTransition(
    _transition(
      runId: runId,
      expectedLastSeq: 2,
      type: OrchestrationEventType.agentsSelected,
      stage: ConversationStage.responding,
      dedupeKey: 'agents-selected',
      selectedAgentIds: const ['product-manager'],
      executableAgentIds: const ['product-manager'],
      checkpoint: RunCheckpoint.responding,
      nextAgentIndex: 0,
    ),
  );
}

final class _DatabaseFixture {
  _DatabaseFixture._(this.directory, this.path);

  factory _DatabaseFixture.create() {
    final directory = Directory.systemTemp.createTempSync(
      'halo-run-event-store-',
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
