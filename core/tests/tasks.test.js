'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {
  tasksDir, loadIndex, saveIndex, loadLocal, saveLocal,
  mergeTask, findTask, rememberSession, sessionForIssue, allLocalSessions,
  loadManual, saveManual, mergeManualTask, findManualTask, removeManualTask,
  loadQueues, saveQueues, findQueue, upsertQueue, removeQueue, enqueueTask, dequeueTask,
  loadLocalState, normalizeSessionKey, rememberSessionById, sessionForTaskId,
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

// --- manual.json (the user's own tasks) ------------------------------------

test('manual tasks round-trip through manual.json', () => {
  const repo = tempRepo();
  mergeManualTask(repo, { id: 'manual-ab12cd34', title: 'Polish README', state: 'pending' });
  saveManual(repo, loadManual(repo).map((t) => ({ ...t, body: 'tidy the install section' })));
  const task = findManualTask(repo, 'manual-ab12cd34');
  assert.equal(task.title, 'Polish README');
  assert.equal(task.body, 'tidy the install section');
  assert.equal(findManualTask(repo, 'manual-nope'), null);
  fs.rmSync(repo, { recursive: true, force: true });
});

test('mergeManualTask upserts by id; removeManualTask deletes', () => {
  const repo = tempRepo();
  mergeManualTask(repo, { id: 'manual-aaaa0001', title: 'one', state: 'pending' });
  mergeManualTask(repo, { id: 'manual-aaaa0001', state: 'done' });
  mergeManualTask(repo, { id: 'manual-aaaa0002', title: 'two', state: 'pending' });
  let tasks = loadManual(repo);
  assert.equal(tasks.length, 2);
  assert.equal(tasks[0].title, 'one', 'upsert keeps the earlier fields');
  assert.equal(tasks[0].state, 'done');
  tasks = removeManualTask(repo, 'manual-aaaa0001');
  assert.deepEqual(tasks.map((t) => t.id), ['manual-aaaa0002']);
  fs.rmSync(repo, { recursive: true, force: true });
});

test('manual.json stays separate from the committed index', () => {
  const repo = tempRepo();
  mergeTask(repo, 9, { title: 'issue nine' });
  mergeManualTask(repo, { id: 'manual-bbbb0001', title: 'local only' });
  const indexJson = fs.readFileSync(path.join(tasksDir(repo), 'index.json'), 'utf8');
  const manualJson = fs.readFileSync(path.join(tasksDir(repo), 'manual.json'), 'utf8');
  assert.ok(!indexJson.includes('local only'));
  assert.ok(!manualJson.includes('issue nine'));
  fs.rmSync(repo, { recursive: true, force: true });
});

test('a missing or corrupt manual.json yields an empty list', () => {
  const repo = tempRepo();
  assert.deepEqual(loadManual(repo), []);
  fs.writeFileSync(path.join(tasksDir(repo), 'manual.json'), 'not json');
  assert.deepEqual(loadManual(repo), []);
  fs.writeFileSync(path.join(tasksDir(repo), 'manual.json'), '{ "tasks": 5 }');
  assert.deepEqual(loadManual(repo), []);
  fs.rmSync(repo, { recursive: true, force: true });
});

// --- queues.json (lanes and their FIFO order) -------------------------------

test('queues round-trip and upsert by id', () => {
  const repo = tempRepo();
  upsertQueue(repo, { id: 'q-1', name: 'Docs cleanup', branch: 'feature/docs-cleanup', state: 'paused' });
  upsertQueue(repo, { id: 'q-1', state: 'active' });
  upsertQueue(repo, { id: 'q-2', name: 'Second' });
  const queues = loadQueues(repo);
  assert.equal(queues.length, 2);
  assert.equal(queues[0].name, 'Docs cleanup', 'upsert keeps the earlier fields');
  assert.equal(queues[0].state, 'active');
  assert.deepEqual(queues[0].taskIds, [], 'taskIds default to an empty list');
  assert.equal(findQueue(repo, 'q-2').name, 'Second');
  assert.equal(findQueue(repo, 'missing'), null);
  fs.rmSync(repo, { recursive: true, force: true });
});

test('enqueueTask is FIFO and idempotent, dequeueTask removes', () => {
  const repo = tempRepo();
  upsertQueue(repo, { id: 'q-1', name: 'Lane' });
  assert.equal(enqueueTask(repo, 'manual-aaaa0001', 'q-1'), true);
  assert.equal(enqueueTask(repo, 'manual-aaaa0002', 'q-1'), true);
  assert.equal(enqueueTask(repo, 'manual-aaaa0001', 'q-1'), false, 'idempotent');
  assert.deepEqual(findQueue(repo, 'q-1').taskIds, ['manual-aaaa0001', 'manual-aaaa0002']);
  assert.equal(enqueueTask(repo, 'manual-aaaa0001', 'missing'), false, 'unknown queue');
  assert.equal(dequeueTask(repo, 'manual-aaaa0001'), true);
  assert.deepEqual(findQueue(repo, 'q-1').taskIds, ['manual-aaaa0002']);
  assert.equal(dequeueTask(repo, 'manual-aaaa0001'), false, 'already gone');
  assert.deepEqual(removeQueue(repo, 'q-1'), []);
  fs.rmSync(repo, { recursive: true, force: true });
});

test('enqueueTask moves a task between queues', () => {
  const repo = tempRepo();
  upsertQueue(repo, { id: 'q-1', name: 'A' });
  upsertQueue(repo, { id: 'q-2', name: 'B' });
  enqueueTask(repo, 'issue-7', 'q-1');
  enqueueTask(repo, 'issue-7', 'q-2');
  assert.deepEqual(findQueue(repo, 'q-1').taskIds, []);
  assert.deepEqual(findQueue(repo, 'q-2').taskIds, ['issue-7']);
  fs.rmSync(repo, { recursive: true, force: true });
});

// --- local.json (sessions, and the v1 numeric-key compatibility) ------------

test('normalizeSessionKey maps legacy numeric keys to task ids', () => {
  assert.equal(normalizeSessionKey('6'), 'issue-6');
  assert.equal(normalizeSessionKey('42'), 'issue-42');
  assert.equal(normalizeSessionKey('issue-6'), 'issue-6');
  assert.equal(normalizeSessionKey('manual-ab12cd34'), 'manual-ab12cd34');
});

test('rememberSession writes task id keys and still reads legacy ones', () => {
  const repo = tempRepo();
  rememberSession(repo, 5, 'session-5');
  const raw = JSON.parse(fs.readFileSync(path.join(tasksDir(repo), 'local.json'), 'utf8'));
  assert.ok(raw.sessions['issue-5'], 'writes the task id key');
  assert.equal(raw.sessions['5'], undefined, 'no numeric key is written');
  assert.equal(sessionForIssue(repo, 5), 'session-5');

  // a file written by v1 (numeric keys) stays readable, and is not rewritten
  saveLocal(repo, { sessions: { 8: { sessionId: 'session-old' } } });
  assert.equal(sessionForIssue(repo, 8), 'session-old');
  assert.equal(sessionForTaskId(repo, 'issue-8'), 'session-old');
  fs.rmSync(repo, { recursive: true, force: true });
});

test('manual task sessions use the same local overlay', () => {
  const repo = tempRepo();
  rememberSessionById(repo, 'manual-ab12cd34', 'session-m');
  assert.equal(sessionForTaskId(repo, 'manual-ab12cd34'), 'session-m');
  assert.deepEqual(allLocalSessions(repo),
                   [{ taskId: 'manual-ab12cd34', issue: null, sessionId: 'session-m' }]);
  fs.rmSync(repo, { recursive: true, force: true });
});

test('loadLocalState keeps the active queue and drops malformed entries', () => {
  const repo = tempRepo();
  saveLocal(repo, {
    sessions: {
      3: { sessionId: 'session-3' },
      'manual-ffff0001': { sessionId: 'session-m' },
      'issue-4': {},
    },
    activeQueueId: 'q-9',
    runningTaskId: 'issue-3',
  });
  const state = loadLocalState(repo);
  assert.deepEqual(Object.keys(state.sessions).sort(), ['issue-3', 'manual-ffff0001']);
  assert.equal(state.activeQueueId, 'q-9');
  assert.equal(state.runningTaskId, 'issue-3');
  fs.rmSync(repo, { recursive: true, force: true });
});

