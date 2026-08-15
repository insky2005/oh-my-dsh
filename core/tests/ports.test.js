'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const net = require('node:net');
const http = require('node:http');
const { isPortFree, freePort, pickPort, isDSHServing } = require('../lib/ports');

function listenOnce(handler) {
  return new Promise((resolve) => {
    const srv = net.createServer(handler);
    srv.listen(0, '127.0.0.1', () => resolve(srv));
  });
}

test('isPortFree: occupied port is not free, free port is free', async () => {
  const srv = await listenOnce();
  const { port } = srv.address();
  assert.equal(await isPortFree(port), false, 'occupied port must be busy');
  await new Promise((r) => srv.close(r));
  assert.equal(await isPortFree(port), true, 'closed port must be free');
});

test('freePort returns a usable free port', async () => {
  const port = await freePort();
  assert.ok(Number.isInteger(port) && port > 0 && port < 65536);
  assert.equal(await isPortFree(port), true);
});

test('pickPort: explicit override wins', async () => {
  assert.equal(await pickPort(3080, 9123), 9123);
});

test('pickPort: preferred when free, else a free port', async () => {
  const srv = await listenOnce();
  const { port } = srv.address();
  // preferred (port) is occupied → must pick a different free port
  const picked = await pickPort(port);
  assert.ok(picked !== port);
  assert.equal(await isPortFree(picked), true);
  await new Promise((r) => srv.close(r));
});

test('isDSHServing: detects the __DSH_BOOT__ marker', async () => {
  const html = '<html><script>window.__DSH_BOOT__={}</script></html>';
  const srv = http.createServer((req, res) => { res.end(html); });
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  const { port } = srv.address();
  assert.equal(await isDSHServing(port), true);
  assert.equal(await isDSHServing(port, '127.0.0.1', 2000, false), true); // any body
  await new Promise((r) => srv.close(r));
  assert.equal(await isDSHServing(port), false); // nothing listening
});
