import { readdirSync, readFileSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { homedir } from 'node:os';

const WS_DIR = '.dsh/workstreams';
const REQ_DIR = '.dsh/requirements';
const TERMINAL = ['merged', 'closed', 'abandoned'];

function parseFm(text) {
  const parts = text.split('---');
  if (parts.length < 3) return {};
  const out = {};
  let cur = null;
  for (const raw of parts[1].split('\n')) {
    const line = raw.trim();
    if (!line) continue;
    const indent = raw.length - raw.trimStart().length;
    const i = line.indexOf(':');
    if (i < 0) continue;
    const k = line.slice(0, i).trim();
    const v = line.slice(i + 1).trim();
    if (indent === 0) {
      if (v === '') { out[k] = {}; cur = k; } else { out[k] = v.split(' ')[0]; cur = null; }
    } else if (cur && typeof out[cur] === 'object') {
      out[cur][k] = v.split(' ')[0];
    }
  }
  return out;
}

function cards(dir) {
  const out = [];
  for (const f of readdirSync(dir)) {
    if (!f.endsWith('.md') || f === 'README.md') continue;
    out.push({ file: f, fm: parseFm(readFileSync(dir + '/' + f, 'utf8')) });
  }
  return out;
}

function repoSlug() {
  if (process.env.DSH_REPO) return process.env.DSH_REPO;
  for (const remote of ['github', 'origin']) {
    try {
      const url = execSync('git remote get-url ' + remote, { encoding: 'utf8' }).trim();
      const i = url.indexOf('github.com');
      if (i < 0) continue;
      let s = url.slice(i + 'github.com'.length);
      while (s.startsWith(':') || s.startsWith('/')) s = s.slice(1);
      if (s.endsWith('.git')) s = s.slice(0, -4);
      if (s.split('/').length >= 2) return s;
    } catch (e) { /* ignore */ }
  }
  return '';
}

function token() {
  if (process.env.GH_TOKEN) return process.env.GH_TOKEN;
  const slug = repoSlug();
  const cands = [];
  if (slug) cands.push(homedir() + '/.dsh/oh-my-dsh/tokens/' + slug.replace('/', '-'));
  cands.push(homedir() + '/.dsh/oh-my-dsh/gh-token');
  for (const p of cands) { try { return readFileSync(p, 'utf8').trim(); } catch (e) { /* ignore */ } }
  return '';
}

async function prStatus(slug, n, tok) {
  const url = 'https://api.github.com/repos/' + slug + '/pulls/' + n;
  const r = await fetch(url, { headers: { Authorization: 'Bearer ' + tok, Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'dsh-derive-status' } });
  if (!r.ok) return 'unknown(HTTP ' + r.status + ')';
  const j = await r.json();
  if (j.merged) return 'merged';
  if (j.state === 'open') return 'open';
  return 'closed';
}

const slug = repoSlug();
const tok = token();
const wss = cards(WS_DIR);
const reqs = cards(REQ_DIR);

for (const w of wss) {
  const fm = w.fm;
  const d = fm.delivery && typeof fm.delivery === 'object' ? fm.delivery : {};
  const pr = d.pr;
  if (fm.abandoned || d.abandoned) w.outcome = 'abandoned';
  else if (fm.stage === 'delivery' && pr) w.outcome = (slug && tok) ? await prStatus(slug, pr, tok) : 'unknown(no token/repo)';
  else w.outcome = '-';
  w.closed = fm.stage === 'delivery' && TERMINAL.includes(w.outcome);
}

const childrenOf = {};
for (const w of wss) {
  const req = w.fm.requirement;
  if (!req) continue;
  (childrenOf[req] = childrenOf[req] || []).push(w);
}
for (const req of reqs) {
  const kids = childrenOf[req.fm.id] || [];
  req.kids = kids.length;
  req.closed = req.fm.state === 'discarded' || (kids.length > 0 && kids.every((k) => k.closed));
}

console.log('repo=' + (slug || '(unknown)') + '  token=' + (tok ? 'yes' : 'no'));
console.log('');
console.log('事项'.padEnd(10) + 'stage'.padEnd(12) + 'pr'.padEnd(6) + 'outcome'.padEnd(22) + 'closed');
for (const w of wss) {
  const d2 = w.fm.delivery && typeof w.fm.delivery === 'object' ? w.fm.delivery : {};
  console.log(String(w.fm.id || w.file).padEnd(10) + String(w.fm.stage || '-').padEnd(12) + String(d2.pr || '-').padEnd(6) + String(w.outcome).padEnd(22) + String(w.closed));
}
console.log('');
console.log('需求'.padEnd(10) + 'state'.padEnd(14) + 'children'.padEnd(10) + 'closed');
for (const req of reqs) {
  console.log(String(req.fm.id || req.file).padEnd(10) + String(req.fm.state || '-').padEnd(14) + String(req.kids).padEnd(10) + String(req.closed));
}