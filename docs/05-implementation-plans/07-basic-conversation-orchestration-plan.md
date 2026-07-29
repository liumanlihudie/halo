# Basic Conversation Orchestration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` or `superpowers:executing-plans`.
> Every production change follows red-green-refactor.

**Goal:** 在 Flutter 本地完成 `auto / mentioned / all` 三种文字对话的可执行
编排闭环，并让群聊页面只消费事件流、不直接伪造 Agent 回复。

**Architecture:** `OrchestrationKernel` 是页面唯一入口；`BasicDurableRunner`
冻结本轮成员、选择 Agent、顺序执行、生成总结并写入 Event Store。
Provider 调用通过 `AgentRuntime` 端口隔离，第一轮使用确定性本地 Runtime
验收流程，后续替换为多 Provider Runtime 不修改 UI。`AgentMessageBus`
独立校验通讯范围、预算和去重。

**Tech Stack:** Dart 3.12、Flutter、Riverpod、Dart Stream、Flutter Test。

## Global Constraints

- 普通消息只能选择当前群成员中的 1–2 个 Agent。
- `@某个 Agent` 只执行合法、去重后的被点名成员，最多 4 个。
- `@所有人` 只执行当前群成员，最多 8 个，并按冻结顺序输出。
- 页面不能直接生成 Agent 回复，只能根据 `OrchestrationEvent` 更新。
- 所有 Event 在同一 Run 内使用从 1 开始的单调 `seq`。
- `clientCommandId` 幂等；重复提交返回同一个 Run。
- Message Bus 接收方必须属于本轮 `executableAgentIds`。
- Provider Key、完整 Prompt、私有记忆和文件正文不得进入 Event。

---

### Task 1: Shared Dart contracts

**Files:**

- Create: `apps/mobile/lib/orchestration/orchestration_models.dart`
- Create: `apps/mobile/lib/orchestration/orchestration_kernel.dart`
- Test: `apps/mobile/test/orchestration/orchestration_contract_test.dart`

**Produces:**

- `ConversationReplyMode`
- `ConversationStage`
- `StartConversationRunCommand`
- `RunHandle`
- `OrchestrationEvent`
- `OrchestrationKernel`

- [x] Write a failing JSON round-trip test for command and event contracts.
- [x] Run `flutter test test/orchestration/orchestration_contract_test.dart`.
- [x] Implement immutable contracts with explicit `toJson/fromJson`.
- [x] Re-run the contract test.

### Task 2: Event store and local runner

**Files:**

- Create: `apps/mobile/lib/orchestration/run_event_store.dart`
- Create: `apps/mobile/lib/orchestration/basic_durable_runner.dart`
- Test: `apps/mobile/test/orchestration/basic_durable_runner_test.dart`

**Consumes:**

- `Future<RunHandle> startRun(StartConversationRunCommand command)`
- `Stream<OrchestrationEvent> watchRun(String runId, {int afterSeq = 0})`

**Produces:**

- `InMemoryRunEventStore`
- `AgentSelector`
- `AgentRuntime`
- `BasicDurableRunner`

- [x] Write a failing test proving `auto` freezes only 1–2 selected group members.
- [x] Implement deterministic selection and monotonic event persistence.
- [x] Write a failing test proving duplicate `clientCommandId` returns the same Run.
- [x] Implement command idempotency.
- [x] Write a failing test proving `mentioned` executes only specified members.
- [x] Implement mention validation and stable queue execution.
- [x] Write a failing test proving `all` emits collecting, cross-discussion,
      summarizing, summary, and completed events in order.
- [x] Implement the all-member pipeline and partial-member failure events.
- [x] Run all orchestration tests.

### Task 3: Controlled Agent Message Bus

**Files:**

- Create: `apps/mobile/lib/orchestration/agent_message_bus.dart`
- Test: `apps/mobile/test/orchestration/agent_message_bus_test.dart`

**Produces:**

- `AgentCollaborationMessage`
- `AgentMessageBus.publish(...)`

- [x] Write a failing test that rejects a recipient outside
      `executableAgentIds`.
- [x] Implement executable-set validation.
- [x] Write a failing test that reuses an existing message for the same
      `dedupeKey`.
- [x] Implement deduplication, collision rejection, the 20-message Run budget,
      and the two-round-trip Agent-pair budget.
- [x] Run the Message Bus tests.

### Task 4: Group-chat presentation adapter

**Owner:** thread `019fa77e-27f2-7f31-a36a-c2794d12c73d`

**Files:**

- Create/modify only:
  `apps/mobile/lib/features/group_chat/`
- Test only:
  `apps/mobile/test/features/`

**Consumes:**

- `OrchestrationKernel.startRun`
- `OrchestrationKernel.watchRun`
- `OrchestrationEvent`

- [x] Write failing widget/controller tests for auto, mentioned, all, running,
      completed, and failed states.
- [x] Replace page-authored mock replies with an injected orchestration port.
- [x] Map selection and stage events to the existing mode hint.
- [x] Map completed Agent and summary events to timeline messages.
- [x] Preserve current HTML-derived layout and run focused widget tests.

### Task 5: Integration and recovery boundary

**Files:**

- Create: `apps/mobile/lib/orchestration/orchestration_providers.dart`
- Create: `apps/mobile/test/orchestration/conversation_orchestration_integration_test.dart`
- Modify: `apps/mobile/lib/app/app.dart`

- [x] Write a failing integration test that sends the same command twice and
      observes one message sequence.
- [x] Wire one application-scoped Kernel and store through Riverpod.
- [x] Verify a new watcher can replay events using `afterSeq`.
- [x] Run `flutter analyze` and the complete Flutter test suite.
- [x] Record the SQLite-backed store as the next implementation slice; the
      current in-memory store is an interface-compatible executable baseline,
      not the final crash-recovery store.

## Acceptance

1. Three modes run through one Kernel API.
2. UI contains no hard-coded execution branches that manufacture Agent output.
3. Selection never escapes the frozen group member set.
4. Event order is deterministic and replayable.
5. Duplicate commands do not duplicate logical Runs.
6. Agent-to-Agent messages are scoped, budgeted, and deduplicated.
7. Flutter analysis and all tests pass.
