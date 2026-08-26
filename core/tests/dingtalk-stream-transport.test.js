'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createDingTalkStreamClient } = require('../lib/dingtalk-stream-transport');

function makeFakeEnv() {
  const sockets = [];
  class FakeWS {
    constructor(url) { this.url = url; this.readyState = 0; sockets.push(this); }
    send() {}
    close() { this.readyState = 3; }
  }
  const fetchImpl = async (url) => {
    const u = String(url);
    if (u.includes('gateway')) return { ok: true, json: async () => ({ endpoint: 'wss://fake-gateway', ticket: 'tk-123' }) };
    if (u.includes('gettoken')) return { ok: true, json: async () => ({ access_token: 'tok-1' }) };
    return { ok: true, json: async () => ({}) };
  };
  return { FakeWS, sockets, fetchImpl };
}

test('stream client: connects on socket open (SDK semantics) with raw ticket', async () => {
  const env = makeFakeEnv();
  const client = createDingTalkStreamClient({
    clientId: 'a', clientSecret: 'b',
    WebSocket: env.FakeWS, fetch: env.fetchImpl,
    gatewayUrl: 'https://x/gateway', tokenUrl: 'https://x/gettoken',
  });
  const connecting = client.connect();
  await new Promise((r) => setTimeout(r, 10)); // let getEndpoint resolve + WS be created
  assert.equal(env.sockets.length, 1, 'one ws created');
  assert.equal(env.sockets[0].url, 'wss://fake-gateway?ticket=tk-123', 'raw ticket appended verbatim');
  env.sockets[0].onopen(); // SDK: connected = socket open
  await connecting;
  assert.equal(client.getState(), 'connected');
});

test('stream client: REGISTERED system frame keeps connected', async () => {
  const env = makeFakeEnv();
  const client = createDingTalkStreamClient({
    clientId: 'a', clientSecret: 'b',
    WebSocket: env.FakeWS, fetch: env.fetchImpl,
    gatewayUrl: 'https://x/gateway', tokenUrl: 'https://x/gettoken',
  });
  const connecting = client.connect();
  await new Promise((r) => setTimeout(r, 10));
  env.sockets[0].onopen();
  await connecting;
  assert.equal(client.getState(), 'connected');
  env.sockets[0].onmessage({ data: JSON.stringify({ type: 'SYSTEM', headers: { topic: 'REGISTERED' }, data: '' }) });
  assert.equal(client.getState(), 'connected');
});
