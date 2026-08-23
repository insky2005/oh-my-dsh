'use strict';

/**
 * Channel transport tests — exercise the ClawBot iLink transport against a
 * mock HTTP host. No live dsh web, no session creation.
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createWeixinClawBotTransport } = require('../lib/weixin-clawbot-transport');

test('e2e: transport maps official iLink getupdates to RawMsg', async () => {
  let gotUrl = null, gotBody = null, gotAuth = null;
  const fetchImpl = async (url, opts) => {
    gotUrl = url;
    gotBody = JSON.parse(opts.body);
    gotAuth = opts.headers.Authorization;
    // official getupdates response shape: { ret, msgs:[{from_user_id,item_list:[{type:1,text_item:{text}}],context_token,create_time_ms}], get_updates_buf }
    return { ok: true, text: async () => JSON.stringify({
      ret: 0,
      get_updates_buf: 'buf-123',
      msgs: [{ from_user_id: 'wx-9', context_token: 'tok', item_list: [{ type: 1, text_item: { text: 'hi' } }], create_time_ms: 1787316000000 }],
    }) };
  };
  const transport = createWeixinClawBotTransport({ baseUrl: 'https://ilinkai.weixin.qq.com', token: 'bt', fetch: fetchImpl });
  await transport.connect();
  const updates = await transport.fetchUpdates();
  assert.equal(updates.length, 1);
  assert.equal(updates[0].conversationId, 'wx-9');
  assert.equal(updates[0].text, 'hi');
  assert.equal(updates[0].contextToken, 'tok');
  assert.ok(gotUrl.includes('ilink/bot/getupdates'));
  assert.equal(gotAuth, 'Bearer bt');
  assert.ok(gotBody.base_info && gotBody.base_info.bot_agent === 'OpenClaw');
  assert.equal(transport._getGetUpdatesBuf(), 'buf-123');
});

test('e2e: transport -14 (stale token) -> fetchUpdates throws code -14', async () => {
  const fetchImpl = async () => ({ ok: true, text: async () => JSON.stringify({ ret: -14, errmsg: 'stale' }) });
  const transport = createWeixinClawBotTransport({ baseUrl: 'https://ilinkai.weixin.qq.com', token: 'bt', fetch: fetchImpl });
  await transport.connect();
  await assert.rejects(() => transport.fetchUpdates(), (e) => e.code === -14);
});

test('e2e: transport connect without token rejects', async () => {
  const fetchImpl = async () => ({ ok: true, text: async () => '{}' });
  const transport = createWeixinClawBotTransport({ baseUrl: 'https://ilinkai.weixin.qq.com', fetch: fetchImpl });
  await assert.rejects(() => transport.connect(), /no bot token/);
});

test('e2e: transport sendMessage builds official payload', async () => {
  let gotUrl = null, gotBody = null;
  const fetchImpl = async (url, opts) => {
    gotUrl = url; gotBody = JSON.parse(opts.body);
    return { ok: true, text: async () => JSON.stringify({ ret: 0 }) };
  };
  const transport = createWeixinClawBotTransport({ baseUrl: 'https://ilinkai.weixin.qq.com', token: 'bt', fetch: fetchImpl });
  await transport.sendMessage({ conversationId: 'wx-9', text: 'hello', contextToken: 'tok' });
  assert.ok(gotUrl.includes('ilink/bot/sendmessage'));
  assert.equal(gotBody.msg.to_user_id, 'wx-9');
  assert.equal(gotBody.msg.message_type, 2);
  assert.equal(gotBody.msg.message_state, 2);
  assert.equal(gotBody.msg.item_list[0].type, 1);
  assert.equal(gotBody.msg.item_list[0].text_item.text, 'hello');
  assert.equal(gotBody.msg.context_token, 'tok');
  assert.equal(gotBody.base_info.bot_agent, 'OpenClaw');
});

test('e2e: transport QR login flow (startLogin + waitForLogin confirmed)', async () => {
  let calls = [];
  const fetchImpl = async (url, opts) => {
    calls.push(url);
    if (url.includes('get_bot_qrcode')) {
      return { ok: true, text: async () => JSON.stringify({ qrcode: 'QR1', qrcode_img_content: 'https://qr/url' }) };
    }
    if (url.includes('get_qrcode_status')) {
      return { ok: true, text: async () => JSON.stringify({ status: 'confirmed', bot_token: 'BT', ilink_bot_id: 'bot-1', ilink_user_id: 'user-1', baseurl: 'https://ilinkai.weixin.qq.com' }) };
    }
    return { ok: true, text: async () => '{}' };
  };
  const transport = createWeixinClawBotTransport({ baseUrl: 'https://ilinkai.weixin.qq.com', fetch: fetchImpl });
  const started = await transport.startLogin();
  assert.equal(started.qrcode, 'QR1');
  assert.match(calls[0], /get_bot_qrcode/);
  const res = await transport.waitForLogin({ qrcode: started.qrcode });
  assert.equal(res.connected, true);
  assert.equal(res.botToken, 'BT');
  assert.equal(transport.getToken(), 'BT');
});

test('e2e: getConfig returns typing_ticket; sendTyping sends status + ticket + user id', async () => {
  const calls = [];
  const fetchImpl = async (url, opts) => {
    calls.push({ url: String(url), body: JSON.parse(opts.body) });
    const u = String(url);
    if (u.includes('getconfig')) return { ok: true, text: async () => JSON.stringify({ ret: 0, typing_ticket: 'TICKET-ABC' }) };
    if (u.includes('sendtyping')) return { ok: true, text: async () => JSON.stringify({ ret: 0 }) };
    return { ok: true, text: async () => '{}' };
  };
  const transport = createWeixinClawBotTransport({ baseUrl: 'https://ilinkai.weixin.qq.com', token: 'bt', userId: 'U-9', fetch: fetchImpl });

  // typing without a cached ticket -> getConfig first, then sendTyping
  await transport.sendTyping({ status: 1, contextToken: 'ctx-1' });
  assert.equal(calls[0].url.includes('ilink/bot/getconfig'), true, 'getConfig called first: ' + calls[0].url);
  assert.equal(calls[0].body.ilink_user_id, 'U-9');
  assert.equal(calls[0].body.context_token, 'ctx-1');
  assert.ok(calls[0].body.base_info, 'getConfig carries base_info');
  assert.equal(calls[1].url.includes('ilink/bot/sendtyping'), true, 'sendtyping called: ' + calls[1].url);
  assert.equal(calls[1].body.ilink_user_id, 'U-9');
  assert.equal(calls[1].body.typing_ticket, 'TICKET-ABC');
  assert.equal(calls[1].body.status, 1);
  assert.ok(calls[1].body.base_info, 'sendTyping carries base_info');

  // cancel typing: ticket is now cached, so no second getConfig
  await transport.sendTyping({ status: 2 });
  assert.equal(calls[2].url.includes('ilink/bot/sendtyping'), true);
  assert.equal(calls[2].body.status, 2);
  assert.equal(calls.length, 3, 'cached ticket -> no extra getConfig call');
});
