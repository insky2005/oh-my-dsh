'use strict';

/**
 * snapshot-io: the filesystem half of session snapshots / rollback.
 *
 * Real temp directories + real node fs (clone falls back to a recursive copy on
 * non-APFS volumes, so the same code path runs on Linux CI). Covers design doc
 * §13 items 1-7 at the operation level, including the atomicity guarantees.
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const io = require('../lib/snapshot-io');
const snapshot = require('../lib/snapshot');

const AT = new Date('2026-09-23T10:15:00Z');
const COMBO_A = { app: '1.16.0', dsh: '0.1.2-rc.1' };
const COMBO_C = { app: '1.16.2', dsh: '0.1.5-rc.2' };

/** A throwaway $DSH_HOME with the entries that matter (and some that must not be copied). */
function makeHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'snapio-'));
  seedSession(home, '--work-a--', 'session-old', ['session.jsonl.zstd']);
  seedSession(home, '--work-a--', 'session-new', ['session.v3.jsonl.zstd']);
  fs.mkdirSync(path.join(home, 'storages'), { recursive: true });
  fs.writeFileSync(path.join(home, 'storages', 'workspace.json'), '{"unit":{"name":"workspace","version":2}}');
  fs.mkdirSync(path.join(home, 'shell'), { recursive: true });
  fs.writeFileSync(path.join(home, 'shell', 'dsh-web.json'), '{"token":"SECRET"}');
  fs.mkdirSync(path.join(home, 'credentials'), { recursive: true });
  fs.writeFileSync(path.join(home, 'credentials', 'key'), 'secret');
  fs.mkdirSync(path.join(home, 'browser'), { recursive: true });
  fs.writeFileSync(path.join(home, 'browser', 'big'), 'x');
  return home;
}

function seedSession(home, slug, id, files) {
  const dir = path.join(home, 'sessions', slug, id);
  fs.mkdirSync(dir, { recursive: true });
  for (const f of files) fs.writeFileSync(path.join(dir, f), 'event\n');
  return dir;
}

function seedTree(root, version, marker) {
  const dir = path.join(root, version);
  fs.mkdirSync(path.join(dir, 'lib'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'lib', 'bin.js'), marker);
  return dir;
}

// --- snapshots -------------------------------------------------------------

test('snapshot-io: a snapshot copies sessions + storages and nothing else', () => {
  const home = makeHome();
  const made = io.createSnapshot({ home, appVersion: COMBO_A.app, dshVersion: COMBO_A.dsh, reason: 'bootstrap', at: AT });
  assert.equal(made.meta.reason, 'bootstrap');
  assert.equal(made.meta.counts.sessions, 2, 'two session dirs, not two slugs');
  assert.equal(made.meta.dshTree, null);
  assert.ok(fs.existsSync(path.join(made.dir, 'sessions', '--work-a--', 'session-old', 'session.jsonl.zstd')));
  assert.ok(fs.existsSync(path.join(made.dir, 'storages', 'workspace.json')));
  for (const forbidden of ['shell', 'credentials', 'browser']) {
    assert.equal(fs.existsSync(path.join(made.dir, forbidden)), false, forbidden + ' must not be copied');
  }
  assert.equal(fs.readdirSync(path.join(made.dir)).filter((n) => n.startsWith('.tmp-')).length, 0);
  assert.equal(fs.readdirSync(io.snapshotsDir(home)).some((n) => n.startsWith('.tmp-')), false);
  assert.deepEqual(io.listSnapshots(home).map((s) => s.id), [made.id]);
  assert.deepEqual(io.snapshotSessionIds(made.dir).sort(), ['session-new', 'session-old']);
});

test('snapshot-io: listSnapshots sorts newest first and flags a broken meta', () => {
  const home = makeHome();
  const older = io.createSnapshot({ home, appVersion: COMBO_A.app, dshVersion: COMBO_A.dsh, reason: 'bootstrap', at: new Date('2026-09-20T00:00:00Z') });
  const newer = io.createSnapshot({ home, appVersion: COMBO_A.app, dshVersion: COMBO_A.dsh, reason: 'combo-change', at: AT });
  fs.mkdirSync(path.join(io.snapshotsDir(home), 'broken_snapshot_dir'), { recursive: true });
  const list = io.listSnapshots(home);
  assert.equal(list[0].id, newer.id);
  assert.equal(list[1].id, older.id);
  assert.equal(list[2].broken, true);
  assert.equal(list[2].meta, null);
});

test('snapshot-io: state and journal round-trip atomically', () => {
  const home = makeHome();
  assert.equal(io.readState(home), null);
  const state = { version: 1, dataCombo: COMBO_A, history: [] };
  io.writeState(home, state);
  assert.deepEqual(io.readState(home), state);
  assert.equal(fs.readdirSync(io.shellDir(home)).some((n) => n.includes('.tmp-')), false);

  let journal = snapshot.newJournal({ targetId: 'x', mode: 'B', at: AT });
  io.writeJournal(home, journal);
  journal = snapshot.advanceJournal(journal, 'stop-server');
  io.writeJournal(home, journal);
  assert.equal(io.readJournal(home).nextStep, 'snapshot-live');
  io.clearJournal(home);
  assert.equal(io.readJournal(home), null);
});

// --- tree pool -------------------------------------------------------------

test('snapshot-io: a dsh tree is captured once per version and then reused', () => {
  const home = makeHome();
  const dshDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dshtree-'));
  fs.mkdirSync(path.join(dshDir, 'lib'), { recursive: true });
  fs.writeFileSync(path.join(dshDir, 'lib', 'bin.js'), '0.1.2-rc.1');
  const first = io.captureTree({ home, dshDir, version: '0.1.2-rc.1' });
  assert.equal(first.action, 'cloned');
  assert.equal(fs.readFileSync(path.join(first.dir, 'lib', 'bin.js'), 'utf8'), '0.1.2-rc.1');
  const second = io.captureTree({ home, dshDir, version: '0.1.2-rc.1' });
  assert.equal(second.action, 'present');
  const missing = io.captureTree({ home, dshDir: path.join(home, 'nope'), version: '9' });
  assert.equal(missing.action, 'none');
});

test('snapshot-io: swapping the tree keeps the displaced one for undo', () => {
  const home = makeHome();
  const runtime = fs.mkdtempSync(path.join(os.tmpdir(), 'runtime-'));
  const dshDir = path.join(runtime, 'dsh');
  fs.mkdirSync(path.join(dshDir, 'lib'), { recursive: true });
  fs.writeFileSync(path.join(dshDir, 'lib', 'bin.js'), '0.1.5');
  // pool holds the previous version
  io.captureTree({ home, dshDir: seedTree(fs.mkdtempSync(path.join(os.tmpdir(), 'old-')), 'dsh-old', '0.1.2'), version: '0.1.2-rc.1' });
  const pooled = io.treeDir(home, '0.1.2-rc.1');
  fs.mkdirSync(pooled, { recursive: true });
  fs.writeFileSync(path.join(pooled, 'version'), '0.1.2-rc.1');

  const swap = io.swapTree({ home, dshDir, toVersion: '0.1.2-rc.1', currentVersion: '0.1.5-rc.2', stamp: 't1' });
  assert.equal(swap.ok, true);
  assert.equal(fs.readFileSync(path.join(dshDir, 'version'), 'utf8'), '0.1.2-rc.1');
  assert.equal(fs.readFileSync(path.join(swap.displaced, 'lib', 'bin.js'), 'utf8'), '0.1.5', 'the new tree is kept, not deleted');

  const missing = io.swapTree({ home, dshDir, toVersion: '0.9.9', currentVersion: null, stamp: 't2' });
  assert.deepEqual(missing.ok, false);
  assert.equal(missing.reason, 'missing-tree');
});

// --- rollback --------------------------------------------------------------

test('snapshot-io: rollback parks the live state, restores the target and quarantines new sessions', () => {
  const home = makeHome();
  // the snapshot was taken when only session-old existed
  const target = io.createSnapshot({ home, appVersion: COMBO_A.app, dshVersion: COMBO_A.dsh, reason: 'dsh-upgrade', at: AT, fromCombo: COMBO_A });
  // work happened since: a brand-new session appears, and session-old migrated
  seedSession(home, '--work-a--', 'session-fresh', ['session.v3.jsonl.zstd']);
  fs.writeFileSync(path.join(home, 'sessions', '--work-a--', 'session-old', 'session.v3.jsonl.zstd'), 'migrated\n');
  fs.writeFileSync(path.join(home, 'storages', 'workspace.json'), '{"unit":{"name":"workspace","version":2},"changed":true}');

  const preId = snapshot.snapshotId({ at: new Date('2026-09-23T11:00:00Z'), app: COMBO_C.app, dsh: COMBO_C.dsh, reason: 'pre-rollback' });
  const result = io.applyRollback({
    home, target, preRollbackId: preId, preRollbackCombo: COMBO_C, forCombo: COMBO_A, at: new Date('2026-09-23T11:00:00Z'),
  });

  assert.equal(result.ok, true);
  assert.deepEqual(result.parked, ['sessions', 'storages']);
  // restored tree no longer carries the migrated file
  assert.equal(fs.existsSync(path.join(home, 'sessions', '--work-a--', 'session-old', 'session.v3.jsonl.zstd')), false);
  assert.ok(fs.existsSync(path.join(home, 'sessions', '--work-a--', 'session-old', 'session.jsonl.zstd')));
  // storages restored to the snapshot content
  assert.equal(JSON.parse(fs.readFileSync(path.join(home, 'storages', 'workspace.json'), 'utf8')).changed, undefined);
  // the brand-new session is quarantined (not deleted) with a manifest
  assert.deepEqual(result.quarantined, ['session-fresh']);
  const stamp = path.basename(result.preRollbackDir);
  const manifest = JSON.parse(fs.readFileSync(path.join(io.quarantineDir(home, stamp), 'quarantine.json'), 'utf8'));
  assert.deepEqual(manifest.sessions.map((x) => x.id), ['session-fresh']);
  assert.ok(fs.existsSync(path.join(io.quarantineDir(home, stamp), 'sessions', '--work-a--', 'session-fresh', 'session.v3.jsonl.zstd')));
  // the parked state is a first-class snapshot with meta (the undo target)
  assert.equal(io.defaultIO.readJson(path.join(result.preRollbackDir, 'meta.json')).reason, 'pre-rollback');
  assert.ok(io.listSnapshots(home).some((s) => s.id === preId && !s.broken));
  // and the pre-rollback copy still holds the migrated file for later recovery
  assert.ok(fs.existsSync(path.join(result.preRollbackDir, 'sessions', '--work-a--', 'session-old', 'session.v3.jsonl.zstd')));
});

test('snapshot-io: pruning keeps the newest snapshots, protects the rollback target and trims the pool', () => {
  const home = makeHome();
  const ids = [];
  for (const day of ['18', '19', '20']) {
    ids.push(io.createSnapshot({ home, appVersion: COMBO_A.app, dshVersion: COMBO_A.dsh, reason: 'combo-change', at: new Date('2026-09-' + day + 'T00:00:00Z') }).id);
  }
  // the newest snapshot is the pre-upgrade one: it references the OLD dsh tree
  ids.push(io.createSnapshot({
    home, appVersion: COMBO_C.app, dshVersion: COMBO_C.dsh, reason: 'dsh-upgrade',
    at: new Date('2026-09-21T00:00:00Z'), fromCombo: COMBO_A,
  }).id);
  const trees = ['0.1.1', '0.1.2-rc.1', '0.1.5-rc.2'];
  for (const v of trees) {
    fs.mkdirSync(io.treeDir(home, v), { recursive: true });
    fs.writeFileSync(path.join(io.treeDir(home, v), 'version'), v);
  }
  const plan = io.pruneSnapshots({ home, keep: 3, currentCombo: COMBO_C, currentDshVersion: '0.1.5-rc.2', state: null });
  assert.equal(plan.removed.length, 1);
  assert.equal(plan.removed[0], ids[0], 'the oldest goes first');
  assert.equal(io.listSnapshots(home).length, 3);
  assert.deepEqual(plan.removedTrees, ['0.1.1'], 'a version no snapshot and no running dsh needs is dropped');
  assert.ok(fs.existsSync(io.treeDir(home, '0.1.5-rc.2')), 'the running version stays');
  assert.ok(fs.existsSync(io.treeDir(home, '0.1.2-rc.1')), 'a tree referenced by a kept snapshot stays');
});
