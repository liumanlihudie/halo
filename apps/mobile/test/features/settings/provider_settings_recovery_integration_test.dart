import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/settings/provider_settings_controller.dart';
import 'package:halo_mobile/features/settings/provider_settings_persistence.dart';
import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';
import 'package:halo_mobile/model_runtime/secure_credential_store.dart';
import 'package:halo_mobile/model_runtime/sqlite_provider_configuration_store.dart';

void main() {
  test(
    'rollback failure survives restart and trusted recovery finalizes staged ref',
    () async {
      final directory = await Directory.systemTemp.createTemp('halo-recovery-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/providers.sqlite';
      var store = SqliteProviderConfigurationStore.open(path);
      var persistence = AtomicProviderSettingsPersistence(store);
      final oldRef = _ref(1);
      final newRef = _ref(2);
      final first = ProviderSettingsSnapshot(
        config: ProviderConfig.toApis(secretRef: oldRef),
        catalog: _catalog(),
      );
      await persistence.replace(null, first);
      await persistence.finalizeReplace(null, first);
      final credentials = _Credentials({oldRef: 'old-key'});
      final controller = ProviderSettingsController(
        credentials: credentials,
        catalogFetcher: _Fetcher(),
        persistence: persistence,
        runtime: _CloseStoreAndFail(store),
        secretRefs: _FixedRef(newRef),
      );

      await expectLater(
        controller.save(
          const ProviderSettingsDraft(
            providerId: 'toapis',
            apiKey: 'new-key',
            enabled: true,
          ),
        ),
        throwsA(isA<ProviderSettingsException>()),
      );

      expect(controller.state, ProviderSettingsState.recoveryPending);
      expect(credentials.deleted, isEmpty);
      expect(credentials.getCalls, 0);

      store = SqliteProviderConfigurationStore.open(path);
      addTearDown(store.close);
      persistence = AtomicProviderSettingsPersistence(store);
      await persistence.recoverPending(credentials);

      expect(credentials.getCalls, 0);
      expect(credentials.deleted, [oldRef]);
      expect((await persistence.load('toapis'))?.config.secretRef, newRef);
      expect(await store.listPendingProviderOperations(), isEmpty);
    },
  );
}

final class _Fetcher implements ProviderModelCatalogFetcher {
  @override
  Future<PersistedProviderModelCatalog> fetch(ProviderConfig config) async =>
      _catalog();
}

PersistedProviderModelCatalog _catalog() => PersistedProviderModelCatalog(
  providerId: 'toapis',
  models: [
    ModelDescriptor(
      ref: ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini'),
      displayName: 'GPT-5 mini',
      capabilities: const ModelCapabilities.text(),
    ),
  ],
  discoveredAt: DateTime.utc(2026, 7, 29, 12),
);

SecretRef _ref(int value) => SecretRef.parse(
  'keychain://halo.provider/00000000-0000-4000-8000-'
  '${value.toString().padLeft(12, '0')}',
);

final class _FixedRef implements ProviderSecretRefFactory {
  const _FixedRef(this.ref);

  final SecretRef ref;

  @override
  SecretRef next() => ref;
}

final class _CloseStoreAndFail implements ProviderRuntimeReloader {
  const _CloseStoreAndFail(this.store);

  final SqliteProviderConfigurationStore store;

  @override
  Future<void> reload() async {
    await store.close();
    throw StateError('runtime reload failed');
  }
}

final class _Credentials implements SecureCredentialStore {
  _Credentials(this.values);

  final Map<SecretRef, String> values;
  final deleted = <SecretRef>[];
  int getCalls = 0;

  @override
  Future<bool> delete(
    SecretRef ref, {
    CancellationToken? cancellationToken,
  }) async {
    deleted.add(ref);
    return values.remove(ref) != null;
  }

  @override
  Future<String?> get(
    SecretRef ref, {
    CancellationToken? cancellationToken,
  }) async {
    getCalls++;
    return values[ref];
  }

  @override
  Future<List<SecureCredentialMetadata>> listMetadata({
    String? service,
    CancellationToken? cancellationToken,
  }) async => [
    for (final ref in values.keys)
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
    values[ref] = secret;
  }
}
