'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { parseIssues, detectGitHubRemote } = require('../lib/issues');

test('parseIssues: filters out pull requests (issues API includes PRs)', () => {
  const json = [
    { number: 1, title: 'real issue', state: 'open', labels: [{ name: 'bug' }], html_url: 'https://github.com/o/r/issues/1' },
    { number: 2, title: 'a PR', state: 'open', pull_request: { url: 'https://api.github.com/pulls/2' }, html_url: 'https://github.com/o/r/pull/2' },
    { number: 3, title: 'another', state: 'open', labels: [], html_url: 'https://github.com/o/r/issues/3' },
  ];
  const issues = parseIssues(json);
  assert.equal(issues.length, 2);
  assert.equal(issues[0].number, 1);
  assert.equal(issues[1].number, 3);
});

test('parseIssues: maps labels and defaults', () => {
  const issues = parseIssues([
    { number: 7, title: 'x', state: 'open', labels: ['a', { name: 'b' }], html_url: 'u' },
  ]);
  assert.deepEqual(issues[0].labels, ['a', 'b']);
  assert.equal(issues[0].htmlUrl, 'u');
  assert.ok(issues[0].updatedAt === null || typeof issues[0].updatedAt === 'string');
});

test('parseIssues: handles non-array input', () => {
  assert.deepEqual(parseIssues(null), []);
  assert.deepEqual(parseIssues({}), []);
  assert.deepEqual(parseIssues('nope'), []);
});

test('detectGitHubRemote: parses ssh remote of this very repo', () => {
  const repoRoot = require('node:path').resolve(__dirname, '../..');
  const r = detectGitHubRemote(repoRoot);
  assert.ok(r, 'helloharness should have a github remote');
  assert.equal(r.owner, 'insky2005');
  assert.equal(r.repo, 'oh-my-dsh');
});

test('detectGitHubRemote: returns null for a non-git directory', () => {
  assert.equal(detectGitHubRemote('/nonexistent-path-xyz'), null);
});

test('detectGitHubRemote: recognizes https remote form', () => {
  // Can't easily spin a fake git repo without network; instead assert the
  // regex handles the https shape via a temp git dir with an https remote.
  const { execFileSync } = require('node:child_process');
  const os = require('node:os');
  const fs = require('node:fs');
  const path = require('node:path');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gh-remote-'));
  try {
    execFileSync('git', ['init', '-q'], { cwd: dir });
    execFileSync('git', ['remote', 'add', 'origin', 'https://github.com/foo/bar.git'], { cwd: dir });
    const r = detectGitHubRemote(dir);
    assert.equal(r.owner, 'foo');
    assert.equal(r.repo, 'bar');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
