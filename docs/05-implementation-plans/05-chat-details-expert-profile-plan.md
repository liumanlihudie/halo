# 聊天详情与专家资料完整交互实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 补齐单聊详情、群资料和专家资料，并保证所有视觉上可操作的元素都有页面、弹层、预览、状态变化或明确反馈。

**Architecture:** 继续使用单文件 HTML 演示架构，在 `prototype.html` 中增加独立页面和轻量内存状态，不引入框架或后端。所有入口复用现有 `data-go`、`data-action` 事件委托、统一底部弹层、Toast 和媒体预览；契约测试在 `prototype.test.cjs` 中先行锁定页面、状态和交互。

**Tech Stack:** HTML、CSS、原生 JavaScript、Phosphor Icons 2.1.1、Node.js `node:test`、Codex in-app Browser。

**Execution status:** Completed on 2026-07-28. Final regression result: 39 passed, 0 failed. Browser QA: no horizontal overflow and no console warnings/errors in the inspected states.

## Global Constraints

- 单聊详情、群资料和专家资料必须是清楚区分的独立页面。
- 所有带按钮、链接、箭头、头像、图片、文件、开关、标签或卡片外观的元素必须可点击。
- 微信截图只用于信息架构与交互习惯参考，不复制品牌、颜色、图标、间距或逐像素布局。
- 通话入口保留在输入框“＋”菜单和专家资料页，不放回聊天导航栏。
- API Key 不在专家资料中展示。
- 危险操作必须二次确认。
- 所有开关必须同步视觉状态、`aria-checked` 和 Toast。
- 所有页面横向溢出为 `0px`，浏览器控制台 0 warning、0 error。

---

### Task 1: 建立交互契约

**Files:**
- Modify: `prototype.test.cjs`
- Test: `prototype.test.cjs`

**Interfaces:**
- Consumes: `readPrototype()` 与 `expectAll()`。
- Produces: 单聊详情、群资料、专家资料与全可点击规则的静态契约。

- [ ] **Step 1: 写单聊详情失败测试**

```js
test('single Agent chat opens a complete chat details page', () => {
  const html = readPrototype();
  expectAll(html, [
    'id="chat-details"',
    'data-go="chat-details"',
    '查找聊天记录',
    '消息免打扰',
    '置顶聊天',
    '重要消息提醒',
    '设置当前聊天背景',
    '导出聊天记录',
    '清空聊天记录',
    '反馈专家问题'
  ], 'single chat details');
});
```

- [ ] **Step 2: 写群资料与专家资料失败测试**

```js
test('group and expert pages expose familiar management paths', () => {
  const html = readPrototype();
  expectAll(html, [
    '查找群聊记录',
    '讨论完成提醒',
    '导出群聊记录',
    'id="expert-data"',
    '专家数据',
    '最近圈层动态',
    'data-action="filter-circle-agent"'
  ], 'group and expert management');
});
```

- [ ] **Step 3: 写全可点击状态失败测试**

```js
test('interactive-looking rows are wired to actions or navigation', () => {
  const html = readPrototype();
  expectAll(html, [
    'const conversationPreferences=',
    'function togglePreference(',
    'function openChatBackgroundPicker(',
    'function openExportOptions(',
    'function openExpertData(',
    'function filterCircleByAgent('
  ], 'interactive state');
});
```

- [ ] **Step 4: 运行测试并确认 RED**

Run:

```bash
node --test prototype.test.cjs
```

Expected: 新增的 3 个测试因页面或函数缺失而失败，现有测试继续通过。

---

### Task 2: 实现单 Agent 聊天详情

**Files:**
- Modify: `prototype.html`
- Test: `prototype.test.cjs`

**Interfaces:**
- Consumes: `currentConversationId`、`showPage(pageId)`、`openSheet(title, html)`、`showToast(message)`。
- Produces: `conversationPreferences`、`togglePreference(key, node)`、`openChatBackgroundPicker()`、`openExportOptions(kind)`。

- [ ] **Step 1: 在单聊导航栏增加详情入口**

```html
<div class="nav-actions">
  <button class="icon" data-go="chat-details" aria-label="聊天详情">
    <i class="ph ph-dots-three"></i>
  </button>
</div>
```

- [ ] **Step 2: 增加独立 `chat-details` 页面**

页面必须包含：

```html
<section class="page" id="chat-details">
  <div class="status">...</div>
  <div class="navbar compact">...</div>
  <div class="body ios-scroll soft-body">
    <button class="chat-peer-card" data-action="open-current-expert">...</button>
    <button class="chat-peer-add" data-action="add-to-group">...</button>
    <div class="setting-row" data-go="chat-history">查找聊天记录</div>
    <div class="setting-row" data-action="history-category" data-category="media">图片与视频</div>
    <div class="setting-row" data-action="history-category" data-category="files">文件</div>
    <div class="setting-row" data-action="history-category" data-category="links">链接</div>
    <div class="setting-row" data-action="history-category" data-category="artifacts">AI 成果</div>
    <div class="setting-row">消息免打扰 ...</div>
    <div class="setting-row">置顶聊天 ...</div>
    <div class="setting-row">重要消息提醒 ...</div>
    <div class="setting-row" data-action="chat-background">设置当前聊天背景</div>
    <div class="setting-row" data-action="export-chat">导出聊天记录</div>
    <div class="setting-row" data-action="clear-chat">清空聊天记录</div>
    <div class="setting-row" data-action="report-expert">反馈专家问题</div>
  </div>
</section>
```

- [ ] **Step 3: 增加会话偏好状态**

```js
const conversationPreferences = {};

function getConversationPreferences(id) {
  return conversationPreferences[id] ||= {
    muted: false,
    pinned: false,
    importantAlerts: true,
    backgroundId: 'default'
  };
}

function togglePreference(key, node) {
  const preferences = getConversationPreferences(currentConversationId);
  preferences[key] = !preferences[key];
  node.classList.toggle('off', !preferences[key]);
  node.setAttribute('aria-checked', String(preferences[key]));
  showToast(preferences[key] ? '设置已开启' : '设置已关闭');
}
```

- [ ] **Step 4: 实现背景、导出、反馈和清空弹层**

```js
function openChatBackgroundPicker() {
  openSheet('设置聊天背景', `
    <button class="sheet-option" data-background="default">默认浅灰</button>
    <button class="sheet-option" data-background="paper">纸张</button>
    <button class="sheet-option" data-background="navy">深蓝</button>
    <button class="sheet-option" data-background="album">从相册选择</button>
  `);
}

function openExportOptions(kind) {
  openSheet(`导出${kind}`, `
    <button class="sheet-option" data-export-format="markdown">Markdown</button>
    <button class="sheet-option" data-export-format="json">JSON</button>
    <button class="sheet-option" data-export-format="zip">ZIP · 包含附件</button>
  `);
}
```

清空记录必须先打开确认弹层，确认后清空当前消息区并插入“聊天记录已清空”的系统状态。

- [ ] **Step 5: 运行测试并确认 GREEN**

Run:

```bash
node --test prototype.test.cjs
```

Expected: 单聊详情契约通过，无原测试回归。

---

### Task 3: 补齐群资料通用会话管理

**Files:**
- Modify: `prototype.html`
- Test: `prototype.test.cjs`

**Interfaces:**
- Consumes: Task 2 的会话偏好、背景、导出与记录分类函数。
- Produces: 群成员到专家资料的跳转，以及群聊独立的通用会话设置。

- [ ] **Step 1: 让群成员成为语义化按钮**

```html
<button class="member" data-contact-profile="产品经理" ...>
  <img class="avatar" ...>
  产品经理
</button>
```

点击后调用现有 `openContactProfile(node)` 并显示该成员资料。

- [ ] **Step 2: 增加群记录快捷入口**

在群聊信息后增加：

```html
<div class="setting-row" data-go="chat-history"><span>查找群聊记录</span><small>›</small></div>
<div class="asset-shortcuts">
  <button data-action="history-category" data-category="media">图片与视频</button>
  <button data-action="history-category" data-category="files">文件</button>
  <button data-action="history-category" data-category="links">链接</button>
  <button data-action="history-category" data-category="artifacts">AI 成果</button>
</div>
```

- [ ] **Step 3: 增加群聊开关与数据操作**

```html
<div class="setting-row"><span>消息免打扰</span><div class="switch" role="switch" ...></div></div>
<div class="setting-row"><span>置顶群聊</span><div class="switch" role="switch" ...></div></div>
<div class="setting-row"><span>讨论完成提醒</span><div class="switch" role="switch" ...></div></div>
<div class="setting-row" data-action="chat-background">设置当前群聊背景</div>
<div class="setting-row" data-action="export-group">导出群聊记录</div>
```

- [ ] **Step 4: 区分清空与删除确认**

`clear-chat` 文案必须说明保留群配置；`delete-group` 文案必须说明删除会话入口和群配置。

- [ ] **Step 5: 运行测试并确认 GREEN**

Run:

```bash
node --test prototype.test.cjs
```

Expected: 群资料契约通过，现有群聊交互测试继续通过。

---

### Task 4: 扩充专家资料与专家数据

**Files:**
- Modify: `prototype.html`
- Test: `prototype.test.cjs`

**Interfaces:**
- Consumes: `currentProfileAgentName`、`circlePublisherState`、`providerConfigs`、`showPage()`、`openMediaPreview()`。
- Produces: `openExpertData()`、`filterCircleByAgent(agentName)`、`expertPreferences`。

- [ ] **Step 1: 让专家资料头部可操作**

- 头像：`data-action="preview-profile-avatar"`。
- 模型标签：`data-action="open-expert-model"`。
- 状态：`data-action="expert-activity"`。
- 更多：打开专家操作菜单。

- [ ] **Step 2: 增加专家数据入口和页面**

```html
<div class="setting-row" data-go="expert-data">
  <span>专家数据</span><small>提示词、模型、工具与权限　›</small>
</div>
```

`expert-data` 页面提供昵称、提示词、回答风格、Provider、模型、语音角色、视频形象、工具权限、数据权限、主动消息、共享事实和私有关系记忆。每行必须通过 `data-action` 打开编辑或详情弹层。

- [ ] **Step 3: 增加最近圈层入口**

```html
<div class="setting-row" data-action="filter-circle-agent">
  <span>最近圈层动态</span><small id="profileCircleSummary">3 条 · 刚刚　›</small>
</div>
```

```js
function filterCircleByAgent(agentName) {
  document.querySelectorAll('#moments .circle-post').forEach(post => {
    post.hidden = post.dataset.circleAgent !== agentName;
  });
  document.getElementById('circleFilterLabel').textContent = `只看 ${agentName}`;
  showPage('moments');
}
```

圈层页必须提供“清除筛选”，恢复所有动态。

- [ ] **Step 4: 实现专家更多菜单**

菜单项：

- 分享专家。
- 复制专家配置。
- 导出专家配置。
- 暂停主动工作。
- 从专家团移除。
- 反馈专家问题。

暂停与移除必须二次确认；移除说明保留历史会话。

- [ ] **Step 5: 运行测试并确认 GREEN**

Run:

```bash
node --test prototype.test.cjs
```

Expected: 专家资料契约通过，圈层发布开关测试继续通过。

---

### Task 5: 完成所有视觉入口的点击反馈

**Files:**
- Modify: `prototype.html`
- Modify: `prototype.test.cjs`

**Interfaces:**
- Consumes: 全部 `data-action`、`data-go`、`data-preview-*`。
- Produces: 不存在死入口的交互审计结果。

- [ ] **Step 1: 增加静态审计测试**

```js
test('interactive-looking setting rows are not dead ends', () => {
  const html = readPrototype();
  const rows = [...html.matchAll(/<div class="setting-row"([^>]*)>/g)];
  const dead = rows.filter(([, attrs]) =>
    !/data-action=|data-go=|data-preview-|role="switch"/.test(attrs)
  );
  assert.equal(dead.length, 0, `dead setting rows: ${dead.length}`);
});
```

如果现有行只负责包裹原生按钮，应改成语义化 `<button>`，不能通过豁免字符串跳过测试。

- [ ] **Step 2: 覆盖头像、标签、卡片和箭头**

逐项检查：

- `.member`
- `.contact`
- `.chat-peer-card`
- `.profile-hero .avatar`
- `.asset-shortcuts button`
- `.setting-row`
- `.circle-post button`
- `.file-card`
- `.link-card`
- `.media-thumb`

每个元素必须有 `data-action`、`data-go`、`data-preview-*` 或原生按钮事件。

- [ ] **Step 3: 覆盖切换状态与辅助功能**

所有自定义开关使用：

```html
<button class="switch" role="switch" aria-checked="true" aria-label="置顶聊天"></button>
```

不能继续使用没有角色、无法键盘聚焦的空 `<div class="switch">`。

- [ ] **Step 4: 运行完整测试**

Run:

```bash
node --test prototype.test.cjs
```

Expected: 全部测试通过，0 failed。

---

### Task 6: 同步多 Provider 模型接入前端

**Files:**
- Modify: `prototype.html`
- Modify: `prototype.test.cjs`
- Modify: `docs/01-product/02-product-design.md`
- Modify: `docs/01-product/03-prototype-spec.md`

**Interfaces:**
- Consumes: `providerConfigs`、`renderProviderState()`、`openProvider(providerId)`、专家资料与市场详情。
- Produces: `ModelRef(providerId, modelId)` 展示、多个 Provider 并存状态、全局默认与单 Agent 覆盖交互。

- [ ] **Step 1: 写多 Provider 失败测试**

```js
test('model service UI supports multiple simultaneous providers and ModelRef labels', () => {
  const html = readPrototype();
  expectAll(html, [
    'ToAPIs',
    'DeepSeek',
    'OpenAI',
    'Anthropic Claude',
    'Google Gemini',
    '自定义 OpenAI-compatible',
    '本地模型',
    '豆包端到端语音',
    '默认文字模型',
    '默认图片模型',
    '默认视频模型',
    'providerId',
    'modelId'
  ], 'multi-provider UI');
  assert.doesNotMatch(html, /所有模型必须经过 ToAPIs|平台 Token|Token 充值/);
});
```

- [ ] **Step 2: 扩充模型服务列表与状态**

模型服务页至少展示：

```text
ToAPIs                    已配置 · 推荐 · 42 个模型
DeepSeek                  已配置 · 2 个模型
OpenAI                    未配置
Anthropic Claude          已配置 · 4 个模型
Google Gemini             连接异常 · 可重试
自定义 OpenAI-compatible  1 个实例
本地模型                  Ollama · 无需 Key
豆包端到端语音            已配置
```

每张卡通过 `data-provider-id` 进入详情；状态必须覆盖 `healthy`、`unconfigured`、`degraded`、`unauthorized` 和 `offline`。

- [ ] **Step 3: 增加全局默认模型选择**

设置页提供四个可点击入口：

```html
<div class="setting-row" data-action="select-default-model" data-model-kind="text">默认文字模型</div>
<div class="setting-row" data-action="select-default-model" data-model-kind="image">默认图片模型</div>
<div class="setting-row" data-action="select-default-model" data-model-kind="video">默认视频模型</div>
<div class="setting-row" data-action="select-default-model" data-model-kind="router">Router 模型</div>
```

选择项必须同时展示 Provider 和模型，例如：

```text
Anthropic · claude-sonnet-4
OpenAI · gpt-5-mini
ToAPIs · seedream-4
```

- [ ] **Step 4: 让 Provider 详情随实例变化**

`openProvider(providerId)` 根据 Provider 渲染：

- 服务名称与 Adapter 类型。
- Base URL。
- Key 或“无需 Key”。
- Key 尾号。
- 模型数量。
- 最近检测时间。
- 健康状态。
- 测试连接、刷新模型、启用/禁用、移除 Key。

ToAPIs 额外显示额度，但只提供“前往 ToAPIs 管理额度”，不提供 Halo 充值、支付或订单。

- [ ] **Step 5: 同步专家、市场与群聊模型标识**

- 专家资料显示 `Provider · modelId`，点击进入单 Agent 模型覆盖。
- 专家数据允许选择 `primaryModelRef` 与候补模型。
- AI 市场详情把模板推荐改成能力要求与推荐 `ModelRef`，安装时按已配置 Provider 解析。
- 群聊发言人标签显示不同 Provider，例如 `产品经理 · Anthropic / claude-sonnet-4`。
- 总结卡显示 `ToAPIs / deepseek-chat` 或其他实际 `RunModelSnapshot`。

- [ ] **Step 6: 补齐无 Key 与异常状态**

原型至少提供：

- 未配置 Key：进入 Provider 设置。
- 401：重新填写 Key。
- 429：显示等待后重试。
- 5xx / 离线：切换候补 Provider 或稍后重试。
- 本地模型离线：检查服务地址。
- 已开始输出：保留部分内容，不跨 Provider 拼接。

每种状态必须有明确按钮或弹层，不显示完整 Key、请求体或堆栈。

- [ ] **Step 7: 运行完整测试**

Run:

```bash
node --test prototype.test.cjs
```

Expected: 多 Provider 契约通过，无账号、无平台计费和现有群聊测试继续通过。

---

### Task 7: 浏览器设计 QA 与文档收口

**Files:**
- Modify: `docs/01-product/02-product-design.md`
- Modify: `docs/01-product/03-prototype-spec.md`
- Modify: `docs/03-development/04-mvp-implementation-plan.md`
- Modify: `docs/06-quality/01-design-qa.md`
- Create: `docs/06-quality/assets/chat-details-expert-profile-2026-07-28/`
- Test: `prototype.test.cjs`

**Interfaces:**
- Consumes: 已完成的 HTML 原型。
- Produces: 浏览器截图、交互证据和最终 QA 记录。

- [ ] **Step 1: 更新产品与开发文档**

写明：

- 会话偏好与专家全局偏好的边界。
- 单聊详情、群资料和专家资料页面清单。
- 所有视觉入口必须可点击的验收标准。
- Flutter MVP 中 `ConversationPreferences` 与 `ExpertPreferences` 的实现任务。

- [ ] **Step 2: 在浏览器验证核心路径**

依次验证：

1. 通用助理 → 聊天详情。
2. 查找记录及四类资产入口。
3. 免打扰、置顶、重要提醒。
4. 背景选择、导出、清空确认、反馈。
5. 群资料新增设置。
6. 群成员 → 专家资料。
7. 专家数据所有行。
8. 最近圈层动态筛选与清除筛选。
9. 专家更多菜单。

- [ ] **Step 3: 测量布局并检查日志**

每个新增页面必须满足：

```text
scrollWidth - clientWidth = 0
console warning count = 0
console error count = 0
```

- [ ] **Step 4: 保存并检查截图**

至少保存：

- `01-chat-details.png`
- `02-chat-background-sheet.png`
- `03-group-info.png`
- `04-expert-profile.png`
- `05-expert-data.png`
- `06-circle-agent-filter.png`

- [ ] **Step 5: 最终验证**

Run:

```bash
node --test prototype.test.cjs
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4173/prototype.html
git diff --check -- prototype.html prototype.test.cjs docs/
```

Expected:

```text
all tests pass
200
no diff-check output
```
