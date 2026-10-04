#!/usr/bin/env node
// REG-002 「无证据不进设计」规划门禁（只读）
// 判据来源：docs/design/panels/planning-template-design.md §2（四件套）/ §4（判据接口）
// 用法：node .dsh/regression/check-planning-gate.mjs [workstreamsDir]
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const DIR = process.argv[2] || '.dsh/workstreams';
const GATED = new Set(['design', 'task', 'acceptance', 'delivery']);

function frontmatter(text) {
  const m = text.match(/^---\n([\s\S]*?)\n---/);
  if (!m) return {};
  const fm = {};
  for (const line of m[1].split('\n')) {
    const kv = line.match(/^([A-Za-z_][\w]*):\s*(.*)$/);
    if (kv) fm[kv[1]] = kv[2].trim();
  }
  return fm;
}

// 取「## 规划」段正文（到下一个 ## 标题为止）
function planningSection(text) {
  const start = text.search(/^##\s+规划\s*$/m);
  if (start === -1) return null;
  const rest = text.slice(start);
  const rel = rest.slice(1).search(/^##\s/m);
  return rel === -1 ? rest : rest.slice(0, rel + 1);
}

function check(card) {
  const fm = frontmatter(card);
  const stage = fm.stage || '';
  if (!GATED.has(stage)) return { stage, gated: false, missing: [] };

  const missing = [];
  const sec = planningSection(card);
  if (sec === null) {
    return { stage, gated: true, missing: ['规划段（## 规划）'] };
  }
  const s = sec;

  // P1 目标（WHAT）
  if (!/(^|\n)\s*[-*]?\s*目标(\s*[（(]\s*WHAT\s*[)）])?\s*[：:]\s*\S/i.test(s)) {
    missing.push('P1 目标（WHAT）');
  }
  // P2 边界（存在即可；写法自由，见设计 §2）
  if (!/(^|\n)\s*[-*]?\s*边界/m.test(s)) missing.push('P2 边界');
  // P3 验收标准 + AC 编号
  if (!/验收标准/.test(s)) missing.push('P3 验收标准');
  else if (!/AC\s*\d/.test(s)) missing.push('P3 验收标准编号（AC<n>）');
  // P4 阶段裁剪声明
  if (!/阶段裁剪声明/.test(s)) missing.push('P4 阶段裁剪声明');

  return { stage, gated: true, missing };
}

const files = readdirSync(DIR)
  .filter((f) => /^WS-.*\.md$/.test(f))
  .sort();

if (files.length === 0) {
  console.log(`（${DIR} 内无 WS 卡）`);
  process.exit(0);
}

let fail = 0;
let skipped = 0;
for (const f of files) {
  const text = readFileSync(join(DIR, f), 'utf8');
  const { stage, gated, missing } = check(text);
  const id = (frontmatter(text).id) || f.replace(/\.md$/, '');
  if (!gated) {
    skipped++;
    console.log(`SKIP  ${id}  stage=${stage || '(无)'}  （未进设计，不检查）`);
    continue;
  }
  if (missing.length === 0) {
    console.log(`PASS  ${id}  stage=${stage}`);
  } else {
    fail++;
    console.log(`FAIL  ${id}  stage=${stage}  缺失: ${missing.join('、')}`);
  }
}
console.log('');
console.log(`${files.length - skipped - fail}/${files.length - skipped} PASS（跳过 ${skipped}）`);
process.exit(fail ? 1 : 0);
