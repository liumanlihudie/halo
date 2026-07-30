# Agent 编排与工具框架开源复用评估

日期：2026-07-30
触发：产品负责人要求「agent 编排、工具设计（不仅仅联网搜索）看看 git 有没有现成的」
方法：两路并行调研（Dart agent 框架 / MCP 与工具生态），结论与推荐见 §4。

## 1. 我们已有什么（不可替换资产）

任何复用方案必须保住以下自研层——没有现成框架提供这些保证：

- **耐久编排**：`BasicDurableRunner` + `SqliteRunEventStore`（崩溃可重放）、
  `SqliteModelCallJournal` 计费围栏（reserve→dispatched→completed，
  幂等键防重复扣费）；
- **结构性信封安全**：`ExecutableExpert.validateAndProject` fail-closed、
  claimType=advice 钉死、未核验披露、执行信封拒收；
- **凭证边界**：SecretRef/Keychain、上游错误正文不落 UI/日志/SQLite、
  端点白名单；
- **模型路由**：`override ?? global`、Provider 启停、目录持久化。

因此复用评估的唯一正确问题是：**哪一层可以换成现成件？**
候选层：① 协议客户端（HTTP 形状/SSE 解析）② 工具定义与执行环
③ agent 高层抽象 ④ 聊天 UI。③④ 我们已有且深度定制，不换。

## 2. Dart agent/客户端框架调研结论（2026-07 实查）

| 包 | 层级 | 维护 | ToAPIs 自定义 baseUrl | 流式工具调用 | 侵入性 |
|---|---|---|---|---|---|
| openai_dart / anthropic_sdk_dart（langchain_dart 子包，MIT） | 类型化 HTTP 客户端 | 极活跃（~24 天前发版） | **官方支持** | 是 | 最低（纯 Dart，无框架绑定） |
| langchain（高层，MIT） | 全框架 LCEL/Agent | 放缓（0.8.1，7 个月前） | 经底层 SDK | 是 | 高 |
| dartantic_ai（BSD-3/MIT 待核） | Agent 框架（Pydantic-AI 式） | 活跃（v3.4.2，27 天前） | 是（OpenAI 兼容 provider） | 是，多步 agent 环 + MCP | 中高（自有 Agent/Tool/Message 抽象） |
| llm_dart（MIT） | 统一客户端 | 一般（4 个月前） | 是 | 是 | 中 |
| flutter_ai_toolkit（Flutter 官方 labs，BSD-3） | 聊天 UI 层 | 维护中（v1.0.0） | N/A（自实现 LlmProvider） | UI 层无关 | 仅 UI |
| Genkit Dart（Google 官方） | 全框架 | 2026-03 发布，preview | 是（OpenAI 兼容） | 是 | 高，API 未稳 |
| dart_agent_core（MIT） | mobile/local-first agent 框架 | 活跃但社区极小（8 likes） | 是 | 是（runStream） | 中高，需自维护心理准备 |

要点：

- 生态里**最活跃、最不侵入**的是 langchain_dart 的 SDK 子包
  （openai_dart / anthropic_sdk_dart）：只当类型化客户端用，
  custom base URL 官方文档化，无 Flutter/框架依赖；
- 完整 agent 环 + MCP 想要现成的，社区最优是 dartantic_ai，
  代价是接受其消息/工具抽象与我们信封管线的适配层；
- langchain 高层与 Genkit 属整框架接管，与 §1 资产冲突面最大，不取；
- dart_agent_core 定位（mobile-first/local-first）与本项目最像，
  但社区体量（8 likes）不足以托付核心层，仅作参考实现阅读。

## 3. MCP 与工具生态调研结论（2026-07 实查）

- **官方 `dart_mcp`（dart-lang/ai，BSD-3）**：活跃但**只支持 stdio 传输**
  （README 明言 Streamable HTTP "Unsupported at this time"）。iOS 禁止
  spawn 子进程 → 官方包在 iOS 内**实际不可用**，不取。
- **`mcp_dart`（leehack，MIT，71 likes/14.6 万下载，35 小时前发版）**：
  client+server+host 全套，实现已锁定的 MCP 2026-07-28 规范，
  **Streamable HTTP（含 OAuth）**；README 明确 Flutter Mobile 无 stdio、
  可连远程 server——**iOS 内嵌 MCP client 的首选**。
  备选 `mcp_client`（makemind.dev，功能相近但仅 7 likes，社区验证不足）。
- **iOS 现实约束**：MCP server 传统形态是本地子进程，iOS 只能走
  远程 Streamable HTTP/SSE。远程生态已成主流（GitHub/Linear/Notion/
  Stripe 等官方 hosted 端点；Tavily/Exa/Firecrawl 提供搜索/抓取类
  hosted MCP，需 API key）。**但 2026-04 对 2181 个远程端点的分析显示
  52% 完全失效、仅 9% 完全健康**——第三方远程 MCP 必须带超时/降级/
  健康检查，核心工具不能指望"即插即用"。
- **可借鉴应用**：**ChatMCP（daodao97/chatmcp，Flutter，Apache-2.0，
  2.2k stars，活跃）**——桌面 stdio+SSE、**移动端仅远程传输**的分层
  与 MCP 市场 GUI 是与本产品最接近的参照系，许可证允许借鉴/复用；
  另有 `mcp_dart` 作者的最小集成样例 flutter-mcp-ai-chat。
- dartantic_ai 自带 `McpClient`（stdio+远程 HTTP 双传输）+ 类型化
  工具定义，可"函数调用为主、MCP 为扩展插槽"两条腿走。

## 4. 推荐（结论先行）

1. **协议客户端层（推荐引入）**：评估以 `openai_dart` 替换我们手写的
   OpenAI 兼容/native transport 的请求/响应形状层，`anthropic_sdk_dart`
   替换 Anthropic transport——保留我们的 SecureJsonHttpClient 端点
   白名单与错误脱敏包裹在外层。收益：流式工具调用、Responses API、
   citations 等形状解析不再自己追协议演进；风险：需验证其能嵌进
   我们的传输安全壳（自定义 http client 注入能力）——**做一个
   spike 分支验证后再定**，不直接改主线。
2. **工具体系双轨（联网搜索之外的工具设计）**：
   - **主轨**：核心工具（搜索、抓取）走厂商托管工具（08 号设计）
     与原生 function-calling——可靠性可控、零新依赖；
   - **扩展插槽**：MCP client 用 `mcp_dart`（MIT，Streamable HTTP，
     iOS 可行）接**远程** MCP server，让高级用户自接 GitHub/Notion/
     Tavily 等 hosted 端点；必须带超时/降级/健康检查（远程生态
     半数端点不可用是实测现实），且每个远程端点过我们的端点
     白名单授权交互，不做静默放行。stdio 形态明确排除在 iOS 外。
3. **产品参照**：ChatMCP（Apache-2.0）的"移动端仅远程传输 + 
   MCP 市场"分层可直接借鉴，许可证兼容。
4. **不换**：耐久运行器、计费围栏、信封安全、路由、聊天 UI。
5. **持续观察**：Genkit Dart 转正（脱离 preview）后重评一次；
   官方 dart_mcp 若补上 Streamable HTTP 再对比 mcp_dart。

## 4a. 复用优先方针（产品负责人定，2026-07-30）

「以后所有的这些复杂的编排和大功能，都用现成的。」——大功能开工前
先查本文档与开源生态，自研仅限 §1 列出的无现成替代层；引入依赖须过
许可证（兼容开源发布）与维护活跃度检查。

## 5. 后续动作

- [x] spike：openai_dart 嵌入安全壳可行性 —— **已验证可行**
  （2026-07-30，分支 `spike/openai-dart-adapter`，提交 cf58bb5，
  4 条离线形状测试全过）：自定义 baseUrl 指 ToAPIs 生效；注入的
  http.Client 能在字节出程序前 fail-closed 执行端点白名单（unary 与
  streaming 同一注入口，无旁路）；上游错误封在类型化异常内可由我们
  的脱敏层统一映射。**注意事项**：库的异常 message 可能内嵌上游正文
  （如 ParseException 拼接 responseBody），映射层必须只输出固定安全
  文案、绝不落 exception.toString()——与现行纪律一致。
  结论：流式改造落地后按此路线替换 OpenAI 兼容 transport 的形状层。
- [x] spike：mcp_dart 远程 Streamable HTTP 最小连通 —— **已验证可行**
  （2026-07-30，分支 `spike/openai-dart-adapter`，提交 4389bec）：
  进程内起真实 StreamableMcpServer（回环随机端口），客户端按 app 将用
  的路径 connect → listTools → callTool 全通，协议协商到 2026-07-28；
  端点授权在我们这层（transport 的 Uri 由我们构造，白名单先于连接）。
  **注意事项**：库自带 INFO/DEBUG 日志（含 server/工具名），接入时须
  按我们的日志纪律收敛日志级别与内容。
- [ ] 结论同步进 `08-agent-web-search-design.md` 的实现选型
- [ ] MCP 工具面的信封/未核验语义设计（工具结果=外部主张，
  沿用结构性披露）——立项时新开 feature spec
