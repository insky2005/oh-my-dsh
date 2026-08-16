'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {
  tasksDir, loadIndex, saveIndex, loadLocal, saveLocal,
  mergeTask, findTask, rememberSession, sessionForIssue, allLocalSessions,
} = require('../lib/tasks');

function tempRepo() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'tasks-idx-'));
}

test('tasksDir creates .dsh/tasks under repo root', () => {
  const repo = tempRepo();
  const dir = tasksDir(repo);
  assert.ok(fs.existsSync(dir));
  assert.ok(dir.endsWith(path.join('.dsh', 'tasks')));
  fs.rmSync(repo, { recursive: true, force: true });
});

test('loadIndex returns fresh index when missing', () => {
  const repo = tempRepo();
  const index = loadIndex(repo);
  assert.equal(index.version, 1);
  assert.deepEqual(index.tasks, []);
  fs.rmSync(repo, { recursive: true, force: true });
});

test('mergeTask upserts by issue number, sorted', () => {
  const repo = tempRepo();
  mergeTask(repo, 12, { branch: 'fix/issue-12', state: 'running' });
  mergeTask(repo, 3, { branch: 'fix/issue-3', state: 'pending' });
  let index = loadIndex(repo);
  assert.deepEqual(index.tasks.map((t) => t.issue), [3, 12]);
  assert.equal(index.tasks[1].branch, 'fix/issue-12');

  // upsert: add prUrl to #12, keep branch
  mergeTask(repo, 12, { prUrl: 'https://github.com/o/r/pull/99', state: 'done' });
  index = loadIndex(repo);
  const t12 = findTask(repo, 12);
  assert.equal(t12.branch, 'fix/issue-12');
  assert.equal(t12.prUrl, 'https://github.com/o/r/pull/99');
  assert.equal(t12.state, 'done');
  fs.rmSync(repo, { recursive: true, force: true });
});

test('findTask returns null for unknown issue', () => {
  const repo = tempRepo();
  assert.equal(findTask(repo, 999), null);
  fs.rmSync(repo, { recursive: true, force: true });
});

test('local overlay: remember + look up session per issue', () => {
  const repo = tempRepo();
  rememberSession(repo, 12, 'session-abc');
  rememberSession(repo, 7, 'session-xyz');
  assert.equal(sessionForIssue(repo, 12), 'session-abc');
  assert.equal(sessionForIssue(repo, 7), 'session-xyz');
  assert.equal(sessionForIssue(repo, 99), null);

  const all = allLocalSessions(repo);
  assert.deepEqual(all.map((e) => e.issue), [7, 12]);
  assert.equal(all.find((e) => e.issue === 12).sessionId, 'session-abc');
  fs.rmSync(repo, { recursive: true, force: true });
});

test('local and index files are separate', () => {
  const repo = tempRepo();
  mergeTask(repo, 5, { branch: 'fix/issue-5' });
  rememberSession(repo, 5, 'session-5');
  // index.json must NOT contain sessionId; local.json must
  const indexJson = fs.readFileSync(path.join(tasksDir(repo), 'index.json'), 'utf8');
  const localJson = fs.readFileSync(path.join(tasksDir(repo), 'local.json'), 'utf8');
  assert.ok(!indexJson.includes('sessionId'));
  assert.ok(localJson.includes('session-5'));
  fs.rmSync(repo, { recursive: true, force: true });
});

test('saveIndex/loadIndex roundtrip preserves data', () => {
  const repo = tempRepo();
  const index = { version: 1, tasks: [{ issue: 1, branch: 'fix/issue-1', state: 'done' }] };
  saveIndex(repo, index);
  const loaded = loadIndex(repo);
  assert.deepEqual(loaded, index);
  fs.rmSync(repo, { recursive: true, force: true });
});
