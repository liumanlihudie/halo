# Expert Team And Circle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将主导航改为“对话、专家团、圈层、设置”，并把原 AI 朋友圈改造成不分类、按时间倒序、可按专家禁止发布的私人动态流。

**Architecture:** 继续使用单文件 HTML 原型，通过共享 `circlePublisherState` 保存各专家的发布权限，通过事件代理处理动态菜单和专家资料开关。圈层内容仍使用现有媒体预览、文件预览和页面导航能力，不增加后端或新依赖。

**Tech Stack:** HTML、CSS、原生 JavaScript、Node.js `node:test`、本地静态 HTTP 服务。

## Global Constraints

- 四个主 Tab 固定为“对话、专家团、圈层、设置”。
- 圈层不分类、不做算法推荐，严格按时间倒序展示。
- 专家默认允许发布，用户可以按专家禁止发布。
- 禁止发布只影响新圈层动态，不停止对话、任务、定时任务或监控。
- 不使用朋友圈大封面、压边头像、点赞评论条或微信品牌视觉。
- 保留现有媒体预览、文件预览、专家资料和会话跳转能力。

---

### Task 1: 固化导航与圈层契约

**Files:**
- Modify: `prototype.test.cjs`
- Modify: `prototype.html`

**Interfaces:**
- Consumes: 现有 `tabs` 数组和 `data-tab` 页面绑定。
- Produces: 标签“对话、专家团、圈层、设置”，页面 ID 继续使用 `contacts` 和 `moments` 以避免无关路由重构。

- [ ] **Step 1: 写失败测试**

断言主导航包含新名称，并拒绝旧主页面名称：

```js
expectAll(html, ['对话', '专家团', '圈层', '设置'], 'navigation');
assert.doesNotMatch(html, />通讯录<|>AI 朋友圈</);
```

- [ ] **Step 2: 运行测试确认失败**

Run: `node --test prototype.test.cjs`  
Expected: FAIL，提示缺少“专家团”或“圈层”。

- [ ] **Step 3: 修改导航和页面标题**

更新桌面侧栏、底部 `tabs` 数据、专家列表页标题和圈层页标题。

- [ ] **Step 4: 运行测试确认通过**

Run: `node --test prototype.test.cjs`  
Expected: PASS。

### Task 2: 重构圈层页面

**Files:**
- Modify: `prototype.test.cjs`
- Modify: `prototype.html`

**Interfaces:**
- Consumes: `data-preview-image`、`data-preview-file`、`data-go`、`data-action`。
- Produces: `.circle-header`、`.circle-post`、`.circle-source` 和覆盖多种来源的圈层动态。

- [ ] **Step 1: 写失败测试**

断言圈层无封面和分类栏，并覆盖来源：

```js
assert.doesNotMatch(html, /class="moment-cover"|class="cover-avatar"/);
expectAll(html, ['主动分享', '定时任务', '监控变化', '任务失败'], 'circle sources');
expectAll(html, ['查看来源', '继续对话'], 'circle actions');
```

- [ ] **Step 2: 运行测试确认失败**

Run: `node --test prototype.test.cjs`  
Expected: FAIL，原因是旧封面仍存在或缺少圈层来源。

- [ ] **Step 3: 实现圈层头部和卡片**

删除旧封面，加入说明文案；将动态改为独立卡片，保留图片、文件、数据和失败状态的真实 Mock。

- [ ] **Step 4: 运行测试确认通过**

Run: `node --test prototype.test.cjs`  
Expected: PASS。

### Task 3: 增加按专家禁止发布

**Files:**
- Modify: `prototype.test.cjs`
- Modify: `prototype.html`

**Interfaces:**
- Consumes: `openSheet(title, content)`、`showToast(text)`、`openContactProfile(node)`。
- Produces: `circlePublisherState`、`syncCirclePermissionUI(agentName)`、`setCirclePublishing(agentName, enabled)`。

- [ ] **Step 1: 写失败测试**

```js
expectAll(
  html,
  [
    'const circlePublisherState=',
    'function setCirclePublishing(',
    'data-action="circle-publishing-toggle"',
    'data-action="block-circle-publisher"',
    '不让该专家发圈层'
  ],
  'circle publishing controls'
);
```

- [ ] **Step 2: 运行测试确认失败**

Run: `node --test prototype.test.cjs`  
Expected: FAIL，提示缺少发布权限状态或操作。

- [ ] **Step 3: 实现资料开关和动态菜单**

资料页开关读取当前专家名称并更新发布权限；动态“更多”面板携带 `data-circle-agent`，确认后关闭发布并显示 Toast。

- [ ] **Step 4: 运行测试确认通过**

Run: `node --test prototype.test.cjs`  
Expected: PASS。

### Task 4: 清理文案并完成浏览器验收

**Files:**
- Modify: `prototype.test.cjs`
- Modify: `prototype.html`
- Modify: `docs/01-product/02-product-design.md`
- Modify: `docs/01-product/03-prototype-spec.md`
- Modify: `docs/06-quality/01-design-qa.md`

**Interfaces:**
- Consumes: 新导航、圈层页面和发布权限操作。
- Produces: 当前产品文档、最终截图和 QA 记录。

- [ ] **Step 1: 写失败测试**

断言面向用户的旧文案已替换：

```js
assert.doesNotMatch(html, /发布到朋友圈|自动总结到朋友圈|添加到通讯录/);
expectAll(html, ['发布到圈层', '允许发布到圈层', '添加到专家团'], 'new copy');
```

- [ ] **Step 2: 运行测试确认失败**

Run: `node --test prototype.test.cjs`  
Expected: FAIL，列出仍存在的旧文案。

- [ ] **Step 3: 更新文案和当前文档**

只修改当前产品定义和实现规范；历史头脑风暴与历史 QA 保留原文以维持决策记录。

- [ ] **Step 4: 浏览器验收**

逐项检查：

1. 四个主 Tab 名称和切换。
2. 专家团列表和专家资料。
3. 圈层无封面、无分类、内容多样。
4. 动态更多菜单禁止发布。
5. 专家资料重新开启发布。
6. 图片、文件和来源跳转。
7. 横向溢出、底部安全区和浏览器控制台。

- [ ] **Step 5: 最终验证**

Run: `node --test prototype.test.cjs`  
Expected: 全部通过。

Run: `curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4173/prototype.html`  
Expected: `200`。

