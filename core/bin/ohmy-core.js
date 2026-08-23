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
 *   node core/bin/ohmy-core.js session run <port> <conversationId> <text> <workspaceRoot>
 *       -- drives a dsh session directly (debug only; no WeChat involved)
 *   node core/bin/ohmy-core.js channel route <refsJson> <conversationId> <text>
 *   node core/bin/ohmy-core.js channel normalize <eventJson>
 *   node core/bin/ohmy-core.js channel state <current> <next>
 *   node core/bin/ohmy-core.js channel login [--save <file>]
 *   node core/bin/ohmy-core.js channel listen <token> [--once]
 *   node core/bin/ohmy-core.js channel reply <token> <to> <text>
 *   node core/bin/ohmy-core.js channel run <channelId> <port> <refsJson> [--dsh-home <dir>]
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

function println(s) {
  process.stdout.write(s + '\n');
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
        // login [--save <file>] — QR login, render QR, poll until confirmed
        let savePath = null;
        for (let i = 0; i < rest.length; i++) { if (rest[i] === '--save') savePath = rest[i + 1] || null; }
        const qr = require('../vendor/qrcode-terminal/lib/main.js');
        const transport = core.createWeixinClawBotTransport({});
        const started = await transport.startLogin();
        println('请用手机微信扫描下方二维码以连接（如二维码无法显示，可访问链接：' + started.qrcodeUrl + '）');
        qr.generate(started.qrcodeUrl, { small: true });
        const result = await transport.waitForLogin({ qrcode: started.qrcode, timeoutMs: 480000 });
        if (result.connected) {
          const out = { botToken: result.botToken, accountId: result.accountId, userId: result.userId, baseUrl: result.baseUrl };
          if (savePath) { require('fs').writeFileSync(savePath, JSON.stringify(out, null, 2), 'utf8'); }
          printJson({ connected: true, ...out, savedTo: savePath });
        } else {
          printJson(result);
        }
      } else if (sub === 'listen') {
        // listen <token> [--once]
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
        println('listening (Ctrl+C to stop)');
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
        // reply <token> <to> <text>
        const token = rest[0] || '';
        const to = rest[1] || '';
        const text = rest.slice(2).join(' ') || '';
        if (!token || !to) fail('usage: channel reply <token> <to> <text>');
        const transport = core.createWeixinClawBotTransport({ token });
        const res = await transport.sendMessage({ conversationId: to, text });
        printJson({ sent: true, to, messageId: res.messageId });
      } else if (sub === 'run') {
        // run <channelId> <port> <refsJson> [--dsh-home <dir>] [--project-root <root>] — live end-to-end loop
        const channelId = rest[0] || '';
        const port = parseInt(rest[1], 10);
        const refs = JSON.parse(rest[2] || '[]');
        const dshIdx = rest.indexOf('--dsh-home');
        const dshHome = dshIdx >= 0 ? rest[dshIdx + 1] : (require('node:os').homedir() + '/.dsh');
        const prIdx = rest.indexOf('--project-root');
        const projectRoot = prIdx >= 0 ? rest[prIdx + 1] : '';
        if (!channelId || !Number.isInteger(port)) fail('usage: channel run <channelId> <port> <refsJson> [--dsh-home <dir>] [--project-root <root>]');
        // NOTE: runWeixinChannel already wires its own onEvent handler that
        // parses slash commands FIRST and routes only ordinary text to the
        // manager. Registering an extra handler here that calls manager.enqueue
        // on every event would re-route commands into the project router and
        // emit the "该会话未绑定任何项目" hint for global commands. We only attach
        // a logging callback via opts.onEvent (receiver for both paths).
        const handle = await core.runWeixinChannel({
          channelId, port, refs, projectRoot, dshHome,
          onEvent: (event, result) => {
            const replyText = result && result.reply && result.reply.text;
            println('handled: ' + JSON.stringify({ conversationId: event.conversationId, text: event.text, reply: replyText }));
          },
        });
        println('channel ' + channelId + ' running (Ctrl+C to stop)');
        await handle.start();
        // Exit promptly on signal; best-effort disconnect (don't wait on the
        // network notifyStop which can hang and leave a zombie runner).
        const stop = () => { handle.stop().catch(() => {}); process.exit(0); };
        process.on('SIGINT', stop); process.on('SIGTERM', stop);
        setInterval(() => {}, 1 << 30);
      } else {
        fail('usage: channel route <refsJson> <conversationId> <text> | normalize <eventJson> | state <current> <next> | login [--save <file>] | listen <token> [--once] | reply <token> <to> <text> | run <channelId> <port> <refsJson> [--dsh-home <dir>]');
      }
      break;
    default:
      fail('usage: ohmy-core { ports | serving | upgrade | session | channel } …');
  }
})().catch((e) => { console.error(e); process.exit(1); });
