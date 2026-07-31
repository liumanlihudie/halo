import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/web_search_tool.dart';
import 'package:halo_mobile/features/circle/circle_news_runner.dart';
import 'package:halo_mobile/features/circle/circle_news_store.dart';
import 'package:halo_mobile/features/circle/circle_post_store.dart';

void main() {
  late Directory root;
  late SqliteCircleNewsStore news;
  late SqliteCirclePostStore circle;

  setUp(() {
    root = Directory.systemTemp.createTempSync('halo-news');
    news = SqliteCircleNewsStore.open('${root.path}/halo_circle.sqlite');
    circle = SqliteCirclePostStore.open('${root.path}/halo_circle.sqlite');
  });

  tearDown(() async {
    await news.close();
    await circle.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  final now = DateTime.utc(2026, 7, 31, 9);

  Future<void> seedJob({
    bool enabled = true,
    DateTime? lastRun,
    String expertId = 'product-manager',
  }) => news.saveJob(
    NewsJob(
      expertId: expertId,
      topic: '产品设计 行业动态',
      cadence: NewsCadence.daily,
      enabled: enabled,
      lastRunAt: lastRun,
    ),
  );

  CircleNewsRunner build({
    _StubSearch? search,
    _StubCurator? curator,
    DateTime? at,
  }) => CircleNewsRunner(
    news: news,
    circle: circle,
    search: search ?? _StubSearch(),
    curator: (curator ?? _StubCurator()).call,
    now: () => at ?? now,
  );

  test(
    'a job that never ran is not due, so a fresh install pays nothing',
    () async {
      await seedJob();
      final search = _StubSearch();

      final outcomes = await build(search: search).runDueJobs();

      expect(outcomes, isEmpty);
      expect(search.queries, isEmpty);
      expect(await circle.countPosts(), 0);
    },
  );

  test('a disabled job never runs', () async {
    await seedJob(enabled: false, lastRun: DateTime.utc(2026, 7, 1));
    final search = _StubSearch();

    await build(search: search).runDueJobs();

    expect(search.queries, isEmpty);
  });

  test('a due job searches, curates and publishes with real links', () async {
    await seedJob(lastRun: DateTime.utc(2026, 7, 29));

    final outcomes = await build().runDueJobs();

    expect(outcomes.single.published, isTrue);
    final post = (await circle.loadFeed()).single;
    expect(post.sourceType, CirclePostSource.schedule);
    // The URL came from the search result, not from the model.
    expect(post.body, contains('https://example.org/a'));
    expect(post.assets, contains('https://example.org/a'));
  });

  test('three missed days produce one run, not three', () async {
    await seedJob(lastRun: DateTime.utc(2026, 7, 28));
    final search = _StubSearch();

    await build(search: search).runDueJobs();
    // Same day, second launch: the period is already claimed.
    await build(search: search).runDueJobs();

    expect(search.queries, hasLength(1));
    expect(await circle.countPosts(), 1);
  });

  test(
    'a long absence is labelled as a catch-up rather than as on time',
    () async {
      await seedJob(lastRun: DateTime.utc(2026, 7, 20));

      await build().runDueJobs();

      expect((await circle.loadFeed()).single.sourceLabel, contains('补跑'));
    },
  );

  test('nothing new means no model call and no post', () async {
    await seedJob(lastRun: DateTime.utc(2026, 7, 29));
    await news.markSeen('product-manager', ['https://example.org/a']);
    final curator = _StubCurator();

    final outcomes = await build(curator: curator).runDueJobs();

    // The cheapest gate: a digest of yesterday's links is worth neither the
    // tokens nor the user's attention.
    expect(curator.calls, isEmpty);
    expect(outcomes.single.published, isFalse);
    expect(outcomes.single.skippedReason, '没有新内容');
    expect(await circle.countPosts(), 0);
  });

  test('an invented index is discarded rather than published', () async {
    await seedJob(lastRun: DateTime.utc(2026, 7, 29));
    final curator = _StubCurator(
      response: '{"picks":[{"index":99,"comment":"不存在的条目"}]}',
    );

    final outcomes = await build(curator: curator).runDueJobs();

    expect(outcomes.single.published, isFalse);
    expect(await circle.countPosts(), 0);
  });

  test('a link written into a comment is stripped out', () async {
    await seedJob(lastRun: DateTime.utc(2026, 7, 29));
    final curator = _StubCurator(
      response:
          '{"picks":[{"index":0,"comment":"详见 https://evil.example/phish 这里"}]}',
    );

    await build(curator: curator).runDueJobs();

    final body = (await circle.loadFeed()).single.body;
    // Only the search result's own URL survives; one the model typed would be
    // indistinguishable from a real citation.
    expect(body, contains('https://example.org/a'));
    expect(body, isNot(contains('evil.example')));
  });

  test('a banned expert publishes nothing even when its job is due', () async {
    await seedJob(lastRun: DateTime.utc(2026, 7, 29));
    await circle.setCanPublish(
      CirclePostAuthor.expert,
      'product-manager',
      allowed: false,
    );

    final outcomes = await build().runDueJobs();

    expect(outcomes.single.published, isFalse);
    expect(await circle.countPosts(), 0);
  });

  test(
    'an unavailable search reports why and does not call the model',
    () async {
      await seedJob(lastRun: DateTime.utc(2026, 7, 29));
      final curator = _StubCurator();

      final outcomes = await build(
        search: _StubSearch(failure: '未配置联网搜索 Key'),
        curator: curator,
      ).runDueJobs();

      expect(outcomes.single.skippedReason, contains('未配置'));
      expect(curator.calls, isEmpty);
    },
  );

  test('malformed model output publishes nothing', () async {
    await seedJob(lastRun: DateTime.utc(2026, 7, 29));

    final outcomes = await build(
      curator: _StubCurator(response: '我觉得第一条不错'),
    ).runDueJobs();

    expect(outcomes.single.published, isFalse);
    expect(await circle.countPosts(), 0);
  });
}

class _StubSearch implements WebSearchBackend {
  _StubSearch({this.failure});

  final String? failure;
  final queries = <String>[];

  @override
  Future<List<WebSearchResult>> search(String query, {int limit = 5}) async {
    final message = failure;
    if (message != null) throw WebSearchUnavailable(message);
    queries.add(query);
    return const [
      WebSearchResult(
        title: '一篇行业文章',
        url: 'https://example.org/a',
        snippet: '摘要',
      ),
    ];
  }
}

class _StubCurator {
  _StubCurator({this.response = '{"picks":[{"index":0,"comment":"值得一看"}]}'});

  final String response;
  final calls = <String>[];

  Future<String> call({
    required String expertId,
    required String prompt,
  }) async {
    calls.add(prompt);
    return response;
  }
}
