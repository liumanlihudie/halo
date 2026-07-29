import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:halo_mobile/orchestration/orchestration_models.dart';

abstract interface class RunEventStore {
  bool get requiresRecoveryReferences;

  ({RunSnapshot snapshot, bool created}) createRun(
    StartConversationRunCommand command,
  );

  TransitionCommit commitTransition(RunTransitionRequest request);

  ExternalCallIntent ensureExternalCallIntent(
    ExternalCallIntentRequest request,
  );

  ExternalCallLease? tryAcquireExternalCallLease({
    required String intentId,
    required String ownerId,
    required DateTime now,
    required Duration leaseDuration,
  });

  ExternalCallIntent recordExternalCallReceipt({
    required ExternalCallLease lease,
    required DateTime now,
    required PublicEventText result,
  });

  ExternalCallIntent getExternalCallIntent(String intentId);

  RunSnapshot getRun(String runId);

  RunWorkItem getWorkItem(String runId);

  List<OrchestrationEvent> loadEvents(String runId, {int afterSeq = 0});

  Stream<OrchestrationEvent> watch(String runId, {int afterSeq = 0});

  Future<void> close();
}

enum ExternalCallKind { respond, summarize }

enum ExternalCallStatus { pending, leased, receipted }

class ExternalCallIntentRequest {
  const ExternalCallIntentRequest({
    required this.intentId,
    required this.idempotencyKey,
    required this.runId,
    required this.kind,
    this.agentId,
  });

  final String intentId;
  final String idempotencyKey;
  final String runId;
  final ExternalCallKind kind;
  final String? agentId;
}

class ExternalCallIntent {
  const ExternalCallIntent({
    required this.intentId,
    required this.idempotencyKey,
    required this.runId,
    required this.kind,
    required this.status,
    required this.attempt,
    required this.fencingToken,
    this.agentId,
    this.ownerId,
    this.leaseExpiresAt,
    this.result,
  });

  final String intentId;
  final String idempotencyKey;
  final String runId;
  final ExternalCallKind kind;
  final ExternalCallStatus status;
  final int attempt;
  final int fencingToken;
  final String? agentId;
  final String? ownerId;
  final DateTime? leaseExpiresAt;
  final PublicEventText? result;
}

class ExternalCallLease {
  const ExternalCallLease({
    required this.intentId,
    required this.ownerId,
    required this.idempotencyKey,
    required this.attempt,
    required this.fencingToken,
    required this.expiresAt,
  });

  final String intentId;
  final String ownerId;
  final String idempotencyKey;
  final int attempt;
  final int fencingToken;
  final DateTime expiresAt;
}

class ExternalCallLeaseLost implements Exception {
  const ExternalCallLeaseLost(this.intentId);

  final String intentId;

  @override
  String toString() => 'External call lease lost: $intentId';
}

class ExternalCallIdentityConflict implements Exception {
  const ExternalCallIdentityConflict(this.identity);

  final String identity;

  @override
  String toString() => 'External call identity conflict: $identity';
}

class RunWorkItem {
  RunWorkItem({
    required this.runId,
    required this.clientCommandId,
    required this.requestHash,
    required this.conversationId,
    required this.hostAgentId,
    required this.replyMode,
    required List<String> memberAgentIds,
    required List<String> mentionedAgentIds,
    required this.inputRef,
    required this.contextRef,
    required this.checkpoint,
    required this.nextAgentIndex,
  }) : memberAgentIds = List.unmodifiable(memberAgentIds),
       mentionedAgentIds = List.unmodifiable(mentionedAgentIds);

  final String runId;
  final String clientCommandId;
  final String requestHash;
  final String conversationId;
  final String hostAgentId;
  final ConversationReplyMode replyMode;
  final List<String> memberAgentIds;
  final List<String> mentionedAgentIds;
  final String? inputRef;
  final String? contextRef;
  final RunCheckpoint checkpoint;
  final int nextAgentIndex;

  RunWorkItem copyWith({RunCheckpoint? checkpoint, int? nextAgentIndex}) {
    return RunWorkItem(
      runId: runId,
      clientCommandId: clientCommandId,
      requestHash: requestHash,
      conversationId: conversationId,
      hostAgentId: hostAgentId,
      replyMode: replyMode,
      memberAgentIds: memberAgentIds,
      mentionedAgentIds: mentionedAgentIds,
      inputRef: inputRef,
      contextRef: contextRef,
      checkpoint: checkpoint ?? this.checkpoint,
      nextAgentIndex: nextAgentIndex ?? this.nextAgentIndex,
    );
  }
}

class RunTransitionRequest {
  RunTransitionRequest({
    required this.runId,
    required this.expectedLastSeq,
    required this.expectedStatus,
    required this.causationId,
    required this.dedupeKey,
    required this.eventType,
    required this.stage,
    this.newStatus,
    this.agentId,
    this.text,
    List<String> selectedAgentIds = const [],
    this.errorCode,
    List<String>? executableAgentIds,
    this.checkpoint,
    this.nextAgentIndex,
  }) : selectedAgentIds = List.unmodifiable(selectedAgentIds),
       executableAgentIds = executableAgentIds == null
           ? null
           : List.unmodifiable(executableAgentIds);

  final String runId;
  final int expectedLastSeq;
  final OrchestrationRunStatus expectedStatus;
  final String causationId;
  final String dedupeKey;
  final OrchestrationEventType eventType;
  final ConversationStage stage;
  final OrchestrationRunStatus? newStatus;
  final String? agentId;
  final PublicEventText? text;
  final List<String> selectedAgentIds;
  final String? errorCode;
  final List<String>? executableAgentIds;
  final RunCheckpoint? checkpoint;
  final int? nextAgentIndex;

  String get identityHash {
    final canonical = jsonEncode({
      'runId': runId,
      'causationId': causationId,
      'dedupeKey': dedupeKey,
      'eventType': eventType.name,
      'stage': stage.name,
      'newStatus': newStatus?.name,
      'agentId': agentId,
      'text': text?.toJson(),
      'selectedAgentIds': selectedAgentIds,
      'errorCode': errorCode,
      'executableAgentIds': executableAgentIds,
      'checkpoint': checkpoint?.name,
      'nextAgentIndex': nextAgentIndex,
    });
    return sha256.convert(utf8.encode(canonical)).toString();
  }
}

class TransitionCommit {
  const TransitionCommit({
    required this.snapshot,
    required this.event,
    required this.committed,
  });

  final RunSnapshot snapshot;
  final OrchestrationEvent event;
  final bool committed;
}

class CommandIdentityConflict implements Exception {
  const CommandIdentityConflict(this.clientCommandId);

  final String clientCommandId;

  @override
  String toString() => 'Command identity conflict: $clientCommandId';
}

class TransitionConflict implements Exception {
  const TransitionConflict(this.runId);

  final String runId;

  @override
  String toString() => 'Transition compare-and-swap conflict: $runId';
}

class TransitionIdentityConflict implements Exception {
  const TransitionIdentityConflict(this.dedupeKey);

  final String dedupeKey;

  @override
  String toString() => 'Transition identity conflict: $dedupeKey';
}

abstract final class TransitionStatePolicy {
  static const _terminalStatuses = {
    OrchestrationRunStatus.completed,
    OrchestrationRunStatus.failed,
    OrchestrationRunStatus.stopped,
  };

  static const _terminalStages = {
    ConversationStage.completed,
    ConversationStage.failed,
    ConversationStage.stopped,
  };

  static void validate({
    required RunSnapshot snapshot,
    required RunWorkItem workItem,
    required RunTransitionRequest request,
    required List<OrchestrationEvent> priorEvents,
  }) {
    if (snapshot.status != OrchestrationRunStatus.running ||
        workItem.checkpoint == RunCheckpoint.terminal) {
      throw TransitionConflict(request.runId);
    }

    final targetStatus = request.newStatus ?? snapshot.status;
    final targetCheckpoint = request.checkpoint ?? workItem.checkpoint;
    final targetExecutable =
        request.executableAgentIds ?? snapshot.executableAgentIds;
    final targetNextAgentIndex =
        request.nextAgentIndex ?? workItem.nextAgentIndex;
    _validateAgentCursor(
      snapshot: snapshot,
      workItem: workItem,
      request: request,
      targetCheckpoint: targetCheckpoint,
      targetExecutable: targetExecutable,
      targetNextAgentIndex: targetNextAgentIndex,
    );

    final expectedTerminal = switch (request.eventType) {
      OrchestrationEventType.runCompleted => (
        status: OrchestrationRunStatus.completed,
        stage: ConversationStage.completed,
      ),
      OrchestrationEventType.runFailed => (
        status: OrchestrationRunStatus.failed,
        stage: ConversationStage.failed,
      ),
      OrchestrationEventType.runStopped => (
        status: OrchestrationRunStatus.stopped,
        stage: ConversationStage.stopped,
      ),
      _ => null,
    };

    if (expectedTerminal != null) {
      if (targetStatus != expectedTerminal.status ||
          request.stage != expectedTerminal.stage ||
          request.checkpoint != RunCheckpoint.terminal ||
          targetCheckpoint != RunCheckpoint.terminal) {
        throw TransitionConflict(request.runId);
      }
      if (request.eventType == OrchestrationEventType.runCompleted &&
          !((workItem.replyMode == ConversationReplyMode.all &&
                  workItem.checkpoint == RunCheckpoint.finalizing) ||
              (workItem.replyMode != ConversationReplyMode.all &&
                  workItem.checkpoint == RunCheckpoint.responding &&
                  workItem.nextAgentIndex ==
                      snapshot.executableAgentIds.length))) {
        throw TransitionConflict(request.runId);
      }
      if (targetNextAgentIndex != workItem.nextAgentIndex ||
          !_sameIds(targetExecutable, snapshot.executableAgentIds)) {
        throw TransitionConflict(request.runId);
      }
      return;
    }

    if (_terminalStatuses.contains(targetStatus) ||
        _terminalStages.contains(request.stage) ||
        targetCheckpoint == RunCheckpoint.terminal) {
      throw TransitionConflict(request.runId);
    }
    if (targetStatus != OrchestrationRunStatus.running) {
      throw TransitionConflict(request.runId);
    }

    final currentIndex = workItem.checkpoint.index;
    final targetIndex = targetCheckpoint.index;
    if (targetIndex < currentIndex || targetIndex > currentIndex + 1) {
      throw TransitionConflict(request.runId);
    }

    final valid = switch ((workItem.checkpoint, targetCheckpoint)) {
      (RunCheckpoint.created, RunCheckpoint.created) => false,
      (RunCheckpoint.created, RunCheckpoint.selectingAgents) =>
        request.eventType == OrchestrationEventType.stageChanged &&
            request.stage == ConversationStage.selectingAgents,
      (RunCheckpoint.selectingAgents, RunCheckpoint.selectingAgents) =>
        request.eventType == OrchestrationEventType.stageChanged &&
            request.stage == ConversationStage.selectingAgents,
      (RunCheckpoint.selectingAgents, RunCheckpoint.responding) =>
        request.eventType == OrchestrationEventType.agentsSelected &&
            request.stage == _responseStage(workItem.replyMode) &&
            request.executableAgentIds != null &&
            targetExecutable.isNotEmpty &&
            request.selectedAgentIds.length == targetExecutable.length &&
            _sameIds(request.selectedAgentIds, targetExecutable) &&
            targetNextAgentIndex == 0,
      (RunCheckpoint.responding, RunCheckpoint.responding) =>
        _isValidRespondingSelfLoop(
          workItem: workItem,
          request: request,
          executableAgentIds: targetExecutable,
          targetNextAgentIndex: targetNextAgentIndex,
          priorEvents: priorEvents,
        ),
      (RunCheckpoint.responding, RunCheckpoint.summarizing) =>
        workItem.replyMode == ConversationReplyMode.all &&
            request.eventType == OrchestrationEventType.stageChanged &&
            request.stage == ConversationStage.summarizing &&
            targetNextAgentIndex == targetExecutable.length,
      (RunCheckpoint.summarizing, RunCheckpoint.summarizing) =>
        request.eventType == OrchestrationEventType.stageChanged &&
            request.stage == ConversationStage.summarizing,
      (RunCheckpoint.summarizing, RunCheckpoint.finalizing) =>
        request.eventType == OrchestrationEventType.summaryCompleted &&
            request.stage == ConversationStage.summarizing,
      (RunCheckpoint.finalizing, RunCheckpoint.finalizing) => false,
      _ => false,
    };
    if (!valid) throw TransitionConflict(request.runId);
  }

  static void _validateAgentCursor({
    required RunSnapshot snapshot,
    required RunWorkItem workItem,
    required RunTransitionRequest request,
    required RunCheckpoint targetCheckpoint,
    required List<String> targetExecutable,
    required int targetNextAgentIndex,
  }) {
    if (workItem.nextAgentIndex < 0 ||
        workItem.nextAgentIndex > snapshot.executableAgentIds.length ||
        targetNextAgentIndex < workItem.nextAgentIndex ||
        targetNextAgentIndex < 0 ||
        targetNextAgentIndex > targetExecutable.length) {
      throw TransitionConflict(request.runId);
    }
    if (request.executableAgentIds != null &&
        !(workItem.checkpoint == RunCheckpoint.selectingAgents &&
            targetCheckpoint == RunCheckpoint.responding)) {
      throw TransitionConflict(request.runId);
    }
  }

  static bool _isValidRespondingSelfLoop({
    required RunWorkItem workItem,
    required RunTransitionRequest request,
    required List<String> executableAgentIds,
    required int targetNextAgentIndex,
    required List<OrchestrationEvent> priorEvents,
  }) {
    final current = workItem.nextAgentIndex;
    final responseStage = _responseStage(workItem.replyMode);
    switch (request.eventType) {
      case OrchestrationEventType.stageChanged:
        return targetNextAgentIndex == current &&
            (request.stage == responseStage ||
                (workItem.replyMode == ConversationReplyMode.all &&
                    current == executableAgentIds.length &&
                    request.stage == ConversationStage.crossDiscussion));
      case OrchestrationEventType.agentMessageStarted:
        return current < executableAgentIds.length &&
            targetNextAgentIndex == current &&
            request.stage == responseStage &&
            request.agentId == executableAgentIds[current];
      case OrchestrationEventType.agentMessageCompleted:
      case OrchestrationEventType.agentMessageFailed:
        return current < executableAgentIds.length &&
            targetNextAgentIndex == current + 1 &&
            request.stage == responseStage &&
            request.agentId == executableAgentIds[current] &&
            _hasUnmatchedStart(priorEvents, executableAgentIds[current]);
      case _:
        return false;
    }
  }

  static bool _hasUnmatchedStart(
    List<OrchestrationEvent> priorEvents,
    String agentId,
  ) {
    var lastStartedSeq = -1;
    var lastFinishedSeq = -1;
    for (final event in priorEvents) {
      if (event.agentId != agentId) continue;
      if (event.type == OrchestrationEventType.agentMessageStarted) {
        lastStartedSeq = event.seq;
      } else if (event.type == OrchestrationEventType.agentMessageCompleted ||
          event.type == OrchestrationEventType.agentMessageFailed) {
        lastFinishedSeq = event.seq;
      }
    }
    return lastStartedSeq > lastFinishedSeq;
  }

  static ConversationStage _responseStage(ConversationReplyMode mode) {
    return mode == ConversationReplyMode.all
        ? ConversationStage.collectingOpinions
        : ConversationStage.responding;
  }

  static bool _sameIds(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}

class EventPayloadRejected implements Exception {
  const EventPayloadRejected(this.reason);

  final String reason;

  @override
  String toString() => 'Event payload rejected: $reason';
}

abstract final class EventPayloadPolicy {
  static const maxTextLength = 4096;
  static const maxIdentifierLength = 256;
  static const _forbiddenMarkers = [
    'apikey',
    'providerkey',
    'secretkey',
    'fullprompt',
    'privatememory',
    'rawtoolresult',
    'toolrawresult',
  ];

  static const _textEventTypes = {
    OrchestrationEventType.agentMessageCompleted,
    OrchestrationEventType.agentMessageFailed,
    OrchestrationEventType.summaryCompleted,
    OrchestrationEventType.runFailed,
  };
  static const _agentEventTypes = {
    OrchestrationEventType.agentMessageStarted,
    OrchestrationEventType.agentMessageCompleted,
    OrchestrationEventType.agentMessageFailed,
  };
  static const _selectedAgentEventTypes = {
    OrchestrationEventType.agentsSelected,
  };
  static const _errorEventTypes = {
    OrchestrationEventType.agentMessageFailed,
    OrchestrationEventType.runFailed,
  };

  static void validate(RunTransitionRequest request) {
    if (request.causationId.isEmpty ||
        request.causationId.length > maxIdentifierLength ||
        request.dedupeKey.isEmpty ||
        request.dedupeKey.length > maxIdentifierLength) {
      throw const EventPayloadRejected('invalid transition identifiers');
    }
    if (request.text != null) {
      if (!_textEventTypes.contains(request.eventType)) {
        throw const EventPayloadRejected('text is not allowed for event type');
      }
      if (request.text!.value.length > maxTextLength) {
        throw const EventPayloadRejected('text exceeds length limit');
      }
      final normalized = request.text!.value.toLowerCase().replaceAll(
        RegExp('[^a-z0-9]'),
        '',
      );
      if (_forbiddenMarkers.any(normalized.contains)) {
        throw const EventPayloadRejected('sensitive content marker');
      }
    }
    if (request.agentId != null &&
        (request.agentId!.isEmpty ||
            request.agentId!.length > maxIdentifierLength)) {
      throw const EventPayloadRejected('invalid agent id');
    }
    if (request.agentId != null &&
        !_agentEventTypes.contains(request.eventType)) {
      throw const EventPayloadRejected(
        'agent id is not allowed for event type',
      );
    }
    if (request.selectedAgentIds.length > 8 ||
        request.selectedAgentIds.any(
          (id) => id.isEmpty || id.length > maxIdentifierLength,
        )) {
      throw const EventPayloadRejected('invalid selected agent ids');
    }
    if (request.selectedAgentIds.isNotEmpty &&
        !_selectedAgentEventTypes.contains(request.eventType)) {
      throw const EventPayloadRejected(
        'selected agent ids are not allowed for event type',
      );
    }
    if (request.errorCode != null &&
        (request.errorCode!.isEmpty ||
            request.errorCode!.length > maxIdentifierLength)) {
      throw const EventPayloadRejected('invalid error code');
    }
    if (request.errorCode != null &&
        !_errorEventTypes.contains(request.eventType)) {
      throw const EventPayloadRejected(
        'error code is not allowed for event type',
      );
    }
    if (request.nextAgentIndex != null && request.nextAgentIndex! < 0) {
      throw const EventPayloadRejected('invalid next agent index');
    }
  }

  static void validateExecutableAgentIds(
    List<String> agentIds,
    List<String> memberAgentIds,
  ) {
    if (agentIds.length > 8 ||
        agentIds.toSet().length != agentIds.length ||
        agentIds.any(
          (id) =>
              id.isEmpty ||
              id.length > maxIdentifierLength ||
              !memberAgentIds.contains(id),
        )) {
      throw const EventPayloadRejected('invalid executable agent ids');
    }
  }
}

class InMemoryRunEventStore implements RunEventStore {
  final _runIdsByCommand = <String, String>{};
  final _requestHashesByCommand = <String, String>{};
  final _snapshots = <String, RunSnapshot>{};
  final _workItems = <String, RunWorkItem>{};
  final _events = <String, List<OrchestrationEvent>>{};
  final _transitionHashes = <String, String>{};
  final _controllers = <String, StreamController<OrchestrationEvent>>{};
  var _nextRunNumber = 1;
  bool _closed = false;
  Future<void>? _closeFuture;
  final _externalCalls = <String, ExternalCallIntent>{};
  final _externalCallIntentIdsByIdempotencyKey = <String, String>{};

  @override
  bool get requiresRecoveryReferences => false;

  @override
  ExternalCallIntent ensureExternalCallIntent(
    ExternalCallIntentRequest request,
  ) {
    _ensureOpen();
    getRun(request.runId);
    final existing = _externalCalls[request.intentId];
    if (existing != null) {
      if (existing.idempotencyKey != request.idempotencyKey ||
          existing.runId != request.runId ||
          existing.kind != request.kind ||
          existing.agentId != request.agentId) {
        throw ExternalCallIdentityConflict(request.intentId);
      }
      return existing;
    }
    final intentForIdempotencyKey =
        _externalCallIntentIdsByIdempotencyKey[request.idempotencyKey];
    if (intentForIdempotencyKey != null) {
      throw ExternalCallIdentityConflict(request.idempotencyKey);
    }
    _externalCallIntentIdsByIdempotencyKey[request.idempotencyKey] =
        request.intentId;
    return _externalCalls[request.intentId] = ExternalCallIntent(
      intentId: request.intentId,
      idempotencyKey: request.idempotencyKey,
      runId: request.runId,
      kind: request.kind,
      status: ExternalCallStatus.pending,
      attempt: 0,
      fencingToken: 0,
      agentId: request.agentId,
    );
  }

  @override
  ExternalCallLease? tryAcquireExternalCallLease({
    required String intentId,
    required String ownerId,
    required DateTime now,
    required Duration leaseDuration,
  }) {
    _ensureOpen();
    final intent = getExternalCallIntent(intentId);
    if (intent.status == ExternalCallStatus.receipted ||
        (intent.status == ExternalCallStatus.leased &&
            intent.leaseExpiresAt!.isAfter(now) &&
            intent.ownerId != ownerId)) {
      return null;
    }
    final expiresAt = now.add(leaseDuration);
    final updated = ExternalCallIntent(
      intentId: intent.intentId,
      idempotencyKey: intent.idempotencyKey,
      runId: intent.runId,
      kind: intent.kind,
      status: ExternalCallStatus.leased,
      attempt: intent.attempt + 1,
      fencingToken: intent.fencingToken + 1,
      agentId: intent.agentId,
      ownerId: ownerId,
      leaseExpiresAt: expiresAt,
      result: intent.result,
    );
    _externalCalls[intentId] = updated;
    return ExternalCallLease(
      intentId: intentId,
      ownerId: ownerId,
      idempotencyKey: intent.idempotencyKey,
      attempt: updated.attempt,
      fencingToken: updated.fencingToken,
      expiresAt: expiresAt,
    );
  }

  @override
  ExternalCallIntent recordExternalCallReceipt({
    required ExternalCallLease lease,
    required DateTime now,
    required PublicEventText result,
  }) {
    _ensureOpen();
    final intent = getExternalCallIntent(lease.intentId);
    if (intent.status != ExternalCallStatus.leased ||
        intent.ownerId != lease.ownerId ||
        intent.attempt != lease.attempt ||
        intent.fencingToken != lease.fencingToken ||
        intent.leaseExpiresAt != lease.expiresAt ||
        !now.isBefore(lease.expiresAt)) {
      throw ExternalCallLeaseLost(lease.intentId);
    }
    return _externalCalls[lease.intentId] = ExternalCallIntent(
      intentId: intent.intentId,
      idempotencyKey: intent.idempotencyKey,
      runId: intent.runId,
      kind: intent.kind,
      status: ExternalCallStatus.receipted,
      attempt: intent.attempt,
      fencingToken: intent.fencingToken,
      agentId: intent.agentId,
      result: result,
    );
  }

  @override
  ExternalCallIntent getExternalCallIntent(String intentId) {
    _ensureOpen();
    final intent = _externalCalls[intentId];
    if (intent == null) throw StateError('Unknown external call: $intentId');
    return intent;
  }

  @override
  ({RunSnapshot snapshot, bool created}) createRun(
    StartConversationRunCommand command,
  ) {
    _ensureOpen();
    final existingRunId = _runIdsByCommand[command.clientCommandId];
    if (existingRunId != null) {
      if (_requestHashesByCommand[command.clientCommandId] !=
          command.requestHash) {
        throw CommandIdentityConflict(command.clientCommandId);
      }
      return (snapshot: getRun(existingRunId), created: false);
    }

    final runId = 'run-${_nextRunNumber++}';
    final snapshot = RunSnapshot(
      runId: runId,
      status: OrchestrationRunStatus.running,
      lastSeq: 1,
      executableAgentIds: const [],
    );
    final event = OrchestrationEvent(
      eventId: '$runId-event-1',
      runId: runId,
      seq: 1,
      type: OrchestrationEventType.runCreated,
      stage: ConversationStage.preparing,
      causationId: 'command:${command.clientCommandId}',
      dedupeKey: 'run-created',
    );
    final work = RunWorkItem(
      runId: runId,
      clientCommandId: command.clientCommandId,
      requestHash: command.requestHash,
      conversationId: command.conversationId,
      hostAgentId: command.hostAgentId,
      replyMode: command.replyMode,
      memberAgentIds: command.memberAgentIds,
      mentionedAgentIds: command.mentionedAgentIds,
      inputRef: command.inputRef,
      contextRef: command.contextRef,
      checkpoint: RunCheckpoint.created,
      nextAgentIndex: 0,
    );
    _runIdsByCommand[command.clientCommandId] = runId;
    _requestHashesByCommand[command.clientCommandId] = command.requestHash;
    _snapshots[runId] = snapshot;
    _workItems[runId] = work;
    _events[runId] = [event];
    _controllers[runId] = StreamController<OrchestrationEvent>.broadcast();
    _transitionHashes['$runId::run-created'] = 'run-created';
    return (snapshot: snapshot, created: true);
  }

  @override
  TransitionCommit commitTransition(RunTransitionRequest request) {
    _ensureOpen();
    EventPayloadPolicy.validate(request);
    if (request.executableAgentIds case final executable?) {
      EventPayloadPolicy.validateExecutableAgentIds(
        executable,
        getWorkItem(request.runId).memberAgentIds,
      );
    }
    final identityKey = '${request.runId}::${request.dedupeKey}';
    final existingHash = _transitionHashes[identityKey];
    if (existingHash != null) {
      if (existingHash != request.identityHash) {
        throw TransitionIdentityConflict(request.dedupeKey);
      }
      final event = _events[request.runId]!.firstWhere(
        (candidate) => candidate.dedupeKey == request.dedupeKey,
      );
      return TransitionCommit(
        snapshot: getRun(request.runId),
        event: event,
        committed: false,
      );
    }

    final snapshot = getRun(request.runId);
    if (snapshot.lastSeq != request.expectedLastSeq ||
        snapshot.status != request.expectedStatus) {
      throw TransitionConflict(request.runId);
    }
    TransitionStatePolicy.validate(
      snapshot: snapshot,
      workItem: getWorkItem(request.runId),
      request: request,
      priorEvents: _events[request.runId]!,
    );
    final seq = snapshot.lastSeq + 1;
    final event = OrchestrationEvent(
      eventId: '${request.runId}-event-$seq',
      runId: request.runId,
      seq: seq,
      type: request.eventType,
      stage: request.stage,
      agentId: request.agentId,
      text: request.text,
      selectedAgentIds: request.selectedAgentIds,
      errorCode: request.errorCode,
      causationId: request.causationId,
      dedupeKey: request.dedupeKey,
    );
    final updated = RunSnapshot(
      runId: request.runId,
      status: request.newStatus ?? snapshot.status,
      lastSeq: seq,
      executableAgentIds: List.unmodifiable(
        request.executableAgentIds ?? snapshot.executableAgentIds,
      ),
    );
    _events[request.runId]!.add(event);
    _snapshots[request.runId] = updated;
    _workItems[request.runId] = getWorkItem(request.runId).copyWith(
      checkpoint: request.checkpoint,
      nextAgentIndex: request.nextAgentIndex,
    );
    _transitionHashes[identityKey] = request.identityHash;
    _controllers[request.runId]!.add(event);
    return TransitionCommit(snapshot: updated, event: event, committed: true);
  }

  @override
  RunSnapshot getRun(String runId) {
    _ensureOpen();
    final snapshot = _snapshots[runId];
    if (snapshot == null) throw StateError('Unknown run: $runId');
    return snapshot;
  }

  @override
  RunWorkItem getWorkItem(String runId) {
    _ensureOpen();
    final work = _workItems[runId];
    if (work == null) throw StateError('Unknown run: $runId');
    return work;
  }

  @override
  List<OrchestrationEvent> loadEvents(String runId, {int afterSeq = 0}) {
    _ensureOpen();
    getRun(runId);
    return List.unmodifiable(
      _events[runId]!.where((event) => event.seq > afterSeq),
    );
  }

  @override
  Stream<OrchestrationEvent> watch(String runId, {int afterSeq = 0}) {
    _ensureOpen();
    getRun(runId);
    return Stream<OrchestrationEvent>.multi((sink) {
      for (final event in loadEvents(runId, afterSeq: afterSeq)) {
        sink.add(event);
      }
      final subscription = _controllers[runId]!.stream
          .where((event) => event.seq > afterSeq)
          .listen(sink.add, onError: sink.addError, onDone: sink.close);
      sink.onCancel = subscription.cancel;
    });
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    await Future.wait(
      _controllers.values.map((controller) => controller.close()),
    );
    _controllers.clear();
  }

  void _ensureOpen() {
    if (_closed) throw StateError('RunEventStore is closed');
  }
}
