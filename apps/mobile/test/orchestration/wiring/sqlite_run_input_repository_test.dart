import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';
import 'package:halo_mobile/orchestration/wiring/run_input_repository.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('rejects v1 with matching columns but wrong constraints', () async {
    final fixture = _InputDatabaseFixture.create();
    final repository = SqliteRunInputRepository.open(fixture.path);
    await repository.close();
    final database = sqlite3.open(fixture.path);
    database.execute('DROP INDEX idx_input_records_gc');
    database.execute('ALTER TABLE input_records RENAME TO old_input_records');
    database.execute('''
      CREATE TABLE input_records (
        input_ref TEXT PRIMARY KEY,
        context_ref TEXT,
        identity_hash TEXT NOT NULL,
        input_text TEXT NOT NULL,
        lifecycle TEXT NOT NULL,
        created_at_micros INTEGER NOT NULL
      )
    ''');
    database.execute('DROP TABLE old_input_records');
    database.execute('''
      CREATE INDEX idx_input_records_gc
      ON input_records (lifecycle, created_at_micros)
    ''');
    database.close();

    expect(() => SqliteRunInputRepository.open(fixture.path), throwsStateError);
    fixture.delete();
  });

  test('rejects v1 index with the right name but wrong column order', () async {
    final fixture = _InputDatabaseFixture.create();
    final repository = SqliteRunInputRepository.open(fixture.path);
    await repository.close();
    final database = sqlite3.open(fixture.path);
    database.execute('DROP INDEX idx_input_records_gc');
    database.execute('''
      CREATE INDEX idx_input_records_gc
      ON input_records (created_at_micros, lifecycle)
    ''');
    database.close();

    expect(() => SqliteRunInputRepository.open(fixture.path), throwsStateError);
    fixture.delete();
  });

  test('rejects a future schema version without downgrading it', () {
    final fixture = _InputDatabaseFixture.create();
    final database = sqlite3.open(fixture.path);
    database.execute('PRAGMA user_version = 2');
    database.close();

    expect(() => SqliteRunInputRepository.open(fixture.path), throwsStateError);

    final reopened = sqlite3.open(fixture.path);
    expect(reopened.select('PRAGMA user_version').first.values.first, 2);
    reopened.close();
    fixture.delete();
  });

  test('rejects a partial version-zero schema without completing it', () {
    final fixture = _InputDatabaseFixture.create();
    final database = sqlite3.open(fixture.path);
    database.execute('CREATE TABLE input_records (input_ref TEXT PRIMARY KEY)');
    database.close();

    expect(() => SqliteRunInputRepository.open(fixture.path), throwsStateError);

    final reopened = sqlite3.open(fixture.path);
    expect(reopened.select('PRAGMA user_version').first.values.first, 0);
    final tables = reopened.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
    );
    expect(tables.map((row) => row['name']), ['input_records']);
    reopened.close();
    fixture.delete();
  });

  test('valid version-one schema reopens without changing its owner', () async {
    final fixture = _InputDatabaseFixture.create();
    final first = SqliteRunInputRepository.open(fixture.path);
    await first.close();
    final rawFirst = sqlite3.open(fixture.path);
    final owner = rawFirst
        .select("SELECT value FROM repository_metadata WHERE key = 'owner_id'")
        .single['value'];
    rawFirst.close();

    final second = SqliteRunInputRepository.open(fixture.path);
    await second.close();
    final rawSecond = sqlite3.open(fixture.path);
    expect(
      rawSecond
          .select(
            "SELECT value FROM repository_metadata WHERE key = 'owner_id'",
          )
          .single['value'],
      owner,
    );
    expect(rawSecond.select('PRAGMA user_version').single.values.first, 1);
    rawSecond.close();
    fixture.delete();
  });

  test(
    'prepare rejects invalid and oversized commands before any row write',
    () async {
      final fixture = _InputDatabaseFixture.create();
      final repository = SqliteRunInputRepository.open(fixture.path);
      final invalid = <StartConversationRunCommand>[
        _command(input: 'x' * 4097),
        _command(clientCommandId: 'x' * 257),
        StartConversationRunCommand(
          clientCommandId: 'too-many-members',
          conversationId: 'group-product',
          hostAgentId: 'agent-0',
          input: 'safe',
          replyMode: ConversationReplyMode.auto,
          memberAgentIds: List.generate(9, (index) => 'agent-$index'),
        ),
      ];

      for (final command in invalid) {
        await expectLater(repository.prepare(command), throwsArgumentError);
      }
      await repository.close();

      final raw = sqlite3.open(fixture.path);
      expect(
        raw
            .select('SELECT COUNT(*) AS count FROM input_records')
            .single['count'],
        0,
      );
      expect(
        raw
            .select('SELECT COUNT(*) AS count FROM input_reservations')
            .single['count'],
        0,
      );
      raw.close();
      fixture.delete();
    },
  );

  test('committed input resolves after the repository is reopened', () async {
    final fixture = _InputDatabaseFixture.create();
    final first = SqliteRunInputRepository.open(fixture.path);
    final reservation = await first.prepare(_command());
    await first.commit(reservation);
    await first.close();

    final reopened = SqliteRunInputRepository.open(fixture.path);
    addTearDown(() async {
      await reopened.close();
      fixture.delete();
    });

    expect(
      await reopened.resolve(
        inputRef: reservation.inputRef,
        contextRef: reservation.contextRef,
      ),
      'PRIVATE_SQLITE_INPUT_SENTINEL',
    );
    await reopened.markReferenced(reservation);
    expect(
      await reopened.lifecycleOf(reservation),
      RunInputLifecycle.referenced,
    );
  });

  test('prepare is transactional across an injected failure', () async {
    final fixture = _InputDatabaseFixture.create();
    final failing = SqliteRunInputRepository.open(
      fixture.path,
      failureInjector: (point) {
        if (point == SqliteRunInputFailurePoint.beforePrepareCommit) {
          throw StateError('injected prepare failure');
        }
      },
    );
    await expectLater(failing.prepare(_command()), throwsStateError);
    await failing.close();

    final reopened = SqliteRunInputRepository.open(fixture.path);
    addTearDown(() async {
      await reopened.close();
      fixture.delete();
    });
    final replacement = await reopened.prepare(_command(input: 'replacement'));
    await reopened.commit(replacement);
    expect(
      await reopened.resolve(
        inputRef: replacement.inputRef,
        contextRef: replacement.contextRef,
      ),
      'replacement',
    );
  });

  test(
    'initialization failure closes its database and preserves the error',
    () async {
      final fixture = _InputDatabaseFixture.create();
      final original = StateError('injected initialization failure');

      expect(
        () => SqliteRunInputRepository.open(
          fixture.path,
          failureInjector: (point) {
            if (point == SqliteRunInputFailurePoint.afterSchemaInitialized) {
              throw original;
            }
          },
        ),
        throwsA(same(original)),
      );

      final reopened = SqliteRunInputRepository.open(fixture.path);
      await reopened.close();
      fixture.delete();
    },
  );

  test(
    'full reservation ownership tuple persists and rejects another DB',
    () async {
      final firstFixture = _InputDatabaseFixture.create();
      final secondFixture = _InputDatabaseFixture.create();
      final first = SqliteRunInputRepository.open(firstFixture.path);
      final second = SqliteRunInputRepository.open(secondFixture.path);
      addTearDown(() async {
        await first.close();
        await second.close();
        firstFixture.delete();
        secondFixture.delete();
      });
      final reservation = await first.prepare(_command());

      await expectLater(
        second.commit(reservation),
        throwsA(isA<RunInputIdentityConflict>()),
      );
      await expectLater(
        second.rollback(reservation),
        throwsA(isA<RunInputIdentityConflict>()),
      );
    },
  );

  test(
    'GC uses a strict cutoff and checks every candidate reference',
    () async {
      var now = DateTime.utc(2026, 7, 29, 12);
      final fixture = _InputDatabaseFixture.create();
      final repository = SqliteRunInputRepository.open(
        fixture.path,
        clock: () => now,
      );
      addTearDown(() async {
        await repository.close();
        fixture.delete();
      });
      final equalCutoff = await repository.prepare(
        _command(clientCommandId: 'equal'),
      );
      await repository.commit(equalCutoff);
      now = now.subtract(const Duration(seconds: 1));
      final older = await repository.prepare(
        _command(clientCommandId: 'older'),
      );
      await repository.commit(older);
      final probed = <(String, String)>[];

      final firstPass = await repository.collectOrphans(
        olderThan: DateTime.utc(2026, 7, 29, 12),
        isReferenced: (inputRef, contextRef) async {
          probed.add((inputRef, contextRef));
          return inputRef == older.inputRef;
        },
      );

      expect(firstPass, 0);
      expect(probed, [(older.inputRef, older.contextRef)]);
      expect(await repository.lifecycleOf(older), RunInputLifecycle.referenced);
      expect(
        await repository.lifecycleOf(equalCutoff),
        RunInputLifecycle.resolvableOrphan,
      );

      final secondPass = await repository.collectOrphans(
        olderThan: DateTime.utc(2026, 7, 29, 12, 0, 0, 1),
        isReferenced: (_, _) async => false,
      );
      expect(secondPass, 1);
      await expectLater(
        repository.resolve(
          inputRef: equalCutoff.inputRef,
          contextRef: equalCutoff.contextRef,
        ),
        throwsA(isA<RunInputUnavailable>()),
      );
    },
  );

  test(
    'uses WAL, busy timeout, schema version, and idempotent close',
    () async {
      final fixture = _InputDatabaseFixture.create();
      final repository = SqliteRunInputRepository.open(fixture.path);

      expect(repository.runtimeConfiguration.journalMode.toLowerCase(), 'wal');
      expect(repository.runtimeConfiguration.busyTimeoutMilliseconds, 5000);
      expect(repository.runtimeConfiguration.schemaVersion, 1);

      await repository.close();
      await repository.close();
      await expectLater(repository.prepare(_command()), throwsStateError);
      fixture.delete();
    },
  );

  test(
    'input DB stores sandbox plaintext while event-safe objects omit it',
    () async {
      final fixture = _InputDatabaseFixture.create();
      final repository = SqliteRunInputRepository.open(fixture.path);
      final reservation = await repository.prepare(_command());
      await repository.commit(reservation);
      await repository.close();

      final searchable = utf8.decode(
        File(fixture.path).readAsBytesSync(),
        allowMalformed: true,
      );
      expect(searchable, contains('PRIVATE_SQLITE_INPUT_SENTINEL'));
      expect(
        reservation.toString(),
        isNot(contains('PRIVATE_SQLITE_INPUT_SENTINEL')),
      );
      fixture.delete();
    },
  );
}

StartConversationRunCommand _command({
  String clientCommandId = 'sqlite-input-command',
  String input = 'PRIVATE_SQLITE_INPUT_SENTINEL',
}) {
  return StartConversationRunCommand(
    clientCommandId: clientCommandId,
    conversationId: 'group-product',
    hostAgentId: 'product-manager',
    input: input,
    replyMode: ConversationReplyMode.auto,
    memberAgentIds: const ['product-manager'],
  );
}

class _InputDatabaseFixture {
  _InputDatabaseFixture._(this.directory, this.path);

  factory _InputDatabaseFixture.create() {
    final directory = Directory.systemTemp.createTempSync('halo-input-db-');
    return _InputDatabaseFixture._(
      directory,
      '${directory.path}/halo_run_inputs.sqlite',
    );
  }

  final Directory directory;
  final String path;

  void delete() => directory.deleteSync(recursive: true);
}
