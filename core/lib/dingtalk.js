'use strict';

/**
 * core/lib/dingtalk.js — DingTalk channel adapter.
 *
 * Second implementation of the ChannelAdapter contract (docs/channel-design.md §3.3),
 * mirroring weixin-clawbot.js but push-based (DingTalk Stream delivers messages via
 * callback, not a poll loop).
 *
 *   const { createDingTalkAdapter } = require('@oh-my-dsh/core');
 *   const adapter = createDingTalkAdapter({ channelId, transport });
 *
 * The transport is push-based (see dingtalk-stream-transport.js): it exposes
 * onEvent(cb) for normalized inbound events and sendMessage(...). The adapter
 * maintains a per-conversation sessionWebhook map (each inbound message carries a
 * time-limited reply webhook) and resolves it when sending a reply.
 */

const { normalizeEvent, buildReply, toPlainText, createStateMachine, CHANNEL_STATES } = require('./channel');

function createDingTalkAdapter(opts = {}) {
  const channelId = opts.channelId;
  if (!channelId) throw new Error('dingtalk: channelId required');
  const transport = opts.transport || {};
  const platform = 'dingtalk';

  const state = createStateMachine(CHANNEL_STATES.DISCONNECTED);
  let handlers = [];
  // conversationId -> { sessionWebhook, messageId } latest inbound, used for replies.
  const webhooks = new Map();

  function onEvent(cb) { handlers.push(cb); return () => { handlers = handlers.filter((h) => h !== cb); }; }
  function emit(event) { for (const h of handlers) { try { h(event); } catch { /* isolate */ } } }
  /** Subscribe to connection-state changes (fires on every actual transition). */
  function onState(cb) { return state.onChange(cb); }

  // Forward normalized inbound events; record the latest reply webhook per conversation.
  if (transport.onEvent) {
    transport.onEvent((event) => {
      if (event && event.conversationId) {
        webhooks.set(event.conversationId, {
          sessionWebhook: event.sessionWebhook || null,
          messageId: event.messageId || null,
        });
      }
      emit(event);
    });
  }
  // Map transport status (disconnected/connecting/connected/reconnecting/stopped) to the state machine.
  if (transport.onStatus) {
    transport.onStatus((s) => {
      const mapped = s === 'connected' ? CHANNEL_STATES.CONNECTED
        : s === 'reconnecting' ? CHANNEL_STATES.RECONNECTING
        : s === 'connecting' ? CHANNEL_STATES.CONNECTING
        : CHANNEL_STATES.DISCONNECTED;
      state.set(mapped);
    });
  }

  async function connect() {
    state.connecting();
    try {
      await (transport.connect || (async () => {})).call(transport);
      // transport.connect() establishes the Stream. Reflect connected explicitly so a
      // missed onStatus transition (or the panel's live state read) cannot leave the
      // state machine stuck on 'connecting' (mirrors the weixin adapter).
      if (transport.getState && transport.getState() === 'connected') {
        state.connected();
      }
    } catch (err) {
      state.authExpired();
      throw err;
    }
  }

  async function disconnect() {
    await (transport.disconnect || (async () => {})).call(transport);
    state.disconnected();
  }

  /** Send a text reply to a conversation using its latest sessionWebhook. */
  async function send(conversationId, reply) {
    const rep = typeof reply === 'string' ? buildReply(reply) : reply || {};
    const meta = webhooks.get(conversationId);
    if (!meta || !meta.sessionWebhook) {
      throw new Error('dingtalk: no sessionWebhook for ' + conversationId + ' (user must send a message first)');
    }
    await (transport.sendMessage || (async () => {})).call(transport, {
      conversationId,
      text: toPlainText(rep.text || ''),
      sessionWebhook: meta.sessionWebhook,
      msgId: rep.messageId || meta.messageId || null,
    });
  }

  function getState() { return state.get(); }
  function getLastError() { return null; }
  function dispose() { handlers = []; }

  return {
    platform, channelId, connect, disconnect, onEvent, onState, send, getState, getLastError, dispose,
  };
}

module.exports = { createDingTalkAdapter };