import 'dart:convert';

import 'package:crypto/crypto.dart';
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

enum RunCheckpoint {
  created,
  selectingAgents,
  responding,
  summarizing,
  finalizing,
  terminal,
}

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

enum PublicEventTextProvenance { trustedApplication, modelOutput }

@immutable
class PublicEventText {
  const PublicEventText._(this.value, this.provenance);

  factory PublicEventText.trustedApplication(String value) {
    return PublicEventText._(
      value,
      PublicEventTextProvenance.trustedApplication,
    );
  }

  factory PublicEventText.fromModelOutput(String value) {
    var redacted = value;
    final patterns = <RegExp>[
      RegExp(
        r'authorization\s*:\s*(?:bearer|basic)\s+\S+',
        caseSensitive: false,
      ),
      RegExp(r'\bbearer\s+\S+', caseSensitive: false),
      RegExp(r'\bsk-[A-Za-z0-9_-]{12,}\b', caseSensitive: false),
      RegExp(
        r'\b(?:password|token|credential|api[_-]?key)\s*[:=]\s*\S+',
        caseSensitive: false,
      ),
      RegExp(r'\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b'),
      RegExp(r'\b[A-Fa-f0-9]{40,}\b'),
      RegExp(r'\b[A-Za-z0-9+/]{32,}={0,2}\b'),
    ];
    for (final pattern in patterns) {
      redacted = redacted.replaceAll(pattern, '[REDACTED]');
    }
    if (redacted.length > 4096) {
      redacted = redacted.substring(0, 4096);
    }
    return PublicEventText._(redacted, PublicEventTextProvenance.modelOutput);
  }

  final String value;
  final PublicEventTextProvenance provenance;

  Map<String, Object?> toJson() => {
    'value': value,
    'provenance': provenance.name,
  };

  factory PublicEventText.fromJson(Map<String, Object?> json) {
    return PublicEventText._(
      json['value']! as String,
      PublicEventTextProvenance.values.byName(json['provenance']! as String),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PublicEventText &&
      value == other.value &&
      provenance == other.provenance;

  @override
  int get hashCode => Object.hash(value, provenance);

  @override
  String toString() => value;
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
    this.inputRef,
    this.contextRef,
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
      inputRef: json['inputRef'] as String?,
      contextRef: json['contextRef'] as String?,
    );
  }

  final String clientCommandId;
  final String conversationId;
  final String hostAgentId;
  final String input;
  final ConversationReplyMode replyMode;
  final List<String> memberAgentIds;
  final List<String> mentionedAgentIds;
  final String? inputRef;
  final String? contextRef;

  String get requestHash {
    final identity = jsonEncode({
      'conversationId': conversationId,
      'hostAgentId': hostAgentId,
      'inputRef': inputRef,
      'inputHash': sha256.convert(utf8.encode(input)).toString(),
      'contextRef': contextRef,
      'replyMode': replyMode.name,
      'memberAgentIds': memberAgentIds,
      'mentionedAgentIds': mentionedAgentIds,
    });
    return sha256.convert(utf8.encode(identity)).toString();
  }

  Map<String, Object?> toJson() => {
    'clientCommandId': clientCommandId,
    'conversationId': conversationId,
    'hostAgentId': hostAgentId,
    'input': input,
    'replyMode': replyMode.name,
    'memberAgentIds': memberAgentIds,
    'mentionedAgentIds': mentionedAgentIds,
    'inputRef': inputRef,
    'contextRef': contextRef,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StartConversationRunCommand &&
          clientCommandId == other.clientCommandId &&
          conversationId == other.conversationId &&
          hostAgentId == other.hostAgentId &&
          input == other.input &&
          inputRef == other.inputRef &&
          contextRef == other.contextRef &&
          replyMode == other.replyMode &&
          listEquals(memberAgentIds, other.memberAgentIds) &&
          listEquals(mentionedAgentIds, other.mentionedAgentIds);

  @override
  int get hashCode => Object.hash(
    clientCommandId,
    conversationId,
    hostAgentId,
    input,
    inputRef,
    contextRef,
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
    PublicEventText? text,
    this.selectedAgentIds = const [],
    this.errorCode,
    this.causationId = '',
    this.dedupeKey = '',
  }) : publicText = text;

  factory OrchestrationEvent.fromJson(Map<String, Object?> json) {
    return OrchestrationEvent(
      eventId: json['eventId']! as String,
      runId: json['runId']! as String,
      seq: json['seq']! as int,
      type: OrchestrationEventType.values.byName(json['type']! as String),
      stage: ConversationStage.values.byName(json['stage']! as String),
      agentId: json['agentId'] as String?,
      text: switch (json['text']) {
        final Map<String, Object?> value => PublicEventText.fromJson(value),
        final Map value => PublicEventText.fromJson(
          Map<String, Object?>.from(value),
        ),
        _ => null,
      },
      selectedAgentIds: List<String>.from(json['selectedAgentIds']! as List),
      errorCode: json['errorCode'] as String?,
      causationId: json['causationId'] as String? ?? '',
      dedupeKey: json['dedupeKey'] as String? ?? '',
    );
  }

  final String eventId;
  final String runId;
  final int seq;
  final OrchestrationEventType type;
  final ConversationStage stage;
  final String? agentId;
  final PublicEventText? publicText;
  String? get text => publicText?.value;
  final List<String> selectedAgentIds;
  final String? errorCode;
  final String causationId;
  final String dedupeKey;

  Map<String, Object?> toJson() => {
    'eventId': eventId,
    'runId': runId,
    'seq': seq,
    'type': type.name,
    'stage': stage.name,
    'agentId': agentId,
    'text': publicText?.toJson(),
    'selectedAgentIds': selectedAgentIds,
    'errorCode': errorCode,
    'causationId': causationId,
    'dedupeKey': dedupeKey,
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
          publicText == other.publicText &&
          listEquals(selectedAgentIds, other.selectedAgentIds) &&
          errorCode == other.errorCode &&
          causationId == other.causationId &&
          dedupeKey == other.dedupeKey;

  @override
  int get hashCode => Object.hash(
    eventId,
    runId,
    seq,
    type,
    stage,
    agentId,
    publicText,
    Object.hashAll(selectedAgentIds),
    errorCode,
    causationId,
    dedupeKey,
  );
}
