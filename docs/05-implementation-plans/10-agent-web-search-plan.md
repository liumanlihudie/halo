# Agent 联网搜索实现计划

日期：2026-07-30
依据：`docs/04-feature-specs/08-agent-web-search-design.md`
前置约束：**流式输出改造（另一工作流在途，涉及
`production_sse_transport.dart` / `single_chat_controller.dart` /
`production_single_chat_port.dart`）落地之前，本计划不动代码**——
T1/T2 与其修改面直接重叠。

## 任务拆分（每项一个提交，附验证门槛）

### T0 托管搜索可用性探针（产品负责人 Key 实测；凭证不入库不入文档）

- ToAPIs Responses 端点是否透传 `tools:[{"type":"web_search"}]`
  并返回 annotations；
- 用户已配置的各 Provider（ToAPIs / DeepSeek / …）逐个记录：
  支持 / 不支持 / 形状差异；DeepSeek 官方 API 预期不支持——记录即可；
- 结论回写设计文档 §2；探针脚本不提交。

### T1 请求座位 + 各协议翻译

- Modify: `model_runtime_models.dart`（`ChatRequest.webSearch` 可选配置：
  开关 + max_uses 上限；默认 null=关闭）
- Modify: 四套 transport（openai_native / anthropic / gemini /
  openai_compatible）按设计 §4 翻译 tools 参数；不支持的协议收到
  webSearch 时抛 `invalidConfiguration`（fail-closed，不静默丢弃）
- Test: 各 transport 的请求体形状合同测试（开/关/上限）

### T2 结构化引用解析

- Modify: `ChatResponse` 增加 `citations`；unary 与 SSE normalizer
  解析各协议 citations/annotations/grounding metadata；
  畸形引用条目丢弃该条不丢整包；scheme 非 http/https 丢弃
- Test: 各协议实录响应形状（T0 采集）+ 对抗样例
  （正文伪造引用不产生 citations；畸形 URL 被滤）

### T3 信封与持久化接线

- Modify: 单聊/群聊运行时把 transport citations 结构性注入
  `evidenceReferences`（不经过模型 JSON 信封，防伪造）；
  `'tools': 'disabled'` metadata 按开关如实更新
- Test: 运行时测试（citations 注入链、无 citations 无来源、
  编码轮转向后兼容老消息）

### T4 来源 UI

- Modify: `single_chat_page.dart`（气泡底「来源 N」折叠列表：域名+标题，
  点击走系统分享/复制；未核验角标不变）
- Test: widget 测试（有/无来源渲染、未核验披露共存、伪造引用对抗样例）

### T5 开关与诚实降级

- Modify: 专家详情页 + 设置页「联网搜索」开关；当前默认模型不支持时
  置灰 + 「当前模型不支持联网搜索」；开关状态持久化（SQLite 非敏感配置）
- Test: widget 测试（支持/不支持两态、置灰文案与实际能力一致）

### T6 真机验收

- 时效性问题实测（来源可点开）、不支持模型的置灰实测、
  老历史回归；iPhone 13 Pro + 模拟器双端

## 顺序与并行

T0 最先且独立（不写代码）；T1→T2→T3 串行（同一改动面）；
T4/T5 依赖 T3 的类型后可并行；T6 收尾。
全程在流式改造落地之后开工。

## 统一门槛（每个提交）

全量 `flutter test --concurrency=1` 绿；`flutter analyze` 干净；
`dart format` 无 diff；上游错误正文与凭证不进 UI/日志/SQLite。
