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
    if (pollTimer || running) return;
    running = true;
    const tick = async () => {
      if (!running) return;
      try {
        const raw = await (transport.fetchUpdates || (async () => [])).call(transport);
        for (const r of raw || []) {
          try { const ev = normalizeEvent({ ...r, channelId, platform }); if (r && r.contextToken) ev.contextToken = r.contextToken; emit(ev); } catch { /* drop malformed */ }
        }
      } catch (err) {
        lastError = err;
        state.reconnecting();
        if (transport.onError) transport.onError(err);
      }
    };
    pollTimer = setInterval(tick, intervalMs);
    if (pollTimer.unref) pollTimer.unref();
  }

  function stopPolling() {
    running = false;
    if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
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
    platform, channelId, connect, disconnect, onEvent, send, getState, getLastError, dispose,
  };
}

module.exports = { createWeixinClawBotAdapter };
