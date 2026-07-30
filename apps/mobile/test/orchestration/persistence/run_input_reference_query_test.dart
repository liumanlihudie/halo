import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';
import 'package:halo_mobile/orchestration/persistence/sqlite_run_event_store.dart';
import 'package:halo_mobile/orchestration/run_event_store.dart';

void main() {
  for (final entry in <(String, _StoreFixture Function())>[
    ('memory', _memoryFixture),
    ('sqlite', _sqliteFixture),
  ]) {
    test('${entry.$1} queries exact persisted input references', () async {
      final testStore = entry.$2();
      addTearDown(testStore.close);

      expect(
        testStore.store.hasRunInputReference('input-ref', 'context-ref'),
        isFalse,
      );
      testStore.store.createRun(_command());

      expect(
        testStore.store.hasRunInputReference('input-ref', 'context-ref'),
        isTrue,
      );
      expect(
        testStore.store.hasRunInputReference('input-ref', 'other-context'),
        isFalse,
      );
      expect(
        testStore.store.hasRunInputReference(
          "input-ref' OR 1=1 --",
          'context-ref',
        ),
        isFalse,
      );
    });
  }

  test(
    'SQLite reports a run reference when createRun throws after commit',
    () async {
      final directory = Directory.systemTemp.createTempSync('halo-ref-query-');
      final path = '${directory.path}/events.sqlite';
      final store = SqliteRunEventStore.open(
        path,
        failureInjector: (point) {
          if (point == SqliteFailurePoint.afterCreateCommit) {
            throw StateError('after commit');
          }
        },
      );
      addTearDown(() async {
        await store.close();
        directory.deleteSync(recursive: true);
      });

      expect(() => store.createRun(_command()), throwsStateError);

      expect(store.hasRunInputReference('input-ref', 'context-ref'), isTrue);
    },
  );
}

StartConversationRunCommand _command() {
  return const StartConversationRunCommand(
    clientCommandId: 'reference-query-command',
    conversationId: 'group-product',
    hostAgentId: 'product-manager',
    input: 'private input',
    inputRef: 'input-ref',
    contextRef: 'context-ref',
    replyMode: ConversationReplyMode.auto,
    memberAgentIds: ['product-manager'],
  );
}

_StoreFixture _memoryFixture() {
  final store = InMemoryRunEventStore();
  return _StoreFixture(store, store.close);
}

_StoreFixture _sqliteFixture() {
  final directory = Directory.systemTemp.createTempSync('halo-ref-query-');
  final store = SqliteRunEventStore.open('${directory.path}/events.sqlite');
  return _StoreFixture(store, () async {
    await store.close();
    directory.deleteSync(recursive: true);
  });
}

class _StoreFixture {
  const _StoreFixture(this.store, this.close);

  final RunEventStore store;
  final Future<void> Function() close;
}
