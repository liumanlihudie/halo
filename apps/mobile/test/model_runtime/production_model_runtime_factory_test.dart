import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/production_model_runtime_factory.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/provider_inspection_transport.dart';
import 'package:halo_mobile/model_runtime/provider_registry.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';
import 'package:halo_mobile/model_runtime/secure_credential_store.dart';
import 'package:halo_mobile/model_runtime/sqlite_provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/unary_http_transport.dart';

void main() {
  test(
    'loads every runtime model from the opened SQLite catalog only',
    () async {
      final fixture = _SqliteFactoryFixture.create();
      final seed = SqliteProviderConfigurationStore.open(fixture.path);
      final created = await seed.replaceProviderConfiguration(
        expectedRevision: null,
        replacement: ProviderConfigurationReplacement(
          config: ProviderConfig.deepSeek(),
          modelCatalog: PersistedProviderModelCatalog(
            providerId: 'deepseek',
            models: [
              _model('deepseek', 'deepseek-chat'),
              _model('deepseek', 'deepseek-reasoner'),
            ],
            discoveredAt: DateTime.utc(2026, 7, 29, 12),
          ),
        ),
      );
      await seed.markProviderMutationRuntimePublished(created);
      await seed.finalizeProviderMutation(created);
      await seed.close();
      var fallbackCalls = 0;

      final runtime = await ProductionModelRuntimeFactory(
        openConfigurationStore: () =>
            SqliteProviderConfigurationStore.open(fixture.path),
        credentialStore: _MemoryCredentialStore(),
        loadModelCatalog: (providerId, cancellationToken) async {
          fallbackCalls++;
          return [_model(providerId, 'gpt-5-mini')];
        },
        inspectionTransport: _NoNetworkInspectionTransport(),
        unaryHttpAdapter: _ProviderResponseAdapter(),
        endpointPolicy: const _AllowTestEndpointPolicy(),
      ).create();
      try {
        expect(
          runtime.registry
              .resolveModel(
                ModelRef(providerId: 'deepseek', modelId: 'deepseek-chat'),
              )
              .ref
              .modelId,
          'deepseek-chat',
        );
        expect(
          runtime.registry
              .resolveModel(
                ModelRef(providerId: 'deepseek', modelId: 'deepseek-reasoner'),
              )
              .ref
              .modelId,
          'deepseek-reasoner',
        );
        expect(
          () => runtime.registry.resolveModel(
            ModelRef(providerId: 'deepseek', modelId: 'gpt-5-mini'),
          ),
          throwsA(
            isA<ModelRuntimeException>().having(
              (error) => error.code,
              'code',
              ModelRuntimeErrorCode.modelNotFound,
            ),
          ),
        );
        expect(fallbackCalls, 0);
      } finally {
        await runtime.close();
        fixture.delete();
      }
    },
  );

  test(
    'rejects enabled SQLite providers with absent or empty catalogs',
    () async {
      for (final persistEmptyCatalog in [false, true]) {
        final fixture = _SqliteFactoryFixture.create();
        final seed = SqliteProviderConfigurationStore.open(fixture.path);
        if (persistEmptyCatalog) {
          final created = await seed.replaceProviderConfiguration(
            expectedRevision: null,
            replacement: ProviderConfigurationReplacement(
              config: ProviderConfig.deepSeek(),
              modelCatalog: PersistedProviderModelCatalog(
                providerId: 'deepseek',
                models: const [],
                discoveredAt: DateTime.utc(2026, 7, 29, 13),
              ),
            ),
          );
          await seed.markProviderMutationRuntimePublished(created);
          await seed.finalizeProviderMutation(created);
        } else {
          await seed.upsert(ProviderConfig.deepSeek());
        }
        await seed.close();
        var fallbackCalls = 0;
        final factory = ProductionModelRuntimeFactory(
          openConfigurationStore: () =>
              SqliteProviderConfigurationStore.open(fixture.path),
          credentialStore: _MemoryCredentialStore(),
          loadModelCatalog: (providerId, cancellationToken) async {
            fallbackCalls++;
            return [_model(providerId, 'deepseek-chat')];
          },
          inspectionTransport: _NoNetworkInspectionTransport(),
          unaryHttpAdapter: _ProviderResponseAdapter(),
          endpointPolicy: const _AllowTestEndpointPolicy(),
        );

        await expectLater(
          factory.create(),
          throwsA(
            isA<ModelRuntimeException>().having(
              (error) => error.code,
              'code',
              ModelRuntimeErrorCode.invalidConfiguration,
            ),
          ),
          reason: persistEmptyCatalog ? 'empty catalog' : 'absent catalog',
        );
        expect(fallbackCalls, 0);
        fixture.delete();
      }
    },
  );

  test(
    'builds compatible and native providers through secure unary transports',
    () async {
      final store = _MemoryConfigurationStore(
        configs: [
          ProviderConfig.toApis(
            secretRef: SecretRef.parse(
              'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174000',
            ),
          ),
          ProviderConfig.anthropic(
            secretRef: SecretRef.parse(
              'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174001',
            ),
          ),
        ],
        globalDefault: ModelRef(
          providerId: 'toapis',
          modelId: 'compatible-chat',
        ),
        agentOverrides: {
          'agent.reviewer': ModelRef(
            providerId: 'anthropic',
            modelId: 'claude-native',
          ),
        },
      );
      final adapter = _ProviderResponseAdapter();
      final runtime = await _factory(
        store,
        adapter: adapter,
        catalogs: {
          'toapis': [_model('toapis', 'compatible-chat')],
          'anthropic': [_model('anthropic', 'claude-native')],
        },
      ).create();
      try {
        expect(
          await runtime.resolveConfiguredModel(),
          ModelRef(providerId: 'toapis', modelId: 'compatible-chat'),
        );
        expect(
          await runtime.resolveConfiguredModel(agentId: 'agent.reviewer'),
          ModelRef(providerId: 'anthropic', modelId: 'claude-native'),
        );
        store.agentOverrides['agent.reviewer'] = ModelRef(
          providerId: 'toapis',
          modelId: 'compatible-chat',
        );
        expect(
          await runtime.resolveConfiguredModel(agentId: 'agent.reviewer'),
          ModelRef(providerId: 'anthropic', modelId: 'claude-native'),
        );

        final compatible = await runtime.registry.chat(
          _request('compatible-request', 'toapis', 'compatible-chat'),
        );
        final native = await runtime.registry.chat(
          _request('native-request', 'anthropic', 'claude-native'),
        );

        expect(compatible.outputText, 'compatible response');
        expect(native.outputText, 'native response');
        expect(adapter.paths, ['/v1/chat/completions', '/v1/messages']);
      } finally {
        await runtime.close();
      }
    },
  );

  test(
    'snapshot rejects unknown and disabled providers and stays immutable',
    () async {
      final store = _MemoryConfigurationStore(
        configs: [
          ProviderConfig.toApis(),
          ProviderConfig.deepSeek(enabled: false),
        ],
      );
      final runtime = await _factory(
        store,
        catalogs: {
          'toapis': [_model('toapis', 'chat')],
          'deepseek': [_model('deepseek', 'chat')],
        },
      ).create();
      try {
        expect(
          () => runtime.registry.resolveModel(
            ModelRef(providerId: 'toapis', modelId: 'unknown'),
          ),
          throwsA(
            isA<ModelRuntimeException>().having(
              (error) => error.code,
              'code',
              ModelRuntimeErrorCode.modelNotFound,
            ),
          ),
        );
        expect(
          () => runtime.registry.resolveModel(
            ModelRef(providerId: 'deepseek', modelId: 'chat'),
          ),
          throwsA(
            isA<ModelRuntimeException>().having(
              (error) => error.code,
              'code',
              ModelRuntimeErrorCode.providerNotFound,
            ),
          ),
        );
        expect(runtime.registry, isA<ProviderRegistryView>());
        expect(runtime.registry, isNot(isA<ProviderRegistry>()));
      } finally {
        await runtime.close();
      }
    },
  );

  test('initialization failure rolls back the opened store', () async {
    final store = _MemoryConfigurationStore(configs: [ProviderConfig.toApis()]);
    final factory = _factory(
      store,
      catalogs: {
        'toapis': [_model('wrong-provider', 'chat')],
      },
    );

    await expectLater(factory.create(), throwsA(isA<ModelRuntimeException>()));

    expect(store.closeCount, 1);
  });

  test('rejects non-Keychain refs before a runtime can be published', () async {
    final store = _MemoryConfigurationStore(
      configs: [
        ProviderConfig.toApis(
          secretRef: SecretRef.parse('memory://test/toapis'),
        ),
      ],
    );

    await expectLater(
      _factory(
        store,
        catalogs: {
          'toapis': [_model('toapis', 'chat')],
        },
      ).create(),
      throwsA(
        isA<ModelRuntimeException>().having(
          (error) => error.code,
          'code',
          ModelRuntimeErrorCode.invalidConfiguration,
        ),
      ),
    );

    expect(store.closeCount, 1);
  });

  test(
    'factory rejects cross-provider ownership including disabled rows',
    () async {
      final ref = SecretRef.parse(
        'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174000',
      );
      final store = _MemoryConfigurationStore(
        configs: [
          ProviderConfig.openAI(enabled: false, secretRef: ref),
          ProviderConfig.customOpenAICompatible(
            providerId: 'custom',
            displayName: 'Custom',
            baseUri: Uri.parse('https://custom.example/v1'),
            secretRef: ref,
          ),
        ],
      );
      await expectLater(
        _factory(
          store,
          catalogs: {
            'custom': [_model('custom', 'chat')],
          },
        ).create(),
        throwsA(
          isA<ModelRuntimeException>().having(
            (error) => error.code,
            'code',
            ModelRuntimeErrorCode.invalidConfiguration,
          ),
        ),
      );
      expect(store.closeCount, 1);
    },
  );

  test('invalid persisted model binding aborts initialization', () async {
    final store = _MemoryConfigurationStore(
      configs: [ProviderConfig.toApis()],
      agentOverrides: {
        'agent.invalid': ModelRef(providerId: 'toapis', modelId: 'missing'),
      },
    );

    await expectLater(
      _factory(
        store,
        catalogs: {
          'toapis': [_model('toapis', 'chat')],
        },
      ).create(),
      throwsA(
        isA<ModelRuntimeException>().having(
          (error) => error.code,
          'code',
          ModelRuntimeErrorCode.modelNotFound,
        ),
      ),
    );

    expect(store.closeCount, 1);
  });

  test('factory and runtime reject non-canonical agent IDs', () async {
    final invalidStore = _MemoryConfigurationStore(
      configs: [ProviderConfig.toApis()],
      agentOverrides: {
        'agent\u200binvalid': ModelRef(providerId: 'toapis', modelId: 'chat'),
      },
    );
    await expectLater(
      _factory(
        invalidStore,
        catalogs: {
          'toapis': [_model('toapis', 'chat')],
        },
      ).create(),
      throwsA(anything),
    );
    expect(invalidStore.closeCount, 1);

    final store = _MemoryConfigurationStore(
      configs: [ProviderConfig.toApis()],
      globalDefault: ModelRef(providerId: 'toapis', modelId: 'chat'),
    );
    final runtime = await _factory(
      store,
      catalogs: {
        'toapis': [_model('toapis', 'chat')],
      },
    ).create();
    try {
      await expectLater(
        runtime.resolveConfiguredModel(agentId: 'agent\u202Eevil'),
        throwsArgumentError,
      );
    } finally {
      await runtime.close();
    }
  });

  test('runtime close is idempotent', () async {
    final store = _MemoryConfigurationStore(configs: [ProviderConfig.toApis()]);
    final runtime = await _factory(
      store,
      catalogs: {
        'toapis': [_model('toapis', 'chat')],
      },
    ).create();

    await runtime.close();
    await runtime.close();

    expect(store.closeCount, 1);
  });

  test('all production entry points fail closed after close', () async {
    final store = _MemoryConfigurationStore(
      configs: [ProviderConfig.toApis()],
      globalDefault: ModelRef(providerId: 'toapis', modelId: 'chat'),
    );
    final runtime = await _factory(
      store,
      catalogs: {
        'toapis': [_model('toapis', 'chat')],
      },
    ).create();
    await runtime.close();

    expect(
      () => runtime.registry.resolveModel(
        ModelRef(providerId: 'toapis', modelId: 'chat'),
      ),
      throwsStateError,
    );
    await expectLater(runtime.resolveConfiguredModel(), throwsStateError);
    await expectLater(
      runtime.chat(_request('closed-chat', 'toapis', 'chat')),
      throwsStateError,
    );
    await expectLater(runtime.discoverModels('toapis'), throwsStateError);
    await expectLater(runtime.probeHealth('toapis'), throwsStateError);
  });

  test(
    'close cancels and drains an in-flight chat before store close',
    () async {
      final store = _MemoryConfigurationStore(
        configs: [
          ProviderConfig.toApis(
            secretRef: SecretRef.parse(
              'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174000',
            ),
          ),
        ],
      );
      final adapter = _CancellationBlockingAdapter();
      final runtime = await _factory(
        store,
        adapter: adapter,
        catalogs: {
          'toapis': [_model('toapis', 'chat')],
        },
      ).create();

      final chat = runtime.chat(_request('in-flight', 'toapis', 'chat'));
      await adapter.dispatched.future;
      final close = runtime.close();

      await expectLater(chat, throwsA(anything));
      await close;
      expect(adapter.cancelled, isTrue);
      expect(store.closeCount, 1);
    },
  );

  test(
    'hot swap publishes the new snapshot before closing the old one',
    () async {
      final oldStore = _MemoryConfigurationStore(
        configs: [ProviderConfig.toApis()],
        globalDefault: ModelRef(providerId: 'toapis', modelId: 'old'),
      );
      final oldRuntime = await _factory(
        oldStore,
        catalogs: {
          'toapis': [_model('toapis', 'old')],
        },
      ).create();
      final newStore = _MemoryConfigurationStore(
        configs: [ProviderConfig.toApis()],
        globalDefault: ModelRef(providerId: 'toapis', modelId: 'new'),
      );
      final slot = ProductionModelRuntimeSlot(oldRuntime);

      await slot.replaceWith(
        _factory(
          newStore,
          catalogs: {
            'toapis': [_model('toapis', 'new')],
          },
        ),
      );

      expect(
        await slot.resolveConfiguredModel(),
        ModelRef(providerId: 'toapis', modelId: 'new'),
      );
      expect(oldStore.closeCount, 1);
      await slot.close();
    },
  );

  test(
    'late old-runtime close failure keeps the new runtime published',
    () async {
      final oldStore = _MemoryConfigurationStore(
        configs: [ProviderConfig.toApis()],
        globalDefault: ModelRef(providerId: 'toapis', modelId: 'old'),
        closeError: StateError('sensitive retirement failure'),
      );
      final slot = ProductionModelRuntimeSlot(
        await _factory(
          oldStore,
          catalogs: {
            'toapis': [_model('toapis', 'old')],
          },
        ).create(),
      );
      final newStore = _MemoryConfigurationStore(
        configs: [ProviderConfig.toApis()],
        globalDefault: ModelRef(providerId: 'toapis', modelId: 'new'),
      );

      await slot.replaceWith(
        _factory(
          newStore,
          catalogs: {
            'toapis': [_model('toapis', 'new')],
          },
        ),
      );

      expect(
        await slot.resolveConfiguredModel(),
        ModelRef(providerId: 'toapis', modelId: 'new'),
      );
      expect(
        slot.retirementState,
        ProductionRuntimeRetirementState.cleanupFailed,
      );
      expect(oldStore.closeCount, 1);
      await slot.close();
    },
  );

  test('caller cancellation links with close and releases listeners', () async {
    final store = _MemoryConfigurationStore(
      configs: [
        ProviderConfig.toApis(
          secretRef: SecretRef.parse(
            'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174000',
          ),
        ),
      ],
    );
    final adapter = _CancellationBlockingAdapter();
    final runtime = await _factory(
      store,
      adapter: adapter,
      catalogs: {
        'toapis': [_model('toapis', 'chat')],
      },
    ).create();
    final caller = CancellationToken();
    final chat = runtime.chat(
      ChatRequest(
        requestId: 'caller-cancel',
        model: ModelRef(providerId: 'toapis', modelId: 'chat'),
        messages: [ChatMessage(role: ChatRole.user, content: 'hello')],
        cancellationToken: caller,
      ),
    );
    await adapter.dispatched.future;
    caller.cancel();
    await expectLater(
      chat.timeout(const Duration(seconds: 1)),
      throwsA(anything),
    );
    expect(caller.activeListenerCount, 0);
    await runtime.close();
  });

  test(
    'slot generation prevents late replace and close resurrection',
    () async {
      final originalStore = _MemoryConfigurationStore(
        configs: [ProviderConfig.toApis()],
        globalDefault: ModelRef(providerId: 'toapis', modelId: 'original'),
      );
      final slot = ProductionModelRuntimeSlot(
        await _factory(
          originalStore,
          catalogs: {
            'toapis': [_model('toapis', 'original')],
          },
        ).create(),
      );
      final slowGate = Completer<void>();
      final slowStore = _MemoryConfigurationStore(
        configs: [ProviderConfig.toApis()],
        globalDefault: ModelRef(providerId: 'toapis', modelId: 'slow'),
        loadGate: slowGate,
      );
      final fastStore = _MemoryConfigurationStore(
        configs: [ProviderConfig.toApis()],
        globalDefault: ModelRef(providerId: 'toapis', modelId: 'fast'),
      );
      final slow = slot.replaceWith(
        _factory(
          slowStore,
          catalogs: {
            'toapis': [_model('toapis', 'slow')],
          },
        ),
      );
      final slowFailure = expectLater(
        slow,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Production model runtime replacement was superseded',
          ),
        ),
      );
      final fast = slot.replaceWith(
        _factory(
          fastStore,
          catalogs: {
            'toapis': [_model('toapis', 'fast')],
          },
        ),
      );
      await fast;
      slowGate.complete();
      await slowFailure;
      expect(
        await slot.resolveConfiguredModel(),
        ModelRef(providerId: 'toapis', modelId: 'fast'),
      );
      expect(slowStore.closeCount, 1);

      final lateGate = Completer<void>();
      final lateStore = _MemoryConfigurationStore(
        configs: [ProviderConfig.toApis()],
        globalDefault: ModelRef(providerId: 'toapis', modelId: 'late'),
        loadGate: lateGate,
      );
      final late = slot.replaceWith(
        _factory(
          lateStore,
          catalogs: {
            'toapis': [_model('toapis', 'late')],
          },
        ),
      );
      final lateFailure = expectLater(
        late,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Production model runtime slot is closed',
          ),
        ),
      );
      final close = slot.close();
      lateGate.complete();
      await Future.wait([lateFailure, close]);
      expect(lateStore.closeCount, 1);
      expect(() => slot.resolveConfiguredModel(), throwsStateError);
    },
  );

  test(
    'slot close cancels and reclaims a create that never completes naturally',
    () async {
      final originalStore = _MemoryConfigurationStore(
        configs: [ProviderConfig.toApis()],
        globalDefault: ModelRef(providerId: 'toapis', modelId: 'original'),
      );
      final slot = ProductionModelRuntimeSlot(
        await _factory(
          originalStore,
          catalogs: {
            'toapis': [_model('toapis', 'original')],
          },
        ).create(),
      );
      final loadStarted = Completer<void>();
      final pendingStore = _MemoryConfigurationStore(
        configs: [ProviderConfig.toApis()],
        loadGate: Completer<void>(),
        loadStarted: loadStarted,
      );

      final replace = slot.replaceWith(_factory(pendingStore));
      final replacementFailure = expectLater(
        replace,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Production model runtime slot is closed',
          ),
        ),
      );
      await loadStarted.future;
      final close = slot.close();

      await close.timeout(const Duration(seconds: 1));
      await replacementFailure.timeout(const Duration(seconds: 1));
      expect(pendingStore.closeCount, 1);
      expect(() => slot.resolveConfiguredModel(), throwsStateError);
    },
  );

  test('slot cancellation reaches a pending catalog loader', () async {
    final originalStore = _MemoryConfigurationStore(
      configs: [ProviderConfig.toApis()],
      globalDefault: ModelRef(providerId: 'toapis', modelId: 'original'),
    );
    final slot = ProductionModelRuntimeSlot(
      await _factory(
        originalStore,
        catalogs: {
          'toapis': [_model('toapis', 'original')],
        },
      ).create(),
    );
    final catalogStarted = Completer<void>();
    var catalogCancelled = false;
    final pendingStore = _MemoryConfigurationStore(
      configs: [ProviderConfig.toApis()],
    );
    final replace = slot.replaceWith(
      _factory(
        pendingStore,
        catalogLoader: (providerId, cancellationToken) async {
          catalogStarted.complete();
          await cancellationToken.whenCancelled;
          catalogCancelled = true;
          throw StateError('cancelled');
        },
      ),
    );
    final replacementFailure = expectLater(
      replace,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Production model runtime slot is closed',
        ),
      ),
    );
    await catalogStarted.future;

    await slot.close().timeout(const Duration(seconds: 1));
    await replacementFailure.timeout(const Duration(seconds: 1));

    expect(catalogCancelled, isTrue);
    expect(pendingStore.closeCount, 1);
  });

  test(
    'registry close drains concurrent chats despite throwing listeners',
    () async {
      final store = _MemoryConfigurationStore(
        configs: [
          ProviderConfig.toApis(
            secretRef: SecretRef.parse(
              'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174000',
            ),
          ),
        ],
      );
      final adapter = _ThrowingListenerCancellationAdapter();
      final runtime = await _factory(
        store,
        adapter: adapter,
        catalogs: {
          'toapis': [_model('toapis', 'chat')],
        },
      ).create();
      final chats = [
        runtime.chat(_request('concurrent-one', 'toapis', 'chat')),
        runtime.chat(_request('concurrent-two', 'toapis', 'chat')),
      ];
      final failures = [
        for (final chat in chats) expectLater(chat, throwsA(anything)),
      ];
      await adapter.allDispatched.future;

      await runtime.close().timeout(const Duration(seconds: 1));
      await Future.wait(failures);
      expect(adapter.cancelledCount, 2);
      expect(store.closeCount, 1);
    },
  );

  test(
    'runtime close cancels discovery even when transport ignores cancellation',
    () async {
      final store = _MemoryConfigurationStore(
        configs: [
          ProviderConfig.toApis(
            secretRef: SecretRef.parse(
              'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174000',
            ),
          ),
        ],
      );
      final inspectionTransport = _IgnoringCancellationInspectionTransport();
      final runtime = await _factory(
        store,
        inspectionTransport: inspectionTransport,
        shutdownTimeout: const Duration(milliseconds: 20),
        catalogs: {
          'toapis': [_model('toapis', 'chat')],
        },
      ).create();
      final discovery = runtime.discoverModels('toapis');
      final discoveryFailure = expectLater(
        discovery,
        throwsA(
          isA<ModelRuntimeException>().having(
            (error) => error.code,
            'code',
            ModelRuntimeErrorCode.streamInterrupted,
          ),
        ),
      );
      await inspectionTransport.dispatched.future;

      await runtime.close().timeout(const Duration(seconds: 1));
      await discoveryFailure;

      expect(runtime.shutdownForced, isFalse);
      expect(store.closeCount, 1);
    },
  );

  test(
    'runtime fences delayed discovery and health successes after close',
    () async {
      final store = _MemoryConfigurationStore(
        configs: [ProviderConfig.toApis()],
      );
      final inspectionTransport = _DelayedSuccessInspectionTransport();
      final runtime = await _factory(
        store,
        inspectionTransport: inspectionTransport,
        catalogs: {
          'toapis': [_model('toapis', 'chat')],
        },
      ).create();
      final discoveryFailure = expectLater(
        runtime.discoverModels('toapis', forceRefresh: true),
        throwsA(
          isA<ModelRuntimeException>().having(
            (error) => error.code,
            'code',
            ModelRuntimeErrorCode.streamInterrupted,
          ),
        ),
      );
      final healthFailure = expectLater(
        runtime.probeHealth('toapis'),
        throwsA(
          isA<ModelRuntimeException>().having(
            (error) => error.code,
            'code',
            ModelRuntimeErrorCode.streamInterrupted,
          ),
        ),
      );
      await Future.wait([
        inspectionTransport.catalogDispatched.future,
        inspectionTransport.healthDispatched.future,
      ]);

      await runtime.close();
      inspectionTransport.completeSuccess();

      await Future.wait([discoveryFailure, healthFailure]);
      expect(() => runtime.registry.configs, throwsStateError);
    },
  );

  test('runtime close force-detaches a hung configuration store', () async {
    final store = _MemoryConfigurationStore(
      configs: [ProviderConfig.toApis()],
      closeGate: Completer<void>(),
    );
    final runtime = await _factory(
      store,
      shutdownTimeout: const Duration(milliseconds: 20),
    ).create();

    await runtime.close().timeout(const Duration(seconds: 1));

    expect(runtime.shutdownForced, isTrue);
    expect(store.closeCount, 1);
    expect(() => runtime.registry.configs, throwsStateError);
  });

  test('runtime close fences a model resolution that completes late', () async {
    final store = _MemoryConfigurationStore(
      configs: [ProviderConfig.toApis()],
      globalDefault: ModelRef(providerId: 'toapis', modelId: 'chat'),
    );
    final runtime = await _factory(
      store,
      catalogs: {
        'toapis': [_model('toapis', 'chat')],
      },
    ).create();

    final resolution = runtime.resolveConfiguredModel();
    final close = runtime.close();

    await expectLater(
      resolution,
      throwsA(
        isA<ModelRuntimeException>().having(
          (error) => error.code,
          'code',
          ModelRuntimeErrorCode.streamInterrupted,
        ),
      ),
    );
    await close;
  });

  test('runtime close force-detaches chat hung in credential lookup', () async {
    final ref = SecretRef.parse(
      'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174000',
    );
    final store = _MemoryConfigurationStore(
      configs: [ProviderConfig.toApis(secretRef: ref)],
    );
    final credentials = _IgnoringCredentialStore();
    final runtime = await _factory(
      store,
      credentialStore: credentials,
      shutdownTimeout: const Duration(milliseconds: 20),
      catalogs: {
        'toapis': [_model('toapis', 'chat')],
      },
    ).create();
    final chat = runtime.chat(_request('hung-credential', 'toapis', 'chat'));
    await credentials.dispatched.future;

    await runtime.close().timeout(const Duration(seconds: 1));

    expect(runtime.shutdownForced, isTrue);
    expect(chat, doesNotComplete);
    expect(store.closeCount, 1);
  });

  test('late credential success cannot dispatch after runtime close', () async {
    final ref = SecretRef.parse(
      'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174000',
    );
    final store = _MemoryConfigurationStore(
      configs: [ProviderConfig.toApis(secretRef: ref)],
    );
    final credentials = _DelayedCredentialStore();
    final adapter = _ProviderResponseAdapter();
    final runtime = await _factory(
      store,
      credentialStore: credentials,
      adapter: adapter,
      shutdownTimeout: const Duration(milliseconds: 20),
      catalogs: {
        'toapis': [_model('toapis', 'chat')],
      },
    ).create();
    final chat = runtime.chat(_request('late-credential', 'toapis', 'chat'));
    final chatFailure = expectLater(
      chat,
      throwsA(
        isA<ModelRuntimeException>().having(
          (error) => error.code,
          'code',
          ModelRuntimeErrorCode.streamInterrupted,
        ),
      ),
    );
    await credentials.dispatched.future;

    await runtime.close();
    credentials.complete();
    await chatFailure;

    expect(adapter.paths, isEmpty);
    expect(runtime.shutdownForced, isTrue);
  });

  test('slot close is bounded when pending store cleanup hangs', () async {
    final originalStore = _MemoryConfigurationStore(
      configs: [ProviderConfig.toApis()],
    );
    final slot = ProductionModelRuntimeSlot(
      await _factory(
        originalStore,
        shutdownTimeout: const Duration(milliseconds: 20),
      ).create(),
    );
    final loadStarted = Completer<void>();
    final pendingStore = _MemoryConfigurationStore(
      configs: [ProviderConfig.toApis()],
      loadGate: Completer<void>(),
      loadStarted: loadStarted,
      closeGate: Completer<void>(),
    );
    final replace = slot.replaceWith(
      _factory(pendingStore, shutdownTimeout: const Duration(milliseconds: 20)),
    );
    final replacementFailure = expectLater(
      replace,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Production model runtime slot is closed',
        ),
      ),
    );
    await loadStarted.future;

    await slot.close().timeout(const Duration(seconds: 1));
    await replacementFailure.timeout(const Duration(seconds: 1));
    expect(() => slot.resolveConfiguredModel(), throwsStateError);
  });

  test('slot replacement fences a hung previous-runtime cleanup', () async {
    final oldStore = _MemoryConfigurationStore(
      configs: [ProviderConfig.toApis()],
      globalDefault: ModelRef(providerId: 'toapis', modelId: 'old'),
      closeGate: Completer<void>(),
    );
    final slot = ProductionModelRuntimeSlot(
      await _factory(
        oldStore,
        shutdownTimeout: const Duration(milliseconds: 20),
        catalogs: {
          'toapis': [_model('toapis', 'old')],
        },
      ).create(),
    );
    final newStore = _MemoryConfigurationStore(
      configs: [ProviderConfig.toApis()],
      globalDefault: ModelRef(providerId: 'toapis', modelId: 'new'),
    );

    await slot
        .replaceWith(
          _factory(
            newStore,
            shutdownTimeout: const Duration(milliseconds: 20),
            catalogs: {
              'toapis': [_model('toapis', 'new')],
            },
          ),
        )
        .timeout(const Duration(seconds: 1));

    expect(
      await slot.resolveConfiguredModel(),
      ModelRef(providerId: 'toapis', modelId: 'new'),
    );
    expect(oldStore.closeCount, 1);
    expect(newStore.closeCount, 0);
    await slot.close();
    expect(newStore.closeCount, 1);
  });
}

ProductionModelRuntimeFactory _factory(
  _MemoryConfigurationStore store, {
  Map<String, List<ModelDescriptor>> catalogs = const {},
  UnaryHttpAdapter? adapter,
  ProviderModelCatalogLoader? catalogLoader,
  ProviderInspectionTransport? inspectionTransport,
  SecureCredentialStore? credentialStore,
  Duration shutdownTimeout = const Duration(seconds: 2),
}) => ProductionModelRuntimeFactory(
  openConfigurationStore: () => store,
  credentialStore: credentialStore ?? _MemoryCredentialStore(),
  loadModelCatalog:
      catalogLoader ??
      (providerId, cancellationToken) async =>
          List.unmodifiable(catalogs[providerId] ?? const []),
  inspectionTransport: inspectionTransport ?? _NoNetworkInspectionTransport(),
  unaryHttpAdapter: adapter ?? _ProviderResponseAdapter(),
  endpointPolicy: const _AllowTestEndpointPolicy(),
  shutdownTimeout: shutdownTimeout,
);

ModelDescriptor _model(String providerId, String modelId) => ModelDescriptor(
  ref: ModelRef(providerId: providerId, modelId: modelId),
  displayName: modelId,
  capabilities: const ModelCapabilities.text(),
);

ChatRequest _request(String requestId, String providerId, String modelId) =>
    ChatRequest(
      requestId: requestId,
      model: ModelRef(providerId: providerId, modelId: modelId),
      messages: [ChatMessage(role: ChatRole.user, content: 'hello')],
    );

final class _MemoryConfigurationStore implements ProviderConfigurationStore {
  _MemoryConfigurationStore({
    required this.configs,
    this.globalDefault,
    this.agentOverrides = const {},
    this.loadGate,
    this.loadStarted,
    this.closeGate,
    this.closeError,
  });

  final List<ProviderConfig> configs;
  final ModelRef? globalDefault;
  final Map<String, ModelRef> agentOverrides;
  final Completer<void>? loadGate;
  final Completer<void>? loadStarted;
  final Completer<void>? closeGate;
  final Object? closeError;
  int closeCount = 0;

  @override
  Future<List<ProviderConfig>> loadEnabled() async {
    await loadGate?.future;
    return List.unmodifiable(configs.where((config) => config.enabled));
  }

  @override
  Future<ModelRef?> loadGlobalDefaultModel() async => globalDefault;

  @override
  Future<ModelRef?> loadAgentModelOverride(String agentId) async =>
      agentOverrides[agentId];

  @override
  Future<Map<String, ModelRef>> loadAgentModelOverrides() async =>
      Map.unmodifiable(agentOverrides);

  @override
  Future<void> close() async {
    closeCount++;
    await closeGate?.future;
    final error = closeError;
    if (error != null) throw error;
  }

  @override
  Future<List<ProviderConfig>> loadAll() async {
    if (loadStarted != null && !loadStarted!.isCompleted) {
      loadStarted!.complete();
    }
    await loadGate?.future;
    return List.unmodifiable(configs);
  }

  @override
  Future<VersionedProviderConfiguration?> loadProvider(String providerId) =>
      throw UnimplementedError();

  @override
  Future<ProviderConfigurationReplacementResult> replaceProviderConfiguration({
    required ProviderConfigurationRevision? expectedRevision,
    required ProviderConfigurationReplacement replacement,
  }) => throw UnimplementedError();

  @override
  Future<ProviderCredentialRotationResult> rotateCredential({
    required String providerId,
    required ProviderCredentialSlot slot,
    required ProviderConfigurationRevision expectedRevision,
    required SecretRef expectedOldRef,
    required SecretRef newRef,
    required ProviderConfigurationReplacement replacement,
  }) => throw UnimplementedError();

  @override
  Future<ProviderRemovalLease> removeProviderAtomically({
    required String providerId,
    required ProviderConfigurationRevision expectedRevision,
  }) => throw UnimplementedError();

  @override
  Future<void> restoreRemovedProvider(ProviderRemovalLease lease) =>
      throw UnimplementedError();

  @override
  Future<void> finalizeProviderRemoval(ProviderRemovalLease lease) =>
      throw UnimplementedError();

  @override
  Future<void> markProviderRemovalRuntimePublished(
    ProviderRemovalLease lease,
  ) => throw UnimplementedError();

  @override
  Future<void> rollbackProviderMutation(
    ProviderConfigurationMutationLease lease,
  ) => throw UnimplementedError();

  @override
  Future<void> finalizeProviderMutation(
    ProviderConfigurationMutationLease lease,
  ) => throw UnimplementedError();

  @override
  Future<void> markProviderMutationRuntimePublished(
    ProviderConfigurationMutationLease lease,
  ) => throw UnimplementedError();

  @override
  Future<List<PendingProviderOperationDescriptor>>
  listPendingProviderOperations() => throw UnimplementedError();

  @override
  Future<PendingProviderOperationRecovery> recoverPendingProviderOperation({
    required PendingProviderOperationId operationId,
    required String expectedProviderId,
    required PendingProviderOperationKind expectedKind,
  }) => throw UnimplementedError();

  @override
  Future<void> remove(String providerId) => throw UnimplementedError();

  @override
  Future<void> setAgentModelOverride(String agentId, ModelRef? model) =>
      throw UnimplementedError();

  @override
  Future<void> setGlobalDefaultModel(ModelRef? model) =>
      throw UnimplementedError();

  @override
  Future<void> upsert(ProviderConfig config) => throw UnimplementedError();
}

final class _MemoryCredentialStore implements SecureCredentialStore {
  @override
  Future<String?> get(
    SecretRef ref, {
    CancellationToken? cancellationToken,
  }) async => 'test-credential';

  @override
  Future<bool> delete(SecretRef ref, {CancellationToken? cancellationToken}) =>
      throw UnimplementedError();

  @override
  Future<List<SecureCredentialMetadata>> listMetadata({
    String? service,
    CancellationToken? cancellationToken,
  }) => throw UnimplementedError();

  @override
  Future<void> set(
    SecretRef ref,
    String secret, {
    CancellationToken? cancellationToken,
  }) => throw UnimplementedError();
}

final class _IgnoringCredentialStore implements SecureCredentialStore {
  final Completer<void> dispatched = Completer<void>();

  @override
  Future<String?> get(SecretRef ref, {CancellationToken? cancellationToken}) {
    if (!dispatched.isCompleted) dispatched.complete();
    return Completer<String?>().future;
  }

  @override
  Future<bool> delete(SecretRef ref, {CancellationToken? cancellationToken}) =>
      throw UnimplementedError();

  @override
  Future<List<SecureCredentialMetadata>> listMetadata({
    String? service,
    CancellationToken? cancellationToken,
  }) => throw UnimplementedError();

  @override
  Future<void> set(
    SecretRef ref,
    String secret, {
    CancellationToken? cancellationToken,
  }) => throw UnimplementedError();
}

final class _DelayedCredentialStore implements SecureCredentialStore {
  final Completer<void> dispatched = Completer<void>();
  final Completer<String?> _credential = Completer<String?>();

  @override
  Future<String?> get(SecretRef ref, {CancellationToken? cancellationToken}) {
    if (!dispatched.isCompleted) dispatched.complete();
    return _credential.future;
  }

  void complete() => _credential.complete('test-only-delayed-credential');

  @override
  Future<bool> delete(SecretRef ref, {CancellationToken? cancellationToken}) =>
      throw UnimplementedError();

  @override
  Future<List<SecureCredentialMetadata>> listMetadata({
    String? service,
    CancellationToken? cancellationToken,
  }) => throw UnimplementedError();

  @override
  Future<void> set(
    SecretRef ref,
    String secret, {
    CancellationToken? cancellationToken,
  }) => throw UnimplementedError();
}

final class _ProviderResponseAdapter implements UnaryHttpAdapter {
  final List<String> paths = [];

  @override
  Future<RawUnaryHttpResponse> send(UnaryHttpAdapterRequest request) async {
    paths.add(request.endpoint.path);
    final body = switch (request.endpoint.path) {
      '/v1/messages' =>
        '{"id":"anthropic-id","content":[{"type":"text","text":'
            '"native response"}],"stop_reason":"end_turn",'
            '"usage":{"input_tokens":1,"output_tokens":2}}',
      _ =>
        '{"id":"compatible-id","choices":[{"message":{"content":'
            '"compatible response"},"finish_reason":"stop"}],'
            '"usage":{"prompt_tokens":1,"completion_tokens":2}}',
    };
    return RawUnaryHttpResponse(
      statusCode: 200,
      headers: const {'content-type': 'application/json'},
      body: Stream.value(Uint8List.fromList(body.codeUnits)),
      remoteAddress: InternetAddress('8.8.8.8'),
    );
  }
}

final class _CancellationBlockingAdapter implements UnaryHttpAdapter {
  final Completer<void> dispatched = Completer<void>();
  bool cancelled = false;

  @override
  Future<RawUnaryHttpResponse> send(UnaryHttpAdapterRequest request) async {
    dispatched.complete();
    await request.cancellationToken.whenCancelled;
    cancelled = true;
    throw const UnaryTransportException(UnaryTransportErrorCode.cancelled);
  }
}

final class _ThrowingListenerCancellationAdapter implements UnaryHttpAdapter {
  final Completer<void> allDispatched = Completer<void>();
  var dispatchedCount = 0;
  var cancelledCount = 0;

  @override
  Future<RawUnaryHttpResponse> send(UnaryHttpAdapterRequest request) async {
    request.cancellationToken.addListener(
      () => throw StateError('throwing provider listener'),
    );
    dispatchedCount++;
    if (dispatchedCount == 2) allDispatched.complete();
    await request.cancellationToken.whenCancelled;
    cancelledCount++;
    throw const UnaryTransportException(UnaryTransportErrorCode.cancelled);
  }
}

final class _IgnoringCancellationInspectionTransport
    implements ProviderInspectionTransport {
  final Completer<void> dispatched = Completer<void>();

  @override
  Future<ProviderCatalogTransportResult> discoverModels(
    ProviderInspectionRequest request,
  ) {
    if (!dispatched.isCompleted) dispatched.complete();
    return Completer<ProviderCatalogTransportResult>().future;
  }

  @override
  Future<ProviderHealthTransportResult> probeHealth(
    ProviderInspectionRequest request,
  ) => Completer<ProviderHealthTransportResult>().future;
}

final class _DelayedSuccessInspectionTransport
    implements ProviderInspectionTransport {
  final Completer<void> catalogDispatched = Completer<void>();
  final Completer<void> healthDispatched = Completer<void>();
  final Completer<ProviderCatalogTransportResult> _catalog =
      Completer<ProviderCatalogTransportResult>();
  final Completer<ProviderHealthTransportResult> _health =
      Completer<ProviderHealthTransportResult>();

  @override
  Future<ProviderCatalogTransportResult> discoverModels(
    ProviderInspectionRequest request,
  ) {
    catalogDispatched.complete();
    return _catalog.future;
  }

  @override
  Future<ProviderHealthTransportResult> probeHealth(
    ProviderInspectionRequest request,
  ) {
    healthDispatched.complete();
    return _health.future;
  }

  void completeSuccess() {
    _catalog.complete(ProviderCatalogTransportResult(models: const []));
    _health.complete(const ProviderHealthTransportResult(statusCode: 200));
  }
}

final class _NoNetworkInspectionTransport
    implements ProviderInspectionTransport {
  @override
  Future<ProviderCatalogTransportResult> discoverModels(
    ProviderInspectionRequest request,
  ) => throw StateError('Network is disabled in this test');

  @override
  Future<ProviderHealthTransportResult> probeHealth(
    ProviderInspectionRequest request,
  ) => throw StateError('Network is disabled in this test');
}

final class _AllowTestEndpointPolicy implements EndpointPolicy {
  const _AllowTestEndpointPolicy();

  @override
  Future<void> validateBeforeConnect(Uri endpoint) async {}

  @override
  void validateAfterConnect(Uri endpoint, InternetAddress remoteAddress) {}
}

final class _SqliteFactoryFixture {
  _SqliteFactoryFixture._(this.directory, this.path);

  factory _SqliteFactoryFixture.create() {
    final directory = Directory.systemTemp.createTempSync(
      'halo-runtime-factory-',
    );
    return _SqliteFactoryFixture._(
      directory,
      '${directory.path}/provider_configuration.sqlite',
    );
  }

  final Directory directory;
  final String path;

  void delete() => directory.deleteSync(recursive: true);
}
