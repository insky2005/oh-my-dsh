'use strict';

/**
 * snapshot: session snapshot / rollback planning (PURE).
 *
 * Covers docs/session-snapshot-rollback-design.md items 1-7 of the test list:
 * naming/meta, the launch decision, the rollback plan, retention protection,
 * the transaction journal, the exclusion list and the tree-pool decision.
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');
const s = require('../lib/snapshot');

const AT = new Date('2026-09-23T10:15:00Z');
const COMBO_A = { app: '1.16.0', dsh: '0.1.2-rc.1' };
const COMBO_B = { app: '1.16.2', dsh: '0.1.2-rc.1' };
const COMBO_C = { app: '1.16.2', dsh: '0.1.5-rc.2' };

// --- naming + meta ---------------------------------------------------------

test('snapshot: id embeds timestamp, both versions and the reason', () => {
  const id = s.snapshotId({ at: AT, app: COMBO_A.app, dsh: COMBO_A.dsh, reason: 'combo-change' });
  assert.equal(id, '20260923-101500_app1.16.0_dsh0.1.2-rc.1_combo-change');
  assert.deepEqual(s.parseSnapshotId(id), {
    timestamp: '20260923-101500', app: '1.16.0', dsh: '0.1.2-rc.1', reason: 'combo-change',
  });
});

test('snapshot: an unknown reason is refused, malformed ids parse to null', () => {
  assert.throws(() => s.snapshotId({ at: AT, app: '1', dsh: '2', reason: 'whatever' }), /unknown reason/);
  for (const bad of ['20260923-101500_app1_dsh2_nope', 'nonsense', '', null, 42]) {
    assert.equal(s.parseSnapshotId(bad), null, String(bad) + ' must not parse');
  }
});

test('snapshot: meta carries a tree reference only when the dsh version changes', () => {
  const appOnly = s.buildMeta({ id: s.snapshotId({ at: AT, app: COMBO_B.app, dsh: COMBO_B.dsh, reason: 'combo-change' }),
    at: AT, reason: 'combo-change', fromCombo: COMBO_A, forCombo: COMBO_B, counts: { sessions: 3 }, logicalBytes: 10 });
  assert.equal(appOnly.dshTree, null, 'app-only change must not need a tree');
  assert.equal(appOnly.createdAt, AT.toISOString());
  assert.deepEqual(s.parseMeta(appOnly), appOnly);

  const dshChange = s.buildMeta({ id: s.snapshotId({ at: AT, app: COMBO_C.app, dsh: COMBO_C.dsh, reason: 'dsh-upgrade' }),
    at: AT, reason: 'dsh-upgrade', fromCombo: COMBO_B, forCombo: COMBO_C });
  assert.equal(dshChange.dshTree, 'trees/0.1.2-rc.1');
});

test('snapshot: parseMeta rejects broken metas', () => {
  assert.throws(() => s.parseMeta(null), /must be an object/);
  assert.throws(() => s.parseMeta({ id: 'bad', reason: 'bootstrap', forCombo: {} }), /bad meta id/);
  assert.throws(() => s.parseMeta({ id: '20260923-101500_app1_dsh2_bootstrap', reason: 'nope', forCombo: {} }), /bad meta reason/);
  assert.throws(() => s.parseMeta({ id: '20260923-101500_app1_dsh2_bootstrap', reason: 'bootstrap' }), /forCombo missing/);
});

// --- launch decision -------------------------------------------------------

test('snapshot: first launch bootstraps, a combo change snapshots, an unchanged combo does not', () => {
  const bootstrap = s.decideLaunch({ state: null, currentCombo: COMBO_A });
  assert.equal(bootstrap.action, 'snapshot');
  assert.equal(bootstrap.reason, 'bootstrap');

  const none = s.decideLaunch({ state: { dataCombo: COMBO_B }, currentCombo: COMBO_B });
  assert.equal(none.action, 'none');
  assert.equal(none.fromCombo, null);

  // Only the app version changed: still worth a snapshot (data-only).
  const appOnly = s.decideLaunch({ state: { dataCombo: COMBO_A }, currentCombo: COMBO_B });
  assert.equal(appOnly.action, 'snapshot');
  assert.equal(appOnly.reason, 'combo-change');
  assert.deepEqual(appOnly.fromCombo, COMBO_A);

  const dshOnly = s.decideLaunch({ state: { dataCombo: COMBO_B }, currentCombo: COMBO_C });
  assert.equal(dshOnly.reason, 'combo-change');
  assert.deepEqual(dshOnly.fromCombo, COMBO_B);
});

// --- rollback plan ---------------------------------------------------------

const SNAP_TREE = s.buildMeta({ id: s.snapshotId({ at: AT, app: COMBO_B.app, dsh: COMBO_B.dsh, reason: 'dsh-upgrade' }),
  at: AT, reason: 'dsh-upgrade', fromCombo: COMBO_B, forCombo: COMBO_C });
const SNAP_DATA_ONLY = s.buildMeta({ id: s.snapshotId({ at: AT, app: COMBO_B.app, dsh: COMBO_B.dsh, reason: 'combo-change' }),
  at: AT, reason: 'combo-change', fromCombo: COMBO_A, forCombo: COMBO_B });

test('snapshot: rollback restores snapshot sessions, quarantines newer ones, swaps the tree', () => {
  const plan = s.planRollback({
    snapshot: SNAP_TREE,
    snapshotSessionIds: ['session-a', 'session-b'],
    currentSessions: [
      { id: 'session-a', files: ['session.jsonl.zstd', 'session.v3.jsonl.zstd'] },
      { id: 'session-c', files: ['session.v3.jsonl.zstd'] },
    ],
    currentDshVersion: COMBO_C.dsh,
    minSupportedDshVersion: COMBO_A.dsh,
    treeAvailable: true,
  });
  assert.equal(plan.mode, 'B');
  assert.equal(plan.fallbackReason, null);
  assert.deepEqual(plan.restore, ['session-a']);
  assert.deepEqual(plan.addMissing, ['session-b']);
  assert.deepEqual(plan.quarantine, ['session-c']);
  assert.deepEqual(plan.dropNewerGeneration, [{ id: 'session-a', files: ['session.v3.jsonl.zstd'] }]);
  assert.deepEqual(plan.tree, { action: 'swap', toVersion: '0.1.2-rc.1', fromVersion: '0.1.5-rc.2' });
  assert.deepEqual(plan.state.dataCombo, COMBO_B);
  assert.equal(plan.state.pinDsh, '0.1.2-rc.1');
});

test('snapshot: a data-only snapshot never touches the tree', () => {
  const plan = s.planRollback({
    snapshot: SNAP_DATA_ONLY,
    snapshotSessionIds: ['session-a'],
    currentSessions: [{ id: 'session-a', files: ['session.jsonl'] }],
    currentDshVersion: COMBO_B.dsh,
    minSupportedDshVersion: COMBO_A.dsh,
    treeAvailable: false,
  });
  assert.equal(plan.mode, 'B');
  assert.deepEqual(plan.tree, { action: 'none' });
  assert.equal(plan.state.pinDsh, null);
  assert.deepEqual(plan.quarantine, []);
  assert.deepEqual(plan.dropNewerGeneration, []);
});

test('snapshot: a missing tree falls back to install-then-swap, a too-old dsh to path A', () => {
  const noTree = s.planRollback({
    snapshot: SNAP_TREE,
    snapshotSessionIds: ['session-a'],
    currentSessions: [{ id: 'session-a', files: ['session.v3.jsonl'] }],
    currentDshVersion: COMBO_C.dsh,
    minSupportedDshVersion: COMBO_A.dsh,
    treeAvailable: false,
  });
  assert.equal(noTree.mode, 'B');
  assert.equal(noTree.fallbackReason, 'tree-missing');
  assert.deepEqual(noTree.tree, { action: 'install-then-swap', toVersion: '0.1.2-rc.1' });

  const tooOld = s.planRollback({
    snapshot: SNAP_TREE,
    snapshotSessionIds: [],
    currentSessions: [],
    currentDshVersion: COMBO_C.dsh,
    minSupportedDshVersion: '0.1.3-alpha.1',
    treeAvailable: true,
  });
  assert.equal(tooOld.mode, 'A');
  assert.equal(tooOld.fallbackReason, 'below-min-supported');
  assert.deepEqual(tooOld.tree, { action: 'none' }, 'path A must not touch the tree');
  assert.equal(tooOld.state.pinDsh, null);
});

test('snapshot: generation detection distinguishes legacy logs from newer generations', () => {
  assert.deepEqual(s.newerGenerationFiles(['session.jsonl.zstd', 'session.v3.jsonl.zstd']), ['session.v3.jsonl.zstd']);
  assert.deepEqual(s.newerGenerationFiles(['session.jsonl', 'session.lock']), []);
  assert.equal(s.isGenerationZero(['session.jsonl.zstd']), true);
  assert.equal(s.isGenerationZero(['session.jsonl.zstd', 'session.v3.jsonl.zstd']), false);
  assert.equal(s.isGenerationZero(['session.v3.jsonl.zstd']), false);
});

// --- retention -------------------------------------------------------------

function snap(ts, from, forCombo) {
  return { id: ts, createdAt: ts, fromCombo: from, forCombo };
}
const S1 = snap('2026-09-20T00:00:00Z', COMBO_A, COMBO_A);
const S2 = snap('2026-09-21T00:00:00Z', COMBO_A, COMBO_B);
const S3 = snap('2026-09-22T00:00:00Z', COMBO_B, COMBO_C);
const S4 = snap('2026-09-23T00:00:00Z', COMBO_C, COMBO_B);

test('snapshot: pruning keeps the 3 newest and protects the current combo + rollback target', () => {
  const plan = s.planPrune({ snapshots: [S4, S3, S2, S1], currentCombo: COMBO_B, keep: 3 });
  assert.deepEqual(plan.keep, [S4.id, S3.id, S2.id]);
  assert.deepEqual(plan.remove, [S1.id]);

  // The oldest is protected twice over: it is BOTH the rollback target and the
  // newest snapshot whose forCombo equals the running combo.
  const guarded = s.planPrune({ snapshots: [S4, S3, S2, S1], state: { rollback: { snapshot: S1.id } }, currentCombo: COMBO_A, keep: 2 });
  assert.ok(guarded.keep.includes(S1.id), 'rollback target must never be pruned');
  assert.ok(guarded.keep.includes(S4.id));
  assert.ok(guarded.keep.includes(S3.id));
  assert.deepEqual(guarded.remove, [S2.id]);
});

test('snapshot: the tree pool keeps exactly the versions still referenced', () => {
  const versions = s.planTreePool({
    snapshots: [{ meta: SNAP_TREE }, { meta: { dshTree: null } }, { meta: { dshTree: 'trees/0.1.5-rc.1' } }],
    currentDshVersion: COMBO_C.dsh,
  });
  assert.deepEqual(versions.sort(), ['0.1.2-rc.1', '0.1.5-rc.1', '0.1.5-rc.2'].sort());
});

test('snapshot: pool decision reports when the running version must be captured or installed', () => {
  assert.deepEqual(s.poolDecision({ poolVersions: [], currentDshVersion: COMBO_A.dsh, neededDshVersion: null }),
    { ensureCurrent: true, target: 'not-needed' });
  assert.deepEqual(s.poolDecision({ poolVersions: ['0.1.2-rc.1', '0.1.5-rc.2'], currentDshVersion: COMBO_C.dsh, neededDshVersion: '0.1.2-rc.1' }),
    { ensureCurrent: false, target: 'in-pool' });
  assert.deepEqual(s.poolDecision({ poolVersions: ['0.1.5-rc.2'], currentDshVersion: COMBO_C.dsh, neededDshVersion: '0.1.2-rc.1' }),
    { ensureCurrent: false, target: 'install' });
});

// --- journal ---------------------------------------------------------------

test('snapshot: the journal advances strictly in order and reports resumability', () => {
  let j = s.newJournal({ targetId: S3.id, mode: 'B', at: AT });
  assert.equal(j.nextStep, 'stop-server');
  assert.deepEqual(s.resumePlan(j), { status: 'in-progress', nextStep: 'stop-server', canUndo: false, canComplete: true });
  assert.throws(() => s.advanceJournal(j, 'restore-data'), /out of order/);

  j = s.advanceJournal(j, 'stop-server');
  j = s.advanceJournal(j, 'snapshot-live', { at: AT.toISOString(), note: 'pre-rollback' });
  const mid = s.resumePlan(j);
  assert.equal(mid.nextStep, 'restore-data');
  assert.equal(mid.canUndo, true, 'undo is possible once the live state is snapshotted');

  for (const step of ['restore-data', 'quarantine', 'swap-tree', 'write-state']) j = s.advanceJournal(j, step);
  assert.equal(j.nextStep, 'done');
  assert.equal(j.done.length, s.JOURNAL_STEPS.length);
  assert.deepEqual(s.resumePlan(j), { status: 'done', nextStep: null, canUndo: true, canComplete: false });
  assert.deepEqual(s.resumePlan(null), { status: 'none', nextStep: null, canUndo: false, canComplete: false });
});

// --- exclusions ------------------------------------------------------------

test('snapshot: secrets, our own state and the browser profile are never snapshotted', () => {
  for (const name of ['shell', 'credentials', '.credentials.yaml', 'profiles', 'settings.yaml',
    'channels', 'browser', 'browser-dev', 'skills', 'attachments', 'tokens']) {
    assert.equal(s.isExcluded(name), true, name + ' must be excluded');
  }
  for (const name of ['sessions', 'storages']) {
    assert.equal(s.isExcluded(name), false, name + ' must be included');
    assert.ok(s.SNAPSHOT_INCLUDES.includes(name));
  }
});
