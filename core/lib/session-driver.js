'use strict';

/**
 * core/lib/session-driver.js — dsh session driver for remote channel messages.
 *
 * Mirrors the IssueRunner RPC envelope (platforms/macos/src/IssueRunnerPanel.swift):
 * HTTP POST to /api/<method> with a `client-request` body, then parse
 * result.value. Platform-independent — any shell (macOS/Windows/Linux) can
 * drive a dsh session from an inbound ChannelEvent.
 *
 * The driver's `run()` maps an event+projectRef to: create session (workspace
 * or cwd) -> rename -> prompt (mode queue) -> poll running -> fetch last
 * assistant message -> return a ChannelReply.
 */

const http = require('node:http');
const crypto = require('node:crypto');

function rpc(port, method, payload = {}, host = '127.0.0.1', timeoutMs = 8000) {
  const rpcId = crypto.randomUUID();
  const body = JSON.stringify({ type: 'client-request', rpcId, method, payload });
  return new Promise((resolve) => {
    const req = http.request(
      { host, port, path: `/api/${method}`, method: 'POST', timeout: timeoutMs,
        headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) } },
      (res) => {
        let data = '';
        res.setEncoding('utf8');
        res.on('data', (c) => { data += c; });
        res.on('end', () => {
          try {
            const json = JSON.parse(data);
            if (json.rpcId !== rpcId) return resolve(null);
            resolve(json);
          } catch { resolve(null); }
        });
      }
    );
    req.on('timeout', () => { req.destroy(); resolve(null); });
    req.on('error', () => resolve(null));
    req.end(body);
  });
}

/** ok() pulls result.ok boolean. */
function ok(json) { return !!(json && json.result && json.result.ok === true); }
/** value() pulls result.value (any). */
function value(json) { return json && json.result && json.result.ok === true ? json.result.value : null; }

async function createSession(port, { workspaceId, cwd }, host, timeoutMs) {
  const payload = workspaceId ? { workspaceId } : cwd ? { cwd } : {};
  if (!payload.workspaceId && !payload.cwd) return null;
  const json = await rpc(port, 'session.create', payload, host, timeoutMs);
  const v = value(json);
  return v && typeof v.sessionId === 'string' ? v.sessionId : null;
}

async function renameSession(port, sessionId, title, host, timeoutMs) {
  const json = await rpc(port, 'session.rename', { sessionId, title }, host, timeoutMs);
  return ok(json);
}

async function promptSession(port, sessionId, text, host, timeoutMs) {
  const payload = { sessionId, mode: 'queue', content: [{ type: 'text', text }] };
  const json = await rpc(port, 'session.prompt', payload, host, timeoutMs);
  return ok(json);
}

async function cancelSession(port, sessionId, host, timeoutMs) {
  const json = await rpc(port, 'session.cancel', { sessionId }, host, timeoutMs);
  return ok(json);
}

/** True while the session is running (poll session.list for the id). */
async function sessionRunning(port, sessionId, host, timeoutMs) {
  const json = await rpc(port, 'session.list', {}, host, timeoutMs);
  const v = value(json);
  if (!v || !Array.isArray(v.items)) return false;
  const hit = v.items.find((s) => s.sessionId === sessionId);
  return !!(hit && hit.running === true);
}

/**
 * Fetch the last assistant message text for a session via session.search
 * (fallback: session.history). Both return a list of messages; we take the
 * last message whose role is assistant/user with a text payload.
 */
async function lastMessage(port, sessionId, host, timeoutMs) {
  for (const method of ['session.search', 'session.history']) {
    const payload = method === 'session.search' ? { query: '', sessionId } : { sessionId };
    const json = await rpc(port, method, payload, host, timeoutMs);
    const v = value(json);
    const msgs = extractMessages(v);
    if (msgs.length) {
      const m = msgs[msgs.length - 1];
      const text = extractText(m);
      if (text) return text;
    }
  }
  return null;
}

function extractMessages(v) {
  if (!v) return [];
  if (Array.isArray(v)) return v;
  if (Array.isArray(v.items)) return v.items;
  if (Array.isArray(v.messages)) return v.messages;
  if (Array.isArray(v.results)) return v.results;
  return [];
}

function extractText(m) {
  if (!m || typeof m !== 'object') return '';
  if (typeof m.text === 'string' && m.text) return m.text;
  if (typeof m.content === 'string' && m.content) return m.content;
  if (Array.isArray(m.content)) {
    const parts = m.content
      .filter((p) => p && typeof p === 'object' && typeof p.text === 'string')
      .map((p) => p.text);
    if (parts.length) return parts.join('\n');
  }
  return '';
}

/**
 * Build the full session driver used by createChannelManager. `run` returns a
 * ChannelReply: create -> prompt -> poll -> lastMessage. Optionally inject a
 * poll interval + max polls for testability.
 */
function createSessionDriver(opts = {}) {
  const port = opts.port || 3080;
  const host = opts.host || '127.0.0.1';
  const timeoutMs = opts.timeoutMs || 8000;
  const pollIntervalMs = opts.pollIntervalMs || 1000;
  const maxPolls = opts.maxPolls || 900; // ~15min at 1s

  async function run(event, ref) {
    const title = `remote(${event.platform}): ${(event.text || '').slice(0, 40) || event.conversationId}`;
    const sid = await createSession(port, { workspaceId: ref.workspaceId, cwd: ref.workspaceRoot }, host, timeoutMs);
    if (!sid) throw new Error('session-driver: session.create failed');
    await renameSession(port, sid, title, host, timeoutMs);
    const text = event.media && event.media.filePath
      ? `${event.text ? event.text + '\n' : ''}[附件: ${event.media.fileName || event.media.filePath}]`
      : event.text || '';
    const prompted = await promptSession(port, sid, text, host, timeoutMs);
    if (!prompted) { await cancelSession(port, sid, host, timeoutMs); throw new Error('session-driver: session.prompt failed'); }
    let polls = 0;
    while (await sessionRunning(port, sid, host, timeoutMs)) {
      if (++polls >= maxPolls) { await cancelSession(port, sid, host, timeoutMs); throw new Error('session-driver: timeout waiting for session'); }
      await sleep(pollIntervalMs);
    }
    const replyText = (await lastMessage(port, sid, host, timeoutMs)) || '(会话未产生可读取的回复文本)';
    return { text: replyText, media: null };
  }

  return { run, createSession, renameSession, promptSession, cancelSession, sessionRunning, lastMessage, rpc };
}

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

module.exports = { createSessionDriver, rpc, createSession, renameSession, promptSession, cancelSession, sessionRunning, lastMessage };
