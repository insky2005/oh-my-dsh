import { readdirSync, readFileSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { homedir } from 'node:os';
import { pathToFileURL } from 'node:url';

const WS_DIR = '.dsh/workstreams';
const REQ_DIR = '.dsh/requirements';

/** Delivery outcomes that make a workstream terminal (store design §5 / §6). */
export const TERMINAL_OUTCOMES = ['merged', 'closed', 'abandoned'];

const HISTORY_HEADING = '## 阶段确认';
// delivery was a stage in older cards; its confirmation still counts as accepted
// (read-compat, same rule as WorkstreamsStageGate.accepted).
const ACCEPTANCE_STAGES = new Set(['acceptance', 'delivery']);

export function parseFm(text) {
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

/** The markdown body after the frontmatter delimiters (line-based, so a --- in
 *  the body does not confuse it). */
export function cardBody(text) {
  const lines = text.split('\n');
  const start = lines.findIndex((line) => line.trim() === '---');
  if (start < 0) return text;
  let end = -1;
  for (let i = start + 1; i < lines.length; i += 1) {
    if (lines[i].trim() === '---') { end = i; break; }
  }
  if (end < 0) return text;
  return lines.slice(end + 1).join('\n');
}

/** The text of a level-2 section (without its heading), or null when absent/empty. */
export function sectionText(body, heading) {
  const lines = body.split('\n');
  const start = lines.findIndex((line) => line.startsWith(heading));
  if (start < 0) return null;
  let end = start + 1;
  while (end < lines.length && !lines[end].startsWith('## ')) end += 1;
  const text = lines.slice(start + 1, end).join('\n').trim();
  return text || null;
}

/**
 * accepted(ws) = the acceptance stage has a confirmation record in
 * "## 阶段确认". Acceptance never advances, so its confirm lives only in the
 * audit trail. Mirrors WorkstreamsStageGate.accepted / RequirementsCore.accepted.
 */
export function accepted(body) {
  const section = sectionText(body, HISTORY_HEADING);
  if (!section) return false;
  for (const raw of section.split('\n')) {
    const line = raw.trim();
    if (!line.startsWith('- ')) continue;
    const fields = line.slice(2).split(' · ');
    if (fields.length < 3) continue;
    if (fields[1].trim() !== 'confirm') continue;
    const stage = fields[2].split('→')[0].trim();
    if (ACCEPTANCE_STAGES.has(stage)) return true;
  }
  return false;
}

/**
 * terminal(ws) / closed(ws) = accepted(ws) ∧ delivery.outcome ∈ TERMINAL_OUTCOMES.
 * Delivery is an OPERATION, not a stage: stage never participates.
 */
export function terminal(acceptedValue, outcome) {
  return acceptedValue === true && TERMINAL_OUTCOMES.includes(outcome);
}

/** closed(req) = discarded, or children ≠ ∅ and every child is terminal. */
export function requirementClosed(state, children) {
  if (state === 'discarded') return true;
  return children.length > 0 && children.every((child) => child.terminal === true);
}

function cards(dir) {
  const out = [];
  for (const f of readdirSync(dir)) {
    if (!f.endsWith('.md') || f === 'README.md') continue;
    const text = readFileSync(dir + '/' + f, 'utf8');
    out.push({ file: f, fm: parseFm(text), body: cardBody(text) });
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

async function main() {
  const slug = repoSlug();
  const tok = token();
  const wss = cards(WS_DIR);
  const reqs = cards(REQ_DIR);

  for (const w of wss) {
    const fm = w.fm;
    const d = fm.delivery && typeof fm.delivery === 'object' ? fm.delivery : {};
    const pr = d.pr;
    if (fm.abandoned || d.abandoned) w.outcome = 'abandoned';
    else if (pr) w.outcome = (slug && tok) ? await prStatus(slug, pr, tok) : 'unknown(no token/repo)';
    else w.outcome = '-';
    w.accepted = accepted(w.body);
    w.terminal = terminal(w.accepted, w.outcome);
    w.closed = w.terminal;
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
    req.closed = requirementClosed(req.fm.state || '', kids);
  }

  console.log('repo=' + (slug || '(unknown)') + '  token=' + (tok ? 'yes' : 'no'));
  console.log('');
  console.log('事项'.padEnd(10) + 'stage'.padEnd(12) + 'accepted'.padEnd(10) + 'pr'.padEnd(6) + 'outcome'.padEnd(22) + 'closed');
  for (const w of wss) {
    const d2 = w.fm.delivery && typeof w.fm.delivery === 'object' ? w.fm.delivery : {};
    console.log(String(w.fm.id || w.file).padEnd(10) + String(w.fm.stage || '-').padEnd(12) + String(w.accepted).padEnd(10) + String(d2.pr || '-').padEnd(6) + String(w.outcome).padEnd(22) + String(w.closed));
  }
  console.log('');
  console.log('需求'.padEnd(10) + '有效状态'.padEnd(14) + 'children'.padEnd(10) + 'closed');
  for (const req of reqs) {
    const raw = req.fm.state || '';
    let eff;
    if (raw === 'discarded') eff = 'discarded';
    else if (req.closed) eff = 'closed';
    else if (req.kids > 0) eff = 'split';
    else eff = raw || 'candidate';
    console.log(String(req.fm.id || req.file).padEnd(10) + eff.padEnd(14) + String(req.kids).padEnd(10) + String(req.closed));
  }
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) await main();
