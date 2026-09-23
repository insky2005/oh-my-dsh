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
    case 'snapshot':
      {
        const S = core.snapshot;
        const IO = core.snapshotIO;
        const flag = (name) => {
          const i = rest.indexOf('--' + name);
          return i >= 0 ? rest[i + 1] : undefined;
        };
        const home = flag('home');
        const dshHome = IO.dshHomeDir(home);
        const flagNum = (name, dflt) => {
          const raw = flag(name);
          const n = raw === undefined ? NaN : parseInt(raw, 10);
          return Number.isInteger(n) ? n : dflt;
        };
        const listPool = () => IO.defaultIO.listNames(IO.treesDir(dshHome))
          .filter((e) => e.isDirectory() && !e.name.startsWith('.'))
          .map((e) => e.name);

        if (sub === 'launch') {
          // The whole pre-spawn job: capture the running tree, snapshot when the
          // (app, dsh) combo changed, update state, prune. Must run BEFORE dsh web
          // starts: dsh writes on open, so a session can migrate the moment it runs.
          const appVersion = flag('app-version');
          const dshVersion = flag('dsh-version');
          const dshDir = flag('dsh-dir');
          const currentCombo = S.comboOf(appVersion, dshVersion);
          const state = IO.readState(dshHome);
          const decision = S.decideLaunch({ state, currentCombo });
          const tree = (flag('no-tree') === undefined && dshDir)
            ? IO.captureTree({ home: dshHome, dshDir, version: dshVersion, expectedLock: flag('expected-lock') })
            : { action: 'skipped', dir: null };
          let snapshotId = null;
          const adoptOnly = flag('no-snapshot') !== undefined;
          if (decision.action === 'snapshot' && !adoptOnly) {
            const made = IO.createSnapshot({
              home: dshHome, appVersion, dshVersion, reason: decision.reason,
              fromCombo: decision.fromCombo || currentCombo, at: new Date(),
            });
            snapshotId = made.id;
          }
          const next = state || { version: 1, history: [] };
          next.dataCombo = currentCombo;
          next.lastLaunch = { combo: currentCombo, at: new Date().toISOString() };
          // --no-snapshot: the caller (e.g. the in-app dsh upgrade) already took
          // the snapshot as part of its transaction; here we only record the new
          // combo so the next launch does not snapshot again.
          next.history = (next.history || []).concat(snapshotId
            ? [{ at: new Date().toISOString(), action: 'snapshot', snapshot: snapshotId, reason: decision.reason, fromCombo: decision.fromCombo || null, forCombo: currentCombo }]
            : []);
          IO.writeState(dshHome, next);
          const prune = IO.pruneSnapshots({ home: dshHome, keep: flagNum('keep', 3), state: next, currentCombo, currentDshVersion: dshVersion });
          const journal = S.resumePlan(IO.readJournal(dshHome));
          const mismatch = !!(next.dataCombo && dshVersion && next.dataCombo.dsh && next.dataCombo.dsh !== dshVersion);
          printJson({ ok: true, launch: decision, snapshotId, tree, prune, journal, mismatch, state: next });
        } else if (sub === 'tree') {
          // Post-boot capture: only ever pool a tree that has PROVEN it boots
          // (the shell calls this once the page has finished loading).
          const version = flag('dsh-version');
          const dir = flag('dsh-dir');
          if (!version || !dir) fail('usage: snapshot tree --dsh-version <v> --dsh-dir <path> [--expected-lock <path>] [--force] [--home <dir>]');
          const res = IO.captureTree({ home: dshHome, dshDir: dir, version, expectedLock: flag('expected-lock'), force: flag('force') !== undefined });
          printJson(Object.assign({ ok: res.action !== 'rejected' }, res));
        } else if (sub === 'list') {
          printJson({
            snapshots: IO.listSnapshots(dshHome).map((s) => ({
              id: s.id, broken: s.broken, createdAt: s.createdAt, sessions: s.sessions, bytes: s.bytes,
              reason: s.meta ? s.meta.reason : null,
              fromCombo: s.meta ? s.meta.fromCombo : null,
              forCombo: s.meta ? s.meta.forCombo : null,
              dshTree: s.meta ? s.meta.dshTree : null,
              treeAvailable: !!(s.meta && s.meta.dshTree && IO.defaultIO.exists(IO.treeDir(dshHome, String(s.meta.dshTree).replace(/^trees\//, '')))),
              restoredFrom: s.meta ? s.meta.restoredFrom : null,
            })),
            state: IO.readState(dshHome),
            pool: listPool(),
            journal: S.resumePlan(IO.readJournal(dshHome)),
          });
        } else if (sub === 'status') {
          const state = IO.readState(dshHome);
          const dshVersion = flag('dsh-version');
          printJson({
            state, pool: listPool(), snapshotCount: IO.listSnapshots(dshHome).length,
            journal: S.resumePlan(IO.readJournal(dshHome)),
            mismatch: !!(state && state.dataCombo && dshVersion && state.dataCombo.dsh !== dshVersion),
          });
        } else if (sub === 'create') {
          const reason = flag('reason');
          if (!reason) fail('usage: snapshot create --reason <bootstrap|combo-change|dsh-upgrade|pre-rollback> --app-version <A> --dsh-version <D> [--from-app <A>] [--from-dsh <D>] [--home <dir>]');
          const fromCombo = S.comboOf(flag('from-app'), flag('from-dsh'));
          // Capture the tree that is about to be left behind, so a later rollback
          // can put it back even if the .pkg replaced the whole app bundle.
          const tree = (flag('dsh-dir') && fromCombo.dsh)
            ? IO.captureTree({ home: dshHome, dshDir: flag('dsh-dir'), version: fromCombo.dsh })
            : { action: 'skipped', dir: null };
          const made = IO.createSnapshot({
            home: dshHome, appVersion: flag('app-version'), dshVersion: flag('dsh-version'), reason,
            fromCombo, at: new Date(),
          });
          printJson({ ok: true, id: made.id, dir: made.dir, meta: made.meta, clone: made.clone, tree });
        } else if (sub === 'plan-rollback') {
          const id = flag('id') || rest[0];
          const target = IO.listSnapshots(dshHome).find((s) => s.id === id);
          if (!target) fail('snapshot plan-rollback: unknown snapshot ' + String(id));
          if (target.broken) fail('snapshot plan-rollback: snapshot meta is unreadable ' + String(id));
          const treeVersion = target.meta.dshTree ? String(target.meta.dshTree).replace(/^trees\//, '') : null;
          const plan = S.planRollback({
            snapshot: target.meta,
            snapshotSessionIds: IO.snapshotSessionIds(target.dir),
            currentSessions: IO.listSessions(dshHome).map((s) => ({ id: s.id, files: s.files })),
            currentDshVersion: flag('current-dsh'),
            minSupportedDshVersion: flag('min-supported'),
            treeAvailable: !!(treeVersion && IO.defaultIO.exists(IO.treeDir(dshHome, treeVersion))),
          });
          printJson({ ok: true, target: { id: target.id, meta: target.meta }, plan, pool: listPool() });
        } else if (sub === 'rollback' || sub === 'finish-rollback') {
          const id = flag('id') || rest[0];
          const target = IO.listSnapshots(dshHome).find((s) => s.id === id);
          if (!target || target.broken) fail('snapshot rollback: unknown or unreadable snapshot ' + String(id));
          const currentApp = flag('current-app');
          const currentDsh = flag('current-dsh');
          const currentCombo = S.comboOf(currentApp, currentDsh);
          const dshDir = flag('dsh-dir');
          const treeVersion = target.meta.dshTree ? String(target.meta.dshTree).replace(/^trees\//, '') : null;
          const resume = IO.readJournal(dshHome);
          let journal = (sub === 'finish-rollback' && resume) ? resume : null;
          if (sub === 'rollback') {
            if (resume && resume.nextStep !== 'done') fail('snapshot rollback: a previous rollback is unfinished (' + resume.nextStep + '); run finish-rollback or undo first');
            if (flag('server-stopped') === undefined) fail('snapshot rollback: --server-stopped is required (the caller must stop dsh web first)');
            const stamp = S.timestampOf(new Date()) + '_rollback';
            journal = S.newJournal({ targetId: id, mode: 'B', at: new Date() });
            journal = S.advanceJournal(journal, 'stop-server', { note: 'caller stopped dsh web' });
            IO.writeJournal(dshHome, journal);
            const preId = S.snapshotId({ at: new Date(), app: currentApp, dsh: currentDsh, reason: 'pre-rollback' });
            const applied = IO.applyRollback({
              home: dshHome, target, preRollbackId: preId, preRollbackCombo: currentCombo, forCombo: target.meta.fromCombo, at: new Date(),
            });
            journal = S.advanceJournal(journal, 'snapshot-live', { note: preId });
            journal = S.advanceJournal(journal, 'restore-data', { note: applied.restored.length + ' sessions' });
            journal = S.advanceJournal(journal, 'quarantine', { note: applied.quarantined.length + ' sessions' });
            IO.writeJournal(dshHome, journal);
            if (treeVersion && dshDir && treeVersion !== currentDsh) {
              const poolDir = IO.treeDir(dshHome, treeVersion);
              // Defense in depth: a pooled tree whose lock differs from the
              // committed one is not the closure we know is good — never swap it
              // back in; let the caller install the version from the lock.
              const expected = flag('expected-lock');
              if (IO.defaultIO.exists(poolDir) && expected && IO.defaultIO.exists(expected)) {
                const have = IO.lockFingerprint(poolDir + '/package-lock.json');
                const want = IO.lockFingerprint(expected);
                if (have && want && have !== want) {
                  IO.defaultIO.remove(poolDir);
                  IO.writeJournal(dshHome, journal);
                  printJson({ ok: true, partial: true, needsTreeInstall: treeVersion, reason: 'pooled-tree-closure-mismatch', have, want, journal, applied, preRollbackId: preId, stamp });
                  return;
                }
              }
              if (!IO.defaultIO.exists(poolDir)) {
                // the caller has to npm-install that version into the pool, then call finish-rollback
                IO.writeJournal(dshHome, journal);
                printJson({ ok: true, partial: true, needsTreeInstall: treeVersion, journal, applied, preRollbackId: preId, stamp });
                return;
              }
              IO.swapTree({ home: dshHome, dshDir, toVersion: treeVersion, currentVersion: currentDsh, stamp });
            }
            journal = S.advanceJournal(journal, 'swap-tree', { note: treeVersion || 'not-needed' });
            journal = writeRollbackState();
            printJson({ ok: true, partial: false, journal, applied, preRollbackId: preId, state: IO.readState(dshHome) });
          } else {
            if (!journal) fail('snapshot finish-rollback: no unfinished rollback journal');
            if (journal.nextStep === 'swap-tree') {
              if (treeVersion && dshDir && treeVersion !== currentDsh) {
                if (!IO.defaultIO.exists(IO.treeDir(dshHome, treeVersion))) fail('snapshot finish-rollback: tree ' + treeVersion + ' still missing from the pool');
                IO.swapTree({ home: dshHome, dshDir, toVersion: treeVersion, currentVersion: currentDsh, stamp: S.timestampOf(new Date()) + '_rollback' });
              }
              journal = S.advanceJournal(journal, 'swap-tree', { note: 'finished by caller' });
            }
            printJson({ ok: true, journal: writeRollbackState(), state: IO.readState(dshHome) });
          }
          function writeRollbackState() {
            const state = IO.readState(dshHome) || { version: 1, history: [] };
            state.dataCombo = target.meta.fromCombo;
            state.rollback = { snapshot: id, at: new Date().toISOString(), pending: false };
            if (journal.mode === 'B' && treeVersion) {
              state.upgradePinned = { dsh: target.meta.fromCombo.dsh, at: new Date().toISOString(), reason: 'rollback' };
            }
            state.history = (state.history || []).concat([{ at: new Date().toISOString(), action: 'rollback', snapshot: id, toCombo: target.meta.fromCombo }]);
            IO.writeState(dshHome, state);
            journal = S.advanceJournal(journal, 'write-state', { note: 'dataCombo restored' });
            IO.writeJournal(dshHome, journal);
            IO.clearJournal(dshHome);
            return journal;
          }
        } else if (sub === 'delete') {
          const id = flag('id') || rest[0];
          if (!id) fail('usage: snapshot delete --id <snapshot-id> [--home <dir>]');
          IO.defaultIO.remove(require('node:path').join(IO.snapshotsDir(dshHome), id));
          printJson({ ok: true, deleted: id, remaining: IO.listSnapshots(dshHome).length });
        } else {
          fail('usage: snapshot launch --app-version <A> --dsh-version <D> [--dsh-dir <path>] [--home <dir>] [--keep <n>] [--no-tree]'
            + ' | tree --dsh-version <D> --dsh-dir <path> [--expected-lock <path>] [--force]'
            + ' | list [--home <dir>] | status [--dsh-version <D>] [--home <dir>]'
            + ' | create --reason <r> --app-version <A> --dsh-version <D> [--from-app <A>] [--from-dsh <D>]'
            + ' | plan-rollback --id <id> [--current-dsh <v>] [--min-supported <v>]'
            + ' | rollback --id <id> --server-stopped --current-app <A> --current-dsh <D> [--dsh-dir <path>] [--min-supported <v>]'
            + ' | finish-rollback --id <id> --current-app <A> --current-dsh <D> [--dsh-dir <path>]'
            + ' | delete --id <id>');
        }
      }
      break;
    default:
      fail('usage: ohmy-core { ports | serving | upgrade | session | channel | snapshot | review } …');
  }
})().catch((e) => { console.error(e); process.exit(1); });
