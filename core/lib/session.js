'use strict';

/**
 * core/lib/session.js — dsh web session RPC (fetch active session cwd).
 * Ported from src/main.swift (DSHSessionRPC): the same `client-request` envelope
 * the web client uses, so any platform can resolve "which project directory is
 * the active session in".
 *
 * The wire shape depends on the dsh version (core/lib/dsh-rpc.js): dsh <= 0.1.1
 * POSTs /api/session.list, dsh >= 0.1.2 POSTs /api/session/list and needs the
 * launch-token cookie — pass `opts.token` on 0.1.2+.
 */

const { callRpc, rpc, SESSION_LIST } = require('./dsh-rpc');

/** session list items of a running dsh web (null when it could not answer). */
async function fetchItems(port, host, timeoutMs, opts) {
  const json = await callRpc(SESSION_LIST, {}, { port, host, timeoutMs, token: opts && opts.token });
  if (!json) return null;
  const res = json.result;
  if (!res || res.ok !== true || !res.value) return null;
  return res.value.items || [];
}

/**
 * Pick the most relevant session's cwd: running sessions first, then the
 * most recently updated non-blank one (mirror of fetchActiveSessionCwd).
 */
async function fetchActiveSessionCwd(port, host = '127.0.0.1', timeoutMs = 6000, opts = {}) {
  const items = await fetchItems(port, host, timeoutMs, opts);
  if (!items) return null;
  const candidates = items.filter((s) => s.blank !== true && typeof s.cwd === 'string');
  const running = candidates.filter((s) => s.running === true);
  const pool = running.length ? running : candidates;
  pool.sort((x, y) => (y.updatedAt || 0) - (x.updatedAt || 0));
  return pool.length ? pool[0].cwd : null;
}

/** The cwd of one specific session by id (mirror of fetchSessionCwd). */
async function fetchSessionCwd(port, sessionId, host = '127.0.0.1', timeoutMs = 6000, opts = {}) {
  const items = await fetchItems(port, host, timeoutMs, opts);
  if (!items) return null;
  const hit = items.find((s) => s.sessionId === sessionId);
  return hit && typeof hit.cwd === 'string' ? hit.cwd : null;
}

module.exports = { rpc, fetchActiveSessionCwd, fetchSessionCwd };
