import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/orchestration/graph_runtime/graph_runtime.dart';
import 'package:halo_mobile/orchestration/graph_spec/condition_expression.dart';
import 'package:halo_mobile/orchestration/graph_spec/graph_spec.dart';
import 'package:halo_mobile/orchestration/graph_spec/graph_spec_compiler.dart';
import 'package:halo_mobile/orchestration/graph_spec/graph_spec_integrity.dart';
import 'package:halo_mobile/orchestration/graph_spec/graph_spec_validator.dart';

void main() {
  test('NodeHandlerRegistry only accepts the GraphSpec node whitelist', () {
    final registry = NodeHandlerRegistry();

    expect(
      () => registry.register(
        'script.eval',
        (input) async => NodeExecutionResult(state: input.context.state),
      ),
      throwsStateError,
    );
  });

  test(
    'executes compiled nodes and chooses the first matching condition',
    () async {
      final visited = <String>[];
      final registry = NodeHandlerRegistry()
        ..register('context.load', (input) async {
          visited.add(input.node.id);
          return NodeExecutionResult(
            state: input.context.state.put('route', 'left'),
          );
        })
        ..register('event.emit', (input) async {
          visited.add(input.node.id);
          return NodeExecutionResult(state: input.context.state);
        });
      final runtime = testGraphRuntime(registry: registry);

      final result = await runtime.execute(
        GraphExecutionRequest(
          runId: 'run-1',
          graph: compiledBranchGraph(),
          initialState: GraphState(const {}),
          supportedStateSchemas: {const StateSchemaIdentity('test.state', 1)},
        ),
      );

      expect(result.status, GraphRunStatus.completed);
      expect(visited, ['load', 'left']);
      expect(result.finalContext.state['route'], 'left');
      expect(
        result.events.map((event) => event.seq),
        List.generate(result.events.length, (index) => index + 1),
      );
      expect(
        result.events.map((event) => event.type),
        containsAllInOrder([
          GraphRuntimeEventType.runStarted,
          GraphRuntimeEventType.nodeStarted,
          GraphRuntimeEventType.nodeCompleted,
          GraphRuntimeEventType.nodeStarted,
          GraphRuntimeEventType.nodeCompleted,
          GraphRuntimeEventType.runCompleted,
        ]),
      );
    },
  );

  test('GraphState and execution context stay immutable', () async {
    final nested = <String, Object?>{
      'items': <Object?>[
        <String, Object?>{'value': 'original'},
      ],
    };
    final state = GraphState(nested);
    nested['items'] = const [];

    expect(
      ((state['items']! as List).single as Map<String, Object?>)['value'],
      'original',
    );
    expect(() => state.values['new'] = true, throwsUnsupportedError);
    expect(() => (state['items']! as List).add('new'), throwsUnsupportedError);
  });

  test('fails closed when a handler or state schema is unavailable', () async {
    final graph = compiledBranchGraph();

    final unknownHandler =
        await testGraphRuntime(registry: NodeHandlerRegistry()).execute(
          GraphExecutionRequest(
            runId: 'run-handler',
            graph: graph,
            initialState: GraphState(const {}),
            supportedStateSchemas: {const StateSchemaIdentity('test.state', 1)},
          ),
        );
    expect(unknownHandler.status, GraphRunStatus.failed);
    expect(unknownHandler.errorCode, 'unknown_node_handler');

    var calls = 0;
    final wrongSchema =
        await testGraphRuntime(
          registry: NodeHandlerRegistry()
            ..register('context.load', (input) async {
              calls += 1;
              return NodeExecutionResult(state: input.context.state);
            }),
        ).execute(
          GraphExecutionRequest(
            runId: 'run-schema',
            graph: graph,
            initialState: GraphState(const {}),
            supportedStateSchemas: {
              const StateSchemaIdentity('other.state', 1),
            },
          ),
        );
    expect(wrongSchema.status, GraphRunStatus.failed);
    expect(wrongSchema.errorCode, 'unsupported_state_schema');
    expect(calls, 0);
  });

  test('fails closed when condition state is missing', () async {
    final registry = NodeHandlerRegistry()
      ..register(
        'context.load',
        (input) async => NodeExecutionResult(state: input.context.state),
      )
      ..register(
        'event.emit',
        (input) async => NodeExecutionResult(state: input.context.state),
      );

    final result = await testGraphRuntime(registry: registry).execute(
      GraphExecutionRequest(
        runId: 'run-condition',
        graph: compiledBranchGraph(),
        initialState: GraphState(const {}),
        supportedStateSchemas: {const StateSchemaIdentity('test.state', 1)},
      ),
    );

    expect(result.status, GraphRunStatus.failed);
    expect(result.errorCode, 'condition_missing_field');
  });

  test(
    'fails closed when runtime condition value has the wrong type',
    () async {
      final registry = NodeHandlerRegistry()
        ..register(
          'context.load',
          (input) async =>
              NodeExecutionResult(state: input.context.state.put('route', 7)),
        )
        ..register(
          'event.emit',
          (input) async => NodeExecutionResult(state: input.context.state),
        );

      final result = await testGraphRuntime(registry: registry).execute(
        GraphExecutionRequest(
          runId: 'run-condition-type',
          graph: compiledBranchGraph(),
          initialState: GraphState(const {}),
          supportedStateSchemas: {const StateSchemaIdentity('test.state', 1)},
        ),
      );

      expect(result.status, GraphRunStatus.failed);
      expect(result.errorCode, 'state_schema_validation_failed');
    },
  );

  test('stop after nodeStarted interrupts before handler invocation', () async {
    final stopToken = GraphStopToken();
    var handlerCalls = 0;
    final registry = NodeHandlerRegistry()
      ..register('context.load', (input) async {
        handlerCalls += 1;
        return NodeExecutionResult(state: input.context.state);
      });
    final runtime = testGraphRuntime(
      registry: registry,
      onEvent: (event) {
        if (event.type == GraphRuntimeEventType.nodeStarted) {
          stopToken.requestStop();
        }
      },
    );

    final result = await runtime.execute(
      GraphExecutionRequest(
        runId: 'run-stop-before-handler',
        graph: compiledBranchGraph(),
        initialState: GraphState(const {}),
        supportedStateSchemas: {const StateSchemaIdentity('test.state', 1)},
        stopToken: stopToken,
      ),
    );

    expect(handlerCalls, 0);
    expect(
      result.events.map((event) => event.type),
      containsAllInOrder([
        GraphRuntimeEventType.nodeStarted,
        GraphRuntimeEventType.nodeInterrupted,
        GraphRuntimeEventType.runStopped,
      ]),
    );
  });

  test('stop request is delivered to an active handler', () async {
    final stopToken = GraphStopToken();
    var observedCancellation = false;
    final registry = NodeHandlerRegistry()
      ..register('context.load', (input) async {
        scheduleMicrotask(stopToken.requestStop);
        await input.cancellationToken.whenCancelled;
        observedCancellation = true;
        return NodeExecutionResult(
          state: input.context.state,
          receipt: const AttemptReceipt.cancelled(),
        );
      });

    final result = await testGraphRuntime(registry: registry).execute(
      GraphExecutionRequest(
        runId: 'run-stop-active-handler',
        graph: compiledBranchGraph(),
        initialState: GraphState(const {}),
        supportedStateSchemas: {const StateSchemaIdentity('test.state', 1)},
        stopToken: stopToken,
      ),
    );

    expect(observedCancellation, isTrue);
    expect(result.status, GraphRunStatus.stopped);
    expect(
      result.events.map((event) => event.type),
      containsAllInOrder([
        GraphRuntimeEventType.nodeStarted,
        GraphRuntimeEventType.nodeInterrupted,
        GraphRuntimeEventType.runStopped,
      ]),
    );
  });

  test(
    'state schema validator rejects initial and handler output state',
    () async {
      final validator = _RouteStateValidator();
      final registry = NodeHandlerRegistry()
        ..register(
          'context.load',
          (input) async =>
              NodeExecutionResult(state: input.context.state.put('route', 7)),
        );
      final runtime = testGraphRuntime(
        registry: registry,
        stateSchemaValidator: validator,
      );

      final invalidInitial = await runtime.execute(
        GraphExecutionRequest(
          runId: 'run-invalid-initial',
          graph: compiledBranchGraph(),
          initialState: GraphState(const {'route': 7}),
          supportedStateSchemas: {const StateSchemaIdentity('test.state', 1)},
        ),
      );
      expect(invalidInitial.errorCode, 'state_schema_validation_failed');

      final invalidOutput = await runtime.execute(
        GraphExecutionRequest(
          runId: 'run-invalid-output',
          graph: compiledBranchGraph(),
          initialState: GraphState(const {}),
          supportedStateSchemas: {const StateSchemaIdentity('test.state', 1)},
        ),
      );
      expect(invalidOutput.errorCode, 'state_schema_validation_failed');
    },
  );

  test('fails closed when no state schema validator is registered', () async {
    final runtime = GraphRuntime(
      registry: NodeHandlerRegistry()
        ..register(
          'context.load',
          (input) async => NodeExecutionResult(state: input.context.state),
        ),
    );

    final result = await runtime.execute(
      GraphExecutionRequest(
        runId: 'run-unregistered-schema-validator',
        graph: compiledBranchGraph(),
        initialState: GraphState(const {}),
        supportedStateSchemas: {const StateSchemaIdentity('test.state', 1)},
      ),
    );

    expect(result.status, GraphRunStatus.failed);
    expect(result.errorCode, 'state_schema_validator_unavailable');
  });

  test(
    'stop requested by nodeCompleted observer wins over completion',
    () async {
      final stopToken = GraphStopToken();
      final registry = NodeHandlerRegistry()
        ..register('context.load', (input) async {
          return NodeExecutionResult(
            state: input.context.state.put('route', 'left'),
          );
        })
        ..register(
          'event.emit',
          (input) async => NodeExecutionResult(state: input.context.state),
        );
      final runtime = testGraphRuntime(
        registry: registry,
        onEvent: (event) {
          if (event.type == GraphRuntimeEventType.nodeCompleted &&
              event.nodeId == 'left') {
            stopToken.requestStop();
          }
        },
      );

      final result = await runtime.execute(
        GraphExecutionRequest(
          runId: 'run-stop-on-completed',
          graph: compiledBranchGraph(),
          initialState: GraphState(const {}),
          supportedStateSchemas: {const StateSchemaIdentity('test.state', 1)},
          stopToken: stopToken,
        ),
      );

      expect(result.status, GraphRunStatus.stopped);
      expect(result.events.last.type, GraphRuntimeEventType.runStopped);
      expect(
        result.events.where(
          (event) => event.type == GraphRuntimeEventType.runCompleted,
        ),
        isEmpty,
      );
    },
  );
}

class _RouteStateValidator implements StateSchemaValidator {
  const _RouteStateValidator();

  @override
  StateSchemaValidationResult validate(
    StateSchemaIdentity schema,
    GraphState state,
  ) {
    final route = state['route'];
    return route == null || route is String
        ? const StateSchemaValidationResult.valid()
        : const StateSchemaValidationResult.invalid('route must be string');
  }
}

GraphRuntime testGraphRuntime({
  required NodeHandlerRegistry registry,
  GraphRuntimeClock? clock,
  StateSchemaValidator? stateSchemaValidator,
  LocalTransactionCoordinator? localTransactionCoordinator,
  void Function(GraphRuntimeEvent event)? onEvent,
}) => GraphRuntime(
  registry: registry,
  clock: clock,
  stateSchemaValidator: stateSchemaValidator ?? const _RouteStateValidator(),
  localTransactionCoordinator: localTransactionCoordinator,
  onEvent: onEvent,
);

CompiledGraphSpec compiledBranchGraph({
  int maxNodeExecutions = 3,
  int maxWallTimeMs = 10000,
  RetryPolicy? loadRetryPolicy,
  SideEffectPolicy loadSideEffectPolicy = SideEffectPolicy.none,
  int loadTimeoutMs = 1000,
}) {
  final placeholder = GraphSpec(
    schemaVersion: 1,
    graphId: 'test.branch',
    graphVersion: 1,
    stateSchemaRef: const StateSchemaRef(schemaId: 'test.state', version: 1),
    entryNodeId: 'load',
    terminalNodeIds: const ['left', 'right'],
    nodes: [
      NodeSpec(
        id: 'load',
        type: 'context.load',
        config: const {},
        timeoutMs: loadTimeoutMs,
        retryPolicy:
            loadRetryPolicy ??
            RetryPolicy(maxAttempts: 1, backoff: RetryBackoff.none),
        sideEffectPolicy: loadSideEffectPolicy,
      ),
      _eventNode('left'),
      _eventNode('right'),
    ],
    edges: const [
      EdgeSpec(
        from: 'load',
        to: 'left',
        priority: 0,
        when: r'$.route == "left"',
      ),
      EdgeSpec(from: 'load', to: 'right', priority: 1),
    ],
    limits: GraphLimits(
      maxNodeExecutions: maxNodeExecutions,
      maxWallTimeMs: maxWallTimeMs,
      maxParallelNodes: 1,
    ),
    requiredCapabilities: const [],
    integrity: const GraphIntegrity(
      contentHash:
          'sha256:0000000000000000000000000000000000000000000000000000000000000000',
    ),
  );
  final spec = _withHash(placeholder);
  final validator = GraphSpecValidator(
    stateSchemaResolver: MapStateSchemaResolver({
      r'$.route': const StateFieldSchema(ConditionValueType.string),
    }),
  );
  return GraphSpecCompiler(validator: validator).compile(spec);
}

NodeSpec _eventNode(String id) => NodeSpec(
  id: id,
  type: 'event.emit',
  config: const {'eventType': 'test.completed'},
  timeoutMs: 1000,
  retryPolicy: RetryPolicy(maxAttempts: 1, backoff: RetryBackoff.none),
  sideEffectPolicy: SideEffectPolicy.none,
);

GraphSpec _withHash(GraphSpec source) => GraphSpec(
  schemaVersion: source.schemaVersion,
  graphId: source.graphId,
  graphVersion: source.graphVersion,
  stateSchemaRef: source.stateSchemaRef,
  entryNodeId: source.entryNodeId,
  terminalNodeIds: source.terminalNodeIds,
  nodes: source.nodes,
  edges: source.edges,
  limits: source.limits,
  requiredCapabilities: source.requiredCapabilities,
  integrity: GraphIntegrity(
    contentHash: GraphSpecIntegrity.calculateContentHash(source),
  ),
);
