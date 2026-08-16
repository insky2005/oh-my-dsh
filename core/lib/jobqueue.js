'use strict';

/**
 * core/lib/jobqueue.js — strictly serial job queue state machine.
 *
 * The IssueRunner panel (and future remote drivers) enqueue jobs; the queue
 * guarantees at most ONE running job at a time and exposes a plain snapshot
 * the UI can subscribe to. Pure logic, no timers — the caller drives it.
 */

const STATES = {
  PENDING: 'pending',
  RUNNING: 'running',
  DONE: 'done',
  FAILED: 'failed',
  CANCELLED: 'cancelled',
};

/** Create an empty serial queue. */
function createQueue() {
  let jobs = [];
  let runningId = null;
  let nextSeq = 1;

  /** Add a job to the tail. Returns the job id. */
  function enqueue(job) {
    const id = job.id != null ? String(job.id) : `job-${nextSeq++}`;
    jobs.push({
      id,
      title: job.title || id,
      source: job.source || 'manual',
      meta: job.meta || null,
      state: STATES.PENDING,
      error: null,
      result: null,
      createdAt: Date.now(),
      startedAt: null,
      finishedAt: null,
    });
    return id;
  }

  /** The next pending job's id, or null (does not mutate state). */
  function peek() {
    const j = jobs.find((x) => x.state === STATES.PENDING);
    return j ? j.id : null;
  }

  /** Mark the given job running. Only succeeds if nothing else is running. */
  function markRunning(id) {
    if (runningId) return false;
    const j = jobs.find((x) => x.id === id && x.state === STATES.PENDING);
    if (!j) return false;
    j.state = STATES.RUNNING;
    j.startedAt = Date.now();
    runningId = id;
    return true;
  }

  /** The currently running job, or null. */
  function current() {
    return runningId ? jobs.find((x) => x.id === runningId) || null : null;
  }

  function isRunning() { return runningId != null; }

  /** Mark the running job done (or any pending job, by id). */
  function complete(id, result = null) {
    const j = jobs.find((x) => x.id === id);
    if (!j) return false;
    j.state = STATES.DONE;
    j.result = result;
    j.finishedAt = Date.now();
    if (runningId === id) runningId = null;
    return true;
  }

  /** Mark the running job failed. */
  function fail(id, error = 'unknown error') {
    const j = jobs.find((x) => x.id === id);
    if (!j) return false;
    j.state = STATES.FAILED;
    j.error = error;
    j.finishedAt = Date.now();
    if (runningId === id) runningId = null;
    return true;
  }

  /** Cancel a pending or running job. Cancelling the running job frees the queue. */
  function cancel(id) {
    const j = jobs.find((x) => x.id === id);
    if (!j) return false;
    if (j.state === STATES.DONE || j.state === STATES.CANCELLED || j.state === STATES.FAILED) return false;
    j.state = STATES.CANCELLED;
    j.finishedAt = Date.now();
    if (runningId === id) runningId = null;
    return true;
  }

  /** Mark a failed job pending again (retry). */
  function retry(id) {
    const j = jobs.find((x) => x.id === id);
    if (!j || j.state !== STATES.FAILED) return false;
    j.state = STATES.PENDING;
    j.error = null;
    j.finishedAt = null;
    return true;
  }

  /** Deep-ish snapshot for UI subscription. */
  function snapshot() {
    return {
      jobs: jobs.map((j) => ({ ...j })),
      runningId,
      hasPending: jobs.some((x) => x.state === STATES.PENDING),
    };
  }

  /** Remove finished jobs (done/failed/cancelled) — UI-level cleanup only. */
  function removeFinished() {
    jobs = jobs.filter((x) => x.state === STATES.PENDING || x.state === STATES.RUNNING);
  }

  return {
    enqueue, peek, markRunning, current, isRunning,
    complete, fail, cancel, retry, snapshot, removeFinished,
  };
}

module.exports = { createQueue, STATES };
