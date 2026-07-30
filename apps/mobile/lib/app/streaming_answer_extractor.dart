/// Incrementally extracts the user-visible `Answer` string value from a JSON
/// object arriving as raw streaming text deltas.
///
/// The extractor scans the accumulated raw text for the first `"Answer"` key
/// (whitespace is allowed around the `:`), then decodes the JSON string value
/// one code unit at a time, stopping at the unescaped closing quote. Escape
/// sequences (`\" \\ \/ \b \f \n \r \t \uXXXX`, including surrogate pairs) are
/// decoded even when split across chunk boundaries. Because it is a plain
/// character-level state machine, anything before the key — including a
/// leading markdown fence line (``` or ```json) — is skipped naturally, the
/// scan never backtracks, and total work is O(n) over all fed chunks.
///
/// This is a *preview-only* decoder: only the decoded Answer value ever leaves
/// it, never surrounding raw model text, and final validation of the complete
/// payload stays with the existing strict decode-and-project path.
final class StreamingAnswerExtractor {
  static const String _key = '"Answer"';

  static const int _quote = 0x22;
  static const int _backslash = 0x5C;
  static const int _colon = 0x3A;
  static const int _unicodeEscape = 0x75; // 'u'

  final StringBuffer _answer = StringBuffer();
  final StringBuffer _escape = StringBuffer();
  String? _answerCache = '';
  _ExtractorPhase _phase = _ExtractorPhase.searchingKey;
  int _keyMatched = 0;
  int? _pendingHighSurrogate;
  bool _complete = false;

  /// True once the unescaped closing quote of the Answer value was seen.
  bool get answerComplete => _complete;

  /// The Answer value decoded so far.
  String get answerSoFar => _answerCache ??= _answer.toString();

  /// Feeds the next raw chunk; returns the newly decoded suffix of the Answer
  /// value (empty when nothing new).
  String feed(String chunk) {
    if (_complete || chunk.isEmpty) {
      return '';
    }
    final decoded = StringBuffer();
    for (var index = 0; index < chunk.length && !_complete; index += 1) {
      final unit = chunk.codeUnitAt(index);
      switch (_phase) {
        case _ExtractorPhase.searchingKey:
          _matchKeyUnit(unit);
        case _ExtractorPhase.expectingColon:
          if (_isJsonWhitespace(unit)) {
            break;
          }
          if (unit == _colon) {
            _phase = _ExtractorPhase.expectingOpeningQuote;
          } else {
            _restartSearch(unit);
          }
        case _ExtractorPhase.expectingOpeningQuote:
          if (_isJsonWhitespace(unit)) {
            break;
          }
          if (unit == _quote) {
            _phase = _ExtractorPhase.inValue;
          } else {
            _restartSearch(unit);
          }
        case _ExtractorPhase.inValue:
          _decodeValueUnit(unit, decoded);
        case _ExtractorPhase.done:
          break;
      }
    }
    if (decoded.isEmpty) {
      return '';
    }
    final suffix = decoded.toString();
    _answer.write(suffix);
    _answerCache = null;
    return suffix;
  }

  void _matchKeyUnit(int unit) {
    if (unit == _key.codeUnitAt(_keyMatched)) {
      _keyMatched += 1;
      if (_keyMatched == _key.length) {
        _keyMatched = 0;
        _phase = _ExtractorPhase.expectingColon;
      }
      return;
    }
    // `"Answer"` has no repeated prefix other than the opening quote, so the
    // only resumable partial match after a mismatch is a fresh `"`.
    _keyMatched = unit == _quote ? 1 : 0;
  }

  void _restartSearch(int unit) {
    _phase = _ExtractorPhase.searchingKey;
    _keyMatched = unit == _quote ? 1 : 0;
  }

  void _decodeValueUnit(int unit, StringBuffer decoded) {
    if (_escape.isNotEmpty) {
      _continueEscape(unit, decoded);
      return;
    }
    if (unit == _backslash) {
      _escape.writeCharCode(unit);
      return;
    }
    if (unit == _quote) {
      _finishValue(decoded);
      return;
    }
    _emitCodeUnit(unit, decoded);
  }

  void _continueEscape(int unit, StringBuffer decoded) {
    if (_escape.length == 1) {
      switch (unit) {
        case 0x22: // "
          _clearEscapeAndEmit(0x22, decoded);
        case 0x5C: // \
          _clearEscapeAndEmit(0x5C, decoded);
        case 0x2F: // /
          _clearEscapeAndEmit(0x2F, decoded);
        case 0x62: // b
          _clearEscapeAndEmit(0x08, decoded);
        case 0x66: // f
          _clearEscapeAndEmit(0x0C, decoded);
        case 0x6E: // n
          _clearEscapeAndEmit(0x0A, decoded);
        case 0x72: // r
          _clearEscapeAndEmit(0x0D, decoded);
        case 0x74: // t
          _clearEscapeAndEmit(0x09, decoded);
        case _unicodeEscape:
          _escape.writeCharCode(unit);
        default:
          // Not a valid JSON escape. Preview tolerantly keeps the raw pair;
          // strict final validation still rejects the payload as a whole.
          final literal = '\\${String.fromCharCode(unit)}';
          _escape.clear();
          for (final raw in literal.codeUnits) {
            _emitCodeUnit(raw, decoded);
          }
      }
      return;
    }
    // Collecting the 4 hex digits of a \uXXXX escape.
    _escape.writeCharCode(unit);
    if (_escape.length < 6) {
      return;
    }
    final sequence = _escape.toString();
    _escape.clear();
    final value = int.tryParse(sequence.substring(2), radix: 16);
    if (value == null) {
      for (final raw in sequence.codeUnits) {
        _emitCodeUnit(raw, decoded);
      }
      return;
    }
    _emitCodeUnit(value, decoded);
  }

  void _clearEscapeAndEmit(int unit, StringBuffer decoded) {
    _escape.clear();
    _emitCodeUnit(unit, decoded);
  }

  /// Emits one UTF-16 code unit, holding back a high surrogate until its pair
  /// arrives so a chunk boundary inside a surrogate pair (escaped or literal)
  /// never leaks a malformed half-character into the preview.
  void _emitCodeUnit(int unit, StringBuffer decoded) {
    final high = _pendingHighSurrogate;
    if (high != null) {
      _pendingHighSurrogate = null;
      decoded.writeCharCode(high);
      decoded.writeCharCode(unit);
      return;
    }
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      _pendingHighSurrogate = unit;
      return;
    }
    decoded.writeCharCode(unit);
  }

  void _finishValue(StringBuffer decoded) {
    final high = _pendingHighSurrogate;
    if (high != null) {
      // A dangling high surrogate right before the closing quote is malformed
      // input; flush it so the preview matches what was actually sent.
      _pendingHighSurrogate = null;
      decoded.writeCharCode(high);
    }
    _complete = true;
    _phase = _ExtractorPhase.done;
  }

  static bool _isJsonWhitespace(int unit) =>
      unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D;
}

enum _ExtractorPhase {
  searchingKey,
  expectingColon,
  expectingOpeningQuote,
  inValue,
  done,
}
