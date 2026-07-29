import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:halo_mobile/orchestration/basic_durable_runner.dart';
import 'package:halo_mobile/orchestration/command_validation.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';
import 'package:sqlite3/sqlite3.dart';

part 'sqlite_run_input_repository.dart';

abstract interface class RunInputRepository implements RunInputResolver {
  Future<RunInputReservation> prepare(StartConversationRunCommand command);

  Future<void> commit(RunInputReservation reservation);

  Future<void> markReferenced(RunInputReservation reservation);

  Future<void> rollback(RunInputReservation reservation);

  Future<RunInputLifecycle> lifecycleOf(RunInputReservation reservation);

  Future<void> close();
}

abstract interface class DurableRunInputRepository
    implements RunInputRepository {
  Future<int> collectOrphans({
    required DateTime olderThan,
    required RunInputReferenceProbe isReferenced,
  });
}

typedef RunInputReferenceProbe =
    Future<bool> Function(String inputRef, String contextRef);

enum RunInputLifecycle { staged, resolvableOrphan, referenced, rolledBack }

class RunInputReservation {
  const RunInputReservation._({
    required this.inputRef,
    required this.contextRef,
    required this.token,
    required this._ownerId,
    required this._identityHash,
    required this._createdRecord,
  });

  final String inputRef;
  final String contextRef;
  final String token;
  final String _ownerId;
  final String _identityHash;
  final bool _createdRecord;
}

class RunInputUnavailable implements Exception {
  const RunInputUnavailable(this.inputRef);

  final String inputRef;

  @override
  String toString() => 'Run input is unavailable: $inputRef';
}

class RunInputIdentityConflict implements Exception {
  const RunInputIdentityConflict(this.inputRef);

  final String inputRef;

  @override
  String toString() => 'Run input identity conflict: $inputRef';
}

final class MemoryRunInputRepository implements RunInputRepository {
  MemoryRunInputRepository({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final _records = <String, _RunInputRecord>{};
  final _reservations = <String, _ReservationRecord>{};
  final _random = Random.secure();
  final DateTime Function() _clock;
  late final String _ownerId = _secureToken();
  var _closed = false;
  Future<void>? _closeFuture;

  @override
  Future<RunInputReservation> prepare(
    StartConversationRunCommand command,
  ) async {
    _ensureOpen();
    StartConversationCommandValidator.validate(command);
    final digest = _structuredDigest('run-input-reference-v1', [
      command.clientCommandId,
    ]);
    final inputRef = 'halo-run-input://sha256/$digest';
    final contextDigest = _structuredDigest('run-context-reference-v1', [
      command.clientCommandId,
    ]);
    final contextRef = 'halo-run-context://sha256/$contextDigest';
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

    final existing = _records[inputRef];
    if (existing != null && existing.identityHash != identityHash) {
      throw RunInputIdentityConflict(inputRef);
    }
    final record =
        existing ??
        _RunInputRecord(
          identityHash: identityHash,
          input: command.input,
          contextRef: contextRef,
          createdAt: _clock(),
        );
    _records[inputRef] = record;

    var token = _secureToken();
    while (_reservations.containsKey(token)) {
      token = _secureToken();
    }
    final reservation = RunInputReservation._(
      inputRef: inputRef,
      contextRef: contextRef,
      token: token,
      ownerId: _ownerId,
      identityHash: identityHash,
      createdRecord: existing == null,
    );
    record.reservationTokens.add(token);
    _reservations[token] = _ReservationRecord(
      reservation: reservation,
      lifecycle: RunInputLifecycle.staged,
    );
    return reservation;
  }

  @override
  Future<void> commit(RunInputReservation reservation) async {
    _ensureOpen();
    final reservationRecord = _validate(reservation);
    switch (reservationRecord.lifecycle) {
      case RunInputLifecycle.resolvableOrphan:
      case RunInputLifecycle.referenced:
        return;
      case RunInputLifecycle.rolledBack:
        throw RunInputIdentityConflict(reservation.inputRef);
      case RunInputLifecycle.staged:
        break;
    }
    final record = _matchingRecord(reservation);
    reservationRecord.lifecycle = RunInputLifecycle.resolvableOrphan;
    if (record.lifecycle == RunInputLifecycle.staged) {
      record.lifecycle = RunInputLifecycle.resolvableOrphan;
    }
  }

  @override
  Future<void> markReferenced(RunInputReservation reservation) async {
    _ensureOpen();
    final reservationRecord = _validate(reservation);
    if (reservationRecord.lifecycle == RunInputLifecycle.referenced) return;
    if (reservationRecord.lifecycle != RunInputLifecycle.resolvableOrphan) {
      throw RunInputIdentityConflict(reservation.inputRef);
    }
    final record = _matchingRecord(reservation);
    reservationRecord.lifecycle = RunInputLifecycle.referenced;
    record.lifecycle = RunInputLifecycle.referenced;
  }

  @override
  Future<void> rollback(RunInputReservation reservation) async {
    _ensureOpen();
    final reservationRecord = _validate(reservation);
    if (reservationRecord.lifecycle == RunInputLifecycle.rolledBack) return;
    final record = _records[reservation.inputRef];
    if (record == null) {
      throw RunInputIdentityConflict(reservation.inputRef);
    }
    if (reservationRecord.lifecycle == RunInputLifecycle.referenced ||
        record.lifecycle == RunInputLifecycle.referenced) {
      return;
    }
    reservationRecord.lifecycle = RunInputLifecycle.rolledBack;
    record.reservationTokens.remove(reservation.token);
    if (reservation._createdRecord && record.reservationTokens.isEmpty) {
      _records.remove(reservation.inputRef);
    }
  }

  @override
  Future<RunInputLifecycle> lifecycleOf(RunInputReservation reservation) async {
    _ensureOpen();
    final reservationRecord = _validate(reservation);
    final record = _records[reservation.inputRef];
    return record?.lifecycle ?? reservationRecord.lifecycle;
  }

  Future<int> collectOrphans({
    required DateTime olderThan,
    required RunInputReferenceProbe isReferenced,
  }) async {
    _ensureOpen();
    var removed = 0;
    for (final entry in _records.entries.toList(growable: false)) {
      final record = entry.value;
      if (record.lifecycle == RunInputLifecycle.referenced ||
          !record.createdAt.isBefore(olderThan)) {
        continue;
      }
      if (await isReferenced(entry.key, record.contextRef)) {
        record.lifecycle = RunInputLifecycle.referenced;
        continue;
      }
      _records.remove(entry.key);
      for (final token in record.reservationTokens) {
        _reservations[token]?.lifecycle = RunInputLifecycle.rolledBack;
      }
      record.reservationTokens.clear();
      removed++;
    }
    return removed;
  }

  @override
  Future<String> resolve({required String inputRef, String? contextRef}) async {
    _ensureOpen();
    final record = _records[inputRef];
    if (record == null ||
        record.lifecycle == RunInputLifecycle.staged ||
        record.lifecycle == RunInputLifecycle.rolledBack ||
        contextRef != record.contextRef) {
      throw RunInputUnavailable(inputRef);
    }
    return record.input;
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    _reservations.clear();
    _records.clear();
  }

  _ReservationRecord _validate(RunInputReservation reservation) {
    final stored = _reservations[reservation.token];
    if (stored == null ||
        reservation._ownerId != _ownerId ||
        stored.reservation.inputRef != reservation.inputRef ||
        stored.reservation.contextRef != reservation.contextRef ||
        stored.reservation.token != reservation.token ||
        stored.reservation._identityHash != reservation._identityHash ||
        stored.reservation._createdRecord != reservation._createdRecord) {
      throw RunInputIdentityConflict(reservation.inputRef);
    }
    return stored;
  }

  _RunInputRecord _matchingRecord(RunInputReservation reservation) {
    final record = _records[reservation.inputRef];
    if (record == null ||
        record.identityHash != reservation._identityHash ||
        record.contextRef != reservation.contextRef ||
        !record.reservationTokens.contains(reservation.token)) {
      throw RunInputIdentityConflict(reservation.inputRef);
    }
    return record;
  }

  String _secureToken() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  void _ensureOpen() {
    if (_closed) throw StateError('RunInputRepository is closed');
  }
}

final class _RunInputRecord {
  _RunInputRecord({
    required this.identityHash,
    required this.input,
    required this.contextRef,
    required this.createdAt,
  });

  final String identityHash;
  final String input;
  final String contextRef;
  final DateTime createdAt;
  final Set<String> reservationTokens = {};
  RunInputLifecycle lifecycle = RunInputLifecycle.staged;
}

final class _ReservationRecord {
  _ReservationRecord({required this.reservation, required this.lifecycle});

  final RunInputReservation reservation;
  RunInputLifecycle lifecycle;
}

String _structuredDigest(String domain, List<String> fields) {
  final bytes = <int>[];

  void addField(String value) {
    final encoded = utf8.encode(value);
    bytes.addAll(utf8.encode('${encoded.length}:'));
    bytes.addAll(encoded);
  }

  addField(domain);
  for (final field in fields) {
    addField(field);
  }
  return sha256.convert(bytes).toString();
}
