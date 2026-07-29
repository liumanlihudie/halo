import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'graph_spec.dart';

enum ConditionValueType {
  string,
  int64,
  boolean,
  stringArray,
  int64Array,
  booleanArray,
}

@immutable
class StateFieldSchema {
  const StateFieldSchema(this.type, {this.nullable = false});

  final ConditionValueType type;
  final bool nullable;
}

abstract interface class StateSchemaResolver {
  StateFieldSchema? resolve(StateSchemaRef schemaRef, String path);
}

class MapStateSchemaResolver implements StateSchemaResolver {
  MapStateSchemaResolver(Map<String, StateFieldSchema> fields)
    : _fields = Map.unmodifiable(fields);

  final Map<String, StateFieldSchema> _fields;

  @override
  StateFieldSchema? resolve(StateSchemaRef schemaRef, String path) =>
      _fields[path];
}

class EmptyStateSchemaResolver implements StateSchemaResolver {
  const EmptyStateSchemaResolver();

  @override
  StateFieldSchema? resolve(StateSchemaRef schemaRef, String path) => null;
}

sealed class ConditionExpression {
  const ConditionExpression();
}

@immutable
class ConditionOr extends ConditionExpression {
  const ConditionOr(this.left, this.right);
  final ConditionExpression left;
  final ConditionExpression right;
}

@immutable
class ConditionAnd extends ConditionExpression {
  const ConditionAnd(this.left, this.right);
  final ConditionExpression left;
  final ConditionExpression right;
}

@immutable
class ConditionNot extends ConditionExpression {
  const ConditionNot(this.operand);
  final ConditionExpression operand;
}

enum ConditionComparator {
  equal,
  notEqual,
  less,
  lessOrEqual,
  greater,
  greaterOrEqual,
}

@immutable
class ConditionLiteral {
  const ConditionLiteral(this.value, this.type);
  final Object? value;
  final ConditionValueType? type;
}

@immutable
class ConditionComparison extends ConditionExpression {
  const ConditionComparison({
    required this.path,
    required this.comparator,
    required this.literal,
  });

  final String path;
  final ConditionComparator comparator;
  final ConditionLiteral literal;
}

@immutable
class ConditionExists extends ConditionExpression {
  const ConditionExists(this.path);
  final String path;
}

@immutable
class ConditionIsNull extends ConditionExpression {
  const ConditionIsNull(this.path);
  final String path;
}

@immutable
class ConditionContains extends ConditionExpression {
  const ConditionContains(this.path, this.literal);
  final String path;
  final ConditionLiteral literal;
}

class ConditionDecodeException implements FormatException {
  const ConditionDecodeException(this.code, this.message, [this.source]);

  final String code;
  @override
  final String message;
  @override
  final Object? source;
  @override
  int? get offset => null;

  @override
  String toString() => '$code: $message';
}

class ConditionExpressionDecoder {
  factory ConditionExpressionDecoder({
    required StateSchemaResolver schemaResolver,
  }) => ConditionExpressionDecoder._(schemaResolver);

  ConditionExpressionDecoder._(this._schemaResolver);

  final StateSchemaResolver _schemaResolver;

  ConditionExpression decode(
    String source, {
    required StateSchemaRef schemaRef,
  }) {
    if (source.length > 4096) {
      throw const ConditionDecodeException(
        'condition_syntax_error',
        'Condition exceeds the maximum length.',
      );
    }
    final parser = _ConditionParser(
      source,
      schemaRef: schemaRef,
      schemaResolver: _schemaResolver,
    );
    return parser.parse();
  }
}

class _ConditionParser {
  _ConditionParser(
    this.source, {
    required this.schemaRef,
    required this.schemaResolver,
  });

  final String source;
  final StateSchemaRef schemaRef;
  final StateSchemaResolver schemaResolver;
  int position = 0;
  int _depth = 0;
  int _nodeCount = 0;

  ConditionExpression parse() {
    try {
      final expression = _parseOr();
      _skipWhitespace();
      if (position != source.length) _syntax('Unexpected input.');
      return expression;
    } on ConditionDecodeException {
      rethrow;
    } on FormatException {
      _syntax('Invalid JSON string literal.');
    }
  }

  ConditionExpression _parseOr() {
    var expression = _parseAnd();
    while (_consume('||')) {
      expression = _record(ConditionOr(expression, _parseAnd()));
    }
    return expression;
  }

  ConditionExpression _parseAnd() {
    var expression = _parseUnary();
    while (_consume('&&')) {
      expression = _record(ConditionAnd(expression, _parseUnary()));
    }
    return expression;
  }

  ConditionExpression _parseUnary() {
    if (_consume('!')) return _record(ConditionNot(_parsePrimary()));
    return _parsePrimary();
  }

  ConditionExpression _parsePrimary() {
    if (_consume('(')) {
      final expression = _withinDepth(_parseOr);
      _expect(')');
      return expression;
    }
    if (_consumeWord('exists')) {
      _expect('(');
      final path = _parsePath();
      _expect(')');
      _resolve(path);
      return _record(ConditionExists(path));
    }
    if (_consumeWord('isNull')) {
      _expect('(');
      final path = _parsePath();
      _expect(')');
      final field = _resolve(path);
      if (!field.nullable) _typeError('isNull requires a nullable field.');
      return _record(ConditionIsNull(path));
    }
    if (_consumeWord('contains')) {
      _expect('(');
      final path = _parsePath();
      _expect(',');
      final literal = _parseLiteral();
      _expect(')');
      final field = _resolve(path);
      final elementType = switch (field.type) {
        ConditionValueType.stringArray => ConditionValueType.string,
        ConditionValueType.int64Array => ConditionValueType.int64,
        ConditionValueType.booleanArray => ConditionValueType.boolean,
        _ => null,
      };
      if (elementType == null || literal.type != elementType) {
        _typeError('contains literal does not match the array element type.');
      }
      return _record(ConditionContains(path, literal));
    }

    final path = _parsePath();
    final comparator = _parseComparator();
    final literal = _parseLiteral();
    final field = _resolve(path);
    _validateComparison(field, comparator, literal);
    return _record(
      ConditionComparison(path: path, comparator: comparator, literal: literal),
    );
  }

  String _parsePath() {
    _skipWhitespace();
    final start = position;
    if (!_consumeRaw(r'$')) _syntax('Expected a state path.');
    while (position < source.length) {
      if (_consumeRaw('.')) {
        if (position >= source.length ||
            !_isIdentifierStart(source.codeUnitAt(position))) {
          _syntax('Invalid path identifier.');
        }
        position += 1;
        while (position < source.length &&
            _isIdentifierPart(source.codeUnitAt(position))) {
          position += 1;
        }
        continue;
      }
      if (_consumeRaw('[')) {
        final indexStart = position;
        while (position < source.length &&
            _isDigit(source.codeUnitAt(position))) {
          position += 1;
        }
        if (indexStart == position ||
            (source[indexStart] == '0' && position - indexStart > 1)) {
          _syntax('Invalid array index.');
        }
        if (!_consumeRaw(']')) _syntax('Unclosed array index.');
        continue;
      }
      break;
    }
    return source.substring(start, position);
  }

  ConditionComparator _parseComparator() {
    for (final candidate in const [
      ('==', ConditionComparator.equal),
      ('!=', ConditionComparator.notEqual),
      ('<=', ConditionComparator.lessOrEqual),
      ('>=', ConditionComparator.greaterOrEqual),
      ('<', ConditionComparator.less),
      ('>', ConditionComparator.greater),
    ]) {
      if (_consume(candidate.$1)) return candidate.$2;
    }
    _syntax('Expected a comparison operator.');
  }

  ConditionLiteral _parseLiteral() {
    _skipWhitespace();
    if (position >= source.length) _syntax('Expected a literal.');
    if (source[position] == '"') {
      final start = position;
      position += 1;
      var escaped = false;
      while (position < source.length) {
        final unit = source.codeUnitAt(position);
        position += 1;
        if (escaped) {
          escaped = false;
          continue;
        }
        if (unit == 0x5c) {
          escaped = true;
          continue;
        }
        if (unit == 0x22) {
          final value = jsonDecode(source.substring(start, position)) as String;
          if (!_hasValidUnicode(value)) {
            throw const ConditionDecodeException(
              'condition_invalid_unicode',
              'String literal contains an unpaired Unicode surrogate.',
            );
          }
          return ConditionLiteral(value, ConditionValueType.string);
        }
        if (unit < 0x20) _syntax('Control characters are not allowed.');
      }
      _syntax('Unclosed string literal.');
    }
    if (_consumeWord('true')) {
      return const ConditionLiteral(true, ConditionValueType.boolean);
    }
    if (_consumeWord('false')) {
      return const ConditionLiteral(false, ConditionValueType.boolean);
    }
    if (_consumeWord('null')) return const ConditionLiteral(null, null);

    final start = position;
    _consumeRaw('-');
    final digitsStart = position;
    while (position < source.length && _isDigit(source.codeUnitAt(position))) {
      position += 1;
    }
    if (digitsStart == position ||
        (source[digitsStart] == '0' && position - digitsStart > 1)) {
      _syntax('Invalid signed integer.');
    }
    final value = BigInt.parse(source.substring(start, position));
    final maximum = BigInt.from(9007199254740991);
    final minimum = -maximum;
    if (value < minimum || value > maximum) {
      throw const ConditionDecodeException(
        'condition_number_out_of_range',
        'Integer literal is outside the JS safe integer range.',
      );
    }
    return ConditionLiteral(value.toInt(), ConditionValueType.int64);
  }

  StateFieldSchema _resolve(String path) {
    final field = schemaResolver.resolve(schemaRef, path);
    if (field == null) {
      throw ConditionDecodeException(
        'condition_unknown_path',
        'Unknown state path: $path',
      );
    }
    return field;
  }

  void _validateComparison(
    StateFieldSchema field,
    ConditionComparator comparator,
    ConditionLiteral literal,
  ) {
    final ordering =
        comparator != ConditionComparator.equal &&
        comparator != ConditionComparator.notEqual;
    if (literal.value == null) {
      if (ordering || !field.nullable) {
        _typeError('null is only valid for nullable equality comparisons.');
      }
      return;
    }
    if (field.type != literal.type) {
      _typeError('Literal type does not match the state field.');
    }
    if (ordering && field.type != ConditionValueType.int64) {
      _typeError('Ordering comparisons require signed Int64 fields.');
    }
  }

  bool _consume(String token) {
    _skipWhitespace();
    return _consumeRaw(token);
  }

  bool _consumeWord(String token) {
    _skipWhitespace();
    if (!source.startsWith(token, position)) return false;
    final end = position + token.length;
    if (end < source.length && _isIdentifierPart(source.codeUnitAt(end))) {
      return false;
    }
    position = end;
    return true;
  }

  bool _consumeRaw(String token) {
    if (!source.startsWith(token, position)) return false;
    position += token.length;
    return true;
  }

  void _expect(String token) {
    if (!_consume(token)) _syntax('Expected "$token".');
  }

  void _skipWhitespace() {
    while (position < source.length) {
      final unit = source.codeUnitAt(position);
      if (unit != 0x20 && unit != 0x09 && unit != 0x0a && unit != 0x0d) {
        return;
      }
      position += 1;
    }
  }

  T _withinDepth<T>(T Function() parse) {
    _depth += 1;
    if (_depth > 32) _complexityError();
    try {
      return parse();
    } finally {
      _depth -= 1;
    }
  }

  T _record<T extends ConditionExpression>(T expression) {
    _nodeCount += 1;
    if (_nodeCount > 128) _complexityError();
    return expression;
  }

  Never _syntax(String message) =>
      throw ConditionDecodeException('condition_syntax_error', message, source);

  Never _typeError(String message) =>
      throw ConditionDecodeException('condition_type_error', message, source);

  Never _complexityError() => throw const ConditionDecodeException(
    'condition_complexity_exceeded',
    'Condition exceeds AST node or recursion limits.',
  );
}

bool _isIdentifierStart(int unit) =>
    (unit >= 0x41 && unit <= 0x5a) ||
    (unit >= 0x61 && unit <= 0x7a) ||
    unit == 0x5f;

bool _isIdentifierPart(int unit) => _isIdentifierStart(unit) || _isDigit(unit);

bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;

bool _hasValidUnicode(String value) {
  final units = value.codeUnits;
  for (var index = 0; index < units.length; index++) {
    final unit = units[index];
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (index + 1 >= units.length ||
          units[index + 1] < 0xdc00 ||
          units[index + 1] > 0xdfff) {
        return false;
      }
      index += 1;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}
