import 'dart:async';
import 'dart:convert';

import 'package:halo_mobile/model_runtime/model_runtime_models.dart';
import 'package:halo_mobile/model_runtime/provider_config.dart';
import 'package:halo_mobile/model_runtime/provider_configuration_store.dart';
import 'package:halo_mobile/model_runtime/secret_ref.dart';
import 'package:sqlite3/sqlite3.dart';

final class SqliteProviderConfigurationStore
    implements ProviderConfigurationStore, ProviderModelCatalogStore {
  SqliteProviderConfigurationStore._(this._database) {
    _initialize();
  }

  factory SqliteProviderConfigurationStore.open(String path) {
    final database = sqlite3.open(path);
    try {
      return SqliteProviderConfigurationStore._(database);
    } on Object catch (error, stackTrace) {
      try {
        database.close();
      } on Object {
        // Cleanup must not replace the schema error.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  static const schemaVersion = 6;
  static const _providerConfigsSql = '''
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
    ''';
  static const _headerRefsSql = '''
      CREATE TABLE provider_header_secret_refs (
        provider_id TEXT NOT NULL
          REFERENCES provider_configs(provider_id) ON DELETE CASCADE,
        header_name TEXT NOT NULL,
        secret_ref TEXT NOT NULL,
        PRIMARY KEY (provider_id, header_name)
      ) STRICT
    ''';
  static const _modelBindingsSql = '''
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
    ''';
  static const _providerModelCatalogsSql = '''
      CREATE TABLE provider_model_catalogs (
        provider_id TEXT PRIMARY KEY
          REFERENCES provider_configs(provider_id) ON DELETE CASCADE,
        discovered_at_ms INTEGER NOT NULL CHECK (discovered_at_ms > 0)
      ) STRICT
    ''';
  static const _providerModelsSql = '''
      CREATE TABLE provider_models (
        provider_id TEXT NOT NULL
          REFERENCES provider_model_catalogs(provider_id) ON DELETE CASCADE,
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
    ''';
  static const _preMetadataProviderModelsSql = '''
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
    ''';
  static const _credentialBindingsSql = '''
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
    ''';
  static const _activeCredentialOwnerIndexSql = '''
      CREATE UNIQUE INDEX credential_bindings_active_owner
      ON credential_bindings(provider_id, credential_slot)
      WHERE state = 'active'
    ''';
  static const _removalLeasesSql = '''
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
        snapshot_json TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'staged'
          CHECK (state IN ('staged', 'runtimePublished'))
      ) STRICT
    ''';
  static const _mutationLeasesSql = '''
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
        applied_bindings_json TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'staged'
          CHECK (state IN ('staged', 'runtimePublished'))
      ) STRICT
    ''';

  /// Global model bindings for purposes other than text.
  ///
  /// Deliberately a separate table rather than a `purpose` column on
  /// `model_bindings`: that table is on the working text path (twenty query
  /// sites plus the strict schema validator) and carries per-expert overrides,
  /// while image and video defaults are global-only. Adding a dimension there
  /// would put the shipped text binding at risk for no gain.
  static const _purposeModelBindingsSql = '''
      CREATE TABLE purpose_model_bindings (
        purpose TEXT PRIMARY KEY CHECK (purpose IN ('image', 'video')),
        provider_id TEXT NOT NULL
          REFERENCES provider_configs(provider_id) ON DELETE CASCADE,
        model_id TEXT NOT NULL CHECK (length(model_id) > 0)
      ) STRICT
    ''';

  /// Services that are a credential and nothing else.
  ///
  /// Doubao speech, Doubao realtime audio and Vidu have no model catalogue to
  /// discover and no OpenAI-compatible chat endpoint, so they cannot be rows in
  /// `provider_configs` — that table requires a base URI, a protocol from a
  /// fixed enum, and a catalogue. Only the Keychain locator is stored here; key
  /// material never reaches SQLite.
  static const _serviceCredentialsSql = '''
      CREATE TABLE service_credentials (
        service_id TEXT PRIMARY KEY
          CHECK (length(service_id) > 0 AND service_id NOT GLOB '*[^a-z0-9-]*'),
        secret_ref TEXT NOT NULL,
        enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
        configured_at_ms INTEGER NOT NULL CHECK (configured_at_ms > 0)
      ) STRICT
    ''';

  final Database _database;
  final Map<String, PendingProviderOperationRecovery> _recoveredOperations = {};
  bool _closed = false;
  Future<void>? _closeFuture;

  void _initialize() {
    _database.execute('PRAGMA journal_mode = WAL');
    _database.execute('PRAGMA busy_timeout = 5000');
    _database.execute('PRAGMA foreign_keys = ON');
    _database.execute('BEGIN IMMEDIATE');
    try {
      final version =
          _database.select('PRAGMA user_version').single.values.first! as int;
      if (version == 0) {
        if (!_schemaIsEmpty()) {
          throw StateError('Unversioned provider configuration database');
        }
        _createSchema();
        _database.execute('PRAGMA user_version = $schemaVersion');
      } else if (version == 3) {
        _migrateV3ToV4();
        _migrateV4ToV5();
        _migrateV5ToV6();
        _database.execute('PRAGMA user_version = $schemaVersion');
      } else if (version == 4) {
        if (_isExactPreMetadataV4Schema()) {
          _migratePreMetadataV4ToFinalV4();
        }
        _migrateV4ToV5();
        _migrateV5ToV6();
        _database.execute('PRAGMA user_version = $schemaVersion');
      } else if (version == 5) {
        _migrateV5ToV6();
        _database.execute('PRAGMA user_version = $schemaVersion');
      } else if (version != schemaVersion) {
        if (version == 1 || version == 2) {
          throw StateError(
            'Provider configuration schema v$version requires explicit rebuild',
          );
        }
        throw StateError(
          'Unsupported provider configuration schema version $version',
        );
      }
      _validateSchema();
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  bool _schemaIsEmpty() => _database.select('''
    SELECT 1 FROM sqlite_master
    WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
    LIMIT 1
  ''').isEmpty;

  void _createSchema() {
    _database.execute(_providerConfigsSql);
    _database.execute(_headerRefsSql);
    _database.execute(_modelBindingsSql);
    _database.execute(_providerModelCatalogsSql);
    _database.execute(_providerModelsSql);
    _database.execute(_credentialBindingsSql);
    _database.execute(_activeCredentialOwnerIndexSql);
    _database.execute(_removalLeasesSql);
    _database.execute(_mutationLeasesSql);
    _database.execute(_purposeModelBindingsSql);
    _database.execute(_serviceCredentialsSql);
  }

  void _migrateV3ToV4() {
    _database.execute(_providerModelCatalogsSql);
    _database.execute(_providerModelsSql);
    final mutationRows = _database.select('''
      SELECT lease_id, previous_snapshot_json, applied_config_json
      FROM provider_configuration_mutations
    ''');
    for (final row in mutationRows) {
      final previous =
          jsonDecode(row['previous_snapshot_json']! as String)
              as Map<String, Object?>;
      previous['modelCatalog'] = null;
      final appliedConfig =
          jsonDecode(row['applied_config_json']! as String)
              as Map<String, Object?>;
      _database.execute(
        '''
          UPDATE provider_configuration_mutations
          SET previous_snapshot_json = ?, applied_config_json = ?
          WHERE lease_id = ?
        ''',
        [
          jsonEncode(previous),
          jsonEncode({'config': appliedConfig, 'modelCatalog': null}),
          row['lease_id'],
        ],
      );
    }
    final removalRows = _database.select('''
      SELECT lease_id, snapshot_json FROM provider_removal_leases
    ''');
    for (final row in removalRows) {
      final snapshot =
          jsonDecode(row['snapshot_json']! as String) as Map<String, Object?>;
      snapshot['modelCatalog'] = null;
      _database.execute(
        'UPDATE provider_removal_leases SET snapshot_json = ? '
        'WHERE lease_id = ?',
        [jsonEncode(snapshot), row['lease_id']],
      );
    }
  }

  void _migrateV4ToV5() {
    _database.execute(
      "ALTER TABLE provider_removal_leases ADD COLUMN state TEXT NOT NULL "
      "DEFAULT 'staged' CHECK (state IN ('staged', 'runtimePublished'))",
    );
    _database.execute(
      "ALTER TABLE provider_configuration_mutations "
      "ADD COLUMN state TEXT NOT NULL DEFAULT 'staged' "
      "CHECK (state IN ('staged', 'runtimePublished'))",
    );
  }

  /// Purely additive: two new tables, nothing existing is rewritten, so an
  /// install that only ever used the text default keeps working untouched.
  void _migrateV5ToV6() {
    _database.execute(_purposeModelBindingsSql);
    _database.execute(_serviceCredentialsSql);
  }

  bool _isExactPreMetadataV4Schema() {
    final v4RemovalLeasesSql = _removalLeasesSql.replaceFirst(
      ",\n        state TEXT NOT NULL DEFAULT 'staged'\n"
          "          CHECK (state IN ('staged', 'runtimePublished'))",
      '',
    );
    final v4MutationLeasesSql = _mutationLeasesSql.replaceFirst(
      ",\n        state TEXT NOT NULL DEFAULT 'staged'\n"
          "          CHECK (state IN ('staged', 'runtimePublished'))",
      '',
    );
    final expected = <String, ({String type, String sql})>{
      'provider_configs': (type: 'table', sql: _providerConfigsSql),
      'provider_header_secret_refs': (type: 'table', sql: _headerRefsSql),
      'model_bindings': (type: 'table', sql: _modelBindingsSql),
      'provider_models': (type: 'table', sql: _preMetadataProviderModelsSql),
      'credential_bindings': (type: 'table', sql: _credentialBindingsSql),
      'credential_bindings_active_owner': (
        type: 'index',
        sql: _activeCredentialOwnerIndexSql,
      ),
      'provider_removal_leases': (type: 'table', sql: v4RemovalLeasesSql),
      'provider_configuration_mutations': (
        type: 'table',
        sql: v4MutationLeasesSql,
      ),
    };
    final objects = _database.select('''
      SELECT type, name, sql FROM sqlite_master
      WHERE name NOT LIKE 'sqlite_%'
        AND type IN ('table', 'index', 'trigger', 'view')
    ''');
    if (objects.length != expected.length) return false;
    for (final row in objects) {
      final name = row['name'] as String?;
      final sql = row['sql'] as String?;
      final expectedObject = name == null ? null : expected[name];
      if (expectedObject == null ||
          row['type'] != expectedObject.type ||
          sql == null ||
          _normalizeSchemaSql(sql) != _normalizeSchemaSql(expectedObject.sql)) {
        return false;
      }
    }
    return true;
  }

  String _normalizeSchemaSql(String sql) {
    final normalized = StringBuffer();
    var insideLiteral = false;
    var pendingSpace = false;
    for (var index = 0; index < sql.length; index++) {
      final character = sql[index];
      if (insideLiteral) {
        normalized.write(character);
        if (character == "'") {
          if (index + 1 < sql.length && sql[index + 1] == "'") {
            normalized.write(sql[++index]);
          } else {
            insideLiteral = false;
          }
        }
        continue;
      }
      if (character == "'") {
        if (pendingSpace && normalized.isNotEmpty) normalized.write(' ');
        pendingSpace = false;
        insideLiteral = true;
        normalized.write(character);
        continue;
      }
      final codeUnit = character.codeUnitAt(0);
      final isWhitespace =
          codeUnit == 0x20 ||
          codeUnit == 0x09 ||
          codeUnit == 0x0a ||
          codeUnit == 0x0d;
      if (isWhitespace) {
        pendingSpace = normalized.isNotEmpty;
        continue;
      }
      if (pendingSpace && normalized.isNotEmpty) normalized.write(' ');
      pendingSpace = false;
      normalized.write(character.toLowerCase());
    }
    return normalized.toString();
  }

  void _migratePreMetadataV4ToFinalV4() {
    final catalogRows = _database.select('''
      SELECT provider_id, MIN(discovered_at_ms) AS discovered_at_ms,
             COUNT(DISTINCT discovered_at_ms) AS discovery_time_count
      FROM provider_models
      GROUP BY provider_id
      ORDER BY provider_id
    ''');
    if (catalogRows.any((row) => row['discovery_time_count'] != 1)) {
      throw StateError('Invalid persisted provider model catalog');
    }
    _database.execute(_providerModelCatalogsSql);
    for (final row in catalogRows) {
      _database.execute(
        '''
          INSERT INTO provider_model_catalogs (provider_id, discovered_at_ms)
          VALUES (?, ?)
        ''',
        [row['provider_id'], row['discovered_at_ms']],
      );
    }
    _database.execute(
      'ALTER TABLE provider_models '
      'RENAME TO provider_models_pre_metadata_v4',
    );
    _database.execute(_providerModelsSql);
    _database.execute('''
      INSERT INTO provider_models (
        provider_id, model_id, display_name, text_generation,
        system_messages, max_output_tokens, supports_temperature,
        discovered_at_ms
      )
      SELECT provider_id, model_id, display_name, text_generation,
             system_messages, max_output_tokens, supports_temperature,
             discovered_at_ms
      FROM provider_models_pre_metadata_v4
    ''');
    _database.execute('DROP TABLE provider_models_pre_metadata_v4');
  }

  void _validateSchema() {
    const expected = {
      'provider_configs',
      'provider_header_secret_refs',
      'model_bindings',
      'provider_model_catalogs',
      'provider_models',
      'credential_bindings',
      'credential_bindings_active_owner',
      'provider_removal_leases',
      'provider_configuration_mutations',
      'purpose_model_bindings',
      'service_credentials',
    };
    final objects = _database.select('''
      SELECT type, name FROM sqlite_master
      WHERE name NOT LIKE 'sqlite_%'
        AND type IN ('table', 'index', 'trigger', 'view')
      ORDER BY type, name
    ''');
    if (objects.length != expected.length) {
      throw StateError('Invalid provider configuration schema');
    }
    for (final row in objects) {
      final name = row['name'] as String?;
      final expectedType = name == 'credential_bindings_active_owner'
          ? 'index'
          : 'table';
      if (row['type'] != expectedType ||
          name == null ||
          !expected.contains(name)) {
        throw StateError('Invalid provider configuration schema');
      }
    }
    _validatePragmaStructure();
    _validateConstraintBehavior();
  }

  void _validatePragmaStructure() {
    const columns = {
      'provider_configs': [
        ('provider_id', 'TEXT', 1, 1),
        ('kind', 'TEXT', 1, 0),
        ('protocol', 'TEXT', 1, 0),
        ('display_name', 'TEXT', 1, 0),
        ('base_uri', 'TEXT', 1, 0),
        ('enabled', 'INTEGER', 1, 0),
        ('secret_ref', 'TEXT', 0, 0),
        ('allow_insecure_http', 'INTEGER', 1, 0),
        ('revision', 'INTEGER', 1, 0),
      ],
      'provider_header_secret_refs': [
        ('provider_id', 'TEXT', 1, 1),
        ('header_name', 'TEXT', 1, 2),
        ('secret_ref', 'TEXT', 1, 0),
      ],
      'model_bindings': [
        ('scope', 'TEXT', 1, 1),
        ('scope_id', 'TEXT', 1, 2),
        ('provider_id', 'TEXT', 1, 0),
        ('model_id', 'TEXT', 1, 0),
      ],
      'provider_model_catalogs': [
        ('provider_id', 'TEXT', 1, 1),
        ('discovered_at_ms', 'INTEGER', 1, 0),
      ],
      'purpose_model_bindings': [
        ('purpose', 'TEXT', 1, 1),
        ('provider_id', 'TEXT', 1, 0),
        ('model_id', 'TEXT', 1, 0),
      ],
      'service_credentials': [
        ('service_id', 'TEXT', 1, 1),
        ('secret_ref', 'TEXT', 1, 0),
        ('enabled', 'INTEGER', 1, 0),
        ('configured_at_ms', 'INTEGER', 1, 0),
      ],
      'provider_models': [
        ('provider_id', 'TEXT', 1, 1),
        ('model_id', 'TEXT', 1, 2),
        ('display_name', 'TEXT', 1, 0),
        ('text_generation', 'INTEGER', 1, 0),
        ('system_messages', 'INTEGER', 1, 0),
        ('max_output_tokens', 'INTEGER', 1, 0),
        ('supports_temperature', 'INTEGER', 1, 0),
        ('discovered_at_ms', 'INTEGER', 1, 0),
      ],
      'credential_bindings': [
        ('secret_ref', 'TEXT', 1, 1),
        ('provider_id', 'TEXT', 1, 0),
        ('credential_slot', 'TEXT', 1, 0),
        ('state', 'TEXT', 1, 0),
        ('retired_revision', 'INTEGER', 0, 0),
      ],
      'provider_removal_leases': [
        ('lease_id', 'TEXT', 1, 1),
        ('operation_id', 'TEXT', 1, 0),
        ('provider_id', 'TEXT', 1, 0),
        ('removed_revision', 'INTEGER', 1, 0),
        ('created_at_ms', 'INTEGER', 1, 0),
        ('snapshot_json', 'TEXT', 1, 0),
        ('state', 'TEXT', 1, 0),
      ],
      'provider_configuration_mutations': [
        ('lease_id', 'TEXT', 1, 1),
        ('operation_id', 'TEXT', 1, 0),
        ('provider_id', 'TEXT', 1, 0),
        ('operation_kind', 'TEXT', 1, 0),
        ('new_revision', 'INTEGER', 1, 0),
        ('created_at_ms', 'INTEGER', 1, 0),
        ('previous_snapshot_json', 'TEXT', 1, 0),
        ('applied_config_json', 'TEXT', 1, 0),
        ('applied_bindings_json', 'TEXT', 1, 0),
        ('state', 'TEXT', 1, 0),
      ],
    };
    for (final entry in columns.entries) {
      final rows = _database.select('PRAGMA table_xinfo(${entry.key})');
      if (rows.length != entry.value.length) {
        throw StateError('Invalid provider configuration schema');
      }
      for (var index = 0; index < rows.length; index++) {
        final expected = entry.value[index];
        final row = rows[index];
        if (row['name'] != expected.$1 ||
            row['type'] != expected.$2 ||
            row['notnull'] != expected.$3 ||
            row['pk'] != expected.$4 ||
            (expected.$1 == 'state' &&
                    (entry.key == 'provider_removal_leases' ||
                        entry.key == 'provider_configuration_mutations')
                ? row['dflt_value'] != "'staged'"
                : row['dflt_value'] != null) ||
            row['hidden'] != 0) {
          throw StateError('Invalid provider configuration schema');
        }
      }
    }
    const expectedForeignKeys = {
      'provider_header_secret_refs': 'provider_configs',
      'model_bindings': 'provider_configs',
      'provider_model_catalogs': 'provider_configs',
      'provider_models': 'provider_model_catalogs',
      'purpose_model_bindings': 'provider_configs',
    };
    for (final entry in expectedForeignKeys.entries) {
      final table = entry.key;
      final foreignKeys = _database.select('PRAGMA foreign_key_list($table)');
      if (foreignKeys.length != 1 ||
          foreignKeys.single['table'] != entry.value ||
          foreignKeys.single['from'] != 'provider_id' ||
          foreignKeys.single['to'] != 'provider_id' ||
          foreignKeys.single['on_delete'] != 'CASCADE') {
        throw StateError('Invalid provider configuration schema');
      }
    }
    if (_database
        .select('PRAGMA foreign_key_list(credential_bindings)')
        .isNotEmpty) {
      throw StateError('Invalid provider configuration schema');
    }
    const indexOrigins = {
      'provider_configs': ['pk'],
      'provider_header_secret_refs': ['pk'],
      'model_bindings': ['pk'],
      'provider_model_catalogs': ['pk'],
      'provider_models': ['pk'],
      'purpose_model_bindings': ['pk'],
      'service_credentials': ['pk'],
      'credential_bindings': ['c', 'pk'],
      'provider_removal_leases': ['pk', 'u', 'u'],
      'provider_configuration_mutations': ['pk', 'u', 'u'],
    };
    for (final entry in indexOrigins.entries) {
      final rows = _database.select('PRAGMA index_list(${entry.key})');
      final origins = rows.map((row) => row['origin'] as String).toList()
        ..sort();
      final expected = [...entry.value]..sort();
      if (origins.join(',') != expected.join(',') ||
          rows.any((row) => row['unique'] != 1) ||
          (entry.key == 'credential_bindings'
              ? rows.where((row) => row['partial'] == 1).length != 1
              : rows.any((row) => row['partial'] != 0))) {
        throw StateError('Invalid provider configuration schema');
      }
    }
    const expectedIndexColumns = {
      'provider_configs': {'provider_id'},
      'provider_header_secret_refs': {'provider_id,header_name'},
      'model_bindings': {'scope,scope_id'},
      'provider_model_catalogs': {'provider_id'},
      'provider_models': {'provider_id,model_id'},
      'purpose_model_bindings': {'purpose'},
      'service_credentials': {'service_id'},
      'credential_bindings': {'secret_ref', 'provider_id,credential_slot'},
      'provider_removal_leases': {'lease_id', 'operation_id', 'provider_id'},
      'provider_configuration_mutations': {
        'lease_id',
        'operation_id',
        'provider_id',
      },
    };
    for (final entry in expectedIndexColumns.entries) {
      final actual = <String>{};
      for (final index in _database.select('PRAGMA index_list(${entry.key})')) {
        final name = index['name']! as String;
        final columns = _database
            .select('PRAGMA index_xinfo("$name")')
            .where((row) => row['key'] == 1)
            .map((row) => row['name'] as String)
            .join(',');
        actual.add(columns);
      }
      if (actual.length != entry.value.length ||
          !actual.containsAll(entry.value)) {
        throw StateError('Invalid provider configuration schema');
      }
    }
    final tables = {
      for (final row in _database.select('PRAGMA table_list'))
        if (expectedIndexColumns.containsKey(row['name']))
          row['name'] as String: row,
    };
    if (tables.length != expectedIndexColumns.length ||
        tables.values.any((row) => row['strict'] != 1)) {
      throw StateError('Invalid provider configuration schema');
    }
  }

  void _validateConstraintBehavior() {
    _database.execute('SAVEPOINT validate_constraints');
    try {
      _expectConstraintFailure('''
        INSERT INTO provider_configs (
          provider_id, kind, protocol, display_name, base_uri, enabled,
          secret_ref, allow_insecure_http, revision
        ) VALUES ('probe', 'toApis', 'openAICompatible', 'Probe',
                  'https://example.invalid/v1', 2, NULL, 0, 1)
      ''');
      _expectConstraintFailure('''
        INSERT INTO provider_configs (
          provider_id, kind, protocol, display_name, base_uri, enabled,
          secret_ref, allow_insecure_http, revision
        ) VALUES ('probe', 'toApis', 'openAICompatible', 'Probe',
                  'https://example.invalid/v1', 1, NULL, 2, 1)
      ''');
      _expectConstraintFailure('''
        INSERT INTO provider_configs (
          provider_id, kind, protocol, display_name, base_uri, enabled,
          secret_ref, allow_insecure_http, revision
        ) VALUES ('bad-revision', 'toApis', 'openAICompatible', 'Probe',
                  'https://example.invalid/v1', 1, NULL, 0, 0)
      ''');
      _database.execute('''
        INSERT INTO provider_configs (
          provider_id, kind, protocol, display_name, base_uri, enabled,
          secret_ref, allow_insecure_http, revision
        ) VALUES ('probe', 'toApis', 'openAICompatible', 'Probe',
                  'https://example.invalid/v1', 1, NULL, 0, 1)
      ''');
      _expectConstraintFailure('''
        INSERT INTO provider_model_catalogs (provider_id, discovered_at_ms)
        VALUES ('probe', 0)
      ''');
      _expectConstraintFailure('''
        INSERT INTO provider_model_catalogs (provider_id, discovered_at_ms)
        VALUES ('missing-provider', 1)
      ''');
      _expectConstraintSuccess('''
        INSERT INTO provider_model_catalogs (provider_id, discovered_at_ms)
        VALUES ('probe', 1)
      ''');
      _expectConstraintFailure('''
        INSERT INTO provider_model_catalogs (provider_id, discovered_at_ms)
        VALUES ('probe', 2)
      ''');
      _expectConstraintSuccess('''
        INSERT INTO provider_models (
          provider_id, model_id, display_name, text_generation,
          system_messages, max_output_tokens, supports_temperature,
          discovered_at_ms
        ) VALUES ('probe', 'model', 'Model', 1, 1, 16384, 1, 1)
      ''');
      for (final (index, values) in <List<Object?>>[
        ['probe', '', 'Model', 1, 1, 16384, 1, 1],
        ['probe', 'empty-name', '', 1, 1, 16384, 1, 1],
        ['probe', 'bad-text', 'Model', 2, 1, 16384, 1, 1],
        ['probe', 'bad-system', 'Model', 1, -1, 16384, 1, 1],
        ['probe', 'bad-tokens-low', 'Model', 1, 1, 0, 1, 1],
        ['probe', 'bad-tokens-high', 'Model', 1, 1, 1000001, 1, 1],
        ['probe', 'bad-temperature', 'Model', 1, 1, 16384, 2, 1],
        ['probe', 'bad-time', 'Model', 1, 1, 16384, 1, 0],
        ['missing-provider', 'model', 'Model', 1, 1, 16384, 1, 1],
      ].indexed) {
        _expectConstraintFailure('''
            INSERT INTO provider_models (
              provider_id, model_id, display_name, text_generation,
              system_messages, max_output_tokens, supports_temperature,
              discovered_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          ''', values);
        if (index == 0) {
          _expectConstraintFailure('''
            INSERT INTO provider_models (
              provider_id, model_id, display_name, text_generation,
              system_messages, max_output_tokens, supports_temperature,
              discovered_at_ms
            ) VALUES ('probe', 'model', 'Duplicate', 1, 1, 16384, 1, 1)
          ''');
        }
      }
      _expectConstraintFailure('''
        INSERT INTO model_bindings (scope, scope_id, provider_id, model_id)
        VALUES ('GLOBAL', '', 'probe', 'model')
      ''');
      _expectConstraintFailure('''
        INSERT INTO model_bindings (scope, scope_id, provider_id, model_id)
        VALUES ('global', 'not-empty', 'probe', 'model')
      ''');
      _expectConstraintFailure('''
        INSERT INTO model_bindings (scope, scope_id, provider_id, model_id)
        VALUES ('agent', '', 'probe', 'model')
      ''');
      _expectConstraintFailure('''
        INSERT INTO model_bindings (scope, scope_id, provider_id, model_id)
        VALUES ('owner', 'agent.one', 'probe', 'model')
      ''');
      _expectConstraintFailure('''
        INSERT INTO credential_bindings (
          secret_ref, provider_id, credential_slot
          , state, retired_revision
        ) VALUES ('keychain://probe/one', 'probe', 'header:INVALID',
                  'active', NULL)
      ''');
      for (final (index, slot) in <String>[
        '',
        'header:',
        'header::',
        'header:x:evil',
        'header:UPPER',
        'header:x\r\nbad',
        'x',
        'primary:extra',
      ].indexed) {
        _expectConstraintFailure(
          '''
            INSERT INTO credential_bindings (
              secret_ref, provider_id, credential_slot,
              state, retired_revision
            ) VALUES ('keychain://probe/invalid-$index', 'probe', ?,
                      'retired', 1)
          ''',
          [slot],
        );
      }
      _database.execute('''
        INSERT INTO credential_bindings (
          secret_ref, provider_id, credential_slot, state, retired_revision
        ) VALUES ('keychain://probe/valid-edge', 'probe', 'header:x_api-key',
                  'retired', 1)
      ''');
      _expectConstraintSuccess('''
        INSERT INTO credential_bindings (
          secret_ref, provider_id, credential_slot, state, retired_revision
        ) VALUES ('keychain://probe/valid-retired-two', 'probe',
                  'header:x_api-key', 'retired', 2)
      ''');
      _database.execute('''
        INSERT INTO credential_bindings (
          secret_ref, provider_id, credential_slot, state, retired_revision
        ) VALUES ('keychain://probe/active-one', 'probe', 'primary',
                  'active', NULL)
      ''');
      _expectConstraintFailure('''
        INSERT INTO credential_bindings (
          secret_ref, provider_id, credential_slot, state, retired_revision
        ) VALUES ('keychain://probe/active-two', 'probe', 'primary',
                  'active', NULL)
      ''');
      _expectConstraintFailure('''
        INSERT INTO credential_bindings (
          secret_ref, provider_id, credential_slot, state, retired_revision
        ) VALUES ('keychain://probe/two', 'probe', 'primary',
                  'retired', NULL)
      ''');
      _expectConstraintFailure('''
        INSERT INTO credential_bindings (
          secret_ref, provider_id, credential_slot, state, retired_revision
        ) VALUES ('keychain://probe/three', 'probe', 'header:x',
                  'active', 1)
      ''');
      _expectConstraintFailure('''
        INSERT INTO credential_bindings (
          secret_ref, provider_id, credential_slot, state, retired_revision
        ) VALUES ('keychain://probe/four', 'probe', 'header:x',
                  'retired', 0)
      ''');
      _expectConstraintFailure('''
        INSERT INTO credential_bindings (
          secret_ref, provider_id, credential_slot, state, retired_revision
        ) VALUES ('keychain://probe/five', 'probe', 'header:x',
                  'unknown', NULL)
      ''');
      final hexA = 'a' * 64;
      final hexB = 'b' * 64;
      final hexC = 'c' * 64;
      final hexD = 'd' * 64;
      final hexE = 'e' * 64;
      _expectConstraintSuccess(
        '''
          INSERT INTO provider_configuration_mutations (
            lease_id, operation_id, provider_id, operation_kind,
            new_revision, created_at_ms, previous_snapshot_json,
            applied_config_json, applied_bindings_json
          ) VALUES (?, ?, 'mutation-valid', 'create', 1, 1, '{}', '{}', '[]')
        ''',
        [hexA, hexB],
      );
      _expectConstraintFailure(
        '''
          INSERT INTO provider_configuration_mutations (
            lease_id, operation_id, provider_id, operation_kind,
            new_revision, created_at_ms, previous_snapshot_json,
            applied_config_json, applied_bindings_json, state
          ) VALUES (?, ?, 'mutation-bad-state', 'create', 1, 1,
                    '{}', '{}', '[]', 'pending')
        ''',
        ['5' * 64, '6' * 64],
      );
      for (final invalidLease in [
        '',
        'a' * 63,
        '${'a' * 63}A',
        '${'a' * 63}g',
      ]) {
        _expectConstraintFailure(
          '''
            INSERT INTO provider_configuration_mutations (
              lease_id, operation_id, provider_id, operation_kind,
              new_revision, created_at_ms, previous_snapshot_json,
              applied_config_json, applied_bindings_json
            ) VALUES (?, ?, 'mutation-bad-lease', 'create', 1, 1,
                      '{}', '{}', '[]')
          ''',
          [invalidLease, hexC],
        );
      }
      for (final invalidOperationId in [
        '',
        'b' * 63,
        '${'b' * 63}B',
        '${'b' * 63}g',
      ]) {
        _expectConstraintFailure(
          '''
            INSERT INTO provider_configuration_mutations (
              lease_id, operation_id, provider_id, operation_kind,
              new_revision, created_at_ms, previous_snapshot_json,
              applied_config_json, applied_bindings_json
            ) VALUES (?, ?, 'mutation-bad-operation', 'create', 1, 1,
                      '{}', '{}', '[]')
          ''',
          [hexD, invalidOperationId],
        );
      }
      for (final (kind, leaseId, operationId) in [
        ('replace', '1' * 64, '2' * 64),
        ('rotate', '3' * 64, '4' * 64),
      ]) {
        _expectConstraintSuccess(
          '''
            INSERT INTO provider_configuration_mutations (
              lease_id, operation_id, provider_id, operation_kind,
              new_revision, created_at_ms, previous_snapshot_json,
              applied_config_json, applied_bindings_json
            ) VALUES (?, ?, ?, ?, 1, 1, '{}', '{}', '[]')
          ''',
          [leaseId, operationId, 'mutation-valid-$kind', kind],
        );
      }
      for (final (index, invalidKind) in [
        '',
        'remove',
        'unknown',
        'CREATE',
        'replace ',
      ].indexed) {
        _expectConstraintFailure(
          '''
            INSERT INTO provider_configuration_mutations (
              lease_id, operation_id, provider_id, operation_kind,
              new_revision, created_at_ms, previous_snapshot_json,
              applied_config_json, applied_bindings_json
            ) VALUES (?, ?, ?, ?, 1, 1, '{}', '{}', '[]')
          ''',
          [
            (index + 10).toRadixString(16).padLeft(64, '0'),
            (index + 20).toRadixString(16).padLeft(64, '0'),
            'mutation-invalid-kind-$index',
            invalidKind,
          ],
        );
      }
      for (final (providerId, kind, revision, createdAt) in [
        ('mutation-revision', 'create', 0, 1),
        ('mutation-created', 'rotate', 1, 0),
      ]) {
        _expectConstraintFailure(
          '''
            INSERT INTO provider_configuration_mutations (
              lease_id, operation_id, provider_id, operation_kind,
              new_revision, created_at_ms, previous_snapshot_json,
              applied_config_json, applied_bindings_json
            ) VALUES (?, ?, ?, ?, ?, ?, '{}', '{}', '[]')
          ''',
          [
            providerId.codeUnits.first.toRadixString(16).padLeft(64, '0'),
            (providerId.codeUnits.first + 1).toRadixString(16).padLeft(64, '0'),
            providerId,
            kind,
            revision,
            createdAt,
          ],
        );
      }
      _expectConstraintSuccess(
        '''
          INSERT INTO provider_removal_leases (
            lease_id, operation_id, provider_id, removed_revision,
            created_at_ms, snapshot_json
          ) VALUES (?, ?, 'removal-valid', 1, 1, '{}')
        ''',
        [hexC, hexD],
      );
      _expectConstraintFailure(
        '''
          INSERT INTO provider_removal_leases (
            lease_id, operation_id, provider_id, removed_revision,
            created_at_ms, snapshot_json, state
          ) VALUES (?, ?, 'removal-bad-state', 1, 1, '{}', 'pending')
        ''',
        ['7' * 64, '8' * 64],
      );
      for (final (index, invalidLeaseId) in [
        '',
        'e' * 63,
        '${'e' * 63}E',
        '${'e' * 63}g',
      ].indexed) {
        _expectConstraintFailure(
          '''
            INSERT INTO provider_removal_leases (
              lease_id, operation_id, provider_id, removed_revision,
              created_at_ms, snapshot_json
            ) VALUES (?, ?, ?, 1, 1, '{}')
          ''',
          [
            invalidLeaseId,
            (index + 30).toRadixString(16).padLeft(64, '0'),
            'removal-invalid-lease-$index',
          ],
        );
      }
      for (final (index, invalidOperationId) in [
        '',
        'f' * 63,
        '${'f' * 63}F',
        '${'f' * 63}g',
      ].indexed) {
        _expectConstraintFailure(
          '''
            INSERT INTO provider_removal_leases (
              lease_id, operation_id, provider_id, removed_revision,
              created_at_ms, snapshot_json
            ) VALUES (?, ?, ?, 1, 1, '{}')
          ''',
          [
            (index + 40).toRadixString(16).padLeft(64, '0'),
            invalidOperationId,
            'removal-invalid-operation-$index',
          ],
        );
      }
      for (final (providerId, leaseId, operationId, revision, createdAt) in [
        ('removal-revision', hexE, '0' * 64, 0, 1),
        ('removal-created', '1' * 64, '2' * 64, 1, 0),
      ]) {
        _expectConstraintFailure(
          '''
            INSERT INTO provider_removal_leases (
              lease_id, operation_id, provider_id, removed_revision,
              created_at_ms, snapshot_json
            ) VALUES (?, ?, ?, ?, ?, '{}')
          ''',
          [leaseId, operationId, providerId, revision, createdAt],
        );
      }
    } finally {
      _database.execute('ROLLBACK TO validate_constraints');
      _database.execute('RELEASE validate_constraints');
    }
  }

  void _expectConstraintFailure(
    String sql, [
    List<Object?> parameters = const [],
  ]) {
    try {
      _database.execute(sql, parameters);
    } on SqliteException {
      return;
    }
    throw StateError('Invalid provider configuration schema');
  }

  void _expectConstraintSuccess(
    String sql, [
    List<Object?> parameters = const [],
  ]) {
    try {
      _database.execute(sql, parameters);
    } on SqliteException {
      throw StateError('Invalid provider configuration schema');
    }
  }

  @override
  Future<List<ProviderConfig>> loadEnabled() => _loadConfigs(enabledOnly: true);

  @override
  Future<List<ProviderConfig>> loadAll() => _loadConfigs(enabledOnly: false);

  @override
  Future<PersistedProviderModelCatalog?> loadProviderModelCatalog(
    String providerId,
  ) => Future.sync(() {
    _requireOpen();
    return _loadProviderModelCatalogSync(
      _requiredIdentifier(providerId, 'providerId'),
    );
  });

  @override
  Future<List<PersistedProviderModelCatalog>> loadAllProviderModelCatalogs() =>
      Future.sync(() {
        _requireOpen();
        final providerIds = _database.select('''
      SELECT provider_id FROM provider_model_catalogs ORDER BY provider_id
    ''');
        return List.unmodifiable([
          for (final row in providerIds)
            _loadProviderModelCatalogSync(row['provider_id']! as String)!,
        ]);
      });

  PersistedProviderModelCatalog? _loadProviderModelCatalogSync(
    String providerId,
  ) {
    final catalogRows = _database.select(
      '''
        SELECT provider_id, discovered_at_ms
        FROM provider_model_catalogs
        WHERE provider_id = ?
      ''',
      [providerId],
    );
    if (catalogRows.isEmpty) return null;
    final rows = _database.select(
      '''
        SELECT provider_id, model_id, display_name, text_generation,
               system_messages, max_output_tokens, supports_temperature,
               discovered_at_ms
        FROM provider_models
        WHERE provider_id = ?
        ORDER BY model_id
      ''',
      [providerId],
    );
    try {
      if (catalogRows.length != 1 ||
          catalogRows.single['provider_id'] != providerId) {
        throw const FormatException();
      }
      final discoveredAtMs = catalogRows.single['discovered_at_ms']! as int;
      if (rows.any(
        (row) =>
            row['provider_id'] != providerId ||
            row['discovered_at_ms'] != discoveredAtMs,
      )) {
        throw const FormatException();
      }
      return PersistedProviderModelCatalog(
        providerId: providerId,
        models: [
          for (final row in rows)
            ModelDescriptor(
              ref: ModelRef(
                providerId: providerId,
                modelId: row['model_id']! as String,
              ),
              displayName: row['display_name']! as String,
              capabilities: ModelCapabilities(
                textGeneration: _decodeSqliteBoolean(row['text_generation']),
                systemMessages: _decodeSqliteBoolean(row['system_messages']),
                maxOutputTokens: row['max_output_tokens']! as int,
                supportsTemperature: _decodeSqliteBoolean(
                  row['supports_temperature'],
                ),
              ),
            ),
        ],
        discoveredAt: DateTime.fromMillisecondsSinceEpoch(
          discoveredAtMs,
          isUtc: true,
        ),
      );
    } on Object {
      throw StateError('Invalid persisted provider model catalog');
    }
  }

  bool _decodeSqliteBoolean(Object? value) {
    if (value == 0) return false;
    if (value == 1) return true;
    throw const FormatException();
  }

  @override
  Future<VersionedProviderConfiguration?> loadProvider(String providerId) =>
      Future.sync(() {
        _requireOpen();
        final normalized = _requiredIdentifier(providerId, 'providerId');
        final rows = _database.select(
          '''
            SELECT provider_id, kind, protocol, display_name, base_uri,
                   enabled, secret_ref, allow_insecure_http, revision
            FROM provider_configs WHERE provider_id = ?
          ''',
          [normalized],
        );
        if (rows.isEmpty) return null;
        final row = rows.single;
        return VersionedProviderConfiguration(
          config: _decodeConfig(row),
          revision: ProviderConfigurationRevision(row['revision']! as int),
        );
      });

  @override
  Future<ProviderConfigurationReplacementResult> replaceProviderConfiguration({
    required ProviderConfigurationRevision? expectedRevision,
    required ProviderConfigurationReplacement replacement,
  }) => Future.sync(() {
    _requireOpen();
    final config = replacement.config;
    final modelCatalog = replacement.modelCatalog;
    if (modelCatalog != null && modelCatalog.providerId != config.providerId) {
      throw const ProviderConfigurationMutationException(
        ProviderConfigurationMutationErrorCode.conflict,
      );
    }
    for (final ref in providerCredentialBindings(config).values) {
      ProviderSecretRefPolicy.validate(ref);
    }
    _database.execute('BEGIN IMMEDIATE');
    try {
      final existing = _database.select(
        '''
          SELECT provider_id, kind, protocol, display_name, base_uri, enabled,
                 secret_ref, allow_insecure_http, revision
          FROM provider_configs WHERE provider_id = ?
        ''',
        [config.providerId],
      );
      final previousBindings = _encodeAllModelBindings();
      final previousConfig = existing.isEmpty
          ? null
          : _decodeConfig(existing.single);
      final previousCatalog = _loadProviderModelCatalogSync(config.providerId);
      final previousRevision = existing.isEmpty
          ? null
          : ProviderConfigurationRevision(existing.single['revision']! as int);
      final retryIdentity = _idempotentReplacementIdentity(
        config: config,
        expectedRevision: expectedRevision,
        currentConfig: previousConfig,
        currentRevision: previousRevision,
        modelBindings: replacement.modelBindings,
        modelCatalog: modelCatalog,
      );
      if (retryIdentity != null) {
        _database.execute('COMMIT');
        return _SqliteProviderConfigurationReplacementResult(
          retryIdentity.leaseId,
          retryIdentity.operationId,
          VersionedProviderConfiguration(
            config: config,
            revision: previousRevision!,
          ),
        );
      }
      _requireNoPendingProviderOperations();
      late final int nextRevision;
      if (expectedRevision == null) {
        if (existing.isNotEmpty) {
          throw const ProviderConfigurationMutationException(
            ProviderConfigurationMutationErrorCode.conflict,
          );
        }
        nextRevision = 1;
        _database.execute(
          '''
            INSERT INTO provider_configs (
              provider_id, kind, protocol, display_name, base_uri, enabled,
              secret_ref, allow_insecure_http, revision
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          ''',
          [
            config.providerId,
            config.kind.name,
            config.protocol.name,
            config.displayName,
            config.baseUri.toString(),
            config.enabled ? 1 : 0,
            config.secretRef?.locator.toString(),
            config.allowInsecureHttp ? 1 : 0,
            nextRevision,
          ],
        );
        for (final entry in providerCredentialBindings(config).entries) {
          _insertOwnership(config.providerId, entry.key, entry.value);
        }
        for (final entry in config.headerSecretRefs.entries) {
          _database.execute(
            '''
              INSERT INTO provider_header_secret_refs (
                provider_id, header_name, secret_ref
              ) VALUES (?, ?, ?)
            ''',
            [config.providerId, entry.key, entry.value.locator.toString()],
          );
        }
      } else {
        if (existing.length != 1 ||
            existing.single['revision'] != expectedRevision.value) {
          throw const ProviderConfigurationMutationException(
            ProviderConfigurationMutationErrorCode.conflict,
          );
        }
        final current = _decodeConfig(existing.single);
        _requireSameCredentialBindings(current, config);
        nextRevision = expectedRevision.value + 1;
        _writeReplacementConfig(
          config,
          expectedRevision: expectedRevision.value,
          nextRevision: nextRevision,
        );
      }
      _replaceProviderModelCatalog(config.providerId, modelCatalog);
      _applyModelBindingMutation(replacement.modelBindings);
      final identity = _insertProviderMutationLease(
        providerId: config.providerId,
        operationKind: expectedRevision == null
            ? PendingProviderOperationKind.create
            : PendingProviderOperationKind.replace,
        newRevision: nextRevision,
        previousSnapshot: _encodeMutationSnapshot(
          previousConfig,
          previousRevision,
          previousBindings,
          previousCatalog,
        ),
        appliedConfig: _encodeAppliedMutationSnapshot(config, modelCatalog),
        appliedBindings: _encodeAllModelBindings(),
      );
      _database.execute('COMMIT');
      final versioned = VersionedProviderConfiguration(
        config: config,
        revision: ProviderConfigurationRevision(nextRevision),
      );
      return _SqliteProviderConfigurationReplacementResult(
        identity.leaseId,
        identity.operationId,
        versioned,
      );
    } on ProviderConfigurationMutationException {
      _database.execute('ROLLBACK');
      rethrow;
    } on Object {
      _database.execute('ROLLBACK');
      throw const ProviderConfigurationMutationException(
        ProviderConfigurationMutationErrorCode.conflict,
      );
    }
  });

  Future<List<ProviderConfig>> _loadConfigs({required bool enabledOnly}) =>
      Future.sync(() {
        _requireOpen();
        final rows = _database.select('''
        SELECT provider_id, kind, protocol, display_name, base_uri, enabled,
               secret_ref, allow_insecure_http
        FROM provider_configs
        ${enabledOnly ? 'WHERE enabled = 1' : ''}
        ORDER BY provider_id
      ''');
        return List<ProviderConfig>.unmodifiable(rows.map(_decodeConfig));
      });

  ProviderConfig _decodeConfig(Row row) {
    try {
      final providerId = row['provider_id']! as String;
      final headerRows = _database.select(
        '''
          SELECT header_name, secret_ref
          FROM provider_header_secret_refs
          WHERE provider_id = ?
          ORDER BY header_name
        ''',
        [providerId],
      );
      final headerRefs = <String, SecretRef>{
        for (final header in headerRows)
          header['header_name']! as String: SecretRef.parse(
            header['secret_ref']! as String,
          ),
      };
      final secretValue = row['secret_ref'] as String?;
      final secretRef = secretValue == null
          ? null
          : SecretRef.parse(secretValue);
      if (secretRef != null) {
        ProviderSecretRefPolicy.validate(secretRef);
        _validateOwnership(providerId, 'primary', secretRef);
      }
      for (final entry in headerRefs.entries) {
        final ref = entry.value;
        ProviderSecretRefPolicy.validate(ref);
        _validateOwnership(
          providerId,
          'header:${entry.key.toLowerCase()}',
          ref,
        );
      }
      return ProviderConfig.persisted(
        providerId: providerId,
        kind: ProviderKind.values.byName(row['kind']! as String),
        protocol: ProviderProtocol.values.byName(row['protocol']! as String),
        displayName: row['display_name']! as String,
        baseUri: Uri.parse(row['base_uri']! as String),
        enabled: row['enabled'] == 1,
        secretRef: secretRef,
        headerSecretRefs: headerRefs,
        allowInsecureHttp: row['allow_insecure_http'] == 1,
      );
    } catch (_) {
      throw StateError('Invalid persisted provider configuration');
    }
  }

  @override
  Future<void> upsert(ProviderConfig config) => Future.sync(() {
    _requireOpen();
    _validatePersistableRef(config.secretRef);
    for (final ref in config.headerSecretRefs.values) {
      _validatePersistableRef(ref);
    }
    _database.execute('BEGIN IMMEDIATE');
    try {
      _requireNoPendingProviderOperations();
      _database.execute(
        '''
          INSERT INTO provider_configs (
            provider_id, kind, protocol, display_name, base_uri, enabled,
            secret_ref, allow_insecure_http, revision
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)
          ON CONFLICT(provider_id) DO UPDATE SET
            kind = excluded.kind,
            protocol = excluded.protocol,
            display_name = excluded.display_name,
            base_uri = excluded.base_uri,
            enabled = excluded.enabled,
            secret_ref = excluded.secret_ref,
            allow_insecure_http = excluded.allow_insecure_http,
            revision = provider_configs.revision + 1
        ''',
        [
          config.providerId,
          config.kind.name,
          config.protocol.name,
          config.displayName,
          config.baseUri.toString(),
          config.enabled ? 1 : 0,
          config.secretRef?.locator.toString(),
          config.allowInsecureHttp ? 1 : 0,
        ],
      );
      _database.execute(
        'DELETE FROM provider_header_secret_refs WHERE provider_id = ?',
        [config.providerId],
      );
      final bindings = providerCredentialBindings(config);
      for (final entry in bindings.entries) {
        _insertOwnership(config.providerId, entry.key, entry.value);
      }
      for (final entry in config.headerSecretRefs.entries) {
        _database.execute(
          '''
            INSERT INTO provider_header_secret_refs (
              provider_id, header_name, secret_ref
            ) VALUES (?, ?, ?)
          ''',
          [config.providerId, entry.key, entry.value.locator.toString()],
        );
      }
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  });

  @override
  Future<void> remove(String providerId) => Future.sync(() {
    _requireOpen();
    final normalized = _requiredIdentifier(providerId, 'providerId');
    _database.execute('BEGIN IMMEDIATE');
    try {
      _requireNoPendingProviderOperations();
      _database.execute('DELETE FROM provider_configs WHERE provider_id = ?', [
        normalized,
      ]);
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  });

  @override
  Future<ProviderCredentialRotationResult> rotateCredential({
    required String providerId,
    required ProviderCredentialSlot slot,
    required ProviderConfigurationRevision expectedRevision,
    required SecretRef expectedOldRef,
    required SecretRef newRef,
    required ProviderConfigurationReplacement replacement,
  }) => Future.sync(() {
    _requireOpen();
    final normalizedProvider = _requiredIdentifier(providerId, 'providerId');
    ProviderSecretRefPolicy.validate(expectedOldRef);
    ProviderSecretRefPolicy.validate(newRef);
    if (replacement.config.providerId != normalizedProvider ||
        replacement.modelCatalog?.providerId != normalizedProvider &&
            replacement.modelCatalog != null ||
        providerCredentialBindings(replacement.config)[slot.value] != newRef) {
      throw const ProviderConfigurationMutationException(
        ProviderConfigurationMutationErrorCode.conflict,
      );
    }
    for (final ref in providerCredentialBindings(replacement.config).values) {
      ProviderSecretRefPolicy.validate(ref);
    }
    if (expectedOldRef == newRef) {
      throw const ProviderConfigurationMutationException(
        ProviderConfigurationMutationErrorCode.conflict,
      );
    }
    _database.execute('BEGIN IMMEDIATE');
    try {
      final providerRows = _database.select(
        '''
          SELECT provider_id, kind, protocol, display_name, base_uri, enabled,
                 secret_ref, allow_insecure_http, revision
          FROM provider_configs WHERE provider_id = ?
        ''',
        [normalizedProvider],
      );
      if (providerRows.length != 1) {
        throw const ProviderConfigurationMutationException(
          ProviderConfigurationMutationErrorCode.conflict,
        );
      }
      final currentRevision = providerRows.single['revision']! as int;
      final currentConfig = _decodeConfig(providerRows.single);
      final currentCatalog = _loadProviderModelCatalogSync(normalizedProvider);
      final previousBindings = _encodeAllModelBindings();
      final currentRef = _readCredentialSlot(normalizedProvider, slot);
      _requireUnchangedCredentialSlots(currentConfig, replacement.config, slot);
      if (_isIdempotentRotation(
        providerId: normalizedProvider,
        slot: slot,
        expectedRevision: expectedRevision.value,
        currentRevision: currentRevision,
        expectedOldRef: expectedOldRef,
        newRef: newRef,
        currentRef: currentRef,
      )) {
        if (!_sameProviderConfig(currentConfig, replacement.config) ||
            !_sameProviderModelCatalog(
              currentCatalog,
              replacement.modelCatalog,
            ) ||
            !_modelMutationMatches(replacement.modelBindings)) {
          throw const ProviderConfigurationMutationException(
            ProviderConfigurationMutationErrorCode.conflict,
          );
        }
        _database.execute('COMMIT');
        final identity = _requireProviderMutationIdentity(
          normalizedProvider,
          currentRevision,
          PendingProviderOperationKind.rotate,
        );
        return _SqliteProviderCredentialRotationResult(
          identity.leaseId,
          identity.operationId,
          normalizedProvider,
          slot,
          expectedOldRef,
          ProviderConfigurationRevision(currentRevision),
        );
      }
      _requireNoPendingProviderOperations();
      if (currentRevision != expectedRevision.value ||
          currentRef != expectedOldRef) {
        throw const ProviderConfigurationMutationException(
          ProviderConfigurationMutationErrorCode.conflict,
        );
      }
      _requireActiveOwnership(normalizedProvider, slot.value, expectedOldRef);
      final nextRevision = currentRevision + 1;
      _retireOwnership(
        normalizedProvider,
        slot.value,
        expectedOldRef,
        nextRevision,
      );
      _activateRotatedOwnership(normalizedProvider, slot.value, newRef);
      _writeReplacementConfig(
        replacement.config,
        expectedRevision: currentRevision,
        nextRevision: nextRevision,
      );
      _replaceProviderModelCatalog(
        normalizedProvider,
        replacement.modelCatalog,
      );
      _applyModelBindingMutation(replacement.modelBindings);
      final identity = _insertProviderMutationLease(
        providerId: normalizedProvider,
        operationKind: PendingProviderOperationKind.rotate,
        newRevision: nextRevision,
        previousSnapshot: _encodeMutationSnapshot(
          currentConfig,
          ProviderConfigurationRevision(currentRevision),
          previousBindings,
          currentCatalog,
        ),
        appliedConfig: _encodeAppliedMutationSnapshot(
          replacement.config,
          replacement.modelCatalog,
        ),
        appliedBindings: _encodeAllModelBindings(),
      );
      _database.execute('COMMIT');
      return _SqliteProviderCredentialRotationResult(
        identity.leaseId,
        identity.operationId,
        normalizedProvider,
        slot,
        expectedOldRef,
        ProviderConfigurationRevision(nextRevision),
      );
    } on ProviderConfigurationMutationException {
      _database.execute('ROLLBACK');
      rethrow;
    } on Object {
      _database.execute('ROLLBACK');
      throw const ProviderConfigurationMutationException(
        ProviderConfigurationMutationErrorCode.conflict,
      );
    }
  });

  @override
  Future<ProviderRemovalLease> removeProviderAtomically({
    required String providerId,
    required ProviderConfigurationRevision expectedRevision,
  }) => Future.sync(() {
    _requireOpen();
    final normalizedProvider = _requiredIdentifier(providerId, 'providerId');
    _database.execute('BEGIN IMMEDIATE');
    try {
      final pending = _database.select(
        '''
          SELECT lease_id, operation_id FROM provider_removal_leases
          WHERE provider_id = ? AND removed_revision = ?
        ''',
        [normalizedProvider, expectedRevision.value],
      );
      if (pending.length == 1) {
        _database.execute('COMMIT');
        return _SqliteProviderRemovalLease(
          pending.single['lease_id']! as String,
          PendingProviderOperationId.parse(
            pending.single['operation_id']! as String,
          ),
          normalizedProvider,
          expectedRevision,
        );
      }
      _requireNoPendingProviderOperations();
      final rows = _database.select(
        '''
          SELECT provider_id, kind, protocol, display_name, base_uri, enabled,
                 secret_ref, allow_insecure_http, revision
          FROM provider_configs WHERE provider_id = ?
        ''',
        [normalizedProvider],
      );
      if (rows.length != 1 ||
          rows.single['revision'] != expectedRevision.value) {
        throw const ProviderConfigurationMutationException(
          ProviderConfigurationMutationErrorCode.conflict,
        );
      }
      final config = _decodeConfig(rows.single);
      final bindings = _database.select(
        '''
          SELECT scope, scope_id, model_id FROM model_bindings
          WHERE provider_id = ? ORDER BY scope, scope_id
        ''',
        [normalizedProvider],
      );
      final snapshot = _encodeRemovalSnapshot(
        config,
        expectedRevision,
        bindings,
        _loadProviderModelCatalogSync(normalizedProvider),
      );
      final identity = _newPendingIdentity();
      _database.execute(
        '''
          INSERT INTO provider_removal_leases (
            lease_id, operation_id, provider_id, removed_revision,
            created_at_ms, snapshot_json
          ) VALUES (?, ?, ?, ?, ?, ?)
        ''',
        [
          identity.leaseId,
          identity.operationId.value,
          normalizedProvider,
          expectedRevision.value,
          DateTime.now().toUtc().millisecondsSinceEpoch,
          snapshot,
        ],
      );
      _database.execute('DELETE FROM provider_configs WHERE provider_id = ?', [
        normalizedProvider,
      ]);
      _database.execute('COMMIT');
      return _SqliteProviderRemovalLease(
        identity.leaseId,
        identity.operationId,
        normalizedProvider,
        expectedRevision,
      );
    } on ProviderConfigurationMutationException {
      _database.execute('ROLLBACK');
      rethrow;
    } on Object {
      _database.execute('ROLLBACK');
      throw const ProviderConfigurationMutationException(
        ProviderConfigurationMutationErrorCode.conflict,
      );
    }
  });

  @override
  Future<void> restoreRemovedProvider(ProviderRemovalLease lease) =>
      Future.sync(() {
        _requireOpen();
        if (lease is! _SqliteProviderRemovalLease) {
          throw const ProviderConfigurationMutationException(
            ProviderConfigurationMutationErrorCode.invalidLease,
          );
        }
        _database.execute('BEGIN IMMEDIATE');
        try {
          final leaseRow = _requireRemovalLease(lease);
          _requirePendingState(leaseRow, PendingProviderOperationState.staged);
          if (_database.select(
            'SELECT 1 FROM provider_configs WHERE provider_id = ?',
            [lease.providerId],
          ).isNotEmpty) {
            throw const ProviderConfigurationMutationException(
              ProviderConfigurationMutationErrorCode.conflict,
            );
          }
          final snapshot = _decodeRemovalSnapshot(
            leaseRow['snapshot_json']! as String,
          );
          if (snapshot.config.providerId != lease.providerId ||
              snapshot.revision != lease.removedRevision) {
            throw const ProviderConfigurationMutationException(
              ProviderConfigurationMutationErrorCode.invalidLease,
            );
          }
          _restoreProviderSnapshot(snapshot);
          _database.execute(
            'DELETE FROM provider_removal_leases WHERE lease_id = ?',
            [lease._leaseId],
          );
          _recoveredOperations.remove(lease.operationId.value);
          _database.execute('COMMIT');
        } on ProviderConfigurationMutationException {
          _database.execute('ROLLBACK');
          rethrow;
        } on Object {
          _database.execute('ROLLBACK');
          throw const ProviderConfigurationMutationException(
            ProviderConfigurationMutationErrorCode.restoreFailed,
          );
        }
      });

  @override
  Future<void> markProviderRemovalRuntimePublished(
    ProviderRemovalLease lease,
  ) => Future.sync(() {
    _requireOpen();
    if (lease is! _SqliteProviderRemovalLease) {
      throw const ProviderConfigurationMutationException(
        ProviderConfigurationMutationErrorCode.invalidLease,
      );
    }
    _database.execute('BEGIN IMMEDIATE');
    try {
      _requireRemovalLease(lease);
      _database.execute(
        '''
          UPDATE provider_removal_leases SET state = 'runtimePublished'
          WHERE lease_id = ? AND operation_id = ? AND state = 'staged'
        ''',
        [lease._leaseId, lease.operationId.value],
      );
      if (_database.updatedRows != 1) {
        throw const ProviderConfigurationMutationException(
          ProviderConfigurationMutationErrorCode.invalidLease,
        );
      }
      _recoveredOperations.remove(lease.operationId.value);
      _database.execute('COMMIT');
    } on ProviderConfigurationMutationException {
      _database.execute('ROLLBACK');
      rethrow;
    } on Object {
      _database.execute('ROLLBACK');
      throw const ProviderConfigurationMutationException(
        ProviderConfigurationMutationErrorCode.conflict,
      );
    }
  });

  @override
  Future<void> finalizeProviderRemoval(ProviderRemovalLease lease) =>
      Future.sync(() {
        _requireOpen();
        if (lease is! _SqliteProviderRemovalLease) {
          throw const ProviderConfigurationMutationException(
            ProviderConfigurationMutationErrorCode.invalidLease,
          );
        }
        _database.execute('BEGIN IMMEDIATE');
        try {
          final leaseRow = _requireRemovalLease(lease);
          _requirePendingState(
            leaseRow,
            PendingProviderOperationState.runtimePublished,
          );
          if (_database.select(
            'SELECT 1 FROM provider_configs WHERE provider_id = ?',
            [lease.providerId],
          ).isNotEmpty) {
            throw const ProviderConfigurationMutationException(
              ProviderConfigurationMutationErrorCode.conflict,
            );
          }
          _database.execute(
            '''
              UPDATE credential_bindings
              SET state = 'retired', retired_revision = ?
              WHERE provider_id = ? AND state = 'active'
            ''',
            [lease.removedRevision.value, lease.providerId],
          );
          _database.execute(
            'DELETE FROM provider_removal_leases WHERE lease_id = ?',
            [lease._leaseId],
          );
          _recoveredOperations.remove(lease.operationId.value);
          _database.execute('COMMIT');
        } on ProviderConfigurationMutationException {
          _database.execute('ROLLBACK');
          rethrow;
        } on Object {
          _database.execute('ROLLBACK');
          throw const ProviderConfigurationMutationException(
            ProviderConfigurationMutationErrorCode.conflict,
          );
        }
      });

  @override
  Future<void> rollbackProviderMutation(
    ProviderConfigurationMutationLease lease,
  ) => Future.sync(() {
    _requireOpen();
    if (lease is! _SqliteProviderMutationLease) {
      throw const ProviderConfigurationMutationException(
        ProviderConfigurationMutationErrorCode.invalidLease,
      );
    }
    _database.execute('BEGIN IMMEDIATE');
    try {
      final row = _requireProviderMutationLease(lease);
      _requirePendingState(row, PendingProviderOperationState.staged);
      final currentRows = _database.select(
        '''
          SELECT provider_id, kind, protocol, display_name, base_uri, enabled,
                 secret_ref, allow_insecure_http, revision
          FROM provider_configs WHERE provider_id = ?
        ''',
        [lease.providerId],
      );
      if (currentRows.length != 1 ||
          currentRows.single['revision'] != lease.newRevision.value ||
          _encodeAllModelBindings() != row['applied_bindings_json']) {
        throw const ProviderConfigurationMutationException(
          ProviderConfigurationMutationErrorCode.conflict,
        );
      }
      final currentConfig = _decodeConfig(currentRows.single);
      final applied = _decodeAppliedMutationSnapshot(
        row['applied_config_json']! as String,
      );
      if (!_sameProviderConfig(currentConfig, applied.config) ||
          !_sameProviderModelCatalog(
            _loadProviderModelCatalogSync(lease.providerId),
            applied.modelCatalog,
          )) {
        throw const ProviderConfigurationMutationException(
          ProviderConfigurationMutationErrorCode.conflict,
        );
      }
      final previous = _decodeMutationSnapshot(
        row['previous_snapshot_json']! as String,
      );
      _restoreOwnershipForRollback(
        currentConfig,
        previous.config,
        lease.newRevision.value,
      );
      _database.execute('DELETE FROM provider_configs WHERE provider_id = ?', [
        lease.providerId,
      ]);
      if (previous.config != null && previous.revision != null) {
        _restoreProviderSnapshot(
          _ProviderRemovalSnapshot(
            previous.config!,
            previous.revision!,
            const [],
            previous.modelCatalog,
          ),
        );
      }
      _database.execute('DELETE FROM model_bindings');
      for (final binding in previous.bindings) {
        _database.execute(
          '''
            INSERT INTO model_bindings (
              scope, scope_id, provider_id, model_id
            ) VALUES (?, ?, ?, ?)
          ''',
          [binding.scope, binding.scopeId, binding.providerId, binding.modelId],
        );
      }
      _database.execute(
        'DELETE FROM provider_configuration_mutations WHERE lease_id = ?',
        [lease._leaseId],
      );
      _recoveredOperations.remove(lease.operationId.value);
      _database.execute('COMMIT');
    } on ProviderConfigurationMutationException {
      _database.execute('ROLLBACK');
      rethrow;
    } on Object {
      _database.execute('ROLLBACK');
      throw const ProviderConfigurationMutationException(
        ProviderConfigurationMutationErrorCode.restoreFailed,
      );
    }
  });

  @override
  Future<void> markProviderMutationRuntimePublished(
    ProviderConfigurationMutationLease lease,
  ) => Future.sync(() {
    _requireOpen();
    if (lease is! _SqliteProviderMutationLease) {
      throw const ProviderConfigurationMutationException(
        ProviderConfigurationMutationErrorCode.invalidLease,
      );
    }
    _database.execute('BEGIN IMMEDIATE');
    try {
      _requireProviderMutationLease(lease);
      _database.execute(
        '''
          UPDATE provider_configuration_mutations
          SET state = 'runtimePublished'
          WHERE lease_id = ? AND operation_id = ? AND state = 'staged'
        ''',
        [lease._leaseId, lease.operationId.value],
      );
      if (_database.updatedRows != 1) {
        throw const ProviderConfigurationMutationException(
          ProviderConfigurationMutationErrorCode.invalidLease,
        );
      }
      _recoveredOperations.remove(lease.operationId.value);
      _database.execute('COMMIT');
    } on ProviderConfigurationMutationException {
      _database.execute('ROLLBACK');
      rethrow;
    } on Object {
      _database.execute('ROLLBACK');
      throw const ProviderConfigurationMutationException(
        ProviderConfigurationMutationErrorCode.conflict,
      );
    }
  });

  @override
  Future<void> finalizeProviderMutation(
    ProviderConfigurationMutationLease lease,
  ) => Future.sync(() {
    _requireOpen();
    if (lease is! _SqliteProviderMutationLease) {
      throw const ProviderConfigurationMutationException(
        ProviderConfigurationMutationErrorCode.invalidLease,
      );
    }
    _database.execute('BEGIN IMMEDIATE');
    try {
      final row = _requireProviderMutationLease(lease);
      _requirePendingState(row, PendingProviderOperationState.runtimePublished);
      final current = _database.select(
        '''
          SELECT provider_id, kind, protocol, display_name, base_uri, enabled,
                 secret_ref, allow_insecure_http, revision
          FROM provider_configs WHERE provider_id = ?
        ''',
        [lease.providerId],
      );
      if (current.length != 1 ||
          current.single['revision'] != lease.newRevision.value ||
          _encodeAllModelBindings() != row['applied_bindings_json']) {
        throw const ProviderConfigurationMutationException(
          ProviderConfigurationMutationErrorCode.conflict,
        );
      }
      final applied = _decodeAppliedMutationSnapshot(
        row['applied_config_json']! as String,
      );
      if (!_sameProviderConfig(_decodeConfig(current.single), applied.config) ||
          !_sameProviderModelCatalog(
            _loadProviderModelCatalogSync(lease.providerId),
            applied.modelCatalog,
          )) {
        throw const ProviderConfigurationMutationException(
          ProviderConfigurationMutationErrorCode.conflict,
        );
      }
      _database.execute(
        'DELETE FROM provider_configuration_mutations WHERE lease_id = ?',
        [lease._leaseId],
      );
      _recoveredOperations.remove(lease.operationId.value);
      _database.execute('COMMIT');
    } on ProviderConfigurationMutationException {
      _database.execute('ROLLBACK');
      rethrow;
    } on Object {
      _database.execute('ROLLBACK');
      throw const ProviderConfigurationMutationException(
        ProviderConfigurationMutationErrorCode.conflict,
      );
    }
  });

  @override
  Future<List<PendingProviderOperationDescriptor>>
  listPendingProviderOperations() => Future.sync(() {
    _requireOpen();
    final descriptors =
        <PendingProviderOperationDescriptor>[
          for (final row in _database.select('''
        SELECT operation_id, provider_id, operation_kind, new_revision,
               created_at_ms, state, previous_snapshot_json, applied_config_json,
               applied_bindings_json
        FROM provider_configuration_mutations
      '''))
            _decodePendingMutationDescriptor(row),
          for (final row in _database.select('''
        SELECT operation_id, provider_id, removed_revision, created_at_ms,
               state, snapshot_json
        FROM provider_removal_leases
      '''))
            _decodePendingRemovalDescriptor(row),
        ]..sort((left, right) {
          final byTime = left.createdAt.compareTo(right.createdAt);
          return byTime != 0
              ? byTime
              : left.operationId.value.compareTo(right.operationId.value);
        });
    return List.unmodifiable(descriptors);
  });

  @override
  Future<PendingProviderOperationRecovery> recoverPendingProviderOperation({
    required PendingProviderOperationId operationId,
    required String expectedProviderId,
    required PendingProviderOperationKind expectedKind,
  }) => Future.sync(() {
    _requireOpen();
    final providerId = _requiredIdentifier(
      expectedProviderId,
      'expectedProviderId',
    );
    final cached = _recoveredOperations[operationId.value];
    if (cached != null) {
      final descriptor = cached.descriptor;
      if (descriptor.providerId != providerId ||
          descriptor.kind != expectedKind ||
          !_pendingRecoveryIsCurrent(cached)) {
        _recoveredOperations.remove(operationId.value);
        throw const ProviderConfigurationMutationException(
          ProviderConfigurationMutationErrorCode.invalidLease,
        );
      }
      return cached;
    }
    _database.execute('BEGIN IMMEDIATE');
    try {
      final mutationRows = _database.select(
        '''
          SELECT lease_id, operation_id, provider_id, operation_kind,
                 new_revision, created_at_ms, state, previous_snapshot_json,
                 applied_config_json, applied_bindings_json
          FROM provider_configuration_mutations WHERE operation_id = ?
        ''',
        [operationId.value],
      );
      final removalRows = _database.select(
        '''
          SELECT lease_id, operation_id, provider_id, removed_revision,
                 created_at_ms, state, snapshot_json
          FROM provider_removal_leases WHERE operation_id = ?
        ''',
        [operationId.value],
      );
      if (mutationRows.length + removalRows.length != 1) {
        throw const ProviderConfigurationMutationException(
          ProviderConfigurationMutationErrorCode.invalidLease,
        );
      }
      final claimedLeaseId = _newInternalLeaseId();
      late final PendingProviderOperationRecovery recovery;
      if (mutationRows.isNotEmpty) {
        final row = mutationRows.single;
        final descriptor = _decodePendingMutationDescriptor(row);
        if (descriptor.providerId != providerId ||
            descriptor.kind != expectedKind) {
          throw const ProviderConfigurationMutationException(
            ProviderConfigurationMutationErrorCode.invalidLease,
          );
        }
        _database.execute(
          '''
            UPDATE provider_configuration_mutations SET lease_id = ?
            WHERE operation_id = ?
          ''',
          [claimedLeaseId, operationId.value],
        );
        recovery = _SqlitePendingProviderOperationRecovery(
          descriptor,
          _RecoveredSqliteProviderMutationLease(
            claimedLeaseId,
            operationId,
            providerId,
            descriptor.revision,
          ),
          null,
        );
      } else {
        final row = removalRows.single;
        final descriptor = _decodePendingRemovalDescriptor(row);
        if (descriptor.providerId != providerId ||
            descriptor.kind != expectedKind) {
          throw const ProviderConfigurationMutationException(
            ProviderConfigurationMutationErrorCode.invalidLease,
          );
        }
        _database.execute(
          '''
            UPDATE provider_removal_leases SET lease_id = ?
            WHERE operation_id = ?
          ''',
          [claimedLeaseId, operationId.value],
        );
        recovery = _SqlitePendingProviderOperationRecovery(
          descriptor,
          null,
          _SqliteProviderRemovalLease(
            claimedLeaseId,
            operationId,
            providerId,
            descriptor.revision,
          ),
        );
      }
      _database.execute('COMMIT');
      _recoveredOperations[operationId.value] = recovery;
      return recovery;
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  });

  bool _pendingRecoveryIsCurrent(PendingProviderOperationRecovery recovery) {
    final mutation = recovery.mutationLease;
    if (mutation is _SqliteProviderMutationLease) {
      return _database
          .select(
            '''
              SELECT 1 FROM provider_configuration_mutations
              WHERE operation_id = ? AND lease_id = ?
            ''',
            [mutation.operationId.value, mutation._leaseId],
          )
          .isNotEmpty;
    }
    final removal = recovery.removalLease;
    if (removal is _SqliteProviderRemovalLease) {
      return _database
          .select(
            '''
              SELECT 1 FROM provider_removal_leases
              WHERE operation_id = ? AND lease_id = ?
            ''',
            [removal.operationId.value, removal._leaseId],
          )
          .isNotEmpty;
    }
    return false;
  }

  String _newInternalLeaseId() =>
      _database
              .select('SELECT lower(hex(randomblob(32))) AS lease_id')
              .single['lease_id']!
          as String;

  @override
  Future<ModelRef?> loadGlobalDefaultModel() => _loadBinding('global', '');

  @override
  Future<void> setGlobalDefaultModel(ModelRef? model) =>
      _setBinding('global', '', model);

  @override
  Future<ModelRef?> loadAgentModelOverride(String agentId) =>
      _loadBinding('agent', _requiredIdentifier(agentId, 'agentId'));

  @override
  Future<Map<String, ModelRef>> loadAgentModelOverrides() => Future.sync(() {
    _requireOpen();
    final rows = _database.select('''
      SELECT scope_id, provider_id, model_id
      FROM model_bindings
      WHERE scope = 'agent'
      ORDER BY scope_id
    ''');
    return Map<String, ModelRef>.unmodifiable({
      for (final row in rows)
        _requiredIdentifier(row['scope_id']! as String, 'agentId'): ModelRef(
          providerId: row['provider_id']! as String,
          modelId: row['model_id']! as String,
        ),
    });
  });

  @override
  Future<void> setAgentModelOverride(String agentId, ModelRef? model) =>
      _setBinding('agent', _requiredIdentifier(agentId, 'agentId'), model);

  Future<ModelRef?> _loadBinding(String scope, String scopeId) =>
      Future.sync(() {
        _requireOpen();
        final rows = _database.select(
          '''
            SELECT provider_id, model_id
            FROM model_bindings
            WHERE scope = ? AND scope_id = ?
          ''',
          [scope, scopeId],
        );
        if (rows.isEmpty) return null;
        final row = rows.single;
        return ModelRef(
          providerId: row['provider_id']! as String,
          modelId: row['model_id']! as String,
        );
      });

  Future<void> _setBinding(String scope, String scopeId, ModelRef? model) =>
      Future.sync(() {
        _requireOpen();
        _database.execute('BEGIN IMMEDIATE');
        try {
          _requireNoPendingProviderOperations();
          if (model == null) {
            _database.execute(
              'DELETE FROM model_bindings WHERE scope = ? AND scope_id = ?',
              [scope, scopeId],
            );
          } else {
            _database.execute(
              '''
                INSERT INTO model_bindings (
                  scope, scope_id, provider_id, model_id
                ) VALUES (?, ?, ?, ?)
                ON CONFLICT(scope, scope_id) DO UPDATE SET
                  provider_id = excluded.provider_id,
                  model_id = excluded.model_id
              ''',
              [scope, scopeId, model.providerId, model.modelId],
            );
          }
          _database.execute('COMMIT');
        } catch (_) {
          _database.execute('ROLLBACK');
          rethrow;
        }
      });

  void _requireNoPendingProviderOperations() {
    final rows = _database.select('''
      SELECT 1 FROM provider_configuration_mutations
      UNION ALL
      SELECT 1 FROM provider_removal_leases
      LIMIT 1
    ''');
    if (rows.isNotEmpty) {
      throw const ProviderConfigurationMutationException(
        ProviderConfigurationMutationErrorCode.conflict,
      );
    }
  }

  SecretRef? _readCredentialSlot(
    String providerId,
    ProviderCredentialSlot slot,
  ) {
    final rows = slot == ProviderCredentialSlot.primary
        ? _database.select(
            'SELECT secret_ref FROM provider_configs WHERE provider_id = ?',
            [providerId],
          )
        : _database.select(
            '''
              SELECT secret_ref FROM provider_header_secret_refs
              WHERE provider_id = ? AND lower(header_name) = ?
            ''',
            [providerId, slot.value.substring('header:'.length)],
          );
    if (rows.length != 1 || rows.single['secret_ref'] == null) return null;
    return SecretRef.parse(rows.single['secret_ref']! as String);
  }

  bool _isIdempotentRotation({
    required String providerId,
    required ProviderCredentialSlot slot,
    required int expectedRevision,
    required int currentRevision,
    required SecretRef expectedOldRef,
    required SecretRef newRef,
    required SecretRef? currentRef,
  }) {
    if (currentRevision != expectedRevision + 1 || currentRef != newRef) {
      return false;
    }
    final oldRows = _database.select(
      '''
        SELECT 1 FROM credential_bindings
        WHERE secret_ref = ? AND provider_id = ? AND credential_slot = ?
          AND state = 'retired' AND retired_revision = ?
      ''',
      [
        expectedOldRef.locator.toString(),
        providerId,
        slot.value,
        currentRevision,
      ],
    );
    final newRows = _database.select(
      '''
        SELECT 1 FROM credential_bindings
        WHERE secret_ref = ? AND provider_id = ? AND credential_slot = ?
          AND state = 'active'
      ''',
      [newRef.locator.toString(), providerId, slot.value],
    );
    return oldRows.length == 1 && newRows.length == 1;
  }

  void _requireActiveOwnership(String providerId, String slot, SecretRef ref) {
    final rows = _database.select(
      '''
        SELECT 1 FROM credential_bindings
        WHERE secret_ref = ? AND provider_id = ? AND credential_slot = ?
          AND state = 'active'
      ''',
      [ref.locator.toString(), providerId, slot],
    );
    if (rows.length != 1) {
      throw const ProviderConfigurationMutationException(
        ProviderConfigurationMutationErrorCode.conflict,
      );
    }
  }

  void _retireOwnership(
    String providerId,
    String slot,
    SecretRef ref,
    int retiredRevision,
  ) {
    _database.execute(
      '''
        UPDATE credential_bindings
        SET state = 'retired', retired_revision = ?
        WHERE secret_ref = ? AND provider_id = ? AND credential_slot = ?
          AND state = 'active'
      ''',
      [retiredRevision, ref.locator.toString(), providerId, slot],
    );
  }

  void _activateRotatedOwnership(
    String providerId,
    String slot,
    SecretRef ref,
  ) {
    final rows = _database.select(
      '''
        SELECT provider_id, credential_slot, state
        FROM credential_bindings WHERE secret_ref = ?
      ''',
      [ref.locator.toString()],
    );
    if (rows.isEmpty) {
      _database.execute(
        '''
          INSERT INTO credential_bindings (
            secret_ref, provider_id, credential_slot, state, retired_revision
          ) VALUES (?, ?, ?, 'active', NULL)
        ''',
        [ref.locator.toString(), providerId, slot],
      );
      return;
    }
    final row = rows.single;
    if (row['provider_id'] != providerId ||
        row['credential_slot'] != slot ||
        row['state'] != 'retired') {
      throw const ProviderConfigurationMutationException(
        ProviderConfigurationMutationErrorCode.conflict,
      );
    }
    _database.execute(
      '''
        UPDATE credential_bindings
        SET state = 'active', retired_revision = NULL
        WHERE secret_ref = ?
      ''',
      [ref.locator.toString()],
    );
  }

  void _requireUnchangedCredentialSlots(
    ProviderConfig current,
    ProviderConfig replacement,
    ProviderCredentialSlot rotatedSlot,
  ) {
    final before = providerCredentialBindings(current);
    final after = providerCredentialBindings(replacement);
    final slots = {...before.keys, ...after.keys}..remove(rotatedSlot.value);
    for (final slot in slots) {
      if (before[slot] != after[slot]) {
        throw const ProviderConfigurationMutationException(
          ProviderConfigurationMutationErrorCode.conflict,
        );
      }
    }
  }

  void _requireSameCredentialBindings(
    ProviderConfig current,
    ProviderConfig replacement,
  ) {
    final before = providerCredentialBindings(current);
    final after = providerCredentialBindings(replacement);
    if (before.length != after.length ||
        before.entries.any((entry) => after[entry.key] != entry.value)) {
      throw const ProviderConfigurationMutationException(
        ProviderConfigurationMutationErrorCode.conflict,
      );
    }
  }

  bool _sameProviderConfig(ProviderConfig left, ProviderConfig right) {
    final leftBindings = providerCredentialBindings(left);
    final rightBindings = providerCredentialBindings(right);
    return left.providerId == right.providerId &&
        left.kind == right.kind &&
        left.protocol == right.protocol &&
        left.displayName == right.displayName &&
        left.baseUri == right.baseUri &&
        left.enabled == right.enabled &&
        left.allowInsecureHttp == right.allowInsecureHttp &&
        leftBindings.length == rightBindings.length &&
        leftBindings.entries.every(
          (entry) => rightBindings[entry.key] == entry.value,
        );
  }

  void _writeReplacementConfig(
    ProviderConfig config, {
    required int expectedRevision,
    required int nextRevision,
  }) {
    _database.execute(
      '''
        UPDATE provider_configs SET
          kind = ?, protocol = ?, display_name = ?, base_uri = ?,
          enabled = ?, secret_ref = ?, allow_insecure_http = ?, revision = ?
        WHERE provider_id = ? AND revision = ?
      ''',
      [
        config.kind.name,
        config.protocol.name,
        config.displayName,
        config.baseUri.toString(),
        config.enabled ? 1 : 0,
        config.secretRef?.locator.toString(),
        config.allowInsecureHttp ? 1 : 0,
        nextRevision,
        config.providerId,
        expectedRevision,
      ],
    );
    _database.execute(
      'DELETE FROM provider_header_secret_refs WHERE provider_id = ?',
      [config.providerId],
    );
    for (final entry in providerCredentialBindings(config).entries) {
      _requireActiveOwnership(config.providerId, entry.key, entry.value);
    }
    for (final entry in config.headerSecretRefs.entries) {
      _database.execute(
        '''
          INSERT INTO provider_header_secret_refs (
            provider_id, header_name, secret_ref
          ) VALUES (?, ?, ?)
        ''',
        [config.providerId, entry.key, entry.value.locator.toString()],
      );
    }
  }

  bool _modelMutationMatches(ProviderModelBindingMutation mutation) {
    if (mutation.replaceGlobalDefault) {
      final current = _loadBindingSync('global', '');
      if (current != mutation.globalDefault) return false;
    }
    for (final entry in mutation.agentOverrides.entries) {
      if (_loadBindingSync('agent', entry.key) != entry.value) return false;
    }
    return true;
  }

  void _applyModelBindingMutation(ProviderModelBindingMutation mutation) {
    if (mutation.replaceGlobalDefault) {
      _writeBindingSync('global', '', mutation.globalDefault);
    }
    for (final entry in mutation.agentOverrides.entries) {
      _writeBindingSync(
        'agent',
        _requiredIdentifier(entry.key, 'agentId'),
        entry.value,
      );
    }
  }

  void _replaceProviderModelCatalog(
    String providerId,
    PersistedProviderModelCatalog? catalog,
  ) {
    if (catalog != null && catalog.providerId != providerId) {
      throw const ProviderConfigurationMutationException(
        ProviderConfigurationMutationErrorCode.conflict,
      );
    }
    _database.execute(
      'DELETE FROM provider_model_catalogs WHERE provider_id = ?',
      [providerId],
    );
    if (catalog != null) {
      _database.execute(
        '''
          INSERT INTO provider_model_catalogs (provider_id, discovered_at_ms)
          VALUES (?, ?)
        ''',
        [providerId, catalog.discoveredAt.millisecondsSinceEpoch],
      );
      final models = [...catalog.models]
        ..sort((left, right) => left.ref.modelId.compareTo(right.ref.modelId));
      for (final model in models) {
        final capabilities = model.capabilities;
        _database.execute(
          '''
            INSERT INTO provider_models (
              provider_id, model_id, display_name, text_generation,
              system_messages, max_output_tokens, supports_temperature,
              discovered_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          ''',
          [
            providerId,
            model.ref.modelId,
            model.displayName,
            capabilities.textGeneration ? 1 : 0,
            capabilities.systemMessages ? 1 : 0,
            capabilities.maxOutputTokens,
            capabilities.supportsTemperature ? 1 : 0,
            catalog.discoveredAt.millisecondsSinceEpoch,
          ],
        );
      }
    }
    _database.execute(
      '''
        DELETE FROM model_bindings
        WHERE provider_id = ?
          AND NOT EXISTS (
            SELECT 1 FROM provider_models
            WHERE provider_models.provider_id = model_bindings.provider_id
              AND provider_models.model_id = model_bindings.model_id
          )
      ''',
      [providerId],
    );
  }

  bool _sameProviderModelCatalog(
    PersistedProviderModelCatalog? left,
    PersistedProviderModelCatalog? right,
  ) {
    if (left == null || right == null) return left == right;
    if (left.providerId != right.providerId ||
        left.discoveredAt != right.discoveredAt ||
        left.models.length != right.models.length) {
      return false;
    }
    final rightById = {
      for (final model in right.models) model.ref.modelId: model,
    };
    for (final model in left.models) {
      final other = rightById[model.ref.modelId];
      final capabilities = model.capabilities;
      final otherCapabilities = other?.capabilities;
      if (other == null ||
          model.ref.providerId != other.ref.providerId ||
          model.displayName != other.displayName ||
          capabilities.textGeneration != otherCapabilities!.textGeneration ||
          capabilities.systemMessages != otherCapabilities.systemMessages ||
          capabilities.maxOutputTokens != otherCapabilities.maxOutputTokens ||
          capabilities.supportsTemperature !=
              otherCapabilities.supportsTemperature) {
        return false;
      }
    }
    return true;
  }

  Object? _modelCatalogToJson(PersistedProviderModelCatalog? catalog) {
    if (catalog == null) return null;
    final models = [...catalog.models]
      ..sort((left, right) => left.ref.modelId.compareTo(right.ref.modelId));
    return {
      'providerId': catalog.providerId,
      'discoveredAtMs': catalog.discoveredAt.millisecondsSinceEpoch,
      'models': [
        for (final model in models)
          {
            'modelId': model.ref.modelId,
            'displayName': model.displayName,
            'textGeneration': model.capabilities.textGeneration,
            'systemMessages': model.capabilities.systemMessages,
            'maxOutputTokens': model.capabilities.maxOutputTokens,
            'supportsTemperature': model.capabilities.supportsTemperature,
          },
      ],
    };
  }

  PersistedProviderModelCatalog? _modelCatalogFromJson(Object? raw) {
    if (raw == null) return null;
    final json = raw as Map<String, Object?>;
    final providerId = json['providerId']! as String;
    return PersistedProviderModelCatalog(
      providerId: providerId,
      models: [
        for (final rawModel in json['models']! as List<Object?>)
          _modelDescriptorFromJson(
            providerId,
            rawModel! as Map<String, Object?>,
          ),
      ],
      discoveredAt: DateTime.fromMillisecondsSinceEpoch(
        json['discoveredAtMs']! as int,
        isUtc: true,
      ),
    );
  }

  ModelDescriptor _modelDescriptorFromJson(
    String providerId,
    Map<String, Object?> rawModel,
  ) => ModelDescriptor(
    ref: ModelRef(
      providerId: providerId,
      modelId: rawModel['modelId']! as String,
    ),
    displayName: rawModel['displayName']! as String,
    capabilities: ModelCapabilities(
      textGeneration: rawModel['textGeneration']! as bool,
      systemMessages: rawModel['systemMessages']! as bool,
      maxOutputTokens: rawModel['maxOutputTokens']! as int,
      supportsTemperature: rawModel['supportsTemperature']! as bool,
    ),
  );

  ModelRef? _loadBindingSync(String scope, String scopeId) {
    final rows = _database.select(
      '''
        SELECT provider_id, model_id FROM model_bindings
        WHERE scope = ? AND scope_id = ?
      ''',
      [scope, scopeId],
    );
    if (rows.isEmpty) return null;
    return ModelRef(
      providerId: rows.single['provider_id']! as String,
      modelId: rows.single['model_id']! as String,
    );
  }

  void _writeBindingSync(String scope, String scopeId, ModelRef? model) {
    if (model == null) {
      _database.execute(
        'DELETE FROM model_bindings WHERE scope = ? AND scope_id = ?',
        [scope, scopeId],
      );
      return;
    }
    _database.execute(
      '''
        INSERT INTO model_bindings (scope, scope_id, provider_id, model_id)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(scope, scope_id) DO UPDATE SET
          provider_id = excluded.provider_id,
          model_id = excluded.model_id
      ''',
      [scope, scopeId, model.providerId, model.modelId],
    );
  }

  String _encodeRemovalSnapshot(
    ProviderConfig config,
    ProviderConfigurationRevision revision,
    ResultSet bindings,
    PersistedProviderModelCatalog? modelCatalog,
  ) => jsonEncode({
    'config': {
      'providerId': config.providerId,
      'kind': config.kind.name,
      'protocol': config.protocol.name,
      'displayName': config.displayName,
      'baseUri': config.baseUri.toString(),
      'enabled': config.enabled,
      'secretRef': config.secretRef?.locator.toString(),
      'headerSecretRefs': {
        for (final entry in config.headerSecretRefs.entries)
          entry.key: entry.value.locator.toString(),
      },
      'allowInsecureHttp': config.allowInsecureHttp,
    },
    'revision': revision.value,
    'modelCatalog': _modelCatalogToJson(modelCatalog),
    'modelBindings': [
      for (final row in bindings)
        {
          'scope': row['scope'],
          'scopeId': row['scope_id'],
          'modelId': row['model_id'],
        },
    ],
  });

  _ProviderRemovalSnapshot _decodeRemovalSnapshot(String encoded) {
    final root = jsonDecode(encoded) as Map<String, Object?>;
    final rawConfig = root['config']! as Map<String, Object?>;
    final rawHeaders = rawConfig['headerSecretRefs']! as Map<String, Object?>;
    final config = ProviderConfig.persisted(
      providerId: rawConfig['providerId']! as String,
      kind: ProviderKind.values.byName(rawConfig['kind']! as String),
      protocol: ProviderProtocol.values.byName(
        rawConfig['protocol']! as String,
      ),
      displayName: rawConfig['displayName']! as String,
      baseUri: Uri.parse(rawConfig['baseUri']! as String),
      enabled: rawConfig['enabled']! as bool,
      secretRef: rawConfig['secretRef'] == null
          ? null
          : SecretRef.parse(rawConfig['secretRef']! as String),
      headerSecretRefs: {
        for (final entry in rawHeaders.entries)
          entry.key: SecretRef.parse(entry.value! as String),
      },
      allowInsecureHttp: rawConfig['allowInsecureHttp']! as bool,
    );
    final bindings = <_RemovalModelBinding>[
      for (final raw in root['modelBindings']! as List<Object?>)
        _RemovalModelBinding.fromJson(raw! as Map<String, Object?>),
    ];
    return _ProviderRemovalSnapshot(
      config,
      ProviderConfigurationRevision(root['revision']! as int),
      bindings,
      _modelCatalogFromJson(root['modelCatalog']),
    );
  }

  void _restoreProviderSnapshot(_ProviderRemovalSnapshot snapshot) {
    final config = snapshot.config;
    _database.execute(
      '''
        INSERT INTO provider_configs (
          provider_id, kind, protocol, display_name, base_uri, enabled,
          secret_ref, allow_insecure_http, revision
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        config.providerId,
        config.kind.name,
        config.protocol.name,
        config.displayName,
        config.baseUri.toString(),
        config.enabled ? 1 : 0,
        config.secretRef?.locator.toString(),
        config.allowInsecureHttp ? 1 : 0,
        snapshot.revision.value,
      ],
    );
    for (final entry in providerCredentialBindings(config).entries) {
      _requireActiveOwnership(config.providerId, entry.key, entry.value);
    }
    for (final entry in config.headerSecretRefs.entries) {
      _database.execute(
        '''
          INSERT INTO provider_header_secret_refs (
            provider_id, header_name, secret_ref
          ) VALUES (?, ?, ?)
        ''',
        [config.providerId, entry.key, entry.value.locator.toString()],
      );
    }
    _replaceProviderModelCatalog(config.providerId, snapshot.modelCatalog);
    for (final binding in snapshot.bindings) {
      _database.execute(
        '''
          INSERT INTO model_bindings (
            scope, scope_id, provider_id, model_id
          ) VALUES (?, ?, ?, ?)
        ''',
        [binding.scope, binding.scopeId, config.providerId, binding.modelId],
      );
    }
  }

  Row _requireRemovalLease(_SqliteProviderRemovalLease lease) {
    final rows = _database.select(
      '''
        SELECT operation_id, provider_id, removed_revision, created_at_ms,
               state, snapshot_json
        FROM provider_removal_leases WHERE lease_id = ?
      ''',
      [lease._leaseId],
    );
    if (rows.length != 1 ||
        rows.single['operation_id'] != lease.operationId.value ||
        rows.single['provider_id'] != lease.providerId ||
        rows.single['removed_revision'] != lease.removedRevision.value) {
      throw const ProviderConfigurationMutationException(
        ProviderConfigurationMutationErrorCode.invalidLease,
      );
    }
    return rows.single;
  }

  void _requirePendingState(Row row, PendingProviderOperationState expected) {
    if (row['state'] != expected.name) {
      throw const ProviderConfigurationMutationException(
        ProviderConfigurationMutationErrorCode.invalidLease,
      );
    }
  }

  String _encodeAllModelBindings() => jsonEncode([
    for (final row in _database.select('''
      SELECT scope, scope_id, provider_id, model_id
      FROM model_bindings ORDER BY scope, scope_id
    '''))
      {
        'scope': row['scope'],
        'scopeId': row['scope_id'],
        'providerId': row['provider_id'],
        'modelId': row['model_id'],
      },
  ]);

  String _encodeMutationSnapshot(
    ProviderConfig? config,
    ProviderConfigurationRevision? revision,
    String modelBindingsJson,
    PersistedProviderModelCatalog? modelCatalog,
  ) => jsonEncode({
    'config': config == null ? null : _configToJson(config),
    'revision': revision?.value,
    'modelCatalog': _modelCatalogToJson(modelCatalog),
    'modelBindings': jsonDecode(modelBindingsJson),
  });

  String _encodeAppliedMutationSnapshot(
    ProviderConfig config,
    PersistedProviderModelCatalog? modelCatalog,
  ) => jsonEncode({
    'config': _configToJson(config),
    'modelCatalog': _modelCatalogToJson(modelCatalog),
  });

  Map<String, Object?> _configToJson(ProviderConfig config) => {
    'providerId': config.providerId,
    'kind': config.kind.name,
    'protocol': config.protocol.name,
    'displayName': config.displayName,
    'baseUri': config.baseUri.toString(),
    'enabled': config.enabled,
    'secretRef': config.secretRef?.locator.toString(),
    'headerSecretRefs': {
      for (final entry in config.headerSecretRefs.entries)
        entry.key: entry.value.locator.toString(),
    },
    'allowInsecureHttp': config.allowInsecureHttp,
  };

  _ProviderMutationSnapshot _decodeMutationSnapshot(String encoded) {
    final root = jsonDecode(encoded) as Map<String, Object?>;
    final rawConfig = root['config'] as Map<String, Object?>?;
    final config = rawConfig == null ? null : _configFromJson(rawConfig);
    return _ProviderMutationSnapshot(
      config,
      root['revision'] == null
          ? null
          : ProviderConfigurationRevision(root['revision']! as int),
      _decodeAllBindings(root['modelBindings']! as List<Object?>),
      _modelCatalogFromJson(root['modelCatalog']),
    );
  }

  _AppliedProviderMutationSnapshot _decodeAppliedMutationSnapshot(
    String encoded,
  ) {
    final root = jsonDecode(encoded) as Map<String, Object?>;
    return _AppliedProviderMutationSnapshot(
      _configFromJson(root['config']! as Map<String, Object?>),
      _modelCatalogFromJson(root['modelCatalog']),
    );
  }

  PendingProviderOperationDescriptor _decodePendingMutationDescriptor(Row row) {
    try {
      final previous = _decodeMutationSnapshot(
        row['previous_snapshot_json']! as String,
      );
      final applied = _decodeAppliedMutationSnapshot(
        row['applied_config_json']! as String,
      );
      final nextConfig = applied.config;
      final nextBindings = _decodeAllBindings(
        jsonDecode(row['applied_bindings_json']! as String) as List<Object?>,
      );
      final kind = PendingProviderOperationKind.values.byName(
        row['operation_kind']! as String,
      );
      if (kind == PendingProviderOperationKind.remove ||
          nextConfig.providerId != row['provider_id']) {
        throw const FormatException();
      }
      final state = PendingProviderOperationState.values.byName(
        row['state']! as String,
      );
      return PendingProviderOperationDescriptor(
        operationId: PendingProviderOperationId.parse(
          row['operation_id']! as String,
        ),
        providerId: row['provider_id']! as String,
        kind: kind,
        state: state,
        revision: ProviderConfigurationRevision(row['new_revision']! as int),
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          row['created_at_ms']! as int,
          isUtc: true,
        ),
        previousConfiguration: previous.config,
        nextConfiguration: nextConfig,
        previousBindings: _bindingSnapshot(previous.bindings),
        nextBindings: _bindingSnapshot(nextBindings),
        previousCredentialRefs: previous.config == null
            ? const {}
            : providerCredentialBindings(previous.config!),
        nextCredentialRefs: providerCredentialBindings(nextConfig),
        allowedActions: state == PendingProviderOperationState.staged
            ? const {PendingProviderTerminalAction.rollback}
            : const {PendingProviderTerminalAction.finalize},
      );
    } on Object {
      throw StateError('Invalid pending provider mutation');
    }
  }

  PendingProviderOperationDescriptor _decodePendingRemovalDescriptor(Row row) {
    try {
      final previous = _decodeRemovalSnapshot(row['snapshot_json']! as String);
      final bindings = [
        for (final binding in previous.bindings)
          _AllModelBinding(
            binding.scope,
            binding.scopeId,
            previous.config.providerId,
            binding.modelId,
          ),
      ];
      final state = PendingProviderOperationState.values.byName(
        row['state']! as String,
      );
      return PendingProviderOperationDescriptor(
        operationId: PendingProviderOperationId.parse(
          row['operation_id']! as String,
        ),
        providerId: row['provider_id']! as String,
        kind: PendingProviderOperationKind.remove,
        state: state,
        revision: ProviderConfigurationRevision(
          row['removed_revision']! as int,
        ),
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          row['created_at_ms']! as int,
          isUtc: true,
        ),
        previousConfiguration: previous.config,
        nextConfiguration: null,
        previousBindings: _bindingSnapshot(bindings),
        nextBindings: ProviderModelBindingSnapshot(),
        previousCredentialRefs: providerCredentialBindings(previous.config),
        nextCredentialRefs: const {},
        allowedActions: state == PendingProviderOperationState.staged
            ? const {PendingProviderTerminalAction.restore}
            : const {PendingProviderTerminalAction.finalize},
      );
    } on Object {
      throw StateError('Invalid pending provider removal');
    }
  }

  List<_AllModelBinding> _decodeAllBindings(List<Object?> rawBindings) => [
    for (final raw in rawBindings)
      _AllModelBinding.fromJson(raw! as Map<String, Object?>),
  ];

  ProviderModelBindingSnapshot _bindingSnapshot(
    Iterable<_AllModelBinding> bindings,
  ) {
    ModelRef? globalDefault;
    final agents = <String, ModelRef>{};
    for (final binding in bindings) {
      final model = ModelRef(
        providerId: binding.providerId,
        modelId: binding.modelId,
      );
      if (binding.scope == 'global' && binding.scopeId.isEmpty) {
        if (globalDefault != null) throw const FormatException();
        globalDefault = model;
      } else if (binding.scope == 'agent' &&
          isCanonicalRuntimeId(binding.scopeId)) {
        if (agents.containsKey(binding.scopeId)) throw const FormatException();
        agents[binding.scopeId] = model;
      } else {
        throw const FormatException();
      }
    }
    return ProviderModelBindingSnapshot(
      globalDefault: globalDefault,
      agentOverrides: agents,
    );
  }

  ProviderConfig _configFromJson(Map<String, Object?> rawConfig) {
    final rawHeaders = rawConfig['headerSecretRefs']! as Map<String, Object?>;
    return ProviderConfig.persisted(
      providerId: rawConfig['providerId']! as String,
      kind: ProviderKind.values.byName(rawConfig['kind']! as String),
      protocol: ProviderProtocol.values.byName(
        rawConfig['protocol']! as String,
      ),
      displayName: rawConfig['displayName']! as String,
      baseUri: Uri.parse(rawConfig['baseUri']! as String),
      enabled: rawConfig['enabled']! as bool,
      secretRef: rawConfig['secretRef'] == null
          ? null
          : SecretRef.parse(rawConfig['secretRef']! as String),
      headerSecretRefs: {
        for (final entry in rawHeaders.entries)
          entry.key: SecretRef.parse(entry.value! as String),
      },
      allowInsecureHttp: rawConfig['allowInsecureHttp']! as bool,
    );
  }

  ({String leaseId, PendingProviderOperationId operationId})
  _insertProviderMutationLease({
    required String providerId,
    required PendingProviderOperationKind operationKind,
    required int newRevision,
    required String previousSnapshot,
    required String appliedConfig,
    required String appliedBindings,
  }) {
    final identity = _newPendingIdentity();
    _database.execute(
      '''
        INSERT INTO provider_configuration_mutations (
          lease_id, operation_id, provider_id, operation_kind, new_revision,
          created_at_ms, previous_snapshot_json, applied_config_json,
          applied_bindings_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        identity.leaseId,
        identity.operationId.value,
        providerId,
        operationKind.name,
        newRevision,
        DateTime.now().toUtc().millisecondsSinceEpoch,
        previousSnapshot,
        appliedConfig,
        appliedBindings,
      ],
    );
    return identity;
  }

  ({String leaseId, PendingProviderOperationId operationId})
  _requireProviderMutationIdentity(
    String providerId,
    int newRevision,
    PendingProviderOperationKind operationKind,
  ) {
    final rows = _database.select(
      '''
        SELECT lease_id, operation_id FROM provider_configuration_mutations
        WHERE provider_id = ? AND new_revision = ? AND operation_kind = ?
      ''',
      [providerId, newRevision, operationKind.name],
    );
    if (rows.length != 1) {
      throw const ProviderConfigurationMutationException(
        ProviderConfigurationMutationErrorCode.conflict,
      );
    }
    return (
      leaseId: rows.single['lease_id']! as String,
      operationId: PendingProviderOperationId.parse(
        rows.single['operation_id']! as String,
      ),
    );
  }

  ({String leaseId, PendingProviderOperationId operationId})?
  _idempotentReplacementIdentity({
    required ProviderConfig config,
    required ProviderConfigurationRevision? expectedRevision,
    required ProviderConfig? currentConfig,
    required ProviderConfigurationRevision? currentRevision,
    required ProviderModelBindingMutation modelBindings,
    required PersistedProviderModelCatalog? modelCatalog,
  }) {
    final intendedRevision = (expectedRevision?.value ?? 0) + 1;
    final expectedKind = expectedRevision == null
        ? PendingProviderOperationKind.create
        : PendingProviderOperationKind.replace;
    if (currentConfig == null ||
        currentRevision?.value != intendedRevision ||
        !_sameProviderConfig(currentConfig, config) ||
        !_sameProviderModelCatalog(
          _loadProviderModelCatalogSync(config.providerId),
          modelCatalog,
        ) ||
        !_modelMutationMatches(modelBindings)) {
      return null;
    }
    final rows = _database.select(
      '''
        SELECT lease_id, operation_id, operation_kind, previous_snapshot_json
        FROM provider_configuration_mutations
        WHERE provider_id = ? AND new_revision = ?
      ''',
      [config.providerId, intendedRevision],
    );
    if (rows.length != 1 ||
        rows.single['operation_kind'] != expectedKind.name) {
      return null;
    }
    final previous = _decodeMutationSnapshot(
      rows.single['previous_snapshot_json']! as String,
    );
    final expectedAbsent = expectedRevision == null;
    if (expectedAbsent
        ? previous.config != null || previous.revision != null
        : previous.config?.providerId != config.providerId ||
              previous.revision != expectedRevision) {
      return null;
    }
    return (
      leaseId: rows.single['lease_id']! as String,
      operationId: PendingProviderOperationId.parse(
        rows.single['operation_id']! as String,
      ),
    );
  }

  ({String leaseId, PendingProviderOperationId operationId})
  _newPendingIdentity() {
    final row = _database.select('''
      SELECT lower(hex(randomblob(32))) AS lease_id,
             lower(hex(randomblob(32))) AS operation_id
    ''').single;
    return (
      leaseId: row['lease_id']! as String,
      operationId: PendingProviderOperationId.parse(
        row['operation_id']! as String,
      ),
    );
  }

  Row _requireProviderMutationLease(_SqliteProviderMutationLease lease) {
    final rows = _database.select(
      '''
        SELECT operation_id, provider_id, operation_kind, new_revision,
               created_at_ms, state, previous_snapshot_json,
               applied_config_json,
               applied_bindings_json
        FROM provider_configuration_mutations WHERE lease_id = ?
      ''',
      [lease._leaseId],
    );
    if (rows.length != 1 ||
        rows.single['operation_id'] != lease.operationId.value ||
        rows.single['provider_id'] != lease.providerId ||
        rows.single['new_revision'] != lease.newRevision.value) {
      throw const ProviderConfigurationMutationException(
        ProviderConfigurationMutationErrorCode.invalidLease,
      );
    }
    return rows.single;
  }

  void _restoreOwnershipForRollback(
    ProviderConfig current,
    ProviderConfig? previous,
    int retiredRevision,
  ) {
    final currentBindings = providerCredentialBindings(current);
    final previousBindings = previous == null
        ? const <String, SecretRef>{}
        : providerCredentialBindings(previous);
    for (final entry in currentBindings.entries) {
      if (previousBindings[entry.key] != entry.value) {
        _retireOwnership(
          current.providerId,
          entry.key,
          entry.value,
          retiredRevision,
        );
      }
    }
    for (final entry in previousBindings.entries) {
      if (currentBindings[entry.key] != entry.value) {
        _insertOwnership(previous!.providerId, entry.key, entry.value);
      }
    }
  }

  String _requiredIdentifier(String value, String name) {
    if (!isCanonicalRuntimeId(value)) {
      throw ArgumentError.value(value, name);
    }
    return value;
  }

  void _validatePersistableRef(SecretRef? ref) {
    if (ref == null) return;
    ProviderSecretRefPolicy.validate(ref);
  }

  void _insertOwnership(String providerId, String slot, SecretRef ref) {
    final locator = ref.locator.toString();
    final existing = _database.select(
      '''
        SELECT secret_ref, provider_id, credential_slot, state
        FROM credential_bindings
        WHERE secret_ref = ? OR (
          provider_id = ? AND credential_slot = ? AND state = 'active'
        )
      ''',
      [locator, providerId, slot],
    );
    if (existing.isNotEmpty) {
      if (existing.length == 1 &&
          existing.single['secret_ref'] == locator &&
          existing.single['provider_id'] == providerId &&
          existing.single['credential_slot'] == slot) {
        if (existing.single['state'] == 'active') return;
        _database.execute(
          '''
            UPDATE credential_bindings
            SET state = 'active', retired_revision = NULL
            WHERE secret_ref = ?
          ''',
          [locator],
        );
        return;
      }
      throw StateError('Provider credential ownership conflict');
    }
    _database.execute(
      '''
        INSERT INTO credential_bindings (
          secret_ref, provider_id, credential_slot, state, retired_revision
        ) VALUES (?, ?, ?, 'active', NULL)
      ''',
      [locator, providerId, slot],
    );
  }

  void _validateOwnership(String providerId, String slot, SecretRef ref) {
    final rows = _database.select(
      '''
        SELECT provider_id, credential_slot, state
        FROM credential_bindings
        WHERE secret_ref = ?
      ''',
      [ref.locator.toString()],
    );
    if (rows.length != 1 ||
        rows.single['provider_id'] != providerId ||
        rows.single['credential_slot'] != slot ||
        rows.single['state'] != 'active') {
      throw StateError('Invalid provider credential ownership');
    }
  }

  void _requireOpen() {
    if (_closed) {
      throw StateError('Provider configuration store is closed');
    }
  }

  @override
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    final closeFuture = Future<void>.sync(() {
      if (_closed) return;
      _closed = true;
      _recoveredOperations.clear();
      _database.close();
    });
    _closeFuture = closeFuture;
    return closeFuture;
  }
}

abstract class _SqliteProviderMutationLease
    implements ProviderConfigurationMutationLease {
  const _SqliteProviderMutationLease(
    this._leaseId,
    this.operationId,
    this.providerId,
    this.newRevision,
  );

  final String _leaseId;
  @override
  final PendingProviderOperationId operationId;
  @override
  final String providerId;
  @override
  final ProviderConfigurationRevision newRevision;
}

final class _SqliteProviderCredentialRotationResult
    extends _SqliteProviderMutationLease
    implements ProviderCredentialRotationResult {
  const _SqliteProviderCredentialRotationResult(
    String leaseId,
    PendingProviderOperationId operationId,
    String providerId,
    this.slot,
    this.oldRefForCleanup,
    ProviderConfigurationRevision newRevision,
  ) : super(leaseId, operationId, providerId, newRevision);

  @override
  final ProviderCredentialSlot slot;
  @override
  final SecretRef oldRefForCleanup;
}

final class _SqliteProviderConfigurationReplacementResult
    extends _SqliteProviderMutationLease
    implements ProviderConfigurationReplacementResult {
  _SqliteProviderConfigurationReplacementResult(
    String leaseId,
    PendingProviderOperationId operationId,
    this.configuration,
  ) : super(
        leaseId,
        operationId,
        configuration.config.providerId,
        configuration.revision,
      );

  @override
  final VersionedProviderConfiguration configuration;
}

final class _RecoveredSqliteProviderMutationLease
    extends _SqliteProviderMutationLease {
  const _RecoveredSqliteProviderMutationLease(
    super.leaseId,
    super.operationId,
    super.providerId,
    super.newRevision,
  );
}

final class _SqliteProviderRemovalLease implements ProviderRemovalLease {
  const _SqliteProviderRemovalLease(
    this._leaseId,
    this.operationId,
    this.providerId,
    this.removedRevision,
  );

  final String _leaseId;
  @override
  final PendingProviderOperationId operationId;
  @override
  final String providerId;
  @override
  final ProviderConfigurationRevision removedRevision;
}

final class _SqlitePendingProviderOperationRecovery
    implements PendingProviderOperationRecovery {
  const _SqlitePendingProviderOperationRecovery(
    this.descriptor,
    this.mutationLease,
    this.removalLease,
  );

  @override
  final PendingProviderOperationDescriptor descriptor;
  @override
  final ProviderConfigurationMutationLease? mutationLease;
  @override
  final ProviderRemovalLease? removalLease;
}

final class _ProviderRemovalSnapshot {
  const _ProviderRemovalSnapshot(
    this.config,
    this.revision,
    this.bindings,
    this.modelCatalog,
  );

  final ProviderConfig config;
  final ProviderConfigurationRevision revision;
  final List<_RemovalModelBinding> bindings;
  final PersistedProviderModelCatalog? modelCatalog;
}

final class _RemovalModelBinding {
  const _RemovalModelBinding(this.scope, this.scopeId, this.modelId);

  factory _RemovalModelBinding.fromJson(Map<String, Object?> json) =>
      _RemovalModelBinding(
        json['scope']! as String,
        json['scopeId']! as String,
        json['modelId']! as String,
      );

  final String scope;
  final String scopeId;
  final String modelId;
}

final class _ProviderMutationSnapshot {
  const _ProviderMutationSnapshot(
    this.config,
    this.revision,
    this.bindings,
    this.modelCatalog,
  );

  final ProviderConfig? config;
  final ProviderConfigurationRevision? revision;
  final List<_AllModelBinding> bindings;
  final PersistedProviderModelCatalog? modelCatalog;
}

final class _AppliedProviderMutationSnapshot {
  const _AppliedProviderMutationSnapshot(this.config, this.modelCatalog);

  final ProviderConfig config;
  final PersistedProviderModelCatalog? modelCatalog;
}

final class _AllModelBinding {
  const _AllModelBinding(
    this.scope,
    this.scopeId,
    this.providerId,
    this.modelId,
  );

  factory _AllModelBinding.fromJson(Map<String, Object?> json) =>
      _AllModelBinding(
        json['scope']! as String,
        json['scopeId']! as String,
        json['providerId']! as String,
        json['modelId']! as String,
      );

  final String scope;
  final String scopeId;
  final String providerId;
  final String modelId;
}
