import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/production_group_chat_port.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/provider_registry.dart';
import 'package:halo_mobile/model_runtime/sqlite_provider_configuration_store.dart';
import 'package:halo_mobile/orchestration/basic_durable_runner.dart';
import 'package:halo_mobile/orchestration/sqlite_model_call_journal.dart';

void main() {
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
    journal.close();
    await store.close();
    await directory.delete(recursive: true);
  });

  LiveRoutingAgentRuntime runtime(_CapturingChatRuntime chat) =>
      LiveRoutingAgentRuntime(
        modelRuntime: chat,
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

      final chat = _CapturingChatRuntime();
      await runtime(chat).respond(turnFor('product-manager'));

      expect(chat.lastRequest?.model, flashModel);
    },
  );

  test('the global default answers an expert without an override', () async {
    await store.setGlobalDefaultModel(chatModel);

    final chat = _CapturingChatRuntime();
    await runtime(chat).respond(turnFor('product-manager'));

    expect(chat.lastRequest?.model, chatModel);
  });

  test('an expert with neither an override nor a global default fails as a '
      'configuration gap, not a transient error', () async {
    final chat = _CapturingChatRuntime();

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
    expect(chat.lastRequest, isNull);
  });
}

final class _CapturingChatRuntime implements ChatModelRuntime {
  ChatRequest? lastRequest;

  @override
  Future<ChatResponse> chat(ChatRequest request) async {
    lastRequest = request;
    return ChatResponse(
      requestId: request.requestId,
      model: request.model,
      outputText: _validExpertOutput,
      finishReason: ChatFinishReason.completed,
      usage: const ChatUsage(inputTokens: 10, outputTokens: 20),
    );
  }
}

const _validExpertOutput =
    '{"Answer":"最大的风险是消息可靠性与模型编排边界。",'
    '"Problem":"风险识别",'
    '"TargetUsers":"个人用户",'
    '"Recommendation":"先把可靠性做透",'
    '"Priorities":["消息可靠性"],'
    '"Risks":["编排复杂度"],'
    '"Verification":{"claimType":"advice","tense":"proposed",'
    '"verified":false,"source":"none",'
    '"proposedActions":[{"verb":"review","target":"reliability-plan",'
    '"conditions":[]}],"executedFacts":[]}}';
