#!/usr/bin/env node
'use strict';

/**
 * core/bin/ohmy-core.js — CLI entry for the shared core.
 *
 * Lets a platform shell (macOS Swift / future Windows / Linux) invoke the
 * shared logic without embedding Node APIs directly:
 *
 *   node core/bin/ohmy-core.js ports is-free <port>
 *   node core/bin/ohmy-core.js ports free
 *   node core/bin/ohmy-core.js serving <port> [needBootMarker]
 *   node core/bin/ohmy-core.js upgrade compare <a> <b>
 *   node core/bin/ohmy-core.js upgrade latest <registry>
 *   node core/bin/ohmy-core.js session cwd <port>
 *   node core/bin/ohmy-core.js session cwd-by-id <port> <sessionId>
 *   node core/bin/ohmy-core.js channel route <refsJson> <conversationId> <text>
 *   node core/bin/ohmy-core.js channel normalize <eventJson>
 *   node core/bin/ohmy-core.js channel state <current> <next>
 */

const core = require('../index');

const [cmd, sub, ...rest] = process.argv.slice(2);

function fail(msg) {
  console.error(msg);
  process.exit(1);
}

function printJson(v) {
  process.stdout.write(JSON.stringify(v) + '\n');
}

(async () => {
  switch (cmd) {
    case 'ports':
      if (sub === 'is-free') {
        const port = parseInt(rest[0], 10);
        if (!Number.isInteger(port)) fail('usage: ports is-free <port>');
        printJson(await core.isPortFree(port));
      } else if (sub === 'free') {
        printJson(await core.freePort());
      } else {
        fail('usage: ports is-free <port> | free');
      }
      break;
    case 'serving':
      {
        const port = parseInt(rest[0], 10);
        const need = rest[1] === undefined ? true : rest[1] === '1';
        printJson(await core.isDSHServing(port, '127.0.0.1', 2000, need));
      }
      break;
    case 'upgrade':
      if (sub === 'compare') {
        if (rest.length < 2) fail('usage: upgrade compare <a> <b>');
        printJson(core.compareVersions(rest[0], rest[1]));
      } else if (sub === 'latest') {
        const reg = rest[0] || core.DEFAULT_REGISTRY;
        printJson(await core.latestVersion(reg));
      } else {
        fail('usage: upgrade compare <a> <b> | latest <registry>');
      }
      break;
    case 'session':
      if (sub === 'cwd') {
        printJson(await core.fetchActiveSessionCwd(parseInt(rest[0], 10)));
      } else if (sub === 'cwd-by-id') {
        printJson(await core.fetchSessionCwd(parseInt(rest[0], 10), rest[1]));
      } else {
        fail('usage: session cwd <port> | cwd-by-id <port> <sessionId>');
      }
      break;
    case 'channel':
      if (sub === 'route') {
        // route <refsJson> <conversationId> <text>
        const refs = JSON.parse(rest[0] || '[]');
        const event = core.normalizeEvent({ conversationId: rest[1] || '', text: rest[2] || '' });
        const router = core.createRouter();
        printJson(router.match({ event, refs }));
      } else if (sub === 'normalize') {
        printJson(core.normalizeEvent(JSON.parse(rest[0] || '{}')));
      } else if (sub === 'state') {
        const sm = core.createStateMachine(rest[0]);
        const next = rest[1];
        printJson({ from: sm.get(), to: next, ok: sm.set(next) });
      } else {
        fail('usage: channel route <refsJson> <conversationId> <text> | normalize <eventJson> | state <current> <next>');
      }
      break;
    default:
      fail('usage: ohmy-core { ports | serving | upgrade | session | channel } …');
  }
})().catch((e) => { console.error(e); process.exit(1); });
