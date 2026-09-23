'use strict';

/**
 * core/lib/snapshot-io.js — filesystem side of session snapshots / rollback.
 *
 * Every mutation goes through an injectable `io` object (default: real fs), so
 * the transaction can be tested headless and the shell can substitute a fake.
 *
 * Layout (docs/session-snapshot-rollback-design.md §4):
 *   $DSH_HOME/shell/dsh-state.json
 *   $DSH_HOME/shell/rollback-journal.json
 *   $DSH_HOME/shell/snapshots/<id>/{meta.json,sessions/,storages/}
 *   $DSH_HOME/shell/snapshots/trees/<dshVersion>/
 *   $DSH_HOME/shell/snapshots/quarantine/<stamp>/{quarantine.json,sessions/}
 *
 * Cloning prefers APFS `cp -cR` (clonefile: 306 MB / 246 files = 0.12 s, ~0 extra
 * space) and falls back to a recursive copy (so Linux CI still exercises the
 * same code path).
 */

const fs = require('node:fs');
const path = require('node:path');
const snapshot = require('./snapshot');

// --- default io ------------------------------------------------------------

/** Atomic JSON write (tmp + rename) so a crash never leaves a torn state file. */
function writeJsonAtomic(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = file + '.tmp-' + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2) + '\n');
  fs.renameSync(tmp, file);
}

/** Recursive byte/file count of a directory (0 when missing). */
function dirStats(dir) {
  let bytes = 0;
  let files = 0;
  const walk = (p) => {
    let entries;
    try { entries = fs.readdirSync(p, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const full = path.join(p, e.name);
      if (e.isDirectory()) walk(full);
      else {
        files += 1;
        try { bytes += fs.statSync(full).size; } catch { /* ignore */ }
      }
    }
  };
  walk(dir);
  return { bytes, files };
}

/**
 * Default IO: clone via APFS clonefile on darwin, recursive copy elsewhere.
 * Returns which strategy actually ran ('clone' | 'copy') for the log line.
 */
const defaultIO = {
  cloneDir(src, dst) {
    if (!fs.existsSync(src)) return 'missing';
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    if (process.platform === 'darwin') {
      try {
        require('node:child_process').execFileSync('/bin/cp', ['-cR', src, dst], { stdio: 'ignore' });
        return 'clone';
      } catch { /* fall through to a plain copy */ }
    }
    fs.cpSync(src, dst, { recursive: true });
    return 'copy';
  },
  move(from, to) {
    fs.mkdirSync(path.dirname(to), { recursive: true });
    fs.renameSync(from, to);
  },
  remove(p) { fs.rmSync(p, { recursive: true, force: true }); },
  exists(p) { return fs.existsSync(p); },
  mkdir(p) { fs.mkdirSync(p, { recursive: true }); },
  readJson(file) {
    try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
  },
  writeJson: writeJsonAtomic,
  listNames(dir) {
    try { return fs.readdirSync(dir, { withFileTypes: true }); } catch { return []; }
  },
  dirStats,
};

// --- paths -----------------------------------------------------------------

function shellDir(home) { return path.join(home, 'shell'); }
function statePath(home) { return path.join(shellDir(home), 'dsh-state.json'); }
function journalPath(home) { return path.join(shellDir(home), 'rollback-journal.json'); }
function snapshotsDir(home) { return path.join(shellDir(home), 'snapshots'); }
function treesDir(home) { return path.join(snapshotsDir(home), 'trees'); }
function treeDir(home, version) { return path.join(treesDir(home), String(version)); }
function quarantineDir(home, stamp) { return path.join(snapshotsDir(home), 'quarantine', String(stamp)); }

/** `$DSH_HOME` (env DSH_HOME, else ~/.dsh) — same rule as review-log/workspace-store. */
function dshHomeDir(home) {
  const h = home || process.env.DSH_HOME;
  return h && String(h).trim() ? String(h).trim() : path.join(require('node:os').homedir(), '.dsh');
}

// --- state / journal -------------------------------------------------------

function readState(home, io) {
  return (io || defaultIO).readJson(statePath(dshHomeDir(home)));
}

function writeState(home, state, io) {
  (io || defaultIO).writeJson(statePath(dshHomeDir(home)), state);
  return state;
}

function readJournal(home, io) { return (io || defaultIO).readJson(journalPath(dshHomeDir(home))); }
function writeJournal(home, journal, io) { (io || defaultIO).writeJson(journalPath(dshHomeDir(home)), journal); return journal; }
function clearJournal(home, io) { (io || defaultIO).remove(journalPath(dshHomeDir(home))); }

// --- scanning --------------------------------------------------------------

/** Every `<slug>/<session-id>/` under $DSH_HOME/sessions, with its log files. */
function listSessions(home, io) {
  const I = io || defaultIO;
  const root = path.join(dshHomeDir(home), 'sessions');
  const out = [];
  for (const slug of I.listNames(root)) {
    if (!slug.isDirectory()) continue;
    const slugDir = path.join(root, slug.name);
    for (const dir of I.listNames(slugDir)) {
      if (!dir.isDirectory()) continue;
      const full = path.join(slugDir, dir.name);
      const files = I.listNames(full).filter((e) => e.isFile()).map((e) => e.name);
      out.push({ id: dir.name, slug: slug.name, dir: full, files });
    }
  }
  return out;
}

/** All well-formed snapshots, newest first; malformed dirs are reported as broken. */
function listSnapshots(home, io) {
  const I = io || defaultIO;
  const root = snapshotsDir(dshHomeDir(home));
  const out = [];
  for (const entry of I.listNames(root)) {
    if (!entry.isDirectory() || entry.name === 'trees' || entry.name === 'quarantine') continue;
    if (entry.name.startsWith('.tmp-')) continue;
    const dir = path.join(root, entry.name);
    const raw = I.readJson(path.join(dir, 'meta.json'));
    let meta = null;
    try { meta = raw ? snapshot.parseMeta(raw) : null; } catch { meta = null; }
    out.push({
      id: entry.name,
      dir,
      meta,
      broken: !meta,
      createdAt: meta ? meta.createdAt : null,
      sessions: I.listNames(path.join(dir, 'sessions')).filter((e) => e.isDirectory()).length,
      bytes: I.dirStats(dir).bytes,
    });
  }
  // Newest first; snapshots whose meta could not be read always come last.
  out.sort((a, b) => {
    if (!a.createdAt && !b.createdAt) return a.id.localeCompare(b.id);
    if (!a.createdAt) return 1;
    if (!b.createdAt) return -1;
    return String(b.createdAt).localeCompare(String(a.createdAt));
  });
  return out;
}

/** Session ids contained in a snapshot directory. */
function snapshotSessionIds(snapshotDir, io) {
  const I = io || defaultIO;
  const ids = [];
  for (const slug of I.listNames(path.join(snapshotDir, 'sessions'))) {
    if (!slug.isDirectory()) continue;
    for (const dir of I.listNames(path.join(snapshotDir, 'sessions', slug.name))) {
      if (dir.isDirectory()) ids.push(dir.name);
    }
  }
  return ids;
}
// --- operations ------------------------------------------------------------

/**
 * Take one data snapshot (`sessions/ + storages/`) atomically: everything is
 * written into `.tmp-<id>` first and renamed into place at the end, so a crash
 * never leaves a half snapshot that the UI would offer as a rollback target.
 *
 * @returns {{id: string, dir: string, meta: object, clone: string}}
 */
function createSnapshot({ home, appVersion, dshVersion, reason, at, io, fromCombo, restoredFrom }) {
  const I = io || defaultIO;
  const root = dshHomeDir(home);
  const id = snapshot.snapshotId({ at, app: appVersion, dsh: dshVersion, reason });
  const dir = path.join(snapshotsDir(root), id);
  const tmp = path.join(snapshotsDir(root), '.tmp-' + id + '-' + process.pid);
  I.remove(tmp);
  I.mkdir(tmp);
  let clone = 'none';
  for (const name of snapshot.SNAPSHOT_INCLUDES) {
    const src = path.join(root, name);
    if (!I.exists(src)) continue;
    clone = I.cloneDir(src, path.join(tmp, name)) || clone;
  }
  const counts = { sessions: countSessions(path.join(tmp, 'sessions'), I) };
  const bytes = I.dirStats(tmp).bytes;
  const meta = snapshot.buildMeta({
    id, at, reason, fromCombo, forCombo: { app: appVersion, dsh: dshVersion }, counts, logicalBytes: bytes, restoredFrom,
  });
  I.writeJson(path.join(tmp, 'meta.json'), meta);
  I.move(tmp, dir);
  return { id, dir, meta, clone };
}

/**
 * Make sure the tree of `version` is in the pool (one copy per dsh version).
 * Called at launch: installing a new .pkg replaces the whole app bundle — and
 * with it the old `runtime/dsh` — before any of our code runs, so the only way
 * to keep the old tree is to have captured it while it was still running.
 * @returns {{action: 'present'|'cloned'|'none', dir: string|null, clone?: string}}
 */
function captureTree({ home, dshDir, version, io }) {
  const I = io || defaultIO;
  if (!version || !dshDir || !I.exists(dshDir)) return { action: 'none', dir: null };
  const root = dshHomeDir(home);
  const dest = treeDir(root, version);
  if (I.exists(dest)) return { action: 'present', dir: dest };
  const tmp = dest + '.tmp-' + process.pid;
  I.remove(tmp);
  const clone = I.cloneDir(dshDir, tmp);
  I.move(tmp, dest);
  return { action: 'cloned', dir: dest, clone };
}

/**
 * Swap the live tree for a pooled one, keeping the tree that was live (never
 * deleted) so a rollback stays undoable.
 */
function swapTree({ home, dshDir, toVersion, currentVersion, io, stamp }) {
  const I = io || defaultIO;
  const root = dshHomeDir(home);
  const source = treeDir(root, toVersion);
  if (!I.exists(source)) return { ok: false, reason: 'missing-tree', dir: source };
  let displaced = currentVersion ? treeDir(root, currentVersion) : null;
  if (!displaced || I.exists(displaced)) {
    displaced = path.join(treesDir(root), '.displaced-' + String(stamp || Date.now()));
  }
  I.move(dshDir, displaced);
  I.move(source, dshDir);
  return { ok: true, displaced, restored: dshDir };
}

/**
 * The data half of a rollback (design doc §7, steps ②③):
 *   1. the live `sessions/ + storages/` is MOVED into a pre-rollback snapshot
 *      (nothing is ever deleted — this is also what makes undo possible);
 *   2. the target snapshot is cloned back into place;
 *   3. sessions that did not exist in the target are copied into the
 *      quarantine area with a manifest, so post-snapshot work stays reachable.
 * The caller handles the server lifecycle, the tree swap and the state file.
 */
function applyRollback({ home, target, preRollbackId, preRollbackCombo, forCombo, at, io }) {
  const I = io || defaultIO;
  const root = dshHomeDir(home);
  if (!target || !target.dir) throw new Error('snapshot: applyRollback needs a target snapshot');
  const preDir = path.join(snapshotsDir(root), preRollbackId);
  I.remove(preDir);
  I.mkdir(preDir);

  // ① park the live state
  const moved = [];
  for (const name of snapshot.SNAPSHOT_INCLUDES) {
    const live = path.join(root, name);
    if (!I.exists(live)) continue;
    I.move(live, path.join(preDir, name));
    moved.push(name);
  }

  // ② restore the target
  for (const name of snapshot.SNAPSHOT_INCLUDES) {
    const src = path.join(target.dir, name);
    if (!I.exists(src)) continue;
    I.cloneDir(src, path.join(root, name));
  }

  // ③ quarantine the sessions the target never knew about
  const wanted = new Set(snapshotSessionIds(target.dir, I));
  const parked = path.join(preDir, 'sessions');
  const stamp = path.basename(preDir);
  const quarantined = [];
  for (const session of listSessions(rootOf(parked), I)) {
    if (wanted.has(session.id)) continue;
    const dest = path.join(quarantineDir(root, stamp), 'sessions', session.slug, session.id);
    I.cloneDir(session.dir, dest);
    quarantined.push({ id: session.id, slug: session.slug });
  }
  if (quarantined.length) {
    I.writeJson(path.join(quarantineDir(root, stamp), 'quarantine.json'), {
      at: at instanceof Date ? at.toISOString() : String(at || ''),
      from: preRollbackId, reason: 'sessions created after the target snapshot', sessions: quarantined,
    });
  }

  // the parked state is a first-class snapshot (it is the undo target)
  const counts = { sessions: countSessions(parked, I) };
  I.writeJson(path.join(preDir, 'meta.json'), snapshot.buildMeta({
    id: preRollbackId, at: at || new Date(), reason: 'pre-rollback',
    fromCombo: preRollbackCombo, forCombo: forCombo || preRollbackCombo,
    counts, logicalBytes: I.dirStats(preDir).bytes,
  }));

  return {
    ok: true,
    preRollbackDir: preDir,
    parked: moved,
    restored: Array.from(wanted).sort(),
    quarantined: quarantined.map((q) => q.id).sort(),
  };
}

/** Treat a sessions directory as an isolated $DSH_HOME (for listSessions). */
function rootOf(sessionsAbsolutePath) { return path.dirname(sessionsAbsolutePath); }

/** Number of <slug>/<session-id>/ directories under one sessions root. */
function countSessions(sessionsRoot, io) {
  const I = io || defaultIO;
  let n = 0;
  for (const slug of I.listNames(sessionsRoot)) {
    if (!slug.isDirectory()) continue;
    n += I.listNames(path.join(sessionsRoot, slug.name)).filter((e) => e.isDirectory()).length;
  }
  return n;
}

/**
 * Prune snapshots (3 newest + protected) and then the tree pool down to the
 * versions the surviving snapshots still reference plus the running version.
 */
function pruneSnapshots({ home, keep, state, currentCombo, currentDshVersion, io }) {
  const I = io || defaultIO;
  const root = dshHomeDir(home);
  const all = listSnapshots(root, I).filter((s) => !s.broken);
  const plan = snapshot.planPrune({
    snapshots: all.map((s) => ({ id: s.id, createdAt: s.createdAt, fromCombo: s.meta.fromCombo, forCombo: s.meta.forCombo })),
    state, currentCombo, keep,
  });
  for (const id of plan.remove) I.remove(path.join(snapshotsDir(root), id));
  const kept = all.filter((s) => plan.keep.indexOf(s.id) !== -1);
  const wantedTrees = new Set(snapshot.planTreePool({ snapshots: kept.map((s) => ({ meta: s.meta })), currentDshVersion }));
  const removedTrees = [];
  for (const entry of I.listNames(treesDir(root))) {
    if (!entry.isDirectory()) continue;
    if (entry.name.startsWith('.displaced-')) continue;   // kept for undo
    if (wantedTrees.has(entry.name)) continue;
    I.remove(path.join(treesDir(root), entry.name));
    removedTrees.push(entry.name);
  }
  return { kept: plan.keep, removed: plan.remove, keptTrees: Array.from(wantedTrees), removedTrees };
}

module.exports = {
  defaultIO,
  writeJsonAtomic,
  dirStats,
  dshHomeDir,
  shellDir,
  statePath,
  journalPath,
  snapshotsDir,
  treesDir,
  treeDir,
  quarantineDir,
  readState,
  writeState,
  readJournal,
  writeJournal,
  clearJournal,
  listSessions,
  listSnapshots,
  countSessions,
  snapshotSessionIds,
  createSnapshot,
  captureTree,
  swapTree,
  applyRollback,
  pruneSnapshots,
};
