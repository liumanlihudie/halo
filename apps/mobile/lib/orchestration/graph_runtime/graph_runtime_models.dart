import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../graph_spec/graph_spec.dart';
import '../graph_spec/graph_spec_compiler.dart';
import '../graph_spec/graph_spec_integrity.dart';

enum GraphRunStatus { completed, failed, stopped }

enum GraphRuntimeEventType {
  runStarted,
  nodeStarted,
  nodeRetrying,
  nodeCompleted,
  nodeFailed,
  nodeInterrupted,
  runCompleted,
  runFailed,
  runStopped,
  budgetExceeded,
}

@immutable
class StateSchemaIdentity {
  const StateSchemaIdentity(this.schemaId, this.version);

  final String schemaId;
  final int version;

  @override
  bool operator ==(Object other) =>
      other is StateSchemaIdentity &&
      other.schemaId == schemaId &&
      other.version == version;

  @override
  int get hashCode => Object.hash(schemaId, version);
}

@immutable
class GraphState {
  GraphState(Map<String, Object?> values) : values = _freezeMap(values);

  final Map<String, Object?> values;

  Object? operator [](String key) => values[key];
  bool containsKey(String key) => values.containsKey(key);

  GraphState put(String key, Object? value) =>
      GraphState({...values, key: value});
}

@immutable
class GraphExecutionContext {
  const GraphExecutionContext({
    required this.runId,
    required this.state,
    required this.nodeExecutions,
    required this.startedAt,
    required this.startedMonotonic,
  });

  final String runId;
  final GraphState state;
  final int nodeExecutions;
  final DateTime startedAt;
  final Duration startedMonotonic;

  GraphExecutionContext recordExecution() => GraphExecutionContext(
    runId: runId,
    state: state,
    nodeExecutions: nodeExecutions + 1,
    startedAt: startedAt,
    startedMonotonic: startedMonotonic,
  );

  GraphExecutionContext withState(GraphState nextState) =>
      GraphExecutionContext(
        runId: runId,
        state: nextState,
        nodeExecutions: nodeExecutions,
        startedAt: startedAt,
        startedMonotonic: startedMonotonic,
      );
}

class GraphStopToken {
  bool _stopRequested = false;
  final Completer<void> _cancelled = Completer<void>();

  bool get isStopRequested => _stopRequested;
  Future<void> get whenCancelled => _cancelled.future;

  void requestStop() {
    if (_stopRequested) return;
    _stopRequested = true;
    _cancelled.complete();
  }
}

class AttemptCancellationToken {
  AttemptCancellationToken(GraphStopToken stopToken) {
    if (stopToken.isStopRequested) {
      requestCancellation('run_stopped');
    } else {
      stopToken.whenCancelled.then((_) => requestCancellation('run_stopped'));
    }
  }

  bool _cancellationRequested = false;
  String? _reason;
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancellationRequested => _cancellationRequested;
  String? get reason => _reason;
  Future<void> get whenCancelled => _cancelled.future;

  void requestCancellation(String reason) {
    if (_cancellationRequested) return;
    _cancellationRequested = true;
    _reason = reason;
    _cancelled.complete();
  }
}

@immutable
class GraphExecutionRequest {
  GraphExecutionRequest({
    required this.runId,
    required this.graph,
    required this.initialState,
    required Set<StateSchemaIdentity> supportedStateSchemas,
    GraphStopToken? stopToken,
  }) : supportedStateSchemas = Set.unmodifiable(supportedStateSchemas),
       stopToken = stopToken ?? GraphStopToken();

  final String runId;
  final CompiledGraphSpec graph;
  final GraphState initialState;
  final Set<StateSchemaIdentity> supportedStateSchemas;
  final GraphStopToken stopToken;
}

@immutable
class GraphRuntimeEvent {
  const GraphRuntimeEvent({
    required this.runId,
    required this.seq,
    required this.type,
    required this.timestamp,
    this.nodeId,
    this.attempt,
    this.errorCode,
    this.safeMessage,
  });

  final String runId;
  final int seq;
  final GraphRuntimeEventType type;
  final DateTime timestamp;
  final String? nodeId;
  final int? attempt;
  final String? errorCode;
  final String? safeMessage;
}

@immutable
class GraphExecutionResult {
  GraphExecutionResult({
    required this.status,
    required this.finalContext,
    required List<GraphRuntimeEvent> events,
    this.errorCode,
  }) : events = List.unmodifiable(events);

  final GraphRunStatus status;
  final GraphExecutionContext finalContext;
  final List<GraphRuntimeEvent> events;
  final String? errorCode;
}

abstract interface class GraphRuntimeClock {
  DateTime now();
  Duration monotonicNow();
  Future<void> delay(Duration duration);
  Future<T> withTimeout<T>(Future<T> future, Duration timeout);
}

class SystemGraphRuntimeClock implements GraphRuntimeClock {
  SystemGraphRuntimeClock() {
    _stopwatch.start();
  }

  final Stopwatch _stopwatch = Stopwatch();

  @override
  DateTime now() => DateTime.now().toUtc();

  @override
  Duration monotonicNow() => _stopwatch.elapsed;

  @override
  Future<void> delay(Duration duration) => Future<void>.delayed(duration);

  @override
  Future<T> withTimeout<T>(Future<T> future, Duration timeout) =>
      future.timeout(timeout);
}

@immutable
class NodeExecutionInput {
  const NodeExecutionInput({
    required this.node,
    required this.context,
    required this.attempt,
    required this.cancellationToken,
    this.idempotencyKey,
  });

  final NodeSpec node;
  final GraphExecutionContext context;
  final int attempt;
  final AttemptCancellationToken cancellationToken;
  final String? idempotencyKey;
}

enum AttemptReceiptStatus {
  noSideEffect,
  cancelled,
  localTransactionCommitted,
  externalEffectCommitted,
}

@immutable
class AttemptReceipt {
  const AttemptReceipt.noSideEffect()
    : status = AttemptReceiptStatus.noSideEffect,
      idempotencyKey = null,
      operationId = null;

  const AttemptReceipt.cancelled()
    : status = AttemptReceiptStatus.cancelled,
      idempotencyKey = null,
      operationId = null;

  const AttemptReceipt.localTransactionCommitted({
    required this.idempotencyKey,
    required this.operationId,
  }) : status = AttemptReceiptStatus.localTransactionCommitted;

  const AttemptReceipt.externalEffectCommitted({
    required this.idempotencyKey,
    required this.operationId,
  }) : status = AttemptReceiptStatus.externalEffectCommitted;

  final AttemptReceiptStatus status;
  final String? idempotencyKey;
  final String? operationId;
}

@immutable
class NodeExecutionResult {
  const NodeExecutionResult({
    required this.state,
    this.receipt = const AttemptReceipt.noSideEffect(),
  });

  final GraphState state;
  final AttemptReceipt receipt;
}

typedef NodeHandler =
    Future<NodeExecutionResult> Function(NodeExecutionInput input);

abstract interface class StateSchemaValidator {
  StateSchemaValidationResult validate(
    StateSchemaIdentity schema,
    GraphState state,
  );
}

@immutable
class StateSchemaValidationResult {
  const StateSchemaValidationResult.valid()
    : isValid = true,
      safeMessage = null;

  const StateSchemaValidationResult.invalid(this.safeMessage) : isValid = false;

  final bool isValid;
  final String? safeMessage;
}

abstract interface class LocalTransactionCoordinator {
  Future<NodeExecutionResult> runExclusive(
    String idempotencyKey,
    Future<NodeExecutionResult> Function() action,
  );
}

class GraphIdempotencyKey {
  const GraphIdempotencyKey._();

  static String forNode({
    required String runId,
    required String nodeId,
    required int executionNumber,
  }) {
    final runBytes = utf8.encode(runId);
    final nodeBytes = utf8.encode(nodeId);
    final identity =
        '${runBytes.length}:$runId|${nodeBytes.length}:$nodeId|'
        '$executionNumber';
    return 'sha256:${GraphSpecIntegrity.sha256Hex(utf8.encode(identity))}';
  }
}

Map<String, Object?> _freezeMap(Map<String, Object?> source) =>
    Map<String, Object?>.unmodifiable(
      source.map((key, value) => MapEntry(key, _freezeValue(value))),
    );

Object? _freezeValue(Object? value) {
  if (value == null || value is String || value is bool) return value;
  if (value is int && value >= -9007199254740991 && value <= 9007199254740991) {
    return value;
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_freezeValue));
  }
  if (value is Map) {
    if (value.keys.any((key) => key is! String)) {
      throw ArgumentError.value(value, 'state', 'Map keys must be strings.');
    }
    return Map<String, Object?>.unmodifiable(
      value.map((key, nested) => MapEntry(key as String, _freezeValue(nested))),
    );
  }
  throw ArgumentError.value(value, 'state', 'Unsupported state value.');
}
