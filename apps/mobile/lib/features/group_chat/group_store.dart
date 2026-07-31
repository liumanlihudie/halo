// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';
import 'package:halo_mobile/features/group_chat/group_members_repository.dart';
import 'package:sqlite3/sqlite3.dart';

@immutable
class StoredGroup {
  const StoredGroup({
    required this.groupId,
    required this.name,
    required this.memberExpertIds,
    required this.createdAt,
  });

  final String groupId;
  final String name;

  /// Canonical expert ids, in the order the user picked them.
  final List<String> memberExpertIds;
  final DateTime createdAt;
}

/// Groups the user created, and the shipped ones they did not.
abstract interface class GroupStore {
  Future<List<StoredGroup>> loadGroups();
  Future<StoredGroup?> loadGroup(String groupId);
  Future<StoredGroup> createGroup({
    required String name,
    required List<String> memberExpertIds,
  });
  Future<void> deleteGroup(String groupId);
  Future<void> close();
}

/// SQLite-backed groups.
///
/// Shares the circle's database file rather than opening a third: both are
/// small, both belong to "things the user assembled", and one fewer file is
/// one fewer thing to migrate.
final class SqliteGroupStore implements GroupStore {
  SqliteGroupStore._(this._database);

  factory SqliteGroupStore.open(String path) {
    final database = sqlite3.open(path);
    try {
      return SqliteGroupStore._(database).._initialize();
    } on Object {
      database.close();
      rethrow;
    }
  }

  final Database _database;
  var _closed = false;
  var _nextSuffix = 0;

  void _initialize() {
    _database
      ..execute('PRAGMA journal_mode = WAL')
      ..execute('PRAGMA busy_timeout = 5000')
      ..execute('''
        CREATE TABLE IF NOT EXISTS user_groups (
          group_id TEXT PRIMARY KEY,
          name TEXT NOT NULL CHECK (length(name) > 0),
          created_at_ms INTEGER NOT NULL CHECK (created_at_ms > 0)
        ) STRICT
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS user_group_members (
          group_id TEXT NOT NULL
            REFERENCES user_groups(group_id) ON DELETE CASCADE,
          expert_id TEXT NOT NULL CHECK (length(expert_id) > 0),
          position INTEGER NOT NULL CHECK (position >= 0),
          PRIMARY KEY (group_id, expert_id)
        ) STRICT
      ''')
      ..execute('PRAGMA foreign_keys = ON');
  }

  @override
  Future<List<StoredGroup>> loadGroups() => Future.sync(() {
    _requireOpen();
    final rows = _database.select(
      'SELECT group_id, name, created_at_ms FROM user_groups '
      'ORDER BY created_at_ms DESC',
    );
    return List<StoredGroup>.unmodifiable([
      for (final row in rows) _hydrate(row),
    ]);
  });

  @override
  Future<StoredGroup?> loadGroup(String groupId) => Future.sync(() {
    _requireOpen();
    final rows = _database.select(
      'SELECT group_id, name, created_at_ms FROM user_groups '
      'WHERE group_id = ?',
      [groupId],
    );
    return rows.isEmpty ? null : _hydrate(rows.single);
  });

  @override
  Future<StoredGroup> createGroup({
    required String name,
    required List<String> memberExpertIds,
  }) => Future.sync(() {
    _requireOpen();
    final trimmed = name.trim();
    // Deduplicated in order: the picker can be tapped twice, and a member
    // listed twice would double that expert's turn in every discussion.
    final members = <String>[];
    for (final id in memberExpertIds) {
      if (id.trim().isNotEmpty && !members.contains(id)) members.add(id.trim());
    }
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', '群名称不能为空');
    }
    if (members.length < 2) {
      // A group of one is a single chat that pretends otherwise.
      throw ArgumentError.value(memberExpertIds, 'memberExpertIds', '至少两位成员');
    }
    final groupId = _newGroupId();
    final createdAtMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    _database.execute('BEGIN IMMEDIATE');
    try {
      _database.execute(
        'INSERT INTO user_groups (group_id, name, created_at_ms) '
        'VALUES (?, ?, ?)',
        [groupId, trimmed, createdAtMs],
      );
      for (final (index, expertId) in members.indexed) {
        _database.execute(
          'INSERT INTO user_group_members (group_id, expert_id, position) '
          'VALUES (?, ?, ?)',
          [groupId, expertId, index],
        );
      }
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
    return StoredGroup(
      groupId: groupId,
      name: trimmed,
      memberExpertIds: List.unmodifiable(members),
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAtMs, isUtc: true),
    );
  });

  @override
  Future<void> deleteGroup(String groupId) => Future.sync(() {
    _requireOpen();
    _database.execute('DELETE FROM user_groups WHERE group_id = ?', [groupId]);
  });

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _database.close();
  }

  StoredGroup _hydrate(Row row) {
    final groupId = row['group_id']! as String;
    final memberRows = _database.select(
      'SELECT expert_id FROM user_group_members WHERE group_id = ? '
      'ORDER BY position',
      [groupId],
    );
    return StoredGroup(
      groupId: groupId,
      name: row['name']! as String,
      memberExpertIds: List<String>.unmodifiable([
        for (final member in memberRows) member['expert_id']! as String,
      ]),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row['created_at_ms']! as int,
        isUtc: true,
      ),
    );
  }

  /// Time-ordered and unique, so two groups created in the same millisecond
  /// still get their own id.
  String _newGroupId() {
    final stamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    return 'group-$stamp-${_nextSuffix++}';
  }

  void _requireOpen() {
    if (_closed) throw StateError('Group storage is closed');
  }
}

/// Serves stored groups first, then the shipped prototype ones.
///
/// Ordered this way so a group the user made cannot be shadowed by a seeded id,
/// while the shipped groups keep working untouched.
final class CompositeGroupMembersRepository implements GroupMembersRepository {
  const CompositeGroupMembersRepository({
    required GroupStore store,
    required Map<String, String> expertDisplayNames,
    GroupMembersRepository fallback = const PrototypeGroupMembersRepository(),
  }) : _store = store,
       _displayNames = expertDisplayNames,
       _fallback = fallback;

  final GroupStore _store;
  final Map<String, String> _displayNames;
  final GroupMembersRepository _fallback;

  @override
  Future<List<GroupChatMember>> loadMembers(String conversationId) async {
    final stored = await _store.loadGroup(conversationId);
    if (stored == null) return _fallback.loadMembers(conversationId);
    return List<GroupChatMember>.unmodifiable([
      for (final expertId in stored.memberExpertIds)
        GroupChatMember(
          expertId: expertId,
          displayName: _displayNames[expertId] ?? expertId,
          role: '群成员',
          // The avatar letter comes from the name, so a renamed expert does
          // not keep an initial that no longer matches.
          avatarLetter: _initialOf(_displayNames[expertId] ?? expertId),
        ),
    ]);
  }

  /// First character of a name, without pulling in a package for it.
  static String _initialOf(String value) =>
      value.isEmpty ? '群' : String.fromCharCode(value.runes.first);
}
