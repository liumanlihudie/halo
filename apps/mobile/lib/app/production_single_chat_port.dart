import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

// ignore_for_file: prefer_initializing_formals

import 'package:halo_mobile/app/streaming_answer_extractor.dart';
import 'package:halo_mobile/experts/expert_output_prompt.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/features/single_chat/single_chat_controller.dart';
import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/chat_stream_models.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/streaming_chat_runtime.dart';

abstract interface class ProductionSingleChatRuntime {
  Future<ModelRef> resolveConfiguredModel({required String agentId});

  Future<ChatResponse> chat(ChatRequest request);
}

final class ProductionSingleChatPort implements SingleChatPort {
  ProductionSingleChatPort({
    required ProductionSingleChatRuntime runtime,
    required ExecutableExpertRegistry experts,
    StreamingChatModelRuntime? streaming,
  }) : _runtime = runtime,
       _experts = experts,
       _streaming = streaming;

  final ProductionSingleChatRuntime _runtime;
  final ExecutableExpertRegistry _experts;

  /// Optional streaming transport. When present, runs stream a live Answer
  /// preview; every failure mode falls back to the unary path so streaming
  /// can never reduce reliability.
  final StreamingChatModelRuntime? _streaming;
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
    StreamController<String>? partials;
    final Future<SingleAgentRunOutcome> outcome;
    if (_streaming case final streaming?) {
      // Broadcast + snapshot semantics: each emission is the full Answer so
      // far, so a listener that attaches after early deltas misses nothing.
      final controller = StreamController<String>.broadcast();
      partials = controller;
      outcome = _executeStreaming(
        streaming: streaming,
        request: request,
        expert: expert,
        cancellationToken: cancellationToken,
        partials: controller,
      );
    } else {
      outcome = _execute(
        request: request,
        expert: expert,
        cancellationToken: cancellationToken,
      );
    }
    final active = _ActiveSingleChatRun(cancellationToken, outcome);
    _active[runId] = active;
    unawaited(
      outcome.whenComplete(() {
        _active.remove(runId);
        unawaited(partials?.close());
      }),
    );
    return SingleAgentRunHandle(
      runId: runId,
      outcome: outcome,
      partialAnswers: partials?.stream,
    );
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
          messages: _conversationMessages(expert, request),
          cancellationToken: cancellationToken,
        ),
      );
      if (cancellationToken.isCancelled) {
        return const SingleAgentRunOutcome.failed(
          failure: SingleAgentRunFailure.retryable,
        );
      }
      var projected = _decodeAndProject(expert, response.outputText);
      if (projected == null && !cancellationToken.isCancelled) {
        projected = await _repairRetry(
          request: request,
          expert: expert,
          model: model,
          previousOutput: response.outputText,
          cancellationToken: cancellationToken,
        );
      }
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

  /// Streaming variant of [_execute].
  ///
  /// Raw streamed text is only ever surfaced two ways: the Answer-value-only
  /// preview produced by [StreamingAnswerExtractor], and the final projection
  /// after the exact same [_decodeAndProject] validation the unary path uses.
  /// Any recoverable stream failure (retryable error, unsupported endpoint,
  /// invalid configuration, or a stream that ends without a finish event)
  /// silently re-runs the full unary path, which also owns error reporting
  /// such as notConfigured.
  Future<SingleAgentRunOutcome> _executeStreaming({
    required StreamingChatModelRuntime streaming,
    required StartSingleAgentRunRequest request,
    required ExecutableExpert expert,
    required CancellationToken cancellationToken,
    required StreamController<String> partials,
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
      final extractor = StreamingAnswerExtractor();
      final raw = StringBuffer();
      var sawFinish = false;
      var fallBackToUnary = false;
      var previews = 0;
      // Diagnostic only: error *codes* and counters, never provider text,
      // headers, or model output. Without it a silent demotion to the unary
      // path is indistinguishable from streaming that simply looks instant.
      String? demotionReason;
      try {
        final events = streaming.streamChat(
          ChatRequest(
            requestId: request.clientCommandId,
            model: model,
            messages: _conversationMessages(expert, request),
            cancellationToken: cancellationToken,
          ),
          cancellationToken: cancellationToken,
        );
        await for (final event in events) {
          if (cancellationToken.isCancelled) {
            break;
          }
          switch (event.type) {
            case ChatStreamEventType.delta:
              final text = event.text ?? '';
              raw.write(text);
              if (extractor.feed(text).isNotEmpty && !partials.isClosed) {
                previews += 1;
                partials.add(extractor.answerSoFar);
              }
            case ChatStreamEventType.usage:
              break;
            case ChatStreamEventType.finish:
              sawFinish = true;
            case ChatStreamEventType.error:
              if (_isStreamFallbackError(event.retryable, event.errorCode)) {
                fallBackToUnary = true;
                demotionReason = 'event:${event.errorCode?.name ?? 'unknown'}';
              } else {
                return SingleAgentRunOutcome.failed(
                  failure: _mapFailure(
                    event.errorCode ?? ModelRuntimeErrorCode.transportFailure,
                  ),
                );
              }
          }
          if (sawFinish || fallBackToUnary) {
            break;
          }
        }
      } on ModelRuntimeException catch (error) {
        if (cancellationToken.isCancelled) {
          return const SingleAgentRunOutcome.failed(
            failure: SingleAgentRunFailure.retryable,
          );
        }
        if (!_isStreamFallbackError(error.retryable, error.code)) {
          return SingleAgentRunOutcome.failed(failure: _mapFailure(error.code));
        }
        fallBackToUnary = true;
        demotionReason = 'exception:${error.code.name}';
      } catch (_) {
        fallBackToUnary = true;
        demotionReason = 'exception:unknown';
      }
      if (cancellationToken.isCancelled) {
        return const SingleAgentRunOutcome.failed(
          failure: SingleAgentRunFailure.retryable,
        );
      }
      if (fallBackToUnary || !sawFinish) {
        developer.log(
          'demoted to unary: reason=${demotionReason ?? 'noFinishEvent'} '
          'previews=$previews',
          name: 'halo.stream',
        );
        return _execute(
          request: request,
          expert: expert,
          cancellationToken: cancellationToken,
        );
      }
      developer.log(
        'streamed: previews=$previews chars=${raw.length}',
        name: 'halo.stream',
      );
      var projected = _decodeAndProject(expert, raw.toString());
      if (projected == null && !cancellationToken.isCancelled) {
        projected = await _repairRetry(
          request: request,
          expert: expert,
          model: model,
          previousOutput: raw.toString(),
          cancellationToken: cancellationToken,
        );
      }
      if (projected == null) {
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

  /// One silent repair attempt: models regularly break the JSON contract on a
  /// first try, and asking again with an explicit correction fixes most of
  /// them without bothering the user. Exactly one retry — a model that fails
  /// twice reports malformedOutput and the user's 重试 button takes over.
  Future<String?> _repairRetry({
    required StartSingleAgentRunRequest request,
    required ExecutableExpert expert,
    required ModelRef model,
    required String previousOutput,
    required CancellationToken cancellationToken,
  }) async {
    final repaired = await _runtime.chat(
      ChatRequest(
        requestId: '${request.clientCommandId}-repair',
        model: model,
        messages: [
          ..._conversationMessages(expert, request),
          ChatMessage(role: ChatRole.assistant, content: previousOutput),
          ChatMessage(
            role: ChatRole.user,
            content:
                '你上一条回复没有按要求返回。请重新只返回一个符合模板的 JSON 对象：'
                '不要 Markdown、不要代码围栏、不要任何解释文字。',
          ),
        ],
        cancellationToken: cancellationToken,
      ),
    );
    if (cancellationToken.isCancelled) {
      return null;
    }
    return _decodeAndProject(expert, repaired.outputText);
  }

  static List<ChatMessage> _conversationMessages(
    ExecutableExpert expert,
    StartSingleAgentRunRequest request,
  ) => [
    ChatMessage(
      role: ChatRole.system,
      content: _renderExpertSystemPrompt(expert),
    ),
    ChatMessage(role: ChatRole.user, content: request.text),
  ];

  static bool _isStreamFallbackError(
    bool? retryable,
    ModelRuntimeErrorCode? code,
  ) =>
      retryable == true ||
      code == ModelRuntimeErrorCode.unsupportedEndpoint ||
      code == ModelRuntimeErrorCode.invalidConfiguration;

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
