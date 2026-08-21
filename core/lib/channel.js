'use strict';

/**
 * core/lib/channel.js — platform-independent Channel abstraction.
 *
 * The unified contract from docs/channel-design.md §3/§4/§6. Pure logic, no
 * timers, no OS APIs — a platform shell (macOS/Windows/Linux) wires the real
 * adapters, session driver and persistence into this module so the dispatch
 * rules, state machine and config model are identical everywhere.
 *
 *   const { createRouter, createChannelManager, normalizeEvent } = require('@oh-my-dsh/core');
 */

/** Unified connection states (docs §3.2). */
const CHANNEL_STATES = {
  DISCONNECTED: 'disconnected',
  CONNECTING: 'connecting',
  CONNECTED: 'connected',
  RECONNECTING: 'reconnecting',
  AUTH_EXPIRED: 'auth-expired',
};

const VALID_STATES = new Set(Object.values(CHANNEL_STATES));

/** Route priorities — higher wins; explicit binding > keyword > default. */
const ROUTE_PRIORITY = {
  conversation: 3,
  keyword: 2,
  default: 1,
};

/**
 * Normalize a raw inbound message into a platform-independent ChannelEvent.
 * Coerces field names and fills defaults; leaves `platform` untouched (the
 * adapter sets it). Throws on missing conversationId.
 */
function normalizeEvent(raw) {
  if (!raw || typeof raw !== 'object') throw new Error('channel: event must be an object');
  const conversationId = raw.conversationId || raw.conversation_id || raw.chatId;
  if (typeof conversationId !== 'string' || !conversationId) {
    throw new Error('channel: event requires a conversationId');
  }
  const media = raw.media || null;
  return {
    channelId: raw.channelId || '',
    platform: raw.platform || '',
    conversationId,
    sender: raw.sender || '',
    text: typeof raw.text === 'string' ? raw.text : '',
    media: media
      ? {
          type: media.type || 'file',
          filePath: media.filePath || null,
          url: media.url || null,
          mimeType: media.mimeType || null,
          fileName: media.fileName || null,
        }
      : null,
    ts: Number.isFinite(raw.ts) ? raw.ts : Date.now(),
  };
}

/**
 * Build a ChannelReply (docs §3.1). Pass a text string or an object
 * { text?, media? }.
 */
function buildReply(textOrObj) {
  if (typeof textOrObj === 'string') return { text: textOrObj, media: null };
  const obj = textOrObj || {};
  return {
    text: typeof obj.text === 'string' ? obj.text : '',
    media: obj.media || null,
  };
}

/**
 * Strip markdown-ish emphasis that a chat client may not render, so the
 * reply reads cleanly in a plain-text chat. (Adapters may call this before
 * send; kept pure for testability.)
 */
function toPlainText(text) {
  if (typeof text !== 'string') return '';
  return text
    .replace(/\*\*([^*]+)\*\*/g, '$1')
    .replace(/\*([^*]+)\*/g, '$1')
    .replace(/`([^`]+)`/g, '$1');
}

/** Create a connection state machine (docs §3.2). */
function createStateMachine(initial = CHANNEL_STATES.DISCONNECTED) {
  let state = VALID_STATES.has(initial) ? initial : CHANNEL_STATES.DISCONNECTED;
  const listeners = new Set();

  function onChange(cb) { listeners.add(cb); return () => listeners.delete(cb); }
  function get() { return state; }
  function set(next) {
    if (!VALID_STATES.has(next)) throw new Error(`channel: invalid state ${next}`);
    if (next === state) return state;
    state = next;
    for (const cb of listeners) cb(state);
    return state;
  }
  // Convenience transitions used by managers/adapters.
  function connecting() { return set(CHANNEL_STATES.CONNECTING); }
  function connected() { return set(CHANNEL_STATES.CONNECTED); }
  function reconnecting() { return set(CHANNEL_STATES.RECONNECTING); }
  function authExpired() { return set(CHANNEL_STATES.AUTH_EXPIRED); }
  function disconnected() { return set(CHANNEL_STATES.DISCONNECTED); }

  return { onChange, get, set, connecting, connected, reconnecting, authExpired, disconnected };
}

/**
 * Dispatch router (docs §6). Given the enabled global channels and the project
 * refs that reference a channel, match a ChannelEvent to at most ONE project.
 *
 * Matching precedence: explicit conversationId binding > keyword/prefix on
 * text > single default fallback. Deterministic on conflicts: highest priority
 * wins; ties resolved by ref order.
 *
 * Returns { ref, priority, reason } or null when nothing matches.
 */
function createRouter() {
  function match({ event, refs = [] }) {
    if (!event) return null;
    const text = event.text || '';
    let best = null;   // { ref, priority, reason }
    for (const ref of refs) {
      const routing = ref.routing || {};
      const convs = routing.conversations || [];
      const keywords = routing.keywords || [];
      // ① explicit conversation binding
      if (convs.includes(event.conversationId)) {
        if (!best || best.priority < ROUTE_PRIORITY.conversation) {
          best = { ref, priority: ROUTE_PRIORITY.conversation, reason: 'conversation' };
        }
        continue;
      }
      // ② keyword / prefix on text
      if (keywords.length && text) {
        const hit = keywords.find((k) => typeof k === 'string' && k && text.includes(k));
        if (hit) {
          if (!best || best.priority < ROUTE_PRIORITY.keyword) {
            best = { ref, priority: ROUTE_PRIORITY.keyword, reason: 'keyword' };
          }
          continue;
        }
      }
    }
    // ③ single default fallback (only if nothing explicit matched)
    if (!best) {
      const defaults = refs.filter((r) => r.routing && r.routing.default === true);
      if (defaults.length === 1) {
        best = { ref: defaults[0], priority: ROUTE_PRIORITY.default, reason: 'default' };
      } else if (defaults.length > 1) {
        best = { ref: defaults[0], priority: ROUTE_PRIORITY.default, reason: 'default-multiple' };
      }
    }
    return best;
  }

  return { match, ROUTE_PRIORITY };
}

/**
 * Normalize a global Channel config (docs §4.1). `connection` is adapter
 * specific and passed through untouched.
 */
function normalizeChannel(raw) {
  if (!raw || typeof raw !== 'object') throw new Error('channel: channel config must be an object');
  const id = raw.id || raw.channelId;
  if (typeof id !== 'string' || !id) throw new Error('channel: channel requires an id');
  return {
    id,
    platform: raw.platform || '',
    name: raw.name || id,
    enabled: raw.enabled !== false,
    state: VALID_STATES.has(raw.state) ? raw.state : CHANNEL_STATES.DISCONNECTED,
    connection: raw.connection || null,
  };
}

/**
 * Parse a project refs file (.dsh/channels.json, docs §4.2). Returns the refs
 * array or throws on malformed JSON.
 */
function parseProjectRefs(json) {
  const data = JSON.parse(json);
  if (!data || typeof data !== 'object' || !Array.isArray(data.refs)) {
    throw new Error('channel: .dsh/channels.json must be { version, refs: [] }');
  }
  return data.refs;
}

/**
 * Orchestrator tying adapters + router + session driver + job queue together
 * (docs §6/§9). Pure coordination: the caller injects the pieces.
 *
 * - `adapters`: a Map channelId -> adapter exposing onEvent(cb) and send().
 * - `refsByChannel`: (channelId) => projectRefs[].
 * - `sessionDriver`: object with { run(event, ref) => Promise<ChannelReply> }.
 * - `jobQueue`: a core/lib/jobqueue queue (optional; plain runner when absent).
 */
function createChannelManager({ adapters, refsByChannel, sessionDriver, jobQueue } = {}) {
  const adapterMap = adapters instanceof Map ? adapters : new Map(Object.entries(adapters || {}));
  const getRefs = typeof refsByChannel === 'function' ? refsByChannel : () => refsByChannel || [];
  const router = createRouter();

  /** Handle one inbound event: route → run session → send reply. */
  async function handleEvent(event) {
    const chId = event.channelId;
    const adapter = adapterMap.get(chId);
    const refs = getRefs(chId);
    const routed = router.match({ event, refs });

    if (!adapter) {
      throw new Error(`channel: no adapter for channel ${chId}`);
    }
    if (!routed) {
      await adapter.send(event.conversationId, buildReply('该会话未绑定任何项目（未匹配路由）。'));
      return { routed: false, reply: null };
    }

    let reply;
    if (sessionDriver) {
      reply = await sessionDriver.run(event, routed.ref);
    } else {
      reply = buildReply(`(no session driver) routed to ${routed.ref.workspaceRoot || routed.ref.channelId}`);
    }
    await adapter.send(event.conversationId, reply);
    return { routed: true, ref: routed.ref, reply };
  }

  /**
   * Wrap handleEvent in the job queue so the same conversation is serial and
   * cross-conversation work can queue. Falls back to direct execution when no
   * queue is provided.
   */
  function enqueue(event) {
    const id = `remote-${event.channelId}-${event.conversationId}`;
    if (jobQueue) {
      const qid = jobQueue.enqueue({ id, title: `remote:${event.conversationId}`, source: 'remote', meta: { event } });
      jobQueue.markRunning(qid);
      return handleEvent(event)
        .then((res) => { jobQueue.complete(qid, res); return res; })
        .catch((err) => { jobQueue.fail(qid, String(err && err.message || err)); throw err; });
    }
    return handleEvent(event);
  }

  return { handleEvent, enqueue, router };
}

module.exports = {
  CHANNEL_STATES,
  ROUTE_PRIORITY,
  normalizeEvent,
  buildReply,
  toPlainText,
  createStateMachine,
  createRouter,
  normalizeChannel,
  parseProjectRefs,
  createChannelManager,
};
