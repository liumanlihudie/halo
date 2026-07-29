import 'package:flutter/foundation.dart';

enum ConversationReplyMode { auto, mentioned, all }

enum ConversationStage {
  preparing,
  selectingAgents,
  responding,
  collectingOpinions,
  crossDiscussion,
  summarizing,
  completed,
  failed,
  stopped,
}

enum OrchestrationRunStatus { running, completed, failed, stopped }

enum OrchestrationEventType {
  runCreated,
  agentsSelected,
  stageChanged,
  agentMessageStarted,
  agentMessageCompleted,
  agentMessageFailed,
  summaryCompleted,
  runCompleted,
  runFailed,
  runStopped,
}

@immutable
class StartConversationRunCommand {
  const StartConversationRunCommand({
    required this.clientCommandId,
    required this.conversationId,
    required this.hostAgentId,
    required this.input,
    required this.replyMode,
    required this.memberAgentIds,
    this.mentionedAgentIds = const [],
  });

  factory StartConversationRunCommand.fromJson(Map<String, Object?> json) {
    return StartConversationRunCommand(
      clientCommandId: json['clientCommandId']! as String,
      conversationId: json['conversationId']! as String,
      hostAgentId: json['hostAgentId']! as String,
      input: json['input']! as String,
      replyMode: ConversationReplyMode.values.byName(
        json['replyMode']! as String,
      ),
      memberAgentIds: List<String>.from(json['memberAgentIds']! as List),
      mentionedAgentIds: List<String>.from(json['mentionedAgentIds']! as List),
    );
  }

  final String clientCommandId;
  final String conversationId;
  final String hostAgentId;
  final String input;
  final ConversationReplyMode replyMode;
  final List<String> memberAgentIds;
  final List<String> mentionedAgentIds;

  Map<String, Object?> toJson() => {
    'clientCommandId': clientCommandId,
    'conversationId': conversationId,
    'hostAgentId': hostAgentId,
    'input': input,
    'replyMode': replyMode.name,
    'memberAgentIds': memberAgentIds,
    'mentionedAgentIds': mentionedAgentIds,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StartConversationRunCommand &&
          clientCommandId == other.clientCommandId &&
          conversationId == other.conversationId &&
          hostAgentId == other.hostAgentId &&
          input == other.input &&
          replyMode == other.replyMode &&
          listEquals(memberAgentIds, other.memberAgentIds) &&
          listEquals(mentionedAgentIds, other.mentionedAgentIds);

  @override
  int get hashCode => Object.hash(
    clientCommandId,
    conversationId,
    hostAgentId,
    input,
    replyMode,
    Object.hashAll(memberAgentIds),
    Object.hashAll(mentionedAgentIds),
  );
}

@immutable
class RunHandle {
  const RunHandle({required this.runId, required this.status});

  final String runId;
  final OrchestrationRunStatus status;
}

@immutable
class RunSnapshot {
  const RunSnapshot({
    required this.runId,
    required this.status,
    required this.lastSeq,
    required this.executableAgentIds,
  });

  final String runId;
  final OrchestrationRunStatus status;
  final int lastSeq;
  final List<String> executableAgentIds;
}

@immutable
class ResumeResult {
  const ResumeResult({required this.runId, required this.resumed});

  final String runId;
  final bool resumed;
}

@immutable
class OrchestrationEvent {
  const OrchestrationEvent({
    required this.eventId,
    required this.runId,
    required this.seq,
    required this.type,
    required this.stage,
    this.agentId,
    this.text,
    this.selectedAgentIds = const [],
    this.errorCode,
  });

  factory OrchestrationEvent.fromJson(Map<String, Object?> json) {
    return OrchestrationEvent(
      eventId: json['eventId']! as String,
      runId: json['runId']! as String,
      seq: json['seq']! as int,
      type: OrchestrationEventType.values.byName(json['type']! as String),
      stage: ConversationStage.values.byName(json['stage']! as String),
      agentId: json['agentId'] as String?,
      text: json['text'] as String?,
      selectedAgentIds: List<String>.from(json['selectedAgentIds']! as List),
      errorCode: json['errorCode'] as String?,
    );
  }

  final String eventId;
  final String runId;
  final int seq;
  final OrchestrationEventType type;
  final ConversationStage stage;
  final String? agentId;
  final String? text;
  final List<String> selectedAgentIds;
  final String? errorCode;

  Map<String, Object?> toJson() => {
    'eventId': eventId,
    'runId': runId,
    'seq': seq,
    'type': type.name,
    'stage': stage.name,
    'agentId': agentId,
    'text': text,
    'selectedAgentIds': selectedAgentIds,
    'errorCode': errorCode,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OrchestrationEvent &&
          eventId == other.eventId &&
          runId == other.runId &&
          seq == other.seq &&
          type == other.type &&
          stage == other.stage &&
          agentId == other.agentId &&
          text == other.text &&
          listEquals(selectedAgentIds, other.selectedAgentIds) &&
          errorCode == other.errorCode;

  @override
  int get hashCode => Object.hash(
    eventId,
    runId,
    seq,
    type,
    stage,
    agentId,
    text,
    Object.hashAll(selectedAgentIds),
    errorCode,
  );
}
