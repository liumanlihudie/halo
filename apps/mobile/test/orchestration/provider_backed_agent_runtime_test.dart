import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/provider_registry.dart';
import 'package:halo_mobile/orchestration/agent_execution_policy.dart';
import 'package:halo_mobile/orchestration/basic_durable_runner.dart';
import 'package:halo_mobile/orchestration/provider_backed_agent_runtime.dart';
import 'package:halo_mobile/orchestration/sqlite_model_call_journal.dart';

void main() {
  late _CapturingRuntime provider;
  late SqliteModelCallJournal journal;
  late ProviderBackedAgentRuntime runtime;
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('halo-provider-runtime-');
    provider = _CapturingRuntime();
    journal = SqliteModelCallJournal.open('${directory.path}/calls.sqlite');
    runtime = _runtime(provider: provider, journal: journal);
  });

  tearDown(() async {
    await journal.close();
    directory.deleteSync(recursive: true);
  });

  test(
    'composes authorized expert prompt, conversation and model override',
    () async {
      provider.response = _response(_adviceOutput());

      final result = await runtime.respond(_turn());
      final request = provider.requests.single;
      expect(
        request.model,
        ModelRef(providerId: 'toapis', modelId: 'architect'),
      );
      expect(request.messages.first.role, ChatRole.system);
      expect(request.messages.first.content, contains('技术架构师'));
      expect(request.messages.last.content, contains('当前用户问题：请评估架构边界'));
      expect(request.messages.last.content, contains('上一位专家的公开结论'));
      expect(result, contains('"uncertainty":"unverified"'));
      expect(result, contains('建议先把架构分层'));
    },
  );

  test(
    'does not use a catalog-only identity as an executable expert',
    () async {
      await expectLater(
        runtime.respond(_turn(agentId: 'data-analyst')),
        throwsA(isA<ProviderBackedAgentRuntimeFailure>()),
      );
      expect(provider.requests, isEmpty);
    },
  );

  test(
    'bounds shared public context and excludes tools private memory and keys',
    () async {
      const secret = 'sk-not-for-provider-123456789012345';
      provider.response = _response(_adviceOutput());

      await runtime.respond(
        _turn(
          input: '用户输入包含 $secret',
          previousResponses: List<String>.filled(20, '公开上下文' * 40),
        ),
      );

      final request = provider.requests.single;
      final serialized = jsonEncode({
        'messages': request.messages
            .map((message) => message.toJson())
            .toList(),
        'metadata': request.metadata,
      });
      expect(serialized, isNot(contains(secret)));
      expect(request.messages.last.content.length, lessThanOrEqualTo(520));
      expect(request.metadata['tools'], 'disabled');
      expect(request.metadata['privateMemory'], 'disabled');
      expect(serialized, isNot(contains('memory.private.read')));
    },
  );

  test(
    'uses a dedicated summarizer package instead of a participant identity',
    () async {
      provider.response = _response(_summaryEnvelope('讨论结论'));

      final result = await runtime.summarize(
        const DiscussionSummaryRequest(
          runId: 'run-summary',
          conversationId: 'group-1',
          input: '原始问题',
          outcomes: [
            AgentTurnOutcome(agentId: 'technical-architect', text: '公开建议'),
          ],
          idempotencyKey: 'summary-1',
        ),
      );

      final request = provider.requests.single;
      expect(
        request.model,
        ModelRef(providerId: 'toapis', modelId: 'summarizer'),
      );
      expect(request.messages.first.content, contains('独立总结器'));
      expect(request.messages.first.content, isNot(contains('技术架构师')));
      expect(result, contains('讨论结论'));
    },
  );

  test(
    'maps provider failures to fixed safe codes without upstream content',
    () async {
      provider.error = const ModelRuntimeException(
        code: ModelRuntimeErrorCode.insufficientBalance,
        safeMessage: 'UPSTREAM_BODY sk-hidden',
        retryable: false,
      );

      await expectLater(
        runtime.respond(_turn(idempotencyKey: 'quota-1')),
        throwsA(
          isA<ProviderBackedAgentRuntimeFailure>()
              .having(
                (error) => error.code,
                'code',
                AgentRuntimeFailureCode.quotaExceeded,
              )
              .having(
                (error) => error.toString(),
                'safe output',
                isNot(contains('UPSTREAM_BODY')),
              ),
        ),
      );
    },
  );

  test('rejects content-filtered finish and malformed model output', () async {
    provider.response = _response(
      _adviceOutput(),
      finishReason: ChatFinishReason.contentFiltered,
    );
    await expectLater(
      runtime.respond(_turn(idempotencyKey: 'filtered-1')),
      throwsA(isA<ProviderBackedAgentRuntimeFailure>()),
    );
    // Under the plain-answer contract prose is a valid reply; only an
    // unusable one (empty here) is malformed.
    provider.response = _response('   ');
    await expectLater(
      runtime.respond(_turn(idempotencyKey: 'malformed-1')),
      throwsA(
        isA<ProviderBackedAgentRuntimeFailure>().having(
          (error) => error.code,
          'code',
          AgentRuntimeFailureCode.malformedOutput,
        ),
      ),
    );
  });

  test('markdown-fenced expert output still parses and completes', () async {
    provider.response = _response('```json\n${_adviceOutput()}\n```');

    final result = await runtime.respond(_turn(idempotencyKey: 'fenced-1'));

    expect(result, contains('建议先把架构分层'));
    expect(result, contains('"uncertainty":"unverified"'));
  });

  test('prose-wrapped summary envelope still parses and completes', () async {
    provider.response = _response('以下是总结：\n${_summaryEnvelope('讨论结论')}\n谢谢。');

    final result = await runtime.summarize(
      const DiscussionSummaryRequest(
        runId: 'run-summary-wrapped',
        conversationId: 'group-1',
        input: '原始问题',
        outcomes: [],
        idempotencyKey: 'summary-wrapped-1',
      ),
    );

    expect(result, contains('讨论结论'));
  });

  test(
    'maps cancellation and retryable provider errors to fixed safe codes',
    () async {
      provider.error = const ModelRuntimeException(
        code: ModelRuntimeErrorCode.streamInterrupted,
        safeMessage: 'provider cancellation details',
        retryable: false,
      );
      await expectLater(
        runtime.respond(_turn(idempotencyKey: 'cancelled-1')),
        throwsA(
          isA<ProviderBackedAgentRuntimeFailure>().having(
            (error) => error.code,
            'code',
            AgentRuntimeFailureCode.cancelled,
          ),
        ),
      );

      provider.error = const ModelRuntimeException(
        code: ModelRuntimeErrorCode.providerUnavailable,
        safeMessage: 'upstream failure details',
        retryable: true,
      );
      await expectLater(
        runtime.respond(_turn(idempotencyKey: 'retryable-1')),
        throwsA(
          isA<ProviderBackedAgentRuntimeFailure>().having(
            (error) => error.code,
            'code',
            AgentRuntimeFailureCode.retryable,
          ),
        ),
      );
    },
  );

  test('timeout and cancellation fail closed as outcome unknown', () async {
    provider.pending = Completer<ChatResponse>();
    final shortRuntime = _runtime(
      provider: provider,
      journal: journal,
      timeout: const Duration(milliseconds: 1),
    );

    await expectLater(
      shortRuntime.respond(_turn(idempotencyKey: 'timeout-1')),
      throwsA(
        isA<ProviderBackedAgentRuntimeFailure>().having(
          (error) => error.code,
          'code',
          AgentRuntimeFailureCode.timeout,
        ),
      ),
    );
    expect(
      (await journal.get('timeout-1'))!.status,
      ModelCallStatus.outcomeUnknown,
    );
    expect(provider.requests.single.cancellationToken!.isCancelled, isTrue);
  });

  test('crash-window replay cannot bill the provider a second time', () async {
    await journal.reserve('crash-window-1');
    await journal.markDispatched('crash-window-1');
    provider.response = _response(_adviceOutput());

    await expectLater(
      runtime.respond(_turn(idempotencyKey: 'crash-window-1')),
      throwsA(
        isA<ProviderBackedAgentRuntimeFailure>().having(
          (error) => error.code,
          'code',
          AgentRuntimeFailureCode.outcomeUnknown,
        ),
      ),
    );
    expect(provider.requests, isEmpty);
  });

  test(
    'completed idempotency replay returns the original public envelope',
    () async {
      provider.response = _response(_adviceOutput());
      final first = await runtime.respond(_turn(idempotencyKey: 'completed-1'));
      final replay = await runtime.respond(
        _turn(idempotencyKey: 'completed-1'),
      );

      expect(replay, first);
      expect(provider.requests, hasLength(1));
    },
  );

  test(
    'summary envelope redacts model-supplied raw keys before publication',
    () async {
      const rawKey = 'sk-summary-secret-123456789012345';
      provider.response = _response(_summaryEnvelope('结果：$rawKey'));

      final published = await runtime.summarize(
        const DiscussionSummaryRequest(
          runId: 'run-summary-redaction',
          conversationId: 'group-1',
          input: '原始问题',
          outcomes: [],
          idempotencyKey: 'summary-redaction-1',
        ),
      );

      expect(published, isNot(contains(rawKey)));
      expect(published, contains('[redacted]'));
    },
  );
}

ProviderBackedAgentRuntime _runtime({
  required _CapturingRuntime provider,
  required SqliteModelCallJournal journal,
  Duration timeout = const Duration(seconds: 1),
}) => ProviderBackedAgentRuntime(
  modelRuntime: provider,
  experts: ExecutableExpertRegistry(
    gateway: const ExpertOutputValidationGateway(),
  ),
  journal: journal,
  policy: AgentExecutionPolicy(
    defaultModel: ModelRef(providerId: 'toapis', modelId: 'default'),
    summarizerModel: ModelRef(providerId: 'toapis', modelId: 'summarizer'),
    expertModelOverrides: {
      'technical-architect': ModelRef(
        providerId: 'toapis',
        modelId: 'architect',
      ),
    },
    requestTimeout: timeout,
    maxSharedContextCharacters: 400,
    maxPublicAnswerCharacters: 300,
  ),
);

AgentTurnRequest _turn({
  String agentId = 'technical-architect',
  String input = '请评估架构边界',
  List<String> previousResponses = const ['上一位专家的公开结论'],
  String idempotencyKey = 'turn-1',
}) => AgentTurnRequest(
  runId: 'run-1',
  conversationId: 'group-1',
  agentId: agentId,
  input: input,
  previousResponses: previousResponses,
  idempotencyKey: idempotencyKey,
);

ChatResponse _response(
  String output, {
  ChatFinishReason finishReason = ChatFinishReason.completed,
}) => ChatResponse(
  requestId: 'provider-request',
  model: ModelRef(providerId: 'toapis', modelId: 'default'),
  outputText: output,
  finishReason: finishReason,
  usage: const ChatUsage(inputTokens: 2, outputTokens: 2),
);

String _adviceOutput() => jsonEncode({
  'Answer': '建议先把架构分层，再逐步验证。',
  'Context': '已知需求',
  'Decision': '分层',
  'Components': ['边界'],
  'Tradeoffs': ['先小后大'],
  'VerificationPlan': ['待验证'],
  'Verification': {
    'claimType': 'advice',
    'tense': 'proposed',
    'verified': false,
    'source': 'none',
    'proposedActions': [
      {'verb': 'review', 'target': 'product-requirements', 'conditions': []},
    ],
    'executedFacts': [],
  },
});

String _summaryEnvelope(String answer) => jsonEncode({
  'answer': answer,
  'uncertainty': 'unverified',
  'evidenceReferences': <String>[],
});

final class _CapturingRuntime implements ChatModelRuntime {
  final requests = <ChatRequest>[];
  ChatResponse? response;
  ModelRuntimeException? error;
  Completer<ChatResponse>? pending;

  @override
  Future<ChatResponse> chat(ChatRequest request) async {
    requests.add(request);
    final currentError = error;
    if (currentError != null) throw currentError;
    final currentPending = pending;
    if (currentPending != null) {
      await Future.any([
        currentPending.future,
        request.cancellationToken!.whenCancelled,
      ]);
      if (request.cancellationToken!.isCancelled) {
        throw const ModelRuntimeException(
          code: ModelRuntimeErrorCode.streamInterrupted,
          safeMessage: 'cancelled',
          retryable: false,
        );
      }
      return currentPending.future;
    }
    return response!;
  }
}
