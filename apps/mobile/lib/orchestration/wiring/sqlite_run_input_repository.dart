part of 'run_input_repository.dart';

enum SqliteRunInputFailurePoint { afterSchemaInitialized, beforePrepareCommit }

typedef SqliteRunInputFailureInjector =
    void Function(SqliteRunInputFailurePoint point);

class SqliteRunInputRuntimeConfiguration {
  const SqliteRunInputRuntimeConfiguration({
    required this.journalMode,
    required this.busyTimeoutMilliseconds,
    required this.schemaVersion,
  });

  final String journalMode;
  final int busyTimeoutMilliseconds;
  final int schemaVersion;
}

final class SqliteRunInputRepository implements DurableRunInputRepository {
  SqliteRunInputRepository._(
    this._database,
    this._clock,
    this._failureInjector,
  ) {
    _initialize();
  }

  factory SqliteRunInputRepository.open(
    String path, {
    DateTime Function() clock = DateTime.now,
    SqliteRunInputFailureInjector? failureInjector,
  }) {
    final database = sqlite3.open(path);
    try {
      return SqliteRunInputRepository._(database, clock, failureInjector);
    } on Object catch (error, stackTrace) {
      try {
        database.close();
      } on Object {
        // Closing a failed initialization must not replace its original error.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  final Database _database;
  final DateTime Function() _clock;
  final SqliteRunInputFailureInjector? _failureInjector;
  final Random _random = Random.secure();
  late final String _ownerId;
  late final SqliteRunInputRuntimeConfiguration runtimeConfiguration;
  bool _closed = false;
  Future<void>? _closeFuture;

  void _initialize() {
    _database.execute('PRAGMA journal_mode = WAL');
    _database.execute('PRAGMA busy_timeout = 5000');
    _database.execute('PRAGMA foreign_keys = ON');
    _database.execute('BEGIN IMMEDIATE');
    try {
      final version =
          _database.select('PRAGMA user_version').first.values.first! as int;
      if (version == 0) {
        if (!_schemaIsEmpty()) {
          throw StateError(
            'Run input database has an unknown partial version-zero schema',
          );
        }
        _createSchema();
        final ownerId = _secureToken();
        _database.execute(
          'INSERT INTO repository_metadata (key, value) VALUES (?, ?)',
          ['owner_id', ownerId],
        );
        _database.execute('PRAGMA user_version = 1');
      } else if (version == 1) {
        _validateVersionOneSchema();
      } else {
        throw StateError(
          'Unsupported run input database schema version $version',
        );
      }
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
    _validateVersionOneSchema();
    _ownerId = _readOwner();
    runtimeConfiguration = SqliteRunInputRuntimeConfiguration(
      journalMode:
          _database.select('PRAGMA journal_mode').first.values.first! as String,
      busyTimeoutMilliseconds:
          _database.select('PRAGMA busy_timeout').first.values.first! as int,
      schemaVersion:
          _database.select('PRAGMA user_version').first.values.first! as int,
    );
    _failureInjector?.call(SqliteRunInputFailurePoint.afterSchemaInitialized);
  }

  bool _schemaIsEmpty() {
    return _database.select('''
      SELECT 1
      FROM sqlite_master
      WHERE type IN ('table', 'index')
        AND name NOT LIKE 'sqlite_%'
      LIMIT 1
    ''').isEmpty;
  }

  void _createSchema() {
    _database.execute('''
      CREATE TABLE repository_metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    _database.execute('''
      CREATE TABLE input_records (
        input_ref TEXT PRIMARY KEY,
        context_ref TEXT NOT NULL,
        identity_hash TEXT NOT NULL,
        input_text TEXT NOT NULL,
        lifecycle TEXT NOT NULL,
        created_at_micros INTEGER NOT NULL
      )
    ''');
    _database.execute('''
      CREATE TABLE input_reservations (
        token TEXT PRIMARY KEY,
        input_ref TEXT NOT NULL,
        context_ref TEXT NOT NULL,
        identity_hash TEXT NOT NULL,
        owner_id TEXT NOT NULL,
        created_record INTEGER NOT NULL,
        lifecycle TEXT NOT NULL
      )
    ''');
    _database.execute('''
      CREATE INDEX idx_input_records_gc
      ON input_records (lifecycle, created_at_micros)
    ''');
    _database.execute('''
      CREATE INDEX idx_input_reservations_ref
      ON input_reservations (input_ref, lifecycle)
    ''');
  }

  void _validateVersionOneSchema() {
    const requiredColumns = <String, Set<String>>{
      'repository_metadata': {'key', 'value'},
      'input_records': {
        'input_ref',
        'context_ref',
        'identity_hash',
        'input_text',
        'lifecycle',
        'created_at_micros',
      },
      'input_reservations': {
        'token',
        'input_ref',
        'context_ref',
        'identity_hash',
        'owner_id',
        'created_record',
        'lifecycle',
      },
    };
    for (final entry in requiredColumns.entries) {
      final rows = _database.select('PRAGMA table_info(${entry.key})');
      final actual = rows.map((row) => row['name']! as String).toSet();
      if (actual.length != entry.value.length ||
          !actual.containsAll(entry.value)) {
        throw StateError('Invalid run input database table ${entry.key}');
      }
      for (final row in rows) {
        final name = row['name']! as String;
        final isPrimary = switch (entry.key) {
          'repository_metadata' => name == 'key',
          'input_records' => name == 'input_ref',
          'input_reservations' => name == 'token',
          _ => false,
        };
        final expectedType =
            {'created_at_micros', 'created_record'}.contains(name)
            ? 'INTEGER'
            : 'TEXT';
        if (row['type'] != expectedType ||
            row['pk'] != (isPrimary ? 1 : 0) ||
            row['notnull'] != (isPrimary ? 0 : 1) ||
            row['dflt_value'] != null) {
          throw StateError(
            'Invalid run input database column ${entry.key}.$name',
          );
        }
      }
    }
    for (final index in const {
      'idx_input_records_gc': (
        table: 'input_records',
        columns: ['lifecycle', 'created_at_micros'],
      ),
      'idx_input_reservations_ref': (
        table: 'input_reservations',
        columns: ['input_ref', 'lifecycle'],
      ),
    }.entries) {
      final listed = _database
          .select('PRAGMA index_list(${index.value.table})')
          .where((row) => row['name'] == index.key)
          .toList();
      final columns = _database
          .select('PRAGMA index_info(${index.key})')
          .map((row) => row['name'])
          .toList();
      if (listed.length != 1 ||
          listed.single['unique'] != 0 ||
          !_sameList(columns, index.value.columns)) {
        throw StateError('Invalid run input database index ${index.key}');
      }
    }
    for (final table in requiredColumns.keys) {
      if (_database.select('PRAGMA foreign_key_list($table)').isNotEmpty) {
        throw StateError('Unexpected run input database foreign key in $table');
      }
    }
    _readOwner();
  }

  bool _sameList(List<Object?> actual, List<String> expected) =>
      actual.length == expected.length &&
      List.generate(
        expected.length,
        (i) => actual[i] == expected[i],
      ).every((value) => value);

  String _readOwner() {
    final owners = _database.select(
      "SELECT value FROM repository_metadata WHERE key = 'owner_id'",
    );
    if (owners.length != 1 ||
        owners.single['value'] is! String ||
        (owners.single['value']! as String).isEmpty) {
      throw StateError('Run input database owner metadata is missing');
    }
    return owners.single['value']! as String;
  }

  @override
  Future<RunInputReservation> prepare(
    StartConversationRunCommand command,
  ) async {
    _ensureOpen();
    StartConversationCommandValidator.validate(command);
    final inputRef =
        'halo-run-input://sha256/'
        '${_structuredDigest('run-input-reference-v1', [command.clientCommandId])}';
    final contextRef =
        'halo-run-context://sha256/'
        '${_structuredDigest('run-context-reference-v1', [command.clientCommandId])}';
    final identityHash = _structuredDigest('run-input-identity-v1', [
      command.clientCommandId,
      command.conversationId,
      command.hostAgentId,
      command.input,
      command.contextRef ?? '',
      command.replyMode.name,
      command.memberAgentIds.length.toString(),
      ...command.memberAgentIds,
      command.mentionedAgentIds.length.toString(),
      ...command.mentionedAgentIds,
    ]);
    return _transaction(() {
      final existing = _database.select(
        '''
          SELECT identity_hash
          FROM input_records
          WHERE input_ref = ?
        ''',
        [inputRef],
      );
      if (existing.isNotEmpty &&
          existing.first['identity_hash'] != identityHash) {
        throw RunInputIdentityConflict(inputRef);
      }
      final createdRecord = existing.isEmpty;
      if (createdRecord) {
        // This is plaintext inside the app sandbox, not encryption. Backups,
        // jailbroken devices, forensic access, SQLite free pages, and WAL files
        // may retain it; orphan GC is not secure erase. Application-layer
        // encryption is deferred to the dedicated security package.
        _database.execute(
          '''
            INSERT INTO input_records (
              input_ref, context_ref, identity_hash, input_text,
              lifecycle, created_at_micros
            ) VALUES (?, ?, ?, ?, ?, ?)
          ''',
          [
            inputRef,
            contextRef,
            identityHash,
            command.input,
            RunInputLifecycle.staged.name,
            _clock().microsecondsSinceEpoch,
          ],
        );
      }
      var token = _secureToken();
      while (_database.select(
        'SELECT 1 FROM input_reservations WHERE token = ? LIMIT 1',
        [token],
      ).isNotEmpty) {
        token = _secureToken();
      }
      _database.execute(
        '''
          INSERT INTO input_reservations (
            token, input_ref, context_ref, identity_hash, owner_id,
            created_record, lifecycle
          ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          token,
          inputRef,
          contextRef,
          identityHash,
          _ownerId,
          createdRecord ? 1 : 0,
          RunInputLifecycle.staged.name,
        ],
      );
      _failureInjector?.call(SqliteRunInputFailurePoint.beforePrepareCommit);
      return RunInputReservation._(
        inputRef: inputRef,
        contextRef: contextRef,
        token: token,
        ownerId: _ownerId,
        identityHash: identityHash,
        createdRecord: createdRecord,
      );
    });
  }

  @override
  Future<void> commit(RunInputReservation reservation) async {
    _ensureOpen();
    _transaction(() {
      final row = _reservationRow(reservation);
      final lifecycle = _lifecycle(row['lifecycle']);
      if (lifecycle == RunInputLifecycle.resolvableOrphan ||
          lifecycle == RunInputLifecycle.referenced) {
        return;
      }
      if (lifecycle != RunInputLifecycle.staged) {
        throw RunInputIdentityConflict(reservation.inputRef);
      }
      _requireRecord(reservation);
      _database.execute(
        'UPDATE input_reservations SET lifecycle = ? WHERE token = ?',
        [RunInputLifecycle.resolvableOrphan.name, reservation.token],
      );
      _database.execute(
        '''
          UPDATE input_records
          SET lifecycle = ?
          WHERE input_ref = ? AND lifecycle = ?
        ''',
        [
          RunInputLifecycle.resolvableOrphan.name,
          reservation.inputRef,
          RunInputLifecycle.staged.name,
        ],
      );
    });
  }

  @override
  Future<void> markReferenced(RunInputReservation reservation) async {
    _ensureOpen();
    _transaction(() {
      final row = _reservationRow(reservation);
      final lifecycle = _lifecycle(row['lifecycle']);
      if (lifecycle == RunInputLifecycle.referenced) return;
      if (lifecycle != RunInputLifecycle.resolvableOrphan) {
        throw RunInputIdentityConflict(reservation.inputRef);
      }
      _requireRecord(reservation);
      _database.execute(
        'UPDATE input_reservations SET lifecycle = ? WHERE token = ?',
        [RunInputLifecycle.referenced.name, reservation.token],
      );
      _database.execute(
        'UPDATE input_records SET lifecycle = ? WHERE input_ref = ?',
        [RunInputLifecycle.referenced.name, reservation.inputRef],
      );
    });
  }

  @override
  Future<void> rollback(RunInputReservation reservation) async {
    _ensureOpen();
    _transaction(() {
      final row = _reservationRow(reservation);
      final lifecycle = _lifecycle(row['lifecycle']);
      if (lifecycle == RunInputLifecycle.rolledBack ||
          lifecycle == RunInputLifecycle.referenced) {
        return;
      }
      final record = _database.select(
        'SELECT lifecycle FROM input_records WHERE input_ref = ?',
        [reservation.inputRef],
      );
      if (record.isEmpty) {
        throw RunInputIdentityConflict(reservation.inputRef);
      }
      if (_lifecycle(record.first['lifecycle']) ==
          RunInputLifecycle.referenced) {
        return;
      }
      _database.execute(
        'UPDATE input_reservations SET lifecycle = ? WHERE token = ?',
        [RunInputLifecycle.rolledBack.name, reservation.token],
      );
      if (reservation._createdRecord) {
        final otherHolders = _database.select(
          '''
            SELECT 1
            FROM input_reservations
            WHERE input_ref = ? AND token != ? AND lifecycle != ?
            LIMIT 1
          ''',
          [
            reservation.inputRef,
            reservation.token,
            RunInputLifecycle.rolledBack.name,
          ],
        );
        if (otherHolders.isEmpty) {
          _database.execute('DELETE FROM input_records WHERE input_ref = ?', [
            reservation.inputRef,
          ]);
        }
      }
    });
  }

  @override
  Future<RunInputLifecycle> lifecycleOf(RunInputReservation reservation) async {
    _ensureOpen();
    final reservationRow = _reservationRow(reservation);
    final record = _database.select(
      'SELECT lifecycle FROM input_records WHERE input_ref = ?',
      [reservation.inputRef],
    );
    return record.isEmpty
        ? _lifecycle(reservationRow['lifecycle'])
        : _lifecycle(record.first['lifecycle']);
  }

  @override
  Future<String> resolve({required String inputRef, String? contextRef}) async {
    _ensureOpen();
    final rows = _database.select(
      '''
        SELECT input_text
        FROM input_records
        WHERE input_ref = ?
          AND context_ref = ?
          AND lifecycle IN (?, ?)
        LIMIT 1
      ''',
      [
        inputRef,
        contextRef,
        RunInputLifecycle.resolvableOrphan.name,
        RunInputLifecycle.referenced.name,
      ],
    );
    if (rows.isEmpty) throw RunInputUnavailable(inputRef);
    return rows.first['input_text']! as String;
  }

  @override
  Future<int> collectOrphans({
    required DateTime olderThan,
    required RunInputReferenceProbe isReferenced,
  }) async {
    _ensureOpen();
    final candidates = _database.select(
      '''
        SELECT input_ref, context_ref
        FROM input_records
        WHERE lifecycle != ? AND created_at_micros < ?
        ORDER BY input_ref
      ''',
      [RunInputLifecycle.referenced.name, olderThan.microsecondsSinceEpoch],
    );
    var removed = 0;
    for (final candidate in candidates) {
      final inputRef = candidate['input_ref']! as String;
      final contextRef = candidate['context_ref']! as String;
      if (await isReferenced(inputRef, contextRef)) {
        _transaction(() {
          _database.execute(
            'UPDATE input_records SET lifecycle = ? WHERE input_ref = ?',
            [RunInputLifecycle.referenced.name, inputRef],
          );
          _database.execute(
            '''
              UPDATE input_reservations
              SET lifecycle = ?
              WHERE input_ref = ? AND lifecycle != ?
            ''',
            [
              RunInputLifecycle.referenced.name,
              inputRef,
              RunInputLifecycle.rolledBack.name,
            ],
          );
        });
        continue;
      }
      final didRemove = _transaction(() {
        final current = _database.select(
          '''
            SELECT 1
            FROM input_records
            WHERE input_ref = ? AND lifecycle != ? AND created_at_micros < ?
          ''',
          [
            inputRef,
            RunInputLifecycle.referenced.name,
            olderThan.microsecondsSinceEpoch,
          ],
        );
        if (current.isEmpty) return false;
        _database.execute(
          'UPDATE input_reservations SET lifecycle = ? WHERE input_ref = ?',
          [RunInputLifecycle.rolledBack.name, inputRef],
        );
        _database.execute('DELETE FROM input_records WHERE input_ref = ?', [
          inputRef,
        ]);
        return true;
      });
      if (didRemove) removed++;
    }
    return removed;
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    _database.close();
  }

  Row _reservationRow(RunInputReservation reservation) {
    final rows = _database.select(
      '''
        SELECT *
        FROM input_reservations
        WHERE token = ?
      ''',
      [reservation.token],
    );
    if (rows.isEmpty) throw RunInputIdentityConflict(reservation.inputRef);
    final row = rows.first;
    if (row['input_ref'] != reservation.inputRef ||
        row['context_ref'] != reservation.contextRef ||
        row['identity_hash'] != reservation._identityHash ||
        row['owner_id'] != _ownerId ||
        row['owner_id'] != reservation._ownerId ||
        row['created_record'] != (reservation._createdRecord ? 1 : 0)) {
      throw RunInputIdentityConflict(reservation.inputRef);
    }
    return row;
  }

  void _requireRecord(RunInputReservation reservation) {
    final rows = _database.select(
      '''
        SELECT 1
        FROM input_records
        WHERE input_ref = ? AND context_ref = ? AND identity_hash = ?
      ''',
      [reservation.inputRef, reservation.contextRef, reservation._identityHash],
    );
    if (rows.isEmpty) throw RunInputIdentityConflict(reservation.inputRef);
  }

  RunInputLifecycle _lifecycle(Object? value) {
    if (value is! String) throw StateError('Invalid input lifecycle');
    return RunInputLifecycle.values.byName(value);
  }

  T _transaction<T>(T Function() operation) {
    _database.execute('BEGIN IMMEDIATE');
    try {
      final result = operation();
      _database.execute('COMMIT');
      return result;
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  String _secureToken() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  void _ensureOpen() {
    if (_closed) throw StateError('RunInputRepository is closed');
  }
}
