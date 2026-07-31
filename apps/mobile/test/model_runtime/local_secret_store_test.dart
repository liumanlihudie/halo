@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/local_secret_store.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';
import 'package:halo_mobile/model_runtime/secure_credential_store.dart';

/// A key that will not save is a feature that does not run.
void main() {
  late Directory directory;
  final ref = SecretRef.parse(
    'keychain://halo.provider/00000000-0000-4000-8000-000000000001',
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('halo-secrets-');
  });

  tearDown(() => directory.deleteSync(recursive: true));

  FallbackCredentialStore store(SecureCredentialStore primary) =>
      FallbackCredentialStore(primary: primary, directory: directory);

  test('the system store is used whenever it works', () async {
    final keychain = _FakeKeychain();
    final subject = store(keychain);

    await subject.set(ref, 'a-key');

    expect(keychain.stored[ref.locator.toString()], 'a-key');
    expect(await subject.get(ref), 'a-key');
    // Nothing is written beside it while the system store is healthy.
    expect(File('${directory.path}/secrets.json').existsSync(), isFalse);
  });

  test('a refused write still saves, and reads back', () async {
    final keychain = _FakeKeychain(failWrites: true);
    final subject = store(keychain);

    await subject.set(ref, 'a-key');

    expect(await subject.get(ref), 'a-key');
  });

  test('a later system write clears the fallback copy', () async {
    final keychain = _FakeKeychain(failWrites: true);
    final subject = store(keychain);
    await subject.set(ref, 'old-key');

    keychain.failWrites = false;
    await subject.set(ref, 'new-key');

    expect(keychain.stored[ref.locator.toString()], 'new-key');
    keychain.stored.clear();
    // The stale local copy must not resurrect a replaced key.
    expect(await subject.get(ref), isNull);
  });

  test('removal takes the fallback copy with it', () async {
    final keychain = _FakeKeychain(failWrites: true);
    final subject = store(keychain);
    await subject.set(ref, 'a-key');

    expect(await subject.delete(ref), isTrue);
    expect(await subject.get(ref), isNull);
  });
}

final class _FakeKeychain implements SecureCredentialStore {
  _FakeKeychain({this.failWrites = false});

  bool failWrites;
  final stored = <String, String>{};

  @override
  Future<void> set(
    SecretRef ref,
    String secret, {
    CancellationToken? cancellationToken,
  }) async {
    if (failWrites) throw StateError('keychain unavailable');
    stored[ref.locator.toString()] = secret;
  }

  @override
  Future<String?> get(
    SecretRef ref, {
    CancellationToken? cancellationToken,
  }) async => stored[ref.locator.toString()];

  @override
  Future<bool> delete(
    SecretRef ref, {
    CancellationToken? cancellationToken,
  }) async => stored.remove(ref.locator.toString()) != null;

  @override
  Future<List<SecureCredentialMetadata>> listMetadata({
    String? service,
    CancellationToken? cancellationToken,
  }) async => const [];
}
