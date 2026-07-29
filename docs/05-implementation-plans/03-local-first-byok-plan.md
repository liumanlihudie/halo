# Halo 本地优先与 BYOK 实施计划

## 目标

把应用基线改为无账号、本地优先、BYOK，并提供可选的自托管 Gateway。

## Task 1：移除平台账户与计费

- 删除登录、验证码、忘记/修改密码、切换账号、退出登录页面。
- 删除账户状态、平台 Token 余额、套餐、订单和支付状态。
- 更新路由与测试，确保源码中不存在旧页面 ID 和动作。

## Task 2：多 Provider 配置

- 定义统一 `ProviderRegistry`、`ModelProvider` 协议和 Provider 模板。
- 实现 ToAPIs、DeepSeek、OpenAI、Anthropic、Gemini 和自定义 OpenAI-compatible 详情。
- 支持连接测试、模型刷新、优先级、启停、保存与移除。
- iOS 使用 Keychain，Android 使用 Keystore。
- SQLite 只保存非敏感元数据和 Keychain 引用。
- 每个 Provider 独立获取或手工配置模型目录，分别选择默认文字、图片和视频模型。
- 模型引用保存 `providerId + modelId`，支持单个 Agent 覆盖。
- 为各协议的流式事件、工具调用、余额查询和异步图片/视频任务编写契约测试。

## Task 3：本地数据层

- 建立 SQLite schema 与迁移系统。
- 附件写入 App 沙盒，数据库只保存路径、哈希和元数据。
- 提供导出、导入、缓存清理和清除本机数据。
- 导出测试必须验证 Keychain 内容和完整 API Key 不在数据包中。

## Task 4：自托管 Gateway

- 提供独立开源服务和 Docker Compose。
- 实现健康检查、版本协商、短期凭证和签名代理。
- App 支持 URL、可选令牌、证书错误和离线状态。
- Gateway 不保存对话正文；日志默认脱敏。

## Task 5：模型路由与降级

- 单聊、群聊和任务均通过本地 Router 选择 Provider。
- 未配置指定模型时展示可操作错误并允许改用已配置模型。
- Provider 超时、限流和断网使用指数退避与幂等重试。
- 端到端语音和视频能力缺少 Gateway 时明确提示部署或关闭。

## Task 6：验证

- 单元测试：Provider 状态、密钥引用、导入导出过滤、路由降级。
- 集成测试：真实 Provider 沙盒、Gateway 健康检查、流式中断恢复。
- 安全测试：日志脱敏、备份泄漏、剪贴板生命周期、Keychain 可访问级别。
- UI 测试：设置 → Provider → 测试 → 保存；本地数据 → 导出；Gateway → 测试。

## 当前原型状态

`prototype.html` 已完成页面和交互 mock；`prototype.test.cjs` 对无账号、BYOK、本地数据和 Gateway 契约进行静态回归。
