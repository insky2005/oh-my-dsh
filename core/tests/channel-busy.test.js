'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const os = require('node:os');
const path = require('node:path');
const fs = require('node:fs');
const { saveChannelAccount } = require('../lib/channel-store');
const { runWeixinChannel } = require('../lib/channel-runner');

// Busy gate: while one generation is in-flight for a conversation, further
// messages get 请等待 and are NOT queued. A gate on session.history holds the
// first generation open so we can observe the busy state deterministically.
test('busy gate: in-flight generation blocks next message (请等待), answer pushed on completion', async () => {
  const http = require('node:http');
  let seq = 0;
  let release = null;
  const gate = new Promise((res) => { release = res; });
  const creates = [];
  const sessions = {};
  const srv = await new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      let body = ''; req.on('data', (c) => { body += c; }); req.on('end', async () => {
        let rpcId = ''; try { rpcId = JSON.parse(body).rpcId || ''; } catch { /* ignore */ }
        res.writeHead(200, { 'content-type': 'application/json' });
        const url = String(req.url || '');
        const p = (() => { try { return JSON.parse(body).payload || {}; } catch { return {}; } })();
        if (url.includes('workspace.list')) { res.end(JSON.stringify({ rpcId, result: { ok: true, value: { items: [{ workspaceId: 'w-1', path: '/Users/loie/repo/alpha', title: 'Alpha', sessionIds: Object.keys(sessions) }], archivedSessionIds: [] } } })); }
        else if (url.includes('session.list')) { const items = Object.keys(sessions).map((id) => ({ sessionId: id, updatedAt: 0, running: false, blank: false, cwd: '/Users/loie/repo/alpha', projections: { values: { title: 's' + id } } })); res.end(JSON.stringify({ rpcId, result: { ok: true, value: { items } } })); }
        else if (url.includes('session.create')) { creates.push(p); const sid = 'sess-' + (++seq); sessions[sid] = { prompted: 0 }; res.end(JSON.stringify({ rpcId, result: { ok: true, value: { sessionId: sid } } })); }
        else if (url.includes('session.rename')) { res.end(JSON.stringify({ rpcId, result: { ok: true, value: { ok: true } } })); }
        else if (url.includes('session.prompt')) { if (sessions[p.sessionId]) sessions[p.sessionId].prompted = 1; res.end(JSON.stringify({ rpcId, result: { ok: true, value: { accepted: true } } })); }
        else if (url.includes('session.cancel')) { res.end(JSON.stringify({ rpcId, result: { ok: true, value: { ok: true } } })); }
        else if (url.includes('session.history')) { await gate; res.end(JSON.stringify({ rpcId, result: { ok: true, value: { events: [{ event: { type: 'assistant/message', data: { message: { role: 'assistant', content: [{ type: 'text', text: '答案-' + (p.sessionId || '') }] } } } }] } } })); }
        else { res.end(JSON.stringify({ rpcId, result: { ok: true, value: null } })); }
      });
    });
    server.listen(0, '127.0.0.1', () => resolve({ srv: server, port: server.address().port }));
  });

  const dshHome = fs.mkdtempSync(path.join(os.tmpdir(), 'chan-busy-'));
  saveChannelAccount('wx-b', { botToken: 'bt', baseUrl: 'https://x' }, dshHome);
  const sent = []; let first = true; const queued = [];
  const fetchImpl = async (url, opts) => {
    const u = String(url); const ok = (o) => ({ ok: true, text: async () => JSON.stringify(o) });
    if (u.includes('getupdates')) { const b = JSON.parse(opts.body); if (first) { first = false; return ok({ ret: 0, get_updates_buf: b.get_updates_buf + 'a', msgs: [] }); } if (queued.length) { const t = queued.shift(); return ok({ ret: 0, get_updates_buf: b.get_updates_buf + 'x', msgs: [{ from_user_id: 'u1', context_token: 't', item_list: [{ type: 1, text_item: { text: t } }], create_time_ms: Date.now(), message_id: 'm' + Date.now() }] }); } return ok({ ret: 0, get_updates_buf: b.get_updates_buf, msgs: [] }); }
    if (u.includes('sendmessage')) { const b = JSON.parse(opts.body); sent.push(b.msg.item_list && b.msg.item_list[0] && b.msg.item_list[0].text_item.text); return ok({ ret: 0 }); } return ok({ ret: 0 });
  };
  const handle = await runWeixinChannel({ channelId: 'wx-b', port: srv.port, refs: [], dshHome, homeDir: '/Users/loie', projectRoot: '/Users/loie/repo/alpha', transportOpts: { fetch: fetchImpl, baseUrl: 'https://x' }, intervalMs: 30 });
  await handle.start();
  const push = async (t) => { queued.push(t); };
  const waitFor = async (pred) => { const dl = Date.now() + 5000; while (Date.now() < dl) { if (pred()) return true; await new Promise((r) => setTimeout(r, 30)); } return false; };

  // msg1 starts a generation (typing indicator is a no-op in the mock transport,
  // so there is no "处理中" text any more). The generation blocks on the gate.
  await push('第一问');
  // while still in-flight, msg2 -> 请等待 (proves msg1 is busy, not queued)
  await push('第二问');
  assert.ok(await waitFor(() => sent.some((s) => /请等待/.test(s))), 'msg2 gets 请等待: ' + JSON.stringify(sent));
  assert.equal(creates.length, 1, 'msg2 was not queued (only one session.create)');
  // release the gate -> msg1 answer pushed
  release();
  assert.ok(await waitFor(() => sent.some((s) => /答案-sess-1/.test(s))), 'msg1 answer pushed: ' + JSON.stringify(sent));
  assert.equal(creates.length, 1);

  await handle.stop(); srv.srv.close();
});