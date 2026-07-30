# Drift Single-Chat Persistence Design

## Decision

Adopt Drift for production single-chat message persistence. Keep the existing
WeChat-style Flutter UI, `SingleChatController`, `SingleChatPort`, Provider
runtime, Keychain pipeline, expert routing, and the already-tested domain
fences. Delete the unfinished hand-written `SqliteChatMessageRepository`
spike.

## Scope

- Persist conversation identity and message projections in one Drift database
  under iOS Application Support.
- Preserve exact message-id idempotency, owner/generation/revision rollback,
  restart recovery, and explicit close behavior.
- Keep `FileSingleChatCommandOutbox` for the first real-chat release because
  its synchronous reservation contract is already consumed by the controller.
  Do not add more custom locking or persistence features to it in this package.
- Inject the Drift repository through `ProductionAppKernelFactory` and close it
  with the kernel.
- Do not change the existing chat visuals, Provider API, expert prompt
  packages, group chat, attachments, voice, or video.

## Data Model

`single_chat_conversations` binds `conversationId` to canonical `expertId`.
`single_chat_messages` stores an auto-incrementing storage revision,
`conversationId`, `messageId`, canonical projection JSON and digest, plus the
optional commit owner and generation. Drift owns schema creation, transactions,
unique constraints, migrations, and isolate-safe database execution.

## Behavioral Contracts

- Appending the same message id and exact projection is idempotent.
- The same message id with different content fails closed.
- `appendIf` inserts only while its commit token remains valid and returns the
  durable storage revision.
- `rollbackOwned` removes only the exact conversation, message, revision,
  owner, and generation returned by `appendIf`.
- Reopening the repository returns the same ordered projections.
- Unsupported schema versions and malformed projection JSON fail closed.
- Closing is idempotent; operations after close fail.

## Production Integration

`ProductionAppKernelFactory` opens `halo_single_chat.sqlite` and the existing
file outbox in the same Application Support directory. It injects the resulting
`DurableChatMessageRepository` into `AppDependencies`. Initialization failure
closes every resource already opened. Kernel close drains settings/runtime/chat
work, then closes the Drift repository and remaining stores.

## Acceptance

1. Focused repository/controller/widget tests pass.
2. App/Settings tests prove the production kernel injects a durable repository.
3. Full `flutter test --concurrency=1` and `flutter analyze` pass.
4. Release iOS build succeeds and installs on the connected iPhone.
5. Manual flow supports Key entry, real single-Agent send, response display,
   and history after app restart.
