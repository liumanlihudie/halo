import 'package:flutter/foundation.dart';

import 'condition_expression.dart';
import 'graph_spec.dart';
import 'graph_spec_integrity.dart';

const supportedGraphNodeTypes = <String>{
  'context.load',
  'mode.resolve',
  'agent.select',
  'queue.build',
  'queue.next',
  'agent.run',
  'agent.persistMessage',
  'bus.validate',
  'bus.publish',
  'claim.extract',
  'evidence.resolve',
  'claim.verify',
  'claim.revise',
  'discussion.summarize',
  'publish.gate',
  'tool.request',
  'artifact.commit',
  'budget.check',
  'loop.guard',
  'branch',
  'join',
  'event.emit',
  'gateway.subgraph',
};

@immutable
class GraphValidationIssue {
  const GraphValidationIssue({
    required this.code,
    required this.message,
    this.nodeId,
  });

  final String code;
  final String message;
  final String? nodeId;
}

@immutable
class GraphValidationResult {
  GraphValidationResult(List<GraphValidationIssue> issues)
    : issues = List.unmodifiable(issues);

  final List<GraphValidationIssue> issues;

  bool get isValid => issues.isEmpty;
}

class GraphSpecValidator {
  GraphSpecValidator({StateSchemaResolver? stateSchemaResolver})
    : _conditionDecoder = ConditionExpressionDecoder(
        schemaResolver: stateSchemaResolver ?? const EmptyStateSchemaResolver(),
      );

  final ConditionExpressionDecoder _conditionDecoder;

  ConditionExpression decodeCondition(
    String source, {
    required StateSchemaRef schemaRef,
  }) => _conditionDecoder.decode(source, schemaRef: schemaRef);

  GraphValidationResult validate(GraphSpec spec) {
    final issues = <GraphValidationIssue>[];
    final nodesById = <String, NodeSpec>{};

    _validateIdentityAndLimits(spec, issues);
    if (!GraphSpecIntegrity.contentHashPattern.hasMatch(
      spec.integrity.contentHash,
    )) {
      issues.add(
        const GraphValidationIssue(
          code: 'invalid_content_hash',
          message: 'Content hash must be sha256 followed by 64 lowercase hex.',
        ),
      );
    } else {
      try {
        if (!GraphSpecIntegrity.verify(spec)) {
          issues.add(
            const GraphValidationIssue(
              code: 'content_hash_mismatch',
              message: 'GraphSpec content does not match its content hash.',
            ),
          );
        }
      } on FormatException catch (error) {
        issues.add(
          GraphValidationIssue(
            code: 'non_canonical_json',
            message: error.message,
          ),
        );
      }
    }
    for (final node in spec.nodes) {
      if (nodesById.containsKey(node.id)) {
        issues.add(
          GraphValidationIssue(
            code: 'duplicate_node_id',
            message: 'Node id "${node.id}" is duplicated.',
            nodeId: node.id,
          ),
        );
      } else {
        nodesById[node.id] = node;
      }
      if (!supportedGraphNodeTypes.contains(node.type)) {
        issues.add(
          GraphValidationIssue(
            code: 'unsupported_node_type',
            message: 'Node type "${node.type}" is not registered.',
            nodeId: node.id,
          ),
        );
      }
      if (node.timeoutMs <= 0 || node.retryPolicy.maxAttempts <= 0) {
        issues.add(
          GraphValidationIssue(
            code: 'invalid_node_budget',
            message: 'Node timeout and retry attempts must be positive.',
            nodeId: node.id,
          ),
        );
      }
      try {
        validateNodeConfigShape(node.type, node.config);
      } on GraphSpecFormatException catch (error) {
        issues.add(
          GraphValidationIssue(
            code: 'invalid_node_config',
            message: error.message,
            nodeId: node.id,
          ),
        );
      }
    }

    if (!nodesById.containsKey(spec.entryNodeId)) {
      issues.add(
        const GraphValidationIssue(
          code: 'entry_node_missing',
          message: 'Entry node does not exist.',
        ),
      );
    }

    final terminalIds = spec.terminalNodeIds.toSet();
    if (terminalIds.isEmpty) {
      issues.add(
        const GraphValidationIssue(
          code: 'terminal_nodes_empty',
          message: 'At least one terminal node is required.',
        ),
      );
    }
    for (final terminalId in terminalIds) {
      if (!nodesById.containsKey(terminalId)) {
        issues.add(
          GraphValidationIssue(
            code: 'terminal_node_missing',
            message: 'Terminal node "$terminalId" does not exist.',
            nodeId: terminalId,
          ),
        );
      }
    }

    final outgoing = <String, List<EdgeSpec>>{};
    for (final edge in spec.edges) {
      if (!nodesById.containsKey(edge.from) ||
          !nodesById.containsKey(edge.to)) {
        issues.add(
          GraphValidationIssue(
            code: 'edge_unknown_node',
            message: 'Edge ${edge.from} -> ${edge.to} has an unknown node.',
            nodeId: edge.from,
          ),
        );
      }
      outgoing.putIfAbsent(edge.from, () => []).add(edge);
    }

    for (final entry in outgoing.entries) {
      final priorities = <int>{};
      var defaultCount = 0;
      for (final edge in entry.value) {
        if (!priorities.add(edge.priority)) {
          issues.add(
            GraphValidationIssue(
              code: 'duplicate_edge_priority',
              message: 'Outgoing edge priorities must be unique.',
              nodeId: entry.key,
            ),
          );
        }
        if (edge.isDefault) defaultCount += 1;
        if (edge.when != null) {
          try {
            decodeCondition(edge.when!, schemaRef: spec.stateSchemaRef);
          } on ConditionDecodeException catch (error) {
            issues.add(
              GraphValidationIssue(
                code: error.code,
                message: error.message,
                nodeId: entry.key,
              ),
            );
          }
        }
      }
      if (defaultCount > 1) {
        issues.add(
          GraphValidationIssue(
            code: 'multiple_default_edges',
            message: 'A node can have at most one default edge.',
            nodeId: entry.key,
          ),
        );
      }
    }

    for (final node in nodesById.values) {
      final edges = outgoing[node.id] ?? const [];
      if (terminalIds.contains(node.id) && edges.isNotEmpty) {
        issues.add(
          GraphValidationIssue(
            code: 'terminal_has_outgoing_edge',
            message: 'Terminal nodes cannot have outgoing edges.',
            nodeId: node.id,
          ),
        );
      } else if (!terminalIds.contains(node.id) && edges.isEmpty) {
        issues.add(
          GraphValidationIssue(
            code: 'non_terminal_dead_end',
            message: 'Reachable non-terminal nodes need an outgoing edge.',
            nodeId: node.id,
          ),
        );
      }
    }

    final reachable = _reachableFrom(spec.entryNodeId, outgoing);
    for (final nodeId in nodesById.keys) {
      if (!reachable.contains(nodeId)) {
        issues.add(
          GraphValidationIssue(
            code: 'unreachable_node',
            message: 'Node "$nodeId" is unreachable from the entry node.',
            nodeId: nodeId,
          ),
        );
      }
    }
    _validateTerminalReachability(
      nodesById: nodesById,
      outgoing: outgoing,
      reachable: reachable,
      terminalIds: terminalIds,
      issues: issues,
    );

    _validateCycles(nodesById, outgoing, reachable, issues);
    return GraphValidationResult(issues);
  }

  void _validateTerminalReachability({
    required Map<String, NodeSpec> nodesById,
    required Map<String, List<EdgeSpec>> outgoing,
    required Set<String> reachable,
    required Set<String> terminalIds,
    required List<GraphValidationIssue> issues,
  }) {
    final reverse = <String, List<String>>{};
    for (final entry in outgoing.entries) {
      if (!nodesById.containsKey(entry.key)) continue;
      for (final edge in entry.value) {
        if (nodesById.containsKey(edge.to)) {
          reverse.putIfAbsent(edge.to, () => []).add(entry.key);
        }
      }
    }
    final canReachTerminal = <String>{};
    final pending = terminalIds.where(nodesById.containsKey).toList();
    while (pending.isNotEmpty) {
      final nodeId = pending.removeLast();
      if (!canReachTerminal.add(nodeId)) continue;
      pending.addAll(reverse[nodeId] ?? const []);
    }
    for (final nodeId in reachable) {
      if (nodesById.containsKey(nodeId) && !canReachTerminal.contains(nodeId)) {
        issues.add(
          GraphValidationIssue(
            code: 'no_terminal_path',
            message: 'Reachable node cannot reach a terminal node.',
            nodeId: nodeId,
          ),
        );
      }
    }
  }

  void _validateIdentityAndLimits(
    GraphSpec spec,
    List<GraphValidationIssue> issues,
  ) {
    if (spec.schemaVersion <= 0 ||
        spec.graphVersion <= 0 ||
        spec.stateSchemaRef.version <= 0 ||
        spec.graphId.trim().isEmpty ||
        spec.stateSchemaRef.schemaId.trim().isEmpty) {
      issues.add(
        const GraphValidationIssue(
          code: 'invalid_graph_identity',
          message:
              'Graph and schema identities must be non-empty and positive.',
        ),
      );
    }
    if (spec.limits.maxNodeExecutions <= 0 ||
        spec.limits.maxWallTimeMs <= 0 ||
        spec.limits.maxParallelNodes <= 0) {
      issues.add(
        const GraphValidationIssue(
          code: 'invalid_graph_limits',
          message: 'All graph limits must be positive.',
        ),
      );
    }
  }

  Set<String> _reachableFrom(
    String entryNodeId,
    Map<String, List<EdgeSpec>> outgoing,
  ) {
    final visited = <String>{};
    final pending = <String>[entryNodeId];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (!visited.add(current)) continue;
      pending.addAll((outgoing[current] ?? const []).map((edge) => edge.to));
    }
    return visited;
  }

  void _validateCycles(
    Map<String, NodeSpec> nodesById,
    Map<String, List<EdgeSpec>> outgoing,
    Set<String> reachable,
    List<GraphValidationIssue> issues,
  ) {
    final bypassesBudget = _hasCycleExcludingType(
      excludedType: 'budget.check',
      nodesById: nodesById,
      outgoing: outgoing,
      reachable: reachable,
    );
    final bypassesLoopGuard = _hasCycleExcludingType(
      excludedType: 'loop.guard',
      nodesById: nodesById,
      outgoing: outgoing,
      reachable: reachable,
    );
    if (bypassesBudget || bypassesLoopGuard) {
      issues.add(
        const GraphValidationIssue(
          code: 'unguarded_cycle',
          message: 'Every cycle must include budget.check and loop.guard.',
        ),
      );
    }
  }

  bool _hasCycleExcludingType({
    required String excludedType,
    required Map<String, NodeSpec> nodesById,
    required Map<String, List<EdgeSpec>> outgoing,
    required Set<String> reachable,
  }) {
    final completed = <String>{};
    final visiting = <String>{};

    bool visit(String nodeId) {
      if (nodesById[nodeId]?.type == excludedType) return false;
      if (visiting.contains(nodeId)) return true;
      if (completed.contains(nodeId)) return false;
      visiting.add(nodeId);
      for (final edge in outgoing[nodeId] ?? const []) {
        if (!reachable.contains(edge.to) ||
            nodesById[edge.to]?.type == excludedType) {
          continue;
        }
        if (visit(edge.to)) return true;
      }
      visiting.remove(nodeId);
      completed.add(nodeId);
      return false;
    }

    for (final nodeId in reachable) {
      if (nodesById.containsKey(nodeId) && visit(nodeId)) return true;
    }
    return false;
  }
}
