import { readFileSync } from 'node:fs';

const doc = readFileSync('docs/research/ai-native-workflow-architecture.md', 'utf8');
const readme = readFileSync('docs/README.md', 'utf8');
const lines = doc.split('\n');

const heads = lines.filter((l) => l.startsWith('### 4.')).map((l) => l.slice(6, 7)).join('');
const refOK = doc.split('§4.').slice(1).every((s) => '1234567'.includes(s[0]));

const checks = [
  ['AC1 想法不再作为事项阶段', !doc.includes('│ 想法')],
  ['AC2 事项首阶段=规划', doc.includes('│ 规划  │──►│ 设计  │')],
  ['AC3 需求 1..N / 事项 0..1 需求', doc.includes('可拆出 1..N 个事项') && doc.includes('**0..1 个需求**')],
  ['AC4 拆解=agent+人工确认', doc.includes('agent 出第一版拆分方案') && doc.includes('**人工确认**')],
  ['AC5 规划证据', doc.includes('验收标准 + 被裁剪阶段的声明')],
  ['AC6 需求状态派生', doc.includes('聚合视图') && doc.includes('不是权威状态')],
  ['AC7 索引同步', readme.includes('需求池 → 拆解 → 事项的两层状态图')],
  ['AC8 无旧标题 4.2 设计阶段', !doc.includes('### 4.2 设计阶段')],
  ['AC9 §4 编号连续', heads === '1234567'],
  ['AC10 §4.x 引用有效', refOK],
  ['AC11 原则 8 = 点记录', doc.includes('**裁决是点记录，不是实时谓词**')],
  ['AC12 终态是派生谓词', doc.includes('**终态是派生的，不是迁移**') && doc.includes('派生谓词，不是 stage')],
];

let fail = 0;
for (const [name, ok] of checks) {
  if (!ok) fail++;
  console.log((ok ? 'PASS' : 'FAIL') + '  ' + name);
}
console.log('');
console.log((checks.length - fail) + '/' + checks.length);
process.exit(fail ? 1 : 0);