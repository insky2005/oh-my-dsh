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
 *   - global  — session/project-independent (/help /ping /status /workspaces
 *               /wks). These must work with NO bound project and must never
 *               produce the "该会话未绑定任何项目" hint.
 *   - project — need a workspace / switched workspace context (/new /sessions
 *               /ses /switch).
 *   - quick   — #wN / #sN codes shown for reference in /help.
 *
 * Two layers:
 *   1. parseCommand(text)  — decide command vs ordinary message (never misjudge
 *      a path like /Users/foo as a command).
 *   2. createCommandRunner  — execute a parsed command, given injected session
 *      operations (getSessions/createSession/switchSession/getStatus). Returns
 *      the reply text to send back to the client.
 *
 *   const { parseCommand, createCommandRunner } = require('@oh-my-dsh/core');
 */

const { toHomePath } = require('./channel-workspaces');

/** Command groups, in /help display order. */
const GROUP_ORDER = ['global', 'project'];

/** Display headings per group. */
const GROUP_LABELS = {
  global: '全局指令（无需绑定项目）',
  project: '项目指令（需绑定 workspace / 先切好 workspace 上下文）',
};

/** Per-group display order (primary command names). */
const GLOBAL_ORDER = ['help', 'ping', 'status', 'workspaces', 'wks'];
const PROJECT_ORDER = ['new', 'sessions', 'ses', 'switch'];

/** Known commands (group drives /help layout; aliases are extra recognisable names). */
const KNOWN = {
  // --- global ---
  help: { group: 'global', arg: 0, title: '/help', desc: '列出所有指令' },
  ping: { group: 'global', arg: 0, title: '/ping', desc: '连通性测试' },
  status: { group: 'global', arg: 0, title: '/status', desc: '查看连接/项目/会话状态' },
  workspaces: { group: 'global', arg: 0, title: '/workspaces', desc: '列出 workspace 并分配代号 #w1/#w2…（别名 /wks）', aliases: ['wks'] },
  wks: { group: 'global', arg: 0, title: '/wks', desc: '列出 workspace 并分配代号 #w1/#w2…' },
  // --- project ---
  new: { group: 'project', arg: 'name?', title: '/new [名称]', desc: '新建一个独立会话' },
  sessions: { group: 'project', arg: 0, title: '/sessions', desc: '列出当前项目的所有会话（别名 /ses）', aliases: ['ses'] },
  ses: { group: 'project', arg: 0, title: '/ses', desc: '列出当前项目的所有会话' },
  switch: { group: 'project', arg: 'name', title: '/switch <名称/编号/#sN>', desc: '切换当前会话' },
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
 * Build the /help reply text: grouped + ordered (global, project, quick).
 */
function helpText() {
  const lines = [];
  for (const gid of GROUP_ORDER) {
    lines.push(GROUP_LABELS[gid] + '：');
    const order = gid === 'global' ? GLOBAL_ORDER : PROJECT_ORDER;
    for (const name of order) {
      const c = KNOWN[name];
      lines.push('  ' + c.title + ' — ' + c.desc);
    }
  }
  lines.push('快速切换：');
  lines.push('  #w1、#w2… — 把消息路由到对应 workspace（见 /wks）');
  lines.push('  #s1、#s2… — 切换会话（见 /sessions，/switch #sN）');
  return lines.join('\n');
}

/**
 * Create a command executor.
 *
 * deps (all injectable, may be async):
 *   getSessions(): Promise<Array<{ id, sessionId?, name?, projectRoot?, createdAt?, updatedAt? }>>
 *   createSession(name?): Promise<{ id, name? }>   // also updates the active mapping
 *   switchSession(selector): Promise<{ id, name? }> // selector = name / index-ish / sessionId
 *   getStatus(): Promise<{ channel?, project?, session?, connected? }>
 *   getWorkspaces(): Promise<Array<{ id, name?, path? }>>  // coded already or raw
 *
 * Returns run(text) -> Promise<string> reply.
 */
function createCommandRunner(deps = {}) {
  const getSessions = deps.getSessions || (async () => []);
  const createSession = deps.createSession || (async () => ({ id: 'n/a' }));
  const switchSession = deps.switchSession || (async () => ({ id: 'n/a' }));
  const getStatus = deps.getStatus || (async () => ({}));
  const getWorkspaces = deps.getWorkspaces || (async () => []);
  // Home dir for ~-shortening display paths (injectable for tests).
  const homeDir = deps.homeDir || require('node:os').homedir();

  async function run(text) {
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
    switch (name) {
      case 'help':
        return { kind: 'reply', text: '可用指令：\n' + helpText() };
      case 'ping': {
        const t0 = Date.now();
        return { kind: 'reply', text: 'pong (' + (Date.now() - t0) + 'ms)' };
      }
      case 'sessions':
      case 'ses': {
        const list = await getSessions();
        if (!list || list.length === 0) return { kind: 'reply', text: '当前项目还没有会话（/new 新建）' };
        const lines = list.map((s, i) => '#s' + (i + 1) + '  ' + (s.name || s.sessionId || s.id || 'unnamed') + '  ' + toHomePath(s.projectRoot, homeDir));
        return { kind: 'reply', text: '会话列表：\n' + lines.join('\n') };
      }
      case 'new': {
        const name = args[0] || '';
        const created = await createSession(name);
        return { kind: 'reply', text: '已新建会话：' + (created.name || created.id || 'unnamed') };
      }
      case 'switch': {
        const selector = args.join(' ').trim();
        if (!selector) return { kind: 'reply', text: '用法：/switch <会话名或编号，或 #sN>' };
        let target = selector;
        // Resolve a #sN code (as shown by /sessions) to the session id/name.
        if (/^#s\d+$/i.test(selector)) {
          const list = await getSessions();
          const idx = parseInt(selector.slice(2), 10) - 1;
          const hit = list[idx];
          if (!hit) return { kind: 'reply', text: '找不到会话 ' + selector };
          target = hit.sessionId || hit.id || hit.name;
        }
        try {
          const s = await switchSession(target);
          return { kind: 'reply', text: '已切换到：' + (s.name || s.id || target) };
        } catch (e) {
          return { kind: 'reply', text: '切换失败：' + (e && e.message || String(e)) };
        }
      }
      case 'status': {
        const st = await getStatus();
        const lines = [
          '连接：' + (st.connected === undefined ? 'n/a' : (st.connected ? '已连接' : '未连接')),
          '项目：' + (st.project || 'n/a'),
          '当前会话：' + (st.session || 'n/a'),
          '通道：' + (st.channel || 'n/a'),
        ];
        return { kind: 'reply', text: lines.join('\n') };
      }
      case 'workspaces':
      case 'wks': {
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
      default:
        return { kind: 'reply', text: '未知指令 /' + name + '（/help 查看）' };
    }
  }

  return { run, helpText, parseCommand };
}

module.exports = { parseCommand, createCommandRunner, KNOWN, helpText, GROUP_ORDER, GROUP_LABELS, GLOBAL_ORDER, PROJECT_ORDER };
