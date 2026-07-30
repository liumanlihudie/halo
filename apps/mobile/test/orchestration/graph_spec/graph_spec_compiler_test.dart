import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/orchestration/graph_spec/condition_expression.dart';
import 'package:halo_mobile/orchestration/graph_spec/graph_spec.dart';
import 'package:halo_mobile/orchestration/graph_spec/graph_spec_compiler.dart';
import 'package:halo_mobile/orchestration/graph_spec/graph_spec_validator.dart';

import 'graph_spec_test.dart';

void main() {
  test('compiler indexes nodes and orders default edges last', () {
    final spec = copyGraph(
      GraphSpec(
        schemaVersion: 1,
        graphId: 'halo.branch',
        graphVersion: 1,
        stateSchemaRef: validGraphSpec().stateSchemaRef,
        entryNodeId: 'load',
        terminalNodeIds: const ['left', 'right'],
        nodes: [
          node('load', 'branch'),
          node('left', 'event.emit'),
          node('right', 'event.emit'),
        ],
        edges: const [
          EdgeSpec(from: 'load', to: 'right', priority: 9),
          EdgeSpec(
            from: 'load',
            to: 'left',
            priority: 2,
            when: r'$.mode == "left"',
          ),
        ],
        limits: const GraphLimits(
          maxNodeExecutions: 3,
          maxWallTimeMs: 10000,
          maxParallelNodes: 1,
        ),
        requiredCapabilities: const [],
        integrity: validGraphSpec().integrity,
      ),
    );

    final compiled = GraphSpecCompiler(
      validator: GraphSpecValidator(
        stateSchemaResolver: MapStateSchemaResolver({
          r'$.mode': const StateFieldSchema(ConditionValueType.string),
        }),
      ),
    ).compile(spec);

    expect(compiled.entryNode.id, 'load');
    expect(compiled.nodesById.keys, ['load', 'left', 'right']);
    expect(compiled.outgoingEdges('load').map((edge) => edge.to), [
      'left',
      'right',
    ]);
    expect(
      compiled.conditionFor(compiled.outgoingEdges('load').first),
      isA<ConditionComparison>(),
    );
    expect(compiled.conditionFor(compiled.outgoingEdges('load').last), isNull);
    expect(
      () => compiled.nodesById['extra'] = node('extra', 'branch'),
      throwsUnsupportedError,
    );
  });

  test('compiler refuses an invalid graph with structured issues', () {
    final invalid = copyGraph(
      GraphSpec(
        schemaVersion: 1,
        graphId: 'halo.invalid',
        graphVersion: 1,
        stateSchemaRef: validGraphSpec().stateSchemaRef,
        entryNodeId: 'missing',
        terminalNodeIds: const ['done'],
        nodes: [node('done', 'event.emit')],
        edges: const [],
        limits: const GraphLimits(
          maxNodeExecutions: 1,
          maxWallTimeMs: 10000,
          maxParallelNodes: 1,
        ),
        requiredCapabilities: const [],
        integrity: validGraphSpec().integrity,
      ),
    );

    expect(
      () => GraphSpecCompiler().compile(invalid),
      throwsA(
        isA<GraphSpecCompilationException>().having(
          (error) => error.issues.map((issue) => issue.code),
          'issue codes',
          contains('entry_node_missing'),
        ),
      ),
    );
  });
}
