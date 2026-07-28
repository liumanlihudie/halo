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
  assert.match(html, /remixicon@4\.6\.0/);
  assert.match(html, /\.icon>i\s*\{[^}]*font-size\s*:\s*18px/);
  assert.match(html, /\.rail-icon i\s*\{[^}]*font-size\s*:\s*16px/);
  assert.match(html, /\.tabs button i\s*\{[^}]*font-size\s*:\s*21px/);
});
