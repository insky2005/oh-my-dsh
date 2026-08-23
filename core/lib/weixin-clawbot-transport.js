'use strict';

/**
 * core/lib/weixin-clawbot-transport.js — WeChat ClawBot transport.
 *
 * Implements the transport contract expected by createWeixinClawBotAdapter:
 *   connect / disconnect / fetchUpdates / sendMessage / onError
 *   plus login helpers: startLogin / waitForLogin / notifyStart / notifyStop
 *
 * THIS IS A PURE IMPLEMENTATION OF THE OFFICIAL iLink BOT PROTOCOL, derived
 * directly from the official package source
 * (@tencent-weixin/openclaw-weixin, Tencent, MIT; latest 2.4.6) — NOT from
 * any third-party reverse-engineering. Endpoints, headers, request/response
 * shapes, token semantics and QR login state machine all mirror the official
 * implementation exactly.
 *
 * Official constants (from the official source):
 *   - Base URL:  https://ilinkai.weixin.qq.com
 *   - CDN base:  https://novac2c.cdn.weixin.qq.com/c2c
 *   - iLink-App-Id: "bot"  (package.json ilink_appid)
 *   - bot_type for QR: "3"
 *   - Stale-token errcode: -14  -> must pause/relogin
 *
 *   const { createWeixinClawBotTransport } = require('@oh-my-dsh/core');
 */

const crypto = require('node:crypto');

/** Official fixed base URL. */
const DEFAULT_BASE_URL = 'https://ilinkai.weixin.qq.com';
/** Official bot_type used for QR login. */
const DEFAULT_ILINK_BOT_TYPE = '3';
/** Official iLink-App-Id (package.json ilink_appid). */
const ILINK_APP_ID = 'bot';
/** Client version header as uint32 0x00MMNNPP (mirrors official buildClientVersion). */
function buildClientVersion(version) {
  const parts = version.split('.').map((p) => parseInt(p, 10));
  const major = parts[0] || 0;
  const minor = parts[1] || 0;
  const patch = parts[2] || 0;
  return ((major & 0xff) << 16) | ((minor & 0xff) << 8) | (patch & 0xff);
}
const CLIENT_VERSION = buildClientVersion('2.4.6');
/** Stale-token errcode (official STALE_TOKEN_ERRCODE). */
const STALE_TOKEN_ERRCODE = -14;
/** Long-poll default timeout (official DEFAULT_LONG_POLL_TIMEOUT_MS). */
const DEFAULT_LONG_POLL_TIMEOUT_MS = 35000;
/** Regular API default timeout (official DEFAULT_API_TIMEOUT_MS). */
const DEFAULT_API_TIMEOUT_MS = 15000;
/** Lightweight API default timeout (official DEFAULT_CONFIG_TIMEOUT_MS). */
const DEFAULT_CONFIG_TIMEOUT_MS = 10000;

/** Message item types (official MessageItemType). */
const MessageItemType = { NONE: 0, TEXT: 1, IMAGE: 2, VOICE: 3, FILE: 4, VIDEO: 5 };
/** Message type (official MessageType). */
const MessageType = { NONE: 0, USER: 1, BOT: 2 };
/** Message state (official MessageState). */
const MessageState = { NEW: 0, GENERATING: 1, FINISH: 2 };

/** X-WECHAT-UIN header: random uint32 -> decimal string -> base64 (official). */
function randomWechatUin() {
  const uint32 = crypto.randomBytes(4).readUInt32BE(0);
  return Buffer.from(String(uint32), 'utf-8').toString('base64');
}

/**
 * Create the transport. opts:
 *   baseUrl      - override base (defaults to official ilinkai.weixin.qq.com)
 *   token        - bot token (from a prior confirmed login, or set after login)
 *   fetch        - injectable fetch (for tests); defaults to globalThis.fetch
 *   clientVersion- override the iLink-App-ClientVersion uint32
 *   botType      - QR bot_type (default "3")
 */
function createWeixinClawBotTransport(opts = {}) {
  const baseUrl = (opts.baseUrl || DEFAULT_BASE_URL).replace(/\/$/, '');
  const fetchImpl = opts.fetch || (typeof globalThis.fetch === 'function' ? globalThis.fetch.bind(globalThis) : null);
  const botType = opts.botType || DEFAULT_ILINK_BOT_TYPE;
  const clientVersion = opts.clientVersion != null ? opts.clientVersion : CLIENT_VERSION;
  const channelId = opts.channelId || 'weixin-clawbot';

  let token = opts.token || null;
  let userId = opts.userId || null;
  let typingTicket = null;
  let errHandler = null;
  let getUpdatesBuf = '';

  function onError(cb) { errHandler = cb; return () => { if (errHandler === cb) errHandler = null; }; }

  /** Common headers (official buildCommonHeaders). */
  function commonHeaders() {
    return {
      'iLink-App-Id': ILINK_APP_ID,
      'iLink-App-ClientVersion': String(clientVersion),
    };
  }
  /** POST headers (official buildHeaders). */
  function postHeaders() {
    const h = {
      'Content-Type': 'application/json',
      AuthorizationType: 'ilink_bot_token',
      'X-WECHAT-UIN': randomWechatUin(),
      ...commonHeaders(),
    };
    if (token && token.trim()) h.Authorization = 'Bearer ' + token.trim();
    return h;
  }
  function getHeaders() { return commonHeaders(); }

  /** base_info payload sent in every API request (official buildBaseInfo). */
  function baseInfo() {
    return { channel_version: '2.4.6', bot_agent: 'OpenClaw' };
  }

  /** POST JSON to an endpoint under baseUrl; returns parsed JSON. Throws on !res.ok. */
  async function apiPost(endpoint, body, timeoutMs, label) {
    if (!fetchImpl) throw new Error('weixin-clawbot-transport: no fetch available');
    const url = baseUrl + '/' + endpoint;
    const controller = timeoutMs != null && timeoutMs > 0 ? new AbortController() : undefined;
    const t = controller ? setTimeout(() => controller.abort(), timeoutMs) : undefined;
    let res;
    try {
      res = await fetchImpl(url, {
        method: 'POST', headers: postHeaders(),
        body: typeof body === 'string' ? body : JSON.stringify(body),
        ...(controller ? { signal: controller.signal } : {}),
      });
    } finally {
      if (t) clearTimeout(t);
    }
    const rawText = await res.text();
    if (!res.ok) throw new Error(label + ' ' + res.status + ': ' + rawText.slice(0, 200));
    return JSON.parse(rawText);
  }

  /** GET an endpoint (query already encoded) with long-poll timeout. */
  async function apiGet(endpoint, timeoutMs, label) {
    if (!fetchImpl) throw new Error('weixin-clawbot-transport: no fetch available');
    const url = baseUrl + '/' + endpoint;
    const controller = timeoutMs != null && timeoutMs > 0 ? new AbortController() : undefined;
    const t = controller ? setTimeout(() => controller.abort(), timeoutMs) : undefined;
    let res;
    try {
      res = await fetchImpl(url, { method: 'GET', headers: getHeaders(), ...(controller ? { signal: controller.signal } : {}) });
    } finally {
      if (t) clearTimeout(t);
    }
    const rawText = await res.text();
    if (!res.ok) throw new Error(label + ' ' + res.status + ': ' + rawText.slice(0, 200));
    return JSON.parse(rawText);
  }

  // ------------------------------------------------------------------ login
  /**
   * Start a QR login. Returns { qrcode, qrcodeUrl, message }.
   * POST ilink/bot/get_bot_qrcode?bot_type=3 { local_token_list: [] }
   */
  async function startLogin() {
    const endpoint = 'ilink/bot/get_bot_qrcode?bot_type=' + encodeURIComponent(botType);
    const resp = await apiPost(endpoint, { local_token_list: [] }, DEFAULT_API_TIMEOUT_MS, 'fetchQRCode');
    return { qrcode: resp.qrcode, qrcodeUrl: resp.qrcode_img_content, message: 'scan the QR code with WeChat to connect' };
  }

  /**
   * Poll QR status until confirmed. Returns login result:
   *   { connected:true, botToken, accountId(ilink_bot_id), userId(ilink_user_id), baseUrl }
   * or { connected:false, message, status }.
   * GET ilink/bot/get_qrcode_status?qrcode=&verify_code=
   * Statuses: wait / scaned / need_verifycode / expired / binded_redirect /
   *           scaned_but_redirect / confirmed
   * On confirmed the server returns bot_token, ilink_bot_id, ilink_user_id, baseurl.
   */
  async function waitForLogin({ qrcode, verifyCode, timeoutMs = 480000, pollIntervalMs = 1000 } = {}) {
    if (!qrcode) throw new Error('weixin-clawbot-transport: waitForLogin requires qrcode from startLogin');
    const deadline = Date.now() + timeoutMs;
    let code = verifyCode || null;
    while (Date.now() < deadline) {
      let endpoint = 'ilink/bot/get_qrcode_status?qrcode=' + encodeURIComponent(qrcode);
      if (code) endpoint += '&verify_code=' + encodeURIComponent(code);
      let statusResponse;
      try {
        statusResponse = await apiGet(endpoint, 35000, 'pollQRStatus');
      } catch (e) {
        if (e && e.name === 'AbortError') return { connected: false, status: 'timeout', message: 'poll timeout' };
        await sleep(pollIntervalMs);
        continue;
      }
      const status = statusResponse.status;
      if (status === 'need_verifycode') {
        return { connected: false, status, message: 'need_verifycode', verifyCodeRequired: true };
      }
      if (status === 'confirmed') {
        if (!statusResponse.ilink_bot_id) {
          return { connected: false, status, message: 'login confirmed but ilink_bot_id missing' };
        }
        const result = {
          connected: true,
          botToken: statusResponse.bot_token,
          accountId: statusResponse.ilink_bot_id,
          userId: statusResponse.ilink_user_id,
          baseUrl: statusResponse.baseurl || baseUrl,
        };
        token = result.botToken;
        userId = result.userId;
        return result;
      }
      if (status === 'binded_redirect') {
        return { connected: false, status, alreadyConnected: true, message: 'already connected to OpenClaw' };
      }
      if (status === 'expired' || status === 'verify_code_blocked') {
        return { connected: false, status, message: 'QR expired or blocked; request a new one' };
      }
      await sleep(pollIntervalMs);
    }
    return { connected: false, status: 'timeout', message: 'login timeout' };
  }

  // ------------------------------------------------------------- lifecycle
  async function connect() {
    if (!token && !opts.token) {
      throw new Error('weixin-clawbot-transport: no bot token; run startLogin + waitForLogin first, or pass opts.token');
    }
    return true;
  }

  async function disconnect() {
    try { await notifyStop(); } catch { /* best effort */ }
    token = null;
  }

  // ------------------------------------------------------------ long-poll
  /**
   * Fetch inbound messages. Returns RawMsg[].
   * POST ilink/bot/getupdates { get_updates_buf, base_info } (long-poll).
   * Response: { ret, msgs[], get_updates_buf, longpolling_timeout_ms }.
   * Stale token (-14) -> throws with err.code = -14 (caller maps to auth-expired).
   */
  async function fetchUpdates() {
    let resp;
    try {
      resp = await apiPost('ilink/bot/getupdates', {
        get_updates_buf: getUpdatesBuf || '',
        base_info: baseInfo(),
      }, DEFAULT_LONG_POLL_TIMEOUT_MS, 'getUpdates');
    } catch (e) {
      if (e && e.name === 'AbortError') return []; // long-poll client timeout = normal
      if (e && e.code === STALE_TOKEN_ERRCODE) throw e;
      throw e;
    }
    if (resp.get_updates_buf != null && resp.get_updates_buf !== '') {
      if (resp.get_updates_buf !== getUpdatesBuf) {
        console.log('[transport] buf advanced len ' + getUpdatesBuf.length + '->' + resp.get_updates_buf.length + ' tail=' + resp.get_updates_buf.slice(-8) + ' (was ' + getUpdatesBuf.slice(-8) + ')');
      } else {
        console.log('[transport] buf UNCHANGED (' + getUpdatesBuf.length + ') ret=' + resp.ret + ' msgs=' + (resp.msgs || []).length);
      }
      getUpdatesBuf = resp.get_updates_buf;
    }
    if (resp.ret !== undefined && resp.ret !== 0) {
      if (resp.ret === STALE_TOKEN_ERRCODE) {
        const err = new Error('weixin-clawbot-transport: stale token (-14)');
        err.code = STALE_TOKEN_ERRCODE;
        throw err;
      }
      throw new Error('weixin-clawbot-transport: getupdates ret=' + resp.ret + ' errmsg=' + (resp.errmsg || ''));
    }
    const msgs = resp.msgs || [];
    return msgs.map((m) => mapInbound(m));
  }

  /** Map an official inbound message to RawMsg (adapter normalizes further). */
  function mapInbound(m) {
    let text = '';
    for (const item of m.item_list || []) {
      if (item.type === MessageItemType.TEXT && item.text_item && item.text_item.text != null) {
        text = String(item.text_item.text);
        break;
      }
    }
    return {
      conversationId: m.from_user_id || '',
      sender: m.from_user_id || '',
      text,
      media: null,
      ts: m.create_time_ms || Date.now(),
      contextToken: m.context_token || null,
      messageId: m.message_id || null,
    };
  }

  // ---------------------------------------------------------------- send
  /**
   * Send a plain text reply. reply = { conversationId, text, media?, contextToken? }.
   * POST ilink/bot/sendmessage
   *   { msg: { from_user_id:"", to_user_id, client_id, message_type:2,
   *            message_state:2, item_list:[{type:1,text_item:{text}}],
   *            context_token }, base_info }
   */
  async function sendMessage(reply) {
    const clientId = 'openclaw-weixin-' + crypto.randomUUID();
    const item_list = [];
    if (reply.text) item_list.push({ type: MessageItemType.TEXT, text_item: { text: reply.text } });
    const body = {
      msg: {
        from_user_id: '',
        to_user_id: reply.conversationId,
        client_id: clientId,
        message_type: MessageType.BOT,
        message_state: MessageState.FINISH,
        item_list: item_list.length ? item_list : undefined,
        context_token: reply.contextToken || undefined,
      },
      base_info: baseInfo(),
    };
    const resp = await apiPost('ilink/bot/sendmessage', body, DEFAULT_API_TIMEOUT_MS, 'sendMessage');
    if (resp.ret && resp.ret !== 0) {
      throw new Error('weixin-clawbot-transport: sendMessage ret=' + resp.ret + ' errmsg=' + (resp.errmsg || ''));
    }
    return { messageId: clientId };
  }

  // ---------------------------------------------------- typing indicator
  /**
   * Fetch bot config (includes typing_ticket) for the account user.
   * POST ilink/bot/getconfig { ilink_user_id, context_token?, base_info }.
   * Response: { ret, typing_ticket }.
   */
  async function getConfig(contextToken) {
    const resp = await apiPost('ilink/bot/getconfig',
      { ilink_user_id: userId, context_token: contextToken, base_info: baseInfo() },
      DEFAULT_CONFIG_TIMEOUT_MS, 'getConfig');
    if (resp && resp.typing_ticket) typingTicket = resp.typing_ticket;
    return resp;
  }
  /**
   * Send or cancel the typing status indicator.
   * POST ilink/bot/sendtyping { ilink_user_id, typing_ticket, status, base_info }.
   * status: 1 = typing, 2 = cancel typing. typing_ticket comes from getConfig.
   */
  async function sendTyping({ status = 1, contextToken } = {}) {
    if (!typingTicket) { try { await getConfig(contextToken); } catch { /* best-effort */ } }
    await apiPost('ilink/bot/sendtyping',
      { ilink_user_id: userId, typing_ticket: typingTicket || undefined, status, base_info: baseInfo() },
      DEFAULT_CONFIG_TIMEOUT_MS, 'sendTyping');
  }

  // -------------------------------------------------------- notifications
  async function notifyStart() {
    return apiPost('ilink/bot/msg/notifystart', { base_info: baseInfo() }, DEFAULT_CONFIG_TIMEOUT_MS, 'notifyStart');
  }
  async function notifyStop() {
    return apiPost('ilink/bot/msg/notifystop', { base_info: baseInfo() }, DEFAULT_CONFIG_TIMEOUT_MS, 'notifyStop');
  }

  function getToken() { return token; }
  function setToken(t) { token = t; }

  return {
    channelId, baseUrl, DEFAULT_BASE_URL,
    connect, disconnect, fetchUpdates, sendMessage, onError,
    startLogin, waitForLogin, notifyStart, notifyStop,
    getToken, setToken, getConfig, sendTyping, STALE_TOKEN_ERRCODE,
    _setGetUpdatesBuf: (b) => { getUpdatesBuf = b; },
    _getGetUpdatesBuf: () => getUpdatesBuf,
  };
}

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

module.exports = { createWeixinClawBotTransport, DEFAULT_BASE_URL, STALE_TOKEN_ERRCODE, MessageItemType, MessageType, MessageState };