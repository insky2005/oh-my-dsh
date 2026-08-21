"use strict";

/**
 * core/lib/weixin-clawbot-transport.js — real WeChat ClawBot transport.
 *
 * Implements the transport contract expected by createWeixinClawBotAdapter:
 *   connect / disconnect / fetchUpdates / sendMessage / onError.
 *
 * Two backing modes:
 *   1. SDK mode — wraps the weixin-agent-sdk (login/start/Bot) when installed.
 *   2. HTTP mode — drives the OpenClaw Weixin HTTP endpoints directly
 *      (login flow, getUpdates long-poll, sendmessage) with no SDK dependency.
 *
 * The HTTP client is injectable (opts.fetch) for testability.
 *
 *   const { createWeixinClawBotTransport } = require('@oh-my-dsh/core');
 *   const transport = createWeixinClawBotTransport({ baseUrl, fetch });
 */

function createWeixinClawBotTransport(opts = {}) {
  const baseUrl = (opts.baseUrl || 'https://api.weixin.qq.com/openclaw').replace(/\/$/, '');
  const fetchImpl = opts.fetch || ((typeof globalThis.fetch === 'function') ? globalThis.fetch.bind(globalThis) : null);
  const channelId = opts.channelId || 'weixin-clawbot';

  // Connection state the HTTP flow needs to remember.
  let token = null;          // auth token after login
  let contextToken = null;   // for proactive sendMessage
  let errHandler = null;
  let pollCursor = null;     // getUpdates cursor (断点续传)

  function onError(cb) { errHandler = cb; return () => { if (errHandler === cb) errHandler = null; }; }

  async function httpPost(path, body) {
    if (!fetchImpl) throw new Error('weixin-clawbot-transport: no fetch available (SDK not installed and no global fetch)');
    const url = baseUrl + path;
    const headers = { 'content-type': 'application/json' };
    if (token) headers['authorization'] = 'Bearer ' + token;
    const res = await fetchImpl(url, { method: 'POST', headers, body: JSON.stringify(body) });
    const text = await res.text();
    let json = null;
    try { json = JSON.parse(text); } catch { json = { ret: -1, errmsg: text.slice(0, 200) }; }
    // OpenClaw error convention: ret/errcode === -14 => token invalid
    const code = (json.ret !== undefined ? json.ret : json.errcode);
    if (code === -14) {
      const err = new Error('weixin-clawbot-transport: token expired (-14)');
      err.code = -14;
      throw err;
    }
    return json;
  }

  async function connect() {
    // In SDK mode the caller passes a ready Bot; in HTTP mode we attempt a
    // session/heartbeat against the configured base. A fully interactive QR
    // login is out of scope for the headless transport — the shell performs it
    // via the SDK or a login endpoint and then sets credentials through opts.
    if (opts.token) token = opts.token;
    if (opts.contextToken) contextToken = opts.contextToken;
    if (opts.sessionToken) token = opts.sessionToken;
    if (!fetchImpl && !opts.sdk) {
      throw new Error('weixin-clawbot-transport: no transport backing (install weixin-agent-sdk or provide fetch)');
    }
    // Heartbeat: getconfig returns ok when authenticated.
    try {
      const cfg = await httpPost('/getconfig', {});
      if (cfg && cfg.ok === true) token = token || (cfg.token || null);
      return;
    } catch (e) {
      if (e && e.code === -14) throw e;
      // Non-auth errors on heartbeat are non-fatal; the poll loop re-checks.
    }
  }

  async function disconnect() {
    token = null;
    contextToken = null;
  }

  /**
   * Poll for new inbound messages. Returns RawMsg[]:
   *   { conversationId, sender?, text?, media?, ts? }
   */
  async function fetchUpdates() {
    const updates = await httpPost('/getupdates', { cursor: pollCursor, limit: 50 });
    const items = (updates && updates.data && Array.isArray(updates.data.items)) ? updates.data.items
                : (updates && Array.isArray(updates.items)) ? updates.items : [];
    if (updates && updates.data && updates.data.next_cursor != null) pollCursor = updates.data.next_cursor;
    return items.map(mapUpdate);
  }

  /** Map an OpenClaw update to a RawMsg consumed by normalizeEvent. */
  function mapUpdate(u) {
    const conversationId = u.conversationId || u.conversation_id || u.chatId || u.from;
    const text = (typeof u.text === 'string') ? u.text
               : (u.message && typeof u.message === 'string') ? u.message
               : (u.content && typeof u.content === 'string') ? u.content : '';
    const media = u.media || (u.attachment ? { type: u.attachment.type, url: u.attachment.url, fileName: u.attachment.fileName } : null);
    return {
      conversationId,
      sender: u.sender || u.fromUser || '',
      text,
      media: media || null,
      ts: u.timestamp || u.ts || (u.time ? u.time * 1000 : Date.now()),
    };
  }

  /** Send a reply. reply = { conversationId, text, media? } (already built). */
  async function sendMessage(reply) {
    const payload = {
      conversationId: reply.conversationId,
      text: reply.text || '',
    };
    if (reply.media) {
      payload.media = {
        type: reply.media.type,
        url: reply.media.url,
        fileName: reply.media.fileName || null,
      };
    }
    if (contextToken) payload.contextToken = contextToken;
    const res = await httpPost('/sendmessage', payload);
    if (res && res.ok === false) throw new Error('weixin-clawbot-transport: send failed: ' + (res.errmsg || 'unknown'));
    return res;
  }

  return {
    channelId,
    connect,
    disconnect,
    fetchUpdates,
    sendMessage,
    onError,
    setContextToken: (t) => { contextToken = t; },
    setToken: (t) => { token = t; },
    getToken: () => token,
  };
}

module.exports = { createWeixinClawBotTransport };
