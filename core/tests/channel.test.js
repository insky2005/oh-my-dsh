'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  CHANNEL_STATES, ROUTE_PRIORITY,
  normalizeEvent, buildReply, toPlainText,
  createStateMachine, createRouter,
  normalizeChannel, parseProjectRefs, createChannelManager,
} = require('../lib/channel');

test('channel: normalizeEvent fills defaults and coerces field names', () => {
  const e = normalizeEvent({ conversationId: 'wx-1', text: 'hi', sender: 'u' });
  assert.equal(e.conversationId, 'wx-1');
  assert.equal(e.text, 'hi');
  assert.equal(e.sender, 'u');
  assert.equal(e.media, null);
  assert.equal(e.platform, '');
  assert.ok(Number.isFinite(e.ts));
});

test('channel: normalizeEvent accepts media and conversation_id alias', () => {
  const e = normalizeEvent({ conversation_id: 'c2', text: 'x', media: { type: 'image', url: 'u.png', fileName: 'a.png' } });
  assert.equal(e.conversationId, 'c2');
  assert.deepEqual(e.media, { type: 'image', filePath: null, url: 'u.png', mimeType: null, fileName: 'a.png' });
});

test('channel: normalizeEvent throws without conversationId', () => {
  assert.throws(() => normalizeEvent({ text: 'x' }), /conversationId/);
});

test('channel: buildReply from string or object', () => {
  assert.deepEqual(buildReply('ok'), { text: 'ok', media: null });
  assert.deepEqual(buildReply({ text: 'a', media: { type: 'file', url: '/f' } }), { text: 'a', media: { type: 'file', url: '/f' } });
});

test('channel: toPlainText strips markdown emphasis', () => {
  assert.equal(toPlainText('**bold** and `code` and *it*'), 'bold and code and it');
});

test('channel: state machine transitions + listeners', () => {
  const sm = createStateMachine(CHANNEL_STATES.DISCONNECTED);
  const seen = [];
  sm.onChange((s) => seen.push(s));
  sm.connecting(); sm.connected(); sm.reconnecting(); sm.authExpired(); sm.disconnected();
  assert.deepEqual(seen, ['connecting', 'connected', 'reconnecting', 'auth-expired', 'disconnected']);
  assert.equal(sm.get(), CHANNEL_STATES.DISCONNECTED);
  assert.throws(() => sm.set('bogus'), /invalid state/);
});

test('channel: router prefers explicit conversation binding', () => {
  const router = createRouter();
  const refs = [
    { channelId: 'ch', workspaceRoot: '/a', routing: { keywords: ['@a'], default: false } },
    { channelId: 'ch', workspaceRoot: '/b', routing: { conversations: ['c-9'], default: false } },
  ];
  const hit = router.match({ event: { conversationId: 'c-9', text: '@a hello' }, refs });
  assert.equal(hit.ref.workspaceRoot, '/b');
  assert.equal(hit.priority, ROUTE_PRIORITY.conversation);
});

test('channel: router falls to keyword when no conversation binding', () => {
  const router = createRouter();
  const refs = [
    { channelId: 'ch', workspaceRoot: '/a', routing: { keywords: ['@a'], default: false } },
    { channelId: 'ch', workspaceRoot: '/d', routing: { default: true } },
  ];
  const hit = router.match({ event: { conversationId: 'c-1', text: 'please @a do it' }, refs });
  assert.equal(hit.ref.workspaceRoot, '/a');
  assert.equal(hit.priority, ROUTE_PRIORITY.keyword);
});

test('channel: router default fallback only when single default', () => {
  const router = createRouter();
  const refs = [
    { channelId: 'ch', workspaceRoot: '/d', routing: { default: true } },
    { channelId: 'ch', workspaceRoot: '/e', routing: { default: true } },
  ];
  const hit = router.match({ event: { conversationId: 'c-1', text: 'hi' }, refs });
  assert.equal(hit.ref.workspaceRoot, '/d');
  assert.equal(hit.reason, 'default-multiple');
});

test('channel: router returns null on no match', () => {
  const router = createRouter();
  const hit = router.match({ event: { conversationId: 'c-1', text: 'x' }, refs: [] });
  assert.equal(hit, null);
});

test('channel: normalizeChannel requires id, defaults enabled/state', () => {
  const ch = normalizeChannel({ id: 'wx-1', platform: 'weixin-clawbot' });
  assert.equal(ch.id, 'wx-1');
  assert.equal(ch.enabled, true);
  assert.equal(ch.state, CHANNEL_STATES.DISCONNECTED);
  assert.throws(() => normalizeChannel({}), /requires an id/);
});

test('channel: parseProjectRefs parses .dsh/channels.json', () => {
  const refs = parseProjectRefs(JSON.stringify({ version: 1, refs: [{ channelId: 'wx-1', workspaceRoot: '/p' }] }));
  assert.equal(refs.length, 1);
  assert.equal(refs[0].workspaceRoot, '/p');
  assert.throws(() => parseProjectRefs('{}'), /refs/);
});

test('channel: manager routes, runs session driver, sends reply', async () => {
  let sent = null;
  const adapter = { channelId: 'wx-1', onEvent() {}, async send(c, r) { sent = r; } };
  const adapters = new Map([['wx-1', adapter]]);
  const refs = [{ channelId: 'wx-1', workspaceRoot: '/proj', routing: { conversations: ['conv-1'] } }];
  const sessionDriver = {
    async run(event, ref) { return { text: 'replied to ' + ref.workspaceRoot, media: null }; },
  };
  const mgr = createChannelManager({ adapters, refsByChannel: () => refs, sessionDriver });
  const res = await mgr.handleEvent(normalizeEvent({ channelId: 'wx-1', conversationId: 'conv-1', text: 'task' }));
  assert.equal(res.routed, true);
  assert.equal(res.ref.workspaceRoot, '/proj');
  assert.equal(res.reply.text, 'replied to /proj');
  assert.equal(sent.text, 'replied to /proj');
});

test('channel: manager replies unbounded hint when no route', async () => {
  let sent = null;
  const adapter = { channelId: 'wx-1', onEvent() {}, async send(c, r) { sent = r; } };
  const adapters = new Map([['wx-1', adapter]]);
  const mgr = createChannelManager({ adapters, refsByChannel: () => [], sessionDriver: null });
  const res = await mgr.handleEvent(normalizeEvent({ channelId: 'wx-1', conversationId: 'conv-x', text: 'hi' }));
  assert.equal(res.routed, false);
  assert.match(sent.text, /未绑定/);
});

test('channel: manager enqueue uses jobQueue (remote source)', async () => {
  const { createQueue } = require('../lib/jobqueue');
  const q = createQueue();
  const adapter = { channelId: 'wx-1', onEvent() {}, async send() {} };
  const sessionDriver = { async run() { return { text: 'done', media: null }; } };
  const mgr = createChannelManager({
    adapters: new Map([['wx-1', adapter]]),
    refsByChannel: () => [{ channelId: 'wx-1', workspaceRoot: '/p', routing: { conversations: ['c'] } }],
    sessionDriver, jobQueue: q,
  });
  await mgr.enqueue(normalizeEvent({ channelId: 'wx-1', conversationId: 'c', text: 'go' }));
  const snap = q.snapshot();
  assert.equal(snap.jobs[0].source, 'remote');
  assert.equal(snap.jobs[0].state, 'done');
});
