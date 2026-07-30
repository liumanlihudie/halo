import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'strict_json_parser.dart';

enum RetryBackoff { none, fixed, exponential }

enum SideEffectPolicy { none, localTransaction, externalIdempotent }

class GraphSpecFormatException implements FormatException {
  const GraphSpecFormatException(this.message, [this.source]);

  @override
  final String message;
  @override
  final Object? source;
  @override
  int? get offset => null;

  @override
  String toString() => 'GraphSpecFormatException: $message';
}

@immutable
class StateSchemaRef {
  const StateSchemaRef({required this.schemaId, required this.version});

  factory StateSchemaRef.fromJson(Map<String, Object?> json) => StateSchemaRef(
    schemaId: json['schemaId']! as String,
    version: json['version']! as int,
  );

  final String schemaId;
  final int version;

  Map<String, Object?> toJson() => {'schemaId': schemaId, 'version': version};
}

@immutable
class RetryPolicy {
  RetryPolicy({
    required this.maxAttempts,
    required this.backoff,
    List<String> retryableErrors = const [],
  }) : retryableErrors = List.unmodifiable(retryableErrors);

  factory RetryPolicy.fromJson(Map<String, Object?> json) => RetryPolicy(
    maxAttempts: json['maxAttempts']! as int,
    backoff: RetryBackoff.values.byName(json['backoff']! as String),
    retryableErrors: List<String>.from(
      json['retryableErrors'] as List? ?? const [],
    ),
  );

  final int maxAttempts;
  final RetryBackoff backoff;
  final List<String> retryableErrors;

  Map<String, Object?> toJson() => {
    'maxAttempts': maxAttempts,
    'backoff': backoff.name,
    'retryableErrors': retryableErrors,
  };
}

@immutable
class NodeSpec {
  NodeSpec({
    required this.id,
    required this.type,
    required Map<String, Object?> config,
    required this.timeoutMs,
    required RetryPolicy retryPolicy,
    required this.sideEffectPolicy,
  }) : config = _freezeMap(config),
       retryPolicy = RetryPolicy(
         maxAttempts: retryPolicy.maxAttempts,
         backoff: retryPolicy.backoff,
         retryableErrors: List<String>.unmodifiable(
           retryPolicy.retryableErrors,
         ),
       );

  factory NodeSpec.fromJson(Map<String, Object?> json) => NodeSpec(
    id: json['id']! as String,
    type: json['type']! as String,
    config: Map<String, Object?>.from(json['config']! as Map),
    timeoutMs: json['timeoutMs']! as int,
    retryPolicy: RetryPolicy.fromJson(
      Map<String, Object?>.from(json['retryPolicy']! as Map),
    ),
    sideEffectPolicy: SideEffectPolicy.values.byName(
      json['sideEffectPolicy']! as String,
    ),
  );

  final String id;
  final String type;
  final Map<String, Object?> config;
  final int timeoutMs;
  final RetryPolicy retryPolicy;
  final SideEffectPolicy sideEffectPolicy;

  Map<String, Object?> toJson() => {
    'id': id,
    'type': type,
    'config': config,
    'timeoutMs': timeoutMs,
    'retryPolicy': retryPolicy.toJson(),
    'sideEffectPolicy': sideEffectPolicy.name,
  };
}

@immutable
class EdgeSpec {
  const EdgeSpec({
    required this.from,
    required this.to,
    required this.priority,
    this.when,
  });

  factory EdgeSpec.fromJson(Map<String, Object?> json) => EdgeSpec(
    from: json['from']! as String,
    to: json['to']! as String,
    priority: json['priority']! as int,
    when: json['when'] as String?,
  );

  final String from;
  final String to;
  final int priority;
  final String? when;

  bool get isDefault => when == null;

  Map<String, Object?> toJson() => {
    'from': from,
    'to': to,
    'priority': priority,
    if (when != null) 'when': when,
  };
}

@immutable
class GraphLimits {
  const GraphLimits({
    required this.maxNodeExecutions,
    required this.maxWallTimeMs,
    required this.maxParallelNodes,
  });

  factory GraphLimits.fromJson(Map<String, Object?> json) => GraphLimits(
    maxNodeExecutions: json['maxNodeExecutions']! as int,
    maxWallTimeMs: json['maxWallTimeMs']! as int,
    maxParallelNodes: json['maxParallelNodes']! as int,
  );

  final int maxNodeExecutions;
  final int maxWallTimeMs;
  final int maxParallelNodes;

  Map<String, Object?> toJson() => {
    'maxNodeExecutions': maxNodeExecutions,
    'maxWallTimeMs': maxWallTimeMs,
    'maxParallelNodes': maxParallelNodes,
  };
}

@immutable
class GraphIntegrity {
  const GraphIntegrity({required this.contentHash});

  factory GraphIntegrity.fromJson(Map<String, Object?> json) =>
      GraphIntegrity(contentHash: json['contentHash']! as String);

  final String contentHash;

  Map<String, Object?> toJson() => {'contentHash': contentHash};
}

@immutable
class GraphSpec {
  GraphSpec({
    required this.schemaVersion,
    required this.graphId,
    required this.graphVersion,
    required this.stateSchemaRef,
    required this.entryNodeId,
    required List<String> terminalNodeIds,
    required List<NodeSpec> nodes,
    required List<EdgeSpec> edges,
    required this.limits,
    required List<String> requiredCapabilities,
    required this.integrity,
  }) : terminalNodeIds = List<String>.unmodifiable(terminalNodeIds),
       nodes = List<NodeSpec>.unmodifiable(nodes.map(_snapshotNode)),
       edges = List<EdgeSpec>.unmodifiable(
         edges.map(
           (edge) => EdgeSpec(
             from: edge.from,
             to: edge.to,
             priority: edge.priority,
             when: edge.when,
           ),
         ),
       ),
       requiredCapabilities = List<String>.unmodifiable(requiredCapabilities);

  factory GraphSpec.decodeUtf8(List<int> bytes) {
    if (bytes.length > 256 * 1024) {
      throw const GraphSpecFormatException('GraphSpec exceeds 256 KiB.');
    }
    late final String source;
    try {
      source = utf8.decode(bytes, allowMalformed: false);
    } on FormatException catch (error) {
      throw GraphSpecFormatException('GraphSpec is not valid UTF-8.', error);
    }
    late final Object? value;
    try {
      value = StrictJsonParser(source).parse();
    } on StrictJsonFormatException catch (error) {
      throw GraphSpecFormatException(error.message, error);
    }
    if (value is! Map<String, Object?>) {
      throw const GraphSpecFormatException(
        'GraphSpec root must be a JSON object.',
      );
    }
    return GraphSpec.fromJson(value);
  }

  factory GraphSpec.decodeString(String source) {
    if (source.length > 256 * 1024) {
      throw const GraphSpecFormatException('GraphSpec exceeds 256 KiB.');
    }
    return GraphSpec.decodeUtf8(utf8.encode(source));
  }

  /// Internal DTO entry point for already-parsed trusted maps.
  ///
  /// External imports must use [decodeUtf8] or [decodeString] so duplicate
  /// object keys and the pre-parse byte limit cannot be bypassed.
  @visibleForTesting
  factory GraphSpec.fromJson(Map<String, Object?> json) {
    try {
      _validateGraphJson(json);
      return GraphSpec(
        schemaVersion: json['schemaVersion']! as int,
        graphId: json['graphId']! as String,
        graphVersion: json['graphVersion']! as int,
        stateSchemaRef: StateSchemaRef.fromJson(
          Map<String, Object?>.from(json['stateSchemaRef']! as Map),
        ),
        entryNodeId: json['entryNodeId']! as String,
        terminalNodeIds: List<String>.from(json['terminalNodeIds']! as List),
        nodes: (json['nodes']! as List)
            .map(
              (value) =>
                  NodeSpec.fromJson(Map<String, Object?>.from(value as Map)),
            )
            .toList(),
        edges: (json['edges']! as List)
            .map(
              (value) =>
                  EdgeSpec.fromJson(Map<String, Object?>.from(value as Map)),
            )
            .toList(),
        limits: GraphLimits.fromJson(
          Map<String, Object?>.from(json['limits']! as Map),
        ),
        requiredCapabilities: List<String>.from(
          json['requiredCapabilities']! as List,
        ),
        integrity: GraphIntegrity.fromJson(
          Map<String, Object?>.from(json['integrity']! as Map),
        ),
      );
    } on GraphSpecFormatException {
      rethrow;
    } catch (error) {
      throw GraphSpecFormatException('Invalid GraphSpec DTO.', error);
    }
  }

  final int schemaVersion;
  final String graphId;
  final int graphVersion;
  final StateSchemaRef stateSchemaRef;
  final String entryNodeId;
  final List<String> terminalNodeIds;
  final List<NodeSpec> nodes;
  final List<EdgeSpec> edges;
  final GraphLimits limits;
  final List<String> requiredCapabilities;
  final GraphIntegrity integrity;

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'graphId': graphId,
    'graphVersion': graphVersion,
    'stateSchemaRef': stateSchemaRef.toJson(),
    'entryNodeId': entryNodeId,
    'terminalNodeIds': terminalNodeIds,
    'nodes': nodes.map((node) => node.toJson()).toList(),
    'edges': edges.map((edge) => edge.toJson()).toList(),
    'limits': limits.toJson(),
    'requiredCapabilities': requiredCapabilities,
    'integrity': integrity.toJson(),
  };
}

NodeSpec _snapshotNode(NodeSpec node) => NodeSpec(
  id: node.id,
  type: node.type,
  config: node.config,
  timeoutMs: node.timeoutMs,
  retryPolicy: node.retryPolicy,
  sideEffectPolicy: node.sideEffectPolicy,
);

Map<String, Object?> _freezeMap(Map<String, Object?> source) {
  final copied = jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
  return Map<String, Object?>.unmodifiable(
    copied.map((key, value) => MapEntry(key, _freezeJson(value))),
  );
}

Object? _freezeJson(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable(
      value.map((key, nested) => MapEntry(key.toString(), _freezeJson(nested))),
    );
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_freezeJson));
  }
  return value;
}

void _validateGraphJson(Map<String, Object?> json) {
  _validateJsonTree(json, depth: 0);
  final encodedLength = utf8.encode(jsonEncode(json)).length;
  if (encodedLength > 256 * 1024) {
    throw const GraphSpecFormatException('GraphSpec exceeds 256 KiB.');
  }
  _expectKeys(json, const {
    'schemaVersion',
    'graphId',
    'graphVersion',
    'stateSchemaRef',
    'entryNodeId',
    'terminalNodeIds',
    'nodes',
    'edges',
    'limits',
    'requiredCapabilities',
    'integrity',
  });
  _expectType<int>(json, 'schemaVersion');
  _expectType<String>(json, 'graphId');
  _expectType<int>(json, 'graphVersion');
  _expectType<String>(json, 'entryNodeId');
  _expectStringList(json, 'terminalNodeIds');
  _expectStringList(json, 'requiredCapabilities');

  final schemaRef = _expectMap(json, 'stateSchemaRef');
  _expectKeys(schemaRef, const {'schemaId', 'version'});
  _expectType<String>(schemaRef, 'schemaId');
  _expectType<int>(schemaRef, 'version');

  final nodes = _expectList(json, 'nodes', maximumLength: 256);
  for (final value in nodes) {
    if (value is! Map) {
      throw const GraphSpecFormatException('Node must be an object.');
    }
    final node = Map<String, Object?>.from(value);
    _expectKeys(node, const {
      'id',
      'type',
      'config',
      'timeoutMs',
      'retryPolicy',
      'sideEffectPolicy',
    });
    _expectType<String>(node, 'id');
    final type = _expectType<String>(node, 'type');
    final config = _expectMap(node, 'config');
    validateNodeConfigShape(type, config);
    _expectType<int>(node, 'timeoutMs');
    _expectType<String>(node, 'sideEffectPolicy');
    final retryPolicy = _expectMap(node, 'retryPolicy');
    _expectKeys(retryPolicy, const {
      'maxAttempts',
      'backoff',
      'retryableErrors',
    });
    _expectType<int>(retryPolicy, 'maxAttempts');
    _expectType<String>(retryPolicy, 'backoff');
    _expectStringList(retryPolicy, 'retryableErrors');
  }

  final edges = _expectList(json, 'edges', maximumLength: 1024);
  for (final value in edges) {
    if (value is! Map) {
      throw const GraphSpecFormatException('Edge must be an object.');
    }
    final edge = Map<String, Object?>.from(value);
    _expectKeys(edge, const {'from', 'to', 'priority', 'when'});
    _expectType<String>(edge, 'from');
    _expectType<String>(edge, 'to');
    _expectType<int>(edge, 'priority');
    if (edge.containsKey('when')) _expectType<String>(edge, 'when');
  }

  final limits = _expectMap(json, 'limits');
  _expectKeys(limits, const {
    'maxNodeExecutions',
    'maxWallTimeMs',
    'maxParallelNodes',
  });
  _expectType<int>(limits, 'maxNodeExecutions');
  _expectType<int>(limits, 'maxWallTimeMs');
  _expectType<int>(limits, 'maxParallelNodes');

  final integrity = _expectMap(json, 'integrity');
  _expectKeys(integrity, const {'contentHash'});
  _expectType<String>(integrity, 'contentHash');
}

void _validateJsonTree(Object? value, {required int depth}) {
  if (depth > 32) {
    throw const GraphSpecFormatException('GraphSpec nesting is too deep.');
  }
  if (value is String) {
    _validateUnicodeString(value);
    return;
  }
  if (value == null || value is bool) return;
  if (value is int) {
    if (value < -9007199254740991 || value > 9007199254740991) {
      throw const GraphSpecFormatException(
        'Integer is outside the JS safe integer range.',
      );
    }
    return;
  }
  if (value is num) {
    throw const GraphSpecFormatException(
      'Only JS-safe integer JSON numbers are supported.',
    );
  }
  if (value is List) {
    for (final nested in value) {
      _validateJsonTree(nested, depth: depth + 1);
    }
    return;
  }
  if (value is Map) {
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw const GraphSpecFormatException(
          'JSON object keys must be strings.',
        );
      }
      _validateJsonTree(entry.value, depth: depth + 1);
    }
    return;
  }
  throw const GraphSpecFormatException('Unsupported JSON value.');
}

void _validateUnicodeString(String value) {
  final units = value.codeUnits;
  for (var index = 0; index < units.length; index++) {
    final unit = units[index];
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (index + 1 >= units.length ||
          units[index + 1] < 0xdc00 ||
          units[index + 1] > 0xdfff) {
        throw const GraphSpecFormatException(
          'String contains an unpaired surrogate.',
        );
      }
      index += 1;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      throw const GraphSpecFormatException(
        'String contains an unpaired surrogate.',
      );
    }
  }
}

void validateNodeConfigShape(String type, Map<String, Object?> config) {
  if (type == 'event.emit') {
    _expectKeys(config, const {'eventType', 'payloadRefs'});
    _expectType<String>(config, 'eventType');
    if (config.containsKey('payloadRefs')) {
      _expectStringList(config, 'payloadRefs');
    }
    return;
  }
  if (type == 'loop.guard') {
    _expectKeys(config, const {'maxIterations'});
    if (config.containsKey('maxIterations')) {
      _expectType<int>(config, 'maxIterations');
    }
    return;
  }
  if (config.isNotEmpty) {
    throw GraphSpecFormatException(
      'Node type "$type" does not accept config fields in schema v1.',
    );
  }
}

void _expectKeys(Map<String, Object?> json, Set<String> allowed) {
  final unknown = json.keys.where((key) => !allowed.contains(key)).toList();
  if (unknown.isNotEmpty) {
    throw GraphSpecFormatException('Unknown fields: ${unknown.join(', ')}.');
  }
}

T _expectType<T>(Map<String, Object?> json, String key) {
  if (!json.containsKey(key) || json[key] is! T) {
    throw GraphSpecFormatException('Field "$key" must be $T.');
  }
  return json[key]! as T;
}

Map<String, Object?> _expectMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map) {
    throw GraphSpecFormatException('Field "$key" must be an object.');
  }
  return Map<String, Object?>.from(value);
}

List<Object?> _expectList(
  Map<String, Object?> json,
  String key, {
  int? maximumLength,
}) {
  final value = json[key];
  if (value is! List) {
    throw GraphSpecFormatException('Field "$key" must be an array.');
  }
  if (maximumLength != null && value.length > maximumLength) {
    throw GraphSpecFormatException('Field "$key" has too many items.');
  }
  return List<Object?>.from(value);
}

void _expectStringList(Map<String, Object?> json, String key) {
  final values = _expectList(json, key);
  if (values.any((value) => value is! String)) {
    throw GraphSpecFormatException('Field "$key" must contain strings.');
  }
}
