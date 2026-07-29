# Halo Gateway

Halo Gateway 是可选、自托管的后端边界，不是 Halo 的账户、消息、记忆、
附件或模型密钥中心。第一阶段只提供可执行合同和确定性校验，不连接任何真实
Provider，也不会运行 LangGraph。

客户端内的 Dart `OrchestrationKernel`、`DurableRunner`、SQLite
Checkpoint/Event Store 和 Agent Message Bus 仍是主执行路径。只有用户明确
授权的 `GraphSpec` 子图，后续才允许交给 Gateway/LangGraph。

## 当前接口

- `GET /healthz`：服务与协议版本协商。
- `POST /v1/providers/validate`：校验非敏感 Provider 元数据；只接受
  `secretRef`，拒绝 `apiKey` 等合同外字段，不持久化配置。
- `POST /v1/orchestration/validate`：校验显式 offload、GraphSpec 引用、
  状态 Schema、可执行专家白名单、模型分配和冻结预算；只验证，不启动任务。
- `POST /v1/verification/publishability`：基于 Claim、EvidenceRef 和独立
  VerifierResult 执行最小发布闸门。

API 默认使用 JSON camelCase，模型引用始终包含 `providerId + modelId`。

## 本地运行

```bash
cd /Users/cofe/IOS-IM/apps/backend
uv sync --extra dev
uv run uvicorn halo_gateway.app:app --app-dir src --reload
```

打开 `http://127.0.0.1:8000/docs` 查看 OpenAPI。

## 测试与静态检查

不创建虚拟环境时，可复用工作机已有依赖：

```bash
cd /Users/cofe/IOS-IM/apps/backend
PYTHONPATH=src python3 -m unittest discover -s tests -v
python3 -m compileall -q src tests
uvx ruff check src tests
uvx ruff format --check src tests
```

## 安全边界

- 请求 Schema 使用 `extra="forbid"`；未知字段直接返回 422。
- 完整 API Key、Gateway Token、Prompt、消息正文和附件正文不得进入日志。
- `ProviderConfig` 仅传递 Vault 引用；Gateway 不读取移动端 Keychain。
- 编排校验仅允许给 `executableAgentIds` 内的专家分配模型。
- 无证据或没有独立核验的事实不能通过发布闸门。
- 当前实现没有数据库，也没有任何真实外部网络调用。

## 下一阶段

1. 与 Flutter 共用 JSON Schema 和契约向量，验证 Dart/Python 往返一致。
2. 增加 Gateway capability handshake、OffloadManifest 和幂等 intent。
3. 增加 SSE/WebSocket 远端帧，但只返回 `originSeq/remoteCursor`。
4. 在合同稳定后接入可选 LangGraph Runner；本地 Event Store 继续分配权威
   Run 序号。
5. 增加短期凭证、工具 Grant、Artifact 哈希和断线恢复测试。
