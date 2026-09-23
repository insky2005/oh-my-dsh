'use strict';

/**
 * core/lib/snapshot.js — session snapshot & rollback planning (PURE, no I/O).
 *
 * dsh persists session logs by **Session format generation** (generation 0 =
 * `session.jsonl`, later generations = `session.v3.jsonl`, plus `.zstd`), and
 * upgrading dsh MIGRATES existing sessions — irreversibly (upstream has no
 * downgrade chain). The shell therefore keeps, before any (app, dsh) combo
 * change, a snapshot of `sessions/ + storages/` and a per-dsh-version copy of
 * the `runtime/dsh` tree, so a user can roll back to the previous combo.
 *
 * This module holds ONLY the decisions: which snapshot to take, what to keep,
 * which files a rollback must restore / delete / quarantine, and the rollback
 * transaction state machine. Filesystem work (clonefile, rename, npm) lives in
 * the callers, so every rule here is testable headless.
 *
 *   const s = require('@oh-my-dsh/core').snapshot;
 *   s.decideLaunch({ state, currentCombo })   // -> take a snapshot?
 *   s.planRollback({ ... })                   // -> restore/quarantine/swap plan
 *
 * Design: docs/session-snapshot-rollback-design.md
 */

const { compareSemver } = require('./upgrade');

/** Snapshot reasons (also the trailing component of a snapshot id). */
const REASONS = ['bootstrap', 'combo-change', 'dsh-upgrade', 'pre-rollback'];

/** $DSH_HOME entries a data snapshot must NEVER copy (see design doc §3). */
const SNAPSHOT_EXCLUDES = [
  'shell',            // our own state — includes dsh-web.json with the launch token
  'credentials',
  'credentials.yaml',
  '.credentials.yaml',
  'profiles',
  'settings.yaml',
  'channels',         // channel bindings / message state (rolling back would drop them)
  'browser',
  'browser-dev',
  'skills',           // no generation coupling
  'attachments',
  'tokens',
  'scaffold-stages',
];

/** $DSH_HOME entries a data snapshot DOES copy. */
const SNAPSHOT_INCLUDES = ['sessions', 'storages'];

const ID_RE = /^(\d{8}-\d{6})_app(.*)_dsh(.*)_([a-z-]+)$/;

/** Rollback transaction steps, in order. */
const JOURNAL_STEPS = ['stop-server', 'snapshot-live', 'restore-data', 'quarantine', 'swap-tree', 'write-state'];

// --- combos ----------------------------------------------------------------

/** Normalise an (app, dsh) pair. */
function comboOf(appVersion, dshVersion) {
  return { app: String(appVersion || ''), dsh: String(dshVersion || '') };
}

/** True when two combos describe the same (app, dsh) pair. */
function sameCombo(a, b) {
  if (!a || !b) return false;
  return String(a.app) === String(b.app) && String(a.dsh) === String(b.dsh);
}

/** Human label, e.g. `oh-my-dsh 1.16.2 / dsh 0.1.2-rc.1`. */
function comboLabel(combo) {
  if (!combo) return '(unknown)';
  return 'oh-my-dsh ' + (combo.app || '?') + ' / dsh ' + (combo.dsh || '?');
}

/** UTC `YYYYMMDD-HHMMSS` from a Date | ISO string | epoch ms. */
function timestampOf(at) {
  const d = at instanceof Date ? at : new Date(at === undefined ? Date.now() : at);
  if (Number.isNaN(d.getTime())) throw new Error('snapshot: invalid timestamp ' + String(at));
  const p = (n, w) => String(n).padStart(w || 2, '0');
  return String(d.getUTCFullYear()) + p(d.getUTCMonth() + 1) + p(d.getUTCDate())
    + '-' + p(d.getUTCHours()) + p(d.getUTCMinutes()) + p(d.getUTCSeconds());
}

/**
 * Snapshot directory id: `<YYYYMMDD-HHMMSS>_app<app>_dsh<dsh>_<reason>`.
 * `_` separates the fields because versions themselves contain `.` and `-`.
 */
function snapshotId({ at, app, dsh, reason }) {
  if (REASONS.indexOf(reason) === -1) throw new Error('snapshot: unknown reason ' + String(reason));
  return timestampOf(at) + '_app' + String(app || '?') + '_dsh' + String(dsh || '?') + '_' + reason;
}

/** Parse a snapshot directory id back into its parts, or null when malformed. */
function parseSnapshotId(id) {
  if (typeof id !== 'string') return null;
  const m = ID_RE.exec(id);
  if (!m) return null;
  if (REASONS.indexOf(m[4]) === -1) return null;
  return { timestamp: m[1], app: m[2], dsh: m[3], reason: m[4] };
}

// --- launch decision -------------------------------------------------------

/**
 * Decide what the shell must do BEFORE spawning dsh web.
 *
 * The snapshot must happen before dsh ever runs: dsh writes on *open*
 * (a `session/end-seed` append), so a session can migrate the moment the new
 * dsh touches it.
 *
 * @returns {{action: 'snapshot'|'none', reason: string|null, fromCombo: object|null}}
 */
function decideLaunch({ state, currentCombo }) {
  if (!state || !state.dataCombo) {
    return { action: 'snapshot', reason: 'bootstrap', fromCombo: currentCombo || null };
  }
  if (sameCombo(state.dataCombo, currentCombo)) {
    return { action: 'none', reason: null, fromCombo: null };
  }
  return { action: 'snapshot', reason: 'combo-change', fromCombo: state.dataCombo };
}

/**
 * Meta for one data snapshot. `dshTree` is set ONLY when the dsh version changes
 * between the data and the version about to run — an app-only change needs no tree.
 */
function buildMeta({ id, at, reason, fromCombo, forCombo, counts, logicalBytes, restoredFrom }) {
  return {
    id,
    createdAt: at instanceof Date ? at.toISOString() : String(at || ''),
    reason,
    fromCombo: comboOf(fromCombo && fromCombo.app, fromCombo && fromCombo.dsh),
    forCombo: comboOf(forCombo && forCombo.app, forCombo && forCombo.dsh),
    dshTree: fromCombo && forCombo && fromCombo.dsh !== forCombo.dsh ? 'trees/' + fromCombo.dsh : null,
    counts: counts || null,
    logicalBytes: typeof logicalBytes === 'number' ? logicalBytes : null,
    restoredFrom: restoredFrom || null,
  };
}

/** Validate a parsed meta object (throws with a readable message). */
function parseMeta(raw) {
  if (!raw || typeof raw !== 'object') throw new Error('snapshot: meta must be an object');
  if (!parseSnapshotId(raw.id)) throw new Error('snapshot: bad meta id ' + String(raw.id));
  if (REASONS.indexOf(raw.reason) === -1) throw new Error('snapshot: bad meta reason ' + String(raw.reason));
  if (!raw.forCombo || typeof raw.forCombo !== 'object') throw new Error('snapshot: meta.forCombo missing');
  return raw;
}

// --- retention -------------------------------------------------------------

/**
 * Which snapshots to keep / drop. Protects (design doc §10):
 *   1. the snapshot the current data was restored from (`state.rollback.snapshot`)
 *   2. the newest snapshot whose `forCombo` equals the running combo
 *   3. the `keep` newest overall
 * @returns {{keep: string[], remove: string[]}}
 */
function planPrune({ snapshots, state, currentCombo, keep }) {
  const limit = typeof keep === 'number' ? keep : 3;
  const list = (snapshots || []).slice().sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
  const protectedIds = new Set();
  const rollbackTarget = state && state.rollback && state.rollback.snapshot;
  if (rollbackTarget) protectedIds.add(rollbackTarget);
  const forCurrent = list.find((s) => s.forCombo && currentCombo && sameCombo(s.forCombo, currentCombo));
  if (forCurrent) protectedIds.add(forCurrent.id);
  const keepIds = [];
  for (const s of list) {
    if (keepIds.length < limit || protectedIds.has(s.id)) keepIds.push(s.id);
  }
  const removeIds = list.filter((s) => keepIds.indexOf(s.id) === -1).map((s) => s.id);
  return { keep: keepIds, remove: removeIds };
}

/** Which dsh tree versions the pool must still hold. */
function planTreePool({ snapshots, currentDshVersion }) {
  const wanted = new Set();
  if (currentDshVersion) wanted.add(currentDshVersion);
  for (const s of snapshots || []) {
    if (s.meta && s.meta.dshTree) wanted.add(String(s.meta.dshTree).replace(/^trees\//, ''));
  }
  return Array.from(wanted);
}

/** Tree-pool decision for one launch / rollback (pure). */
function poolDecision({ poolVersions, currentDshVersion, neededDshVersion }) {
  const pool = new Set(poolVersions || []);
  const ensureCurrent = !!(currentDshVersion && !pool.has(currentDshVersion));
  if (!neededDshVersion) return { ensureCurrent, target: 'not-needed' };
  if (pool.has(neededDshVersion)) return { ensureCurrent, target: 'in-pool' };
  return { ensureCurrent, target: 'install' };
}

// --- rollback planning -----------------------------------------------------

const LEGACY_LOG_RE = /^session\.jsonl(\.zstd)?$/;
const GENERATION_LOG_RE = /^session\.v[1-9][0-9]*\.jsonl(\.zstd)?$/;

/** Log filenames of a session dir that belong to a LATER format generation. */
function newerGenerationFiles(files) {
  return (files || []).filter((f) => GENERATION_LOG_RE.test(f));
}

/** True when a session directory only carries generation-0 logs. */
function isGenerationZero(files) {
  const list = files || [];
  return list.some((f) => LEGACY_LOG_RE.test(f)) && newerGenerationFiles(list).length === 0;
}

/**
 * Plan a rollback (PURE): what to restore, what to quarantine, what to swap.
 *
 * Two paths (design doc §8):
 *   B — data + built-in dsh: restore data AND rename the old tree back into place;
 *   A — data only: the target dsh tree is unavailable or below the shell\u2019s
 *       minimum supported version, so the user is told to reinstall the old app.
 *
 * @param {object} opts
 * @param {object} opts.snapshot            target snapshot meta
 * @param {string[]} opts.snapshotSessionIds session ids present in that snapshot
 * @param {Array<{id: string, files: string[]}>} opts.currentSessions current session dirs
 * @param {string} [opts.currentDshVersion]  dsh version installed right now
 * @param {string} [opts.minSupportedDshVersion] shell compatibility floor
 * @param {boolean} [opts.treeAvailable]     target tree present in the pool
 */
function planRollback({ snapshot, snapshotSessionIds, currentSessions, currentDshVersion, minSupportedDshVersion, treeAvailable }) {
  if (!snapshot || !snapshot.fromCombo) throw new Error('snapshot: planRollback needs a target meta');
  const wantIds = new Set(snapshotSessionIds || []);
  const have = currentSessions || [];
  const haveIds = new Set(have.map((s) => s.id));

  const restore = [];
  const addMissing = [];
  for (const id of wantIds) {
    if (haveIds.has(id)) restore.push(id); else addMissing.push(id);
  }
  const quarantine = haveIds.size
    ? Array.from(haveIds).filter((id) => !wantIds.has(id))
    : [];

  // A restored session keeps its generation-0 archive; any later-generation file
  // in it must go, otherwise old and new generations compete (the state in which
  // NEITHER dsh reads the session).
  const dropNewerGeneration = [];
  for (const s of have) {
    if (!wantIds.has(s.id)) continue;
    const files = newerGenerationFiles(s.files);
    if (files.length) dropNewerGeneration.push({ id: s.id, files });
  }

  const needsTree = !!snapshot.dshTree;
  const targetDsh = snapshot.fromCombo.dsh;
  let mode = 'B';
  let fallbackReason = null;
  if (needsTree && minSupportedDshVersion && targetDsh
      && compareSemver(targetDsh, minSupportedDshVersion) < 0) {
    mode = 'A';
    fallbackReason = 'below-min-supported';
  }

  let tree = { action: 'none' };
  if (needsTree && mode === 'B') {
    tree = treeAvailable
      ? { action: 'swap', toVersion: targetDsh, fromVersion: currentDshVersion || null }
      : { action: 'install-then-swap', toVersion: targetDsh };
    if (!treeAvailable && fallbackReason === null) fallbackReason = 'tree-missing';
  }

  return {
    mode,
    fallbackReason,
    restore: restore.sort(),
    addMissing: addMissing.sort(),
    quarantine: quarantine.sort(),
    dropNewerGeneration,
    tree,
    state: {
      dataCombo: snapshot.fromCombo,
      pinDsh: mode === 'B' && needsTree ? targetDsh : null,
    },
  };
}

// --- rollback journal (transaction state machine) --------------------------

/** Start a rollback transaction. */
function newJournal({ targetId, mode, at }) {
  if (!targetId) throw new Error('snapshot: journal needs a target snapshot id');
  return {
    version: 1,
    targetId,
    mode: mode === 'A' ? 'A' : 'B',
    at: at instanceof Date ? at.toISOString() : String(at || ''),
    nextStep: JOURNAL_STEPS[0],
    done: [],
  };
}

/**
 * Record one completed step. Rejects out-of-order steps (a journal is only
 * ever advanced along JOURNAL_STEPS), so a half-finished transaction is always
 * resumable from `nextStep`.
 */
function advanceJournal(journal, step, info) {
  if (!journal) throw new Error('snapshot: missing journal');
  if (step !== journal.nextStep) {
    throw new Error('snapshot: journal step out of order (expected ' + journal.nextStep + ', got ' + step + ')');
  }
  const idx = JOURNAL_STEPS.indexOf(step);
  const done = journal.done.concat([{
    step,
    at: info && info.at ? String(info.at) : new Date().toISOString(),
    note: (info && info.note) || null,
  }]);
  const next = JOURNAL_STEPS[idx + 1] || 'done';
  return Object.assign({}, journal, { done, nextStep: next });
}

/** What the shell should do with a journal it found on disk at launch. */
function resumePlan(journal) {
  if (!journal) return { status: 'none', nextStep: null, canUndo: false, canComplete: false };
  const finished = journal.nextStep === 'done';
  return {
    status: finished ? 'done' : 'in-progress',
    nextStep: finished ? null : journal.nextStep,
    // A rollback is undoable only once the pre-rollback snapshot exists.
    canUndo: journal.done.some((d) => d.step === 'snapshot-live'),
    canComplete: !finished,
  };
}

/** True when a $DSH_HOME entry name must be excluded from a data snapshot. */
function isExcluded(name) {
  return SNAPSHOT_EXCLUDES.indexOf(String(name)) !== -1;
}
module.exports = {
  REASONS,
  SNAPSHOT_EXCLUDES,
  SNAPSHOT_INCLUDES,
  JOURNAL_STEPS,
  comboOf,
  sameCombo,
  comboLabel,
  timestampOf,
  snapshotId,
  parseSnapshotId,
  decideLaunch,
  buildMeta,
  parseMeta,
  planPrune,
  planTreePool,
  poolDecision,
  newerGenerationFiles,
  isGenerationZero,
  planRollback,
  newJournal,
  advanceJournal,
  resumePlan,
  isExcluded,
};
