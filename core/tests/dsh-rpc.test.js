'use strict';

/**
 * dsh-rpc: the channel runner must reach dsh web on BOTH API generations —
 * legacy dot-methods (dsh <= 0.1.1) and the slash-endpoint + launch-token
 * cookie surface (dsh >= 0.1.2). Docs: docs/plans/dsh-012rc1-compat-audit.md (C1).
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const {
  callRpc, surfaceOf, _resetForTests,
  SESSION_LIST, WORKSPACE_LIST,
} = require('../lib/dsh-rpc');
const { lastMessage, listWorkspaceSessions } = require('../lib/session-driver');

const COOKIE = 'dsh-auth-test=ok';

/**
 * Close a mock server AND destroy its sockets. Node's global agent keeps
 * connections alive by default (>=19), and `server.close()` alone then waits for
 * them — which can leave a test file (and a CI job) hanging.
 */
function closeServer(srv) {
  try { if (typeof srv.closeAllConnections === 'function') srv.closeAllConnections(); } catch { /* ignore */ }
  try { srv.close(); } catch { /* ignore */ }
}

/** Mock dsh >= 0.1.2: /api needs the launch-token cookie; endpoints are slash paths. */
function startModernServer({ token = 'tok', sessions = [], records = [] } = {}) {
  const calls = [];
  return new Promise((resolve) => {
    const srv = http.createServer((req, res) => {
      const url = String(req.url || '');
      if (req.method === 'GET') {
        if (url === '/?token=' + token) {
          res.writeHead(303, { 'set-cookie': [COOKIE + '; Path=/; HttpOnly'] });
          res.end();
          return;
        }
        res.writeHead(401);
        res.end('unauthorized');
        return;
      }
      let body = '';
      req.on('data', (c) => { body += c; });
      req.on('end', () => {
        if (!String(req.headers.cookie || '').includes(COOKIE)) {
          res.writeHead(401);
          res.end('unauthorized');
          return;
        }
        const json = JSON.parse(body || '{}');
        const endpoint = url.replace('/api/', '');
        calls.push({ endpoint, payload: json.payload });
        const reply = (value) => {
          res.writeHead(200, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ rpcId: json.rpcId, result: { ok: true, value } }));
        };
        if (endpoint === 'session/list') return reply({ items: sessions });
        if (endpoint === 'session/page') return reply({ records });
        res.writeHead(404);
        res.end('not found');
      });
    });
    srv.listen(0, '127.0.0.1', () => resolve({ srv, port: srv.address().port, calls }));
  });
}

/** Mock dsh <= 0.1.1: dot-method endpoints, no auth. */
function startLegacyServer({ sessions = [] } = {}) {
  const calls = [];
  return new Promise((resolve) => {
    const srv = http.createServer((req, res) => {
      let body = '';
      req.on('data', (c) => { body += c; });
      req.on('end', () => {
        const url = String(req.url || '');
        const json = JSON.parse(body || '{}');
        calls.push({ endpoint: url.replace('/api/', ''), payload: json.payload });
        if (url === '/api/session.list') {
          res.writeHead(200, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ rpcId: json.rpcId, result: { ok: true, value: { items: sessions } } }));
          return;
        }
        res.writeHead(404);
        res.end('not found');
      });
    });
    srv.listen(0, '127.0.0.1', () => resolve({ srv, port: srv.address().port, calls }));
  });
}

// One session exactly as dsh web reports it (dsh >= 0.1.2 wire shape).
const item = {
  sessionId: 'session-1', updatedAt: 5, running: false, blank: false, cwd: '/w/alpha',
  projections: { asOfSeq: 12, values: { title: 'Alpha chat' } },
};

test('dsh-rpc: dsh >= 0.1.2 slash endpoint + launch-token cookie', async () => {
  _resetForTests();
  const { srv, port, calls } = await startModernServer({ sessions: [item] });
  try {
    const json = await callRpc(SESSION_LIST, {}, { port, token: 'tok' });
    assert.equal(json.result.ok, true);
    assert.equal(json.result.value.items.length, 1);
    assert.equal(surfaceOf(SESSION_LIST, { port, token: 'tok' }), 'modern');
    assert.equal(calls[0].endpoint, 'session/list');
    assert.deepEqual(calls[0].payload, { args: { _request: {} } }, 'modern envelope wraps args');
  } finally { closeServer(srv); }
});

test('dsh-rpc: without the launch token a 0.1.2 server cannot be reached', async () => {
  _resetForTests();
  const { srv, port } = await startModernServer({ sessions: [item] });
  try {
    assert.equal(await callRpc(SESSION_LIST, {}, { port }), null);
  } finally { closeServer(srv); }
});

test('dsh-rpc: dsh <= 0.1.1 dot-method surface still works (fallback)', async () => {
  _resetForTests();
  const { srv, port, calls } = await startLegacyServer({ sessions: [item] });
  try {
    const json = await callRpc(SESSION_LIST, {}, { port });
    assert.equal(json.result.value.items.length, 1);
    assert.equal(surfaceOf(SESSION_LIST, { port }), 'legacy');
    assert.deepEqual(calls.map((c) => c.endpoint), ['session/list', 'session.list']);
  } finally { closeServer(srv); }
});

test('dsh-rpc: an endpoint the server lacks (workspace/list on 0.1.2) does not poison other endpoints', async () => {
  _resetForTests();
  const { srv, port, calls } = await startModernServer({ sessions: [item] });
  try {
    assert.equal(await callRpc(WORKSPACE_LIST, {}, { port, token: 'tok' }), null);
    assert.equal(surfaceOf(WORKSPACE_LIST, { port, token: 'tok' }), 'legacy');
    const json = await callRpc(SESSION_LIST, {}, { port, token: 'tok' });
    assert.equal(json.result.value.items.length, 1, 'session/list stays on the modern surface');
    assert.deepEqual(calls.map((c) => c.endpoint), ['workspace/list', 'workspace.list', 'session/list']);
  } finally { closeServer(srv); }
});

test('dsh-rpc: lastMessage replays session/page up to the session/list cursor', async () => {
  _resetForTests();
  const records = [
    { type: 'event', event: { type: 'user/message', data: { role: 'user', content: [{ type: 'text', text: 'hi' }] } } },
    { type: 'event', event: { type: 'assistant/message', data: { message: { role: 'assistant', content: [{ type: 'text', text: '第一段' }] } } } },
    { type: 'event', event: { type: 'assistant/message', data: { message: { role: 'assistant', content: [
      { type: 'reasoning', text: '内部推理不应外泄' },
      { type: 'text', text: '最终回复' },
    ] } } } },
  ];
  const { srv, port, calls } = await startModernServer({ sessions: [item], records });
  try {
    assert.equal(await lastMessage(port, 'session-1', '127.0.0.1', 4000, { token: 'tok' }), '最终回复');
    const page = calls.find((c) => c.endpoint === 'session/page');
    assert.equal(page.payload.args.request.throughSeq, 12, 'page uses the projection cursor');
    assert.equal(page.payload.args.request.address.sessionId, 'session-1');
  } finally { closeServer(srv); }
});

test('dsh-rpc: listWorkspaceSessions falls back to the persisted workspace store on 0.1.2', async () => {
  _resetForTests();
  const os = require('node:os');
  const path = require('node:path');
  const fs = require('node:fs');
  const dshHome = fs.mkdtempSync(path.join(os.tmpdir(), 'ws-store-'));
  fs.mkdirSync(path.join(dshHome, 'storages'), { recursive: true });
  fs.writeFileSync(path.join(dshHome, 'storages', 'workspace.json'), JSON.stringify({
    unit: { name: 'workspace', version: 2 },
    global: { workspaceIds: ['w-1'], archivedSessionIds: [] },
    tables: { workspaces: { 'w-1': { path: '/w/alpha', title: 'Alpha', sessionIds: ['session-1'], createdAt: 'x', updatedAt: 'y' } } },
  }), 'utf8');
  const { srv, port } = await startModernServer({ sessions: [item] });
  try {
    const list = await listWorkspaceSessions(port, '127.0.0.1', '/w/alpha', 4000, { token: 'tok', dshHome });
    assert.equal(list.length, 1);
    assert.equal(list[0].sessionId, 'session-1');
    assert.equal(list[0].name, 'Alpha chat');
  } finally { closeServer(srv); }
});
test('dsh-rpc: a stale cookie is re-exchanged once after a dsh web restart', async () => {
  _resetForTests();
  let generation = 1;      // bumped = "dsh web restarted with a new secret"
  const gets = [];
  const srv = http.createServer((req, res) => {
    const url = String(req.url || '');
    if (req.method === 'GET') {
      gets.push(url);
      res.writeHead(303, { 'set-cookie': ['dsh-auth-test=gen' + generation + '; Path=/'] });
      res.end();
      return;
    }
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      if (!String(req.headers.cookie || '').includes('dsh-auth-test=gen' + generation)) {
        res.writeHead(401);
        res.end('unauthorized');
        return;
      }
      const json = JSON.parse(body || '{}');
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ rpcId: json.rpcId, result: { ok: true, value: { items: [item] } } }));
    });
  });
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  const port = srv.address().port;
  try {
    const first = await callRpc(SESSION_LIST, {}, { port, token: 'tok' });
    assert.equal(first.result.value.items.length, 1);
    generation = 2; // the running dsh web is replaced
    const second = await callRpc(SESSION_LIST, {}, { port, token: 'tok' });
    assert.equal(second.result.value.items.length, 1, 'stale cookie must be re-exchanged');
    assert.equal(gets.length, 2, 'exactly one cookie exchange per generation');
  } finally { closeServer(srv); }
});

