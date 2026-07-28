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
| 01 | [总体技术方案](02-architecture/01-system-technical-design.md) | Flutter 双端、服务端、数据、API、模型、语音视频与安全总设计 |
| 02 | [多 Agent 编排方案](02-architecture/02-agent-orchestration-langgraph.md) | 三种群聊模式、LangGraph 状态机、上下文和失败策略 |
| 03 | [技术选型决策](02-architecture/03-technology-selection.md) | OpenMinis、Hermes、LangGraph 的评估和最终决定 |

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
| 03 | [账户、认证与 Token](04-feature-specs/03-account-auth-token-design.md) | 登录、验证码、密码、切换账号、退出和充值 |

## 05 历史实施计划

- [AI 市场与设置实施计划](05-implementation-plans/01-agent-market-settings-plan.md)
- [全会话 Mock 数据实施计划](05-implementation-plans/02-conversation-mock-data-plan.md)
- [账户、认证与 Token 实施计划](05-implementation-plans/03-account-auth-token-plan.md)

这些文档记录 HTML 演示的实现过程。正式 MVP 开发以 `03-development/04-mvp-implementation-plan.md` 为准。

## 06 质量

- [设计与交互 QA 记录](06-quality/01-design-qa.md)
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
