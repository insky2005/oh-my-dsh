'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { parseCommand, createCommandRunner, helpText, KNOWN } = require('../lib/channel-commands');

test('parseCommand: known command is recognized', () => {
  assert.deepEqual(parseCommand('/help'), { kind: 'command', name: 'help', args: [] });
  assert.deepEqual(parseCommand('/new  我的项目 '), { kind: 'command', name: 'new', args: ['我的项目'] });
  assert.deepEqual(parseCommand('/workspaces Alpha'), { kind: 'command', name: 'workspaces', args: ['Alpha'] });
  assert.deepEqual(parseCommand('/sessions #s2'), { kind: 'command', name: 'sessions', args: ['#s2'] });
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

test('parseCommand: aliases /ses and /wks are recognized', () => {
  assert.deepEqual(parseCommand('/ses'), { kind: 'command', name: 'ses', args: [] });
  assert.deepEqual(parseCommand('/wks'), { kind: 'command', name: 'wks', args: [] });
});

test('KNOWN table has the v2 command set + aliases, no /switch', () => {
  for (const name of ['help', 'ping', 'status', 'workspaces', 'wks', 'sessions', 'ses', 'new']) {
    assert.ok(KNOWN[name], 'missing ' + name);
  }
  assert.ok(!KNOWN.switch, '/switch must be removed');
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

test('runner: /new uses createSession unified reply', async () => {
  const runner = createCommandRunner({
    createSession: async (c) => ({ id: 's-1', reply: '创建新会话 #s1 (s-1)\n请继续与我对话，我正在听...' }),
  });
  const res = await runner.run('/new');
  assert.match(res.text, /创建新会话 #s1 \(s-1\)/);
  assert.match(res.text, /请继续与我对话/);
});

test('runner: /new <内容> also uses the unified createSession reply', async () => {
  let called = null;
  const runner = createCommandRunner({
    createSession: async (c) => { called = c; return { id: 's-2', reply: '创建新会话 #s1 (s-2)' }; },
  });
  const res = await runner.run('/new 打开百度');
  assert.equal(called, '打开百度');
  assert.match(res.text, /创建新会话 #s1 \(s-2\)/);
});

test('runner: /sessions lists sessions', async () => {
  const runner = createCommandRunner({
    getSessions: async () => [{ sessionId: 's-1', name: 'a' }, { sessionId: 's-2', name: 'b' }],
  });
  const res = await runner.run('/sessions');
  assert.match(res.text, /#s1 \(s-1\), a/);
  assert.match(res.text, /#s2 \(s-2\), b/);
  assert.match(res.text, /会话列表：/);
});

test('runner: /sessions empty -> hint', async () => {
  const runner = createCommandRunner({ getSessions: async () => [] });
  const res = await runner.run('/sessions');
  assert.match(res.text, /还没有会话/);
});

test('runner: /sessions <内容> switches session and binds conversation', async () => {
  let bound = null;
  const runner = createCommandRunner({
    getSessions: async () => [{ sessionId: 's-1', name: '会话甲' }, { sessionId: 's-2', name: '会话乙' }],
    switchSession: async (sel) => ({ id: 's-2', name: '会话乙', projectRoot: '/p' }),
    bindSession: async (cid, rec) => { bound = { cid, rec }; },
  });
  const res = await runner.run('/sessions 会话乙', { conversationId: 'conv-9' });
  assert.match(res.text, /已切换到会话 #s2 \(s-2\), 会话乙/);
  assert.deepEqual(bound, { cid: 'conv-9', rec: { sessionId: 's-2', projectRoot: '/p', name: '会话乙' } });
});

test('runner: /ses <内容> switches via switchSession too', async () => {
  let sel = null;
  const runner = createCommandRunner({
    getSessions: async () => [{ sessionId: 's-1', name: '会话甲' }, { sessionId: 's-2', name: '会话乙' }],
    switchSession: async (s) => { sel = s; return { id: 's-2', name: '会话乙', projectRoot: '/p' }; },
  });
  const res = await runner.run('/ses #s2');
  assert.equal(sel, '#s2');
  assert.match(res.text, /已切换到会话 #s2/);
});

test('runner: /sessions <内容> not found -> hint', async () => {
  const runner = createCommandRunner({ switchSession: async () => { throw new Error('找不到会话：xxx'); } });
  const res = await runner.run('/sessions xxx');
  assert.match(res.text, /找不到会话/);
});

test('runner: /workspaces lists workspaces', async () => {
  const runner = createCommandRunner({
    getWorkspaces: async () => [{ code: 'w1', name: 'Alpha', path: '/a' }, { code: 'w2', name: 'Beta', path: '/b' }],
  });
  const res = await runner.run('/workspaces');
  assert.match(res.text, /#w1 \(Alpha\): \/a/);
  assert.match(res.text, /#w2 \(Beta\): \/b/);
});

test('runner: /workspaces <内容> switches workspace', async () => {
  const runner = createCommandRunner({
    homeDir: '/Users/loie',
    switchWorkspace: async () => ({ code: 'w1', name: 'Alpha', path: '/Users/loie/repo/alpha', recent: [{ sessionId: 's-1', name: '会话甲' }] }),
  });
  const res = await runner.run('/workspaces Alpha');
  assert.match(res.text, /已切换到工作区 #w1 \(Alpha\), ~\/repo\/alpha/);
  assert.match(res.text, /当前会话：n\/a/);
  assert.match(res.text, /#s1 \(s-1\), 会话甲/);
});

test('runner: /workspaces <内容> failure surfaces the message', async () => {
  const runner = createCommandRunner({ switchWorkspace: async () => { throw new Error('未找到工作区：Beta（/wks 或 /workspaces 查看）'); } });
  const res = await runner.run('/workspaces Beta');
  assert.match(res.text, /未找到工作区/);
});

test('runner: /wks shortens home paths to ~ and uses title as name', async () => {
  const home = '/Users/alice';
  const runner = createCommandRunner({
    homeDir: home,
    getWorkspaces: async () => [
      { code: 'w1', name: 'repowikitest', path: home + '/code/repowikitest' },
      { code: 'w2', path: home + '/code/helloharness' },
    ],
  });
  const res = await runner.run('/wks');
  assert.match(res.text, /#w1 \(repowikitest\): ~\/code\/repowikitest/);
  assert.match(res.text, /#w2 \(helloharness\): ~\/code\/helloharness/);
  assert.ok(!res.text.includes('/Users/alice'), 'must not leak the home path');
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

test('/help lists global, then workspace, then quick groups in order (no /switch)', async () => {
  const runner = createCommandRunner({});
  const res = await runner.run('/help');
  assert.equal(res.kind, 'reply');
  const text = res.text;
  const lines = text.split('\n');
  const pos = (s) => lines.findIndex((l) => l.includes(s));
  const g = pos('全局指令');
  const w = pos('工作区指令');
  const q = pos('快捷指令');
  assert.ok(g >= 0 && w > g && q > w, 'groups must be in order: global < workspace < quick');

  const gi = ['/help —', '/ping —', '/status —'].map(pos);
  for (let i = 1; i < gi.length; i++) assert.ok(gi[i] > gi[i - 1], 'global order broken at index ' + i);
  const wi = ['/workspaces、/wks', '/sessions、/ses', '/new '].map(pos);
  for (let i = 1; i < wi.length; i++) assert.ok(wi[i] > wi[i - 1], 'workspace order broken at index ' + i);

  assert.ok(!/\/switch/.test(text), '/switch must not appear in /help');
  assert.match(text, /#w1/);
  assert.match(text, /#s1/);
});

test('runner: /sessions and /ses show workspace header + recent 5, format #sN (id), title', async () => {
  const sessions = [
    { sessionId: 's-1', name: '会话甲' }, { sessionId: 's-2', name: '会话乙' },
    { sessionId: 's-3', name: '会话丙' }, { sessionId: 's-4', name: '会话丁' },
    { sessionId: 's-5', name: '会话戊' }, { sessionId: 's-6', name: '会话己' },
  ];
  const deps = {
    getSessions: async () => sessions,
    getStatus: async () => ({ workspace: { code: 'w1', name: 'Alpha', path: '/Users/loie/repo/alpha' } }),
    homeDir: '/Users/loie',
  };
  const r1 = await createCommandRunner(deps).run('/sessions');
  assert.match(r1.text, /工作区 #w1 \(Alpha\), ~\/repo\/alpha/);
  assert.match(r1.text, /会话列表：/);
  assert.match(r1.text, /#s1 \(s-1\), 会话甲/);
  assert.match(r1.text, /#s5 \(s-5\), 会话戊/);
  assert.ok(!r1.text.includes('s-6'), 'must be limited to 5 sessions');
  const r2 = await createCommandRunner(deps).run('/ses');
  assert.match(r2.text, /#s1 \(s-1\), 会话甲/);
});
