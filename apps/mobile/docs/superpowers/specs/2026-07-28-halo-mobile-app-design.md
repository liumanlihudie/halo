# Halo Flutter 双端工程设计

日期：2026-07-28  
状态：已按产品原型与现有工程文档收敛

## 1. 目标

在 `IOS-IM/apps/mobile` 建立可持续开发、可测试、可在 iOS 与 Android 模拟器运行的 Flutter 工程。现有 `prototype.html` 只作为交互和 Mock 数据参考，不复制其单文件结构。

第一阶段交付双端应用壳、登录态、四个主 Tab、独立页面路由、领域模型、Mock Repository 和首批单元测试。网络、数据库、WebSocket、真实语音和视频能力只定义边界，不在第一阶段接入真实服务。

## 2. 方案选择

### 方案 A：单 Flutter App，按 Feature 分目录

这是首期采用的方案。

- 优点：iOS 与 Android 共享 UI、状态、模型、缓存和测试，启动快且调试直接。
- 边界：Feature 不互相引用 Widget；跨模块能力通过 Core 协议和领域模型协作。
- 演进：当模块稳定或多人并行开发时，再把 DesignSystem、Networking 等抽为独立 Dart Package。

### 方案 B：Flutter App 从第一天拆多个 Dart Package

- 优点：编译边界和依赖约束更强。
- 缺点：首期包结构、资源管理和生成代码配置成本较高，产品仍在快速调整时收益有限。

### 方案 C：所有页面放入一个 App 目录

- 优点：最省初始配置。
- 缺点：会重现 HTML 单文件的问题，路由、状态、Mock 和业务逻辑很快互相耦合，因此不采用。

## 3. 工程结构

```text
IOS-IM/apps/mobile/
├── lib/
│   ├── app/
│   │   ├── app.dart
│   │   ├── environment.dart
│   │   ├── router.dart
│   │   └── root_shell.dart
│   ├── core/
│   │   ├── design_system/
│   │   ├── models/
│   │   ├── networking/
│   │   ├── persistence/
│   │   ├── realtime/
│   │   └── media/
│   ├── features/
│   │   ├── auth/
│   │   ├── conversations/
│   │   ├── chat/
│   │   ├── group_chat/
│   │   ├── contacts/
│   │   ├── agent_market/
│   │   ├── moments/
│   │   ├── settings/
│   │   ├── voice_call/
│   │   └── video_call/
│   └── mock/
│       ├── mock_data/
│       └── repositories/
├── test/
├── integration_test/
├── ios/
├── android/
├── assets/
├── pubspec.yaml
└── docs/
```

每个 Feature 内部按需要包含 `domain`、`data`、`application` 和 `presentation`，但不为了目录整齐创建空层级。

## 4. 应用导航

根 Router 只根据会话状态决定显示登录流程或主应用。主应用固定四个 Tab：

1. 对话
2. 通讯录
3. AI 朋友圈
4. 设置

全局导航由 go_router 集中维护，不在页面内拼装全局导航状态。单聊、群聊、Agent 资料、AI 市场、账户中心、Token 充值等都是独立 Route 和独立 Widget。

登录退出流程：

```text
未登录 → 登录页 → 主 Tab
主 Tab → 设置 → 退出确认 → 登录页
```

演示阶段账号和密码只要非空即可登录；验证码接受任意六位数字。修改新密码仍展示强度校验。

## 5. 状态和依赖

- 使用 Riverpod 管理页面状态与依赖注入。
- Provider 注入会话、Agent、会话列表、消息、朋友圈和账务 Repository。
- Widget 只调用 Notifier 或 Repository 协议，不直接读取 JSON、数据库 Row 或 Dio。
- Mock 与真实实现遵循同一协议，切换环境时不改页面代码。
- 全局状态仅保留登录会话、当前账户和 Router；消息草稿、筛选条件等状态归各 Feature。

## 6. 领域模型

首期建立以下稳定模型：

- `Account`
- `Agent`
- `Conversation`
- `ConversationMember`
- `Message`
- `MessageContent`
- `GroupReplyMode`
- `Moment`
- `TokenBalance`
- `TokenTransaction`

`MessageContent` 使用枚举表达文字、图片、文件、语音、网页、表格、图表、日历、风险、失败和系统通知，避免一个包含大量可选字段的消息对象。

群聊回复模式固定为：

- `automatic`：系统选择 1–2 个 Agent。
- `mentioned`：只调用被点名 Agent。
- `everyone`：所有群成员依次发言、补充或反驳，最后总结。

## 7. UI 规范

- 使用 Flutter 的 Navigator、NavigationBar、ListView、BottomSheet、Dialog 和 SafeArea，并按平台适配返回手势。
- 图标使用稳定的矢量图标集；iOS 专属系统图标只能通过明确的平台适配层使用，不复制 HTML 字体图标或手绘 SVG。
- iOS 交互区域最小 44×44pt，Android 最小 48×48dp。
- 支持系统字号缩放、深色模式、VoiceOver 和 TalkBack。
- 颜色优先使用系统语义颜色；品牌色只作为 Accent。
- 不绘制网页滚动条、浏览器边框或模拟 iPhone 外壳。

## 8. 数据流

发送消息的页面数据流：

```text
Composer
  → ChatController
  → MessageRepository
  → 本地乐观消息
  → RealtimeClient 事件
  → ConversationStore 去重和归并
  → Flutter Widget 更新
```

首期 Mock Repository 立即返回确定性结果，并能模拟发送中、失败、重试、流式生成和停止状态。后续真实实现保持相同接口，通过 API 和 WebSocket 替换 Mock。

## 9. 错误处理

- 可恢复错误在内容附近展示重试，例如文件上传失败和消息发送失败。
- 登录字段错误显示在字段下方。
- 全局阻断错误使用 Alert。
- 短暂成功反馈使用轻量 Toast 或系统反馈，不遮挡点击。
- Repository 错误转换为领域错误，Widget 不直接展示服务端原始报错。
- 重复实时事件按 `eventId` 去重，旧序号事件不重复应用。

## 10. 测试策略

### 单元测试

- `router_test.dart`：四 Tab 顺序、登录路由、退出后回登录。
- `auth_controller_test.dart`：任意非空账号密码可登录，空值不能登录。
- `ConversationStoreTests`：会话排序、未读数和事件去重。
- `GroupReplyModeTests`：三种模式的目标 Agent 选择。
- `MessageContentTests`：各种消息格式可稳定渲染所需数据。

### 集成测试

- 退出后可以重新登录。
- 四个 Tab 可切换。
- 所有 Mock 会话可以进入。
- 单聊加号菜单包含语音和视频通话。
- 群聊不出现语音或视频通话。
- AI 市场可筛选并添加 Agent。

### 构建验证

- iOS Simulator 与 Android Emulator 都能构建和启动。
- `flutter analyze`、`flutter test` 和核心 `integration_test` 必须通过。
- 单元测试必须通过后才增加下一批页面。
- 核心 Feature 提供可独立运行的 Widget Catalog 或 Golden 测试场景。

## 11. 第一阶段验收

1. Flutter 工程能生成 iOS 与 Android Runner，并在双端模拟器构建。
2. 登录、退出和重新登录链路可操作。
3. 四个主 Tab 都是独立 Flutter Feature 页面。
4. 对话列表可进入单聊和三种文字群聊。
5. 页面由 Mock Repository 提供数据，不依赖 HTML DOM。
6. 路由、认证和群聊模式有自动化测试。
7. 工程目录中不存在承载全部页面的单一超大 Widget。

## 12. 非目标

第一阶段不实现：

- 真实账户服务和短信验证码。
- LangGraph 与模型 Provider 调用。
- 真实 Token 支付。
- 豆包端到端语音。
- Vidu 视频通话。
- APNs、FCM、跨设备云同步和生产数据库。

这些能力会在 Flutter 双端应用壳稳定后按现有 MVP 实施计划逐项接入。
