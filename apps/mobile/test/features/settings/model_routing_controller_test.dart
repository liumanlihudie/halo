import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/settings/model_routing_controller.dart';
import 'package:halo_mobile/features/settings/provider_settings_controller.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/sqlite_provider_configuration_store.dart';

void main() {
  final deepSeekChat = ModelRef(
    providerId: 'deepseek',
    modelId: 'deepseek-chat',
  );
  final deepSeekReasoner = ModelRef(
    providerId: 'deepseek',
    modelId: 'deepseek-reasoner',
  );
  final toApisSelected = ModelRef(
    providerId: 'toapis',
    modelId: 'selected-model-id',
  );
  final options = [
    AvailableModelOption(
      ref: deepSeekChat,
      providerName: 'DeepSeek',
      modelName: 'DeepSeek Chat',
    ),
    AvailableModelOption(
      ref: deepSeekReasoner,
      providerName: 'DeepSeek',
      modelName: 'DeepSeek Reasoner',
    ),
    AvailableModelOption(
      ref: toApisSelected,
      providerName: 'ToAPIs',
      modelName: 'Selected Model',
    ),
  ];

  test(
    'SQLite adapter expands every model from every enabled persisted catalog',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'halo-model-routing-',
      );
      final store = SqliteProviderConfigurationStore.open(
        '${directory.path}/providers.sqlite',
      );
      try {
        Future<void> persist(
          ProviderConfig config,
          List<ModelDescriptor> models,
        ) async {
          final mutation = await store.replaceProviderConfiguration(
            expectedRevision: null,
            replacement: ProviderConfigurationReplacement(
              config: config,
              modelCatalog: PersistedProviderModelCatalog(
                providerId: config.providerId,
                models: models,
                discoveredAt: DateTime.utc(2026, 7, 29, 12),
              ),
            ),
          );
          await store.markProviderMutationRuntimePublished(mutation);
          await store.finalizeProviderMutation(mutation);
        }

        await persist(ProviderConfig.deepSeek(), [
          ModelDescriptor(
            ref: deepSeekChat,
            displayName: 'DeepSeek Chat',
            capabilities: const ModelCapabilities.text(),
          ),
          ModelDescriptor(
            ref: deepSeekReasoner,
            displayName: 'DeepSeek Reasoner',
            capabilities: const ModelCapabilities.text(),
          ),
        ]);
        await persist(ProviderConfig.toApis(), [
          ModelDescriptor(
            ref: toApisSelected,
            displayName: 'Selected Model',
            capabilities: const ModelCapabilities.text(),
          ),
        ]);

        final persisted = await SqliteModelRoutingPersistence(
          store,
        ).loadAvailableModels();

        expect(persisted.map((option) => option.ref).toSet(), {
          deepSeekChat,
          deepSeekReasoner,
          toApisSelected,
        });
        expect(
          persisted
              .where((option) => option.ref == deepSeekReasoner)
              .single
              .providerName,
          'DeepSeek',
        );
        expect(
          persisted
              .where((option) => option.ref == toApisSelected)
              .single
              .modelName,
          'Selected Model',
        );
      } finally {
        await store.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'global selection persists one concrete catalog model and reloads',
    () async {
      final persistence = _Persistence(
        availableModels: options,
        globalDefault: deepSeekChat,
      );
      final runtime = _Reloader();
      final controller = ModelRoutingController(
        persistence: persistence,
        runtime: runtime,
      );

      await controller.load();
      await controller.setGlobalDefault(deepSeekReasoner);

      expect(controller.availableModels, options);
      expect(
        () => controller.availableModels.add(options.first),
        throwsUnsupportedError,
      );
      expect(controller.globalDefault, deepSeekReasoner);
      expect(persistence.globalWrites, [deepSeekReasoner]);
      expect(runtime.reloadCount, 1);
    },
  );

  test(
    'unknown and newly removed models are rejected before a write',
    () async {
      final persistence = _Persistence(
        availableModels: options,
        globalDefault: deepSeekChat,
      );
      final runtime = _Reloader();
      final controller = ModelRoutingController(
        persistence: persistence,
        runtime: runtime,
      );
      await controller.load();

      await expectLater(
        controller.setGlobalDefault(
          ModelRef(providerId: 'deepseek', modelId: 'not-persisted'),
        ),
        throwsA(isA<ModelRoutingException>()),
      );
      persistence.availableModels = [options.first, options.last];
      await expectLater(
        controller.setGlobalDefault(deepSeekReasoner),
        throwsA(isA<ModelRoutingException>()),
      );
      await expectLater(
        controller.setExpertOverride('product-manager', deepSeekReasoner),
        throwsA(isA<ModelRoutingException>()),
      );

      expect(persistence.globalWrites, isEmpty);
      expect(persistence.expertWrites, isEmpty);
      expect(runtime.reloadCount, 0);
    },
  );

  test(
    'expert inherits the current global model until an explicit override wins',
    () async {
      final persistence = _Persistence(
        availableModels: options,
        globalDefault: deepSeekChat,
      );
      final controller = ModelRoutingController(
        persistence: persistence,
        runtime: _Reloader(),
      );

      await controller.load();
      await controller.loadExpertOverride('product-manager');
      expect(controller.expertOverrideFor('product-manager'), isNull);
      expect(controller.effectiveModelFor('product-manager'), deepSeekChat);

      await controller.setExpertOverride('product-manager', toApisSelected);
      expect(controller.expertOverrideFor('product-manager'), toApisSelected);
      expect(controller.effectiveModelFor('product-manager'), toApisSelected);

      await controller.setGlobalDefault(deepSeekReasoner);
      expect(controller.effectiveModelFor('product-manager'), toApisSelected);

      await controller.setExpertOverride('product-manager', null);
      expect(controller.expertOverrideFor('product-manager'), isNull);
      expect(controller.effectiveModelFor('product-manager'), deepSeekReasoner);
      expect(persistence.expertWrites, [
        ('product-manager', toApisSelected),
        ('product-manager', null),
      ]);
    },
  );

  test('failed global reload restores the prior concrete binding', () async {
    final persistence = _Persistence(
      availableModels: options,
      globalDefault: deepSeekChat,
    );
    final runtime = _Reloader()..failuresRemaining = 1;
    final controller = ModelRoutingController(
      persistence: persistence,
      runtime: runtime,
    );
    await controller.load();

    await expectLater(
      controller.setGlobalDefault(toApisSelected),
      throwsA(isA<ModelRoutingException>()),
    );

    expect(persistence.globalDefault, deepSeekChat);
    expect(persistence.globalWrites, [toApisSelected, deepSeekChat]);
    expect(controller.globalDefault, deepSeekChat);
  });

  test('failed first global reload restores an absent prior binding', () async {
    final persistence = _Persistence(
      availableModels: options,
      globalDefault: null,
    );
    final runtime = _Reloader()..failuresRemaining = 1;
    final controller = ModelRoutingController(
      persistence: persistence,
      runtime: runtime,
    );
    await controller.load();

    await expectLater(
      controller.setGlobalDefault(deepSeekChat),
      throwsA(isA<ModelRoutingException>()),
    );

    expect(persistence.globalDefault, isNull);
    expect(persistence.globalRestores, [null]);
    expect(controller.globalDefault, isNull);
  });

  test('failed expert reload restores the prior override', () async {
    final persistence = _Persistence(
      availableModels: options,
      globalDefault: deepSeekChat,
      expertOverrides: {'product-manager': deepSeekReasoner},
    );
    final runtime = _Reloader()..failuresRemaining = 1;
    final controller = ModelRoutingController(
      persistence: persistence,
      runtime: runtime,
    );
    await controller.load();
    await controller.loadExpertOverride('product-manager');

    await expectLater(
      controller.setExpertOverride('product-manager', toApisSelected),
      throwsA(isA<ModelRoutingException>()),
    );

    expect(persistence.expertOverrides['product-manager'], deepSeekReasoner);
    expect(persistence.expertWrites, [
      ('product-manager', toApisSelected),
      ('product-manager', deepSeekReasoner),
    ]);
    expect(controller.expertOverrideFor('product-manager'), deepSeekReasoner);
  });

  test('global and expert writes share one FIFO', () async {
    final persistence = _Persistence(
      availableModels: options,
      globalDefault: deepSeekChat,
    );
    final firstReload = Completer<void>();
    final runtime = _Reloader()..nextReload = firstReload.future;
    final controller = ModelRoutingController(
      persistence: persistence,
      runtime: runtime,
    );
    await controller.load();

    final globalWrite = controller.setGlobalDefault(deepSeekReasoner);
    await persistence.waitForGlobalWrites(1);
    final expertWrite = controller.setExpertOverride(
      'product-manager',
      toApisSelected,
    );
    await Future<void>.delayed(Duration.zero);

    expect(persistence.expertWrites, isEmpty);
    firstReload.complete();
    await Future.wait([globalWrite, expertWrite]);
    expect(persistence.events, [
      'global:deepseek/deepseek-reasoner',
      'expert:product-manager:toapis/selected-model-id',
    ]);
  });

  test(
    'shared runtime reloader serializes callers across controllers',
    () async {
      final firstReload = Completer<void>();
      final delegate = _Reloader()..nextReload = firstReload.future;
      final reloader = SerializedProviderRuntimeReloader(delegate);

      final first = reloader.reload();
      await Future<void>.delayed(Duration.zero);
      final second = reloader.reload();
      await Future<void>.delayed(Duration.zero);
      expect(delegate.reloadCount, 1);

      firstReload.complete();
      await Future.wait([first, second]);
      expect(delegate.reloadCount, 2);
    },
  );

  test('close drains accepted mutations before rejecting new writes', () async {
    final persistence = _Persistence(
      availableModels: options,
      globalDefault: deepSeekChat,
    );
    final blockedReload = Completer<void>();
    final runtime = _Reloader()..nextReload = blockedReload.future;
    final controller = ModelRoutingController(
      persistence: persistence,
      runtime: runtime,
    );
    await controller.load();

    final write = controller.setGlobalDefault(deepSeekReasoner);
    await persistence.waitForGlobalWrites(1);
    var closed = false;
    final close = controller.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);

    blockedReload.complete();
    await Future.wait([write, close]);
    expect(closed, isTrue);
    expect(() => controller.setGlobalDefault(toApisSelected), throwsStateError);
  });

  test(
    'failed rollback never claims the previous binding is still live',
    () async {
      final persistence = _Persistence(
        availableModels: options,
        globalDefault: deepSeekChat,
      )..failGlobalRestore = true;
      final controller = ModelRoutingController(
        persistence: persistence,
        runtime: _Reloader()..failuresRemaining = 1,
      );
      await controller.load();

      await expectLater(
        controller.setGlobalDefault(deepSeekReasoner),
        throwsA(
          isA<ModelRoutingException>().having(
            (error) => error.safeMessage,
            'safeMessage',
            '模型配置未能恢复，请重启应用后重试',
          ),
        ),
      );

      expect(controller.recoveryPending, isTrue);
      // Persistence stayed ahead of the runtime, so the failure must not be
      // reported as "原配置仍然有效".
      expect(persistence.globalDefault, deepSeekReasoner);
      await controller.close();
    },
  );

  test('a successful mutation clears the pending recovery flag', () async {
    final persistence = _Persistence(
      availableModels: options,
      globalDefault: deepSeekChat,
    )..failGlobalRestore = true;
    final runtime = _Reloader()..failuresRemaining = 1;
    final controller = ModelRoutingController(
      persistence: persistence,
      runtime: runtime,
    );
    await controller.load();
    await expectLater(
      controller.setGlobalDefault(deepSeekReasoner),
      throwsA(isA<ModelRoutingException>()),
    );
    expect(controller.recoveryPending, isTrue);

    await controller.setGlobalDefault(toApisSelected);

    expect(controller.recoveryPending, isFalse);
    expect(controller.globalDefault, toApisSelected);
    await controller.close();
  });

  test('close waits for an in-flight read before disposing', () async {
    final persistence = _Persistence(
      availableModels: options,
      globalDefault: deepSeekChat,
    );
    final gate = Completer<void>();
    persistence.availableModelsGate = gate;
    final controller = ModelRoutingController(
      persistence: persistence,
      runtime: _Reloader(),
    );

    final load = controller.load();
    await Future<void>.delayed(Duration.zero);
    var closed = false;
    final close = controller.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);

    gate.complete();
    await Future.wait([load, close]);
    expect(closed, isTrue);
  });

  test(
    'a read overlapping a mutation cannot publish a stale binding',
    () async {
      final persistence = _Persistence(
        availableModels: options,
        globalDefault: deepSeekChat,
      );
      final controller = ModelRoutingController(
        persistence: persistence,
        runtime: _Reloader(),
      );
      await controller.load();

      final gate = Completer<void>();
      persistence.availableModelsGate = gate;
      final staleRead = controller.load();
      await Future<void>.delayed(Duration.zero);

      await controller.setGlobalDefault(deepSeekReasoner);
      gate.complete();
      await staleRead;

      expect(controller.globalDefault, deepSeekReasoner);
      await controller.close();
    },
  );
}

final class _Persistence
    implements ModelRoutingPersistence, ModelRoutingRollbackPersistence {
  _Persistence({
    required List<AvailableModelOption> availableModels,
    required this.globalDefault,
    Map<String, ModelRef> expertOverrides = const {},
  }) : availableModels = List.of(availableModels),
       expertOverrides = Map.of(expertOverrides);

  List<AvailableModelOption> availableModels;
  ModelRef? globalDefault;
  final Map<String, ModelRef> expertOverrides;
  final List<ModelRef> globalWrites = [];
  final List<ModelRef?> globalRestores = [];
  final List<(String, ModelRef?)> expertWrites = [];
  final List<String> events = [];
  bool failGlobalRestore = false;

  /// Held by the next [loadAvailableModels] call, then cleared.
  Completer<void>? availableModelsGate;
  Completer<void>? _globalWriteWaiter;

  @override
  Future<List<AvailableModelOption>> loadAvailableModels() async {
    final gate = availableModelsGate;
    if (gate != null) {
      availableModelsGate = null;
      await gate.future;
    }
    return List.of(availableModels);
  }

  @override
  Future<ModelRef?> loadGlobalDefault() async => globalDefault;

  @override
  Future<void> setGlobalDefault(ModelRef model) async {
    globalDefault = model;
    globalWrites.add(model);
    events.add('global:$model');
    _globalWriteWaiter?.complete();
    _globalWriteWaiter = null;
  }

  @override
  Future<void> restoreGlobalDefault(ModelRef? model) async {
    if (failGlobalRestore) throw StateError('restore failed');
    globalDefault = model;
    globalRestores.add(model);
    if (model != null) globalWrites.add(model);
  }

  @override
  Future<ModelRef?> loadExpertOverride(String expertId) async =>
      expertOverrides[expertId];

  @override
  Future<void> setExpertOverride(String expertId, ModelRef? model) async {
    if (model == null) {
      expertOverrides.remove(expertId);
    } else {
      expertOverrides[expertId] = model;
    }
    expertWrites.add((expertId, model));
    events.add('expert:$expertId:${model ?? 'default'}');
  }

  Future<void> waitForGlobalWrites(int count) async {
    if (globalWrites.length >= count) return;
    _globalWriteWaiter = Completer<void>();
    await _globalWriteWaiter!.future;
  }
}

final class _Reloader implements ProviderRuntimeReloader {
  int failuresRemaining = 0;
  int reloadCount = 0;
  Future<void>? nextReload;

  @override
  Future<void> reload() async {
    reloadCount++;
    final pending = nextReload;
    nextReload = null;
    if (pending != null) await pending;
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw StateError('reload failed');
    }
  }
}
