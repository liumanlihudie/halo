import 'dart:async';

import 'package:halo_mobile/orchestration/orchestration_models.dart';

abstract interface class RunEventStore {
  ({RunSnapshot snapshot, bool created}) createRun(
    StartConversationRunCommand command,
  );

  OrchestrationEvent append({
    required String runId,
    required OrchestrationEventType type,
    required ConversationStage stage,
    String? agentId,
    String? text,
    List<String> selectedAgentIds,
    String? errorCode,
  });

  void updateRun({
    required String runId,
    OrchestrationRunStatus? status,
    List<String>? executableAgentIds,
  });

  RunSnapshot getRun(String runId);

  Stream<OrchestrationEvent> watch(String runId, {int afterSeq = 0});
}

class InMemoryRunEventStore implements RunEventStore {
  final _runIdsByCommand = <String, String>{};
  final _snapshots = <String, RunSnapshot>{};
  final _events = <String, List<OrchestrationEvent>>{};
  final _controllers = <String, StreamController<OrchestrationEvent>>{};
  var _nextRunNumber = 1;

  @override
  ({RunSnapshot snapshot, bool created}) createRun(
    StartConversationRunCommand command,
  ) {
    final existingRunId = _runIdsByCommand[command.clientCommandId];
    if (existingRunId != null) {
      return (snapshot: getRun(existingRunId), created: false);
    }

    final runId = 'run-${_nextRunNumber++}';
    final snapshot = RunSnapshot(
      runId: runId,
      status: OrchestrationRunStatus.running,
      lastSeq: 0,
      executableAgentIds: const [],
    );
    _runIdsByCommand[command.clientCommandId] = runId;
    _snapshots[runId] = snapshot;
    _events[runId] = <OrchestrationEvent>[];
    _controllers[runId] = StreamController<OrchestrationEvent>.broadcast();
    return (snapshot: snapshot, created: true);
  }

  @override
  OrchestrationEvent append({
    required String runId,
    required OrchestrationEventType type,
    required ConversationStage stage,
    String? agentId,
    String? text,
    List<String> selectedAgentIds = const [],
    String? errorCode,
  }) {
    final snapshot = getRun(runId);
    final seq = snapshot.lastSeq + 1;
    final event = OrchestrationEvent(
      eventId: '$runId-event-$seq',
      runId: runId,
      seq: seq,
      type: type,
      stage: stage,
      agentId: agentId,
      text: text,
      selectedAgentIds: List.unmodifiable(selectedAgentIds),
      errorCode: errorCode,
    );
    _events[runId]!.add(event);
    _snapshots[runId] = RunSnapshot(
      runId: runId,
      status: snapshot.status,
      lastSeq: seq,
      executableAgentIds: snapshot.executableAgentIds,
    );
    _controllers[runId]!.add(event);
    return event;
  }

  @override
  RunSnapshot getRun(String runId) {
    final snapshot = _snapshots[runId];
    if (snapshot == null) {
      throw StateError('Unknown run: $runId');
    }
    return snapshot;
  }

  @override
  void updateRun({
    required String runId,
    OrchestrationRunStatus? status,
    List<String>? executableAgentIds,
  }) {
    final snapshot = getRun(runId);
    _snapshots[runId] = RunSnapshot(
      runId: runId,
      status: status ?? snapshot.status,
      lastSeq: snapshot.lastSeq,
      executableAgentIds: List.unmodifiable(
        executableAgentIds ?? snapshot.executableAgentIds,
      ),
    );
  }

  @override
  Stream<OrchestrationEvent> watch(String runId, {int afterSeq = 0}) {
    getRun(runId);
    return Stream<OrchestrationEvent>.multi((sink) {
      for (final event in _events[runId]!) {
        if (event.seq > afterSeq) {
          sink.add(event);
        }
      }
      final subscription = _controllers[runId]!.stream
          .where((event) => event.seq > afterSeq)
          .listen(sink.add, onError: sink.addError);
      sink.onCancel = subscription.cancel;
    });
  }
}
