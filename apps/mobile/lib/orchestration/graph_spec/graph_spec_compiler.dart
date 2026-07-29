import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'condition_expression.dart';
import 'graph_spec.dart';
import 'graph_spec_validator.dart';

@immutable
class CompiledGraphSpec {
  CompiledGraphSpec({
    required this.source,
    required Map<String, NodeSpec> nodesById,
    required Map<String, List<EdgeSpec>> outgoingByNodeId,
    required Map<EdgeSpec, ConditionExpression> conditionsByEdge,
  }) : nodesById = UnmodifiableMapView(nodesById),
       _conditionsByEdge = UnmodifiableMapView(conditionsByEdge),
       _outgoingByNodeId = UnmodifiableMapView(
         outgoingByNodeId.map(
           (nodeId, edges) => MapEntry(nodeId, List.unmodifiable(edges)),
         ),
       );

  final GraphSpec source;
  final Map<String, NodeSpec> nodesById;
  final Map<String, List<EdgeSpec>> _outgoingByNodeId;
  final Map<EdgeSpec, ConditionExpression> _conditionsByEdge;

  NodeSpec get entryNode => nodesById[source.entryNodeId]!;

  List<EdgeSpec> outgoingEdges(String nodeId) =>
      _outgoingByNodeId[nodeId] ?? const [];

  ConditionExpression? conditionFor(EdgeSpec edge) => _conditionsByEdge[edge];
}

class GraphSpecCompilationException implements Exception {
  GraphSpecCompilationException(List<GraphValidationIssue> issues)
    : issues = List.unmodifiable(issues);

  final List<GraphValidationIssue> issues;

  @override
  String toString() =>
      'GraphSpecCompilationException(${issues.map((issue) => issue.code).join(', ')})';
}

class GraphSpecCompiler {
  GraphSpecCompiler({GraphSpecValidator? validator})
    : _validator = validator ?? GraphSpecValidator();

  final GraphSpecValidator _validator;

  CompiledGraphSpec compile(GraphSpec spec) {
    final validation = _validator.validate(spec);
    if (!validation.isValid) {
      throw GraphSpecCompilationException(validation.issues);
    }

    final nodesById = <String, NodeSpec>{
      for (final node in spec.nodes) node.id: node,
    };
    final outgoing = <String, List<EdgeSpec>>{};
    for (final edge in spec.edges) {
      outgoing.putIfAbsent(edge.from, () => []).add(edge);
    }
    for (final edges in outgoing.values) {
      edges.sort((left, right) {
        if (left.isDefault != right.isDefault) {
          return left.isDefault ? 1 : -1;
        }
        return left.priority.compareTo(right.priority);
      });
    }
    final conditions = <EdgeSpec, ConditionExpression>{
      for (final edge in spec.edges)
        if (edge.when != null)
          edge: _validator.decodeCondition(
            edge.when!,
            schemaRef: spec.stateSchemaRef,
          ),
    };

    return CompiledGraphSpec(
      source: spec,
      nodesById: nodesById,
      outgoingByNodeId: outgoing,
      conditionsByEdge: conditions,
    );
  }
}
