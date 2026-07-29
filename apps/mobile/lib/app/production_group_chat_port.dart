import 'package:halo_mobile/experts/expert_prompt_package.dart';
import 'package:halo_mobile/features/group_chat/group_chat_controller.dart';
import 'package:halo_mobile/orchestration/agent_execution_policy.dart';
import 'package:halo_mobile/orchestration/basic_durable_runner.dart';
import 'package:halo_mobile/orchestration/orchestration_kernel.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';
import 'package:halo_mobile/orchestration/provider_backed_agent_runtime.dart';
import 'package:halo_mobile/orchestration/sqlite_model_call_journal.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/provider_registry.dart';

/// Adapts the orchestration kernel to the narrower port the group chat UI needs.
///
/// [GroupChatRunPort] is a strict subset of [OrchestrationKernel]; this exists
/// only so the UI cannot reach `getRun` and the rest of the kernel surface.
final class ProductionGroupChatPort implements GroupChatRunPort {
  const ProductionGroupChatPort(this._kernel);

  final OrchestrationKernel _kernel;

  @override
  Future<RunHandle> startRun(StartConversationRunCommand command) =>
      _kernel.startRun(command);

  @override
  Stream<OrchestrationEvent> watchRun(String runId, {int afterSeq = 0}) =>
      _kernel.watchRun(runId, afterSeq: afterSeq);

  @override
  Future<void> requestStop(String runId) => _kernel.requestStop(runId);

  @override
  Future<ResumeResult> resumeRun(String runId) => _kernel.resumeRun(runId);
}

/// Resolves each group turn's model at the moment the turn runs.
///
/// [AgentExecutionPolicy] holds a frozen override map, but single chat resolves
/// bindings live through `resolveConfiguredModel`. Rebuilding the policy per
/// turn keeps both paths on one source of truth, so a model changed in settings
/// takes effect on the next turn instead of at the next app launch.
final class LiveRoutingAgentRuntime
    implements AgentRuntime, IdempotentAgentRuntimeCapability {
  LiveRoutingAgentRuntime({
    required ChatModelRuntime modelRuntime,
    required ExecutableExpertRegistry experts,
    required SqliteModelCallJournal journal,
    required ProviderConfigurationStore store,
  }) : _modelRuntime = modelRuntime,
       _experts = experts,
       _journal = journal,
       _store = store;

  // ignore_for_file: prefer_initializing_formals

  final ChatModelRuntime _modelRuntime;
  final ExecutableExpertRegistry _experts;
  final SqliteModelCallJournal _journal;
  final ProviderConfigurationStore _store;

  @override
  bool get supportsIdempotency => true;

  @override
  Future<String> respond(AgentTurnRequest request) async =>
      (await _delegate(agentId: request.agentId)).respond(request);

  @override
  Future<String> summarize(DiscussionSummaryRequest request) async =>
      // The summarizer is a separate identity with no per-expert override, so
      // it can only use the global default.
      (await _delegate(agentId: null)).summarize(request);

  /// Resolves the model exactly as single chat does — `override ?? global` —
  /// so a group turn works whenever the equivalent single chat would, including
  /// when only a per-expert model is set and no global default exists.
  Future<ProviderBackedAgentRuntime> _delegate({
    required String? agentId,
  }) async {
    final globalDefault = await _store.loadGlobalDefaultModel();
    final overrides = await _store.loadAgentModelOverrides();
    final effective = agentId == null
        ? globalDefault
        : overrides[agentId] ?? globalDefault;
    if (effective == null) {
      // Same contract as single chat: a missing binding is a configuration gap,
      // never a transient failure the runner should retry.
      throw const ModelRuntimeException(
        code: ModelRuntimeErrorCode.invalidConfiguration,
        safeMessage: '尚未配置默认模型',
        retryable: false,
      );
    }
    return ProviderBackedAgentRuntime(
      modelRuntime: _modelRuntime,
      experts: _experts,
      journal: _journal,
      policy: AgentExecutionPolicy(
        defaultModel: effective,
        summarizerModel: effective,
      ),
    );
  }
}

/// Picks who answers, using each expert's own routing card.
///
/// The prototype selector carried its own keyword table, which did not cover the
/// real member roster, so most members could never be selected in auto mode.
final class RoutingCardAgentSelector implements AgentSelector {
  const RoutingCardAgentSelector(this._experts, {this.maximumSelected = 2});

  final ExecutableExpertRegistry _experts;
  final int maximumSelected;

  @override
  Future<List<String>> select(AgentSelectionRequest request) async {
    final matched = <String>[];
    final clarifying = <String>[];
    for (final agentId in request.candidateAgentIds) {
      final card = _experts.routingCards[agentId];
      if (card == null) continue;
      switch (card.evaluate(request.input)) {
        case RoutingOutcome.match:
          matched.add(agentId);
        case RoutingOutcome.needsClarification:
          clarifying.add(agentId);
        case RoutingOutcome.noMatch:
          break;
      }
    }
    final selected = matched.isNotEmpty ? matched : clarifying;
    // Never answer with nobody: an empty selection would end the run silently.
    final resolved = selected.isNotEmpty
        ? selected
        : request.candidateAgentIds.take(1).toList();
    return resolved.take(maximumSelected).toList(growable: false);
  }
}
