'use strict';

/**
 * core/lib/session-driver.js — dsh session driver for remote channel messages.
 *
 * Mirrors the IssueRunner RPC envelope (platforms/macos/src/IssueRunnerPanel.swift):
 * HTTP POST to /api/<method> with a `client-request` body, then parse
 * result.value. Platform-independent — any shell (macOS/Windows/Linux) can
 * drive a dsh session from an inbound ChannelEvent.
 *
 * The transport is version-agnostic (core/lib/dsh-rpc.js): dsh <= 0.1.1 uses the
 * dot-method surface, dsh >= 0.1.2 the slash-endpoint surface plus the
 * browser-session cookie minted from its launch token. Pass `token` (the one in
 * the URL dsh web prints) to authenticate against 0.1.2+.
 *
 * The driver's `run()` maps an event+projectRef to: create session (workspace
 * or cwd) -> rename -> prompt (mode queue) -> poll running -> fetch last
 * assistant message -> return a ChannelReply.
 */

const crypto = require('node:crypto');
const {
  callRpc, rpc, surfaceOf,
  SESSION_LIST, SESSION_CREATE, SESSION_RENAME, SESSION_PROMPT, SESSION_CANCEL,
  SESSION_PAGE, SESSION_SEARCH, SESSION_HISTORY,
} = require('./dsh-rpc');
const { listWorkspaces } = require('./workspace-store');

/** ok() pulls result.ok boolean. */
function ok(json) { return !!(json && json.result && json.result.ok === true); }
/** value() pulls result.value (any). */
function value(json) { return json && json.result && json.result.ok === true ? json.result.value : null; }

/** Per-call transport context (port/host/timeout + dsh >= 0.1.2 auth token). */
function callCtx(port, host, timeoutMs, opts) {
  const o = opts || {};
  return {
    port,
    host: host || o.host || '127.0.0.1',
    timeoutMs: timeoutMs || o.timeoutMs || 8000,
    token: o.token,
  };
}

/** session/list items, or null when the server could not answer. */
async function fetchSessionItems(port, host, timeoutMs, opts) {
  const json = await callRpc(SESSION_LIST, {}, callCtx(port, host, timeoutMs, opts));
  const v = value(json);
  return v && Array.isArray(v.items) ? v.items : null;
}

async function createSession(port, { workspaceId, cwd }, host, timeoutMs, opts) {
  const args = workspaceId ? { workspaceId } : cwd ? { cwd } : null;
  if (!args) return null;
  const json = await callRpc(SESSION_CREATE, args, callCtx(port, host, timeoutMs, opts));
  const v = value(json);
  return v && typeof v.sessionId === 'string' ? v.sessionId : null;
}

async function renameSession(port, sessionId, title, host, timeoutMs, opts) {
  const json = await callRpc(SESSION_RENAME, { sessionId, title }, callCtx(port, host, timeoutMs, opts));
  return ok(json);
}

async function promptSession(port, sessionId, text, host, timeoutMs, opts) {
  // dsh >= 0.1.2 requires a client request id for idempotent prompt delivery.
  const payload = {
    requestId: crypto.randomUUID(),
    sessionId,
    mode: 'queue',
    content: [{ type: 'text', text }],
  };
  const json = await callRpc(SESSION_PROMPT, payload, callCtx(port, host, timeoutMs, opts));
  return ok(json);
}

async function cancelSession(port, sessionId, host, timeoutMs, opts) {
  const json = await callRpc(SESSION_CANCEL, { sessionId }, callCtx(port, host, timeoutMs, opts));
  return ok(json);
}

/** True while the session is running (session list lookup). */
async function sessionRunning(port, sessionId, host, timeoutMs, opts) {
  const items = await fetchSessionItems(port, host, timeoutMs, opts);
  if (!items) return false;
  const hit = items.find((s) => s.sessionId === sessionId);
  return !!(hit && hit.running === true);
}

/** True if a session with this id exists in dsh. */
async function sessionExists(port, sessionId, host, timeoutMs, opts) {
  if (!sessionId) return false;
  const items = await fetchSessionItems(port, host, timeoutMs, opts);
  if (!items) return false;
  return items.some((s) => s.sessionId === sessionId);
}

function extractMessages(v) {
  if (!v) return [];
  if (Array.isArray(v)) return v;
  if (Array.isArray(v.items)) return v.items;
  if (Array.isArray(v.messages)) return v.messages;
  if (Array.isArray(v.results)) return v.results;
  if (Array.isArray(v.events)) {
    return v.events.map((e) => { const ev = e && e.event ? e.event : e; return ev && ev.data ? ev.data.message : null; }).filter(Boolean);
  }
  return [];
}

function extractText(m) {
  if (!m || typeof m !== 'object') return '';
  if (typeof m.text === 'string' && m.text) return m.text;
  if (typeof m.content === 'string' && m.content) return m.content;
  if (Array.isArray(m.content)) {
    // Prefer the visible answer parts: an assistant message also carries
    // reasoning / tool-call parts whose "text" must not leak into a channel
    // reply (WeChat gets the answer only).
    const withText = m.content.filter((p) => p && typeof p === 'object' && typeof p.text === 'string');
    const visible = withText.filter((p) => p.type !== 'reasoning' && p.type !== 'tool-call');
    const parts = (visible.length ? visible : withText).map((p) => p.text);
    if (parts.length) return parts.join('\n');
  }
  return '';
}

/** Last assistant text inside a session/page reply (dsh >= 0.1.2). */
function lastAssistantFromPage(v) {
  const records = v && Array.isArray(v.records) ? v.records : [];
  let last = null;
  for (const r of records) {
    const ev = r && r.event;
    if (!ev || (ev.type !== 'assistant/message' && ev.type !== 'message')) continue;
    const t = extractText(ev.data && ev.data.message ? ev.data.message : ev.data);
    if (t) last = t;
  }
  return last;
}

/**
 * Fetch the last assistant reply text for a session.
 *
 * dsh >= 0.1.2: session/page replays the session log up to the projection
 * cursor reported by session/list (session.history/session.search are gone).
 * dsh <= 0.1.1: session.history, with session.search as a fallback.
 */
async function lastMessage(port, sessionId, host, timeoutMs, opts) {
  const ctx = callCtx(port, host, timeoutMs, opts);
  const items = await fetchSessionItems(port, host, timeoutMs, opts);
  if (surfaceOf(SESSION_LIST, ctx) === 'modern') {
    const item = (items || []).find((s) => s.sessionId === sessionId);
    const throughSeq = item && item.projections && item.projections.asOfSeq;
    if (typeof throughSeq !== 'number') return null;
    const page = await callRpc(SESSION_PAGE, {
      address: { kind: 'session', sessionId },
      throughSeq,
      maxMessages: 400,
    }, ctx);
    return lastAssistantFromPage(value(page));
  }
  // --- legacy surface (dsh <= 0.1.1) ---
  const hist = await callRpc(SESSION_HISTORY, { sessionId }, ctx);
  const v = value(hist);
  if (v) {
    const events = (Array.isArray(v.events) ? v.events : []).concat(Array.isArray(v.items) ? v.items : []);
    let lastText = null;
    for (const e of events) {
      const ev = e && typeof e === 'object' && e.event ? e.event : e;
      const type = ev && ev.type;
      if (type !== 'assistant/message' && type !== 'message') continue;
      const msg = ev.data && ev.data.message;
      const t = extractText(msg);
      if (t) lastText = t;
    }
    if (lastText) return lastText;
  }
  // Fallback: session.search
  for (const q of ['', '\u6700\u65b0']) {  // '' then a broad query
    const json = await callRpc(SESSION_SEARCH, { query: q, sessionId }, ctx);
    const sv = value(json);
    const msgs = extractMessages(sv);
    if (msgs.length) {
      const m = msgs[msgs.length - 1];
      const text = extractText(m);
      if (text) return text;
    }
  }
  return null;
}

/**
 * Build the full session driver used by createChannelManager. `run` returns a
 * ChannelReply: create -> prompt -> poll -> lastMessage. Optionally inject a
 * poll interval + max polls for testability; `token` authenticates dsh >= 0.1.2.
 */
function createSessionDriver(opts = {}) {
  const port = opts.port || 3080;
  const host = opts.host || '127.0.0.1';
  const timeoutMs = opts.timeoutMs || 8000;
  const pollIntervalMs = opts.pollIntervalMs || 1000;
  const maxPolls = opts.maxPolls || 900; // ~15min at 1s
  const rpcOpts = { host, timeoutMs, token: opts.token, dshHome: opts.dshHome };

  /**
   * Run one channel event through a dsh session (A: multi-turn reuse).
   *
   * - If the caller already bound a session (`event.sessionId`) and it still
   *   exists in dsh, REUSE it (no create/rename) so a conversation keeps one
   *   session across turns until /new or /switch.
   * - Otherwise CREATE a new session. Prefer `workspaceId` (so the session
   *   belongs to a workspace, C) from `ref.workspaceId` or `event.workspaceId`;
   *   fall back to `cwd` from `ref.workspaceRoot` / `event.workspace`.
   *
   * Returns `{ text, media, sessionId }` so the caller can persist the mapping.
   */
  async function run(event, ref) {
    let sid = event && event.sessionId;
    if (sid && (await sessionExists(port, sid, host, timeoutMs, rpcOpts))) {
      // reuse — keep the existing session/title
    } else {
      const wsId = (ref && ref.workspaceId) || (event && (event.workspaceId || (event.workspace && event.workspace.id)));
      const cwd = (ref && ref.workspaceRoot) || (event && (event.workspaceRoot || (typeof event.workspace === 'string' ? event.workspace : null)));
      sid = await createSession(port, { workspaceId: wsId, cwd }, host, timeoutMs, rpcOpts);
      if (!sid) throw new Error('session-driver: session.create failed');
      const title = `remote(${event.platform}): ${(event.text || '').slice(0, 40) || event.conversationId}`;
      await renameSession(port, sid, title, host, timeoutMs, rpcOpts);
    }
    const text = event.media && event.media.filePath
      ? `${event.text ? event.text + '\n' : ''}[附件: ${event.media.fileName || event.media.filePath}]`
      : event.text || '';
    const prompted = await promptSession(port, sid, text, host, timeoutMs, rpcOpts);
    if (!prompted) { await cancelSession(port, sid, host, timeoutMs, rpcOpts); throw new Error('session-driver: session.prompt failed'); }
    let polls = 0;
    while (await sessionRunning(port, sid, host, timeoutMs, rpcOpts)) {
      if (++polls >= maxPolls) { await cancelSession(port, sid, host, timeoutMs, rpcOpts); throw new Error('session-driver: timeout waiting for session'); }
      await sleep(pollIntervalMs);
    }
    const replyText = (await lastMessage(port, sid, host, timeoutMs, rpcOpts)) || '(会话未产生可读取的回复文本)';
    return { text: replyText, media: null, sessionId: sid };
  }

  return {
    run,
    createSession: (p, req, h, t) => createSession(p, req, h, t, rpcOpts),
    renameSession: (p, id, title, h, t) => renameSession(p, id, title, h, t, rpcOpts),
    promptSession: (p, id, text, h, t) => promptSession(p, id, text, h, t, rpcOpts),
    cancelSession: (p, id, h, t) => cancelSession(p, id, h, t, rpcOpts),
    sessionRunning: (p, id, h, t) => sessionRunning(p, id, h, t, rpcOpts),
    sessionExists: (p, id, h, t) => sessionExists(p, id, h, t, rpcOpts),
    lastMessage: (p, id, h, t) => lastMessage(p, id, h, t, rpcOpts),
    rpc: (p, method, payload, h, t) => rpc(p, method, payload, h, t, rpcOpts),
  };
}

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

/**
 * List the dsh sessions that live in a given workspace (by cwd and/or the
 * workspace's sessionIds). Returns [{ sessionId, name, projectRoot, updatedAt, running }].
 * The display name comes from session.list projections.values.title; sessions
 * whose cwd IS the workspace root are included too (dsh >= 0.1.2 has no
 * workspace.list, so the workspace's sessionIds come from the persisted store).
 */
async function listWorkspaceSessions(port, host, projectRoot, timeoutMs, opts) {
  const ctx = callCtx(port, host, timeoutMs, opts);
  const workspaces = await listWorkspaces(port, {
    host: ctx.host, timeoutMs: ctx.timeoutMs, token: ctx.token, dshHome: opts && opts.dshHome,
  });
  const ws = workspaces.find((w) => w.path === projectRoot);
  const wsIds = new Set(ws ? ws.sessionIds || [] : []);

  const items = (await fetchSessionItems(port, host, timeoutMs, opts)) || [];
  return items
    .filter((s) => s.cwd === projectRoot || wsIds.has(s.sessionId))
    .sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0))
    .map((s) => ({
      sessionId: s.sessionId,
      name: (s.projections && s.projections.values && s.projections.values.title) || '',
      projectRoot,
      updatedAt: s.updatedAt,
      running: s.running === true,
    }));
}

module.exports = { createSessionDriver, rpc, createSession, renameSession, promptSession, cancelSession, sessionRunning, sessionExists, lastMessage, listWorkspaceSessions };
