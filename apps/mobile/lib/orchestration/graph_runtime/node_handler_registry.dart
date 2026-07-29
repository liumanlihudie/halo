import '../graph_spec/graph_spec_validator.dart';
import 'graph_runtime_models.dart';

class NodeHandlerRegistry {
  NodeHandlerRegistry({Set<String> allowedNodeTypes = supportedGraphNodeTypes})
    : _allowedNodeTypes = Set.unmodifiable(allowedNodeTypes);

  final Set<String> _allowedNodeTypes;
  final Map<String, NodeHandler> _handlers = {};

  void register(String nodeType, NodeHandler handler) {
    if (!_allowedNodeTypes.contains(nodeType) ||
        _handlers.containsKey(nodeType)) {
      throw StateError('Node handler registration is invalid or duplicated.');
    }
    _handlers[nodeType] = handler;
  }

  NodeHandler? resolve(String nodeType) => _handlers[nodeType];
}
