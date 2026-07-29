import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/orchestration/basic_durable_runner.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';
import 'package:halo_mobile/orchestration/persistence/sqlite_run_event_store.dart';
import 'package:halo_mobile/orchestration/run_event_store.dart';

void main() {
  for (final storeKind in ['memory', 'sqlite']) {
    test('$storeKind rejects a stale receipt after lease takeover', () async {
      final harness = _StoreHarness.create(storeKind);
      final store = harness.store;
      try {
        final runId = store.createRun(_command()).snapshot.runId;
        final intentId = '$runId:respond:0';
        store.ensureExternalCallIntent(
          ExternalCallIntentRequest(
            intentId: intentId,
            idempotencyKey: intentId,
            runId: runId,
            kind: ExternalCallKind.respond,
            agentId: 'product-manager',
          ),
        );
        final startedAt = DateTime.utc(2026, 7, 29, 1);
        final first = store.tryAcquireExternalCallLease(
          intentId: intentId,
          ownerId: 'runner-a',
          now: startedAt,
          leaseDuration: const Duration(seconds: 10),
        )!;
        final takenOverAt = startedAt.add(const Duration(seconds: 11));
        final second = store.tryAcquireExternalCallLease(
          intentId: intentId,
          ownerId: 'runner-b',
          now: takenOverAt,
          leaseDuration: const Duration(seconds: 10),
        )!;

        expect(second.attempt, first.attempt + 1);
        expect(second.fencingToken, greaterThan(first.fencingToken));
        expect(
          () => store.recordExternalCallReceipt(
            lease: first,
            now: takenOverAt,
            result: PublicEventText.fromModelOutput('stale'),
          ),
          throwsA(isA<ExternalCallLeaseLost>()),
        );

        final receipt = store.recordExternalCallReceipt(
          lease: second,
          now: takenOverAt,
          result: PublicEventText.fromModelOutput('current'),
        );
        expect(receipt.result?.value, 'current');
      } finally {
        await harness.dispose();
      }
    });

    test(
      '$storeKind rejects the old fence when the same owner renews',
      () async {
        final harness = _StoreHarness.create(storeKind);
        final store = harness.store;
        try {
          final runId = store.createRun(_command()).snapshot.runId;
          final intentId = '$runId:respond:0';
          store.ensureExternalCallIntent(
            ExternalCallIntentRequest(
              intentId: intentId,
              idempotencyKey: intentId,
              runId: runId,
              kind: ExternalCallKind.respond,
              agentId: 'product-manager',
            ),
          );
          final now = DateTime.utc(2026, 7, 29, 1);
          final oldLease = store.tryAcquireExternalCallLease(
            intentId: intentId,
            ownerId: 'runner-a',
            now: now,
            leaseDuration: const Duration(seconds: 10),
          )!;
          final renewedAt = now.add(const Duration(seconds: 11));
          final currentLease = store.tryAcquireExternalCallLease(
            intentId: intentId,
            ownerId: 'runner-a',
            now: renewedAt,
            leaseDuration: const Duration(seconds: 10),
          )!;

          expect(
            () => store.recordExternalCallReceipt(
              lease: oldLease,
              now: renewedAt,
              result: PublicEventText.fromModelOutput('stale'),
            ),
            throwsA(isA<ExternalCallLeaseLost>()),
          );
          expect(currentLease.fencingToken, greaterThan(oldLease.fencingToken));
        } finally {
          await harness.dispose();
        }
      },
    );

    test('$storeKind rejects a receipt after its lease expires', () async {
      final harness = _StoreHarness.create(storeKind);
      final store = harness.store;
      try {
        final runId = store.createRun(_command()).snapshot.runId;
        final intentId = '$runId:respond:0';
        store.ensureExternalCallIntent(
          ExternalCallIntentRequest(
            intentId: intentId,
            idempotencyKey: intentId,
            runId: runId,
            kind: ExternalCallKind.respond,
            agentId: 'product-manager',
          ),
        );
        final now = DateTime.utc(2026, 7, 29, 1);
        final lease = store.tryAcquireExternalCallLease(
          intentId: intentId,
          ownerId: 'runner-a',
          now: now,
          leaseDuration: const Duration(seconds: 10),
        )!;

        expect(
          () => store.recordExternalCallReceipt(
            lease: lease,
            now: now.add(const Duration(seconds: 10)),
            result: PublicEventText.fromModelOutput('late'),
          ),
          throwsA(isA<ExternalCallLeaseLost>()),
        );
      } finally {
        await harness.dispose();
      }
    });

    test('$storeKind validates attempt and fence independently', () async {
      final harness = _StoreHarness.create(storeKind);
      final store = harness.store;
      try {
        final runId = store.createRun(_command()).snapshot.runId;
        final intentId = '$runId:respond:0';
        store.ensureExternalCallIntent(
          ExternalCallIntentRequest(
            intentId: intentId,
            idempotencyKey: intentId,
            runId: runId,
            kind: ExternalCallKind.respond,
            agentId: 'product-manager',
          ),
        );
        final now = DateTime.utc(2026, 7, 29, 1);
        final lease = store.tryAcquireExternalCallLease(
          intentId: intentId,
          ownerId: 'runner-a',
          now: now,
          leaseDuration: const Duration(seconds: 10),
        )!;
        final wrongAttempt = ExternalCallLease(
          intentId: lease.intentId,
          ownerId: lease.ownerId,
          idempotencyKey: lease.idempotencyKey,
          attempt: lease.attempt + 1,
          fencingToken: lease.fencingToken,
          expiresAt: lease.expiresAt,
        );
        final wrongFence = ExternalCallLease(
          intentId: lease.intentId,
          ownerId: lease.ownerId,
          idempotencyKey: lease.idempotencyKey,
          attempt: lease.attempt,
          fencingToken: lease.fencingToken + 1,
          expiresAt: lease.expiresAt,
        );

        for (final forged in [wrongAttempt, wrongFence]) {
          expect(
            () => store.recordExternalCallReceipt(
              lease: forged,
              now: now,
              result: PublicEventText.fromModelOutput('forged'),
            ),
            throwsA(isA<ExternalCallLeaseLost>()),
          );
        }
      } finally {
        await harness.dispose();
      }
    });
  }

  test(
    'late runner return cannot fail or advance after a newer fence completes',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'halo-runner-fence-',
      );
      final path = '${directory.path}/orchestration.sqlite';
      final storeA = SqliteRunEventStore.open(path);
      final storeB = SqliteRunEventStore.open(path);
      final clock = _FakeClock(DateTime.utc(2026, 7, 29, 2));
      final runtimeA = _BlockingRuntime();
      final runnerA = BasicDurableRunner(
        store: storeA,
        selector: const _Selector(),
        runtime: runtimeA,
        inputResolver: const _Resolver(),
        runnerId: 'runner-a',
        clock: clock.now,
        externalCallLeaseDuration: const Duration(seconds: 10),
      );
      final handle = await runnerA.startRun(_command());
      await runtimeA.started.future;

      clock.advance(const Duration(seconds: 11));
      final runnerB = BasicDurableRunner(
        store: storeB,
        selector: const _Selector(),
        runtime: const _ImmediateRuntime(),
        inputResolver: const _Resolver(),
        runnerId: 'runner-b',
        clock: clock.now,
        externalCallLeaseDuration: const Duration(seconds: 10),
      );
      expect((await runnerB.resumeRun(handle.runId)).resumed, isTrue);
      await _waitForTerminal(storeB, handle.runId);

      runtimeA.complete('late response');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final events = storeB.loadEvents(handle.runId);
      expect(
        events.where(
          (event) => event.type == OrchestrationEventType.agentMessageFailed,
        ),
        isEmpty,
      );
      expect(
        events.where(
          (event) => event.type == OrchestrationEventType.runCompleted,
        ),
        hasLength(1),
      );
      expect(
        events
            .singleWhere(
              (event) =>
                  event.type == OrchestrationEventType.agentMessageCompleted,
            )
            .text,
        'current response',
      );
      expect(
        storeB.getRun(handle.runId).status,
        OrchestrationRunStatus.completed,
      );

      await storeA.close();
      await storeB.close();
      directory.deleteSync(recursive: true);
    },
  );
}

Future<void> _waitForTerminal(RunEventStore store, String runId) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (store.getRun(runId).status == OrchestrationRunStatus.running) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('run did not become terminal');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _FakeClock {
  _FakeClock(this.value);

  DateTime value;

  DateTime now() => value;

  void advance(Duration duration) {
    value = value.add(duration);
  }
}

class _Selector implements AgentSelector {
  const _Selector();

  @override
  Future<List<String>> select(AgentSelectionRequest request) async {
    return const ['product-manager'];
  }
}

class _Resolver implements RunInputResolver {
  const _Resolver();

  @override
  Future<String> resolve({required String inputRef, String? contextRef}) async {
    return '分析风险';
  }
}

class _BlockingRuntime
    implements AgentRuntime, IdempotentAgentRuntimeCapability {
  final started = Completer<void>();
  final _response = Completer<String>();

  @override
  bool get supportsIdempotency => true;

  void complete(String value) => _response.complete(value);

  @override
  Future<String> respond(AgentTurnRequest request) {
    if (!started.isCompleted) started.complete();
    return _response.future;
  }

  @override
  Future<String> summarize(DiscussionSummaryRequest request) async => 'summary';
}

class _ImmediateRuntime
    implements AgentRuntime, IdempotentAgentRuntimeCapability {
  const _ImmediateRuntime();

  @override
  bool get supportsIdempotency => true;

  @override
  Future<String> respond(AgentTurnRequest request) async => 'current response';

  @override
  Future<String> summarize(DiscussionSummaryRequest request) async => 'summary';
}

StartConversationRunCommand _command() {
  return const StartConversationRunCommand(
    clientCommandId: 'fencing-command',
    conversationId: 'fencing-conversation',
    hostAgentId: 'product-manager',
    input: '分析风险',
    inputRef: 'message://fencing/input',
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
    final directory = Directory.systemTemp.createTempSync('halo-fencing-');
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
