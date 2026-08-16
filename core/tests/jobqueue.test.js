'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createQueue, STATES } = require('../lib/jobqueue');

test('queue: enqueue + strict serial execution', () => {
  const q = createQueue();
  const a = q.enqueue({ title: 'issue 1' });
  const b = q.enqueue({ title: 'issue 2' });

  assert.equal(q.peek(), a);
  assert.equal(q.markRunning(a), true);
  assert.equal(q.isRunning(), true);
  assert.equal(q.current().id, a);

  // Second job cannot start while first is running
  assert.equal(q.markRunning(b), false);

  q.complete(a, { prUrl: 'https://github.com/o/r/pull/1' });
  assert.equal(q.isRunning(), false);
  assert.equal(q.peek(), b);
  assert.equal(q.markRunning(b), true);
  q.complete(b);
  assert.equal(q.peek(), null);
});

test('queue: fail sets state and frees the queue', () => {
  const q = createQueue();
  const a = q.enqueue({ title: 'x' });
  q.markRunning(a);
  q.fail(a, 'build broke');
  assert.equal(q.snapshot().jobs[0].state, STATES.FAILED);
  assert.equal(q.snapshot().jobs[0].error, 'build broke');
  assert.equal(q.isRunning(), false);
});

test('queue: retry moves failed job back to pending', () => {
  const q = createQueue();
  const a = q.enqueue({ title: 'x' });
  q.markRunning(a);
  q.fail(a, 'oops');
  assert.equal(q.retry(a), true);
  assert.equal(q.snapshot().jobs[0].state, STATES.PENDING);
  assert.equal(q.retry('missing'), false);
});

test('queue: cancel pending and running jobs', () => {
  const q = createQueue();
  const a = q.enqueue({ title: 'a' });
  const b = q.enqueue({ title: 'b' });

  // cancel pending
  assert.equal(q.cancel(b), true);
  assert.equal(q.snapshot().jobs[1].state, STATES.CANCELLED);

  // cancel running frees queue
  q.markRunning(a);
  assert.equal(q.cancel(a), true);
  assert.equal(q.isRunning(), false);

  // already-finished cannot be cancelled
  assert.equal(q.cancel(a), false);
});

test('queue: snapshot is detached and complete', () => {
  const q = createQueue();
  q.enqueue({ title: 't', source: 'github', meta: { issue: 12 } });
  const snap = q.snapshot();
  assert.equal(snap.jobs.length, 1);
  assert.equal(snap.jobs[0].title, 't');
  assert.equal(snap.jobs[0].source, 'github');
  assert.equal(snap.jobs[0].meta.issue, 12);
  assert.equal(snap.hasPending, true);
  // mutating the snapshot must not affect the queue
  snap.jobs[0].state = 'tampered';
  assert.equal(q.snapshot().jobs[0].state, STATES.PENDING);
});

test('queue: custom ids respected, auto ids unique', () => {
  const q = createQueue();
  assert.equal(q.enqueue({ id: 'issue-7', title: 'x' }), 'issue-7');
  const auto1 = q.enqueue({ title: 'y' });
  const auto2 = q.enqueue({ title: 'z' });
  assert.notEqual(auto1, auto2);
});

test('queue: removeFinished drops only terminal jobs', () => {
  const q = createQueue();
  const a = q.enqueue({ title: 'a' });
  const b = q.enqueue({ title: 'b' });
  const c = q.enqueue({ title: 'c' });
  q.markRunning(a);
  q.complete(a);
  q.cancel(b);
  q.removeFinished();
  const ids = q.snapshot().jobs.map((j) => j.id);
  assert.deepEqual(ids, [c]);
});
