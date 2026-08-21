'use strict';

/**
 * core/lib/channel-runner.js — run a live WeChat channel end-to-end.
 *
 * Wires the already-verified pieces into one loop (docs §6/§9):
 *   token(disk) -> ClawBot transport -> adapter (long-poll getupdates)
 *     -> ChannelManager (Router + SessionDriver against live dsh web)
 *     -> context_token reply via adapter.send
 *
 * Inbound messages are first checked against the slash-command table
 * (docs/channel-ui-commands.md §4): commands are handled by
 * createCommandRunner (no project session); ordinary text is routed to the
 * project via Router -> dsh session, with a persistent conversationId ->
 * sessionId mapping (createChannelSessions, decision E).
 *
 *   const { runWeixinChannel } = require('@oh-my-dsh/core');
 *   const handle = runWeixinChannel({ channelId, port, refs, dshHome });
 *   await handle.start();
 *   ...
 *   await handle.stop();
 */

const { createWeixinClawBotTransport } = require('./weixin-clawbot-transport');
const { createWeixinClawBotAdapter } = require('./weixin-clawbot');
const { createSessionDriver } = require('./session-driver');
const { createChannelManager, normalizeEvent } = require('./channel');
const { createCommandRunner, parseCommand } = require('./channel-commands');
const { createChannelSessions } = require('./channel-sessions');
const { loadChannelAccount } = require('./channel-store');
const { createQueue } = require('./jobqueue');

/**
 * Build the adapters map for a set of project refs. Each distinct channelId in
 * refs gets a ClawBot adapter backed by its saved account token (if any).
 * Returns { adapters: Map, refsByChannel(channelId) }.
 */
function buildWeixinAdapters({ refs, dshHome, transportOpts, intervalMs }) {
  const adapters = new Map();
  const byChannel = new Map();
  for (const ref of refs || []) {
    if (!ref.channelId) continue;
    const list = byChannel.get(ref.channelId) || [];
    list.push(ref);
    byChannel.set(ref.channelId, list);
  }
  for (const [channelId, channelRefs] of byChannel) {
    const account = loadChannelAccount(channelId, dshHome);
    const transport = createWeixinClawBotTransport({
      channelId,
      token: account ? account.botToken : null,
      baseUrl: account ? account.baseUrl : undefined,
      ...(transportOpts || {}),
    });
    const adapter = createWeixinClawBotAdapter({ channelId, transport, intervalMs: intervalMs || 1000 });
    adapters.set(channelId, adapter);
  }
  const refsByChannel = (channelId) => byChannel.get(channelId) || [];
  return { adapters, refsByChannel };
}

/**
 * Run a live WeChat channel end-to-end.
 *
 * opts:
 *   channelId   - the global channel id whose saved token to use
 *   port        - dsh web port (default 3080)
 *   refs        - project refs for this channel (from .dsh/channels.json)
 *   dshHome     - DSH_HOME for token lookup (default ~/.dsh)
 *   sessionOpts - overrides for createSessionDriver (poll interval etc.)
 *   transportOpts - overrides for createWeixinClawBotTransport (fetch, baseUrl)
 *   intervalMs  - adapter long-poll interval
 *   onEvent     - optional callback(event, result) after handling each message
 *   onState     - optional callback(channelId, state) on adapter state changes
 *   commands    - optional pre-built command runner deps; defaults to a runner
 *                 wired to the session store + session driver
 */
async function runWeixinChannel(opts = {}) {
  const channelId = opts.channelId;
  if (!channelId) throw new Error('channel-runner: channelId required');
  const { adapters, refsByChannel } = buildWeixinAdapters({
    refs: opts.refs || [],
    dshHome: opts.dshHome,
    transportOpts: opts.transportOpts,
    intervalMs: opts.intervalMs,
  });
  const adapter = adapters.get(channelId);
  if (!adapter) throw new Error('channel-runner: no adapter for ' + channelId);

  const sessionDriver = createSessionDriver({ port: opts.port || 3080, ...(opts.sessionOpts || {}) });
  const manager = createChannelManager({
    adapters,
    refsByChannel,
    sessionDriver,
    jobQueue: createQueue(),
  });

  // Session store per the first routed project (decision E). If refs exist,
  // use the first project root; caller can override via opts.projectRoot.
  const projectRoot = opts.projectRoot || (opts.refs && opts.refs[0] && opts.refs[0].workspaceRoot) || process.cwd();
  const store = opts.sessions || createChannelSessions({ projectRoot, channelId });

  // Command runner wired to the session store + session driver.
  const commandRunner = opts.commands || createCommandRunner({
    getSessions: () => store.listSessions(),
    createSession: async (name) => {
      const sid = await sessionDriver.createSession(opts.port || 3080, { cwd: projectRoot });
      const rec = store.setSession('_active', { sessionId: sid, name: name || null, projectRoot });
      return { id: sid, name: name || null };
    },
    switchSession: async (selector) => {
      const list = store.listSessions();
      const hit = list.find((s) => s.name === selector || s.sessionId === selector)
               || list[parseInt(selector, 10) - 1];
      if (!hit) throw new Error('找不到会话：' + selector);
      return { id: hit.sessionId, name: hit.name };
    },
    getStatus: async () => ({
      connected: adapter.getState() === 'connected',
      project: projectRoot,
      session: store.getSession('_active') ? store.getSession('_active').sessionId : null,
      channel: channelId,
    }),
  });

  let running = false;
  const onEventUnsub = adapter.onEvent(async (event) => {
    if (!running) return;
    try {
      // 1) commands take precedence; ordinary text routes to the project.
      const parsed = parseCommand(event.text);
      if (parsed.kind === 'command' || parsed.kind === 'unknown') {
        const reply = await commandRunner.run(event.text);
        const payload = { conversationId: event.conversationId, text: reply.text, contextToken: event.contextToken };
        await adapter.send(event.conversationId, payload);
        store.appendMessage({ conversationId: event.conversationId, dir: 'in', text: event.text });
        store.appendMessage({ conversationId: event.conversationId, dir: 'out', text: reply.text });
        if (opts.onEvent) opts.onEvent(event, { command: parsed.name || parsed.kind, reply });
        return;
      }
      // 2) ordinary message: ensure a session mapping then route via manager.
      let rec = store.getSession(event.conversationId);
      if (!rec) {
        const sid = await sessionDriver.createSession(opts.port || 3080, { cwd: projectRoot });
        rec = store.setSession(event.conversationId, { sessionId: sid, projectRoot });
      }
      // Ensure the event routes to the project whose session we resolved.
      event.sessionId = rec.sessionId;
      store.appendMessage({ conversationId: event.conversationId, sessionId: rec.sessionId, dir: 'in', text: event.text });
      const result = await manager.enqueue(event);
      const replyText = result && result.reply && result.reply.text;
      if (replyText) {
        store.appendMessage({ conversationId: event.conversationId, sessionId: rec.sessionId, dir: 'out', text: replyText });
      }
      if (opts.onEvent) opts.onEvent(event, result);
    } catch (e) {
      // isolation: a failed message must not kill the poll loop
    }
  });

  return {
    channelId,
    adapter,
    manager,
    store,
    commandRunner,
    async start() {
      running = true;
      await adapter.connect();
    },
    async stop() {
      running = false;
      onEventUnsub();
      await adapter.disconnect();
    },
    state: () => adapter.getState(),
    account: () => loadChannelAccount(channelId, opts.dshHome),
  };
}

module.exports = { runWeixinChannel, buildWeixinAdapters };
