'use strict';

/**
 * core/lib/workspace-store.js — the dsh workspace list (live RPC + persisted store).
 *
 * dsh <= 0.1.1 serves `workspace.list` over the HTTP RPC. dsh >= 0.1.2 dropped it
 * (the web client follows a `workspace/follow` stream instead), but the same
 * workspaces are persisted to $DSH_HOME/storages/workspace.json — the file the
 * shell already reads — so that store is the fallback.
 *
 *   const { listWorkspaces } = require('@oh-my-dsh/core');
 *   const ws = await listWorkspaces(3080, { dshHome, token });
 *
 * Docs: docs/plans/dsh-012rc1-compat-audit.md (C1).
 */

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { callRpc, WORKSPACE_LIST } = require('./dsh-rpc');

/** dsh data home (env DSH_HOME or ~/.dsh). */
function dshHomePath(dshHome) {
  const h = dshHome || process.env.DSH_HOME;
  return h && String(h).trim() ? String(h).trim() : path.join(os.homedir(), '.dsh');
}

/**
 * Read $DSH_HOME/storages/workspace.json → { items } in dsh web's own order
 * (global.workspaceIds). Each item mirrors the old workspace.list shape:
 * { workspaceId, path, title, sessionIds, createdAt, updatedAt }.
 * Never throws — a missing/unreadable store is simply "no workspaces".
 */
function readWorkspaceStore(dshHome) {
  const file = path.join(dshHomePath(dshHome), 'storages', 'workspace.json');
  let json = null;
  try { json = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return { items: [] }; }
  const tables = json && json.tables && json.tables.workspaces;
  if (!tables || typeof tables !== 'object') return { items: [] };
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
  return { items };
}

/**
 * The workspaces of the running dsh web: the live RPC when that server still
 * serves it (dsh <= 0.1.1), otherwise the persisted store (dsh >= 0.1.2).
 * Returns [] when neither is available.
 */
async function listWorkspaces(port, opts = {}) {
  const json = await callRpc(WORKSPACE_LIST, {}, { port, host: opts.host, timeoutMs: opts.timeoutMs, token: opts.token });
  const v = json && json.result && json.result.ok === true ? json.result.value : null;
  if (v && Array.isArray(v.items)) return v.items;
  return readWorkspaceStore(opts.dshHome).items;
}

module.exports = { listWorkspaces, readWorkspaceStore, dshHomePath };
