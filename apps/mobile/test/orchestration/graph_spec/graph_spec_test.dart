import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/orchestration/graph_spec/graph_spec.dart';
import 'package:halo_mobile/orchestration/graph_spec/graph_spec_integrity.dart';

void main() {
  test('GraphSpec survives a JSON round trip without losing fields', () {
    final spec = validGraphSpec();

    final restored = GraphSpec.fromJson(spec.toJson());

    expect(restored.toJson(), spec.toJson());
  });

  test('GraphSpec snapshots caller-owned collections', () {
    final nodes = <NodeSpec>[
      node('load', 'context.load'),
      node('done', 'event.emit'),
    ];
    final config = <String, Object?>{
      'eventType': 'run.completed',
      'metadata': <String, Object?>{'visible': true},
    };
    nodes[1] = NodeSpec(
      id: 'done',
      type: 'event.emit',
      config: config,
      timeoutMs: 1000,
      retryPolicy: RetryPolicy(maxAttempts: 1, backoff: RetryBackoff.none),
      sideEffectPolicy: SideEffectPolicy.localTransaction,
    );
    final spec = GraphSpec(
      schemaVersion: 1,
      graphId: 'halo.immutable',
      graphVersion: 1,
      stateSchemaRef: const StateSchemaRef(
        schemaId: 'halo.run-state',
        version: 1,
      ),
      entryNodeId: 'load',
      terminalNodeIds: const ['done'],
      nodes: nodes,
      edges: const [EdgeSpec(from: 'load', to: 'done', priority: 0)],
      limits: const GraphLimits(
        maxNodeExecutions: 2,
        maxWallTimeMs: 10000,
        maxParallelNodes: 1,
      ),
      requiredCapabilities: const ['sqlite.checkpoint'],
      integrity: const GraphIntegrity(contentHash: 'sha256:test'),
    );

    nodes.clear();
    config['eventType'] = 'tampered';
    (config['metadata']! as Map<String, Object?>)['visible'] = false;

    expect(spec.nodes, hasLength(2));
    expect(spec.nodes.last.config['eventType'], 'run.completed');
    expect(
      (spec.nodes.last.config['metadata']! as Map<String, Object?>)['visible'],
      isTrue,
    );
    expect(() => spec.nodes.add(node('x', 'branch')), throwsUnsupportedError);
    expect(
      () => spec.nodes.last.config['eventType'] = 'changed',
      throwsUnsupportedError,
    );
  });
}

GraphSpec validGraphSpec() => copyGraph(
  GraphSpec(
    schemaVersion: 1,
    graphId: 'halo.noop',
    graphVersion: 1,
    stateSchemaRef: const StateSchemaRef(
      schemaId: 'halo.orchestration.run-state',
      version: 1,
    ),
    entryNodeId: 'load',
    terminalNodeIds: const ['done'],
    nodes: [node('load', 'context.load'), node('done', 'event.emit')],
    edges: const [EdgeSpec(from: 'load', to: 'done', priority: 0)],
    limits: const GraphLimits(
      maxNodeExecutions: 2,
      maxWallTimeMs: 10000,
      maxParallelNodes: 1,
    ),
    requiredCapabilities: const ['sqlite.checkpoint'],
    integrity: const GraphIntegrity(
      contentHash:
          'sha256:0000000000000000000000000000000000000000000000000000000000000000',
    ),
  ),
);

NodeSpec node(String id, String type) => NodeSpec(
  id: id,
  type: type,
  config: type == 'event.emit'
      ? const {'eventType': 'run.completed'}
      : const {},
  timeoutMs: 1000,
  retryPolicy: RetryPolicy(maxAttempts: 1, backoff: RetryBackoff.none),
  sideEffectPolicy: SideEffectPolicy.none,
);

GraphSpec copyGraph(
  GraphSpec source, {
  String? graphId,
  GraphIntegrity? integrity,
  bool recomputeHash = true,
}) {
  GraphSpec build(GraphIntegrity value) => GraphSpec(
    schemaVersion: source.schemaVersion,
    graphId: graphId ?? source.graphId,
    graphVersion: source.graphVersion,
    stateSchemaRef: source.stateSchemaRef,
    entryNodeId: source.entryNodeId,
    terminalNodeIds: source.terminalNodeIds,
    nodes: source.nodes,
    edges: source.edges,
    limits: source.limits,
    requiredCapabilities: source.requiredCapabilities,
    integrity: value,
  );

  final candidate = build(integrity ?? source.integrity);
  if (!recomputeHash) return candidate;
  return build(
    GraphIntegrity(
      contentHash: GraphSpecIntegrity.calculateContentHash(candidate),
    ),
  );
}
