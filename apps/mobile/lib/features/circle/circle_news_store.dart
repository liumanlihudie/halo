import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';

/// How often a news job should run.
enum NewsCadence {
  daily(Duration(days: 1), '每天'),
  weekly(Duration(days: 7), '每周');

  const NewsCadence(this.period, this.displayName);

  final Duration period;
  final String displayName;
}

@immutable
class NewsJob {
  const NewsJob({
    required this.expertId,
    required this.topic,
    required this.cadence,
    required this.enabled,
    this.lastRunAt,
  });

  final String expertId;

  /// What this expert goes looking for, in its own words.
  final String topic;
  final NewsCadence cadence;
  final bool enabled;
  final DateTime? lastRunAt;

  /// True when [now] has passed the next scheduled run.
  ///
  /// A job that has never run is **not** due: a fresh install must not spend
  /// the user's money before they have seen the feature.
  bool isDue(DateTime now) {
    final last = lastRunAt;
    if (!enabled || last == null) return false;
    return now.isAfter(last.add(cadence.period));
  }

  /// Identifies the period [now] falls in, so a run can be recorded once.
  String periodKey(DateTime now) {
    final utc = now.toUtc();
    return cadence == NewsCadence.weekly
        ? 'w${utc.year}-${(utc.difference(DateTime.utc(utc.year)).inDays ~/ 7)}'
        : 'd${utc.year}-${utc.month}-${utc.day}';
  }
}

abstract interface class CircleNewsStore {
  Future<List<NewsJob>> loadJobs();
  Future<NewsJob?> loadJob(String expertId);
  Future<void> saveJob(NewsJob job);

  /// Records that [expertId] ran for [periodKey]. Returns false when that
  /// period was already claimed, which is how a second launch on the same day
  /// avoids paying twice.
  Future<bool> claimRun(String expertId, String periodKey, DateTime ranAt);

  /// Filters out items this expert has already published.
  Future<List<String>> unseen(String expertId, List<String> itemKeys);
  Future<void> markSeen(String expertId, List<String> itemKeys);
  Future<void> close();
}

final class SqliteCircleNewsStore implements CircleNewsStore {
  SqliteCircleNewsStore._(this._database);

  factory SqliteCircleNewsStore.open(String path) {
    final database = sqlite3.open(path);
    try {
      return SqliteCircleNewsStore._(database).._initialize();
    } on Object {
      database.close();
      rethrow;
    }
  }

  final Database _database;
  var _closed = false;

  void _initialize() {
    _database
      ..execute('PRAGMA journal_mode = WAL')
      ..execute('PRAGMA busy_timeout = 5000')
      ..execute('''
        CREATE TABLE IF NOT EXISTS circle_news_jobs (
          expert_id TEXT PRIMARY KEY,
          topic TEXT NOT NULL,
          cadence TEXT NOT NULL CHECK (cadence IN ('daily', 'weekly')),
          enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
          last_run_at_ms INTEGER
        ) STRICT
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS circle_news_runs (
          expert_id TEXT NOT NULL,
          period_key TEXT NOT NULL,
          ran_at_ms INTEGER NOT NULL,
          PRIMARY KEY (expert_id, period_key)
        ) STRICT
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS circle_news_seen (
          expert_id TEXT NOT NULL,
          item_key TEXT NOT NULL,
          PRIMARY KEY (expert_id, item_key)
        ) STRICT
      ''');
  }

  @override
  Future<List<NewsJob>> loadJobs() => Future.sync(() {
    _requireOpen();
    final rows = _database.select(
      'SELECT * FROM circle_news_jobs ORDER BY expert_id',
    );
    return List<NewsJob>.unmodifiable(rows.map(_decode));
  });

  @override
  Future<NewsJob?> loadJob(String expertId) => Future.sync(() {
    _requireOpen();
    final rows = _database.select(
      'SELECT * FROM circle_news_jobs WHERE expert_id = ?',
      [expertId],
    );
    return rows.isEmpty ? null : _decode(rows.single);
  });

  @override
  Future<void> saveJob(NewsJob job) => Future.sync(() {
    _requireOpen();
    _database.execute(
      'INSERT INTO circle_news_jobs '
      '(expert_id, topic, cadence, enabled, last_run_at_ms) '
      'VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(expert_id) DO UPDATE SET '
      '  topic = excluded.topic, cadence = excluded.cadence, '
      '  enabled = excluded.enabled, last_run_at_ms = excluded.last_run_at_ms',
      [
        job.expertId,
        job.topic,
        job.cadence.name,
        job.enabled ? 1 : 0,
        job.lastRunAt?.toUtc().millisecondsSinceEpoch,
      ],
    );
  });

  @override
  Future<bool> claimRun(String expertId, String periodKey, DateTime ranAt) =>
      Future.sync(() {
        _requireOpen();
        try {
          _database.execute(
            'INSERT INTO circle_news_runs (expert_id, period_key, ran_at_ms) '
            'VALUES (?, ?, ?)',
            [expertId, periodKey, ranAt.toUtc().millisecondsSinceEpoch],
          );
        } on SqliteException catch (error) {
          // Already claimed: opening the app twice in one day must not pay for
          // two runs.
          if (error.resultCode == 19) return false;
          rethrow;
        }
        _database.execute(
          'UPDATE circle_news_jobs SET last_run_at_ms = ? WHERE expert_id = ?',
          [ranAt.toUtc().millisecondsSinceEpoch, expertId],
        );
        return true;
      });

  @override
  Future<List<String>> unseen(String expertId, List<String> itemKeys) =>
      Future.sync(() {
        _requireOpen();
        final fresh = <String>[];
        for (final key in itemKeys) {
          final rows = _database.select(
            'SELECT 1 FROM circle_news_seen '
            'WHERE expert_id = ? AND item_key = ?',
            [expertId, key],
          );
          if (rows.isEmpty) fresh.add(key);
        }
        return List.unmodifiable(fresh);
      });

  @override
  Future<void> markSeen(String expertId, List<String> itemKeys) =>
      Future.sync(() {
        _requireOpen();
        for (final key in itemKeys) {
          _database.execute(
            'INSERT OR IGNORE INTO circle_news_seen (expert_id, item_key) '
            'VALUES (?, ?)',
            [expertId, key],
          );
        }
      });

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _database.close();
  }

  void _requireOpen() {
    if (_closed) throw StateError('News storage is closed');
  }

  static NewsJob _decode(Row row) {
    final lastRun = row['last_run_at_ms'] as int?;
    return NewsJob(
      expertId: row['expert_id']! as String,
      topic: row['topic']! as String,
      cadence: NewsCadence.values.byName(row['cadence']! as String),
      enabled: row['enabled'] == 1,
      lastRunAt: lastRun == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastRun, isUtc: true),
    );
  }
}
