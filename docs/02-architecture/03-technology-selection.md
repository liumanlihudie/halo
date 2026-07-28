# IOS-IM Agent 技术选型决策

版本：1.0  
日期：2026-07-28  
决策：LangGraph 作为服务端编排核心

## 1. 评估对象

- [OpenMinis](https://github.com/OpenMinis/OpenMinis)：原生移动端、设备内 Agent Runtime。
- [Hermes Agent](https://github.com/NousResearch/hermes-agent)：功能完整的通用 Agent 和子任务委派系统。
- [LangGraph](https://github.com/langchain-ai/langgraph)：持久化、有状态的工作流与多 Agent 编排框架。

## 2. 需求权重

| 需求 | 权重 |
|---|---:|
| 三种群聊模式可确定控制 | 25% |
| 具名长期 Agent 与独立记忆 | 20% |
| 中断恢复、重试和状态可观测 | 15% |
| 多模型、工具和流式输出 | 15% |
| 移动双端接入成本 | 10% |
| 商业许可与可维护性 | 10% |
| 首版开发速度 | 5% |

## 3. 结论矩阵

| 方案 | 优势 | 关键缺口 | 定位 |
|---|---|---|---|
| OpenMinis | iOS 原生、设备工具、本地 Linux、成熟单 Agent 交互 | 多 Agent 群聊不是核心；GPLv3；首版过重 | 设计参考 |
| Hermes | Agent Loop、工具、Skills、记忆、子 Agent 委派较完整；MIT | 偏主 Agent → 临时子任务；具名持久 Profile 和产品化群聊仍需改造 | 可选执行器 |
| LangGraph | Router、条件边、并行、子图、Checkpoint、可恢复状态；MIT | 不是成品，需要自行实现 Agent、数据和运营能力 | 编排核心 |

## 4. 决策

正式 MVP 使用：

```text
Flutter iOS / Android
  + 自有业务 API
  + LangGraph Orchestrator
  + 自有 Agent/Profile/Memory 数据模型
  + Provider SDK 或 LangChain 模型适配
```

### 4.1 移动端框架选择 Flutter

- 产品从零开始，没有必须复用的 React Native、SwiftUI 或 Jetpack Compose 代码。
- 聊天消息、群聊状态、朋友圈卡片、市场和设置需要大量一致的自定义 UI，Flutter 可以共享 Widget、状态、路由、缓存和自动化测试。
- 相机、文件、通知、豆包语音和 Vidu 等平台能力通过 Flutter Plugin 暴露统一 Dart 接口，插件内部保留 Swift/Kotlin 实现。
- 不选择 React Native：当前没有 React 团队与既有组件资产，无法抵消 JavaScript 与原生模块边界的维护成本。
- 不选择 Compose Multiplatform：虽然 Android 与 iOS UI 已稳定，但当前没有 Kotlin 工程基础，且 iOS 专属 SDK 接入仍需要原生适配。

Flutter 支持范围与插件机制以官方文档为准：

- [Flutter 支持平台](https://docs.flutter.dev/reference/supported-platforms)
- [Flutter 插件开发](https://docs.flutter.dev/packages-and-plugins/developing-packages)

### 不采用完整 OpenMinis Fork

- OpenMinis 最有价值的是移动端 Agent Loop、工具卡片、流式表现、上下文压缩和设备权限设计。
- 它的并发工具不是多 Agent 编排，Session Fork 也不是协作 Agent。
- GPLv3 对闭源商业应用存在明显约束。
- 完整 Alpine/iSH 会提高包体、能耗、后台执行和构建复杂度。

### 不采用 Hermes 作为总控

- Hermes 适合让主 Agent 分派研究、编程、浏览器等任务。
- 本产品要求用户直接看见并长期维护多个专家身份，流程需要比自由委派更确定。
- 群成员、发言顺序、反驳次数、总结来源、Token 预算必须由业务状态机掌控。
- 如果某个专家需要复杂 Shell、浏览器或长任务，可把 Hermes 封装为该专家的 Runner。

### 选择 LangGraph

- `auto` 可实现为 Router + 1–2 个节点。
- `mentioned` 可实现为确定性条件边。
- `all` 可实现为发言队列、Review 循环和 Summary 节点。
- Checkpoint 能覆盖停止、恢复、失败重试和长任务。
- MIT 许可适合商业产品；部署可以完全自托管。

## 5. LangChain 的使用边界

“使用 LangChain”不等于把所有业务都写成 Chain。

允许使用：

- Provider 和 Tool 的标准化适配。
- Structured Output 与 JSON Schema 校验。
- 文档解析、检索器等成熟组件。

不允许依赖：

- 隐式全局 Memory。
- 无状态、不可恢复的长 Chain。
- 让一个 Supervisor 自由决定所有产品状态。

业务状态、权限、计费、消息和 Agent 身份始终由自有数据库管理。

## 6. 风险控制

| 风险 | 控制 |
|---|---|
| LangGraph 图逐渐过大 | 单聊、群聊、总结、朋友圈拆成独立子图 |
| 框架升级影响恢复 | 固定版本；Checkpoint 记录 `graph_version` |
| Provider 类型侵入业务 | 自有 `ModelGateway` 协议隔离 |
| 上下文成本失控 | 快照、窗口、摘要和 Run 级预算 |
| Hermes 执行器成为单点依赖 | 只实现标准 `AgentRunner` 接口，可替换 |
| 移动端与服务端状态不一致 | 服务端序号、事件重放和幂等消息 ID |

## 7. 验证性 Spike

正式开发第一阶段完成一个最小验证：

1. 建立三个固定 Agent Profile。
2. 实现 `auto`、`mentioned`、`all` 三条图路径。
3. 使用两个不同模型 Provider。
4. 在 `all` 中完成观点、一次交叉评论和总结。
5. 中途停止并从 Checkpoint 恢复。
6. 输出每个 Agent 的 Token、延迟和费用。

Spike 通过标准：没有重复消息、没有跨 Agent 私有记忆、三种模式的实际调用对象与 UI 提示一致。
