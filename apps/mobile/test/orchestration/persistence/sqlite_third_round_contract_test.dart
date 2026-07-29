import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/orchestration/basic_durable_runner.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';
import 'package:halo_mobile/orchestration/persistence/sqlite_run_event_store.dart';
import 'package:halo_mobile/orchestration/run_event_store.dart';

void main() {
  test('durable store rejects a run without an input reference', () async {
    final fixture = _DatabaseFixture.create();
    final store = SqliteRunEventStore.open(fixture.path);
    try {
      expect(store.requiresRecoveryReferences, isTrue);
      expect(
        () => store.createRun(_command(inputRef: null)),
        throwsArgumentError,
      );
    } finally {
      await store.close();
      fixture.delete();
    }
  });

  test('only one owner can lease one external logical intent', () async {
    final fixture = _DatabaseFixture.create();
    final first = SqliteRunEventStore.open(fixture.path);
    final second = SqliteRunEventStore.open(fixture.path);
    try {
      final runId = first.createRun(_command()).snapshot.runId;
      first.ensureExternalCallIntent(
        ExternalCallIntentRequest(
          intentId: '$runId:respond:0',
          idempotencyKey: '$runId:respond:0',
          runId: runId,
          kind: ExternalCallKind.respond,
          agentId: 'product-manager',
        ),
      );

      final now = DateTime.utc(2026, 7, 29);
      final lease = first.tryAcquireExternalCallLease(
        intentId: '$runId:respond:0',
        ownerId: 'runner-a',
        now: now,
        leaseDuration: const Duration(seconds: 30),
      );
      final competing = second.tryAcquireExternalCallLease(
        intentId: '$runId:respond:0',
        ownerId: 'runner-b',
        now: now,
        leaseDuration: const Duration(seconds: 30),
      );

      expect(lease?.ownerId, 'runner-a');
      expect(lease?.attempt, 1);
      expect(competing, isNull);
    } finally {
      await first.close();
      await second.close();
      fixture.delete();
    }
  });

  test('model output becomes public text only after secret redaction', () {
    final text = PublicEventText.fromModelOutput(
      'ok Authorization: Bearer abc.def.ghi '
      'password=hunter2 sk-proj-12345678901234567890 '
      'QWxhZGRpbjpPcGVuU2VzYW1lMTIzNDU2Nzg5MA==',
    );

    expect(text.value, contains('ok'));
    expect(text.value, isNot(contains('Bearer')));
    expect(text.value, isNot(contains('hunter2')));
    expect(text.value, isNot(contains('sk-proj')));
    expect(text.value, isNot(contains('QWxhZGRp')));
    expect(text.provenance, PublicEventTextProvenance.modelOutput);
  });

  test('durable runner rejects start without a recovery resolver', () async {
    final fixture = _DatabaseFixture.create();
    final store = SqliteRunEventStore.open(fixture.path);
    final runner = BasicDurableRunner(
      store: store,
      selector: const _Selector(),
      runtime: const _Runtime(),
    );
    try {
      await expectLater(runner.startRun(_command()), throwsArgumentError);
    } finally {
      await store.close();
      fixture.delete();
    }
  });

  for (final invalid in [
    const ['product-manager', 'product-manager'],
    const ['outside-member'],
    [for (var index = 0; index < 257; index++) 'x'].join(),
  ]) {
    test('executable agent validation rejects $invalid', () async {
      final fixture = _DatabaseFixture.create();
      final store = SqliteRunEventStore.open(fixture.path);
      try {
        final runId = store.createRun(_command()).snapshot.runId;
        final ids = invalid is String ? [invalid] : invalid as List<String>;
        expect(
          () => store.commitTransition(
            RunTransitionRequest(
              runId: runId,
              expectedLastSeq: 1,
              expectedStatus: OrchestrationRunStatus.running,
              causationId: 'invalid-executable',
              dedupeKey: 'invalid-executable',
              eventType: OrchestrationEventType.agentsSelected,
              stage: ConversationStage.responding,
              executableAgentIds: ids,
              selectedAgentIds: ids,
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

  test('close completes while a SQLite watcher is paused', () async {
    final fixture = _DatabaseFixture.create();
    final store = SqliteRunEventStore.open(fixture.path);
    final runId = store.createRun(_command()).snapshot.runId;
    final subscription = store.watch(runId).listen((_) {});
    subscription.pause();

    await store.close().timeout(const Duration(milliseconds: 250));

    await subscription.cancel();
    fixture.delete();
  });
}

class _Selector implements AgentSelector {
  const _Selector();

  @override
  Future<List<String>> select(AgentSelectionRequest request) async {
    return const ['product-manager'];
  }
}

class _Runtime implements AgentRuntime, IdempotentAgentRuntimeCapability {
  const _Runtime();

  @override
  bool get supportsIdempotency => true;

  @override
  Future<String> respond(AgentTurnRequest request) async => 'reply';

  @override
  Future<String> summarize(DiscussionSummaryRequest request) async => 'summary';
}

StartConversationRunCommand _command({String? inputRef = 'message://input'}) {
  return StartConversationRunCommand(
    clientCommandId: 'third-round-command',
    conversationId: 'group-product',
    hostAgentId: 'product-manager',
    input: '分析风险',
    inputRef: inputRef,
    replyMode: ConversationReplyMode.auto,
    memberAgentIds: const ['product-manager'],
  );
}

final class _DatabaseFixture {
  _DatabaseFixture._(this.directory, this.path);

  factory _DatabaseFixture.create() {
    final directory = Directory.systemTemp.createTempSync('halo-third-round-');
    return _DatabaseFixture._(
      directory,
      '${directory.path}/orchestration.sqlite',
    );
  }

  final Directory directory;
  final String path;

  void delete() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}
