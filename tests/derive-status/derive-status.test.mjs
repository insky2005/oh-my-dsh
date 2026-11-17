//
//  derive-status.test.mjs — headless tests for .dsh/tools/derive-status.mjs.
//
//  The terminal-state derivation is a pure predicate:
//      accepted(ws) = the acceptance stage has a confirm record in "## 阶段确认"
//      terminal(ws) = accepted(ws) ∧ delivery.outcome ∈ {merged, closed, abandoned}
//      closed(req)  = discarded, or children ≠ ∅ and every child terminal
//
//  Negative cases matter most: merged WITHOUT acceptance confirmation is NOT
//  closed, and confirmed acceptance WITH an open outcome is NOT closed.
//
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  accepted,
  cardBody,
  parseFm,
  requirementClosed,
  sectionText,
  terminal,
  TERMINAL_OUTCOMES,
} from '../../.dsh/tools/derive-status.mjs';

test('frontmatter keeps delivery facts and stage', () => {
  const fm = parseFm(`---
id: WS-001
stage: acceptance
delivery:
  pr: 78
  outcome: merged   # derived cache
---
body
`);
  assert.equal(fm.id, 'WS-001');
  assert.equal(fm.stage, 'acceptance');
  assert.equal(fm.delivery.outcome, 'merged');
});

test('cardBody drops the frontmatter and keeps the audit trail', () => {
  const body = cardBody(`---
id: WS-001
stage: acceptance
---

## 阶段确认

- 2026-10-07 · confirm · acceptance → done · source:panel
`);
  assert.match(body, /## 阶段确认/);
  assert.match(body, /confirm · acceptance/);
});

test('sectionText returns the level-2 section body', () => {
  const body = `## 阶段确认

- a

## 其他

- b`;
  assert.equal(sectionText(body, '## 阶段确认'), '- a');
  assert.equal(sectionText(body, '## 缺失'), null);
});

test('accepted: acceptance confirm is accepted', () => {
  const body = `## 阶段确认

- 2026-10-07 · confirm · acceptance → done · source:panel`;
  assert.equal(accepted(body), true);
});

test('accepted: legacy delivery confirm still counts (read-compat)', () => {
  const body = `## 阶段确认

- 2026-10-03 · confirm · delivery → done`;
  assert.equal(accepted(body), true);
});

test('accepted: an earlier stage confirm is not acceptance', () => {
  const body = `## 阶段确认

- 2026-10-03 · confirm · planning → design`;
  assert.equal(accepted(body), false);
});

test('accepted: a reject is not acceptance', () => {
  const body = `## 阶段确认

- 2026-10-03 · reject · acceptance · 返工`;
  assert.equal(accepted(body), false);
});

test('accepted: no history section is not accepted', () => {
  assert.equal(accepted('## 验收\n\n- 证据：测试绿。'), false);
  assert.equal(accepted(''), false);
});

test('terminal: acceptance NOT confirmed + merged outcome is NOT closed', () => {
  assert.equal(terminal(false, 'merged'), false);
});

test('terminal: acceptance confirmed + open outcome is NOT closed', () => {
  assert.equal(terminal(true, 'open'), false);
  assert.equal(terminal(true, 'unknown(HTTP 500)'), false);
  assert.equal(terminal(true, '-'), false);
});

test('terminal: acceptance confirmed + every terminal outcome is closed', () => {
  for (const outcome of TERMINAL_OUTCOMES) {
    assert.equal(terminal(true, outcome), true, outcome);
  }
});

test('requirementClosed: every child must be terminal', () => {
  assert.equal(requirementClosed('', [{ terminal: true }, { terminal: true }]), true);
  assert.equal(requirementClosed('', [{ terminal: true }, { terminal: false }]), false);
  assert.equal(requirementClosed('', []), false);
  assert.equal(requirementClosed('discarded', []), true);
  assert.equal(requirementClosed('evaluating', [{ terminal: false }]), false);
});
