import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/model_runtime.dart';
import 'package:halo_mobile/model_runtime/testing/fake_secure_credential_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'store supports set get delete and metadata without logging secrets',
    () async {
      const secret = 'credential-must-never-be-logged';
      final channel = FakeSecureCredentialChannel()
        ..enqueueResult(null)
        ..enqueueResult(Uint8List.fromList(utf8.encode(secret)))
        ..enqueueResult([
          {
            'service': 'openai',
            'account': 'primary',
            'createdAt': '2030-01-01T10:00:00.000Z',
            'updatedAt': '2030-01-02T10:00:00.000Z',
          },
        ])
        ..enqueueResult(true);
      final store = MethodChannelSecureCredentialStore(channel: channel);
      final ref = SecretRef.parse('keychain://openai/primary');

      await store.set(ref, secret);
      expect(await store.get(ref), secret);
      final metadata = await store.listMetadata(service: 'openai');
      expect(metadata.single.service, 'openai');
      expect(metadata.single.account, 'primary');
      expect(metadata.single.createdAt, DateTime.utc(2030, 1, 1, 10));
      expect(metadata.single.updatedAt, DateTime.utc(2030, 1, 2, 10));
      expect(await store.delete(ref), isTrue);

      expect(channel.records.map((record) => record.method), [
        'set',
        'get',
        'listMetadata',
        'delete',
      ]);
      expect(channel.records.first.hadSecret, isTrue);
      expect(channel.records.first.secretWasBytes, isTrue);
      expect(
        channel.records.skip(1).every((record) => !record.hadSecret),
        isTrue,
      );
      expect(channel.records.join(), isNot(contains(secret)));
    },
  );

  test(
    'store accepts only strict keychain service and account references',
    () async {
      final channel = FakeSecureCredentialChannel();
      final store = MethodChannelSecureCredentialStore(channel: channel);
      final invalidRefs = [
        SecretRef.parse('memory://test/openai'),
        SecretRef.parse('vault://openai/primary'),
        SecretRef.parse('keychain://openai'),
        SecretRef.parse('keychain://openai/primary/extra'),
        SecretRef.parse('keychain://openai/'),
      ];

      for (final ref in invalidRefs) {
        await expectLater(
          store.get(ref),
          throwsA(_storeError(SecureCredentialStoreError.invalidReference)),
        );
      }
      expect(channel.callCount, 0);
    },
  );

  test(
    'store rejects empty and oversized secrets before the channel',
    () async {
      final channel = FakeSecureCredentialChannel();
      final store = MethodChannelSecureCredentialStore(channel: channel);
      final ref = SecretRef.parse('keychain://openai/primary');

      await expectLater(
        store.set(ref, ''),
        throwsA(_storeError(SecureCredentialStoreError.invalidSecret)),
      );
      await expectLater(
        store.set(
          ref,
          List.filled(
            MethodChannelSecureCredentialStore.maximumSecretBytes + 1,
            'x',
          ).join(),
        ),
        throwsA(_storeError(SecureCredentialStoreError.invalidSecret)),
      );
      expect(channel.callCount, 0);
    },
  );

  test(
    'resolver reads keychain values without caching and gives a short lease',
    () async {
      final channel = FakeSecureCredentialChannel()
        ..enqueueResult(Uint8List.fromList(utf8.encode('first-secret')))
        ..enqueueResult(Uint8List.fromList(utf8.encode('second-secret')));
      final store = MethodChannelSecureCredentialStore(channel: channel);
      final resolver = KeychainSecretResolver(
        store: store,
        now: () => DateTime.utc(2030, 1, 1, 10),
        leaseDuration: const Duration(seconds: 20),
      );
      final ref = SecretRef.parse('keychain://openai/primary');

      final first = await resolver.resolve(ref);
      final second = await resolver.resolve(ref);

      expect(first?.value, 'first-secret');
      expect(second?.value, 'second-secret');
      expect(first?.expiresAt, DateTime.utc(2030, 1, 1, 10, 0, 20));
      expect(channel.callCount, 2);
      expect(resolver.toString(), isNot(contains('first-secret')));
    },
  );

  test(
    'resolver returns null for a missing item and rejects non-keychain refs',
    () async {
      final channel = FakeSecureCredentialChannel()..enqueueResult(null);
      final resolver = KeychainSecretResolver(
        store: MethodChannelSecureCredentialStore(channel: channel),
      );

      expect(
        await resolver.resolve(SecretRef.parse('keychain://openai/missing')),
        isNull,
      );
      await expectLater(
        resolver.resolve(SecretRef.parse('memory://test/openai')),
        throwsA(_storeError(SecureCredentialStoreError.invalidReference)),
      );
      expect(channel.callCount, 1);
    },
  );

  test(
    'cancellation ends a pending operation with a fixed safe error',
    () async {
      final pending = Completer<Object?>();
      final channel = FakeSecureCredentialChannel()
        ..enqueueFuture(pending.future);
      final store = MethodChannelSecureCredentialStore(channel: channel);
      final token = CancellationToken();

      final future = store.get(
        SecretRef.parse('keychain://openai/primary'),
        cancellationToken: token,
      );
      await Future<void>.delayed(Duration.zero);
      token.cancel();

      await expectLater(
        future.timeout(const Duration(seconds: 1)),
        throwsA(_storeError(SecureCredentialStoreError.cancelled)),
      );
    },
  );

  test('a late get buffer is wiped after cancellation wins', () async {
    final pending = Completer<Object?>();
    final lateBytes = Uint8List.fromList(utf8.encode('late-secret'));
    final channel = FakeSecureCredentialChannel()
      ..enqueueFuture(pending.future);
    final store = MethodChannelSecureCredentialStore(channel: channel);
    final token = CancellationToken();

    final future = store.get(
      SecretRef.parse('keychain://openai/primary'),
      cancellationToken: token,
    );
    await Future<void>.delayed(Duration.zero);
    token.cancel();
    await expectLater(
      future,
      throwsA(_storeError(SecureCredentialStoreError.cancelled)),
    );

    pending.complete(lateBytes);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(lateBytes, everyElement(0));
  });

  test('an already cancelled operation never reaches the channel', () async {
    final token = CancellationToken()..cancel();
    final channel = FakeSecureCredentialChannel();
    final store = MethodChannelSecureCredentialStore(channel: channel);

    await expectLater(
      store.delete(
        SecretRef.parse('keychain://openai/primary'),
        cancellationToken: token,
      ),
      throwsA(_storeError(SecureCredentialStoreError.cancelled)),
    );
    expect(channel.callCount, 0);
  });

  test(
    'dispatched delete waits for a definitive result after cancellation',
    () async {
      final pending = Completer<Object?>();
      final channel = FakeSecureCredentialChannel()
        ..enqueueFuture(pending.future);
      final store = MethodChannelSecureCredentialStore(channel: channel);
      final token = CancellationToken();

      final deletion = store.delete(
        SecretRef.parse('keychain://openai/primary'),
        cancellationToken: token,
      );
      await Future<void>.delayed(Duration.zero);
      token.cancel();
      pending.complete(true);

      expect(await deletion, isTrue);
      expect(channel.callCount, 1);
    },
  );

  test(
    'dispatched set waits for a definitive result after cancellation',
    () async {
      final pending = Completer<Object?>();
      final channel = FakeSecureCredentialChannel()
        ..enqueueFuture(pending.future);
      final store = MethodChannelSecureCredentialStore(channel: channel);
      final token = CancellationToken();

      final write = store.set(
        SecretRef.parse('keychain://openai/primary'),
        'short-lived-secret',
        cancellationToken: token,
      );
      await Future<void>.delayed(Duration.zero);
      token.cancel();
      pending.complete(null);

      await expectLater(write, completes);
      expect(channel.callCount, 1);
    },
  );

  test('concurrent reads retain their own results', () async {
    final first = Completer<Object?>();
    final second = Completer<Object?>();
    final channel = FakeSecureCredentialChannel()
      ..enqueueFuture(first.future)
      ..enqueueFuture(second.future);
    final store = MethodChannelSecureCredentialStore(channel: channel);

    final firstRead = store.get(SecretRef.parse('keychain://openai/first'));
    final secondRead = store.get(SecretRef.parse('keychain://openai/second'));
    second.complete(Uint8List.fromList(utf8.encode('second-secret')));
    first.complete(Uint8List.fromList(utf8.encode('first-secret')));

    expect(await firstRead, 'first-secret');
    expect(await secondRead, 'second-secret');
    expect(channel.callCount, 2);
  });

  test(
    'duplicate set operations remain updates at the channel boundary',
    () async {
      final channel = FakeSecureCredentialChannel()
        ..enqueueResult(null)
        ..enqueueResult(null);
      final store = MethodChannelSecureCredentialStore(channel: channel);
      final ref = SecretRef.parse('keychain://openai/primary');

      await store.set(ref, 'first');
      await store.set(ref, 'updated');

      expect(channel.records.length, 2);
      expect(channel.records.every((record) => record.method == 'set'), isTrue);
      expect(channel.records.join(), isNot(contains('updated')));
    },
  );

  test('platform failures map to fixed errors without response text', () async {
    final cases = {
      'locked': SecureCredentialStoreError.deviceLocked,
      'cancelled': SecureCredentialStoreError.cancelled,
      'not_found': SecureCredentialStoreError.notFound,
      'invalid_arguments': SecureCredentialStoreError.invalidReference,
      'unavailable': SecureCredentialStoreError.unavailable,
      'unexpected': SecureCredentialStoreError.operationFailed,
    };

    for (final entry in cases.entries) {
      final channel = FakeSecureCredentialChannel()
        ..enqueueError(
          PlatformException(
            code: entry.key,
            message: 'Authorization sk-platform-secret keychain body',
            details: {'secret': 'must-not-escape'},
          ),
        );
      final store = MethodChannelSecureCredentialStore(channel: channel);

      await expectLater(
        store.get(SecretRef.parse('keychain://openai/primary')),
        throwsA(_storeError(entry.value)),
      );
    }
  });

  test('malformed channel responses fail closed', () async {
    final malformedResults = [
      42,
      {'secret': 'wrong-shape'},
      [
        {
          'service': 'openai',
          'account': 'primary',
          'createdAt': 'not-a-date',
          'updatedAt': '2030-01-02T10:00:00.000Z',
        },
      ],
    ];

    for (final result in malformedResults) {
      final channel = FakeSecureCredentialChannel()..enqueueResult(result);
      final store = MethodChannelSecureCredentialStore(channel: channel);
      final operation = result is List
          ? store.listMetadata()
          : store.get(SecretRef.parse('keychain://openai/primary'));
      await expectLater(
        operation,
        throwsA(_storeError(SecureCredentialStoreError.invalidResponse)),
      );
    }
  });

  test(
    'only high-confidence complete credential tokens are rejected',
    () async {
      final channel = FakeSecureCredentialChannel();
      final store = MethodChannelSecureCredentialStore(channel: channel);
      const token = 'sk-live-abcdefghijklmnopqrstuvwxyz012345';

      await expectLater(
        store.get(SecretRef.parse('keychain://$token/primary')),
        throwsA(_storeError(SecureCredentialStoreError.invalidReference)),
      );
      await expectLater(
        store.get(SecretRef.parse('keychain://openai/$token')),
        throwsA(_storeError(SecureCredentialStoreError.invalidReference)),
      );
      await expectLater(
        store.listMetadata(service: token),
        throwsA(_storeError(SecureCredentialStoreError.invalidReference)),
      );
      expect(channel.callCount, 0);
    },
  );

  test('locator-like identifiers are not mistaken for credentials', () async {
    const identifiers = [
      'BearerTeamAccount',
      'asia-production',
      'aiza-production',
      'apikey-team',
      'OpenRouterProductionAccount2026',
    ];
    final channel = FakeSecureCredentialChannel();
    for (var index = 0; index < identifiers.length * 2; index++) {
      channel.enqueueResult(index.isEven ? null : []);
    }
    final store = MethodChannelSecureCredentialStore(channel: channel);

    for (final identifier in identifiers) {
      expect(
        await store.get(
          SecretRef.parse(
            Uri(
              scheme: 'keychain',
              host: 'openai',
              pathSegments: [identifier],
            ).toString(),
          ),
        ),
        isNull,
      );
      expect(await store.listMetadata(service: identifier), isEmpty);
    }
    expect(channel.callCount, identifiers.length * 2);
  });

  test(
    'identifier limits use UTF-8 bytes for emoji and combining text',
    () async {
      final acceptedService = '${List.filled(124, 'a').join()}😀';
      final rejectedService = '${List.filled(125, 'a').join()}😀';
      final acceptedAccount = List.filled(256, 'a').join();
      final rejectedAccount = List.filled(257, 'a').join();
      final channel = FakeSecureCredentialChannel()
        ..enqueueResult([])
        ..enqueueResult(null);
      final store = MethodChannelSecureCredentialStore(channel: channel);

      expect(await store.listMetadata(service: acceptedService), isEmpty);
      expect(
        await store.get(
          SecretRef.parse(
            Uri(
              scheme: 'keychain',
              host: 'openai',
              pathSegments: [acceptedAccount],
            ).toString(),
          ),
        ),
        isNull,
      );
      await expectLater(
        store.listMetadata(service: rejectedService),
        throwsA(_storeError(SecureCredentialStoreError.invalidReference)),
      );
      await expectLater(
        store.get(
          SecretRef.parse(
            Uri(
              scheme: 'keychain',
              host: 'openai',
              pathSegments: [rejectedAccount],
            ).toString(),
          ),
        ),
        throwsA(_storeError(SecureCredentialStoreError.invalidReference)),
      );
      expect(channel.callCount, 2);
    },
  );

  test('normal service and account identifiers remain accepted', () async {
    final channel = FakeSecureCredentialChannel()
      ..enqueueResult(null)
      ..enqueueResult([]);
    final store = MethodChannelSecureCredentialStore(channel: channel);

    expect(
      await store.get(
        SecretRef.parse('keychain://com.halo.provider/user@example.com'),
      ),
      isNull,
    );
    expect(await store.listMetadata(service: 'com.halo.provider'), isEmpty);
    expect(channel.callCount, 2);
  });
}

Matcher _storeError(SecureCredentialStoreError code) =>
    isA<SecureCredentialStoreException>()
        .having((error) => error.code, 'code', code)
        .having(
          (error) => error.toString(),
          'safe string',
          allOf(
            isNot(contains('Authorization')),
            isNot(contains('sk-')),
            isNot(contains('keychain body')),
            isNot(contains('must-not-escape')),
          ),
        );
