import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/settings/provider_settings_controller.dart';
import 'package:halo_mobile/features/settings/service_credentials_controller.dart';
import 'package:halo_mobile/model_runtime/provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';
import 'package:halo_mobile/model_runtime/secure_credential_store.dart';

void main() {
  ServiceCredentialsController build({
    _FakeCredentials? credentials,
    _FakePersistence? persistence,
  }) => ServiceCredentialsController(
    credentials: credentials ?? _FakeCredentials(),
    persistence: persistence ?? _FakePersistence(),
    secretRefs: _SequentialRefs(),
    now: () => DateTime.utc(2026, 7, 30, 12),
  );

  test('nothing is configured before a key is saved', () async {
    final controller = build();

    await controller.load();

    for (final service in KeyOnlyService.values) {
      expect(controller.statusFor(service).configured, isFalse);
    }
  });

  test('saving writes the key to the platform store, not to the row', () async {
    final credentials = _FakeCredentials();
    final persistence = _FakePersistence();
    final controller = build(
      credentials: credentials,
      persistence: persistence,
    );
    await controller.load();

    expect(
      await controller.save(KeyOnlyService.doubaoSpeech, 'volc-key'),
      isTrue,
    );

    expect(credentials.stored.values.single, 'volc-key');
    expect(persistence.records.single.serviceId, 'doubao-speech');
    // The row records where the key lives, never the key.
    expect(
      persistence.records.single.secretRef.locator.toString(),
      credentials.stored.keys.single,
    );
    expect(
      controller.statusFor(KeyOnlyService.doubaoSpeech).configured,
      isTrue,
    );
  });

  test(
    'a pasted key keeps its surrounding whitespace out of the header',
    () async {
      final credentials = _FakeCredentials();
      final controller = build(credentials: credentials);
      await controller.load();

      await controller.save(KeyOnlyService.vidu, '  vidu-key\n');

      expect(credentials.stored.values.single, 'vidu-key');
    },
  );

  test('an empty key saves nothing at all', () async {
    final credentials = _FakeCredentials();
    final persistence = _FakePersistence();
    final controller = build(
      credentials: credentials,
      persistence: persistence,
    );
    await controller.load();

    expect(await controller.save(KeyOnlyService.vidu, '   '), isFalse);

    expect(credentials.stored, isEmpty);
    expect(persistence.records, isEmpty);
  });

  test('a failed row write deletes the key it just stored', () async {
    final credentials = _FakeCredentials();
    final persistence = _FakePersistence(failPut: true);
    final controller = build(
      credentials: credentials,
      persistence: persistence,
    );
    await controller.load();

    expect(
      await controller.save(KeyOnlyService.doubaoRealtimeAudio, 'key'),
      isFalse,
    );

    // No orphan: a Keychain item nothing references would linger forever.
    expect(credentials.stored, isEmpty);
    expect(
      controller.statusFor(KeyOnlyService.doubaoRealtimeAudio).configured,
      isFalse,
    );
  });

  test('replacing a key deletes the one it displaced', () async {
    final credentials = _FakeCredentials();
    final persistence = _FakePersistence();
    final controller = build(
      credentials: credentials,
      persistence: persistence,
    );
    await controller.load();

    await controller.save(KeyOnlyService.doubaoSpeech, 'first');
    final firstLocator = credentials.stored.keys.single;
    await controller.save(KeyOnlyService.doubaoSpeech, 'second');

    expect(credentials.stored.values, ['second']);
    expect(credentials.deleted, contains(firstLocator));
    expect(persistence.records, hasLength(1));
  });

  test('removing forgets the row and deletes the key', () async {
    final credentials = _FakeCredentials();
    final persistence = _FakePersistence();
    final controller = build(
      credentials: credentials,
      persistence: persistence,
    );
    await controller.load();
    await controller.save(KeyOnlyService.vidu, 'vidu-key');
    final locator = credentials.stored.keys.single;

    expect(await controller.remove(KeyOnlyService.vidu), isTrue);

    expect(persistence.records, isEmpty);
    expect(credentials.stored, isEmpty);
    expect(credentials.deleted, contains(locator));
    expect(controller.statusFor(KeyOnlyService.vidu).configured, isFalse);
  });

  test('a failed keychain write leaves no row behind', () async {
    final credentials = _FakeCredentials(failSet: true);
    final persistence = _FakePersistence();
    final controller = build(
      credentials: credentials,
      persistence: persistence,
    );
    await controller.load();

    expect(await controller.save(KeyOnlyService.vidu, 'key'), isFalse);

    expect(persistence.records, isEmpty);
  });

  test(
    'an unreadable store reports nothing configured, never a stale yes',
    () async {
      final controller = build(persistence: _FakePersistence(failLoad: true));

      await controller.load();

      expect(controller.loaded, isTrue);
      for (final service in KeyOnlyService.values) {
        expect(controller.statusFor(service).configured, isFalse);
      }
    },
  );

  test('unknown service ids in storage are ignored', () async {
    final persistence = _FakePersistence()
      ..records.add(
        PersistedServiceCredential(
          serviceId: 'retired-service',
          secretRef: SecretRef.parse(
            'keychain://halo.provider/11111111-2222-4333-8444-555555555555',
          ),
          enabled: true,
          configuredAt: DateTime.utc(2026, 7, 1),
        ),
      );
    final controller = build(persistence: persistence);

    await controller.load();

    for (final service in KeyOnlyService.values) {
      expect(controller.statusFor(service).configured, isFalse);
    }
  });

  test('every service id is a stable canonical slug', () {
    for (final service in KeyOnlyService.values) {
      // These ids are persisted, so a rename would orphan a user's key.
      expect(service.id, matches(RegExp(r'^[a-z0-9-]+$')));
      expect(KeyOnlyService.byId(service.id), service);
    }
    expect(KeyOnlyService.byId('nope'), isNull);
  });
}

class _SequentialRefs implements ProviderSecretRefFactory {
  var _next = 0;

  @override
  SecretRef next() {
    _next += 1;
    final tail = _next.toString().padLeft(12, '0');
    return SecretRef.parse(
      'keychain://halo.provider/aaaaaaaa-bbbb-4ccc-8ddd-$tail',
    );
  }
}

class _FakeCredentials implements SecureCredentialStore {
  _FakeCredentials({this.failSet = false});

  final bool failSet;
  final Map<String, String> stored = {};
  final List<String> deleted = [];

  @override
  Future<void> set(
    SecretRef ref,
    String secret, {
    CancellationToken? cancellationToken,
  }) async {
    if (failSet) throw StateError('keychain unavailable');
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
  }) async {
    deleted.add(ref.locator.toString());
    return stored.remove(ref.locator.toString()) != null;
  }

  @override
  Future<List<SecureCredentialMetadata>> listMetadata({
    String? service,
    CancellationToken? cancellationToken,
  }) async => const [];
}

class _FakePersistence implements ServiceCredentialPersistence {
  _FakePersistence({this.failPut = false, this.failLoad = false});

  final bool failPut;
  final bool failLoad;
  final List<PersistedServiceCredential> records = [];

  @override
  Future<List<PersistedServiceCredential>> loadServiceCredentials() async {
    if (failLoad) throw StateError('unreadable');
    return List.unmodifiable(records);
  }

  @override
  Future<SecretRef?> putServiceCredential(
    String serviceId,
    SecretRef secretRef, {
    required bool enabled,
    required DateTime configuredAt,
  }) async {
    if (failPut) throw StateError('write failed');
    final index = records.indexWhere((record) => record.serviceId == serviceId);
    final displaced = index == -1 ? null : records[index].secretRef;
    final record = PersistedServiceCredential(
      serviceId: serviceId,
      secretRef: secretRef,
      enabled: enabled,
      configuredAt: configuredAt,
    );
    if (index == -1) {
      records.add(record);
    } else {
      records[index] = record;
    }
    return displaced?.locator == secretRef.locator ? null : displaced;
  }

  @override
  Future<SecretRef?> removeServiceCredential(String serviceId) async {
    final index = records.indexWhere((record) => record.serviceId == serviceId);
    if (index == -1) return null;
    return records.removeAt(index).secretRef;
  }
}
