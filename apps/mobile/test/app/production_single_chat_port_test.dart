import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/production_single_chat_port.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/features/single_chat/chat_message_repository.dart';
import 'package:halo_mobile/features/single_chat/single_chat_controller.dart';
import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/chat_stream_models.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/streaming_chat_runtime.dart';

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

  test('request tells the model to answer in plain Markdown', () async {
    runtime.response = ChatResponse(
      requestId: 'command-contract',
      model: ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini'),
      outputText: '先把需求澄清清楚，再决定优先级。',
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
    expect(systemPrompt, contains('直接用自然中文回答用户'));
    expect(systemPrompt, contains('支持 Markdown'));
    expect(systemPrompt, contains('1200'));
    // The JSON envelope is gone: it was a constant the app pins, and every
    // model slip destroyed a finished answer.
    expect(systemPrompt, isNot(contains('"Verification"')));
    expect(
      systemPrompt,
      isNot(contains('Return exactly one valid JSON object')),
    );
  });

  test('a complete answer survives a botched advice envelope', () async {
    // Field failure (2026-07-30): the model answered fully but used an
    // uncontrolled verb and a non-kebab-case target, so the whole reply was
    // dropped as 发送失败. The advice envelope is app-pinned; losing the
    // answer to it is pure damage.
    final sloppy = Map<String, Object?>.from(_adviceOutput('生产建议'))
      ..['Answer'] = '亚马逊女鞋行业竞争激烈，建议先做选品验证。'
      ..['Verification'] = {
        'claimType': 'advice',
        'tense': 'proposed',
        'verified': false,
        'source': 'none',
        'proposedActions': [
          {'verb': 'suggest', 'target': '美国亚马逊市场', 'conditions': <String>[]},
        ],
        'executedFacts': <String>[],
      };
    runtime.response = ChatResponse(
      requestId: 'command-sloppy',
      model: ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini'),
      outputText: jsonEncode(sloppy),
      finishReason: ChatFinishReason.completed,
      usage: const ChatUsage(inputTokens: 10, outputTokens: 2),
    );

    final handle = await port.startSingleAgentRun(
      const StartSingleAgentRunRequest(
        conversationId: 'conversation-sloppy',
        expertId: 'product-manager',
        text: '分析下亚马逊女鞋行业',
        clientCommandId: 'command-sloppy',
      ),
    );
    final outcome = await handle.outcome;

    expect(outcome.answer, '亚马逊女鞋行业竞争激烈，建议先做选品验证。');
    expect(outcome.failure, SingleAgentRunFailure.none);
    // No repair round trip is needed when the answer itself is sound.
    expect(runtime.requests, hasLength(1));
  });

  test('an answer-only reply still projects', () async {
    runtime.response = ChatResponse(
      requestId: 'command-answer-only',
      model: ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini'),
      outputText: jsonEncode({'Answer': '直接回答，没有其他字段。'}),
      finishReason: ChatFinishReason.completed,
      usage: const ChatUsage(inputTokens: 10, outputTokens: 2),
    );

    final handle = await port.startSingleAgentRun(
      const StartSingleAgentRunRequest(
        conversationId: 'conversation-answer-only',
        expertId: 'product-manager',
        text: '你好',
        clientCommandId: 'command-answer-only',
      ),
    );

    expect((await handle.outcome).answer, '直接回答，没有其他字段。');
  });

  test('a self-claimed execution envelope is still refused', () async {
    final forged = Map<String, Object?>.from(_executionOutput())
      ..['Verification'] = {
        ...(_executionOutput()['Verification']! as Map<String, Object?>),
        'source': '',
      };
    runtime.response = ChatResponse(
      requestId: 'command-forged',
      model: ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini'),
      outputText: jsonEncode(forged),
      finishReason: ChatFinishReason.completed,
      usage: const ChatUsage(inputTokens: 10, outputTokens: 2),
    );

    final handle = await port.startSingleAgentRun(
      const StartSingleAgentRunRequest(
        conversationId: 'conversation-forged',
        expertId: 'product-manager',
        text: '发布了吗',
        clientCommandId: 'command-forged',
      ),
    );
    final outcome = await handle.outcome;

    expect(outcome.answer, isEmpty);
    expect(outcome.failure, SingleAgentRunFailure.malformedOutput);
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

  test('prose that claims execution is still only unverified advice', () async {
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
    // The text is shown — it is the reply — but the claim carries no weight:
    // the envelope is pinned by the app, so this stays model output, never
    // verified evidence. Safety is structural, not lexical.
    expect(outcome.answer, '我已经执行并验证全部操作');
    expect(outcome.sourceType, ChatMessageSourceType.modelOutput);
    expect(outcome.evidenceReferences, isEmpty);
    expect(outcome.verifierToken, isNull);
  });

  test('an empty reply is repaired once, then reported', () async {
    runtime.response = ChatResponse(
      requestId: 'command-repair',
      model: ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini'),
      outputText: '   ',
      finishReason: ChatFinishReason.completed,
      usage: const ChatUsage(inputTokens: 2, outputTokens: 8),
    );
    runtime.queuedResponses.add(runtime.response!);
    runtime.response = ChatResponse(
      requestId: 'command-repair-2',
      model: ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini'),
      outputText: '修复后的回答。',
      finishReason: ChatFinishReason.completed,
      usage: const ChatUsage(inputTokens: 2, outputTokens: 8),
    );

    final handle = await port.startSingleAgentRun(
      const StartSingleAgentRunRequest(
        conversationId: 'conversation-repair',
        expertId: 'product-manager',
        text: '分析一下',
        clientCommandId: 'command-repair',
      ),
    );

    final outcome = await handle.outcome;
    expect(outcome.answer, '修复后的回答。');
    expect(runtime.requests, hasLength(2));
  });

  test('two unusable replies report malformedOutput', () async {
    final empty = ChatResponse(
      requestId: 'command-repair-fail',
      model: ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini'),
      outputText: '',
      finishReason: ChatFinishReason.completed,
      usage: const ChatUsage(inputTokens: 2, outputTokens: 8),
    );
    runtime.response = empty;
    runtime.queuedResponses.add(empty);

    final handle = await port.startSingleAgentRun(
      const StartSingleAgentRunRequest(
        conversationId: 'conversation-repair-fail',
        expertId: 'product-manager',
        text: '分析一下',
        clientCommandId: 'command-repair-fail',
      ),
    );

    final outcome = await handle.outcome;
    expect(outcome.failure, SingleAgentRunFailure.malformedOutput);
    expect(outcome.failure, isNot(SingleAgentRunFailure.contentFiltered));
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

  group('streaming', () {
    late _FakeStreamingRuntime streamingRuntime;
    late ProductionSingleChatPort streamingPort;

    setUp(() {
      streamingRuntime = _FakeStreamingRuntime();
      streamingPort = ProductionSingleChatPort(
        runtime: runtime,
        experts: ExecutableExpertRegistry(
          gateway: const ExpertOutputValidationGateway(),
        ),
        streaming: streamingRuntime,
      );
    });

    test(
      'deltas grow the Answer preview and finish completes without unary',
      () async {
        final handle = await streamingPort.startSingleAgentRun(
          const StartSingleAgentRunRequest(
            conversationId: 'conversation-stream',
            expertId: 'product-manager',
            text: '请分析需求',
            clientCommandId: 'command-stream',
          ),
        );
        expect(handle.partialAnswers, isNotNull);
        final partials = <String>[];
        final subscription = handle.partialAnswers!.listen(partials.add);
        await pumpEventQueue();

        final events = streamingRuntime.streams.single;
        const payload = '先把需求澄清清楚，再决定优先级。';
        var seq = 0;
        for (var i = 0; i < payload.length; i += 6) {
          events.add(
            ChatStreamEvent.delta(
              seq: ++seq,
              text: payload.substring(
                i,
                i + 6 > payload.length ? payload.length : i + 6,
              ),
            ),
          );
        }
        events.add(
          ChatStreamEvent.finish(
            seq: ++seq,
            finishReason: ChatFinishReason.completed,
          ),
        );
        await events.close();
        await pumpEventQueue();

        final outcome = await handle.outcome;
        await subscription.cancel();
        expect(outcome.isCompleted, isTrue);
        expect(outcome.answer, '先把需求澄清清楚，再决定优先级。');
        // Partials grow: every snapshot extends the previous one.
        expect(partials.length, greaterThan(1));
        for (var i = 1; i < partials.length; i += 1) {
          expect(partials[i], startsWith(partials[i - 1]));
        }
        expect(partials.last, '先把需求澄清清楚，再决定优先级。');
        // The streamed run never touched the unary transport.
        expect(runtime.requests, isEmpty);
        expect(streamingRuntime.requests, hasLength(1));
        expect(streamingRuntime.requests.single.requestId, 'command-stream');
      },
    );

    test('a legacy JSON stream still yields just the answer', () async {
      final handle = await streamingPort.startSingleAgentRun(
        const StartSingleAgentRunRequest(
          conversationId: 'conversation-stream-legacy',
          expertId: 'product-manager',
          text: '请分析需求',
          clientCommandId: 'command-stream-legacy',
        ),
      );
      await pumpEventQueue();

      final events = streamingRuntime.streams.single;
      events.add(
        ChatStreamEvent.delta(seq: 1, text: jsonEncode(_adviceOutput('生产建议'))),
      );
      events.add(
        ChatStreamEvent.finish(
          seq: 2,
          finishReason: ChatFinishReason.completed,
        ),
      );
      await events.close();
      await pumpEventQueue();

      // A model that ignores the plain-text contract must not dump raw JSON
      // into the bubble.
      expect((await handle.outcome).answer, '先把需求澄清清楚，再决定优先级。');
      expect(runtime.requests, isEmpty);
    });

    test(
      'retryable stream error falls back silently to the unary path',
      () async {
        runtime.response = ChatResponse(
          requestId: 'command-stream-fallback',
          model: ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini'),
          outputText: jsonEncode(_adviceOutput('回退建议')),
          finishReason: ChatFinishReason.completed,
          usage: const ChatUsage(inputTokens: 10, outputTokens: 2),
        );
        final handle = await streamingPort.startSingleAgentRun(
          const StartSingleAgentRunRequest(
            conversationId: 'conversation-stream-fallback',
            expertId: 'product-manager',
            text: '请分析需求',
            clientCommandId: 'command-stream-fallback',
          ),
        );
        await pumpEventQueue();

        final events = streamingRuntime.streams.single;
        events.add(ChatStreamEvent.delta(seq: 1, text: '{"An'));
        events.add(
          ChatStreamEvent.error(
            seq: 2,
            code: ModelRuntimeErrorCode.providerUnavailable,
            safeMessage: '稍后重试',
            retryable: true,
          ),
        );
        await events.close();

        final outcome = await handle.outcome;
        expect(outcome.isCompleted, isTrue);
        expect(outcome.answer, '先把需求澄清清楚，再决定优先级。');
        // The full unary path ran exactly once.
        expect(runtime.requests, hasLength(1));
        expect(runtime.requests.single.requestId, 'command-stream-fallback');
      },
    );

    test('streamed prose is the answer, with no repair round trip', () async {
      // Under the plain-text contract there is nothing to "fix": prose is
      // exactly what was asked for, so the unary transport is never touched.
      final handle = await streamingPort.startSingleAgentRun(
        const StartSingleAgentRunRequest(
          conversationId: 'conversation-stream-prose',
          expertId: 'product-manager',
          text: '分析一下',
          clientCommandId: 'command-stream-prose',
        ),
      );
      await pumpEventQueue();

      final events = streamingRuntime.streams.single;
      events.add(ChatStreamEvent.delta(seq: 1, text: '好的，我来'));
      events.add(ChatStreamEvent.delta(seq: 2, text: '帮你分析一下。'));
      events.add(
        ChatStreamEvent.finish(
          seq: 3,
          finishReason: ChatFinishReason.completed,
        ),
      );
      await events.close();
      await pumpEventQueue();

      final outcome = await handle.outcome;
      expect(outcome.isCompleted, isTrue);
      expect(outcome.answer, '好的，我来帮你分析一下。');
      expect(runtime.requests, isEmpty);
    });

    test('stop cancels the streaming request', () async {
      final handle = await streamingPort.startSingleAgentRun(
        const StartSingleAgentRunRequest(
          conversationId: 'conversation-stream-stop',
          expertId: 'product-manager',
          text: '等待',
          clientCommandId: 'command-stream-stop',
        ),
      );
      await pumpEventQueue();
      final stopped = streamingPort.stopSingleAgentRun(handle.runId);
      await streamingRuntime.streams.single.close();
      await stopped;

      final token = streamingRuntime.requests.single.cancellationToken;
      expect(token?.isCancelled, isTrue);
      expect((await handle.outcome).failure, SingleAgentRunFailure.retryable);
      expect(runtime.requests, isEmpty);
    });
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

final class _FakeStreamingRuntime implements StreamingChatModelRuntime {
  final requests = <ChatRequest>[];
  final streams = <StreamController<ChatStreamEvent>>[];

  @override
  Stream<ChatStreamEvent> streamChat(
    ChatRequest request, {
    required CancellationToken cancellationToken,
  }) {
    requests.add(request);
    final controller = StreamController<ChatStreamEvent>();
    streams.add(controller);
    return controller.stream;
  }
}

final class _FakeRuntime implements ProductionSingleChatRuntime {
  final requests = <ChatRequest>[];
  final resolvedAgentIds = <String>[];
  ChatResponse? response;
  final queuedResponses = <ChatResponse>[];
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
    if (queuedResponses.isNotEmpty) return queuedResponses.removeAt(0);
    return response!;
  }
}
