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
 *   node core/bin/ohmy-core.js upgrade next <current> <versions...>  # stepwise target (stable/rc)
 *   node core/bin/ohmy-core.js session cwd <port>
 *   node core/bin/ohmy-core.js session cwd-by-id <port> <sessionId>
 *   node core/bin/ohmy-core.js session run <port> <conversationId> <text> <workspaceRoot>
 *       -- drives a dsh session directly (debug only; no WeChat involved)
 *   node core/bin/ohmy-core.js channel route <refsJson> <conversationId> <text>
 *   node core/bin/ohmy-core.js channel normalize <eventJson>
 *   node core/bin/ohmy-core.js channel state <current> <next>
 *   node core/bin/ohmy-core.js channel login [--save <file>]
 *   node core/bin/ohmy-core.js channel login-dingtalk [--save <file>]
 *   node core/bin/ohmy-core.js channel listen <token> [--once]
 *   node core/bin/ohmy-core.js channel reply <token> <to> <text>
 *   node core/bin/ohmy-core.js settings get <key>
 *   node core/bin/ohmy-core.js settings set <key> <json>
 *   node core/bin/ohmy-core.js settings unset <key>
 *   node core/bin/ohmy-core.js settings list
 *   node core/bin/ohmy-core.js channel run <channelId> <port> <refsJson> [--dsh-home <dir>] [--dsh-token <token>]
 *   node core/bin/ohmy-core.js review sessions [--workspace <dir>] [--limit <n>] [--dsh-home <dir>]
 *   node core/bin/ohmy-core.js review audit <sessionId> [--workspace <dir>] [--dsh-home <dir>] [--max-entries <n>]
 *   node core/bin/ohmy-core.js review audit-file <path.jsonl[.zstd]> [--workspace <dir>] [--max-entries <n>]
 *       -- READ-ONLY session-log change audit (Review panel; see docs/review-panel-design.md)
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
      } else if (sub === 'next') {
        if (rest.length < 2) fail('usage: upgrade next <current> <versions...>');
        println(core.nextStepTarget(rest[0], rest.slice(1)) || '');
      } else {
        fail('usage: upgrade compare <a> <b> | latest <registry> | next <current> <versions...>');
      }
      break;
    case 'settings':
      if (sub === 'get') {
        if (!rest[0]) fail('usage: settings get <key>');
        println(JSON.stringify(core.settingsGet(rest[0])));
      } else if (sub === 'set') {
        if (!rest[0] || rest.length < 2) fail('usage: settings set <key> <json>');
        let val; try { val = JSON.parse(rest[1]); } catch { val = rest[1]; }
        core.settingsSet(rest[0], val);
        println('ok');
      } else if (sub === 'unset') {
        if (!rest[0]) fail('usage: settings unset <key>');
        core.settingsUnset(rest[0]);
        println('ok');
      } else if (sub === 'list') {
        printJson(core.settingsReadAll());
      } else if (sub === 'path') {
        println(core.settingsPath());
      } else {
        fail('usage: settings get <key> | set <key> <json> | unset <key> | list | path');
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
      } else if (sub === 'login-dingtalk') {
        // login-dingtalk [--save <file>] — DingTalk device-code app registration (QR auto-create).
        let savePath = null;
        for (let i = 0; i < rest.length; i++) { if (rest[i] === '--save') savePath = rest[i + 1] || null; }
        const qr = require('../vendor/qrcode-terminal/lib/main.js');
        const dev = require('../lib/dingtalk-device');
        const begin = await dev.beginRegistration();
        println('请用手机钉钉扫码创建应用（如二维码无法显示，可访问链接：' + begin.verificationUriComplete + '）');
        qr.generate(begin.verificationUriComplete, { small: true });
        const creds = await dev.waitForCredentials(begin);
        const out = { clientId: creds.clientId, clientSecret: creds.clientSecret };
        if (savePath) { require('fs').writeFileSync(savePath, JSON.stringify(out, null, 2), 'utf8'); }
        printJson({ connected: true, ...out, savedTo: savePath });
      } else if (sub === 'run') {
        // run <channelId> <port> <refsJson> [--dsh-home <dir>] [--project-root <root>] — live end-to-end loop
        const channelId = rest[0] || '';
        const port = parseInt(rest[1], 10);
        const refs = JSON.parse(rest[2] || '[]');
        const dshIdx = rest.indexOf('--dsh-home');
        const dshHome = dshIdx >= 0 ? rest[dshIdx + 1]
          : (process.env.DSH_HOME || (require('node:os').homedir() + '/.dsh'));
        // dsh >= 0.1.2 fences its /api RPC behind a per-instance cookie minted
        // from the launch token in the URL dsh web prints; the shell passes it.
        const tokIdx = rest.indexOf('--dsh-token');
        const dshToken = tokIdx >= 0 ? (rest[tokIdx + 1] || '') : (process.env.DSH_WEB_TOKEN || '');
        const prIdx = rest.indexOf('--project-root');
        const projectRoot = prIdx >= 0 ? rest[prIdx + 1] : '';
        if (!channelId || !Number.isInteger(port)) fail('usage: channel run <channelId> <port> <refsJson> [--dsh-home <dir>] [--project-root <root>] [--dsh-token <token>]');
        // NOTE: runWeixinChannel already wires its own onEvent handler that
        // parses slash commands FIRST and routes only ordinary text to the
        // manager. Registering an extra handler here that calls manager.enqueue
        // on every event would re-route commands into the project router and
        // emit the "该会话未绑定任何项目" hint for global commands. We only attach
        // a logging callback via opts.onEvent (receiver for both paths).
        const runner = channelId.startsWith('dingtalk') ? core.runDingTalkChannel : core.runWeixinChannel;
        const handle = await runner({
          channelId, port, refs, projectRoot, dshHome, dshToken,
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
        fail('usage: channel route <refsJson> <conversationId> <text> | normalize <eventJson> | state <current> <next> | login [--save <file>] | login-dingtalk [--save <file>] | listen <token> [--once] | reply <token> <to> <text> | run <channelId> <port> <refsJson> [--dsh-home <dir>] [--project-root <root>] [--dsh-token <token>]');
      }
      break;
    case 'review':
      {
        const flag = (name) => {
          const i = rest.indexOf('--' + name);
          return i >= 0 ? rest[i + 1] : undefined;
        };
        const dshHome = flag('dsh-home');
        const workspace = flag('workspace');
        const limitRaw = flag('limit');
        const entriesRaw = flag('max-entries');
        const maxEntries = entriesRaw === undefined ? 0 : parseInt(entriesRaw, 10) || 0;
        if (sub === 'sessions') {
          const limit = limitRaw === undefined ? 40 : parseInt(limitRaw, 10);
          printJson(core.listSessionLogs({ dshHome, workspace, limit: Number.isInteger(limit) ? limit : 40 }));
        } else if (sub === 'audit') {
          const sessionId = rest[0];
          if (!sessionId) fail('usage: review audit <sessionId> [--workspace <dir>] [--dsh-home <dir>] [--max-entries <n>]');
          const audit = core.auditSession({ sessionId, dshHome, workspace });
          if (maxEntries > 0 && audit.entries) audit.entries = audit.entries.slice(-maxEntries);
          printJson(audit);
        } else if (sub === 'audit-file') {
          const file = rest[0];
          if (!file) fail('usage: review audit-file <path.jsonl[.zstd]> [--workspace <dir>] [--max-entries <n>]');
          const audit = core.auditSessionLog({ file, workspace });
          if (maxEntries > 0 && audit.entries) audit.entries = audit.entries.slice(-maxEntries);
          printJson(audit);
        } else {
          fail('usage: review sessions [--workspace <dir>] [--limit <n>] [--dsh-home <dir>] | audit <sessionId> [--workspace <dir>] [--max-entries <n>] | audit-file <path> [--workspace <dir>] [--max-entries <n>]');
        }
      }
      break;
    default:
      fail('usage: ohmy-core { ports | serving | upgrade | session | channel | review } …');
  }
})().catch((e) => { console.error(e); process.exit(1); });
