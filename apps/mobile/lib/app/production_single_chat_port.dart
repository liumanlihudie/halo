import 'dart:async';
import 'dart:convert';

// ignore_for_file: prefer_initializing_formals

import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/features/single_chat/single_chat_controller.dart';
import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';

abstract interface class ProductionSingleChatRuntime {
  Future<ModelRef> resolveConfiguredModel({required String agentId});

  Future<ChatResponse> chat(ChatRequest request);
}

final class ProductionSingleChatPort implements SingleChatPort {
  ProductionSingleChatPort({
    required ProductionSingleChatRuntime runtime,
    required ExecutableExpertRegistry experts,
  }) : _runtime = runtime,
       _experts = experts;

  final ProductionSingleChatRuntime _runtime;
  final ExecutableExpertRegistry _experts;
  final Map<String, _ActiveSingleChatRun> _active = {};
  bool _closed = false;
  Future<void>? _closeFuture;

  @override
  Future<SingleAgentRunHandle> startSingleAgentRun(
    StartSingleAgentRunRequest request,
  ) async {
    if (_closed) {
      throw StateError('Production single chat is unavailable');
    }
    final expert = _experts.singleChatById(request.expertId);
    if (expert == null) {
      throw StateError('Expert is not authorized for single chat');
    }
    final runId = 'single-${request.clientCommandId}';
    if (_active.containsKey(runId)) {
      throw StateError('A run with this command identity is already active');
    }
    final cancellationToken = CancellationToken();
    final outcome = _execute(
      request: request,
      expert: expert,
      cancellationToken: cancellationToken,
    );
    final active = _ActiveSingleChatRun(cancellationToken, outcome);
    _active[runId] = active;
    unawaited(outcome.whenComplete(() => _active.remove(runId)));
    return SingleAgentRunHandle(runId: runId, outcome: outcome);
  }

  Future<SingleAgentRunOutcome> _execute({
    required StartSingleAgentRunRequest request,
    required ExecutableExpert expert,
    required CancellationToken cancellationToken,
  }) async {
    try {
      final model = await _runtime.resolveConfiguredModel(
        agentId: request.expertId,
      );
      if (cancellationToken.isCancelled) {
        return const SingleAgentRunOutcome.failed(
          failure: SingleAgentRunFailure.retryable,
        );
      }
      final response = await _runtime.chat(
        ChatRequest(
          requestId: request.clientCommandId,
          model: model,
          messages: [
            ChatMessage(
              role: ChatRole.system,
              content: _renderExpertSystemPrompt(expert),
            ),
            ChatMessage(role: ChatRole.user, content: request.text),
          ],
          cancellationToken: cancellationToken,
        ),
      );
      if (cancellationToken.isCancelled) {
        return const SingleAgentRunOutcome.failed(
          failure: SingleAgentRunFailure.retryable,
        );
      }
      final projected = _decodeAndProject(expert, response.outputText);
      if (projected == null) {
        return const SingleAgentRunOutcome.failed(
          failure: SingleAgentRunFailure.contentFiltered,
        );
      }
      return SingleAgentRunOutcome.completed(answer: projected);
    } on ModelRuntimeException catch (error) {
      return SingleAgentRunOutcome.failed(failure: _mapFailure(error.code));
    } on StateError {
      return const SingleAgentRunOutcome.failed(
        failure: SingleAgentRunFailure.retryable,
      );
    } catch (_) {
      return const SingleAgentRunOutcome.failed(
        failure: SingleAgentRunFailure.retryable,
      );
    }
  }

  @override
  Future<void> stopSingleAgentRun(String runId) async {
    final active = _active[runId];
    if (active == null) return;
    active.cancellationToken.cancel();
    await active.outcome;
  }

  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    _closed = true;
    final active = _active.values.toList(growable: false);
    for (final run in active) {
      run.cancellationToken.cancel();
    }
    final future = Future.wait<void>([
      for (final run in active) run.outcome.then<void>((_) {}),
    ]);
    _closeFuture = future;
    return future;
  }
}

String _renderExpertSystemPrompt(ExecutableExpert expert) {
  const proposedAction = {
    'verb': 'review',
    'target': 'replace-with-target',
    'conditions': ['replace-with-condition'],
  };
  final template = <String, Object?>{};
  for (final entry in expert.profile.outputSchema.fields.entries) {
    template[entry.key] = switch (entry.value) {
      OutputValueType.string => 'replace-with-answer',
      OutputValueType.stringList => ['replace-with-item'],
      OutputValueType.evidenceList => <Object?>[],
      OutputValueType.integer => 0,
      OutputValueType.boolean => false,
      OutputValueType.proposedActionList => [proposedAction],
      OutputValueType.verificationEnvelope => {
        'claimType': 'advice',
        'tense': 'proposed',
        'verified': false,
        'source': 'none',
        'proposedActions': [proposedAction],
        'executedFacts': <String>[],
      },
    };
  }
  return [
    expert.profile.promptPackage.render(),
    'Output format:',
    'Return exactly one valid JSON object and no Markdown or surrounding text.',
    'Use exactly the keys and value shapes in this template. Replace every '
        'placeholder with a concise answer. Do not add or remove keys.',
    'Verification.proposedActions MUST contain at least one action. Its verb '
        'MUST be one of: analyze, compare, document, implement, measure, plan, '
        'query, review, test, train, verify. target and every condition MUST '
        'be lowercase ASCII kebab-case identifiers. executedFacts MUST be [].',
    jsonEncode(template),
  ].join('\n');
}

String? _decodeAndProject(ExecutableExpert expert, String rawModelOutput) {
  try {
    final decoded = jsonDecode(rawModelOutput);
    if (decoded is! Map) return null;
    final output = <String, Object?>{};
    for (final entry in decoded.entries) {
      final key = entry.key;
      if (key is! String) return null;
      output[key] = entry.value;
    }
    // The iPhone P0 is advice-only. Execution claims need a future trusted
    // tool/receipt context, so model-supplied receipt-shaped JSON is never
    // treated as evidence or passed through as a completed answer.
    if (_isUnsupportedExecutionEnvelope(output)) return null;
    return expert.validateAndProject(output);
  } catch (_) {
    return null;
  }
}

bool _isUnsupportedExecutionEnvelope(Map<String, Object?> output) {
  final verification = output['Verification'];
  return verification is Map && verification['claimType'] == 'execution';
}

final class _ActiveSingleChatRun {
  const _ActiveSingleChatRun(this.cancellationToken, this.outcome);

  final CancellationToken cancellationToken;
  final Future<SingleAgentRunOutcome> outcome;
}

SingleAgentRunFailure _mapFailure(ModelRuntimeErrorCode code) => switch (code) {
  ModelRuntimeErrorCode.invalidCredential =>
    SingleAgentRunFailure.authentication,
  ModelRuntimeErrorCode.insufficientBalance ||
  ModelRuntimeErrorCode.rateLimited => SingleAgentRunFailure.quotaLimited,
  ModelRuntimeErrorCode.contentRejected =>
    SingleAgentRunFailure.contentFiltered,
  _ => SingleAgentRunFailure.retryable,
};
