'use strict';

/**
 * core/lib/channel-sessions.js — channel-scoped session mapping + message log.
 *
 * Docs: docs/channel-storage.md (globalization, 2026-08-22), docs/channel-ui-commands.md §3.4/§3.8.
 *
 * Persisted under the GLOBAL channel dir (survives runner restarts, does NOT
 * pollute a project checkout — message content is not committed anywhere):
 *   ~/.dsh/channels/<channelId>.sessions.json                     — session mapping
 *   ~/.dsh/channels/<channelId>.workspaces.json                   — workspaceKey <-> projectRoot registry
 *   ~/.dsh/channels/<channelId>.<workspaceKey>.<sessionId>.messages.json  — per-session message archive
 *   ~/.dsh/channels/<channelId>.<workspaceKey>.system.messages.json       — sessionId=null (command/system) bucket
 *
 * Sessions map a (channelId, conversationId) to the active dsh session id, so
 * multi-turn chats keep one session until /new or /switch. Messages are an
 * append-only in/out log bucketed by (workspace, session).
 *
 *   const { createChannelSessions } = require('@oh-my-dsh/core');
 */

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');

/** Max messages kept per bucket file (decision E). */
const MAX_MESSAGES = 1000;

function channelsDir(dshHome) {
  return path.join(dshHome || process.env.DSH_HOME || path.join(os.homedir(), '.dsh'), 'channels');
}

/** Workspace key from a project root basename: keep A-Za-z0-9._- + CJK, else '-' (channel-storage.md §4). */
function workspaceKey(projectRoot) {
  if (!projectRoot) return '';
  const base = String(projectRoot).split(/[\\/]/).filter(Boolean).pop() || 'ws';
  let key = String(base).replace(/[^\w\u4e00-\u9fa5.-]/g, '-');
  if (!key) key = 'ws';
  if (key.length > 48) key = key.slice(0, 48);
  return key;
}

/** Suffix a key with a path hash when it is taken by a different projectRoot. */
function disambiguate(key, projectRoot, registry) {
  if (!registry[key] || registry[key] === projectRoot) return key;
  const h = crypto.createHash('sha1').update(projectRoot).digest('hex').slice(0, 6);
  return key + '-' + h;
}

function readJson(file, fallback) {
  try {
    if (!fs.existsSync(file)) return fallback;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

/**
 * Create a channel-scoped session + message store.
 * opts: { channelId, dshHome, defaultProjectRoot }.
 */
function createChannelSessions({ channelId, dshHome, defaultProjectRoot }) {
  if (!channelId) throw new Error('channel-sessions: channelId required');
  const dir = channelsDir(dshHome);
  const sessionsFile = path.join(dir, channelId + '.sessions.json');
  const workspacesFile = path.join(dir, channelId + '.workspaces.json');
  // Channel-global system bucket for command/system messages that have NO project
  // context — they must NOT be scoped under a workspace key.
  const channelSystemFile = path.join(dir, channelId + '.system.messages.json');

  function ensureDir() { fs.mkdirSync(dir, { recursive: true }); }

  // ----- workspaceKey registry -----
  function loadWorkspaces() { return readJson(workspacesFile, {}) || {}; }
  function saveWorkspaces(reg) { try { ensureDir(); fs.writeFileSync(workspacesFile, JSON.stringify(reg, null, 2), 'utf8'); } catch { /* non-fatal */ } }
  /** Resolve the workspace key for a project root; persist=true writes it to the
   *  workspaces.json registry (only the project-view toggle / explicit registration). */
  function resolveKey(projectRoot, persist) {
    if (!projectRoot) return '';
    const reg = loadWorkspaces();
    let key = workspaceKey(projectRoot);
    for (const [k, root] of Object.entries(reg)) { if (root === projectRoot) { key = k; break; } }
    key = disambiguate(key, projectRoot, reg);
    if (persist && reg[key] !== projectRoot) { reg[key] = projectRoot; saveWorkspaces(reg); }
    return key;
  }
  /** Resolve AND persist the key (explicit enable / registration). */
  function registerProjectRoot(projectRoot) { return resolveKey(projectRoot, true); }
  /** Resolve the key WITHOUT persisting. Archiving must NOT auto-enable a project
   *  (enable is controlled only by the project-view toggle, docs/channel-project-switch.md). */
  function resolveWorkspaceKey(projectRoot) { return resolveKey(projectRoot, false); }

  // ----- project enable (the "project switch"; docs/channel-project-switch.md) -----
  // A project root present in this channel's workspaces.json = that workspace has
  // the channel enabled. Membership is by VALUE (projectRoot), not by key.
  function listEnabledWorkspaces() {
    return Object.values(loadWorkspaces()).filter(Boolean);
  }
  function isWorkspaceEnabled(projectRoot) {
    if (!projectRoot) return false;
    return listEnabledWorkspaces().includes(projectRoot);
  }
  function setWorkspaceEnabled(projectRoot, enabled) {
    if (!projectRoot) return false;
    if (enabled) {
      if (!isWorkspaceEnabled(projectRoot)) registerProjectRoot(projectRoot); // derives key + registers + saves
    } else {
      const reg = loadWorkspaces();
      let changed = false;
      for (const k of Object.keys(reg)) if (reg[k] === projectRoot) { delete reg[k]; changed = true; }
      if (changed) saveWorkspaces(reg);
    }
    return true;
  }

  function bucketFile(projectRoot, sessionId) {
    // derive the key WITHOUT registering — archiving a message must not auto-enable the project.
    const key = resolveWorkspaceKey(projectRoot);
    return path.join(dir, channelId + '.' + key + '.' + (sessionId || 'system') + '.messages.json');
  }

  // ----- sessions -----
  function loadSessions() {
    const data = readJson(sessionsFile, { version: 1, sessions: [] });
    return Array.isArray(data.sessions) ? data.sessions : [];
  }
  function saveSessions(sessions) {
    try { ensureDir(); fs.writeFileSync(sessionsFile, JSON.stringify({ version: 1, sessions }, null, 2), 'utf8'); } catch { /* non-fatal */ }
  }
  function getSession(conversationId) {
    return loadSessions().find((s) => s.conversationId === conversationId) || null;
  }
  // Set/refresh the ACTIVE session for a conversation. Sessions are recorded
  // once per sessionId (history is preserved: /new does NOT erase the previous
  // session, it just re-binds the conversation to the new one), so a project's
  // full session list is always visible in the panel.
  function setSession(conversationId, rec) {
    const sessions = loadSessions();
    // un-bind the previous owner of this conversation
    for (const s of sessions) if (s.conversationId === conversationId) s.conversationId = null;
    // upsert by sessionId (keep all sessions)
    let entry = sessions.find((s) => s.sessionId === rec.sessionId);
    if (!entry) {
      entry = { sessionId: rec.sessionId, createdAt: rec.createdAt || Date.now() };
      sessions.push(entry);
    }
    entry.conversationId = conversationId;
    if (rec.projectRoot) { entry.projectRoot = rec.projectRoot; entry.workspaceKey = rec.workspaceKey || resolveWorkspaceKey(rec.projectRoot); }
    else { entry.projectRoot = entry.projectRoot || null; entry.workspaceKey = entry.workspaceKey || null; }
    if (rec.name != null) entry.name = rec.name;
    entry.updatedAt = Date.now();
    saveSessions(sessions);
    return entry;
  }
  function listSessions() {
    return loadSessions().sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0));
  }

  // ----- messages (bucketed) -----
  function readBucket(file) {
    const data = readJson(file, { version: 1, messages: [] });
    return Array.isArray(data.messages) ? data.messages : [];
  }
  function bucketFiles(prefix) {
    try {
      return fs.readdirSync(dir)
        .filter((f) => f.startsWith(prefix) && f.endsWith('.messages.json'))
        .map((f) => path.join(dir, f));
    } catch { return []; }
  }
  /** All messages across every bucket of this channel. */
  function loadMessages() {
    let out = [];
    for (const f of bucketFiles(channelId + '.')) out = out.concat(readBucket(f));
    return out;
  }
  /** Messages for one workspace key (incl. its system bucket). */
  function loadMessagesFor(workspaceKey) {
    let out = [];
    for (const f of bucketFiles(channelId + '.' + (workspaceKey || '') + '.')) out = out.concat(readBucket(f));
    return out;
  }
  /** Append a message record. dir = "in" | "out".
   *  Bucket = project-scoped (projectRoot, sessionId??system) when there is a
   *  project context; otherwise (command/system message with no project context)
   *  a channel-GLOBAL system bucket — never scoped under a workspace key. */
  function appendMessage({ conversationId, sessionId, dir, text, ts, projectRoot }) {
    let root = projectRoot;
    if (!root) { const rec = getSession(conversationId); root = (rec && rec.projectRoot) || null; }
    let file;
    if (root) {
      file = bucketFile(root, sessionId);
    } else if (!sessionId) {
      // channel-level system message (no project context)
      file = channelSystemFile;
    } else {
      root = defaultProjectRoot || null;
      if (!root) return; // nowhere to archive — best effort, never throw
      file = bucketFile(root, sessionId);
    }
    const messages = readBucket(file);
    messages.push({ channelId, conversationId, sessionId: sessionId || null, dir, text: String(text || ''), ts: ts || Date.now(), projectRoot: root });
    if (messages.length > MAX_MESSAGES) messages.splice(0, messages.length - MAX_MESSAGES);
    try { ensureDir(); fs.writeFileSync(file, JSON.stringify({ version: 1, messages }, null, 2), 'utf8'); } catch { /* non-fatal */ }
  }
  /** List messages for a conversation across all buckets (oldest first). */
  function listMessages(conversationId, limit) {
    const msgs = loadMessages().filter((m) => m.conversationId === conversationId).sort((a, b) => (a.ts || 0) - (b.ts || 0));
    return limit ? msgs.slice(-limit) : msgs;
  }

  return {
    sessionsFile, workspacesFile, dir,
    getSession, setSession, listSessions,
    appendMessage, listMessages, loadMessages, loadMessagesFor,
    registerProjectRoot, resolveWorkspaceKey, workspaceKey,
    listEnabledWorkspaces, isWorkspaceEnabled, setWorkspaceEnabled,
  };
}

module.exports = { createChannelSessions, workspaceKey, channelsDir, MAX_MESSAGES };
