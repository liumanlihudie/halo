import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/production_app_kernel.dart';
import 'package:halo_mobile/features/settings/provider_settings_controller.dart';
import 'package:halo_mobile/features/settings/provider_settings_persistence.dart';
import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/secure_credential_store.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';

void main() {
  test('opens app-support database and closes kernel idempotently', () async {
    final directory = await Directory.systemTemp.createTemp('halo-kernel-');
    addTearDown(() => directory.delete(recursive: true));
    final stores = <_FakeStore>[];
    final factory = ProductionAppKernelFactory(
      applicationSupportDirectory: () async => directory,
      openProviderStore: (_) {
        final store = _FakeStore();
        stores.add(store);
        return store;
      },
      buildSettingsPersistence: (_) => _FakeSettingsPersistence(),
      credentials: _FakeCredentials(),
    );

    final kernel = await factory.create();
    await Future.wait([kernel.close(), kernel.close()]);

    expect(kernel.name, 'production');
    expect(stores, hasLength(2));
    expect(stores.every((store) => store.closeCount == 1), isTrue);
  });

  test('initialization failure closes already opened settings store', () async {
    final directory = await Directory.systemTemp.createTemp('halo-kernel-');
    addTearDown(() => directory.delete(recursive: true));
    final settingsStore = _FakeStore();
    var opens = 0;
    final factory = ProductionAppKernelFactory(
      applicationSupportDirectory: () async => directory,
      openProviderStore: (_) {
        if (++opens == 1) return settingsStore;
        throw StateError('runtime store failed');
      },
      buildSettingsPersistence: (_) => _FakeSettingsPersistence(),
      credentials: _FakeCredentials(),
    );

    await expectLater(factory.create(), throwsStateError);

    expect(settingsStore.closeCount, 1);
  });

  test(
    'pending recovery failure fails closed and closes settings store',
    () async {
      final directory = await Directory.systemTemp.createTemp('halo-kernel-');
      addTearDown(() => directory.delete(recursive: true));
      final settingsStore = _FakeStore();
      final persistence = _FakeSettingsPersistence()
        ..recoveryError = StateError('recovery failed');
      final factory = ProductionAppKernelFactory(
        applicationSupportDirectory: () async => directory,
        openProviderStore: (_) => settingsStore,
        buildSettingsPersistence: (_) => persistence,
        credentials: _FakeCredentials(),
      );

      await expectLater(factory.create(), throwsStateError);

      expect(settingsStore.closeCount, 1);
      expect(persistence.recoveryCalls, 1);
    },
  );

  test(
    'production rejects persistence without durable recovery capability',
    () async {
      final directory = await Directory.systemTemp.createTemp('halo-kernel-');
      addTearDown(() => directory.delete(recursive: true));
      final settingsStore = _FakeStore();
      final factory = ProductionAppKernelFactory(
        applicationSupportDirectory: () async => directory,
        openProviderStore: (_) => settingsStore,
        buildSettingsPersistence: (_) => _NonRecoveringPersistence(),
        credentials: _FakeCredentials(),
      );

      await expectLater(factory.create(), throwsStateError);

      expect(settingsStore.closeCount, 1);
    },
  );

  test(
    'production SQLite kernel reopens from the same app-support path',
    () async {
      final directory = await Directory.systemTemp.createTemp('halo-kernel-');
      addTearDown(() => directory.delete(recursive: true));
      final factory = ProductionAppKernelFactory(
        applicationSupportDirectory: () async => directory,
        credentials: _FakeCredentials(),
      );

      final first = await factory.create();
      await first.close();
      final second = await factory.create();
      await second.close();

      expect(
        File('${directory.path}/halo_providers.sqlite').existsSync(),
        isTrue,
      );
    },
  );
}

final class _FakeStore implements ProviderConfigurationStore {
  int closeCount = 0;

  @override
  Future<void> close() async => closeCount++;

  @override
  Future<List<ProviderConfig>> loadAll() async => const [];

  @override
  Future<List<ProviderConfig>> loadEnabled() async => const [];

  @override
  Future<Map<String, ModelRef>> loadAgentModelOverrides() async => const {};

  @override
  Future<ModelRef?> loadAgentModelOverride(String agentId) async => null;

  @override
  Future<ModelRef?> loadGlobalDefaultModel() async => null;

  @override
  Future<void> remove(String providerId) async {}

  @override
  Future<void> setAgentModelOverride(String agentId, ModelRef? model) async {}

  @override
  Future<void> setGlobalDefaultModel(ModelRef? model) async {}

  @override
  Future<void> upsert(ProviderConfig config) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeSettingsPersistence
    implements
        ProviderSettingsPersistence,
        ProviderSettingsRecoveryPersistence {
  Object? recoveryError;
  int recoveryCalls = 0;

  @override
  Future<void> recoverPending(SecureCredentialStore credentials) async {
    recoveryCalls++;
    final error = recoveryError;
    if (error != null) throw error;
  }

  @override
  Future<void> finalizeRemoval(ProviderSettingsSnapshot snapshot) async {}

  @override
  Future<ProviderSettingsSnapshot?> load(String providerId) async => null;

  @override
  Future<void> remove(ProviderSettingsSnapshot snapshot) async {}

  @override
  Future<void> replace(
    ProviderSettingsSnapshot? previous,
    ProviderSettingsSnapshot next,
  ) async {}

  @override
  Future<void> rollbackReplace(
    ProviderSettingsSnapshot? previous,
    ProviderSettingsSnapshot next,
  ) async {}

  @override
  Future<void> finalizeReplace(
    ProviderSettingsSnapshot? previous,
    ProviderSettingsSnapshot next,
  ) async {}

  @override
  Future<void> restore(ProviderSettingsSnapshot snapshot) async {}
}

final class _NonRecoveringPersistence implements ProviderSettingsPersistence {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeCredentials implements SecureCredentialStore {
  @override
  Future<bool> delete(
    SecretRef ref, {
    CancellationToken? cancellationToken,
  }) async => true;

  @override
  Future<String?> get(
    SecretRef ref, {
    CancellationToken? cancellationToken,
  }) async => null;

  @override
  Future<List<SecureCredentialMetadata>> listMetadata({
    String? service,
    CancellationToken? cancellationToken,
  }) async => const [];

  @override
  Future<void> set(
    SecretRef ref,
    String secret, {
    CancellationToken? cancellationToken,
  }) async {}
}
