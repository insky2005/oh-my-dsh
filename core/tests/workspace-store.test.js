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
const { readWorkspaceStore, listWorkspaces, dshHomePath } = require('../lib/workspace-store');

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
  } finally { srv.close(); }
});

test('workspace-store: dshHomePath honours an explicit home over DSH_HOME', () => {
  assert.equal(dshHomePath('/tmp/explicit'), '/tmp/explicit');
  assert.ok(dshHomePath().endsWith('.dsh') || dshHomePath()[0] === '/');
});
