import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/web_search_tool.dart';

void main() {
  test('a search hands the model real results to cite', () async {
    final tool = buildWebSearchTool(backend: _StubBackend());

    final result = await tool.call({'query': 'flutter 3.44 release'});

    final map = result as Map<String, Object?>;
    expect(map['ok'], isTrue);
    final results = map['results']! as List;
    expect(results, hasLength(1));
    expect((results.single as Map)['url'], 'https://example.org/a');
  });

  test(
    'an unavailable search tells the model why, and does not throw',
    () async {
      final tool = buildWebSearchTool(
        backend: _StubBackend(failure: '未配置联网搜索 Key，去「设置 - 语音与通话 Key」添加'),
      );

      final result = await tool.call({'query': '任何问题'}) as Map<String, Object?>;

      // Handed back as data so the expert can explain in its own words rather
      // than the whole turn dying on a missing key.
      expect(result['ok'], isFalse);
      expect(result['error'], contains('设置'));
    },
  );

  test('a missing query is refused rather than searched blindly', () async {
    final backend = _StubBackend();
    final tool = buildWebSearchTool(backend: backend);

    final result = await tool.call({}) as Map<String, Object?>;

    expect(result['ok'], isFalse);
    expect(backend.queries, isEmpty);
  });

  test('the tool describes itself so the model knows when to reach for it', () {
    final tool = buildWebSearchTool(backend: _StubBackend());

    expect(tool.name, 'web_search');
    // The instruction that keeps citations honest lives in the description,
    // where the model actually reads it.
    expect(tool.description, contains('不要自己编造链接'));
  });

  test('callers can observe what was actually searched', () async {
    final seen = <List<WebSearchResult>>[];
    final tool = buildWebSearchTool(
      backend: _StubBackend(),
      onResults: seen.add,
    );

    await tool.call({'query': '任何问题'});

    expect(seen.single.single.url, 'https://example.org/a');
  });
}

class _StubBackend implements WebSearchBackend {
  _StubBackend({this.failure});

  final String? failure;
  final queries = <String>[];

  @override
  Future<List<WebSearchResult>> search(String query, {int limit = 5}) async {
    queries.add(query);
    final message = failure;
    if (message != null) throw WebSearchUnavailable(message);
    return const [
      WebSearchResult(
        title: 'Flutter 3.44',
        url: 'https://example.org/a',
        snippet: '发布说明',
      ),
    ];
  }
}
