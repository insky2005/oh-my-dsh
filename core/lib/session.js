'use strict';

/**
 * core/lib/session.js — dsh web session RPC (fetch active session cwd).
 * Ported from src/main.swift (DSHSessionRPC): the same HTTP POST
 * /api/session.list `client-request` envelope the web client uses, so any
 * platform can resolve "which project directory is the active session in".
 */

const http = require('node:http');
const crypto = require('node:crypto');

/** POST a client-request RPC to the dsh web host and return the parsed JSON. */
function rpc(port, method, payload = {}, host = '127.0.0.1', timeoutMs = 6000) {
  const rpcId = crypto.randomUUID();
  const body = JSON.stringify({ type: 'client-request', rpcId, method, payload });
  return new Promise((resolve) => {
    const req = http.request(
      { host, port, path: '/api/session.list', method: 'POST', timeout: timeoutMs, headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) } },
      (res) => {
        let data = '';
        res.setEncoding('utf8');
        res.on('data', (c) => { data += c; });
        res.on('end', () => {
          try {
            const json = JSON.parse(data);
            if (json.rpcId !== rpcId) return resolve(null);
            resolve(json);
          } catch {
            resolve(null);
          }
        });
      }
    );
    req.on('timeout', () => { req.destroy(); resolve(null); });
    req.on('error', () => resolve(null));
    req.end(body);
  });
}

/**
 * Pick the most relevant session's cwd: running sessions first, then the
 * most recently updated non-blank one (mirror of fetchActiveSessionCwd).
 */
async function fetchActiveSessionCwd(port, host = '127.0.0.1', timeoutMs = 6000) {
  const json = await rpc(port, 'session.list', {}, host, timeoutMs);
  if (!json) return null;
  const res = json.result;
  if (!res || res.ok !== true || !res.value) return null;
  const items = res.value.items || [];
  const candidates = items.filter((s) => s.blank !== true && typeof s.cwd === 'string');
  const running = candidates.filter((s) => s.running === true);
  const pool = running.length ? running : candidates;
  pool.sort((x, y) => (y.updatedAt || 0) - (x.updatedAt || 0));
  return pool.length ? pool[0].cwd : null;
}

/** The cwd of one specific session by id (mirror of fetchSessionCwd). */
async function fetchSessionCwd(port, sessionId, host = '127.0.0.1', timeoutMs = 6000) {
  const json = await rpc(port, 'session.list', {}, host, timeoutMs);
  if (!json) return null;
  const res = json.result;
  if (!res || res.ok !== true || !res.value) return null;
  const items = res.value.items || [];
  const hit = items.find((s) => s.sessionId === sessionId);
  return hit && typeof hit.cwd === 'string' ? hit.cwd : null;
}

module.exports = { rpc, fetchActiveSessionCwd, fetchSessionCwd };
