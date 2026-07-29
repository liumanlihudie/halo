import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/production_app_kernel.dart';
import 'package:halo_mobile/features/settings/provider_settings_controller.dart';
import 'package:halo_mobile/features/settings/provider_settings_persistence.dart';
import 'package:halo_mobile/features/single_chat/chat_message_repository.dart';
import 'package:halo_mobile/features/single_chat/drift_chat_message_repository.dart';
import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/secure_credential_store.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';
import 'package:halo_mobile/model_runtime/sqlite_provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/testing/fake_unary_http_adapter.dart';

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

  test('production injects a durable single-chat repository', () async {
    final directory = await Directory.systemTemp.createTemp('halo-kernel-');
    addTearDown(() => directory.delete(recursive: true));
    final factory = ProductionAppKernelFactory(
      applicationSupportDirectory: () async => directory,
      credentials: _FakeCredentials(),
    );

    final kernel = await factory.create();

    expect(
      kernel.dependencies.chatRepository,
      isA<DriftChatMessageRepository>(),
    );
    expect(
      kernel.dependencies.chatRepository,
      isA<DurableChatMessageRepository>(),
    );
    kernel.dependencies.chatRepository.commandOutbox.reserve(
      conversationId: 'general-assistant',
      normalizedIntent: '验证 production outbox 路径',
      createCommandId: () => 'production-outbox-command',
    );
    expect(
      File('${directory.path}/single-chat-commands.json').existsSync(),
      isTrue,
    );
    expect(
      File('${directory.path}/halo_single_chat.sqlite').existsSync(),
      isTrue,
    );
    await kernel.close();
    expect(
      kernel.dependencies.chatRepository.load('general-assistant'),
      throwsStateError,
    );
  });

  test(
    'production single-chat messages survive kernel close and reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp('halo-kernel-');
      addTearDown(() => directory.delete(recursive: true));
      final factory = ProductionAppKernelFactory(
        applicationSupportDirectory: () async => directory,
        credentials: _FakeCredentials(),
      );
      const message = ChatMessageProjection(
        id: 'persisted:user',
        kind: ChatMessageKind.userText,
        text: '跨 kernel 保留',
      );

      final first = await factory.create();
      await first.dependencies.chatRepository.append(
        'general-assistant',
        message,
      );
      await first.close();

      final reopened = await factory.create();
      addTearDown(reopened.close);

      final loaded = await reopened.dependencies.chatRepository.load(
        'general-assistant',
      );
      expect(loaded, hasLength(1));
      expect(loaded.single.id, message.id);
      expect(loaded.single.kind, message.kind);
      expect(loaded.single.text, message.text);
    },
  );

  test(
    'initialization failure closes durable chat repository and preserves error',
    () async {
      final directory = await Directory.systemTemp.createTemp('halo-kernel-');
      addTearDown(() => directory.delete(recursive: true));
      final settingsStore = _FakeStore();
      final repository = _TrackingDurableChatRepository(
        closeError: StateError('chat repository cleanup failed'),
      );
      final originalError = StateError('runtime store failed');
      var storeOpens = 0;
      final factory = ProductionAppKernelFactory(
        applicationSupportDirectory: () async => directory,
        openProviderStore: (_) {
          if (++storeOpens == 1) return settingsStore;
          throw originalError;
        },
        buildSettingsPersistence: (_) => _FakeSettingsPersistence(),
        credentials: _FakeCredentials(),
        openChatRepository:
            ({
              required databasePath,
              required commandOutbox,
              required conversations,
            }) async {
              expect(databasePath, '${directory.path}/halo_single_chat.sqlite');
              commandOutbox.reserve(
                conversationId: 'general-assistant',
                normalizedIntent: '初始化失败前打开 outbox',
                createCommandId: () => 'initialization-failure-command',
              );
              expect(
                File(
                  '${directory.path}/single-chat-commands.json',
                ).existsSync(),
                isTrue,
              );
              expect(conversations, contains('general-assistant'));
              return repository;
            },
      );

      await expectLater(factory.create(), throwsA(same(originalError)));

      expect(repository.closeCount, 1);
      expect(settingsStore.closeCount, 1);
    },
  );

  test(
    'production save discovers every model and runtime reload uses persisted catalog',
    () async {
      final directory = await Directory.systemTemp.createTemp('halo-kernel-');
      addTearDown(() => directory.delete(recursive: true));
      final credentials = _FakeCredentials();
      final adapter = FakeUnaryHttpAdapter(retainRequestContentForTesting: true)
        ..enqueueJson(
          statusCode: 200,
          body: {
            'object': 'list',
            'data': [
              {'id': 'catalog-only-a', 'object': 'model'},
              {'id': 'catalog-only-b', 'object': 'model'},
            ],
          },
        );
      addTearDown(adapter.dispose);
      final factory = ProductionAppKernelFactory(
        applicationSupportDirectory: () async => directory,
        credentials: credentials,
        unaryHttpAdapter: adapter,
      );
      final kernel = await factory.create();

      await kernel.dependencies.providerSettings!.save(
        const ProviderSettingsDraft(
          providerId: 'toapis',
          apiKey: 'production-catalog-secret',
          enabled: true,
        ),
      );
      await kernel.close();

      final store = SqliteProviderConfigurationStore.open(
        '${directory.path}/halo_providers.sqlite',
      );
      addTearDown(store.close);
      final catalog = (await store.loadProviderModelCatalog('toapis'))!;
      expect(catalog.models.map((model) => model.ref.modelId), [
        'catalog-only-a',
        'catalog-only-b',
      ]);
      expect(
        catalog.models.map((model) => model.ref.modelId),
        isNot(contains('gpt-5-mini')),
      );
      expect(adapter.records.single.method, 'GET');
      expect(adapter.records.single.path, '/v1/models');
      expect(adapter.records.single.authorizationWasBearer, isTrue);
      expect(adapter.records.single.toString(), isNot(contains('secret')));
    },
  );
}

final class _TrackingDurableChatRepository
    implements DurableChatMessageRepository {
  _TrackingDurableChatRepository({this.closeError});

  final Object? closeError;
  int closeCount = 0;

  @override
  Future<void> close() async {
    closeCount++;
    final error = closeError;
    if (error != null) throw error;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
  final Map<SecretRef, String> values = {};

  @override
  Future<bool> delete(
    SecretRef ref, {
    CancellationToken? cancellationToken,
  }) async => values.remove(ref) != null;

  @override
  Future<String?> get(
    SecretRef ref, {
    CancellationToken? cancellationToken,
  }) async => values[ref];

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
