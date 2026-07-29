import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'chat_message_repository.dart';

part 'drift_chat_message_repository.g.dart';

class SingleChatConversations extends Table {
  TextColumn get conversationId => text()();
  TextColumn get expertId => text()();

  @override
  Set<Column<Object>> get primaryKey => {conversationId};
}

class SingleChatMessages extends Table {
  IntColumn get storageRevision => integer().autoIncrement()();
  TextColumn get conversationId => text()();
  TextColumn get messageId => text()();
  TextColumn get projectionJson => text()();
  TextColumn get projectionSha256 => text()();
  TextColumn get ownerId => text().nullable()();
  IntColumn get ownerGeneration => integer().nullable()();

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {conversationId, messageId},
  ];
}

@DriftDatabase(tables: [SingleChatConversations, SingleChatMessages])
class _SingleChatDatabase extends _$_SingleChatDatabase {
  _SingleChatDatabase(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) async => migrator.createAll(),
    onUpgrade: (migrator, from, to) async {
      throw StateError('Unsupported single-chat history schema version $from.');
    },
  );
}

/// Drift-backed durable storage for a single chat's message projections.
final class DriftChatMessageRepository implements DurableChatMessageRepository {
  DriftChatMessageRepository._({
    required this._database,
    required this._commandOutbox,
    required Map<String, SingleChatConversationProjection> conversations,
    required this._storagePolicy,
    required this._databaseFile,
  }) : _conversations = Map.unmodifiable(conversations);

  static Future<DriftChatMessageRepository> open({
    required String databasePath,
    required FileSingleChatCommandOutbox commandOutbox,
    required Map<String, SingleChatConversationProjection> conversations,
    SingleChatOutboxStoragePolicy storagePolicy =
        const BestEffortSingleChatOutboxStoragePolicy(),
  }) async {
    final file = File(databasePath).absolute;
    storagePolicy.prepareDirectory(file.parent);
    final database = _SingleChatDatabase(
      NativeDatabase.createInBackground(file, setup: _configureNativeDatabase),
    );
    final repository = DriftChatMessageRepository._(
      database: database,
      commandOutbox: commandOutbox,
      conversations: conversations,
      storagePolicy: storagePolicy,
      databaseFile: file,
    );
    try {
      await database.customSelect('SELECT 1').get();
      await repository._bindConversations();
      repository._protectDatabaseFile();
      return repository;
    } on Object catch (error, stackTrace) {
      await database.close();
      if (error.toString().contains(
        'Unsupported single-chat history schema version',
      )) {
        Error.throwWithStackTrace(
          StateError('Unsupported single-chat history schema version.'),
          stackTrace,
        );
      }
      rethrow;
    }
  }

  final _SingleChatDatabase _database;
  final FileSingleChatCommandOutbox _commandOutbox;
  final Map<String, SingleChatConversationProjection> _conversations;
  final SingleChatOutboxStoragePolicy _storagePolicy;
  final File _databaseFile;
  bool _closed = false;
  Future<void>? _closing;

  @override
  SingleChatCommandOutbox get commandOutbox {
    _ensureOpen();
    return _commandOutbox;
  }

  @override
  SingleChatConversationProjection describe(String conversationId) {
    _ensureOpen();
    final conversation = _conversations[conversationId];
    if (conversation == null) {
      throw StateError('Unknown single-chat conversation.');
    }
    return conversation;
  }

  @override
  Future<List<ChatMessageProjection>> load(String conversationId) async {
    _ensureOpen();
    final rows =
        await (_database.select(_database.singleChatMessages)
              ..where((row) => row.conversationId.equals(conversationId))
              ..orderBy([(row) => OrderingTerm.asc(row.storageRevision)]))
            .get();
    return List<ChatMessageProjection>.unmodifiable(
      rows.map(_decodeStoredMessage),
    );
  }

  @override
  Future<void> append(
    String conversationId,
    ChatMessageProjection message,
  ) async {
    _ensureOpen();
    await _database.transaction(() async {
      final existing = await _findMessage(conversationId, message.id);
      if (existing != null) {
        if (_sameStoredMessage(existing, message)) {
          return;
        }
        throw StateError(
          'Single-chat message id is already bound to different content.',
        );
      }
      await _insertMessage(conversationId: conversationId, message: message);
    });
    _protectDatabaseFile();
  }

  @override
  Future<ChatMessageCommitResult> appendIf(
    String conversationId,
    ChatMessageProjection message,
    ChatMessageCommitToken token,
    bool Function() shouldAppend,
  ) async {
    _ensureOpen();
    if (!token.isValid) {
      return _uncommitted(message.id, token);
    }
    final result = await _database.transaction(() async {
      if (!token.isValid || !shouldAppend()) {
        return _uncommitted(message.id, token);
      }
      final existing = await _findMessage(conversationId, message.id);
      if (existing != null) {
        return ChatMessageCommitResult(
          messageId: message.id,
          committed: _sameStoredMessage(existing, message),
          inserted: false,
          ownerId: token.value,
          ownerGeneration: token.generation,
        );
      }
      final storageRevision = await _insertMessage(
        conversationId: conversationId,
        message: message,
        ownerId: token.value,
        ownerGeneration: token.generation,
      );
      return ChatMessageCommitResult(
        messageId: message.id,
        committed: true,
        inserted: true,
        ownerId: token.value,
        ownerGeneration: token.generation,
        storageRevision: storageRevision,
      );
    });
    _protectDatabaseFile();
    if (result.committed && result.inserted) {
      token.onInvalidated(() {
        unawaited(() async {
          try {
            await rollbackOwned(conversationId, result);
          } on Object {
            // The controller performs and observes its own compensation.
          }
        }());
      });
    }
    return result;
  }

  @override
  Future<ChatMessageRollbackDisposition> rollbackOwned(
    String conversationId,
    ChatMessageCommitResult commit,
  ) async {
    _ensureOpen();
    if (!commit.inserted) {
      return ChatMessageRollbackDisposition.commitDidNotInsert;
    }
    final ownerId = commit.ownerId;
    final ownerGeneration = commit.ownerGeneration;
    final storageRevision = commit.storageRevision;
    if (ownerId == null || ownerGeneration == null || storageRevision == null) {
      return ChatMessageRollbackDisposition.ownershipMismatch;
    }
    return _database.transaction(() async {
      final current = await _findMessage(conversationId, commit.messageId);
      if (current == null) {
        return ChatMessageRollbackDisposition.alreadyAbsent;
      }
      if (current.ownerId != ownerId ||
          current.ownerGeneration != ownerGeneration ||
          current.storageRevision != storageRevision) {
        return ChatMessageRollbackDisposition.ownershipMismatch;
      }
      await (_database.delete(_database.singleChatMessages)..where(
            (row) =>
                row.conversationId.equals(conversationId) &
                row.messageId.equals(commit.messageId) &
                row.ownerId.equals(ownerId) &
                row.ownerGeneration.equals(ownerGeneration) &
                row.storageRevision.equals(storageRevision),
          ))
          .go();
      return ChatMessageRollbackDisposition.removedOwnedRevision;
    });
  }

  @override
  Future<void> close() {
    final closing = _closing;
    if (closing != null) {
      return closing;
    }
    _closed = true;
    return _closing = _database.close();
  }

  Future<void> _bindConversations() {
    return _database.transaction(() async {
      for (final conversation in _conversations.values) {
        if (conversation.conversationId.isEmpty ||
            conversation.expertId.isEmpty) {
          throw ArgumentError('Single-chat conversation binding is invalid.');
        }
        final existing =
            await (_database.select(_database.singleChatConversations)..where(
                  (row) =>
                      row.conversationId.equals(conversation.conversationId),
                ))
                .getSingleOrNull();
        if (existing != null) {
          if (existing.expertId != conversation.expertId) {
            throw StateError(
              'Single-chat conversation expert binding has changed.',
            );
          }
          continue;
        }
        await _database
            .into(_database.singleChatConversations)
            .insert(
              SingleChatConversationsCompanion.insert(
                conversationId: conversation.conversationId,
                expertId: conversation.expertId,
              ),
            );
      }
    });
  }

  Future<SingleChatMessage?> _findMessage(
    String conversationId,
    String messageId,
  ) {
    return (_database.select(_database.singleChatMessages)..where(
          (row) =>
              row.conversationId.equals(conversationId) &
              row.messageId.equals(messageId),
        ))
        .getSingleOrNull();
  }

  Future<int> _insertMessage({
    required String conversationId,
    required ChatMessageProjection message,
    String? ownerId,
    int? ownerGeneration,
  }) {
    final projectionJson = encodeChatMessageProjection(message);
    return _database
        .into(_database.singleChatMessages)
        .insert(
          SingleChatMessagesCompanion.insert(
            conversationId: conversationId,
            messageId: message.id,
            projectionJson: projectionJson,
            projectionSha256: sha256
                .convert(utf8.encode(projectionJson))
                .toString(),
            ownerId: Value(ownerId),
            ownerGeneration: Value(ownerGeneration),
          ),
        );
  }

  ChatMessageProjection _decodeStoredMessage(SingleChatMessage stored) {
    final expectedDigest = sha256
        .convert(utf8.encode(stored.projectionJson))
        .toString();
    if (stored.messageId.isEmpty || stored.projectionSha256 != expectedDigest) {
      throw const FormatException(
        'Single-chat history message envelope is invalid.',
      );
    }
    final projection = decodeChatMessageProjection(stored.projectionJson);
    if (projection.id != stored.messageId) {
      throw const FormatException(
        'Single-chat history message id does not match its projection.',
      );
    }
    return projection;
  }

  bool _sameStoredMessage(
    SingleChatMessage stored,
    ChatMessageProjection message,
  ) {
    _decodeStoredMessage(stored);
    return stored.projectionJson == encodeChatMessageProjection(message);
  }

  ChatMessageCommitResult _uncommitted(
    String messageId,
    ChatMessageCommitToken token,
  ) {
    return ChatMessageCommitResult(
      messageId: messageId,
      committed: false,
      inserted: false,
      ownerId: token.value,
      ownerGeneration: token.generation,
    );
  }

  void _protectDatabaseFile() {
    for (final suffix in ['', '-wal', '-shm']) {
      final file = File('${_databaseFile.path}$suffix');
      if (file.existsSync()) {
        _storagePolicy.protectAndExcludeFromBackup(file);
      }
    }
    _storagePolicy.syncDirectory(_databaseFile.parent);
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('Single-chat history repository is closed.');
    }
  }
}

void _configureNativeDatabase(dynamic database) {
  database.execute('PRAGMA journal_mode = WAL');
  database.execute('PRAGMA busy_timeout = 5000');
  database.execute('PRAGMA foreign_keys = ON');
}
