'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const os = require('node:os');
const path = require('node:path');
const fs = require('node:fs');
const { saveChannelAccount } = require('../lib/channel-store');
const { runWeixinChannel } = require('../lib/channel-runner');
const { resolveRefBinding } = require('../lib/channel');

// Drive a sequence of ORDINARY (non-command) messages through runWeixinChannel and
// record what the mock dsh web session driver did: session.create payloads and
// prompt targets. Verifies A (session reuse) + C (workspaceId creation).
async function runOrdinarySequence(texts, { projectRoot = '/Users/loie/repo/alpha', workspaceId = 'w-1', refs = [] } = {}) {
  const http = require('node:http');
  let seq = 0;
  const creates = [];          // session.create payloads
  const prompts = [];          // prompt targets (sessionId)
  const sessions = {};         // id -> { prompted }
  const wsSrv = await new Promise((resolve) => {
    const srv = http.createServer((req, res) => {
      let body = ''; req.on('data', (c) => { body += c; }); req.on('end', () => {
        let rpcId = ''; try { rpcId = JSON.parse(body).rpcId || ''; } catch { /* ignore */ }
        res.writeHead(200, { 'content-type': 'application/json' });
        const url = String(req.url || '');
        const p = (() => { try { return JSON.parse(body).payload || {}; } catch { return {}; } })();
        if (url.includes('workspace.list')) { res.end(JSON.stringify({ rpcId, result: { ok: true, value: { items: [{ workspaceId, path: projectRoot, title: 'Alpha', sessionIds: Object.keys(sessions) }], archivedSessionIds: [] } } })); }
        else if (url.includes('session.list')) { const items = Object.keys(sessions).map((id) => ({ sessionId: id, updatedAt: 0, running: false, blank: false, cwd: projectRoot, projections: { values: { title: 's' + id } } })); res.end(JSON.stringify({ rpcId, result: { ok: true, value: { items } } })); }
        else if (url.includes('session.create')) { creates.push(p); const sid = 'sess-' + (++seq); sessions[sid] = { prompted: 0 }; res.end(JSON.stringify({ rpcId, result: { ok: true, value: { sessionId: sid } } })); }
        else if (url.includes('session.rename')) { res.end(JSON.stringify({ rpcId, result: { ok: true, value: { ok: true } } })); }
        else if (url.includes('session.prompt')) { prompts.push(p.sessionId); if (sessions[p.sessionId]) sessions[p.sessionId].prompted = 1; res.end(JSON.stringify({ rpcId, result: { ok: true, value: { accepted: true } } })); }
        else if (url.includes('session.cancel')) { res.end(JSON.stringify({ rpcId, result: { ok: true, value: { ok: true } } })); }
        else if (url.includes('session.history')) { res.end(JSON.stringify({ rpcId, result: { ok: true, value: { events: [{ event: { type: 'assistant/message', data: { message: { role: 'assistant', content: [{ type: 'text', text: 'ok-' + p.sessionId }] } } } }] } } })); }
        else { res.end(JSON.stringify({ rpcId, result: { ok: true, value: null } })); }
      });
    });
    srv.listen(0, '127.0.0.1', () => resolve({ srv, port: srv.address().port }));
  });
  const dshHome = fs.mkdtempSync(path.join(os.tmpdir(), 'chan-orb-'));
  saveChannelAccount('wx-o', { botToken: 'bt', baseUrl: 'https://x' }, dshHome);
  let sent = []; let first = true; let queued = [];
  const fetchImpl = async (url, opts) => {
    const u = String(url); const ok = (o) => ({ ok: true, text: async () => JSON.stringify(o) });
    if (u.includes('getupdates')) { const b = JSON.parse(opts.body); if (first) { first = false; return ok({ ret: 0, get_updates_buf: b.get_updates_buf + 'a', msgs: [] }); } if (queued.length) { const t = queued.shift(); return ok({ ret: 0, get_updates_buf: b.get_updates_buf + 'x', msgs: [{ from_user_id: 'u1', context_token: 't', item_list: [{ type: 1, text_item: { text: t } }], create_time_ms: Date.now(), message_id: 'm' + Date.now() }] }); } return ok({ ret: 0, get_updates_buf: b.get_updates_buf, msgs: [] }); }
    if (u.includes('sendmessage')) { const b = JSON.parse(opts.body); sent.push(b.msg.item_list && b.msg.item_list[0] && b.msg.item_list[0].text_item.text); return ok({ ret: 0 }); } return ok({ ret: 0 });
  };
  const handle = await runWeixinChannel({ channelId: 'wx-o', port: wsSrv.port, refs, dshHome, homeDir: '/Users/loie', projectRoot, transportOpts: { fetch: fetchImpl, baseUrl: 'https://x' }, intervalMs: 40 });
  await handle.start();
  const sendSeq = async (t) => { const before = sent.length; queued.push(t); const dl = Date.now() + 5000; while (sent.length <= before && Date.now() < dl) await new Promise((r) => setTimeout(r, 40)); };
  for (const t of texts) await sendSeq(t);
  await handle.stop(); wsSrv.srv.close();
  return { sent, creates, prompts };
}

test('A: ordinary messages reuse one session per conversation', async () => {
  const { creates, prompts } = await runOrdinarySequence(['第一条', '第二条', '第三条']);
  assert.equal(creates.length, 1, 'one session.create for a multi-turn conversation');
  assert.equal(prompts.length, 3, 'every turn prompts the (same) session');
  assert.equal(new Set(prompts).size, 1, 'all prompts target the same sessionId');
});

test('C: session.create uses workspaceId so the session belongs to the workspace', async () => {
  const { creates } = await runOrdinarySequence(['帮我看看项目']);
  assert.equal(creates.length, 1);
  assert.equal(creates[0].workspaceId, 'w-1');
  assert.equal(creates[0].cwd, undefined, 'no bare cwd fallback when a workspace is resolved');
});

test('B: resolveRefBinding honors explicit conversation + keyword binding (no default fallback)', () => {
  const refs = [
    { channelId: 'c', workspaceRoot: '/p/A', routing: { conversations: ['conv-9'], keywords: ['@alpha'], default: true } },
    { channelId: 'c', workspaceRoot: '/p/B', routing: { conversations: ['conv-8'], keywords: ['@beta'], default: false } },
  ];
  assert.equal(resolveRefBinding(refs, { conversationId: 'conv-9', text: 'hi' }).workspaceRoot, '/p/A', 'explicit conversation binding');
  assert.equal(resolveRefBinding(refs, { conversationId: 'x', text: '来点 @beta 活' }).workspaceRoot, '/p/B', 'keyword binding');
  assert.equal(resolveRefBinding(refs, { conversationId: 'unbound', text: '普通' }), null, 'no explicit match -> fall back to workspace-tag');
});
