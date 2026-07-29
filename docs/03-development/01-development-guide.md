# IOS-IM 开发总指南

日期：2026-07-28

## 产品边界

- 个人用户，通讯录只有 AI Agent。
- 无账户、无登录、无平台计费。
- 数据本地优先，用户可以配置多个模型 Provider 与自己的 Key。
- 四个主页面：对话、通讯录、AI 朋友圈、设置。
- 群聊首版仅文字；一对一支持文字、附件、语音和视频。

## 当前原型

根目录 `prototype.html` 是可点击的单文件演示，覆盖：

- 12 种富消息会话与三类多 Agent 群聊。
- 50 位 AI 市场专家。
- AI 朋友圈成果与来源回溯。
- Provider 配置、测试、保存与移除。
- 本地数据导入导出、缓存清理和危险操作确认。
- 可选自托管 Gateway。

运行：

```bash
python3 -m http.server 4173 --directory .
```

测试：

```bash
node --test prototype.test.cjs
```

## 正式工程阶段

### A：Flutter 壳与本地数据

- 四 Tab、Design System、Riverpod、go_router。
- Drift / SQLite、附件目录、schema migration。
- Keychain / Keystore Vault。

### B：多 Provider 与单聊

- `ProviderRegistry` 与 `ModelProvider` 协议。
- ToAPIs、OpenAI-compatible、DeepSeek、OpenAI、Anthropic、Gemini Adapter。
- 模型发现、能力归一化、SSE、用量和统一错误。
- 流式消息、停止、重试、附件和草稿。

### C：Agent、群聊与记忆

- Agent 模板、通讯录和内置市场。
- `auto`、`mentioned`、`all` 群聊状态机。
- 共享事实与私有关系记忆。

### D：朋友圈与迁移

- 会话成果生成、来源追踪和可见性。
- 本地数据导出、导入、冲突处理和密钥过滤。

### E：Gateway、语音与视频

- Docker 自托管 Gateway。
- 豆包端到端双工语音。
- Webhook、签名和可靠长时间后台任务扩展。

## 原型与正式产品差异

| 能力 | 原型 | 正式 App |
|---|---|---|
| 持久化 | 刷新重置 | SQLite + App 沙盒 |
| API Key | 内存 mock | Keychain / Keystore |
| 模型连接 | 交互反馈 | Provider API / 本地模型 |
| 群聊 | 定时 mock | 可取消的状态机 |
| 导入导出 | 提示反馈 | 版本化数据包 |
| Gateway | 表单 mock | 用户自托管服务 |

## 上线前门槛

- 任何日志、数据库、备份和崩溃报告不得包含完整 API Key。
- 导入、清除数据和移除密钥有确认与恢复边界。
- 弱网、后台、权限拒绝、磁盘不足和流式中断通过真机测试。
- iOS 隐私清单、Android Data Safety 和第三方许可证准确。
- 发布包不内置服务商密钥，不要求 Halo 账号。
