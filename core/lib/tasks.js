'use strict';

/**
 * core/lib/tasks.js — issue-task association index persisted under
 * `<repoRoot>/.dsh/tasks/`.
 *
 * Two files:
 *   index.json  — repo-scoped, COMMITTED: issue → branch → PR → state
 *                 (shared across machines / teammates).
 *   local.json  — machine-scoped, GITIGNORED: adds sessionId (the current
 *                 dsh instance's session is not meaningful on other machines).
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

/** Record the dsh session id for an issue in the LOCAL (gitignored) overlay. */
function rememberSession(repoRoot, issueNumber, sessionId) {
  const local = loadLocal(repoRoot);
  local.sessions[String(issueNumber)] = { sessionId, updatedAt: new Date().toISOString() };
  saveLocal(repoRoot, local);
  return local;
}

/** Look up the session id recorded for an issue on THIS machine. */
function sessionForIssue(repoRoot, issueNumber) {
  const local = loadLocal(repoRoot);
  const entry = local.sessions[String(issueNumber)];
  return entry ? entry.sessionId : null;
}

/** All session ids recorded on this machine (for restart re-attachment). */
function allLocalSessions(repoRoot) {
  const local = loadLocal(repoRoot);
  return Object.entries(local.sessions).map(([issue, entry]) => ({
    issue: Number(issue),
    sessionId: entry.sessionId,
  }));
}

module.exports = {
  tasksDir,
  loadIndex,
  saveIndex,
  loadLocal,
  saveLocal,
  mergeTask,
  findTask,
  rememberSession,
  sessionForIssue,
  allLocalSessions,
};
