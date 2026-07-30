// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:dartantic_interface/dartantic_interface.dart' as llm;
import 'package:halo_mobile/app/dartantic_single_chat_port.dart';
import 'package:halo_mobile/experts/expert_output_prompt.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/orchestration/agent_execution_policy.dart';
import 'package:halo_mobile/orchestration/basic_durable_runner.dart';
import 'package:halo_mobile/orchestration/provider_backed_agent_runtime.dart';
import 'package:halo_mobile/orchestration/sqlite_model_call_journal.dart';

/// Group chat turns on dartantic_ai.
///
/// Same shape as single chat — system prompt in, plain text out, nothing that
/// can discard a finished reply — while keeping the two guarantees the group
/// runner depends on: every call passes the SQLite billing fence, and a
/// completed idempotency key replays its original public result instead of
/// paying for a second run.
final class DartanticAgentRuntime
    implements AgentRuntime, IdempotentAgentRuntimeCapability {
  DartanticAgentRuntime({
    required ModelAgentFactory agents,
    required ExecutableExpertRegistry experts,
    required SqliteModelCallJournal journal,
    required AgentExecutionPolicy policy,
  }) : _agents = agents,
       _experts = experts,
       _journal = journal,
       _policy = policy;

  final ModelAgentFactory _agents;
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
    return _billedRun(
      idempotencyKey: request.idempotencyKey,
      model: _policy.modelForExpert(expert.profile.id),
      systemPrompt: _expertSystemPrompt(expert),
      input: _participantInput(request.input, request.previousResponses),
      project: expert.sanitizePlainAnswer,
    );
  }

  @override
  Future<String> summarize(DiscussionSummaryRequest request) => _billedRun(
    idempotencyKey: request.idempotencyKey,
    model: _policy.summarizerModel,
    systemPrompt: _policy.summarizerPrompt.render(),
    input: _summaryInput(request),
    project: (text) => text.trim().isEmpty ? null : text.trim(),
  );

  Future<String> _billedRun({
    required String idempotencyKey,
    required ModelRef model,
    required String systemPrompt,
    required String input,
    required String? Function(String text) project,
  }) async {
    final entry = await _journal.reserve(idempotencyKey);
    if (entry.status == ModelCallStatus.completed) return entry.publicResult!;
    if (entry.status != ModelCallStatus.reserved) {
      throw const ProviderBackedAgentRuntimeFailure(
        AgentRuntimeFailureCode.outcomeUnknown,
      );
    }
    try {
      await _journal.markDispatched(idempotencyKey);
      final agent = await _agents.agentForModel(model);
      final answer = StringBuffer();
      await agent
          .sendStream(input, history: [llm.ChatMessage.system(systemPrompt)])
          .forEach((chunk) => answer.write(chunk.output))
          .timeout(_policy.requestTimeout);
      final projected = project(answer.toString());
      if (projected == null) {
        await _markUnknown(idempotencyKey);
        throw const ProviderBackedAgentRuntimeFailure(
          AgentRuntimeFailureCode.malformedOutput,
        );
      }
      final encoded = TruthfulOutputEnvelope(
        answer: projected,
        uncertainty: 'unverified',
        evidenceReferences: const [],
      ).encode();
      await _journal.complete(idempotencyKey, publicResult: encoded);
      return encoded;
    } on ProviderBackedAgentRuntimeFailure {
      rethrow;
    } on TimeoutException {
      await _markUnknown(idempotencyKey);
      throw const ProviderBackedAgentRuntimeFailure(
        AgentRuntimeFailureCode.timeout,
      );
    } on StateError {
      // No usable provider binding: a configuration gap, never a retry.
      await _markUnknown(idempotencyKey);
      throw const ProviderBackedAgentRuntimeFailure(
        AgentRuntimeFailureCode.unauthorizedExpert,
      );
    } on Object {
      await _markUnknown(idempotencyKey);
      throw const ProviderBackedAgentRuntimeFailure(
        AgentRuntimeFailureCode.retryable,
      );
    }
  }

  Future<void> _markUnknown(String idempotencyKey) async {
    try {
      await _journal.markOutcomeUnknown(idempotencyKey);
    } on StateError {
      // A terminal journal transition is intentionally never reopened.
    }
  }

  String _expertSystemPrompt(ExecutableExpert expert) =>
      '${expert.profile.promptPackage.render()}\n\n'
      'P0 runtime policy: tools are disabled; private memory is unavailable; '
      'do not request credentials. Completed facts require trusted receipts '
      'and are unsupported in P0.\n'
      '${renderExpertOutputPrompt(expert)}';

  String _participantInput(String input, List<String> previousResponses) {
    final shared = _bounded(previousResponses.join('\n'));
    final current = _bounded(input);
    return [
      if (shared.isNotEmpty) '公开共享上下文：\n$shared',
      '当前用户问题：$current',
    ].join('\n\n');
  }

  String _summaryInput(DiscussionSummaryRequest request) {
    final outcomes = request.outcomes
        .map((outcome) => '${outcome.agentId}：${outcome.text ?? '未获得公开结论'}')
        .join('\n');
    return _bounded('原始问题：${request.input}\n公开讨论：\n$outcomes');
  }

  String _bounded(String value) =>
      value.length <= _policy.maxSharedContextCharacters
      ? value
      : value.substring(0, _policy.maxSharedContextCharacters);
}
