import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:halo_mobile/orchestration/orchestration_kernel.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';

const groupChatMemberAgentIds = <String>[
  'product-manager',
  'interaction-designer',
  'technical-architect',
  'growth-advisor',
];

enum GroupChatMessageStatus { running, completed, failed }

@immutable
class GroupChatAgentMessage {
  const GroupChatAgentMessage({
    required this.agentId,
    required this.text,
    required this.status,
  });

  final String agentId;
  final String text;
  final GroupChatMessageStatus status;

  GroupChatAgentMessage copyWith({
    String? text,
    GroupChatMessageStatus? status,
  }) => GroupChatAgentMessage(
    agentId: agentId,
    text: text ?? this.text,
    status: status ?? this.status,
  );
}

@immutable
class GroupChatTurn {
  const GroupChatTurn({
    required this.input,
    required this.messages,
    required this.status,
    required this.stage,
    this.summary,
    this.errorCode,
  });

  final String input;
  final List<GroupChatAgentMessage> messages;
  final OrchestrationRunStatus status;
  final ConversationStage? stage;
  final String? summary;
  final String? errorCode;
}

class GroupChatController extends ChangeNotifier {
  GroupChatController({required this.kernel, required this.conversationId});

  final OrchestrationKernel kernel;
  final String conversationId;

  StreamSubscription<OrchestrationEvent>? _subscription;
  final List<GroupChatAgentMessage> _messages = [];
  final List<GroupChatTurn> _pastTurns = [];
  final Map<String, int> _activeMessageByAgent = {};

  String? runId;
  String? submittedInput;
  ConversationReplyMode? replyMode;
  ConversationStage? stage;
  OrchestrationRunStatus? status;
  List<String> selectedAgentIds = const [];
  String? summary;
  String? errorCode;
  bool stopRequested = false;
  int _lastSeq = 0;

  List<GroupChatAgentMessage> get messages => List.unmodifiable(_messages);
  List<GroupChatTurn> get pastTurns => List.unmodifiable(_pastTurns);
  bool get isRunning => status == OrchestrationRunStatus.running;

  Future<void> submit({
    required String input,
    required ConversationReplyMode mode,
    List<String> mentionedAgentIds = const [],
  }) async {
    final normalizedInput = input.trim();
    if (normalizedInput.isEmpty || isRunning) return;

    await _subscription?.cancel();
    final previousInput = submittedInput;
    final previousStatus = status;
    if (previousInput != null && previousStatus != null) {
      _pastTurns.add(
        GroupChatTurn(
          input: previousInput,
          messages: List.unmodifiable(List.of(_messages)),
          status: previousStatus,
          stage: stage,
          summary: summary,
          errorCode: errorCode,
        ),
      );
    }
    _messages.clear();
    _activeMessageByAgent.clear();
    runId = null;
    submittedInput = normalizedInput;
    replyMode = mode;
    stage = ConversationStage.preparing;
    status = OrchestrationRunStatus.running;
    selectedAgentIds = const [];
    summary = null;
    errorCode = null;
    stopRequested = false;
    _lastSeq = 0;
    notifyListeners();

    try {
      final handle = await kernel.startRun(
        StartConversationRunCommand(
          clientCommandId:
              '$conversationId-${DateTime.now().microsecondsSinceEpoch}',
          conversationId: conversationId,
          hostAgentId: groupChatMemberAgentIds.first,
          input: normalizedInput,
          replyMode: mode,
          memberAgentIds: groupChatMemberAgentIds,
          mentionedAgentIds: mentionedAgentIds,
        ),
      );
      runId = handle.runId;
      status = handle.status;
      notifyListeners();
      _subscription = kernel
          .watchRun(handle.runId, afterSeq: 0)
          .listen(
            _applyEvent,
            onError: _applyStreamError,
            onDone: _applyStreamDone,
          );
    } on Object {
      status = OrchestrationRunStatus.failed;
      stage = ConversationStage.failed;
      errorCode = 'orchestration_start_failed';
      notifyListeners();
    }
  }

  Future<void> stop() async {
    final activeRunId = runId;
    if (!isRunning || activeRunId == null || stopRequested) return;
    stopRequested = true;
    notifyListeners();
    try {
      await kernel.requestStop(activeRunId);
    } on Object {
      stopRequested = false;
      errorCode = 'orchestration_stop_failed';
      notifyListeners();
    }
  }

  void _applyEvent(OrchestrationEvent event) {
    if (event.runId != runId || event.seq <= _lastSeq) return;
    _lastSeq = event.seq;
    stage = event.stage;

    switch (event.type) {
      case OrchestrationEventType.runCreated:
        status = OrchestrationRunStatus.running;
      case OrchestrationEventType.agentsSelected:
        selectedAgentIds = List.unmodifiable(event.selectedAgentIds);
      case OrchestrationEventType.stageChanged:
        break;
      case OrchestrationEventType.agentMessageStarted:
        final agentId = event.agentId;
        if (agentId != null) {
          _messages.add(
            GroupChatAgentMessage(
              agentId: agentId,
              text: event.text ?? '',
              status: GroupChatMessageStatus.running,
            ),
          );
          _activeMessageByAgent[agentId] = _messages.length - 1;
        }
      case OrchestrationEventType.agentMessageCompleted:
        _finishAgentMessage(event, GroupChatMessageStatus.completed);
      case OrchestrationEventType.agentMessageFailed:
        _finishAgentMessage(event, GroupChatMessageStatus.failed);
      case OrchestrationEventType.summaryCompleted:
        summary = event.text;
      case OrchestrationEventType.runCompleted:
        status = OrchestrationRunStatus.completed;
        stage = ConversationStage.completed;
      case OrchestrationEventType.runFailed:
        _failActiveMessages();
        status = OrchestrationRunStatus.failed;
        stage = ConversationStage.failed;
        errorCode = event.errorCode;
      case OrchestrationEventType.runStopped:
        status = OrchestrationRunStatus.stopped;
        stage = ConversationStage.stopped;
        stopRequested = false;
    }
    notifyListeners();
  }

  void _finishAgentMessage(
    OrchestrationEvent event,
    GroupChatMessageStatus messageStatus,
  ) {
    final agentId = event.agentId;
    if (agentId == null) return;
    final index = _activeMessageByAgent.remove(agentId);
    final text = event.text ?? event.errorCode ?? '';
    if (index == null) {
      _messages.add(
        GroupChatAgentMessage(
          agentId: agentId,
          text: text,
          status: messageStatus,
        ),
      );
      return;
    }
    _messages[index] = _messages[index].copyWith(
      text: text,
      status: messageStatus,
    );
  }

  void _applyStreamError(Object error) {
    _failActiveMessages();
    status = OrchestrationRunStatus.failed;
    stage = ConversationStage.failed;
    errorCode = 'orchestration_stream_failed';
    notifyListeners();
  }

  void _applyStreamDone() {
    if (!isRunning) return;
    _failActiveMessages();
    status = OrchestrationRunStatus.failed;
    stage = ConversationStage.failed;
    errorCode = 'orchestration_stream_closed';
    notifyListeners();
  }

  void _failActiveMessages() {
    for (final index in _activeMessageByAgent.values) {
      _messages[index] = _messages[index].copyWith(
        text: '回答中断',
        status: GroupChatMessageStatus.failed,
      );
    }
    _activeMessageByAgent.clear();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
