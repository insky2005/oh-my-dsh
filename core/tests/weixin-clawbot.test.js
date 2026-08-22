'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createWeixinClawBotAdapter } = require('../lib/weixin-clawbot');
const { CHANNEL_STATES } = require('../lib/channel');

test('clawbot: connect transitions to connected and polls updates', async () => {
  const updates = [{ conversationId: 'wx-1', text: 'hello', sender: 'alice' }];
  const sent = [];
  let connected = false;
  let fetched = false;
  const transport = {
    async connect() { connected = true; },
    async disconnect() { connected = false; },
    // return the message ONCE, then empty — otherwise the strictly-serial poll
    // loop re-emits + re-logs the same message for the whole test (noise only).
    async fetchUpdates() { if (fetched) return []; fetched = true; return updates; },
    async sendMessage(payload) { sent.push(payload); },
  };
  const adapter = createWeixinClawBotAdapter({ channelId: 'ch-1', transport, intervalMs: 10 });
  assert.equal(adapter.getState(), CHANNEL_STATES.DISCONNECTED);

  const events = [];
  adapter.onEvent((e) => events.push(e));
  await adapter.connect();
  assert.equal(adapter.getState(), CHANNEL_STATES.CONNECTED);

  // poll loop is async; wait a tick for the first fetchUpdates emission
  await new Promise((r) => setTimeout(r, 50));
  assert.ok(events.length >= 1, 'expected at least one event');
  assert.equal(events[0].platform, 'weixin-clawbot');
  assert.equal(events[0].channelId, 'ch-1');
  assert.equal(events[0].conversationId, 'wx-1');
  assert.equal(events[0].text, 'hello');

  // send strips markdown and forwards to transport
  await adapter.send('wx-1', { text: '**done** `ok`', media: null });
  assert.equal(sent[0].conversationId, 'wx-1');
  assert.equal(sent[0].text, 'done ok');

  await adapter.disconnect();
  assert.equal(adapter.getState(), CHANNEL_STATES.DISCONNECTED);
  adapter.dispose();
});

test('clawbot: connect failure -> auth-expired', async () => {
  const transport = {
    async connect() { throw new Error('login failed'); },
    async fetchUpdates() { return []; },
  };
  const adapter = createWeixinClawBotAdapter({ channelId: 'ch-2', transport });
  await assert.rejects(() => adapter.connect(), /login failed/);
  assert.equal(adapter.getState(), CHANNEL_STATES.AUTH_EXPIRED);
  adapter.dispose();
});

test('clawbot: fetchUpdates error -> reconnecting state', async () => {
  let shouldFail = false;
  const transport = {
    async connect() {},
    async fetchUpdates() { if (shouldFail) throw new Error('net'); return []; },
  };
  const adapter = createWeixinClawBotAdapter({ channelId: 'ch-3', transport, intervalMs: 10 });
  await adapter.connect();
  shouldFail = true;
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(adapter.getState(), CHANNEL_STATES.RECONNECTING);
  await adapter.disconnect();
  adapter.dispose();
});

test('clawbot: normalizeEvent validates and drops malformed updates', async () => {
  let fetchedOnce = false;
  const transport = {
    async connect() {},
    async fetchUpdates() {
      if (fetchedOnce) return [];
      fetchedOnce = true;
      return [{ text: 'no conversation' }, { conversationId: 'ok-1', text: 'good' }];
    },
  };
  const adapter = createWeixinClawBotAdapter({ channelId: 'ch-4', transport, intervalMs: 10 });
  const events = [];
  adapter.onEvent((e) => events.push(e));
  await adapter.connect();
  await new Promise((r) => setTimeout(r, 40));
  assert.equal(events.length, 1);
  assert.equal(events[0].conversationId, 'ok-1');
  await adapter.disconnect();
  adapter.dispose();
});
