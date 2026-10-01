// Regression tests for the shell's injected session tracker
// (main.swift: sessionTrackerScript).
//
// The tracker tells the shell which dsh session is active so the project
// directory (terminal / preview / wiki / tasks) can follow switches.
//
// dsh <= 0.1.5 emitted RPCs on window.fetch, and the non-idempotent
// subagent(s).list call was the reliable per-switch signal. dsh 0.1.7-rc.2
// removed that endpoint AND moved every Typert Remote stream (including the
// real session-open path, session/follow) onto one WebSocket frame:
//   { type: "open", streamId, endpoint, payload }
// with the identity now inside a SessionAddress (payload.args.request.address).
// These tests pin BOTH layers against the real script extracted from main.swift,
// so a silent loss of the follow signal fails here instead of in the UI.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const MAIN_SWIFT = fileURLToPath(
  new URL('../../platforms/macos/src/main.swift', import.meta.url));

function extractSwiftString(source, name) {
  const marker = `private static let ${name} = """`;
  const start = source.indexOf(marker);
  assert.notEqual(start, -1, `missing ${name} in main.swift`);
  const from = start + marker.length;
  const end = source.indexOf('"""', from);
  assert.notEqual(end, -1, `unterminated ${name} in main.swift`);
  return source.slice(from, end);
}

const script = extractSwiftString(
  readFileSync(MAIN_SWIFT, 'utf8'), 'sessionTrackerScript');

// --- environment ------------------------------------------------------------

function makeEnvironment() {
  const posted = [];
  const fetched = [];
  const sent = [];

  function WebSocket() {}
  WebSocket.OPEN = 1;
  WebSocket.prototype.send = function (data) { sent.push(data); };

  const window = {
    fetch: async (input) => {
      fetched.push(String(input));
      return { ok: true };
    },
    webkit: {
      messageHandlers: {
        dshSession: { postMessage: (m) => posted.push(m) },
      },
    },
  };
  return { window, WebSocket, posted, fetched, sent };
}

function install() {
  const env = makeEnvironment();
  // The script is an IIFE; it patches window.fetch and WebSocket.prototype.send.
  new Function('window', 'WebSocket', script)(env.window, env.WebSocket);
  return env;
}

function followFrame(endpoint, request) {
  return JSON.stringify({
    type: 'open',
    streamId: 'stream-1',
    endpoint,
    payload: { args: { request } },
  });
}

async function postFetch(env, method, payload) {
  await env.window.fetch('/api/' + method, {
    method: 'POST',
    body: JSON.stringify({ type: 'client-request', rpcId: 'rpc-1', method, payload }),
  });
}

// --- layer 2: dsh 0.1.7 WebSocket stream open -------------------------------

test('a session/follow address posts the session id', () => {
  const env = install();
  const ws = new env.WebSocket();
  ws.send(followFrame('session/follow', {
    address: { kind: 'session', sessionId: 'session-a' },
    assistantStream: true,
  }));
  assert.deepEqual(env.posted, [{ sessionId: 'session-a' }]);
  assert.equal(env.sent.length, 1, 'the frame must still be sent');
});

test('a subagent follow address posts the owning parent session', () => {
  const env = install();
  const ws = new env.WebSocket();
  ws.send(followFrame('session/follow', {
    address: {
      kind: 'subagent',
      parentSessionId: 'parent-p',
      childSessionId: 'child-c',
      mode: 'continuable',
    },
  }));
  assert.deepEqual(env.posted, [{ sessionId: 'parent-p' }]);
});

test('a session/page address also tracks (history paging starts a session)', () => {
  const env = install();
  const ws = new env.WebSocket();
  ws.send(followFrame('session/page', {
    address: { kind: 'session', sessionId: 'session-page' },
    throughSeq: 12,
  }));
  assert.deepEqual(env.posted, [{ sessionId: 'session-page' }]);
});

test('repeated frames for the same session post once (noise guard)', () => {
  const env = install();
  const ws = new env.WebSocket();
  ws.send(followFrame('session/follow', { address: { kind: 'session', sessionId: 's1' } }));
  ws.send(followFrame('session/follow', { address: { kind: 'session', sessionId: 's1' } }));
  assert.equal(env.posted.length, 1);
});

test('a session switch posts the new id', () => {
  const env = install();
  const ws = new env.WebSocket();
  ws.send(followFrame('session/follow', { address: { kind: 'session', sessionId: 's1' } }));
  ws.send(followFrame('session/follow', { address: { kind: 'session', sessionId: 's2' } }));
  assert.deepEqual(env.posted, [{ sessionId: 's1' }, { sessionId: 's2' }]);
});

test('the host-wide session/control stream does not post', () => {
  const env = install();
  const ws = new env.WebSocket();
  ws.send(followFrame('session/control', {}));
  assert.equal(env.posted.length, 0);
});

test('an unrelated stream open frame is left alone and still sent', () => {
  const env = install();
  const ws = new env.WebSocket();
  const frame = JSON.stringify({
    type: 'open', streamId: 'x', endpoint: 'workspace/follow', payload: { args: {} },
  });
  ws.send(frame);
  assert.equal(env.posted.length, 0);
  assert.deepEqual(env.sent, [frame]);
});

test('non-JSON and non-string sends pass through untouched', () => {
  const env = install();
  const ws = new env.WebSocket();
  ws.send('not json');
  ws.send(new Uint8Array([1, 2, 3]));
  assert.equal(env.posted.length, 0);
  assert.equal(env.sent.length, 2);
});

// --- layer 1: unary fetch (both generations) --------------------------------

test('a legacy flat session/prompt payload posts its sessionId', async () => {
  const env = install();
  await postFetch(env, 'session/prompt', { args: { request: { sessionId: 'legacy-1' } } });
  assert.deepEqual(env.posted, [{ sessionId: 'legacy-1' }]);
});

test('a dsh 0.1.2 subagents/list payload posts parentSessionId', async () => {
  const env = install();
  await postFetch(env, 'subagents/list', { args: { parentSessionId: 'parent-legacy' } });
  assert.deepEqual(env.posted, [{ sessionId: 'parent-legacy' }]);
});

test('a session/projections unary request posts its sessionId', async () => {
  const env = install();
  await postFetch(env, 'session/projections', { args: { request: { sessionId: 'proj-1' } } });
  assert.deepEqual(env.posted, [{ sessionId: 'proj-1' }]);
});

test('unrelated fetches pass through untouched', async () => {
  const env = install();
  await env.window.fetch('/api/session/list', { method: 'POST', body: '{}' });
  assert.deepEqual(env.fetched, ['/api/session/list']);
  assert.equal(env.posted.length, 0);
});
