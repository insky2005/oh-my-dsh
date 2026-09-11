'use strict';

/**
 * core/lib/review-log.js — dsh session-log change audit (READ-ONLY).
 *
 * Answers "which files did the agent change, and how?" for one dsh session,
 * without touching dsh: it reads the session log dsh itself persists under
 * `$DSH_HOME/sessions/<workspace-slug>/<session-id>/session.jsonl[.zstd]` and
 * folds the recorded tool traffic into an audit model.
 *
 * Three record families are merged (see docs/review-panel-design.md):
 *   1. `tool/result` → `data.meta.diffs` — the applied contextual hunks of a
 *      TOP-LEVEL `write`/`edit` call (what the Web GUI's diff card renders);
 *   2. `tool/call` (top-level) / `tool/code-dispatch-start` (nested in run_code)
 *      → `arguments` — the exact requested change (old_string/new_string, or
 *      the whole content of a create);
 *   3. `bash` calls → the command text, flagged when it looks like a write so
 *      the reader knows the file change is NOT structurally recorded.
 *
 * The session log container is a concatenation of independently decodable
 * Zstandard frames (one per durable batch), so a plain one-shot decode returns
 * only the first frame. scanZstdFrames() walks the frame headers and
 * zstdDecompressSync() decodes each frame on its own; a torn final frame is
 * reported and skipped rather than failing the audit.
 *
 *   const { auditSession, listSessionLogs } = require('@oh-my-dsh/core');
 */

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const zlib = require('node:zlib');

/** Session-log artifact names, in preference order (zstd first). */
const SESSION_LOG_FILES = ['session.jsonl.zstd', 'session.jsonl'];

/** Zstandard frame magic (`0xFD2FB528`, little-endian on disk). */
const ZSTD_MAGIC = 4247762216;

/** Bash fragments that mean "this command may write files". */
const BASH_WRITE_HINTS = [
  /(^|[^0-9&])>>?(?![&])/, // > / >> redirection (not 2>&1, not =>)
  /\bsed\b[^|]*\s-i\b/,
  /\bperl\b[^|]*\s-i\b/,
  /\brm\b/,
  /\bmv\b/,
  /\bcp\b/,
  /\btee\b/,
  /\btruncate\b/,
  /\bdd\b/,
  /\bpatch\b/,
  /\bgit\s+(checkout|restore|apply|reset|stash|clean)\b/,
  /\bnpm\s+(install|ci)\b/,
  /\bpnpm\s+(install|add)\b/,
  /\byarn\s+(install|add)\b/,
  /\bmake\b/,
  /\btouch\b/,
  /\bmkdir\b/,
  /\bln\b/,
];

/** First-party tools whose calls mutate files (and how to read their args). */
const MUTATION_TOOLS = new Set(['write', 'edit', 'str_replace_editor']);

/** Tools whose command text is worth auditing even without structure. */
const SHELL_TOOLS = new Set(['bash', 'pwsh']);

// --- diagnostics -----------------------------------------------------------

function diag(list, code, message) {
  list.push({ code, message });
}

/** True when this Node release can decode Zstandard (v22.15+/v23.8+). */
function zstdAvailable() {
  return typeof zlib.zstdDecompressSync === 'function';
}

// --- session-log container -------------------------------------------------

/** DSH_HOME (default ~/.dsh) — the dsh data root. */
function dshHomeDir(dshHome) {
  return dshHome || process.env.DSH_HOME || path.join(os.homedir(), '.dsh');
}

/** The dsh session-log root: `$DSH_HOME/sessions`. */
function sessionsDir(dshHome) {
  return path.join(dshHomeDir(dshHome), 'sessions');
}

/** The session-log artifact inside a session directory, or null. */
function sessionLogFile(sessionDir) {
  for (const name of SESSION_LOG_FILES) {
    const p = path.join(sessionDir, name);
    if (fs.existsSync(p)) return p;
  }
  return null;
}

/**
 * Locate structurally complete Zstandard frames without decompressing them.
 * Mirrors the dsh JSONL container: consecutive frames, each with a standard
 * frame header, blocks and optional checksum. A frame cut by a crash (or by a
 * still-open write) is reported as `tornStart` instead of throwing.
 *
 * @param {Buffer} buffer - bytes currently present in the artifact.
 * @param {number} [maxFrames] - stop after this many complete frames.
 * @returns {{frames: Array<{start: number, end: number}>, tornStart?: number}}
 */
function scanZstdFrames(buffer, maxFrames = Number.POSITIVE_INFINITY) {
  const frames = [];
  let offset = 0;
  while (offset < buffer.length) {
    const start = offset;
    if (buffer.length - offset < 4) return { frames, tornStart: start };
    if (buffer.readUInt32LE(offset) !== ZSTD_MAGIC) {
      throw new Error('corrupt Zstandard session log: invalid frame magic at byte ' + offset);
    }
    offset += 4;
    if (offset === buffer.length) return { frames, tornStart: start };
    const descriptor = buffer.readUInt8(offset);
    offset += 1;
    if ((descriptor & 24) !== 0) {
      throw new Error('corrupt Zstandard session log: reserved frame-header bit at byte ' + (offset - 1));
    }
    const contentSizeFlag = descriptor >>> 6;
    const singleSegment = (descriptor & 32) !== 0;
    const checksum = (descriptor & 4) !== 0;
    const dictionaryFlag = descriptor & 3;
    const dictionaryBytes = dictionaryFlag === 3 ? 4 : dictionaryFlag;
    const contentSizeBytes = contentSizeFlag === 0 ? (singleSegment ? 1 : 0) : 1 << contentSizeFlag;
    const remainingHeaderBytes = (singleSegment ? 0 : 1) + dictionaryBytes + contentSizeBytes;
    if (buffer.length - offset < remainingHeaderBytes) return { frames, tornStart: start };
    offset += remainingHeaderBytes;
    for (;;) {
      if (buffer.length - offset < 3) return { frames, tornStart: start };
      const blockHeader = buffer.readUIntLE(offset, 3);
      offset += 3;
      const lastBlock = (blockHeader & 1) !== 0;
      const blockType = (blockHeader >>> 1) & 3;
      const blockSize = blockHeader >>> 3;
      if (blockType === 3) {
        throw new Error('corrupt Zstandard session log: reserved block type at byte ' + (offset - 3));
      }
      const payloadBytes = blockType === 1 ? 1 : blockSize;
      if (buffer.length - offset < payloadBytes) return { frames, tornStart: start };
      offset += payloadBytes;
      if (lastBlock) break;
    }
    if (checksum) {
      if (buffer.length - offset < 4) return { frames, tornStart: start };
      offset += 4;
    }
    frames.push({ start, end: offset });
    if (frames.length === maxFrames) return { frames };
  }
  return { frames };
}

/**
 * Decode a session-log artifact into UTF-8 JSONL text.
 *
 * Plaintext artifacts pass through. Zstandard artifacts are decoded frame by
 * frame; a torn final frame is skipped (the audit then covers the durable part
 * and reports the loss through `diagnostics`).
 *
 * @param {string} file - artifact path.
 * @param {{maxFrames?: number, diagnostics?: Array<{code: string, message: string}>}} [options]
 * @returns {string} decoded JSONL text.
 */
function decodeSessionLog(file, options = {}) {
  const diagnostics = options.diagnostics || [];
  if (file.endsWith('.jsonl')) return fs.readFileSync(file, 'utf8');
  if (!zstdAvailable()) {
    diag(diagnostics, 'zstd-unsupported',
      '[review] 本机 node (' + process.version + ') 不支持 zstd 解码（需 v22.15+/v23.8+）；请用 App 内置运行时');
    return '';
  }
  const buffer = fs.readFileSync(file);
  const { frames, tornStart } = scanZstdFrames(buffer, options.maxFrames);
  if (tornStart !== undefined) {
    diag(diagnostics, 'zstd-torn-frame',
      '[review] 日志末尾存在未完成帧（byte ' + tornStart + '），已跳过该帧，审计覆盖已落盘部分');
  }
  const chunks = [];
  for (const frame of frames) {
    try {
      chunks.push(zlib.zstdDecompressSync(buffer.subarray(frame.start, frame.end)));
    } catch (error) {
      diag(diagnostics, 'zstd-frame-failed',
        '[review] 帧解码失败（byte ' + frame.start + '）：' + (error && error.message ? error.message : String(error)));
    }
  }
  return Buffer.concat(chunks).toString('utf8');
}

/** Parse JSONL text into events; malformed lines are counted, never thrown. */
function parseEvents(text, diagnostics = []) {
  const events = [];
  let malformed = 0;
  for (const line of text.split('\n')) {
    if (!line || !line.trim()) continue;
    try {
      events.push(JSON.parse(line));
    } catch {
      malformed += 1;
    }
  }
  if (malformed > 0) {
    diag(diagnostics, 'malformed-lines', '[review] 跳过 ' + malformed + ' 行无法解析的 JSONL');
  }
  return events;
}

/** The `session` header event of an event list, or null. */
function sessionHeader(events) {
  for (const event of events) {
    if (event && event.type === 'session') return event;
  }
  return null;
}

/**
 * List session logs, newest first, optionally restricted to one workspace.
 *
 * Only the first frame (the session header) is decoded, so discovery stays
 * cheap on large logs.
 *
 * @param {{dshHome?: string, workspace?: string, limit?: number}} [options]
 * @returns {Array<object>} session descriptors.
 */
function listSessionLogs(options = {}) {
  const dir = sessionsDir(options.dshHome);
  const limit = options.limit === undefined ? 40 : options.limit;
  const out = [];
  const diagnostics = [];
  let slugs;
  try {
    slugs = fs.readdirSync(dir, { withFileTypes: true }).filter((e) => e.isDirectory());
  } catch {
    return { sessions: [], diagnostics: [{ code: 'no-sessions-dir', message: '[review] 未找到会话目录: ' + dir }] };
  }
  for (const slug of slugs) {
    const slugDir = path.join(dir, slug.name);
    let ids;
    try {
      ids = fs.readdirSync(slugDir, { withFileTypes: true }).filter((e) => e.isDirectory());
    } catch {
      continue;
    }
    for (const id of ids) {
      const sessionDir = path.join(slugDir, id.name);
      const file = sessionLogFile(sessionDir);
      if (!file) continue;
      let header = null;
      try {
        const head = decodeSessionLog(file, { maxFrames: 1, diagnostics });
        header = sessionHeader(parseEvents(head));
      } catch (error) {
        diag(diagnostics, 'header-read-failed',
          '[review] 读取会话头失败 ' + file + '：' + (error && error.message ? error.message : String(error)));
      }
      if (options.workspace && (!header || header.cwd !== options.workspace)) continue;
      let stat = null;
      try { stat = fs.statSync(file); } catch { /* keep null */ }
      out.push({
        id: (header && header.id) || id.name,
        dir: sessionDir,
        file,
        cwd: (header && header.cwd) || null,
        createdAt: (header && header.createdAt) || null,
        parentSession: (header && header.parentSession) || null,
        delegationDepth: header && header.delegationDepth !== undefined ? header.delegationDepth : 0,
        compressed: file.endsWith('.zstd'),
        sizeBytes: stat ? stat.size : 0,
        mtimeMs: stat ? stat.mtimeMs : 0,
      });
    }
  }
  out.sort((a, b) => b.mtimeMs - a.mtimeMs);
  return { sessions: limit >= 0 ? out.slice(0, limit) : out, total: out.length, diagnostics };
}

// --- audit folding ---------------------------------------------------------

/** Parse a tool-call argument payload (dsh stores it as a JSON string). */
function parseArgs(raw) {
  if (raw && typeof raw === 'object') return raw;
  if (typeof raw !== 'string' || !raw.trim()) return {};
  try {
    const value = JSON.parse(raw);
    return value && typeof value === 'object' ? value : {};
  } catch {
    return {};
  }
}

/** Turn an absolute path into a workspace-relative one when it is inside. */
function relativize(filePath, workspace) {
  if (!filePath) return filePath;
  if (!workspace) return filePath;
  const root = workspace.endsWith(path.sep) ? workspace : workspace + path.sep;
  return filePath.startsWith(root) ? filePath.slice(root.length) : filePath;
}

/** Count the lines a hunk side carries (0 for a pure insertion/deletion). */
function sideLines(text) {
  if (typeof text !== 'string' || text === '') return 0;
  return text.split('\n').length;
}

/** True when a shell command looks like it writes files. */
function bashLooksLikeWrite(command) {
  if (typeof command !== 'string' || !command) return false;
  return BASH_WRITE_HINTS.some((re) => re.test(command));
}

/** Audit-facing category for a mutation kind ('diff' is assigned later when hunks arrive). */
function categoryFor(kind) {
  if (kind === 'edit' || kind === 'insert') return 'args';
  return 'content';
}

/** Build the change entry for one mutation call, or null when it is a read. */
function mutationEntry(tool, args) {
  if (tool === 'write') {
    if (typeof args.file_path !== 'string') return null;
    const content = typeof args.content === 'string' ? args.content : '';
    return { pathAbs: args.file_path, hunks: [], pendingContent: content, kind: 'write' };
  }
  if (tool === 'edit') {
    if (typeof args.file_path !== 'string') return null;
    const oldText = typeof args.old_string === 'string' ? args.old_string : '';
    const newText = typeof args.new_string === 'string' ? args.new_string : '';
    return { pathAbs: args.file_path, hunks: [{ oldText, newText }], kind: 'edit' };
  }
  if (tool === 'str_replace_editor') {
    const command = args.command;
    if (command !== 'create' && command !== 'str_replace' && command !== 'insert') return null;
    if (typeof args.path !== 'string') return null;
    if (command === 'create') {
      return { pathAbs: args.path, hunks: [{ oldText: null, newText: typeof args.file_text === 'string' ? args.file_text : '' }], kind: 'create' };
    }
    if (command === 'str_replace') {
      return {
        pathAbs: args.path,
        hunks: [{
          oldText: typeof args.old_str === 'string' ? args.old_str : '',
          newText: typeof args.new_str === 'string' ? args.new_str : '',
        }],
        kind: 'edit',
      };
    }
    return {
      pathAbs: args.path,
      hunks: [{ oldText: null, newText: typeof args.new_str === 'string' ? args.new_str : '' }],
      kind: 'insert',
    };
  }
  return null;
}

/**
 * Fold session events into a read-only audit model.
 *
 * @param {Array<object>} events - parsed session-log events.
 * @param {{workspace?: string}} [options]
 * @returns {{session: object|null, entries: Array<object>, stats: object, diagnostics: Array<object>}}
 */
function buildAudit(events, options = {}) {
  const workspace = options.workspace || null;
  const diagnostics = [];
  const header = sessionHeader(events);
  const pending = new Map();
  const entries = [];
  let order = 0;
  // Turn context: top-level calls carry turn/step; a nested `run_code` dispatch
  // inherits its parent call's turn so the panel can group by 对话 (turn).
  const contextByCallId = new Map();
  const turns = new Map();
  let currentTurn = null;
  let currentPrompt = null;

  const addEntry = (entry) => {
    entries.push(entry);
    return entry;
  };

  for (const event of events) {
    if (!event || typeof event !== 'object') continue;
    const data = event.data || {};
    if (event.type === 'turn/start') {
      currentTurn = data.turn === undefined ? null : data.turn;
      currentPrompt = null;
      if (currentTurn !== null && !turns.has(currentTurn)) {
        turns.set(currentTurn, { turn: currentTurn, prompt: null, startedAt: event.time || null });
      }
      continue;
    }
    if (event.type === 'user/message') {
      const source = data.source || {};
      const parts = Array.isArray(data.content) ? data.content : [];
      const text = parts.filter((p) => p && p.type === 'text' && typeof p.text === 'string')
        .map((p) => p.text).join(' ').trim();
      if (source.kind === 'user' && text && currentTurn !== null) {
        currentPrompt = currentPrompt || text;
        const record = turns.get(currentTurn) || { turn: currentTurn, prompt: null, startedAt: event.time || null };
        if (!record.prompt) record.prompt = text;
        turns.set(currentTurn, record);
      }
      continue;
    }
    if (event.type === 'tool/call') {
      const event0 = data;
      const entry = addEntry({
        seq: event.seq,
        turn: event0.turn === undefined ? null : event0.turn,
        step: event0.step === undefined ? null : event0.step,
        order: order++,
        tool: event0.name,
        surface: 'top',
        callId: event0.callId === undefined ? null : event0.callId,
        subCallId: null,
        rootCallId: event0.callId === undefined ? null : event0.callId,
        status: 'unknown',
        category: null,
        pathAbs: null,
        path: null,
        command: null,
        suspicion: null,
        hunks: [],
        added: 0,
        removed: 0,
        note: null,
      });
      contextByCallId.set(String(entry.callId), { turn: entry.turn, step: entry.step });
      const args = parseArgs(event0.arguments);
      if (MUTATION_TOOLS.has(event0.name)) {
        const m = mutationEntry(event0.name, args);
        if (m) {
          entry.pathAbs = m.pathAbs;
          entry.path = relativize(m.pathAbs, workspace);
          entry.hunks = m.hunks;
          entry.category = categoryFor(m.kind);
          entry.note = 'args';
          if (m.pendingContent !== undefined) entry.pendingContent = m.pendingContent;
        } else {
          entry.note = 'unparsed-args';
        }
        pending.set(String(entry.callId), entry);
      } else if (SHELL_TOOLS.has(event0.name)) {
        entry.category = 'bash';
        entry.command = typeof args.command === 'string' ? args.command : JSON.stringify(args).slice(0, 400);
        entry.suspicion = bashLooksLikeWrite(entry.command) ? 'write-like' : 'unknown';
        pending.set(String(entry.callId), entry);
      }
      continue;
    }
    if (event.type === 'tool/code-dispatch-start') {
      const inherited = contextByCallId.get(String(data.parentCallId))
        || contextByCallId.get(String(data.rootCallId))
        || { turn: null, step: null };
      const entry = addEntry({
        seq: event.seq,
        turn: inherited.turn,
        step: inherited.step,
        order: order++,
        tool: data.name,
        surface: 'nested',
        callId: null,
        subCallId: data.subCallId === undefined ? null : data.subCallId,
        rootCallId: data.rootCallId === undefined ? null : data.rootCallId,
        status: 'unknown',
        category: null,
        pathAbs: null,
        path: null,
        command: null,
        suspicion: null,
        hunks: [],
        added: 0,
        removed: 0,
        note: 'nested',
      });
      const args = parseArgs(data.arguments);
      if (MUTATION_TOOLS.has(data.name)) {
        const m = mutationEntry(data.name, args);
        if (m) {
          entry.pathAbs = m.pathAbs;
          entry.path = relativize(m.pathAbs, workspace);
          entry.hunks = m.hunks;
          entry.category = categoryFor(m.kind);
          entry.note = m.kind === 'write' ? 'nested-content' : 'nested-args';
          if (m.pendingContent !== undefined) entry.pendingContent = m.pendingContent;
        } else {
          entry.note = 'unparsed-args';
        }
        pending.set(String(entry.subCallId), entry);
      } else if (SHELL_TOOLS.has(data.name)) {
        entry.category = 'bash';
        entry.command = typeof args.command === 'string' ? args.command : JSON.stringify(args).slice(0, 400);
        entry.suspicion = bashLooksLikeWrite(entry.command) ? 'write-like' : 'unknown';
        pending.set(String(entry.subCallId), entry);
      }
      continue;
    }
    if (event.type === 'tool/code-dispatch') {
      const entry = pending.get(String(data.subCallId));
      if (entry) {
        entry.status = data.isError ? 'error' : 'ok';
        if (entry.status === 'error') {
          entry.hunks = [];
          entry.pendingContent = undefined;
        } else if (entry.pendingContent !== undefined) {
          // A nested 'write' only ever records the written content — the old
          // side is not in the log, so the hunk is a pure insertion.
          entry.hunks = [{ oldText: null, newText: entry.pendingContent }];
          entry.pendingContent = undefined;
        }
      }
      continue;
    }
    if (event.type === 'tool/result') {
      const callId = data.message && data.message.source ? data.message.source.callId : undefined;
      const entry = callId === undefined ? undefined : pending.get(String(callId));
      const part = data.message && Array.isArray(data.message.content)
        ? data.message.content.find((c) => c && c.type === 'tool-result')
        : null;
      const isError = part ? part.isError === true : false;
      if (!entry) continue;
      entry.status = isError ? 'error' : 'ok';
      const diffs = data.meta && Array.isArray(data.meta.diffs) ? data.meta.diffs : null;
      if (isError) {
        entry.hunks = [];
        entry.pendingContent = undefined;
      } else if (diffs && diffs.length > 0) {
        entry.hunks = diffs.map((d) => ({ oldText: d.oldText === undefined ? null : d.oldText, newText: d.newText }));
        entry.category = 'diff';
        entry.note = 'applied-hunks';
      } else if (entry.pendingContent !== undefined) {
        // `diffs: []` is dsh's projection for "no applied hunks": for `write` that
        // means the file did not exist before, so the entry is a creation. An
        // update whose content is byte-identical reports the same empty list,
        // which is why the note says "created" rather than proving it.
        entry.hunks = [{ oldText: null, newText: entry.pendingContent }];
        entry.note = diffs && diffs.length === 0 ? 'created-content' : 'written-content';
      }
      entry.pendingContent = undefined;
      continue;
    }
  }

  for (const entry of entries) {
    delete entry.pendingContent;
    for (const hunk of entry.hunks) {
      entry.added += sideLines(hunk.newText);
      entry.removed += sideLines(hunk.oldText === null ? null : hunk.oldText);
    }
  }

  const mutations = entries.filter((e) => e.category === 'diff' || e.category === 'args' || e.category === 'content');
  const bashEntries = entries.filter((e) => e.category === 'bash');
  const files = new Set();
  for (const entry of mutations) {
    if (entry.status === 'ok' && entry.path) files.add(entry.path);
  }
  const stats = {
    entries: entries.length,
    mutations: mutations.length,
    files: files.size,
    added: mutations.reduce((a, e) => (e.status === 'ok' ? a + e.added : a), 0),
    removed: mutations.reduce((a, e) => (e.status === 'ok' ? a + e.removed : a), 0),
    nested: entries.filter((e) => e.surface === 'nested').length,
    bashCalls: bashEntries.length,
    bashSuspect: bashEntries.filter((e) => e.suspicion === 'write-like').length,
    failed: entries.filter((e) => e.status === 'error').length,
  };
  const session = header
    ? {
      id: header.id,
      cwd: header.cwd || null,
      createdAt: header.createdAt || null,
      parentSession: header.parentSession || null,
      delegationDepth: header.delegationDepth || 0,
    }
    : null;
  const turnList = Array.from(turns.values()).sort((a, b) => a.turn - b.turn);
  for (const record of turnList) {
    if (record.prompt && record.prompt.length > 200) record.prompt = record.prompt.slice(0, 200) + '…';
  }
  return { session, entries, turns: turnList, stats, diagnostics };
}

/**
 * Audit one session log file end to end.
 *
 * @param {{file: string, workspace?: string}} options
 * @returns {{session: object|null, entries: Array<object>, stats: object, diagnostics: Array<object>}}
 */
function auditSessionLog(options) {
  const diagnostics = [];
  if (!options || !options.file) {
    return { session: null, turns: [], entries: [], stats: null, diagnostics: [{ code: 'no-file', message: '[review] 缺少会话文件路径' }] };
  }
  const text = decodeSessionLog(options.file, { diagnostics });
  const events = parseEvents(text, diagnostics);
  const audit = buildAudit(events, { workspace: options.workspace });
  return {
    session: audit.session,
    turns: audit.turns,
    entries: audit.entries,
    stats: audit.stats,
    diagnostics: diagnostics.concat(audit.diagnostics),
  };
}

/**
 * Audit one session by id (searched across workspaces), newest match wins.
 *
 * @param {{sessionId: string, dshHome?: string, workspace?: string}} options
 */
function auditSession(options) {
  if (!options || !options.sessionId) {
    return { session: null, turns: [], entries: [], stats: null, diagnostics: [{ code: 'no-session-id', message: '[review] 缺少 sessionId' }] };
  }
  const listed = listSessionLogs({ dshHome: options.dshHome, workspace: options.workspace, limit: -1 });
  const match = listed.sessions.filter((s) => s.id === options.sessionId).sort((a, b) => b.mtimeMs - a.mtimeMs)[0]
    || listed.sessions.filter((s) => path.basename(s.dir) === options.sessionId).sort((a, b) => b.mtimeMs - a.mtimeMs)[0];
  if (!match) {
    return {
      session: null,
      turns: [],
      entries: [],
      stats: null,
      diagnostics: listed.diagnostics.concat([{ code: 'session-not-found', message: '[review] 未找到会话 ' + options.sessionId }]),
    };
  }
  return auditSessionLog({ file: match.file, workspace: options.workspace || match.cwd });
}

module.exports = {
  SESSION_LOG_FILES,
  dshHomeDir,
  sessionsDir,
  sessionLogFile,
  zstdAvailable,
  scanZstdFrames,
  decodeSessionLog,
  parseEvents,
  listSessionLogs,
  buildAudit,
  auditSessionLog,
  auditSession,
  relativize,
  bashLooksLikeWrite,
};
