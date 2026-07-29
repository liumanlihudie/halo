# IOS-IM 文档索引

文档按“产品 → 架构 → 开发 → 功能规格 → 实施计划 → 质量证据”的阅读顺序排列。编号代表推荐阅读顺序，不代表版本号。

## 01 产品

| 顺序 | 文档 | 用途 |
|---|---|---|
| 01 | [最初头脑风暴](01-product/01-brainstorm-2026-07-27.md) | 保存想法形成过程；其中部分早期结论已被后续设计覆盖 |
| 02 | [产品与交互设计](01-product/02-product-design.md) | 当前有效的产品定位、信息架构、群聊规则和验收标准 |
| 03 | [HTML 原型规格](01-product/03-prototype-spec.md) | 页面清单、Mock 覆盖和原型完成条件 |

发生冲突时，以 `02-product-design.md` 为准。

## 02 架构

| 顺序 | 文档 | 用途 |
|---|---|---|
| 01 | [总体技术方案](02-architecture/01-system-technical-design.md) | Flutter 双端、本地数据、Provider、Gateway、语音视频与安全 |
| 02 | [多 Agent LangGraph 参考](02-architecture/02-agent-orchestration-langgraph.md) | 可选自托管复杂 Runner 的图状态与失败策略 |
| 03 | [技术选型决策](02-architecture/03-technology-selection.md) | 本地优先技术栈与不采用项 |
| 04 | [开源本地优先架构](02-architecture/04-local-first-open-source-architecture.md) | 数据边界、请求路径和 Gateway 责任 |
| 05 | [ToAPIs Provider 接入](02-architecture/05-toapis-provider-integration.md) | 预置聚合中转站、Key 配置、模型发现、流式文本与异步媒体 |
| 06 | [多模型 Provider 架构](02-architecture/06-multi-provider-model-access.md) | ToAPIs、官方 API、自定义兼容服务、本地模型与跨 Provider 路由 |
| 07 | [Agent 事实可信与证据协议](02-architecture/07-agent-truthfulness-evidence-protocol.md) | Claim、证据、独立核验、受约束总结、发布闸门与幻觉评测 |
| 08 | [可执行 Agent Profile 与 Prompt 系统](02-architecture/08-executable-agent-profile-prompt-system.md) | Prompt Package、Routing Card、工具策略、记忆、输出 Schema 与评测合同 |

## 03 开发

| 顺序 | 文档 | 用途 |
|---|---|---|
| 01 | [演示版与 MVP 开发总指南](03-development/01-development-guide.md) | 当前演示范围、启动方式、测试和 MVP 阶段 |
| 02 | [工程开发规范](03-development/02-engineering-guide.md) | 正式工程目录、分支、配置、接口、测试和发布规范 |
| 03 | [HTML 原型实施计划](03-development/03-prototype-implementation-plan.md) | 已完成原型的历史实施计划 |
| 04 | [MVP 实施计划](03-development/04-mvp-implementation-plan.md) | 从工程初始化到 TestFlight 与 Google Play 内测的可执行任务顺序 |

## 04 功能规格

| 顺序 | 文档 | 用途 |
|---|---|---|
| 01 | [AI 市场与设置](04-feature-specs/01-agent-market-settings-design.md) | 50 位专家市场和设置资料卡 |
| 02 | [全会话 Mock 数据](04-feature-specs/02-conversation-mock-data-design.md) | 各类消息、会话和异常状态覆盖 |
| 03 | [本地优先与 BYOK](04-feature-specs/03-local-first-byok-design.md) | 无账号、模型密钥、本地数据与自托管 Gateway |
| 04 | [聊天记录与文件资产](04-feature-specs/04-chat-history-assets-design.md) | 按会话分类查找用户文件和模型生成成果 |
| 05 | [专家团与圈层](04-feature-specs/05-expert-team-circle-design.md) | 四栏导航、私人专家动态流和按专家发布权限 |
| 06 | [聊天详情与专家资料完整交互](04-feature-specs/06-chat-details-expert-profile-interactions.md) | 单聊、群聊、专家资料的熟悉路径与全可点击验收矩阵 |

## 05 历史实施计划

- [AI 市场与设置实施计划](05-implementation-plans/01-agent-market-settings-plan.md)
- [全会话 Mock 数据实施计划](05-implementation-plans/02-conversation-mock-data-plan.md)
- [本地优先与 BYOK 实施计划](05-implementation-plans/03-local-first-byok-plan.md)
- [专家团与圈层实施计划](05-implementation-plans/04-expert-team-circle-plan.md)
- [聊天详情与专家资料完整交互实施计划](05-implementation-plans/05-chat-details-expert-profile-plan.md)
- [聊天记录搜索与卡片模式实施计划](05-implementation-plans/06-chat-history-search-card-plan.md)
- [基础文字对话编排实施计划](05-implementation-plans/07-basic-conversation-orchestration-plan.md)
- [真实 Agent 单聊与群聊实施计划](05-implementation-plans/08-real-agent-chat-and-group-chat-plan.md)

01–06 记录 HTML 演示的实现过程；07 记录已完成的本地确定性 durable
编排阶段；08 记录已接通的真实 Provider durable 单聊，以及生产群聊待接线工作。
总体 MVP 顺序继续参考 `03-development/04-mvp-implementation-plan.md`。

## 06 质量

- [设计与交互 QA 记录](06-quality/01-design-qa.md)
- [聊天详情与多 Provider QA](06-quality/02-chat-details-multi-provider-qa.md)
- `06-quality/assets/`：浏览器验收截图

## 根目录非文档文件

| 文件 | 说明 |
|---|---|
| `../prototype.html` | 当前唯一静态演示入口 |
| `../prototype.test.cjs` | 原型契约测试 |

## 文档维护规则

1. 新产品决策写入产品设计或对应功能规格，不追加到头脑风暴原文。
2. 跨模块技术决策写入架构文档；局部实现细节写入工程开发规范。
3. 已执行完成的临时计划保留在 `05-implementation-plans`，不作为当前规范引用。
4. 文档中禁止出现 `TBD`；未决定事项必须写明负责人、触发条件和决策截止阶段。
5. 每次修改接口、状态机或数据模型时，同步更新测试与相关文档。
