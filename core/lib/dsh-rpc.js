'use strict';

/**
 * core/lib/dsh-rpc.js — HTTP RPC transport for dsh web, both API generations.
 *
 * dsh exposes two wire surfaces for the same unary RPCs:
 *
 *   legacy (dsh <= 0.1.1) — POST /api/<dot.method>, payload = the request args,
 *                           no authentication.
 *   modern (dsh >= 0.1.2) — POST /api/<slash/endpoint>, payload =
 *                           { args: { <field>: args } }, and /api is fenced by
 *                           a browser-session cookie minted from the launch
 *                           token dsh prints as
 *                           "dsh web: http://127.0.0.1:<port>/?token=...".
 *
 * callRpc() hides the difference: it tries the modern endpoint first and, when
 * the running server does not know it (or cannot authenticate it), falls back
 * to the legacy method. The decision is cached per (host, port, endpoint) — a
 * server may know session/list but not workspace/list, so it is not a
 * per-server switch.
 *
 *   const { callRpc, SESSION_LIST } = require('@oh-my-dsh/core');
 *   const json = await callRpc(SESSION_LIST, {}, { port: 3080, token });
 *
 * Docs: docs/plans/dsh-012rc1-compat-audit.md (channel runner / C1).
 */

const http = require('node:http');
const crypto = require('node:crypto');

/** `${host}:${port}:${modernEndpoint}` -> 'modern' | 'legacy' (per endpoint). */
const surfaceCache = new Map();
/** `${host}:${port}` -> cookie header value for dsh >= 0.1.2's /api fence. */
const cookieCache = new Map();

/** Endpoint descriptors: the same call on both surfaces. */
const SESSION_LIST = { modern: 'session/list', legacy: 'session.list', field: '_request' };
const SESSION_CREATE = { modern: 'session/create', legacy: 'session.create', field: 'request' };
const SESSION_RENAME = { modern: 'session/rename', legacy: 'session.rename', field: 'request' };
const SESSION_PROMPT = { modern: 'session/prompt', legacy: 'session.prompt', field: 'request' };
const SESSION_CANCEL = { modern: 'session/cancel', legacy: 'session.cancel', field: 'request' };
const SESSION_PAGE = { modern: 'session/page', legacy: null, field: 'request' };
const SESSION_SEARCH = { modern: null, legacy: 'session.search' };
const SESSION_HISTORY = { modern: null, legacy: 'session.history' };
const WORKSPACE_LIST = { modern: 'workspace/list', legacy: 'workspace.list', field: '_request' };

/** Normalize the per-call context (port/host/timeout/token). */
function ctxOf(opts) {
  const o = opts || {};
  return {
    port: o.port,
    host: o.host || '127.0.0.1',
    timeoutMs: o.timeoutMs || 8000,
    token: String(o.token || process.env.DSH_WEB_TOKEN || '').trim(),
  };
}

function cacheKey(ctx, suffix) {
  return ctx.host + ':' + ctx.port + (suffix ? ':' + suffix : '');
}

/** One HTTP request. Resolves null on transport failure; never throws. */
function request(ctx, path, { body, cookie, method = 'POST' } = {}) {
  return new Promise((resolve) => {
    const payload = body === undefined ? null : Buffer.from(JSON.stringify(body));
    const headers = {};
    if (payload) {
      headers['content-type'] = 'application/json';
      headers['content-length'] = String(payload.length);
    }
    if (cookie) headers.cookie = cookie;
    const req = http.request(
      { host: ctx.host, port: ctx.port, path, method, timeout: ctx.timeoutMs, headers },
      (res) => {
        let data = '';
        res.setEncoding('utf8');
        res.on('data', (c) => { data += c; });
        res.on('end', () => resolve({ status: res.statusCode || 0, headers: res.headers || {}, text: data }));
      }
    );
    req.on('timeout', () => { req.destroy(); resolve(null); });
    req.on('error', () => resolve(null));
    req.end(payload || undefined);
  });
}

/**
 * Mint (and cache) the dsh >= 0.1.2 browser-session cookie: GET /?token=<launch
 * token> answers 303 with a signed `dsh-auth-*` Set-Cookie that /api accepts.
 * Returns '' when no token is configured or the exchange fails (a legacy dsh
 * needs no cookie), so callers can stay transport-agnostic.
 */
async function authenticate(ctx) {
  const key = cacheKey(ctx);
  if (cookieCache.has(key)) return cookieCache.get(key);
  if (!ctx.token) return '';
  const res = await request(ctx, '/?token=' + encodeURIComponent(ctx.token), { method: 'GET' });
  if (!res) return ''; // server not up yet — retry on the next call
  const raw = res.headers['set-cookie'];
  const list = Array.isArray(raw) ? raw : raw ? [raw] : [];
  const hit = list.map((c) => String(c).split(';')[0].trim()).find((c) => c.startsWith('dsh-auth-'));
  if (!hit) return '';
  cookieCache.set(key, hit);
  return hit;
}

function parseJson(text) {
  try { return JSON.parse(text); } catch { return null; }
}

/** Drop a cached cookie (it came from a previous dsh web process / secret). */
function forgetCookie(ctx) {
  cookieCache.delete(cacheKey(ctx));
}

/** POST one endpoint with the client-request envelope; null on transport failure. */
async function post(ctx, method, payload, cookie) {
  const rpcId = crypto.randomUUID();
  const res = await request(ctx, '/api/' + method, {
    body: { type: 'client-request', rpcId, method, payload },
    cookie,
  });
  if (!res) return null;
  const json = parseJson(res.text);
  if (!json || json.rpcId !== rpcId) return { status: res.status, json: null };
  return { status: res.status, json };
}

function envelope(spec, args, modern) {
  if (!modern) return args || {};
  const field = spec.field || 'request';
  return { args: { [field]: args || {} } };
}

/** True when a modern response is a usable success (a legacy server answers 404). */
function usable(json) {
  return !!(json && json.result && json.result.ok === true
    && json.result.value !== null && json.result.value !== undefined);
}

/** Which surface is in effect for a descriptor on this server (undefined: unknown). */
function surfaceOf(spec, opts) {
  const ctx = ctxOf(opts);
  return surfaceCache.get(cacheKey(ctx, spec.modern || spec.legacy));
}

/**
 * Run one unary RPC against whichever surface the server speaks.
 * Returns the parsed server-response envelope (`{ result: { ok, value|error } }`)
 * or null when the call could not be made at all.
 */
async function callRpc(spec, args, opts) {
  const ctx = ctxOf(opts);
  let cookie = await authenticate(ctx);
  const key = cacheKey(ctx, spec.modern || spec.legacy);

  if (spec.modern && surfaceCache.get(key) !== 'legacy') {
    let res = await post(ctx, spec.modern, envelope(spec, args, true), cookie);
    if (res && res.status === 401 && cookie) {
      // The cookie outlived the dsh web process that minted it — re-exchange once.
      forgetCookie(ctx);
      cookie = await authenticate(ctx);
      res = await post(ctx, spec.modern, envelope(spec, args, true), cookie);
    }
    if (res) {
      if (usable(res.json)) {
        surfaceCache.set(key, 'modern');
        return res.json;
      }
      surfaceCache.set(key, 'legacy');
    }
  }
  if (!spec.legacy) return null;
  const legacy = await post(ctx, spec.legacy, envelope(spec, args, false), cookie);
  return legacy ? legacy.json : null;
}

/**
 * Legacy-only POST (dsh <= 0.1.1 wire shape) — kept for callers that already
 * know the method name; prefer callRpc for anything that must also work on
 * dsh >= 0.1.2.
 */
async function rpc(port, method, payload = {}, host = '127.0.0.1', timeoutMs = 8000, opts = {}) {
  const ctx = ctxOf({ port, host, timeoutMs, token: opts.token });
  const res = await post(ctx, method, payload, await authenticate(ctx));
  return res ? res.json : null;
}

/** Test hook: forget cached surfaces/cookies (different mock servers per test). */
function _resetForTests() {
  surfaceCache.clear();
  cookieCache.clear();
}

module.exports = {
  callRpc, rpc, authenticate, surfaceOf, _resetForTests,
  SESSION_LIST, SESSION_CREATE, SESSION_RENAME, SESSION_PROMPT, SESSION_CANCEL,
  SESSION_PAGE, SESSION_SEARCH, SESSION_HISTORY, WORKSPACE_LIST,
};
