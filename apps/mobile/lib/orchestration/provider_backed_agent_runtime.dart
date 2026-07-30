import 'dart:async';
import 'dart:convert';

import 'package:halo_mobile/experts/expert_output_prompt.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/provider_registry.dart';
import 'package:halo_mobile/orchestration/agent_execution_policy.dart';
import 'package:halo_mobile/orchestration/basic_durable_runner.dart';
import 'package:halo_mobile/orchestration/sqlite_model_call_journal.dart';

enum AgentRuntimeFailureCode {
  unauthorizedExpert,
  outcomeUnknown,
  timeout,
  cancelled,
  contentFiltered,
  quotaExceeded,
  retryable,
  malformedOutput,
}

/// A deliberately detail-free failure suitable for the durable runner boundary.
final class ProviderBackedAgentRuntimeFailure implements Exception {
  const ProviderBackedAgentRuntimeFailure(this.code);

  final AgentRuntimeFailureCode code;

  @override
  String toString() => 'ProviderBackedAgentRuntimeFailure(${code.name})';
}

/// Public, persisted result for P0: advice only and explicitly unverified.
final class TruthfulOutputEnvelope {
  TruthfulOutputEnvelope({
    required this.answer,
    required this.uncertainty,
    required List<String> evidenceReferences,
  }) : evidenceReferences = List.unmodifiable(evidenceReferences);

  final String answer;
  final String uncertainty;
  final List<String> evidenceReferences;

  String encode() => jsonEncode({
    'answer': answer,
    'uncertainty': uncertainty,
    'evidenceReferences': evidenceReferences,
  });

  static TruthfulOutputEnvelope? decode(
    Object? value, {
    required int maxAnswerCharacters,
  }) {
    if (value is! Map || value.keys.any((key) => key is! String)) return null;
    const keys = {'answer', 'uncertainty', 'evidenceReferences'};
    if (value.keys.toSet().length != keys.length ||
        !value.keys.toSet().containsAll(keys)) {
      return null;
    }
    final answer = value['answer'];
    final uncertainty = value['uncertainty'];
    final references = value['evidenceReferences'];
    if (answer is! String ||
        answer.trim().isEmpty ||
        answer.length > maxAnswerCharacters ||
        uncertainty != 'unverified' ||
        references is! List ||
        references.any(
          (reference) => reference is! String || reference.trim().isEmpty,
        )) {
      return null;
    }
    return TruthfulOutputEnvelope(
      answer: _redactPublicText(answer),
      uncertainty: uncertainty,
      evidenceReferences: references
          .cast<String>()
          .map(_redactPublicText)
          .toList(growable: false),
    );
  }
}

/// Provider-backed, unary-only P0 runtime.
///
/// The SQLite journal is intentionally an additional provider billing fence,
/// not a substitute for [BasicDurableRunner]'s event-level external intent.
final class ProviderBackedAgentRuntime
    implements AgentRuntime, IdempotentAgentRuntimeCapability {
  factory ProviderBackedAgentRuntime({
    required ChatModelRuntime modelRuntime,
    required ExecutableExpertRegistry experts,
    required SqliteModelCallJournal journal,
    required AgentExecutionPolicy policy,
  }) => ProviderBackedAgentRuntime._(modelRuntime, experts, journal, policy);

  ProviderBackedAgentRuntime._(
    this._modelRuntime,
    this._experts,
    this._journal,
    this._policy,
  );

  final ChatModelRuntime _modelRuntime;
  final ExecutableExpertRegistry _experts;
  final SqliteModelCallJournal _journal;
  final AgentExecutionPolicy _policy;

  @override
  bool get supportsIdempotency => true;

  @override
  Future<String> respond(AgentTurnRequest request) async {
    final expert = _experts.groupChatById(request.agentId);
    if (expert == null) {
      throw const ProviderBackedAgentRuntimeFailure(
        AgentRuntimeFailureCode.unauthorizedExpert,
      );
    }
    final entry = await _journal.reserve(request.idempotencyKey);
    if (entry.status == ModelCallStatus.completed) return entry.publicResult!;
    if (entry.status != ModelCallStatus.reserved) {
      throw const ProviderBackedAgentRuntimeFailure(
        AgentRuntimeFailureCode.outcomeUnknown,
      );
    }

    final cancellation = CancellationToken();
    try {
      await _journal.markDispatched(request.idempotencyKey);
      final response = await _callWithTimeout(
        ChatRequest(
          requestId: request.idempotencyKey,
          model: _policy.modelForExpert(expert.profile.id),
          messages: [
            ChatMessage(
              role: ChatRole.system,
              content: _expertSystemPrompt(expert),
            ),
            ChatMessage(
              role: ChatRole.user,
              content: _participantInput(
                request.input,
                request.previousResponses,
              ),
            ),
          ],
          maxOutputTokens: _policy.maxPublicAnswerCharacters,
          metadata: const {
            'surface': 'group-chat',
            'tools': 'disabled',
            'privateMemory': 'disabled',
          },
          cancellationToken: cancellation,
        ),
        cancellation,
      );
      final envelope = _projectExpertResponse(expert, response);
      if (envelope == null) {
        await _journal.markOutcomeUnknown(request.idempotencyKey);
        throw const ProviderBackedAgentRuntimeFailure(
          AgentRuntimeFailureCode.malformedOutput,
        );
      }
      final encoded = envelope.encode();
      await _journal.complete(request.idempotencyKey, publicResult: encoded);
      return encoded;
    } on _RuntimeTimedOut {
      cancellation.cancel();
      await _markUnknown(request.idempotencyKey);
      throw const ProviderBackedAgentRuntimeFailure(
        AgentRuntimeFailureCode.timeout,
      );
    } on ModelRuntimeException catch (error) {
      cancellation.cancel();
      await _markUnknown(request.idempotencyKey);
      throw ProviderBackedAgentRuntimeFailure(_mapModelFailure(error.code));
    } on ProviderBackedAgentRuntimeFailure {
      await _markUnknown(request.idempotencyKey);
      rethrow;
    } on Object {
      cancellation.cancel();
      await _markUnknown(request.idempotencyKey);
      throw const ProviderBackedAgentRuntimeFailure(
        AgentRuntimeFailureCode.retryable,
      );
    }
  }

  @override
  Future<String> summarize(DiscussionSummaryRequest request) async {
    final entry = await _journal.reserve(request.idempotencyKey);
    if (entry.status == ModelCallStatus.completed) return entry.publicResult!;
    if (entry.status != ModelCallStatus.reserved) {
      throw const ProviderBackedAgentRuntimeFailure(
        AgentRuntimeFailureCode.outcomeUnknown,
      );
    }
    final cancellation = CancellationToken();
    try {
      await _journal.markDispatched(request.idempotencyKey);
      final response = await _callWithTimeout(
        ChatRequest(
          requestId: request.idempotencyKey,
          model: _policy.summarizerModel,
          messages: [
            ChatMessage(
              role: ChatRole.system,
              content: _policy.summarizerPrompt.render(),
            ),
            ChatMessage(role: ChatRole.user, content: _summaryInput(request)),
          ],
          maxOutputTokens: _policy.maxPublicAnswerCharacters,
          metadata: const {
            'surface': 'group-chat-summary',
            'tools': 'disabled',
            'privateMemory': 'disabled',
          },
          cancellationToken: cancellation,
        ),
        cancellation,
      );
      if (response.finishReason == ChatFinishReason.contentFiltered) {
        await _journal.markOutcomeUnknown(request.idempotencyKey);
        throw const ProviderBackedAgentRuntimeFailure(
          AgentRuntimeFailureCode.contentFiltered,
        );
      }
      if (response.finishReason != ChatFinishReason.completed) {
        await _journal.markOutcomeUnknown(request.idempotencyKey);
        throw const ProviderBackedAgentRuntimeFailure(
          AgentRuntimeFailureCode.malformedOutput,
        );
      }
      final decoded = _decodeEnvelope(response.outputText);
      if (decoded == null) {
        await _journal.markOutcomeUnknown(request.idempotencyKey);
        throw const ProviderBackedAgentRuntimeFailure(
          AgentRuntimeFailureCode.malformedOutput,
        );
      }
      final encoded = decoded.encode();
      await _journal.complete(request.idempotencyKey, publicResult: encoded);
      return encoded;
    } on _RuntimeTimedOut {
      cancellation.cancel();
      await _markUnknown(request.idempotencyKey);
      throw const ProviderBackedAgentRuntimeFailure(
        AgentRuntimeFailureCode.timeout,
      );
    } on ModelRuntimeException catch (error) {
      cancellation.cancel();
      await _markUnknown(request.idempotencyKey);
      throw ProviderBackedAgentRuntimeFailure(_mapModelFailure(error.code));
    } on ProviderBackedAgentRuntimeFailure {
      await _markUnknown(request.idempotencyKey);
      rethrow;
    } on Object {
      cancellation.cancel();
      await _markUnknown(request.idempotencyKey);
      throw const ProviderBackedAgentRuntimeFailure(
        AgentRuntimeFailureCode.retryable,
      );
    }
  }

  Future<ChatResponse> _callWithTimeout(
    ChatRequest request,
    CancellationToken cancellation,
  ) => _modelRuntime
      .chat(request)
      .timeout(
        _policy.requestTimeout,
        onTimeout: () {
          cancellation.cancel();
          throw const _RuntimeTimedOut();
        },
      );

  Future<void> _markUnknown(String idempotencyKey) async {
    try {
      await _journal.markOutcomeUnknown(idempotencyKey);
    } on StateError {
      // A terminal journal transition is intentionally never reopened.
    }
  }

  String _expertSystemPrompt(ExecutableExpert expert) =>
      '${expert.profile.promptPackage.render()}\n\n'
      'P0 runtime policy: tools are disabled; private memory is unavailable; do not request credentials. '
      'Completed facts require trusted receipts and are unsupported in P0.\n'
      // Without the explicit template and verb allowlist a real provider
      // returns non-conforming JSON and the whole turn is dropped silently.
      '${renderExpertOutputPrompt(expert)}';

  String _participantInput(String input, List<String> previousResponses) {
    final shared = _bounded(
      _redact(input: previousResponses.join('\n')),
      _policy.maxSharedContextCharacters,
    );
    final current = _bounded(
      _redact(input: input),
      _policy.maxSharedContextCharacters,
    );
    return [
      if (shared.isNotEmpty) '公开共享上下文：\n$shared',
      '当前用户问题：$current',
    ].join('\n\n');
  }

  String _summaryInput(DiscussionSummaryRequest request) {
    final outcomes = request.outcomes
        .map((outcome) => '${outcome.agentId}：${outcome.text ?? '未获得公开结论'}')
        .join('\n');
    return _bounded(
      _redact(input: '原始问题：${request.input}\n公开讨论：\n$outcomes'),
      _policy.maxSharedContextCharacters,
    );
  }

  TruthfulOutputEnvelope? _projectExpertResponse(
    ExecutableExpert expert,
    ChatResponse response,
  ) {
    if (response.finishReason == ChatFinishReason.contentFiltered) {
      throw const ProviderBackedAgentRuntimeFailure(
        AgentRuntimeFailureCode.contentFiltered,
      );
    }
    if (response.finishReason != ChatFinishReason.completed) return null;
    try {
      final decoded = jsonDecode(
        _unwrapModelJsonObjectText(response.outputText),
      );
      if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
        return null;
      }
      final output = Map<String, Object?>.from(decoded);
      final projected = expert.validateAndProject(output);
      if (projected == null ||
          projected.length > _policy.maxPublicAnswerCharacters) {
        return null;
      }
      return TruthfulOutputEnvelope(
        answer: projected,
        uncertainty: 'unverified',
        evidenceReferences: const [],
      );
    } on FormatException {
      return null;
    }
  }

  TruthfulOutputEnvelope? _decodeEnvelope(String raw) {
    try {
      return TruthfulOutputEnvelope.decode(
        jsonDecode(_unwrapModelJsonObjectText(raw)),
        maxAnswerCharacters: _policy.maxPublicAnswerCharacters,
      );
    } on FormatException {
      return null;
    }
  }

  static String _bounded(String value, int maximum) =>
      value.length <= maximum ? value : value.substring(0, maximum);

  static String _redact({required String input}) => _redactPublicText(input);

  static AgentRuntimeFailureCode _mapModelFailure(ModelRuntimeErrorCode code) =>
      switch (code) {
        ModelRuntimeErrorCode.insufficientBalance ||
        ModelRuntimeErrorCode.rateLimited =>
          AgentRuntimeFailureCode.quotaExceeded,
        ModelRuntimeErrorCode.contentRejected =>
          AgentRuntimeFailureCode.contentFiltered,
        ModelRuntimeErrorCode.streamInterrupted =>
          AgentRuntimeFailureCode.cancelled,
        _ => AgentRuntimeFailureCode.retryable,
      };
}

final class _RuntimeTimedOut implements Exception {
  const _RuntimeTimedOut();
}

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

String _redactPublicText(String value) => value
    .replaceAll(
      RegExp(r'\bsk-[A-Za-z0-9_-]{12,}\b', caseSensitive: false),
      '[redacted]',
    )
    .replaceAll(
      RegExp(
        r'\b(?:api[_ -]?key|password|token|credential)\s*[:=]\s*\S+',
        caseSensitive: false,
      ),
      '[redacted]',
    )
    .replaceAll(
      RegExp(
        r'authorization\s*:\s*(?:bearer|basic)\s+\S+',
        caseSensitive: false,
      ),
      '[redacted]',
    );
