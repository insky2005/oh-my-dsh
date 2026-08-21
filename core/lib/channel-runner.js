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
const { assignCodes, resolveWorkspaceTag } = require('./channel-workspaces');
const { loadChannelAccount } = require('./channel-store');
const { createQueue } = require('./jobqueue');

/**
 * Build the adapters map for a set of project refs. Each distinct channelId in
 * refs gets a ClawBot adapter backed by its saved account token (if any).
 * Returns { adapters: Map, refsByChannel(channelId) }.
 */
function buildWeixinAdapters({ refs, dshHome, transportOpts, intervalMs, ensureChannelId }) {
  const adapters = new Map();
  const byChannel = new Map();
  for (const ref of refs || []) {
    if (!ref.channelId) continue;
    const list = byChannel.get(ref.channelId) || [];
    list.push(ref);
    byChannel.set(ref.channelId, list);
  }
  // Always build an adapter for the explicitly requested channel, even when
  // no refs reference it yet (e.g. startup before project binding).
  if (ensureChannelId && !byChannel.has(ensureChannelId)) {
    byChannel.set(ensureChannelId, []);
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
 * Load dsh workspaces (via workspace.list) and assign codes.
 * Returns [{ id, path, name, code }], empty on failure.
 */
async function loadWorkspaces(port, host, timeoutMs) {
  try {
    const { rpc } = require('./session-driver');
    const json = await rpc(port, 'workspace.list', {}, host || '127.0.0.1', timeoutMs || 8000);
    const v = json && json.result && json.result.value;
    if (!v || !Array.isArray(v.items)) return [];
    return assignCodes(v.items);
  } catch {
    return [];
  }
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
    ensureChannelId: channelId,
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

  // Workspace routing (docs §3.9): codes w1/w2… + #tag.
  const port = opts.port || 3080;
  const wsHost = opts.host || '127.0.0.1';
  const getCodedWorkspaces = async () => loadWorkspaces(port, wsHost, opts.timeoutMs);

  // Command runner wired to the session store + session driver.
  const commandRunner = opts.commands || createCommandRunner({
    getSessions: () => store.listSessions(),
    getWorkspaces: () => getCodedWorkspaces(),
    createSession: async (name) => {
      // /new [#w1] — route to the tagged/first workspace.
      const ws = await getCodedWorkspaces();
      const resolved = resolveWorkspaceTag(name || '', { workspaces: ws, preferFirst: true });
      const targetRoot = resolved.workspace ? resolved.workspace.path : projectRoot;
      const sid = await sessionDriver.createSession(port, { cwd: targetRoot });
      const rec = store.setSession('_active', { sessionId: sid, name: name || null, projectRoot: targetRoot });
      return { id: sid, name: name || null, workspace: resolved.workspace };
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
      console.log('[runner:' + channelId + '] onEvent received id=' + (event.messageId || '?') + ' text=' + JSON.stringify(event.text) + ' @' + Date.now());
      // 1) commands take precedence; ordinary text routes to the project.
      const parsed = parseCommand(event.text);
      if (parsed.kind === 'command' || parsed.kind === 'unknown') {
        const reply = await commandRunner.run(event.text);
        console.log('[runner:' + channelId + '] command ' + (parsed.name || parsed.kind) + ' -> reply=' + JSON.stringify(reply && reply.text));
        const payload = { conversationId: event.conversationId, text: reply.text, contextToken: event.contextToken };
        await adapter.send(event.conversationId, payload);
        store.appendMessage({ conversationId: event.conversationId, dir: 'in', text: event.text });
        store.appendMessage({ conversationId: event.conversationId, dir: 'out', text: reply.text });
        if (opts.onEvent) opts.onEvent(event, { command: parsed.name || parsed.kind, reply });
        return;
      }
      // 2) ordinary message: resolve target workspace (#tag / last / first),
      // then ensure a session mapping and route via manager.
      const ws = await getCodedWorkspaces();
      const resolved = resolveWorkspaceTag(event.text, {
        workspaces: ws,
        lastCode: store.getSession('lastWorkspace') ? store.getSession('lastWorkspace').sessionId : null,
        preferFirst: true,
      });
      const targetRoot = resolved.workspace ? resolved.workspace.path : projectRoot;
      if (resolved.workspace) {
        store.setSession('lastWorkspace', { sessionId: resolved.workspace.code, name: 'lastWorkspace', projectRoot: targetRoot });
      }
      // strip the #tag so it isn't sent to the session as literal text
      const sessionText = resolved.cleanText || event.text;
      let rec = store.getSession(event.conversationId);
      if (!rec || (resolved.source === 'tag' && rec.projectRoot !== targetRoot)) {
        const sid = await sessionDriver.createSession(port, { cwd: targetRoot });
        rec = store.setSession(event.conversationId, { sessionId: sid, projectRoot: targetRoot });
      }
      event.sessionId = rec.sessionId;
      event.workspace = targetRoot;
      store.appendMessage({ conversationId: event.conversationId, sessionId: rec.sessionId, dir: 'in', text: sessionText });
      const eventForSession = { ...event, text: sessionText };
      const result = await manager.enqueue(eventForSession);
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
