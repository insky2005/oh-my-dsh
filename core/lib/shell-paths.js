'use strict';

/**
 * core/lib/shell-paths.js — the single source of truth for where oh-my-dsh
 * SHELL work data lives, plus the one-time layout migration.
 *
 * Layout (docs/design/shell/storage-layout-refactor.md):
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

/** Human-readable migration/rollback note written into the shell root. */
const ROLLBACK_FILE = 'ROLLBACK.md';

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
function migrateLegacyLayout(explicit, opts = {}) {
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
  writeRollbackGuide(root, moved, opts);
  return moved;
}

function rollbackGuidePath(explicit) {
  return path.join(shellRoot(explicit), ROLLBACK_FILE);
}

/** Plain-text (bilingual) rollback note for a human. */
function renderRollbackGuide({ moved = [], at = new Date().toISOString(), appVersion = '' } = {}) {
  const movedList = moved.length
    ? moved.map((m) => '  - `' + m + '`').join('\n')
    : '  - （无：本机此前已完成迁移）';
  const ver = appVersion ? '`' + appVersion + '`' : '（未知）';
  return [
    '# oh-my-dsh 壳层数据目录迁移 / 回退说明',
    '',
    '生成时间：`' + at + '`　App 版本：' + ver,
    '',
    'oh-my-dsh 已把**壳层自己的工作数据**从 `$DSH_HOME` 根目录收敛到 `$DSH_HOME/oh-my-dsh/` 下',
    '（与 `projects/` 并列）。dsh 自有的 `sessions/`、`storages/`、`settings.yaml` 以及',
    '上游契约路径 `$DSH_HOME/skills/` **未改动**。迁移是同卷 `rename`：数据未复制、未丢失。',
    '',
    '本次实际迁移：',
    movedList,
    '',
    '## 回退到只认旧根目录的旧版 App',
    '',
    '1. 退出 oh-my-dsh；',
    '2. 在终端执行（默认 `$DSH_HOME=~/.dsh`）：',
    '',
    '```bash',
    'H="${DSH_HOME:-$HOME/.dsh}"',
    'for n in shell browser repo-wiki channel-runtime channels tokens gh-token browser-api.port shell-api.port; do',
    '  [ -e "$H/$n" ] && continue            # 目标已存在，跳过（不覆盖）',
    '  [ -e "$H/oh-my-dsh/$n" ] && mv "$H/oh-my-dsh/$n" "$H/$n"',
    'done',
    '# 开发版（DSH_DEV_BUILD）旧路径是 browser-dev 而非 browser：',
    '# [ -e "$H/browser-dev" ] || { [ -e "$H/browser" ] && mv "$H/browser" "$H/browser-dev"; }',
    '```',
    '',
    '3. 重新打开旧版 App。',
    '',
    '说明：反向移动前请先退出 App；重新升级到新版会再次自动归位。此文件由壳层迁移时生成，可安全删除。',
    '',
    '---',
    '',
    '# oh-my-dsh shell data directory migration / rollback',
    '',
    'The shell moved its own work data from the `$DSH_HOME` root into `$DSH_HOME/oh-my-dsh/`',
    '(next to `projects/`). dsh\'s own `sessions/`, `storages/`, `settings.yaml` and the upstream',
    'contract path `$DSH_HOME/skills/` are untouched. It was a same-volume rename: nothing was',
    'copied or lost.',
    '',
    'To roll back to an older app that only reads the root paths: quit oh-my-dsh, run the bash',
    'loop above, then relaunch the older app. Re-upgrading to a newer version moves the data back',
    'automatically. This file is generated by the shell and can be deleted safely.',
    '',
  ].join('\n');
}

/** Write the rollback note; keep the first record when nothing new was moved. */
function writeRollbackGuide(root, moved, opts = {}) {
  const file = path.join(root, ROLLBACK_FILE);
  if (!moved.length && fs.existsSync(file)) return file;
  try {
    fs.mkdirSync(root, { recursive: true });
    fs.writeFileSync(file, renderRollbackGuide({ moved, at: opts.at, appVersion: opts.appVersion }), 'utf8');
  } catch { /* best effort */ }
  return file;
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
  ROLLBACK_FILE,
  rollbackGuidePath,
  renderRollbackGuide,
  writeRollbackGuide,
};
