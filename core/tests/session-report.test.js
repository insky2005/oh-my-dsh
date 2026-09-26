// Session report extraction (the tasks panel's 交接简报).
//
// The panel keeps ONE session per task (so each context stays small) and hands the
// next task a brief built from the previous one's final report. That report is the
// LAST `assistant/message` text of the session — not truncated, not summarised.
// These tests use a PLAINTEXT session.jsonl fixture, so they need no zstd support
// (the app decodes .zstd through its bundled node).

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const core = require('../index.js');

function fixtureHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'ohmy-brief-'));
  return home;
}

function writeSession(home, slug, id, events) {
  const dir = path.join(home, 'sessions', slug, id);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'session.jsonl'),
    events.map((e) => JSON.stringify(e)).join('\n') + '\n');
  return dir;
}

function assistant(text, turn = 1, step = 1) {
  return { type: 'assistant/message', seq: 1, data: { turn, step, message: { role: 'assistant', content: [{ type: 'text', text }] } } };
}

test('sessionReport returns the LAST assistant text, not the first', () => {
  const home = fixtureHome();
  writeSession(home, '--tmp-proj--', 'session-one', [
    { type: 'session', id: 'session-one', cwd: '/tmp/proj', createdAt: '2026-09-27T00:00:00Z' },
    assistant('先看一眼仓库结构。', 1, 1),
    { type: 'tool/call', data: { name: 'bash', callId: 'c1', turn: 1, step: 2 } },
    assistant('已完成：抽出了 TokenStore，测试通过。', 1, 3),
  ]);
  const report = core.sessionReport({ sessionId: 'session-one', dshHome: home });
  assert.equal(report.text, '已完成：抽出了 TokenStore，测试通过。');
  assert.equal(report.count, 2);
  assert.equal(report.cwd, '/tmp/proj');
});

test('sessionReport ignores chunk events and empty messages', () => {
  const home = fixtureHome();
  writeSession(home, '--tmp-proj--', 'session-two', [
    { type: 'session', id: 'session-two', cwd: '/tmp/proj' },
    { type: 'assistant/chunk', data: { chunk: { type: 'block-start', index: 0 } } },
    { type: 'text-chunks', data: { texts: ['半', '句', '话'] } },
    { type: 'assistant/message', data: { turn: 1, step: 1, message: { role: 'assistant', content: [] } } },
    assistant('真正的汇报', 1, 2),
  ]);
  const report = core.sessionReport({ sessionId: 'session-two', dshHome: home });
  assert.equal(report.text, '真正的汇报');
  assert.equal(report.count, 1, '流式分片不算一条汇报');
});

test('a session whose agent never spoke has no report (but is still found)', () => {
  const home = fixtureHome();
  writeSession(home, '--tmp-proj--', 'session-three', [
    { type: 'session', id: 'session-three', cwd: '/tmp/proj' },
    { type: 'user/message', data: { source: { kind: 'user' }, content: [{ type: 'text', text: '干点活' }] } },
  ]);
  const report = core.sessionReport({ sessionId: 'session-three', dshHome: home });
  assert.equal(report.text, null, '没有汇报就是 null —— 简报里会写成「没有留下汇报」');
  assert.equal(report.count, 0);
  assert.ok(report.file, '会话本身仍然找到了');
});

test('an unknown session reports nothing and says so', () => {
  const home = fixtureHome();
  const report = core.sessionReport({ sessionId: 'session-nope', dshHome: home });
  assert.equal(report.text, null);
  assert.equal(report.file, null);
  assert.ok(report.diagnostics.some((d) => d.code === 'session-not-found'));
});

test('sessionReport is not truncated', () => {
  const home = fixtureHome();
  const long = 'A'.repeat(20000) + ' 结尾';
  writeSession(home, '--tmp-proj--', 'session-long', [
    { type: 'session', id: 'session-long', cwd: '/tmp/proj' },
    assistant(long, 1, 1),
  ]);
  const report = core.sessionReport({ sessionId: 'session-long', dshHome: home });
  assert.equal(report.text.length, long.length, '汇报原样带过去（截断会失真）');
  assert.ok(report.text.endsWith('结尾'));
});
