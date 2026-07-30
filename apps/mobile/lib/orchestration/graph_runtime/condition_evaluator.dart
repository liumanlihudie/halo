import '../graph_spec/condition_expression.dart';
import 'graph_runtime_models.dart';

class GraphConditionException implements Exception {
  const GraphConditionException(this.code, this.safeMessage);

  final String code;
  final String safeMessage;
}

class GraphConditionEvaluator {
  bool evaluate(ConditionExpression expression, GraphState state) {
    return switch (expression) {
      ConditionOr(:final left, :final right) =>
        evaluate(left, state) || evaluate(right, state),
      ConditionAnd(:final left, :final right) =>
        evaluate(left, state) && evaluate(right, state),
      ConditionNot(:final operand) => !evaluate(operand, state),
      ConditionExists(:final path) => _resolve(path, state).exists,
      ConditionIsNull(:final path) => _required(path, state) == null,
      ConditionContains(:final path, :final literal) => _contains(
        _required(path, state),
        literal.value,
      ),
      ConditionComparison(:final path, :final comparator, :final literal) =>
        _compare(_required(path, state), comparator, literal.value),
    };
  }

  bool _contains(Object? collection, Object? value) {
    if (collection is! List) {
      throw const GraphConditionException(
        'condition_type_error',
        '条件字段类型与图定义不匹配',
      );
    }
    return collection.contains(value);
  }

  bool _compare(
    Object? actual,
    ConditionComparator comparator,
    Object? expected,
  ) {
    if (actual != null &&
        expected != null &&
        actual.runtimeType != expected.runtimeType) {
      throw const GraphConditionException(
        'condition_type_error',
        '条件字段类型与图定义不匹配',
      );
    }
    if (comparator == ConditionComparator.equal) return actual == expected;
    if (comparator == ConditionComparator.notEqual) return actual != expected;
    if (actual is! int || expected is! int) {
      throw const GraphConditionException(
        'condition_type_error',
        '条件字段类型与图定义不匹配',
      );
    }
    return switch (comparator) {
      ConditionComparator.less => actual < expected,
      ConditionComparator.lessOrEqual => actual <= expected,
      ConditionComparator.greater => actual > expected,
      ConditionComparator.greaterOrEqual => actual >= expected,
      _ => throw StateError('Equality was handled above.'),
    };
  }

  Object? _required(String path, GraphState state) {
    final resolved = _resolve(path, state);
    if (!resolved.exists) {
      throw const GraphConditionException(
        'condition_missing_field',
        '条件依赖的状态字段不存在',
      );
    }
    return resolved.value;
  }

  ({bool exists, Object? value}) _resolve(String path, GraphState state) {
    Object? current = state.values;
    var position = 1;
    while (position < path.length) {
      if (path[position] == '.') {
        position += 1;
        final start = position;
        while (position < path.length &&
            path[position] != '.' &&
            path[position] != '[') {
          position += 1;
        }
        final key = path.substring(start, position);
        if (current is! Map<String, Object?> || !current.containsKey(key)) {
          return (exists: false, value: null);
        }
        current = current[key];
      } else if (path[position] == '[') {
        position += 1;
        final end = path.indexOf(']', position);
        if (end < 0 || current is! List) {
          return (exists: false, value: null);
        }
        final index = int.parse(path.substring(position, end));
        if (index >= current.length) return (exists: false, value: null);
        current = current[index];
        position = end + 1;
      } else {
        return (exists: false, value: null);
      }
    }
    return (exists: true, value: current);
  }
}
