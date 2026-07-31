import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/model_purpose.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';
import 'package:halo_mobile/model_runtime/sqlite_provider_configuration_store.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('persists a provider model catalog across database reopen', () async {
    final fixture = _DatabaseFixture.create();
    final discoveredAt = DateTime.utc(2026, 7, 29, 8, 30);
    final store = SqliteProviderConfigurationStore.open(fixture.path);
    final created = await store.replaceProviderConfiguration(
      expectedRevision: null,
      replacement: ProviderConfigurationReplacement(
        config: ProviderConfig.deepSeek(),
        modelCatalog: _deepSeekCatalog(discoveredAt),
      ),
    );
    await store.markProviderMutationRuntimePublished(created);
    await store.finalizeProviderMutation(created);
    await store.close();

    final reopened = SqliteProviderConfigurationStore.open(fixture.path);
    try {
      final catalog = await reopened.loadProviderModelCatalog('deepseek');
      expect(catalog!.models.map((model) => model.ref.modelId), [
        'deepseek-chat',
        'deepseek-reasoner',
      ]);
      expect(catalog.providerId, 'deepseek');
      expect(catalog.discoveredAt, discoveredAt);
      expect(catalog.models.last.displayName, 'DeepSeek Reasoner');
      expect(catalog.models.last.capabilities.systemMessages, isFalse);
      expect(catalog.models.last.capabilities.maxOutputTokens, 65536);
      expect(catalog.models.last.capabilities.supportsTemperature, isFalse);
      final allCatalogs = await reopened.loadAllProviderModelCatalogs();
      expect(allCatalogs, hasLength(1));
      expect(allCatalogs.single.providerId, 'deepseek');
      expect(allCatalogs.single.models.map((model) => model.ref.modelId), [
        'deepseek-chat',
        'deepseek-reasoner',
      ]);
    } finally {
      await reopened.close();
      fixture.delete();
    }
  });

  test('present empty catalog round-trips directly and after reopen', () async {
    final fixture = _DatabaseFixture.create();
    final discoveredAt = DateTime.utc(2026, 7, 29, 8, 31, 0, 123);
    final store = SqliteProviderConfigurationStore.open(fixture.path);
    final created = await store.replaceProviderConfiguration(
      expectedRevision: null,
      replacement: ProviderConfigurationReplacement(
        config: ProviderConfig.deepSeek(),
        modelCatalog: _emptyDeepSeekCatalog(discoveredAt),
      ),
    );
    final direct = await store.loadProviderModelCatalog('deepseek');
    expect(direct, isNotNull);
    expect(direct!.models, isEmpty);
    expect(direct.discoveredAt, discoveredAt);
    final directAll = await store.loadAllProviderModelCatalogs();
    expect(directAll, hasLength(1));
    expect(directAll.single.discoveredAt, discoveredAt);
    await store.markProviderMutationRuntimePublished(created);
    await store.finalizeProviderMutation(created);
    await store.close();

    final reopened = SqliteProviderConfigurationStore.open(fixture.path);
    try {
      final persisted = await reopened.loadProviderModelCatalog('deepseek');
      expect(persisted, isNotNull);
      expect(persisted!.models, isEmpty);
      expect(persisted.discoveredAt, discoveredAt);
      final all = await reopened.loadAllProviderModelCatalogs();
      expect(all, hasLength(1));
      expect(all.single.providerId, 'deepseek');
      expect(all.single.models, isEmpty);
      expect(all.single.discoveredAt, discoveredAt);
    } finally {
      await reopened.close();
      fixture.delete();
    }
  });

  test('rollback restores a present empty catalog and its timestamp', () async {
    final fixture = _DatabaseFixture.create();
    final originalDiscoveredAt = DateTime.utc(2026, 7, 29, 8, 32, 0, 456);
    final store = SqliteProviderConfigurationStore.open(fixture.path);
    try {
      final created = await store.replaceProviderConfiguration(
        expectedRevision: null,
        replacement: ProviderConfigurationReplacement(
          config: ProviderConfig.deepSeek(),
          modelCatalog: _emptyDeepSeekCatalog(originalDiscoveredAt),
        ),
      );
      await store.markProviderMutationRuntimePublished(created);
      await store.finalizeProviderMutation(created);
      final before = (await store.loadProvider('deepseek'))!;
      final replacement = await store.replaceProviderConfiguration(
        expectedRevision: before.revision,
        replacement: ProviderConfigurationReplacement(
          config: ProviderConfig.deepSeek(enabled: false),
          modelCatalog: _deepSeekCatalog(
            DateTime.utc(2026, 7, 29, 8, 33, 0, 789),
          ),
        ),
      );

      await store.rollbackProviderMutation(replacement);

      final restored = await store.loadProviderModelCatalog('deepseek');
      expect(restored, isNotNull);
      expect(restored!.models, isEmpty);
      expect(restored.discoveredAt, originalDiscoveredAt);
    } finally {
      await store.close();
      fixture.delete();
    }
  });

  test(
    'removal restore restores a present empty catalog and its timestamp',
    () async {
      final fixture = _DatabaseFixture.create();
      final discoveredAt = DateTime.utc(2026, 7, 29, 8, 34, 0, 321);
      final store = SqliteProviderConfigurationStore.open(fixture.path);
      try {
        final created = await store.replaceProviderConfiguration(
          expectedRevision: null,
          replacement: ProviderConfigurationReplacement(
            config: ProviderConfig.deepSeek(),
            modelCatalog: _emptyDeepSeekCatalog(discoveredAt),
          ),
        );
        await store.markProviderMutationRuntimePublished(created);
        await store.finalizeProviderMutation(created);
        final before = (await store.loadProvider('deepseek'))!;
        final removal = await store.removeProviderAtomically(
          providerId: 'deepseek',
          expectedRevision: before.revision,
        );

        await store.restoreRemovedProvider(removal);

        final restored = await store.loadProviderModelCatalog('deepseek');
        expect(restored, isNotNull);
        expect(restored!.models, isEmpty);
        expect(restored.discoveredAt, discoveredAt);
      } finally {
        await store.close();
        fixture.delete();
      }
    },
  );

  test('persisted catalog rejects sub-millisecond discovery time', () {
    expect(
      () => _emptyDeepSeekCatalog(
        DateTime.utc(2026, 7, 29, 8, 35).add(const Duration(microseconds: 1)),
      ),
      throwsArgumentError,
    );
  });

  test(
    'schema v3 migrates configs and bindings without inventing models',
    () async {
      final fixture = _DatabaseFixture.create();
      _createV3Database(fixture.path);

      final migrated = SqliteProviderConfigurationStore.open(fixture.path);
      try {
        final provider = await migrated.loadProvider('deepseek');
        expect(provider!.config, isA<ProviderConfig>());
        expect(provider.config.providerId, 'deepseek');
        expect(provider.revision.value, 7);
        expect(
          await migrated.loadGlobalDefaultModel(),
          ModelRef(providerId: 'deepseek', modelId: 'deepseek-chat'),
        );
        expect(
          await migrated.loadAgentModelOverride('agent.writer'),
          ModelRef(providerId: 'deepseek', modelId: 'deepseek-reasoner'),
        );
        expect(await migrated.loadProviderModelCatalog('deepseek'), isNull);
        expect(await migrated.loadAllProviderModelCatalogs(), isEmpty);
      } finally {
        await migrated.close();
      }

      final raw = sqlite3.open(fixture.path);
      expect(
        raw.select('PRAGMA user_version').single.values.single,
        SqliteProviderConfigurationStore.schemaVersion,
      );
      raw.close();
      fixture.delete();
    },
  );

  test(
    'exact pre-metadata schema v4 migrates in place without data loss',
    () async {
      final fixture = _DatabaseFixture.create();
      final discoveredAt = DateTime.utc(2026, 7, 29, 8, 40, 0, 654);
      _createPreMetadataV4Database(fixture.path, discoveredAt);
      final beforeMigration = sqlite3.open(fixture.path);
      beforeMigration.execute(
        '''
          INSERT INTO provider_configuration_mutations (
            lease_id, operation_id, provider_id, operation_kind,
            new_revision, created_at_ms, previous_snapshot_json,
            applied_config_json, applied_bindings_json
          ) VALUES (?, ?, 'pending-v4', 'create', 1, 1, '{}', '{}', '[]')
        ''',
        ['9' * 64, '0' * 64],
      );
      beforeMigration.close();

      final migrated = SqliteProviderConfigurationStore.open(fixture.path);
      try {
        final provider = (await migrated.loadProvider('deepseek'))!;
        expect(provider.config.providerId, 'deepseek');
        expect(provider.revision.value, 7);
        final catalog = (await migrated.loadProviderModelCatalog('deepseek'))!;
        expect(catalog.discoveredAt, discoveredAt);
        expect(catalog.models.map((model) => model.ref.modelId), [
          'deepseek-chat',
          'deepseek-reasoner',
        ]);
        expect(catalog.models.last.capabilities.systemMessages, isFalse);
        expect(catalog.models.last.capabilities.maxOutputTokens, 65536);
        expect(
          await migrated.loadGlobalDefaultModel(),
          ModelRef(providerId: 'deepseek', modelId: 'deepseek-chat'),
        );
        expect(
          await migrated.loadAgentModelOverride('agent.writer'),
          ModelRef(providerId: 'deepseek', modelId: 'deepseek-reasoner'),
        );
      } finally {
        await migrated.close();
      }

      final raw = sqlite3.open(fixture.path);
      expect(
        raw.select('PRAGMA user_version').single.values.single,
        SqliteProviderConfigurationStore.schemaVersion,
      );
      expect(
        raw
            .select('PRAGMA table_xinfo(provider_configuration_mutations)')
            .map((row) => row['name']),
        contains('state'),
      );
      expect(
        raw
            .select(
              'SELECT state FROM provider_configuration_mutations '
              "WHERE provider_id = 'pending-v4'",
            )
            .single['state'],
        'staged',
      );
      expect(
        raw
            .select('PRAGMA table_xinfo(provider_removal_leases)')
            .map((row) => row['name']),
        contains('state'),
      );
      expect(
        raw.select(
          "SELECT 1 FROM sqlite_master "
          "WHERE type = 'table' AND name = 'provider_model_catalogs'",
        ),
        hasLength(1),
      );
      expect(
        raw.select('PRAGMA foreign_key_list(provider_models)').single['table'],
        'provider_model_catalogs',
      );
      raw.execute(
        "DELETE FROM provider_configuration_mutations "
        "WHERE provider_id = 'pending-v4'",
      );
      raw.close();

      final validated = SqliteProviderConfigurationStore.open(fixture.path);
      await validated.close();
      fixture.delete();
    },
  );

  test('tampered pre-metadata schema v4 still fails closed', () {
    final fixture = _DatabaseFixture.create();
    _createPreMetadataV4Database(
      fixture.path,
      DateTime.utc(2026, 7, 29, 8, 41),
    );
    final raw = sqlite3.open(fixture.path);
    raw.execute('PRAGMA writable_schema = ON');
    raw.execute(
      'UPDATE sqlite_master SET sql = replace(sql, ?, ?) '
      "WHERE name = 'provider_models'",
      [
        'max_output_tokens > 0 AND max_output_tokens <= 1000000',
        'max_output_tokens >= 0 AND max_output_tokens <= 1000000',
      ],
    );
    raw.execute('PRAGMA writable_schema = OFF');
    raw.close();

    expect(
      () => SqliteProviderConfigurationStore.open(fixture.path),
      throwsStateError,
    );
    fixture.delete();
  });

  test(
    'pending replacement rollback restores the exact prior catalog',
    () async {
      final fixture = _DatabaseFixture.create();
      final originalDiscoveredAt = DateTime.utc(2026, 7, 28, 9);
      final store = SqliteProviderConfigurationStore.open(fixture.path);
      try {
        final created = await store.replaceProviderConfiguration(
          expectedRevision: null,
          replacement: ProviderConfigurationReplacement(
            config: ProviderConfig.deepSeek(),
            modelCatalog: _deepSeekCatalog(originalDiscoveredAt),
          ),
        );
        await store.markProviderMutationRuntimePublished(created);
        await store.finalizeProviderMutation(created);
        final before = (await store.loadProvider('deepseek'))!;

        final replacement = await store.replaceProviderConfiguration(
          expectedRevision: before.revision,
          replacement: ProviderConfigurationReplacement(
            config: ProviderConfig.deepSeek(enabled: false),
            modelCatalog: PersistedProviderModelCatalog(
              providerId: 'deepseek',
              models: [
                ModelDescriptor(
                  ref: ModelRef(
                    providerId: 'deepseek',
                    modelId: 'deepseek-reasoner',
                  ),
                  displayName: 'Reasoner v2',
                  capabilities: const ModelCapabilities.text(
                    systemMessages: false,
                    maxOutputTokens: 32768,
                    supportsTemperature: false,
                  ),
                ),
              ],
              discoveredAt: DateTime.utc(2026, 7, 29, 9),
            ),
          ),
        );
        expect(
          (await store.loadProviderModelCatalog(
            'deepseek',
          ))!.models.single.displayName,
          'Reasoner v2',
        );

        await store.rollbackProviderMutation(replacement);

        final restored = await store.loadProviderModelCatalog('deepseek');
        expect(restored!.discoveredAt, originalDiscoveredAt);
        expect(restored.models.map((model) => model.ref.modelId), [
          'deepseek-chat',
          'deepseek-reasoner',
        ]);
        expect(restored.models.last.displayName, 'DeepSeek Reasoner');
        expect(restored.models.last.capabilities.maxOutputTokens, 65536);
      } finally {
        await store.close();
        fixture.delete();
      }
    },
  );

  test('removal restore restores the provider model catalog', () async {
    final fixture = _DatabaseFixture.create();
    final discoveredAt = DateTime.utc(2026, 7, 28, 10);
    final store = SqliteProviderConfigurationStore.open(fixture.path);
    try {
      final created = await store.replaceProviderConfiguration(
        expectedRevision: null,
        replacement: ProviderConfigurationReplacement(
          config: ProviderConfig.deepSeek(),
          modelCatalog: _deepSeekCatalog(discoveredAt),
        ),
      );
      await store.markProviderMutationRuntimePublished(created);
      await store.finalizeProviderMutation(created);
      final before = (await store.loadProvider('deepseek'))!;

      final removal = await store.removeProviderAtomically(
        providerId: 'deepseek',
        expectedRevision: before.revision,
      );
      expect(await store.loadProviderModelCatalog('deepseek'), isNull);

      await store.restoreRemovedProvider(removal);

      final restored = await store.loadProviderModelCatalog('deepseek');
      expect(restored!.discoveredAt, discoveredAt);
      expect(restored.models.map((model) => model.ref.modelId), [
        'deepseek-chat',
        'deepseek-reasoner',
      ]);
    } finally {
      await store.close();
      fixture.delete();
    }
  });

  test(
    'catalog replacement clears only bindings for removed provider models',
    () async {
      final fixture = _DatabaseFixture.create();
      final store = SqliteProviderConfigurationStore.open(fixture.path);
      try {
        final created = await store.replaceProviderConfiguration(
          expectedRevision: null,
          replacement: ProviderConfigurationReplacement(
            config: ProviderConfig.deepSeek(),
            modelCatalog: _deepSeekCatalog(DateTime.utc(2026, 7, 28, 11)),
          ),
        );
        await store.markProviderMutationRuntimePublished(created);
        await store.finalizeProviderMutation(created);
        await store.upsert(ProviderConfig.openAI());
        await store.setGlobalDefaultModel(
          ModelRef(providerId: 'deepseek', modelId: 'deepseek-chat'),
        );
        await store.setAgentModelOverride(
          'agent.keep',
          ModelRef(providerId: 'deepseek', modelId: 'deepseek-reasoner'),
        );
        await store.setAgentModelOverride(
          'agent.other',
          ModelRef(providerId: 'openai', modelId: 'gpt-5'),
        );
        final before = (await store.loadProvider('deepseek'))!;

        final replacement = await store.replaceProviderConfiguration(
          expectedRevision: before.revision,
          replacement: ProviderConfigurationReplacement(
            config: ProviderConfig.deepSeek(),
            modelCatalog: PersistedProviderModelCatalog(
              providerId: 'deepseek',
              models: [
                ModelDescriptor(
                  ref: ModelRef(
                    providerId: 'deepseek',
                    modelId: 'deepseek-reasoner',
                  ),
                  displayName: 'DeepSeek Reasoner',
                  capabilities: const ModelCapabilities.text(
                    systemMessages: false,
                    maxOutputTokens: 65536,
                    supportsTemperature: false,
                  ),
                ),
              ],
              discoveredAt: DateTime.utc(2026, 7, 29, 11),
            ),
          ),
        );

        expect(await store.loadGlobalDefaultModel(), isNull);
        expect(
          await store.loadAgentModelOverride('agent.keep'),
          ModelRef(providerId: 'deepseek', modelId: 'deepseek-reasoner'),
        );
        expect(
          await store.loadAgentModelOverride('agent.other'),
          ModelRef(providerId: 'openai', modelId: 'gpt-5'),
        );
        await store.markProviderMutationRuntimePublished(replacement);
        await store.finalizeProviderMutation(replacement);
      } finally {
        await store.close();
        fixture.delete();
      }
    },
  );

  test(
    'persists only secret references and round-trips enabled configs',
    () async {
      final fixture = _DatabaseFixture.create();
      final store = SqliteProviderConfigurationStore.open(fixture.path);
      try {
        final keyRef = SecretRef.parse(
          'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174000',
        );
        final headerRef = SecretRef.parse(
          'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174001',
        );
        await store.upsert(
          ProviderConfig.toApis(
            secretRef: keyRef,
          ).copyWith(headerSecretRefs: {'x-tenant-token': headerRef}),
        );
        await store.upsert(ProviderConfig.deepSeek(enabled: false));

        final enabled = await store.loadEnabled();

        expect(enabled, hasLength(1));
        expect(enabled.single.providerId, 'toapis');
        expect(enabled.single.secretRef, keyRef);
        expect(enabled.single.headerSecretRefs, {'x-tenant-token': headerRef});

        final raw = sqlite3.open(fixture.path);
        final persistedProvider = raw
            .select(
              "SELECT secret_ref FROM provider_configs WHERE provider_id = 'toapis'",
            )
            .single;
        final persistedHeader = raw
            .select('SELECT secret_ref FROM provider_header_secret_refs')
            .single;
        final allPersistedText = raw
            .select('''
            SELECT provider_id || kind || protocol || display_name || base_uri ||
                   enabled || ifnull(secret_ref, '') || allow_insecure_http
                   AS value
            FROM provider_configs
          ''')
            .map((row) => row['value'])
            .join();
        expect(persistedProvider['secret_ref'], keyRef.locator.toString());
        expect(persistedHeader['secret_ref'], headerRef.locator.toString());
        expect(allPersistedText, isNot(contains('sk-live-never-persist')));
        raw.close();
      } finally {
        await store.close();
        fixture.delete();
      }
    },
  );

  test('persists global default and independent per-agent overrides', () async {
    final fixture = _DatabaseFixture.create();
    final store = SqliteProviderConfigurationStore.open(fixture.path);
    try {
      await store.upsert(ProviderConfig.toApis());
      await store.upsert(ProviderConfig.openAI());
      final global = ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini');
      final planner = ModelRef(providerId: 'openai', modelId: 'gpt-5');

      await store.setGlobalDefaultModel(global);
      await store.setAgentModelOverride('agent.planner', planner);

      expect(await store.loadGlobalDefaultModel(), global);
      expect(await store.loadAgentModelOverride('agent.planner'), planner);
      expect(await store.loadAgentModelOverride('agent.reviewer'), isNull);
      expect(await store.loadAgentModelOverrides(), {'agent.planner': planner});

      await store.setAgentModelOverride('agent.planner', null);
      expect(await store.loadAgentModelOverride('agent.planner'), isNull);
      expect(await store.loadGlobalDefaultModel(), global);
    } finally {
      await store.close();
      fixture.delete();
    }
  });

  test('locator policy rejects tokens without guessing their shape', () async {
    final fixture = _DatabaseFixture.create();
    final store = SqliteProviderConfigurationStore.open(fixture.path);
    try {
      for (final account in [
        'AIzaSyD-high-entropy-google-key',
        'eyJhbGciOiJIUzI1NiJ9.payload.signature',
        'vQ9x3N7pL2mR8tY5kW1sF6dH4jC0bA',
        '123E4567-E89B-42D3-A456-426614174000',
      ]) {
        await expectLater(
          store.upsert(
            ProviderConfig.toApis(
              secretRef: SecretRef.parse('keychain://halo.provider/$account'),
            ),
          ),
          throwsArgumentError,
        );
      }

      expect(await store.loadAll(), isEmpty);
    } finally {
      await store.close();
      fixture.delete();
    }
  });

  test('load rejects a tampered locator using the shared policy', () async {
    final fixture = _DatabaseFixture.create();
    final store = SqliteProviderConfigurationStore.open(fixture.path);
    await store.upsert(
      ProviderConfig.toApis(
        secretRef: SecretRef.parse(
          'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174000',
        ),
      ),
    );
    await store.close();
    final raw = sqlite3.open(fixture.path);
    raw.execute(
      "UPDATE provider_configs SET secret_ref = "
      "'keychain://halo.provider/eyJhbGciOiJIUzI1NiJ9.payload.signature'",
    );
    raw.close();
    final reopened = SqliteProviderConfigurationStore.open(fixture.path);
    try {
      await expectLater(reopened.loadEnabled(), throwsStateError);
    } finally {
      await reopened.close();
      fixture.delete();
    }
  });

  test('one secret ref cannot be reused across providers or slots', () async {
    final fixture = _DatabaseFixture.create();
    final store = SqliteProviderConfigurationStore.open(fixture.path);
    final ref = SecretRef.parse(
      'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174000',
    );
    try {
      await store.upsert(ProviderConfig.openAI(secretRef: ref));
      await expectLater(
        store.upsert(
          ProviderConfig.customOpenAICompatible(
            providerId: 'custom',
            displayName: 'Custom',
            baseUri: Uri.parse('https://custom.example/v1'),
            secretRef: ref,
          ),
        ),
        throwsA(anything),
      );
      expect(
        () => ProviderConfig.openAI(
          secretRef: ref,
        ).copyWith(headerSecretRefs: {'x-api-key': ref}),
        throwsArgumentError,
      );
    } finally {
      await store.close();
      fixture.delete();
    }
  });

  test('config enforces normalized credential slot bijection in memory', () {
    final first = SecretRef.parse(
      'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174000',
    );
    final second = SecretRef.parse(
      'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174001',
    );
    expect(
      () => ProviderConfig.customOpenAICompatible(
        providerId: 'custom',
        displayName: 'Custom',
        baseUri: Uri.parse('https://custom.example/v1'),
        headerSecretRefs: {'X-Api-Key': first, 'x-api-key': second},
      ),
      throwsArgumentError,
    );
    expect(
      () => ProviderConfig.customOpenAICompatible(
        providerId: 'custom',
        displayName: 'Custom',
        baseUri: Uri.parse('https://custom.example/v1'),
        secretRef: first,
        headerSecretRefs: {'x-api-key': first},
      ),
      throwsArgumentError,
    );
  });

  test('provider locator rejects percent-encoded UUID aliases', () {
    expect(
      () => SecretRef.parse(
        'keychain://halo.provider/%31'
        '23e4567-e89b-42d3-a456-426614174000',
      ),
      throwsArgumentError,
    );
  });

  test('deleting a config does not release its Keychain ownership', () async {
    final fixture = _DatabaseFixture.create();
    final store = SqliteProviderConfigurationStore.open(fixture.path);
    final ref = SecretRef.parse(
      'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174000',
    );
    try {
      await store.upsert(ProviderConfig.openAI(secretRef: ref));
      await store.remove('openai');
      await expectLater(
        store.upsert(
          ProviderConfig.customOpenAICompatible(
            providerId: 'custom',
            displayName: 'Custom',
            baseUri: Uri.parse('https://custom.example/v1'),
            secretRef: ref,
          ),
        ),
        throwsA(anything),
      );
      await store.upsert(ProviderConfig.openAI(secretRef: ref));
    } finally {
      await store.close();
      fixture.delete();
    }
  });

  test('ToAPIs canonical endpoint cannot drift in persisted data', () async {
    final fixture = _DatabaseFixture.create();
    final store = SqliteProviderConfigurationStore.open(fixture.path);
    await store.upsert(ProviderConfig.toApis());
    await store.close();

    final raw = sqlite3.open(fixture.path);
    raw.execute(
      "UPDATE provider_configs SET base_uri = 'https://api.toapis.com/v1' "
      "WHERE provider_id = 'toapis'",
    );
    raw.close();

    final reopened = SqliteProviderConfigurationStore.open(fixture.path);
    try {
      await expectLater(reopened.loadEnabled(), throwsStateError);
    } finally {
      await reopened.close();
      fixture.delete();
    }
  });

  test('rejects a persisted built-in kind with the wrong protocol', () async {
    final fixture = _DatabaseFixture.create();
    final store = SqliteProviderConfigurationStore.open(fixture.path);
    await store.upsert(ProviderConfig.openAI());
    await store.close();

    final raw = sqlite3.open(fixture.path);
    raw.execute(
      "UPDATE provider_configs SET protocol = 'anthropic' "
      "WHERE provider_id = 'openai'",
    );
    raw.close();

    final reopened = SqliteProviderConfigurationStore.open(fixture.path);
    try {
      await expectLater(reopened.loadEnabled(), throwsStateError);
    } finally {
      await reopened.close();
      fixture.delete();
    }
  });

  test(
    'all builtin endpoints are canonical and cannot redirect credentials',
    () {
      final cases = {
        ProviderConfig.deepSeek(): 'https://api.deepseek.com/v1',
        ProviderConfig.openAI(): 'https://api.openai.com/v1',
        ProviderConfig.anthropic(): 'https://api.anthropic.com/v1',
        ProviderConfig.gemini():
            'https://generativelanguage.googleapis.com/v1beta',
      };
      for (final entry in cases.entries) {
        expect(entry.key.baseUri.toString(), entry.value);
        expect(
          () => ProviderConfig.persisted(
            providerId: entry.key.providerId,
            kind: entry.key.kind,
            protocol: entry.key.protocol,
            displayName: entry.key.displayName,
            baseUri: Uri.parse('https://attacker.example/v1'),
            enabled: true,
            secretRef: null,
            allowInsecureHttp: false,
          ),
          throwsStateError,
        );
      }
    },
  );

  test('fake v1 schema with matching columns fails closed', () {
    final fixture = _DatabaseFixture.create();
    final raw = sqlite3.open(fixture.path);
    raw.execute('''
      CREATE TABLE provider_configs (
        provider_id TEXT PRIMARY KEY, kind TEXT, protocol TEXT,
        display_name TEXT, base_uri TEXT, enabled INTEGER, secret_ref TEXT,
        allow_insecure_http INTEGER
      )
    ''');
    raw.execute('''
      CREATE TABLE provider_header_secret_refs (
        provider_id TEXT, header_name TEXT, secret_ref TEXT,
        PRIMARY KEY (provider_id, header_name)
      )
    ''');
    raw.execute('''
      CREATE TABLE model_bindings (
        scope TEXT, scope_id TEXT, provider_id TEXT, model_id TEXT,
        PRIMARY KEY (scope, scope_id)
      )
    ''');
    raw.execute('PRAGMA user_version = 1');
    raw.close();
    expect(
      () => SqliteProviderConfigurationStore.open(fixture.path),
      throwsStateError,
    );
    fixture.delete();
  });

  test('schema fingerprint preserves quoted CHECK literal case', () async {
    final fixture = _DatabaseFixture.create();
    final store = SqliteProviderConfigurationStore.open(fixture.path);
    await store.close();
    final raw = sqlite3.open(fixture.path);
    raw.execute('PRAGMA writable_schema = ON');
    raw.execute(
      "UPDATE sqlite_master SET sql = replace(sql, ?, ?) "
      "WHERE name = 'model_bindings'",
      ["'global'", "'GLOBAL'"],
    );
    raw.execute('PRAGMA writable_schema = OFF');
    raw.close();
    expect(
      () => SqliteProviderConfigurationStore.open(fixture.path),
      throwsStateError,
    );
    fixture.delete();
  });

  test(
    'schema fingerprint accepts semantically equivalent whitespace',
    () async {
      final fixture = _DatabaseFixture.create();
      final store = SqliteProviderConfigurationStore.open(fixture.path);
      await store.close();
      final raw = sqlite3.open(fixture.path);
      raw.execute('PRAGMA writable_schema = ON');
      raw.execute(
        "UPDATE sqlite_master SET sql = replace(sql, 'CHECK (', 'CHECK    (') "
        "WHERE name = 'model_bindings'",
      );
      raw.execute('PRAGMA writable_schema = OFF');
      raw.close();
      final reopened = SqliteProviderConfigurationStore.open(fixture.path);
      await reopened.close();
      fixture.delete();
    },
  );

  test('structured schema accepts equivalent SQL keyword casing', () async {
    final fixture = _DatabaseFixture.create();
    final store = SqliteProviderConfigurationStore.open(fixture.path);
    await store.close();
    final raw = sqlite3.open(fixture.path);
    raw.execute('PRAGMA writable_schema = ON');
    raw.execute(
      "UPDATE sqlite_master SET sql = replace(sql, 'CREATE TABLE', "
      "'create table') WHERE name = 'provider_configs'",
    );
    raw.execute('PRAGMA writable_schema = OFF');
    raw.close();
    final reopened = SqliteProviderConfigurationStore.open(fixture.path);
    await reopened.close();
    fixture.delete();
  });

  test('structured schema rejects a widened active-owner index', () async {
    final fixture = _DatabaseFixture.create();
    final store = SqliteProviderConfigurationStore.open(fixture.path);
    await store.close();
    final raw = sqlite3.open(fixture.path);
    raw.execute('PRAGMA writable_schema = ON');
    raw.execute(
      'UPDATE sqlite_master SET sql = replace(sql, ?, ?) '
      "WHERE name = 'credential_bindings_active_owner'",
      ["WHERE state = 'active'", "WHERE state = 'retired'"],
    );
    raw.execute('PRAGMA writable_schema = OFF');
    raw.close();

    expect(
      () => SqliteProviderConfigurationStore.open(fixture.path),
      throwsStateError,
    );
    fixture.delete();
  });

  test('structured schema rejects a widened provider revision check', () async {
    final fixture = _DatabaseFixture.create();
    final store = SqliteProviderConfigurationStore.open(fixture.path);
    await store.close();
    final raw = sqlite3.open(fixture.path);
    raw.execute('PRAGMA writable_schema = ON');
    raw.execute(
      'UPDATE sqlite_master SET sql = replace(sql, ?, ?) '
      "WHERE name = 'provider_configs'",
      ['CHECK (revision > 0)', 'CHECK (revision >= 0)'],
    );
    raw.execute('PRAGMA writable_schema = OFF');
    raw.close();

    expect(
      () => SqliteProviderConfigurationStore.open(fixture.path),
      throwsStateError,
    );
    fixture.delete();
  });

  test('structured schema rejects widened pending-operation checks', () async {
    final cases = [
      (
        'provider_configuration_mutations',
        'length(lease_id) = 64',
        'length(lease_id) >= 63',
      ),
      (
        'provider_configuration_mutations',
        'new_revision > 0',
        'new_revision >= 0',
      ),
      (
        'provider_removal_leases',
        'removed_revision > 0',
        'removed_revision >= 0',
      ),
      ('provider_removal_leases', 'created_at_ms > 0', 'created_at_ms >= 0'),
      (
        'provider_configuration_mutations',
        "state IN ('staged', 'runtimePublished')",
        "state IN ('staged', 'runtimePublished', 'pending')",
      ),
      (
        'provider_removal_leases',
        "state IN ('staged', 'runtimePublished')",
        "state IN ('staged', 'runtimePublished', 'pending')",
      ),
    ];
    for (final (table, original, weakened) in cases) {
      final fixture = _DatabaseFixture.create();
      final store = SqliteProviderConfigurationStore.open(fixture.path);
      await store.close();
      final raw = sqlite3.open(fixture.path);
      raw.execute('PRAGMA writable_schema = ON');
      raw.execute(
        'UPDATE sqlite_master SET sql = replace(sql, ?, ?) WHERE name = ?',
        [original, weakened, table],
      );
      raw.execute('PRAGMA writable_schema = OFF');
      raw.close();

      expect(
        () => SqliteProviderConfigurationStore.open(fixture.path),
        throwsStateError,
        reason: '$table: $original',
      );
      fixture.delete();
    }
  });

  test(
    'v3 behavior probes reject every weakened pending identity and kind check',
    () async {
      final cases = <(String, String, String)>[];
      for (final table in [
        'provider_configuration_mutations',
        'provider_removal_leases',
      ]) {
        for (final column in ['lease_id', 'operation_id']) {
          cases.addAll([
            (
              table,
              'length($column) = 64',
              '(length($column) = 64 OR length($column) = 0)',
            ),
            (
              table,
              "$column NOT GLOB '*[^0-9a-f]*'",
              "$column NOT GLOB '*[^0-9A-Fa-f]*'",
            ),
            (
              table,
              "$column NOT GLOB '*[^0-9a-f]*'",
              "$column NOT GLOB '*[^0-9a-g]*'",
            ),
          ]);
        }
      }
      for (final invalidKind in [
        '',
        'unknown',
        'CREATE',
        'replace ',
        'remove',
      ]) {
        cases.add((
          'provider_configuration_mutations',
          "operation_kind IN ('create', 'replace', 'rotate')",
          "operation_kind IN ('create', 'replace', 'rotate', '$invalidKind')",
        ));
      }

      for (final (table, original, weakened) in cases) {
        final fixture = _DatabaseFixture.create();
        final store = SqliteProviderConfigurationStore.open(fixture.path);
        await store.close();
        final raw = sqlite3.open(fixture.path);
        raw.execute('PRAGMA writable_schema = ON');
        raw.execute(
          'UPDATE sqlite_master SET sql = replace(sql, ?, ?) WHERE name = ?',
          [original, weakened, table],
        );
        raw.execute('PRAGMA writable_schema = OFF');
        raw.close();

        expect(
          () => SqliteProviderConfigurationStore.open(fixture.path),
          throwsStateError,
          reason: '$table must reject: $weakened',
        );
        fixture.delete();
      }
    },
  );

  test('canonical IDs and display text reject Unicode formatting attacks', () {
    expect(
      () => ProviderConfig.customOpenAICompatible(
        providerId: 'custom\u200bprovider',
        displayName: 'Custom',
        baseUri: Uri.parse('https://custom.example/v1'),
      ),
      throwsArgumentError,
    );
    expect(
      () => ProviderConfig.customOpenAICompatible(
        providerId: 'custom',
        displayName: 'Safe\u202Eevil',
        baseUri: Uri.parse('https://custom.example/v1'),
      ),
      throwsArgumentError,
    );
    for (final invalid in ['   ', 'line\u2028break', 'note\uFFF9hidden']) {
      expect(
        () => ProviderConfig.customOpenAICompatible(
          providerId: 'custom',
          displayName: invalid,
          baseUri: Uri.parse('https://custom.example/v1'),
        ),
        throwsArgumentError,
      );
    }
    final valid = ProviderConfig.customOpenAICompatible(
      providerId: 'custom',
      displayName: '模型服务 🚀',
      baseUri: Uri.parse('https://custom.example/v1'),
    );
    expect(valid.displayName, '模型服务 🚀');
  });

  test(
    'an older install gains the new tables without losing anything',
    () async {
      final fixture = _DatabaseFixture.create();
      // Build a real v5 database through the shipped code path, then rewind the
      // version marker so reopening exercises the v5 -> v6 upgrade.
      final before = SqliteProviderConfigurationStore.open(fixture.path);
      await before.upsert(
        ProviderConfig.deepSeek(
          enabled: true,
          secretRef: SecretRef.parse(
            'keychain://halo.provider/2f3a4b5c-6d7e-4f80-9a1b-2c3d4e5f6071',
          ),
        ),
      );
      await before.setGlobalDefaultModel(
        ModelRef(providerId: 'deepseek', modelId: 'deepseek-chat'),
      );
      await before.setAgentModelOverride(
        'product-manager',
        ModelRef(providerId: 'deepseek', modelId: 'deepseek-reasoner'),
      );
      await before.close();

      final raw = sqlite3.open(fixture.path);
      raw.execute('DROP TABLE provider_model_modalities');
      raw.execute('DROP TABLE purpose_model_bindings');
      raw.execute('DROP TABLE service_credentials');
      raw.execute('PRAGMA user_version = 5');
      raw.close();

      final upgraded = SqliteProviderConfigurationStore.open(fixture.path);
      addTearDown(upgraded.close);

      // The upgrade is additive: everything the install already had survives.
      expect(
        await upgraded.loadGlobalDefaultModel(),
        ModelRef(providerId: 'deepseek', modelId: 'deepseek-chat'),
      );
      expect(
        (await upgraded.loadAgentModelOverrides())['product-manager'],
        ModelRef(providerId: 'deepseek', modelId: 'deepseek-reasoner'),
      );
      expect((await upgraded.loadEnabled()).single.providerId, 'deepseek');

      final reopened = sqlite3.open(fixture.path);
      expect(
        reopened.select('PRAGMA user_version').single.values.first,
        SqliteProviderConfigurationStore.schemaVersion,
      );
      expect(
        reopened
            .select(
              "SELECT name FROM sqlite_master WHERE type = 'table' "
              "AND name IN ('purpose_model_bindings', 'service_credentials', "
              "'provider_model_modalities')",
            )
            .length,
        3,
      );
      reopened.close();
    },
  );

  test(
    'service credentials record a locator and displace the old one',
    () async {
      final fixture = _DatabaseFixture.create();
      final store = SqliteProviderConfigurationStore.open(fixture.path);
      addTearDown(store.close);

      expect(await store.loadServiceCredentials(), isEmpty);

      final first = SecretRef.parse(
        'keychain://halo.provider/aaaaaaaa-bbbb-4ccc-8ddd-000000000001',
      );
      expect(
        await store.putServiceCredential(
          'doubao-speech',
          first,
          enabled: true,
          configuredAt: DateTime.utc(2026, 7, 30, 12),
        ),
        // Nothing displaced on a first write.
        isNull,
      );

      final stored = (await store.loadServiceCredentials()).single;
      expect(stored.serviceId, 'doubao-speech');
      expect(stored.secretRef.locator, first.locator);
      expect(stored.enabled, isTrue);
      // Never leaks the locator, which a log line might carry.
      expect(stored.toString(), isNot(contains('keychain://')));

      final second = SecretRef.parse(
        'keychain://halo.provider/aaaaaaaa-bbbb-4ccc-8ddd-000000000002',
      );
      final displaced = await store.putServiceCredential(
        'doubao-speech',
        second,
        enabled: true,
        configuredAt: DateTime.utc(2026, 7, 30, 13),
      );
      // The caller is told which key it may now delete.
      expect(displaced?.locator, first.locator);
      expect(
        (await store.loadServiceCredentials()).single.secretRef.locator,
        second.locator,
      );

      // Re-saving the same locator must not ask the caller to delete it.
      expect(
        await store.putServiceCredential(
          'doubao-speech',
          second,
          enabled: true,
          configuredAt: DateTime.utc(2026, 7, 30, 14),
        ),
        isNull,
      );

      expect(
        (await store.removeServiceCredential('doubao-speech'))?.locator,
        second.locator,
      );
      expect(await store.loadServiceCredentials(), isEmpty);
      expect(await store.removeServiceCredential('doubao-speech'), isNull);
    },
  );

  test('service credentials survive a reopen and reject bad ids', () async {
    final fixture = _DatabaseFixture.create();
    final store = SqliteProviderConfigurationStore.open(fixture.path);
    final ref = SecretRef.parse(
      'keychain://halo.provider/aaaaaaaa-bbbb-4ccc-8ddd-000000000009',
    );
    await store.putServiceCredential(
      'vidu',
      ref,
      enabled: true,
      configuredAt: DateTime.utc(2026, 7, 30, 12),
    );
    await expectLater(
      store.putServiceCredential(
        'Vidu Video',
        ref,
        enabled: true,
        configuredAt: DateTime.utc(2026, 7, 30, 12),
      ),
      throwsArgumentError,
    );
    await store.close();

    final reopened = SqliteProviderConfigurationStore.open(fixture.path);
    addTearDown(reopened.close);
    final records = await reopened.loadServiceCredentials();
    expect(records.single.serviceId, 'vidu');
    expect(records.single.configuredAt.isUtc, isTrue);
  });

  test(
    'a v6 install keeps its purpose bindings when vision is added',
    () async {
      final fixture = _DatabaseFixture.create();
      final before = SqliteProviderConfigurationStore.open(fixture.path);
      await before.upsert(
        ProviderConfig.deepSeek(
          enabled: true,
          secretRef: SecretRef.parse(
            'keychain://halo.provider/3f3a4b5c-6d7e-4f80-9a1b-2c3d4e5f6072',
          ),
        ),
      );
      await before.close();

      // Rewind to a v6 shape: no modality table, and a purpose CHECK that
      // predates vision.
      final raw = sqlite3.open(fixture.path);
      raw.execute('DROP TABLE provider_model_modalities');
      raw.execute('DROP TABLE purpose_model_bindings');
      raw.execute("""
      CREATE TABLE purpose_model_bindings (
        purpose TEXT PRIMARY KEY CHECK (purpose IN ('image', 'video')),
        provider_id TEXT NOT NULL
          REFERENCES provider_configs(provider_id) ON DELETE CASCADE,
        model_id TEXT NOT NULL CHECK (length(model_id) > 0)
      ) STRICT
    """);
      raw.execute(
        'INSERT INTO purpose_model_bindings (purpose, provider_id, model_id) '
        "VALUES ('image', 'deepseek', 'some-image-model')",
      );
      raw.execute('PRAGMA user_version = 6');
      raw.close();

      final upgraded = SqliteProviderConfigurationStore.open(fixture.path);
      addTearDown(upgraded.close);

      final reopened = sqlite3.open(fixture.path);
      // The chosen image default survived the table rebuild.
      final rows = reopened.select(
        'SELECT purpose, model_id FROM purpose_model_bindings',
      );
      expect(rows.single['purpose'], 'image');
      expect(rows.single['model_id'], 'some-image-model');
      // And vision is now an accepted purpose.
      reopened.execute(
        'INSERT INTO purpose_model_bindings (purpose, provider_id, model_id) '
        "VALUES ('vision', 'deepseek', 'some-vision-model')",
      );
      expect(
        reopened.select('PRAGMA user_version').single.values.first,
        SqliteProviderConfigurationStore.schemaVersion,
      );
      reopened.close();
    },
  );

  test(
    'declared modalities round-trip and drive purpose suitability',
    () async {
      final fixture = _DatabaseFixture.create();
      final store = SqliteProviderConfigurationStore.open(fixture.path);
      addTearDown(store.close);
      final created = await store.replaceProviderConfiguration(
        expectedRevision: null,
        replacement: ProviderConfigurationReplacement(
          config: ProviderConfig.toApis(
            secretRef: SecretRef.parse(
              'keychain://halo.provider/4f3a4b5c-6d7e-4f80-9a1b-2c3d4e5f6073',
            ),
          ),
          modelCatalog: PersistedProviderModelCatalog(
            providerId: 'toapis',
            discoveredAt: DateTime.utc(2026, 7, 31),
            models: [
              ModelDescriptor(
                ref: ModelRef(providerId: 'toapis', modelId: 'gpt-5-mini'),
                displayName: 'GPT-5 mini',
                capabilities: const ModelCapabilities.text(),
                declaredModalities: const {'chat_completions'},
              ),
              ModelDescriptor(
                ref: ModelRef(providerId: 'toapis', modelId: 'seedream-4'),
                displayName: 'Seedream 4',
                capabilities: const ModelCapabilities(
                  textGeneration: false,
                  systemMessages: false,
                  maxOutputTokens: 4096,
                  supportsTemperature: false,
                ),
                declaredModalities: const {'images/generations'},
              ),
              ModelDescriptor(
                ref: ModelRef(providerId: 'toapis', modelId: 'some-embedding'),
                displayName: 'Some Embedding',
                capabilities: const ModelCapabilities(
                  textGeneration: false,
                  systemMessages: false,
                  maxOutputTokens: 4096,
                  supportsTemperature: false,
                ),
                declaredModalities: const {'embeddings'},
              ),
            ],
          ),
        ),
      );
      await store.markProviderMutationRuntimePublished(created);
      await store.finalizeProviderMutation(created);

      final catalog = await store.loadProviderModelCatalog('toapis');
      final byId = {
        for (final model in catalog!.models) model.ref.modelId: model,
      };
      expect(byId['seedream-4']!.declaredModalities, {'images/generations'});
      expect(byId['gpt-5-mini']!.declaredModalities, {'chat_completions'});

      // The picker must offer the image model and neither of the others.
      expect(
        ModelPurposeSuitability.allows(ModelPurpose.image, byId['seedream-4']!),
        isTrue,
      );
      expect(
        ModelPurposeSuitability.allows(ModelPurpose.image, byId['gpt-5-mini']!),
        isFalse,
      );
      expect(
        ModelPurposeSuitability.allows(
          ModelPurpose.image,
          byId['some-embedding']!,
        ),
        isFalse,
      );
      // Vision cannot be detected from a catalogue, so every text model is
      // offered and the user names the one that actually reads images.
      expect(
        ModelPurposeSuitability.allows(
          ModelPurpose.vision,
          byId['gpt-5-mini']!,
        ),
        isTrue,
      );
      expect(
        ModelPurposeSuitability.allows(
          ModelPurpose.vision,
          byId['seedream-4']!,
        ),
        isFalse,
      );

      final ref = ModelRef(providerId: 'toapis', modelId: 'seedream-4');
      await store.setPurposeModel(ModelPurpose.image, ref);
      expect(await store.loadPurposeModel(ModelPurpose.image), ref);
      expect(await store.loadPurposeModel(ModelPurpose.video), isNull);
      await store.setPurposeModel(ModelPurpose.image, null);
      expect(await store.loadPurposeModel(ModelPurpose.image), isNull);
    },
  );

  test('rejects a future schema without changing its version', () {
    final fixture = _DatabaseFixture.create();
    final raw = sqlite3.open(fixture.path);
    final future = SqliteProviderConfigurationStore.schemaVersion + 1;
    raw.execute('PRAGMA user_version = $future');
    raw.close();

    expect(
      () => SqliteProviderConfigurationStore.open(fixture.path),
      throwsStateError,
    );

    final reopened = sqlite3.open(fixture.path);
    expect(reopened.select('PRAGMA user_version').single.values.first, future);
    reopened.close();
    fixture.delete();
  });

  test('schema v2 requires an explicit development rebuild', () {
    final fixture = _DatabaseFixture.create();
    final raw = sqlite3.open(fixture.path);
    raw.execute('PRAGMA user_version = 2');
    raw.close();

    expect(
      () => SqliteProviderConfigurationStore.open(fixture.path),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('requires explicit rebuild'),
        ),
      ),
    );
    fixture.delete();
  });

  test('close is idempotent and operations fail after close', () async {
    final fixture = _DatabaseFixture.create();
    final ProviderConfigurationStore store =
        SqliteProviderConfigurationStore.open(fixture.path);

    await store.close();
    await store.close();

    await expectLater(store.loadEnabled(), throwsStateError);
    fixture.delete();
  });

  test(
    'provider replacement atomically creates config and model bindings',
    () async {
      final fixture = _DatabaseFixture.create();
      final store = SqliteProviderConfigurationStore.open(fixture.path);
      final ref = SecretRef.parse(
        'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174000',
      );
      final model = ModelRef(providerId: 'openai', modelId: 'gpt-5');
      try {
        final created = await store.replaceProviderConfiguration(
          expectedRevision: null,
          replacement: ProviderConfigurationReplacement(
            config: ProviderConfig.openAI(secretRef: ref),
            modelCatalog: null,
            modelBindings: ProviderModelBindingMutation(
              replaceGlobalDefault: true,
              globalDefault: model,
              agentOverrides: {'agent.writer': model},
            ),
          ),
        );
        expect(created.newRevision.value, 1);
        expect((await store.loadProvider('openai'))!.config.secretRef, ref);
        expect(await store.loadGlobalDefaultModel(), model);
        expect(await store.loadAgentModelOverride('agent.writer'), model);

        final retry = await store.replaceProviderConfiguration(
          expectedRevision: null,
          replacement: ProviderConfigurationReplacement(
            config: ProviderConfig.openAI(secretRef: ref),
            modelCatalog: null,
            modelBindings: ProviderModelBindingMutation(
              replaceGlobalDefault: true,
              globalDefault: model,
              agentOverrides: {'agent.writer': model},
            ),
          ),
        );
        expect(retry.newRevision, created.newRevision);
        await expectLater(
          store.rollbackProviderMutation(
            _ForgedMutationLease('openai', created.newRevision),
          ),
          throwsA(
            isA<ProviderConfigurationMutationException>().having(
              (error) => error.code,
              'code',
              ProviderConfigurationMutationErrorCode.invalidLease,
            ),
          ),
        );

        await store.rollbackProviderMutation(retry);
        expect(await store.loadProvider('openai'), isNull);
        expect(await store.loadGlobalDefaultModel(), isNull);
        expect(await store.loadAgentModelOverride('agent.writer'), isNull);
        await expectLater(
          store.rollbackProviderMutation(created),
          throwsA(isA<ProviderConfigurationMutationException>()),
        );

        final recreated = await store.replaceProviderConfiguration(
          expectedRevision: null,
          replacement: ProviderConfigurationReplacement(
            config: ProviderConfig.openAI(secretRef: ref),
            modelCatalog: null,
          ),
        );
        await store.markProviderMutationRuntimePublished(recreated);
        await store.finalizeProviderMutation(recreated);
        await expectLater(
          store.finalizeProviderMutation(recreated),
          throwsA(isA<ProviderConfigurationMutationException>()),
        );
      } finally {
        await store.close();
        fixture.delete();
      }
    },
  );

  test('rotation rollback lease survives a database reopen', () async {
    final fixture = _DatabaseFixture.create();
    final oldRef = SecretRef.parse(
      'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174000',
    );
    final newRef = SecretRef.parse(
      'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174001',
    );
    final first = SqliteProviderConfigurationStore.open(fixture.path);
    await first.upsert(ProviderConfig.openAI(secretRef: oldRef));
    final before = (await first.loadProvider('openai'))!;
    final lease = await first.rotateCredential(
      providerId: 'openai',
      slot: ProviderCredentialSlot.primary,
      expectedRevision: before.revision,
      expectedOldRef: oldRef,
      newRef: newRef,
      replacement: ProviderConfigurationReplacement(
        config: ProviderConfig.openAI(secretRef: newRef),
        modelCatalog: null,
      ),
    );
    await first.close();

    final reopened = SqliteProviderConfigurationStore.open(fixture.path);
    try {
      await reopened.rollbackProviderMutation(lease);
      final restored = (await reopened.loadProvider('openai'))!;
      expect(restored.config.secretRef, oldRef);
      expect(restored.revision, before.revision);
    } finally {
      await reopened.close();
      fixture.delete();
    }
  });

  test(
    'pending create is recovered after restart using only its stable id',
    () async {
      final fixture = _DatabaseFixture.create();
      final ref = SecretRef.parse(
        'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174000',
      );
      late final String operationIdValue;
      {
        final first = SqliteProviderConfigurationStore.open(fixture.path);
        final staged = await first.replaceProviderConfiguration(
          expectedRevision: null,
          replacement: ProviderConfigurationReplacement(
            config: ProviderConfig.openAI(secretRef: ref),
            modelCatalog: null,
            modelBindings: ProviderModelBindingMutation(
              replaceGlobalDefault: true,
              globalDefault: ModelRef(providerId: 'openai', modelId: 'gpt-5'),
            ),
          ),
        );
        operationIdValue = staged.operationId.value;
        await first.close();
      }

      final reopened = SqliteProviderConfigurationStore.open(fixture.path);
      try {
        final operationId = PendingProviderOperationId.parse(operationIdValue);
        final pending = await reopened.listPendingProviderOperations();
        expect(pending, hasLength(1));
        final descriptor = pending.single;
        expect(descriptor.operationId, operationId);
        expect(descriptor.kind, PendingProviderOperationKind.create);
        expect(descriptor.state, PendingProviderOperationState.staged);
        expect(descriptor.createdAt.isUtc, isTrue);
        expect(descriptor.providerId, 'openai');
        expect(descriptor.previousConfiguration, isNull);
        expect(descriptor.nextConfiguration!.secretRef, ref);
        expect(descriptor.previousCredentialRefs, isEmpty);
        expect(descriptor.nextCredentialRefs.values, contains(ref));
        expect(
          descriptor.nextBindings.globalDefault,
          ModelRef(providerId: 'openai', modelId: 'gpt-5'),
        );
        expect(descriptor.allowedActions, {
          PendingProviderTerminalAction.rollback,
        });
        expect(descriptor.toString(), isNot(contains(operationId.value)));
        expect(descriptor.toString(), isNot(contains(ref.locator.toString())));

        final recovery = await reopened.recoverPendingProviderOperation(
          operationId: operationId,
          expectedProviderId: 'openai',
          expectedKind: PendingProviderOperationKind.create,
        );
        await reopened.rollbackProviderMutation(recovery.mutationLease!);
        expect(await reopened.loadProvider('openai'), isNull);
        expect(await reopened.listPendingProviderOperations(), isEmpty);
      } finally {
        await reopened.close();
        fixture.delete();
      }
    },
  );

  test(
    'mutation publication phase is durable one-way and exact-lease bound',
    () async {
      final fixture = _DatabaseFixture.create();
      late final PendingProviderOperationId operationId;
      {
        final first = SqliteProviderConfigurationStore.open(fixture.path);
        final lease = await first.replaceProviderConfiguration(
          expectedRevision: null,
          replacement: ProviderConfigurationReplacement(
            config: ProviderConfig.openAI(),
            modelCatalog: null,
          ),
        );
        operationId = lease.operationId;
        await expectLater(
          first.finalizeProviderMutation(lease),
          throwsA(isA<ProviderConfigurationMutationException>()),
        );
        await first.markProviderMutationRuntimePublished(lease);
        await expectLater(
          first.markProviderMutationRuntimePublished(lease),
          throwsA(isA<ProviderConfigurationMutationException>()),
        );
        await first.close();
      }

      final reopened = SqliteProviderConfigurationStore.open(fixture.path);
      try {
        final descriptor =
            (await reopened.listPendingProviderOperations()).single;
        expect(descriptor.operationId, operationId);
        expect(
          descriptor.state,
          PendingProviderOperationState.runtimePublished,
        );
        expect(descriptor.allowedActions, {
          PendingProviderTerminalAction.finalize,
        });
        final recovery = await reopened.recoverPendingProviderOperation(
          operationId: operationId,
          expectedProviderId: 'openai',
          expectedKind: PendingProviderOperationKind.create,
        );
        await reopened.finalizeProviderMutation(recovery.mutationLease!);
        expect(await reopened.listPendingProviderOperations(), isEmpty);
      } finally {
        await reopened.close();
        fixture.delete();
      }
    },
  );

  test(
    'removal publication phase survives restart and rejects stale lease',
    () async {
      final fixture = _DatabaseFixture.create();
      late final ProviderRemovalLease staleLease;
      late final PendingProviderOperationId operationId;
      {
        final first = SqliteProviderConfigurationStore.open(fixture.path);
        await first.upsert(ProviderConfig.openAI());
        final before = (await first.loadProvider('openai'))!;
        staleLease = await first.removeProviderAtomically(
          providerId: 'openai',
          expectedRevision: before.revision,
        );
        operationId = staleLease.operationId;
        await expectLater(
          first.finalizeProviderRemoval(staleLease),
          throwsA(isA<ProviderConfigurationMutationException>()),
        );
        await first.close();
      }

      final reopened = SqliteProviderConfigurationStore.open(fixture.path);
      try {
        final recovery = await reopened.recoverPendingProviderOperation(
          operationId: operationId,
          expectedProviderId: 'openai',
          expectedKind: PendingProviderOperationKind.remove,
        );
        await expectLater(
          reopened.markProviderRemovalRuntimePublished(staleLease),
          throwsA(isA<ProviderConfigurationMutationException>()),
        );
        await reopened.markProviderRemovalRuntimePublished(
          recovery.removalLease!,
        );
        expect(
          (await reopened.listPendingProviderOperations()).single.state,
          PendingProviderOperationState.runtimePublished,
        );
        await reopened.finalizeProviderRemoval(recovery.removalLease!);
        expect(await reopened.listPendingProviderOperations(), isEmpty);
      } finally {
        await reopened.close();
        fixture.delete();
      }
    },
  );

  test(
    'pending rotation recovers old and new refs then finalizes once',
    () async {
      final fixture = _DatabaseFixture.create();
      final oldRef = SecretRef.parse(
        'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174000',
      );
      final newRef = SecretRef.parse(
        'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174001',
      );
      late final String operationIdValue;
      {
        final first = SqliteProviderConfigurationStore.open(fixture.path);
        await first.upsert(ProviderConfig.openAI(secretRef: oldRef));
        final before = (await first.loadProvider('openai'))!;
        final staged = await first.rotateCredential(
          providerId: 'openai',
          slot: ProviderCredentialSlot.primary,
          expectedRevision: before.revision,
          expectedOldRef: oldRef,
          newRef: newRef,
          replacement: ProviderConfigurationReplacement(
            config: ProviderConfig.openAI(secretRef: newRef),
            modelCatalog: null,
          ),
        );
        operationIdValue = staged.operationId.value;
        await first.close();
      }

      final reopened = SqliteProviderConfigurationStore.open(fixture.path);
      try {
        final operationId = PendingProviderOperationId.parse(operationIdValue);
        final descriptor =
            (await reopened.listPendingProviderOperations()).single;
        expect(descriptor.kind, PendingProviderOperationKind.rotate);
        expect(descriptor.previousCredentialRefs.values, contains(oldRef));
        expect(descriptor.nextCredentialRefs.values, contains(newRef));
        final recoveries = await Future.wait([
          reopened.recoverPendingProviderOperation(
            operationId: operationId,
            expectedProviderId: 'openai',
            expectedKind: PendingProviderOperationKind.rotate,
          ),
          reopened.recoverPendingProviderOperation(
            operationId: operationId,
            expectedProviderId: 'openai',
            expectedKind: PendingProviderOperationKind.rotate,
          ),
        ]);
        expect(identical(recoveries.first, recoveries.last), isTrue);

        await reopened.markProviderMutationRuntimePublished(
          recoveries.first.mutationLease!,
        );
        await reopened.finalizeProviderMutation(
          recoveries.first.mutationLease!,
        );
        expect(await reopened.listPendingProviderOperations(), isEmpty);
        await expectLater(
          reopened.finalizeProviderMutation(recoveries.last.mutationLease!),
          throwsA(isA<ProviderConfigurationMutationException>()),
        );
        await expectLater(
          reopened.recoverPendingProviderOperation(
            operationId: operationId,
            expectedProviderId: 'openai',
            expectedKind: PendingProviderOperationKind.rotate,
          ),
          throwsA(isA<ProviderConfigurationMutationException>()),
        );
      } finally {
        await reopened.close();
        fixture.delete();
      }
    },
  );

  test('pending replacement recovers after restart and rolls back', () async {
    final fixture = _DatabaseFixture.create();
    late final PendingProviderOperationId operationId;
    {
      final first = SqliteProviderConfigurationStore.open(fixture.path);
      await first.upsert(ProviderConfig.openAI());
      final before = (await first.loadProvider('openai'))!;
      final staged = await first.replaceProviderConfiguration(
        expectedRevision: before.revision,
        replacement: ProviderConfigurationReplacement(
          config: ProviderConfig.openAI(enabled: false),
          modelCatalog: null,
        ),
      );
      operationId = staged.operationId;
      await first.close();
    }

    final reopened = SqliteProviderConfigurationStore.open(fixture.path);
    try {
      final descriptor =
          (await reopened.listPendingProviderOperations()).single;
      expect(descriptor.kind, PendingProviderOperationKind.replace);
      expect(descriptor.previousConfiguration!.enabled, isTrue);
      expect(descriptor.nextConfiguration!.enabled, isFalse);
      final recovery = await reopened.recoverPendingProviderOperation(
        operationId: operationId,
        expectedProviderId: 'openai',
        expectedKind: PendingProviderOperationKind.replace,
      );
      await reopened.rollbackProviderMutation(recovery.mutationLease!);
      expect((await reopened.loadProvider('openai'))!.config.enabled, isTrue);
      expect(await reopened.listPendingProviderOperations(), isEmpty);
    } finally {
      await reopened.close();
      fixture.delete();
    }
  });

  test(
    'pending removal recovers after restart and restores without old lease',
    () async {
      final fixture = _DatabaseFixture.create();
      final ref = SecretRef.parse(
        'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174000',
      );
      late final String operationIdValue;
      {
        final first = SqliteProviderConfigurationStore.open(fixture.path);
        await first.upsert(ProviderConfig.openAI(secretRef: ref));
        final before = (await first.loadProvider('openai'))!;
        final staged = await first.removeProviderAtomically(
          providerId: 'openai',
          expectedRevision: before.revision,
        );
        operationIdValue = staged.operationId.value;
        await first.close();
      }

      final reopened = SqliteProviderConfigurationStore.open(fixture.path);
      try {
        final operationId = PendingProviderOperationId.parse(operationIdValue);
        final descriptor =
            (await reopened.listPendingProviderOperations()).single;
        expect(descriptor.kind, PendingProviderOperationKind.remove);
        expect(descriptor.previousConfiguration!.secretRef, ref);
        expect(descriptor.nextConfiguration, isNull);
        expect(descriptor.previousCredentialRefs.values, contains(ref));
        expect(
          descriptor.allowedActions,
          contains(PendingProviderTerminalAction.restore),
        );
        final recovered = await reopened.recoverPendingProviderOperation(
          operationId: operationId,
          expectedProviderId: 'openai',
          expectedKind: PendingProviderOperationKind.remove,
        );
        expect(recovered.mutationLease, isNull);
        await reopened.restoreRemovedProvider(recovered.removalLease!);
        expect((await reopened.loadProvider('openai'))!.config.secretRef, ref);
        expect(await reopened.listPendingProviderOperations(), isEmpty);
      } finally {
        await reopened.close();
        fixture.delete();
      }
    },
  );

  test(
    'recovered removal finalizes after key deletion and disappears',
    () async {
      final fixture = _DatabaseFixture.create();
      final ref = SecretRef.parse(
        'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174000',
      );
      late final PendingProviderOperationId operationId;
      {
        final first = SqliteProviderConfigurationStore.open(fixture.path);
        await first.upsert(ProviderConfig.openAI(secretRef: ref));
        final before = (await first.loadProvider('openai'))!;
        operationId = (await first.removeProviderAtomically(
          providerId: 'openai',
          expectedRevision: before.revision,
        )).operationId;
        await first.close();
      }

      final reopened = SqliteProviderConfigurationStore.open(fixture.path);
      try {
        final recovery = await reopened.recoverPendingProviderOperation(
          operationId: operationId,
          expectedProviderId: 'openai',
          expectedKind: PendingProviderOperationKind.remove,
        );
        await reopened.markProviderRemovalRuntimePublished(
          recovery.removalLease!,
        );
        await reopened.finalizeProviderRemoval(recovery.removalLease!);
        expect(await reopened.listPendingProviderOperations(), isEmpty);
        expect(await reopened.loadProvider('openai'), isNull);
      } finally {
        await reopened.close();
        fixture.delete();
      }
    },
  );

  test(
    'pending recovery rejects forged identity kind provider and database',
    () async {
      final firstFixture = _DatabaseFixture.create();
      final secondFixture = _DatabaseFixture.create();
      final first = SqliteProviderConfigurationStore.open(firstFixture.path);
      final staged = await first.replaceProviderConfiguration(
        expectedRevision: null,
        replacement: ProviderConfigurationReplacement(
          config: ProviderConfig.openAI(),
          modelCatalog: null,
        ),
      );
      final operationId = staged.operationId;
      await first.close();
      final reopened = SqliteProviderConfigurationStore.open(firstFixture.path);
      final other = SqliteProviderConfigurationStore.open(secondFixture.path);
      try {
        for (final attempt in [
          reopened.recoverPendingProviderOperation(
            operationId: PendingProviderOperationId.parse('a' * 64),
            expectedProviderId: 'openai',
            expectedKind: PendingProviderOperationKind.create,
          ),
          reopened.recoverPendingProviderOperation(
            operationId: operationId,
            expectedProviderId: 'toapis',
            expectedKind: PendingProviderOperationKind.create,
          ),
          reopened.recoverPendingProviderOperation(
            operationId: operationId,
            expectedProviderId: 'openai',
            expectedKind: PendingProviderOperationKind.rotate,
          ),
          other.recoverPendingProviderOperation(
            operationId: operationId,
            expectedProviderId: 'openai',
            expectedKind: PendingProviderOperationKind.create,
          ),
        ]) {
          await expectLater(
            attempt,
            throwsA(isA<ProviderConfigurationMutationException>()),
          );
        }
      } finally {
        await reopened.close();
        await other.close();
        firstFixture.delete();
        secondFixture.delete();
      }
    },
  );

  test(
    'two reopened stores recover safely but terminal action stays one-shot',
    () async {
      final fixture = _DatabaseFixture.create();
      late final String operationIdValue;
      {
        final staging = SqliteProviderConfigurationStore.open(fixture.path);
        operationIdValue = (await staging.replaceProviderConfiguration(
          expectedRevision: null,
          replacement: ProviderConfigurationReplacement(
            config: ProviderConfig.openAI(),
            modelCatalog: null,
          ),
        )).operationId.value;
        await staging.close();
      }

      final first = SqliteProviderConfigurationStore.open(fixture.path);
      final second = SqliteProviderConfigurationStore.open(fixture.path);
      try {
        final operationId = PendingProviderOperationId.parse(operationIdValue);
        final recoveries = await Future.wait([
          first.recoverPendingProviderOperation(
            operationId: operationId,
            expectedProviderId: 'openai',
            expectedKind: PendingProviderOperationKind.create,
          ),
          second.recoverPendingProviderOperation(
            operationId: operationId,
            expectedProviderId: 'openai',
            expectedKind: PendingProviderOperationKind.create,
          ),
        ]);
        await second.markProviderMutationRuntimePublished(
          recoveries.last.mutationLease!,
        );
        await expectLater(
          first.finalizeProviderMutation(recoveries.first.mutationLease!),
          throwsA(
            isA<ProviderConfigurationMutationException>().having(
              (error) => error.code,
              'code',
              ProviderConfigurationMutationErrorCode.invalidLease,
            ),
          ),
        );
        await second.finalizeProviderMutation(recoveries.last.mutationLease!);
        expect(await second.listPendingProviderOperations(), isEmpty);

        final current = (await first.loadProvider('openai'))!;
        final next = await first.replaceProviderConfiguration(
          expectedRevision: current.revision,
          replacement: ProviderConfigurationReplacement(
            config: ProviderConfig.openAI(enabled: false),
            modelCatalog: null,
          ),
        );
        await first.markProviderMutationRuntimePublished(next);
        await first.finalizeProviderMutation(next);
      } finally {
        await first.close();
        await second.close();
        fixture.delete();
      }
    },
  );

  test(
    'credential rotation atomically switches the active ref and revision',
    () async {
      final fixture = _DatabaseFixture.create();
      final store = SqliteProviderConfigurationStore.open(fixture.path);
      final oldRef = SecretRef.parse(
        'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174000',
      );
      final newRef = SecretRef.parse(
        'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174001',
      );
      try {
        await store.upsert(ProviderConfig.openAI(secretRef: oldRef));
        final model = ModelRef(providerId: 'openai', modelId: 'gpt-5');
        await store.setGlobalDefaultModel(model);
        await store.setAgentModelOverride('agent.writer', model);
        final before = (await store.loadProvider('openai'))!;

        final result = await store.rotateCredential(
          providerId: 'openai',
          slot: ProviderCredentialSlot.primary,
          expectedRevision: before.revision,
          expectedOldRef: oldRef,
          newRef: newRef,
          replacement: ProviderConfigurationReplacement(
            config: ProviderConfig.openAI(enabled: false, secretRef: newRef),
            modelCatalog: null,
            modelBindings: ProviderModelBindingMutation(
              replaceGlobalDefault: true,
              agentOverrides: {'agent.writer': null},
            ),
          ),
        );

        final after = (await store.loadProvider('openai'))!;
        expect(after.config.secretRef, newRef);
        expect(after.config.enabled, isFalse);
        expect(after.revision.value, before.revision.value + 1);
        expect(result.oldRefForCleanup, oldRef);
        expect(result.newRevision, after.revision);
        expect(await store.loadGlobalDefaultModel(), isNull);
        expect(await store.loadAgentModelOverride('agent.writer'), isNull);

        await store.rollbackProviderMutation(result);
        final rolledBack = (await store.loadProvider('openai'))!;
        expect(rolledBack.config.secretRef, oldRef);
        expect(rolledBack.config.enabled, isTrue);
        expect(rolledBack.revision, before.revision);
        expect(await store.loadGlobalDefaultModel(), model);
        expect(await store.loadAgentModelOverride('agent.writer'), model);
        await expectLater(
          store.rollbackProviderMutation(result),
          throwsA(isA<ProviderConfigurationMutationException>()),
        );

        final raw = sqlite3.open(fixture.path);
        final ownership = raw.select('''
        SELECT secret_ref, state FROM credential_bindings
        WHERE provider_id = 'openai' AND credential_slot = 'primary'
        ORDER BY secret_ref
      ''');
        expect(ownership.map((row) => row['state']).toSet(), {
          'active',
          'retired',
        });
        raw.close();
      } finally {
        await store.close();
        fixture.delete();
      }
    },
  );

  test(
    'credential rotation is idempotent but rejects stale or foreign owners',
    () async {
      final fixture = _DatabaseFixture.create();
      final store = SqliteProviderConfigurationStore.open(fixture.path);
      final oldRef = SecretRef.parse(
        'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174000',
      );
      final newRef = SecretRef.parse(
        'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174001',
      );
      final foreignRef = SecretRef.parse(
        'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174002',
      );
      try {
        await store.upsert(ProviderConfig.openAI(secretRef: oldRef));
        await store.upsert(ProviderConfig.toApis(secretRef: foreignRef));
        final before = (await store.loadProvider('openai'))!;
        final first = await store.rotateCredential(
          providerId: 'openai',
          slot: ProviderCredentialSlot.primary,
          expectedRevision: before.revision,
          expectedOldRef: oldRef,
          newRef: newRef,
          replacement: ProviderConfigurationReplacement(
            config: ProviderConfig.openAI(secretRef: newRef),
            modelCatalog: null,
          ),
        );
        final retry = await store.rotateCredential(
          providerId: 'openai',
          slot: ProviderCredentialSlot.primary,
          expectedRevision: before.revision,
          expectedOldRef: oldRef,
          newRef: newRef,
          replacement: ProviderConfigurationReplacement(
            config: ProviderConfig.openAI(secretRef: newRef),
            modelCatalog: null,
          ),
        );
        expect(retry.newRevision, first.newRevision);

        await expectLater(
          store.rotateCredential(
            providerId: 'openai',
            slot: ProviderCredentialSlot.primary,
            expectedRevision: before.revision,
            expectedOldRef: oldRef,
            newRef: foreignRef,
            replacement: ProviderConfigurationReplacement(
              config: ProviderConfig.openAI(secretRef: foreignRef),
              modelCatalog: null,
            ),
          ),
          throwsA(isA<ProviderConfigurationMutationException>()),
        );
        await expectLater(
          store.rotateCredential(
            providerId: 'openai',
            slot: ProviderCredentialSlot.header('X-Api-Key'),
            expectedRevision: first.newRevision,
            expectedOldRef: newRef,
            newRef: oldRef,
            replacement: ProviderConfigurationReplacement(
              config: ProviderConfig.openAI(
                secretRef: newRef,
              ).copyWith(headerSecretRefs: {'x-api-key': oldRef}),
              modelCatalog: null,
            ),
          ),
          throwsA(isA<ProviderConfigurationMutationException>()),
        );
        expect((await store.loadProvider('openai'))!.config.secretRef, newRef);
        await store.markProviderMutationRuntimePublished(retry);
        await store.finalizeProviderMutation(retry);
      } finally {
        await store.close();
        fixture.delete();
      }
    },
  );

  test('idempotent mutation identity is bound to its operation kind', () async {
    final oldRef = SecretRef.parse(
      'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174000',
    );
    final newRef = SecretRef.parse(
      'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174001',
    );

    final rotationFixture = _DatabaseFixture.create();
    final rotationStore = SqliteProviderConfigurationStore.open(
      rotationFixture.path,
    );
    try {
      await rotationStore.upsert(ProviderConfig.openAI(secretRef: oldRef));
      final before = (await rotationStore.loadProvider('openai'))!;
      final rotation = await rotationStore.rotateCredential(
        providerId: 'openai',
        slot: ProviderCredentialSlot.primary,
        expectedRevision: before.revision,
        expectedOldRef: oldRef,
        newRef: newRef,
        replacement: ProviderConfigurationReplacement(
          config: ProviderConfig.openAI(secretRef: newRef),
          modelCatalog: null,
        ),
      );

      await expectLater(
        rotationStore.replaceProviderConfiguration(
          expectedRevision: before.revision,
          replacement: ProviderConfigurationReplacement(
            config: ProviderConfig.openAI(secretRef: newRef),
            modelCatalog: null,
          ),
        ),
        throwsA(
          isA<ProviderConfigurationMutationException>().having(
            (error) => error.code,
            'code',
            ProviderConfigurationMutationErrorCode.conflict,
          ),
        ),
      );
      expect(rotation.oldRefForCleanup, oldRef);
      expect(
        (await rotationStore.listPendingProviderOperations()).single.kind,
        PendingProviderOperationKind.rotate,
      );
      await rotationStore.rollbackProviderMutation(rotation);
    } finally {
      await rotationStore.close();
      rotationFixture.delete();
    }

    final replacementFixture = _DatabaseFixture.create();
    final replacementStore = SqliteProviderConfigurationStore.open(
      replacementFixture.path,
    );
    try {
      await replacementStore.upsert(ProviderConfig.openAI(secretRef: oldRef));
      final before = (await replacementStore.loadProvider('openai'))!;
      final replacement = await replacementStore.replaceProviderConfiguration(
        expectedRevision: before.revision,
        replacement: ProviderConfigurationReplacement(
          config: ProviderConfig.openAI(enabled: false, secretRef: oldRef),
          modelCatalog: null,
        ),
      );

      await expectLater(
        replacementStore.rotateCredential(
          providerId: 'openai',
          slot: ProviderCredentialSlot.primary,
          expectedRevision: before.revision,
          expectedOldRef: oldRef,
          newRef: newRef,
          replacement: ProviderConfigurationReplacement(
            config: ProviderConfig.openAI(enabled: false, secretRef: newRef),
            modelCatalog: null,
          ),
        ),
        throwsA(
          isA<ProviderConfigurationMutationException>().having(
            (error) => error.code,
            'code',
            ProviderConfigurationMutationErrorCode.conflict,
          ),
        ),
      );
      expect(
        (await replacementStore.listPendingProviderOperations()).single.kind,
        PendingProviderOperationKind.replace,
      );
      await replacementStore.rollbackProviderMutation(replacement);
    } finally {
      await replacementStore.close();
      replacementFixture.delete();
    }
  });

  test('create and replace retry only their matching operation kind', () async {
    final fixture = _DatabaseFixture.create();
    final store = SqliteProviderConfigurationStore.open(fixture.path);
    try {
      final createPayload = ProviderConfigurationReplacement(
        config: ProviderConfig.openAI(),
        modelCatalog: null,
      );
      final create = await store.replaceProviderConfiguration(
        expectedRevision: null,
        replacement: createPayload,
      );
      final createRetry = await store.replaceProviderConfiguration(
        expectedRevision: null,
        replacement: createPayload,
      );
      expect(createRetry.operationId, create.operationId);
      expect(
        (await store.listPendingProviderOperations()).single.kind,
        PendingProviderOperationKind.create,
      );
      await expectLater(
        store.replaceProviderConfiguration(
          expectedRevision: create.newRevision,
          replacement: createPayload,
        ),
        throwsA(isA<ProviderConfigurationMutationException>()),
      );
      await store.rollbackProviderMutation(createRetry);

      await store.upsert(ProviderConfig.openAI());
      final before = (await store.loadProvider('openai'))!;
      final replacePayload = ProviderConfigurationReplacement(
        config: ProviderConfig.openAI(enabled: false),
        modelCatalog: null,
      );
      final replace = await store.replaceProviderConfiguration(
        expectedRevision: before.revision,
        replacement: replacePayload,
      );
      final replaceRetry = await store.replaceProviderConfiguration(
        expectedRevision: before.revision,
        replacement: replacePayload,
      );
      expect(replaceRetry.operationId, replace.operationId);
      expect(
        (await store.listPendingProviderOperations()).single.kind,
        PendingProviderOperationKind.replace,
      );
      await expectLater(
        store.replaceProviderConfiguration(
          expectedRevision: null,
          replacement: replacePayload,
        ),
        throwsA(isA<ProviderConfigurationMutationException>()),
      );
      await store.rollbackProviderMutation(replaceRetry);
    } finally {
      await store.close();
      fixture.delete();
    }
  });

  test(
    'pending mutation rejects legacy writes and never wedges next rotation',
    () async {
      final fixture = _DatabaseFixture.create();
      final store = SqliteProviderConfigurationStore.open(fixture.path);
      final oldRef = SecretRef.parse(
        'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174000',
      );
      final newRef = SecretRef.parse(
        'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174001',
      );
      try {
        await store.upsert(ProviderConfig.openAI(secretRef: oldRef));
        final before = (await store.loadProvider('openai'))!;
        final mutation = await store.rotateCredential(
          providerId: 'openai',
          slot: ProviderCredentialSlot.primary,
          expectedRevision: before.revision,
          expectedOldRef: oldRef,
          newRef: newRef,
          replacement: ProviderConfigurationReplacement(
            config: ProviderConfig.openAI(secretRef: newRef),
            modelCatalog: null,
          ),
        );

        for (final write in [
          store.upsert(
            ProviderConfig.openAI(enabled: false, secretRef: newRef),
          ),
          store.setGlobalDefaultModel(
            ModelRef(providerId: 'openai', modelId: 'gpt-5'),
          ),
          store.setAgentModelOverride(
            'agent.writer',
            ModelRef(providerId: 'openai', modelId: 'gpt-5'),
          ),
        ]) {
          await expectLater(
            write,
            throwsA(
              isA<ProviderConfigurationMutationException>().having(
                (error) => error.code,
                'code',
                ProviderConfigurationMutationErrorCode.conflict,
              ),
            ),
          );
        }

        await store.rollbackProviderMutation(mutation);
        final restored = (await store.loadProvider('openai'))!;
        final next = await store.rotateCredential(
          providerId: 'openai',
          slot: ProviderCredentialSlot.primary,
          expectedRevision: restored.revision,
          expectedOldRef: oldRef,
          newRef: newRef,
          replacement: ProviderConfigurationReplacement(
            config: ProviderConfig.openAI(secretRef: newRef),
            modelCatalog: null,
          ),
        );
        await store.markProviderMutationRuntimePublished(next);
        await store.finalizeProviderMutation(next);
        await store.setGlobalDefaultModel(
          ModelRef(providerId: 'openai', modelId: 'gpt-5'),
        );
      } finally {
        await store.close();
        fixture.delete();
      }
    },
  );

  test(
    'legacy writes recheck pending operations after acquiring the WAL write lock',
    () async {
      for (final action in ['upsert', 'remove', 'global', 'agent']) {
        final fixture = _DatabaseFixture.create();
        final setup = SqliteProviderConfigurationStore.open(fixture.path);
        await setup.upsert(ProviderConfig.openAI());
        await setup.close();

        final workerMessages = ReceivePort();
        final isolate = await Isolate.spawn(_legacyWriteWorker, [
          fixture.path,
          action,
          workerMessages.sendPort,
        ]);
        final messages = StreamIterator<Object?>(workerMessages);
        Database? writer;
        try {
          expect(await messages.moveNext(), isTrue);
          final ready = messages.current! as List<Object?>;
          expect(ready.first, 'ready');
          final commandPort = ready.last! as SendPort;

          writer = sqlite3.open(fixture.path);
          writer.execute('PRAGMA journal_mode = WAL');
          writer.execute('PRAGMA busy_timeout = 5000');
          writer.execute('BEGIN IMMEDIATE');
          writer.execute(
            '''
              INSERT INTO provider_configuration_mutations (
                lease_id, operation_id, provider_id, operation_kind,
                new_revision, created_at_ms, previous_snapshot_json,
                applied_config_json, applied_bindings_json
              ) VALUES (?, ?, 'pending', 'create', 1, 1, '{}', '{}', '[]')
            ''',
            ['a' * 64, 'b' * 64],
          );

          commandPort.send('run');
          await Future<void>.delayed(const Duration(milliseconds: 100));
          writer.execute('COMMIT');

          expect(await messages.moveNext(), isTrue);
          expect(
            messages.current,
            ['conflict'],
            reason: '$action must recheck after the staged write commits',
          );
        } finally {
          if (writer != null) {
            try {
              writer.execute('ROLLBACK');
            } on SqliteException {
              // The successful COMMIT leaves no transaction to roll back.
            }
            writer.close();
          }
          isolate.kill(priority: Isolate.immediate);
          await messages.cancel();
          workerMessages.close();
          fixture.delete();
        }
      }
    },
  );

  test(
    'remove lease restores config and model bindings exactly once',
    () async {
      final fixture = _DatabaseFixture.create();
      final store = SqliteProviderConfigurationStore.open(fixture.path);
      final ref = SecretRef.parse(
        'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174000',
      );
      try {
        await store.upsert(ProviderConfig.openAI(secretRef: ref));
        final model = ModelRef(providerId: 'openai', modelId: 'gpt-5');
        await store.setGlobalDefaultModel(model);
        await store.setAgentModelOverride('agent.writer', model);
        final before = (await store.loadProvider('openai'))!;

        final lease = await store.removeProviderAtomically(
          providerId: 'openai',
          expectedRevision: before.revision,
        );
        expect(await store.loadProvider('openai'), isNull);

        await store.restoreRemovedProvider(lease);
        final restored = (await store.loadProvider('openai'))!;
        expect(restored.config.secretRef, ref);
        expect(restored.revision, before.revision);
        expect(await store.loadGlobalDefaultModel(), model);
        expect(await store.loadAgentModelOverride('agent.writer'), model);
        await expectLater(
          store.restoreRemovedProvider(lease),
          throwsA(isA<ProviderConfigurationMutationException>()),
        );
      } finally {
        await store.close();
        fixture.delete();
      }
    },
  );

  test(
    'remove restore blocks conflicting writes rejects forgery and survives reopen',
    () async {
      final fixture = _DatabaseFixture.create();
      var store = SqliteProviderConfigurationStore.open(fixture.path);
      final ref = SecretRef.parse(
        'keychain://halo.provider/123e4567-e89b-42d3-a456-426614174000',
      );
      await store.upsert(ProviderConfig.openAI(secretRef: ref));
      final before = (await store.loadProvider('openai'))!;
      final lease = await store.removeProviderAtomically(
        providerId: 'openai',
        expectedRevision: before.revision,
      );
      await store.close();

      store = SqliteProviderConfigurationStore.open(fixture.path);
      await store.restoreRemovedProvider(lease);
      final second = await store.removeProviderAtomically(
        providerId: 'openai',
        expectedRevision: before.revision,
      );
      await expectLater(
        store.upsert(ProviderConfig.openAI(secretRef: ref)),
        throwsA(
          isA<ProviderConfigurationMutationException>().having(
            (error) => error.code,
            'code',
            ProviderConfigurationMutationErrorCode.conflict,
          ),
        ),
      );
      await expectLater(
        store.restoreRemovedProvider(
          _ForgedRemovalLease('openai', before.revision),
        ),
        throwsA(isA<ProviderConfigurationMutationException>()),
      );
      await store.restoreRemovedProvider(second);
      await store.upsert(ProviderConfig.openAI(secretRef: ref));
      await store.close();
      fixture.delete();
    },
  );
}

final class _ForgedRemovalLease implements ProviderRemovalLease {
  _ForgedRemovalLease(this.providerId, this.removedRevision)
    : operationId = PendingProviderOperationId.parse('f' * 64);

  @override
  final PendingProviderOperationId operationId;
  @override
  final String providerId;

  @override
  final ProviderConfigurationRevision removedRevision;
}

final class _ForgedMutationLease implements ProviderConfigurationMutationLease {
  _ForgedMutationLease(this.providerId, this.newRevision)
    : operationId = PendingProviderOperationId.parse('e' * 64);

  @override
  final PendingProviderOperationId operationId;
  @override
  final String providerId;

  @override
  final ProviderConfigurationRevision newRevision;
}

final class _DatabaseFixture {
  _DatabaseFixture._(this.directory, this.path);

  factory _DatabaseFixture.create() {
    final directory = Directory.systemTemp.createTempSync(
      'halo-provider-config-',
    );
    return _DatabaseFixture._(
      directory,
      '${directory.path}/provider_configuration.sqlite',
    );
  }

  final Directory directory;
  final String path;

  void delete() => directory.deleteSync(recursive: true);
}

PersistedProviderModelCatalog _deepSeekCatalog(DateTime discoveredAt) =>
    PersistedProviderModelCatalog(
      providerId: 'deepseek',
      models: [
        ModelDescriptor(
          ref: ModelRef(providerId: 'deepseek', modelId: 'deepseek-chat'),
          displayName: 'DeepSeek Chat',
          capabilities: const ModelCapabilities.text(maxOutputTokens: 8192),
        ),
        ModelDescriptor(
          ref: ModelRef(providerId: 'deepseek', modelId: 'deepseek-reasoner'),
          displayName: 'DeepSeek Reasoner',
          capabilities: const ModelCapabilities.text(
            systemMessages: false,
            maxOutputTokens: 65536,
            supportsTemperature: false,
          ),
        ),
      ],
      discoveredAt: discoveredAt,
    );

PersistedProviderModelCatalog _emptyDeepSeekCatalog(DateTime discoveredAt) =>
    PersistedProviderModelCatalog(
      providerId: 'deepseek',
      models: const [],
      discoveredAt: discoveredAt,
    );

void _createV3Database(String path) {
  final raw = sqlite3.open(path);
  raw.execute('PRAGMA foreign_keys = ON');
  raw.execute('''
    CREATE TABLE provider_configs (
      provider_id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      protocol TEXT NOT NULL,
      display_name TEXT NOT NULL,
      base_uri TEXT NOT NULL,
      enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
      secret_ref TEXT,
      allow_insecure_http INTEGER NOT NULL
        CHECK (allow_insecure_http IN (0, 1)),
      revision INTEGER NOT NULL CHECK (revision > 0)
    ) STRICT
  ''');
  raw.execute('''
    CREATE TABLE provider_header_secret_refs (
      provider_id TEXT NOT NULL
        REFERENCES provider_configs(provider_id) ON DELETE CASCADE,
      header_name TEXT NOT NULL,
      secret_ref TEXT NOT NULL,
      PRIMARY KEY (provider_id, header_name)
    ) STRICT
  ''');
  raw.execute('''
    CREATE TABLE model_bindings (
      scope TEXT NOT NULL CHECK (scope IN ('global', 'agent')),
      scope_id TEXT NOT NULL,
      provider_id TEXT NOT NULL
        REFERENCES provider_configs(provider_id) ON DELETE CASCADE,
      model_id TEXT NOT NULL,
      PRIMARY KEY (scope, scope_id),
      CHECK (
        (scope = 'global' AND scope_id = '') OR
        (scope = 'agent' AND length(scope_id) > 0)
      )
    ) STRICT
  ''');
  raw.execute('''
    CREATE TABLE credential_bindings (
      secret_ref TEXT PRIMARY KEY,
      provider_id TEXT NOT NULL,
      credential_slot TEXT NOT NULL,
      state TEXT NOT NULL CHECK (state IN ('active', 'retired')),
      retired_revision INTEGER,
      CHECK (
        credential_slot = 'primary' OR
        (
          substr(credential_slot, 1, 7) = 'header:' AND
          length(credential_slot) > 7 AND
          substr(credential_slot, 8)
            NOT GLOB '*[^!#\$%&''*+.^_`|~0-9a-z-]*'
        )
      ),
      CHECK (
        (state = 'active' AND retired_revision IS NULL) OR
        (
          state = 'retired' AND
          retired_revision IS NOT NULL AND
          retired_revision > 0
        )
      )
    ) STRICT
  ''');
  raw.execute('''
    CREATE UNIQUE INDEX credential_bindings_active_owner
    ON credential_bindings(provider_id, credential_slot)
    WHERE state = 'active'
  ''');
  raw.execute('''
    CREATE TABLE provider_removal_leases (
      lease_id TEXT PRIMARY KEY
        CHECK (length(lease_id) = 64 AND lease_id NOT GLOB '*[^0-9a-f]*'),
      operation_id TEXT NOT NULL UNIQUE
        CHECK (
          length(operation_id) = 64 AND
          operation_id NOT GLOB '*[^0-9a-f]*'
        ),
      provider_id TEXT NOT NULL UNIQUE,
      removed_revision INTEGER NOT NULL CHECK (removed_revision > 0),
      created_at_ms INTEGER NOT NULL CHECK (created_at_ms > 0),
      snapshot_json TEXT NOT NULL
    ) STRICT
  ''');
  raw.execute('''
    CREATE TABLE provider_configuration_mutations (
      lease_id TEXT PRIMARY KEY
        CHECK (length(lease_id) = 64 AND lease_id NOT GLOB '*[^0-9a-f]*'),
      operation_id TEXT NOT NULL UNIQUE
        CHECK (
          length(operation_id) = 64 AND
          operation_id NOT GLOB '*[^0-9a-f]*'
        ),
      provider_id TEXT NOT NULL UNIQUE,
      operation_kind TEXT NOT NULL
        CHECK (operation_kind IN ('create', 'replace', 'rotate')),
      new_revision INTEGER NOT NULL CHECK (new_revision > 0),
      created_at_ms INTEGER NOT NULL CHECK (created_at_ms > 0),
      previous_snapshot_json TEXT NOT NULL,
      applied_config_json TEXT NOT NULL,
      applied_bindings_json TEXT NOT NULL
    ) STRICT
  ''');
  raw.execute('''
    INSERT INTO provider_configs (
      provider_id, kind, protocol, display_name, base_uri, enabled,
      secret_ref, allow_insecure_http, revision
    ) VALUES (
      'deepseek', 'deepSeek', 'openAICompatible', 'DeepSeek',
      'https://api.deepseek.com/v1', 1, NULL, 0, 7
    )
  ''');
  raw.execute('''
    INSERT INTO model_bindings (scope, scope_id, provider_id, model_id)
    VALUES ('global', '', 'deepseek', 'deepseek-chat')
  ''');
  raw.execute('''
    INSERT INTO model_bindings (scope, scope_id, provider_id, model_id)
    VALUES ('agent', 'agent.writer', 'deepseek', 'deepseek-reasoner')
  ''');
  raw.execute('PRAGMA user_version = 3');
  raw.close();
}

void _createPreMetadataV4Database(String path, DateTime discoveredAt) {
  _createV3Database(path);
  final raw = sqlite3.open(path);
  raw.execute('PRAGMA foreign_keys = ON');
  raw.execute('''
    CREATE TABLE provider_models (
      provider_id TEXT NOT NULL
        REFERENCES provider_configs(provider_id) ON DELETE CASCADE,
      model_id TEXT NOT NULL CHECK (length(model_id) > 0),
      display_name TEXT NOT NULL CHECK (length(display_name) > 0),
      text_generation INTEGER NOT NULL
        CHECK (text_generation IN (0, 1)),
      system_messages INTEGER NOT NULL
        CHECK (system_messages IN (0, 1)),
      max_output_tokens INTEGER NOT NULL
        CHECK (max_output_tokens > 0 AND max_output_tokens <= 1000000),
      supports_temperature INTEGER NOT NULL
        CHECK (supports_temperature IN (0, 1)),
      discovered_at_ms INTEGER NOT NULL CHECK (discovered_at_ms > 0),
      PRIMARY KEY (provider_id, model_id)
    ) STRICT
  ''');
  raw.execute(
    '''
      INSERT INTO provider_models (
        provider_id, model_id, display_name, text_generation,
        system_messages, max_output_tokens, supports_temperature,
        discovered_at_ms
      ) VALUES ('deepseek', 'deepseek-chat', 'DeepSeek Chat',
                1, 1, 8192, 1, ?)
    ''',
    [discoveredAt.millisecondsSinceEpoch],
  );
  raw.execute(
    '''
      INSERT INTO provider_models (
        provider_id, model_id, display_name, text_generation,
        system_messages, max_output_tokens, supports_temperature,
        discovered_at_ms
      ) VALUES ('deepseek', 'deepseek-reasoner', 'DeepSeek Reasoner',
                1, 0, 65536, 0, ?)
    ''',
    [discoveredAt.millisecondsSinceEpoch],
  );
  raw.execute('PRAGMA user_version = 4');
  raw.close();
}

Future<void> _legacyWriteWorker(List<Object?> arguments) async {
  final path = arguments[0]! as String;
  final action = arguments[1]! as String;
  final resultPort = arguments[2]! as SendPort;
  final commandPort = ReceivePort();
  final store = SqliteProviderConfigurationStore.open(path);
  resultPort.send(['ready', commandPort.sendPort]);
  await commandPort.first;
  try {
    switch (action) {
      case 'upsert':
        await store.upsert(ProviderConfig.openAI(enabled: false));
        break;
      case 'remove':
        await store.remove('openai');
        break;
      case 'global':
        await store.setGlobalDefaultModel(
          ModelRef(providerId: 'openai', modelId: 'gpt-5'),
        );
        break;
      case 'agent':
        await store.setAgentModelOverride(
          'agent.writer',
          ModelRef(providerId: 'openai', modelId: 'gpt-5'),
        );
        break;
      default:
        throw StateError('Unknown legacy write action');
    }
    resultPort.send(['success']);
  } on ProviderConfigurationMutationException catch (error) {
    resultPort.send([error.code.name]);
  } on Object catch (error) {
    resultPort.send(['unexpected', error.runtimeType.toString()]);
  } finally {
    commandPort.close();
    await store.close();
  }
}
