'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  compareVersions, normalizeRegistry, resolveRegistry, DEFAULT_REGISTRY,
  buildUpgradeArgs,
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
