'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {
  settingsPath, settingsReadAll, settingsGet, settingsSet, settingsUnset, dshHome,
} = require('../lib/settings');

function tmpHome() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'ohmy-settings-'));
}

test('settingsPath: <DSH_HOME>/shell/config.json', () => {
  assert.equal(settingsPath('/tmp/x'), '/tmp/x/shell/config.json');
});

test('dshHome: explicit > env > ~/.dsh', () => {
  assert.equal(dshHome('/tmp/e'), '/tmp/e');
  const prev = process.env.DSH_HOME;
  process.env.DSH_HOME = '/tmp/env-home';
  assert.equal(dshHome(), '/tmp/env-home');
  delete process.env.DSH_HOME;
  assert.equal(dshHome(), path.join(os.homedir(), '.dsh'));
  if (prev !== undefined) process.env.DSH_HOME = prev; else delete process.env.DSH_HOME;
});

test('get on absent file returns null; readAll returns {}', () => {
  const h = tmpHome();
  assert.equal(settingsGet('nope', h), null);
  assert.deepEqual(settingsReadAll(h), {});
});

test('set/get/unset round-trip (string, bool, number, object)', () => {
  const h = tmpHome();
  settingsSet('appTheme', 'dark', h);
  settingsSet('autoUpgradeDsh', false, h);
  settingsSet('nextAutoUpgradeCheck', 123.5, h);
  settingsSet('channel.global.list', [{ id: 'x', platform: 'weixin' }], h);
  assert.equal(settingsGet('appTheme', h), 'dark');
  assert.equal(settingsGet('autoUpgradeDsh', h), false);
  assert.equal(settingsGet('nextAutoUpgradeCheck', h), 123.5);
  assert.deepEqual(settingsGet('channel.global.list', h), [{ id: 'x', platform: 'weixin' }]);
  settingsUnset('appTheme', h);
  assert.equal(settingsGet('appTheme', h), null);
  // survives a re-read from disk
  const all = settingsReadAll(h);
  assert.equal(all.autoUpgradeDsh, false);
  assert.ok(!('appTheme' in all));
});

test('writes are atomic (no tmp left) and file is valid JSON', () => {
  const h = tmpHome();
  settingsSet('a', 1, h);
  const dir = path.join(h, 'shell');
  const leftovers = fs.readdirSync(dir).filter((f) => f.includes('.tmp-'));
  assert.deepEqual(leftovers, []);
  const parsed = JSON.parse(fs.readFileSync(path.join(dir, 'config.json'), 'utf8'));
  assert.equal(parsed.a, 1);
});
