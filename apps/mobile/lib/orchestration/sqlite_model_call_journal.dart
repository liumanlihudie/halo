import 'package:sqlite3/sqlite3.dart';

/// Durable provider-billing boundary, intentionally independent of the
/// runner's external-intent receipt fence. The runner owns event delivery;
/// this journal owns the unsafe interval after a provider has been dispatched.
enum ModelCallStatus { reserved, dispatched, completed, failed, outcomeUnknown }

enum ModelCallErrorCode {
  retryable,
  timeout,
  cancelled,
  contentFiltered,
  quotaExceeded,
  malformedOutput,
  configuration,
}

final class ModelCallJournalEntry {
  const ModelCallJournalEntry({
    required this.idempotencyKey,
    required this.status,
    this.publicResult,
    this.errorCode,
  });

  final String idempotencyKey;
  final ModelCallStatus status;
  final String? publicResult;
  final ModelCallErrorCode? errorCode;
}

final class SqliteModelCallJournal {
  SqliteModelCallJournal._(this._database) {
    _initialize();
  }

  factory SqliteModelCallJournal.open(String path) {
    final database = sqlite3.open(path);
    try {
      return SqliteModelCallJournal._(database);
    } on Object catch (error, stackTrace) {
      database.close();
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  final Database _database;
  var _closed = false;

  void _initialize() {
    _database.execute('PRAGMA journal_mode = WAL');
    _database.execute('PRAGMA busy_timeout = 5000');
    _database.execute('BEGIN IMMEDIATE');
    try {
      final version =
          _database.select('PRAGMA user_version').single.values.single as int;
      if (version == 0) {
        final existing = _database.select(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
        );
        if (existing.isNotEmpty) {
          throw StateError('Unknown model call journal schema');
        }
        _database.execute('''
          CREATE TABLE model_call_journal (
            idempotency_key TEXT PRIMARY KEY,
            status TEXT NOT NULL,
            public_result TEXT,
            error_code TEXT
          )
        ''');
        _database.execute('PRAGMA user_version = 1');
      } else if (version != 1) {
        throw StateError(
          'Unsupported model call journal schema version $version',
        );
      }
      _validateSchema();
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  void _validateSchema() {
    final columns = _database
        .select('PRAGMA table_info(model_call_journal)')
        .map((row) => row['name']! as String)
        .toSet();
    const required = {
      'idempotency_key',
      'status',
      'public_result',
      'error_code',
    };
    if (columns.length != required.length || !columns.containsAll(required)) {
      throw StateError('Invalid model call journal schema');
    }
  }

  Future<ModelCallJournalEntry> reserve(String idempotencyKey) async {
    _ensureOpen();
    if (idempotencyKey.trim().isEmpty || idempotencyKey.length > 512) {
      throw ArgumentError.value(idempotencyKey, 'idempotencyKey');
    }
    _database.execute('BEGIN IMMEDIATE');
    try {
      final current = _read(idempotencyKey);
      if (current == null) {
        _database.execute(
          'INSERT INTO model_call_journal (idempotency_key, status) VALUES (?, ?)',
          [idempotencyKey, ModelCallStatus.reserved.name],
        );
        _database.execute('COMMIT');
        return ModelCallJournalEntry(
          idempotencyKey: idempotencyKey,
          status: ModelCallStatus.reserved,
        );
      }
      if (current.status == ModelCallStatus.dispatched) {
        _database.execute(
          'UPDATE model_call_journal SET status = ? WHERE idempotency_key = ?',
          [ModelCallStatus.outcomeUnknown.name, idempotencyKey],
        );
        _database.execute('COMMIT');
        return ModelCallJournalEntry(
          idempotencyKey: idempotencyKey,
          status: ModelCallStatus.outcomeUnknown,
        );
      }
      _database.execute('COMMIT');
      return current;
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<void> markDispatched(String idempotencyKey) => _transition(
    idempotencyKey,
    allowed: {ModelCallStatus.reserved},
    status: ModelCallStatus.dispatched,
  );

  Future<void> complete(String idempotencyKey, {required String publicResult}) {
    if (publicResult.trim().isEmpty || publicResult.length > 65536) {
      throw ArgumentError.value(publicResult, 'publicResult');
    }
    return _transition(
      idempotencyKey,
      allowed: {ModelCallStatus.dispatched},
      status: ModelCallStatus.completed,
      publicResult: publicResult,
    );
  }

  Future<void> fail(
    String idempotencyKey, {
    required ModelCallErrorCode errorCode,
  }) => _transition(
    idempotencyKey,
    allowed: {ModelCallStatus.reserved},
    status: ModelCallStatus.failed,
    errorCode: errorCode,
  );

  Future<void> markOutcomeUnknown(String idempotencyKey) => _transition(
    idempotencyKey,
    allowed: {ModelCallStatus.dispatched},
    status: ModelCallStatus.outcomeUnknown,
  );

  Future<void> _transition(
    String idempotencyKey, {
    required Set<ModelCallStatus> allowed,
    required ModelCallStatus status,
    String? publicResult,
    ModelCallErrorCode? errorCode,
  }) async {
    _ensureOpen();
    _database.execute('BEGIN IMMEDIATE');
    try {
      final current = _read(idempotencyKey);
      if (current == null || !allowed.contains(current.status)) {
        throw StateError('Invalid model call journal transition');
      }
      _database.execute(
        'UPDATE model_call_journal SET status = ?, public_result = ?, error_code = ? WHERE idempotency_key = ?',
        [status.name, publicResult, errorCode?.name, idempotencyKey],
      );
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<ModelCallJournalEntry?> get(String idempotencyKey) async {
    _ensureOpen();
    return _read(idempotencyKey);
  }

  ModelCallJournalEntry? _read(String key) {
    final rows = _database.select(
      'SELECT idempotency_key, status, public_result, error_code FROM model_call_journal WHERE idempotency_key = ?',
      [key],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return ModelCallJournalEntry(
      idempotencyKey: row['idempotency_key']! as String,
      status: ModelCallStatus.values.byName(row['status']! as String),
      publicResult: row['public_result'] as String?,
      errorCode: switch (row['error_code'] as String?) {
        null => null,
        final value => ModelCallErrorCode.values.byName(value),
      },
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _database.close();
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Model call journal is closed');
  }
}
