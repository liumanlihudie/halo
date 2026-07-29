# IOS-IM MVP Implementation Plan

**Goal:** 交付无账号、本地优先、BYOK 的 Flutter iOS / Android 开源 MVP。

**Architecture:** Flutter 客户端拥有本地数据、Provider Registry、Model Router 和群聊状态机；ToAPIs、厂商官方 API、自定义兼容服务和本地模型可并存，豆包实时语音及需要服务端回调的能力可连接用户自托管 Gateway。

## 全局约束

- 不实现真人社交、企业组织或官方用户账户。
- 不实现平台 Token、充值、支付或订阅。
- API Key 只进入 Keychain / Keystore。
- 对话、Agent、记忆和附件默认在本机。
- 四个主 Tab 为对话、专家团、圈层和设置。
- 群聊首版仅文字；通话只支持一对一 Agent。

## Task 1：Flutter 工程与设计系统

- [ ] 建立 Feature-first 工程、Riverpod 和 go_router。
- [ ] 实现字体、颜色、圆角、间距、图标和安全区 Token。
- [ ] 完成四 Tab、设备尺寸和无横向滚动回归测试。

## Task 2：本地数据库与文件资产

- [ ] 定义 Agent、Conversation、Message、Run、Memory、CirclePost、CirclePublishingPolicy、Asset、MessageAssetRef、GenerationArtifact schema。
- [ ] 建立 Drift migration 与 Repository。
- [ ] 实现附件 SHA-256 去重、引用计数、原子落盘、缩略图、视频首帧和缓存清理。
- [ ] 数据库只保存 App 沙盒相对路径；覆盖 App 重启和迁移后的路径解析测试。
- [ ] 覆盖升级、崩溃恢复和空间不足测试。

## Task 3：Vault 与多 Provider

- [ ] 定义 `SecretVault`、`ProviderRegistry`、`ModelProvider`、`ModelRef` 和统一事件/错误接口。
- [ ] iOS 接入 Keychain，Android 接入 Keystore。
- [ ] 实现 ToAPIs 设置详情、Key 测试、保存、移除和掩码展示。
- [ ] 实现 `GET /models?type=all`，按 endpoint type 归一化并缓存模型目录。
- [ ] 实现通用 OpenAI-compatible Adapter，支持多个实例与能力覆盖。
- [ ] 实现 DeepSeek、OpenAI、Anthropic、Gemini 官方 Adapter。
- [ ] 实现各协议的流式事件、取消、tool call、reasoning、usage 与统一错误映射。
- [ ] 实现 `GET /balance`，只用于设置页额度展示，不增加平台充值。
- [ ] 实现图片/视频异步任务提交、恢复查询、`Retry-After` 和有界退避。
- [ ] 把远端媒体结果下载到 `AssetRepository` 并关联 `GenerationArtifact`。
- [ ] 模型引用统一保存 `providerId + modelId`，支持全局、会话和 Agent 三级覆盖。
- [ ] 验证日志、数据库和备份中不存在完整 API Key。

## Task 4：单聊

- [ ] 实现会话列表和富消息组件。
- [ ] 实现流式事件、停止、重试、失败恢复和草稿。
- [ ] 图片、文件、拍照、录音统一进入附件流水线。
- [ ] 从聊天资料进入“查找聊天记录”，支持全部、图片与视频、文件、链接和 AI 成果。
- [ ] 实现统一预览、定位原消息、转发、导出和删除当前引用。
- [ ] 一对一语音和视频入口放在输入框“＋”菜单。

## Task 5：文字群聊

- [ ] 实现 `auto`、`mentioned`、`all` 三种模式。
- [ ] 实现成员队列、补充/反驳轮次、停止和总结。
- [ ] 定义 AgentMessage 与 Agent Message Bus，支持提问、委派、交付、批评、核验请求和任务移交。
- [ ] 实现群内公开消息与“专家协作过程”审计视图。
- [ ] 实现接收方权限、私有记忆隔离、通讯预算、循环检测、幂等派发和分支停止。
- [ ] AgentMessage 只传递授权的 Message、Claim、Evidence 和 Asset ID；工具副作用继续经过 Tool Permission Broker。
- [ ] 实现 `creative`、`grounded`、`high_stakes` 回答模式与风险分类。
- [ ] 实现 Claim、EvidenceRef、Claim Ledger 和来源定位。
- [ ] 实现独立 Verifier、冲突修订和受约束总结器。
- [ ] 实现 Citation/Publish Gate，阻止无证据事实进入长期记忆和圈层。
- [ ] 中高风险 Claim 优先使用不同 Provider 或模型家族核验，不采用多数投票。
- [ ] 群资料管理成员、共享上下文和默认规则。
- [ ] 群资料提供“查找聊天记录”，复用单聊分类、预览和资产引用组件。
- [ ] 覆盖切换会话、后台恢复和部分 Provider 失败。
- [ ] 覆盖 A→B→A 循环、接收方失败、超预算、越权文件引用和恢复后重复派发。
- [ ] 覆盖伪造引用、来源冲突、无答案、过期事实、Prompt 注入和多个 Agent 一致但错误。

## Task 6：专家团、AI 市场与圈层

- [ ] 专家团只保存 AI Agent，并按工作、资讯和生活能力组织。
- [ ] 内置 50 个开源 Agent 模板，可添加和编辑。
- [ ] 圈层不做分类或推荐，严格按发布时间倒序展示。
- [ ] 圈层覆盖专家主动分享、对话总结、任务、定时任务、监控和失败状态。
- [ ] 发布默认开启，可全局和按 Agent 关闭；关闭不停止专家工作、不删除历史动态、不补发禁发期间内容。

## Task 7：本地导入导出

- [ ] 生成版本化 manifest、结构化数据和附件清单。
- [ ] 导出时强制排除 Vault 内容并扫描密钥格式。
- [ ] 导入前校验版本、哈希、空间和冲突。
- [ ] 清除缓存与清除本机数据分开并二次确认。

## Task 8：自托管 Gateway

- [ ] 建立独立服务、Dockerfile 与 Compose。
- [ ] 实现健康检查、版本协商、签名和短期凭证。
- [ ] 接入豆包端到端双工语音及需要服务端签名或回调的扩展能力。
- [ ] 生图、生视频等临时 URL 返回有效期；App 完成后立即下载并写入 GenerationArtifact。
- [ ] 默认关闭正文日志，不存储对话和附件。

## Task 9：质量与发布

- [ ] 单元、Widget、集成和 Golden 测试。
- [ ] 真机验证弱网、后台、权限拒绝、磁盘不足和长会话。
- [ ] 完成许可证、隐私清单、密钥扫描和依赖漏洞检查。
- [ ] 生成 TestFlight / Android 内测包和开源发布说明。

## 完成标准

用户安装后无需登录，配置自己的模型 Key 即可完成单聊和文字群聊；重启后数据仍在；可以无密钥泄漏地导出迁移；可选 Gateway 不影响基础功能。
