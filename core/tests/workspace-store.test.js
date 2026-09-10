'use strict';

/**
 * workspace-store: dsh >= 0.1.2 has no workspace.list RPC, so the channel runner
 * reads the workspaces dsh web persists to $DSH_HOME/storages/workspace.json.
 * Docs: docs/plans/dsh-012rc1-compat-audit.md (C1).
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { readWorkspaceStore, listWorkspaces, describeStore, dshHomePath } = require('../lib/workspace-store');

/// Close a mock server AND destroy its sockets (Node keeps connections alive by
/// default, so server.close() alone can leave the test process hanging).
function closeServer(srv) {
  try { if (typeof srv.closeAllConnections === 'function') srv.closeAllConnections(); } catch { /* ignore */ }
  try { srv.close(); } catch { /* ignore */ }
}

function seed(dshHome, doc) {
  const dir = path.join(dshHome, 'storages');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'workspace.json'), JSON.stringify(doc), 'utf8');
}

test('workspace-store: reads workspaces in dsh web order with title + sessionIds', () => {
  const dshHome = fs.mkdtempSync(path.join(os.tmpdir(), 'ws-read-'));
  seed(dshHome, {
    unit: { name: 'workspace', version: 2 },
    global: { workspaceIds: ['b', 'a'], archivedSessionIds: [] },
    tables: { workspaces: {
      a: { path: '/p/alpha', title: 'Alpha', sessionIds: ['s-1'], createdAt: 'x', updatedAt: 'y' },
      b: { path: '/p/beta', title: 'Beta', sessionIds: [], createdAt: 'x', updatedAt: 'y' },
      c: { path: '', title: 'broken' },
    } },
  });
  assert.deepEqual(readWorkspaceStore(dshHome).items.map((w) => w.workspaceId), ['b', 'a']);
  assert.deepEqual(readWorkspaceStore(dshHome).items[1], {
    workspaceId: 'a', path: '/p/alpha', title: 'Alpha', sessionIds: ['s-1'], createdAt: 'x', updatedAt: 'y',
  });
});

test('workspace-store: missing / malformed store is simply empty (never throws)', () => {
  const dshHome = fs.mkdtempSync(path.join(os.tmpdir(), 'ws-none-'));
  assert.deepEqual(readWorkspaceStore(dshHome).items, []);
  fs.mkdirSync(path.join(dshHome, 'storages'), { recursive: true });
  fs.writeFileSync(path.join(dshHome, 'storages', 'workspace.json'), '{oops', 'utf8');
  assert.deepEqual(readWorkspaceStore(dshHome).items, []);
});

test('workspace-store: a different domain version is read best-effort AND reported', () => {
  const dshHome = fs.mkdtempSync(path.join(os.tmpdir(), 'ws-ver-'));
  seed(dshHome, {
    unit: { name: 'workspace', version: 3 },
    global: { workspaceIds: ['w-1'] },
    tables: { workspaces: { 'w-1': { path: '/p/alpha', title: 'Alpha', sessionIds: [] } } },
  });
  const store = readWorkspaceStore(dshHome);
  assert.equal(store.reason, 'version');
  assert.equal(store.version, 3);
  assert.equal(store.items.length, 1, 'still readable → best-effort items');
  assert.match(describeStore(store), /understands v2/);
});

test('workspace-store: an unexpected layout is reported (never silent)', () => {
  const dshHome = fs.mkdtempSync(path.join(os.tmpdir(), 'ws-shape-'));
  seed(dshHome, { unit: { name: 'workspace', version: 2 }, global: {}, tables: {} });
  const store = readWorkspaceStore(dshHome);
  assert.equal(store.reason, 'unexpected');
  assert.deepEqual(store.items, []);
  assert.match(describeStore(store), /unexpected shape/);
});

test('workspace-store: a missing store stays quiet (that is the normal dsh <= 0.1.1 case)', () => {
  const store = readWorkspaceStore(fs.mkdtempSync(path.join(os.tmpdir(), 'ws-quiet-')));
  assert.equal(store.reason, 'missing');
  assert.equal(describeStore(store), null);
});

test('workspace-store: listWorkspaces logs a broken store through opts.log', async () => {
  const http = require('node:http');
  const dshHome = fs.mkdtempSync(path.join(os.tmpdir(), 'ws-log-'));
  seed(dshHome, { unit: { name: 'workspace', version: 9 }, global: { workspaceIds: ['w-1'] }, tables: { workspaces: { 'w-1': { path: '/p/a', title: 'A', sessionIds: [] } } } });
  const srv = await new Promise((resolve) => {
    const s = http.createServer((req, res) => { res.writeHead(404); res.end('not found'); });
    s.listen(0, '127.0.0.1', () => resolve(s));
  });
  const logged = [];
  try {
    const items = await listWorkspaces(srv.address().port, { dshHome, log: (m) => logged.push(m) });
    assert.equal(items.length, 1);
    assert.equal(logged.length, 1);
    assert.match(logged[0], /\[workspace-store\].*understands v2/);
  } finally { closeServer(srv); }
});

test('workspace-store: listWorkspaces falls back to the store when the server has no workspace.list', async () => {
  const http = require('node:http');
  const dshHome = fs.mkdtempSync(path.join(os.tmpdir(), 'ws-rpc-'));
  seed(dshHome, {
    unit: { name: 'workspace', version: 2 },
    global: { workspaceIds: ['w-1'] },
    tables: { workspaces: { 'w-1': { path: '/p/alpha', title: 'Alpha', sessionIds: [] } } },
  });
  const srv = await new Promise((resolve) => {
    const s = http.createServer((req, res) => { res.writeHead(404); res.end('not found'); });
    s.listen(0, '127.0.0.1', () => resolve(s));
  });
  try {
    const items = await listWorkspaces(srv.address().port, { dshHome });
    assert.equal(items.length, 1);
    assert.equal(items[0].path, '/p/alpha');
    assert.equal(items[0].title, 'Alpha');
  } finally { closeServer(srv); }
});

test('workspace-store: dshHomePath honours an explicit home over DSH_HOME', () => {
  assert.equal(dshHomePath('/tmp/explicit'), '/tmp/explicit');
  assert.ok(dshHomePath().endsWith('.dsh') || dshHomePath()[0] === '/');
});
