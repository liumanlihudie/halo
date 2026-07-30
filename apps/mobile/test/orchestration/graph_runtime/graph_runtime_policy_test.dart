import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/orchestration/graph_runtime/graph_runtime.dart';
import 'package:halo_mobile/orchestration/graph_spec/graph_spec.dart';

import 'graph_runtime_test.dart';

void main() {
  test('enforces node execution and wall-time budgets', () async {
    final clock = FakeGraphRuntimeClock();
    final registry = NodeHandlerRegistry()
      ..register('context.load', (input) async {
        clock.advance(const Duration(milliseconds: 11));
        return NodeExecutionResult(
          state: input.context.state.put('route', 'left'),
        );
      })
      ..register(
        'event.emit',
        (input) async => NodeExecutionResult(state: input.context.state),
      );

    final executionBudget = await testGraphRuntime(registry: registry).execute(
      GraphExecutionRequest(
        runId: 'run-count',
        graph: compiledBranchGraph(maxNodeExecutions: 1),
        initialState: GraphState(const {}),
        supportedStateSchemas: {const StateSchemaIdentity('test.state', 1)},
      ),
    );
    expect(executionBudget.status, GraphRunStatus.failed);
    expect(executionBudget.errorCode, 'node_execution_budget_exhausted');
    expect(executionBudget.events.last.type, GraphRuntimeEventType.runFailed);

    clock.reset();
    final wallTimeBudget =
        await testGraphRuntime(registry: registry, clock: clock).execute(
          GraphExecutionRequest(
            runId: 'run-wall',
            graph: compiledBranchGraph(maxWallTimeMs: 10),
            initialState: GraphState(const {}),
            supportedStateSchemas: {const StateSchemaIdentity('test.state', 1)},
          ),
        );
    expect(wallTimeBudget.status, GraphRunStatus.failed);
    expect(wallTimeBudget.errorCode, 'wall_time_budget_exhausted');
  });

  test(
    'retries with injected backoff and succeeds within maxAttempts',
    () async {
      final clock = FakeGraphRuntimeClock();
      var attempts = 0;
      final registry = NodeHandlerRegistry()
        ..register('context.load', (input) async {
          attempts += 1;
          if (attempts < 3) throw StateError('transient');
          return NodeExecutionResult(
            state: input.context.state.put('route', 'left'),
          );
        })
        ..register(
          'event.emit',
          (input) async => NodeExecutionResult(state: input.context.state),
        );

      final result = await testGraphRuntime(registry: registry, clock: clock)
          .execute(
            GraphExecutionRequest(
              runId: 'run-retry',
              graph: compiledBranchGraph(
                maxNodeExecutions: 4,
                loadRetryPolicy: RetryPolicy(
                  maxAttempts: 3,
                  backoff: RetryBackoff.exponential,
                  retryableErrors: const ['node_handler_error'],
                ),
              ),
              initialState: GraphState(const {}),
              supportedStateSchemas: {
                const StateSchemaIdentity('test.state', 1),
              },
            ),
          );

      expect(result.status, GraphRunStatus.completed);
      expect(attempts, 3);
      expect(clock.delays, const [
        Duration(milliseconds: 250),
        Duration(milliseconds: 500),
      ]);
      expect(
        result.events.where(
          (event) => event.type == GraphRuntimeEventType.nodeRetrying,
        ),
        hasLength(2),
      );
    },
  );

  test('counts retry attempts against maxNodeExecutions', () async {
    var attempts = 0;
    final registry = NodeHandlerRegistry()
      ..register('context.load', (input) async {
        attempts += 1;
        if (attempts == 1) throw StateError('transient');
        return NodeExecutionResult(
          state: input.context.state.put('route', 'left'),
        );
      })
      ..register(
        'event.emit',
        (input) async => NodeExecutionResult(state: input.context.state),
      );

    final result = await testGraphRuntime(registry: registry).execute(
      GraphExecutionRequest(
        runId: 'run-retry-budget',
        graph: compiledBranchGraph(
          maxNodeExecutions: 2,
          loadRetryPolicy: RetryPolicy(
            maxAttempts: 2,
            backoff: RetryBackoff.none,
            retryableErrors: const ['node_handler_error'],
          ),
        ),
        initialState: GraphState(const {}),
        supportedStateSchemas: {const StateSchemaIdentity('test.state', 1)},
      ),
    );

    expect(attempts, 2);
    expect(result.status, GraphRunStatus.failed);
    expect(result.errorCode, 'node_execution_budget_exhausted');
  });

  test('does not announce a retry that execution budget cannot fund', () async {
    final registry = NodeHandlerRegistry()
      ..register('context.load', (_) async => throw StateError('transient'));

    final result = await testGraphRuntime(registry: registry).execute(
      GraphExecutionRequest(
        runId: 'run-no-phantom-retry',
        graph: compiledBranchGraph(
          maxNodeExecutions: 1,
          loadRetryPolicy: RetryPolicy(
            maxAttempts: 2,
            backoff: RetryBackoff.none,
            retryableErrors: const ['node_handler_error'],
          ),
        ),
        initialState: GraphState(const {}),
        supportedStateSchemas: {const StateSchemaIdentity('test.state', 1)},
      ),
    );

    expect(result.errorCode, 'node_execution_budget_exhausted');
    expect(
      result.events.where(
        (event) => event.type == GraphRuntimeEventType.nodeRetrying,
      ),
      isEmpty,
    );
  });

  test('turns node timeout into a structured terminal failure', () async {
    final clock = FakeGraphRuntimeClock()..timeoutNext = true;
    final registry = NodeHandlerRegistry()
      ..register(
        'context.load',
        (input) async => NodeExecutionResult(state: input.context.state),
      );

    final result = await testGraphRuntime(registry: registry, clock: clock)
        .execute(
          GraphExecutionRequest(
            runId: 'run-timeout',
            graph: compiledBranchGraph(loadTimeoutMs: 5),
            initialState: GraphState(const {}),
            supportedStateSchemas: {const StateSchemaIdentity('test.state', 1)},
          ),
        );

    expect(result.status, GraphRunStatus.failed);
    expect(result.errorCode, 'node_timeout');
  });

  test(
    'fails closed when a timed-out handler never acknowledges cancel',
    () async {
      final clock = FakeGraphRuntimeClock()..forcedTimeouts = 2;
      final never = Completer<NodeExecutionResult>();
      final registry = NodeHandlerRegistry()
        ..register('context.load', (_) => never.future);

      final result = await testGraphRuntime(registry: registry, clock: clock)
          .execute(
            GraphExecutionRequest(
              runId: 'run-non-cooperative',
              graph: compiledBranchGraph(loadTimeoutMs: 5),
              initialState: GraphState(const {}),
              supportedStateSchemas: {
                const StateSchemaIdentity('test.state', 1),
              },
            ),
          );

      expect(result.errorCode, 'node_timeout_unacknowledged');
      expect(
        result.events.map((event) => event.type),
        containsAllInOrder([
          GraphRuntimeEventType.nodeStarted,
          GraphRuntimeEventType.nodeInterrupted,
          GraphRuntimeEventType.runFailed,
        ]),
      );
    },
  );

  test('caps node timeout at the remaining graph wall-time budget', () async {
    final clock = FakeGraphRuntimeClock();
    final registry = NodeHandlerRegistry()
      ..register(
        'context.load',
        (input) async => NodeExecutionResult(
          state: input.context.state.put('route', 'left'),
        ),
      )
      ..register(
        'event.emit',
        (input) async => NodeExecutionResult(state: input.context.state),
      );

    await testGraphRuntime(registry: registry, clock: clock).execute(
      GraphExecutionRequest(
        runId: 'run-timeout-cap',
        graph: compiledBranchGraph(maxWallTimeMs: 10, loadTimeoutMs: 1000),
        initialState: GraphState(const {}),
        supportedStateSchemas: {const StateSchemaIdentity('test.state', 1)},
      ),
    );

    expect(clock.timeouts.first, const Duration(milliseconds: 10));
  });

  test('wall budget uses monotonic time instead of calendar time', () async {
    final clock = FakeGraphRuntimeClock();
    final registry = NodeHandlerRegistry()
      ..register('context.load', (input) async {
        clock.jumpCalendar(const Duration(days: 30));
        return NodeExecutionResult(
          state: input.context.state.put('route', 'left'),
        );
      })
      ..register(
        'event.emit',
        (input) async => NodeExecutionResult(state: input.context.state),
      );

    final result = await testGraphRuntime(registry: registry, clock: clock)
        .execute(
          GraphExecutionRequest(
            runId: 'run-calendar-jump',
            graph: compiledBranchGraph(maxWallTimeMs: 10),
            initialState: GraphState(const {}),
            supportedStateSchemas: {const StateSchemaIdentity('test.state', 1)},
          ),
        );

    expect(result.status, GraphRunStatus.completed);
  });

  test(
    'provides deterministic idempotency keys to side-effect nodes',
    () async {
      String? receivedKey;
      final registry = NodeHandlerRegistry()
        ..register('context.load', (input) async {
          receivedKey = input.idempotencyKey;
          return NodeExecutionResult(
            state: input.context.state.put('route', 'left'),
            receipt: AttemptReceipt.externalEffectCommitted(
              idempotencyKey: input.idempotencyKey!,
              operationId: 'provider-op',
            ),
          );
        })
        ..register(
          'event.emit',
          (input) async => NodeExecutionResult(state: input.context.state),
        );

      final result = await testGraphRuntime(registry: registry).execute(
        GraphExecutionRequest(
          runId: 'run-side-effect',
          graph: compiledBranchGraph(
            loadSideEffectPolicy: SideEffectPolicy.externalIdempotent,
          ),
          initialState: GraphState(const {}),
          supportedStateSchemas: {const StateSchemaIdentity('test.state', 1)},
        ),
      );

      expect(result.status, GraphRunStatus.completed);
      expect(receivedKey, startsWith('sha256:'));
    },
  );

  test(
    'all retry attempts reuse one logical execution idempotency key',
    () async {
      final receivedKeys = <String>[];
      var calls = 0;
      final registry = NodeHandlerRegistry()
        ..register('context.load', (input) async {
          calls += 1;
          receivedKeys.add(input.idempotencyKey!);
          if (calls == 1) throw StateError('transient');
          return NodeExecutionResult(
            state: input.context.state.put('route', 'left'),
            receipt: AttemptReceipt.externalEffectCommitted(
              idempotencyKey: input.idempotencyKey!,
              operationId: 'provider-op',
            ),
          );
        })
        ..register(
          'event.emit',
          (input) async => NodeExecutionResult(state: input.context.state),
        );

      final result = await testGraphRuntime(registry: registry).execute(
        GraphExecutionRequest(
          runId: 'run-stable-key',
          graph: compiledBranchGraph(
            maxNodeExecutions: 3,
            loadSideEffectPolicy: SideEffectPolicy.externalIdempotent,
            loadRetryPolicy: RetryPolicy(
              maxAttempts: 2,
              backoff: RetryBackoff.none,
              retryableErrors: const ['node_handler_error'],
            ),
          ),
          initialState: GraphState(const {}),
          supportedStateSchemas: {const StateSchemaIdentity('test.state', 1)},
        ),
      );

      expect(result.status, GraphRunStatus.completed);
      expect(receivedKeys, hasLength(2));
      expect(receivedKeys.toSet(), hasLength(1));
    },
  );

  test(
    'local side effects execute through the transaction coordinator',
    () async {
      final coordinator = _RecordingTransactionCoordinator();
      final registry = NodeHandlerRegistry()
        ..register('context.load', (input) async {
          return NodeExecutionResult(
            state: input.context.state.put('route', 'left'),
            receipt: AttemptReceipt.localTransactionCommitted(
              idempotencyKey: input.idempotencyKey!,
              operationId: 'sqlite-tx-1',
            ),
          );
        })
        ..register(
          'event.emit',
          (input) async => NodeExecutionResult(state: input.context.state),
        );

      final result =
          await testGraphRuntime(
            registry: registry,
            localTransactionCoordinator: coordinator,
          ).execute(
            GraphExecutionRequest(
              runId: 'run-local-transaction',
              graph: compiledBranchGraph(
                loadSideEffectPolicy: SideEffectPolicy.localTransaction,
              ),
              initialState: GraphState(const {}),
              supportedStateSchemas: {
                const StateSchemaIdentity('test.state', 1),
              },
            ),
          );

      expect(result.status, GraphRunStatus.completed);
      expect(coordinator.keys, hasLength(1));
      expect(coordinator.keys.single, startsWith('sha256:'));
    },
  );

  test('structured idempotency identity prevents colon collisions', () {
    final first = GraphIdempotencyKey.forNode(
      runId: 'a:b',
      nodeId: 'c',
      executionNumber: 1,
    );
    final second = GraphIdempotencyKey.forNode(
      runId: 'a',
      nodeId: 'b:c',
      executionNumber: 1,
    );

    expect(first, isNot(second));
  });

  test(
    'timeout cancels and awaits a late external side-effect receipt',
    () async {
      final clock = FakeGraphRuntimeClock()..timeoutNext = true;
      var attempts = 0;
      var sideEffects = 0;
      final registry = NodeHandlerRegistry()
        ..register('context.load', (input) async {
          attempts += 1;
          await input.cancellationToken.whenCancelled;
          sideEffects += 1;
          return NodeExecutionResult(
            state: input.context.state,
            receipt: AttemptReceipt.externalEffectCommitted(
              idempotencyKey: input.idempotencyKey!,
              operationId: 'provider-op-1',
            ),
          );
        });

      final result = await testGraphRuntime(registry: registry, clock: clock)
          .execute(
            GraphExecutionRequest(
              runId: 'run-late-effect',
              graph: compiledBranchGraph(
                loadSideEffectPolicy: SideEffectPolicy.externalIdempotent,
                loadRetryPolicy: RetryPolicy(
                  maxAttempts: 2,
                  backoff: RetryBackoff.none,
                  retryableErrors: const ['node_timeout'],
                ),
              ),
              initialState: GraphState(const {}),
              supportedStateSchemas: {
                const StateSchemaIdentity('test.state', 1),
              },
            ),
          );

      expect(attempts, 1);
      expect(sideEffects, 1);
      expect(result.status, GraphRunStatus.failed);
      expect(result.errorCode, 'node_timeout_external_effect');
    },
  );

  test(
    'side-effect timeout rejects noSideEffect receipt and never retries',
    () async {
      final clock = FakeGraphRuntimeClock()..timeoutNext = true;
      var attempts = 0;
      final registry = NodeHandlerRegistry()
        ..register('context.load', (input) async {
          attempts += 1;
          await input.cancellationToken.whenCancelled;
          return NodeExecutionResult(state: input.context.state);
        });

      final result = await testGraphRuntime(registry: registry, clock: clock)
          .execute(
            GraphExecutionRequest(
              runId: 'run-side-effect-no-receipt',
              graph: compiledBranchGraph(
                loadSideEffectPolicy: SideEffectPolicy.externalIdempotent,
                loadRetryPolicy: RetryPolicy(
                  maxAttempts: 2,
                  backoff: RetryBackoff.none,
                  retryableErrors: const ['node_timeout'],
                ),
              ),
              initialState: GraphState(const {}),
              supportedStateSchemas: {
                const StateSchemaIdentity('test.state', 1),
              },
            ),
          );

      expect(attempts, 1);
      expect(result.errorCode, 'node_timeout_unacknowledged');
      expect(
        result.events.where(
          (event) => event.type == GraphRuntimeEventType.nodeRetrying,
        ),
        isEmpty,
      );
    },
  );

  test('side-effect cancellation rejects noSideEffect receipt', () async {
    final stopToken = GraphStopToken();
    final registry = NodeHandlerRegistry()
      ..register('context.load', (input) async {
        scheduleMicrotask(stopToken.requestStop);
        await input.cancellationToken.whenCancelled;
        return NodeExecutionResult(state: input.context.state);
      });

    final result = await testGraphRuntime(registry: registry).execute(
      GraphExecutionRequest(
        runId: 'run-cancel-no-receipt',
        graph: compiledBranchGraph(
          loadSideEffectPolicy: SideEffectPolicy.externalIdempotent,
          loadRetryPolicy: RetryPolicy(
            maxAttempts: 2,
            backoff: RetryBackoff.none,
            retryableErrors: const ['node_handler_error'],
          ),
        ),
        initialState: GraphState(const {}),
        supportedStateSchemas: {const StateSchemaIdentity('test.state', 1)},
        stopToken: stopToken,
      ),
    );

    expect(result.status, GraphRunStatus.failed);
    expect(result.errorCode, 'node_cancellation_unacknowledged');
    expect(
      result.events.where(
        (event) => event.type == GraphRuntimeEventType.nodeRetrying,
      ),
      isEmpty,
    );
  });

  test(
    'durable local receipt cache prevents commit duplication on retry',
    () async {
      final coordinator = _ReceiptCacheTransactionCoordinator(
        throwAfterFirstCommit: true,
      );
      var commits = 0;
      final registry = NodeHandlerRegistry()
        ..register('context.load', (input) async {
          commits += 1;
          return NodeExecutionResult(
            state: input.context.state.put('route', 'left'),
            receipt: AttemptReceipt.localTransactionCommitted(
              idempotencyKey: input.idempotencyKey!,
              operationId: 'sqlite-commit-1',
            ),
          );
        })
        ..register(
          'event.emit',
          (input) async => NodeExecutionResult(state: input.context.state),
        );

      final result =
          await testGraphRuntime(
            registry: registry,
            localTransactionCoordinator: coordinator,
          ).execute(
            GraphExecutionRequest(
              runId: 'run-commit-then-throw',
              graph: compiledBranchGraph(
                maxNodeExecutions: 3,
                loadSideEffectPolicy: SideEffectPolicy.localTransaction,
                loadRetryPolicy: RetryPolicy(
                  maxAttempts: 2,
                  backoff: RetryBackoff.none,
                  retryableErrors: const ['node_handler_error'],
                ),
              ),
              initialState: GraphState(const {}),
              supportedStateSchemas: {
                const StateSchemaIdentity('test.state', 1),
              },
            ),
          );

      expect(result.status, GraphRunStatus.completed);
      expect(commits, 1);
      expect(coordinator.calls, 2);
    },
  );

  test('local transaction fails closed without durable coordinator', () async {
    final runtime = GraphRuntime(
      registry: NodeHandlerRegistry()
        ..register(
          'context.load',
          (input) async => NodeExecutionResult(state: input.context.state),
        ),
      stateSchemaValidator: const _AlwaysValidStateSchemaValidator(),
    );

    final result = await runtime.execute(
      GraphExecutionRequest(
        runId: 'run-no-local-coordinator',
        graph: compiledBranchGraph(
          loadSideEffectPolicy: SideEffectPolicy.localTransaction,
        ),
        initialState: GraphState(const {}),
        supportedStateSchemas: {const StateSchemaIdentity('test.state', 1)},
      ),
    );

    expect(result.errorCode, 'local_transaction_coordinator_unavailable');
  });

  test('stop token prevents scheduling the next node', () async {
    final stopToken = GraphStopToken();
    var terminalCalls = 0;
    final registry = NodeHandlerRegistry()
      ..register('context.load', (input) async {
        stopToken.requestStop();
        return NodeExecutionResult(
          state: input.context.state.put('route', 'left'),
        );
      })
      ..register('event.emit', (input) async {
        terminalCalls += 1;
        return NodeExecutionResult(state: input.context.state);
      });

    final result = await testGraphRuntime(registry: registry).execute(
      GraphExecutionRequest(
        runId: 'run-stop',
        graph: compiledBranchGraph(),
        initialState: GraphState(const {}),
        supportedStateSchemas: {const StateSchemaIdentity('test.state', 1)},
        stopToken: stopToken,
      ),
    );

    expect(result.status, GraphRunStatus.stopped);
    expect(terminalCalls, 0);
    expect(result.events.last.type, GraphRuntimeEventType.runStopped);
  });
}

class FakeGraphRuntimeClock implements GraphRuntimeClock {
  DateTime _now = DateTime.utc(2026);
  Duration _monotonic = Duration.zero;
  final List<Duration> delays = [];
  final List<Duration> timeouts = [];
  bool timeoutNext = false;
  int forcedTimeouts = 0;

  @override
  DateTime now() => _now;

  void advance(Duration duration) {
    _now = _now.add(duration);
    _monotonic += duration;
  }

  void jumpCalendar(Duration duration) => _now = _now.add(duration);

  void reset() {
    _now = DateTime.utc(2026);
    _monotonic = Duration.zero;
    delays.clear();
    timeouts.clear();
  }

  @override
  Duration monotonicNow() => _monotonic;

  @override
  Future<void> delay(Duration duration) async {
    delays.add(duration);
    advance(duration);
  }

  @override
  Future<T> withTimeout<T>(Future<T> future, Duration timeout) {
    timeouts.add(timeout);
    if (timeoutNext) {
      timeoutNext = false;
      return Future<T>.error(TimeoutException('fake timeout'));
    }
    if (forcedTimeouts > 0) {
      forcedTimeouts -= 1;
      return Future<T>.error(TimeoutException('fake timeout'));
    }
    return future;
  }
}

class _RecordingTransactionCoordinator implements LocalTransactionCoordinator {
  final List<String> keys = [];

  @override
  Future<NodeExecutionResult> runExclusive(
    String idempotencyKey,
    Future<NodeExecutionResult> Function() action,
  ) {
    keys.add(idempotencyKey);
    return action();
  }
}

class _ReceiptCacheTransactionCoordinator
    implements LocalTransactionCoordinator {
  _ReceiptCacheTransactionCoordinator({required this.throwAfterFirstCommit});

  final bool throwAfterFirstCommit;
  final Map<String, NodeExecutionResult> _committed = {};
  int calls = 0;

  @override
  Future<NodeExecutionResult> runExclusive(
    String idempotencyKey,
    Future<NodeExecutionResult> Function() action,
  ) async {
    calls += 1;
    final cached = _committed[idempotencyKey];
    if (cached != null) return cached;
    final result = await action();
    _committed[idempotencyKey] = result;
    if (throwAfterFirstCommit) throw StateError('post-commit transport error');
    return result;
  }
}

class _AlwaysValidStateSchemaValidator implements StateSchemaValidator {
  const _AlwaysValidStateSchemaValidator();

  @override
  StateSchemaValidationResult validate(
    StateSchemaIdentity schema,
    GraphState state,
  ) => const StateSchemaValidationResult.valid();
}
