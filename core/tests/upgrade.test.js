'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  compareVersions, normalizeRegistry, resolveRegistry, DEFAULT_REGISTRY,
  buildUpgradeArgs, compareSemver, isReleaseCandidate, nextStepTarget,
  pinSpec, buildPrefetchArgs, buildApplyArgs,
} = require('../lib/upgrade');

test('compareVersions: x.y.z', () => {
  assert.equal(compareVersions('1.0.0', '1.0.0'), 0);
  assert.equal(compareVersions('1.0.1', '1.0.0'), 1);
  assert.equal(compareVersions('1.0.0', '1.0.1'), -1);
  assert.equal(compareVersions('1.2.0', '1.10.0'), -1);
  assert.equal(compareVersions('0.1.0-rc.6', '0.1.0'), -1);
  assert.equal(compareVersions('0.1.0-rc.6', '0.1.0-rc.5'), 1);
});

test('normalizeRegistry trims trailing slashes', () => {
  assert.equal(normalizeRegistry(' https://registry.npmmirror.com/ '), 'https://registry.npmmirror.com');
});

test('resolveRegistry priority: env > saved > default', () => {
  assert.equal(resolveRegistry({ DSH_REGISTRY: 'https://a/' }), 'https://a');
  assert.equal(resolveRegistry({}, 'https://b/'), 'https://b');
  assert.equal(resolveRegistry({}), DEFAULT_REGISTRY);
});

test('buildUpgradeArgs mirrors the Swift upgrade argv', () => {
  const args = buildUpgradeArgs('/rt/npm/bin/npm-cli.js', 'https://reg');
  assert.deepEqual(args, [
    '/rt/npm/bin/npm-cli.js', 'install', '--loglevel=error',
    '--no-audit', '--no-fund', '--registry', 'https://reg', '@deepseek-ai/dsh@latest',
  ]);
});

test('compareSemver: core ordering + prerelease precedence', () => {
  assert.equal(compareSemver('0.1.2-rc.1', '0.1.1-rc.2'), 1);
  assert.equal(compareSemver('0.1.2', '0.1.2-rc.1'), 1);      // stable > rc
  assert.equal(compareSemver('0.1.2-rc.1', '0.1.2'), -1);
  assert.equal(compareSemver('0.1.2-rc.10', '0.1.2-rc.9'), 1); // rc.10 > rc.9
  assert.equal(compareSemver('0.1.2-rc.1', '0.1.2-alpha.5'), 1); // rc > alpha
  assert.equal(compareSemver('0.1.2-alpha.5', '0.1.2-alpha.4'), 1);
  assert.equal(compareSemver('0.1.2', '0.1.2'), 0);
});

test('isReleaseCandidate keeps stable and rc only', () => {
  assert.equal(isReleaseCandidate('0.1.2'), true);
  assert.equal(isReleaseCandidate('0.1.2-rc.1'), true);
  assert.equal(isReleaseCandidate('0.1.2-alpha.3'), false);
  assert.equal(isReleaseCandidate('0.1.2-beta.1'), false);
  assert.equal(isReleaseCandidate('0.1.5-dev.2'), false);
});

test('nextStepTarget steps one candidate at a time, never to latest', () => {
  const published = [
    '0.1.2-rc.1', '0.1.2-alpha.2', '0.1.3-alpha.2', '0.1.5-alpha.1',
    '0.1.1-rc.2', '0.1.2-alpha.5',
  ];
  // From 0.1.1-rc.2 the next release candidate (stable/rc) is 0.1.2-rc.1 —
  // not dist-tags.latest if that were newer, and not the alphas.
  assert.equal(nextStepTarget('0.1.1-rc.2', published), '0.1.2-rc.1');
  // Advance through to the highest release candidate.
  assert.equal(nextStepTarget('0.1.2-rc.1', published), null); // nothing newer that is stable/rc
});

test('nextStepTarget advances through multiple release candidates in order', () => {
  const published = ['0.1.0', '0.2.0-rc.1', '0.2.0', '0.3.0', '0.4.0'];
  assert.equal(nextStepTarget('0.1.0', published), '0.2.0-rc.1');
  assert.equal(nextStepTarget('0.2.0-rc.1', published), '0.2.0');
  assert.equal(nextStepTarget('0.2.0', published), '0.3.0');
  assert.equal(nextStepTarget('0.4.0', published), null);
});

test('nextStepTarget treats a prerelease current as needing a forward rc/stable', () => {
  const published = ['0.1.2-rc.1', '0.1.2-rc.2', '0.1.2'];
  assert.equal(nextStepTarget('0.1.2-rc.1', published), '0.1.2-rc.2');
  assert.equal(nextStepTarget('0.1.2-rc.2', published), '0.1.2');
});

test('pinSpec / prefetch / apply argv are pinned to the step target', () => {
  assert.equal(pinSpec('0.1.2-rc.1'), '@deepseek-ai/dsh@0.1.2-rc.1');
  assert.deepEqual(buildPrefetchArgs('/rt/npm/bin/npm-cli.js', 'https://reg', '0.1.2-rc.1'), [
    '/rt/npm/bin/npm-cli.js', 'install', '--loglevel=error', '--no-audit',
    '--no-fund', '--registry', 'https://reg', '@deepseek-ai/dsh@0.1.2-rc.1',
  ]);
  assert.deepEqual(buildApplyArgs('/rt/npm/bin/npm-cli.js', 'https://reg', '0.1.2-rc.1'), [
    '/rt/npm/bin/npm-cli.js', 'install', '--loglevel=error', '--no-audit',
    '--no-fund', '--prefer-offline', '--registry', 'https://reg', '@deepseek-ai/dsh@0.1.2-rc.1',
  ]);
});
