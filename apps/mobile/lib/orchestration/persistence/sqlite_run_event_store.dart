import 'dart:async';
import 'dart:convert';

import 'package:halo_mobile/orchestration/orchestration_models.dart';
import 'package:halo_mobile/orchestration/run_event_store.dart';
import 'package:sqlite3/sqlite3.dart';

enum SqliteFailurePoint {
  afterRunInserted,
  afterRunCreatedInserted,
  afterWorkItemInserted,
  afterCommandMappingInserted,
  beforeCreateCommit,
  afterTransitionEventInserted,
  afterSnapshotUpdated,
  afterWorkItemUpdated,
  beforeTransitionCommit,
}

typedef SqliteFailureInjector = void Function(SqliteFailurePoint point);

class SqliteRuntimeConfiguration {
  const SqliteRuntimeConfiguration({
    required this.journalMode,
    required this.busyTimeoutMilliseconds,
  });

  final String journalMode;
  final int busyTimeoutMilliseconds;
}

final class SqliteRunEventStore implements RunEventStore {
  SqliteRunEventStore._(
    this._database,
    this._watchPollInterval,
    this._failureInjector,
  ) {
    _initialize();
  }

  factory SqliteRunEventStore.open(
    String path, {
    Duration watchPollInterval = const Duration(milliseconds: 25),
    SqliteFailureInjector? failureInjector,
  }) {
    return SqliteRunEventStore._(
      sqlite3.open(path),
      watchPollInterval,
      failureInjector,
    );
  }

  final Database _database;
  final Duration _watchPollInterval;
  final SqliteFailureInjector? _failureInjector;
  final Set<_WatchRegistration> _watchers = {};
  late final SqliteRuntimeConfiguration runtimeConfiguration;
  bool _closed = false;
  Future<void>? _closeFuture;

  @override
  bool get requiresRecoveryReferences => true;

  void _initialize() {
    _database.execute('PRAGMA journal_mode = WAL');
    _database.execute('PRAGMA busy_timeout = 5000');
    _database.execute('PRAGMA foreign_keys = ON');
    runtimeConfiguration = SqliteRuntimeConfiguration(
      journalMode:
          _database.select('PRAGMA journal_mode').first.values.first! as String,
      busyTimeoutMilliseconds:
          _database.select('PRAGMA busy_timeout').first.values.first! as int,
    );
    _database.execute('''
      CREATE TABLE IF NOT EXISTS runs (
        run_id TEXT PRIMARY KEY,
        status TEXT NOT NULL,
        last_seq INTEGER NOT NULL,
        executable_agent_ids TEXT NOT NULL
      )
    ''');
    _database.execute('''
      CREATE TABLE IF NOT EXISTS command_runs (
        client_command_id TEXT PRIMARY KEY,
        request_hash TEXT NOT NULL,
        run_id TEXT NOT NULL REFERENCES runs(run_id)
      )
    ''');
    _database.execute('''
      CREATE TABLE IF NOT EXISTS work_items (
        run_id TEXT PRIMARY KEY REFERENCES runs(run_id),
        client_command_id TEXT NOT NULL,
        request_hash TEXT NOT NULL,
        conversation_id TEXT NOT NULL,
        host_agent_id TEXT NOT NULL,
        reply_mode TEXT NOT NULL,
        member_agent_ids TEXT NOT NULL,
        mentioned_agent_ids TEXT NOT NULL,
        input_ref TEXT,
        context_ref TEXT,
        checkpoint TEXT NOT NULL,
        next_agent_index INTEGER NOT NULL
      )
    ''');
    _database.execute('''
      CREATE TABLE IF NOT EXISTS events (
        run_id TEXT NOT NULL REFERENCES runs(run_id),
        seq INTEGER NOT NULL,
        event_id TEXT NOT NULL UNIQUE,
        type TEXT NOT NULL,
        stage TEXT NOT NULL,
        agent_id TEXT,
        text TEXT,
        text_provenance TEXT,
        selected_agent_ids TEXT NOT NULL,
        error_code TEXT,
        causation_id TEXT NOT NULL,
        dedupe_key TEXT NOT NULL,
        transition_hash TEXT NOT NULL,
        PRIMARY KEY (run_id, seq),
        UNIQUE (run_id, dedupe_key)
      )
    ''');
    final eventColumns = _database
        .select('PRAGMA table_info(events)')
        .map((row) => row['name'])
        .toSet();
    if (!eventColumns.contains('text_provenance')) {
      _database.execute('ALTER TABLE events ADD COLUMN text_provenance TEXT');
      _database.execute(
        "UPDATE events SET text_provenance = 'trustedApplication' "
        'WHERE text IS NOT NULL',
      );
    }
    _database.execute('''
      CREATE TABLE IF NOT EXISTS external_call_intents (
        intent_id TEXT PRIMARY KEY,
        idempotency_key TEXT NOT NULL UNIQUE,
        run_id TEXT NOT NULL REFERENCES runs(run_id),
        kind TEXT NOT NULL,
        agent_id TEXT,
        status TEXT NOT NULL,
        lease_owner TEXT,
        lease_expires_at INTEGER,
        attempt INTEGER NOT NULL,
        fencing_token INTEGER NOT NULL,
        result_text TEXT,
        result_provenance TEXT
      )
    ''');
    final intentColumns = _database
        .select('PRAGMA table_info(external_call_intents)')
        .map((row) => row['name'])
        .toSet();
    if (!intentColumns.contains('fencing_token')) {
      _database.execute(
        'ALTER TABLE external_call_intents '
        'ADD COLUMN fencing_token INTEGER NOT NULL DEFAULT 0',
      );
    }
    _database.execute('''
      CREATE TABLE IF NOT EXISTS store_metadata (
        key TEXT PRIMARY KEY,
        int_value INTEGER NOT NULL
      )
    ''');
    _database.execute('''
      INSERT OR IGNORE INTO store_metadata (key, int_value)
      VALUES ('next_run_number', 1)
    ''');
  }

  @override
  ({RunSnapshot snapshot, bool created}) createRun(
    StartConversationRunCommand command,
  ) {
    _ensureOpen();
    if (command.inputRef == null || command.inputRef!.trim().isEmpty) {
      throw ArgumentError('Durable runs require a non-empty input reference');
    }
    return _transaction(() {
      final existing = _database.select(
        '''
          SELECT request_hash, run_id
          FROM command_runs
          WHERE client_command_id = ?
        ''',
        [command.clientCommandId],
      );
      if (existing.isNotEmpty) {
        if (existing.first['request_hash'] != command.requestHash) {
          throw CommandIdentityConflict(command.clientCommandId);
        }
        return (
          snapshot: _readRun(existing.first['run_id']! as String),
          created: false,
        );
      }

      final metadata = _database.select('''
        SELECT int_value
        FROM store_metadata
        WHERE key = 'next_run_number'
      ''');
      final nextRunNumber = metadata.first['int_value']! as int;
      final runId = 'run-$nextRunNumber';
      final snapshot = RunSnapshot(
        runId: runId,
        status: OrchestrationRunStatus.running,
        lastSeq: 1,
        executableAgentIds: const [],
      );
      final event = OrchestrationEvent(
        eventId: '$runId-event-1',
        runId: runId,
        seq: 1,
        type: OrchestrationEventType.runCreated,
        stage: ConversationStage.preparing,
        causationId: 'command:${command.clientCommandId}',
        dedupeKey: 'run-created',
      );

      _database.execute(
        '''
          INSERT INTO runs (
            run_id, status, last_seq, executable_agent_ids
          ) VALUES (?, ?, ?, ?)
        ''',
        [runId, snapshot.status.name, 1, jsonEncode(const <String>[])],
      );
      _inject(SqliteFailurePoint.afterRunInserted);
      _insertEvent(event, transitionHash: 'run-created');
      _inject(SqliteFailurePoint.afterRunCreatedInserted);
      _database.execute(
        '''
          INSERT INTO work_items (
            run_id,
            client_command_id,
            request_hash,
            conversation_id,
            host_agent_id,
            reply_mode,
            member_agent_ids,
            mentioned_agent_ids,
            input_ref,
            context_ref,
            checkpoint,
            next_agent_index
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          runId,
          command.clientCommandId,
          command.requestHash,
          command.conversationId,
          command.hostAgentId,
          command.replyMode.name,
          jsonEncode(command.memberAgentIds),
          jsonEncode(command.mentionedAgentIds),
          command.inputRef,
          command.contextRef,
          RunCheckpoint.created.name,
          0,
        ],
      );
      _inject(SqliteFailurePoint.afterWorkItemInserted);
      _database.execute(
        '''
          INSERT INTO command_runs (client_command_id, request_hash, run_id)
          VALUES (?, ?, ?)
        ''',
        [command.clientCommandId, command.requestHash, runId],
      );
      _inject(SqliteFailurePoint.afterCommandMappingInserted);
      _database.execute(
        '''
          UPDATE store_metadata
          SET int_value = ?
          WHERE key = 'next_run_number'
        ''',
        [nextRunNumber + 1],
      );
      _inject(SqliteFailurePoint.beforeCreateCommit);
      return (snapshot: snapshot, created: true);
    });
  }

  @override
  TransitionCommit commitTransition(RunTransitionRequest request) {
    _ensureOpen();
    EventPayloadPolicy.validate(request);
    return _transaction(() {
      final executable = request.executableAgentIds;
      if (executable != null) {
        final work = _readWorkItem(request.runId);
        EventPayloadPolicy.validateExecutableAgentIds(
          executable,
          work.memberAgentIds,
        );
      }
      final duplicate = _database.select(
        '''
          SELECT *
          FROM events
          WHERE run_id = ? AND dedupe_key = ?
        ''',
        [request.runId, request.dedupeKey],
      );
      if (duplicate.isNotEmpty) {
        if (duplicate.first['transition_hash'] != request.identityHash) {
          throw TransitionIdentityConflict(request.dedupeKey);
        }
        return TransitionCommit(
          snapshot: _readRun(request.runId),
          event: _eventFromRow(duplicate.first),
          committed: false,
        );
      }

      final snapshot = _readRun(request.runId);
      if (snapshot.lastSeq != request.expectedLastSeq ||
          snapshot.status != request.expectedStatus) {
        throw TransitionConflict(request.runId);
      }
      TransitionStatePolicy.validate(
        snapshot: snapshot,
        workItem: _readWorkItem(request.runId),
        request: request,
        priorEvents: loadEvents(request.runId),
      );
      final seq = snapshot.lastSeq + 1;
      final event = OrchestrationEvent(
        eventId: '${request.runId}-event-$seq',
        runId: request.runId,
        seq: seq,
        type: request.eventType,
        stage: request.stage,
        agentId: request.agentId,
        text: request.text,
        selectedAgentIds: request.selectedAgentIds,
        errorCode: request.errorCode,
        causationId: request.causationId,
        dedupeKey: request.dedupeKey,
      );
      _insertEvent(event, transitionHash: request.identityHash);
      _inject(SqliteFailurePoint.afterTransitionEventInserted);

      final updated = RunSnapshot(
        runId: request.runId,
        status: request.newStatus ?? snapshot.status,
        lastSeq: seq,
        executableAgentIds: List.unmodifiable(
          request.executableAgentIds ?? snapshot.executableAgentIds,
        ),
      );
      _database.execute(
        '''
          UPDATE runs
          SET status = ?, last_seq = ?, executable_agent_ids = ?
          WHERE run_id = ?
        ''',
        [
          updated.status.name,
          updated.lastSeq,
          jsonEncode(updated.executableAgentIds),
          request.runId,
        ],
      );
      _inject(SqliteFailurePoint.afterSnapshotUpdated);

      final work = _readWorkItem(request.runId);
      _database.execute(
        '''
          UPDATE work_items
          SET checkpoint = ?, next_agent_index = ?
          WHERE run_id = ?
        ''',
        [
          (request.checkpoint ?? work.checkpoint).name,
          request.nextAgentIndex ?? work.nextAgentIndex,
          request.runId,
        ],
      );
      _inject(SqliteFailurePoint.afterWorkItemUpdated);
      _inject(SqliteFailurePoint.beforeTransitionCommit);
      return TransitionCommit(snapshot: updated, event: event, committed: true);
    });
  }

  @override
  ExternalCallIntent ensureExternalCallIntent(
    ExternalCallIntentRequest request,
  ) {
    _ensureOpen();
    return _transaction(() {
      _readRun(request.runId);
      final rows = _database.select(
        'SELECT * FROM external_call_intents WHERE intent_id = ?',
        [request.intentId],
      );
      if (rows.isNotEmpty) {
        final existing = _externalCallFromRow(rows.first);
        if (existing.idempotencyKey != request.idempotencyKey ||
            existing.runId != request.runId ||
            existing.kind != request.kind ||
            existing.agentId != request.agentId) {
          throw ExternalCallIdentityConflict(request.intentId);
        }
        return existing;
      }
      final idempotencyRows = _database.select(
        '''
          SELECT intent_id
          FROM external_call_intents
          WHERE idempotency_key = ?
        ''',
        [request.idempotencyKey],
      );
      if (idempotencyRows.isNotEmpty) {
        throw ExternalCallIdentityConflict(request.idempotencyKey);
      }
      _database.execute(
        '''
          INSERT INTO external_call_intents (
            intent_id, idempotency_key, run_id, kind, agent_id, status, attempt,
            fencing_token
          ) VALUES (?, ?, ?, ?, ?, ?, 0, 0)
        ''',
        [
          request.intentId,
          request.idempotencyKey,
          request.runId,
          request.kind.name,
          request.agentId,
          ExternalCallStatus.pending.name,
        ],
      );
      return getExternalCallIntent(request.intentId);
    });
  }

  @override
  ExternalCallLease? tryAcquireExternalCallLease({
    required String intentId,
    required String ownerId,
    required DateTime now,
    required Duration leaseDuration,
  }) {
    _ensureOpen();
    return _transaction(() {
      final intent = getExternalCallIntent(intentId);
      if (intent.status == ExternalCallStatus.receipted) return null;
      final expiresAt = now.add(leaseDuration);
      _database.execute(
        '''
          UPDATE external_call_intents
          SET status = ?, lease_owner = ?, lease_expires_at = ?,
              attempt = attempt + 1, fencing_token = fencing_token + 1
          WHERE intent_id = ?
            AND status != ?
            AND (
              status = ? OR lease_expires_at <= ? OR lease_owner = ?
            )
        ''',
        [
          ExternalCallStatus.leased.name,
          ownerId,
          expiresAt.microsecondsSinceEpoch,
          intentId,
          ExternalCallStatus.receipted.name,
          ExternalCallStatus.pending.name,
          now.microsecondsSinceEpoch,
          ownerId,
        ],
      );
      if (_database.updatedRows != 1) return null;
      final leased = getExternalCallIntent(intentId);
      return ExternalCallLease(
        intentId: intentId,
        ownerId: ownerId,
        idempotencyKey: leased.idempotencyKey,
        attempt: leased.attempt,
        fencingToken: leased.fencingToken,
        expiresAt: expiresAt,
      );
    });
  }

  @override
  ExternalCallIntent recordExternalCallReceipt({
    required ExternalCallLease lease,
    required DateTime now,
    required PublicEventText result,
  }) {
    _ensureOpen();
    return _transaction(() {
      final intent = getExternalCallIntent(lease.intentId);
      if (intent.status != ExternalCallStatus.leased) {
        throw ExternalCallLeaseLost(lease.intentId);
      }
      _database.execute(
        '''
          UPDATE external_call_intents
          SET status = ?, result_text = ?, result_provenance = ?,
              lease_owner = NULL, lease_expires_at = NULL
          WHERE intent_id = ?
            AND status = ?
            AND lease_owner = ?
            AND attempt = ?
            AND fencing_token = ?
            AND lease_expires_at = ?
            AND lease_expires_at > ?
        ''',
        [
          ExternalCallStatus.receipted.name,
          result.value,
          result.provenance.name,
          lease.intentId,
          ExternalCallStatus.leased.name,
          lease.ownerId,
          lease.attempt,
          lease.fencingToken,
          lease.expiresAt.microsecondsSinceEpoch,
          now.microsecondsSinceEpoch,
        ],
      );
      if (_database.updatedRows != 1) {
        throw ExternalCallLeaseLost(lease.intentId);
      }
      return getExternalCallIntent(lease.intentId);
    });
  }

  @override
  ExternalCallIntent getExternalCallIntent(String intentId) {
    _ensureOpen();
    final rows = _database.select(
      'SELECT * FROM external_call_intents WHERE intent_id = ?',
      [intentId],
    );
    if (rows.isEmpty) throw StateError('Unknown external call: $intentId');
    return _externalCallFromRow(rows.first);
  }

  @override
  RunSnapshot getRun(String runId) {
    _ensureOpen();
    return _readRun(runId);
  }

  @override
  RunWorkItem getWorkItem(String runId) {
    _ensureOpen();
    return _readWorkItem(runId);
  }

  @override
  List<OrchestrationEvent> loadEvents(String runId, {int afterSeq = 0}) {
    _ensureOpen();
    _readRun(runId);
    final rows = _database.select(
      '''
        SELECT *
        FROM events
        WHERE run_id = ? AND seq > ?
        ORDER BY seq ASC
      ''',
      [runId, afterSeq],
    );
    return List.unmodifiable(rows.map(_eventFromRow));
  }

  @override
  Stream<OrchestrationEvent> watch(String runId, {int afterSeq = 0}) {
    _ensureOpen();
    _readRun(runId);
    var cursor = afterSeq;
    late final StreamController<OrchestrationEvent> controller;
    late final _WatchRegistration registration;

    void poll() {
      if (_closed || controller.isClosed) return;
      try {
        for (final event in loadEvents(runId, afterSeq: cursor)) {
          cursor = event.seq;
          controller.add(event);
        }
      } on Object catch (error, stackTrace) {
        if (!_closed && !controller.isClosed) {
          controller.addError(error, stackTrace);
        }
      }
    }

    controller = StreamController<OrchestrationEvent>();
    registration = _WatchRegistration(controller);
    controller.onListen = () {
      _watchers.add(registration);
      poll();
      registration.timer = Timer.periodic(_watchPollInterval, (_) => poll());
    };
    controller.onCancel = () {
      registration.cancel();
      _watchers.remove(registration);
    };
    return controller.stream;
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    final active = List<_WatchRegistration>.of(_watchers);
    _watchers.clear();
    for (final watcher in active) {
      watcher.cancel();
      if (!watcher.controller.isClosed) {
        unawaited(watcher.controller.close());
      }
    }
    _database.close();
  }

  RunSnapshot _readRun(String runId) {
    final rows = _database.select(
      '''
        SELECT status, last_seq, executable_agent_ids
        FROM runs
        WHERE run_id = ?
      ''',
      [runId],
    );
    if (rows.isEmpty) throw StateError('Unknown run: $runId');
    final row = rows.first;
    return RunSnapshot(
      runId: runId,
      status: OrchestrationRunStatus.values.byName(row['status']! as String),
      lastSeq: row['last_seq']! as int,
      executableAgentIds: _decodeStringList(row['executable_agent_ids']),
    );
  }

  RunWorkItem _readWorkItem(String runId) {
    final rows = _database.select(
      '''
        SELECT *
        FROM work_items
        WHERE run_id = ?
      ''',
      [runId],
    );
    if (rows.isEmpty) throw StateError('Unknown work item: $runId');
    final row = rows.first;
    return RunWorkItem(
      runId: runId,
      clientCommandId: row['client_command_id']! as String,
      requestHash: row['request_hash']! as String,
      conversationId: row['conversation_id']! as String,
      hostAgentId: row['host_agent_id']! as String,
      replyMode: ConversationReplyMode.values.byName(
        row['reply_mode']! as String,
      ),
      memberAgentIds: _decodeStringList(row['member_agent_ids']),
      mentionedAgentIds: _decodeStringList(row['mentioned_agent_ids']),
      inputRef: row['input_ref'] as String?,
      contextRef: row['context_ref'] as String?,
      checkpoint: RunCheckpoint.values.byName(row['checkpoint']! as String),
      nextAgentIndex: row['next_agent_index']! as int,
    );
  }

  void _insertEvent(
    OrchestrationEvent event, {
    required String transitionHash,
  }) {
    _database.execute(
      '''
        INSERT INTO events (
          run_id,
          seq,
          event_id,
          type,
          stage,
          agent_id,
          text,
          text_provenance,
          selected_agent_ids,
          error_code,
          causation_id,
          dedupe_key,
          transition_hash
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        event.runId,
        event.seq,
        event.eventId,
        event.type.name,
        event.stage.name,
        event.agentId,
        event.publicText?.value,
        event.publicText?.provenance.name,
        jsonEncode(event.selectedAgentIds),
        event.errorCode,
        event.causationId,
        event.dedupeKey,
        transitionHash,
      ],
    );
  }

  OrchestrationEvent _eventFromRow(Row row) {
    return OrchestrationEvent(
      eventId: row['event_id']! as String,
      runId: row['run_id']! as String,
      seq: row['seq']! as int,
      type: OrchestrationEventType.values.byName(row['type']! as String),
      stage: ConversationStage.values.byName(row['stage']! as String),
      agentId: row['agent_id'] as String?,
      text: row['text'] == null
          ? null
          : PublicEventText.fromJson({
              'value': row['text']! as String,
              'provenance': row['text_provenance']! as String,
            }),
      selectedAgentIds: _decodeStringList(row['selected_agent_ids']),
      errorCode: row['error_code'] as String?,
      causationId: row['causation_id']! as String,
      dedupeKey: row['dedupe_key']! as String,
    );
  }

  ExternalCallIntent _externalCallFromRow(Row row) {
    final resultText = row['result_text'] as String?;
    return ExternalCallIntent(
      intentId: row['intent_id']! as String,
      idempotencyKey: row['idempotency_key']! as String,
      runId: row['run_id']! as String,
      kind: ExternalCallKind.values.byName(row['kind']! as String),
      status: ExternalCallStatus.values.byName(row['status']! as String),
      attempt: row['attempt']! as int,
      fencingToken: row['fencing_token']! as int,
      agentId: row['agent_id'] as String?,
      ownerId: row['lease_owner'] as String?,
      leaseExpiresAt: row['lease_expires_at'] == null
          ? null
          : DateTime.fromMicrosecondsSinceEpoch(
              row['lease_expires_at']! as int,
              isUtc: true,
            ),
      result: resultText == null
          ? null
          : PublicEventText.fromJson({
              'value': resultText,
              'provenance': row['result_provenance']! as String,
            }),
    );
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

  void _inject(SqliteFailurePoint point) => _failureInjector?.call(point);

  void _ensureOpen() {
    if (_closed) throw StateError('RunEventStore is closed');
  }
}

final class _WatchRegistration {
  _WatchRegistration(this.controller);

  final StreamController<OrchestrationEvent> controller;
  Timer? timer;

  void cancel() {
    timer?.cancel();
    timer = null;
  }
}

List<String> _decodeStringList(Object? encoded) {
  if (encoded is! String) {
    throw const FormatException('Expected a JSON string list');
  }
  final decoded = jsonDecode(encoded);
  if (decoded is! List) {
    throw const FormatException('Expected a JSON string list');
  }
  return List<String>.unmodifiable(decoded.cast<String>());
}
