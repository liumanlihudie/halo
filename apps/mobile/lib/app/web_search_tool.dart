// ignore_for_file: prefer_initializing_formals

import 'package:dartantic_interface/dartantic_interface.dart' as llm;
import 'package:halo_mobile/app/generation_transport.dart';
import 'package:halo_mobile/features/settings/service_credentials_controller.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';

/// One result, exactly as the search service returned it.
class WebSearchResult {
  const WebSearchResult({
    required this.title,
    required this.url,
    required this.snippet,
  });

  final String title;
  final String url;
  final String snippet;
}

abstract interface class WebSearchBackend {
  /// Throws [WebSearchUnavailable] when it cannot search.
  Future<List<WebSearchResult>> search(String query, {int limit});
}

final class WebSearchUnavailable implements Exception {
  const WebSearchUnavailable(this.safeMessage);

  final String safeMessage;

  @override
  String toString() => 'WebSearchUnavailable($safeMessage)';
}

/// Tavily, chosen because it answers with clean title/url/content rather than
/// a page of HTML to scrape.
///
/// The key is read per call from the credential store, so adding or removing
/// it in settings takes effect on the next question.
final class TavilyWebSearchBackend implements WebSearchBackend {
  TavilyWebSearchBackend({
    required ServiceCredentialPersistence credentials,
    required SecretResolver secretResolver,
    required GenerationTransport transport,
  }) : _credentials = credentials,
       _secretResolver = secretResolver,
       _transport = transport;

  static final Uri endpoint = Uri.parse('https://api.tavily.com/search');

  /// Snippets are trimmed before they reach the model: a handful of long pages
  /// would crowd out the conversation itself.
  static const maximumSnippetChars = 600;

  final ServiceCredentialPersistence _credentials;
  final SecretResolver _secretResolver;
  final GenerationTransport _transport;

  @override
  Future<List<WebSearchResult>> search(String query, {int limit = 5}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      throw const WebSearchUnavailable('没有可搜索的内容');
    }
    final key = await _apiKey();
    if (key == null) {
      throw const WebSearchUnavailable('未配置联网搜索 Key，去「设置 - 语音与通话 Key」添加');
    }
    final Map<String, Object?> body;
    try {
      body = await _transport.postJson(
        endpoint: endpoint,
        headers: const {},
        body: {
          'api_key': key,
          'query': trimmed,
          'max_results': limit.clamp(1, 10),
          'search_depth': 'basic',
        },
      );
    } on GenerationRateLimited {
      throw const WebSearchUnavailable('搜索服务限流了，稍后再试');
    } on GenerationTransportException catch (error) {
      throw WebSearchUnavailable(error.safeMessage);
    }
    final results = body['results'];
    if (results is! List) {
      throw const WebSearchUnavailable('搜索服务返回了无法解析的内容');
    }
    final parsed = <WebSearchResult>[];
    for (final entry in results) {
      if (entry is! Map<String, Object?>) continue;
      final url = entry['url'];
      final title = entry['title'];
      // A result without a usable https URL is dropped rather than passed on:
      // the whole point is that every citation is real and reachable.
      if (url is! String || !url.startsWith('https://')) continue;
      final content = entry['content'];
      parsed.add(
        WebSearchResult(
          title: title is String && title.isNotEmpty ? title : url,
          url: url,
          snippet: content is String
              ? (content.length > maximumSnippetChars
                    ? '${content.substring(0, maximumSnippetChars)}…'
                    : content)
              : '',
        ),
      );
    }
    if (parsed.isEmpty) {
      throw const WebSearchUnavailable('没有搜到可用的结果');
    }
    return List.unmodifiable(parsed);
  }

  Future<String?> _apiKey() async {
    try {
      for (final record in await _credentials.loadServiceCredentials()) {
        if (record.serviceId != KeyOnlyService.webSearch.id) continue;
        if (!record.enabled) return null;
        final credential = await _secretResolver.resolve(record.secretRef);
        final value = credential?.value;
        return value == null || value.isEmpty ? null : value;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}

/// The search tool handed to an expert.
///
/// Results are returned as structured entries, so the URL an expert cites came
/// from the search service and not from its own prose. Asking a model to
/// remember the web produces confident links that go nowhere.
llm.Tool buildWebSearchTool({
  required WebSearchBackend backend,
  void Function(List<WebSearchResult> results)? onResults,
}) => llm.Tool<Map<String, dynamic>>(
  name: 'web_search',
  description:
      '搜索互联网获取最新信息。当问题涉及近期事件、具体数据、你不确定的事实，'
      '或用户明确要求查证时使用。引用信息时必须使用返回结果中的 url，不要自己编造链接。',
  inputSchema: llm.S.object(
    properties: {'query': llm.S.string(description: '搜索关键词，尽量具体')},
    required: ['query'],
  ),
  onCall: (input) async {
    final query = input['query'];
    if (query is! String) return {'ok': false, 'error': '缺少搜索词'};
    try {
      final results = await backend.search(query);
      onResults?.call(results);
      return {
        'ok': true,
        'results': [
          for (final result in results)
            {
              'title': result.title,
              'url': result.url,
              'snippet': result.snippet,
            },
        ],
      };
    } on WebSearchUnavailable catch (error) {
      // Returned to the model rather than thrown, so it can tell the user why
      // it could not look something up instead of the turn dying.
      return {'ok': false, 'error': error.safeMessage};
    } catch (_) {
      return {'ok': false, 'error': '搜索失败'};
    }
  },
);

/// True when a search key is configured, so callers can decide whether to
/// declare the tool at all.
Future<bool> hasWebSearchKey(ServiceCredentialPersistence credentials) async {
  try {
    for (final record in await credentials.loadServiceCredentials()) {
      if (record.serviceId == KeyOnlyService.webSearch.id) {
        return record.enabled;
      }
    }
    return false;
  } catch (_) {
    return false;
  }
}
