'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const os = require('node:os');
const path = require('node:path');
const fs = require('node:fs');
const { createDingTalkTransport, createDingTalkStreamClient, TOPIC_ROBOT } = require('../lib/dingtalk-stream-transport');
const { createDingTalkAdapter } = require('../lib/dingtalk');
const { CHANNEL_STATES, normalizeEvent } = require('../lib/channel');
const { runDingTalkChannel } = require('../lib/channel-runner');
const { saveChannelAccount } = require('../lib/channel-store');

/** A controllable mock DingTalk Stream client. */
function makeMockClient(overrides = {}) {
  const topics = new Map();
  const statusHandlers = new Set();
  let status = 'stopped';
  const acked = [];
  const client = {
    registerCallbackListener(t, cb) { topics.set(t, cb); },
    _fire(topic, data, headers) { const cb = topics.get(topic); if (cb) cb({ data, headers: headers || {} }); },
    getAccessToken: overrides.getAccessToken || (async () => 'tok-1'),
    socketCallBackResponse(mid, result) { acked.push({ mid, result }); },
    async connect() { status = 'connected'; for (const h of statusHandlers) h(status); },
    async disconnect() { status = 'stopped'; for (const h of statusHandlers) h(status); },
    getState() { return status; },
    onStatus(cb) { statusHandlers.add(cb); return () => statusHandlers.delete(cb); },
    _acked: acked,
  };
  Object.assign(client, overrides);
  return client;
}

function robotFrame(msgId, overrides = {}) {
  return JSON.stringify({
    msgId,
    conversationId: 'conv-1',
    senderStaffId: 'u-1',
    senderNick: 'Alice',
    sessionWebhook: 'https://hook.example/reply',
    sessionWebhookExpiredTime: Date.now() + 3600_000,
    createAt: Date.now(),
    conversationType: 'single',
    msgtype: 'text',
    text: { content: '你好' },
    robotCode: 'rc',
    ...overrides,
  });
}

test('dingtalk transport: robot callback -> normalized event + msgId dedupe', () => {
  const client = makeMockClient();
  const transport = createDingTalkTransport({ channelId: 'dt-1', client });
  const events = [];
  transport.onEvent((e) => events.push(e));

  client._fire(TOPIC_ROBOT, robotFrame('m1'));
  assert.equal(events.length, 1);
  assert.equal(events[0].channelId, 'dt-1');
  assert.equal(events[0].platform, 'dingtalk');
  assert.equal(events[0].conversationId, 'conv-1');
  assert.equal(events[0].text, '你好');
  assert.equal(events[0].messageId, 'm1');
  assert.equal(events[0].sessionWebhook, 'https://hook.example/reply');

  // same msgId redelivered (server retry) is deduped
  client._fire(TOPIC_ROBOT, robotFrame('m1'));
  assert.equal(events.length, 1);

  // new msgId delivers
  client._fire(TOPIC_ROBOT, robotFrame('m2', { text: { content: '第二次' } }));
  assert.equal(events.length, 2);
  assert.equal(events[1].text, '第二次');
});

test('dingtalk transport: sendMessage POSTs sessionWebhook + acks', async () => {
  const client = makeMockClient();
  const calls = [];
  const fetchImpl = async (url, opts) => {
    calls.push({ url, opts });
    return { ok: true, json: async () => ({ code: 0 }) };
  };
  const transport = createDingTalkTransport({ channelId: 'dt-1', client, fetch: fetchImpl });
  const res = await transport.sendMessage({ conversationId: 'conv-1', text: '回复', sessionWebhook: 'https://hook.example/reply', msgId: 'm1' });
  assert.equal(calls.length, 1);
  const body = JSON.parse(calls[0].opts.body);
  assert.equal(body.msgtype, 'text');
  assert.equal(body.text.content, '回复');
  assert.equal(calls[0].opts.headers['x-acs-dingtalk-access-token'], 'tok-1');
  assert.equal(client._acked.length, 1, 'must ack the originating frame');
  assert.equal(client._acked[0].mid, 'm1');
  assert.equal(res.sent, true);
});

test('dingtalk adapter: connect state + sessionWebhook reply', async () => {
  const client = makeMockClient();
  const transport = createDingTalkTransport({ channelId: 'dt-1', client, fetch: async () => ({ ok: true, json: async () => ({}) }) });
  const adapter = createDingTalkAdapter({ channelId: 'dt-1', transport });
  assert.equal(adapter.getState(), CHANNEL_STATES.DISCONNECTED);

  await adapter.connect();
  assert.equal(adapter.getState(), CHANNEL_STATES.CONNECTED);

  const events = [];
  adapter.onEvent((e) => events.push(e));
  client._fire(TOPIC_ROBOT, robotFrame('m1'));
  assert.equal(events.length, 1);
  assert.equal(events[0].platform, 'dingtalk');

  // reply uses the conversation's latest sessionWebhook
  await adapter.send('conv-1', { text: '**done** `ok`' });
  await adapter.disconnect();
  assert.equal(adapter.getState(), CHANNEL_STATES.DISCONNECTED);
  adapter.dispose();
});

test('dingtalk adapter: send without a sessionWebhook throws', async () => {
  const client = makeMockClient();
  const transport = createDingTalkTransport({ channelId: 'dt-2', client });
  const adapter = createDingTalkAdapter({ channelId: 'dt-2', transport });
  await assert.rejects(() => adapter.send('unknown-conv', 'hi'), /sessionWebhook/);
  adapter.dispose();
});

test('dingtalk runner: exports runDingTalkChannel', () => {
  assert.equal(typeof runDingTalkChannel, 'function');
});

test('dingtalk runner: end-to-end via injected client + fetch', async () => {
  const http = require('node:http');
  const wsSrv = await new Promise((resolve) => {
    const srv = http.createServer((req, res) => {
      let body = '';
      req.on('data', (c) => { body += c; });
      req.on('end', () => {
        let rpcId = '';
        try { rpcId = JSON.parse(body).rpcId || ''; } catch { /* ignore */ }
        res.writeHead(200, { 'content-type': 'application/json' });
        const url = String(req.url || '');
        if (url.includes('/api/workspace.list')) {
          res.end(JSON.stringify({ rpcId, result: { ok: true, value: { items: [{ workspaceId: 'w1', path: '/p', title: 'P', sessionIds: [] }] } } }));
        } else if (url.includes('/api/session.list')) {
          res.end(JSON.stringify({ rpcId, result: { ok: true, value: { items: [] } } }));
        } else if (url.includes('/api/session.create')) {
          res.end(JSON.stringify({ rpcId, result: { ok: true, value: { sessionId: 'sess-1' } } }));
        } else if (url.includes('/api/session.rename')) {
          res.end(JSON.stringify({ rpcId, result: { ok: true, value: {} } }));
        } else if (url.includes('/api/session.prompt')) {
          res.end(JSON.stringify({ rpcId, result: { ok: true, value: {} } }));
        } else if (url.includes('/api/session.history')) {
          res.end(JSON.stringify({ rpcId, result: { ok: true, value: { events: [{ event: { type: 'assistant/message', data: { message: { role: 'assistant', content: [{ type: 'text', text: '答复内容' }] } } } }] } } }));
        } else {
          res.end(JSON.stringify({ rpcId, result: { ok: true, value: null } }));
        }
      });
    });
    srv.listen(0, '127.0.0.1', () => resolve({ srv, port: srv.address().port }));
  });

  const dshHome = fs.mkdtempSync(path.join(os.tmpdir(), 'dt-run-'));
  saveChannelAccount('dt-c', { clientId: 'appkey', clientSecret: 'appsecret' }, dshHome);
  const projectRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'dt-pr-'))
  {
    const dir = path.join(dshHome, 'channels');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'dt-c.workspaces.json'), JSON.stringify({ ws: projectRoot }), 'utf8');
  }

  const client = makeMockClient();
  let replied = null;
  const fetchImpl = async (url, opts) => {
    if (String(url).includes('hook.example')) { replied = JSON.parse(opts.body); return { ok: true, json: async () => ({}) }; }
    return { ok: true, json: async () => ({}) };
  };

  const handle = await runDingTalkChannel({
    channelId: 'dt-c',
    port: wsSrv.port,
    refs: [{ channelId: 'dt-c', workspaceRoot: projectRoot, routing: { default: true } }],
    projectRoot,
    dshHome,
    transportOpts: { clientFactory: (cid, acct) => client, fetch: fetchImpl },
  });
  await handle.start();
  // fire an inbound robot message -> routes to session -> replies via webhook
  client._fire(TOPIC_ROBOT, robotFrame('m-r1'));
  await new Promise((r) => setTimeout(r, 300));
  await handle.stop();
  wsSrv.srv.close();
  assert.ok(replied, 'expected a reply to be sent to the sessionWebhook');
  assert.equal(replied.msgtype, 'text');
  assert.ok(replied.text.content.length > 0);
});
