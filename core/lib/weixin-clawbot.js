'use strict';

/**
 * core/lib/weixin-clawbot.js — WeChat ClawBot channel adapter.
 *
 * First implementation of the ChannelAdapter contract (docs §3.3, §8).
 *
 * Design: the adapter is transport-injectable. In production it wraps the
 * weixin-agent-sdk (login/start/Bot) via the real transport; in tests a mock
 * transport drives the same event/state logic. This keeps the state machine,
 * event normalization and send() path platform-independent and testable
 * without a live WeChat login.
 *
 *   const { createWeixinClawBotAdapter } = require('@oh-my-dsh/core');
 *   const adapter = createWeixinClawBotAdapter({ channelId, transport });
 */

const { normalizeEvent, buildReply, toPlainText, createStateMachine, CHANNEL_STATES } = require('./channel');

/**
 * Create a WeChat ClawBot adapter.
 *
 * opts.transport must expose:
 *   async connect(): Promise<void>          // login/connect to WeChat
 *   async disconnect(): Promise<void>
 *   async sendMessage(conversationId, reply): Promise<void>   // reply text/media
 *   async fetchUpdates(): Promise<RawMsg[]> // getUpdates long-poll results
 *   onError(cb: (err) => void): void        // transport-level error (optional)
 *
 * RawMsg (platform-shaped) → normalized via normalizeEvent():
 *   { conversationId, sender?, text?, media?, ts? }
 *
 * The adapter runs a poll loop (setInterval, injectable intervalMs) that pulls
 * fetchUpdates() and emits normalized ChannelEvent to the manager's handler.
 */
function createWeixinClawBotAdapter(opts = {}) {
  const channelId = opts.channelId;
  if (!channelId) throw new Error('weixin-clawbot: channelId required');
  const transport = opts.transport || {};
  const intervalMs = opts.intervalMs || 1000;
  const platform = 'weixin-clawbot';

  const state = createStateMachine(CHANNEL_STATES.DISCONNECTED);
  let handlers = [];
  let pollTimer = null;
  let running = false;
  let lastError = null;

  function onEvent(cb) { handlers.push(cb); return () => { handlers = handlers.filter((h) => h !== cb); }; }
  function emit(event) { for (const h of handlers) { try { h(event); } catch (e) { /* isolate */ } } }
  /** Subscribe to connection-state changes (fires on every actual transition). */
  function onState(cb) { return state.onChange(cb); }

  async function connect() {
    state.connecting();
    try {
      await (transport.connect || (async () => {})).call(transport);
      state.connected();
      startPolling();
    } catch (err) {
      lastError = err;
      state.authExpired();
      throw err;
    }
  }

  async function disconnect() {
    stopPolling();
    state.disconnected();
    await (transport.disconnect || (async () => {})).call(transport);
  }

  function startPolling() {
    // Strictly serial long-poll loop (mirrors official monitor's while-loop):
    // each getUpdates call blocks until new messages or the long-poll timeout,
    // then loops immediately. No setInterval — this keeps the long-poll
    // connection continuous, which the server relies on to advance the
    // get_updates_buf cursor (otherwise the same message is redelivered).
    if (pollTimer || running) return;
    running = true;
    const loop = async () => {
      while (running) {
        try {
          const raw = await (transport.fetchUpdates || (async () => [])).call(transport);
          if (raw && raw.length) {
            console.log('[clawbot:' + channelId + '] fetchUpdates got ' + raw.length + ' msg(s) @' + Date.now() + ' ' + JSON.stringify(raw.map((m) => ({ id: m.messageId, t: m.text }))));
          }
          for (const r of raw || []) {
            try { const ev = normalizeEvent({ ...r, channelId, platform }); if (r && r.contextToken) ev.contextToken = r.contextToken; console.log('[clawbot:' + channelId + '] EMIT ' + ev.conversationId + ' text=' + JSON.stringify(ev.text)); emit(ev); } catch { /* drop malformed */ }
          }
          // yield so a mock/immediate-return transport does not busy-loop
          await sleep(0);
        } catch (err) {
          lastError = err;
          state.reconnecting();
          if (transport.onError) transport.onError(err);
          await sleep(intervalMs);
        }
      }
    };
    pollTimer = loop(); // hold the promise so the loop keeps the process alive
  }

  function stopPolling() {
    running = false;
    pollTimer = null;
  }

  function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

  /** Send/cancel the typing indicator (status 1=typing, 2=cancel). Best-effort. */
  async function sendTyping(conversationId, status, contextToken) {
    await ((transport.sendTyping) || (async () => {})).call(transport, { status, contextToken: contextToken || undefined });
  }

  async function send(conversationId, reply) {
    const rep = typeof reply === 'string' ? buildReply(reply) : reply || {};
    const payload = {
      conversationId,
      text: toPlainText(rep.text || ''),
      media: rep.media || null,
      contextToken: rep.contextToken || (reply && reply.contextToken) || null,
    };
    await (transport.sendMessage || (async () => {})).call(transport, payload);
  }

  function getState() { return state.get(); }
  function getLastError() { return lastError; }
  function dispose() { stopPolling(); handlers = []; }

  return {
    platform, channelId, connect, disconnect, onEvent, onState, send, sendTyping, getState, getLastError, dispose,
  };
}

module.exports = { createWeixinClawBotAdapter };