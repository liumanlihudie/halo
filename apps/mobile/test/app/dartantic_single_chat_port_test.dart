@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartantic_ai/dartantic_ai.dart' as dartantic;
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/dartantic_single_chat_port.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/features/single_chat/single_chat_controller.dart';

/// Single chat on dartantic: what the user reads is what the model sent.
void main() {
  late HttpServer server;
  late List<Map<String, Object?>> received;
  late List<String> pieces;
  late int status;
  late DartanticSingleChatPort port;

  setUp(() async {
    received = [];
    pieces = ['## 结论\n\n', '- 第一点\n', '- 第二点'];
    status = 200;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(() async {
      await for (final request in server) {
        received.add(
          jsonDecode(await utf8.decodeStream(request)) as Map<String, Object?>,
        );
        if (status != 200) {
          request.response.statusCode = status;
          request.response.add(utf8.encode('{"error":{"message":"nope"}}'));
          await request.response.close();
          continue;
        }
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        for (final piece in pieces) {
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
    port = DartanticSingleChatPort(
      agents: _FakeAgents(server.port),
      experts: ExecutableExpertRegistry(
        gateway: const ExpertOutputValidationGateway(),
      ),
    );
  });

  tearDown(() async {
    await port.close();
    await server.close(force: true);
  });

  Future<SingleAgentRunHandle> start({
    String text = '继续分析',
    List<SingleChatHistoryTurn> history = const [],
    String commandId = 'command-1',
  }) => port.startSingleAgentRun(
    StartSingleAgentRunRequest(
      conversationId: 'conversation-1',
      expertId: 'product-manager',
      text: text,
      clientCommandId: commandId,
      history: history,
    ),
  );

  test('markdown streams through and lands verbatim', () async {
    final handle = await start();
    final partials = <String>[];
    final subscription = handle.partialAnswers!.listen(partials.add);

    final outcome = await handle.outcome;
    await subscription.cancel();

    expect(outcome.isCompleted, isTrue);
    expect(outcome.answer, '## 结论\n\n- 第一点\n- 第二点');
    // Snapshots grow; the last one is the whole answer.
    expect(partials.last, outcome.answer);
    for (var i = 1; i < partials.length; i += 1) {
      expect(partials[i], startsWith(partials[i - 1]));
    }
  });

  test('the conversation so far reaches the model in order', () async {
    final handle = await start(
      history: const [
        SingleChatHistoryTurn(fromUser: true, text: '分析下亚马逊女鞋行业'),
        SingleChatHistoryTurn(fromUser: false, text: '该行业竞争激烈。'),
      ],
    );
    await handle.outcome;

    final messages = (received.single['messages']! as List)
        .cast<Map<String, Object?>>();
    expect(messages.map((message) => message['role']).toList(), [
      'system',
      'user',
      'assistant',
      'user',
    ]);
    expect(messages.first['content'], contains('产品'));
    expect(messages[1]['content'], '分析下亚马逊女鞋行业');
    expect(messages[2]['content'], '该行业竞争激烈。');
    expect(messages.last['content'], '继续分析');
  });

  test('a long reply is delivered whole', () async {
    pieces = List.filled(400, '这是很长的一段回答。');
    final handle = await start(commandId: 'command-long');

    final outcome = await handle.outcome;

    expect(outcome.answer.length, 400 * '这是很长的一段回答。'.length);
  });

  test('an upstream error keeps nothing invented, and never lies', () async {
    status = 500;
    final handle = await start(commandId: 'command-error');

    final outcome = await handle.outcome;

    expect(outcome.isCompleted, isFalse);
    expect(outcome.failure, SingleAgentRunFailure.retryable);
    expect(outcome.answer, isEmpty);
  });

  test('an unconfigured expert says so instead of looking transient', () async {
    final unconfigured = DartanticSingleChatPort(
      agents: const _UnconfiguredAgents(),
      experts: ExecutableExpertRegistry(
        gateway: const ExpertOutputValidationGateway(),
      ),
    );
    addTearDown(unconfigured.close);

    final handle = await unconfigured.startSingleAgentRun(
      const StartSingleAgentRunRequest(
        conversationId: 'conversation-1',
        expertId: 'product-manager',
        text: '你好',
        clientCommandId: 'command-unconfigured',
      ),
    );

    expect((await handle.outcome).failure, SingleAgentRunFailure.notConfigured);
  });
}

final class _FakeAgents implements SingleChatAgentFactory {
  const _FakeAgents(this.port);

  final int port;

  @override
  Future<dartantic.Agent> agentFor(String expertId) async =>
      dartantic.Agent.forProvider(
        dartantic.OpenAIProvider(
          name: 'halo-test',
          apiKey: 'test-key-never-real',
          baseUrl: Uri.parse('http://127.0.0.1:$port/v1'),
        ),
        chatModelName: 'deepseek-chat',
      );
}

final class _UnconfiguredAgents implements SingleChatAgentFactory {
  const _UnconfiguredAgents();

  @override
  Future<dartantic.Agent> agentFor(String expertId) async =>
      throw StateError('No model is configured for this expert');
}
