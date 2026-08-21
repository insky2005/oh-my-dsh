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
 *   node core/bin/ohmy-core.js session run <port> <conversationId> <text> <workspaceRoot>
 *       -- drives a dsh session directly (debug only; no WeChat involved)
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
      } else if (sub === 'run') {
        // run <port> <conversationId> <text> <workspaceRoot> — DEBUG ONLY.
        // Drives a dsh session directly from a synthetic event; does NOT touch
        // WeChat. Use to validate the session pipeline in isolation.
        const port = parseInt(rest[0], 10);
        const conversationId = rest[1] || '';
        const text = rest[2] || '';
        const workspaceRoot = rest[3];
        if (!Number.isInteger(port) || !conversationId || !workspaceRoot) {
          fail('usage: session run <port> <conversationId> <text> <workspaceRoot>');
        }
        const driver = core.createSessionDriver({ port });
        const ref = { channelId: 'cli', workspaceRoot, routing: { conversations: [conversationId] } };
        const event = core.normalizeEvent({ channelId: 'cli', conversationId, text, platform: 'cli' });
        const reply = await driver.run(event, ref);
        printJson(reply);
      } else {
        fail('usage: session cwd <port> | cwd-by-id <port> <sessionId> | run <port> <conversationId> <text> <workspaceRoot>');
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
      } else if (sub === 'login') {
        let savePath = null;
        for (let i = 0; i < rest.length; i++) { if (rest[i] === '--save') savePath = rest[i + 1] || null; }
        const qr = require('../vendor/qrcode-terminal/lib/main.js');
        const transport = core.createWeixinClawBotTransport({});
        const started = await transport.startLogin();
        process.stdout.write('\n请用手机微信扫描下方二维码以连接（如二维码无法显示，可访问链接：');
        process.stdout.write(started.qrcodeUrl);
        process.stdout.write('）\n\n');
        qr.generate(started.qrcodeUrl, { small: true });
        const result = await transport.waitForLogin({ qrcode: started.qrcode, timeoutMs: 480000 });
        if (result.connected) {
          const out = { botToken: result.botToken, accountId: result.accountId, userId: result.userId, baseUrl: result.baseUrl };
          if (savePath) { fs.writeFileSync(savePath, JSON.stringify(out, null, 2), 'utf8'); }
          printJson({ connected: true, ...out, savedTo: savePath });
        } else {
          printJson(result);
        }
      } else if (sub === 'listen') {
        const token = rest[0] || '';
        const once = rest.includes('--once');
        if (!token) fail('usage: channel listen <token> [--once]');
        const transport = core.createWeixinClawBotTransport({ token });
        await transport.connect();
        if (once) {
          const updates = await transport.fetchUpdates();
          printJson(updates);
          process.exit(0);
        }
        process.stdout.write('listening (Ctrl+C to stop)\n');
        while (true) {
          try {
            const updates = await transport.fetchUpdates();
            for (const u of updates) { printJson(u); }
          } catch (e) {
            process.stderr.write('listen error: ' + (e && e.message || String(e)) + '\n');
            if (e && e.code === -14) { process.stderr.write('token expired (-14), re-login needed\n'); process.exit(2); }
            await new Promise((r) => setTimeout(r, 2000));
          }
        }
      } else if (sub === 'reply') {
        const token = rest[0] || '';
        const to = rest[1] || '';
        const text = rest.slice(2).join(' ') || '';
        if (!token || !to) fail('usage: channel reply <token> <to> <text>');
        const transport = core.createWeixinClawBotTransport({ token });
        const res = await transport.sendMessage({ conversationId: to, text });
        printJson({ sent: true, to, messageId: res.messageId });
      } else {
        fail('usage: channel route <refsJson> <conversationId> <text> | normalize <eventJson> | state <current> <next> | login [--save <file>] | listen <token> [--once] | reply <token> <to> <text>');
      }
      break;
    default:
      fail('usage: ohmy-core { ports | serving | upgrade | session | channel } …');
  }
})().catch((e) => { console.error(e); process.exit(1); });
