import 'dart:async';

import '../graph_spec/graph_spec.dart';
import 'condition_evaluator.dart';
import 'graph_runtime_models.dart';
import 'node_handler_registry.dart';

class GraphRuntime {
  factory GraphRuntime({
    required NodeHandlerRegistry registry,
    GraphRuntimeClock? clock,
    GraphConditionEvaluator? conditionEvaluator,
    StateSchemaValidator? stateSchemaValidator,
    LocalTransactionCoordinator? localTransactionCoordinator,
    void Function(GraphRuntimeEvent event)? onEvent,
  }) => GraphRuntime._(
    registry,
    clock ?? SystemGraphRuntimeClock(),
    conditionEvaluator ?? GraphConditionEvaluator(),
    stateSchemaValidator,
    localTransactionCoordinator,
    onEvent,
  );

  GraphRuntime._(
    this._registry,
    this._clock,
    this._conditionEvaluator,
    this._stateSchemaValidator,
    this._localTransactionCoordinator,
    this._onEvent,
  );

  final NodeHandlerRegistry _registry;
  final GraphRuntimeClock _clock;
  final GraphConditionEvaluator _conditionEvaluator;
  final StateSchemaValidator? _stateSchemaValidator;
  final LocalTransactionCoordinator? _localTransactionCoordinator;
  final void Function(GraphRuntimeEvent event)? _onEvent;

  Future<GraphExecutionResult> execute(GraphExecutionRequest request) async {
    final events = <GraphRuntimeEvent>[];
    var seq = 0;
    final startedAt = _clock.now();
    var context = GraphExecutionContext(
      runId: request.runId,
      state: request.initialState,
      nodeExecutions: 0,
      startedAt: startedAt,
      startedMonotonic: _clock.monotonicNow(),
    );

    void emit(
      GraphRuntimeEventType type, {
      String? nodeId,
      int? attempt,
      String? errorCode,
      String? safeMessage,
    }) {
      final event = GraphRuntimeEvent(
        runId: request.runId,
        seq: ++seq,
        type: type,
        timestamp: _clock.now(),
        nodeId: nodeId,
        attempt: attempt,
        errorCode: errorCode,
        safeMessage: safeMessage,
      );
      events.add(event);
      _onEvent?.call(event);
    }

    GraphExecutionResult finish(GraphRunStatus status, {String? errorCode}) =>
        GraphExecutionResult(
          status: status,
          finalContext: context,
          events: events,
          errorCode: errorCode,
        );

    void failRun(
      String code,
      String message, {
      String? nodeId,
      int? attempt,
      bool budget = false,
    }) {
      if (budget) {
        emit(
          GraphRuntimeEventType.budgetExceeded,
          nodeId: nodeId,
          attempt: attempt,
          errorCode: code,
          safeMessage: message,
        );
      }
      emit(
        GraphRuntimeEventType.runFailed,
        nodeId: nodeId,
        attempt: attempt,
        errorCode: code,
        safeMessage: message,
      );
    }

    final schemaRef = request.graph.source.stateSchemaRef;
    final schema = StateSchemaIdentity(schemaRef.schemaId, schemaRef.version);
    if (!request.supportedStateSchemas.contains(schema)) {
      failRun('unsupported_state_schema', '当前运行时不支持此状态版本');
      return finish(
        GraphRunStatus.failed,
        errorCode: 'unsupported_state_schema',
      );
    }
    final schemaValidator = _stateSchemaValidator;
    if (schemaValidator == null) {
      failRun('state_schema_validator_unavailable', '当前运行时未注册此状态契约的校验器');
      return finish(
        GraphRunStatus.failed,
        errorCode: 'state_schema_validator_unavailable',
      );
    }
    final initialValidation = schemaValidator.validate(
      schema,
      request.initialState,
    );
    if (!initialValidation.isValid) {
      failRun(
        'state_schema_validation_failed',
        initialValidation.safeMessage ?? '初始状态不符合状态契约',
      );
      return finish(
        GraphRunStatus.failed,
        errorCode: 'state_schema_validation_failed',
      );
    }

    emit(GraphRuntimeEventType.runStarted);
    var nodeId = request.graph.source.entryNodeId;
    while (true) {
      if (request.stopToken.isStopRequested) {
        emit(GraphRuntimeEventType.runStopped);
        return finish(GraphRunStatus.stopped);
      }
      final topBudgetError = _budgetError(request, context);
      if (topBudgetError != null) {
        failRun(topBudgetError, _budgetMessage(topBudgetError), budget: true);
        return finish(GraphRunStatus.failed, errorCode: topBudgetError);
      }

      final node = request.graph.nodesById[nodeId];
      if (node == null) {
        failRun('unknown_node', '图引用了不存在的节点', nodeId: nodeId);
        return finish(GraphRunStatus.failed, errorCode: 'unknown_node');
      }
      final handler = _registry.resolve(node.type);
      if (handler == null) {
        failRun('unknown_node_handler', '当前运行时不支持此节点', nodeId: node.id);
        return finish(GraphRunStatus.failed, errorCode: 'unknown_node_handler');
      }
      if (node.retryPolicy.maxAttempts > 10) {
        failRun('invalid_retry_policy', '节点重试次数超过运行时上限', nodeId: node.id);
        return finish(GraphRunStatus.failed, errorCode: 'invalid_retry_policy');
      }
      if (node.sideEffectPolicy == SideEffectPolicy.localTransaction &&
          _localTransactionCoordinator == null) {
        failRun(
          'local_transaction_coordinator_unavailable',
          '当前运行时未配置持久事务协调器',
          nodeId: node.id,
        );
        return finish(
          GraphRunStatus.failed,
          errorCode: 'local_transaction_coordinator_unavailable',
        );
      }

      NodeExecutionResult? nodeResult;
      String? terminalErrorCode;
      var terminalAttempt = 0;
      final logicalExecutionNumber = context.nodeExecutions + 1;
      final idempotencyKey = node.sideEffectPolicy == SideEffectPolicy.none
          ? null
          : GraphIdempotencyKey.forNode(
              runId: request.runId,
              nodeId: node.id,
              executionNumber: logicalExecutionNumber,
            );
      for (
        var attempt = 1;
        attempt <= node.retryPolicy.maxAttempts;
        attempt += 1
      ) {
        terminalAttempt = attempt;
        if (request.stopToken.isStopRequested) break;
        final attemptBudgetError = _budgetError(request, context);
        if (attemptBudgetError != null) {
          terminalErrorCode = attemptBudgetError;
          break;
        }

        context = context.recordExecution();
        emit(
          GraphRuntimeEventType.nodeStarted,
          nodeId: node.id,
          attempt: attempt,
        );

        final cancellationToken = AttemptCancellationToken(request.stopToken);
        if (request.stopToken.isStopRequested) {
          emit(
            GraphRuntimeEventType.nodeInterrupted,
            nodeId: node.id,
            attempt: attempt,
            errorCode: 'run_stopped',
            safeMessage: '运行已停止',
          );
          emit(GraphRuntimeEventType.runStopped, nodeId: node.id);
          return finish(GraphRunStatus.stopped);
        }

        final remainingWall = _remainingWallTime(request, context);
        if (remainingWall <= Duration.zero) {
          terminalErrorCode = 'wall_time_budget_exhausted';
          emit(
            GraphRuntimeEventType.nodeInterrupted,
            nodeId: node.id,
            attempt: attempt,
            errorCode: terminalErrorCode,
            safeMessage: _budgetMessage(terminalErrorCode),
          );
          break;
        }
        final nodeTimeout = Duration(milliseconds: node.timeoutMs);
        final effectiveTimeout = remainingWall < nodeTimeout
            ? remainingWall
            : nodeTimeout;
        final input = NodeExecutionInput(
          node: node,
          context: context,
          attempt: attempt,
          cancellationToken: cancellationToken,
          idempotencyKey: idempotencyKey,
        );
        final handlerFuture = _invoke(
          node: node,
          handler: handler,
          input: input,
          idempotencyKey: idempotencyKey,
        );

        try {
          final completedResult = await _clock.withTimeout(
            handlerFuture,
            effectiveTimeout,
          );
          nodeResult = completedResult;
          if (request.stopToken.isStopRequested) {
            final cancellationError = _cancellationReceiptError(
              node,
              completedResult.receipt,
            );
            emit(
              GraphRuntimeEventType.nodeInterrupted,
              nodeId: node.id,
              attempt: attempt,
              errorCode: cancellationError ?? 'run_stopped',
              safeMessage: cancellationError == null ? '运行已停止' : '处理器未安全确认取消',
            );
            if (cancellationError != null) {
              failRun(
                cancellationError,
                '处理器未安全确认取消',
                nodeId: node.id,
                attempt: attempt,
              );
              return finish(
                GraphRunStatus.failed,
                errorCode: cancellationError,
              );
            }
            emit(GraphRuntimeEventType.runStopped, nodeId: node.id);
            return finish(GraphRunStatus.stopped);
          }
          final receiptError = _validateReceipt(
            node,
            completedResult.receipt,
            idempotencyKey,
          );
          if (receiptError != null) {
            terminalErrorCode = receiptError;
            nodeResult = null;
            emit(
              GraphRuntimeEventType.nodeFailed,
              nodeId: node.id,
              attempt: attempt,
              errorCode: receiptError,
              safeMessage: '副作用执行回执无效',
            );
            break;
          }
          final outputValidation = schemaValidator.validate(
            schema,
            completedResult.state,
          );
          if (!outputValidation.isValid) {
            terminalErrorCode = 'state_schema_validation_failed';
            nodeResult = null;
            emit(
              GraphRuntimeEventType.nodeFailed,
              nodeId: node.id,
              attempt: attempt,
              errorCode: terminalErrorCode,
              safeMessage: outputValidation.safeMessage ?? '节点输出不符合状态契约',
            );
            break;
          }
          break;
        } on TimeoutException {
          final wallLimited = effectiveTimeout == remainingWall;
          cancellationToken.requestCancellation(
            wallLimited ? 'wall_time_budget_exhausted' : 'node_timeout',
          );
          final receipt = await _awaitCancellationReceipt(
            request,
            context,
            handlerFuture,
          );
          if (receipt == null) {
            terminalErrorCode = 'node_timeout_unacknowledged';
          } else if (_isCommitted(receipt.receipt)) {
            terminalErrorCode =
                receipt.receipt.status ==
                    AttemptReceiptStatus.externalEffectCommitted
                ? 'node_timeout_external_effect'
                : 'node_timeout_local_commit';
          } else if (_isAcknowledgedCancellation(node, receipt.receipt)) {
            terminalErrorCode = wallLimited
                ? 'wall_time_budget_exhausted'
                : 'node_timeout';
          } else {
            terminalErrorCode = 'node_timeout_unacknowledged';
          }
          nodeResult = null;
          emit(
            GraphRuntimeEventType.nodeInterrupted,
            nodeId: node.id,
            attempt: attempt,
            errorCode: terminalErrorCode,
            safeMessage: '节点执行超时',
          );
        } catch (_) {
          terminalErrorCode = 'node_handler_error';
          emit(
            GraphRuntimeEventType.nodeFailed,
            nodeId: node.id,
            attempt: attempt,
            errorCode: terminalErrorCode,
            safeMessage: '节点执行失败',
          );
        }

        final canRetry =
            attempt < node.retryPolicy.maxAttempts &&
            node.retryPolicy.retryableErrors.contains(terminalErrorCode) &&
            terminalErrorCode != 'node_timeout_external_effect' &&
            terminalErrorCode != 'node_timeout_local_commit' &&
            terminalErrorCode != 'node_timeout_unacknowledged';
        if (!canRetry) break;

        final backoff = _backoff(node.retryPolicy.backoff, attempt);
        final retryBudgetError = _retryBudgetError(request, context, backoff);
        if (retryBudgetError != null) {
          terminalErrorCode = retryBudgetError;
          break;
        }
        emit(
          GraphRuntimeEventType.nodeRetrying,
          nodeId: node.id,
          attempt: attempt,
          errorCode: terminalErrorCode,
          safeMessage: '节点执行失败，准备重试',
        );
        await _clock.delay(backoff);
        if (request.stopToken.isStopRequested) {
          emit(GraphRuntimeEventType.runStopped, nodeId: node.id);
          return finish(GraphRunStatus.stopped);
        }
      }

      if (request.stopToken.isStopRequested) {
        emit(GraphRuntimeEventType.runStopped, nodeId: node.id);
        return finish(GraphRunStatus.stopped);
      }
      if (nodeResult == null) {
        final code =
            _budgetError(request, context) ??
            terminalErrorCode ??
            'node_handler_error';
        failRun(
          code,
          _budgetMessage(code),
          nodeId: node.id,
          attempt: terminalAttempt,
          budget: _isBudgetError(code),
        );
        return finish(GraphRunStatus.failed, errorCode: code);
      }

      context = context.withState(nodeResult.state);
      emit(
        GraphRuntimeEventType.nodeCompleted,
        nodeId: node.id,
        attempt: terminalAttempt,
      );
      if (request.stopToken.isStopRequested) {
        emit(GraphRuntimeEventType.runStopped, nodeId: node.id);
        return finish(GraphRunStatus.stopped);
      }
      if (_wallTimeExceeded(request, context)) {
        failRun(
          'wall_time_budget_exhausted',
          '运行时间预算已用尽',
          nodeId: node.id,
          budget: true,
        );
        return finish(
          GraphRunStatus.failed,
          errorCode: 'wall_time_budget_exhausted',
        );
      }
      if (request.graph.source.terminalNodeIds.contains(node.id)) {
        emit(GraphRuntimeEventType.runCompleted);
        return finish(GraphRunStatus.completed);
      }

      try {
        final outgoing = request.graph.outgoingEdges(node.id);
        String? selected;
        for (final edge in outgoing) {
          final condition = request.graph.conditionFor(edge);
          if (condition == null ||
              _conditionEvaluator.evaluate(condition, context.state)) {
            selected = edge.to;
            break;
          }
        }
        if (selected == null) {
          throw const GraphConditionException(
            'condition_no_match',
            '没有可执行的后续分支',
          );
        }
        nodeId = selected;
      } on GraphConditionException catch (error) {
        failRun(error.code, error.safeMessage, nodeId: node.id);
        return finish(GraphRunStatus.failed, errorCode: error.code);
      } catch (_) {
        failRun('condition_evaluation_failed', '条件计算失败', nodeId: node.id);
        return finish(
          GraphRunStatus.failed,
          errorCode: 'condition_evaluation_failed',
        );
      }
    }
  }

  Future<NodeExecutionResult> _invoke({
    required NodeSpec node,
    required NodeHandler handler,
    required NodeExecutionInput input,
    required String? idempotencyKey,
  }) {
    if (node.sideEffectPolicy == SideEffectPolicy.localTransaction) {
      return _localTransactionCoordinator!.runExclusive(
        idempotencyKey!,
        () => handler(input),
      );
    }
    return handler(input);
  }

  Future<NodeExecutionResult?> _awaitCancellationReceipt(
    GraphExecutionRequest request,
    GraphExecutionContext context,
    Future<NodeExecutionResult> handlerFuture,
  ) async {
    final remaining = _remainingWallTime(request, context);
    if (remaining <= Duration.zero) return null;
    final grace = remaining < const Duration(milliseconds: 250)
        ? remaining
        : const Duration(milliseconds: 250);
    try {
      return await _clock.withTimeout(handlerFuture, grace);
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
  }

  String? _validateReceipt(
    NodeSpec node,
    AttemptReceipt receipt,
    String? idempotencyKey,
  ) {
    if (node.sideEffectPolicy == SideEffectPolicy.none) {
      return receipt.status == AttemptReceiptStatus.noSideEffect
          ? null
          : 'side_effect_receipt_invalid';
    }
    final expected = node.sideEffectPolicy == SideEffectPolicy.localTransaction
        ? AttemptReceiptStatus.localTransactionCommitted
        : AttemptReceiptStatus.externalEffectCommitted;
    if (receipt.status != expected ||
        receipt.idempotencyKey != idempotencyKey ||
        receipt.operationId == null ||
        receipt.operationId!.isEmpty) {
      return 'side_effect_receipt_invalid';
    }
    return null;
  }

  bool _isCommitted(AttemptReceipt receipt) =>
      receipt.status == AttemptReceiptStatus.localTransactionCommitted ||
      receipt.status == AttemptReceiptStatus.externalEffectCommitted;

  bool _isAcknowledgedCancellation(NodeSpec node, AttemptReceipt receipt) {
    if (node.sideEffectPolicy == SideEffectPolicy.none) {
      return receipt.status == AttemptReceiptStatus.cancelled ||
          receipt.status == AttemptReceiptStatus.noSideEffect;
    }
    return receipt.status == AttemptReceiptStatus.cancelled;
  }

  String? _cancellationReceiptError(NodeSpec node, AttemptReceipt receipt) {
    if (node.sideEffectPolicy == SideEffectPolicy.none) return null;
    if (receipt.status == AttemptReceiptStatus.cancelled) return null;
    if (receipt.status == AttemptReceiptStatus.externalEffectCommitted) {
      return 'node_cancellation_external_effect';
    }
    if (receipt.status == AttemptReceiptStatus.localTransactionCommitted) {
      return 'node_cancellation_local_commit';
    }
    return 'node_cancellation_unacknowledged';
  }

  String? _budgetError(
    GraphExecutionRequest request,
    GraphExecutionContext context,
  ) {
    if (_wallTimeExceeded(request, context)) {
      return 'wall_time_budget_exhausted';
    }
    if (context.nodeExecutions >=
        request.graph.source.limits.maxNodeExecutions) {
      return 'node_execution_budget_exhausted';
    }
    return null;
  }

  String? _retryBudgetError(
    GraphExecutionRequest request,
    GraphExecutionContext context,
    Duration backoff,
  ) {
    if (context.nodeExecutions >=
        request.graph.source.limits.maxNodeExecutions) {
      return 'node_execution_budget_exhausted';
    }
    final remaining = _remainingWallTime(request, context);
    if (remaining <= backoff) return 'wall_time_budget_exhausted';
    return null;
  }

  bool _wallTimeExceeded(
    GraphExecutionRequest request,
    GraphExecutionContext context,
  ) =>
      _clock.monotonicNow() - context.startedMonotonic >=
      Duration(milliseconds: request.graph.source.limits.maxWallTimeMs);

  Duration _remainingWallTime(
    GraphExecutionRequest request,
    GraphExecutionContext context,
  ) {
    final elapsed = _clock.monotonicNow() - context.startedMonotonic;
    final maximum = Duration(
      milliseconds: request.graph.source.limits.maxWallTimeMs,
    );
    final remaining = maximum - elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  bool _isBudgetError(String code) =>
      code == 'wall_time_budget_exhausted' ||
      code == 'node_execution_budget_exhausted';

  String _budgetMessage(String code) => switch (code) {
    'wall_time_budget_exhausted' => '运行时间预算已用尽',
    'node_execution_budget_exhausted' => '节点执行预算已用尽',
    'state_schema_validation_failed' => '节点输出不符合状态契约',
    'node_timeout_external_effect' => '节点超时后已产生外部副作用',
    'node_timeout_local_commit' => '节点超时后本地事务已提交',
    'node_timeout_unacknowledged' => '节点超时且处理器未确认取消',
    'node_timeout' => '节点执行超时',
    _ => '节点执行失败',
  };

  Duration _backoff(RetryBackoff policy, int failedAttempt) => switch (policy) {
    RetryBackoff.none => Duration.zero,
    RetryBackoff.fixed => const Duration(milliseconds: 250),
    RetryBackoff.exponential => Duration(
      milliseconds: 250 * (1 << (failedAttempt - 1)),
    ),
  };
}
