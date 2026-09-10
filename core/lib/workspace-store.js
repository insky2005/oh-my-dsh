'use strict';

/**
 * core/lib/workspace-store.js — the dsh workspace list (live RPC + persisted store).
 *
 * dsh <= 0.1.1 serves `workspace.list` over the HTTP RPC. dsh >= 0.1.2 dropped it
 * (the web client follows a `workspace/follow` stream instead), but the same
 * workspaces are persisted to $DSH_HOME/storages/workspace.json — the file the
 * shell already reads — so that store is the fallback.
 *
 * ⚠️ That file is NOT an API contract (see docs/dsh-version-impact.md §6.2):
 * dsh owns it as a private, schema-validated domain store
 * (defineDomain({ name: 'workspace', version: 2, global: {…}, tables: { workspaces } }))
 * and may rename fields, move the file or bump the version without notice —
 * silently breaking every consumer. So the reader validates the domain
 * name/version and REPORTS what it found instead of quietly returning [].
 *
 *   const { listWorkspaces } = require('@oh-my-dsh/core');
 *   const ws = await listWorkspaces(3080, { dshHome, token, log });
 *
 * Docs: docs/plans/dsh-012rc1-compat-audit.md (C1).
 */

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { callRpc, WORKSPACE_LIST } = require('./dsh-rpc');

/** The domain this reader understands (dsh-workspace/lib/invariant.js). */
const SUPPORTED_DOMAIN = { name: 'workspace', version: 2 };

/** dsh data home (env DSH_HOME or ~/.dsh). */
function dshHomePath(dshHome) {
  const h = dshHome || process.env.DSH_HOME;
  return h && String(h).trim() ? String(h).trim() : path.join(os.homedir(), '.dsh');
}

/** Human-readable line for a non-ok read, or null when nothing is wrong. */
function describeStore(store) {
  switch (store.reason) {
    case 'ok':
    case 'missing':
      return null;
    case 'unreadable':
      return 'persisted workspace store ' + store.file + ' is unreadable (parse/lock failure?)';
    case 'unexpected':
      return 'persisted workspace store ' + store.file + ' has an unexpected shape (no tables.workspaces)';
    case 'version':
      return 'persisted workspace store ' + store.file + ' is domain ' + store.name + ' v' + store.version
        + ', this build understands v' + SUPPORTED_DOMAIN.version
        + (store.items.length ? ' — read best-effort' : ' — cannot read it');
    default:
      return 'persisted workspace store ' + store.file + ' could not be read (' + store.reason + ')';
  }
}

/**
 * Read $DSH_HOME/storages/workspace.json → { items, reason, version? } in dsh web's
 * own order (global.workspaceIds). Each item mirrors the old workspace.list shape:
 * { workspaceId, path, title, sessionIds, createdAt, updatedAt }.
 *
 * Never throws. `reason` is one of: ok | missing | unreadable | unexpected | version.
 * A version bump still parses best-effort (the shape may be compatible) — callers
 * should surface `describeStore()` so the fallback failing is not silent.
 */
function readWorkspaceStore(dshHome) {
  const file = path.join(dshHomePath(dshHome), 'storages', 'workspace.json');
  let text = null;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (e) {
    return { items: [], reason: e && e.code === 'ENOENT' ? 'missing' : 'unreadable', file };
  }
  let json = null;
  try { json = JSON.parse(text); } catch { return { items: [], reason: 'unreadable', file }; }

  const unit = json && json.unit;
  const name = unit && unit.name;
  const version = unit && unit.version;
  const tables = json && json.tables && json.tables.workspaces;
  if (!tables || typeof tables !== 'object') {
    return { items: [], reason: 'unexpected', file, name, version };
  }
  const order = json.global && Array.isArray(json.global.workspaceIds) ? json.global.workspaceIds : [];
  const ids = order.filter((id) => tables[id])
    .concat(Object.keys(tables).filter((id) => !order.includes(id)));
  const items = [];
  for (const id of ids) {
    const w = tables[id];
    if (!w || typeof w !== 'object' || typeof w.path !== 'string' || !w.path) continue;
    items.push({
      workspaceId: id,
      path: w.path,
      title: typeof w.title === 'string' ? w.title : '',
      sessionIds: Array.isArray(w.sessionIds) ? w.sessionIds : [],
      createdAt: w.createdAt,
      updatedAt: w.updatedAt,
    });
  }
  if (name !== SUPPORTED_DOMAIN.name) return { items, reason: 'unexpected', file, name, version };
  if (version !== SUPPORTED_DOMAIN.version) return { items, reason: 'version', file, name, version };
  return { items, reason: 'ok', file, version };
}

/**
 * The workspaces of the running dsh web: the live RPC when that server still
 * serves it (dsh <= 0.1.1), otherwise the persisted store (dsh >= 0.1.2).
 * Returns [] when neither is available.
 *
 * opts.log — optional sink for a broken/unrecognised store (the persisted layout
 * is private; failing silently is how this fallback rots unnoticed).
 */
async function listWorkspaces(port, opts = {}) {
  const json = await callRpc(WORKSPACE_LIST, {}, { port, host: opts.host, timeoutMs: opts.timeoutMs, token: opts.token });
  const v = json && json.result && json.result.ok === true ? json.result.value : null;
  if (v && Array.isArray(v.items)) return v.items;
  const store = readWorkspaceStore(opts.dshHome);
  const note = describeStore(store);
  if (note && typeof opts.log === 'function') opts.log('[workspace-store] ' + note);
  return store.items;
}

module.exports = { listWorkspaces, readWorkspaceStore, describeStore, dshHomePath, SUPPORTED_DOMAIN };
