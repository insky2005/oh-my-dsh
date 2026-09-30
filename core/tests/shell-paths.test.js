'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const sp = require('../lib/shell-paths');

function tmp() { return fs.mkdtempSync(path.join(os.tmpdir(), 'shell-paths-')); }

test('shell-paths: every shell dir nests under $DSH_HOME/oh-my-dsh', () => {
  assert.equal(sp.shellRoot('/h'), '/h/oh-my-dsh');
  for (const [fn, tail] of [
    ['shellDir', 'shell'], ['browserDir', 'browser'], ['repoWikiDir', 'repo-wiki'],
    ['channelRuntimeDir', 'channel-runtime'], ['channelsDir', 'channels'], ['tokensDir', 'tokens'],
  ]) {
    assert.equal(sp[fn]('/h'), '/h/oh-my-dsh/' + tail, fn);
  }
  assert.equal(sp.ghTokenPath('/h'), '/h/oh-my-dsh/gh-token');
  assert.equal(sp.browserPortPath('/h'), '/h/oh-my-dsh/browser-api.port');
  assert.equal(sp.shellPortPath('/h'), '/h/oh-my-dsh/shell-api.port');
});

test('shell-paths: migrateLegacyLayout moves legacy root entries and is idempotent', () => {
  const h = tmp();
  fs.mkdirSync(path.join(h, 'shell', 'snapshots'), { recursive: true });
  fs.writeFileSync(path.join(h, 'shell', 'config.json'), '{"a":1}');
  fs.mkdirSync(path.join(h, 'channels'), { recursive: true });
  fs.writeFileSync(path.join(h, 'channels', 'wx.json'), '{}');
  fs.mkdirSync(path.join(h, 'tokens'), { recursive: true });
  fs.writeFileSync(path.join(h, 'tokens', 'o-r'), 'T');
  fs.writeFileSync(path.join(h, 'gh-token'), 'G');
  fs.writeFileSync(path.join(h, 'browser-api.port'), '3081');
  fs.writeFileSync(path.join(h, 'shell-api.port'), '3081');

  const moved = sp.migrateLegacyLayout(h);
  assert.ok(moved.includes('shell -> shell'), 'reports shell');
  assert.equal(fs.existsSync(path.join(h, 'shell')), false, 'old shell gone');
  assert.equal(fs.readFileSync(path.join(h, 'oh-my-dsh', 'shell', 'config.json'), 'utf8'), '{"a":1}');
  assert.ok(fs.existsSync(path.join(h, 'oh-my-dsh', 'shell', 'snapshots')), 'nested dirs move too');
  assert.equal(fs.readFileSync(path.join(h, 'oh-my-dsh', 'channels', 'wx.json'), 'utf8'), '{}');
  assert.equal(fs.readFileSync(path.join(h, 'oh-my-dsh', 'tokens', 'o-r'), 'utf8'), 'T');
  assert.equal(fs.readFileSync(path.join(h, 'oh-my-dsh', 'gh-token'), 'utf8'), 'G');
  assert.equal(fs.readFileSync(path.join(h, 'oh-my-dsh', 'browser-api.port'), 'utf8'), '3081');
  assert.equal(fs.readFileSync(path.join(h, 'oh-my-dsh', 'shell-api.port'), 'utf8'), '3081');

  assert.deepEqual(sp.migrateLegacyLayout(h), [], 'second run is a no-op');
  assert.deepEqual(sp.migrateLegacyLayout(h), [], 'and stays a no-op');
});

test('shell-paths: migrateLegacyLayout never overwrites an existing new target', () => {
  const h = tmp();
  fs.mkdirSync(path.join(h, 'channels'), { recursive: true });
  fs.writeFileSync(path.join(h, 'channels', 'old.json'), 'old');
  fs.mkdirSync(path.join(h, 'oh-my-dsh', 'channels'), { recursive: true });
  fs.writeFileSync(path.join(h, 'oh-my-dsh', 'channels', 'new.json'), 'new');

  sp.migrateLegacyLayout(h);
  assert.equal(fs.readFileSync(path.join(h, 'oh-my-dsh', 'channels', 'new.json'), 'utf8'), 'new');
  assert.equal(fs.existsSync(path.join(h, 'channels', 'old.json')), true, 'source kept when target exists');
});

test('shell-paths: canonical browser wins over stale browser-dev', () => {
  const h = tmp();
  fs.mkdirSync(path.join(h, 'browser'));
  fs.writeFileSync(path.join(h, 'browser', 'p'), 'release');
  fs.mkdirSync(path.join(h, 'browser-dev'));
  fs.writeFileSync(path.join(h, 'browser-dev', 'p'), 'dev');

  sp.migrateLegacyLayout(h);
  assert.equal(fs.readFileSync(path.join(h, 'oh-my-dsh', 'browser', 'p'), 'utf8'), 'release');
  assert.equal(fs.existsSync(path.join(h, 'browser-dev')), true, 'stale dev profile left untouched');
});

test('shell-paths: migration drops a human-readable rollback guide', () => {
  const h = tmp();
  fs.mkdirSync(path.join(h, 'shell'), { recursive: true });
  fs.writeFileSync(path.join(h, 'shell', 'config.json'), '{}');
  const moved = sp.migrateLegacyLayout(h, { appVersion: '1.2.3' });
  assert.ok(moved.length >= 1);
  const guide = fs.readFileSync(sp.rollbackGuidePath(h), 'utf8');
  assert.match(guide, /回退/);
  assert.match(guide, /shell -> shell/);
  assert.match(guide, /1\.2\.3/);
  assert.match(guide, /oh-my-dsh/);
  assert.match(guide, /ROLLBACK/i.test(guide) ? /ROLLBACK/i : /migration/i);
});

test('shell-paths: a fresh home still gets the guide, and a no-op run keeps the first record', () => {
  const h = tmp();
  sp.migrateLegacyLayout(h);
  const p = sp.rollbackGuidePath(h);
  assert.ok(fs.existsSync(p), 'guide created even with nothing to move');
  const first = fs.readFileSync(p, 'utf8');
  sp.migrateLegacyLayout(h);
  assert.equal(fs.readFileSync(p, 'utf8'), first, 'unchanged when nothing moved');
});
