'use strict';

/**
 * core/lib/channel-sessions.js — per-channel session mapping + message log.
 *
 * Docs: docs/channel-ui-commands.md §3.4/§3.8 (decision E).
 *
 * Persisted under the PROJECT .dsh directory so it travels with the repo
 * (but message content is NOT committed — see .gitignore):
 *   <projectRoot>/.dsh/channels/<channelId>.sessions.json
 *   <projectRoot>/.dsh/channels/<channelId>.messages.json
 *
 * Sessions: map a (channelId, conversationId) to the active dsh session id,
 * so multi-turn chats keep one session until /new or /switch.
 * Messages: append-only log of in/out messages, grouped by Channel/Session.
 *
 *   const { createChannelSessions } = require('@oh-my-dsh/core');
 */

const fs = require('node:fs');
const path = require('node:path');

/** Max messages kept per channel file (decision E). */
const MAX_MESSAGES = 1000;

function sessionsFilePath(projectRoot, channelId) {
  return path.join(projectRoot, '.dsh', 'channels', channelId + '.sessions.json');
}
function messagesFilePath(projectRoot, channelId) {
  return path.join(projectRoot, '.dsh', 'channels', channelId + '.messages.json');
}

function readJson(file, fallback) {
  try {
    if (!fs.existsSync(file)) return fallback;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

/**
 * Create a session store bound to one (projectRoot, channelId).
 */
function createChannelSessions({ projectRoot, channelId }) {
  const sessionsFile = sessionsFilePath(projectRoot, channelId);
  const messagesFile = messagesFilePath(projectRoot, channelId);

  function ensureDir() {
    fs.mkdirSync(path.dirname(sessionsFile), { recursive: true });
  }

  // ----- sessions -----
  function loadSessions() {
    const data = readJson(sessionsFile, { version: 1, sessions: [] });
    return Array.isArray(data.sessions) ? data.sessions : [];
  }
  function saveSessions(sessions) {
    ensureDir();
    fs.writeFileSync(sessionsFile, JSON.stringify({ version: 1, sessions }, null, 2), 'utf8');
  }

  /** Get the active session record for a conversation (or null). */
  function getSession(conversationId) {
    return loadSessions().find((s) => s.conversationId === conversationId) || null;
  }

  /** Set (upsert) the session record for a conversation. */
  function setSession(conversationId, rec) {
    const sessions = loadSessions();
    const idx = sessions.findIndex((s) => s.conversationId === conversationId);
    const entry = { conversationId, sessionId: rec.sessionId, projectRoot: rec.projectRoot || projectRoot, name: rec.name || null, createdAt: rec.createdAt || Date.now(), updatedAt: Date.now() };
    if (idx >= 0) sessions[idx] = entry; else sessions.push(entry);
    saveSessions(sessions);
    return entry;
  }

  /** List all sessions (ordered by updatedAt desc). */
  function listSessions() {
    return loadSessions().sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0));
  }

  // ----- messages (decision E: persisted to project .dsh) -----
  function loadMessages() {
    const data = readJson(messagesFile, { version: 1, messages: [] });
    return Array.isArray(data.messages) ? data.messages : [];
  }
  function saveMessages(messages) {
    ensureDir();
    fs.writeFileSync(messagesFile, JSON.stringify({ version: 1, messages }, null, 2), 'utf8');
  }

  /**
   * Append a message record. dir = "in" (received) | "out" (reply).
   * Rolls to the most recent MAX_MESSAGES.
   */
  function appendMessage({ conversationId, sessionId, dir, text, ts }) {
    const messages = loadMessages();
    messages.push({ channelId, conversationId, sessionId: sessionId || null, dir, text: String(text || ''), ts: ts || Date.now() });
    if (messages.length > MAX_MESSAGES) messages.splice(0, messages.length - MAX_MESSAGES);
    saveMessages(messages);
  }

  /** List messages for a conversation (oldest first). */
  function listMessages(conversationId, limit) {
    const msgs = loadMessages().filter((m) => m.conversationId === conversationId);
    return limit ? msgs.slice(-limit) : msgs;
  }

  return {
    sessionsFile, messagesFile,
    getSession, setSession, listSessions,
    appendMessage, listMessages, loadMessages,
  };
}

module.exports = { createChannelSessions, sessionsFilePath, messagesFilePath, MAX_MESSAGES };
