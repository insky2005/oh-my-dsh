'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const os = require('node:os');
const path = require('node:path');
const fs = require('node:fs');
const { saveChannelAccount, loadChannelAccount, clearChannelAccount, channelAccountPath } = require('../lib/channel-store');
const { createChannelManager, normalizeEvent } = require('../lib/channel');

test('channel-store: save/load/clear account file (file-first)', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'chan-store-'));
  const p = saveChannelAccount('wx-test', { botToken: 'bt', accountId: 'acc', userId: 'user', baseUrl: 'https://ilinkai.weixin.qq.com' }, dir);
  assert.equal(p, channelAccountPath('wx-test', dir));
  assert.ok(fs.existsSync(p));
  const acct = loadChannelAccount('wx-test', dir);
  assert.equal(acct.botToken, 'bt');
  assert.equal(acct.userId, 'user');
  assert.ok(clearChannelAccount('wx-test', dir));
  assert.equal(loadChannelAccount('wx-test', dir), null);
});

test('channel-runner: manager sends reply carrying contextToken', async () => {
  let sent = null;
  const sessionDriver = { async run() { return { text: 'ok', media: null }; } };
  const adapters = new Map([['wx-c', { channelId: 'wx-c', onEvent() {}, async send(c, r) { sent = r; } }]]);
  const mgr = createChannelManager({
    adapters,
    refsByChannel: () => [{ channelId: 'wx-c', workspaceRoot: '/p', routing: { conversations: ['u'] } }],
    sessionDriver,
  });
  const ev = normalizeEvent({ channelId: 'wx-c', conversationId: 'u', text: 'hi' });
  ev.contextToken = 'tok-9';  // adapter attaches contextToken after normalization
  const res = await mgr.handleEvent(ev);
  assert.equal(res.reply.text, 'ok');
  assert.equal(res.reply.contextToken, 'tok-9', 'reply must carry contextToken');
  assert.equal(sent.contextToken, 'tok-9', 'adapter.send receives contextToken');
});

test('channel-runner: router no-match sends unbounded hint', async () => {
  let sent = null;
  const adapters = new Map([['wx-c', { channelId: 'wx-c', onEvent() {}, async send(c, r) { sent = r; } }]]);
  const mgr = createChannelManager({ adapters, refsByChannel: () => [], sessionDriver: null });
  const res = await mgr.handleEvent(normalizeEvent({ channelId: 'wx-c', conversationId: 'orphan', text: 'hi' }));
  assert.equal(res.routed, false);
  assert.match(sent.text, /未绑定/);
});
