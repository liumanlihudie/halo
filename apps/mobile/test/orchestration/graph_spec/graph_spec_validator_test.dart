import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/orchestration/graph_spec/condition_expression.dart';
import 'package:halo_mobile/orchestration/graph_spec/graph_spec.dart';
import 'package:halo_mobile/orchestration/graph_spec/graph_spec_validator.dart';

import 'graph_spec_test.dart';

void main() {
  final validator = GraphSpecValidator();

  test('accepts the minimal complete graph from the architecture contract', () {
    expect(validator.validate(validGraphSpec()).isValid, isTrue);
  });

  test('reports duplicate node ids and unreachable nodes', () {
    final spec = _copy(
      validGraphSpec(),
      nodes: [
        node('load', 'context.load'),
        node('done', 'event.emit'),
        node('done', 'branch'),
        node('orphan', 'event.emit'),
      ],
    );

    expect(
      validator.validate(spec).issues.map((issue) => issue.code),
      containsAll(['duplicate_node_id', 'unreachable_node']),
    );
  });

  test('rejects invalid references, terminal exits and dead ends', () {
    final spec = _copy(
      validGraphSpec(),
      nodes: [
        node('load', 'context.load'),
        node('middle', 'branch'),
        node('done', 'event.emit'),
      ],
      edges: const [
        EdgeSpec(from: 'load', to: 'middle', priority: 0),
        EdgeSpec(from: 'done', to: 'missing', priority: 0),
      ],
    );

    expect(
      validator.validate(spec).issues.map((issue) => issue.code),
      containsAll([
        'edge_unknown_node',
        'terminal_has_outgoing_edge',
        'non_terminal_dead_end',
      ]),
    );
  });

  test('rejects duplicate priorities and more than one default edge', () {
    final spec = _copy(
      validGraphSpec(),
      nodes: [
        node('load', 'context.load'),
        node('left', 'branch'),
        node('right', 'branch'),
        node('done', 'event.emit'),
      ],
      edges: const [
        EdgeSpec(from: 'load', to: 'left', priority: 0, when: r'$.mode == "a"'),
        EdgeSpec(
          from: 'load',
          to: 'right',
          priority: 0,
          when: r'$.mode == "b"',
        ),
        EdgeSpec(from: 'load', to: 'done', priority: 2),
        EdgeSpec(from: 'load', to: 'done', priority: 3),
        EdgeSpec(from: 'left', to: 'done', priority: 0),
        EdgeSpec(from: 'right', to: 'done', priority: 0),
      ],
    );

    expect(
      validator.validate(spec).issues.map((issue) => issue.code),
      containsAll(['duplicate_edge_priority', 'multiple_default_edges']),
    );
  });

  test('requires budget.check and loop.guard inside every cycle', () {
    final unguarded = _copy(
      validGraphSpec(),
      nodes: [
        node('load', 'context.load'),
        node('work', 'agent.run'),
        node('done', 'event.emit'),
      ],
      edges: const [
        EdgeSpec(from: 'load', to: 'work', priority: 0),
        EdgeSpec(
          from: 'work',
          to: 'work',
          priority: 0,
          when: r'$.again == true',
        ),
        EdgeSpec(from: 'work', to: 'done', priority: 1),
      ],
      maxNodeExecutions: 6,
    );

    expect(
      validator.validate(unguarded).issues.map((issue) => issue.code),
      contains('unguarded_cycle'),
    );

    final guarded = _copy(
      validGraphSpec(),
      nodes: [
        node('load', 'context.load'),
        node('budget', 'budget.check'),
        node('guard', 'loop.guard'),
        node('work', 'agent.run'),
        node('done', 'event.emit'),
      ],
      edges: const [
        EdgeSpec(from: 'load', to: 'budget', priority: 0),
        EdgeSpec(from: 'budget', to: 'guard', priority: 0),
        EdgeSpec(from: 'guard', to: 'work', priority: 0),
        EdgeSpec(
          from: 'work',
          to: 'budget',
          priority: 0,
          when: r'$.again == true',
        ),
        EdgeSpec(from: 'work', to: 'done', priority: 1),
      ],
      maxNodeExecutions: 10,
    );

    expect(
      validator
          .validate(guarded)
          .issues
          .where((issue) => issue.code == 'unguarded_cycle'),
      isEmpty,
    );
  });

  test('rejects a cycle that can bypass the guards in a guarded component', () {
    final spec = _copy(
      validGraphSpec(),
      nodes: [
        node('load', 'context.load'),
        node('budget', 'budget.check'),
        node('guard', 'loop.guard'),
        node('work', 'agent.run'),
        node('done', 'event.emit'),
      ],
      edges: const [
        EdgeSpec(from: 'load', to: 'budget', priority: 0),
        EdgeSpec(from: 'budget', to: 'guard', priority: 0),
        EdgeSpec(from: 'guard', to: 'work', priority: 0),
        EdgeSpec(
          from: 'work',
          to: 'budget',
          priority: 0,
          when: r'$.again == true',
        ),
        EdgeSpec(
          from: 'work',
          to: 'work',
          priority: 1,
          when: r'$.bypass == true',
        ),
        EdgeSpec(from: 'work', to: 'done', priority: 2),
      ],
      maxNodeExecutions: 10,
    );

    expect(
      validator.validate(spec).issues.map((issue) => issue.code),
      contains('unguarded_cycle'),
    );
  });

  test('rejects unsupported nodes and invalid execution budgets', () {
    final spec = _copy(
      validGraphSpec(),
      nodes: [node('load', 'script.eval'), node('done', 'event.emit')],
      maxNodeExecutions: 0,
    );

    expect(
      validator.validate(spec).issues.map((issue) => issue.code),
      containsAll(['unsupported_node_type', 'invalid_graph_limits']),
    );
  });

  test(
    'allows a positive execution budget smaller than reachable node count',
    () {
      final spec = _copy(
        validGraphSpec(),
        nodes: [
          node('load', 'context.load'),
          node('middle', 'branch'),
          node('done', 'event.emit'),
        ],
        edges: const [
          EdgeSpec(from: 'load', to: 'middle', priority: 0),
          EdgeSpec(from: 'middle', to: 'done', priority: 0),
        ],
        maxNodeExecutions: 1,
      );

      expect(
        validator
            .validate(spec)
            .issues
            .where((issue) => issue.code == 'execution_budget_too_small'),
        isEmpty,
      );
    },
  );

  test('rejects reachable nodes that cannot reach any terminal', () {
    final spec = _copy(
      validGraphSpec(),
      nodes: [
        node('load', 'context.load'),
        node('budget', 'budget.check'),
        node('guard', 'loop.guard'),
        node('closed', 'branch'),
        node('done', 'event.emit'),
      ],
      edges: const [
        EdgeSpec(from: 'load', to: 'budget', priority: 0),
        EdgeSpec(from: 'budget', to: 'guard', priority: 0),
        EdgeSpec(from: 'guard', to: 'closed', priority: 0),
        EdgeSpec(from: 'closed', to: 'budget', priority: 0),
      ],
      maxNodeExecutions: 10,
    );

    expect(
      validator.validate(spec).issues.map((issue) => issue.code),
      contains('no_terminal_path'),
    );
  });

  test(
    'validates every when expression against the referenced state schema',
    () {
      final spec = _copy(
        validGraphSpec(),
        edges: const [
          EdgeSpec(
            from: 'load',
            to: 'done',
            priority: 0,
            when: r'$.unknown == true',
          ),
        ],
      );
      final schemaValidator = GraphSpecValidator(
        stateSchemaResolver: MapStateSchemaResolver({
          r'$.ready': const StateFieldSchema(ConditionValueType.boolean),
        }),
      );

      expect(
        schemaValidator.validate(spec).issues.map((issue) => issue.code),
        contains('condition_unknown_path'),
      );
    },
  );
}

GraphSpec _copy(
  GraphSpec source, {
  List<NodeSpec>? nodes,
  List<EdgeSpec>? edges,
  int? maxNodeExecutions,
}) {
  final candidate = GraphSpec(
    schemaVersion: source.schemaVersion,
    graphId: source.graphId,
    graphVersion: source.graphVersion,
    stateSchemaRef: source.stateSchemaRef,
    entryNodeId: source.entryNodeId,
    terminalNodeIds: source.terminalNodeIds,
    nodes: nodes ?? source.nodes,
    edges: edges ?? source.edges,
    limits: GraphLimits(
      maxNodeExecutions: maxNodeExecutions ?? source.limits.maxNodeExecutions,
      maxWallTimeMs: source.limits.maxWallTimeMs,
      maxParallelNodes: source.limits.maxParallelNodes,
    ),
    requiredCapabilities: source.requiredCapabilities,
    integrity: source.integrity,
  );
  return copyGraph(candidate);
}
