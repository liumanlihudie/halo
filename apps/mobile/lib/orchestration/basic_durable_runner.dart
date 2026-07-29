import 'dart:async';

import 'package:halo_mobile/orchestration/orchestration_kernel.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';
import 'package:halo_mobile/orchestration/run_event_store.dart';

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
  });

  final String runId;
  final String conversationId;
  final String agentId;
  final String input;
  final List<String> previousResponses;
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
  });

  final String runId;
  final String conversationId;
  final String input;
  final List<AgentTurnOutcome> outcomes;

  List<String> get responses => outcomes
      .where((outcome) => outcome.text != null)
      .map((outcome) => outcome.text!)
      .toList(growable: false);
}

abstract interface class AgentRuntime {
  Future<String> respond(AgentTurnRequest request);

  Future<String> summarize(DiscussionSummaryRequest request);
}

class BasicDurableRunner implements OrchestrationKernel {
  factory BasicDurableRunner({
    required RunEventStore store,
    required AgentSelector selector,
    required AgentRuntime runtime,
  }) => BasicDurableRunner._(store, selector, runtime);

  BasicDurableRunner._(this._store, this._selector, this._runtime);

  final RunEventStore _store;
  final AgentSelector _selector;
  final AgentRuntime _runtime;
  final _stopRequested = <String>{};

  @override
  Future<RunHandle> startRun(StartConversationRunCommand command) async {
    final frozenCommand = StartConversationRunCommand(
      clientCommandId: command.clientCommandId,
      conversationId: command.conversationId,
      hostAgentId: command.hostAgentId,
      input: command.input,
      replyMode: command.replyMode,
      memberAgentIds: List.unmodifiable(List.of(command.memberAgentIds)),
      mentionedAgentIds: List.unmodifiable(List.of(command.mentionedAgentIds)),
    );
    _validateCommand(frozenCommand);
    final creation = _store.createRun(frozenCommand);
    if (!creation.created) {
      return RunHandle(
        runId: creation.snapshot.runId,
        status: creation.snapshot.status,
      );
    }

    final runId = creation.snapshot.runId;
    _store.append(
      runId: runId,
      type: OrchestrationEventType.runCreated,
      stage: ConversationStage.preparing,
    );
    unawaited(Future<void>(() => _execute(runId, frozenCommand)));
    return RunHandle(runId: runId, status: OrchestrationRunStatus.running);
  }

  Future<void> _execute(
    String runId,
    StartConversationRunCommand command,
  ) async {
    try {
      if (_isStopped(runId)) return;
      _store.append(
        runId: runId,
        type: OrchestrationEventType.stageChanged,
        stage: ConversationStage.selectingAgents,
      );
      final selected = switch (command.replyMode) {
        ConversationReplyMode.auto => await _selectAuto(command),
        ConversationReplyMode.mentioned =>
          command.mentionedAgentIds.toSet().toList(),
        ConversationReplyMode.all => List<String>.from(command.memberAgentIds),
      };
      if (_isStopped(runId)) return;
      final responseStage = command.replyMode == ConversationReplyMode.all
          ? ConversationStage.collectingOpinions
          : ConversationStage.responding;
      _store.updateRun(runId: runId, executableAgentIds: selected);
      _store.append(
        runId: runId,
        type: OrchestrationEventType.agentsSelected,
        stage: responseStage,
        selectedAgentIds: selected,
      );
      _store.append(
        runId: runId,
        type: OrchestrationEventType.stageChanged,
        stage: responseStage,
        selectedAgentIds: selected,
      );

      final outcomes = <AgentTurnOutcome>[];
      for (final agentId in selected) {
        if (_isStopped(runId)) {
          return;
        }
        _store.append(
          runId: runId,
          type: OrchestrationEventType.agentMessageStarted,
          stage: responseStage,
          agentId: agentId,
        );
        try {
          final response = await _runtime.respond(
            AgentTurnRequest(
              runId: runId,
              conversationId: command.conversationId,
              agentId: agentId,
              input: command.input,
              previousResponses: List.unmodifiable(
                outcomes
                    .where((outcome) => outcome.text != null)
                    .map((outcome) => outcome.text!),
              ),
            ),
          );
          if (_isStopped(runId)) {
            return;
          }
          outcomes.add(AgentTurnOutcome(agentId: agentId, text: response));
          _store.append(
            runId: runId,
            type: OrchestrationEventType.agentMessageCompleted,
            stage: responseStage,
            agentId: agentId,
            text: response,
          );
        } on Object {
          if (_isStopped(runId)) return;
          if (command.replyMode != ConversationReplyMode.all) {
            _store.append(
              runId: runId,
              type: OrchestrationEventType.agentMessageFailed,
              stage: responseStage,
              agentId: agentId,
              text: '专家暂时无法回答',
              errorCode: 'agent_runtime_failed',
            );
            throw const _SafeOrchestrationFailure();
          }
          outcomes.add(
            AgentTurnOutcome(
              agentId: agentId,
              errorCode: 'agent_runtime_failed',
            ),
          );
          _store.append(
            runId: runId,
            type: OrchestrationEventType.agentMessageFailed,
            stage: responseStage,
            agentId: agentId,
            text: '专家暂时无法回答',
            errorCode: 'agent_runtime_failed',
          );
        }
      }
      if (_isStopped(runId)) {
        return;
      }
      if (command.replyMode == ConversationReplyMode.all) {
        _store.append(
          runId: runId,
          type: OrchestrationEventType.stageChanged,
          stage: ConversationStage.crossDiscussion,
        );
        if (_isStopped(runId)) return;
        _store.append(
          runId: runId,
          type: OrchestrationEventType.stageChanged,
          stage: ConversationStage.summarizing,
        );
        final summary = await _runtime.summarize(
          DiscussionSummaryRequest(
            runId: runId,
            conversationId: command.conversationId,
            input: command.input,
            outcomes: List.unmodifiable(outcomes),
          ),
        );
        if (_isStopped(runId)) return;
        _store.append(
          runId: runId,
          type: OrchestrationEventType.summaryCompleted,
          stage: ConversationStage.summarizing,
          text: summary,
        );
      }
      if (_isStopped(runId)) return;
      _store.updateRun(runId: runId, status: OrchestrationRunStatus.completed);
      _store.append(
        runId: runId,
        type: OrchestrationEventType.stageChanged,
        stage: ConversationStage.completed,
      );
      _store.append(
        runId: runId,
        type: OrchestrationEventType.runCompleted,
        stage: ConversationStage.completed,
      );
    } on Object {
      if (_isStopped(runId)) return;
      _store.updateRun(runId: runId, status: OrchestrationRunStatus.failed);
      _store.append(
        runId: runId,
        type: OrchestrationEventType.runFailed,
        stage: ConversationStage.failed,
        text: '编排运行失败，请稍后重试',
        errorCode: 'orchestration_failed',
      );
    }
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
    if (selected.isEmpty) {
      selected.add(command.hostAgentId);
    }
    return selected;
  }

  bool _isStopped(String runId) {
    if (_stopRequested.contains(runId)) return true;
    return _store.getRun(runId).status == OrchestrationRunStatus.stopped;
  }

  void _validateCommand(StartConversationRunCommand command) {
    if (command.clientCommandId.trim().isEmpty ||
        command.conversationId.trim().isEmpty ||
        command.input.trim().isEmpty) {
      throw ArgumentError('Command identifiers and input must not be empty');
    }
    if (command.memberAgentIds.isEmpty || command.memberAgentIds.length > 8) {
      throw ArgumentError('A run requires between 1 and 8 group members');
    }
    if (command.memberAgentIds.toSet().length !=
        command.memberAgentIds.length) {
      throw ArgumentError('Group member IDs must be unique');
    }
    if (!command.memberAgentIds.contains(command.hostAgentId)) {
      throw ArgumentError('Host Agent must be a current group member');
    }
    if (command.replyMode == ConversationReplyMode.mentioned) {
      final mentioned = command.mentionedAgentIds.toSet();
      if (mentioned.isEmpty || mentioned.length > 4) {
        throw ArgumentError('Mentioned mode requires between 1 and 4 agents');
      }
      if (!mentioned.every(command.memberAgentIds.contains)) {
        throw ArgumentError('Mentioned agents must be current group members');
      }
    }
  }

  @override
  Future<RunSnapshot> getRun(String runId) async => _store.getRun(runId);

  @override
  Future<void> requestStop(String runId) async {
    final snapshot = _store.getRun(runId);
    if (snapshot.status != OrchestrationRunStatus.running) {
      return;
    }
    _stopRequested.add(runId);
    _store.updateRun(runId: runId, status: OrchestrationRunStatus.stopped);
    _store.append(
      runId: runId,
      type: OrchestrationEventType.runStopped,
      stage: ConversationStage.stopped,
    );
  }

  @override
  Future<ResumeResult> resumeRun(String runId) async {
    _store.getRun(runId);
    return ResumeResult(runId: runId, resumed: false);
  }

  @override
  Stream<OrchestrationEvent> watchRun(String runId, {int afterSeq = 0}) {
    return _store.watch(runId, afterSeq: afterSeq);
  }
}

class _SafeOrchestrationFailure implements Exception {
  const _SafeOrchestrationFailure();
}
