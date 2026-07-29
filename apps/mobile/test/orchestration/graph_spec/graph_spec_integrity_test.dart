import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/orchestration/graph_spec/graph_spec.dart';
import 'package:halo_mobile/orchestration/graph_spec/graph_spec_integrity.dart';
import 'package:halo_mobile/orchestration/graph_spec/graph_spec_validator.dart';

import 'graph_spec_test.dart';

void main() {
  test('canonical JSON sorts object keys and excludes only contentHash', () {
    final canonical = GraphSpecIntegrity.canonicalizeJson({
      'z': 2,
      'integrity': {'signature': 'kept', 'contentHash': 'sha256:ignored'},
      'a': ['中文', true, null],
    });

    expect(
      utf8.decode(canonical),
      '{"a":["中文",true,null],"integrity":{"signature":"kept"},"z":2}',
    );
  });

  test('computed SHA-256 is stable for a hand checked canonical fixture', () {
    expect(
      GraphSpecIntegrity.sha256Hex(utf8.encode('abc')),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  test('matches the Gateway canonical vector at JS safe integer bounds', () {
    final canonical = GraphSpecIntegrity.canonicalizeJson({
      'z': -9007199254740991,
      'integrity': {'contentHash': 'sha256:ignored'},
      'a': 9007199254740991,
    });

    expect(
      utf8.decode(canonical),
      '{"a":9007199254740991,"integrity":{},"z":-9007199254740991}',
    );
    expect(
      GraphSpecIntegrity.sha256Hex(canonical),
      'acd76e18e59a3a8d219e0c976fb81ac1413d8e91a09176af0b3e3dd1a15aaeb9',
    );
  });

  test('canonicalization rejects values outside the supported JCS domain', () {
    expect(
      () => GraphSpecIntegrity.canonicalizeJson({'value': 1.5}),
      throwsFormatException,
    );
    expect(
      () => GraphSpecIntegrity.canonicalizeJson({
        'value': String.fromCharCode(0xd800),
      }),
      throwsFormatException,
    );
    expect(
      () => GraphSpecIntegrity.canonicalizeJson({'value': 9007199254740992}),
      throwsFormatException,
    );
  });

  test('validator rejects malformed and tampered content hashes', () {
    final valid = validGraphSpec();
    final malformed = copyGraph(
      valid,
      integrity: const GraphIntegrity(contentHash: 'sha256:not-hex'),
      recomputeHash: false,
    );
    final tampered = copyGraph(
      valid,
      graphId: 'halo.tampered',
      recomputeHash: false,
    );

    expect(
      GraphSpecValidator()
          .validate(malformed)
          .issues
          .map((issue) => issue.code),
      contains('invalid_content_hash'),
    );
    expect(
      GraphSpecValidator().validate(tampered).issues.map((issue) => issue.code),
      contains('content_hash_mismatch'),
    );
  });

  test('validator reports non-canonical in-memory values without throwing', () {
    final source = validGraphSpec();
    final invalid = GraphSpec(
      schemaVersion: source.schemaVersion,
      graphId: source.graphId,
      graphVersion: source.graphVersion,
      stateSchemaRef: source.stateSchemaRef,
      entryNodeId: source.entryNodeId,
      terminalNodeIds: source.terminalNodeIds,
      nodes: [
        NodeSpec(
          id: 'load',
          type: 'context.load',
          config: const {'temperature': 0.5},
          timeoutMs: 1000,
          retryPolicy: RetryPolicy(maxAttempts: 1, backoff: RetryBackoff.none),
          sideEffectPolicy: SideEffectPolicy.none,
        ),
        source.nodes.last,
      ],
      edges: source.edges,
      limits: source.limits,
      requiredCapabilities: source.requiredCapabilities,
      integrity: source.integrity,
    );

    expect(
      GraphSpecValidator().validate(invalid).issues.map((issue) => issue.code),
      contains('non_canonical_json'),
    );
  });
}
