import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:halo_mobile/foundation/design_system/halo_components.dart';

enum ChatMessageKind {
  systemNotice,
  userText,
  agentText,
  progress,
  file,
  userImage,
  quote,
}

enum ChatMessageSourceType { modelOutput, verifiedEvidence, userVisibleSummary }

class ChatMessageVerificationAttestation {
  const ChatMessageVerificationAttestation({
    required this.receiptId,
    required this.expertId,
    required this.runId,
    required this.commandId,
  });

  final String receiptId;
  final String expertId;
  final String runId;
  final String commandId;
}

class SingleChatConversationProjection {
  const SingleChatConversationProjection({
    required this.conversationId,
    required this.expertId,
    required this.title,
    required this.agentName,
    required this.modelLabel,
    required this.avatarLetter,
    this.tag = '可用',
    this.tagTone = HaloTagTone.green,
    this.avatarImageUrl,
  });

  final String conversationId;
  final String expertId;
  final String title;
  final String agentName;
  final String modelLabel;
  final String avatarLetter;
  final String tag;
  final HaloTagTone tagTone;
  final String? avatarImageUrl;
}

class ChatMessageProjection {
  const ChatMessageProjection({
    required this.id,
    required this.kind,
    this.text,
    this.secondaryText,
    this.tertiaryText,
    this.imageUrl,
    this.progress,
    this.sourceType,
    this.uncertainty,
    this.evidenceReferences = const [],
    this.verificationAttestation,
    this.dispatchClaimOwner,
    this.dispatchClaimGeneration,
  });

  final String id;
  final ChatMessageKind kind;
  final String? text;
  final String? secondaryText;
  final String? tertiaryText;
  final String? imageUrl;
  final double? progress;
  final ChatMessageSourceType? sourceType;
  final String? uncertainty;
  final List<String> evidenceReferences;
  final ChatMessageVerificationAttestation? verificationAttestation;
  final String? dispatchClaimOwner;
  final int? dispatchClaimGeneration;

  ChatMessageProjection withVerification({
    required ChatMessageSourceType? sourceType,
    required ChatMessageVerificationAttestation? attestation,
    List<String>? canonicalEvidenceReferences,
  }) {
    return ChatMessageProjection(
      id: id,
      kind: kind,
      text: text,
      secondaryText: secondaryText,
      tertiaryText: tertiaryText,
      imageUrl: imageUrl,
      progress: progress,
      sourceType: sourceType,
      uncertainty: uncertainty,
      evidenceReferences: canonicalEvidenceReferences ?? evidenceReferences,
      verificationAttestation: attestation,
      dispatchClaimOwner: dispatchClaimOwner,
      dispatchClaimGeneration: dispatchClaimGeneration,
    );
  }
}

class ChatMessageCommitToken {
  ChatMessageCommitToken(this.value, {this.generation = 0});

  final String value;
  final int generation;
  bool _valid = true;
  final List<void Function()> _invalidationCallbacks = [];
  bool get isValid => _valid;

  void onInvalidated(void Function() callback) {
    if (!_valid) {
      callback();
      return;
    }
    _invalidationCallbacks.add(callback);
  }

  void invalidate() {
    if (!_valid) {
      return;
    }
    _valid = false;
    for (final callback in _invalidationCallbacks) {
      callback();
    }
    _invalidationCallbacks.clear();
  }
}

class ChatMessageCommitResult {
  const ChatMessageCommitResult({
    required this.messageId,
    required this.committed,
    required this.inserted,
    this.ownerId,
    this.ownerGeneration,
    this.storageRevision,
  });

  final String messageId;
  final bool committed;
  final bool inserted;
  final String? ownerId;
  final int? ownerGeneration;
  final int? storageRevision;
}

enum ChatMessageRollbackDisposition {
  removedOwnedRevision,
  alreadyAbsent,
  ownershipMismatch,
  commitDidNotInsert,
}

extension ChatMessageRollbackDispositionSafety
    on ChatMessageRollbackDisposition {
  bool get confirmsNoCommittedAnswer =>
      this == ChatMessageRollbackDisposition.removedOwnedRevision ||
      this == ChatMessageRollbackDisposition.alreadyAbsent;
}

enum SingleChatCommandStatus { pending, completed, stopped }

typedef SingleChatEpochClock = int Function();

int _systemEpochMilliseconds() => DateTime.now().toUtc().millisecondsSinceEpoch;

class SingleChatDispatchClaim {
  const SingleChatDispatchClaim({
    required this.conversationId,
    required this.commandId,
    required this.ownerId,
    required this.generation,
  });

  final String conversationId;
  final String commandId;
  final String ownerId;
  final int generation;
}

class SingleChatCommandRecord {
  const SingleChatCommandRecord({
    required this.conversationId,
    required this.commandId,
    required this.normalizedIntent,
    this.status = SingleChatCommandStatus.pending,
    this.revision = 0,
    this.dispatchClaimOwner,
    this.dispatchClaimGeneration,
    this.dispatchClaimExpiresAtEpochMs,
    this.terminalOwner,
    this.terminalGeneration,
  });

  final String conversationId;
  final String commandId;
  final String normalizedIntent;
  final SingleChatCommandStatus status;
  final int revision;
  final String? dispatchClaimOwner;
  final int? dispatchClaimGeneration;
  final int? dispatchClaimExpiresAtEpochMs;
  final String? terminalOwner;
  final int? terminalGeneration;

  bool get hasDispatchClaim => dispatchClaimOwner != null;

  SingleChatCommandRecord claimDispatch({
    required String ownerId,
    required int expiresAtEpochMs,
  }) {
    final generation = revision + 1;
    return SingleChatCommandRecord(
      conversationId: conversationId,
      commandId: commandId,
      normalizedIntent: normalizedIntent,
      status: status,
      revision: generation,
      dispatchClaimOwner: ownerId,
      dispatchClaimGeneration: generation,
      dispatchClaimExpiresAtEpochMs: expiresAtEpochMs,
    );
  }

  SingleChatCommandRecord releaseDispatchClaim() {
    return SingleChatCommandRecord(
      conversationId: conversationId,
      commandId: commandId,
      normalizedIntent: normalizedIntent,
      status: status,
      revision: revision + 1,
    );
  }

  SingleChatCommandRecord renewDispatchClaim(int expiresAtEpochMs) {
    return SingleChatCommandRecord(
      conversationId: conversationId,
      commandId: commandId,
      normalizedIntent: normalizedIntent,
      status: status,
      revision: revision,
      dispatchClaimOwner: dispatchClaimOwner,
      dispatchClaimGeneration: dispatchClaimGeneration,
      dispatchClaimExpiresAtEpochMs: expiresAtEpochMs,
    );
  }

  SingleChatCommandRecord markTerminal(
    SingleChatCommandStatus terminalStatus, {
    SingleChatDispatchClaim? dispatchClaim,
  }) {
    return SingleChatCommandRecord(
      conversationId: conversationId,
      commandId: commandId,
      normalizedIntent: normalizedIntent,
      status: terminalStatus,
      revision: revision + 1,
      terminalOwner: dispatchClaim?.ownerId,
      terminalGeneration: dispatchClaim?.generation,
    );
  }

  bool wasTerminatedBy(SingleChatDispatchClaim claim) {
    return status != SingleChatCommandStatus.pending &&
        conversationId == claim.conversationId &&
        commandId == claim.commandId &&
        terminalOwner == claim.ownerId &&
        terminalGeneration == claim.generation;
  }
}

bool _ownsDispatchClaim(
  SingleChatCommandRecord record,
  SingleChatDispatchClaim claim,
) {
  return record.status == SingleChatCommandStatus.pending &&
      record.conversationId == claim.conversationId &&
      record.commandId == claim.commandId &&
      record.dispatchClaimOwner == claim.ownerId &&
      record.dispatchClaimGeneration == claim.generation;
}

abstract interface class SingleChatCommandOutbox {
  SingleChatCommandRecord reserve({
    required String conversationId,
    required String normalizedIntent,
    required String Function() createCommandId,
  });

  /// Atomically grants a short, exclusive permit for starting the upstream
  /// run. An expired permit may be replaced so a process crash cannot strand
  /// a pending user intent forever.
  SingleChatDispatchClaim? claimForDispatch({
    required String conversationId,
    required String commandId,
    required String ownerId,
    required int nowEpochMs,
    required int leaseExpiresAtEpochMs,
  });

  bool releaseDispatchClaim(SingleChatDispatchClaim claim);

  bool renewDispatchClaim({
    required SingleChatDispatchClaim claim,
    required int nowEpochMs,
    required int leaseExpiresAtEpochMs,
  });

  void markTerminal(
    String conversationId,
    String commandId,
    SingleChatCommandStatus status, {
    SingleChatDispatchClaim? dispatchClaim,
    bool reconcilePersistedAnswer = false,
  });

  SingleChatCommandRecord? read(String conversationId, String commandId);

  List<SingleChatCommandRecord> pendingForConversation(String conversationId);
}

class InMemorySingleChatCommandOutbox implements SingleChatCommandOutbox {
  InMemorySingleChatCommandOutbox({
    List<SingleChatCommandRecord> seed = const [],
    SingleChatEpochClock? nowEpochMs,
  }) : _records = List<SingleChatCommandRecord>.of(seed),
       _nowEpochMs = nowEpochMs ?? _systemEpochMilliseconds;

  final List<SingleChatCommandRecord> _records;
  final SingleChatEpochClock _nowEpochMs;

  List<SingleChatCommandRecord> snapshot() =>
      List<SingleChatCommandRecord>.unmodifiable(_records);

  @override
  SingleChatCommandRecord reserve({
    required String conversationId,
    required String normalizedIntent,
    required String Function() createCommandId,
  }) {
    for (final record in _records.reversed) {
      if (record.conversationId == conversationId &&
          record.normalizedIntent == normalizedIntent &&
          record.status == SingleChatCommandStatus.pending) {
        return record;
      }
    }
    final record = SingleChatCommandRecord(
      conversationId: conversationId,
      commandId: createCommandId(),
      normalizedIntent: normalizedIntent,
    );
    _records.add(record);
    return record;
  }

  @override
  SingleChatDispatchClaim? claimForDispatch({
    required String conversationId,
    required String commandId,
    required String ownerId,
    required int nowEpochMs,
    required int leaseExpiresAtEpochMs,
  }) {
    if (ownerId.isEmpty || leaseExpiresAtEpochMs <= nowEpochMs) {
      throw ArgumentError('Single-chat dispatch claim is invalid.');
    }
    final index = _records.indexWhere(
      (record) =>
          record.conversationId == conversationId &&
          record.commandId == commandId,
    );
    if (index < 0) {
      return null;
    }
    final current = _records[index];
    if (current.status != SingleChatCommandStatus.pending ||
        (current.hasDispatchClaim &&
            current.dispatchClaimExpiresAtEpochMs! > nowEpochMs)) {
      return null;
    }
    final claimed = current.claimDispatch(
      ownerId: ownerId,
      expiresAtEpochMs: leaseExpiresAtEpochMs,
    );
    _records[index] = claimed;
    return SingleChatDispatchClaim(
      conversationId: conversationId,
      commandId: commandId,
      ownerId: ownerId,
      generation: claimed.dispatchClaimGeneration!,
    );
  }

  @override
  bool releaseDispatchClaim(SingleChatDispatchClaim claim) {
    final index = _records.indexWhere(
      (record) =>
          record.conversationId == claim.conversationId &&
          record.commandId == claim.commandId,
    );
    if (index < 0) {
      return false;
    }
    final current = _records[index];
    if (!_ownsDispatchClaim(current, claim)) {
      return false;
    }
    _records[index] = current.releaseDispatchClaim();
    return true;
  }

  @override
  bool renewDispatchClaim({
    required SingleChatDispatchClaim claim,
    required int nowEpochMs,
    required int leaseExpiresAtEpochMs,
  }) {
    if (leaseExpiresAtEpochMs <= nowEpochMs) {
      return false;
    }
    final index = _records.indexWhere(
      (record) =>
          record.conversationId == claim.conversationId &&
          record.commandId == claim.commandId,
    );
    if (index < 0) {
      return false;
    }
    final current = _records[index];
    if (!_ownsDispatchClaim(current, claim) ||
        current.dispatchClaimExpiresAtEpochMs! <= nowEpochMs) {
      return false;
    }
    _records[index] = current.renewDispatchClaim(leaseExpiresAtEpochMs);
    return true;
  }

  @override
  void markTerminal(
    String conversationId,
    String commandId,
    SingleChatCommandStatus status, {
    SingleChatDispatchClaim? dispatchClaim,
    bool reconcilePersistedAnswer = false,
  }) {
    final index = _records.indexWhere(
      (record) =>
          record.conversationId == conversationId &&
          record.commandId == commandId,
    );
    if (index < 0) {
      throw StateError('Single-chat command does not exist.');
    }
    final current = _records[index];
    if (current.status == status) {
      if (dispatchClaim != null && !current.wasTerminatedBy(dispatchClaim)) {
        throw StateError('Single-chat terminal ownership mismatch.');
      }
      if (current.terminalOwner != null && dispatchClaim == null) {
        throw StateError('Single-chat terminal ownership mismatch.');
      }
      if (current.terminalOwner == null && dispatchClaim != null) {
        throw StateError('Single-chat terminal ownership mismatch.');
      }
      return;
    }
    if (current.status != SingleChatCommandStatus.pending) {
      throw StateError('Single-chat command is already terminal.');
    }
    if (current.hasDispatchClaim &&
        (dispatchClaim == null ||
            !_ownsDispatchClaim(current, dispatchClaim))) {
      throw StateError('Single-chat dispatch claim ownership mismatch.');
    }
    if (!current.hasDispatchClaim && dispatchClaim != null) {
      throw StateError('Single-chat dispatch claim ownership mismatch.');
    }
    if (dispatchClaim != null &&
        current.dispatchClaimExpiresAtEpochMs! <= _nowEpochMs()) {
      throw StateError('Single-chat dispatch claim has expired.');
    }
    if (status == SingleChatCommandStatus.completed && dispatchClaim == null) {
      throw StateError('Single-chat completion requires dispatch ownership.');
    }
    _records[index] = current.markTerminal(
      status,
      dispatchClaim: dispatchClaim,
    );
  }

  @override
  SingleChatCommandRecord? read(String conversationId, String commandId) {
    for (final record in _records) {
      if (record.conversationId == conversationId &&
          record.commandId == commandId) {
        return record;
      }
    }
    return null;
  }

  @override
  List<SingleChatCommandRecord> pendingForConversation(String conversationId) {
    return List<SingleChatCommandRecord>.unmodifiable(
      _records.where(
        (record) =>
            record.conversationId == conversationId &&
            record.status == SingleChatCommandStatus.pending,
      ),
    );
  }
}

typedef ApplicationSupportDirectoryProvider = Future<Directory> Function();

/// Native composition should implement iOS data protection, backup exclusion,
/// and parent-directory fsync here. The pure Dart default deliberately exposes
/// the capability boundary instead of claiming guarantees it cannot provide.
abstract interface class SingleChatOutboxStoragePolicy {
  void prepareDirectory(Directory directory);

  void protectAndExcludeFromBackup(File file);

  void syncDirectory(Directory directory);
}

class BestEffortSingleChatOutboxStoragePolicy
    implements SingleChatOutboxStoragePolicy {
  const BestEffortSingleChatOutboxStoragePolicy();

  @override
  void prepareDirectory(Directory directory) {
    directory.createSync(recursive: true);
  }

  @override
  void protectAndExcludeFromBackup(File file) {}

  @override
  void syncDirectory(Directory directory) {}
}

class FileSingleChatCommandOutbox implements SingleChatCommandOutbox {
  FileSingleChatCommandOutbox(
    String path, {
    this.storagePolicy = const BestEffortSingleChatOutboxStoragePolicy(),
    SingleChatEpochClock? nowEpochMs,
  }) : _file = _canonicalOutboxFile(path),
       _nowEpochMs = nowEpochMs ?? _systemEpochMilliseconds {
    _withExclusiveLock<void>((snapshot) => (snapshot, null));
  }

  static Future<FileSingleChatCommandOutbox> openInApplicationSupport({
    required ApplicationSupportDirectoryProvider directoryProvider,
    SingleChatOutboxStoragePolicy storagePolicy =
        const BestEffortSingleChatOutboxStoragePolicy(),
    String fileName = 'single-chat-commands.json',
    SingleChatEpochClock? nowEpochMs,
  }) async {
    final directory = await directoryProvider();
    if (!directory.isAbsolute) {
      throw StateError('Application Support directory must be absolute.');
    }
    return FileSingleChatCommandOutbox(
      '${directory.path}${Platform.pathSeparator}$fileName',
      storagePolicy: storagePolicy,
      nowEpochMs: nowEpochMs,
    );
  }

  final File _file;
  final SingleChatEpochClock _nowEpochMs;
  final SingleChatOutboxStoragePolicy storagePolicy;

  @override
  SingleChatCommandRecord reserve({
    required String conversationId,
    required String normalizedIntent,
    required String Function() createCommandId,
  }) {
    return _withExclusiveLock((snapshot) {
      for (final record in snapshot.records.reversed) {
        if (record.conversationId == conversationId &&
            record.normalizedIntent == normalizedIntent &&
            record.status == SingleChatCommandStatus.pending) {
          return (snapshot, record);
        }
      }
      final record = SingleChatCommandRecord(
        conversationId: conversationId,
        commandId: createCommandId(),
        normalizedIntent: normalizedIntent,
      );
      return (
        snapshot.copyWith(records: [...snapshot.records, record]),
        record,
      );
    });
  }

  @override
  SingleChatDispatchClaim? claimForDispatch({
    required String conversationId,
    required String commandId,
    required String ownerId,
    required int nowEpochMs,
    required int leaseExpiresAtEpochMs,
  }) {
    if (ownerId.isEmpty || leaseExpiresAtEpochMs <= nowEpochMs) {
      throw ArgumentError('Single-chat dispatch claim is invalid.');
    }
    return _withExclusiveLock((snapshot) {
      final records = List<SingleChatCommandRecord>.of(snapshot.records);
      final index = records.indexWhere(
        (record) =>
            record.conversationId == conversationId &&
            record.commandId == commandId,
      );
      if (index < 0) {
        return (snapshot, null);
      }
      final current = records[index];
      if (current.status != SingleChatCommandStatus.pending ||
          (current.hasDispatchClaim &&
              current.dispatchClaimExpiresAtEpochMs! > nowEpochMs)) {
        return (snapshot, null);
      }
      final claimed = current.claimDispatch(
        ownerId: ownerId,
        expiresAtEpochMs: leaseExpiresAtEpochMs,
      );
      records[index] = claimed;
      return (
        snapshot.copyWith(records: records),
        SingleChatDispatchClaim(
          conversationId: conversationId,
          commandId: commandId,
          ownerId: ownerId,
          generation: claimed.dispatchClaimGeneration!,
        ),
      );
    });
  }

  @override
  bool releaseDispatchClaim(SingleChatDispatchClaim claim) {
    return _withExclusiveLock((snapshot) {
      final records = List<SingleChatCommandRecord>.of(snapshot.records);
      final index = records.indexWhere(
        (record) =>
            record.conversationId == claim.conversationId &&
            record.commandId == claim.commandId,
      );
      if (index < 0 || !_ownsDispatchClaim(records[index], claim)) {
        return (snapshot, false);
      }
      records[index] = records[index].releaseDispatchClaim();
      return (snapshot.copyWith(records: records), true);
    });
  }

  @override
  bool renewDispatchClaim({
    required SingleChatDispatchClaim claim,
    required int nowEpochMs,
    required int leaseExpiresAtEpochMs,
  }) {
    if (leaseExpiresAtEpochMs <= nowEpochMs) {
      return false;
    }
    return _withExclusiveLock((snapshot) {
      final records = List<SingleChatCommandRecord>.of(snapshot.records);
      final index = records.indexWhere(
        (record) =>
            record.conversationId == claim.conversationId &&
            record.commandId == claim.commandId,
      );
      if (index < 0) {
        return (snapshot, false);
      }
      final current = records[index];
      if (!_ownsDispatchClaim(current, claim) ||
          current.dispatchClaimExpiresAtEpochMs! <= nowEpochMs) {
        return (snapshot, false);
      }
      records[index] = current.renewDispatchClaim(leaseExpiresAtEpochMs);
      return (snapshot.copyWith(records: records), true);
    });
  }

  @override
  void markTerminal(
    String conversationId,
    String commandId,
    SingleChatCommandStatus status, {
    SingleChatDispatchClaim? dispatchClaim,
    bool reconcilePersistedAnswer = false,
  }) {
    _withExclusiveLock((snapshot) {
      final records = List<SingleChatCommandRecord>.of(snapshot.records);
      final index = records.indexWhere(
        (record) =>
            record.conversationId == conversationId &&
            record.commandId == commandId,
      );
      if (index < 0) {
        throw StateError('Single-chat command does not exist.');
      }
      final current = records[index];
      if (current.status == status) {
        if (dispatchClaim != null && !current.wasTerminatedBy(dispatchClaim)) {
          throw StateError('Single-chat terminal ownership mismatch.');
        }
        if (current.terminalOwner != null && dispatchClaim == null) {
          throw StateError('Single-chat terminal ownership mismatch.');
        }
        if (current.terminalOwner == null && dispatchClaim != null) {
          throw StateError('Single-chat terminal ownership mismatch.');
        }
        return (snapshot, null);
      }
      if (current.status != SingleChatCommandStatus.pending) {
        throw StateError('Single-chat command is already terminal.');
      }
      if (current.hasDispatchClaim &&
          (dispatchClaim == null ||
              !_ownsDispatchClaim(current, dispatchClaim))) {
        throw StateError('Single-chat dispatch claim ownership mismatch.');
      }
      if (!current.hasDispatchClaim && dispatchClaim != null) {
        throw StateError('Single-chat dispatch claim ownership mismatch.');
      }
      if (dispatchClaim != null &&
          current.dispatchClaimExpiresAtEpochMs! <= _nowEpochMs()) {
        throw StateError('Single-chat dispatch claim has expired.');
      }
      if (status == SingleChatCommandStatus.completed &&
          dispatchClaim == null) {
        throw StateError('Single-chat completion requires dispatch ownership.');
      }
      records[index] = current.markTerminal(
        status,
        dispatchClaim: dispatchClaim,
      );
      return (snapshot.copyWith(records: records), null);
    });
  }

  @override
  SingleChatCommandRecord? read(String conversationId, String commandId) {
    return _withExclusiveLock((snapshot) {
      SingleChatCommandRecord? found;
      for (final record in snapshot.records) {
        if (record.conversationId == conversationId &&
            record.commandId == commandId) {
          found = record;
          break;
        }
      }
      return (snapshot, found);
    });
  }

  @override
  List<SingleChatCommandRecord> pendingForConversation(String conversationId) {
    return _withExclusiveLock((snapshot) {
      final records = [
        for (final record in snapshot.records)
          if (record.conversationId == conversationId &&
              record.status == SingleChatCommandStatus.pending)
            record,
      ];
      return (snapshot, List<SingleChatCommandRecord>.unmodifiable(records));
    });
  }

  T _withExclusiveLock<T>(
    (_OutboxSnapshot, T) Function(_OutboxSnapshot snapshot) operation,
  ) {
    storagePolicy.prepareDirectory(_file.parent);
    _IsolateMutexOwnership? isolateMutex;
    RandomAccessFile? lock;
    var operatingSystemLockHeld = false;
    try {
      isolateMutex = _acquireIsolateMutex();
      final lockFile = File('${_file.path}.lock')..createSync(recursive: true);
      lock = lockFile.openSync(mode: FileMode.append);
      lock.lockSync(FileLock.blockingExclusive);
      operatingSystemLockHeld = true;
      final before = _recoverLocked();
      final (after, result) = operation(before);
      if (!identical(after, before) &&
          (after.records != before.records ||
              after.generation != before.generation)) {
        _persistLocked(
          after.copyWith(generation: before.generation + 1),
          expectedGeneration: before.generation,
        );
      }
      return result;
    } finally {
      try {
        if (operatingSystemLockHeld) {
          lock?.unlockSync();
          operatingSystemLockHeld = false;
        }
      } finally {
        try {
          lock?.closeSync();
        } finally {
          isolateMutex?.release();
        }
      }
    }
  }

  _IsolateMutexOwnership _acquireIsolateMutex() {
    // POSIX advisory locks are process-scoped, so sibling isolates also use a
    // PID-local O_EXCL mutex. A crashed process normally leaves a different
    // PID suffix, while the OS lock remains the cross-process serialization
    // boundary. A same-PID orphan fails closed: wall-clock age is never enough
    // evidence to delete a mutex that a paused sibling isolate may still own.
    final mutex = File('${_file.path}.mutex.$pid');
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (true) {
      try {
        mutex.createSync(exclusive: true);
        final ownerToken = _newTransactionId();
        try {
          mutex.writeAsStringSync(ownerToken, flush: true);
        } on FileSystemException {
          if (mutex.existsSync()) {
            mutex.deleteSync();
          }
          rethrow;
        }
        return _IsolateMutexOwnership(mutex, ownerToken);
      } on FileSystemException {
        final now = DateTime.now();
        if (now.isAfter(deadline)) {
          throw FileSystemException(
            'Timed out acquiring single-chat outbox isolate mutex.',
            mutex.path,
          );
        }
        sleep(const Duration(milliseconds: 2));
      }
    }
  }

  _OutboxSnapshot _recoverLocked() {
    final temporary = File('${_file.path}.tmp');
    final markerFile = File('${_file.path}.commit');
    if (!markerFile.existsSync()) {
      if (temporary.existsSync()) {
        temporary.deleteSync();
        storagePolicy.syncDirectory(_file.parent);
      }
      return _readCanonical();
    }

    final marker = _decodeCommitMarker(markerFile);
    _OutboxSnapshot? canonical;
    Object? canonicalFailure;
    try {
      canonical = _readCanonical();
    } catch (error) {
      canonicalFailure = error;
    }
    if (canonical != null && marker.matches(canonical)) {
      markerFile.deleteSync();
      if (temporary.existsSync()) {
        temporary.deleteSync();
      }
      storagePolicy.syncDirectory(_file.parent);
      return canonical;
    }
    if (canonical != null && canonical.generation > marker.generation) {
      markerFile.deleteSync();
      if (temporary.existsSync()) {
        temporary.deleteSync();
      }
      storagePolicy.syncDirectory(_file.parent);
      return canonical;
    }
    if (canonical != null && canonical.generation == marker.generation) {
      throw const FormatException(
        'Single-chat outbox has conflicting commits at one generation.',
      );
    }
    if (!temporary.existsSync()) {
      throw FormatException(
        'Committed single-chat outbox temporary payload is missing.',
        canonicalFailure,
      );
    }
    final staged = _decodeSnapshot(temporary);
    if (!marker.matches(staged)) {
      throw const FormatException(
        'Single-chat outbox commit marker does not match its payload.',
      );
    }
    temporary.renameSync(_file.path);
    storagePolicy.protectAndExcludeFromBackup(_file);
    storagePolicy.syncDirectory(_file.parent);
    markerFile.deleteSync();
    storagePolicy.syncDirectory(_file.parent);
    return staged;
  }

  _OutboxSnapshot _readCanonical() {
    if (!_file.existsSync()) {
      return const _OutboxSnapshot(generation: 0, txId: 'empty', records: []);
    }
    return _decodeSnapshot(_file);
  }

  void _persistLocked(
    _OutboxSnapshot snapshot, {
    required int expectedGeneration,
  }) {
    final latest = _readCanonical();
    if (latest.generation != expectedGeneration) {
      throw StateError('Single-chat outbox generation conflict.');
    }
    final txId = _newTransactionId();
    final committed = snapshot.copyWith(txId: txId);
    final encoded = _encodeSnapshot(committed);
    final payloadDigest = sha256.convert(utf8.encode(encoded)).toString();
    final temporary = File('${_file.path}.tmp');
    final nextMarker = File('${_file.path}.commit.next');
    final marker = File('${_file.path}.commit');
    temporary.writeAsStringSync(encoded, flush: true);
    storagePolicy.protectAndExcludeFromBackup(temporary);
    nextMarker.writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'generation': committed.generation,
        'txId': committed.txId,
        'payloadSha256': payloadDigest,
      }),
      flush: true,
    );
    storagePolicy.protectAndExcludeFromBackup(nextMarker);
    nextMarker.renameSync(marker.path);
    storagePolicy.syncDirectory(_file.parent);
    temporary.renameSync(_file.path);
    storagePolicy.protectAndExcludeFromBackup(_file);
    storagePolicy.syncDirectory(_file.parent);
    marker.deleteSync();
    storagePolicy.syncDirectory(_file.parent);
  }
}

class MonotonicUlidGenerator {
  MonotonicUlidGenerator({
    int Function()? nowMilliseconds,
    List<int> Function(int)? randomBytes,
  }) : _nowMilliseconds =
           nowMilliseconds ?? (() => DateTime.now().millisecondsSinceEpoch),
       _randomBytes = randomBytes ?? _secureRandomBytes;

  static final shared = MonotonicUlidGenerator();
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  static final BigInt _randomMask = (BigInt.one << 80) - BigInt.one;

  final int Function() _nowMilliseconds;
  final List<int> Function(int) _randomBytes;
  int _lastTimestamp = -1;
  BigInt _lastRandom = BigInt.zero;

  String next() {
    var timestamp = _nowMilliseconds();
    if (timestamp < 0) {
      timestamp = 0;
    }
    if (timestamp > _lastTimestamp) {
      _lastTimestamp = timestamp;
      _lastRandom = _bytesToBigInt(_randomBytes(10)) & _randomMask;
    } else {
      timestamp = _lastTimestamp;
      _lastRandom = (_lastRandom + BigInt.one) & _randomMask;
      if (_lastRandom == BigInt.zero) {
        timestamp += 1;
        _lastTimestamp = timestamp;
      }
    }

    var value = (BigInt.from(timestamp) << 80) | _lastRandom;
    final characters = List<String>.filled(26, '0');
    for (var index = 25; index >= 0; index -= 1) {
      characters[index] = _alphabet[(value & BigInt.from(31)).toInt()];
      value >>= 5;
    }
    return characters.join();
  }
}

abstract interface class ChatMessageRepository {
  SingleChatCommandOutbox get commandOutbox;

  SingleChatConversationProjection describe(String conversationId);

  Future<List<ChatMessageProjection>> load(String conversationId);

  Future<void> append(String conversationId, ChatMessageProjection message);

  /// A durable implementation must bind an inserted projection to the token's
  /// owner id and generation, and revoke only that exact owned revision.
  Future<ChatMessageCommitResult> appendIf(
    String conversationId,
    ChatMessageProjection message,
    ChatMessageCommitToken token,
    bool Function() shouldAppend,
  );

  /// Compare-and-removes the exact owner/generation/storage revision returned
  /// by [appendIf]. Message id alone is never sufficient authorization.
  Future<ChatMessageRollbackDisposition> rollbackOwned(
    String conversationId,
    ChatMessageCommitResult commit,
  );
}

abstract interface class DurableChatMessageRepository
    implements ChatMessageRepository {
  Future<void> close();
}

String encodeChatMessageProjection(ChatMessageProjection message) {
  return jsonEncode({
    'id': message.id,
    'kind': message.kind.name,
    'text': message.text,
    'secondaryText': message.secondaryText,
    'tertiaryText': message.tertiaryText,
    'imageUrl': message.imageUrl,
    'progress': message.progress,
    'sourceType': message.sourceType?.name,
    'uncertainty': message.uncertainty,
    'evidenceReferences': message.evidenceReferences,
    'verificationAttestation': message.verificationAttestation == null
        ? null
        : {
            'receiptId': message.verificationAttestation!.receiptId,
            'expertId': message.verificationAttestation!.expertId,
            'runId': message.verificationAttestation!.runId,
            'commandId': message.verificationAttestation!.commandId,
          },
    'dispatchClaimOwner': message.dispatchClaimOwner,
    'dispatchClaimGeneration': message.dispatchClaimGeneration,
  });
}

ChatMessageProjection decodeChatMessageProjection(String encoded) {
  try {
    final decoded = jsonDecode(encoded);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException(
        'Single-chat message projection must be an object.',
      );
    }
    final id = decoded['id'];
    final rawKind = decoded['kind'];
    final rawText = decoded['text'];
    final rawSecondaryText = decoded['secondaryText'];
    final rawTertiaryText = decoded['tertiaryText'];
    final rawImageUrl = decoded['imageUrl'];
    final rawProgress = decoded['progress'];
    final rawSourceType = decoded['sourceType'];
    final rawUncertainty = decoded['uncertainty'];
    final rawEvidence = decoded['evidenceReferences'];
    final rawAttestation = decoded['verificationAttestation'];
    final rawDispatchOwner = decoded['dispatchClaimOwner'];
    final rawDispatchGeneration = decoded['dispatchClaimGeneration'];
    if (id is! String ||
        id.isEmpty ||
        rawKind is! String ||
        !_isNullableString(rawText) ||
        !_isNullableString(rawSecondaryText) ||
        !_isNullableString(rawTertiaryText) ||
        !_isNullableString(rawImageUrl) ||
        (rawProgress != null &&
            (rawProgress is! num || !rawProgress.isFinite)) ||
        !_isNullableString(rawSourceType) ||
        !_isNullableString(rawUncertainty) ||
        rawEvidence is! List<Object?> ||
        rawEvidence.any((item) => item is! String) ||
        !_isNullableString(rawDispatchOwner) ||
        (rawDispatchGeneration != null &&
            (rawDispatchGeneration is! int || rawDispatchGeneration <= 0)) ||
        ((rawDispatchOwner == null) != (rawDispatchGeneration == null))) {
      throw const FormatException(
        'Single-chat message projection contains invalid typed fields.',
      );
    }
    ChatMessageKind kind;
    try {
      kind = ChatMessageKind.values.byName(rawKind);
    } on ArgumentError {
      throw const FormatException(
        'Single-chat message projection kind is invalid.',
      );
    }
    ChatMessageSourceType? sourceType;
    if (rawSourceType != null) {
      try {
        sourceType = ChatMessageSourceType.values.byName(
          rawSourceType as String,
        );
      } on ArgumentError {
        throw const FormatException(
          'Single-chat message source type is invalid.',
        );
      }
    }
    ChatMessageVerificationAttestation? attestation;
    if (rawAttestation != null) {
      if (rawAttestation is! Map<String, Object?>) {
        throw const FormatException(
          'Single-chat verification attestation must be an object.',
        );
      }
      final receiptId = rawAttestation['receiptId'];
      final expertId = rawAttestation['expertId'];
      final runId = rawAttestation['runId'];
      final commandId = rawAttestation['commandId'];
      if (receiptId is! String ||
          receiptId.isEmpty ||
          expertId is! String ||
          expertId.isEmpty ||
          runId is! String ||
          runId.isEmpty ||
          commandId is! String ||
          commandId.isEmpty) {
        throw const FormatException(
          'Single-chat verification attestation is invalid.',
        );
      }
      attestation = ChatMessageVerificationAttestation(
        receiptId: receiptId,
        expertId: expertId,
        runId: runId,
        commandId: commandId,
      );
    }
    return ChatMessageProjection(
      id: id,
      kind: kind,
      text: rawText as String?,
      secondaryText: rawSecondaryText as String?,
      tertiaryText: rawTertiaryText as String?,
      imageUrl: rawImageUrl as String?,
      progress: (rawProgress as num?)?.toDouble(),
      sourceType: sourceType,
      uncertainty: rawUncertainty as String?,
      evidenceReferences: List<String>.unmodifiable(rawEvidence.cast<String>()),
      verificationAttestation: attestation,
      dispatchClaimOwner: rawDispatchOwner as String?,
      dispatchClaimGeneration: rawDispatchGeneration as int?,
    );
  } on FormatException {
    rethrow;
  } on Object catch (error) {
    throw FormatException('Invalid single-chat message projection.', error);
  }
}

bool _isNullableString(Object? value) => value == null || value is String;

class InMemoryChatMessageRepository implements ChatMessageRepository {
  InMemoryChatMessageRepository({
    Map<String, List<ChatMessageProjection>> seed = const {},
    Map<String, SingleChatConversationProjection> conversations = const {},
    SingleChatCommandOutbox? commandOutbox,
  }) : _messages = {
         for (final entry in seed.entries)
           entry.key: List<ChatMessageProjection>.of(entry.value),
       },
       _conversations = Map.of(conversations),
       commandOutbox = commandOutbox ?? InMemorySingleChatCommandOutbox();

  final Map<String, List<ChatMessageProjection>> _messages;
  final Map<String, Map<String, _MessageOwnership>> _messageOwnership = {};
  final Map<String, SingleChatConversationProjection> _conversations;
  int _nextStorageRevision = 0;
  @override
  final SingleChatCommandOutbox commandOutbox;

  @override
  SingleChatConversationProjection describe(String conversationId) {
    final conversation = _conversations[conversationId];
    if (conversation == null) {
      throw StateError('Unknown single-chat conversation.');
    }
    return conversation;
  }

  @override
  Future<List<ChatMessageProjection>> load(String conversationId) async {
    return List<ChatMessageProjection>.unmodifiable(
      _messages[conversationId] ?? const [],
    );
  }

  @override
  Future<void> append(
    String conversationId,
    ChatMessageProjection message,
  ) async {
    final messages = _messages[conversationId] ??= [];
    for (final existing in messages) {
      if (existing.id != message.id) {
        continue;
      }
      if (_sameMessageProjection(existing, message)) {
        return;
      }
      throw StateError(
        'Single-chat message id is already bound to different content.',
      );
    }
    messages.add(message);
  }

  @override
  Future<ChatMessageCommitResult> appendIf(
    String conversationId,
    ChatMessageProjection message,
    ChatMessageCommitToken token,
    bool Function() shouldAppend,
  ) async {
    if (!token.isValid || !shouldAppend()) {
      return ChatMessageCommitResult(
        messageId: message.id,
        committed: false,
        inserted: false,
        ownerId: token.value,
        ownerGeneration: token.generation,
      );
    }
    final messages = _messages[conversationId] ??= [];
    ChatMessageProjection? existing;
    for (final candidate in messages) {
      if (candidate.id == message.id) {
        existing = candidate;
        break;
      }
    }
    if (existing != null) {
      return ChatMessageCommitResult(
        messageId: message.id,
        committed: _sameMessageProjection(existing, message),
        inserted: false,
        ownerId: token.value,
        ownerGeneration: token.generation,
      );
    }
    const inserted = true;
    int? storageRevision;
    messages.add(message);
    storageRevision = ++_nextStorageRevision;
    final ownership = _MessageOwnership(
      ownerId: token.value,
      ownerGeneration: token.generation,
      storageRevision: storageRevision,
    );
    (_messageOwnership[conversationId] ??= {})[message.id] = ownership;
    token.onInvalidated(() {
      _removeIfOwned(conversationId, message.id, ownership);
    });
    return ChatMessageCommitResult(
      messageId: message.id,
      committed: true,
      inserted: inserted,
      ownerId: token.value,
      ownerGeneration: token.generation,
      storageRevision: storageRevision,
    );
  }

  @override
  Future<ChatMessageRollbackDisposition> rollbackOwned(
    String conversationId,
    ChatMessageCommitResult commit,
  ) async {
    if (!commit.inserted) {
      return ChatMessageRollbackDisposition.commitDidNotInsert;
    }
    final ownerId = commit.ownerId;
    final ownerGeneration = commit.ownerGeneration;
    final storageRevision = commit.storageRevision;
    if (ownerId == null || ownerGeneration == null || storageRevision == null) {
      return ChatMessageRollbackDisposition.ownershipMismatch;
    }
    return _removeIfOwned(
      conversationId,
      commit.messageId,
      _MessageOwnership(
        ownerId: ownerId,
        ownerGeneration: ownerGeneration,
        storageRevision: storageRevision,
      ),
    );
  }

  ChatMessageRollbackDisposition _removeIfOwned(
    String conversationId,
    String messageId,
    _MessageOwnership expected,
  ) {
    final owners = _messageOwnership[conversationId];
    final actual = owners?[messageId];
    if (actual == null) {
      final stillPresent =
          _messages[conversationId]?.any(
            (message) => message.id == messageId,
          ) ??
          false;
      return stillPresent
          ? ChatMessageRollbackDisposition.ownershipMismatch
          : ChatMessageRollbackDisposition.alreadyAbsent;
    }
    if (actual != expected) {
      return ChatMessageRollbackDisposition.ownershipMismatch;
    }
    _messages[conversationId]?.removeWhere(
      (message) => message.id == messageId,
    );
    owners!.remove(messageId);
    return ChatMessageRollbackDisposition.removedOwnedRevision;
  }
}

bool _sameMessageProjection(
  ChatMessageProjection left,
  ChatMessageProjection right,
) {
  return left.id == right.id &&
      left.kind == right.kind &&
      left.text == right.text &&
      left.secondaryText == right.secondaryText &&
      left.tertiaryText == right.tertiaryText &&
      left.imageUrl == right.imageUrl &&
      left.progress == right.progress &&
      left.sourceType == right.sourceType &&
      left.uncertainty == right.uncertainty &&
      _sameStrings(left.evidenceReferences, right.evidenceReferences) &&
      _sameVerificationAttestation(
        left.verificationAttestation,
        right.verificationAttestation,
      ) &&
      left.dispatchClaimOwner == right.dispatchClaimOwner &&
      left.dispatchClaimGeneration == right.dispatchClaimGeneration;
}

bool _sameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}

bool _sameVerificationAttestation(
  ChatMessageVerificationAttestation? left,
  ChatMessageVerificationAttestation? right,
) {
  if (identical(left, right)) {
    return true;
  }
  return left != null &&
      right != null &&
      left.receiptId == right.receiptId &&
      left.expertId == right.expertId &&
      left.runId == right.runId &&
      left.commandId == right.commandId;
}

class _MessageOwnership {
  const _MessageOwnership({
    required this.ownerId,
    required this.ownerGeneration,
    required this.storageRevision,
  });

  final String ownerId;
  final int ownerGeneration;
  final int storageRevision;

  @override
  bool operator ==(Object other) =>
      other is _MessageOwnership &&
      ownerId == other.ownerId &&
      ownerGeneration == other.ownerGeneration &&
      storageRevision == other.storageRevision;

  @override
  int get hashCode => Object.hash(ownerId, ownerGeneration, storageRevision);
}

List<int> _secureRandomBytes(int length) {
  final random = Random.secure();
  return List<int>.generate(length, (_) => random.nextInt(256));
}

BigInt _bytesToBigInt(List<int> bytes) {
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte & 0xff);
  }
  return value;
}

class _IsolateMutexOwnership {
  const _IsolateMutexOwnership(this.file, this.ownerToken);

  final File file;
  final String ownerToken;

  void release() {
    try {
      if (file.existsSync() && file.readAsStringSync() == ownerToken) {
        file.deleteSync();
      }
    } on FileSystemException {
      // A failed exact-owner cleanup only delays later writers until lease
      // recovery; it never authorizes deleting a successor's mutex.
    }
  }
}

class _OutboxSnapshot {
  const _OutboxSnapshot({
    required this.generation,
    required this.txId,
    required this.records,
  });

  final int generation;
  final String txId;
  final List<SingleChatCommandRecord> records;

  _OutboxSnapshot copyWith({
    int? generation,
    String? txId,
    List<SingleChatCommandRecord>? records,
  }) {
    return _OutboxSnapshot(
      generation: generation ?? this.generation,
      txId: txId ?? this.txId,
      records: records ?? this.records,
    );
  }
}

class _OutboxCommitMarker {
  const _OutboxCommitMarker({
    required this.generation,
    required this.txId,
    required this.payloadSha256,
  });

  final int generation;
  final String txId;
  final String payloadSha256;

  bool matches(_OutboxSnapshot snapshot) {
    if (generation != snapshot.generation || txId != snapshot.txId) {
      return false;
    }
    return payloadSha256 ==
        sha256.convert(utf8.encode(_encodeSnapshot(snapshot))).toString();
  }
}

_OutboxSnapshot _decodeSnapshot(File file) {
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Single-chat outbox root must be an object.');
    }
    if (decoded['schemaVersion'] != 1) {
      throw const FormatException(
        'Unsupported single-chat outbox schema version.',
      );
    }
    final generation = decoded['generation'];
    final txId = decoded['txId'];
    final rawRecords = decoded['records'];
    if (generation is! int || generation < 0) {
      throw const FormatException(
        'Single-chat outbox generation must be a non-negative integer.',
      );
    }
    if (txId is! String || txId.isEmpty) {
      throw const FormatException(
        'Single-chat outbox transaction id is invalid.',
      );
    }
    if (rawRecords is! List<Object?>) {
      throw const FormatException('Single-chat outbox records must be a list.');
    }
    final records = <SingleChatCommandRecord>[];
    final keys = <String>{};
    for (final item in rawRecords) {
      if (item is! Map<String, Object?>) {
        throw const FormatException(
          'Single-chat outbox record must be an object.',
        );
      }
      final conversationId = item['conversationId'];
      final commandId = item['commandId'];
      final normalizedIntent = item['normalizedIntent'];
      final rawStatus = item['status'];
      final revision = item['revision'];
      final dispatchClaimOwner = item['dispatchClaimOwner'];
      final dispatchClaimGeneration = item['dispatchClaimGeneration'];
      final dispatchClaimExpiresAtEpochMs =
          item['dispatchClaimExpiresAtEpochMs'];
      final terminalOwner = item['terminalOwner'];
      final terminalGeneration = item['terminalGeneration'];
      final hasDispatchClaimField =
          dispatchClaimOwner != null ||
          dispatchClaimGeneration != null ||
          dispatchClaimExpiresAtEpochMs != null;
      final hasTerminalOwnerField =
          terminalOwner != null || terminalGeneration != null;
      if (conversationId is! String ||
          conversationId.isEmpty ||
          commandId is! String ||
          commandId.isEmpty ||
          normalizedIntent is! String ||
          normalizedIntent.isEmpty ||
          rawStatus is! String ||
          revision is! int ||
          revision < 0 ||
          (hasDispatchClaimField &&
              (dispatchClaimOwner is! String ||
                  dispatchClaimOwner.isEmpty ||
                  dispatchClaimGeneration is! int ||
                  dispatchClaimGeneration <= 0 ||
                  dispatchClaimGeneration != revision ||
                  dispatchClaimExpiresAtEpochMs is! int ||
                  dispatchClaimExpiresAtEpochMs <= 0)) ||
          (hasTerminalOwnerField &&
              (terminalOwner is! String ||
                  terminalOwner.isEmpty ||
                  terminalGeneration is! int ||
                  terminalGeneration <= 0 ||
                  terminalGeneration >= revision))) {
        throw const FormatException(
          'Single-chat outbox record contains invalid typed fields.',
        );
      }
      SingleChatCommandStatus status;
      try {
        status = SingleChatCommandStatus.values.byName(rawStatus);
      } on ArgumentError {
        throw const FormatException(
          'Single-chat outbox record status is invalid.',
        );
      }
      if (hasDispatchClaimField && status != SingleChatCommandStatus.pending) {
        throw const FormatException(
          'A terminal single-chat command cannot retain a dispatch claim.',
        );
      }
      if (hasTerminalOwnerField && status == SingleChatCommandStatus.pending) {
        throw const FormatException(
          'A pending single-chat command cannot retain terminal ownership.',
        );
      }
      if (!keys.add('$conversationId\u0000$commandId')) {
        throw const FormatException(
          'Single-chat outbox contains duplicate command records.',
        );
      }
      records.add(
        SingleChatCommandRecord(
          conversationId: conversationId,
          commandId: commandId,
          normalizedIntent: normalizedIntent,
          status: status,
          revision: revision,
          dispatchClaimOwner: hasDispatchClaimField
              ? dispatchClaimOwner as String
              : null,
          dispatchClaimGeneration: hasDispatchClaimField
              ? dispatchClaimGeneration as int
              : null,
          dispatchClaimExpiresAtEpochMs: hasDispatchClaimField
              ? dispatchClaimExpiresAtEpochMs as int
              : null,
          terminalOwner: hasTerminalOwnerField ? terminalOwner as String : null,
          terminalGeneration: hasTerminalOwnerField
              ? terminalGeneration as int
              : null,
        ),
      );
    }
    return _OutboxSnapshot(
      generation: generation,
      txId: txId,
      records: List<SingleChatCommandRecord>.unmodifiable(records),
    );
  } on FormatException {
    rethrow;
  } on Object catch (error) {
    throw FormatException('Invalid single-chat command outbox.', error);
  }
}

_OutboxCommitMarker _decodeCommitMarker(File file) {
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    final generation = decoded is Map<String, Object?>
        ? decoded['generation']
        : null;
    final txId = decoded is Map<String, Object?> ? decoded['txId'] : null;
    final payloadSha256 = decoded is Map<String, Object?>
        ? decoded['payloadSha256']
        : null;
    if (decoded is! Map<String, Object?> ||
        decoded['schemaVersion'] != 1 ||
        generation is! int ||
        generation < 0 ||
        txId is! String ||
        txId.isEmpty ||
        payloadSha256 is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(payloadSha256)) {
      throw const FormatException('Invalid single-chat outbox commit marker.');
    }
    return _OutboxCommitMarker(
      generation: generation,
      txId: txId,
      payloadSha256: payloadSha256,
    );
  } on FormatException {
    rethrow;
  } on Object catch (error) {
    throw FormatException('Invalid single-chat outbox commit marker.', error);
  }
}

String _encodeSnapshot(_OutboxSnapshot snapshot) {
  return jsonEncode({
    'schemaVersion': 1,
    'generation': snapshot.generation,
    'txId': snapshot.txId,
    'records': [
      for (final record in snapshot.records) _encodeCommandRecord(record),
    ],
  });
}

Map<String, Object?> _encodeCommandRecord(SingleChatCommandRecord record) {
  final encoded = <String, Object?>{
    'conversationId': record.conversationId,
    'commandId': record.commandId,
    'normalizedIntent': record.normalizedIntent,
    'status': record.status.name,
    'revision': record.revision,
  };
  if (record.dispatchClaimOwner case final owner?) {
    encoded['dispatchClaimOwner'] = owner;
  }
  if (record.dispatchClaimGeneration case final generation?) {
    encoded['dispatchClaimGeneration'] = generation;
  }
  if (record.dispatchClaimExpiresAtEpochMs case final expiresAt?) {
    encoded['dispatchClaimExpiresAtEpochMs'] = expiresAt;
  }
  if (record.terminalOwner case final owner?) {
    encoded['terminalOwner'] = owner;
  }
  if (record.terminalGeneration case final generation?) {
    encoded['terminalGeneration'] = generation;
  }
  return encoded;
}

String _newTransactionId() {
  final bytes = _secureRandomBytes(16);
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

File _canonicalOutboxFile(String path) {
  final absolute = File(path).absolute;
  final parent = absolute.parent;
  if (!parent.existsSync()) {
    return absolute;
  }
  return File(
    '${parent.resolveSymbolicLinksSync()}${Platform.pathSeparator}${absolute.uri.pathSegments.last}',
  );
}

class FixtureChatMessageRepository extends InMemoryChatMessageRepository {
  FixtureChatMessageRepository({
    SingleChatCommandOutbox? commandOutbox,
    bool includeRichHistory = false,
  }) : super(
         conversations: _fixtureConversations,
         commandOutbox: commandOutbox ?? InMemorySingleChatCommandOutbox(),
         seed: includeRichHistory
             ? {
                 for (final conversationId in _fixtureConversations.keys)
                   conversationId: _richHistory,
               }
             : const {},
       );
}

class SingleChatCatalogRepository extends InMemoryChatMessageRepository {
  SingleChatCatalogRepository()
    : super(
        conversations: _fixtureConversations,
        commandOutbox: InMemorySingleChatCommandOutbox(),
      );
}

const _fixtureConversations = <String, SingleChatConversationProjection>{
  'general-assistant': SingleChatConversationProjection(
    conversationId: 'general-assistant',
    expertId: 'general',
    title: '通用助理',
    agentName: '通用助理',
    modelLabel: 'ToAPIs / gpt-5-mini',
    avatarLetter: '助',
    avatarImageUrl:
        'https://images.unsplash.com/photo-1494790108377-be9c29b29330?w=120',
  ),
  'data-analyst-chat': SingleChatConversationProjection(
    conversationId: 'data-analyst-chat',
    expertId: 'data-analyst',
    title: '数据分析师',
    agentName: '数据分析师',
    modelLabel: 'DeepSeek / deepseek-chat',
    avatarLetter: '数',
  ),
  'calendar-assistant': SingleChatConversationProjection(
    conversationId: 'calendar-assistant',
    expertId: 'calendar',
    title: '日程管家',
    agentName: '日程管家',
    modelLabel: 'Doubao / end-to-end voice',
    avatarLetter: '日',
  ),
  'contract-review-chat': SingleChatConversationProjection(
    conversationId: 'contract-review-chat',
    expertId: 'legal-risk-advisor',
    title: '合同审阅助手',
    agentName: '合同审阅助手',
    modelLabel: 'ToAPIs / gpt-5-mini',
    avatarLetter: '合',
  ),
  'monitoring-chat': SingleChatConversationProjection(
    conversationId: 'monitoring-chat',
    expertId: 'fact-checker',
    title: '信息监控',
    agentName: '信息观察员',
    modelLabel: 'DeepSeek / deepseek-chat',
    avatarLetter: '监',
  ),
  'deep-research-task': SingleChatConversationProjection(
    conversationId: 'deep-research-task',
    expertId: 'industry-researcher',
    title: '深度研究任务',
    agentName: '研究员',
    modelLabel: 'Anthropic / claude-sonnet-4',
    avatarLetter: '研',
  ),
};

const _richHistory = <ChatMessageProjection>[
  ChatMessageProjection(
    id: 'fixture-system',
    kind: ChatMessageKind.systemNotice,
    text: '今天 10:02 · 已启用共享事实记忆',
  ),
  ChatMessageProjection(
    id: 'fixture-user',
    kind: ChatMessageKind.userText,
    text: '结合我刚发的材料，整理一版面向投资人的竞品分析。',
  ),
  ChatMessageProjection(
    id: 'fixture-agent',
    kind: ChatMessageKind.agentText,
    text: '收到。我先让研究员核验关键数据，再整理成市场格局、差异化和风险三部分。',
    sourceType: ChatMessageSourceType.modelOutput,
    uncertainty: '历史演示内容，未绑定可验证来源',
  ),
  ChatMessageProjection(
    id: 'fixture-progress',
    kind: ChatMessageKind.progress,
    text: '任务进行中',
    secondaryText: '已核验 16 / 23 个来源',
    progress: .68,
  ),
  ChatMessageProjection(
    id: 'fixture-file',
    kind: ChatMessageKind.file,
    text: '个人 AI 通讯竞品分析.pdf',
    secondaryText: '12 页 · 2.4 MB · 已完成',
    tertiaryText: '8 个来源 · 已沉淀至圈层',
  ),
  ChatMessageProjection(
    id: 'fixture-image',
    kind: ChatMessageKind.userImage,
    imageUrl: 'https://images.unsplash.com/photo-1551288049-bebda4e38f71?w=520',
  ),
  ChatMessageProjection(
    id: 'fixture-quote',
    kind: ChatMessageKind.quote,
    secondaryText: '你发来的数据看板',
    text: '我补充核对了漏斗口径：注册到首次有效对话的转化率应为 42.8%，原图少算了跨端登录。',
  ),
];
