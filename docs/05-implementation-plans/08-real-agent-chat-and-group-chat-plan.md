# Real Agent Chat And Group Chat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` or `superpowers:executing-plans`.
> Every production change follows red-green-refactor and receives an independent
> review before commit.

**Goal:** 在现有真实 Provider 单聊基础上完成 durable 单聊收口，并把已完成的
本地 durable 群聊编排接入生产 Provider，使单聊和群聊都使用用户本机 Keychain
密钥、多 Provider 模型运行时和可执行专家 Prompt Package。

**Architecture:** `ApplicationKernelHost` 管理
`ProductionAppKernelFactory` 的异步创建、替换和关闭；生产 AppKernel 通过
`ProductionModelRuntimeFactory` 构建 Provider Registry，并向页面注入
`SingleChatPort`、聊天仓储和 Provider 设置控制器。当前
`ProductionSingleChatPort` 已能执行真实 Provider 单聊，单聊消息与命令 Outbox
已由 Drift/File durable 仓储持久化并注入 production AppKernel；群聊已具备本地
durable 编排合同，生产 AppKernel 和 Router 尚未注入 production group port。
目标状态是单聊和群聊都经过本地
`OrchestrationKernel`，聊天消息、Run 事件和输入引用分别持久化。

**Tech Stack:** Flutter、Dart、Riverpod、Drift/SQLite、iOS Keychain、
OpenAI-compatible/OpenAI/Anthropic/Gemini HTTPS Adapter、Flutter Test、
XCTest。

## Global Constraints

- 不提供 Halo 账户、登录或平台计费；用户无需注册即可进入应用，自托管 Gateway
  始终可选，不能成为本地直连模型对话的前置条件。
- 第一阶段只开放非流式文字对话；图片、文件、语音和视频不伪装为已接通。
- iPhone P0 production catalog 只开放 ToAPIs 和 DeepSeek。自定义
  OpenAI-compatible、OpenAI、Anthropic、Gemini Adapter 属于已具备的底层能力，
  在各自配置、目录发现和真机验收完成前不得标为生产可用。
- 所有 Provider 使用同一 `providerId + modelId` 强类型引用，禁止只按模型名
  路由。
- Key 只写入 iOS Keychain；SQLite、Event、日志、异常和 `toString()` 禁止出现
  Key、完整 Prompt、私有记忆正文和上游错误正文。
- 单聊也必须通过 `OrchestrationKernel`，固定执行当前专家，不走页面直连模型。
- 群聊 `auto` 只选 1–2 个成员，`mentioned` 只执行被点名成员，`all` 按冻结成员
  顺序执行、允许受预算约束的补充/反驳并生成总结。
- 模型输出必须携带来源类型：`modelOutput`、`verifiedEvidence` 或
  `userVisibleSummary`；没有证据的事实结论显示“未核验”，不能包装成已证实。
- 所有写操作支持取消、超时、失败重试和幂等；终态 Run 不得复活。
- 真实 Key 烟测仅使用低额度测试 Key，不进入自动化测试和仓库。

---

## Current Gap Baseline

| Area | Completed | Blocking gap |
|---|---|---|
| iOS shell | 四栏页面、Release 构建签名；`ApplicationKernelHost` 已管理 production kernel 生命周期 | readiness 仍通过 unavailable kernel 回退表达，尚无独立 missing-provider 页面状态 |
| Provider settings | Keychain bridge、SQLite 非敏感配置、保存/移除、失败回滚和 runtime reload 已接入 | 连接测试、模型目录刷新和独立启停 UI 仍明确不可用 |
| Model runtime | `ProductionModelRuntimeFactory`、Registry、健康检查、原生与兼容 Adapter 已完成；`ProductionAppKernelFactory` 已创建并持有 runtime | P0 production catalog 仅 ToAPIs、DeepSeek；其他 Adapter 尚未完成配置入口、目录和真机开放 |
| Orchestration | `BasicDurableRunner`、SQLite Event Store、`auto / mentioned / all` 和 production/testing factory 合同已完成 | 默认 Riverpod provider 仍是 `InMemoryRunEventStore + LocalPrototypeAgentRuntime`；真实 Provider-backed Agent runtime 尚未接入 |
| Single chat | `SingleChatPort`、`ProductionSingleChatPort`、真实 Provider 调用、Drift 消息仓储、File command Outbox、恢复与 AppKernel/Router 注入已完成 | 当前 production port 仍直连 model runtime，尚未迁入 `OrchestrationKernel` |
| Group chat | Controller 已消费 Run Event；五人原型成员、本地 durable 三模式编排与测试已完成 | Router 仍直接构造无 production run port 的 `GroupChatPage`，成员和历史仍为 prototype repository |
| Experts | 已有可执行 Prompt Package 和扩展目录 | UI 的 50 位专家尚未全部拥有可执行包、模型绑定和评测 |
| Truthfulness | Claim/Evidence/Verifier 文档与事件来源约束 | 尚未接入真实对话执行链和 UI 标记 |
| Media/files | 原型入口和消息卡片 | 本地文件资产库、上传、模型产物落盘未实现 |
| Voice/video | 原型页面 | 豆包端到端语音、TTS、Vidu 视频均未接生产服务 |

---

### Task 1: Finish Provider Settings Inspection Actions

**Status:** 持久化、Keychain、保存/移除、恢复和 runtime reload 已完成；本任务只
覆盖仍禁用的连接测试、目录刷新和独立启停行为。

**Files:**

- Modify: `apps/mobile/lib/model_runtime/provider_inspection_transport.dart`
- Modify: `apps/mobile/lib/features/settings/provider_settings_controller.dart`
- Modify: `apps/mobile/lib/features/settings/provider_detail_page.dart`
- Test: `apps/mobile/test/model_runtime/provider_health_probe_test.dart`
- Test: `apps/mobile/test/model_runtime/model_catalog_discovery_test.dart`
- Test: `apps/mobile/test/features/provider_settings_test.dart`

**Interfaces:**

- Produces connection-test, catalog-refresh and enabled-state actions on the
  existing `ProviderSettingsController`.
- Consumes the existing `ProviderConfigurationStore`,
  `MethodChannelSecureCredentialStore`, `ProductionModelRuntimeFactory` and a
  production `ProviderInspectionTransport`.

- [x] Persist only `SecretRef` and non-sensitive Provider configuration in
      SQLite; keep Key bytes in `SecureCredentialStore`.
- [x] Connect save/remove to `ProviderSettingsController` with recovery,
      rollback and runtime reload.
- [ ] Write failing tests for connection test, catalog refresh and independent
      enable/disable actions for ToAPIs and DeepSeek.
- [ ] Implement a production inspection transport without displaying upstream
      response bodies.
- [ ] Replace the three disabled actions on `ProviderDetailPage` with the tested
      controller operations.
- [ ] Add loading, auth failure, quota failure, invalid endpoint and saved states
      without displaying upstream response bodies.
- [ ] Re-run focused tests, then
      `flutter analyze lib/model_runtime lib/features/settings`.

### Task 2: Production Model Runtime Factory

**Status:** Core implementation and tests are complete. P0 exposure remains
intentionally limited to ToAPIs and DeepSeek.

**Files:**

- Existing: `apps/mobile/lib/model_runtime/production_model_runtime_factory.dart`
- Existing: `apps/mobile/lib/model_runtime/model_runtime_providers.dart`
- Test: `apps/mobile/test/model_runtime/production_model_runtime_factory_test.dart`

**Interfaces:**

- Produces:
  `Future<ProductionModelRuntime> ProductionModelRuntimeFactory.create()`。
- `ProductionModelRuntime` owns a `ProviderRegistry`, catalog discovery, health
  probes and a `Future<void> close()` lifecycle.
- Consumes enabled `ProviderConfig`, `KeychainSecretResolver`,
  `SecureJsonHttpClient` and the four production unary transports.

- [x] Write tests for mixed compatible/native Provider registration,
      unknown model rejection, disabled Provider rejection and close idempotency.
- [x] Implement protocol-specific Provider construction using the already
      validated model descriptors; never infer Provider from a model name.
- [x] Add factory initialization rollback so a partial Provider set and opened
      stores are closed if any configuration fails.
- [x] Wire `ProductionModelRuntimeFactory` into
      `ProductionAppKernelFactory`.
- [ ] Keep AppKernel catalog exposure at ToAPIs and DeepSeek until each
      additional Adapter has a production configuration flow, catalog and
      iPhone acceptance evidence.

### Task 3: Provider-Backed Executable Agent Runtime

**Status:** 已实现但未接线（2026-07-30 核对）。
`provider_backed_agent_runtime.dart`、`agent_execution_policy.dart`、
`sqlite_model_call_journal.dart` 及其测试都已存在，实现了
`IdempotentAgentRuntimeCapability`、可信输出信封、超时取消、安全失败码映射和
计费围栏。真正的缺口是**它们在 `lib/` 里零引用**：
`orchestration_providers.dart` 仍默认 `InMemoryRunEventStore +
LocalPrototypeAgentRuntime`，`ProductionAppKernelFactory` 从不构造
`OrchestrationKernelFactory.production`。现有 production 单聊仍由
`ProductionSingleChatPort` 直接调用 `ProductionModelRuntime`。

两个已知偏差需要在接线时一并处理：`_expertSystemPrompt` 不下发输出 schema 模板和
受控 verb 白名单（真实 Provider 极可能因此返回不合规 JSON 而整轮静默丢弃），以及
把字符预算 `maxPublicAnswerCharacters` 传给了 token 字段 `maxOutputTokens`。

**Files:**

- Create: `apps/mobile/lib/orchestration/provider_backed_agent_runtime.dart`
- Create: `apps/mobile/lib/orchestration/agent_execution_policy.dart`
- Create: `apps/mobile/lib/orchestration/sqlite_model_call_journal.dart`
- Test: `apps/mobile/test/orchestration/provider_backed_agent_runtime_test.dart`
- Test: `apps/mobile/test/orchestration/sqlite_model_call_journal_test.dart`

**Interfaces:**

- Produces `ProviderBackedAgentRuntime implements AgentRuntime`.
- Consumes:
  `ChatModelRuntime.chat(ChatRequest)`、
  `ExpertPromptPackage`、
  `ModelRef`、
  `AgentTurnRequest.idempotencyKey`。
- `respond()` emits bounded public text; `summarize()` uses a dedicated
  summarizer package and cannot silently reuse a participant identity.
- `SqliteModelCallJournal` uses the idempotency key to persist
  `reserved / dispatched / completed / failed / outcomeUnknown`; a repeated
  completed call returns the stored public result, while a crash after dispatch
  fails closed as `outcomeUnknown` and never automatically bills the Provider
  a second time.

- [ ] Write failing tests for system prompt composition, expert identity,
      conversation input, bounded shared context and per-expert model override.
- [ ] Write failing tests proving disabled tools, private memory, raw Key and
      full upstream errors never enter `ChatRequest` or public events.
- [ ] Write failing tests for timeout, cancellation, content filtering, quota,
      retryability and malformed model output.
- [ ] Implement the minimum adapter using the existing unary
      `ChatModelRuntime`; do not add real tool calls in this task.
- [ ] Write red-green crash-window tests proving a repeated idempotency key
      cannot issue a second Provider call after `dispatched`, even when no
      response was durably recorded.
- [ ] Add a truthful-output envelope containing answer text, uncertainty and
      evidence references; unsupported factual claims remain `unverified`.
- [ ] Run focused tests, all orchestration tests and `flutter analyze`.

### Task 4: Real Single-Agent Conversation

**Status:** `SingleChatPort`、`ProductionSingleChatPort`、production
AppKernel/Router injection、Drift durable 消息仓储、File command Outbox、
projection 和 crash-window recovery 已完成，并通过 focused/full-suite 门禁。

**Files:**

- Create: `apps/mobile/lib/features/single_chat/single_chat_controller.dart`
- Create: `apps/mobile/lib/features/single_chat/chat_message_repository.dart`
- Modify: `apps/mobile/lib/features/single_chat/single_chat_page.dart`
- Test: `apps/mobile/test/features/single_chat_controller_test.dart`
- Modify: `apps/mobile/test/features/single_chat_test.dart`

**Interfaces:**

- Produces `SingleChatController.submit(text)` and
  `SingleChatController.stop()`.
- Consumes `SingleChatPort.startSingleAgentRun(...)` and persisted chat
  projections.
- The current `ProductionSingleChatPort` executes the selected executable
  expert through `ProductionModelRuntime`; migration into
  `OrchestrationKernel` remains Task 3/6 work.

- [x] Write a failing controller test proving one tap creates one user message
      and one Run, while duplicate taps reuse the same client command identity.
- [x] Write failing widget tests for sending, running, completed, stopped,
      filtered, quota-limited and retryable-failure states.
- [x] Replace hard-coded message children with repository history plus current
      Run projection, retaining all existing visual message formats.
- [x] Connect the composer send button and stop action; keep attachment,
      voice and video entries explicitly marked unavailable until their packages
      are implemented.
- [x] Re-run focused widget/controller tests and confirm no Mock fixture creates
      new Agent replies.

### Task 5: Real Multi-Agent Group Conversation

**Status:** 本地 durable 群聊编排、事件消费和三种模式已经完成。生产 group port、
持久化成员/历史仓储及 AppKernel/Router 注入尚未完成。

**Files:**

- Modify: `apps/mobile/lib/features/group_chat/group_members_repository.dart`
- Modify: `apps/mobile/lib/features/group_chat/group_chat_controller.dart`
- Modify: `apps/mobile/lib/features/group_chat/group_chat_page.dart`
- Modify: `apps/mobile/lib/features/group_chat/group_chat_history_repository.dart`
- Test: `apps/mobile/test/features/group_chat_live_runtime_test.dart`
- Modify: `apps/mobile/test/features/group_chat_orchestration_test.dart`

**Interfaces:**

- Group membership resolves executable expert IDs and model bindings from the
  same expert catalog used by the expert market.
- `auto` uses the production selector; `mentioned` passes explicit IDs; `all`
  executes frozen members and a separate summarizer/verifier.

- [x] Cover local durable `auto / mentioned / all` selection and event
      projection with deterministic runtime tests.
- [ ] Write failing integration tests for real `auto` selection of 1–2 members,
      exact `mentioned` execution and ordered `all` execution.
- [ ] Write failing tests for one bounded supplement/rebuttal round through
      `AgentMessageBus`, including recipient, message and round-trip budgets.
- [ ] Replace the five prototype group members with persisted group
      membership and executable Prompt Package lookup.
- [ ] Project selection, stage, Agent output, verification state and summary
      events into the existing timeline UI.
- [ ] Persist history across app restart and replay only events after the last
      projected sequence.
- [ ] Run all group-chat, orchestration and persistence tests.

### Task 6: Complete Production AppKernel Orchestration Wiring

**Status:** `ProductionAppKernelFactory` and `ApplicationKernelHost` already
own production model runtime, Provider settings, real `SingleChatPort` and
their shutdown lifecycle. This task adds the missing production orchestration
and group-chat dependencies without replacing those types.

**Files:**

- Modify: `apps/mobile/lib/app/app_kernel.dart`
- Modify: `apps/mobile/lib/app/production_app_kernel.dart`
- Modify: `apps/mobile/lib/app/router.dart`
- Modify: `apps/mobile/lib/orchestration/orchestration_providers.dart`
- Test: `apps/mobile/test/app/production_app_kernel_test.dart`
- Test: `apps/mobile/test/app/router_injection_test.dart`

**Interfaces:**

- `ProductionAppKernelFactory.create()` opens Provider configuration,
  `ProductionModelRuntime`, chat repositories and
  `OrchestrationKernelFactory.production`.
- `ApplicationKernelHost` publishes and replaces the resulting
  `AppDependencies`.
- Kernel close drains the orchestration kernel before closing model runtime and
  stores.

- [x] Build and lifecycle-test `ProductionAppKernelFactory` and
      `ApplicationKernelHost` for the existing Provider settings/runtime and
      single-chat dependencies.
- [ ] Write a failing test proving release bootstrap never constructs
      `LocalPrototypeAgentRuntime` or `InMemoryRunEventStore`.
- [ ] Write a failing test proving missing Provider shows a configuration call
      to action instead of generating fake replies.
- [ ] Extend the existing asynchronous AppKernel bootstrap and rollback with
      one production orchestration kernel and production group port.
- [ ] Keep a separately named testing override for deterministic widget tests.
- [ ] Run the complete Flutter test suite and `flutter analyze`.

### Task 7: Real-Key Smoke Gate And iPhone Acceptance

**Status:** 尚未通过。只有 ToAPIs 和 DeepSeek 可以进入本阶段的 P0 验收；其他
Provider 必须先完成配置入口、目录和对应真机验收。

**Files:**

- Create:
  `apps/mobile/test_driver/manual_real_provider_smoke_checklist.md`
- Modify: `docs/06-quality/02-chat-details-multi-provider-qa.md`

**Acceptance sequence:**

1. Save a low-quota test Key through the iPhone settings page.
2. Test connection without sending chat content.
3. Discover models and choose a default `providerId + modelId`.
4. Send one single-Agent message and verify restart persistence.
5. Run `auto`, `mentioned` and `all` group messages.
6. Trigger invalid Key, quota, timeout, cancellation and content-filter states.
7. Inspect SQLite/log output and confirm no Key or full Prompt is present.

- [ ] Run `flutter test --concurrency=1`.
- [ ] Run `flutter analyze`.
- [ ] Build `flutter build ios --release --no-tree-shake-icons`.
- [ ] Install the Release app on the registered iPhone and complete the seven
      manual acceptance steps.
- [ ] Only after all gates pass, publish the explicit status:
      “可以填写真实 API Key 进行测试”。

## Work Order

1. Preserve the completed Task 2 runtime and existing AppKernel contracts while
   Task 4 durable single-chat changes finish their focused and full-suite gates.
2. Tasks 1 and 3 can proceed in parallel against the existing
   `ProductionModelRuntimeFactory` contract.
3. Finish Task 5 production group repositories and port only after Task 3’s
   Provider-backed runtime passes independent review.
4. Task 6 injects only reviewed single-chat, orchestration and group-chat
   packages through `ProductionAppKernelFactory` and `ApplicationKernelHost`.
5. Task 7 is the sole gate for announcing real-Key readiness; Adapter existence
   alone never qualifies a Provider as production-ready.

## Deferred After Real Text Chat

1. Production streaming SSE/UTF-8 transport and token-by-token UI.
2. File asset manager: local uploads, generated images/videos, per-chat
   classification and system share/export.
3. Image generation and image understanding Provider adapters.
4. Vidu video generation, task polling and local result persistence.
5. Doubao end-to-end duplex voice, TTS fallback and voice persona policy.
6. Notification scheduling, background execution and iOS background limits.
7. Circle auto-summary publishing, evidence labels and user approval rules.
8. Complete executable Prompt Package, routing policy and evaluation suite for
   all 50 displayed experts.
9. App-layer encryption for the run-input SQLite database and key rotation.
10. TestFlight packaging, privacy manifest, permission strings and release QA.
