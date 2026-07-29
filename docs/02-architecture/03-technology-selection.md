# IOS-IM 技术选型决策

版本：2.0
日期：2026-07-28

## 决策摘要

```text
Flutter iOS / Android
  + Riverpod / go_router
  + Drift / SQLite
  + Keychain / Keystore
  + 本地 Model Router 与群聊状态机
  + Provider 适配器
  + 用户自托管 Gateway（可选）
```

## Flutter

聊天、群聊、专家团、圈层、市场和设置需要双端一致的自定义 UI。Flutter 能共享 Widget、路由、缓存、网络和自动化测试，同时通过 Swift/Kotlin 插件接入豆包语音、Vidu、相机、文件和通知。

## 本地数据

- Drift / SQLite：强类型查询、迁移和事务。
- App 沙盒：附件和媒体。
- Keychain / Keystore：API Key 与 Gateway 令牌。
- 不使用 PostgreSQL、Redis 或对象存储作为 MVP 的必需依赖。

## 模型连接

业务层定义自有 `ModelProvider` 和 `ProviderRegistry`。MVP 首批适配：

1. ToAPIs 聚合 Provider。
2. 通用 OpenAI-compatible Provider。
3. DeepSeek 官方 API。
4. OpenAI 官方 API。
5. Anthropic Messages API。
6. Google Gemini API。
7. 豆包端到端语音。

OpenRouter、硅基流动、Ollama、LM Studio、vLLM 和用户自建中转站优先通过通用兼容层接入。厂商特有能力无法被兼容层准确表达时再增加原生 Adapter。详细合同见 [多模型 Provider 接入架构](06-multi-provider-model-access.md)。

## 群聊编排

MVP 使用 Dart 状态机完成选择、队列、反驳、总结、停止和恢复。这样离线数据、取消信号与 UI 状态都在同一可信边界。

LangGraph 保留为未来可选 Runner，不再要求官方服务端部署。Hermes 可作为重型工具执行器接入。OpenMinis 只参考移动端工具和权限设计；若复用代码必须遵守其许可证。

## 开源与许可证

- 项目目标是公开源码和可自托管，不依赖商业计费。
- 首选 Apache-2.0 或 MIT；正式发布前完成依赖许可证扫描。
- Provider SDK 必须允许客户端分发；不允许把服务商长期主密钥写入仓库或 App 包。

## 明确不选

- 官方账户与认证后台。
- 平台 Token、充值、订阅和支付。
- 强制云端消息、记忆或附件存储。
- MVP 阶段的微服务、Kubernetes 和集中式 Agent 市场后台。
