import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';

/// Where a post came from.
enum CirclePostSource { conversation, task, schedule, monitor, spontaneous }

/// What a post carries.
enum CirclePostContent { text, image, gallery, file, video, data, status }

/// Who published a post.
///
/// A group summary belongs to no single member — it is produced by the
/// summariser identity, which has its own model binding — so filing it under a
/// member would be a forged byline.
enum CirclePostAuthor { expert, group }

@immutable
class CirclePost {
  const CirclePost({
    required this.id,
    required this.authorType,
    required this.authorId,
    required this.sourceType,
    required this.sourceLabel,
    required this.body,
    required this.contentType,
    required this.createdAt,
    this.memberAgentIds = const [],
    this.sourceId,
    this.title,
    this.assets = const [],
  });

  final String id;
  final CirclePostAuthor authorType;

  /// The canonical expert id, or the group id. Never a profile id: the publish
  /// permission is keyed on the same value the chat pipeline uses, and mixing
  /// the two makes a ban silently fail to apply.
  final String authorId;

  /// Participants, for the avatar row on a group post. Empty for expert posts.
  final List<String> memberAgentIds;
  final CirclePostSource sourceType;
  final String? sourceId;
  final String sourceLabel;
  final String? title;
  final String body;
  final CirclePostContent contentType;
  final List<String> assets;
  final DateTime createdAt;
}

/// Result of asking to publish.
enum CirclePublishResult {
  published,

  /// The author is not allowed to publish. Returned rather than thrown so the
  /// caller can carry on with the rest of its turn.
  blocked,

  /// The same origin already produced a post. A retried run must not double up.
  duplicate,
}

abstract interface class CirclePostStore {
  Future<List<CirclePost>> loadFeed({int limit});
  Future<CirclePublishResult> publish(
    CirclePost post, {
    required String originKey,
  });
  Future<void> delete(String postId);
  Future<bool> canPublish(CirclePostAuthor authorType, String authorId);
  Future<void> setCanPublish(
    CirclePostAuthor authorType,
    String authorId, {
    required bool allowed,
  });
  Future<int> countPosts();
  Future<List<Map<String, Object?>>> exportPosts();
  Future<void> erasePosts();
  Future<void> close();
}

/// SQLite-backed feed.
///
/// Its own database file on purpose: the single-chat history is schema v1 with
/// no upgrade path, so adding a table there would brick every installed app.
final class SqliteCirclePostStore implements CirclePostStore {
  SqliteCirclePostStore._(this._database);

  factory SqliteCirclePostStore.open(String path) {
    final database = sqlite3.open(path);
    try {
      return SqliteCirclePostStore._(database).._initialize();
    } on Object {
      database.close();
      rethrow;
    }
  }

  static const schemaVersion = 1;

  final Database _database;
  var _closed = false;

  void _initialize() {
    _database
      ..execute('PRAGMA journal_mode = WAL')
      ..execute('PRAGMA busy_timeout = 5000')
      ..execute('''
        CREATE TABLE IF NOT EXISTS circle_posts (
          id TEXT PRIMARY KEY,
          author_type TEXT NOT NULL CHECK (author_type IN ('expert', 'group')),
          author_id TEXT NOT NULL CHECK (length(author_id) > 0),
          member_agent_ids TEXT NOT NULL,
          source_type TEXT NOT NULL CHECK (
            source_type IN
              ('conversation', 'task', 'schedule', 'monitor', 'spontaneous')
          ),
          source_id TEXT,
          source_label TEXT NOT NULL,
          title TEXT,
          body TEXT NOT NULL,
          content_type TEXT NOT NULL CHECK (
            content_type IN
              ('text', 'image', 'gallery', 'file', 'video', 'data', 'status')
          ),
          assets TEXT NOT NULL,
          created_at_ms INTEGER NOT NULL CHECK (created_at_ms > 0),
          state TEXT NOT NULL CHECK (state IN ('published', 'deleted')),
          origin_key TEXT NOT NULL UNIQUE
        ) STRICT
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS circle_publish_permissions (
          author_type TEXT NOT NULL CHECK (author_type IN ('expert', 'group')),
          author_id TEXT NOT NULL CHECK (length(author_id) > 0),
          allowed INTEGER NOT NULL CHECK (allowed IN (0, 1)),
          PRIMARY KEY (author_type, author_id)
        ) STRICT
      ''')
      ..execute('PRAGMA user_version = $schemaVersion');
  }

  @override
  Future<List<CirclePost>> loadFeed({int limit = 200}) => Future.sync(() {
    _requireOpen();
    final rows = _database.select(
      "SELECT * FROM circle_posts WHERE state = 'published' "
      'ORDER BY created_at_ms DESC, id DESC LIMIT ?',
      [limit],
    );
    return List<CirclePost>.unmodifiable(rows.map(_decode));
  });

  @override
  Future<CirclePublishResult> publish(
    CirclePost post, {
    required String originKey,
  }) => Future.sync(() {
    _requireOpen();
    // Checked here rather than in the UI: hiding a button is not a rule, and
    // the spec says the client must check before creating a post.
    if (!_canPublishSync(post.authorType, post.authorId)) {
      return CirclePublishResult.blocked;
    }
    try {
      _database.execute(
        'INSERT INTO circle_posts ('
        '  id, author_type, author_id, member_agent_ids, source_type,'
        '  source_id, source_label, title, body, content_type, assets,'
        '  created_at_ms, state, origin_key'
        ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'published', ?)",
        [
          post.id,
          post.authorType.name,
          post.authorId,
          jsonEncode(post.memberAgentIds),
          post.sourceType.name,
          post.sourceId,
          post.sourceLabel,
          post.title,
          post.body,
          post.contentType.name,
          jsonEncode(post.assets),
          post.createdAt.toUtc().millisecondsSinceEpoch,
          originKey,
        ],
      );
      return CirclePublishResult.published;
    } on SqliteException catch (error) {
      // The unique origin key is the backstop: a retried run reaches here and
      // is turned away rather than posting the same thing twice.
      if (error.resultCode == 19) return CirclePublishResult.duplicate;
      rethrow;
    }
  });

  @override
  Future<void> delete(String postId) => Future.sync(() {
    _requireOpen();
    // Soft delete: banning an expert must leave its history alone, and the two
    // actions have to stay independent.
    _database.execute(
      "UPDATE circle_posts SET state = 'deleted' WHERE id = ?",
      [postId],
    );
  });

  @override
  Future<bool> canPublish(CirclePostAuthor authorType, String authorId) =>
      Future.sync(() {
        _requireOpen();
        return _canPublishSync(authorType, authorId);
      });

  bool _canPublishSync(CirclePostAuthor authorType, String authorId) {
    final rows = _database.select(
      'SELECT allowed FROM circle_publish_permissions '
      'WHERE author_type = ? AND author_id = ?',
      [authorType.name, authorId],
    );
    // Missing means allowed: the product default is that experts may publish.
    return rows.isEmpty || rows.single['allowed'] == 1;
  }

  @override
  Future<void> setCanPublish(
    CirclePostAuthor authorType,
    String authorId, {
    required bool allowed,
  }) => Future.sync(() {
    _requireOpen();
    _database.execute(
      'INSERT INTO circle_publish_permissions (author_type, author_id, allowed)'
      ' VALUES (?, ?, ?) ON CONFLICT(author_type, author_id) '
      'DO UPDATE SET allowed = excluded.allowed',
      [authorType.name, authorId, allowed ? 1 : 0],
    );
  });

  @override
  Future<int> countPosts() => Future.sync(() {
    _requireOpen();
    return _database
            .select(
              "SELECT COUNT(*) AS c FROM circle_posts WHERE state = 'published'",
            )
            .single['c']!
        as int;
  });

  @override
  Future<List<Map<String, Object?>>> exportPosts() => Future.sync(() {
    _requireOpen();
    final rows = _database.select(
      "SELECT * FROM circle_posts WHERE state = 'published' "
      'ORDER BY created_at_ms',
    );
    return List<Map<String, Object?>>.unmodifiable([
      for (final row in rows)
        {
          'id': row['id'],
          'authorType': row['author_type'],
          'authorId': row['author_id'],
          'sourceType': row['source_type'],
          'sourceLabel': row['source_label'],
          'title': row['title'],
          'body': row['body'],
          'contentType': row['content_type'],
          'createdAt': DateTime.fromMillisecondsSinceEpoch(
            row['created_at_ms']! as int,
            isUtc: true,
          ).toIso8601String(),
        },
    ]);
  });

  @override
  Future<void> erasePosts() => Future.sync(() {
    _requireOpen();
    // Hard delete here, unlike a user deleting one post: this is the settings
    // page promising the content is gone.
    _database.execute('DELETE FROM circle_posts');
  });

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _database.close();
  }

  void _requireOpen() {
    if (_closed) throw StateError('Circle storage is closed');
  }

  static CirclePost _decode(Row row) => CirclePost(
    id: row['id']! as String,
    authorType: CirclePostAuthor.values.byName(row['author_type']! as String),
    authorId: row['author_id']! as String,
    memberAgentIds: List<String>.unmodifiable(
      (jsonDecode(row['member_agent_ids']! as String) as List).cast<String>(),
    ),
    sourceType: CirclePostSource.values.byName(row['source_type']! as String),
    sourceId: row['source_id'] as String?,
    sourceLabel: row['source_label']! as String,
    title: row['title'] as String?,
    body: row['body']! as String,
    contentType: CirclePostContent.values.byName(
      row['content_type']! as String,
    ),
    assets: List<String>.unmodifiable(
      (jsonDecode(row['assets']! as String) as List).cast<String>(),
    ),
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      row['created_at_ms']! as int,
      isUtc: true,
    ),
  );
}

/// Ensures the parent directory exists before opening.
File prepareCircleDatabaseFile(String path) {
  final file = File(path).absolute;
  file.parent.createSync(recursive: true);
  return file;
}
