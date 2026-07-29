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
      await persistence.markReplaceRuntimePublished(null, first);
      await persistence.finalizeReplace(null, first);
      final loaded = await persistence.load('toapis');
      expect(loaded?.config.secretRef, first.config.secretRef);
      expect(
        loaded?.catalog?.models.map((model) => model.ref.modelId),
        unorderedEquals(['gpt-5-mini', 'gpt-5']),
      );

      final replacement = _snapshot(_ref(2));
      await persistence.replace(loaded, replacement);
      await persistence.rollbackReplace(loaded, replacement);
      expect(
        (await persistence.load('toapis'))?.config.secretRef,
        first.config.secretRef,
      );

      final current = await persistence.load('toapis');
      await persistence.replace(current, replacement);
      await persistence.markReplaceRuntimePublished(current, replacement);
      await persistence.finalizeReplace(current, replacement);
      expect(
        (await persistence.load('toapis'))?.config.secretRef,
        replacement.config.secretRef,
      );
    },
  );

  test(
    'catalog refresh replaces the full directory and only clears removed bindings',
    () async {
      final directory = await Directory.systemTemp.createTemp('halo-settings-');
      addTearDown(() => directory.delete(recursive: true));
      final store = SqliteProviderConfigurationStore.open(
        '${directory.path}/providers.sqlite',
      );
      addTearDown(store.close);
      final persistence = AtomicProviderSettingsPersistence(store);
      final first = _snapshot(_ref(22));
      await persistence.replace(null, first);
      await persistence.markReplaceRuntimePublished(null, first);
      await persistence.finalizeReplace(null, first);
      await store.setGlobalDefaultModel(
        ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini'),
      );
      await store.setAgentModelOverride(
        'agent.keep',
        ModelRef(providerId: 'toapis', modelId: 'gpt-5'),
      );
      final previous = (await persistence.load('toapis'))!;
      final refreshed = ProviderSettingsSnapshot(
        config: previous.config,
        catalog: _catalog(
          modelIds: const ['gpt-5'],
          discoveredAt: DateTime.utc(2026, 7, 29, 13),
        ),
      );

      await persistence.replace(previous, refreshed);
      await persistence.markReplaceRuntimePublished(previous, refreshed);
      await persistence.finalizeReplace(previous, refreshed);

      expect(await store.loadGlobalDefaultModel(), isNull);
      expect(
        await store.loadAgentModelOverride('agent.keep'),
        ModelRef(providerId: 'toapis', modelId: 'gpt-5'),
      );
      final loaded = (await persistence.load('toapis'))!;
      expect(loaded.config.secretRef, previous.config.secretRef);
      expect(loaded.catalog!.discoveredAt, DateTime.utc(2026, 7, 29, 13));
      expect(loaded.catalog!.models.map((model) => model.ref.modelId), [
        'gpt-5',
      ]);
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
      await persistence.markReplaceRuntimePublished(null, first);
      await persistence.finalizeReplace(null, first);

      final loaded = (await persistence.load('toapis'))!;
      await persistence.remove(loaded);
      await persistence.restore(loaded);
      expect(await persistence.load('toapis'), isNotNull);

      final reloaded = (await persistence.load('toapis'))!;
      await persistence.remove(reloaded);
      await persistence.markRemovalRuntimePublished(reloaded);
      await persistence.finalizeRemoval(reloaded);
      expect(await persistence.load('toapis'), isNull);
    },
  );

  test(
    'reopened legacy config without catalog loads and can be removed',
    () async {
      final directory = await Directory.systemTemp.createTemp('halo-settings-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/providers.sqlite';
      var store = SqliteProviderConfigurationStore.open(path);
      await store.upsert(
        ProviderConfig.deepSeek(enabled: false, secretRef: _ref(24)),
      );
      await store.close();

      store = SqliteProviderConfigurationStore.open(path);
      addTearDown(store.close);
      final persistence = AtomicProviderSettingsPersistence(store);
      final legacy = (await persistence.load('deepseek'))!;

      expect(legacy.catalog, isNull);
      expect(await store.loadProviderModelCatalog('deepseek'), isNull);
      await persistence.remove(legacy);
      await persistence.markRemovalRuntimePublished(legacy);
      await persistence.finalizeRemoval(legacy);

      expect(await persistence.load('deepseek'), isNull);
      expect(await store.loadAllProviderModelCatalogs(), isEmpty);
    },
  );

  test(
    'legacy empty catalog loads for removal but cannot be republished',
    () async {
      final directory = await Directory.systemTemp.createTemp('halo-settings-');
      addTearDown(() => directory.delete(recursive: true));
      final store = SqliteProviderConfigurationStore.open(
        '${directory.path}/providers.sqlite',
      );
      addTearDown(store.close);
      final emptyCatalog = _catalog(modelIds: const []);
      final created = await store.replaceProviderConfiguration(
        expectedRevision: null,
        replacement: ProviderConfigurationReplacement(
          config: ProviderConfig.toApis(enabled: false, secretRef: _ref(25)),
          modelCatalog: emptyCatalog,
        ),
      );
      await store.markProviderMutationRuntimePublished(created);
      await store.finalizeProviderMutation(created);
      final persistence = AtomicProviderSettingsPersistence(store);
      final legacy = (await persistence.load('toapis'))!;

      expect(legacy.catalog!.models, isEmpty);
      await expectLater(
        persistence.replace(
          legacy,
          ProviderSettingsSnapshot(
            config: legacy.config,
            catalog: emptyCatalog,
          ),
        ),
        throwsStateError,
      );
      await persistence.remove(legacy);
      await persistence.markRemovalRuntimePublished(legacy);
      await persistence.finalizeRemoval(legacy);

      expect(await persistence.load('toapis'), isNull);
    },
  );

  test(
    'restart rolls back staged rotation without reading either Key',
    () async {
      final directory = await Directory.systemTemp.createTemp('halo-settings-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/providers.sqlite';
      var store = SqliteProviderConfigurationStore.open(path);
      var persistence = AtomicProviderSettingsPersistence(store);
      final first = _snapshot(_ref(4));
      await persistence.replace(null, first);
      await persistence.markReplaceRuntimePublished(null, first);
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
      expect(credentials.deleted, [replacement.config.secretRef]);
      expect(await store.listPendingProviderOperations(), isEmpty);
      expect(
        (await persistence.load('toapis'))?.config.secretRef,
        first.config.secretRef,
      );
    },
  );

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
      await persistence.markReplaceRuntimePublished(null, first);
      await persistence.finalizeReplace(null, first);
      final loaded = (await persistence.load('toapis'))!;
      final replacement = _snapshot(_ref(7));
      await persistence.replace(loaded, replacement);
      await persistence.markReplaceRuntimePublished(loaded, replacement);
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
      await persistence.markReplaceRuntimePublished(null, first);
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
    'restart restores staged removal without deleting its old ref',
    () async {
      final directory = await Directory.systemTemp.createTemp('halo-settings-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/providers.sqlite';
      var store = SqliteProviderConfigurationStore.open(path);
      var persistence = AtomicProviderSettingsPersistence(store);
      final first = _snapshot(_ref(10));
      await persistence.replace(null, first);
      await persistence.markReplaceRuntimePublished(null, first);
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
      expect(credentials.deleted, isEmpty);
      expect(await persistence.load('toapis'), isNotNull);
      expect(await store.listPendingProviderOperations(), isEmpty);
    },
  );

  test(
    'restart finalizes published removal and deletes only its old ref',
    () async {
      final directory = await Directory.systemTemp.createTemp('halo-settings-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/providers.sqlite';
      var store = SqliteProviderConfigurationStore.open(path);
      var persistence = AtomicProviderSettingsPersistence(store);
      final first = _snapshot(_ref(23));
      await persistence.replace(null, first);
      await persistence.markReplaceRuntimePublished(null, first);
      await persistence.finalizeReplace(null, first);
      final loaded = (await persistence.load('toapis'))!;
      await persistence.remove(loaded);
      await persistence.markRemovalRuntimePublished(loaded);
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
      await persistence.markReplaceRuntimePublished(null, first);
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
      await persistence.markReplaceRuntimePublished(null, first);
      await persistence.finalizeReplace(null, first);
      final loaded = (await persistence.load('toapis'))!;
      await persistence.replace(loaded, replacement);
      await persistence.markReplaceRuntimePublished(loaded, replacement);
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
        replacement: ProviderConfigurationReplacement(
          config: nextConfig,
          modelCatalog: null,
        ),
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
  catalog: _catalog(),
);

PersistedProviderModelCatalog _catalog({
  List<String> modelIds = const ['gpt-5-mini', 'gpt-5'],
  DateTime? discoveredAt,
}) => PersistedProviderModelCatalog(
  providerId: 'toapis',
  models: [
    for (final modelId in modelIds)
      ModelDescriptor(
        ref: ModelRef(providerId: 'toapis', modelId: modelId),
        displayName: modelId,
        capabilities: const ModelCapabilities.text(),
      ),
  ],
  discoveredAt: discoveredAt ?? DateTime.utc(2026, 7, 29, 12),
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
