'use strict';

/**
 * core/lib/channel-commands.js — slash-command parsing & execution for channels.
 *
 * Docs: docs/channel-ui-commands.md §4. Platform-independent Node module so any
 * shell (macOS/Windows/Linux) reuses the exact same command semantics.
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

/** Known commands (first priority set; add more here as they land). */
const KNOWN = {
  help: { arg: 0, title: '/help', desc: '列出所有指令' },
  new: { arg: 'name?', title: '/new [名称]', desc: '新建一个独立会话' },
  sessions: { arg: 0, title: '/sessions', desc: '列出当前项目的所有会话' },
  switch: { arg: 'name', title: '/switch <名称/编号>', desc: '切换当前会话' },
  status: { arg: 0, title: '/status', desc: '查看连接/项目/会话状态' },
  ping: { arg: 0, title: '/ping', desc: '连通性测试' },
  workspaces: { arg: 0, title: '/workspaces', desc: '列出 workspace 并分配代号 w1/w2…（别名 /wks）' },
  wks: { arg: 0, title: '/wks', desc: '列出 workspace 并分配代号 w1/w2…' },
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
 * Build the /help reply text from the command table.
 */
function helpText() {
  return Object.values(KNOWN)
    .map((c) => c.title + ' — ' + c.desc)
    .join('\n');
}

/**
 * Create a command executor.
 *
 * deps (all injectable, may be async):
 *   getSessions(): Promise<Array<{ id, name?, projectRoot?, createdAt?, updatedAt? }>>
 *   createSession(name?): Promise<{ id, name? }>   // also updates the active mapping
 *   switchSession(selector): Promise<{ id, name? }> // selector = name or index-ish
 *   getStatus(): Promise<{ channel?, project?, session?, connected? }>
 *
 * Returns run(text) -> Promise<string> reply.
 */
function createCommandRunner(deps = {}) {
  const getSessions = deps.getSessions || (async () => []);
  const createSession = deps.createSession || (async () => ({ id: 'n/a' }));
  const switchSession = deps.switchSession || (async () => ({ id: 'n/a' }));
  const getStatus = deps.getStatus || (async () => ({}));
  const getWorkspaces = deps.getWorkspaces || (async () => []);

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
      case 'sessions': {
        const list = await getSessions();
        if (!list || list.length === 0) return { kind: 'reply', text: '当前项目还没有会话（/new 新建）' };
        const lines = list.map((s, i) => (i + 1) + '. ' + (s.name || s.id) + '  ' + (s.projectRoot || ''));
        return { kind: 'reply', text: '会话列表：\n' + lines.join('\n') };
      }
      case 'new': {
        const name = args[0] || '';
        const created = await createSession(name);
        return { kind: 'reply', text: '已新建会话：' + (created.name || created.id || 'unnamed') };
      }
      case 'switch': {
        const selector = args.join(' ').trim();
        if (!selector) return { kind: 'reply', text: '用法：/switch <会话名或编号>' };
        try {
          const s = await switchSession(selector);
          return { kind: 'reply', text: '已切换到：' + (s.name || s.id || selector) };
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
        const lines = ws.map((w, i) => 'w' + (i + 1) + ' → ' + (w.path || w.name || w.id));
        return { kind: 'reply', text: 'workspace 列表：\n' + lines.join('\n') };
      }
      default:
        return { kind: 'reply', text: '未知指令 /' + name + '（/help 查看）' };
    }
  }

  return { run, helpText, parseCommand };
}

module.exports = { parseCommand, createCommandRunner, KNOWN, helpText };
