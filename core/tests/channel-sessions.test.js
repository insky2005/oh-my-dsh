'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const os = require('node:os');
const path = require('node:path');
const fs = require('node:fs');
const { createChannelSessions } = require('../lib/channel-sessions');

test('sessions: set/get/list persists to project .dsh', () => {
  const proj = fs.mkdtempSync(path.join(os.tmpdir(), 'proj-'));
  const store = createChannelSessions({ projectRoot: proj, channelId: 'wx-1' });
  store.setSession('conv-a', { sessionId: 's-1', projectRoot: proj, name: '对话A' });
  store.setSession('conv-b', { sessionId: 's-2', projectRoot: proj, name: '对话B' });
  assert.ok(fs.existsSync(store.sessionsFile), 'sessions file written');
  assert.match(store.sessionsFile, /proj-.*\/\.dsh\/channels\/wx-1\.sessions\.json/);
  assert.equal(store.getSession('conv-a').sessionId, 's-1');
  assert.equal(store.listSessions().length, 2);
  const store2 = createChannelSessions({ projectRoot: proj, channelId: 'wx-1' });
  assert.equal(store2.getSession('conv-b').sessionId, 's-2');
});

test('sessions: upsert same conversation updates without duplicate', () => {
  const proj = fs.mkdtempSync(path.join(os.tmpdir(), 'proj-'));
  const store = createChannelSessions({ projectRoot: proj, channelId: 'wx-1' });
  store.setSession('conv-a', { sessionId: 's-1' });
  store.setSession('conv-a', { sessionId: 's-2' });
  assert.equal(store.listSessions().length, 1);
  assert.equal(store.getSession('conv-a').sessionId, 's-2');
});

test('sessions: appendMessage persists and groups by conversation', () => {
  const proj = fs.mkdtempSync(path.join(os.tmpdir(), 'proj-'));
  const store = createChannelSessions({ projectRoot: proj, channelId: 'wx-1' });
  store.appendMessage({ conversationId: 'conv-a', sessionId: 's-1', dir: 'in', text: 'hi' });
  store.appendMessage({ conversationId: 'conv-a', sessionId: 's-1', dir: 'out', text: 'hello' });
  store.appendMessage({ conversationId: 'conv-b', sessionId: 's-2', dir: 'in', text: 'other' });
  assert.ok(fs.existsSync(store.messagesFile), 'messages file written');
  const a = store.listMessages('conv-a');
  assert.equal(a.length, 2);
  assert.equal(a[0].text, 'hi');
  assert.equal(a[1].dir, 'out');
  const b = store.listMessages('conv-b');
  assert.equal(b.length, 1);
  assert.equal(b[0].text, 'other');
  const store2 = createChannelSessions({ projectRoot: proj, channelId: 'wx-1' });
  assert.equal(store2.listMessages('conv-a').length, 2);
});

test('sessions: files live under project .dsh/channels', () => {
  const store = createChannelSessions({ projectRoot: '/tmp/fake-proj', channelId: 'wx-9' });
  assert.equal(store.sessionsFile, '/tmp/fake-proj/.dsh/channels/wx-9.sessions.json');
  assert.equal(store.messagesFile, '/tmp/fake-proj/.dsh/channels/wx-9.messages.json');
});
