# IOS-IM 工程开发规范

日期：2026-07-28

## 仓库结构

```text
apps/
  mobile/
packages/
  design_system/
  domain/
  provider_contracts/
services/
  gateway/          # 可选自托管
docs/
```

移动应用必须可以在 `services/gateway` 未启动时完成本地浏览、配置和所有可直连模型对话。

## Flutter 模块边界

- `foundation/database`：Drift schema、migration、事务。
- `foundation/files`：原子文件写入、缩略图、预览和缓存。
- `foundation/assets`：Asset 元数据、内容哈希、引用计数、生成成果和授权解析。
- `foundation/security`：Vault，不暴露平台 API 给业务层。
- `features/providers`：Provider 适配器与 Router。
- `features/conversations`：消息状态机。
- `features/chat_history`：按会话检索图片视频、文件、链接和 AI 成果。
- `features/group_chat`：成员队列、轮次、取消和总结。
- `features/agent_collaboration`：Agent Message Bus、任务委派、协作日志、预算、循环检测和幂等派发。
- `features/memory`：共享/私有记忆和检索。
- `features/local_data`：导入导出和清除。

Feature 之间通过领域接口交互，Widget 不直接执行 SQL、读取密钥或调用厂商 SDK。

## 核心接口

```dart
abstract interface class SecretVault {
  Future<void> write(String ref, String secret);
  Future<String?> read(String ref);
  Future<void> delete(String ref);
}

abstract interface class ModelProvider {
  ProviderCapabilities get capabilities;
  Future<ConnectionResult> testConnection();
  Future<List<ModelDescriptor>> listModels({ModelKind? kind});
  Stream<ModelEvent> generateText(ModelRequest request);
  Future<GenerationTask> generateMedia(MediaRequest request);
  Future<GenerationTask> getMediaTask(String remoteTaskId);
  Future<ProviderBalance?> getBalance();
}

abstract interface class MessageRepository {
  Stream<List<Message>> watchConversation(String conversationId);
  Future<void> append(Message message);
  Future<void> updateStatus(String messageId, MessageStatus status);
}

abstract interface class AssetRepository {
  Stream<List<Asset>> watchConversationAssets(
    String conversationId,
    AssetFilter filter,
  );
  Future<Asset> importFile(ImportAssetCommand command);
  Future<Asset> finalizeGeneratedAsset(GeneratedAssetCommand command);
  Future<void> addReference(AssetReference reference);
  Future<DeleteAssetResult> removeReference(AssetReference reference);
}
```

## 状态和并发

- 每次生成使用稳定 `runId` 和 `messageId`。
- 取消是显式状态，不用丢弃 Stream 代替。
- UI reducer 必须忽略已完成或已取消 Run 的迟到事件。
- 工具副作用带幂等键。
- 群聊设置轮数、时间、并发和模型用量上限。
- Agent 间通讯必须持久化结构化 AgentMessage；自然语言不能直接触发另一个 Agent。
- 协作分支只能引用当前 Run 授权的 Message、Claim、Evidence 和 Asset ID。

## 配置与密钥

- Provider 的 URL、模型 ID、能力和 Key 引用可进 SQLite。
- 完整 API Key 和 Gateway 令牌只能进 Keychain / Keystore。
- ToAPIs 预置配置的默认 Base URL 为 `https://toapis.com/v1`；业务层不得拼接任何厂商路径。
- Provider Registry 支持多个 Adapter 和同类型多个实例；模型引用必须保存 `providerId + modelId`。
- 模型目录以 `GET /models?type=all` 的当前 Key 响应为准，缓存必须记录刷新时间。
- `.env.example` 只放字段名与假值。
- 日志、Telemetry、Crash report、剪贴板和导出包默认脱敏。
- 连接测试不得发送用户对话正文。

## 数据库迁移

- 每个 schema 变更提供 up migration 和升级测试。
- 禁止在 Widget 内查询数据库。
- 批量消息和记忆写入使用事务。
- 删除附件前检查引用计数。
- 数据库只保存沙盒相对路径，不保存设备绝对路径。
- 模型生成结果先写临时文件，校验完成后原子移动到资产目录。
- GenerationArtifact 必须保存来源消息、Agent、Provider、模型和输入资产 ID。
- 迁移失败保留原文件并提供可恢复错误。

## Gateway

Gateway 使用小型模块化服务即可：

- 健康检查与版本协商。
- 短期凭证和请求签名。
- WebSocket / SSE 适配。
- 默认无正文日志、无对话数据库。

不得添加 Halo 官方账户、平台 Token 账本或强制云同步。

## 测试分层

| 层级 | 内容 |
|---|---|
| Dart 单元 | Router、Reducer、Vault 引用、导出过滤 |
| Widget | 四 Tab、Provider 设置、群聊、聊天记录分类、本地数据 |
| Repository | migration、事务、附件去重、引用删除、生成成果落盘 |
| Provider 契约 | ToAPIs 模型目录、SSE、异步媒体、超时、取消、限流与错误映射 |
| Gateway 集成 | 健康检查、签名、版本不兼容 |
| 真机 | 权限、后台、弱网、磁盘、Keychain |

## 提交门槛

```bash
dart format --set-exit-if-changed .
flutter analyze
flutter test
```

Gateway 另运行格式化、类型检查、单元测试和容器健康检查。CI 必须包含 secret scan、依赖漏洞和许可证扫描。

## 发布门槛

- 全部测试通过且关键页面完成视觉 QA。
- 数据升级和导入导出在上一版本真实数据上验证。
- App 包与仓库没有服务商密钥。
- 无账号首次启动路径在离线环境可进入。
- README、隐私说明、许可证和 Gateway 部署文档同步更新。
