# IOS-IM MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建可通过 TestFlight 与 Google Play 内测交付的个人 AI 通讯 MVP，支持账户、50 位专家市场、一对一文字消息、三种多 Agent 文字群聊、AI 朋友圈成果流和可追踪 Token 用量。

**Architecture:** Flutter iOS / Android 客户端通过 REST 与 WebSocket 连接模块化 API；业务数据存于 PostgreSQL，多 Agent 流程由独立 LangGraph 服务编排。Agent 身份、模型、工具、记忆和账务解耦，所有生成通过稳定 Run/Generation ID 流式传输并可停止、恢复和审计。

**Tech Stack:** Flutter、Dart、Riverpod、go_router、Dio、Drift/SQLite、Python 3.12、FastAPI、LangGraph、PostgreSQL、Redis、S3 兼容对象存储、OpenTelemetry、flutter_test、integration_test、Pytest。

## Global Constraints

- 产品仅面向个人用户，不实现企业组织、管理员或真人社交。
- 四个主 Tab 固定为对话、通讯录、AI 朋友圈和设置。
- 群聊首版仅支持文字；语音和视频只支持一对一 Agent。
- 普通消息选择 1–2 个 Agent；Mention 只调用被点名者；全员讨论只包含当前群成员。
- Agent 私有关系记忆禁止跨 Agent 共享。
- 移动客户端不保存模型 Provider 主密钥；权威编排和计费状态在服务端。
- 所有消息写入、账务写入和外部副作用必须幂等。
- OpenMinis GPLv3 代码不得复制进闭源产品。

---

### Task 1: 建立契约和本地运行骨架

**Files:**
- Create: `packages/contracts/openapi.yaml`
- Create: `packages/contracts/events/realtime-event.schema.json`
- Create: `services/api/app/main.py`
- Create: `services/orchestrator/app/main.py`
- Create: `infra/docker/docker-compose.yml`
- Create: `Makefile`
- Test: `services/api/tests/test_health.py`
- Test: `services/orchestrator/tests/test_health.py`

**Interfaces:**
- Produces: `GET /healthz`、统一 Realtime Event Envelope、PostgreSQL/Redis 本地依赖。
- Consumes: 无。

- [ ] **Step 1: 写 API 和 Orchestrator 健康检查失败测试**

分别断言 `/healthz` 返回 `{"status":"ok","service":"api"}` 和 `{"status":"ok","service":"orchestrator"}`。

- [ ] **Step 2: 运行测试确认失败**

```bash
pytest services/api/tests/test_health.py services/orchestrator/tests/test_health.py -q
```

预期：模块或路由不存在。

- [ ] **Step 3: 实现最小 FastAPI 应用、Docker Compose 和 Make 入口**

Compose 仅包含 PostgreSQL、Redis 和 MinIO；应用进程在本机运行以方便调试。

- [ ] **Step 4: 定义事件信封 Schema**

必填字段为 `eventId`、`eventType`、`conversationId`、`serverSequence`、`occurredAt`、`payload`。

- [ ] **Step 5: 运行测试和 Schema 校验**

```bash
make test
```

- [ ] **Step 6: 提交**

```bash
git add Makefile infra packages services
git commit -m "build: bootstrap api orchestrator and shared contracts"
```

### Task 2: 建立账户、认证和 Token 账本

**Files:**
- Create: `services/api/app/identity/models.py`
- Create: `services/api/app/identity/routes.py`
- Create: `services/api/app/billing/models.py`
- Create: `services/api/app/billing/ledger.py`
- Create: `infra/migrations/versions/001_identity_billing.py`
- Test: `services/api/tests/identity/test_sessions.py`
- Test: `services/api/tests/billing/test_ledger.py`

**Interfaces:**
- Consumes: Task 1 FastAPI 与数据库。
- Produces: 用户、设备 Session、账号切换、Token 余额和不可变账本。

- [ ] **Step 1: 写登录 Session、刷新和退出测试**

覆盖过期 Token、重复退出和设备撤销。

- [ ] **Step 2: 写账本幂等测试**

同一个 `external_transaction_id` 充值两次只增加一次余额；生成扣费必须同时记录 `run_id`。

- [ ] **Step 3: 运行测试确认失败**

```bash
pytest services/api/tests/identity services/api/tests/billing -q
```

- [ ] **Step 4: 实现身份表、Session 和账本服务**

余额由账本求和或可信快照得出，禁止直接更新一个无审计 `balance` 字段。

- [ ] **Step 5: 运行测试并提交**

```bash
pytest services/api/tests/identity services/api/tests/billing -q
git add services/api/app/identity services/api/app/billing infra/migrations
git commit -m "feat(account): add sessions and idempotent token ledger"
```

### Task 3: 建立 Agent 市场和 50 位专家数据

**Files:**
- Create: `services/api/app/agents/models.py`
- Create: `services/api/app/agents/routes.py`
- Create: `services/api/app/agents/seeds/market_agents.json`
- Create: `infra/migrations/versions/002_agents.py`
- Test: `services/api/tests/agents/test_market.py`

**Interfaces:**
- Consumes: 用户身份。
- Produces: `Agent`、不可变 `AgentVersion`、`UserAgent` 安装关系和市场分页 API。

- [ ] **Step 1: 写市场分页、搜索、分类和安装测试**

固定数据必须恰好包含 50 位专家；重复安装返回同一 `user_agent_id`。

- [ ] **Step 2: 运行测试确认失败**

```bash
pytest services/api/tests/agents/test_market.py -q
```

- [ ] **Step 3: 实现数据模型和种子数据**

每位专家包含能力标签、Persona、默认模型 Profile、工具策略、语音 Profile 和朋友圈权限默认值。

- [ ] **Step 4: 运行测试并提交**

```bash
pytest services/api/tests/agents/test_market.py -q
git add services/api/app/agents infra/migrations
git commit -m "feat(agents): add versioned fifty-agent marketplace"
```

### Task 4: 建立会话、消息和实时事件

**Files:**
- Create: `services/api/app/conversations/models.py`
- Create: `services/api/app/conversations/routes.py`
- Create: `services/api/app/messages/service.py`
- Create: `services/api/app/realtime/gateway.py`
- Create: `infra/migrations/versions/003_conversations_messages.py`
- Test: `services/api/tests/messages/test_idempotency.py`
- Test: `services/api/tests/realtime/test_replay.py`

**Interfaces:**
- Consumes: 用户和已安装 Agent。
- Produces: 会话成员、消息分页、幂等发送、服务端序号和事件重放。

- [ ] **Step 1: 写重复发送和消息顺序测试**

相同用户和 `client_message_id` 只生成一条消息；`server_sequence` 在会话内严格递增。

- [ ] **Step 2: 写断线重放测试**

客户端携带最后确认序号后只能收到缺失事件。

- [ ] **Step 3: 运行测试确认失败**

```bash
pytest services/api/tests/messages services/api/tests/realtime -q
```

- [ ] **Step 4: 实现模型、Repository 和 Realtime Gateway**

用户消息先进入数据库事务，再发布事件；事件投递失败不得丢失已接受消息。

- [ ] **Step 5: 运行测试并提交**

```bash
pytest services/api/tests/messages services/api/tests/realtime -q
git add services/api/app/conversations services/api/app/messages services/api/app/realtime infra/migrations
git commit -m "feat(chat): add durable messages and replayable events"
```

### Task 5: 实现 Model Gateway 和基础 AgentRunner

**Files:**
- Create: `services/orchestrator/app/model_gateway/protocol.py`
- Create: `services/orchestrator/app/model_gateway/openai_compatible.py`
- Create: `services/orchestrator/app/runners/protocol.py`
- Create: `services/orchestrator/app/runners/direct_runner.py`
- Test: `services/orchestrator/tests/model_gateway/test_normalization.py`
- Test: `services/orchestrator/tests/runners/test_direct_runner.py`

**Interfaces:**
- Consumes: Agent/Profile 和 Provider 配置。
- Produces: `AgentRunner.stream()`、统一 Delta/Tool/Usage/Completed/Error 事件。

- [ ] **Step 1: 写 Provider 事件标准化失败测试**

覆盖文本 Delta、工具调用、Token 用量、正常结束、超时和取消。

- [ ] **Step 2: 运行测试确认失败**

```bash
pytest services/orchestrator/tests/model_gateway services/orchestrator/tests/runners -q
```

- [ ] **Step 3: 实现协议和首个 OpenAI-Compatible 适配器**

Provider 特有类型只能存在于适配器内部。

- [ ] **Step 4: 实现 Prompt/工具/预算组装**

每次 Request 记录 Agent Version、Model Profile、Prompt Version 和限制。

- [ ] **Step 5: 运行测试并提交**

```bash
pytest services/orchestrator/tests/model_gateway services/orchestrator/tests/runners -q
git add services/orchestrator/app
git commit -m "feat(runtime): add normalized model gateway and agent runner"
```

### Task 6: 实现 LangGraph 三种文字群聊模式

**Files:**
- Create: `services/orchestrator/app/graphs/group_chat/state.py`
- Create: `services/orchestrator/app/graphs/group_chat/nodes.py`
- Create: `services/orchestrator/app/graphs/group_chat/graph.py`
- Create: `services/orchestrator/app/graphs/group_chat/policies.py`
- Test: `services/orchestrator/tests/group_chat/test_modes.py`
- Test: `services/orchestrator/tests/group_chat/test_stop_resume.py`
- Test: `services/orchestrator/tests/group_chat/test_memory_isolation.py`

**Interfaces:**
- Consumes: `AgentRunner`、会话 Context Repository、Message Repository。
- Produces: `run_group_chat(command) -> AsyncIterator[RealtimeEvent]`。

- [ ] **Step 1: 写三种模式失败测试**

断言 `auto` 调用 1–2 位成员、`mentioned` 只调用指定成员、`all` 调用全部当前成员并生成总结。

- [ ] **Step 2: 写停止恢复和私有记忆隔离测试**

停止后不能启动新 Generation；A 的私有记忆不能出现在 B 的 Request Fixture。

- [ ] **Step 3: 运行测试确认失败**

```bash
pytest services/orchestrator/tests/group_chat -q
```

- [ ] **Step 4: 实现 State、节点、条件边和 Postgres Checkpointer**

严格采用架构文档中的阶段和预算字段。

- [ ] **Step 5: 实现交叉评论和可引用总结**

总结中的每项结论必须包含来源消息 ID。

- [ ] **Step 6: 运行测试并提交**

```bash
pytest services/orchestrator/tests/group_chat -q
git add services/orchestrator/app/graphs/group_chat services/orchestrator/tests/group_chat
git commit -m "feat(orchestration): add controlled multi-agent group chat"
```

### Task 7: 建立 Flutter 双端应用壳和本地缓存

**Files:**
- Create: `apps/mobile/.fvmrc`
- Create: `apps/mobile/pubspec.yaml`
- Create: `apps/mobile/lib/main.dart`
- Create: `apps/mobile/lib/app/app.dart`
- Create: `apps/mobile/lib/app/router.dart`
- Create: `apps/mobile/lib/core/api/api_client.dart`
- Create: `apps/mobile/lib/core/database/app_database.dart`
- Create: `apps/mobile/lib/core/realtime/realtime_client.dart`
- Test: `apps/mobile/test/app/router_test.dart`
- Test: `apps/mobile/test/core/realtime/realtime_reducer_test.dart`

**Interfaces:**
- Consumes: OpenAPI 与 Event Schema 生成 DTO。
- Produces: 四 Tab、导航、API、数据库和 Realtime 基础设施。

- [ ] **Step 1: 写四 Tab 路由和事件去重测试**

断言 Tab 顺序固定，重复 `eventId` 不会重复应用。

- [ ] **Step 2: 建立 Flutter 工程和 Design Token**

字号支持系统缩放；所有按钮在 iOS 最小点击区域 44×44pt、Android 最小 48×48dp；页面遵循安全区和平台返回手势。

- [ ] **Step 3: 实现 API、SQLite 和 WebSocket 基础层**

离线读取本地缓存，恢复连接后按序号补事件。

- [ ] **Step 4: 运行 Flutter 测试并提交**

```bash
cd apps/mobile
fvm flutter analyze
fvm flutter test
cd ../..
git add apps/mobile packages/contracts
git commit -m "feat(mobile): bootstrap Flutter shell persistence and realtime"
```

### Task 8: 实现认证、设置和 Token 页面

**Files:**
- Create: `apps/mobile/lib/features/settings/`
- Create: `apps/mobile/lib/features/identity/`
- Create: `apps/mobile/lib/features/billing/`
- Test: `apps/mobile/integration_test/account_flows_test.dart`

**Interfaces:**
- Consumes: Task 2 API。
- Produces: 登录、验证码、忘记/修改密码、切换账号、退出、余额、充值和交易记录 UI。

- [ ] **Step 1: 写核心 UI 流程测试**

覆盖退出确认、验证码输入、密码字段错误和重复支付结果刷新。

- [ ] **Step 2: 实现页面和 Repository**

登录页不展示主 Tab；成功后恢复用户最后页面。

- [ ] **Step 3: 运行 UI 测试并提交**

```bash
cd apps/mobile
fvm flutter test
fvm flutter test integration_test/account_flows_test.dart
cd ../..
git add apps/mobile/lib/features apps/mobile/integration_test
git commit -m "feat(mobile-account): add authentication settings and token flows"
```

### Task 9: 实现通讯录、市场和单聊

**Files:**
- Create: `apps/mobile/lib/features/contacts/`
- Create: `apps/mobile/lib/features/agent_market/`
- Create: `apps/mobile/lib/features/conversations/`
- Create: `apps/mobile/lib/features/chat/`
- Test: `apps/mobile/integration_test/market_and_chat_test.dart`

**Interfaces:**
- Consumes: Tasks 3–5 API 与事件。
- Produces: 50 位专家市场、添加通讯录、会话列表和一对一文字/图片/文件消息。

- [ ] **Step 1: 写市场搜索、安装和消息状态 UI 测试**

覆盖加载、空、失败、重试、发送中、已发送和失败状态。

- [ ] **Step 2: 实现市场和通讯录**

分类使用可横向滑动内容但隐藏滚动条；卡片和详情共享同一 Agent DTO。

- [ ] **Step 3: 实现聊天消息渲染器**

覆盖文本、图片、文件、引用、成果卡、系统消息、工具状态和生成中状态。

- [ ] **Step 4: 运行测试并提交**

```bash
cd apps/mobile
fvm flutter test
fvm flutter test integration_test/market_and_chat_test.dart
cd ../..
git add apps/mobile/lib/features apps/mobile/integration_test
git commit -m "feat(mobile-chat): add agent market contacts and direct chat"
```

### Task 10: 实现群聊和 AI 朋友圈

**Files:**
- Create: `apps/mobile/lib/features/group_chat/`
- Create: `apps/mobile/lib/features/moments/`
- Create: `services/api/app/moments/`
- Test: `apps/mobile/integration_test/group_chat_modes_test.dart`
- Test: `services/api/tests/moments/test_source_traceability.py`

**Interfaces:**
- Consumes: Task 6 Graph 事件和消息。
- Produces: 模式提示、群资料、讨论阶段、停止、总结卡和可追溯朋友圈。

- [ ] **Step 1: 写三种模式和停止 UI 测试**

发送前必须显示当前模式；运行时显示当前发言 Agent 和讨论阶段。

- [ ] **Step 2: 实现 GroupChat Feature**

客户端只发送控制指令，不自行选择 Agent 或伪造讨论结果。

- [ ] **Step 3: 写并实现朋友圈来源测试**

每条自动生成内容必须拥有合法 `source_type` 和 `source_id`。

- [ ] **Step 4: 实现 Moments 页面和发布策略**

支持成果、总结、提醒、图片和失败状态；自动总结可以关闭。

- [ ] **Step 5: 运行全部测试并提交**

```bash
make test
cd apps/mobile
fvm flutter analyze
fvm flutter test
fvm flutter test integration_test/group_chat_modes_test.dart
cd ../..
git add apps/mobile/lib/features/group_chat apps/mobile/lib/features/moments apps/mobile/integration_test services/api/app/moments
git commit -m "feat(group-chat): add controlled discussions and traceable moments"
```

### Task 11: 完成安全、可观测性和双端内测验收

**Files:**
- Create: `services/api/app/shared/telemetry.py`
- Create: `services/orchestrator/app/telemetry/tracing.py`
- Create: `packages/agent-evals/group_routing.jsonl`
- Create: `packages/agent-evals/privacy_isolation.jsonl`
- Create: `docs/06-quality/02-mobile-release-checklist.md`
- Test: `packages/agent-evals/test_eval_thresholds.py`

**Interfaces:**
- Consumes: 全部功能。
- Produces: Trace、指标、隐私评测、发布开关和双端内测验收报告。

- [ ] **Step 1: 建立路由与隐私 Eval**

路由正确率目标不低于 90%；私有记忆泄露样例必须 100% 被阻断。

- [ ] **Step 2: 接入脱敏 Trace 和运行成本指标**

Trace 中只保存 Prompt 哈希、版本和长度，不保存默认完整正文。

- [ ] **Step 3: 执行弱网、后台、取消、Provider 故障和支付幂等测试**

结果写入 `02-mobile-release-checklist.md`，每项包含平台、设备、构建号、结果和证据。

- [ ] **Step 4: 运行完整验证**

```bash
make lint
make test
cd apps/mobile
fvm flutter analyze
fvm flutter test
fvm flutter test integration_test
```

- [ ] **Step 5: 提交发布候选**

```bash
git add services packages docs apps/mobile
git commit -m "chore(release): complete privacy reliability and mobile beta gates"
```
