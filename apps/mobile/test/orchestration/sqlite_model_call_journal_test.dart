import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/orchestration/sqlite_model_call_journal.dart';

void main() {
  test(
    'completed idempotency key returns its one durable public result',
    () async {
      final fixture = _Fixture.create();
      final journal = SqliteModelCallJournal.open(fixture.path);
      try {
        expect(
          (await journal.reserve('call-1')).status,
          ModelCallStatus.reserved,
        );
        await journal.markDispatched('call-1');
        await journal.complete('call-1', publicResult: '{"answer":"safe"}');

        final repeated = await journal.reserve('call-1');
        expect(repeated.status, ModelCallStatus.completed);
        expect(repeated.publicResult, '{"answer":"safe"}');
      } finally {
        await journal.close();
        fixture.delete();
      }
    },
  );

  test(
    'a repeated dispatched key fails closed without becoming reservable',
    () async {
      final fixture = _Fixture.create();
      final journal = SqliteModelCallJournal.open(fixture.path);
      try {
        await journal.reserve('call-crash-window');
        await journal.markDispatched('call-crash-window');

        final repeated = await journal.reserve('call-crash-window');
        expect(repeated.status, ModelCallStatus.outcomeUnknown);
        expect(repeated.publicResult, isNull);
        expect(
          (await journal.get('call-crash-window'))!.status,
          ModelCallStatus.outcomeUnknown,
        );
      } finally {
        await journal.close();
        fixture.delete();
      }
    },
  );

  test(
    'journal never persists prompt-shaped data or provider error bodies',
    () async {
      const secret = 'sk-this-must-never-be-written-0123456789';
      final fixture = _Fixture.create();
      final journal = SqliteModelCallJournal.open(fixture.path);
      try {
        await journal.reserve('call-safe-error');
        await journal.fail(
          'call-safe-error',
          errorCode: ModelCallErrorCode.retryable,
        );
        await journal.close();

        final bytes = File(fixture.path).readAsBytesSync();
        final databaseText = String.fromCharCodes(bytes);
        expect(databaseText, isNot(contains(secret)));
        expect(databaseText, contains('retryable'));
      } finally {
        await journal.close();
        fixture.delete();
      }
    },
  );
}

final class _Fixture {
  _Fixture._(this.directory);

  final Directory directory;
  String get path => '${directory.path}/model-calls.sqlite';

  factory _Fixture.create() => _Fixture._(
    Directory.systemTemp.createTempSync('halo-model-call-journal-'),
  );

  void delete() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}
