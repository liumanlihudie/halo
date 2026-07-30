# Agent 联网搜索设计

日期：2026-07-30
状态：设计定稿，待实现（实现排期见 `05-implementation-plans/10-agent-web-search-plan.md`）
决策依据：产品负责人确认队列（长按菜单 → 流式 → Provider 启停 → 设置页 → **联网搜索** → Share Extension → 语音）

## 1. 产品定位与非目标

- Agent 回答时可联网检索，回答附「来源」列表（可点开），对齐主流 AI 助手习惯；
- 检索到的网页内容是**网络主张，不是可信证据**：`sourceType` 仍为
  `modelOutput`，未核验披露完全不变；受信证据三专家降级为 advice-only
  的决策（2026-07-30）不因联网而回退；
- **非目标**：本机爬虫/网页抓取（ToS 与反爬风险、注入面大）、
  自建搜索索引、RAG 知识库（另行立项）。

## 2. 现状实证（2026-07-30）

- `ChatRequest`（`lib/model_runtime/model_runtime_models.dart`）没有 tools
  字段；群聊运行时（`lib/orchestration/provider_backed_agent_runtime.dart`）
  显式 `'tools': 'disabled'`。联网能力目前**诚实缺席**。
- ToAPIs 文档（`docs/大模型toapis对接.md`）中 `web_search` 工具**只出现在
  Seedance 2 视频生成**；聊天端点（Chat Completions / Responses /
  Anthropic Messages）未文档化任何搜索工具。经 ToAPIs 代理是否透传
  厂商托管搜索**未实证 → T0 探针**。
- 厂商原生托管搜索（检索所得，接入前须以官方文档核对参数）：
  OpenAI Responses `web_search` 工具、Anthropic Messages `web_search`
  server tool、Gemini `google_search` grounding。三者都在**服务端执行**
  搜索并随响应返回结构化引用（citations/grounding metadata）。

## 3. 核心架构决策

### 3.1 首选 A 层：厂商托管搜索（本期实现）

模型厂商在服务端执行搜索，客户端只声明工具、收结构化引用：

- **无客户端工具执行环**——不需要在 app 里造 agent loop，
  现有「一次请求 → 一个信封」的管线形状不变；
- **零新增密钥**——沿用已配置 Provider 的 Key 与计费围栏
  （`SqliteModelCallJournal` 语义不变：仍是一次模型调用）；
- 端点白名单不变（仍只访问已批准的 Provider 域名）。

### 3.2 留座 B 层：客户端工具环 + 独立搜索 API

Tavily / Brave / Serper 等需要新 Key、新端点白名单评审、以及真正的
工具执行环（多轮往返、上限控制）。仅当 A 层在用户的 Provider 组合上
全部不可用时再排期，由产品负责人决定选哪家、供 Key。

### 3.3 引用防伪造：只认传输层结构化引用

模型正文里「自称」的引用一律不信。`evidenceReferences` 只从
**transport 解析的结构化 citations 字段**（Responses annotations /
Anthropic citations / Gemini grounding metadata）注入，与信封投影的
结构性安全同一原则：不做正文词法扫描，不给模型伪造来源的通道。
transport 未返回结构化引用时，UI 就不显示来源——宁缺毋假。

## 4. 请求与响应形状

- `ChatRequest` 增加可选 `webSearch`（bool 或 per-call 上限配置），
  默认关闭；各 transport 按协议翻译：
  - OpenAI Responses：`tools: [{"type": "web_search"}]`
  - Anthropic：`tools: [{"type": "web_search_20250305", "name": "web_search", "max_uses": N}]`
  - Gemini：`tools: [{"google_search": {}}]`
  - OpenAI Chat Completions（含 ToAPIs 兼容层）：无托管搜索标准形状，
    按 T0 探针结论决定（不透传则该 Provider 如实标注不支持）；
- `ChatResponse` 增加 `List<WebCitation> citations`（url/title/摘录，
  可为空）；SSE 与 unary 两套 normalizer 都要解析；
- 搜索次数上限：请求侧声明（如 max_uses=3），防失控计费；
  `usage` 中的搜索用量如实入账单事实（不估算）。

## 5. 数据模型与 UI

- `ChatMessageProjection.evidenceReferences`（已存在）承载引用 URL 列表；
  编码格式向后兼容（老消息无引用照常解码）；
- 专家气泡底部「来源 N」折叠条目：点开列表，条目显示域名+标题；
  点击暂用系统分享/复制（app 内不内嵌浏览器，避免扩大攻击面）；
- 未核验角标照旧；引用存在≠已核验，UI 文案不得暗示核验。

## 6. 开关与诚实降级

- 专家详情页与设置页各有「联网搜索」开关（默认关，产品负责人可改）；
- 当前默认模型的 Provider/协议不支持托管搜索时，开关如实置灰并说明
  （「当前模型不支持联网搜索」），**不静默降级**为无搜索回答冒充；
- 开着开关但该轮实际未搜索（usage=0）时不显示来源条——如实。

## 7. 安全与计费边界

- 端点白名单零新增（A 层）；B 层若立项，新端点独立小提交评审；
- 搜索由厂商服务端执行，用户查询文本会到达厂商——与聊天正文同级
  的既有事实，无新披露面；
- 引用 URL 展示前做 scheme 白名单（http/https）；不自动预抓取内容；
- 上游错误正文照旧不落 UI/日志/SQLite；
- 每轮请求计费围栏不变；搜索用量随 usage 如实记录。

## 8. 验收标准

1. 支持托管搜索的模型上：问时效性问题 → 回答携带可点开的来源列表；
2. 不支持的模型上：开关置灰 + 如实说明，回答管线不变；
3. 引用只来自结构化 citations；构造「正文伪造引用」的对抗样例不产生来源条；
4. 未核验披露在带来源的回答上依然完整；
5. 老历史消息（无引用字段）解码渲染不回归；
6. 全量 `flutter test` 绿、`flutter analyze` 干净、真机验收。
