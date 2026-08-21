'use strict';

/**
 * core/lib/channel-store.js — channel credential/account persistence.
 *
 * Docs §4.1 credential decision (2026-08-21): FILE-FIRST, zero-prompt.
 * Token/account metadata for a channel lives at ~/.dsh/channels/<channelId>.json
 * (chmod 600), read first; Keychain is the fallback for legacy entries only.
 * Pure Node + fs — works identically on macOS/Windows/Linux.
 *
 *   const { loadChannelAccount, saveChannelAccount, channelAccountPath } = require('@oh-my-dsh/core');
 */

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

function channelsDir(dshHome) {
  return path.join(dshHome || process.env.DSH_HOME || path.join(os.homedir(), '.dsh'), 'channels');
}

/** The file path for a channel's persisted account/token. */
function channelAccountPath(channelId, dshHome) {
  return path.join(channelsDir(dshHome), channelId + '.json');
}

/**
 * Load a channel's saved account (token + accountId + userId + baseUrl).
 * Returns null when absent/unreadable. File-first, no prompts.
 */
function loadChannelAccount(channelId, dshHome) {
  if (!channelId) return null;
  const p = channelAccountPath(channelId, dshHome);
  try {
    if (!fs.existsSync(p)) return null;
    const raw = fs.readFileSync(p, 'utf8');
    const data = JSON.parse(raw);
    return {
      botToken: data.botToken || data.token || null,
      accountId: data.accountId || null,
      userId: data.userId || null,
      baseUrl: data.baseUrl || null,
    };
  } catch {
    return null;
  }
}

/**
 * Save a channel's account/token to disk (chmod 600). File-first + Keychain
 * is out of scope here (Node cannot write macOS Keychain without a shell
 * bridge); the file is the authoritative read source.
 */
function saveChannelAccount(channelId, account, dshHome) {
  if (!channelId) throw new Error('channel-store: channelId required');
  const dir = channelsDir(dshHome);
  fs.mkdirSync(dir, { recursive: true });
  const p = channelAccountPath(channelId, dshHome);
  const data = JSON.stringify({
    botToken: account.botToken || account.token || null,
    accountId: account.accountId || null,
    userId: account.userId || null,
    baseUrl: account.baseUrl || null,
    updatedAt: Date.now(),
  }, null, 2);
  fs.writeFileSync(p, data, { mode: 0o600 });
  try { fs.chmodSync(p, 0o600); } catch { /* best effort */ }
  return p;
}

/** Remove a channel's saved account file. */
function clearChannelAccount(channelId, dshHome) {
  const p = channelAccountPath(channelId, dshHome);
  try { if (fs.existsSync(p)) fs.unlinkSync(p); return true; } catch { return false; }
}

module.exports = { channelsDir, channelAccountPath, loadChannelAccount, saveChannelAccount, clearChannelAccount };
