'use strict';

/**
 * core/lib/channel-runner.js — run a live channel end-to-end.
 *
 * Shared orchestration for channel platforms (WeChat ClawBot, DingTalk, ...):
 *   credential(disk) -> transport -> adapter (long-poll or push/Stream)
 *     -> ChannelManager (Router + SessionDriver against live dsh web)
 *     -> reply via adapter.send
 *
 * Inbound messages are first checked against the slash-command table
 * (docs/channel-ui-commands.md §4): commands are handled by
 * createCommandRunner (no project session); ordinary text is routed to the
 * project via Router -> dsh session, with a persistent conversationId ->
 * sessionId mapping (createChannelSessions, decision E).
 *
 *   const { runWeixinChannel, runDingTalkChannel } = require('@oh-my-dsh/core');
 *   const handle = runWeixinChannel({ channelId, port, refs, dshHome });
 *   await handle.start();
 *   ...
 *   await handle.stop();
 */

const { createWeixinClawBotTransport } = require('./weixin-clawbot-transport');
const { createWeixinClawBotAdapter } = require('./weixin-clawbot');
const { createDingTalkTransport, createDingTalkStreamClient } = require('./dingtalk-stream-transport');
const { createDingTalkAdapter } = require('./dingtalk');
const { createDingTalkAuth } = require('./dingtalk-access');
const { createSessionDriver, listWorkspaceSessions } = require('./session-driver');
const { createChannelManager, normalizeEvent, resolveRefBinding } = require('./channel');
const { createCommandRunner, parseCommand } = require('./channel-commands');
const { createChannelSessions } = require('./channel-sessions');
const { assignCodes, resolveWorkspaceTag, toHomePath } = require('./channel-workspaces');
const { loadChannelAccount, createChannelRuntimeStore } = require('./channel-store');
const { createQueue } = require('./jobqueue');
const os = require('node:os');
const path = require('node:path');

/**
 * Build the WeChat ClawBot adapters map for a set of project refs. Each
 * distinct channelId gets a ClawBot adapter backed by its saved account token.
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
  if (ensureChannelId && !byChannel.has(ensureChannelId)) {
    byChannel.set(ensureChannelId, []);
  }
  for (const [channelId, channelRefs] of byChannel) {
    const account = loadChannelAccount(channelId, dshHome);
    const transport = createWeixinClawBotTransport({
      channelId,
      token: account ? account.botToken : null,
      baseUrl: account ? account.baseUrl : undefined,
      userId: account ? account.userId : undefined,
      ...(transportOpts || {}),
    });
    const adapter = createWeixinClawBotAdapter({ channelId, transport, intervalMs: intervalMs || 1000 });
    adapters.set(channelId, adapter);
  }
  const refsByChannel = (channelId) => byChannel.get(channelId) || [];
  return { adapters, refsByChannel };
}

/**
 * Build the DingTalk adapters map. Each distinct channelId gets a DingTalk
 * Stream adapter backed by its saved clientId/clientSecret (AppKey/AppSecret).
 * Returns { adapters: Map, refsByChannel(channelId) }.
 */
function buildDingTalkAdapters({ refs, dshHome, transportOpts, ensureChannelId }) {
  const adapters = new Map();
  const byChannel = new Map();
  for (const ref of refs || []) {
    if (!ref.channelId) continue;
    const list = byChannel.get(ref.channelId) || [];
    list.push(ref);
    byChannel.set(ref.channelId, list);
  }
  if (ensureChannelId && !byChannel.has(ensureChannelId)) {
    byChannel.set(ensureChannelId, []);
  }
  for (const [channelId] of byChannel) {
    const account = loadChannelAccount(channelId, dshHome);
    const client = transportOpts && transportOpts.clientFactory
      ? transportOpts.clientFactory(channelId, account, transportOpts)
      : createDingTalkStreamClient({
          channelId,
          clientId: account ? account.clientId || account.appKey : null,
          clientSecret: account ? account.clientSecret || account.appSecret : null,
          ...(transportOpts || {}),
        });
    const transport = createDingTalkTransport({ channelId, client, fetch: transportOpts && transportOpts.fetch, log: transportOpts && transportOpts.log });
    const adapter = createDingTalkAdapter({ channelId, transport });
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
 * Shared live-channel orchestration. Called by runWeixinChannel / runDingTalkChannel
 * with the platform-appropriate adapter builder.
 *
 * opts (in addition to platform/buildAdapters):
 *   channelId   - the global channel id whose saved credential to use
 *   port        - dsh web port (default 3080)
 *   refs        - project refs for this channel (from .dsh/channels.json)
 *   dshHome     - DSH_HOME for credential lookup (default ~/.dsh)
 *   sessionOpts - overrides for createSessionDriver (poll interval etc.)
 *   transportOpts - overrides for the platform transport
 *   intervalMs  - weixin adapter long-poll interval (ignored for push transports)
 *   onEvent     - optional callback(event, result) after handling each message
 *   commands    - optional pre-built command runner deps
 */
async function runChannel(opts = {}) {
  const platform = opts.platform;
  const channelId = opts.channelId;
  if (!channelId) throw new Error('channel-runner: channelId required');
  if (!opts.buildAdapters) throw new Error('channel-runner: buildAdapters required');
  const { adapters, refsByChannel } = opts.buildAdapters({
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

  const projectRoot = opts.projectRoot
    || (opts.refs && opts.refs[0] && opts.refs[0].workspaceRoot)
    || path.join(os.homedir(), '.dsh', 'channel-runtime', channelId);
  const store = opts.sessions || createChannelSessions({ channelId, dshHome: opts.dshHome, defaultProjectRoot: projectRoot });

  let enabledCache = { roots: null, at: 0 };
  const isEnabledForRoot = (root) => {
    if (!root) return false;
    const now = Date.now();
    if (!enabledCache.roots || now - enabledCache.at > 1000) {
      try { enabledCache.roots = store.listEnabledWorkspaces ? store.listEnabledWorkspaces() : []; } catch { enabledCache.roots = []; }
      enabledCache.at = now;
    }
    return enabledCache.roots.includes(root);
  };
  const sendNotEnabled = (event) => adapter.send(event.conversationId, { text: '该项目未启用该通道，请在面板「通道」项目视图开启后使用' });

  const port = opts.port || 3080;
  const wsHost = opts.host || '127.0.0.1';
  const homeDir = opts.homeDir || require('node:os').homedir();
  const getCodedWorkspaces = async () => loadWorkspaces(port, wsHost, opts.timeoutMs);

  const runtime = opts.runtime || createChannelRuntimeStore({ channelId, dshHome: opts.dshHome });
  const getLastWorkspace = () => runtime.getLastWorkspace();
  const setLastWorkspace = (ws) => runtime.setLastWorkspace(ws);
  const currentWorkspaceRoot = () => {
    const lw = runtime.getLastWorkspace();
    return (lw && lw.projectRoot) || projectRoot;
  };
  const currentSessions = () => listWorkspaceSessions(port, wsHost, currentWorkspaceRoot(), opts.timeoutMs);
  const sessionCode = async (sessionId) => {
    const list = await currentSessions();
    const idx = list.findIndex((s) => s.sessionId === sessionId);
    return idx >= 0 ? 's' + (idx + 1) : '';
  };

  const commandRunner = opts.commands || createCommandRunner({
    getSessions: () => currentSessions(),
    getWorkspaces: async () => {
      const ws = await getCodedWorkspaces();
      return ws.filter((w) => isEnabledForRoot(w.path));
    },
    createSession: async (content) => {
      const ws = await getCodedWorkspaces();
      const resolved = resolveWorkspaceTag(content || '', {
        workspaces: ws,
        lastCode: getLastWorkspace() ? getLastWorkspace().code : null,
        preferFirst: true,
      });
      const target = resolved.workspace || null;
      const targetRoot = target ? target.path : projectRoot;
      if (!isEnabledForRoot(targetRoot)) {
        runtime.setActiveSession(null);
        throw new Error('该项目未启用该通道，请在面板「通道」项目视图开启后使用');
      }
      const sid = target && target.id
        ? await sessionDriver.createSession(port, { workspaceId: target.id })
        : await sessionDriver.createSession(port, { cwd: targetRoot });
      let reply;
      if (content) {
        await sessionDriver.renameSession(port, sid, content, wsHost, opts.timeoutMs);
        runtime.setActiveSession({ sessionId: sid, name: content, projectRoot: targetRoot, pendingPrompt: false });
        const code = await sessionCode(sid);
        reply = '创建新会话 #' + code + ' (' + sid + ')';
      } else {
        runtime.setActiveSession({ sessionId: sid, name: 'New Session', projectRoot: targetRoot, pendingPrompt: true });
        const code = await sessionCode(sid);
        reply = '创建新会话 #' + code + ' (' + sid + ')\n请继续与我对话，我正在听...';
      }
      return { id: sid, name: content || 'New Session', workspace: target, reply };
    },
    switchSession: async (selector) => {
      const list = await currentSessions();
      const sel = String(selector || '').trim();
      let hit = null;
      const m = /^#s(\d+)$/i.exec(sel);
      if (m) hit = list[parseInt(m[1], 10) - 1];
      else hit = list.find((s) => s.name === sel || s.sessionId === sel) || list[parseInt(sel, 10) - 1];
      if (!hit) throw new Error('找不到会话：' + sel);
      runtime.setActiveSession({ sessionId: hit.sessionId, projectRoot: hit.projectRoot, name: hit.name });
      return { id: hit.sessionId, name: hit.name, projectRoot: hit.projectRoot };
    },
    switchWorkspace: async (selector) => {
      const sel = String(selector || '').trim();
      const coded = await getCodedWorkspaces();
      let target = null;
      const m = /^#?w(\d+)$/i.exec(sel);
      if (m) {
        target = coded[parseInt(m[1], 10) - 1] || null;
      } else {
        const low = sel.toLowerCase();
        target = coded.find((w) => {
          const n = (w.name || '').toLowerCase();
          const p = (w.path || '').toLowerCase();
          return n === low || p === low || p.includes(low) || n.includes(low);
        }) || null;
      }
      if (!target) throw new Error('未找到工作区：' + sel + '（/wks 或 /workspaces 查看）');
      if (!isEnabledForRoot(target.path)) {
        throw new Error('该项目未启用该通道，请在面板「通道」项目视图开启后使用');
      }
      setLastWorkspace(target);
      runtime.setActiveSession(null);
      const recent = (await currentSessions()).slice(0, 5);
      return { code: target.code, name: target.name || '', path: target.path, recent };
    },
    bindSession: (conversationId, rec) => store.setSession(conversationId, rec),
    getStatus: async () => {
      const lw = runtime.getLastWorkspace();
      const active = runtime.getActiveSession();
      const sessions = await currentSessions();
      const activeIdx = active ? sessions.findIndex((s) => s.sessionId === active.sessionId) : -1;
      return {
        channel: channelId,
        connected: adapter.getState() === 'connected',
        workspace: lw ? { code: lw.code, name: lw.name || '', path: lw.projectRoot || '' } : null,
        session: active
          ? { code: activeIdx >= 0 ? 's' + (activeIdx + 1) : '', sessionId: active.sessionId, name: active.name || '' }
          : null,
      };
    },
  });

  let running = false;
  const busy = new Set();
  const isBusy = (conversationId) => busy.has(conversationId);

  function dispatchGeneration({ conversationId, sessionId, workspace, workspaceId, text, contextToken }) {
    busy.add(conversationId);
    (async () => {
      try {
        if (adapter.sendTyping) { try { await adapter.sendTyping(conversationId, 1, contextToken); } catch { /* best-effort */ } }
        const event = { channelId, platform, conversationId, sessionId, workspace, workspaceId, text, contextToken };
        const reply = await sessionDriver.run(event, { workspaceRoot: workspace, workspaceId });
        const outText = reply && reply.text;
        if (outText) {
          store.appendMessage({ conversationId, sessionId: (reply && reply.sessionId) || sessionId, dir: 'out', text: outText });
          await adapter.send(conversationId, { text: outText, contextToken });
        }
        if (opts.onEvent) opts.onEvent(event, { reply });
      } catch (e) {
        try { await adapter.send(conversationId, { text: '生成失败：' + (e && e.message || String(e)), contextToken }); } catch { /* ignore */ }
      } finally {
        if (adapter.sendTyping) { try { await adapter.sendTyping(conversationId, 2, contextToken); } catch { /* best-effort */ } }
        busy.delete(conversationId);
      }
    })();
  }

  const onEventUnsub = adapter.onEvent(async (event) => {
    if (!running) return;
    // Optional access gate (dingtalk owner-binding): consume /bind, reject unauthorized.
    if (opts.auth) {
      const a = await opts.auth.check(event);
      if (a.handled || !a.allowed) {
        store.appendMessage({ conversationId: event.conversationId, dir: 'in', text: event.text });
        if (a.reply) {
          store.appendMessage({ conversationId: event.conversationId, dir: 'out', text: a.reply });
          try { await adapter.send(event.conversationId, { text: a.reply, contextToken: event.contextToken }); } catch { /* ignore */ }
        }
        if (opts.onEvent) opts.onEvent(event, { auth: { handled: a.handled, allowed: a.allowed, reply: a.reply } });
        return;
      }
    }
    try {
      const parsed = parseCommand(event.text);
      if (parsed.kind === 'command' || parsed.kind === 'unknown') {
        if (parsed.kind === 'command' && parsed.name === 'new' && parsed.args && parsed.args[0] && isBusy(event.conversationId)) {
          await adapter.send(event.conversationId, { text: '请等待，前一条消息还在处理中', contextToken: event.contextToken });
          store.appendMessage({ conversationId: event.conversationId, dir: 'in', text: event.text });
          return;
        }
        if (parsed.kind === 'command'
            && (parsed.name === 'sessions' || parsed.name === 'ses')
            && !isEnabledForRoot(currentWorkspaceRoot())) {
          await adapter.send(event.conversationId, { text: '该项目未启用该通道，请在面板「通道」项目视图开启后使用', contextToken: event.contextToken });
          store.appendMessage({ conversationId: event.conversationId, dir: 'in', text: event.text });
          return;
        }
        const reply = await commandRunner.run(event.text, { conversationId: event.conversationId });
        if (parsed.kind === 'command' && parsed.name === 'new') {
          const act = runtime.getActiveSession();
          if (act && act.sessionId) {
            store.setSession(event.conversationId, { sessionId: act.sessionId, projectRoot: act.projectRoot, name: act.name });
            const payload = { conversationId: event.conversationId, text: reply.text, contextToken: event.contextToken };
            await adapter.send(event.conversationId, payload);
            store.appendMessage({ conversationId: event.conversationId, dir: 'in', text: event.text });
            store.appendMessage({ conversationId: event.conversationId, dir: 'out', text: reply.text });
            if (parsed.args && parsed.args[0]) {
              dispatchGeneration({
                conversationId: event.conversationId,
                sessionId: act.sessionId,
                workspace: act.projectRoot || projectRoot,
                workspaceId: null,
                text: parsed.args.join(' '),
                contextToken: event.contextToken,
              });
            }
            if (opts.onEvent) opts.onEvent(event, { command: 'new', reply });
            return;
          }
        }
        const payload = { conversationId: event.conversationId, text: reply.text, contextToken: event.contextToken };
        await adapter.send(event.conversationId, payload);
        store.appendMessage({ conversationId: event.conversationId, dir: 'in', text: event.text });
        store.appendMessage({ conversationId: event.conversationId, dir: 'out', text: reply.text });
        if (opts.onEvent) opts.onEvent(event, { command: parsed.name || parsed.kind, reply });
        return;
      }
      const quick = /^#([ws])(\d+)\s*$/i.exec(String(event.text || '').trim());
      if (quick) {
        const kind = quick[1].toLowerCase();
        const n = parseInt(quick[2], 10);
        let replyText;
        if (kind === 'w') {
          const ws = await getCodedWorkspaces();
          const w = ws[n - 1];
          if (!w) {
            replyText = '未找到工作区 #w' + n + ' （/wks 或 /workspaces 查看）';
          } else if (!isEnabledForRoot(w.path)) {
            replyText = '该项目未启用该通道，请在面板「通道」项目视图开启后使用';
          } else {
            setLastWorkspace(w);
            runtime.setActiveSession(null);
            const lines = ['已切换到工作区 #' + w.code + ' (' + (w.name || '') + '), ' + toHomePath(w.path, homeDir), '当前会话：n/a'];
            const recent = (await currentSessions()).slice(0, 5);
            if (recent.length) {
              lines.push('最近会话（' + recent.length + '）：');
              recent.forEach((s, i) => { lines.push('  #s' + (i + 1) + ' (' + s.sessionId + '), ' + (s.name || '')); });
            } else {
              lines.push('最近会话：暂无（/new 新建）');
            }
            replyText = lines.join('\n');
          }
        } else {
          if (!isEnabledForRoot(currentWorkspaceRoot())) {
            replyText = '该项目未启用该通道，请在面板「通道」项目视图开启后使用';
          } else {
            const list = await currentSessions();
            const s = list[n - 1];
            if (!s) replyText = '未找到会话 #s' + n + ' （/ses 或 /sessions 查看）';
            else {
              store.setSession(event.conversationId, { sessionId: s.sessionId, projectRoot: s.projectRoot, name: s.name });
              runtime.setActiveSession({ sessionId: s.sessionId, projectRoot: s.projectRoot, name: s.name });
              replyText = '已切换到会话 #s' + n + ' (' + s.sessionId + '), ' + (s.name || '');
            }
          }
        }
        const payload = { conversationId: event.conversationId, text: replyText, contextToken: event.contextToken };
        await adapter.send(event.conversationId, payload);
        store.appendMessage({ conversationId: event.conversationId, dir: 'in', text: event.text });
        store.appendMessage({ conversationId: event.conversationId, dir: 'out', text: replyText });
        if (opts.onEvent) opts.onEvent(event, { command: 'quick-' + kind, reply: { text: replyText } });
        return;
      }
      if (isBusy(event.conversationId)) {
        await adapter.send(event.conversationId, { text: '请等待，前一条消息还在处理中', contextToken: event.contextToken });
        store.appendMessage({ conversationId: event.conversationId, dir: 'in', text: event.text });
        if (opts.onEvent) opts.onEvent(event, { busy: true });
        return;
      }
      busy.add(event.conversationId);
      const ws = await getCodedWorkspaces();
      const refRoute = resolveRefBinding(opts.refs, event);
      let resolved;
      if (refRoute) {
        const w = ws.find((x) => x.path === refRoute.workspaceRoot);
        resolved = { workspace: w || null, code: w && w.code, cleanText: String(event.text || ''), source: 'ref' };
      } else {
        resolved = resolveWorkspaceTag(event.text, {
          workspaces: ws,
          lastCode: getLastWorkspace() ? getLastWorkspace().code : null,
          preferFirst: true,
        });
      }
      const targetRoot = resolved.workspace ? resolved.workspace.path : projectRoot;
      const targetWsId = resolved.workspace ? resolved.workspace.id : null;
      if (!isEnabledForRoot(targetRoot)) {
        await sendNotEnabled(event);
        if (opts.onEvent) opts.onEvent(event, { projectNotEnabled: true });
        busy.delete(event.conversationId);
        return;
      }
      if (resolved.workspace) {
        setLastWorkspace({ code: resolved.workspace.code, name: resolved.workspace.name, projectRoot: targetRoot });
      }
      const sessionText = resolved.cleanText || event.text;
      const active = runtime.getActiveSession();
      if (active && active.pendingPrompt && sessionText && active.projectRoot === targetRoot) {
        runtime.setActiveSession({ sessionId: active.sessionId, projectRoot: targetRoot, name: sessionText, pendingPrompt: false });
        store.setSession(event.conversationId, { sessionId: active.sessionId, projectRoot: targetRoot, name: sessionText });
        store.appendMessage({ conversationId: event.conversationId, sessionId: active.sessionId, dir: 'in', text: sessionText });
        if (opts.onEvent) opts.onEvent(event, { command: 'activate-session' });
        dispatchGeneration({ conversationId: event.conversationId, sessionId: active.sessionId, workspace: targetRoot, workspaceId: targetWsId, text: sessionText, contextToken: event.contextToken });
        return;
      }
      let rec = store.getSession(event.conversationId);
      if (!rec || rec.projectRoot !== targetRoot) {
        const sid = targetWsId
          ? await sessionDriver.createSession(port, { workspaceId: targetWsId })
          : await sessionDriver.createSession(port, { cwd: targetRoot });
        rec = store.setSession(event.conversationId, { sessionId: sid, projectRoot: targetRoot });
      }
      event.sessionId = rec.sessionId;
      event.workspaceId = targetWsId;
      event.workspace = targetRoot;
      event.projectRoot = targetRoot;
      store.appendMessage({ conversationId: event.conversationId, sessionId: rec.sessionId, dir: 'in', text: sessionText });
      dispatchGeneration({ conversationId: event.conversationId, sessionId: rec.sessionId, workspace: targetRoot, workspaceId: targetWsId, text: sessionText, contextToken: event.contextToken });
    } catch (e) {
      /* isolation: a failed message must not kill the loop */
    }
  });

  const onStateUnsub = adapter.onState ? adapter.onState((s) => { try { runtime.setConnectionState(s); } catch { /* non-fatal */ } }) : null;
  if (onStateUnsub) runtime.setConnectionState(adapter.getState());

  return {
    channelId,
    adapter,
    manager,
    store,
    runtime,
    commandRunner,
    async start() {
      running = true;
      await adapter.connect();
      try { runtime.setConnectionState(adapter.getState()); } catch { /* non-fatal */ }
    },
    async stop() {
      running = false;
      onEventUnsub();
      if (typeof onStateUnsub === 'function') onStateUnsub();
      await adapter.disconnect();
    },
    state: () => adapter.getState(),
    account: () => loadChannelAccount(channelId, opts.dshHome),
  };
}

/**
 * Run a live WeChat ClawBot channel end-to-end (long-poll transport).
 */
async function runWeixinChannel(opts = {}) {
  return runChannel({ ...opts, platform: 'weixin-clawbot', buildAdapters: buildWeixinAdapters });
}

/**
 * Run a live DingTalk channel end-to-end (Stream push transport).
 */
async function runDingTalkChannel(opts = {}) {
  const channelId = opts.channelId;
  const log = opts.log || ((m) => console.log(m));
  const auth = createDingTalkAuth({ channelId, dshHome: opts.dshHome, log });
  log('[dingtalk:' + channelId + '] 管理员绑定口令：' + auth.getBindCode()
    + (auth.isBound() ? '（已绑定）' : '（未绑定：发送 /bind <口令> 完成绑定）'));
  return runChannel({ ...opts, platform: 'dingtalk', buildAdapters: buildDingTalkAdapters, auth });
}

module.exports = { runWeixinChannel, runDingTalkChannel, buildWeixinAdapters, buildDingTalkAdapters };