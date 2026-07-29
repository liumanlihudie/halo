# Halo Mobile App 设计规格

日期：2026-07-28  
状态：已收敛为 Flutter iOS-first 的 MVP 前置工程里程碑

## 1. 目标与边界

Halo 是面向单个个人用户的 AI 原生即时通讯应用。用户直接启动应用，在本机配置一个或多个模型服务的 API Key，与不同专长的 AI Agent 对话、协作，并查看专家主动产生的圈层内容。

本规格定义当前有效的移动端方向：

- 数据、会话、Agent、记忆和附件默认留在设备本机。
- 模型服务由用户自带密钥配置；内置与自定义 Provider 可以同时使用。
- 专家身份与底层模型解耦；切换模型不会改变专家的人设、权限或记忆边界。
- 四个固定主入口为：**对话、专家团、圈层、设置**。
- 群聊仅支持文字，并提供自动选择、指定回答、全员讨论三种模式。
- 专家协作和事实可信度采用结构化 `AgentMessage`、`Claim`、`EvidenceRef` 与独立 `Verifier` 边界。
- Gateway 是用户自行部署的可选扩展，不是基础功能的前置条件。

第一阶段是最终 Flutter iOS / Android MVP 之前的 iOS-first 工程里程碑。唯一可运行交付物是 Flutter iOS 工程底座及由确定性 fixtures 和内存 Repository 驱动的可交互演示数据。它不发起真实模型请求，不执行真实的群聊编排、语音视频、联网检索或 Gateway 调用。共享的 domain、features 和基础协议必须保持平台无关；第一阶段通过 iOS Simulator 验证工程和交互，后续再生成 Android Runner，并在 Android Emulator 与真机完成对等验收。

## 2. 设计原则

1. **对话优先**：任务、追问、文件交换、协作与结果回溯均以会话为中心。
2. **本地优先**：离线仍可查看已落库会话、专家、圈层、附件元数据和设置；远端能力是可替换扩展。
3. **专家优先于模型**：用户面向专家选择能力，模型选择由专家策略、本地路由和用户偏好共同决定。
4. **可控的多专家协作**：用户始终知道哪些专家会发言、处于哪个阶段，并能停止讨论或协作分支。
5. **可信状态可见**：观点、建议与事实分开表达；没有可追溯证据的内容不能表现为确定事实。
6. **熟悉但独立**：采用移动 IM 的低学习成本结构，不复制其他产品的品牌资产、特有图标、文案或布局。

## 3. 第一阶段交付范围

### 3.1 必须可运行的内容

- 一个可由 Xcode 打开、在 iOS Simulator 启动的 Flutter 工程。
- 最终 iOS / Android 共用的 Dart 领域层和 Feature 边界；其中不得直接引用 UIKit、Keychain 或其他 iOS API。
- Riverpod、go_router、自有 Design System 与 feature-first 目录骨架。
- 启动后直达四栏主界面，四个入口可切换并保留各自导航栈。
- 对话列表、单聊、三种文字群聊、专家团、圈层、设置的静态或本地 Mock 页面。
- 领域模型、Repository 接口和确定性 Mock Repository。
- Drift schema、本地资产库、密钥仓库和多 Provider 的接口、数据合同与测试替身。
- 可演示的协作过程、Claim、Evidence 和核验状态视图；数据由本地样例提供。
- 单元、Widget 与基础集成测试，覆盖主导航、路由、群聊模式和关键本地数据契约。

### 3.2 明确不在第一阶段实现

- 真实模型服务连接、流式输出、模型目录拉取、用量查询或自动降级。
- 真实 Agent 调度、工具调用、联网取证、独立核验或长期记忆写入。
- 一对一语音、视频、推送、跨设备同步与后台任务。
- 导入导出、媒体处理流水线和真实 Gateway 通信。
- Android Runner 的生成、平台适配与设备验收；这些工作在共享 Dart 边界稳定后进行。
- 真人联系人、真人社交关系、企业组织管理和公共内容推荐。

上述能力只能在既定边界内逐项接入；页面不得为尚未接入的能力伪造已生效的结果。

## 4. 信息架构与导航

根路由无身份前置流程。应用启动后进入 `AppShell`，底部固定四个 Tab：

| Tab | 首屏职责 | 可进入页面 |
|---|---|---|
| 对话 | 展示按最近活动排序的单聊和群聊 | 单聊、群聊、群资料、聊天记录与资产引用 |
| 专家团 | 管理本机已安装的 AI Agent | Agent 资料、AI 市场、创建群聊、加入现有群 |
| 圈层 | 展示专家主动分享与任务结果 | 动态详情、来源依据、继续对话、发布规则 |
| 设置 | 管理模型服务、本地数据、隐私与扩展 | Provider 详情、存储管理、记忆与隐私、Gateway、圈层发布管理 |

路由由 `go_router` 集中定义。Tab 内采用 StatefulShellRoute 或等价的独立 Navigator，避免进入聊天后切换 Tab 丢失阅读位置。跨 Tab 的操作使用明确的 URI 参数或领域 ID，例如从圈层动态进入其来源会话时传递 `conversationId` 与 `messageId`，而不是传递 Widget 实例。

推荐的首期路由如下：

```text
/
  /conversations
  /experts
  /circle
  /settings
  /chat/:conversationId
  /groups/:conversationId/info
  /experts/:agentId
  /experts/market
  /circle/:postId
  /settings/providers
  /settings/providers/:providerId
  /settings/local-data
  /settings/gateway
```

## 5. 工程结构

采用单一 Flutter 应用、按 Feature 分目录的方案。首期不拆分多个 Dart Package，以降低工程初始化和资源管理成本；模块之间只经由领域模型、Repository 协议和应用服务协作。

```text
apps/mobile/
├── lib/
│   ├── app/
│   │   ├── app.dart
│   │   ├── bootstrap.dart
│   │   ├── router.dart
│   │   └── app_shell.dart
│   ├── foundation/
│   │   ├── database/
│   │   ├── files/
│   │   ├── network/
│   │   ├── security/
│   │   ├── design_system/
│   │   └── diagnostics/
│   ├── domain/
│   │   ├── models/
│   │   ├── repositories/
│   │   └── services/
│   ├── features/
│   │   ├── conversations/
│   │   ├── group_chat/
│   │   ├── expert_team/
│   │   ├── agent_market/
│   │   ├── circle/
│   │   ├── providers/
│   │   ├── local_data/
│   │   ├── memory/
│   │   └── gateway/
│   └── mock/
│       ├── fixtures/
│       └── repositories/
├── test/
├── integration_test/
├── assets/
├── ios/
└── pubspec.yaml
```

Feature 可以按需细分为 `data`、`application`、`presentation`，但不创建没有职责的空目录。页面不能直接读取数据库行、文件路径、密钥或厂商协议；这些实现被限制在 foundation 与 data 层。`domain/` 与 `features/` 不得直接依赖 iOS API；Keychain、文件选择、相机、麦克风、通知等平台能力必须通过 Dart 接口和 platform adapter 注入，使同一领域代码可在后续 Android Runner 中复用。

## 6. 状态、依赖与本地数据

- Riverpod 负责依赖装配、异步状态和页面控制器。
- `bootstrap.dart` 先装配确定性 fixtures、内存 Repository、内存 AssetRepository、内存 SecretVault 和 Mock Provider Registry，再挂载 Flutter App。
- Widget 只依赖 Controller、Use Case 或 Repository 协议；Mock 与后续真实实现共享同一协议。
- 全局状态仅包括应用配置、选中的 Tab、已初始化的基础设施引用和短生命周期提示；草稿、筛选器、阅读位置等归各 Feature 管理。
- 所有样例数据具有稳定 ID 和固定时序，保证测试、截图与演示可重复。
- 第一阶段不承诺关闭进程后的数据保留；重启应用可以重新载入同一组确定性 fixtures。

本机持久化边界如下：

| 数据 | 第一阶段边界与测试替身 | 后续真实实现 |
|---|---|---|
| 会话、消息、Agent、Run、记忆、圈层动态 | Drift schema、Repository 协议、fixtures 与内存实现 | Task 2 实现 SQLite 写入、查询、迁移和崩溃恢复 |
| 图片、音频、视频、文件 | Asset 数据合同、引用关系与内存 AssetRepository | Task 2 实现 SHA-256 去重、原子落盘、缩略图与清理 |
| API Key、敏感 Header、Gateway 凭据 | `SecretVault` 协议与不接触系统存储的内存替身 | 后续 platform adapter 分别接入 iOS Keychain 与 Android Keystore |
| 临时文件和缩略图 | 缓存接口与目录约定 | 有界缓存、空间回收和故障恢复 |

Drift schema 只允许保存 `secretRef`，不得定义保存完整 API Key 的列。资产路径合同只接受 App 沙盒相对路径。第一阶段只测试 schema、Row Mapper、Repository 和 Vault 接口，不打开生产 SQLite 文件，也不执行真实迁移；实际 SQLite 写入、路径解析、迁移与恢复属于后续 Task 2。

## 7. 领域模型

首期先固定跨 Feature 的数据合同。展示层可以使用样例数据，但不得自行发明与合同不一致的字段。

```text
LocalProfile
  deviceId, displayName, avatar, preferences

AgentProfile
  id, name, avatar, category, status
  personaProfile, toolIds, modelPolicy
  sharedMemoryPolicy, privateMemoryId, proactivePolicy

Conversation
  id, type(oneToOne|group|system), title
  memberAgentIds, hostAgentId, defaultReplyMode
  sharedContextPolicy, summaryPolicy, latestActivityAt

Message
  id, conversationId, senderType(user|agent|system)
  senderId, content, status, createdAt
  replyMode, mentionedAgentIds, replyToMessageId, assetRefs

Run
  id, conversationId, kind, phase, status
  cancelState, modelSnapshot, startedAt, completedAt

Asset
  id, origin, mediaType, mimeType, sha256
  localRelativePath, thumbnailRelativePath, referenceCount, status

CirclePost
  id, createdByAgentId, sourceRunId, sourceMessageId
  kind, content, assetRefs, createdAt, publishingState
```

`MessageContent` 使用封闭类型表达纯文本、图片、文件、引用来源、任务进度、结构化结论、失败与系统通知。避免以大量可空字段承载互斥内容。每条消息以稳定 `messageId` 关联附件、Run、事实声明和后续导航。

## 8. 多 Provider 与本地模型路由边界

移动端不把业务模型绑定到任一厂商。预置 ToAPIs、DeepSeek、OpenAI、Anthropic、Gemini 与豆包实时语音的 Adapter 类型，并支持多个自定义 OpenAI-compatible 实例和本地模型服务。

统一模型引用为：

```text
ModelRef
  providerId, modelId

ProviderConfig
  id, adapterType, displayName, baseUrl
  secretRef, enabled, priority, capabilityOverrides, healthState

AgentModelPolicy
  primaryModelRef, fallbackModelRefs, taskOverrides
  qualityTier, latencyPreference, costPreference

RunModelSnapshot
  providerId, modelId, adapterVersion
  catalogVersion, capabilitySnapshot
```

`modelId` 不是全局唯一值，任何持久化模型选择都必须保存 `providerId + modelId`。Provider 配置变化不会破坏既有消息或已保存的 `RunModelSnapshot`。

后续真实接入遵循下列协议；第一阶段只提供可测试的接口、空实现和设置页样例状态：

```dart
abstract interface class ModelProvider {
  String get providerId;
  ProviderCapabilities get capabilities;

  Future<ConnectionResult> testConnection();
  Future<List<ModelDescriptor>> listModels({ModelKind? kind});
  Stream<ModelEvent> generateText(ModelRequest request);
  Future<GenerationTask> generateMedia(MediaRequest request);
  Future<GenerationTask> getMediaTask(String remoteTaskId);
  Future<void> cancelMediaTask(String remoteTaskId);
  Future<ProviderBalance?> getBalance();
}
```

`ProviderRegistry` 创建并隔离各 Provider 实例；本地 `ModelRouter` 先按能力、可用性、显式选择与用户优先级过滤和评分，再固化 `RunModelSnapshot`。自动路由要能解释所选专家和模型的原因，但不能暴露密钥或内部提示词。失败切换只允许发生在没有可见输出且错误可重试时；工具副作用必须依赖幂等键。

设置页的 Provider 卡片显示已配置、未配置或异常等样例状态、可用模型数、默认能力、最近检测时间和密钥尾号掩码。页面中的连接测试与保存按钮在首期只更新本地演示状态，不访问网络。

## 9. 对话与群聊

### 9.1 单聊

单聊面向一个 Agent，首期提供可发送的本地乐观文本消息、确定性的 Mock 回复、消息状态、引用来源入口、附件入口占位和失败重试样例。聊天资料页提供“查找聊天记录”的类型筛选入口，按全部、图片与视频、文件、链接和 AI 成果组织；首期结果由 fixtures 驱动。

语音和视频是后续独立 Feature，不属于当前聊天实现。未来通过 `CommunicationCapability`、`CallLauncher` 等平台无关接口向一对一会话注册可用动作，再由 iOS 与 Android adapter 实现设备能力；聊天 Feature 只消费能力描述和启动合同，不直接依赖音视频 SDK、平台 API、媒体会话状态或实现类。第一阶段不创建音视频路由、按钮、占位实现或演示状态，群聊也不暴露相关能力。

### 9.2 三种文字群聊模式

群聊成员均为 Agent，使用本地状态机表达以下模式：

| 模式 | 触发 | 规则 | 首期演示 |
|---|---|---|---|
| `auto` | 普通发送 | Router 从群成员中选择 1–2 位合适专家 | 固定选择样例专家并显示选择原因 |
| `mentioned` | `@Agent` | 仅运行被点名的一个或多个专家 | 根据输入中的稳定 Agent ID 生成 Mock 回复 |
| `all` | `@所有人` 或“让大家讨论” | 全员按队列发言，可有限补充或反驳，最后总结 | 展示观点收集、交叉讨论、总结三阶段 |

每个群聊 Run 都有稳定 ID、阶段、取消状态和 Repository 状态位置。界面同一时刻仅显示一个“正在输入”的 Agent，用户可停止整个讨论或单个协作分支。首期的停止按钮必须改变内存状态，不得仅做视觉反馈。

群资料包括群名称、头像、目标、成员、主持 Agent、默认发言模式、共享上下文范围、允许的资产范围、自动总结和圈层发布规则。每项设置先写入本地 Mock Repository，并为后续 SQLite 实现保留相同接口。

## 10. AgentMessage 专家协作

专家之间只能通过由群聊编排器控制的 `AgentMessage` 通信；不能形成无限制、不可审计的后台对话。

```text
AgentMessage
  id, runId, parentMessageId
  senderAgentId, recipientAgentId
  kind(question|delegation|delivery|critique|verificationRequest|handoff)
  allowedMessageIds, claimIds, evidenceRefIds, assetIds
  state(requested|processing|completed|rejected|failed|cancelled)
  budget, idempotencyKey, createdAt, completedAt
```

编排器负责接收方权限、私有记忆隔离、通信预算、循环检测、幂等派发、分支停止和审计记录。`AgentMessage` 只能传递已授权的消息、Claim、Evidence 与 Asset ID；有副作用的工具仍需经过 Tool Permission Broker。

用户看到两条明确分离的线：

- **群内公开消息**：必要的观点、回复和总结进入时间线。
- **专家协作过程**：提问、委派、交付、批评和核验请求在独立审计视图中查看，避免刷屏。

首期使用固定协作轨迹验证 UI、状态机和停止逻辑。真实派发、工具执行和模型上下文拼装留到后续里程碑。

## 11. Claim、Evidence 与 Verifier 可信层

多专家一致不等同于事实。任何事实性结果在最终对用户可见前必须遵循：

```text
观点生成
→ 原子 Claim
→ 证据绑定
→ 独立 Verifier
→ 冲突处理
→ 受约束总结
→ 发布闸门
```

回答模式先由确定性规则分类为 `creative`、`grounded` 或 `high_stakes`。包含时效性、价格、政策、法律、医疗、财务或真实性判断的请求不得落入 `creative`。

```text
Claim
  id, runId, createdByAgentId, text
  type(fact|inference|opinion|proposal)
  risk(low|medium|high), temporalScope
  evidenceRefIds
  verificationStatus(
    unverified|supported|partiallySupported|
    contradicted|unverifiable|stale
  )
  verifierRunId, verificationNotes

EvidenceRef
  id
  sourceType(
    user_message|local_asset|web_source|
    tool_result|database_record|test_result
  )
  sourceId, sourceTitle
  locator, capturedAt, contentHash, excerpt, trustTier
```

`Claim` 必须原子化：一条可独立验证的陈述对应一个 Claim。`opinion` 和 `proposal` 不得伪装为事实；`inference` 必须展示推断依据。其他 Agent 的发言仅是待核验线索，不能升级证据等级。

证据等级由确定性规则根据来源类型、独立性、时效、可复现性与风险计算，模型不得自行填写：

| 等级 | 规则含义 | 可支持内容 |
|---|---|---|
| E0 | 没有证据 | 创意、意见和待验证假设 |
| E1 | 用户输入或单一非权威来源 | 低风险背景，必须显示来源局限 |
| E2 | 单一一手来源或可复现工具结果 | 普通事实 |
| E3 | 多个独立来源，且至少一个是一手来源 | 高风险或争议事实 |
| E4 | 确定性验证，例如计算、数据库查询、测试或签名校验 | 可复现的确定结论 |

多个来源若互相转载或来自同一上游，只按一个独立来源计算。风险要求与证据等级共同决定 `verificationStatus`；模型自报置信度和多个 Agent 的重复说法均不参与等级计算。

Verifier 与原始观点生成者隔离，只能判定证据的支持、部分支持、冲突、不可核验或过期，以及推荐保守措辞。中高风险场景优先采用不同模型家族或 Provider 核验。总结器只能读取 Claim、核验状态、Evidence 与明确标注的观点建议，不能补充新事实。

每个事实性消息显示轻量状态：已核验、部分支持、待核验、有冲突或仅为建议。点击打开“查看依据”面板，其中包含 Claim、来源定位、核验结论与抓取时间。群聊总结卡显示已核验事实、分歧、待确认与来源的数量。

发布闸门阻止未核验、冲突、不可核验或已过期的事实性 Claim 进入长期事实记忆和圈层。高风险结果还需要用户确认。首期以本地 fixtures 覆盖每种状态和阻断结果，不进行真实取证。

## 12. 圈层与专家团

专家团仅包含本机 Agent，按工作、资讯与生活能力组织。用户可以搜索、筛选、查看专家资料、开始单聊、加入群聊或从 AI 市场添加模板。专家资料必须显示专业边界、工具权限、记忆范围、模型策略和主动发布规则。

圈层是按发布时间倒序的私人专家动态流，不做分类、公共推荐或真人互动。内容包括专家主动分享、对话总结、任务成果、定时任务、监控变化、进度、异常和失败。原始私密文件不直接展开，仅提供经过允许的摘要和资产引用。

每位专家默认允许发布。关闭某位专家的发布权限不会停止其对话、任务、定时任务或监控，也不删除已有动态。所有有来源的动态必须能进入来源依据或原会话；事实性动态同样受发布闸门约束。

## 13. UI 与可访问性

- 使用 `NavigationBar`、`ListView`、`BottomSheet`、`Dialog` 和 `SafeArea`，并遵循 iOS 返回手势与系统字号。
- 交互目标至少 44×44 pt；不绘制网页滚动条、浏览器边框或设备外壳。
- 颜色、字级、圆角、间距与图标由 Design System 变量提供；品牌色只作为强调色。
- 支持浅色、深色、动态字号、VoiceOver、语义标签和减少动态效果偏好。
- 图片、文件、进度、错误、核验状态和协作状态都必须具有非颜色的文字或图标表达。
- 首期所有未接通能力必须有明确的本地提示，不显示永远旋转的加载状态。

## 14. 错误、取消与隐私

- 可恢复的局部错误在内容附近显示重试；阻断操作才使用 Alert。
- Repository 将基础设施错误转换为领域错误，Widget 不直接展示底层异常文本。
- 每个 Run、媒体任务和协作分支都可取消；取消后保留已产生的本地内容并标记终止原因。
- 重复事件以 `eventId` 或稳定实体版本去重；旧事件不得覆盖新状态。
- 日志默认脱敏，不记录完整 API Key、完整提示词、消息正文或附件正文。
- Provider 连接测试不得发送用户对话；移除密钥、清除本机数据和覆盖导入均须显式确认。
- 导出能力接入时必须排除 Vault 内容、敏感 Header、Gateway 凭据、缓存和临时文件。

## 15. 可选 Gateway

Gateway 是单独发布、由用户自行部署的开源组件。移动端的 Gateway Feature 只管理地址、版本、健康状态和本机 Vault 引用；关闭或不可达时，基础本地功能仍然完整可用。

后续 Gateway 可提供：服务端签名、短期凭据、WebSocket/SSE 协议适配、统一网络出口，以及需要回调或签名的实时语音和长任务能力。它不保存 Halo 的对话、记忆或附件，也不承担身份、云存储或计费职责。

第一阶段仅实现 `GatewayClient`、版本协商数据模型和离线 Mock；设置页展示“未连接”或固定样例健康状态。

## 16. 实施顺序

1. **iOS-first 工程与设计系统**：创建 Flutter iOS Runner、平台无关路由、四 Tab、Theme、可访问性变量与基础测试；建立平台能力接口，禁止 domain 与 features 直接引用 iOS API。
2. **第一阶段数据边界**：只定义 Drift schema、Row Mapper、AssetRepository、SecretVault 和路径合同，以确定性 fixtures 与内存适配器驱动页面，不执行 SQLite 写入或迁移。
3. **领域与 Mock**：落地 Agent、Conversation、Message、Run、CirclePost、ProviderConfig、AgentMessage、Claim 和 Evidence 合同，建立确定性 Repository。
4. **对话和群聊**：完成会话列表、单聊、三种文字群聊、协作审计视图、停止状态与群资料页面。
5. **专家团、圈层、设置**：完成专家资料、市场、动态流、发布规则、模型服务、本地数据和 Gateway 设置页面。
6. **可信表达与质量**：完成依据面板、状态标识、发布闸门样例、Golden/Widget/集成测试和 iOS Simulator 回归。
7. **后续 Task 2 与跨平台验收**：实现 SQLite 写入、查询、迁移、资产落盘与恢复；生成 Android Runner，补齐 Android platform adapter，并在 Android Emulator 与真机完成对等验收。
8. **后续能力接入**：按 Provider 内核、真实文字模型、群聊编排、独立音视频 Feature、多模态、本地导入导出和 Gateway 的独立里程碑推进。

## 17. 测试策略与验收

### 自动化测试

- 路由测试：冷启动直达四栏、Tab 顺序、跨 Tab 深链与返回栈。
- 领域测试：会话排序、未读数、消息状态、资产引用、三种群聊模式、协作分支停止和事件去重。
- 可信层测试：Claim 原子化、状态映射、冲突展示、发布闸门、来源定位与不同专家重复观点不提高证据等级。
- 数据边界测试：Drift schema 不含完整 API Key 列，Row Mapper 只写 `secretRef`，Repository 与 Vault 内存替身遵循接口；不测试真实 SQLite 写入、迁移或重启恢复。
- Provider 契约测试：`ModelRef` 序列化合同、Provider 隔离、能力过滤、媒体任务查询与取消接口、无输出时的可重试降级。
- Widget 测试：四栏、单聊、群聊阶段、协作审计、依据面板、设置页和动态字号。
- 集成测试：iOS Simulator 启动、主导航、样例消息发送、`auto`/`mentioned`/`all` 流程和取消讨论；每次启动均可重新加载同一组 fixtures，但不验收跨重启持久化。

### 第一阶段验收标准

1. `flutter analyze`、`flutter test` 和选定的 iOS `integration_test` 通过。
2. iOS-first Flutter 工程可在 Simulator 构建、启动并稳定切换四个主入口；共享 Dart 代码不直接依赖 iOS API，并明确保留后续 Android Runner 与对等验收里程碑。
3. 不依赖网络即可浏览所有首期样例数据，且样例操作产生可观察的本地状态变化。
4. 对话可进入单聊与三种文字群聊；当前聊天实现不包含音视频按钮、路由、SDK 或平台会话状态。
5. 专家协作过程、可信状态和来源依据均有可访问的演示页面。
6. 数据边界通过测试：Drift schema 与 Row Mapper 只接受 `secretRef`，fixtures 和内存替身不向数据库合同、日志或样例导出数据写入完整 API Key。
7. 未接通的模型、媒体与 Gateway 能力不会被呈现为已完成的业务结果。

## 18. 后续实施约束

接入真实能力时，必须保持本规格的三个不可变约束：本机数据优先、Provider 与业务领域解耦、事实可信度不由多模型投票决定。每个新增 Adapter、资产流水线、编排器或 Gateway 能力都需要独立测试其失败、取消、迁移、隐私与恢复路径，且不能改变既有本地历史的可读性。
