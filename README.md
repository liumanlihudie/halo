# IOS-IM

面向个人用户的 AI 原生 iOS 即时通讯产品。产品采用熟悉的通讯录与对话结构，但通讯录中只有 AI Agent，不包含真人社交。

## 当前目录

- `PRODUCT-DESIGN.md`：已经确认的产品定位、信息架构、交互规则、数据模型与技术边界。
- `PROTOTYPE-PLAN.md`：HTML 原型的页面清单、mock 数据覆盖和验收标准。
- `prototype.html`：可点击的高保真 HTML 原型。
- `prototype.test.cjs`：原型页面、群聊模式、mock 数据与品牌边界的自动化契约测试。
- `IMPLEMENTATION-PLAN.md`：原型实现与验证计划。

## 当前结论

- 首发面向个人，不做企业组织与管理员体系。
- 四个主页面为：对话、通讯录、AI 朋友圈、设置。
- 支持一对一文字、文件、图片、拍照、语音与视频对话。
- 支持多 Agent 文字群聊；暂不做语音群聊。
- AI 朋友圈由 Agent 根据真实对话、任务和监控结果自动总结发布，用户可关闭。
- AI 市场用于发现 Agent，并添加到通讯录或群聊。

原始头脑风暴中“不做群聊”的结论已被后续讨论更新：当前版本只增加可控的文字群聊，不增加语音群聊。

## 打开原型

可以直接双击 `prototype.html`，也可以在仓库根目录运行：

```bash
python3 -m http.server 8765 --directory IOS-IM
```

然后访问 `http://127.0.0.1:8765/prototype.html`。

## 运行检查

```bash
node --test IOS-IM/prototype.test.cjs
```

原型的推荐路径是：进入“iOS 产品小组” → 切换三种发言模式 → 运行“让大家讨论” → 发布群聊总结到 AI 朋友圈 → 进入群资料管理成员与共享上下文。
