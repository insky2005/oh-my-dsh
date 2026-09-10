'use strict';

/**
 * core/lib/settings.js — language-agnostic shell settings store.
 *
 * The single canonical implementation (path resolution + atomic
 * read/modify/write) for oh-my-dsh *shell* settings, shared by every platform
 * shell (macOS Swift / future Windows / Linux). Backed by a plain UTF-8 JSON
 * file so ANY language can read it:
 *
 *   $DSH_HOME/shell/config.json      (DSH_HOME defaults to ~/.dsh)
 *
 * Keys are flat strings; values are arbitrary JSON values. The dsh daemon's own
 * $DSH_HOME/settings.yaml is separate and never touched here.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

/** Resolve the dsh data home: explicit arg > $DSH_HOME > ~/.dsh. */
function dshHome(explicit) {
  const env = process.env.DSH_HOME;
  if (explicit && String(explicit).trim()) return String(explicit).trim();
  if (env && env.trim()) return env.trim();
  return path.join(os.homedir(), '.dsh');
}

function settingsDir(explicit) {
  return path.join(dshHome(explicit), 'shell');
}

function settingsPath(explicit) {
  return path.join(settingsDir(explicit), 'config.json');
}

/** Read the whole settings object (empty object when absent/invalid). */
function readAll(explicit) {
  try {
    const raw = fs.readFileSync(settingsPath(explicit), 'utf8');
    const j = JSON.parse(raw);
    return j && typeof j === 'object' && !Array.isArray(j) ? j : {};
  } catch {
    return {};
  }
}

/** Atomically write the whole settings object (mkdir + tmp + rename). */
function writeAll(obj, explicit) {
  const dir = settingsDir(explicit);
  fs.mkdirSync(dir, { recursive: true });
  const file = settingsPath(explicit);
  const tmp = file + '.tmp-' + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2) + '\n', 'utf8');
  fs.renameSync(tmp, file);
  return file;
}

/** One key's value, or null when absent. */
function get(key, explicit) {
  const all = readAll(explicit);
  return Object.prototype.hasOwnProperty.call(all, key) ? all[key] : null;
}

/** Set one key (any JSON value) and persist; returns the value. */
function set(key, value, explicit) {
  const all = readAll(explicit);
  all[key] = value;
  writeAll(all, explicit);
  return value;
}

/** Remove one key; returns true. */
function unset(key, explicit) {
  const all = readAll(explicit);
  delete all[key];
  writeAll(all, explicit);
  return true;
}

module.exports = {
  dshHome,
  settingsDir,
  settingsPath,
  settingsReadAll: readAll,
  settingsGet: get,
  settingsSet: set,
  settingsUnset: unset,
};
