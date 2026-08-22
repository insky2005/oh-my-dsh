'use strict';

/**
 * core/lib/channel-store.js — channel credential/account persistence.
 *
 * Docs §4.1 credential decision (2026-08-21): FILE-FIRST, zero-prompt.
 * Token/account metadata for a channel lives at ~/.dsh/channels/<channelId>.json
 * (chmod 600), read first; Keychain is the fallback for legacy entries only.
 * Pure Node + fs — works identically on macOS/Windows/Linux.
 *
 *   const { loadChannelAccount, saveChannelAccount, channelAccountPath } = require('@oh-my-dsh/core');
 */

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

function channelsDir(dshHome) {
  return path.join(dshHome || process.env.DSH_HOME || path.join(os.homedir(), '.dsh'), 'channels');
}

/** The file path for a channel's persisted account/token. */
function channelAccountPath(channelId, dshHome) {
  return path.join(channelsDir(dshHome), channelId + '.json');
}

/**
 * Load a channel's saved account (token + accountId + userId + baseUrl).
 * Returns null when absent/unreadable. File-first, no prompts.
 */
function loadChannelAccount(channelId, dshHome) {
  if (!channelId) return null;
  const p = channelAccountPath(channelId, dshHome);
  try {
    if (!fs.existsSync(p)) return null;
    const raw = fs.readFileSync(p, 'utf8');
    const data = JSON.parse(raw);
    return {
      botToken: data.botToken || data.token || null,
      accountId: data.accountId || null,
      userId: data.userId || null,
      baseUrl: data.baseUrl || null,
    };
  } catch {
    return null;
  }
}

/**
 * Save a channel's account/token to disk (chmod 600). File-first + Keychain
 * is out of scope here (Node cannot write macOS Keychain without a shell
 * bridge); the file is the authoritative read source.
 */
function saveChannelAccount(channelId, account, dshHome) {
  if (!channelId) throw new Error('channel-store: channelId required');
  const dir = channelsDir(dshHome);
  fs.mkdirSync(dir, { recursive: true });
  const p = channelAccountPath(channelId, dshHome);
  const data = JSON.stringify({
    botToken: account.botToken || account.token || null,
    accountId: account.accountId || null,
    userId: account.userId || null,
    baseUrl: account.baseUrl || null,
    updatedAt: Date.now(),
  }, null, 2);
  fs.writeFileSync(p, data, { mode: 0o600 });
  try { fs.chmodSync(p, 0o600); } catch { /* best effort */ }
  return p;
}
/** Remove a channel's saved account file. */
function clearChannelAccount(channelId, dshHome) {
  const p = channelAccountPath(channelId, dshHome);
  try { if (fs.existsSync(p)) fs.unlinkSync(p); return true; } catch { return false; }
}

// ---------------------------------------------------------------------------
// Channel-global runtime state (always under ~/.dsh/channels/<id>.state.json —
// writable, channel-addressed, survives runner restarts). Holds per-channel
// state like `lastWorkspace` (the project this channel most recently used),
// which must NOT live under a project's .dsh (unknown/unwritable before a
// project is bound, and unreachable on restart).
// ---------------------------------------------------------------------------
function channelStatePath(channelId, dshHome) {
  return path.join(channelsDir(dshHome), channelId + '.state.json');
}

/** Load channel-global runtime state ({} when absent/unreadable). */
function loadChannelState(channelId, dshHome) {
  if (!channelId) return {};
  const p = channelStatePath(channelId, dshHome);
  try {
    if (!fs.existsSync(p)) return {};
    const data = JSON.parse(fs.readFileSync(p, 'utf8'));
    return data && typeof data === 'object' ? data : {};
  } catch {
    return {};
  }
}

/** Save channel-global runtime state (best-effort; never throws). */
function saveChannelState(channelId, state, dshHome) {
  if (!channelId || !state) return false;
  const p = channelStatePath(channelId, dshHome);
  try {
    fs.mkdirSync(channelsDir(dshHome), { recursive: true });
    fs.writeFileSync(p, JSON.stringify({ version: 1, ...state, updatedAt: Date.now() }, null, 2), { mode: 0o600 });
    try { fs.chmodSync(p, 0o600); } catch { /* best effort */ }
    return true;
  } catch {
    return false;
  }
}


/**
 * Channel-global runtime store: lastWorkspace + known sessions + active session.
 * All persisted in ~/.dsh/channels/<channelId>.state.json. Channel-scoped (NOT
 * per-project) so it is always writable and survives runner restarts — no-tag
 * routing, the session list and the active session are restored on startup.
 *
 * sessions:  { [sessionId]: { sessionId, projectRoot, name, conversationId?, createdAt, updatedAt } }
 *            keyed by sessionId (unique); conversationId marks which chat owns it.
 * activeSessionId: which session is currently active (for /status).
 */
function createChannelRuntimeStore({ channelId, dshHome }) {
  // In-memory cache of the state. Every mutation updates `cache` SYNCHRONOUSLY
  // (then persists), so two async handlers (e.g. /new setActiveSession and the
  // connection-state onState) can never read a stale snapshot and overwrite each
  // other's changes — the classic read-modify-write race on the state file.
  let cache = loadChannelState(channelId, dshHome) || {};
  function load() { return cache; }
  function save(patch) {
    cache = { ...cache, ...patch };
    saveChannelState(channelId, { ...cache }, dshHome);
  }

  function getLastWorkspace() { return load().lastWorkspace || null; }
  function setLastWorkspace(ws) {
    const v = ws ? { code: ws.code, name: ws.name || '', projectRoot: ws.projectRoot || ws.path || '' } : null;
    save({ lastWorkspace: v });
    return v;
  }

  /** Get the session currently owned by a conversation (or null). */
  function getSession(conversationId) {
    if (!conversationId) return null;
    const all = load().sessions || {};
    const hit = Object.values(all).find((s) => s.conversationId === conversationId);
    return hit || null;
  }
  /** Bind a conversation to a session (upsert; un-binds its previous owner). */
  function setSession(conversationId, rec) {
    if (!conversationId || !rec || !rec.sessionId) return null;
    const cur = load();
    const sessions = Object.assign({}, cur.sessions || {});
    for (const k of Object.keys(sessions)) if (sessions[k].conversationId === conversationId) sessions[k].conversationId = null;
    const sid = rec.sessionId;
    const ex = sessions[sid] || {};
    sessions[sid] = { sessionId: sid, projectRoot: rec.projectRoot || ex.projectRoot || '', name: rec.name || ex.name || null, conversationId, createdAt: ex.createdAt || Date.now(), updatedAt: Date.now() };
    save({ sessions });
    return sessions[sid];
  }
  /** Ensure a session is known (used by /new and /switch so it shows in /sessions). */
  function addSession(rec) {
    if (!rec || !rec.sessionId) return null;
    const cur = load();
    const sessions = Object.assign({}, cur.sessions || {});
    const sid = rec.sessionId;
    const ex = sessions[sid] || {};
    sessions[sid] = { sessionId: sid, projectRoot: rec.projectRoot || ex.projectRoot || '', name: rec.name || ex.name || null, conversationId: ex.conversationId || null, createdAt: ex.createdAt || Date.now(), updatedAt: Date.now() };
    save({ sessions });
    return sessions[sid];
  }
  function listSessions() {
    const all = load().sessions || {};
    return Object.values(all).sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0));
  }

  function getActiveSession() {
    const sid = load().activeSessionId;
    if (!sid) return null;
    const all = load().sessions || {};
    const s = all[sid];
    return s ? { sessionId: s.sessionId, projectRoot: s.projectRoot, name: s.name, updatedAt: s.updatedAt } : { sessionId: sid };
  }

  /** Persist the live connection state (read by the panel on demand). */
  function setConnectionState(stateStr) {
    const s = stateStr === 'auth-expired' ? 'authExpired' : stateStr || 'disconnected';
    save({ state: s, connected: s === 'connected' });
    return s;
  }
  /** Set the active session (also ensures it is a known session). */
  function setActiveSession(rec) {
    if (!rec || !rec.sessionId) { save({ activeSessionId: null }); return null; }
    const cur = load();
    const sessions = Object.assign({}, cur.sessions || {});
    const sid = rec.sessionId;
    const ex = sessions[sid] || {};
    sessions[sid] = { sessionId: sid, projectRoot: rec.projectRoot || ex.projectRoot || '', name: rec.name || ex.name || null, conversationId: ex.conversationId || null, createdAt: ex.createdAt || Date.now(), updatedAt: Date.now() };
    save({ sessions, activeSessionId: sid });
    return { sessionId: sid, projectRoot: sessions[sid].projectRoot, name: sessions[sid].name, updatedAt: sessions[sid].updatedAt };
  }
  return { load, getLastWorkspace, setLastWorkspace, getSession, setSession, addSession, listSessions, getActiveSession, setActiveSession, setConnectionState };
}

module.exports = { channelsDir, channelAccountPath, loadChannelAccount, saveChannelAccount, clearChannelAccount, channelStatePath, loadChannelState, saveChannelState, createChannelRuntimeStore };



