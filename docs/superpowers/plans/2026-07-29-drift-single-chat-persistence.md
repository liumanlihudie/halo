# Drift Single-Chat Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the unfinished raw-SQLite single-chat repository with a thin
Drift repository and inject it into the production AppKernel.

**Architecture:** Drift owns the SQLite schema, migrations, transactions and
background execution. Existing domain types and controller fences remain the
public contract. Production AppKernel creates and closes the repository from
the iOS Application Support directory.

**Tech Stack:** Flutter, Dart, Drift, SQLite, build_runner, Flutter Test.

## Global Constraints

- Keep the current WeChat-style UI unchanged.
- Keep the four reviewed domain fixes: trusted terminal clock, ownerless-answer
  quarantine, no claimless reconciliation bypass, and exact user-message CAS.
- Delete the raw `SqliteChatMessageRepository` spike.
- Do not redesign the command outbox, orchestration, Provider runtime, group
  chat, attachments, voice, or video.
- No real API Key or public network call in automated tests.

---

### Task 1: Drift Chat Repository

**Files:**

- Modify: `apps/mobile/pubspec.yaml`
- Modify: `apps/mobile/pubspec.lock`
- Modify: `apps/mobile/lib/features/single_chat/chat_message_repository.dart`
- Create: `apps/mobile/lib/features/single_chat/drift_chat_message_repository.dart`
- Generate: `apps/mobile/lib/features/single_chat/drift_chat_message_repository.g.dart`
- Modify: `apps/mobile/test/features/single_chat_controller_test.dart`

**Interfaces:**

- Consumes: `ChatMessageRepository`, `DurableChatMessageRepository`,
  `ChatMessageProjection`, `ChatMessageCommitToken`.
- Produces:
  `Future<DriftChatMessageRepository> DriftChatMessageRepository.open(...)`.

- [ ] Write failing tests using a real temporary database for reopen recovery,
      exact duplicate/conflict behavior, exact owned rollback, schema-version
      rejection, idempotent close, and operations after close.
- [ ] Run the focused tests and confirm failure because
      `DriftChatMessageRepository` does not exist.
- [ ] Add `drift`, `drift_flutter`, `drift_dev`, and `build_runner`; define the
      two tables and generated database.
- [ ] Implement `describe`, `load`, `append`, `appendIf`, `rollbackOwned`, and
      `close` with Drift transactions and unique constraints.
- [ ] Remove the raw `SqliteChatMessageRepository`, its `sqlite3` import, and
      raw schema inspection code.
- [ ] Generate the `.g.dart` file and run focused repository/controller tests,
      range analyze, formatting, and diff-check.

### Task 2: Production AppKernel Injection

**Files:**

- Modify: `apps/mobile/lib/app/production_app_kernel.dart`
- Modify: `apps/mobile/test/app/production_app_kernel_test.dart`
- Modify: `apps/mobile/test/app/router_injection_test.dart`

**Interfaces:**

- Consumes: `DriftChatMessageRepository.open`, Application Support directory,
  existing conversation projections and `FileSingleChatCommandOutbox`.
- Produces: production `AppDependencies.chatRepository` implementing
  `DurableChatMessageRepository`.

- [ ] Write a failing production-kernel test proving the injected repository is
      durable, survives close/reopen, and is closed on initialization failure.
- [ ] Run the test and confirm it fails while production injects
      `InMemoryChatMessageRepository`.
- [ ] Open `halo_single_chat.sqlite` and `single-chat-commands.json` from the
      resolved Application Support directory and inject the Drift repository.
- [ ] Add repository cleanup to every initialization failure and kernel-close
      path without replacing the original error.
- [ ] Run App/Settings, router, and complete single-chat focused tests plus
      range analyze and diff-check.

### Task 3: Release Gate

**Files:**

- Modify only stale tests or documentation whose assertions contradict the
  reviewed production contracts.

**Interfaces:**

- Consumes: reviewed Drift repository and production AppKernel.
- Produces: a verified iPhone Release build.

- [ ] Run `flutter test --concurrency=1 --reporter compact`.
- [ ] Run `flutter analyze`.
- [ ] Run `flutter build ios --release --no-tree-shake-icons`.
- [ ] Install `build/ios/iphoneos/Runner.app` with `xcrun devicectl` on device
      `FD4F00E2-E4F1-5934-A4BF-142451B3829B`.
- [ ] Launch `com.cofe.haloMobile` when the phone is unlocked and report only
      the observed installation/launch result.
