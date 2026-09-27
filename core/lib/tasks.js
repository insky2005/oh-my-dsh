'use strict';

/**
 * core/lib/tasks.js — issue-task association index persisted under
 * `<repoRoot>/.dsh/tasks/`.
 *
 * Four files, one job each (docs/issue-runner-design.md §V2-4):
 *   index.json   — repo-scoped, COMMITTED: issue → branch → PR → state
 *                  (shared across machines / teammates; the v1 shape, kept).
 *   manual.json  — machine-scoped, GITIGNORED: the user's own tasks.
 *   queues.json  — machine-scoped, GITIGNORED: queue definitions + FIFO order.
 *   local.json   — machine-scoped, GITIGNORED: task id → dsh sessionId (the
 *                  current instance's session is not meaningful elsewhere) plus
 *                  the last active queue. v1 keyed sessions by ISSUE NUMBER;
 *                  reading accepts both and nothing is rewritten on load.
 *
 * This is the "association index" that lets you locate the dsh session (and
 * branch / PR) for any issue, and recover task state after an app restart.
 * Pure JSON I/O + merge logic — no network, testable headlessly.
 */

const fs = require('node:fs');
const path = require('node:path');

/** Resolve `.dsh/tasks` under a repo root; creates it if missing. */
function tasksDir(repoRoot) {
  const dir = path.join(repoRoot, '.dsh', 'tasks');
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

const INDEX_FILE = 'index.json';
const LOCAL_FILE = 'local.json';
const MANUAL_FILE = 'manual.json';
const QUEUES_FILE = 'queues.json';

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

function writeJson(file, obj) {
  fs.writeFileSync(file, JSON.stringify(obj, null, 2) + '\n', 'utf8');
}

/** Empty index shape. */
function emptyIndex() {
  return { version: 1, tasks: [] };
}

/** Load the committed index (or a fresh one if missing/corrupt). */
function loadIndex(repoRoot) {
  return readJson(path.join(tasksDir(repoRoot), INDEX_FILE), emptyIndex());
}

/** Load the local (machine-scoped) overlay. */
function loadLocal(repoRoot) {
  return readJson(path.join(tasksDir(repoRoot), LOCAL_FILE), { sessions: {} });
}

/** Write the committed index. */
function saveIndex(repoRoot, index) {
  writeJson(path.join(tasksDir(repoRoot), INDEX_FILE), index);
}

/** Write the local overlay. */
function saveLocal(repoRoot, local) {
  writeJson(path.join(tasksDir(repoRoot), LOCAL_FILE), local);
}

/**
 * Merge an update into the index (upsert by issue number). `update` may carry
 * any subset of { branch, prUrl, prNumber, state, error, startedAt, finishedAt }.
 * Returns the new index.
 */
function mergeTask(repoRoot, issueNumber, update) {
  const index = loadIndex(repoRoot);
  const idx = index.tasks.findIndex((t) => t.issue === issueNumber);
  const base = idx >= 0 ? index.tasks[idx] : { issue: issueNumber };
  const merged = { ...base, ...update, issue: issueNumber };
  if (idx >= 0) index.tasks[idx] = merged;
  else index.tasks.push(merged);
  index.tasks.sort((a, b) => a.issue - b.issue);
  saveIndex(repoRoot, index);
  return index;
}

/** Find a task by issue number from the committed index. */
function findTask(repoRoot, issueNumber) {
  const index = loadIndex(repoRoot);
  return index.tasks.find((t) => t.issue === issueNumber) || null;
}

// ---------------------------------------------------------------------------
// manual.json — the user's own tasks (machine-scoped)
// ---------------------------------------------------------------------------

/** A fresh index shape for manual.json. */
function emptyManual() {
  return { version: 1, tasks: [] };
}

/** Load the manual tasks (or an empty list when missing/corrupt). */
function loadManual(repoRoot) {
  const obj = readJson(path.join(tasksDir(repoRoot), MANUAL_FILE), emptyManual());
  if (!Array.isArray(obj.tasks)) return [];
  return obj.tasks.filter((t) => t && typeof t.id === 'string');
}

/** Write the manual tasks. */
function saveManual(repoRoot, tasks) {
  writeJson(path.join(tasksDir(repoRoot), MANUAL_FILE), { version: 1, tasks });
}

/** Upsert one manual task by id. */
function mergeManualTask(repoRoot, task) {
  if (!task || typeof task.id !== 'string') throw new Error('mergeManualTask needs a task id');
  const tasks = loadManual(repoRoot);
  const idx = tasks.findIndex((t) => t.id === task.id);
  if (idx >= 0) tasks[idx] = { ...tasks[idx], ...task };
  else tasks.push(task);
  saveManual(repoRoot, tasks);
  return tasks;
}

/** Find a manual task by id. */
function findManualTask(repoRoot, id) {
  return loadManual(repoRoot).find((t) => t.id === id) || null;
}

/** Remove a manual task by id; returns what is left. */
function removeManualTask(repoRoot, id) {
  const kept = loadManual(repoRoot).filter((t) => t.id !== id);
  saveManual(repoRoot, kept);
  return kept;
}

// ---------------------------------------------------------------------------
// queues.json — lane definitions and their FIFO order (machine-scoped)
// ---------------------------------------------------------------------------

/** Load the queues (or an empty list when missing/corrupt). */
function loadQueues(repoRoot) {
  const obj = readJson(path.join(tasksDir(repoRoot), QUEUES_FILE), { version: 1, queues: [] });
  if (!Array.isArray(obj.queues)) return [];
  return obj.queues.filter((q) => q && typeof q.id === 'string');
}

/** Write the queues. */
function saveQueues(repoRoot, queues) {
  writeJson(path.join(tasksDir(repoRoot), QUEUES_FILE), { version: 1, queues });
}

/** Find a queue by id. */
function findQueue(repoRoot, id) {
  return loadQueues(repoRoot).find((q) => q.id === id) || null;
}

/** Upsert one queue by id (taskIds default to an empty list). */
function upsertQueue(repoRoot, queue) {
  if (!queue || typeof queue.id !== 'string') throw new Error('upsertQueue needs a queue id');
  const queues = loadQueues(repoRoot);
  const idx = queues.findIndex((q) => q.id === queue.id);
  const base = idx >= 0 ? queues[idx] : { taskIds: [], state: 'paused', autoCreated: false, autoPR: false, baseBranch: 'main' };
  const merged = { ...base, ...queue, id: queue.id, taskIds: queue.taskIds || base.taskIds || [] };
  if (idx >= 0) queues[idx] = merged;
  else queues.push(merged);
  saveQueues(repoRoot, queues);
  return merged;
}

/** Remove a queue by id; returns what is left. */
function removeQueue(repoRoot, id) {
  const kept = loadQueues(repoRoot).filter((q) => q.id !== id);
  saveQueues(repoRoot, kept);
  return kept;
}

/**
 * Append a task to a queue (FIFO). Moving a task that already sits in another
 * queue moves it out first. Idempotent for the same queue (returns false).
 */
function enqueueTask(repoRoot, taskId, queueId) {
  const queues = loadQueues(repoRoot);
  const queue = queues.find((q) => q.id === queueId);
  if (!queue) return false;
  if (!Array.isArray(queue.taskIds)) queue.taskIds = [];
  for (const other of queues) {
    if (other.id === queueId || !Array.isArray(other.taskIds)) continue;
    other.taskIds = other.taskIds.filter((id) => id !== taskId);
  }
  if (queue.taskIds.includes(taskId)) {
    saveQueues(repoRoot, queues);
    return false;
  }
  queue.taskIds.push(taskId);
  saveQueues(repoRoot, queues);
  return true;
}

/** Take a task out of every queue (the 移出队列 action). */
function dequeueTask(repoRoot, taskId) {
  const queues = loadQueues(repoRoot);
  let removed = false;
  for (const queue of queues) {
    if (!Array.isArray(queue.taskIds)) continue;
    const kept = queue.taskIds.filter((id) => id !== taskId);
    if (kept.length !== queue.taskIds.length) {
      queue.taskIds = kept;
      removed = true;
    }
  }
  saveQueues(repoRoot, queues);
  return removed;
}

// ---------------------------------------------------------------------------
// local.json — sessions (task id → sessionId) and the last active queue
// ---------------------------------------------------------------------------

/** v1 keyed sessions by ISSUE NUMBER ("6"); v2 keys them by task id. */
function normalizeSessionKey(key) {
  return /^[0-9]+$/.test(key) ? `issue-${key}` : key;
}

/** The local overlay with session keys normalised to task ids. */
function loadLocalState(repoRoot) {
  const local = loadLocal(repoRoot);
  const sessions = {};
  for (const [key, entry] of Object.entries(local.sessions || {})) {
    if (!entry || typeof entry.sessionId !== 'string') continue;
    sessions[normalizeSessionKey(key)] = {
      sessionId: entry.sessionId,
      updatedAt: entry.updatedAt || null,
    };
  }
  return {
    sessions,
    activeQueueId: local.activeQueueId || null,
    runningTaskId: local.runningTaskId || null,
  };
}

/** Write the local overlay back (always with task id session keys). */
function saveLocalState(repoRoot, state) {
  const sessions = {};
  for (const [id, entry] of Object.entries(state.sessions || {})) {
    sessions[id] = { sessionId: entry.sessionId, updatedAt: entry.updatedAt || new Date().toISOString() };
  }
  const out = { sessions };
  if (state.activeQueueId) out.activeQueueId = state.activeQueueId;
  if (state.runningTaskId) out.runningTaskId = state.runningTaskId;
  saveLocal(repoRoot, out);
  return out;
}

/** Record the dsh session id of a task (issue-N or manual-…) on this machine. */
function rememberSessionById(repoRoot, taskId, sessionId) {
  const state = loadLocalState(repoRoot);
  state.sessions[taskId] = { sessionId, updatedAt: new Date().toISOString() };
  saveLocalState(repoRoot, state);
  return state;
}

/** Look up the session id recorded for a task id on THIS machine. */
function sessionForTaskId(repoRoot, taskId) {
  const entry = loadLocalState(repoRoot).sessions[taskId];
  return entry ? entry.sessionId : null;
}

/** Record the session id for an issue (writes the issue-N task id key). */
function rememberSession(repoRoot, issueNumber, sessionId) {
  return rememberSessionById(repoRoot, `issue-${issueNumber}`, sessionId);
}

/** Look up the session id recorded for an issue on THIS machine. */
function sessionForIssue(repoRoot, issueNumber) {
  return sessionForTaskId(repoRoot, `issue-${issueNumber}`);
}

/** All session ids recorded on this machine (for restart re-attachment). */
function allLocalSessions(repoRoot) {
  const entries = Object.entries(loadLocalState(repoRoot).sessions).map(([taskId, entry]) => {
    const match = /^issue-([0-9]+)$/.exec(taskId);
    return { taskId, issue: match ? Number(match[1]) : null, sessionId: entry.sessionId };
  });
  entries.sort((a, b) => {
    if (a.issue === b.issue) return a.taskId.localeCompare(b.taskId);
    if (a.issue === null) return 1;
    if (b.issue === null) return -1;
    return a.issue - b.issue;
  });
  return entries;
}

module.exports = {
  // index.json (committed, v1 shape)
  tasksDir,
  loadIndex,
  saveIndex,
  mergeTask,
  findTask,
  // manual.json (machine-scoped)
  loadManual,
  saveManual,
  mergeManualTask,
  findManualTask,
  removeManualTask,
  // queues.json (machine-scoped)
  loadQueues,
  saveQueues,
  findQueue,
  upsertQueue,
  removeQueue,
  enqueueTask,
  dequeueTask,
  // local.json (machine-scoped)
  loadLocal,
  saveLocal,
  loadLocalState,
  saveLocalState,
  normalizeSessionKey,
  rememberSession,
  rememberSessionById,
  sessionForIssue,
  sessionForTaskId,
  allLocalSessions,
};
