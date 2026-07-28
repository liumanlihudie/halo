# IOS-IM 工程开发规范

版本：1.0  
日期：2026-07-28

## 1. 文档目的

本文定义正式 MVP 的工程边界、推荐目录、环境、接口、测试和交付规范。当前 `prototype.html` 是产品演示，不直接演进为正式 Flutter 或服务端代码。

## 2. 推荐仓库结构

正式开发启动后，在 `IOS-IM` 下增加：

```text
IOS-IM/
├── apps/
│   └── mobile/
│       ├── lib/
│       │   ├── app/
│       │   ├── core/
│       │   └── features/
│       ├── test/
│       ├── integration_test/
│       ├── ios/
│       ├── android/
│       └── pubspec.yaml
├── services/
│   ├── api/
│   ├── orchestrator/
│   └── workers/
├── packages/
│   ├── contracts/
│   └── agent-evals/
├── infra/
│   ├── docker/
│   └── migrations/
├── docs/
├── prototype.html
└── prototype.test.cjs
```

首版允许 API、Conversation、Agent Market 和 Moment 运行在同一个模块化单体中；LangGraph Orchestrator 独立为 Python 服务。不要在验证商业价值前拆成大量微服务。

## 3. 技术栈

### Flutter 移动端

- Flutter Stable + Dart，最低支持 iOS 18 和 Android API 26。
- Riverpod 管理 Feature 状态与依赖注入。
- go_router 管理登录态、四 Tab ShellRoute 和类型安全路由入口。
- Dio、WebSocket 和 Stream 管理 REST 与实时事件。
- Drift / SQLite 管理本地缓存；数据库 Row 不直接穿透到业务层。
- Freezed 与 json_serializable 生成不可变领域对象和契约 DTO。
- flutter_test、integration_test、golden tests 和 mocktail。
- 豆包语音、Vidu、通知、系统分享与无法跨端抽象的媒体能力通过 Platform Channel 或 Flutter Plugin 接入 Swift/Kotlin。

### 服务端

- Python 3.12。
- FastAPI 提供 REST、SSE/WebSocket 鉴权入口。
- LangGraph 实现单聊和群聊编排。
- PostgreSQL 保存业务数据和生产 Checkpoint。
- Redis 用于短期锁、限流、连接路由和可丢失缓存。
- S3 兼容对象存储保存附件。
- Alembic 管理数据库迁移。
- Pytest、Ruff、Mypy。

### 可观测性

- OpenTelemetry Trace 贯穿 `request_id → run_id → generation_id → tool_call_id`。
- 结构化日志禁止记录完整 Prompt、Token、密码、短信验证码和附件正文。
- 指标包括消息成功率、首 Token 延迟、完整延迟、重试率、停止成功率、Provider 错误率和单 Run 成本。

## 4. Flutter 模块边界

```text
apps/mobile/
├── lib/
│   ├── app/
│   │   ├── app.dart
│   │   ├── router.dart
│   │   └── environment.dart
│   ├── core/
│   │   ├── api/
│   │   ├── auth/
│   │   ├── database/
│   │   ├── realtime/
│   │   ├── design_system/
│   │   ├── media/
│   │   └── observability/
│   └── features/
│       ├── conversations/
│       ├── chat/
│       ├── group_chat/
│       ├── contacts/
│       ├── agent_market/
│       ├── moments/
│       ├── settings/
│       ├── voice_call/
│       └── video_call/
├── ios/
└── android/
```

规则：

1. Feature 不直接依赖其他 Feature 的 Widget 或 Notifier。
2. UI 使用领域 DTO，不使用数据库 Row 或原始网络 JSON。
3. 导航由 go_router 的集中 Router 管理，不在任意 Widget 中拼装全局页面状态。
4. WebSocket 事件先进入 Realtime Store，再更新 Feature Repository。
5. 所有图片、文件和音视频都通过 Media 层获得短期访问地址。
6. `lib/` 不直接导入 Swift/Kotlin 类型；原生差异通过 Dart 接口和插件实现隔离。

## 5. 服务端模块边界

```text
services/api/app/
├── identity/
├── accounts/
├── billing/
├── agents/
├── conversations/
├── messages/
├── memories/
├── moments/
├── files/
├── realtime/
└── shared/

services/orchestrator/app/
├── graphs/
│   ├── single_chat/
│   ├── group_chat/
│   ├── moment_generation/
│   └── common/
├── runners/
├── model_gateway/
├── tools/
├── context/
├── policies/
└── telemetry/
```

API 服务拥有业务数据写权限。Orchestrator 通过明确的 Repository/HTTP 接口读取上下文和追加生成消息，不直接随意修改账户、充值或市场数据。

## 6. 核心接口

### AgentRunner

```python
class AgentRunner(Protocol):
    async def stream(
        self,
        request: AgentRunRequest,
    ) -> AsyncIterator[AgentRunEvent]: ...

    async def cancel(self, generation_id: str) -> None: ...
```

`AgentRunRequest` 必须包含：

- `generation_id`
- `agent_profile_version`
- `model_profile`
- `context_snapshot`
- `tool_policy`
- `limits`

Hermes Runner、直接 Provider Runner 或未来本地模型 Runner 都实现同一协议。

### ModelGateway

```python
class ModelGateway(Protocol):
    async def stream_chat(
        self,
        request: NormalizedModelRequest,
    ) -> AsyncIterator[NormalizedModelEvent]: ...
```

业务层禁止直接判断 Anthropic/OpenAI/豆包响应格式。

### MessageRepository

```python
class MessageRepository(Protocol):
    async def accept_user_message(self, command: SendMessage) -> Message: ...
    async def append_agent_delta(self, event: AgentDelta) -> None: ...
    async def complete_agent_message(self, event: AgentCompleted) -> Message: ...
```

所有写方法带幂等键。

## 7. API 与事件契约

契约源文件建议存放于：

```text
packages/contracts/
├── openapi.yaml
├── events/
│   ├── realtime-event.schema.json
│   ├── message-event.schema.json
│   └── generation-event.schema.json
└── fixtures/
```

生成 Dart DTO 和 Python 校验模型，禁止手工维护两份不同字段名。兼容性规则：

- 新增可选字段属于向后兼容。
- 删除字段、改类型、改枚举语义必须升级 API 版本。
- Event 必须允许旧客户端忽略未知事件。
- 服务端在最低支持版本淘汰前保留旧字段。

## 8. 配置和密钥

环境分为 `local`、`staging`、`production`：

```text
DATABASE_URL
REDIS_URL
OBJECT_STORAGE_ENDPOINT
OBJECT_STORAGE_BUCKET
MODEL_GATEWAY_MASTER_KEY
APPLE_BUNDLE_ID
APPLE_TEAM_ID
DOUBAO_VOICE_APP_ID
VIDU_API_BASE_URL
```

- `.env.example` 只包含变量名和无敏感默认值。
- 本地密钥不得提交 Git。
- 生产密钥进入云端 Secret Manager。
- 移动客户端只保存短期登录 Token 和设备标识，不内置 Provider 主密钥。
- 所有外部 Provider 配置支持独立禁用和灰度。

## 9. 数据库迁移

1. 每次 Schema 修改必须带 Alembic Migration。
2. Migration 在 Staging 真实数据副本上验证升级时间。
3. 删除字段使用“停止写入 → 观察 → 停止读取 → 后续版本删除”流程。
4. 消息和账务表只允许可审计修正，不做无记录覆盖。
5. Agent Profile 版本不可变；更新产生新版本。

## 10. 开发流程

每个功能按以下顺序：

1. 修改产品/功能规格。
2. 修改 OpenAPI 或 Event Schema。
3. 写失败的单元或契约测试。
4. 实现最小功能。
5. 运行单元、集成和受影响的 UI 测试。
6. 更新 QA 证据与文档。
7. 提交一个意图明确的 Commit。

Commit 建议：

```text
feat(group-chat): add explicit mentioned routing
fix(realtime): deduplicate replayed message events
docs(architecture): define agent runner boundary
test(billing): cover duplicate Apple transaction
```

## 11. 测试分层

| 层级 | 内容 | 阻断合并 |
|---|---|---|
| 单元 | Router、Reducer、预算、权限、格式化 | 是 |
| 契约 | OpenAPI、事件 Schema、Provider 适配 | 是 |
| 集成 | PostgreSQL、Checkpoint、对象存储、WebSocket | 是 |
| Eval | Agent 选择、总结质量、隐私泄露、工具策略 | 低于阈值阻断 |
| Flutter Widget | Router、Reducer、四 Tab、登录、聊天、群聊、市场和设置 | 核心路径阻断 |
| 双端集成 | iOS 与 Android 的登录、权限、媒体、前后台恢复和通知 | 核心路径阻断 |
| 视觉回归 | 字号、安全区、图标、截断和滚动 | 发布前阻断 |

Agent Eval 数据不能只使用正常问题，至少包含：

- 模糊意图。
- 错误 Mention。
- 提示词注入。
- 请求 Agent 泄露其他 Agent 私有记忆。
- 超长群聊。
- Provider 超时和部分失败。
- 用户中途停止。

## 12. 本地开发

正式工程建立后，统一入口建议为：

```bash
make bootstrap
make dev
make test
make lint
make contracts
```

`make dev` 启动 PostgreSQL、Redis、对象存储模拟、API 和 Orchestrator。Flutter 使用 `--dart-define=API_BASE_URL=...` 指向本机 API；Android 模拟器默认使用 `10.0.2.2`，iOS 模拟器使用 `127.0.0.1`。

本机前置依赖：

- Flutter Stable，通过 FVM 锁定仓库版本并提交 `.fvmrc`。
- Xcode 与 iOS Simulator。
- Android Studio、Android SDK 和 Android Emulator。
- CocoaPods，仅用于 Flutter iOS 插件依赖。
- Java 17 或 Flutter 当前稳定版要求的兼容 JDK。

移动端常用命令：

```bash
cd IOS-IM/apps/mobile
fvm flutter pub get
fvm dart run build_runner build --delete-conflicting-outputs
fvm flutter analyze
fvm flutter test
fvm flutter test integration_test
fvm flutter run
```

当前 HTML 演示仍使用：

```bash
python3 -m http.server 4173 --directory IOS-IM
node --test IOS-IM/prototype.test.cjs
```

## 13. 发布门槛

进入 TestFlight 与 Google Play 内测前必须满足：

- 账户删除和数据导出真实可用。
- Apple 登录、Token 账本与支付回执具备幂等处理。
- 权限文案和 Privacy Manifest 完成。
- Android Data Safety、通知权限和前台服务声明完成。
- Provider、豆包和 Vidu 都有超时、熔断和总开关。
- 群聊 Run 具备 Token、轮数、时间和工具调用上限。
- Prompt、Agent Profile 和 Graph 都记录版本。
- Staging 完成弱网、后台恢复、推送和断线重连测试。
- 崩溃、日志和 Trace 不包含敏感内容。
