import 'dart:convert';

const runtimeUnicodeSecurityDataVersion = '15.1.0';

bool isCanonicalRuntimeId(String value) =>
    isSafeRuntimeIdentifier(value, maxUtf8Bytes: 128) &&
    RegExp(r'^[a-z][a-z0-9._-]{0,127}$').hasMatch(value);

bool isSafeRuntimeIdentifier(String value, {required int maxUtf8Bytes}) =>
    isSafeRuntimeDisplayText(value, maxUtf8Bytes: maxUtf8Bytes);

bool isSafeRuntimeDisplayText(String value, {int maxUtf8Bytes = 240}) {
  if (value.isEmpty ||
      value != value.trim() ||
      !_hasWellFormedUtf16(value) ||
      utf8.encode(value).length > maxUtf8Bytes) {
    return false;
  }
  for (final rune in value.runes) {
    if (_isForbiddenScalar(rune)) return false;
  }
  return true;
}

bool _hasWellFormedUtf16(String value) {
  for (var index = 0; index < value.length; index++) {
    final unit = value.codeUnitAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++index >= value.length) return false;
      final low = value.codeUnitAt(index);
      if (low < 0xdc00 || low > 0xdfff) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}

bool _isForbiddenScalar(int rune) =>
    rune <= 0x1f ||
    (rune >= 0x7f && rune <= 0x9f) ||
    rune == 0x34f ||
    (rune >= 0x2028 && rune <= 0x202e) ||
    _isUnicodeFormat(rune) ||
    (rune >= 0xfdd0 && rune <= 0xfdef) ||
    (rune & 0xffff) == 0xfffe ||
    (rune & 0xffff) == 0xffff ||
    (rune >= 0xe0000 && rune <= 0xe007f);

// Generated from Unicode 15.1.0 General_Category=Format (Cf).
const _unicodeFormatRanges = <(int, int)>[
  (0x00ad, 0x00ad),
  (0x0600, 0x0605),
  (0x061c, 0x061c),
  (0x06dd, 0x06dd),
  (0x070f, 0x070f),
  (0x0890, 0x0891),
  (0x08e2, 0x08e2),
  (0x180e, 0x180e),
  (0x200b, 0x200f),
  (0x202a, 0x202e),
  (0x2060, 0x2064),
  (0x2066, 0x206f),
  (0xfeff, 0xfeff),
  (0xfff9, 0xfffb),
  (0x110bd, 0x110bd),
  (0x110cd, 0x110cd),
  (0x13430, 0x13455),
  (0x1bca0, 0x1bca3),
  (0x1d173, 0x1d17a),
  (0xe0001, 0xe0001),
  (0xe0020, 0xe007f),
];

bool _isUnicodeFormat(int rune) {
  var low = 0;
  var high = _unicodeFormatRanges.length - 1;
  while (low <= high) {
    final middle = (low + high) >> 1;
    final range = _unicodeFormatRanges[middle];
    if (rune < range.$1) {
      high = middle - 1;
    } else if (rune > range.$2) {
      low = middle + 1;
    } else {
      return true;
    }
  }
  return false;
}
