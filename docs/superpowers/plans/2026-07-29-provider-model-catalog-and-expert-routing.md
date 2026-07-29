# Provider Model Catalog and Expert Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fetch and persist every Provider model when an API Key is saved, let the user select a global default model, and let each installed expert either inherit that default or use an explicit model.

**Architecture:** Extend the trusted Provider SQLite store to schema v4 so configuration, model catalogs, pending mutations, global bindings, and expert overrides remain consistent. Add a production `GET /models` transport on top of the existing pinned-DNS/TLS HTTP boundary. Keep Provider configuration, global model selection, and per-expert selection behind narrow controllers injected through `ApplicationKernel`.

**Tech Stack:** Flutter/Dart, sqlite3, iOS Keychain, existing `SecureJsonHttpClient`, `ModelCatalogDiscovery`, GoRouter, Flutter widget tests.

## Global Constraints

- No production model ID may be hardcoded.
- Saving a Key persists every validated model returned by the Provider.
- Provider detail contains no editable model ID.
- Global default is selected from persisted models.
- Each installed expert supports “跟随全局默认” or one explicit persisted model.
- API Keys remain Keychain-only and never appear in SQLite, logs, exceptions, or widget state.
- A failed discovery or runtime reload preserves the previous config, catalog, bindings, and Key.
- Tests must follow RED → GREEN; no production implementation is written before the corresponding failing test.

---

### Task 1: Schema v4 Persisted Model Catalog

**Files:**
- Modify: `apps/mobile/lib/model_runtime/provider_configuration_store.dart`
- Modify: `apps/mobile/lib/model_runtime/sqlite_provider_configuration_store.dart`
- Modify: `apps/mobile/lib/model_runtime/production_model_runtime_factory.dart`
- Modify: `apps/mobile/lib/model_runtime/model_runtime.dart`
- Modify: `apps/mobile/test/model_runtime/provider_configuration_store_test.dart`
- Modify: `apps/mobile/test/model_runtime/production_model_runtime_factory_test.dart`

**Interfaces:**
- Produces:

```dart
@immutable
class PersistedProviderModelCatalog {
  PersistedProviderModelCatalog({
    required this.providerId,
    required List<ModelDescriptor> models,
    required this.discoveredAt,
  }) : models = List.unmodifiable(models);

  final String providerId;
  final List<ModelDescriptor> models;
  final DateTime discoveredAt;
}

abstract interface class ProviderModelCatalogStore {
  Future<PersistedProviderModelCatalog?> loadProviderModelCatalog(
    String providerId,
  );
  Future<List<PersistedProviderModelCatalog>> loadAllProviderModelCatalogs();
}
```

- Extends `ProviderConfigurationReplacement` with a required catalog for settings-driven create/replace/rotate operations:

```dart
final PersistedProviderModelCatalog? modelCatalog;
```

- `ProductionModelRuntimeFactory` loads catalogs from the same opened store when it implements `ProviderModelCatalogStore`; no fallback model IDs are synthesized.

- [ ] **Step 1: Write failing persistence tests**

Add literal fixtures for DeepSeek models `deepseek-chat` and `deepseek-reasoner`. Assert:

```dart
final reopened = SqliteProviderConfigurationStore.open(path);
final catalog = await reopened.loadProviderModelCatalog('deepseek');
expect(catalog!.models.map((model) => model.ref.modelId), [
  'deepseek-chat',
  'deepseek-reasoner',
]);
```

Add tests proving v3 → v4 preserves Provider config and bindings, pending rollback restores the prior catalog, removal restore restores its catalog, and a catalog replacement clears only bindings that reference removed models.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
cd /Users/cofe/IOS-IM/apps/mobile
flutter test test/model_runtime/provider_configuration_store_test.dart
```

Expected: compile failure because `PersistedProviderModelCatalog` and catalog APIs do not exist.

- [ ] **Step 3: Implement schema v4 and catalog validation**

Add `provider_models` keyed by `(provider_id, model_id)` with capability columns and UTC discovery time. Extend pending mutation/removal snapshots so rollback/restore includes the exact prior catalog. Validate model IDs, display names, capabilities, uniqueness, Provider ownership, timestamps, table columns, indexes, foreign keys, strict mode, and CHECK constraints using the existing behavioral-probe pattern.

- [ ] **Step 4: Write failing runtime tests**

Assert `ProductionModelRuntimeFactory.create()` resolves both persisted DeepSeek models and rejects an enabled Provider whose persisted catalog is absent or empty. The production loader must not return `gpt-5-mini` or `deepseek-chat` unless that ID exists in SQLite.

- [ ] **Step 5: Implement persisted runtime loading**

Use the configuration store opened by the factory as `ProviderModelCatalogStore`. Build each Provider adapter with that Provider’s persisted descriptors. Keep `ModelRef(providerId, modelId)` validation in `ProviderRegistry`.

- [ ] **Step 6: Verify focused tests**

Run:

```bash
flutter test test/model_runtime/provider_configuration_store_test.dart \
  test/model_runtime/production_model_runtime_factory_test.dart
flutter analyze lib/model_runtime test/model_runtime
```

Expected: all tests pass and analysis reports no issues.

- [ ] **Step 7: Commit**

```bash
git add apps/mobile/lib/model_runtime/provider_configuration_store.dart \
  apps/mobile/lib/model_runtime/sqlite_provider_configuration_store.dart \
  apps/mobile/lib/model_runtime/production_model_runtime_factory.dart \
  apps/mobile/lib/model_runtime/model_runtime.dart \
  apps/mobile/test/model_runtime/provider_configuration_store_test.dart \
  apps/mobile/test/model_runtime/production_model_runtime_factory_test.dart
git commit -m "feat: persist provider model catalogs"
```

### Task 2: Secure Production `GET /models`

**Files:**
- Modify: `apps/mobile/lib/model_runtime/unary_http_transport.dart`
- Modify: `apps/mobile/lib/model_runtime/testing/fake_unary_http_adapter.dart`
- Create: `apps/mobile/lib/model_runtime/production_provider_inspection_transport.dart`
- Modify: `apps/mobile/lib/model_runtime/model_runtime.dart`
- Modify: `apps/mobile/test/model_runtime/unary_http_security_test.dart`
- Create: `apps/mobile/test/model_runtime/production_provider_inspection_transport_test.dart`

**Interfaces:**
- Produces:

```dart
Future<SecureJsonHttpResponse> getJson({
  required Uri endpoint,
  required Map<String, String> headers,
  required Set<String> sensitiveHeaderNames,
  required CancellationToken cancellationToken,
});

final class ProductionProviderInspectionTransport
    implements ProviderInspectionTransport {
  ProductionProviderInspectionTransport({required SecureJsonHttpClient client});
}
```

- `discoverModels` accepts only enabled ToAPIs and DeepSeek configs in this release, requests exactly `<baseUri>/models`, and returns `UpstreamModelMetadata` for every valid `data[*].id`.

- [ ] **Step 1: Write failing HTTP boundary tests**

Add tests proving GET is accepted, lowercase/whitespace/CRLF methods are rejected, GET sends no body, sensitive headers are never retained by the safe fake, redirect remains disabled, cancellation aborts the request, and existing DNS/TLS/SNI endpoint policy still runs.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
flutter test test/model_runtime/unary_http_security_test.dart
```

Expected: failure because only canonical POST is currently allowed and `getJson` is absent.

- [ ] **Step 3: Implement canonical GET support**

Change the internal method allowlist to exactly `GET` and `POST`. `postJson` continues to send JSON bytes; `getJson` requires an empty body and does not set `content-type`. Both paths reuse the existing connect, response, size, compression, JSON depth, cancellation, and redaction controls.

- [ ] **Step 4: Write failing Provider inspection tests**

Use a real `ProductionProviderInspectionTransport` over a fake HTTP adapter. Assert a literal OpenAI-compatible response:

```json
{
  "object": "list",
  "data": [
    {"id": "deepseek-chat", "object": "model"},
    {"id": "deepseek-reasoner", "object": "model"}
  ]
}
```

becomes two metadata rows in upstream order. Add 401, 429, 500, malformed root, missing ID, duplicate ID, wrong endpoint, cancellation, and credential-redaction cases.

- [ ] **Step 5: Implement production inspection transport**

Send `Authorization: Bearer <ephemeral credential>` only after endpoint validation. Map HTTP errors through fixed safe `ModelRuntimeException` values. Never store or print the credential or upstream error body. Mark discovered entries as confirmed text/system/temperature capable for the supported OpenAI-compatible chat Providers; do not invent image, video, or tool capabilities.

- [ ] **Step 6: Verify focused tests**

Run:

```bash
flutter test test/model_runtime/unary_http_security_test.dart \
  test/model_runtime/production_provider_inspection_transport_test.dart \
  test/model_runtime/model_catalog_discovery_test.dart
flutter analyze lib/model_runtime test/model_runtime
```

Expected: all tests pass and analysis reports no issues.

- [ ] **Step 7: Commit**

```bash
git add apps/mobile/lib/model_runtime/unary_http_transport.dart \
  apps/mobile/lib/model_runtime/testing/fake_unary_http_adapter.dart \
  apps/mobile/lib/model_runtime/production_provider_inspection_transport.dart \
  apps/mobile/lib/model_runtime/model_runtime.dart \
  apps/mobile/test/model_runtime/unary_http_security_test.dart \
  apps/mobile/test/model_runtime/production_provider_inspection_transport_test.dart
git commit -m "feat: fetch provider model catalogs"
```

### Task 3: Save Key With Complete Model Discovery

**Files:**
- Modify: `apps/mobile/lib/features/settings/provider_settings_controller.dart`
- Modify: `apps/mobile/lib/features/settings/provider_settings_persistence.dart`
- Modify: `apps/mobile/lib/features/settings/provider_detail_page.dart`
- Modify: `apps/mobile/lib/app/production_app_kernel.dart`
- Modify: `apps/mobile/test/features/settings/provider_settings_controller_test.dart`
- Modify: `apps/mobile/test/features/settings/provider_settings_persistence_test.dart`
- Modify: `apps/mobile/test/features/settings/provider_detail_page_test.dart`
- Modify: `apps/mobile/test/app/production_app_kernel_test.dart`

**Interfaces:**
- Produces:

```dart
abstract interface class ProviderModelCatalogFetcher {
  Future<PersistedProviderModelCatalog> fetch(ProviderConfig config);
}

@immutable
class ProviderSettingsDraft {
  const ProviderSettingsDraft({
    required this.providerId,
    required this.apiKey,
    required this.enabled,
  });
}
```

- `ProviderSettingsSnapshot` contains `config` and `catalog`; it no longer owns a manually entered model.
- `ProviderSettingsController.refreshCatalog(providerId)` fetches and atomically replaces the complete directory using the existing credential reference.

- [ ] **Step 1: Write failing controller transaction tests**

Assert the exact order is Keychain set → fetch catalog → staged persistence replace → runtime reload → finalize → old Key delete. Add failures at fetch, persistence, reload, finalize, and old-Key cleanup. Fetch failure must leave the old snapshot and old Key intact and delete the new Key.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
flutter test test/features/settings/provider_settings_controller_test.dart \
  test/features/settings/provider_settings_persistence_test.dart
```

Expected: compile failure because `ProviderModelCatalogFetcher` and catalog snapshots are absent.

- [ ] **Step 3: Implement catalog-aware save and refresh**

After writing the new Keychain value, build the canonical Provider config and fetch all models through `ModelCatalogDiscovery`. Reject empty catalogs. Pass the validated catalog into the staged SQLite replacement. On refresh, retain the existing Keychain ref and replace only the complete catalog plus affected bindings.

- [ ] **Step 4: Write failing Provider page tests**

Assert:

- no widget with text `默认模型 ID`;
- saving text is `正在验证并获取模型…`;
- configured page displays `已获取 2 个模型`;
- refresh is enabled only after configuration;
- API Key value is cleared after successful save and never rendered.

- [ ] **Step 5: Implement Provider page UI**

Remove `_modelController` and the model-ID field. Render catalog count and timestamp from controller state. Wire “刷新模型目录” to `refreshCatalog`.

- [ ] **Step 6: Wire production discovery**

Replace `_UnavailableInspectionTransport` and `_loadProductionModels` in `production_app_kernel.dart` with `ProductionProviderInspectionTransport` and the persisted catalog loader from Task 1. Use the same trusted host allowlist already used by production chat.

- [ ] **Step 7: Verify focused tests**

Run:

```bash
flutter test test/features/settings test/app/production_app_kernel_test.dart
flutter analyze lib/app lib/features/settings test/app test/features/settings
```

Expected: all tests pass and analysis reports no issues.

- [ ] **Step 8: Commit**

```bash
git add apps/mobile/lib/features/settings/provider_settings_controller.dart \
  apps/mobile/lib/features/settings/provider_settings_persistence.dart \
  apps/mobile/lib/features/settings/provider_detail_page.dart \
  apps/mobile/lib/app/production_app_kernel.dart \
  apps/mobile/test/features/settings \
  apps/mobile/test/app/production_app_kernel_test.dart
git commit -m "feat: discover models when saving provider keys"
```

### Task 4: Global Default and Per-Expert Model Selection

**Files:**
- Create: `apps/mobile/lib/features/settings/model_routing_controller.dart`
- Create: `apps/mobile/lib/features/settings/model_picker_sheet.dart`
- Modify: `apps/mobile/lib/features/settings/model_providers_page.dart`
- Modify: `apps/mobile/lib/features/expert_market/expert_profile_page.dart`
- Modify: `apps/mobile/lib/app/app_kernel.dart`
- Modify: `apps/mobile/lib/app/production_app_kernel.dart`
- Modify: `apps/mobile/lib/app/router.dart`
- Create: `apps/mobile/test/features/settings/model_routing_controller_test.dart`
- Create: `apps/mobile/test/features/settings/model_picker_sheet_test.dart`
- Modify: `apps/mobile/test/features/provider_settings_test.dart`
- Create: `apps/mobile/test/features/expert_profile_model_routing_test.dart`
- Modify: `apps/mobile/test/app/router_injection_test.dart`

**Interfaces:**
- Produces:

```dart
@immutable
class AvailableModelOption {
  const AvailableModelOption({
    required this.ref,
    required this.providerName,
    required this.modelName,
  });

  final ModelRef ref;
  final String providerName;
  final String modelName;
}

abstract interface class ModelRoutingPersistence {
  Future<List<AvailableModelOption>> loadAvailableModels();
  Future<ModelRef?> loadGlobalDefault();
  Future<void> setGlobalDefault(ModelRef model);
  Future<ModelRef?> loadExpertOverride(String expertId);
  Future<void> setExpertOverride(String expertId, ModelRef? model);
}
```

- `ModelRoutingController` exposes immutable available models, the global default, and expert overrides. Every write validates that the selected `ModelRef` is present in the persisted catalog, writes the binding, and reloads the runtime.

- [ ] **Step 1: Write failing controller tests**

Assert global selection persists and reloads; unknown models are rejected; an expert without override resolves to the current global model; explicit override wins; setting `null` removes the override; failed reload restores the prior binding.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
flutter test test/features/settings/model_routing_controller_test.dart
```

Expected: compile failure because the controller and persistence contract do not exist.

- [ ] **Step 3: Implement routing controller and production adapter**

Adapt `SqliteProviderConfigurationStore` catalog reads plus existing `load/setGlobalDefaultModel` and `load/setAgentModelOverride`. Serialize writes through one controller-owned FIFO and reuse `ProviderRuntimeReloader`.

- [ ] **Step 4: Write failing global picker widget tests**

Assert the models are grouped by Provider, every saved model appears, search filters by display name and model ID, the selected global model has a checkmark, and choosing an item updates the “默认文字模型” row.

- [ ] **Step 5: Implement shared model picker and global row**

Use one bottom sheet for global and expert selection. Global mode requires a concrete model. Remove inert `onTap: () {}` from “默认文字模型” and wire it to the picker.

- [ ] **Step 6: Write failing expert profile tests**

Assert an installed expert profile displays:

```text
模型
跟随默认 · DeepSeek / deepseek-chat
```

After choosing an override, assert:

```text
独立 · ToAPIs / selected-model-id
```

Choosing “跟随全局默认” must persist `null`. Market-mode profiles must not show an editable routing row.

- [ ] **Step 7: Implement expert profile routing**

Inject `ModelRoutingController` through `AppDependencies` and router builders. Add the model row to the installed expert’s “专家与动态” settings group. Use the canonical executable expert ID used by chat routing, not fixture display IDs.

- [ ] **Step 8: Verify focused tests**

Run:

```bash
flutter test test/features/settings/model_routing_controller_test.dart \
  test/features/settings/model_picker_sheet_test.dart \
  test/features/expert_profile_model_routing_test.dart \
  test/app/router_injection_test.dart
flutter analyze lib/app lib/features/settings \
  lib/features/expert_market test/app test/features
```

Expected: all tests pass and analysis reports no issues.

- [ ] **Step 9: Commit**

```bash
git add apps/mobile/lib/features/settings/model_routing_controller.dart \
  apps/mobile/lib/features/settings/model_picker_sheet.dart \
  apps/mobile/lib/features/settings/model_providers_page.dart \
  apps/mobile/lib/features/expert_market/expert_profile_page.dart \
  apps/mobile/lib/app/app_kernel.dart \
  apps/mobile/lib/app/production_app_kernel.dart \
  apps/mobile/lib/app/router.dart \
  apps/mobile/test/features \
  apps/mobile/test/app/router_injection_test.dart
git commit -m "feat: select global and expert models"
```

### Task 5: Integration and Real DeepSeek Acceptance

**Files:**
- No production files are owned by this task. A failure is returned to the
  owning Task 1–4 file list and fixed with a new RED → GREEN cycle there.
- Test: `apps/mobile/test/model_runtime/`
- Test: `apps/mobile/test/features/settings/`
- Test: `apps/mobile/test/features/single_chat_controller_test.dart`
- Test: `apps/mobile/test/app/`

**Interfaces:**
- Consumes all contracts from Tasks 1–4.
- Produces a simulator build where a real saved DeepSeek Key discovers models, persists them across restart, selects a default, assigns an expert override, and completes a real single chat using the selected model.

- [ ] **Step 1: Run full automated verification**

```bash
cd /Users/cofe/IOS-IM/apps/mobile
flutter test --concurrency=1
flutter analyze
git diff --check
```

Expected: zero failed tests, no analyzer issues, and no whitespace errors.

- [ ] **Step 2: Run the simulator acceptance flow**

Use simulator `4569A31A-A611-4ABE-901B-A3B95A330128`:

1. Save the existing DeepSeek Key without entering a model ID.
2. Confirm at least `deepseek-chat` is shown in the persisted directory.
3. Kill and relaunch the app; confirm the model list remains.
4. Select `deepseek-chat` as global default.
5. Set 产品经理 to follow global and complete one real chat.
6. Set 技术架构师 to an explicit available model and confirm `resolveConfiguredModel(agentId: 'technical-architect')` returns that exact `ModelRef`.

- [ ] **Step 3: Build the iOS app**

```bash
flutter build ios --debug --simulator
```

Expected: exit code 0.

- [ ] **Step 4: Commit verified integration fixes**

Stage only files changed for this feature and create:

```bash
git commit -m "test: verify dynamic model routing"
```
