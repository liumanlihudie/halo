# AI 市场与设置页升级 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将现有 Halo iOS HTML 原型升级为包含 50 个可筛选、可搜索、分批加载且可查看详情的专家市场，并完善设置页个人身份卡与统一图标。

**Architecture:** 保持现有单文件原型结构，在 `prototype.html` 中增加一个稳定的 `marketAgents` 数据集合和小型本地状态机，由纯函数完成过滤、分页和卡片渲染。设置页继续使用现有组件与 Phosphor 图标库，只扩展资料卡结构和图标映射，不引入后端或新依赖。

**Tech Stack:** HTML5、CSS、原生 JavaScript、Phosphor Icons、Node.js `node:test`

## Global Constraints

- 只修改 `IOS-IM` 内的原型、测试和验收材料。
- `marketAgents` 必须恰好包含 50 个具有不同名称和能力描述的专家。
- 首次与每次追加均展示 10 个专家。
- 不实现后端、登录、支付、真实模型调用或跨刷新持久化。
- 所有新增设置图标必须来自当前 Phosphor 图标库。
- 保持现有 393 × 852 手机画布、动态安全区和四个底部标签页。

---

### Task 1: 建立 50 个专家数据与基础市场渲染

**Files:**
- Modify: `prototype.html`
- Test: `prototype.test.cjs`

**Interfaces:**
- Produces: `marketAgents: MarketAgent[]`
- Produces: `renderMarketAgents(): void`
- Produces: `filterMarketAgents(): MarketAgent[]`
- Produces: `marketState: { category: string, query: string, visibleCount: number, selectedId: string | null }`

`MarketAgent` 字段：

```js
{
  id: 'contract-review',
  name: '合同审阅助手',
  category: '法律财税',
  description: '标记风险条款、解释影响，并给出逐条修改建议。',
  rating: 4.8,
  badge: '热门',
  model: 'Claude Sonnet',
  price: '约 ¥0.4–1.5/份',
  tags: ['合同', '风险', '修订'],
  avatar: 'https://images.unsplash.com/...',
  verified: true,
  permissions: '仅访问你主动发送的文件'
}
```

- [ ] **Step 1: 写入失败测试**

在 `prototype.test.cjs` 中增加：

```js
test('AI market defines exactly 50 varied experts', () => {
  const html = readPrototype();
  const block = html.match(/const marketAgents=\[([\s\S]*?)\n  \];/);
  assert.ok(block, 'marketAgents should be declared');
  const ids = [...block[1].matchAll(/\bid:'([^']+)'/g)].map(match => match[1]);
  assert.equal(ids.length, 50);
  assert.equal(new Set(ids).size, 50);
  expectAll(
    block[1],
    ['效率', '研究', '内容', '数据', '法律财税', '生活'],
    'market categories'
  );
  expectAll(
    block[1],
    ['Claude Sonnet', 'GPT', 'Gemini Pro', 'DeepSeek', 'Doubao'],
    'market models'
  );
});
```

- [ ] **Step 2: 运行测试并确认失败**

Run:

```bash
node --test prototype.test.cjs
```

Expected: FAIL，提示 `marketAgents should be declared`。

- [ ] **Step 3: 添加数据容器和列表挂载点**

将市场页硬编码专家卡片替换为：

```html
<div class="market-title">
  <b id="marketHeading">本周精选</b>
  <span id="marketCount">已显示 10 / 50</span>
</div>
<div id="marketAgentList"></div>
<div class="market-load-state" id="marketLoadState">继续向下滑动加载更多</div>
```

在脚本中声明 50 个完整 `MarketAgent` 对象，名称、描述和 ID 不重复。分类分布为：效率 9、研究 9、内容 8、数据 8、法律财税 8、生活 8。不同专家轮换使用至少五种模型。

- [ ] **Step 4: 实现最小渲染函数**

```js
const MARKET_PAGE_SIZE=10;
const marketState={category:'推荐',query:'',visibleCount:MARKET_PAGE_SIZE,selectedId:null};

function filterMarketAgents(){
  const query=marketState.query.trim().toLowerCase();
  return marketAgents.filter(agent=>{
    const categoryMatch=marketState.category==='推荐'
      || marketState.category==='新上架'&&agent.badge==='新上架'
      || agent.category===marketState.category;
    const haystack=[agent.name,agent.description,agent.category,...agent.tags]
      .join(' ')
      .toLowerCase();
    return categoryMatch&&(!query||haystack.includes(query));
  });
}

function renderMarketAgents(){
  const filtered=filterMarketAgents();
  const visible=filtered.slice(0,marketState.visibleCount);
  document.getElementById('marketAgentList').innerHTML=visible.map(agent=>`
    <article class="agent-card" data-agent-id="${agent.id}">
      <img class="avatar" src="${agent.avatar}" alt="">
      <div class="agent-card-main">
        <div class="agent-card-head">
          <b>${escapeHtml(agent.name)}</b>
          <span class="rating">★ ${agent.rating.toFixed(1)} · ${agent.badge}</span>
        </div>
        <p>${escapeHtml(agent.description)}</p>
        <div class="mini-tags">
          <span>${escapeHtml(agent.model)}</span>
          <span>${escapeHtml(agent.price)}</span>
          ${agent.tags.slice(0,2).map(tag=>`<span>${escapeHtml(tag)}</span>`).join('')}
        </div>
      </div>
    </article>
  `).join('');
  document.getElementById('marketCount').textContent=
    `已显示 ${visible.length} / ${filtered.length}`;
}
```

- [ ] **Step 5: 初始化市场并运行测试**

在脚本初始化区域调用：

```js
renderMarketAgents();
```

Run:

```bash
node --test prototype.test.cjs
```

Expected: PASS。

- [ ] **Step 6: 提交**

```bash
git add prototype.html prototype.test.cjs
git commit -m "feat: add fifty expert market profiles"
```

---

### Task 2: 分类、搜索与分批加载

**Files:**
- Modify: `prototype.html`
- Test: `prototype.test.cjs`

**Interfaces:**
- Consumes: `marketAgents`, `marketState`, `filterMarketAgents()`, `renderMarketAgents()`
- Produces: `setMarketCategory(category: string): void`
- Produces: `setMarketQuery(query: string): void`
- Produces: `loadMoreMarketAgents(): void`

- [ ] **Step 1: 写入失败测试**

```js
test('AI market supports filtering, search, and ten-item incremental loading', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
      'const MARKET_PAGE_SIZE=10',
      'function setMarketCategory(category)',
      'function setMarketQuery(query)',
      'function loadMoreMarketAgents()',
      'id="marketSearchInput"',
      'id="marketAgentList"',
      'id="marketLoadState"'
    ],
    'market behavior'
  );
});
```

- [ ] **Step 2: 运行测试并确认失败**

Run:

```bash
node --test prototype.test.cjs
```

Expected: FAIL，缺少分类、搜索或加载函数。

- [ ] **Step 3: 改造分类与搜索控件**

```html
<label class="search market-search">
  <i class="ph ph-magnifying-glass"></i>
  <input id="marketSearchInput" type="search" placeholder="搜索 Agent、技能或工作场景">
</label>
<div class="chips" id="marketCategories">
  <button class="chip active" data-market-category="推荐">推荐</button>
  <button class="chip" data-market-category="效率">效率</button>
  <button class="chip" data-market-category="研究">研究</button>
  <button class="chip" data-market-category="内容">内容</button>
  <button class="chip" data-market-category="数据">数据</button>
  <button class="chip" data-market-category="法律财税">法律财税</button>
  <button class="chip" data-market-category="生活">生活</button>
  <button class="chip" data-market-category="新上架">新上架</button>
</div>
```

搜索输入使用透明背景和无边框样式，点击标签只影响 `data-market-category` 控件，不复用其他页面 `.chip` 的通用提示逻辑。

- [ ] **Step 4: 实现状态更新函数**

```js
function setMarketCategory(category){
  marketState.category=category;
  marketState.visibleCount=MARKET_PAGE_SIZE;
  document.querySelectorAll('[data-market-category]').forEach(button=>{
    button.classList.toggle('active',button.dataset.marketCategory===category);
  });
  document.querySelector('#market .market-body').scrollTop=0;
  renderMarketAgents();
}

function setMarketQuery(query){
  marketState.query=query;
  marketState.visibleCount=MARKET_PAGE_SIZE;
  renderMarketAgents();
}

function loadMoreMarketAgents(){
  const total=filterMarketAgents().length;
  if(marketState.visibleCount>=total)return;
  marketState.visibleCount=Math.min(total,marketState.visibleCount+MARKET_PAGE_SIZE);
  renderMarketAgents();
}
```

- [ ] **Step 5: 绑定输入、分类和市场滚动**

```js
document.getElementById('marketSearchInput').addEventListener('input',event=>{
  setMarketQuery(event.currentTarget.value);
});

document.getElementById('marketCategories').addEventListener('click',event=>{
  const button=event.target.closest('[data-market-category]');
  if(button)setMarketCategory(button.dataset.marketCategory);
});

document.querySelector('#market .market-body').addEventListener('scroll',event=>{
  const body=event.currentTarget;
  if(body.scrollTop+body.clientHeight>=body.scrollHeight-80){
    loadMoreMarketAgents();
  }
});
```

当 `filtered.length===0` 时，`renderMarketAgents()` 写入包含 `data-action="clear-market-filter"` 的空状态；加载状态在全部加载后显示“已显示全部专家”。

- [ ] **Step 6: 运行测试并提交**

Run:

```bash
node --test prototype.test.cjs
```

Expected: PASS。

```bash
git add prototype.html prototype.test.cjs
git commit -m "feat: add expert market discovery controls"
```

---

### Task 3: 动态专家详情与添加状态

**Files:**
- Modify: `prototype.html`
- Test: `prototype.test.cjs`

**Interfaces:**
- Consumes: `marketAgents`, `marketState`
- Produces: `openMarketAgent(id: string): void`
- Produces: `installSelectedAgent(): void`

- [ ] **Step 1: 写入失败测试**

```js
test('every market expert can populate the shared detail screen', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
      'function openMarketAgent(id)',
      'function installSelectedAgent()',
      'id="marketDetailName"',
      'id="marketDetailDescription"',
      'id="marketDetailAbilities"',
      'id="marketDetailModel"',
      'id="marketDetailPermissions"'
    ],
    'market detail binding'
  );
});
```

- [ ] **Step 2: 运行测试并确认失败**

Run:

```bash
node --test prototype.test.cjs
```

Expected: FAIL，缺少动态详情绑定。

- [ ] **Step 3: 给详情页增加稳定挂载点**

为现有 Agent 详情页的头像、名称、认证信息、描述、能力、模型价格、权限和主按钮分别增加 ID：

```html
<img class="avatar" id="marketDetailAvatar" alt="">
<h2 id="marketDetailName"></h2>
<small id="marketDetailMeta"></small>
<p id="marketDetailDescription"></p>
<div class="ability-grid" id="marketDetailAbilities"></div>
<p id="marketDetailModel"></p>
<p id="marketDetailPermissions"></p>
<button class="primary" id="installButton" data-action="install-agent">添加到通讯录</button>
```

- [ ] **Step 4: 实现详情写入和添加**

```js
function openMarketAgent(id){
  const agent=marketAgents.find(item=>item.id===id);
  if(!agent){
    showToast('没有找到这个专家');
    showPage('market');
    return;
  }
  marketState.selectedId=id;
  document.getElementById('marketDetailAvatar').src=agent.avatar;
  document.getElementById('marketDetailName').textContent=agent.name;
  document.getElementById('marketDetailMeta').textContent=
    `${agent.verified?'认证专家':'独立专家'} · ★ ${agent.rating.toFixed(1)} · ${agent.badge}`;
  document.getElementById('marketDetailDescription').textContent=agent.description;
  document.getElementById('marketDetailAbilities').innerHTML=agent.tags.map(tag=>
    `<div class="ability"><b>${escapeHtml(tag)}</b>${escapeHtml(agent.description)}</div>`
  ).join('');
  document.getElementById('marketDetailModel').textContent=
    `${agent.model} · ${agent.price}`;
  document.getElementById('marketDetailPermissions').textContent=agent.permissions;
  showPage('market-detail');
}

function installSelectedAgent(){
  const agent=marketAgents.find(item=>item.id===marketState.selectedId);
  if(!agent)return;
  const button=document.getElementById('installButton');
  button.textContent='已添加';
  button.classList.add('done');
  showToast(`${agent.name}已添加到通讯录`);
}
```

市场列表使用事件委托读取 `data-agent-id` 并调用 `openMarketAgent()`。现有 `installAgent()` 改为调用 `installSelectedAgent()`，保留合同助手兼容行为。

- [ ] **Step 5: 运行测试并提交**

Run:

```bash
node --test prototype.test.cjs
```

Expected: PASS。

```bash
git add prototype.html prototype.test.cjs
git commit -m "feat: bind market cards to expert details"
```

---

### Task 4: 扩大个人资料卡并统一设置图标

**Files:**
- Modify: `prototype.html`
- Test: `prototype.test.cjs`

**Interfaces:**
- Produces: `.settings-profile-card`
- Produces: `.profile-stats`
- Consumes: 现有 Phosphor Icons 样式表

- [ ] **Step 1: 写入失败测试**

```js
test('settings exposes an expanded identity card and real icons', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
      'class="settings-profile-card"',
      'Halo ID',
      '偏好直接结论 · 主要用于产品与研究',
      '已添加 Agent',
      '本月用量',
      'ph ph-brain',
      'ph ph-users',
      'ph ph-sparkle',
      'ph ph-chart-donut',
      'ph ph-waveform',
      'ph ph-video-camera',
      'ph ph-bell',
      'ph ph-shield-check',
      'ph ph-scan'
    ],
    'settings identity and icons'
  );
  assert.doesNotMatch(html, /<div class="row-icon">(?:忆|私|圈|模|声|像|铃|权|面)<\/div>/);
});
```

- [ ] **Step 2: 运行测试并确认失败**

Run:

```bash
node --test prototype.test.cjs
```

Expected: FAIL，缺少身份卡或真实设置图标。

- [ ] **Step 3: 实现个人身份卡**

```html
<section class="settings-profile-card" data-action="profile">
  <div class="profile-identity">
    <img class="avatar" src="..." alt="Cofe">
    <div>
      <h3>Cofe</h3>
      <p>Halo ID · cofe.ai</p>
      <small>偏好直接结论 · 主要用于产品与研究</small>
    </div>
    <i class="ph ph-caret-right"></i>
  </div>
  <div class="profile-sync">
    <span><i class="ph ph-cloud-check"></i> iCloud 刚刚同步</span>
    <span>跨设备记忆已开启</span>
  </div>
  <div class="profile-stats">
    <div><b>9</b><small>已添加 Agent</small></div>
    <div><b>¥36.20</b><small>本月用量</small></div>
    <div><b>128</b><small>共享记忆</small></div>
  </div>
</section>
```

CSS 使用现有圆角、浅灰背景和紫色强调色。卡片最小高度 150px，资料文本允许两行但不得溢出，统计区使用三列网格。

- [ ] **Step 4: 替换设置项文字图标**

把每个：

```html
<div class="row-icon">忆</div>
```

替换为：

```html
<div class="row-icon"><i class="ph ph-brain"></i></div>
```

并按设计文档完成全部图标映射。补充：

```css
.row-icon i{font-size:17px;line-height:1}
```

不得改变现有开关、箭头、说明文本和点击行为。

- [ ] **Step 5: 运行测试并提交**

Run:

```bash
node --test prototype.test.cjs
```

Expected: PASS。

```bash
git add prototype.html prototype.test.cjs
git commit -m "feat: expand settings identity and icons"
```

---

### Task 5: 浏览器验收、设计 QA 与服务

**Files:**
- Modify: `docs/06-quality/01-design-qa.md`
- Create: `docs/06-quality/assets/qa-market-50-agents.png`
- Create: `docs/06-quality/assets/qa-settings-profile.png`
- Test: `prototype.test.cjs`

**Interfaces:**
- Consumes: 完成后的 `prototype.html`
- Produces: 可访问的 `http://127.0.0.1:4173/prototype.html`

- [ ] **Step 1: 运行静态与全量测试**

```bash
node --test prototype.test.cjs
node -e 'const fs=require("fs"),vm=require("vm");const h=fs.readFileSync("prototype.html","utf8");const m=h.match(/<script>([\s\S]*)<\/script>/);if(!m)throw new Error("script missing");new vm.Script(m[1]);console.log("inline script syntax: ok")'
git diff --check -- .
npm test
```

Expected: 原型测试全部通过、内联脚本语法正确、无 diff 格式错误、项目 544 个既有测试全部通过。

- [ ] **Step 2: 确认本地服务**

如果 4173 端口没有现有服务，在 `IOS-IM` 目录运行：

```bash
python3 -m http.server 4173 --bind 127.0.0.1
```

验证：

```bash
curl -fsS -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1:4173/prototype.html
```

Expected: `HTTP 200`。

- [ ] **Step 3: 浏览器验证 AI 市场**

在应用内浏览器打开 `http://127.0.0.1:4173/prototype.html`：

1. 点击“AI 市场”。
2. 确认首屏计数为 `已显示 10 / 50`。
3. 滚动到底至少四次，确认最终为 `已显示 50 / 50`。
4. 选择“法律财税”，确认只显示该分类。
5. 搜索“合同”，确认结果名称或标签匹配。
6. 点击搜索结果，确认详情名称、模型和权限随专家变化。
7. 检查浏览器控制台无错误。
8. 保存 `docs/06-quality/assets/qa-market-50-agents.png`。

- [ ] **Step 4: 浏览器验证设置页**

1. 点击“设置”。
2. 确认个人资料卡完整显示头像、Halo ID、简介、同步状态和三项统计。
3. 确认每个设置项均为 Phosphor 图标，不出现文字方块。
4. 滚动到页面底部，确认底部导航与设置项均不裁切。
5. 保存 `docs/06-quality/assets/qa-settings-profile.png`。

- [ ] **Step 5: 更新设计 QA**

在 `docs/06-quality/01-design-qa.md` 追加本轮来源、截图、浏览器 viewport、交互检查、控制台结果和五项视觉检查：字体、间距、颜色、图片、文案。只有没有未解决 P0/P1/P2 时写：

```md
final result: passed
```

- [ ] **Step 6: 最终提交**

```bash
git add prototype.html prototype.test.cjs docs/06-quality/01-design-qa.md docs/06-quality/assets/qa-market-50-agents.png docs/06-quality/assets/qa-settings-profile.png
git commit -m "feat: complete expanded AI expert market"
```
