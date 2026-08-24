'use strict';

/**
 * core/lib/channel-commands.js — slash-command parsing & execution for channels.
 *
 * Docs: docs/channel-ui-commands.md §4. Platform-independent Node module so any
 * shell (macOS/Windows/Linux) reuses the exact same command semantics.
 *
 * Commands are grouped so that /help stays readable and so the runner can treat
 * them differently:
 *
 *   - global   — session/project-independent (/help /ping /status). These must
 *                work with NO bound project and must never produce the
 *                "该会话未绑定任何项目" hint.
 *   - workspace — need a workspace / switched workspace context (/workspaces
 *                /wks /sessions /ses /new).
 *   - quick    — #wN / #sN codes shown for reference in /help.
 *
 * Two layers:
 *   1. parseCommand(text)  — decide command vs ordinary message (never misjudge
 *      a path like /Users/foo as a command).
 *   2. createCommandRunner  — execute a parsed command, given injected session
 *      operations (getSessions/createSession/switchSession/switchWorkspace/
 *      bindSession/getStatus). Returns the reply text to send back to the client.
 *
 * run(text, ctx) — ctx is optional ({ conversationId }) so a session switch
 *   (via /sessions /ses with an argument) can bind the conversation mapping.
 *
 *   const { parseCommand, createCommandRunner } = require('@oh-my-dsh/core');
 */

const { toHomePath } = require('./channel-workspaces');

/** Command groups, in /help display order. */
const GROUP_ORDER = ['global', 'workspace'];

/** Display headings per group. */
const GROUP_LABELS = {
  global: '全局指令（无需绑定项目）',
  workspace: '工作区指令（需绑定 workspace / 先切好 workspace 上下文）',
};

/** Per-group display order (primary command names; aliases are folded in). */
const GLOBAL_ORDER = ['help', 'ping', 'status'];
const WORKSPACE_ORDER = ['workspaces', 'sessions', 'new'];

/** Known commands (group drives /help layout; aliases are extra recognisable names). */
const KNOWN = {
  // --- global ---
  help: { group: 'global', arg: 0, title: '/help', desc: '列出所有指令' },
  ping: { group: 'global', arg: 0, title: '/ping', desc: '连通性测试' },
  status: { group: 'global', arg: 0, title: '/status', desc: '查看连接/项目/会话状态' },
  // --- workspace ---
  workspaces: { group: 'workspace', arg: 'name?', title: '/workspaces、/wks [名称或代号]', desc: '列出或切换工作区', aliases: ['wks'] },
  wks: { group: 'workspace', arg: 'name?', title: '/wks [名称或代号]', desc: '列出或切换工作区' },
  sessions: { group: 'workspace', arg: 'name?', title: '/sessions、/ses [会话id或代号]', desc: '列出或切换会话（最近 5 条）', aliases: ['ses'] },
  ses: { group: 'workspace', arg: 'name?', title: '/ses [会话id或代号]', desc: '列出或切换会话（最近 5 条）' },
  new: { group: 'workspace', arg: 'content?', title: '/new [内容]', desc: '创建新会话' },
};

/**
 * Parse a message into a command or ordinary text.
 *
 * Returns:
 *   { kind: "command", name, args: string[] }  when the whole message starts
 *   with "/" and the first token is a known command;
 *   { kind: "text", text } otherwise (incl. unknown "/xxx" and paths).
 */
function parseCommand(text) {
  if (typeof text !== 'string' || !text.startsWith('/')) return { kind: 'text', text };
  const parts = text.split(/\s+/).filter(Boolean);
  const name = (parts[0] || '').slice(1).toLowerCase();
  if (!name) return { kind: 'text', text };
  if (KNOWN[name]) {
    return { kind: 'command', name, args: parts.slice(1) };
  }
  // Unknown /xxx — treat as a command-ish reply (not a path).
  return { kind: 'unknown', name, text };
}

/**
 * Build the /help reply text: grouped + ordered (global, workspace, quick).
 */
function helpText() {
  const lines = [];
  for (const gid of GROUP_ORDER) {
    lines.push(GROUP_LABELS[gid] + '：');
    const order = gid === 'global' ? GLOBAL_ORDER : WORKSPACE_ORDER;
    for (const name of order) {
      const c = KNOWN[name];
      lines.push('  ' + c.title + ' — ' + c.desc);
    }
  }
  lines.push('快捷指令（# 开头，设置当前工作区 / 会话）：');
  lines.push('  #w1、#w2… — 切换工作区（见 /workspaces）');
  lines.push('  #s1、#s2… — 切换会话（见 /sessions）');
  return lines.join('\n');
}

/**
 * Create a command executor.
 *
 * deps (all injectable, may be async):
 *   getSessions(): Promise<Array<{ id, sessionId?, name?, projectRoot?, createdAt?, updatedAt? }>>
 *   createSession(content?): Promise<{ id, name?, reply }>  // also updates the active mapping
 *   switchSession(selector): Promise<{ id, name?, projectRoot? }> // selector = name / id / index / #sN
 *   switchWorkspace(selector): Promise<{ code, name?, path?, recent? }> // selector = #wN / wN / name / path
 *   bindSession(conversationId, rec): Promise<void>          // bind a conversation to a session
 *   getStatus(): Promise<{ channel?, project?, session?, connected? }>
 *   getWorkspaces(): Promise<Array<{ id, name?, path? }>>  // coded already or raw
 *
 * Returns run(text, ctx?) -> Promise<{ kind, text?, parsed? }> reply.
 */
function createCommandRunner(deps = {}) {
  const getSessions = deps.getSessions || (async () => []);
  const createSession = deps.createSession || (async () => ({ id: 'n/a', reply: '创建新会话' }));
  const switchSession = deps.switchSession || (async () => ({ id: 'n/a' }));
  const switchWorkspace = deps.switchWorkspace || (async () => { throw new Error('未找到工作区'); });
  const bindSession = deps.bindSession || null;
  const getStatus = deps.getStatus || (async () => ({}));
  const getWorkspaces = deps.getWorkspaces || (async () => []);
  // Home dir for ~-shortening display paths (injectable for tests).
  const homeDir = deps.homeDir || require('node:os').homedir();

  async function run(text, ctx) {
    const parsed = parseCommand(text);
    if (parsed.kind === 'unknown') {
      // Unknown /cmd — reply with a hint, don't route as a message.
      return { kind: 'reply', text: '未知指令 /' + parsed.name + '（/help 查看）' };
    }
    if (parsed.kind !== 'command') {
      // not a command — caller routes as ordinary message
      return { kind: 'text', parsed };
    }
    const { name, args } = parsed;
    const conversationId = ctx && ctx.conversationId;
    switch (name) {
      case 'help':
        return { kind: 'reply', text: '可用指令：\n' + helpText() };
      case 'ping': {
        const t0 = Date.now();
        return { kind: 'reply', text: 'pong (' + (Date.now() - t0) + 'ms)' };
      }
      case 'sessions':
      case 'ses': {
        // With an argument -> switch session (same effect as #sN).
        if (args && args.length) {
          const selector = args.join(' ').trim();
          try {
            const s = await switchSession(selector); // throws 找不到会话 when unresolved
            const list = await getSessions();
            const idx = list.findIndex((x) => x.sessionId === s.id || x.id === s.id);
            const code = idx >= 0 ? 's' + (idx + 1) : '';
            if (bindSession && conversationId && s.id) {
              await bindSession(conversationId, { sessionId: s.id, projectRoot: s.projectRoot, name: s.name });
            }
            return { kind: 'reply', text: '已切换到会话 #' + code + ' (' + (s.id || '') + '), ' + (s.name || '') };
          } catch (e) {
            return { kind: 'reply', text: '找不到会话：' + selector };
          }
        }
        const list = await getSessions();
        if (!list || list.length === 0) return { kind: 'reply', text: '当前项目还没有会话（/new 新建）' };
        const st = await getStatus();
        const wsLine = st.workspace
          ? '工作区 #' + st.workspace.code + ' (' + (st.workspace.name || '') + '), ' + toHomePath(st.workspace.path, homeDir)
          : '工作区 n/a';
        // most recent 5 sessions
        const recent = list.slice(0, 5);
        const lines = recent.map((s, i) => '#s' + (i + 1) + ' (' + (s.sessionId || s.id || '') + '), ' + (s.name || ''));
        return { kind: 'reply', text: wsLine + '\n会话列表：\n' + lines.join('\n') };
      }
      case 'new': {
        const content = args[0] || '';
        try {
          const created = await createSession(content);
          return { kind: 'reply', text: created.reply || ('创建新会话：' + (created.name || created.id || 'unnamed')) };
        } catch (e) {
          return { kind: 'reply', text: (e && e.message) || String(e) };
        }
      }
      case 'workspaces':
      case 'wks': {
        // With an argument -> switch workspace (same effect as #wN).
        if (args && args.length) {
          const selector = args.join(' ').trim();
          try {
            const t = await switchWorkspace(selector); // throws when not found / not enabled
            const lines = [
              '已切换到工作区 #' + t.code + ' (' + (t.name || '') + '), ' + toHomePath(t.path, homeDir),
              '当前会话：n/a',
            ];
            const recent = t.recent || [];
            if (recent.length) {
              lines.push('最近会话（' + recent.length + '）：');
              recent.forEach((s, i) => { lines.push('  #s' + (i + 1) + ' (' + (s.sessionId || '') + '), ' + (s.name || '')); });
            } else {
              lines.push('最近会话：暂无（/new 新建）');
            }
            return { kind: 'reply', text: lines.join('\n') };
          } catch (e) {
            return { kind: 'reply', text: (e && e.message) || String(e) };
          }
        }
        const ws = await getWorkspaces();
        if (!ws || ws.length === 0) return { kind: 'reply', text: '没有可用的 workspace' };
        const lines = ws.map((w, i) => {
          const code = '#' + (w.code || 'w' + (i + 1));
          // name = title (dsh web) or path basename — never the full /Users/... path
          const base = (w.path || '').split(/[\\/]/).filter(Boolean).pop() || '';
          const name = w.name || base || w.id || 'unnamed';
          return code + ' (' + name + '): ' + toHomePath(w.path, homeDir);
        });
        return { kind: 'reply', text: 'workspace 列表：\n' + lines.join('\n') };
      }
      case 'status': {
        const st = await getStatus();
        const ws = st.workspace
          ? '#' + st.workspace.code + ' (' + (st.workspace.name || '') + '), ' + toHomePath(st.workspace.path, homeDir)
          : 'n/a';
        const sess = st.session
          ? '#' + (st.session.code || '?') + ' (' + (st.session.sessionId || '') + '), ' + (st.session.name || '')
          : 'n/a';
        const lines = [
          '通道：' + (st.channel || 'n/a'),
          '连接：' + (st.connected === undefined ? 'n/a' : (st.connected ? '已连接' : '未连接')),
          '当前工作区：' + ws,
          '当前会话：' + sess,
        ];
        return { kind: 'reply', text: lines.join('\n') };
      }
      default:
        return { kind: 'reply', text: '未知指令 /' + name + '（/help 查看）' };
    }
  }

  return { run, helpText, parseCommand };
}

module.exports = { parseCommand, createCommandRunner, KNOWN, helpText, GROUP_ORDER, GROUP_LABELS, GLOBAL_ORDER, WORKSPACE_ORDER };
