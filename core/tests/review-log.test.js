'use strict';

/**
 * review-log: READ-ONLY audit of dsh session logs (docs/review-panel-design.md).
 *
 * The three merged record families are exercised here with synthetic events:
 * applied hunks from `tool/result.meta.diffs`, call arguments from `tool/call`
 * and `tool/code-dispatch-start`, and bash command text. The Zstandard container
 * is covered only when the running Node exposes zstd (v22.15+/v23.8+) — the
 * audit path itself must stay testable on the CI Node without it.
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const zlib = require('node:zlib');
const review = require('../lib/review-log');

function tempHome() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'review-'));
}

/** Write a plaintext session log at the dsh layout and return its path. */
function seedSession(dshHome, slug, id, events) {
  const dir = path.join(dshHome, 'sessions', slug, id);
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, 'session.jsonl');
  fs.writeFileSync(file, events.map((e) => JSON.stringify(e)).join('\n') + '\n', 'utf8');
  return file;
}

const HEADER = { type: 'session', id: 'session-a', createdAt: 1000, cwd: '/work/proj', delegationDepth: 0 };

function topCall(seq, callId, name, args) {
  return { type: 'tool/call', seq, data: { turn: 1, step: 1, callId, name, arguments: JSON.stringify(args) } };
}

function topResult(seq, callId, meta, isError) {
  return {
    type: 'tool/result',
    seq,
    data: {
      turn: 1,
      step: 1,
      message: {
        source: { kind: 'tool', callId },
        content: [{ type: 'tool-result', toolCallId: callId, content: [{ type: 'text', text: 'ok' }], isError: isError === true }],
      },
      ...(meta === undefined ? {} : { meta }),
    },
  };
}

test('review-log: top-level edit uses the applied hunks from result meta', () => {
  const events = [
    HEADER,
    topCall(10, 'c1', 'edit', { file_path: '/work/proj/src/a.js', old_string: 'x', new_string: 'y' }),
    topResult(11, 'c1', { diffs: [{ path: '/work/proj/src/a.js', oldText: 'let x = 1;', newText: 'let y = 1;\nlet z = 2;' }] }),
  ];
  const audit = review.buildAudit(events, { workspace: '/work/proj' });
  const entry = audit.entries[0];
  assert.equal(entry.category, 'diff');
  assert.equal(entry.note, 'applied-hunks');
  assert.equal(entry.path, 'src/a.js');
  assert.equal(entry.status, 'ok');
  assert.equal(entry.added, 2);
  assert.equal(entry.removed, 1);
  assert.equal(audit.stats.files, 1);
  assert.equal(audit.stats.nested, 0);
});

test('review-log: edit without result meta falls back to the call arguments', () => {
  const events = [
    HEADER,
    topCall(20, 'c2', 'edit', { file_path: '/work/proj/src/b.js', old_string: 'old-line', new_string: 'new-line' }),
    topResult(21, 'c2', undefined),
  ];
  const entry = review.buildAudit(events, { workspace: '/work/proj' }).entries[0];
  assert.equal(entry.category, 'args');
  assert.equal(entry.note, 'args');
  assert.deepEqual(entry.hunks, [{ oldText: 'old-line', newText: 'new-line' }]);
  assert.equal(entry.path, 'src/b.js');
});

test('review-log: created file has empty applied hunks and falls back to the written content', () => {
  const events = [
    HEADER,
    topCall(30, 'c3', 'write', { file_path: '/work/proj/src/new.js', content: 'a\nb\nc' }),
    topResult(31, 'c3', { diffs: [] }),
  ];
  const entry = review.buildAudit(events, { workspace: '/work/proj' }).entries[0];
  assert.equal(entry.category, 'content');
  assert.equal(entry.note, 'created-content');
  assert.deepEqual(entry.hunks, [{ oldText: null, newText: 'a\nb\nc' }]);
  assert.equal(entry.added, 3);
  assert.equal(entry.removed, 0);
});

test('review-log: nested run_code dispatches are audited from their arguments', () => {
  const events = [
    HEADER,
    { type: 'tool/call', seq: 40, data: { turn: 1, step: 1, callId: 'root', name: 'run_code', arguments: '{}' } },
    { type: 'tool/code-dispatch-start', seq: 41, data: { rootCallId: 'root', parentCallId: 'root', subCallId: 'root:code:1', name: 'write', arguments: { file_path: '/work/proj/core/x.js', content: 'one\ntwo' } } },
    { type: 'tool/code-dispatch', seq: 42, data: { rootCallId: 'root', parentCallId: 'root', subCallId: 'root:code:1', name: 'write', arguments: { file_path: '/work/proj/core/x.js', content: 'one\ntwo' }, isError: false, content: [] } },
    { type: 'tool/code-dispatch-start', seq: 43, data: { rootCallId: 'root', parentCallId: 'root', subCallId: 'root:code:2', name: 'edit', arguments: { file_path: '/work/proj/core/x.js', old_string: 'one', new_string: 'one!' } } },
    { type: 'tool/code-dispatch', seq: 44, data: { rootCallId: 'root', parentCallId: 'root', subCallId: 'root:code:2', name: 'edit', arguments: { file_path: '/work/proj/core/x.js', old_string: 'one', new_string: 'one!' }, isError: false, content: [] } },
  ];
  const audit = review.buildAudit(events, { workspace: '/work/proj' });
  const nested = audit.entries.filter((e) => e.surface === 'nested' && e.category !== 'bash');
  assert.equal(nested.length, 2);
  assert.equal(nested[0].category, 'content');
  assert.equal(nested[0].note, 'nested-content');
  assert.equal(nested[0].added, 2);
  assert.equal(nested[1].category, 'args');
  assert.equal(nested[1].note, 'nested-args');
  assert.deepEqual(nested[1].hunks, [{ oldText: 'one', newText: 'one!' }]);
  assert.equal(audit.stats.nested, 2); // one entry per dispatch (the run_code call itself is top-level)
});

test('review-log: turns are labelled by the user message and inherited by nested calls', () => {
  const events = [
    HEADER,
    { type: 'turn/start', seq: 4, data: { turn: 1 } },
    { type: 'user/message', seq: 5, data: { content: [{ type: 'text', text: 'first ask' }], source: { kind: 'user' }, role: 'user' } },
    { type: 'tool/call', seq: 6, data: { turn: 1, step: 1, callId: 'root', name: 'run_code', arguments: '{}' } },
    { type: 'tool/code-dispatch-start', seq: 7, data: { rootCallId: 'root', parentCallId: 'root', subCallId: 'root:code:1', name: 'write', arguments: { file_path: '/work/proj/a.txt', content: 'x' } } },
    { type: 'tool/code-dispatch', seq: 8, data: { rootCallId: 'root', parentCallId: 'root', subCallId: 'root:code:1', name: 'write', arguments: { file_path: '/work/proj/a.txt', content: 'x' }, isError: false, content: [] } },
    { type: 'turn/start', seq: 9, data: { turn: 2 } },
    { type: 'user/message', seq: 10, data: { content: [{ type: 'text', text: 'second ask' }], source: { kind: 'user' }, role: 'user' } },
    { type: 'tool/call', seq: 11, data: { turn: 2, step: 1, callId: 'c9', name: 'edit', arguments: JSON.stringify({ file_path: '/work/proj/a.txt', old_string: 'x', new_string: 'y' }) } },
    topResult(12, 'c9', undefined),
  ];
  const audit = review.buildAudit(events, { workspace: '/work/proj' });
  assert.deepEqual(audit.turns.map((t) => t.turn), [1, 2]);
  assert.equal(audit.turns[0].prompt, 'first ask');
  assert.equal(audit.turns[1].prompt, 'second ask');
  const nested = audit.entries.find((e) => e.surface === 'nested');
  assert.equal(nested.turn, 1, 'nested dispatch inherits the run_code call turn');
  assert.equal(nested.step, 1);
  const second = audit.entries.find((e) => e.callId === 'c9');
  assert.equal(second.turn, 2);
});

test('review-log: a tool-result message never becomes a turn prompt', () => {
  const events = [
    HEADER,
    { type: 'turn/start', seq: 4, data: { turn: 1 } },
    { type: 'user/message', seq: 5, data: { content: [{ type: 'text', text: 'real ask' }], source: { kind: 'user' }, role: 'user' } },
    topCall(6, 'c1', 'read', { file_path: '/work/proj/a.txt' }),
    topResult(7, 'c1', undefined),
    { type: 'turn/start', seq: 8, data: { turn: 2 } },
  ];
  const audit = review.buildAudit(events, { workspace: '/work/proj' });
  assert.equal(audit.turns[0].prompt, 'real ask');
  assert.equal(audit.turns[1].prompt, null);
});

test('review-log: a failed mutation records its error state without hunks', () => {
  const events = [
    HEADER,
    topCall(50, 'c5', 'edit', { file_path: '/work/proj/src/c.js', old_string: 'a', new_string: 'b' }),
    topResult(51, 'c5', undefined, true),
  ];
  const audit = review.buildAudit(events, { workspace: '/work/proj' });
  const entry = audit.entries[0];
  assert.equal(entry.status, 'error');
  assert.deepEqual(entry.hunks, []);
  assert.equal(audit.stats.failed, 1);
  assert.equal(audit.stats.files, 0);
  assert.equal(audit.stats.added, 0);
});

test('review-log: bash calls are listed and flagged when they may write', () => {
  const events = [
    HEADER,
    { type: 'tool/call', seq: 60, data: { turn: 1, step: 2, callId: 'b1', name: 'bash', arguments: JSON.stringify({ command: 'ls -la', description: 'list' }) } },
    { type: 'tool/call', seq: 61, data: { turn: 1, step: 2, callId: 'b2', name: 'bash', arguments: JSON.stringify({ command: 'sed -i "" -e s/a/b/ src/a.js', description: 'edit' }) } },
    { type: 'tool/call', seq: 62, data: { turn: 1, step: 2, callId: 'b3', name: 'bash', arguments: JSON.stringify({ command: 'echo hi > out.txt', description: 'write' }) } },
  ];
  const audit = review.buildAudit(events, { workspace: '/work/proj' });
  assert.equal(audit.stats.bashCalls, 3);
  assert.equal(audit.stats.bashSuspect, 2);
  assert.equal(audit.entries[0].suspicion, 'unknown');
  assert.equal(audit.entries[1].suspicion, 'write-like');
  assert.equal(audit.stats.mutations, 0);
});

test('review-log: str_replace_editor create/str_replace/insert map to audit entries', () => {
  const events = [
    HEADER,
    topCall(70, 'e1', 'str_replace_editor', { command: 'create', path: '/work/proj/d.txt', file_text: 'body' }),
    topCall(71, 'e2', 'str_replace_editor', { command: 'str_replace', path: '/work/proj/d.txt', old_str: 'body', new_str: 'body2' }),
    topCall(72, 'e3', 'str_replace_editor', { command: 'view', path: '/work/proj/d.txt' }),
    topCall(73, 'e4', 'str_replace_editor', { command: 'insert', path: '/work/proj/d.txt', insert_line: 1, new_str: 'tail' }),
  ];
  const audit = review.buildAudit(events, { workspace: '/work/proj' });
  const entries = audit.entries.filter((e) => e.category && e.category !== 'bash');
  assert.equal(entries.length, 3); // view is a read, not an audit entry
  assert.equal(entries[0].category, 'content');
  assert.equal(entries[1].category, 'args');
  assert.equal(entries[1].note, 'args');
  assert.equal(entries[2].category, 'args');
  assert.equal(entries[2].note, 'args');
});

test('review-log: malformed JSONL lines are skipped with a diagnostic', () => {
  const diagnostics = [];
  const events = review.parseEvents('{"type":"session"}\nnot json\n\n{"type":"turn/start"}\n', diagnostics);
  assert.equal(events.length, 2);
  assert.equal(diagnostics.length, 1);
  assert.equal(diagnostics[0].code, 'malformed-lines');
});

test('review-log: bashLooksLikeWrite ignores benign commands', () => {
  assert.equal(review.bashLooksLikeWrite('git status --short'), false);
  assert.equal(review.bashLooksLikeWrite('node --test core/tests/'), false);
  assert.equal(review.bashLooksLikeWrite('cat a.txt'), false);
  assert.equal(review.bashLooksLikeWrite('cat a.txt > b.txt'), true);
  assert.equal(review.bashLooksLikeWrite('rm -rf dist'), true);
  assert.equal(review.bashLooksLikeWrite('git checkout -- src/'), true);
});

test('review-log: relativize keeps foreign paths absolute', () => {
  assert.equal(review.relativize('/work/proj/src/a.js', '/work/proj'), 'src/a.js');
  assert.equal(review.relativize('/work/proj', '/work/proj'), '/work/proj');
  assert.equal(review.relativize('/elsewhere/a.js', '/work/proj'), '/elsewhere/a.js');
});

test('review-log: listSessionLogs filters by workspace and audits end to end', () => {
  const dshHome = tempHome();
  seedSession(dshHome, '--work-proj--', 'session-a', [
    HEADER,
    topCall(10, 'c1', 'edit', { file_path: '/work/proj/src/a.js', old_string: 'x', new_string: 'y\nz' }),
    topResult(11, 'c1', { diffs: [{ path: '/work/proj/src/a.js', oldText: 'x', newText: 'y\nz' }] }),
  ]);
  seedSession(dshHome, '--other--', 'session-b', [{ type: 'session', id: 'session-b', cwd: '/other' }]);

  const listed = review.listSessionLogs({ dshHome, workspace: '/work/proj' });
  assert.deepEqual(listed.sessions.map((s) => s.id), ['session-a']);
  assert.equal(listed.sessions[0].compressed, false);

  const audit = review.auditSession({ sessionId: 'session-a', dshHome, workspace: '/work/proj' });
  assert.equal(audit.session.id, 'session-a');
  assert.equal(audit.stats.files, 1);
  assert.equal(audit.entries[0].path, 'src/a.js');
});

test('review-log: auditSession reports a missing session instead of throwing', () => {
  const dshHome = tempHome();
  fs.mkdirSync(path.join(dshHome, 'sessions'), { recursive: true });
  const audit = review.auditSession({ sessionId: 'nope', dshHome });
  assert.equal(audit.stats, null);
  assert.equal(audit.diagnostics[audit.diagnostics.length - 1].code, 'session-not-found');
});

test('review-log: zstd container decodes every concatenated frame', { skip: typeof zlib.zstdCompressSync !== 'function' }, () => {
  const dshHome = tempHome();
  const dir = path.join(dshHome, 'sessions', '--work-proj--', 'session-z');
  fs.mkdirSync(dir, { recursive: true });
  const events = [
    HEADER,
    topCall(10, 'c1', 'write', { file_path: '/work/proj/z.txt', content: 'hello' }),
    topResult(11, 'c1', { diffs: [] }),
  ];
  const frames = events.map((e) => zlib.zstdCompressSync(Buffer.from(JSON.stringify(e) + '\n', 'utf8')));
  const file = path.join(dir, 'session.jsonl.zstd');
  fs.writeFileSync(file, Buffer.concat(frames));

  const scanned = review.scanZstdFrames(fs.readFileSync(file));
  assert.equal(scanned.frames.length, 3);
  assert.equal(scanned.tornStart, undefined);

  const audit = review.auditSessionLog({ file, workspace: '/work/proj' });
  assert.equal(audit.session.id, 'session-a');
  assert.equal(audit.entries[0].path, 'z.txt');
  assert.equal(audit.stats.files, 1);
});

test('review-log: a torn trailing frame is skipped with a diagnostic', { skip: typeof zlib.zstdCompressSync !== 'function' }, () => {
  const dshHome = tempHome();
  const dir = path.join(dshHome, 'sessions', '--work-proj--', 'session-t');
  fs.mkdirSync(dir, { recursive: true });
  const whole = zlib.zstdCompressSync(Buffer.from(JSON.stringify(HEADER) + '\n', 'utf8'));
  const torn = zlib.zstdCompressSync(Buffer.from(JSON.stringify(topCall(10, 'c1', 'edit', { file_path: '/work/proj/a.js', old_string: 'a', new_string: 'b' })) + '\n', 'utf8'));
  const file = path.join(dir, 'session.jsonl.zstd');
  fs.writeFileSync(file, Buffer.concat([whole, torn.subarray(0, Math.floor(torn.length / 2))]));

  const audit = review.auditSessionLog({ file, workspace: '/work/proj' });
  assert.equal(audit.entries.length, 0);
  assert.ok(audit.diagnostics.some((d) => d.code === 'zstd-torn-frame'));
});

test('review-log: an invalid frame magic is reported, not thrown', { skip: typeof zlib.zstdCompressSync !== 'function' }, () => {
  assert.throws(() => review.scanZstdFrames(Buffer.from('not a zstd frame at all')), /invalid frame magic/);
});
