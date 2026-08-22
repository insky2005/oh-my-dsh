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

test('runner: /status shows channel-state format', async () => {
  const runner = createCommandRunner({
    homeDir: '/Users/loie',
    getStatus: async () => ({
      channel: 'wx',
      connected: true,
      workspace: { code: 'w1', name: 'helloharness', path: '/Users/loie/code/helloharness' },
      session: { code: 's1', sessionId: 'sess-9', name: '会话甲' },
    }),
  });
  const res = await runner.run('/status');
  const text = res.text;
  assert.match(text, /通道：wx/);
  assert.match(text, /连接：已连接/);
  assert.match(text, /当前工作区：#w1 \(helloharness\), ~\/code\/helloharness/);
  assert.match(text, /当前会话：#s1 \(sess-9\), 会话甲/);
});

test('runner: /status falls back to n/a when no workspace/session', async () => {
  const runner = createCommandRunner({
    getStatus: async () => ({ channel: 'wx', connected: false, workspace: null, session: null }),
  });
  const res = await runner.run('/status');
  assert.match(res.text, /连接：未连接/);
  assert.match(res.text, /当前工作区：n\/a/);
  assert.match(res.text, /当前会话：n\/a/);
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

test('parseCommand: aliases /ses and /wks are recognized', () => {
  assert.deepEqual(parseCommand('/ses'), { kind: 'command', name: 'ses', args: [] });
  assert.deepEqual(parseCommand('/wks'), { kind: 'command', name: 'wks', args: [] });
});

test('/help lists global, then project, then quick-switch groups in order', async () => {
  const runner = createCommandRunner({});
  const res = await runner.run('/help');
  assert.equal(res.kind, 'reply');
  const text = res.text;
  const lines = text.split('\n');
  const pos = (s) => lines.findIndex((l) => l.includes(s));
  const g = pos('全局指令');
  const p = pos('项目指令');
  const q = pos('快捷指令');
  assert.ok(g >= 0 && p > g && q > p, 'groups must be in order: global < project < quick');

  // global order: help, ping, status, workspaces, wks
  const gi = ['/help —', '/ping —', '/status —', '/workspaces —', '/wks —'].map(pos);
  for (let i = 1; i < gi.length; i++) assert.ok(gi[i] > gi[i - 1], 'global command order broken at index ' + i);
  // project order: new, sessions, ses, switch
  const pi = ['/new ', '/sessions —', '/ses —', '/switch '].map(pos);
  for (let i = 1; i < pi.length; i++) assert.ok(pi[i] > pi[i - 1], 'project command order broken at index ' + i);
  // quick switch hint mentions #w1 and #s1
  assert.match(text, /#w1/);
  assert.match(text, /#s1/);
});

test('runner: /wks shows code #wN, name (title) and path', async () => {
  const runner = createCommandRunner({
    getWorkspaces: async () => [{ code: 'w1', name: 'Alpha', path: '/a' }, { code: 'w2', name: 'Beta', path: '/b' }],
  });
  const res = await runner.run('/wks');
  assert.match(res.text, /#w1 \(Alpha\): \/a/);
  assert.match(res.text, /#w2 \(Beta\): \/b/);
});

test('runner: /workspaces alias lists codes too', async () => {
  const runner = createCommandRunner({
    getWorkspaces: async () => [{ code: 'w1', name: 'Alpha', path: '/a' }],
  });
  const res = await runner.run('/workspaces');
  assert.match(res.text, /#w1 \(Alpha\): \/a/);
});

test('runner: /wks shortens home paths to ~ and uses title as name', async () => {
  const home = '/Users/alice';
  const runner = createCommandRunner({
    homeDir: home,
    getWorkspaces: async () => [
      { code: 'w1', name: 'repowikitest', path: home + '/code/repowikitest' },
      // no title -> falls back to basename, still ~-shortened
      { code: 'w2', path: home + '/code/helloharness' },
    ],
  });
  const res = await runner.run('/wks');
  assert.match(res.text, /#w1 \(repowikitest\): ~\/code\/repowikitest/);
  assert.match(res.text, /#w2 \(helloharness\): ~\/code\/helloharness/);
  assert.ok(!res.text.includes('/Users/alice'), 'must not leak the home path');
});

test('runner: /sessions and /ses show code #sN and name', async () => {
  const sessions = [{ sessionId: 's-1', name: '会话甲', projectRoot: '/p1' }, { sessionId: 's-2', name: '会话乙', projectRoot: '/p2' }];
  const deps = { getSessions: async () => sessions };
  const r1 = await createCommandRunner(deps).run('/sessions');
  assert.match(r1.text, /#s1\s+会话甲\s+\/p1/);
  assert.match(r1.text, /#s2\s+会话乙\s+\/p2/);
  const r2 = await createCommandRunner(deps).run('/ses');
  assert.match(r2.text, /#s1\s+会话甲/);
});

test('runner: /switch #sN resolves to that session', async () => {
  let target = null;
  const runner = createCommandRunner({
    getSessions: async () => [{ sessionId: 's-1', name: '会话甲' }, { sessionId: 's-2', name: '会话乙' }],
    switchSession: async (sel) => { target = sel; return { id: sel, name: '会话乙' }; },
  });
  const res = await runner.run('/switch #s2');
  assert.equal(target, 's-2');
  assert.match(res.text, /会话乙/);
});

test('runner: /switch #sN out of range -> not found', async () => {
  const runner = createCommandRunner({
    getSessions: async () => [{ sessionId: 's-1', name: '会话甲' }],
    switchSession: async (sel) => ({ id: sel, name: sel }),
  });
  const res = await runner.run('/switch #s9');
  assert.match(res.text, /找不到会话/);
});
