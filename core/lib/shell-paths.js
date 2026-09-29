'use strict';

/**
 * core/lib/shell-paths.js — the single source of truth for where oh-my-dsh
 * SHELL work data lives, plus the one-time layout migration.
 *
 * Layout (docs/storage-layout-refactor.md):
 *
 *   $DSH_HOME/oh-my-dsh/
 *     projects/         projects panel workspaces (ProjectsCore.defaultSubpath)
 *     shell/            shell settings + snapshot state/snapshots
 *     browser/          CEF/Chromium profile (release + dev unified)
 *     repo-wiki/        wiki panel DSH_HOME-private root
 *     channel-runtime/  channel runner runtime
 *     channels/         channel credentials/sessions/messages/state
 *     tokens/           per-repo GitHub tokens
 *     gh-token          generic GitHub token
 *     browser-api.port  browser panel localhost API port
 *     shell-api.port    tasks panel localhost API port
 *
 * dsh's own data (sessions/ storages/ settings.yaml ...) and the upstream
 * contract path $DSH_HOME/skills/ are NOT touched.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

/** Directory name of the shell data root, nested inside $DSH_HOME. */
const SHELL_ROOT = 'oh-my-dsh';

/** Resolve the dsh data home: explicit arg > $DSH_HOME > ~/.dsh. */
function dshHome(explicit) {
  if (explicit && String(explicit).trim()) return String(explicit).trim();
  const env = process.env.DSH_HOME;
  if (env && env.trim()) return env.trim();
  return path.join(os.homedir(), '.dsh');
}

function shellRoot(explicit) { return path.join(dshHome(explicit), SHELL_ROOT); }
function shellDir(explicit) { return path.join(shellRoot(explicit), 'shell'); }
function browserDir(explicit) { return path.join(shellRoot(explicit), 'browser'); }
function repoWikiDir(explicit) { return path.join(shellRoot(explicit), 'repo-wiki'); }
function channelRuntimeDir(explicit) { return path.join(shellRoot(explicit), 'channel-runtime'); }
function channelsDir(explicit) { return path.join(shellRoot(explicit), 'channels'); }
function tokensDir(explicit) { return path.join(shellRoot(explicit), 'tokens'); }
function ghTokenPath(explicit) { return path.join(shellRoot(explicit), 'gh-token'); }
function browserPortPath(explicit) { return path.join(shellRoot(explicit), 'browser-api.port'); }
function shellPortPath(explicit) { return path.join(shellRoot(explicit), 'shell-api.port'); }

/**
 * Legacy $DSH_HOME-root entries -> new shell-root entries. Order matters:
 * browser is moved before browser-dev, so a home that has both keeps the
 * canonical profile and leaves the (stale) dev one alone rather than clobbering.
 */
const LEGACY_MOVES = [
  ['shell', 'shell'],
  ['browser', 'browser'],
  ['browser-dev', 'browser'],
  ['repo-wiki', 'repo-wiki'],
  ['channel-runtime', 'channel-runtime'],
  ['channels', 'channels'],
  ['tokens', 'tokens'],
  ['gh-token', 'gh-token'],
  ['browser-api.port', 'browser-api.port'],
  ['shell-api.port', 'shell-api.port'],
];

/**
 * One-time, idempotent move of legacy $DSH_HOME-root shell data into
 * $DSH_HOME/oh-my-dsh/. Never overwrites an existing target; a failed rename
 * leaves the source in place. Returns the list of "old -> new" names moved
 * (for logging); absent/skipped entries are not reported.
 */
function migrateLegacyLayout(explicit) {
  const home = dshHome(explicit);
  const root = shellRoot(home);
  const moved = [];
  for (const [oldName, newName] of LEGACY_MOVES) {
    const from = path.join(home, oldName);
    try { fs.lstatSync(from); } catch { continue; }
    const to = path.join(root, newName);
    if (fs.existsSync(to)) continue;   // keep the new data, never overwrite
    try {
      fs.mkdirSync(path.dirname(to), { recursive: true });
      fs.renameSync(from, to);
      moved.push(oldName + ' -> ' + newName);
    } catch {
      // cross-device or permissions: keep the source, try again next launch
    }
  }
  return moved;
}

module.exports = {
  SHELL_ROOT,
  dshHome,
  shellRoot,
  shellDir,
  browserDir,
  repoWikiDir,
  channelRuntimeDir,
  channelsDir,
  tokensDir,
  ghTokenPath,
  browserPortPath,
  shellPortPath,
  migrateLegacyLayout,
};
