'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const os = require('node:os');
const path = require('node:path');
const fs = require('node:fs');
const { saveChannelAccount, loadChannelAccount, clearChannelAccount, channelAccountPath } = require('../lib/channel-store');
const { createChannelManager, normalizeEvent } = require('../lib/channel');
const { runWeixinChannel } = require('../lib/channel-runner');

test('channel-store: save/load/clear account file (file-first)', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'chan-store-'));
  const p = saveChannelAccount('wx-test', { botToken: 'bt', accountId: 'acc', userId: 'user', baseUrl: 'https://ilinkai.weixin.qq.com' }, dir);
  assert.equal(p, channelAccountPath('wx-test', dir));
  assert.ok(fs.existsSync(p));
  const acct = loadChannelAccount('wx-test', dir);
  assert.equal(acct.botToken, 'bt');
  assert.equal(acct.userId, 'user');
  assert.ok(clearChannelAccount('wx-test', dir));
  assert.equal(loadChannelAccount('wx-test', dir), null);
});

test('channel-runner: manager sends reply carrying contextToken', async () => {
  let sent = null;
  const sessionDriver = { async run() { return { text: 'ok', media: null }; } };
  const adapters = new Map([['wx-c', { channelId: 'wx-c', onEvent() {}, async send(c, r) { sent = r; } }]]);
  const mgr = createChannelManager({
    adapters,
    refsByChannel: () => [{ channelId: 'wx-c', workspaceRoot: '/p', routing: { conversations: ['u'] } }],
    sessionDriver,
  });
  const ev = normalizeEvent({ channelId: 'wx-c', conversationId: 'u', text: 'hi' });
  ev.contextToken = 'tok-9';  // adapter attaches contextToken after normalization
  const res = await mgr.handleEvent(ev);
  assert.equal(res.reply.text, 'ok');
  assert.equal(res.reply.contextToken, 'tok-9', 'reply must carry contextToken');
  assert.equal(sent.contextToken, 'tok-9', 'adapter.send receives contextToken');
});

test('channel-runner: router no-match sends unbounded hint', async () => {
  let sent = null;
  const adapters = new Map([['wx-c', { channelId: 'wx-c', onEvent() {}, async send(c, r) { sent = r; } }]]);
  const mgr = createChannelManager({ adapters, refsByChannel: () => [], sessionDriver: null });
  const res = await mgr.handleEvent(normalizeEvent({ channelId: 'wx-c', conversationId: 'orphan', text: 'hi' }));
  assert.equal(res.routed, false);
  assert.match(sent.text, /未绑定/);
});

// Drive one inbound message through runWeixinChannel against a mock transport
// (dsh web workspace.list) and a temp store. Returns the reply text the adapter
// sent, or null if nothing was sent within the wait window.
async function runQuickCommand({ text, sessions = [], workspaces = [{ workspaceId: 'a', path: '/Users/loie/repo/alpha', title: 'Alpha' }], homeDir = '/Users/loie' }) {
  const http = require('node:http');

  const wsSrv = await new Promise((resolve) => {
    const srv = http.createServer((req, res) => {
      let body = '';
      req.on('data', (c) => { body += c; });
      req.on('end', () => {
        let rpcId = '';
        try { rpcId = JSON.parse(body).rpcId || ''; } catch { /* ignore */ }
        res.writeHead(200, { 'content-type': 'application/json' });
        if (String(req.url || '').includes('/api/workspace.list')) {
          res.end(JSON.stringify({ rpcId, result: { ok: true, value: { items: workspaces, archivedSessionIds: [] } } }));
        } else {
          res.end(JSON.stringify({ rpcId, result: { ok: true, value: null } }));
        }
      });
    });
    srv.listen(0, '127.0.0.1', () => resolve({ srv, port: srv.address().port }));
  });

  const dshHome = fs.mkdtempSync(path.join(os.tmpdir(), 'chan-run-'));
  saveChannelAccount('wx-q', { botToken: 'bt', baseUrl: 'https://x' }, dshHome);
  const projectRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'chan-pr-'));
  if (sessions.length) {
    const dir = path.join(projectRoot, '.dsh', 'channels');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'wx-q.sessions.json'), JSON.stringify({ version: 1, sessions }, null, 2));
  }

  let sent = null;
  let first = true;
  const fetchImpl = async (url, opts) => {
    const u = String(url);
    const ok = (obj) => ({ ok: true, text: async () => JSON.stringify(obj) });
    if (u.includes('getupdates')) {
      const body = JSON.parse(opts.body);
      if (first) {
        first = false;
        return ok({ ret: 0, get_updates_buf: body.get_updates_buf + 'a', msgs: [{ from_user_id: 'u-1', context_token: 'tok', item_list: [{ type: 1, text_item: { text } }], create_time_ms: Date.now(), message_id: 'm1' }] });
      }
      return ok({ ret: 0, get_updates_buf: body.get_updates_buf, msgs: [] });
    }
    if (u.includes('sendmessage')) {
      const body = JSON.parse(opts.body);
      sent = body.msg && body.msg.item_list && body.msg.item_list[0] && body.msg.item_list[0].text_item.text;
      return ok({ ret: 0 });
    }
    return ok({ ret: 0 });
  };

  const handle = await runWeixinChannel({
    channelId: 'wx-q', port: wsSrv.port, refs: [], dshHome, projectRoot, homeDir,
    transportOpts: { fetch: fetchImpl, baseUrl: 'https://x' },
    intervalMs: 50,
  });
  await handle.start();

  const deadline = Date.now() + 5000;
  while (sent === null && Date.now() < deadline) await new Promise((r) => setTimeout(r, 50));
  await handle.stop();
  wsSrv.srv.close();
  return sent;
}

test('channel-runner: #w1 quick command sets current project', async () => {
  const sent = await runQuickCommand({ text: '#w1' });
  assert.ok(sent, 'expected a reply');
  assert.match(sent, /已切换到项目/);
  assert.match(sent, /#w1 \(Alpha\): ~\/repo\/alpha/);
});

test('channel-runner: #s1 quick command sets current session', async () => {
  const sent = await runQuickCommand({
    text: '#s1',
    sessions: [{ conversationId: 'u-9', sessionId: 'sess-1', projectRoot: '/Users/loie/repo/alpha', name: '会话甲', createdAt: 1, updatedAt: 1 }],
  });
  assert.ok(sent, 'expected a reply');
  assert.match(sent, /已切换会话/);
  assert.match(sent, /#s1 \(会话甲\)/);
});
