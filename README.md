# IOS-IM

面向个人用户的 AI 原生移动通讯产品，当前以 iOS 为首发目标，后续复用 Flutter 工程支持 Android。产品不包含真人社交；四个主页面为对话、专家团、圈层和设置。

项目采用无账号、本地优先、BYOK 的开源模式：安装后直接使用，对话和记忆默认保存在本机，用户可以配置 ToAPIs、模型厂商官方 API、自定义 OpenAI-compatible 服务或本地模型，密钥进入系统安全存储；需要签名、Webhook 或可靠后台执行的能力可连接用户自己的 Gateway。

## 快速入口

- [文档总索引](docs/README.md)
- [产品与交互设计](docs/01-product/02-product-design.md)
- [总体技术方案](docs/02-architecture/01-system-technical-design.md)
- [多 Agent 编排方案](docs/02-architecture/02-agent-orchestration-langgraph.md)
- [技术选型决策](docs/02-architecture/03-technology-selection.md)
- [开源本地优先架构](docs/02-architecture/04-local-first-open-source-architecture.md)
- [ToAPIs Provider 接入](docs/02-architecture/05-toapis-provider-integration.md)
- [多模型 Provider 架构](docs/02-architecture/06-multi-provider-model-access.md)
- [Agent 事实可信与证据协议](docs/02-architecture/07-agent-truthfulness-evidence-protocol.md)
- [可执行 Agent Profile 与 Prompt 系统](docs/02-architecture/08-executable-agent-profile-prompt-system.md)
- [开发总指南](docs/03-development/01-development-guide.md)
- [工程开发规范](docs/03-development/02-engineering-guide.md)
- [MVP 开发计划](docs/03-development/04-mvp-implementation-plan.md)

## 工程入口

静态原型保留在根目录；可运行的 iOS-first Flutter 工程位于 `apps/mobile`：

```text
IOS-IM/
├── apps/mobile/         # Flutter 工程与 iOS Runner
├── prototype.html       # 可点击的单文件 HTML 演示
├── prototype.test.cjs   # 原型契约测试
└── docs/
    └── 06-quality/
        └── assets/      # 原型视觉验收截图
```

直接打开 [prototype.html](prototype.html)，或者从工作区根目录启动服务：

```bash
python3 -m http.server 4173 --directory .
```

浏览器访问：

```text
http://127.0.0.1:4173/prototype.html
```

## 运行检查

```bash
node --test prototype.test.cjs
cd apps/mobile
flutter analyze
flutter test
flutter build ios --simulator
```

推荐演示路径：进入“iOS 产品小组” → 切换三种发言模式 → 运行“让大家讨论” → 发布群聊总结到圈层 → 进入群资料管理成员与共享上下文。

## 当前技术结论

- 移动端使用 Flutter，共享 iOS 与 Android 的交互、缓存、媒体采集和实时状态代码。
- 无登录、无平台 Token、无充值支付；Halo 官方不托管用户对话或密钥。
- 对话、Agent、记忆使用 SQLite，附件使用 App 沙盒，API Key 使用 Keychain / Keystore。
- 本地 Router 支持 ToAPIs、DeepSeek、OpenAI、Anthropic、Gemini、自定义 OpenAI-compatible 和本地模型；需要签名、Webhook 或可靠后台执行的能力使用用户自托管 Gateway。
- 多 Agent 编排首版运行在客户端状态机；LangGraph 可作为后续可选自托管 Runner。
- Agent 身份与模型解耦，同一个专家可以独立配置模型、提示词、工具、记忆、声音和视频形象。
- Hermes Agent 可作为重型工具执行器或实现参考，不作为产品总控。
- OpenMinis 只作为移动 Agent Runtime 和设备工具设计参考，不直接复制其 GPLv3 代码。
- 首版只做文字群聊；语音和视频通话只支持一对一 Agent。
