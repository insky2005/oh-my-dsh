'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { fetchActiveSessionCwd, fetchSessionCwd } = require('../lib/session');

/** Spin up a fake dsh web host answering session.list RPCs. */
function fakeHost(items) {
  return new Promise((resolve) => {
    const srv = http.createServer((req, res) => {
      let body = '';
      req.on('data', (c) => { body += c; });
      req.on('end', () => {
        const parsed = JSON.parse(body);
        res.setHeader('content-type', 'application/json');
        res.end(JSON.stringify({
          rpcId: parsed.rpcId,
          result: { ok: true, value: { items } },
        }));
      });
    });
    srv.listen(0, '127.0.0.1', () => {
      resolve({ srv, port: srv.address().port });
    });
  });
}

test('fetchActiveSessionCwd prefers running sessions, newest first', async () => {
  const { srv, port } = await fakeHost([
    { sessionId: 'a', cwd: '/old', blank: false, running: true, updatedAt: 1 },
    { sessionId: 'b', cwd: '/new', blank: false, running: true, updatedAt: 2 },
    { sessionId: 'c', cwd: '/blank', blank: true, running: false, updatedAt: 99 },
  ]);
  try {
    assert.equal(await fetchActiveSessionCwd(port), '/new');
  } finally {
    srv.close();
  }
});

test('fetchActiveSessionCwd falls back to non-running when none running', async () => {
  const { srv, port } = await fakeHost([
    { sessionId: 'a', cwd: '/older', blank: false, running: false, updatedAt: 1 },
    { sessionId: 'b', cwd: '/newer', blank: false, running: false, updatedAt: 2 },
  ]);
  try {
    assert.equal(await fetchActiveSessionCwd(port), '/newer');
  } finally {
    srv.close();
  }
});

test('fetchActiveSessionCwd returns null when nothing usable', async () => {
  const { srv, port } = await fakeHost([
    { sessionId: 'a', cwd: '/x', blank: true, running: true, updatedAt: 1 },
    { sessionId: 'b', blank: false, running: true, updatedAt: 1 }, // no cwd
  ]);
  try {
    assert.equal(await fetchActiveSessionCwd(port), null);
  } finally {
    srv.close();
  }
});

test('fetchSessionCwd resolves one session by id', async () => {
  const { srv, port } = await fakeHost([
    { sessionId: 'a', cwd: '/a', blank: false, running: true, updatedAt: 1 },
    { sessionId: 'b', cwd: '/b', blank: false, running: true, updatedAt: 2 },
  ]);
  try {
    assert.equal(await fetchSessionCwd(port, 'a'), '/a');
    assert.equal(await fetchSessionCwd(port, 'zzz'), null);
  } finally {
    srv.close();
  }
});
