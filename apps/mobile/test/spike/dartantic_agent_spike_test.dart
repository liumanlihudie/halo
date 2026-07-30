@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartantic_ai/dartantic_ai.dart';
import 'package:dartantic_interface/dartantic_interface.dart';
import 'package:flutter_test/flutter_test.dart';

/// Spike: can dartantic_ai replace the hand-written single-chat orchestration?
///
/// Requirements it has to meet, each pinned below:
/// 1. Point at an arbitrary OpenAI-compatible base URL (ToAPIs / DeepSeek).
/// 2. Send a system prompt plus real conversation history.
/// 3. Stream plain text back — no JSON envelope, no projection, nothing that
///    can discard a reply the user already read.
void main() {
  late HttpServer server;
  late List<Map<String, Object?>> received;

  setUp(() async {
    received = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(() async {
      await for (final request in server) {
        final body =
            jsonDecode(await utf8.decodeStream(request))
                as Map<String, Object?>;
        received.add(body);
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        for (final piece in ['## 结论\n\n', '- 第一点\n', '- 第二点']) {
          request.response.add(
            utf8.encode(
              'data: ${jsonEncode({
                'id': 'chatcmpl-1',
                'object': 'chat.completion.chunk',
                'created': 0,
                'model': 'deepseek-chat',
                'choices': [
                  {
                    'index': 0,
                    'delta': {'content': piece},
                  },
                ],
              })}\n\n',
            ),
          );
        }
        request.response.add(utf8.encode('data: [DONE]\n\n'));
        await request.response.close();
      }
    }());
  });

  tearDown(() => server.close(force: true));

  test(
    'streams plain markdown from a custom OpenAI-compatible endpoint',
    () async {
      final agent = Agent.forProvider(
        OpenAIProvider(
          name: 'halo-test',
          apiKey: 'test-key-never-real',
          baseUrl: Uri.parse('http://127.0.0.1:${server.port}/v1'),
        ),
        chatModelName: 'deepseek-chat',
      );

      final buffer = StringBuffer();
      await for (final chunk in agent.sendStream(
        '继续分析',
        history: [
          ChatMessage.system('你是产品经理。'),
          ChatMessage.user('分析下亚马逊女鞋行业'),
          ChatMessage.model('该行业竞争激烈。'),
        ],
      )) {
        buffer.write(chunk.output);
      }

      // Plain markdown text, accumulated by simple concatenation.
      expect(buffer.toString(), '## 结论\n\n- 第一点\n- 第二点');

      // The conversation actually reached the model, in order.
      final sent = received.single;
      final messages = (sent['messages']! as List).cast<Map<String, Object?>>();
      expect(messages.map((message) => message['role']).toList(), [
        'system',
        'user',
        'assistant',
        'user',
      ]);
      expect(messages[1]['content'], '分析下亚马逊女鞋行业');
      expect(messages[2]['content'], '该行业竞争激烈。');
      expect(messages.last['content'], '继续分析');
      expect(sent['model'], 'deepseek-chat');
    },
  );
}
