import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/production_single_chat_port.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/features/single_chat/single_chat_controller.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';

void main() {
  late _FakeRuntime runtime;
  late ProductionSingleChatPort port;

  setUp(() {
    runtime = _FakeRuntime();
    port = ProductionSingleChatPort(
      runtime: runtime,
      experts: ExecutableExpertRegistry(
        gateway: const ExpertOutputValidationGateway(),
      ),
    );
  });

  test(
    'maps an authorized executable expert into a production request',
    () async {
      runtime.response = ChatResponse(
        requestId: 'command-1',
        model: ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini'),
        outputText: jsonEncode(_adviceOutput('生产建议')),
        finishReason: ChatFinishReason.completed,
        usage: const ChatUsage(inputTokens: 10, outputTokens: 2),
      );

      final handle = await port.startSingleAgentRun(
        const StartSingleAgentRunRequest(
          conversationId: 'conversation-1',
          expertId: 'product-manager',
          text: '请分析需求',
          clientCommandId: 'command-1',
        ),
      );
      final outcome = await handle.outcome;

      expect(outcome.answer, '先把需求澄清清楚，再决定优先级。');
      expect(runtime.resolvedAgentIds, ['product-manager']);
      expect(runtime.requests, hasLength(1));
      final request = runtime.requests.single;
      expect(request.requestId, 'command-1');
      expect(request.messages.last.role, ChatRole.user);
      expect(request.messages.last.content, '请分析需求');
      expect(request.messages.first.role, ChatRole.system);
      expect(request.messages.first.content, contains('产品'));
    },
  );

  test('request tells the model the complete advice JSON contract', () async {
    runtime.response = ChatResponse(
      requestId: 'command-contract',
      model: ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini'),
      outputText: jsonEncode(_adviceOutput('生产建议')),
      finishReason: ChatFinishReason.completed,
      usage: const ChatUsage(inputTokens: 10, outputTokens: 2),
    );

    final handle = await port.startSingleAgentRun(
      const StartSingleAgentRunRequest(
        conversationId: 'conversation-contract',
        expertId: 'product-manager',
        text: '请分析需求',
        clientCommandId: 'command-contract',
      ),
    );
    await handle.outcome;

    final systemPrompt = runtime.requests.single.messages.first.content;
    for (final requiredField in const [
      '"Problem"',
      '"TargetUsers"',
      '"Recommendation"',
      '"Priorities"',
      '"Risks"',
      '"Verification"',
    ]) {
      expect(systemPrompt, contains(requiredField));
    }
    expect(systemPrompt, contains('"claimType":"advice"'));
    expect(systemPrompt, contains('"tense":"proposed"'));
    expect(systemPrompt, contains('"verified":false'));
    expect(systemPrompt, contains('"source":"none"'));
    expect(systemPrompt, contains('"proposedActions"'));
    expect(systemPrompt, contains('"executedFacts":[]'));
    expect(
      systemPrompt,
      contains('Verification.proposedActions MUST contain at least one action'),
    );
    expect(
      systemPrompt,
      contains(
        'analyze, compare, document, implement, measure, plan, query, '
        'review, test, train, verify',
      ),
    );
  });

  test('rejects catalog-only expert that is not executable in single chat', () {
    expect(
      () => port.startSingleAgentRun(
        const StartSingleAgentRunRequest(
          conversationId: 'conversation-1',
          expertId: 'user-researcher',
          text: '分析数据',
          clientCommandId: 'command-2',
        ),
      ),
      throwsA(isA<StateError>()),
    );
    expect(runtime.requests, isEmpty);
  });

  test(
    'raw model text never crosses the trusted projection boundary',
    () async {
      runtime.response = ChatResponse(
        requestId: 'command-raw',
        model: ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini'),
        outputText: '我已经执行并验证全部操作',
        finishReason: ChatFinishReason.completed,
        usage: const ChatUsage(inputTokens: 2, outputTokens: 8),
      );

      final handle = await port.startSingleAgentRun(
        const StartSingleAgentRunRequest(
          conversationId: 'conversation-raw',
          expertId: 'product-manager',
          text: '执行操作',
          clientCommandId: 'command-raw',
        ),
      );

      final outcome = await handle.outcome;
      expect(outcome.failure, SingleAgentRunFailure.malformedOutput);
      expect(outcome.failure, isNot(SingleAgentRunFailure.contentFiltered));
    },
  );

  test('markdown-fenced JSON output still decodes and projects', () async {
    runtime.response = ChatResponse(
      requestId: 'command-fenced',
      model: ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini'),
      outputText: '```json\n${jsonEncode(_adviceOutput('生产建议'))}\n```',
      finishReason: ChatFinishReason.completed,
      usage: const ChatUsage(inputTokens: 10, outputTokens: 2),
    );

    final handle = await port.startSingleAgentRun(
      const StartSingleAgentRunRequest(
        conversationId: 'conversation-fenced',
        expertId: 'product-manager',
        text: '请分析需求',
        clientCommandId: 'command-fenced',
      ),
    );

    final outcome = await handle.outcome;
    expect(outcome.isCompleted, isTrue);
    expect(outcome.answer, '先把需求澄清清楚，再决定优先级。');
  });

  test('prose-wrapped JSON output still decodes and projects', () async {
    runtime.response = ChatResponse(
      requestId: 'command-prose',
      model: ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini'),
      outputText: '好的，以下是分析结果：\n${jsonEncode(_adviceOutput('生产建议'))}\n希望对你有帮助。',
      finishReason: ChatFinishReason.completed,
      usage: const ChatUsage(inputTokens: 10, outputTokens: 2),
    );

    final handle = await port.startSingleAgentRun(
      const StartSingleAgentRunRequest(
        conversationId: 'conversation-prose',
        expertId: 'product-manager',
        text: '请分析需求',
        clientCommandId: 'command-prose',
      ),
    );

    final outcome = await handle.outcome;
    expect(outcome.isCompleted, isTrue);
    expect(outcome.answer, '先把需求澄清清楚，再决定优先级。');
  });

  test('execution claim without a trusted receipt is not projected', () async {
    runtime.response = ChatResponse(
      requestId: 'command-execution',
      model: ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini'),
      outputText: jsonEncode(_executionOutput()),
      finishReason: ChatFinishReason.completed,
      usage: const ChatUsage(inputTokens: 2, outputTokens: 8),
    );

    final handle = await port.startSingleAgentRun(
      const StartSingleAgentRunRequest(
        conversationId: 'conversation-execution',
        expertId: 'product-manager',
        text: '执行操作',
        clientCommandId: 'command-execution',
      ),
    );

    expect(
      (await handle.outcome).failure,
      SingleAgentRunFailure.malformedOutput,
    );
  });

  test(
    'model-supplied receipt cannot enable unsupported P0 execution',
    () async {
      final output = _executionOutput();
      final verification = output['Verification']! as Map<String, Object?>;
      verification['receipt'] = {
        'receiptId': 'model-invented-receipt',
        'status': 'verified',
      };
      runtime.response = ChatResponse(
        requestId: 'command-fake-receipt',
        model: ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini'),
        outputText: jsonEncode(output),
        finishReason: ChatFinishReason.completed,
        usage: const ChatUsage(inputTokens: 2, outputTokens: 8),
      );

      final handle = await port.startSingleAgentRun(
        const StartSingleAgentRunRequest(
          conversationId: 'conversation-fake-receipt',
          expertId: 'product-manager',
          text: '执行并提供回执',
          clientCommandId: 'command-fake-receipt',
        ),
      );

      final outcome = await handle.outcome;
      expect(outcome.isCompleted, isFalse);
      expect(outcome.answer, isEmpty);
      expect(outcome.failure, SingleAgentRunFailure.malformedOutput);
    },
  );

  test(
    'advice envelope cannot smuggle an unverified completed execution claim',
    () async {
      runtime.response = ChatResponse(
        requestId: 'command-smuggled-execution',
        model: ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini'),
        outputText: jsonEncode(_adviceOutput('我已执行发布并验证所有生产检查均已完成')),
        finishReason: ChatFinishReason.completed,
        usage: const ChatUsage(inputTokens: 2, outputTokens: 8),
      );

      final handle = await port.startSingleAgentRun(
        const StartSingleAgentRunRequest(
          conversationId: 'conversation-smuggled-execution',
          expertId: 'product-manager',
          text: '请给出建议',
          clientCommandId: 'command-smuggled-execution',
        ),
      );

      final outcome = await handle.outcome;
      expect(outcome.answer, '先把需求澄清清楚，再决定优先级。');
      expect(outcome.answer, isNot(contains('我已执行')));
    },
  );

  test('stop cancels the exact production runtime request', () async {
    runtime.block = Completer<ChatResponse>();
    final handle = await port.startSingleAgentRun(
      const StartSingleAgentRunRequest(
        conversationId: 'conversation-1',
        expertId: 'product-manager',
        text: '等待',
        clientCommandId: 'command-3',
      ),
    );

    await port.stopSingleAgentRun(handle.runId);

    expect(runtime.requests.single.cancellationToken?.isCancelled, isTrue);
    expect((await handle.outcome).failure, SingleAgentRunFailure.retryable);
  });

  test(
    'maps authentication, quota, filtering, and network errors safely',
    () async {
      final cases = <ModelRuntimeErrorCode, SingleAgentRunFailure>{
        ModelRuntimeErrorCode.invalidCredential:
            SingleAgentRunFailure.authentication,
        ModelRuntimeErrorCode.insufficientBalance:
            SingleAgentRunFailure.quotaLimited,
        ModelRuntimeErrorCode.contentRejected:
            SingleAgentRunFailure.contentFiltered,
        ModelRuntimeErrorCode.providerUnavailable:
            SingleAgentRunFailure.retryable,
      };
      var index = 0;
      for (final entry in cases.entries) {
        runtime.error = ModelRuntimeException(
          code: entry.key,
          safeMessage: '固定安全状态',
          retryable: true,
        );
        final handle = await port.startSingleAgentRun(
          StartSingleAgentRunRequest(
            conversationId: 'conversation-$index',
            expertId: 'product-manager',
            text: 'hello',
            clientCommandId: 'command-error-$index',
          ),
        );
        expect((await handle.outcome).failure, entry.value);
        index++;
      }
    },
  );

  test('close cancels and drains active work and is idempotent', () async {
    runtime.block = Completer<ChatResponse>();
    final handle = await port.startSingleAgentRun(
      const StartSingleAgentRunRequest(
        conversationId: 'conversation-1',
        expertId: 'product-manager',
        text: '等待',
        clientCommandId: 'command-4',
      ),
    );

    await Future.wait([port.close(), port.close()]);

    expect((await handle.outcome).failure, SingleAgentRunFailure.retryable);
    expect(
      () => port.startSingleAgentRun(
        const StartSingleAgentRunRequest(
          conversationId: 'conversation-2',
          expertId: 'product-manager',
          text: 'new',
          clientCommandId: 'command-5',
        ),
      ),
      throwsStateError,
    );
  });
}

Map<String, Object?> _adviceOutput(String recommendation) => {
  'Answer': '先把需求澄清清楚，再决定优先级。',
  'Problem': '需求尚未澄清',
  'TargetUsers': '目标用户',
  'Recommendation': recommendation,
  'Priorities': ['先验证需求'],
  'Risks': ['输入可能不完整'],
  'Verification': {
    'claimType': 'advice',
    'tense': 'proposed',
    'verified': false,
    'source': 'none',
    'proposedActions': [
      {
        'verb': 'review',
        'target': 'product-requirements',
        'conditions': ['stakeholder-approval'],
      },
    ],
    'executedFacts': <String>[],
  },
};

Map<String, Object?> _executionOutput() => {
  'Answer': '我已执行完成。',
  'Problem': '执行任务',
  'TargetUsers': '用户',
  'Recommendation': '已完成',
  'Priorities': ['发布'],
  'Risks': ['无'],
  'Verification': {
    'claimType': 'execution',
    'tense': 'completed',
    'verified': true,
    'source': 'self-reported',
    'proposedActions': <Object?>[],
    'executedFacts': ['已经发布'],
  },
};

final class _FakeRuntime implements ProductionSingleChatRuntime {
  final requests = <ChatRequest>[];
  final resolvedAgentIds = <String>[];
  ChatResponse? response;
  ModelRuntimeException? error;
  Completer<ChatResponse>? block;

  @override
  Future<ModelRef> resolveConfiguredModel({required String agentId}) async {
    resolvedAgentIds.add(agentId);
    return ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini');
  }

  @override
  Future<ChatResponse> chat(ChatRequest request) async {
    requests.add(request);
    final currentError = error;
    if (currentError != null) {
      error = null;
      throw currentError;
    }
    final pending = block;
    if (pending != null) {
      await request.cancellationToken!.whenCancelled;
      throw const ModelRuntimeException(
        code: ModelRuntimeErrorCode.transportFailure,
        safeMessage: '请求已停止',
        retryable: true,
      );
    }
    return response!;
  }
}
