# IOS-IM 全会话 Mock 数据扩充 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让对话频道中的 12 条会话全部可进入独立、内容丰富的对话，并覆盖主要消息格式、任务状态和异常情况。

**Architecture:** 保持 `prototype.html` 单文件结构，新增 `conversationMocks` 数据集与共享消息渲染器，动态更新现有 `#chat` 页面。三个群聊扩展 `groups` 数据并在 `openGroup(key)` 时渲染独立历史；列表项只保存会话 ID，不复制页面。

**Tech Stack:** HTML5、CSS、原生 JavaScript、Phosphor Icons、Node.js `node:test`

## Global Constraints

- 所有文件继续放在 `IOS-IM`。
- 对话列表包含 12 个唯一、可打开的会话。
- 群聊只支持文字，不显示语音或视频通话。
- 单 Agent 可显示语音和视频；任务和系统会话不显示通话。
- Mock 状态只保存在页面生命周期内。
- 用户输入必须经过 `escapeHtml`。
- 不接真实模型、文件、权限、语音、视频、日历或支付服务。
- 既有 AI 市场、设置、群聊模式和安全区行为必须保持。

---

### Task 1: 建立 12 条可映射会话的数据契约

**Files:**
- Modify: `IOS-IM/prototype.test.cjs`
- Modify: `IOS-IM/prototype.html`

**Interfaces:**
- Produces: `conversationMocks: Record<string, ConversationMock>`
- Produces: 列表项属性 `data-conversation-id="<id>"`
- Consumes: 现有 `groups`、`escapeHtml(value)`

- [ ] **Step 1: 写失败测试**

在 `prototype.test.cjs` 增加：

```js
test('every conversation list item maps to one of twelve rich mock conversations', () => {
  const html = readPrototype();
  const ids = [...html.matchAll(/data-conversation-id="([^"]+)"/g)].map(match => match[1]);
  assert.equal(new Set(ids).size, 9);
  expectAll(html, [
    "const conversationMocks={",
    "'general-assistant'",
    "'data-analyst-chat'",
    "'calendar-assistant'",
    "'translation-expert-chat'",
    "'contract-review-chat'",
    "'deep-research-task'",
    "'file-processing'",
    "'monitoring-chat'",
    "'system-assistant'"
  ], 'conversation dataset');
});
```

三个群聊继续使用 `data-open-group`，因此数据驱动普通/任务/系统会话为 9 条，总数与三个群聊合计 12 条。

- [ ] **Step 2: 运行测试确认失败**

Run: `node --test IOS-IM/prototype.test.cjs`

Expected: FAIL，提示 `conversationMocks` 或会话 ID 缺失。

- [ ] **Step 3: 实现数据和列表映射**

新增 9 条 `conversationMocks`。每条至少包含：

```js
{
  id,
  type,
  title,
  avatar,
  status,
  preview,
  time,
  unread,
  capabilities:{attachments,voiceCall,videoCall,taskActions},
  composerPlaceholder,
  quickActions,
  messages
}
```

把现有普通会话、研究任务、文件处理和数据分析条目改成 `data-conversation-id`，并补充日程、翻译、合同、监控和系统助手列表项。

- [ ] **Step 4: 运行测试确认通过**

Run: `node --test IOS-IM/prototype.test.cjs`

Expected: 新测试 PASS，既有测试无回归。

- [ ] **Step 5: 提交**

```bash
git add IOS-IM/prototype.html IOS-IM/prototype.test.cjs
git commit -m "feat: add twelve mapped conversation scenarios"
```

---

### Task 2: 实现共享消息渲染器和完整格式

**Files:**
- Modify: `IOS-IM/prototype.test.cjs`
- Modify: `IOS-IM/prototype.html`

**Interfaces:**
- Consumes: `conversationMocks`
- Produces: `renderMessage(message): string`
- Produces: `renderConversation(id): void`
- Produces: `openConversation(id): void`
- Produces: `currentConversationId: string`

- [ ] **Step 1: 写失败测试**

```js
test('conversation mocks cover rich message and failure formats', () => {
  const html = readPrototype();
  expectAll(html, [
    "type:'text'",
    "type:'quote'",
    "type:'image'",
    "type:'gallery'",
    "type:'file'",
    "type:'voice'",
    "type:'link'",
    "type:'table'",
    "type:'chart'",
    "type:'progress'",
    "type:'checklist'",
    "type:'calendar'",
    "type:'risk'",
    "type:'error'",
    "type:'system'"
  ], 'message types');
  expectAll(html, [
    'function renderMessage(message)',
    'function renderConversation(id)',
    'function openConversation(id)'
  ], 'conversation renderer');
});
```

- [ ] **Step 2: 运行测试确认失败**

Run: `node --test IOS-IM/prototype.test.cjs`

Expected: FAIL，提示消息类型与渲染函数缺失。

- [ ] **Step 3: 增加消息组件样式**

在现有聊天样式附近增加：

- `.quote-block`
- `.gallery-message`
- `.voice-message`
- `.link-card`
- `.metric-grid`
- `.data-table`
- `.mini-chart`
- `.checklist-card`
- `.calendar-card`
- `.risk-card`
- `.error-card`
- `.system-notice`
- `.quick-actions`

所有组件限制在手机内容宽度内并复用现有 Token。

- [ ] **Step 4: 实现受控渲染器**

`renderMessage(message)` 使用 `switch(message.type)` 只处理预定义消息类型。文本、标题、字段和值统一调用 `escapeHtml`；图片 URL 只读取内置 Mock 数据。

`renderConversation(id)` 更新：

- `#singleChatTitle`
- `#singleChatStatus`
- `#singleChatAvatar`
- `#singleChat`
- `#singleInput`
- `#singleCallActions`
- `#singleQuickActions`

任务和系统会话隐藏 `#singleCallActions`。

- [ ] **Step 5: 接入列表点击**

全局点击处理器识别：

```js
const conversationNode=event.target.closest('[data-conversation-id]');
if(conversationNode){
  openConversation(conversationNode.dataset.conversationId);
  return;
}
```

- [ ] **Step 6: 运行测试确认通过**

Run: `node --test IOS-IM/prototype.test.cjs`

Expected: 全部 PASS。

- [ ] **Step 7: 提交**

```bash
git add IOS-IM/prototype.html IOS-IM/prototype.test.cjs
git commit -m "feat: render rich conversation message formats"
```

---

### Task 3: 为三个群聊提供独立历史

**Files:**
- Modify: `IOS-IM/prototype.test.cjs`
- Modify: `IOS-IM/prototype.html`

**Interfaces:**
- Consumes: `groups`
- Produces: `renderGroupMessages(group): void`
- Updates: `openGroup(key)`

- [ ] **Step 1: 写失败测试**

```js
test('all three groups define independent members goals and histories', () => {
  const html = readPrototype();
  expectAll(html, [
    "product:{title:'iOS 产品小组'",
    "research:{title:'本周信息研判'",
    "content:{title:'内容发布团队'",
    'function renderGroupMessages(group)'
  ], 'group histories');
  expectAll(html, [
    '交叉核验',
    '来源可信度',
    '封面方向 B',
    '事实核验'
  ], 'distinct group content');
});
```

- [ ] **Step 2: 运行测试确认失败**

Run: `node --test IOS-IM/prototype.test.cjs`

Expected: FAIL，提示独立历史或渲染函数缺失。

- [ ] **Step 3: 扩展群聊数据**

每个 `groups[key]` 增加：

```js
{
  title,
  goal,
  members,
  host,
  messages
}
```

三组分别覆盖产品评审、信息研判和内容发布消息。

- [ ] **Step 4: 渲染当前群历史**

实现 `renderGroupMessages(group)`，复用 `renderMessage` 可共用的卡片格式，并保留 Agent 名称、模型、头像和引用关系。

`openGroup(key)` 调用渲染函数并更新群资料中的名称、目标、主持 Agent 和成员数量。

- [ ] **Step 5: 让模拟回复匹配当前群成员**

记录 `currentGroupKey`。`runGroupReply(mode)` 和 `startDiscussion()` 从当前群读取成员，而不是始终输出产品经理、技术架构师和交互设计师。

- [ ] **Step 6: 运行测试确认通过**

Run: `node --test IOS-IM/prototype.test.cjs`

Expected: 全部 PASS。

- [ ] **Step 7: 提交**

```bash
git add IOS-IM/prototype.html IOS-IM/prototype.test.cjs
git commit -m "feat: add distinct mock histories for every group"
```

---

### Task 4: 新消息、场景动作与列表同步

**Files:**
- Modify: `IOS-IM/prototype.test.cjs`
- Modify: `IOS-IM/prototype.html`

**Interfaces:**
- Consumes: `currentConversationId`, `conversationMocks`
- Produces: `sendSingleMessage(): void`
- Produces: `updateConversationPreview(id,text): void`
- Produces: `runConversationAction(action,id): void`

- [ ] **Step 1: 写失败测试**

```js
test('single conversation sends and scenario actions update visible state', () => {
  const html = readPrototype();
  expectAll(html, [
    'function sendSingleMessage()',
    'function updateConversationPreview(id,text)',
    'function runConversationAction(action,id)',
    'data-conversation-action="retry-upload"',
    'data-conversation-action="stop-task"',
    'data-conversation-action="grant-permission"',
    'data-conversation-action="view-usage"'
  ], 'conversation mutation');
});
```

- [ ] **Step 2: 运行测试确认失败**

Run: `node --test IOS-IM/prototype.test.cjs`

Expected: FAIL，提示状态更新函数或动作缺失。

- [ ] **Step 3: 实现发送与列表同步**

`sendSingleMessage()`：

1. 读取当前输入文字。
2. 空文字直接返回。
3. 用 `escapeHtml` 渲染用户消息。
4. 把结构化消息追加到当前 `messages`。
5. 清空输入框。
6. 更新列表预览和时间为“刚刚”。

- [ ] **Step 4: 实现场景动作**

`runConversationAction` 至少处理：

- `retry-upload`：失败 → 上传中 → 已完成。
- `stop-task`：进行中 → 已停止。
- `grant-permission`：展示授权说明弹层。
- `view-usage`：展示用量弹层。
- `confirm-calendar`：日程卡变为已确认。
- `export-result`：展示导出成功 Toast。

- [ ] **Step 5: 运行测试确认通过**

Run: `node --test IOS-IM/prototype.test.cjs`

Expected: 全部 PASS。

- [ ] **Step 6: 提交**

```bash
git add IOS-IM/prototype.html IOS-IM/prototype.test.cjs
git commit -m "feat: add mutable conversation scenario actions"
```

---

### Task 5: 浏览器 QA、文档和最终验证

**Files:**
- Modify: `IOS-IM/DEVELOPMENT-GUIDE.md`
- Modify: `IOS-IM/design-qa.md`
- Create: `IOS-IM/qa-rich-conversations.png`

**Interfaces:**
- Consumes: 完成后的 `prototype.html`
- Produces: 可复查的浏览器验收记录

- [ ] **Step 1: 更新开发文档**

在 `DEVELOPMENT-GUIDE.md` 中补充 12 条会话、消息格式矩阵和推荐演示路径。

- [ ] **Step 2: 运行自动测试**

Run:

```bash
node --test IOS-IM/prototype.test.cjs
node -e "const fs=require('fs'),vm=require('vm');const h=fs.readFileSync('IOS-IM/prototype.html','utf8');new vm.Script(h.match(/<script>([\s\S]*?)<\/script>/)[1])"
git diff --check -- IOS-IM
```

Expected: 零失败、零语法错误、零空白错误。

- [ ] **Step 3: 浏览器逐项点击**

在 `http://127.0.0.1:4173/prototype.html`：

1. 打开 12 条列表会话。
2. 验证每条标题和首屏内容不同。
3. 验证 Agent 会话通话按钮存在。
4. 验证任务和系统会话通话按钮隐藏。
5. 在普通 Agent 会话发送消息并确认列表摘要更新。
6. 触发文件重试、停止任务、日程确认、权限和用量操作。
7. 检查手机底部、滚动区域和浏览器控制台。

- [ ] **Step 4: 保存截图和 QA 记录**

保存 `qa-rich-conversations.png`，并在 `design-qa.md` 记录视口、会话抽查、交互结果和控制台状态。

- [ ] **Step 5: 最终验证**

Run:

```bash
node --test IOS-IM/prototype.test.cjs
npm test
curl -fsS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:4173/prototype.html
```

Expected: 原型测试与全项目测试零失败，HTTP 200。

- [ ] **Step 6: 提交**

```bash
git add IOS-IM
git commit -m "feat: complete rich conversation demo"
```

