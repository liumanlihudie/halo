import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartantic_ai/dartantic_ai.dart' as dartantic;
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/dartantic_single_chat_port.dart';
import 'package:halo_mobile/app/production_group_chat_port.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/sqlite_provider_configuration_store.dart';
import 'package:halo_mobile/orchestration/basic_durable_runner.dart';
import 'package:halo_mobile/orchestration/sqlite_model_call_journal.dart';

void main() {
  late HttpServer server;
  final deepSeek = ProviderConfig.deepSeek();
  final chatModel = ModelRef(providerId: 'deepseek', modelId: 'deepseek-chat');
  final flashModel = ModelRef(
    providerId: 'deepseek',
    modelId: 'deepseek-v4-flash',
  );

  late Directory directory;
  late SqliteProviderConfigurationStore store;
  late SqliteModelCallJournal journal;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('halo-group-port-');
    store = SqliteProviderConfigurationStore.open(
      '${directory.path}/providers.sqlite',
    );
    journal = SqliteModelCallJournal.open('${directory.path}/journal.sqlite');
    final mutation = await store.replaceProviderConfiguration(
      expectedRevision: null,
      replacement: ProviderConfigurationReplacement(
        config: deepSeek,
        modelCatalog: PersistedProviderModelCatalog(
          providerId: 'deepseek',
          models: [
            ModelDescriptor(
              ref: chatModel,
              displayName: 'DeepSeek Chat',
              capabilities: const ModelCapabilities.text(),
            ),
            ModelDescriptor(
              ref: flashModel,
              displayName: 'DeepSeek Flash',
              capabilities: const ModelCapabilities.text(),
            ),
          ],
          discoveredAt: DateTime.utc(2026, 7, 30),
        ),
      ),
    );
    await store.markProviderMutationRuntimePublished(mutation);
    await store.finalizeProviderMutation(mutation);
  });

  tearDown(() async {
    await server.close(force: true);
    journal.close();
    await store.close();
    await directory.delete(recursive: true);
  });

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(() async {
      await for (final request in server) {
        await utf8.decodeStream(request);
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
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
                  'delta': {'content': '最大的风险是消息可靠性与模型编排边界。'},
                },
              ],
            })}\n\n',
          ),
        );
        request.response.add(utf8.encode('data: [DONE]\n\n'));
        await request.response.close();
      }
    }());
  });

  LiveRoutingAgentRuntime runtime(_CapturingAgents chat) =>
      LiveRoutingAgentRuntime(
        agents: chat,
        experts: ExecutableExpertRegistry(
          gateway: const ExpertOutputValidationGateway(),
        ),
        journal: journal,
        store: store,
      );

  AgentTurnRequest turnFor(String agentId) => AgentTurnRequest(
    runId: 'run-1',
    conversationId: 'group-product',
    agentId: agentId,
    input: '这个产品最大的风险是什么？',
    previousResponses: const [],
    idempotencyKey: 'run-1:$agentId:0',
  );

  test(
    'a group turn uses the per-expert override when no global default is set',
    () async {
      // Exactly the state that broke a live group chat: only an override,
      // no global default. Single chat resolves this via `override ?? global`,
      // so the group turn must too, instead of failing 尚未配置默认模型.
      await store.setAgentModelOverride('product-manager', flashModel);

      final chat = _CapturingAgents(server.port);
      await runtime(chat).respond(turnFor('product-manager'));

      expect(chat.lastModel, flashModel);
    },
  );

  test('the global default answers an expert without an override', () async {
    await store.setGlobalDefaultModel(chatModel);

    final chat = _CapturingAgents(server.port);
    await runtime(chat).respond(turnFor('product-manager'));

    expect(chat.lastModel, chatModel);
  });

  test('an expert with neither an override nor a global default fails as a '
      'configuration gap, not a transient error', () async {
    final chat = _CapturingAgents(server.port);

    await expectLater(
      runtime(chat).respond(turnFor('product-manager')),
      throwsA(
        isA<ModelRuntimeException>().having(
          (error) => error.code,
          'code',
          ModelRuntimeErrorCode.invalidConfiguration,
        ),
      ),
    );
    expect(chat.lastModel, isNull);
  });
}

/// Records which model binding a turn resolved to, then answers plainly.
final class _CapturingAgents implements ModelAgentFactory {
  _CapturingAgents(this.port);

  final int port;
  ModelRef? lastModel;

  @override
  Future<dartantic.Agent> agentForModel(
    ModelRef model, {
    List<dartantic.Tool> tools = const [],
  }) async {
    lastModel = model;
    return dartantic.Agent.forProvider(
      dartantic.OpenAIProvider(
        name: 'halo-test',
        apiKey: 'test-key-never-real',
        baseUrl: Uri.parse('http://127.0.0.1:$port/v1'),
      ),
      chatModelName: model.modelId,
    );
  }
}
