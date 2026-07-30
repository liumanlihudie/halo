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
      'keychain://openai:443/primary',
      'vault://provider:8443/account',
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

  test('credential values are never silently trimmed', () {
    final expiry = DateTime.utc(2030);
    expect(
      () => EphemeralCredential(value: ' secret', expiresAt: expiry),
      throwsArgumentError,
    );
    expect(
      EphemeralCredential(value: 'secret', expiresAt: expiry).value,
      'secret',
    );
  });

  test('secret locators reject percent-encoded identity aliases', () {
    for (final locator in [
      'keychain://openai/%61ccount',
      'vault://team/%73ecret',
      'memory://test/%6bey',
    ]) {
      expect(() => SecretRef.parse(locator), throwsArgumentError);
    }
  });
}
