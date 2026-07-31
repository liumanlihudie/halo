@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';

/// The credential the settings page writes must be the one calls accept.
///
/// A blank App Key is written as an empty middle segment, and requiring three
/// non-empty parts rejected exactly the value the page produces — a call then
/// sat on 正在接通 with the reason swallowed.
void main() {
  ({String appId, String? appKey, String token})? parse(String value) {
    final parts = value.split(':');
    if (parts.length == 3 && parts[1].isEmpty) parts.removeAt(1);
    if (parts.length == 3 && parts.every((part) => part.isNotEmpty)) {
      return (appId: parts[0], appKey: parts[1], token: parts[2]);
    }
    if (parts.length == 2 && parts.every((part) => part.isNotEmpty)) {
      return (appId: parts[0], appKey: null, token: parts[1]);
    }
    return null;
  }

  test('a blank App Key falls back to the fixed one', () {
    final parsed = parse('9331423139::a-token');
    expect(parsed?.appId, '9331423139');
    expect(parsed?.appKey, isNull);
    expect(parsed?.token, 'a-token');
  });

  test('all three values are kept when supplied', () {
    final parsed = parse('9331423139:an-app-key:a-token');
    expect(parsed?.appKey, 'an-app-key');
    expect(parsed?.token, 'a-token');
  });

  test('two values mean the fixed app key', () {
    expect(parse('9331423139:a-token')?.token, 'a-token');
  });

  test('a lone key is not a dialogue credential', () {
    expect(parse('just-a-key'), isNull);
  });
}
