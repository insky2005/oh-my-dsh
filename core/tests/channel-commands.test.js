'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { parseCommand, createCommandRunner, helpText, KNOWN } = require('../lib/channel-commands');

test('parseCommand: known command is recognized', () => {
  assert.deepEqual(parseCommand('/help'), { kind: 'command', name: 'help', args: [] });
  assert.deepEqual(parseCommand('/new  我的项目 '), { kind: 'command', name: 'new', args: ['我的项目'] });
  assert.deepEqual(parseCommand('/switch 3'), { kind: 'command', name: 'switch', args: ['3'] });
});

test('parseCommand: ordinary text and paths are NOT commands', () => {
  assert.equal(parseCommand('hello world').kind, 'text');
  assert.equal(parseCommand('/Users/loie/file').kind, 'unknown'); // path-like
  assert.equal(parseCommand('').kind, 'text');
});

test('parseCommand: unknown /cmd is reported as unknown', () => {
  const r = parseCommand('/bogus args');
  assert.equal(r.kind, 'unknown');
  assert.equal(r.name, 'bogus');
});

test('runner: /help lists known commands', async () => {
  const runner = createCommandRunner({});
  const res = await runner.run('/help');
  assert.equal(res.kind, 'reply');
  assert.match(res.text, /\/new/);
  assert.match(res.text, /\/ping/);
});

test('runner: /ping replies pong', async () => {
  const runner = createCommandRunner({});
  const res = await runner.run('/ping');
  assert.match(res.text, /^pong/);
});

test('runner: /new calls createSession', async () => {
  let called = null;
  const runner = createCommandRunner({
    createSession: async (name) => { called = name; return { id: 's-1', name }; },
  });
  const res = await runner.run('/new 我的会话');
  assert.equal(called, '我的会话');
  assert.match(res.text, /我的会话/);
});

test('runner: /sessions lists sessions', async () => {
  const runner = createCommandRunner({
    getSessions: async () => [{ name: 'a', projectRoot: '/p1' }, { name: 'b', projectRoot: '/p2' }],
  });
  const res = await runner.run('/sessions');
  assert.match(res.text, /a/);
  assert.match(res.text, /b/);
});

test('runner: /sessions empty -> hint', async () => {
  const runner = createCommandRunner({ getSessions: async () => [] });
  const res = await runner.run('/sessions');
  assert.match(res.text, /还没有会话/);
});

test('runner: /switch calls switchSession with selector', async () => {
  let sel = null;
  const runner = createCommandRunner({
    switchSession: async (s) => { sel = s; return { name: '目标会话' }; },
  });
  const res = await runner.run('/switch 目标会话');
  assert.equal(sel, '目标会话');
  assert.match(res.text, /目标会话/);
});

test('runner: /switch without arg -> usage', async () => {
  const runner = createCommandRunner({ switchSession: async () => ({}) });
  const res = await runner.run('/switch');
  assert.match(res.text, /用法/);
});

test('runner: /status shows fields', async () => {
  const runner = createCommandRunner({
    getStatus: async () => ({ connected: true, project: '/proj', session: 's-9', channel: 'wx' }),
  });
  const res = await runner.run('/status');
  assert.match(res.text, /已连接/);
  assert.match(res.text, /\/proj/);
  assert.match(res.text, /s-9/);
});

test('runner: unknown command replied with hint', async () => {
  const runner = createCommandRunner({});
  const res = await runner.run('/bogus');
  assert.match(res.text, /未知指令/);
});

test('runner: ordinary text passes through as text', async () => {
  const runner = createCommandRunner({});
  const res = await runner.run('请帮我看看');
  assert.equal(res.kind, 'text');
});

test('KNOWN table has the six first-priority commands', () => {
  for (const name of ['help', 'new', 'sessions', 'switch', 'status', 'ping']) {
    assert.ok(KNOWN[name], 'missing ' + name);
  }
});
