'use strict';

/**
 * core/lib/channel-workspaces.js — workspace code assignment + #tag routing.
 *
 * Docs: docs/channel-ui-commands.md §3.9. Platform-independent Node module.
 *
 * Two layers:
 *   1. assignCodes(workspaces) — sort by path, assign w1/w2… codes (case-insensitive).
 *   2. resolveWorkspaceTag(text, { workspaces }) — find a target workspace from
 *      #w1 (code) or #<workspace name/path> in the message; returns
 *      { workspace, code, cleanText } where cleanText strips the tag.
 *
 * The /workspaces and /wks commands are wired in channel-commands.js; the
 * runner uses resolveWorkspaceTag to pick the projectRoot for session mapping.
 *
 *   const { assignCodes, resolveWorkspaceTag, parseTag } = require('@oh-my-dsh/core');
 */

/**
 * Shorten an absolute path to a ~-relative form for display, so it never
 * leaks the OS user's home directory (e.g. /Users/alice/a/b -> ~/a/b).
 * Returns the input unchanged when homeDir is unknown or the path isn't under
 * it. Pure & testable; pass the home dir explicitly.
 */
function toHomePath(p, homeDir) {
  if (typeof p !== 'string' || !p) return p || '';
  const h = typeof homeDir === 'string' && homeDir ? homeDir : '';
  if (!h) return p;
  if (p === h) return '~';
  if (p.startsWith(h + '/')) return '~' + p.slice(h.length);
  return p;
}

/**
 * Normalize a workspace entry to { id, path, name }.
 * The display name is the workspace.title (what dsh web shows); falls back to
 * the path basename so we never leak a full /Users/... path as a name.
 */
function normalizeWorkspace(w) {
  const path = w.path || '';
  let name = w.title || w.name || '';
  if (!name) {
    const base = path.split(/[\\/]/).filter(Boolean).pop() || path;
    name = base;
  }
  return { id: w.workspaceId || w.id || '', path, name };
}

/**
 * Sort workspaces by path and assign codes w1, w2, … (1-based).
 * Returns [{ id, path, name, code }] sorted by path.
 */
function assignCodes(workspaces) {
  return (workspaces || [])
    .map(normalizeWorkspace)
    .filter((w) => w.path || w.id)
    .sort((a, b) => a.path.localeCompare(b.path))
    .map((w, i) => ({ ...w, code: 'w' + (i + 1) }));
}

/**
 * Extract a candidate #tag from text. Returns the matched token (#w1 / #name)
 * and its trimmed inner value, or null. Handles both #w1 and #my-workspace
 * (letters, digits, - _ . and CJK). Stops at whitespace/punctuation.
 */
function parseTag(text) {
  if (typeof text !== 'string') return null;
  // Match # followed by a token (not starting with a number-only to avoid #1 confusion,
  // but w1 is fine). We allow letters/digits/-_/. and CJK.
  const m = text.match(/#([A-Za-z0-9_.\-\u4e00-\u9fa5]+)/);
  if (!m) return null;
  const raw = m[0];
  const value = m[1];
  return { raw, value: value.toLowerCase() };
}

/**
 * Resolve the target workspace for a message.
 *
 * opts:
 *   workspaces - array of { workspaceId|id, path, name } (all dsh workspaces)
 *   text       - the inbound message text
 *   lastCode   - (optional) the code of the most-recently-routed workspace
 *   preferFirst- (default true) fall back to the first workspace when no tag
 *                and no lastCode
 *
 * Returns:
 *   { workspace, code, cleanText, source: "tag"|"last"|"first"|"none" }
 *   cleanText is the message with the #tag stripped (for sending to the session).
 *   source "none" when no workspaces at all (caller replies "no workspace").
 */
function resolveWorkspaceTag(text, opts = {}) {
  const coded = assignCodes(opts.workspaces);
  const cleanText = String(text || '');
  const tag = parseTag(cleanText);

  if (tag) {
    // 1) exact code match (#w1)
    const byCode = coded.find((w) => w.code === tag.value);
    if (byCode) {
      return { workspace: byCode, code: byCode.code, cleanText: stripTag(cleanText, tag.raw), source: 'tag' };
    }
    // 2) name/path match (#workspace-name)
    const byName = coded.find((w) => {
      const n = (w.name || '').toLowerCase();
      const pathLow = (w.path || '').toLowerCase();
      return n.includes(tag.value) || pathLow.includes(tag.value);
    });
    if (byName) {
      return { workspace: byName, code: byName.code, cleanText: stripTag(cleanText, tag.raw), source: 'tag' };
    }
  }

  // 3) last used workspace (code)
  if (opts.lastCode) {
    const byLast = coded.find((w) => w.code === opts.lastCode.toLowerCase());
    if (byLast) return { workspace: byLast, code: byLast.code, cleanText, source: 'last' };
  }

  // 4) first workspace
  if (coded.length && opts.preferFirst !== false) {
    return { workspace: coded[0], code: coded[0].code, cleanText, source: 'first' };
  }

  return { workspace: null, code: null, cleanText, source: 'none' };
}

function stripTag(text, rawTag) {
  // remove the tag token (first occurrence), collapsing extra spaces
  const idx = text.indexOf(rawTag);
  if (idx < 0) return text;
  let out = text.slice(0, idx) + text.slice(idx + rawTag.length);
  return out.replace(/\s{2,}/g, ' ').trim();
}

module.exports = { assignCodes, parseTag, resolveWorkspaceTag, normalizeWorkspace, toHomePath };
