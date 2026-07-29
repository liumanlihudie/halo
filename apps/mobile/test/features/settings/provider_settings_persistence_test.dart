import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/settings/provider_settings_controller.dart';
import 'package:halo_mobile/features/settings/provider_settings_persistence.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/secure_credential_store.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';
import 'package:halo_mobile/model_runtime/sqlite_provider_configuration_store.dart';

void main() {
  test(
    'stages, rolls back, and finalizes trusted provider mutations',
    () async {
      final directory = await Directory.systemTemp.createTemp('halo-settings-');
      addTearDown(() => directory.delete(recursive: true));
      final store = SqliteProviderConfigurationStore.open(
        '${directory.path}/providers.sqlite',
      );
      addTearDown(store.close);
      final persistence = AtomicProviderSettingsPersistence(store);
      final first = _snapshot(_ref(1));

      await persistence.replace(null, first);
      await persistence.finalizeReplace(null, first);
      final loaded = await persistence.load('toapis');
      expect(loaded?.config.secretRef, first.config.secretRef);
      expect(loaded?.model, first.model);

      final replacement = _snapshot(_ref(2));
      await persistence.replace(loaded, replacement);
      await persistence.rollbackReplace(loaded, replacement);
      expect(
        (await persistence.load('toapis'))?.config.secretRef,
        first.config.secretRef,
      );

      final current = await persistence.load('toapis');
      await persistence.replace(current, replacement);
      await persistence.finalizeReplace(current, replacement);
      expect(
        (await persistence.load('toapis'))?.config.secretRef,
        replacement.config.secretRef,
      );
    },
  );

  test(
    'removal lease restores or finalizes the same snapshot identity',
    () async {
      final directory = await Directory.systemTemp.createTemp('halo-settings-');
      addTearDown(() => directory.delete(recursive: true));
      final store = SqliteProviderConfigurationStore.open(
        '${directory.path}/providers.sqlite',
      );
      addTearDown(store.close);
      final persistence = AtomicProviderSettingsPersistence(store);
      final first = _snapshot(_ref(3));
      await persistence.replace(null, first);
      await persistence.finalizeReplace(null, first);

      final loaded = (await persistence.load('toapis'))!;
      await persistence.remove(loaded);
      await persistence.restore(loaded);
      expect(await persistence.load('toapis'), isNotNull);

      final reloaded = (await persistence.load('toapis'))!;
      await persistence.remove(reloaded);
      await persistence.finalizeRemoval(reloaded);
      expect(await persistence.load('toapis'), isNull);
    },
  );

  test('restart resumes staged rotation without reading either Key', () async {
    final directory = await Directory.systemTemp.createTemp('halo-settings-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/providers.sqlite';
    var store = SqliteProviderConfigurationStore.open(path);
    var persistence = AtomicProviderSettingsPersistence(store);
    final first = _snapshot(_ref(4));
    await persistence.replace(null, first);
    await persistence.finalizeReplace(null, first);
    final loaded = (await persistence.load('toapis'))!;
    final replacement = _snapshot(_ref(5));
    await persistence.replace(loaded, replacement);
    await store.close();

    store = SqliteProviderConfigurationStore.open(path);
    addTearDown(store.close);
    persistence = AtomicProviderSettingsPersistence(store);
    final credentials = _RecoveryCredentials({
      first.config.secretRef!,
      replacement.config.secretRef!,
    });
    await persistence.recoverPending(credentials);

    expect(credentials.getCalls, 0);
    expect(credentials.deleted, [first.config.secretRef]);
    expect(await store.listPendingProviderOperations(), isEmpty);
    expect(
      (await persistence.load('toapis'))?.config.secretRef,
      replacement.config.secretRef,
    );
  });

  test(
    'delete false leaves staged operation durable for next startup',
    () async {
      final directory = await Directory.systemTemp.createTemp('halo-settings-');
      addTearDown(() => directory.delete(recursive: true));
      final store = SqliteProviderConfigurationStore.open(
        '${directory.path}/providers.sqlite',
      );
      addTearDown(store.close);
      final persistence = AtomicProviderSettingsPersistence(store);
      final first = _snapshot(_ref(6));
      await persistence.replace(null, first);
      await persistence.finalizeReplace(null, first);
      final loaded = (await persistence.load('toapis'))!;
      final replacement = _snapshot(_ref(7));
      await persistence.replace(loaded, replacement);
      final credentials = _RecoveryCredentials({
        first.config.secretRef!,
        replacement.config.secretRef!,
      })..deleteResult = false;

      await expectLater(
        persistence.recoverPending(credentials),
        throwsStateError,
      );

      expect(await store.listPendingProviderOperations(), hasLength(1));
    },
  );

  test(
    'missing staged replacement credential rolls back fail closed',
    () async {
      final directory = await Directory.systemTemp.createTemp('halo-settings-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/providers.sqlite';
      var store = SqliteProviderConfigurationStore.open(path);
      var persistence = AtomicProviderSettingsPersistence(store);
      final first = _snapshot(_ref(8));
      await persistence.replace(null, first);
      await persistence.finalizeReplace(null, first);
      final loaded = (await persistence.load('toapis'))!;
      await persistence.replace(loaded, _snapshot(_ref(9)));
      await store.close();

      store = SqliteProviderConfigurationStore.open(path);
      addTearDown(store.close);
      persistence = AtomicProviderSettingsPersistence(store);
      await persistence.recoverPending(
        _RecoveryCredentials({first.config.secretRef!}),
      );

      expect(await store.listPendingProviderOperations(), isEmpty);
      expect(
        (await persistence.load('toapis'))?.config.secretRef,
        first.config.secretRef,
      );
    },
  );

  test(
    'restart resumes staged removal and deletes only referenced old ref',
    () async {
      final directory = await Directory.systemTemp.createTemp('halo-settings-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/providers.sqlite';
      var store = SqliteProviderConfigurationStore.open(path);
      var persistence = AtomicProviderSettingsPersistence(store);
      final first = _snapshot(_ref(10));
      await persistence.replace(null, first);
      await persistence.finalizeReplace(null, first);
      final loaded = (await persistence.load('toapis'))!;
      await persistence.remove(loaded);
      await store.close();

      store = SqliteProviderConfigurationStore.open(path);
      addTearDown(store.close);
      persistence = AtomicProviderSettingsPersistence(store);
      final credentials = _RecoveryCredentials({first.config.secretRef!});
      await persistence.recoverPending(credentials);

      expect(credentials.getCalls, 0);
      expect(credentials.deleted, [first.config.secretRef]);
      expect(await persistence.load('toapis'), isNull);
      expect(await store.listPendingProviderOperations(), isEmpty);
    },
  );

  test('startup removes an unreferenced app-owned Keychain orphan', () async {
    final directory = await Directory.systemTemp.createTemp('halo-settings-');
    addTearDown(() => directory.delete(recursive: true));
    final store = SqliteProviderConfigurationStore.open(
      '${directory.path}/providers.sqlite',
    );
    addTearDown(store.close);
    final persistence = AtomicProviderSettingsPersistence(store);
    final orphan = _ref(11);
    final credentials = _RecoveryCredentials({orphan});

    await persistence.recoverPending(credentials);

    expect(credentials.deleted, [orphan]);
  });

  test(
    'restart preserves every live custom credential binding and deletes orphan',
    () async {
      final directory = await Directory.systemTemp.createTemp('halo-settings-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/providers.sqlite';
      var store = SqliteProviderConfigurationStore.open(path);
      final primary = _ref(12);
      final header = _ref(13);
      final orphan = _ref(14);
      await store.upsert(
        ProviderConfig.customOpenAICompatible(
          providerId: 'custom-provider',
          displayName: 'Custom Provider',
          baseUri: Uri.parse('https://custom.example/v1'),
          secretRef: primary,
          headerSecretRefs: {'X-Secondary-Key': header},
        ),
      );
      await store.close();

      store = SqliteProviderConfigurationStore.open(path);
      addTearDown(store.close);
      final persistence = AtomicProviderSettingsPersistence(store);
      final credentials = _RecoveryCredentials({primary, header, orphan});

      await persistence.recoverPending(credentials);

      expect(credentials.refs, {primary, header});
      expect(credentials.deleted, [orphan]);
    },
  );

  test(
    'missing old and new refs keeps staged mutation pending fail closed',
    () async {
      final directory = await Directory.systemTemp.createTemp('halo-settings-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/providers.sqlite';
      var store = SqliteProviderConfigurationStore.open(path);
      var persistence = AtomicProviderSettingsPersistence(store);
      final first = _snapshot(_ref(15));
      await persistence.replace(null, first);
      await persistence.finalizeReplace(null, first);
      final loaded = (await persistence.load('toapis'))!;
      await persistence.replace(loaded, _snapshot(_ref(16)));
      await store.close();

      store = SqliteProviderConfigurationStore.open(path);
      addTearDown(store.close);
      persistence = AtomicProviderSettingsPersistence(store);
      await expectLater(
        persistence.recoverPending(_RecoveryCredentials({})),
        throwsStateError,
      );

      expect(await store.listPendingProviderOperations(), hasLength(1));
    },
  );

  test(
    'available new ref finalizes even when old ref is already absent',
    () async {
      final directory = await Directory.systemTemp.createTemp('halo-settings-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/providers.sqlite';
      var store = SqliteProviderConfigurationStore.open(path);
      var persistence = AtomicProviderSettingsPersistence(store);
      final first = _snapshot(_ref(17));
      final replacement = _snapshot(_ref(18));
      await persistence.replace(null, first);
      await persistence.finalizeReplace(null, first);
      final loaded = (await persistence.load('toapis'))!;
      await persistence.replace(loaded, replacement);
      await store.close();

      store = SqliteProviderConfigurationStore.open(path);
      addTearDown(store.close);
      persistence = AtomicProviderSettingsPersistence(store);
      await persistence.recoverPending(
        _RecoveryCredentials({replacement.config.secretRef!}),
      );

      expect(await store.listPendingProviderOperations(), isEmpty);
      expect(
        (await persistence.load('toapis'))?.config.secretRef,
        replacement.config.secretRef,
      );
    },
  );

  test(
    'rollback requires every previous custom header credential to exist',
    () async {
      final directory = await Directory.systemTemp.createTemp('halo-settings-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/providers.sqlite';
      var store = SqliteProviderConfigurationStore.open(path);
      final oldPrimary = _ref(19);
      final oldHeader = _ref(20);
      final newPrimary = _ref(21);
      final oldConfig = ProviderConfig.customOpenAICompatible(
        providerId: 'custom-provider',
        displayName: 'Custom Provider',
        baseUri: Uri.parse('https://custom.example/v1'),
        secretRef: oldPrimary,
        headerSecretRefs: {'X-Secondary-Key': oldHeader},
      );
      await store.upsert(oldConfig);
      final current = (await store.loadProvider('custom-provider'))!;
      final nextConfig = oldConfig.copyWith(secretRef: newPrimary);
      await store.rotateCredential(
        providerId: 'custom-provider',
        slot: ProviderCredentialSlot.primary,
        expectedRevision: current.revision,
        expectedOldRef: oldPrimary,
        newRef: newPrimary,
        replacement: ProviderConfigurationReplacement(config: nextConfig),
      );
      await store.close();

      store = SqliteProviderConfigurationStore.open(path);
      addTearDown(store.close);
      final persistence = AtomicProviderSettingsPersistence(store);
      await expectLater(
        persistence.recoverPending(_RecoveryCredentials({oldPrimary})),
        throwsStateError,
      );

      expect(await store.listPendingProviderOperations(), hasLength(1));
    },
  );
}

ProviderSettingsSnapshot _snapshot(SecretRef ref) => ProviderSettingsSnapshot(
  config: ProviderConfig.toApis(secretRef: ref),
  model: ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini'),
);

SecretRef _ref(int value) => SecretRef.parse(
  'keychain://halo.provider/00000000-0000-4000-8000-'
  '${value.toString().padLeft(12, '0')}',
);

final class _RecoveryCredentials implements SecureCredentialStore {
  _RecoveryCredentials(this.refs);

  final Set<SecretRef> refs;
  final deleted = <SecretRef>[];
  int getCalls = 0;
  bool deleteResult = true;

  @override
  Future<bool> delete(
    SecretRef ref, {
    CancellationToken? cancellationToken,
  }) async {
    deleted.add(ref);
    if (deleteResult) refs.remove(ref);
    return deleteResult;
  }

  @override
  Future<String?> get(
    SecretRef ref, {
    CancellationToken? cancellationToken,
  }) async {
    getCalls++;
    return null;
  }

  @override
  Future<List<SecureCredentialMetadata>> listMetadata({
    String? service,
    CancellationToken? cancellationToken,
  }) async => [
    for (final ref in refs)
      SecureCredentialMetadata(
        service: ref.locator.host,
        account: ref.locator.pathSegments.single,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
  ];

  @override
  Future<void> set(
    SecretRef ref,
    String secret, {
    CancellationToken? cancellationToken,
  }) async {
    refs.add(ref);
  }
}
