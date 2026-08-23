'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const os = require('node:os');
const path = require('node:path');
const fs = require('node:fs');
const { createChannelSessions, workspaceKey, channelsDir } = require('../lib/channel-sessions');

const HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'sess-home-'));

test('sessions: set/get/list persists to global channel sessions.json', () => {
  const store = createChannelSessions({ channelId: 'wx-1', dshHome: HOME });
  store.setSession('conv-a', { sessionId: 's-1', projectRoot: '/p/a', name: '对话A' });
  store.setSession('conv-b', { sessionId: 's-2', projectRoot: '/p/a', name: '对话B' });
  assert.ok(fs.existsSync(store.sessionsFile), 'global sessions file written');
  assert.match(store.sessionsFile, /wx-1\.sessions\.json$/);
  assert.equal(store.getSession('conv-a').sessionId, 's-1');
  assert.equal(store.listSessions().length, 2);
  const store2 = createChannelSessions({ channelId: 'wx-1', dshHome: HOME });
  assert.equal(store2.getSession('conv-b').sessionId, 's-2');
});

test('sessions: re-binding a conversation keeps BOTH sessions in history (panel lists all)', () => {
  const store = createChannelSessions({ channelId: 'wx-upsert', dshHome: HOME });
  store.setSession('conv-a', { sessionId: 's-1' });
  store.setSession('conv-a', { sessionId: 's-2' });
  // history preserved — both sessions remain listable (e.g. after /new)
  assert.equal(store.listSessions().length, 2);
  // the conversation points to the latest session
  assert.equal(store.getSession('conv-a').sessionId, 's-2');
  // the previous session is no longer bound to the conversation but still exists
  assert.equal(store.listSessions().find((s) => s.sessionId === 's-1').conversationId, null);
});

test('sessions: distinct conversations have their own active sessions, all listed', () => {
  const store = createChannelSessions({ channelId: 'wx-multi', dshHome: HOME });
  store.setSession('conv-a', { sessionId: 's-1', projectRoot: '/p' });
  store.setSession('conv-b', { sessionId: 's-2', projectRoot: '/p' });
  assert.equal(store.getSession('conv-a').sessionId, 's-1');
  assert.equal(store.getSession('conv-b').sessionId, 's-2');
  assert.equal(store.listSessions().length, 2);
});

test('sessions: appendMessage writes per-session buckets under global channels dir', () => {
  const store = createChannelSessions({ channelId: 'wx-2', dshHome: HOME });
  store.appendMessage({ conversationId: 'conv-a', sessionId: 's-1', dir: 'in', text: 'hi', projectRoot: '/Users/loie/repo/alpha' });
  store.appendMessage({ conversationId: 'conv-a', sessionId: 's-1', dir: 'out', text: 'hello', projectRoot: '/Users/loie/repo/alpha' });
  store.appendMessage({ conversationId: 'conv-b', sessionId: 's-2', dir: 'in', text: 'other', projectRoot: '/Users/loie/repo/alpha' });
  store.appendMessage({ conversationId: 'conv-c', sessionId: null, dir: 'in', text: '/help', projectRoot: '/Users/loie/repo/alpha' });
  // no project dir pollution
  assert.ok(!fs.existsSync('/Users/loie/repo/alpha/.dsh/channels/wx-2.sessions.json'));
  // buckets under global channels dir
  assert.ok(fs.existsSync(path.join(store.dir, 'wx-2.alpha.s-1.messages.json')), 'session bucket written');
  assert.ok(fs.existsSync(path.join(store.dir, 'wx-2.alpha.s-2.messages.json')), 'second session bucket written');
  assert.ok(fs.existsSync(path.join(store.dir, 'wx-2.alpha.system.messages.json')), 'system bucket written');
  const a = store.listMessages('conv-a');
  assert.equal(a.length, 2);
  assert.equal(a[0].text, 'hi');
  assert.equal(a[1].dir, 'out');
  const b = store.listMessages('conv-b');
  assert.equal(b.length, 1);
  assert.equal(b[0].text, 'other');
  const c = store.listMessages('conv-c');
  assert.equal(c.length, 1);
  assert.equal(c[0].sessionId, null);
  // reload from a fresh store on the same channel
  const store2 = createChannelSessions({ channelId: 'wx-2', dshHome: HOME });
  assert.equal(store2.listMessages('conv-a').length, 2);
});

test('sessions: appendMessage without projectRoot falls back to mapping/default', () => {
  const store = createChannelSessions({ channelId: 'wx-3', dshHome: HOME, defaultProjectRoot: '/Users/loie/repo/beta' });
  store.setSession('conv-x', { sessionId: 's-9', projectRoot: '/Users/loie/repo/beta' });
  // mapping fallback
  store.appendMessage({ conversationId: 'conv-x', sessionId: 's-9', dir: 'in', text: 'mapped' });
  // default fallback (no mapping)
  store.appendMessage({ conversationId: 'orphan', sessionId: null, dir: 'in', text: 'default' });
  assert.equal(store.listMessages('conv-x').length, 1);
  assert.equal(store.listMessages('orphan').length, 1);
});

test('sessions: workspace key cleaning + duplicate disambiguation', () => {
  assert.equal(workspaceKey('/Users/loie/repo/alpha'), 'alpha');
  assert.equal(workspaceKey('/a b/c+d e'), 'c-d-e'); // basename, non-word -> '-'
  const store = createChannelSessions({ channelId: 'wx-4', dshHome: HOME });
  const k1 = store.registerProjectRoot('/Users/loie/repo/alpha');
  const k2 = store.registerProjectRoot('/Other/alpha');
  assert.equal(k1, 'alpha');
  assert.match(k2, /^alpha-[0-9a-f]{6}$/);
  // same root re-registers to its original key
  assert.equal(store.registerProjectRoot('/Users/loie/repo/alpha'), 'alpha');
});