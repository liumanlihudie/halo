import 'dart:convert';

class StrictJsonFormatException implements FormatException {
  const StrictJsonFormatException(this.message);

  @override
  final String message;
  @override
  Object? get source => null;
  @override
  int? get offset => null;
}

class StrictJsonParser {
  StrictJsonParser(this.source);

  final String source;
  int _position = 0;

  Object? parse() {
    final value = _parseValue(depth: 0);
    _skipWhitespace();
    if (_position != source.length) {
      _fail('Unexpected trailing JSON input.');
    }
    return value;
  }

  Object? _parseValue({required int depth}) {
    if (depth > 32) _fail('JSON nesting is too deep.');
    _skipWhitespace();
    if (_position >= source.length) _fail('Unexpected end of JSON.');
    return switch (source.codeUnitAt(_position)) {
      0x7b => _parseObject(depth: depth),
      0x5b => _parseArray(depth: depth),
      0x22 => _parseString(),
      0x74 => _parseKeyword('true', true),
      0x66 => _parseKeyword('false', false),
      0x6e => _parseKeyword('null', null),
      _ => _parseInteger(),
    };
  }

  Map<String, Object?> _parseObject({required int depth}) {
    _position += 1;
    final result = <String, Object?>{};
    final keys = <String>{};
    _skipWhitespace();
    if (_consume('}')) return result;
    while (true) {
      _skipWhitespace();
      if (_position >= source.length || source.codeUnitAt(_position) != 0x22) {
        _fail('Object keys must be JSON strings.');
      }
      final key = _parseString();
      if (!keys.add(key)) _fail('Duplicate object key: $key.');
      _skipWhitespace();
      _expect(':');
      result[key] = _parseValue(depth: depth + 1);
      _skipWhitespace();
      if (_consume('}')) return result;
      _expect(',');
    }
  }

  List<Object?> _parseArray({required int depth}) {
    _position += 1;
    final result = <Object?>[];
    _skipWhitespace();
    if (_consume(']')) return result;
    while (true) {
      result.add(_parseValue(depth: depth + 1));
      _skipWhitespace();
      if (_consume(']')) return result;
      _expect(',');
    }
  }

  String _parseString() {
    final start = _position;
    _position += 1;
    var escaped = false;
    while (_position < source.length) {
      final unit = source.codeUnitAt(_position);
      _position += 1;
      if (escaped) {
        escaped = false;
        continue;
      }
      if (unit == 0x5c) {
        escaped = true;
        continue;
      }
      if (unit == 0x22) {
        try {
          final value =
              jsonDecode(source.substring(start, _position)) as String;
          _validateUnicode(value);
          return value;
        } on FormatException {
          _fail('Invalid JSON string.');
        }
      }
      if (unit < 0x20) _fail('Unescaped control character in JSON string.');
    }
    _fail('Unclosed JSON string.');
  }

  Object? _parseKeyword(String token, Object? value) {
    if (!source.startsWith(token, _position)) {
      _fail('Invalid JSON literal.');
    }
    _position += token.length;
    return value;
  }

  int _parseInteger() {
    final start = _position;
    _consume('-');
    final digitsStart = _position;
    while (_position < source.length) {
      final unit = source.codeUnitAt(_position);
      if (unit < 0x30 || unit > 0x39) break;
      _position += 1;
    }
    if (digitsStart == _position ||
        (source.codeUnitAt(digitsStart) == 0x30 &&
            _position - digitsStart > 1)) {
      _fail('Invalid JSON integer.');
    }
    if (_position < source.length) {
      final unit = source.codeUnitAt(_position);
      if (unit == 0x2e || unit == 0x45 || unit == 0x65) {
        _fail('Only JS-safe integers are supported.');
      }
    }
    final parsed = BigInt.parse(source.substring(start, _position));
    final maximum = BigInt.from(9007199254740991);
    if (parsed < -maximum || parsed > maximum) {
      _fail('Integer is outside the JS safe integer range.');
    }
    return parsed.toInt();
  }

  void _skipWhitespace() {
    while (_position < source.length) {
      final unit = source.codeUnitAt(_position);
      if (unit != 0x20 && unit != 0x09 && unit != 0x0a && unit != 0x0d) {
        return;
      }
      _position += 1;
    }
  }

  bool _consume(String token) {
    if (!source.startsWith(token, _position)) return false;
    _position += token.length;
    return true;
  }

  void _expect(String token) {
    if (!_consume(token)) _fail('Expected "$token".');
  }

  Never _fail(String message) => throw StrictJsonFormatException(message);
}

void _validateUnicode(String value) {
  final units = value.codeUnits;
  for (var index = 0; index < units.length; index++) {
    final unit = units[index];
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (index + 1 >= units.length ||
          units[index + 1] < 0xdc00 ||
          units[index + 1] > 0xdfff) {
        throw const FormatException('Unpaired Unicode surrogate.');
      }
      index += 1;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      throw const FormatException('Unpaired Unicode surrogate.');
    }
  }
}
