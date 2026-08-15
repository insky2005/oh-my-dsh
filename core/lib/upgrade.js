'use strict';

/**
 * core/lib/upgrade.js — dsh version compare, registry config, latest-version
 * and upgrade-command builders. Ported from src/main.swift (VersionKit /
 * RegistryConfig / DSHUpdater) so every platform shares the same upgrade
 * semantics. The actual `npm install` still runs with the platform's node.
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
 * bundled dsh tree (mirror of DSHUpdater.upgrade argv).
 */
function buildUpgradeArgs(npmCli, registry, spec = '@deepseek-ai/dsh@latest') {
  return [npmCli, 'install', '--loglevel=error', '--no-audit', '--no-fund', '--registry', registry, spec];
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
};
