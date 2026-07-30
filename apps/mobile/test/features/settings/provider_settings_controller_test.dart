import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/model_runtime_errors.dart';
import 'package:halo_mobile/features/settings/model_routing_controller.dart';
import 'package:halo_mobile/features/settings/provider_settings_controller.dart';
import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/secure_credential_store.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';

void main() {
  late _FakeCredentials credentials;
  late _FakeCatalogFetcher catalogFetcher;
  late _FakePersistence persistence;
  late _FakeRuntimeReloader runtime;
  late _SequentialSecretRefs refs;
  late ProviderSettingsController controller;
  late List<String> events;

  setUp(() {
    events = [];
    credentials = _FakeCredentials(events);
    catalogFetcher = _FakeCatalogFetcher(events);
    persistence = _FakePersistence(events);
    runtime = _FakeRuntimeReloader(events);
    refs = _SequentialSecretRefs();
    controller = ProviderSettingsController(
      credentials: credentials,
      catalogFetcher: catalogFetcher,
      persistence: persistence,
      runtime: runtime,
      secretRefs: refs,
    );
  });

  test(
    'provider save waits for failed routing reload rollback to finish',
    () async {
      final coordinator = SerializedProviderMutationCoordinator();
      final oldModel = ModelRef(
        providerId: 'deepseek',
        modelId: 'deepseek-chat',
      );
      final nextModel = ModelRef(
        providerId: 'deepseek',
        modelId: 'deepseek-reasoner',
      );
      final restoreGate = Completer<void>();
      final routingPersistence = _RoutingPersistence(
        events: events,
        options: [
          AvailableModelOption(
            ref: oldModel,
            providerName: 'DeepSeek',
            modelName: 'DeepSeek Chat',
          ),
          AvailableModelOption(
            ref: nextModel,
            providerName: 'DeepSeek',
            modelName: 'DeepSeek Reasoner',
          ),
        ],
        globalDefault: oldModel,
        restoreGate: restoreGate.future,
      );
      final sharedRuntime = _RoutingAwareRuntime(routingPersistence);
      final routing = ModelRoutingController(
        persistence: routingPersistence,
        runtime: sharedRuntime,
        mutationCoordinator: coordinator,
      );
      final provider = ProviderSettingsController(
        credentials: credentials,
        catalogFetcher: catalogFetcher,
        persistence: persistence,
        runtime: sharedRuntime,
        secretRefs: refs,
        mutationCoordinator: coordinator,
      );
      await routing.load();

      final routingWrite = routing.setGlobalDefault(nextModel);
      await routingPersistence.restoreStarted.future;
      final providerSave = provider.save(
        const ProviderSettingsDraft(
          providerId: 'deepseek',
          apiKey: 'new-secret',
          enabled: true,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(events, isNot(contains('credential:set')));

      restoreGate.complete();
      await expectLater(routingWrite, throwsA(isA<ModelRoutingException>()));
      await providerSave;

      expect(routingPersistence.globalDefault, oldModel);
      expect(sharedRuntime.publishedModel, oldModel);
      expect(
        events.indexOf('routing:rollback:end'),
        lessThan(events.indexOf('credential:set')),
      );
    },
  );

  test(
    'save orders Keychain, discovery, staged publish, reload, finalize, cleanup',
    () async {
      final oldRef = refs.next();
      persistence.current = _snapshot('toapis', oldRef);

      await controller.save(
        const ProviderSettingsDraft(
          providerId: 'toapis',
          apiKey: 'new-secret',
          enabled: true,
        ),
      );

      expect(credentials.setValues.single, 'new-secret');
      expect(persistence.current!.config.secretRef, refs.issued.last);
      expect(persistence.current!.catalog!.models, hasLength(2));
      expect(runtime.reloadCount, 1);
      expect(controller.state, ProviderSettingsState.ready);
      expect(events, [
        'credential:set',
        'catalog:fetch',
        'persistence:replace',
        'runtime:reload',
        'persistence:markReplaceRuntimePublished',
        'persistence:finalizeReplace',
        'credential:delete:old',
      ]);
    },
  );

  test(
    'replacement rotates UUID and never reads old Key into Dart memory',
    () async {
      final oldRef = refs.next();
      persistence.current = _snapshot('toapis', oldRef);

      await controller.save(
        const ProviderSettingsDraft(
          providerId: 'toapis',
          apiKey: 'replacement',
          enabled: true,
        ),
      );

      expect(credentials.getCalls, 0);
      expect(
        catalogFetcher.configs.single.secretRef,
        credentials.setRefs.single,
      );
      expect(credentials.setRefs.single, isNot(oldRef));
      expect(credentials.deletedRefs, [oldRef]);
      expect(persistence.current!.config.secretRef, credentials.setRefs.single);
    },
  );

  test(
    'catalog fetch failure preserves old snapshot and Key and deletes new Key',
    () async {
      final oldRef = refs.next();
      final old = _snapshot('deepseek', oldRef);
      persistence.current = old;
      catalogFetcher.error = StateError('fetch failed');

      await expectLater(
        controller.save(
          const ProviderSettingsDraft(
            providerId: 'deepseek',
            apiKey: 'replacement',
            enabled: true,
          ),
        ),
        throwsA(isA<ProviderSettingsException>()),
      );

      expect(persistence.current, same(old));
      expect(credentials.deletedRefs, [credentials.setRefs.single]);
      expect(credentials.deletedRefs, isNot(contains(oldRef)));
      expect(persistence.calls, isEmpty);
      expect(controller.snapshotFor('deepseek'), same(old));
      expect(controller.state, ProviderSettingsState.saveFailed);
    },
  );

  test('empty catalog fails closed before persistence publish', () async {
    catalogFetcher.catalog = _catalog('toapis', const []);

    await expectLater(
      controller.save(
        const ProviderSettingsDraft(
          providerId: 'toapis',
          apiKey: 'replacement',
          enabled: true,
        ),
      ),
      throwsA(isA<ProviderSettingsException>()),
    );

    expect(persistence.calls, isEmpty);
    expect(credentials.deletedRefs, [credentials.setRefs.single]);
  });

  test(
    'configuration switch failure deletes new ref and preserves old state',
    () async {
      final oldRef = refs.next();
      final old = _snapshot('deepseek', oldRef);
      persistence
        ..current = old
        ..replaceError = StateError('switch failed');

      await expectLater(
        controller.save(
          const ProviderSettingsDraft(
            providerId: 'deepseek',
            apiKey: 'replacement',
            enabled: true,
          ),
        ),
        throwsA(isA<ProviderSettingsException>()),
      );

      expect(credentials.getCalls, 0);
      expect(credentials.deletedRefs, [credentials.setRefs.single]);
      expect(persistence.current, same(old));
      expect(controller.state, ProviderSettingsState.saveFailed);
    },
  );

  test(
    'runtime reload failure restores old config and deletes new ref',
    () async {
      final oldRef = refs.next();
      final old = _snapshot('toapis', oldRef);
      persistence.current = old;
      runtime.error = StateError('reload failed');

      await expectLater(
        controller.save(
          const ProviderSettingsDraft(
            providerId: 'toapis',
            apiKey: 'replacement',
            enabled: true,
          ),
        ),
        throwsA(isA<ProviderSettingsException>()),
      );

      expect(persistence.current, same(old));
      expect(credentials.deletedRefs, [credentials.setRefs.single]);
    },
  );

  test(
    'runtime reload and rollback failure preserves new ref for recovery',
    () async {
      final oldRef = refs.next();
      persistence.current = _snapshot('toapis', oldRef);
      runtime.error = StateError('reload failed');
      persistence.restoreError = StateError('rollback conflicted');

      await expectLater(
        controller.save(
          const ProviderSettingsDraft(
            providerId: 'toapis',
            apiKey: 'replacement',
            enabled: true,
          ),
        ),
        throwsA(isA<ProviderSettingsException>()),
      );

      expect(credentials.deletedRefs, isEmpty);
      expect(controller.state, ProviderSettingsState.recoveryPending);
    },
  );

  test('finalize failure keeps old Key and reports pending cleanup', () async {
    final oldRef = refs.next();
    persistence.current = _snapshot('toapis', oldRef);
    persistence.finalizeError = StateError('finalize failed');

    await controller.save(
      const ProviderSettingsDraft(
        providerId: 'toapis',
        apiKey: 'replacement',
        enabled: true,
      ),
    );

    expect(persistence.current!.config.secretRef, isNot(oldRef));
    expect(credentials.deletedRefs, isNot(contains(oldRef)));
    expect(controller.state, ProviderSettingsState.cleanupPending);
    expect(events, [
      'credential:set',
      'catalog:fetch',
      'persistence:replace',
      'runtime:reload',
      'persistence:markReplaceRuntimePublished',
      'persistence:finalizeReplace',
    ]);
  });

  test(
    'publication mark failure preserves both Keys for restart recovery',
    () async {
      final oldRef = refs.next();
      persistence.current = _snapshot('toapis', oldRef);
      persistence.markPublishedError = StateError('durable mark failed');

      await expectLater(
        controller.save(
          const ProviderSettingsDraft(
            providerId: 'toapis',
            apiKey: 'replacement',
            enabled: true,
          ),
        ),
        throwsA(isA<ProviderSettingsException>()),
      );

      expect(credentials.deletedRefs, isEmpty);
      expect(persistence.calls, isNot(contains('finalizeReplace')));
      expect(controller.state, ProviderSettingsState.recoveryPending);
    },
  );

  test(
    'late old-runtime retirement failure does not rollback or delete new Key',
    () async {
      final oldRef = refs.next();
      persistence.current = _snapshot('toapis', oldRef);
      runtime.onReload = () async {
        events.add('runtime:retirementCleanupFailed');
      };

      await controller.save(
        const ProviderSettingsDraft(
          providerId: 'toapis',
          apiKey: 'replacement',
          enabled: true,
        ),
      );

      final newRef = credentials.setRefs.single;
      expect(persistence.calls, [
        'replace',
        'markReplaceRuntimePublished',
        'finalizeReplace',
      ]);
      expect(credentials.deletedRefs, [oldRef]);
      expect(credentials.deletedRefs, isNot(contains(newRef)));
      expect(controller.state, ProviderSettingsState.ready);
    },
  );

  test(
    'old ref cleanup failure keeps new config and reports safe cleanup state',
    () async {
      final oldRef = refs.next();
      persistence.current = _snapshot('toapis', oldRef);
      credentials.deleteErrors[oldRef] = StateError('keychain unavailable');

      await controller.save(
        const ProviderSettingsDraft(
          providerId: 'toapis',
          apiKey: 'replacement',
          enabled: true,
        ),
      );

      expect(persistence.current!.config.secretRef, isNot(oldRef));
      expect(controller.state, ProviderSettingsState.cleanupPending);
    },
  );

  test(
    'old ref delete false follows finalize and reports cleanup pending',
    () async {
      final oldRef = refs.next();
      persistence.current = _snapshot('toapis', oldRef);
      credentials.deleteResults[oldRef] = false;

      await controller.save(
        const ProviderSettingsDraft(
          providerId: 'toapis',
          apiKey: 'replacement',
          enabled: true,
        ),
      );

      expect(controller.state, ProviderSettingsState.cleanupPending);
      expect(persistence.calls, contains('finalizeReplace'));
    },
  );

  test(
    'published delete keeps DB removed when Keychain cleanup fails',
    () async {
      final oldRef = refs.next();
      final old = _snapshot('deepseek', oldRef);
      persistence.current = old;
      credentials.deleteErrors[oldRef] = StateError('delete failed');

      await controller.remove('deepseek');

      expect(persistence.calls.take(2), [
        'remove',
        'markRemovalRuntimePublished',
      ]);
      expect(persistence.current, isNull);
      expect(controller.state, ProviderSettingsState.cleanupPending);
    },
  );

  test(
    'reload and restore double failure never reports delete success',
    () async {
      final oldRef = refs.next();
      persistence.current = _snapshot('toapis', oldRef);
      runtime.error = StateError('reload failed');
      persistence.restoreError = StateError('restore failed');

      await expectLater(
        controller.remove('toapis'),
        throwsA(isA<ProviderSettingsException>()),
      );

      expect(controller.state, ProviderSettingsState.orphanedCredential);
      expect(controller.hasConfiguration, isFalse);
    },
  );

  test('removal publication mark failure preserves old Key', () async {
    final oldRef = refs.next();
    persistence.current = _snapshot('toapis', oldRef);
    persistence.markPublishedError = StateError('durable mark failed');

    await expectLater(
      controller.remove('toapis'),
      throwsA(isA<ProviderSettingsException>()),
    );

    expect(credentials.deletedRefs, isEmpty);
    expect(persistence.calls, ['remove', 'markRemovalRuntimePublished']);
    expect(controller.state, ProviderSettingsState.recoveryPending);
  });

  test('close rejects new work and drains in-flight work', () async {
    persistence.loadGate = Completer<void>();
    final operation = controller.save(
      const ProviderSettingsDraft(
        providerId: 'toapis',
        apiKey: 'secret',
        enabled: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    var closed = false;
    final closing = controller.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    persistence.loadGate!.complete();
    await operation;
    await closing;

    expect(() => controller.remove('toapis'), throwsStateError);
    expect(
      () => ChangeNotifier.debugAssertNotDisposed(controller),
      throwsFlutterError,
    );
  });

  test(
    'loads are isolated by provider and late completion cannot contaminate',
    () async {
      final toApisGate = Completer<void>();
      persistence.loadGates['toapis'] = toApisGate;
      persistence.currents['deepseek'] = _snapshot('deepseek', refs.next());

      final lateToApis = controller.load('toapis');
      await controller.load('deepseek');

      expect(controller.hasConfigurationFor('deepseek'), isTrue);
      expect(controller.stateFor('deepseek'), ProviderSettingsState.ready);
      expect(controller.hasConfigurationFor('toapis'), isFalse);

      toApisGate.complete();
      await lateToApis;

      expect(controller.stateFor('toapis'), ProviderSettingsState.idle);
      expect(controller.stateFor('deepseek'), ProviderSettingsState.ready);
      expect(controller.hasConfigurationFor('deepseek'), isTrue);
    },
  );

  test('failed operation releases provider gate', () async {
    persistence.loadErrors['toapis'] = StateError('unavailable');

    await expectLater(controller.load('toapis'), throwsStateError);
    persistence.loadErrors.remove('toapis');

    await controller.load('toapis');
    expect(controller.stateFor('toapis'), ProviderSettingsState.idle);
  });

  test(
    'refresh reuses existing credential and atomically replaces full catalog',
    () async {
      final oldRef = refs.next();
      final old = _snapshot('deepseek', oldRef, modelIds: ['deepseek-chat']);
      persistence.current = old;
      await controller.load('deepseek');
      catalogFetcher.catalog = _catalog('deepseek', const [
        'deepseek-chat',
        'deepseek-reasoner',
      ]);
      events.clear();

      await controller.refreshCatalog('deepseek');

      expect(catalogFetcher.configs.single.secretRef, oldRef);
      expect(credentials.setRefs, isEmpty);
      expect(credentials.deletedRefs, isEmpty);
      expect(
        controller
            .snapshotFor('deepseek')!
            .catalog!
            .models
            .map((model) => model.ref.modelId),
        ['deepseek-chat', 'deepseek-reasoner'],
      );
      expect(events, [
        'catalog:fetch',
        'persistence:replace',
        'runtime:reload',
        'persistence:markReplaceRuntimePublished',
        'persistence:finalizeReplace',
      ]);
    },
  );

  test(
    'refresh publication mark failure leaves catalog recovery pending',
    () async {
      final oldRef = refs.next();
      final old = _snapshot('deepseek', oldRef, modelIds: ['deepseek-chat']);
      persistence.current = old;
      persistence.markPublishedError = StateError('durable mark failed');
      catalogFetcher.catalog = _catalog('deepseek', const [
        'deepseek-chat',
        'deepseek-reasoner',
      ]);

      await expectLater(
        controller.refreshCatalog('deepseek'),
        throwsA(isA<ProviderSettingsException>()),
      );

      expect(credentials.deletedRefs, isEmpty);
      expect(persistence.calls, ['replace', 'markReplaceRuntimePublished']);
      expect(controller.state, ProviderSettingsState.recoveryPending);
    },
  );

  test(
    'setEnabled flips only the enabled bit, keeping credential and catalog',
    () async {
      final oldRef = refs.next();
      persistence.current = _snapshot(
        'deepseek',
        oldRef,
        modelIds: ['deepseek-chat'],
      );
      await controller.load('deepseek');
      events.clear();

      await controller.setEnabled('deepseek', false);

      final snapshot = controller.snapshotFor('deepseek')!;
      expect(snapshot.config.enabled, isFalse);
      expect(snapshot.config.secretRef, oldRef);
      expect(snapshot.catalog!.models.map((model) => model.ref.modelId), [
        'deepseek-chat',
      ]);
      expect(credentials.setRefs, isEmpty);
      expect(credentials.deletedRefs, isEmpty);
      expect(events, [
        'persistence:replace',
        'runtime:reload',
        'persistence:markReplaceRuntimePublished',
        'persistence:finalizeReplace',
      ]);
      expect(controller.stateFor('deepseek'), ProviderSettingsState.ready);

      await controller.setEnabled('deepseek', true);
      expect(controller.snapshotFor('deepseek')!.config.enabled, isTrue);
      expect(controller.snapshotFor('deepseek')!.config.secretRef, oldRef);
    },
  );

  test('setEnabled to the current value is a no-op', () async {
    final oldRef = refs.next();
    persistence.current = _snapshot('deepseek', oldRef);
    await controller.load('deepseek');
    events.clear();

    await controller.setEnabled('deepseek', true);

    expect(events, isEmpty);
    expect(controller.stateFor('deepseek'), ProviderSettingsState.ready);
  });

  test('setEnabled rolls back when the runtime reload fails', () async {
    final oldRef = refs.next();
    persistence.current = _snapshot('deepseek', oldRef);
    await controller.load('deepseek');
    runtime.error = StateError('runtime unavailable');
    events.clear();

    await expectLater(
      controller.setEnabled('deepseek', false),
      throwsA(
        isA<ProviderSettingsException>().having(
          (error) => error.safeMessage,
          'safeMessage',
          '停用失败，原配置仍然有效',
        ),
      ),
    );

    expect(events, [
      'persistence:replace',
      'runtime:reload',
      'persistence:rollbackReplace',
    ]);
    expect(persistence.current!.config.enabled, isTrue);
    expect(controller.stateFor('deepseek'), ProviderSettingsState.saveFailed);
  });

  test('setEnabled without a saved configuration fails closed', () async {
    persistence.current = null;

    await expectLater(
      controller.setEnabled('deepseek', false),
      throwsA(
        isA<ProviderSettingsException>().having(
          (error) => error.safeMessage,
          'safeMessage',
          '请先配置模型服务',
        ),
      ),
    );
    expect(persistence.calls, isEmpty);
  });

  test('mutations run FIFO while loads remain provider isolated', () async {
    final toApisGate = Completer<void>();
    persistence.loadGates['toapis'] = toApisGate;
    final firstMutation = controller.save(
      const ProviderSettingsDraft(
        providerId: 'toapis',
        apiKey: 'toapis-key',
        enabled: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final secondMutation = controller.save(
      const ProviderSettingsDraft(
        providerId: 'deepseek',
        apiKey: 'deepseek-key',
        enabled: true,
      ),
    );
    await controller.load('deepseek');

    expect(controller.stateFor('deepseek'), ProviderSettingsState.idle);
    expect(credentials.setValues, isEmpty);
    toApisGate.complete();
    await Future.wait([firstMutation, secondMutation]);
    expect(credentials.setValues, ['toapis-key', 'deepseek-key']);
  });

  test('failed mutation does not poison the FIFO queue', () async {
    runtime.error = StateError('first reload failed');

    final first = controller.save(
      const ProviderSettingsDraft(
        providerId: 'toapis',
        apiKey: 'first-key',
        enabled: true,
      ),
    );
    final second = controller.save(
      const ProviderSettingsDraft(
        providerId: 'deepseek',
        apiKey: 'second-key',
        enabled: true,
      ),
    );

    await expectLater(first, throwsA(isA<ProviderSettingsException>()));
    await second;

    expect(controller.stateFor('deepseek'), ProviderSettingsState.ready);
    expect(credentials.setValues, ['first-key', 'second-key']);
  });

  group('auto default model', () {
    late _FakeBindingDefaults bindingDefaults;
    late ProviderSettingsController boundController;

    setUp(() {
      bindingDefaults = _FakeBindingDefaults(events);
      boundController = ProviderSettingsController(
        credentials: credentials,
        catalogFetcher: catalogFetcher,
        persistence: persistence,
        runtime: runtime,
        secretRefs: refs,
        bindingDefaults: bindingDefaults,
      );
    });

    test(
      'first save without a global default binds the first catalog model',
      () async {
        await boundController.save(
          const ProviderSettingsDraft(
            providerId: 'toapis',
            apiKey: 'first-key',
            enabled: true,
          ),
        );

        expect(
          bindingDefaults.globalDefault,
          ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini'),
        );
        expect(runtime.reloadCount, 2);
        expect(boundController.state, ProviderSettingsState.ready);
        expect(events, [
          'credential:set',
          'catalog:fetch',
          'persistence:replace',
          'runtime:reload',
          'persistence:markReplaceRuntimePublished',
          'persistence:finalizeReplace',
          'bindingDefaults:load',
          'bindingDefaults:set:gpt-5-mini',
          'runtime:reload',
        ]);
      },
    );

    test('save never overwrites an existing global default', () async {
      final existing = ModelRef(
        providerId: 'deepseek',
        modelId: 'deepseek-chat',
      );
      bindingDefaults.globalDefault = existing;

      await boundController.save(
        const ProviderSettingsDraft(
          providerId: 'toapis',
          apiKey: 'second-provider-key',
          enabled: true,
        ),
      );

      expect(bindingDefaults.globalDefault, existing);
      expect(bindingDefaults.setCalls, isEmpty);
      expect(runtime.reloadCount, 1);
      expect(boundController.state, ProviderSettingsState.ready);
    });

    test(
      'auto-default reload failure rolls the default back and keeps the save',
      () async {
        runtime.onReload = () async {
          if (runtime.reloadCount == 2) {
            runtime.error = StateError('binding reload failed');
          }
        };

        await boundController.save(
          const ProviderSettingsDraft(
            providerId: 'toapis',
            apiKey: 'first-key',
            enabled: true,
          ),
        );

        expect(bindingDefaults.globalDefault, isNull);
        expect(bindingDefaults.setCalls, [
          ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini'),
          null,
        ]);
        expect(events, contains('bindingDefaults:set:null'));
        expect(boundController.state, ProviderSettingsState.ready);
        expect(persistence.current!.config.providerId, 'toapis');
      },
    );

    test('catalog refresh never touches the global default', () async {
      persistence.current = _snapshot(
        'deepseek',
        refs.next(),
        modelIds: ['deepseek-chat'],
      );
      catalogFetcher.catalog = _catalog('deepseek', const [
        'deepseek-reasoner',
        'deepseek-chat',
      ]);

      await boundController.refreshCatalog('deepseek');

      expect(bindingDefaults.globalDefault, isNull);
      expect(bindingDefaults.setCalls, isEmpty);
      expect(events, isNot(contains('bindingDefaults:load')));
      expect(boundController.state, ProviderSettingsState.ready);
    });
  });

  test(
    'connection test reports reachable, auth, quota and unreachable',
    () async {
      persistence.current = _snapshot(
        'deepseek',
        SecretRef.parse(
          'keychain://halo.provider/00000000-0000-4000-8000-000000000abc',
        ),
      );

      await controller.testConnection('deepseek');
      expect(
        controller.connectionResultFor('deepseek'),
        ProviderConnectionResult.reachable,
      );

      catalogFetcher.error = const ModelRuntimeException(
        code: ModelRuntimeErrorCode.invalidCredential,
        safeMessage: 'x',
        retryable: false,
      );
      await controller.testConnection('deepseek');
      expect(
        controller.connectionResultFor('deepseek'),
        ProviderConnectionResult.authFailed,
      );

      catalogFetcher.error = const ModelRuntimeException(
        code: ModelRuntimeErrorCode.rateLimited,
        safeMessage: 'x',
        retryable: true,
      );
      await controller.testConnection('deepseek');
      expect(
        controller.connectionResultFor('deepseek'),
        ProviderConnectionResult.quotaExceeded,
      );

      catalogFetcher.error = StateError('network down');
      await controller.testConnection('deepseek');
      expect(
        controller.connectionResultFor('deepseek'),
        ProviderConnectionResult.unreachable,
      );
    },
  );

  test('connection test on an unconfigured provider says so', () async {
    persistence.current = null;
    await controller.testConnection('deepseek');
    expect(
      controller.connectionResultFor('deepseek'),
      ProviderConnectionResult.notConfigured,
    );
    // Nothing was written; a read-only probe never persists.
    expect(events, isNot(contains('persistence:replace')));
  });

  test(
    'mutation dependency awaiting remove fails fast instead of deadlocking',
    () async {
      Object? reentrantError;
      runtime.onReload = () async {
        try {
          await controller.remove('deepseek');
        } catch (error) {
          reentrantError = error;
        }
      };

      await controller
          .save(
            const ProviderSettingsDraft(
              providerId: 'toapis',
              apiKey: 'toapis-key',
              enabled: true,
            ),
          )
          .timeout(const Duration(seconds: 1));

      expect(
        reentrantError,
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Reentrant provider settings mutation calls are not allowed',
        ),
      );
      expect(controller.stateFor('toapis'), ProviderSettingsState.ready);
    },
  );

  test(
    'mutation dependency awaiting close fails fast instead of deadlocking',
    () async {
      Object? reentrantError;
      runtime.onReload = () async {
        try {
          await controller.close();
        } catch (error) {
          reentrantError = error;
        }
      };

      await controller
          .save(
            const ProviderSettingsDraft(
              providerId: 'toapis',
              apiKey: 'toapis-key',
              enabled: true,
            ),
          )
          .timeout(const Duration(seconds: 1));

      expect(
        reentrantError,
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Reentrant provider settings mutation calls are not allowed',
        ),
      );
      await controller.close();
    },
  );

  test(
    'completed mutation context cannot reject later unrelated work',
    () async {
      Zone? completedMutationZone;
      runtime.onReload = () async {
        completedMutationZone = Zone.current;
      };
      await controller.save(
        const ProviderSettingsDraft(
          providerId: 'toapis',
          apiKey: 'toapis-key',
          enabled: true,
        ),
      );

      await completedMutationZone!
          .run(() => controller.remove('deepseek'))
          .timeout(const Duration(seconds: 1));

      expect(controller.stateFor('deepseek'), ProviderSettingsState.idle);
    },
  );

  test(
    'close drains accepted FIFO mutations and rejects new enqueue',
    () async {
      final gate = Completer<void>();
      persistence.loadGates['toapis'] = gate;
      final first = controller.save(
        const ProviderSettingsDraft(
          providerId: 'toapis',
          apiKey: 'first-key',
          enabled: true,
        ),
      );
      final second = controller.remove('deepseek');
      final closing = controller.close();

      expect(() => controller.remove('toapis'), throwsStateError);
      var closed = false;
      closing.then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);

      gate.complete();
      await Future.wait([first, second, closing]);
      expect(controller.stateFor('toapis'), ProviderSettingsState.ready);
    },
  );
}

final class _FakeCredentials implements SecureCredentialStore {
  _FakeCredentials(this.events);

  final List<String> events;
  int getCalls = 0;
  final setRefs = <SecretRef>[];
  final setValues = <String>[];
  final deletedRefs = <SecretRef>[];
  final deleteErrors = <SecretRef, Object>{};
  final deleteResults = <SecretRef, bool>{};

  @override
  Future<void> set(
    SecretRef ref,
    String secret, {
    CancellationToken? cancellationToken,
  }) async {
    events.add('credential:set');
    setRefs.add(ref);
    setValues.add(secret);
  }

  @override
  Future<String?> get(
    SecretRef ref, {
    CancellationToken? cancellationToken,
  }) async {
    getCalls++;
    return 'must-not-be-read';
  }

  @override
  Future<bool> delete(
    SecretRef ref, {
    CancellationToken? cancellationToken,
  }) async {
    events.add(
      setRefs.contains(ref) ? 'credential:delete:new' : 'credential:delete:old',
    );
    deletedRefs.add(ref);
    final error = deleteErrors[ref];
    if (error != null) throw error;
    return deleteResults[ref] ?? true;
  }

  @override
  Future<List<SecureCredentialMetadata>> listMetadata({
    String? service,
    CancellationToken? cancellationToken,
  }) async => const [];
}

final class _FakeBindingDefaults implements ModelBindingDefaults {
  _FakeBindingDefaults(this.events);

  final List<String> events;
  ModelRef? globalDefault;
  Object? loadError;
  final setCalls = <ModelRef?>[];

  @override
  Future<ModelRef?> loadGlobalDefault() async {
    events.add('bindingDefaults:load');
    final error = loadError;
    if (error != null) throw error;
    return globalDefault;
  }

  @override
  Future<void> setGlobalDefault(ModelRef? model) async {
    events.add('bindingDefaults:set:${model?.modelId ?? 'null'}');
    setCalls.add(model);
    globalDefault = model;
  }
}

final class _FakeCatalogFetcher implements ProviderModelCatalogFetcher {
  _FakeCatalogFetcher(this.events);

  final List<String> events;
  final configs = <ProviderConfig>[];
  PersistedProviderModelCatalog? catalog;
  Object? error;

  @override
  Future<PersistedProviderModelCatalog> fetch(ProviderConfig config) async {
    events.add('catalog:fetch');
    configs.add(config);
    final currentError = error;
    if (currentError != null) throw currentError;
    return catalog ?? _catalog(config.providerId);
  }
}

final class _FakePersistence implements ProviderSettingsPersistence {
  _FakePersistence(this.events);

  final List<String> events;
  ProviderSettingsSnapshot? current;
  final currents = <String, ProviderSettingsSnapshot?>{};
  Object? replaceError;
  Object? restoreError;
  Object? finalizeError;
  Object? markPublishedError;
  Completer<void>? loadGate;
  final loadGates = <String, Completer<void>>{};
  final loadErrors = <String, Object>{};
  final calls = <String>[];

  @override
  Future<ProviderSettingsSnapshot?> load(String providerId) async {
    await (loadGates[providerId]?.future ?? loadGate?.future);
    final error = loadErrors[providerId];
    if (error != null) throw error;
    return currents.containsKey(providerId) ? currents[providerId] : current;
  }

  @override
  Future<void> replace(
    ProviderSettingsSnapshot? previous,
    ProviderSettingsSnapshot next,
  ) async {
    events.add('persistence:replace');
    calls.add('replace');
    final error = replaceError;
    if (error != null) throw error;
    current = next;
  }

  @override
  Future<void> rollbackReplace(
    ProviderSettingsSnapshot? previous,
    ProviderSettingsSnapshot next,
  ) async {
    events.add('persistence:rollbackReplace');
    calls.add('rollbackReplace');
    final error = restoreError;
    if (error != null) throw error;
    current = previous;
  }

  @override
  Future<void> finalizeReplace(
    ProviderSettingsSnapshot? previous,
    ProviderSettingsSnapshot next,
  ) async {
    events.add('persistence:finalizeReplace');
    calls.add('finalizeReplace');
    final error = finalizeError;
    if (error != null) throw error;
  }

  @override
  Future<void> markReplaceRuntimePublished(
    ProviderSettingsSnapshot? previous,
    ProviderSettingsSnapshot next,
  ) async {
    events.add('persistence:markReplaceRuntimePublished');
    calls.add('markReplaceRuntimePublished');
    final error = markPublishedError;
    if (error != null) throw error;
  }

  @override
  Future<void> remove(ProviderSettingsSnapshot snapshot) async {
    calls.add('remove');
    current = null;
  }

  @override
  Future<void> restore(ProviderSettingsSnapshot snapshot) async {
    calls.add('restore');
    final error = restoreError;
    if (error != null) throw error;
    current = snapshot;
  }

  @override
  Future<void> markRemovalRuntimePublished(
    ProviderSettingsSnapshot snapshot,
  ) async {
    calls.add('markRemovalRuntimePublished');
    final error = markPublishedError;
    if (error != null) throw error;
  }

  @override
  Future<void> finalizeRemoval(ProviderSettingsSnapshot snapshot) async {
    calls.add('finalize');
  }
}

final class _FakeRuntimeReloader implements ProviderRuntimeReloader {
  _FakeRuntimeReloader(this.events);

  final List<String> events;
  int reloadCount = 0;
  Object? error;
  Future<void> Function()? onReload;

  @override
  Future<void> reload() async {
    events.add('runtime:reload');
    reloadCount++;
    await onReload?.call();
    final current = error;
    error = null;
    if (current != null) throw current;
  }
}

final class _RoutingPersistence
    implements ModelRoutingPersistence, ModelRoutingRollbackPersistence {
  _RoutingPersistence({
    required this.events,
    required this.options,
    required this.globalDefault,
    required this.restoreGate,
  });

  final List<String> events;
  final List<AvailableModelOption> options;
  ModelRef? globalDefault;
  final Future<void> restoreGate;
  final Completer<void> restoreStarted = Completer<void>();

  @override
  Future<List<AvailableModelOption>> loadAvailableModels() async => options;

  @override
  Future<ModelRef?> loadGlobalDefault() async => globalDefault;

  @override
  Future<void> setGlobalDefault(ModelRef model) async {
    globalDefault = model;
  }

  @override
  Future<void> restoreGlobalDefault(ModelRef? model) async {
    events.add('routing:rollback:start');
    restoreStarted.complete();
    await restoreGate;
    globalDefault = model;
    events.add('routing:rollback:end');
  }

  @override
  Future<ModelRef?> loadExpertOverride(String expertId) async => null;

  @override
  Future<void> setExpertOverride(String expertId, ModelRef? model) async {}
}

final class _RoutingAwareRuntime implements ProviderRuntimeReloader {
  _RoutingAwareRuntime(this.persistence);

  final _RoutingPersistence persistence;
  var reloadCount = 0;
  ModelRef? publishedModel;

  @override
  Future<void> reload() async {
    reloadCount++;
    if (reloadCount == 1) throw StateError('routing reload failed');
    publishedModel = persistence.globalDefault;
  }
}

ProviderSettingsSnapshot _snapshot(
  String providerId,
  SecretRef ref, {
  List<String>? modelIds,
}) => ProviderSettingsSnapshot(
  config: switch (providerId) {
    'toapis' => ProviderConfig.toApis(secretRef: ref),
    'deepseek' => ProviderConfig.deepSeek(secretRef: ref),
    _ => throw ArgumentError.value(providerId),
  },
  catalog: _catalog(providerId, modelIds),
);

PersistedProviderModelCatalog _catalog(
  String providerId, [
  List<String>? modelIds,
]) => PersistedProviderModelCatalog(
  providerId: providerId,
  models: [
    for (final modelId
        in modelIds ??
            (providerId == 'deepseek'
                ? const ['deepseek-chat', 'deepseek-reasoner']
                : const ['gpt-5-mini', 'gpt-5']))
      ModelDescriptor(
        ref: ModelRef(providerId: providerId, modelId: modelId),
        displayName: modelId,
        capabilities: const ModelCapabilities.text(),
      ),
  ],
  discoveredAt: DateTime.utc(2026, 7, 29, 12),
);

final class _SequentialSecretRefs implements ProviderSecretRefFactory {
  int _next = 0;
  final issued = <SecretRef>[];

  @override
  SecretRef next() {
    final suffix = (++_next).toString().padLeft(12, '0');
    final ref = SecretRef.parse(
      'keychain://halo.provider/00000000-0000-4000-8000-$suffix',
    );
    issued.add(ref);
    return ref;
  }
}
