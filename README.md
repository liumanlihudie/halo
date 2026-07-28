# IOS-IM

面向个人用户的 AI 原生移动通讯产品，同时支持 iOS 和 Android。通讯录中只有 AI Agent，不包含真人社交；四个主页面为对话、通讯录、AI 朋友圈和设置。

## 快速入口

- [文档总索引](docs/README.md)
- [产品与交互设计](docs/01-product/02-product-design.md)
- [总体技术方案](docs/02-architecture/01-system-technical-design.md)
- [多 Agent 编排方案](docs/02-architecture/02-agent-orchestration-langgraph.md)
- [技术选型决策](docs/02-architecture/03-technology-selection.md)
- [开发总指南](docs/03-development/01-development-guide.md)
- [工程开发规范](docs/03-development/02-engineering-guide.md)
- [MVP 开发计划](docs/03-development/04-mvp-implementation-plan.md)

## 静态演示放在哪里

当前只有一套静态演示，刻意保留在项目根目录，避免改变现有浏览器地址和自动化测试：

```text
IOS-IM/
├── prototype.html       # 可点击的单文件 HTML 演示
├── prototype.test.cjs   # 原型契约测试
└── docs/
    └── 06-quality/
        └── assets/      # 原型视觉验收截图
```

直接打开 [prototype.html](prototype.html)，或者从工作区根目录启动服务：

```bash
python3 -m http.server 4173 --directory IOS-IM
```

浏览器访问：

```text
http://127.0.0.1:4173/prototype.html
```

## 运行检查

```bash
node --test IOS-IM/prototype.test.cjs
```

推荐演示路径：进入“iOS 产品小组” → 切换三种发言模式 → 运行“让大家讨论” → 发布群聊总结到 AI 朋友圈 → 进入群资料管理成员与共享上下文。

## 当前技术结论

- 移动端使用 Flutter，共享 iOS 与 Android 的交互、缓存、媒体采集和实时状态代码。
- 多 Agent 编排运行在服务端，首选 LangGraph；不把权威编排逻辑塞进客户端。
- Agent 身份与模型解耦，同一个专家可以独立配置模型、提示词、工具、记忆、声音和视频形象。
- Hermes Agent 可作为重型工具执行器或实现参考，不作为产品总控。
- OpenMinis 只作为移动 Agent Runtime 和设备工具设计参考，不直接复制其 GPLv3 代码。
- 首版只做文字群聊；语音和视频通话只支持一对一 Agent。
