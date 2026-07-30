import 'dart:async';
import 'dart:convert';

// ignore_for_file: prefer_initializing_formals

import 'package:halo_mobile/experts/expert_output_prompt.dart';
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
        // Schema-nonconforming model output is a formatting miss, not a
        // provider safety rejection; only ModelRuntimeErrorCode.contentRejected
        // may surface as contentFiltered.
        return const SingleAgentRunOutcome.failed(
          failure: SingleAgentRunFailure.malformedOutput,
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

String _renderExpertSystemPrompt(ExecutableExpert expert) => [
  expert.profile.promptPackage.render(),
  renderExpertOutputPrompt(expert),
].join('\n');

/// Deterministically unwraps common non-semantic packaging around a JSON
/// object payload: surrounding whitespace, one markdown code fence
/// (``` or ```json), and, failing that, one substring extraction from the
/// first `{` to the last `}`. This only removes packaging; every schema
/// check after decoding stays exactly as strict as before.
String _unwrapModelJsonObjectText(String raw) {
  var text = raw.trim();
  if (text.startsWith('```')) {
    final firstLineBreak = text.indexOf('\n');
    final closingFence = text.lastIndexOf('```');
    if (firstLineBreak >= 0 && closingFence > firstLineBreak) {
      text = text.substring(firstLineBreak + 1, closingFence).trim();
    }
  }
  if (!(text.startsWith('{') && text.endsWith('}'))) {
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      text = text.substring(start, end + 1);
    }
  }
  return text;
}

String? _decodeAndProject(ExecutableExpert expert, String rawModelOutput) {
  try {
    final decoded = jsonDecode(_unwrapModelJsonObjectText(rawModelOutput));
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
  // A missing or unresolvable model binding is a configuration gap, not a
  // transient send failure; telling the user to retry would never work.
  ModelRuntimeErrorCode.invalidConfiguration =>
    SingleAgentRunFailure.notConfigured,
  _ => SingleAgentRunFailure.retryable,
};
