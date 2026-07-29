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

test('prototype contains the four familiar but Halo-specific top tabs', () => {
  const html = readPrototype();
  expectAll(html, ['对话', '专家团', '圈层', '设置'], 'navigation');
  assert.doesNotMatch(html, />通讯录<|>AI 朋友圈</);
  assert.doesNotMatch(html, /真人好友|真人朋友圈|企业通讯录/);
});

test('circle is an unclassified reverse-chronological expert feed, not a Moments clone', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
      'class="circle-head"',
      'class="circle-post"',
      '你的专家最近在想什么、做什么',
      '主动分享',
      '定时任务',
      '监控变化',
      '任务失败',
      '查看来源',
      '继续对话'
    ],
    'circle feed'
  );
  assert.doesNotMatch(html, /class="moment-cover"|class="cover-avatar"|class="feed-space"/);
});

test('each expert can be prevented from publishing without disabling their work', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
      'const circlePublisherState=',
      'function setCirclePublishing(',
      'function syncCirclePermissionUI(',
      'data-action="circle-publishing-toggle"',
      'data-action="block-circle-publisher"',
      '不让该专家发圈层',
      '不会停止对话、任务、定时任务或监控'
    ],
    'circle publishing controls'
  );
});

test('current UI copy uses expert team and circle terminology', () => {
  const html = readPrototype();
  expectAll(html, ['添加到专家团', '发布到圈层', '允许发布到圈层'], 'current terminology');
  assert.doesNotMatch(
    html,
    /发布到朋友圈|自动总结到朋友圈|添加到通讯录|总结到 AI 朋友圈|朋友圈自动总结/
  );
});

test('single Agent chat opens a complete chat details page', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
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
    ],
    'single chat details'
  );
});

test('group and expert pages expose familiar management paths', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
      '查找群聊记录',
      '讨论完成提醒',
      '导出群聊记录',
      'id="expert-data"',
      '专家数据',
      '最近圈层动态',
      'data-action="filter-circle-agent"'
    ],
    'group and expert management'
  );
});

test('chat details and expert data expose stateful interactive handlers', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
      'const conversationPreferences=',
      'function togglePreference(',
      'function openChatBackgroundPicker(',
      'function openExportOptions(',
      'function openExpertData(',
      'function filterCircleByAgent('
    ],
    'interactive state'
  );
});

test('chat history opens in a search-only idle state', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
      'id="historySearchInput"',
      'id="historyContent"',
      'data-history-mode="search-idle"',
      'const historyViewState=',
      '.navbar button[hidden]{display:none}'
    ],
    'chat history search shell'
  );
  assert.doesNotMatch(html, /class="history-filter|id="historyResults"/);
});

test('history search renders highlighted list results', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
      'const historyItems=[',
      'messageText:',
      'displayName:',
      'agentName:',
      'sourceTitle:',
      'function renderHistorySearchResults(query)',
      'function highlightHistoryMatch(text,query)',
      'class="history-search-result',
      '<mark class="history-match">'
    ],
    'history search results'
  );
});

test('history categories render date-grouped cards', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
      'function renderHistoryCards(category)',
      'class="history-date-section"',
      'class="history-media-grid"',
      'class="history-file-grid"',
      'class="history-link-card',
      'class="history-artifact-card',
      'data-action="history-category-menu"',
      "content.dataset.historyMode='category-cards'"
    ],
    'history card categories'
  );
});

test('add-to-group sheet uses compact thumbnails that cannot overflow their rows', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
      'class="sheet-group-avatar"',
      '.sheet-option .sheet-group-avatar{width:36px;height:36px;flex:0 0 36px',
      '.sheet-group-avatar i{min-width:0;min-height:0',
      '<button type="button" class="sheet-option" data-sheet-action="pick-group"'
    ],
    'add-to-group sheet layout'
  );
});

test('model service UI supports multiple simultaneous providers and ModelRef labels', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
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
    ],
    'multi-provider UI'
  );
  assert.doesNotMatch(html, /所有模型必须经过 ToAPIs|平台 Token|Token 充值/);
});

test('default model selection persists providerId and modelId as separate values', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
      'function applyDefaultModel(kind,providerId,modelId)',
      'applyDefaultModel(action.dataset.modelKind,action.dataset.providerRef,action.dataset.modelRef)',
      'providerState.defaultModels[kind]={providerId,modelId}'
    ],
    'default model selection'
  );
  assert.doesNotMatch(
    html,
    /applyDefaultModel\(action\.dataset\.modelKind,\{providerId:/
  );
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

test('all rich media messages expose a shared preview interaction', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
      'id="media-preview"',
      'id="mediaPreviewImage"',
      'id="mediaPreviewTitle"',
      'id="mediaPreviewCounter"',
      'const mediaPreviewState=',
      'function openMediaPreview(',
      'function stepMediaPreview(',
      'data-preview-image=',
      'data-preview-file=',
      'data-preview-link=',
      'data-action="close-media-preview"',
      'data-action="preview-previous"',
      'data-action="preview-next"'
    ],
    'shared rich media preview'
  );
  assert.match(
    html,
    /closest\('\.gallery-message,\.photo-grid,\.circle-gallery'\)/,
    'circle galleries should open as one navigable image group'
  );
});

test('previewable media has visible affordance and accessible labels', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
      '.previewable-media',
      '.media-preview',
      '.media-preview-toolbar',
      'aria-label="预览图片"',
      'aria-label="预览文件"',
      'aria-label="打开网页预览"'
    ],
    'preview affordance'
  );
});

test('contacts group settings and context rows never show dead-end affordances', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
      'data-contact-profile=',
      'function openContactProfile(',
      'id="profileAgentName"',
      'id="groupInfoGoal"',
      'id="groupInfoHost"',
      'data-action="edit-group-goal"',
      'data-action="edit-group-host"',
      'data-preview-file="IOS-IM 产品规格.md"',
      'data-action="memory-private"'
    ],
    'interactive rows'
  );
});

test('call controls and rich cards use semantic buttons with feedback', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
      '<button type="button" class="call-btn"',
      '<button type="button" class="round"',
      'aria-label="切换摄像头"',
      'aria-label="静音"',
      'data-action="play-voice"',
      'data-action="inspect-rich-card"',
      'data-go="moment-detail"'
    ],
    'semantic controls'
  );
  assert.doesNotMatch(html, /<div class="(?:call-btn|round)(?:\s|")/);
});

test('open-source market UI describes BYOK instead of platform prices', () => {
  const html = readPrototype();
  expectAll(
    html,
    ['使用你的 API Key', 'BYOK · 按服务商账单结算'],
    'BYOK market copy'
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

test('destructive message actions render as deliberate iOS controls', () => {
  const html = readPrototype();
  assert.match(
    html,
    /\.message-action\.danger\{[^}]*border:1px solid[^}]*background:#fff6f6[^}]*color:var\(--red\)/
  );
  assert.match(
    html,
    /class="message-action \$\{message\.action==='stop-task'\?'danger':''\}"/
  );
  assert.match(html, /ph-stop-circle/);
});

test('compact titles stay centered and one-to-one calls live in the plus menu', () => {
  const html = readPrototype();
  assert.match(
    html,
    /\.navbar\.compact h2\{[^}]*position:absolute[^}]*left:50%[^}]*transform:translateX\(-50%\)/
  );
  const chatHeader = html.match(
    /<section class="page" id="chat">([\s\S]*?)<div class="chat-scroll/
  );
  assert.ok(chatHeader, 'single chat header should exist');
  assert.doesNotMatch(chatHeader[1], /data-go="voice"|data-go="video"|语音通话|视频通话/);
  expectAll(
    html,
    [
      'function openAttachmentSheet()',
      'data-go="voice"',
      'data-go="video"',
      '端到端语音通话',
      'Vidu 视频通话'
    ],
    'plus menu call actions'
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
      '发布到圈层'
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
    ['主动分享', '定时任务', '监控变化', '任务失败', '查看来源'],
    'circle mocks'
  );
  expectAll(
    html,
    ['本地空间', '共享事实记忆', '模型服务', 'Face ID', '系统权限'],
    'settings mocks'
  );
});

test('market and mutable flows are represented', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
      'AI 市场',
      '添加到专家团',
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
  assert.doesNotMatch(html, /#07c160|class="[^"]*\bwechat\b/i);
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
  assert.doesNotMatch(html, /ph-orbit/, 'Phosphor 2.1.1 does not ship the ph-orbit glyph');
  assert.match(html, /ph-circles-three/, 'circle navigation should use an available glyph');
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
    'chips ios-scroll',
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
  assert.match(html, /\.stage\{[^}]*position:relative/);
  assert.match(html, /\.phone\{[^}]*position:absolute[^}]*top:28px[^}]*left:50%[^}]*margin-left:-196\.5px[^}]*transform-origin:top center/);
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

test('toast feedback never intercepts taps on controls beneath it', () => {
  const html = readPrototype();
  assert.match(
    html,
    /\.toast\{[^}]*pointer-events:none/,
    'transparent or visible toast feedback must not block buttons'
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

test('settings exposes an expanded local-space card and real icons', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
      'class="settings-profile-card"',
      '无账号 · 数据由你掌控',
      '数据仅保存在本机',
      '已添加 Agent',
      '已配置模型',
      'ph ph-brain',
      'ph ph-users',
      'ph ph-sparkle',
      'ph ph-cpu',
      'ph ph-waveform',
      'ph ph-video-camera',
      'ph ph-database',
      'ph ph-shield-check',
      'ph ph-scan'
    ],
    'settings identity and icons'
  );
  assert.doesNotMatch(html, /<div class="row-icon">(?:忆|私|圈|模|声|像|铃|权|面)<\/div>/);
});

test('settings exposes BYOK providers local data and optional self-hosting', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
      'data-go="model-providers"',
      'data-go="provider-detail"',
      'data-go="self-hosted-gateway"',
      'data-go="local-data"',
      'id="model-providers"',
      'id="provider-detail"',
      'id="self-hosted-gateway"',
      'id="local-data"',
      'API Key',
      'iOS Keychain',
      'OpenAI-compatible',
      '自托管 Gateway',
      '导入数据包',
      '导出数据包'
    ],
    'local-first settings'
  );
});

test('prototype has no account authentication or platform billing flow', () => {
  const html = readPrototype();
  assert.doesNotMatch(html, /id="(?:login|verification-login|forgot-password|change-password|switch-account|account-center|token-center|token-checkout|token-result)"/);
  assert.doesNotMatch(html, /data-action="(?:logout|password-login|apple-login|start-token-checkout|submit-token-payment)"/);
  assert.doesNotMatch(html, /退出登录|验证码登录|忘记密码|充值 Token|Token 余额|删除账户/);
});

test('provider configuration can be tested saved and removed locally', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
      'const providerState=',
      'function renderProviderState()',
      'function openProvider(id)',
      'function testProviderConnection()',
      'function saveProvider()',
      'function removeProvider()',
      'data-action="test-provider"',
      'data-action="save-provider"',
      'data-action="remove-provider"',
      '只保存在本机 Keychain'
    ],
    'provider configuration'
  );
});

test('local data controls explain ownership backup and destructive clearing', () => {
  const html = readPrototype();
  expectAll(
    html,
    [
      '数据默认保存在本机',
      'API Key 不进入导出包',
      'data-action="export-local-data"',
      'data-action="import-local-data"',
      'data-action="clear-local-data"',
      '清除本机数据'
    ],
    'local data ownership'
  );
});
