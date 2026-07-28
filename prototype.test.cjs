const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const prototypePath = path.join(__dirname, 'prototype.html');

function readPrototype() {
  assert.ok(
    fs.existsSync(prototypePath),
    'prototype.html should exist in IOS-IM'
  );
  return fs.readFileSync(prototypePath, 'utf8');
}

function expectAll(source, values, label) {
  for (const value of values) {
    assert.ok(source.includes(value), `${label} should include “${value}”`);
  }
}

test('prototype contains the four AI-only IM tabs', () => {
  const html = readPrototype();
  expectAll(html, ['对话', '通讯录', 'AI 朋友圈', '设置'], 'navigation');
  assert.doesNotMatch(html, /真人好友|真人朋友圈|企业通讯录/);
});

test('conversation list includes three distinct text groups', () => {
  const html = readPrototype();
  expectAll(
    html,
    ['iOS 产品小组', '本周信息研判', '内容发布团队'],
    'conversation list'
  );
  expectAll(
    html,
    ['id="group-chat"', 'id="group-info"', 'id="new-group"', 'id="group-context"'],
    'group screens'
  );
});

test('every conversation list item maps to one of twelve rich mock conversations', () => {
  const html = readPrototype();
  const ids = [...html.matchAll(/data-conversation-id="([^"$]+)"/g)].map(match => match[1]);
  assert.equal(new Set(ids).size, 9);
  expectAll(
    html,
    [
      'const conversationMocks={',
      "'general-assistant'",
      "'data-analyst-chat'",
      "'calendar-assistant'",
      "'translation-expert-chat'",
      "'contract-review-chat'",
      "'deep-research-task'",
      "'file-processing'",
      "'monitoring-chat'",
      "'system-assistant'"
    ],
    'conversation dataset'
  );
});

test('conversation mocks cover rich message and failure formats', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
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
    ],
    'message types'
  );
  expectAll(
    html,
    ['function renderMessage(message)', 'function renderConversation(id)', 'function openConversation(id)'],
    'conversation renderer'
  );
});

test('all three groups define independent members goals and histories', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
      "product:{title:'iOS 产品小组'",
      "research:{title:'本周信息研判'",
      "content:{title:'内容发布团队'",
      'function renderGroupMessages(group)'
    ],
    'group histories'
  );
  expectAll(html, ['交叉核验', '来源可信度', '封面方向 B', '事实核验'], 'distinct group content');
});

test('single conversation sends and scenario actions update visible state', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
      'function sendSingleMessage()',
      'function updateConversationPreview(id,text)',
      'function runConversationAction(action,id)',
      'retry-upload',
      'stop-task',
      'grant-permission',
      'view-usage'
    ],
    'conversation mutation'
  );
});

test('group chat exposes all three reply modes and no call controls', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
      '自动选择 1–2 个合适的 Agent',
      '@某个 Agent',
      '@所有人',
      '让大家讨论',
      'setGroupMode',
      'runGroupReply',
      'stopDiscussion'
    ],
    'group chat'
  );

  const groupPage = html.match(
    /<section class="page[^"]*" id="group-chat">([\s\S]*?)<\/section>/
  );
  assert.ok(groupPage, 'group chat section should be present');
  assert.doesNotMatch(groupPage[1], /语音通话|视频通话|data-go="voice"|data-go="video"/);
});

test('group discussion shows phases, rebuttal, stop, and summary actions', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
      '观点收集',
      '交叉讨论',
      '生成总结',
      '我不同意',
      '停止讨论',
      '保存总结',
      '发布到朋友圈'
    ],
    'discussion flow'
  );
});

test('main pages contain varied mock data families', () => {
  const html = readPrototype();
  expectAll(
    html,
    ['PDF', '任务进行中', '发送失败', '图片', '未读'],
    'conversation mocks'
  );
  expectAll(
    html,
    ['工作型', '资讯型', '生活型', '忙碌', '可用'],
    'contact mocks'
  );
  expectAll(
    html,
    ['数据洞察', '周报', '仅自己可见', '任务失败', '来源对话'],
    'Moments mocks'
  );
  expectAll(
    html,
    ['iCloud', '共享事实记忆', '模型与用量', 'Face ID', '数据与权限'],
    'settings mocks'
  );
});

test('market and mutable flows are represented', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
      'AI 市场',
      '添加到通讯录',
      '添加到群聊',
      'createGroup',
      'installAgent',
      'addAgentToGroup',
      'publishSummary'
    ],
    'mutable flows'
  );
});

test('prototype uses a single accent and avoids WeChat brand assets', () => {
  const html = readPrototype();
  assert.match(html, /--accent:/);
  assert.doesNotMatch(html, /微信|WeChat|#07c160|wechat/i);
});

test('compact icon buttons cannot inherit full-width primary CTA layout', () => {
  const html = readPrototype();
  assert.doesNotMatch(
    html,
    /(?:^|})\s*\.primary\s*\{[^}]*flex\s*:\s*1/,
    'primary CTA layout must be scoped to its owning component'
  );
  assert.match(
    html,
    /\.icon\.primary\s*\{[^}]*flex\s*:\s*0 0 34px/,
    'icon primary buttons must keep a fixed 34px hit area'
  );
  assert.match(
    html,
    /\.bottom-bar \.primary\s*\{/,
    'bottom-bar CTA should own its flexible width'
  );
});

test('navigation controls use one real icon family with explicit glyph sizing', () => {
  const html = readPrototype();
  assert.match(html, /@phosphor-icons\/web@2\.1\.1/);
  assert.doesNotMatch(html, /remixicon|class="ri-/);
  assert.match(html, /\.icon>i\s*\{[^}]*font-size\s*:\s*18px/);
  assert.match(html, /\.rail-icon i\s*\{[^}]*font-size\s*:\s*16px/);
  assert.match(html, /\.tabs button i\s*\{[^}]*font-size\s*:\s*21px/);
});

test('iOS surfaces use hidden overlay scrolling without browser-width tracks', () => {
  const html = readPrototype();
  assert.match(html, /html,body\{[^}]*overflow:hidden/);
  assert.match(html, /\.ios-scroll\{[^}]*scrollbar-width:none/);
  assert.match(html, /\.ios-scroll::-webkit-scrollbar\{display:none/);
  for (const className of [
    'body ios-scroll',
    'chat-scroll ios-scroll',
    'market-body ios-scroll',
    'moments-scroll ios-scroll',
    'detail-body ios-scroll',
    'sheet ios-scroll'
  ]) {
    assert.ok(html.includes(className), `scrolling surface should include “${className}”`);
  }
});

test('phone and chat composers stay clear of rounded corners and overlays', () => {
  const html = readPrototype();
  assert.match(html, /--phone-safe-bottom:\s*30px/);
  assert.match(html, /\.workspace\{[^}]*height:100vh[^}]*min-height:0[^}]*overflow:hidden/);
  assert.match(html, /\.stage\{[^}]*height:100vh[^}]*min-height:0[^}]*overflow:hidden/);
  assert.match(html, /\.stage\{[^}]*place-items:start center/);
  assert.match(html, /\.phone\{[^}]*transform-origin:top center/);
  assert.match(
    html,
    /\.chat-scroll\{[^}]*padding:12px 12px var\(--composer-offset,\s*128px\)/
  );
  assert.match(
    html,
    /\.composer\{[^}]*padding:4px 9px var\(--phone-safe-bottom\)/
  );
  expectAll(
    html,
    ['function syncComposerInsets()', 'ResizeObserver', 'function fitPhoneToStage()', 'phone.style.marginTop'],
    'responsive phone layout'
  );
});

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
