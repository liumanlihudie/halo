import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/model_runtime.dart';

void main() {
  test('SecretRef accepts only explicit secure locator schemes', () {
    final refs = [
      SecretRef.parse('keychain://provider/openai'),
      SecretRef.parse('vault://provider/toapis'),
      SecretRef.parse('memory://test/toapis'),
    ];

    expect(refs.map((ref) => ref.scheme).toList(), const [
      'keychain',
      'vault',
      'memory',
    ]);
  });

  test('SecretRef rejects plaintext and credential-shaped input', () {
    for (final value in [
      'sk-live-plaintext',
      'plain-text-secret',
      'https://example.com/secret',
      'vault:missing-authority',
      'memory://production/not-test',
      '',
    ]) {
      expect(() => SecretRef.parse(value), throwsArgumentError, reason: value);
    }
  });

  test('SecretRef string representation is always redacted', () {
    final ref = SecretRef.parse('vault://provider/private-account');

    expect(ref.toString(), 'vault://***/***');
    expect(ref.toString(), isNot(contains('private-account')));
  });
}
