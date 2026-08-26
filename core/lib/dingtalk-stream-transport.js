'use strict';

/**
 * core/lib/dingtalk-stream-transport.js — DingTalk Stream transport.
 *
 * Implements the Stream-mode connection (DWClient-equivalent) using Node's
 * built-in WebSocket + fetch (Node >= 22), so the repo stays self-contained
 * (no external ws/axios/dingtalk-stream dependency — same principle as the
 * WeChat ClawBot transport, which reimplements the protocol).
 *
 * Docs: docs/channel-dingtalk-stream.md §2/§3/§5.1.
 *
 *   const { createDingTalkTransport, createDingTalkStreamClient } = require('@oh-my-dsh/core');
 *
 * The transport exposes a push-based contract for the adapter:
 *   - connect(): Promise<void>
 *   - onEvent(cb): (event) => void            // normalized inbound ChannelEvent
 *   - onStatus(cb): (status) => void
 *   - sendMessage({ conversationId, text, sessionWebhook, msgId }): Promise<void>
 *   - getState(): 'disconnected'|'connecting'|'connected'|'reconnecting'|'stopped'
 *   - disconnect(): Promise<void>
 *
 * The real client is injectable (opts.client) so tests drive the same event/state
 * logic with a mock client.
 */

const { normalizeEvent } = require('./channel');

// ---------------------------------------------------------------- constants
const GATEWAY_URL = 'https://api.dingtalk.com/v1.0/gateway/connections/open';
const GET_TOKEN_URL = 'https://oapi.dingtalk.com/gettoken';
const TOPIC_ROBOT = '/v1.0/im/bot/messages/get';
const TOPIC_CARD = '/v1.0/card/instances/callback';
const DISCONNECTED = 'disconnected';
const CONNECTING = 'connecting';
const CONNECTED = 'connected';
const RECONNECTING = 'reconnecting';
const STOPPED = 'stopped';

/**
 * Real DingTalk Stream client (built-in WebSocket + fetch). Injectable seams for
 * tests: opts.fetch, opts.WebSocket, opts.gatewayUrl, opts.tokenUrl.
 * Mirrors the official dingtalk-stream SDK protocol:
 *   gateway open -> { endpoint, ticket } -> wss?ticket= -> downstream frames.
 */
function createDingTalkStreamClient(opts = {}) {
  const clientId = opts.clientId;
  const clientSecret = opts.clientSecret;
  if (!clientId || !clientSecret) throw new Error('dingtalk-stream: clientId/clientSecret required');
  const gatewayUrl = opts.gatewayUrl || GATEWAY_URL;
  const tokenUrl = opts.tokenUrl || GET_TOKEN_URL;
  const fetchImpl = opts.fetch || (typeof globalThis.fetch === 'function' ? globalThis.fetch.bind(globalThis) : null);
  const WS = opts.WebSocket || (typeof globalThis.WebSocket === 'function' ? globalThis.WebSocket : null);
  const log = opts.log || (() => {});

  let socket = null;
  let accessToken = null;
  let tokenExpiresAt = 0;
  let status = DISCONNECTED;
  let reconnectTimer = null;
  let reconnectAttempts = 0;
  let userDisconnect = false;
  const statusHandlers = new Set();
  const topicCallbacks = new Map();

  function setStatus(s) {
    if (s === status) return;
    status = s;
    for (const h of statusHandlers) { try { h(s); } catch (e) { /* isolate */ } }
  }
  function onStatus(cb) { statusHandlers.add(cb); return () => statusHandlers.delete(cb); }

  /** POST the gateway endpoint; returns { endpoint, ticket }. */
  async function getEndpoint() {
    if (!fetchImpl) throw new Error('dingtalk-stream: no fetch available');
    const res = await fetchImpl(gatewayUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({
        clientId,
        clientSecret,
        ua: '',
        subscriptions: [{ type: 'EVENT', topic: '*' }, { type: 'CALLBACK', topic: TOPIC_ROBOT }],
      }),
    });
    const data = await res.json();
    if (!data || !data.endpoint || !data.ticket) {
      throw new Error('dingtalk-stream: gateway did not return endpoint/ticket');
    }
    return { endpoint: data.endpoint, ticket: data.ticket };
  }

  /** Fetch + cache an app access token (refresh near expiry). */
  async function getAccessToken(force = false) {
    if (accessToken && !force && Date.now() < tokenExpiresAt - 60_000) return accessToken;
    if (!fetchImpl) throw new Error('dingtalk-stream: no fetch available');
    const url = tokenUrl + '?appkey=' + encodeURIComponent(clientId) + '&appsecret=' + encodeURIComponent(clientSecret);
    const res = await fetchImpl(url);
    const data = await res.json();
    if (!data || !data.access_token) throw new Error('dingtalk-stream: getAccessToken failed');
    accessToken = data.access_token;
    tokenExpiresAt = Date.now() + 2 * 60 * 60 * 1000; // ~2h (refreshed near expiry)
    return accessToken;
  }

  function sendFrame(payload, sock = socket) {
    if (!sock || sock.readyState !== 1) return; // 1 = OPEN
    try { sock.send(JSON.stringify(payload)); } catch (err) { log('sendFrame error: ' + (err && err.message)); }
  }

  /** ACK a downstream frame by messageId (avoids server retry within 60s). */
  function sendEventAck(message, ackData) {
    const messageId = message && message.headers && message.headers.messageId;
    if (!messageId) return;
    sendFrame({ code: 200, headers: { contentType: 'application/json', messageId }, message: 'OK', data: JSON.stringify(ackData) });
  }

  /** Reply-response ack for a robot callback (result = the sessionWebhook POST body/response). */
  function socketCallBackResponse(messageId, result) {
    if (!messageId) return;
    sendFrame({ code: 200, headers: { contentType: 'application/json', messageId }, message: 'OK', data: JSON.stringify({ response: result }) });
  }

  function onDownStream(raw) {
    let msg;
    try { msg = JSON.parse(raw); } catch { return; }
    if (!msg || typeof msg !== 'object') return;
    const headers = msg.headers || {};
    const topic = headers.topic;
    if (msg.type === 'CALLBACK' && topicCallbacks.has(topic)) {
      const cb = topicCallbacks.get(topic);
      try { cb({ data: msg.data, headers }); } catch (err) { log('topic callback error: ' + (err && err.message)); }
    } else if (msg.type === 'SYSTEM') {
      log('dingtalk-stream SYSTEM topic=' + topic);
      if (topic === 'CONNECTED') {
        /* opening */
      } else if (topic === 'REGISTERED') {
        log('dingtalk-stream REGISTERED — bot subscribed');
        reconnectAttempts = 0;
        setStatus(CONNECTED);
      } else if (topic === 'disconnect') {
        setStatus(STOPPED);
      } else if (topic === 'KEEPALIVE') {
        /* built-in ws ping/pong handles heartbeat */
      } else if (topic === 'ping') {
        sendFrame({ code: 200, headers, message: 'OK', data: msg.data });
      }
    } else if (msg.type === 'EVENT') {
      sendEventAck(msg, { status: 'SUCCESS' });
    }
  }

  function scheduleReconnect() {
    if (userDisconnect || reconnectTimer) return; // already disconnecting or a reconnect is pending
    const delay = Math.min(1000 * Math.pow(2, reconnectAttempts) + Math.random() * 500, 60_000);
    reconnectAttempts += 1;
    setStatus(RECONNECTING);
    log('dingtalk-stream reconnecting in ' + Math.round(delay / 1000) + 's (attempt ' + reconnectAttempts + ')');
    reconnectTimer = setTimeout(() => { reconnectTimer = null; void connect(); }, delay);
  }

  /** Open the WebSocket and wire frame handling. Resolves on REGISTERED (or timeout). */
  function connect() {
    if (userDisconnect) return Promise.resolve();
    if (!WS) return Promise.reject(new Error('dingtalk-stream: no WebSocket available'));
    return new Promise((resolve, reject) => {
      (async () => {
        try {
          setStatus(CONNECTING);
          const ep = await getEndpoint();
          if (userDisconnect) { setStatus(STOPPED); return; }
          // Raw ticket (official SDK appends it verbatim: endpoint + '?ticket=' + ticket).
          const sock = new WS(ep.endpoint + '?ticket=' + ep.ticket);
          let settled = false;
          sock.onopen = () => {
            if (socket !== sock) return;
            log('dingtalk-stream ws open — marking connected (SDK semantics: connected = socket open)');
            // SDK sets connected on socket open; REGISTERED (onDownStream) is a separate
            // registration confirmation and also sets CONNECTED if it arrives.
            setStatus(CONNECTED);
          };
          sock.onmessage = (ev) => onDownStream(String(ev.data));
          sock.onclose = () => {
            if (socket !== sock) return;
            socket = null;
            if (userDisconnect) { setStatus(STOPPED); return; }
            scheduleReconnect();
            if (!settled) { settled = true; setStatus(RECONNECTING); reject(new Error('dingtalk-stream: closed before registered')); }
          };
          sock.onerror = () => { /* close handler handles reconnect */ };
          socket = sock;
          let connectTimeout;
          const off = onStatus((s) => { if (s === CONNECTED && !settled) { settled = true; clearTimeout(connectTimeout); off(); log('dingtalk-stream connected via status ' + s); resolve(); } });
          connectTimeout = setTimeout(() => { if (!settled) { settled = true; clearTimeout(connectTimeout); off(); log('dingtalk-stream connect() resolved by timeout; status=' + status); resolve(); } }, 8000);
        } catch (err) {
          if (!userDisconnect) scheduleReconnect();
          reject(err);
        }
      })();
    });
  }

  function disconnect() {
    userDisconnect = true;
    if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
    if (socket) {
      const sock = socket;
      socket = null;
      try { sock.close(); } catch (e) { /* ignore */ }
    }
    setStatus(STOPPED);
  }

  function registerCallbackListener(topic, cb) { topicCallbacks.set(topic, cb); }
  function getState() { return status; }

  return {
    clientId,
    registerCallbackListener,
    getAccessToken,
    socketCallBackResponse,
    connect,
    disconnect,
    getState,
    onStatus,
    TOPIC_ROBOT,
    TOPIC_CARD,
  };
}

/**
 * Transport wrapper: adapts a Stream client (real or mock) to the adapter's
 * push-based contract.
 *
 * opts:
 *   channelId   - global channel id (added to normalized events)
 *   client      - a DingTalk Stream client exposing registerCallbackListener /
 *                 getAccessToken / socketCallBackResponse / connect / disconnect /
 *                 getState / onStatus
 *   log         - optional logger
 */
function createDingTalkTransport(opts = {}) {
  const channelId = opts.channelId;
  if (!channelId) throw new Error('dingtalk-stream: channelId required');
  const client = opts.client;
  if (!client) throw new Error('dingtalk-stream: transport requires a client');
  const platform = 'dingtalk';
  const log = opts.log || (() => {});
  const fetchImpl = opts.fetch || globalThis.fetch;

  let eventHandlers = [];
  const seen = new Map(); // msgId -> ts (dedupe against 60s server retry)
  const SEEN_TTL_MS = 30 * 60 * 1000;

  function onEvent(cb) { eventHandlers.push(cb); return () => { eventHandlers = eventHandlers.filter((h) => h !== cb); }; }
  function emit(event) { for (const h of eventHandlers) { try { h(event); } catch { /* isolate */ } } }

  /** Parse the raw robot message .data into a platform-shaped inbound event. */
  function mapInbound(rawData) {
    let m;
    try { m = typeof rawData === 'string' ? JSON.parse(rawData) : rawData; } catch { return null; }
    if (!m || typeof m !== 'object') return null;
    const msgtype = m.msgtype || '';
    let text = '';
    if (msgtype === 'text' && m.text && typeof m.text.content === 'string') text = m.text.content;
    else if (msgtype === 'richText') {
      const parts = (m.content && m.content.texts) || [];
      text = parts.map((p) => (p && p.text) || '').join(' ');
    }
    return {
      conversationId: m.conversationId || m.chatId || '',
      sender: m.senderStaffId || m.senderId || '',
      text,
      msgId: m.msgId || null,
      sessionWebhook: m.sessionWebhook || '',
      sessionWebhookExpiredTime: m.sessionWebhookExpiredTime || 0,
      msgtype,
      ts: Number(m.createAt) || Date.now(),
    };
  }

  // Route robot messages to a normalized event (deduped by msgId).
  client.registerCallbackListener(TOPIC_ROBOT, (frame) => {
    const inbound = mapInbound(frame && frame.data);
    if (!inbound) return;
    if (inbound.msgId) {
      if (seen.has(inbound.msgId)) {
        log('[dingtalk:' + channelId + '] drop duplicate msgId=' + inbound.msgId);
        return;
      }
      seen.set(inbound.msgId, Date.now());
      for (const [k, v] of seen) if (Date.now() - v > SEEN_TTL_MS) seen.delete(k);
    }
    const event = normalizeEvent({ ...inbound, channelId, platform });
    if (inbound.msgId) event.messageId = inbound.msgId;
    if (inbound.sessionWebhook) event.sessionWebhook = inbound.sessionWebhook;
    log('[dingtalk:' + channelId + '] EMIT ' + event.conversationId + ' text=' + JSON.stringify(event.text));
    emit(event);
  });

  /** Send a plain-text reply to the conversation via its sessionWebhook. */
  async function sendMessage(payload = {}) {
    const { conversationId, text, sessionWebhook, msgId } = payload;
    if (!sessionWebhook) throw new Error('dingtalk-stream: no sessionWebhook to reply');
    const token = await client.getAccessToken();
    const body = { at: { isAtAll: false }, text: { content: text || '' }, msgtype: 'text' };
    const res = await fetchImpl(sessionWebhook, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-acs-dingtalk-access-token': token },
      body: JSON.stringify(body),
    });
    let result = null;
    try { result = await res.json(); } catch { /* ignore */ }
    if (msgId) client.socketCallBackResponse(msgId, result || {});
    return { sent: res.ok, result };
  }

  async function connect() { return client.connect(); }
  async function disconnect() { return client.disconnect(); }
  function getState() { return client.getState(); }

  return { platform, channelId, connect, disconnect, onEvent, sendMessage, getState, onStatus: client.onStatus.bind(client) };
}

module.exports = {
  createDingTalkTransport,
  createDingTalkStreamClient,
  GATEWAY_URL,
  GET_TOKEN_URL,
  TOPIC_ROBOT,
  TOPIC_CARD,
};