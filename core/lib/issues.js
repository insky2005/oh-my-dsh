'use strict';

/**
 * core/lib/issues.js — GitHub issues & PR integration (REST API).
 *
 * Provides: issue list parsing/fetching, PR creation, and git-remote → GitHub
 * repo detection. Used by the IssueRunner panel; platform-independent so any
 * shell (macOS today, Windows/Linux later) reuses the same logic. Uses only
 * node built-ins (https/child_process) — zero npm dependencies.
 */

const https = require('node:https');
const { execFileSync } = require('node:child_process');

const API_BASE = 'https://api.github.com';

/** GET a GitHub REST endpoint, returning parsed JSON or null. */
function ghGet(path, token = null, timeoutMs = 15_000) {
  return new Promise((resolve) => {
    const headers = {
      accept: 'application/vnd.github+json',
      'user-agent': 'oh-my-dsh',
    };
    if (token) headers.authorization = `Bearer ${token}`;
    const req = https.get(
      API_BASE + path,
      { headers, timeout: timeoutMs },
      (res) => {
        let body = '';
        res.setEncoding('utf8');
        res.on('data', (c) => { body += c; });
        res.on('end', () => {
          try {
            resolve({ status: res.statusCode, body: JSON.parse(body) });
          } catch {
            resolve({ status: res.statusCode, body: null });
          }
        });
      }
    );
    req.on('timeout', () => { req.destroy(); resolve({ status: 0, body: null }); });
    req.on('error', () => resolve({ status: 0, body: null }));
  });
}

/** POST a GitHub REST endpoint with a JSON body. */
function ghPost(path, body, token = null, timeoutMs = 20_000) {
  return new Promise((resolve) => {
    const payload = JSON.stringify(body);
    const headers = {
      accept: 'application/vnd.github+json',
      'user-agent': 'oh-my-dsh',
      'content-type': 'application/json',
      'content-length': Buffer.byteLength(payload),
    };
    if (token) headers.authorization = `Bearer ${token}`;
    const req = https.request(
      API_BASE + path,
      { method: 'POST', headers, timeout: timeoutMs },
      (res) => {
        let body = '';
        res.setEncoding('utf8');
        res.on('data', (c) => { body += c; });
        res.on('end', () => {
          try {
            resolve({ status: res.statusCode, body: JSON.parse(body) });
          } catch {
            resolve({ status: res.statusCode, body: null });
          }
        });
      }
    );
    req.on('timeout', () => { req.destroy(); resolve({ status: 0, body: null }); });
    req.on('error', () => resolve({ status: 0, body: null }));
    req.end(payload);
  });
}

/**
 * Parse a `/repos/{owner}/{repo}/issues` response into plain issue objects.
 * The issues API also returns pull requests — those carry a `pull_request`
 * key and MUST be filtered out.
 */
function parseIssues(json) {
  if (!Array.isArray(json)) return [];
  return json
    .filter((item) => item && !item.pull_request) // PRs appear in issues API
    .map((item) => ({
      number: item.number,
      title: item.title || '',
      body: item.body || '',
      state: item.state || 'open',
      labels: (item.labels || []).map((l) => (typeof l === 'string' ? l : l.name)).filter(Boolean),
      htmlUrl: item.html_url || `https://github.com/issues/${item.number}`,
      updatedAt: item.updated_at || null,
    }));
}

/** Fetch open issues for a repo (state=open, up to `perPage`). */
async function fetchIssues(owner, repo, token = null, perPage = 50, timeoutMs = 15_000) {
  const path = `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/issues?state=open&per_page=${perPage}`;
  const res = await ghGet(path, token, timeoutMs);
  if (res.status !== 200 || !res.body) return { ok: false, status: res.status, issues: [] };
  return { ok: true, status: res.status, issues: parseIssues(res.body) };
}

/**
 * Create a pull request. Returns { ok, status, pr } where pr has
 * { number, htmlUrl } on success, or { ok, error } with the API error body.
 */
async function createPullRequest(owner, repo, opts, token = null, timeoutMs = 20_000) {
  const { title, head, base = 'main', body = '' } = opts;
  const res = await ghPost(
    `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/pulls`,
    { title, head, base, body },
    token,
    timeoutMs
  );
  if (res.status >= 200 && res.status < 300 && res.body) {
    return {
      ok: true,
      status: res.status,
      pr: { number: res.body.number, htmlUrl: res.body.html_url || '' },
    };
  }
  return { ok: false, status: res.status, error: res.body };
}

/**
 * PATCH a GitHub REST endpoint with a JSON body.
 */
function ghPatch(path, body, token = null, timeoutMs = 20_000) {
  return new Promise((resolve) => {
    const payload = JSON.stringify(body);
    const headers = {
      accept: 'application/vnd.github+json',
      'user-agent': 'oh-my-dsh',
      'content-type': 'application/json',
      'content-length': Buffer.byteLength(payload),
    };
    if (token) headers.authorization = `Bearer ${token}`;
    const req = https.request(
      API_BASE + path,
      { method: 'PATCH', headers, timeout: timeoutMs },
      (res) => {
        let body = '';
        res.setEncoding('utf8');
        res.on('data', (c) => { body += c; });
        res.on('end', () => {
          try {
            resolve({ status: res.statusCode, body: JSON.parse(body) });
          } catch {
            resolve({ status: res.statusCode, body: null });
          }
        });
      }
    );
    req.on('timeout', () => { req.destroy(); resolve({ status: 0, body: null }); });
    req.on('error', () => resolve({ status: 0, body: null }));
    req.end(payload);
  });
}

/**
 * Post a comment on an issue and (optionally) close it. User-initiated —
 * never automatic. Returns { ok, status, error? }.
 */
async function commentAndCloseIssue(owner, repo, issueNumber, { comment, close = true }, token = null, timeoutMs = 20_000) {
  const commentPath = `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/issues/${issueNumber}/comments`;
  const commentRes = await ghPost(commentPath, { body: comment }, token, timeoutMs);
  if (commentRes.status < 200 || commentRes.status >= 300) {
    return { ok: false, status: commentRes.status, error: commentRes.body, step: 'comment' };
  }
  if (!close) return { ok: true, status: commentRes.status, step: 'comment-only' };

  const closePath = `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/issues/${issueNumber}`;
  const closeRes = await ghPatch(closePath, { state: 'closed' }, token, timeoutMs);
  if (closeRes.status < 200 || closeRes.status >= 300) {
    return { ok: false, status: closeRes.status, error: closeRes.body, step: 'close' };
  }
  return { ok: true, status: closeRes.status, step: 'comment+close' };
}

/**
 * Detect whether a directory is a git repo with a GitHub remote, and extract
 * owner/repo. Returns null when not a GitHub remote.
 *
 *   detectGitHubRemote("/path/to/repo")
 *   → { owner: "insky2005", repo: "oh-my-dsh", remote: "git@github.com:insky2005/oh-my-dsh.git" }
 */
function detectGitHubRemote(repoPath) {
  let remotes;
  try {
    remotes = execFileSync('git', ['-C', repoPath, 'remote', '-v'], {
      encoding: 'utf8',
      timeout: 10_000,
    });
  } catch {
    return null; // not a git repo
  }
  // Prefer the remote literally named "github", else the first github.com one.
  const lines = remotes.trim().split('\n').map((l) => l.trim());
  const seen = new Map();
  for (const line of lines) {
    const m = line.match(/^(\S+)\s+(\S+)\s+\(fetch\)$/);
    if (!m) continue;
    seen.set(m[1], m[2]);
  }
  let remoteUrl = seen.get('github') || [...seen.values()].find((u) => /github\.com/i.test(u));
  if (!remoteUrl) return null;

  // github.com URLs come in two shapes:
  //   https://github.com/owner/repo.git
  //   git@github.com:owner/repo.git
  const m = remoteUrl.match(/github\.com[/:]([^/]+)\/([^/.]+)(?:\.git)?$/i);
  if (!m) return null;
  return { owner: m[1], repo: m[2], remote: remoteUrl };
}

module.exports = {
  parseIssues,
  fetchIssues,
  createPullRequest,
  commentAndCloseIssue,
  detectGitHubRemote,
  ghGet,
  ghPost,
  ghPatch,
};
