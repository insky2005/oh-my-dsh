'use strict';

/**
 * core/lib/upgrade.js — dsh version compare, registry config, stepwise
 * latest-version/upgrade-command builders. Ported from src/main.swift
 * (VersionKit / RegistryConfig / DSHUpdater) so every platform shares the same
 * upgrade semantics. The actual `npm install` still runs with the platform's
 * node.
 *
 * Upgrades are STEPWISE: a single upgrade only advances to the next release
 * candidate (stable or rc) strictly newer than the installed version — it
 * never jumps straight to `dist-tags.latest`. See nextStepTarget().
 */

const https = require('node:https');
const http = require('node:http');

/** Mirror of VersionKit.compare: -1/0/1 for a vs b. Handles x.y.z and x.y.z-rc.N. */
function compareVersions(a, b) {
  const numeric = (s) => (s.split('-')[0] || s).split('.').map((x) => parseInt(x, 10) || 0);
  const pa = numeric(a), pb = numeric(b);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const x = i < pa.length ? pa[i] : 0;
    const y = i < pb.length ? pb[i] : 0;
    if (x !== y) return x < y ? -1 : 1;
  }
  const preA = a.includes('-'), preB = b.includes('-');
  if (preA !== preB) return preA ? -1 : 1;
  if (preA) {
    const ra = a.split('-')[1], rb = b.split('-')[1];
    const na = parseInt(ra, 10) || 0, nb = parseInt(rb, 10) || 0;
    if (na !== nb) return na < nb ? -1 : 1;
    if (ra !== rb) return ra < rb ? -1 : 1;
  }
  return 0;
}

/** Strip trailing slashes (mirror of RegistryConfig.normalize). */
function normalizeRegistry(url) {
  return (url || '').trim().replace(/\/+$/, '');
}

const DEFAULT_REGISTRY = 'https://registry.npmmirror.com';

/**
 * Resolve the registry: explicit env > saved > China mirror.
 * Pass a `saved` string (e.g. from user defaults) when the caller has one.
 */
function resolveRegistry(env = {}, saved = null) {
  if (env.DSH_REGISTRY) return normalizeRegistry(env.DSH_REGISTRY);
  if (saved) return normalizeRegistry(saved);
  return DEFAULT_REGISTRY;
}

/** GET a URL, returning the raw body string or null (mirror of HTTP.get). */
function httpGet(urlString, timeoutMs = 15_000) {
  return new Promise((resolve) => {
    let lib = http;
    if (urlString.startsWith('https:')) lib = https;
    const req = lib.get(urlString, { timeout: timeoutMs }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (c) => { body += c; });
      res.on('end', () => resolve(body));
    });
    req.on('timeout', () => { req.destroy(); resolve(null); });
    req.on('error', () => resolve(null));
  });
}

/** Fetch the `dist-tags.latest` version of @deepseek-ai/dsh from a registry. */
async function latestVersion(registry, pkg = '@deepseek-ai/dsh') {
  const body = await httpGet(`${registry}/${pkg}`, 15_000);
  if (!body) return null;
  try {
    const json = JSON.parse(body);
    return (json['dist-tags'] && json['dist-tags'].latest) || null;
  } catch {
    return null;
  }
}

/** Read the installed version from a package.json next to a dsh bin.js. */
function installedVersion(dshBin) {
  const fs = require('node:fs');
  const path = require('node:path');
  const pkg = path.join(path.dirname(path.dirname(dshBin)), 'package.json');
  try {
    return JSON.parse(fs.readFileSync(pkg, 'utf8')).version || null;
  } catch {
    return null;
  }
}

/**
 * Build the `node <npm-cli> install …` argv for an in-place upgrade of the
 * bundled dsh tree (mirror of DSHUpdater.upgrade argv). Retained for backward
 * parity; prefer buildPrefetchArgs/buildApplyArgs for stepwise upgrades.
 */
function buildUpgradeArgs(npmCli, registry, spec = '@deepseek-ai/dsh@latest') {
  return [npmCli, 'install', '--loglevel=error', '--no-audit', '--no-fund', '--registry', registry, spec];
}

/**
 * Robust semver parse: { core: [major, minor, patch], pre: [identifiers] }.
 * Handles x.y.z and arbitrary prerelease identifiers (rc.N, alpha.N, …).
 */
function parseSemver(v) {
  const s = String(v || '');
  const dash = s.indexOf('-');
  const coreStr = dash < 0 ? s : s.slice(0, dash);
  const core = coreStr.split('.').map((x) => parseInt(x, 10) || 0);
  while (core.length < 3) core.push(0);
  let pre = [];
  if (dash >= 0) pre = s.slice(dash + 1).split('.');
  return { core, pre };
}

/** Full semver compare (numeric core + prerelease precedence). -1/0/1. */
function compareSemver(a, b) {
  const pa = parseSemver(a), pb = parseSemver(b);
  for (let i = 0; i < 3; i++) {
    if (pa.core[i] !== pb.core[i]) return pa.core[i] < pb.core[i] ? -1 : 1;
  }
  const x = pa.pre, y = pb.pre;
  if (x.length === 0 && y.length === 0) return 0;
  if (x.length === 0) return 1; // stable sorts after any prerelease
  if (y.length === 0) return -1;
  const n = Math.max(x.length, y.length);
  for (let i = 0; i < n; i++) {
    if (i >= x.length) return -1; // shorter prefix sorts lower
    if (i >= y.length) return 1;
    const xi = /^\d+$/.test(x[i]), yi = /^\d+$/.test(y[i]);
    let c;
    if (xi && yi) {
      const nx = parseInt(x[i], 10), ny = parseInt(y[i], 10);
      c = nx === ny ? 0 : nx < ny ? -1 : 1;
    } else if (xi) c = -1; // numeric identifier < alphanumeric
    else if (yi) c = 1;
    else c = x[i] < y[i] ? -1 : x[i] > y[i] ? 1 : 0;
    if (c !== 0) return c;
  }
  return 0;
}

/** True when a published version is an upgrade candidate: stable or `rc.*`. */
function isReleaseCandidate(v) {
  const dash = String(v || '').indexOf('-');
  if (dash < 0) return true; // stable
  const first = String(v).slice(dash + 1).split('.')[0];
  return first === 'rc';
}

/**
 * Pick the NEXT step target for a stepwise upgrade: among published versions
 * that are release candidates (stable / rc) and strictly newer than `current`,
 * return the immediately-next one by semver order (never jump to the latest).
 * Returns null when nothing newer is available.
 */
function nextStepTarget(current, publishedVersions) {
  const cands = (publishedVersions || [])
    .filter((v) => isReleaseCandidate(v) && compareSemver(v, current) > 0);
  if (cands.length === 0) return null;
  cands.sort(compareSemver);
  return cands[0];
}

/** `@deepseek-ai/dsh@<version>` pinned spec for a stepwise upgrade. */
function pinSpec(version) {
  return '@deepseek-ai/dsh@' + version;
}

/** argv warming the shared npm cache (download phase) — runs in a staging dir. */
function buildPrefetchArgs(npmCli, registry, version) {
  return [npmCli, 'install', '--loglevel=error', '--no-audit', '--no-fund',
          '--registry', registry, pinSpec(version)];
}

/** argv applying a pinned version in place, served from the warm npm cache. */
function buildApplyArgs(npmCli, registry, version) {
  return [npmCli, 'install', '--loglevel=error', '--no-audit', '--no-fund',
          '--prefer-offline', '--registry', registry, pinSpec(version)];
}

module.exports = {
  compareVersions,
  normalizeRegistry,
  resolveRegistry,
  DEFAULT_REGISTRY,
  httpGet,
  latestVersion,
  installedVersion,
  buildUpgradeArgs,
  parseSemver,
  compareSemver,
  isReleaseCandidate,
  nextStepTarget,
  pinSpec,
  buildPrefetchArgs,
  buildApplyArgs,
};
