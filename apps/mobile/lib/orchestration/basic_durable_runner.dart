import 'dart:async';

import 'package:halo_mobile/orchestration/command_validation.dart';
import 'package:halo_mobile/orchestration/orchestration_kernel.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';
import 'package:halo_mobile/orchestration/run_event_store.dart';

var _runnerSerial = 0;

String _nextRunnerId() {
  _runnerSerial++;
  return 'runner-${DateTime.now().microsecondsSinceEpoch}-$_runnerSerial';
}

class AgentSelectionRequest {
  AgentSelectionRequest({
    required this.input,
    required List<String> candidateAgentIds,
  }) : candidateAgentIds = List.unmodifiable(candidateAgentIds);

  final String input;
  final List<String> candidateAgentIds;
}

abstract interface class AgentSelector {
  Future<List<String>> select(AgentSelectionRequest request);
}

class AgentTurnRequest {
  const AgentTurnRequest({
    required this.runId,
    required this.conversationId,
    required this.agentId,
    required this.input,
    required this.previousResponses,
    required this.idempotencyKey,
  });

  final String runId;
  final String conversationId;
  final String agentId;
  final String input;
  final List<String> previousResponses;
  final String idempotencyKey;
}

class AgentTurnOutcome {
  const AgentTurnOutcome({required this.agentId, this.text, this.errorCode});

  final String agentId;
  final String? text;
  final String? errorCode;
}

class DiscussionSummaryRequest {
  const DiscussionSummaryRequest({
    required this.runId,
    required this.conversationId,
    required this.input,
    required this.outcomes,
    required this.idempotencyKey,
  });

  final String runId;
  final String conversationId;
  final String input;
  final List<AgentTurnOutcome> outcomes;
  final String idempotencyKey;

  List<String> get responses => outcomes
      .where((outcome) => outcome.text != null)
      .map((outcome) => outcome.text!)
      .toList(growable: false);
}

abstract interface class AgentRuntime {
  Future<String> respond(AgentTurnRequest request);

  Future<String> summarize(DiscussionSummaryRequest request);
}

abstract interface class IdempotentAgentRuntimeCapability {
  bool get supportsIdempotency;
}

enum DurableRunnerFailurePoint { afterExternalCallReturnedBeforeReceipt }

class DurableRunnerCrash implements Exception {
  const DurableRunnerCrash();
}

typedef DurableRunnerFailureInjector =
    void Function(DurableRunnerFailurePoint point);

abstract interface class RunInputResolver {
  Future<String> resolve({required String inputRef, String? contextRef});
}

class BasicDurableRunner implements OrchestrationKernel {
  factory BasicDurableRunner({
    required RunEventStore store,
    required AgentSelector selector,
    required AgentRuntime runtime,
    RunInputResolver? inputResolver,
    String? runnerId,
    DateTime Function()? clock,
    Duration externalCallLeaseDuration = const Duration(seconds: 30),
    DurableRunnerFailureInjector? failureInjector,
  }) => BasicDurableRunner._(
    store,
    selector,
    runtime,
    inputResolver,
    runnerId ?? _nextRunnerId(),
    clock ?? DateTime.now,
    externalCallLeaseDuration,
    failureInjector,
  );

  BasicDurableRunner._(
    this._store,
    this._selector,
    this._runtime,
    this._inputResolver,
    this._runnerId,
    this._clock,
    this._externalCallLeaseDuration,
    this._failureInjector,
  );

  final RunEventStore _store;
  final AgentSelector _selector;
  final AgentRuntime _runtime;
  final RunInputResolver? _inputResolver;
  final String _runnerId;
  final DateTime Function() _clock;
  final Duration _externalCallLeaseDuration;
  final DurableRunnerFailureInjector? _failureInjector;
  final _stopRequested = <String>{};
  final _activeRuns = <String>{};
  final _scheduledTasks = <String, Future<void>>{};
  final _ephemeralCommands = <String, StartConversationRunCommand>{};
  Future<void>? _shutdownFuture;
  var _shuttingDown = false;

  @override
  Future<RunHandle> startRun(StartConversationRunCommand command) async {
    _ensureAcceptingRuns();
    _ensureRuntimeCapability();
    final frozenCommand = _freeze(command);
    StartConversationCommandValidator.validate(frozenCommand);
    if (_store.requiresRecoveryReferences &&
        (_inputResolver == null ||
            frozenCommand.inputRef == null ||
            frozenCommand.inputRef!.trim().isEmpty)) {
      throw ArgumentError(
        'Durable runs require an inputRef and a RunInputResolver',
      );
    }
    final creation = _store.createRun(frozenCommand);
    final runId = creation.snapshot.runId;
    _ephemeralCommands[runId] = frozenCommand;
    if (creation.snapshot.status == OrchestrationRunStatus.running) {
      _schedule(runId, frozenCommand);
    }
    return RunHandle(runId: runId, status: creation.snapshot.status);
  }

  void _schedule(String runId, StartConversationRunCommand command) {
    if (_shuttingDown) return;
    if (!_activeRuns.add(runId)) return;
    final task = _runScheduled(runId, command);
    _scheduledTasks[runId] = task;
    unawaited(task);
  }

  Future<void> _runScheduled(
    String runId,
    StartConversationRunCommand command,
  ) async {
    try {
      if (_shuttingDown) return;
      await _execute(runId, command);
    } on Object {
      // This is the final boundary for an intentionally unawaited task.
      // _execute persists safe failures while the runner is live; shutdown
      // must never leak a late asynchronous error.
      return;
    } finally {
      _activeRuns.remove(runId);
      _scheduledTasks.remove(runId);
    }
  }

  Future<void> _execute(
    String runId,
    StartConversationRunCommand command,
  ) async {
    try {
      if (_shuttingDown) return;
      var work = _store.getWorkItem(runId);
      if (work.checkpoint == RunCheckpoint.terminal || _isStopped(runId)) {
        return;
      }

      if (work.checkpoint == RunCheckpoint.created) {
        _commit(
          runId,
          eventType: OrchestrationEventType.stageChanged,
          stage: ConversationStage.selectingAgents,
          dedupeKey: 'stage-selecting',
          checkpoint: RunCheckpoint.selectingAgents,
        );
        work = _store.getWorkItem(runId);
      }

      if (work.checkpoint == RunCheckpoint.selectingAgents) {
        final selected = switch (command.replyMode) {
          ConversationReplyMode.auto => await _selectAuto(command),
          ConversationReplyMode.mentioned =>
            command.mentionedAgentIds.toSet().toList(),
          ConversationReplyMode.all => List<String>.from(
            command.memberAgentIds,
          ),
        };
        if (_shuttingDown) return;
        if (_isStopped(runId)) return;
        final responseStage = _responseStage(command.replyMode);
        _commit(
          runId,
          eventType: OrchestrationEventType.agentsSelected,
          stage: responseStage,
          dedupeKey: 'agents-selected',
          selectedAgentIds: selected,
          executableAgentIds: selected,
          checkpoint: RunCheckpoint.responding,
          nextAgentIndex: 0,
        );
        _commit(
          runId,
          eventType: OrchestrationEventType.stageChanged,
          stage: responseStage,
          dedupeKey: 'stage-responding',
        );
        work = _store.getWorkItem(runId);
      }

      if (work.checkpoint == RunCheckpoint.responding) {
        await _continueResponses(runId, command, work);
        if (_shuttingDown) return;
        work = _store.getWorkItem(runId);
      }

      if (work.checkpoint == RunCheckpoint.summarizing) {
        final outcomes = _restoreOutcomes(runId);
        final summary = await _invokeSummary(
          runId,
          command,
          List.unmodifiable(outcomes),
        );
        if (_shuttingDown) return;
        if (summary == null) return;
        if (_isStopped(runId)) return;
        _commit(
          runId,
          eventType: OrchestrationEventType.summaryCompleted,
          stage: ConversationStage.summarizing,
          dedupeKey: 'summary-completed',
          text: summary,
          checkpoint: RunCheckpoint.finalizing,
        );
        work = _store.getWorkItem(runId);
      }

      if (work.checkpoint == RunCheckpoint.finalizing) {
        _commit(
          runId,
          eventType: OrchestrationEventType.runCompleted,
          stage: ConversationStage.completed,
          dedupeKey: 'run-completed',
          newStatus: OrchestrationRunStatus.completed,
          checkpoint: RunCheckpoint.terminal,
        );
      }
    } on DurableRunnerCrash {
      return;
    } on ExternalCallLeaseLost {
      return;
    } on TransitionConflict {
      return;
    } on Object {
      if (_shuttingDown) return;
      if (_isStopped(runId)) return;
      final snapshot = _store.getRun(runId);
      if (snapshot.status != OrchestrationRunStatus.running) return;
      try {
        _commit(
          runId,
          eventType: OrchestrationEventType.runFailed,
          stage: ConversationStage.failed,
          dedupeKey: 'run-failed',
          text: PublicEventText.trustedApplication('编排运行失败，请稍后重试'),
          errorCode: 'orchestration_failed',
          newStatus: OrchestrationRunStatus.failed,
          checkpoint: RunCheckpoint.terminal,
        );
      } on TransitionConflict {
        return;
      }
    }
  }

  Future<void> _continueResponses(
    String runId,
    StartConversationRunCommand command,
    RunWorkItem work,
  ) async {
    final selected = _store.getRun(runId).executableAgentIds;
    final outcomes = _restoreOutcomes(runId);
    final responseStage = _responseStage(command.replyMode);

    for (var index = work.nextAgentIndex; index < selected.length; index++) {
      if (_isStopped(runId)) return;
      final agentId = selected[index];
      _commit(
        runId,
        eventType: OrchestrationEventType.agentMessageStarted,
        stage: responseStage,
        dedupeKey: 'agent-started-$index',
        agentId: agentId,
      );
      try {
        final response = await _invokeResponse(
          runId,
          index,
          agentId,
          command,
          List.unmodifiable(
            outcomes
                .where((outcome) => outcome.text != null)
                .map((outcome) => outcome.text!),
          ),
        );
        if (_shuttingDown) return;
        if (response == null) return;
        if (_isStopped(runId)) return;
        outcomes.add(AgentTurnOutcome(agentId: agentId, text: response.value));
        _commit(
          runId,
          eventType: OrchestrationEventType.agentMessageCompleted,
          stage: responseStage,
          dedupeKey: 'agent-completed-$index',
          agentId: agentId,
          text: response,
          checkpoint: RunCheckpoint.responding,
          nextAgentIndex: index + 1,
        );
      } on DurableRunnerCrash {
        rethrow;
      } on ExternalCallLeaseLost {
        rethrow;
      } on Object {
        if (_shuttingDown) return;
        if (_isStopped(runId)) return;
        outcomes.add(
          AgentTurnOutcome(agentId: agentId, errorCode: 'agent_runtime_failed'),
        );
        _commit(
          runId,
          eventType: OrchestrationEventType.agentMessageFailed,
          stage: responseStage,
          dedupeKey: 'agent-failed-$index',
          agentId: agentId,
          text: PublicEventText.trustedApplication('专家暂时无法回答'),
          errorCode: 'agent_runtime_failed',
          checkpoint: RunCheckpoint.responding,
          nextAgentIndex: index + 1,
        );
        if (command.replyMode != ConversationReplyMode.all) {
          throw const _SafeOrchestrationFailure();
        }
      }
    }
    if (_isStopped(runId)) return;

    if (command.replyMode == ConversationReplyMode.all) {
      _commit(
        runId,
        eventType: OrchestrationEventType.stageChanged,
        stage: ConversationStage.crossDiscussion,
        dedupeKey: 'stage-cross-discussion',
      );
      _commit(
        runId,
        eventType: OrchestrationEventType.stageChanged,
        stage: ConversationStage.summarizing,
        dedupeKey: 'stage-summarizing',
        checkpoint: RunCheckpoint.summarizing,
      );
    } else {
      _commit(
        runId,
        eventType: OrchestrationEventType.runCompleted,
        stage: ConversationStage.completed,
        dedupeKey: 'run-completed',
        newStatus: OrchestrationRunStatus.completed,
        checkpoint: RunCheckpoint.terminal,
      );
    }
  }

  TransitionCommit _commit(
    String runId, {
    required OrchestrationEventType eventType,
    required ConversationStage stage,
    required String dedupeKey,
    OrchestrationRunStatus? newStatus,
    String? agentId,
    PublicEventText? text,
    List<String> selectedAgentIds = const [],
    String? errorCode,
    List<String>? executableAgentIds,
    RunCheckpoint? checkpoint,
    int? nextAgentIndex,
  }) {
    final snapshot = _store.getRun(runId);
    return _store.commitTransition(
      RunTransitionRequest(
        runId: runId,
        expectedLastSeq: snapshot.lastSeq,
        expectedStatus: snapshot.status,
        causationId: '$runId:$dedupeKey',
        dedupeKey: dedupeKey,
        eventType: eventType,
        stage: stage,
        newStatus: newStatus,
        agentId: agentId,
        text: text,
        selectedAgentIds: selectedAgentIds,
        errorCode: errorCode,
        executableAgentIds: executableAgentIds,
        checkpoint: checkpoint,
        nextAgentIndex: nextAgentIndex,
      ),
    );
  }

  List<AgentTurnOutcome> _restoreOutcomes(String runId) {
    final byAgent = <String, AgentTurnOutcome>{};
    for (final event in _store.loadEvents(runId)) {
      final agentId = event.agentId;
      if (agentId == null) continue;
      if (event.type == OrchestrationEventType.agentMessageCompleted) {
        byAgent[agentId] = AgentTurnOutcome(agentId: agentId, text: event.text);
      } else if (event.type == OrchestrationEventType.agentMessageFailed) {
        byAgent[agentId] = AgentTurnOutcome(
          agentId: agentId,
          errorCode: event.errorCode,
        );
      }
    }
    return [
      for (final agentId in _store.getRun(runId).executableAgentIds)
        ?byAgent[agentId],
    ];
  }

  Future<List<String>> _selectAuto(StartConversationRunCommand command) async {
    List<String> requested;
    try {
      requested = await _selector.select(
        AgentSelectionRequest(
          input: command.input,
          candidateAgentIds: command.memberAgentIds,
        ),
      );
    } on Object {
      requested = [command.hostAgentId];
    }
    final selected = requested
        .where(command.memberAgentIds.contains)
        .toSet()
        .take(2)
        .toList();
    if (selected.isEmpty) selected.add(command.hostAgentId);
    return selected;
  }

  ConversationStage _responseStage(ConversationReplyMode mode) {
    return mode == ConversationReplyMode.all
        ? ConversationStage.collectingOpinions
        : ConversationStage.responding;
  }

  bool _isStopped(String runId) {
    if (_shuttingDown) return true;
    if (_stopRequested.contains(runId)) return true;
    return _store.getRun(runId).status == OrchestrationRunStatus.stopped;
  }

  StartConversationRunCommand _freeze(StartConversationRunCommand command) {
    return StartConversationRunCommand(
      clientCommandId: command.clientCommandId,
      conversationId: command.conversationId,
      hostAgentId: command.hostAgentId,
      input: command.input,
      inputRef: command.inputRef,
      contextRef: command.contextRef,
      replyMode: command.replyMode,
      memberAgentIds: List.unmodifiable(List.of(command.memberAgentIds)),
      mentionedAgentIds: List.unmodifiable(List.of(command.mentionedAgentIds)),
    );
  }

  @override
  Future<RunSnapshot> getRun(String runId) async => _store.getRun(runId);

  @override
  Future<void> requestStop(String runId) async {
    _ensureAcceptingRuns();
    final snapshot = _store.getRun(runId);
    if (snapshot.status != OrchestrationRunStatus.running) return;
    _stopRequested.add(runId);
    try {
      _commit(
        runId,
        eventType: OrchestrationEventType.runStopped,
        stage: ConversationStage.stopped,
        dedupeKey: 'run-stopped',
        newStatus: OrchestrationRunStatus.stopped,
        checkpoint: RunCheckpoint.terminal,
      );
    } on TransitionConflict {
      return;
    }
  }

  @override
  Future<ResumeResult> resumeRun(String runId) async {
    _ensureAcceptingRuns();
    _ensureRuntimeCapability();
    final snapshot = _store.getRun(runId);
    if (snapshot.status != OrchestrationRunStatus.running ||
        _activeRuns.contains(runId)) {
      return ResumeResult(runId: runId, resumed: false);
    }
    var command = _ephemeralCommands[runId];
    if (command == null) {
      final work = _store.getWorkItem(runId);
      final inputRef = work.inputRef;
      final resolver = _inputResolver;
      if (inputRef == null || resolver == null) {
        return ResumeResult(runId: runId, resumed: false);
      }
      final input = await resolver.resolve(
        inputRef: inputRef,
        contextRef: work.contextRef,
      );
      if (_shuttingDown) {
        return ResumeResult(runId: runId, resumed: false);
      }
      command = StartConversationRunCommand(
        clientCommandId: work.clientCommandId,
        conversationId: work.conversationId,
        hostAgentId: work.hostAgentId,
        input: input,
        inputRef: work.inputRef,
        contextRef: work.contextRef,
        replyMode: work.replyMode,
        memberAgentIds: work.memberAgentIds,
        mentionedAgentIds: work.mentionedAgentIds,
      );
      if (command.requestHash != work.requestHash) {
        throw CommandIdentityConflict(work.clientCommandId);
      }
      _ephemeralCommands[runId] = command;
    }
    _schedule(runId, command);
    return ResumeResult(runId: runId, resumed: true);
  }

  @override
  Stream<OrchestrationEvent> watchRun(String runId, {int afterSeq = 0}) {
    return _store.watch(runId, afterSeq: afterSeq);
  }

  Future<PublicEventText?> _invokeResponse(
    String runId,
    int index,
    String agentId,
    StartConversationRunCommand command,
    List<String> previousResponses,
  ) async {
    final intentId = '$runId:respond:$index';
    final intent = _store.ensureExternalCallIntent(
      ExternalCallIntentRequest(
        intentId: intentId,
        idempotencyKey: intentId,
        runId: runId,
        kind: ExternalCallKind.respond,
        agentId: agentId,
      ),
    );
    if (intent.status == ExternalCallStatus.receipted) return intent.result;
    final lease = _store.tryAcquireExternalCallLease(
      intentId: intentId,
      ownerId: _runnerId,
      now: _clock(),
      leaseDuration: _externalCallLeaseDuration,
    );
    if (lease == null) return null;
    final raw = await _runtime.respond(
      AgentTurnRequest(
        runId: runId,
        conversationId: command.conversationId,
        agentId: agentId,
        input: command.input,
        previousResponses: previousResponses,
        idempotencyKey: intentId,
      ),
    );
    if (_shuttingDown) return null;
    _failureInjector?.call(
      DurableRunnerFailurePoint.afterExternalCallReturnedBeforeReceipt,
    );
    return _store
        .recordExternalCallReceipt(
          lease: lease,
          now: _clock(),
          result: PublicEventText.fromModelOutput(raw),
        )
        .result;
  }

  Future<PublicEventText?> _invokeSummary(
    String runId,
    StartConversationRunCommand command,
    List<AgentTurnOutcome> outcomes,
  ) async {
    final intentId = '$runId:summarize';
    final intent = _store.ensureExternalCallIntent(
      ExternalCallIntentRequest(
        intentId: intentId,
        idempotencyKey: intentId,
        runId: runId,
        kind: ExternalCallKind.summarize,
      ),
    );
    if (intent.status == ExternalCallStatus.receipted) return intent.result;
    final lease = _store.tryAcquireExternalCallLease(
      intentId: intentId,
      ownerId: _runnerId,
      now: _clock(),
      leaseDuration: _externalCallLeaseDuration,
    );
    if (lease == null) return null;
    final raw = await _runtime.summarize(
      DiscussionSummaryRequest(
        runId: runId,
        conversationId: command.conversationId,
        input: command.input,
        outcomes: outcomes,
        idempotencyKey: intentId,
      ),
    );
    if (_shuttingDown) return null;
    _failureInjector?.call(
      DurableRunnerFailurePoint.afterExternalCallReturnedBeforeReceipt,
    );
    return _store
        .recordExternalCallReceipt(
          lease: lease,
          now: _clock(),
          result: PublicEventText.fromModelOutput(raw),
        )
        .result;
  }

  Future<void> shutdown() {
    _shuttingDown = true;
    return _shutdownFuture ??= _drainScheduledTasks();
  }

  Future<void> _drainScheduledTasks() async {
    while (_scheduledTasks.isNotEmpty) {
      await Future.wait<void>(List<Future<void>>.of(_scheduledTasks.values));
    }
    _ephemeralCommands.clear();
    _stopRequested.clear();
  }

  void _ensureAcceptingRuns() {
    if (_shuttingDown) {
      throw StateError('BasicDurableRunner is shut down');
    }
  }

  void _ensureRuntimeCapability() {
    if (_store.requiresRecoveryReferences &&
        (_runtime is! IdempotentAgentRuntimeCapability ||
            !(_runtime as IdempotentAgentRuntimeCapability)
                .supportsIdempotency)) {
      throw UnsupportedError(
        'Durable runner requires an idempotent AgentRuntime',
      );
    }
  }
}

class _SafeOrchestrationFailure implements Exception {
  const _SafeOrchestrationFailure();
}
