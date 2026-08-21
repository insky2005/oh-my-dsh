'use strict';

/**
 * End-to-end channel dispatch test: drives the FULL pipeline
 *   ClawBot adapter(mock transport) -> ChannelManager -> Router ->
 *   session driver (LIVE dsh web on 3080) -> reply -> adapter.send
 *
 * Requires a live dsh web on 127.0.0.1:3080 (the app / dsh web running).
 * Skipped when no live server is present.
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');
const os = require('node:os');
const path = require('node:path');
const fs = require('node:fs');
const { createWeixinClawBotAdapter } = require('../lib/weixin-clawbot');
const { createWeixinClawBotTransport } = require('../lib/weixin-clawbot-transport');
const { createSessionDriver } = require('../lib/session-driver');
const { createChannelManager, normalizeEvent, createRouter, buildReply } = require('../lib/channel');

function liveDSH() {
  return new Promise((resolve) => {
    const req = require('node:http').get({ host: '127.0.0.1', port: 3080, path: '/', timeout: 2000 }, (res) => {
      res.resume(); resolve(res.statusCode === 200);
    });
    req.on('error', () => resolve(false));
    req.on('timeout', () => { req.destroy(); resolve(false); });
  });
}

test('e2e: ClawBot adapter -> manager -> router -> LIVE dsh session -> send', { timeout: 60000 }, async (t) => {
  const up = await liveDSH();
  if (!up) { t.skip('no live dsh web on 3080'); return; }

  // A throwaway project dir for the session.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'chan-e2e-'));

  // Mock transport: queues one inbound message, records sends.
  const sent = [];
  const mockTransport = {
    async connect() {},
    async disconnect() {},
    async fetchUpdates() {
      const items = [{ conversationId: 'e2e-conv', text: '请回复：全流程验证通过', ts: Date.now() }];
      return items;
    },
    async sendMessage(payload) { sent.push(payload); },
    onError() {},
  };

  // Wire the FULL pipeline.
  const adapter = createWeixinClawBotAdapter({ channelId: 'wx-e2e', transport: mockTransport, intervalMs: 30 });
  const adapters = new Map([['wx-e2e', adapter]]);
  const refsByChannel = () => [
    { channelId: 'wx-e2e', workspaceRoot: dir, workspaceId: undefined, routing: { conversations: ['e2e-conv'] } },
  ];
  const sessionDriver = createSessionDriver({ port: 3080, pollIntervalMs: 300, maxPolls: 120 });
  const mgr = createChannelManager({ adapters, refsByChannel, sessionDriver });

  // Drive one event through the manager.
  const event = normalizeEvent({ channelId: 'wx-e2e', conversationId: 'e2e-conv', text: '请回复：全流程验证通过', platform: 'weixin-clawbot' });
  const res = await mgr.handleEvent(event);

  assert.equal(res.routed, true, 'should route to the project');
  assert.equal(res.ref.workspaceRoot, dir);
  assert.ok(res.reply && typeof res.reply.text === 'string', 'session should produce a reply');
  assert.ok(res.reply.text.length > 0, 'reply text non-empty');
  // The adapter.send must have been called with the reply.
  assert.equal(sent.length, 1, 'adapter.send should be called once');
  assert.equal(sent[0].conversationId, 'e2e-conv');
  assert.ok(sent[0].text.length > 0, 'sent reply non-empty');
  console.log('e2e reply:', JSON.stringify(sent[0].text).slice(0, 120));

  adapter.dispose();
});

test('e2e: transport maps OpenClaw updates to RawMsg', async () => {
  let gotUrl = null, gotBody = null;
  const fetchImpl = async (url, opts) => {
    gotUrl = url; gotBody = JSON.parse(opts.body);
    return { text: async () => JSON.stringify({ data: { items: [{ conversationId: 'wx-9', text: 'hi', sender: 'alice' }], next_cursor: 7 } }) };
  };
  const transport = createWeixinClawBotTransport({ baseUrl: 'http://x/openclaw', fetch: fetchImpl });
  await transport.connect();
  const updates = await transport.fetchUpdates();
  assert.equal(updates.length, 1);
  assert.equal(updates[0].conversationId, 'wx-9');
  assert.equal(updates[0].text, 'hi');
  assert.match(gotUrl, /getupdates/);
});

test('e2e: transport -14 -> connect rejects auth-expired', async () => {
  const fetchImpl = async () => ({ text: async () => JSON.stringify({ ret: -14 }) });
  const transport = createWeixinClawBotTransport({ baseUrl: 'http://x/openclaw', fetch: fetchImpl });
  await assert.rejects(() => transport.connect(), /-14/);
});
