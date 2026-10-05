//
//  model-tests.swift — headless tests for RequirementsCore (no AppKit, no window).
//  Built by tests/requirements-panel/run.sh (top-level code must live in main.swift).
//

import Foundation

var checks = 0
var failures = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { failures += 1; print("  FAIL " + label) }
}

func eq<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected { failures += 1; print("  FAIL " + label + ": got " + String(describing: actual) + ", want " + String(describing: expected)) }
}

func section(_ name: String) { print("--- " + name + " ---") }

/// Assert a throwing call fails with exactly this PoolError.
func expectError<T>(_ label: String, _ expected: PoolError, _ body: () throws -> T) {
    checks += 1
    do {
        _ = try body()
        failures += 1
        print("  FAIL " + label + ": no error thrown")
    } catch let error as PoolError {
        if error != expected { failures += 1; print("  FAIL " + label + ": got " + String(describing: error)) }
    } catch {
        failures += 1
        print("  FAIL " + label + ": unexpected error " + String(describing: error))
    }
}

func tempWorkspace(_ tag: String) -> String {
    let path = NSTemporaryDirectory() + "reqpool-" + tag + "-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

func write(_ path: String, _ text: String) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? text.write(toFile: path, atomically: true, encoding: .utf8)
}

func files(in dir: String) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
}

func requirementFixture(_ id: String, state: String?, children: Bool = false) -> String {
    var text = "---\nid: " + id + "\ntitle: " + id + " 需求\n"
    if let state = state { text += "state: " + state + "\n" }
    text += "source: test\ncreated: 2026-10-03\nupdated: 2026-10-03\n---\n\n## 诉求\n\n测试诉求。\n"
    return text
}

func workstreamFixture(_ id: String, requirement: String, stage: String, outcome: String?) -> String {
    var text = "---\nid: " + id + "\ntitle: " + id + " 事项\nrequirement: " + requirement + "\nstage: " + stage + "\n"
    if let outcome = outcome { text += "delivery:\n  outcome: " + outcome + "\n" }
    text += "created: 2026-10-03\nupdated: 2026-10-03\n---\n\n# " + id + "\n"
    return text
}

// MARK: - Frontmatter parsing

section("frontmatter")
eq(RequirementsCore.parseScalar("\"quoted\""), "quoted", "double quotes stripped")
eq(RequirementsCore.parseScalar("'single'"), "single", "single quotes stripped")
eq(RequirementsCore.parseInlineList("[a, b, c]"), ["a", "b", "c"], "inline list")
eq(RequirementsCore.parseInlineList("not a list"), nil, "non-list returns nil")

let parsed = RequirementsCore.parseCard("""
---
id: REQ-002
title: 需求 & 事项
workstreams: [WS-001, WS-002]
requirement: REQ-002
covered:
  - docs/a.md
  - docs/b.md
delivery:
  pr: 88
  outcome: merged
---

## 诉求

正文。
""")
eq(RequirementsCore.string(parsed.fm, "id"), "REQ-002", "id parsed")
eq(RequirementsCore.list(parsed.fm, "workstreams"), ["WS-001", "WS-002"], "inline list parsed")
eq(RequirementsCore.list(parsed.fm, "covered"), ["docs/a.md", "docs/b.md"], "indented list parsed")
eq(RequirementsCore.nested(parsed.fm, "delivery", "outcome"), "merged", "nested delivery.outcome parsed")
eq(RequirementsCore.string(parsed.fm, "title"), "需求 & 事项", "value keeps full text (no token truncation)")
check(parsed.body.contains("## 诉求"), "body kept after frontmatter")

let malformed = RequirementsCore.parseCard("no frontmatter here")
eq(malformed.fm.isEmpty, true, "missing frontmatter yields empty map")

// MARK: - Derivation

section("derivation")
let openChild = WorkstreamSummary(id: "WS-001", title: "a", requirement: "REQ-001", stage: "design", outcome: nil, path: "")
let closedChild = WorkstreamSummary(id: "WS-002", title: "b", requirement: "REQ-001", stage: "delivery", outcome: "merged", path: "")
let abandonedChild = WorkstreamSummary(id: "WS-003", title: "c", requirement: "REQ-001", stage: "delivery", outcome: "abandoned", path: "")

check(RequirementsCore.isTerminal(closedChild), "delivery+merged is terminal")
check(RequirementsCore.isTerminal(abandonedChild), "delivery+abandoned is terminal")
check(!RequirementsCore.isTerminal(openChild), "design is not terminal")
check(!RequirementsCore.isTerminal(WorkstreamSummary(id: "WS-004", title: "d", requirement: nil, stage: "delivery", outcome: "open", path: "")), "delivery+open is not terminal")

eq(RequirementsCore.effectiveState(state: nil, children: []), .candidate, "no state, no children -> candidate")
eq(RequirementsCore.effectiveState(state: "evaluating", children: []), .evaluating, "manual evaluating preserved")
eq(RequirementsCore.effectiveState(state: "suspended", children: []), .suspended, "manual suspended preserved")
eq(RequirementsCore.effectiveState(state: nil, children: [openChild]), .split, "children with an open one -> split")
eq(RequirementsCore.effectiveState(state: nil, children: [closedChild, abandonedChild]), .closed, "all terminal -> closed")
eq(RequirementsCore.effectiveState(state: "discarded", children: [closedChild]), .discarded, "discarded wins over closed")
eq(RequirementsCore.effectiveState(state: nil, children: []), .candidate, "empty children never closed")

// MARK: - load()

section("load")
let ws1 = tempWorkspace("load")
write(ws1 + "/.dsh/requirements/REQ-001.md", requirementFixture("REQ-001", state: nil))
write(ws1 + "/.dsh/requirements/REQ-002.md", requirementFixture("REQ-002", state: "discarded"))
write(ws1 + "/.dsh/requirements/README.md", "# not a card")
write(ws1 + "/.dsh/workstreams/WS-001.md", workstreamFixture("WS-001", requirement: "REQ-001", stage: "design", outcome: nil))
write(ws1 + "/.dsh/workstreams/WS-002.md", workstreamFixture("WS-002", requirement: "REQ-001", stage: "delivery", outcome: "merged"))

let snap = RequirementsCore.load(workspace: ws1)
eq(snap.dshExists, true, "dsh exists")
eq(snap.requirements.count, 2, "two requirement cards (README skipped)")
eq(snap.workstreams.count, 2, "two workstream cards")
eq(snap.requirements[0].requirement.id, "REQ-001", "sorted by id")
eq(snap.requirements[0].children.count, 2, "children aggregated by WS.requirement")
eq(snap.requirements[0].effectiveState, .split, "one open child -> split")
eq(snap.requirements[1].effectiveState, .discarded, "discarded card")

let missing = RequirementsCore.load(workspace: "/definitely/not/here")
eq(missing.dshExists, false, "missing workspace -> dshExists false")
eq(missing.requirements.count, 0, "missing workspace -> no requirements")

// MARK: - createRequirement / setState

section("writes")
let ws2 = tempWorkspace("writes")
write(ws2 + "/.dsh/requirements/REQ-007.md", requirementFixture("REQ-007", state: nil))
let created = try! RequirementsCore.createRequirement(workspace: ws2, title: "  新需求  ", body: "", source: nil, today: "2026-10-04")
eq(created.id, "REQ-000008", "next id after REQ-007 (six-digit)")
eq(created.title, "新需求", "title trimmed")
eq(created.state, "candidate", "new requirement is a candidate")
check(FileManager.default.fileExists(atPath: RequirementsCore.requirementPath(ws2, id: "REQ-000008")), "card written")
check(!files(in: RequirementsCore.requirementsDir(ws2)).contains(where: { $0.contains(".tmp-") }), "no temp files left behind")
check(created.body.contains("新需求"), "empty body falls back to the title")

expectError("empty title throws missingTitle", .missingTitle) {
    _ = try RequirementsCore.createRequirement(workspace: ws2, title: "   ", body: nil, source: nil, today: "2026-10-04")
}

let evaluating = try! RequirementsCore.setState(workspace: ws2, id: "REQ-000008", state: "evaluating", today: "2026-10-05")
eq(evaluating.state, "evaluating", "state updated")
eq(evaluating.updated, "2026-10-05", "updated date bumped")
expectError("derived state rejected on write", .unknownState("split")) {
    _ = try RequirementsCore.setState(workspace: ws2, id: "REQ-000008", state: "split", today: "2026-10-05")
}
expectError("unknown requirement throws", .unknownRequirement("REQ-999")) {
    _ = try RequirementsCore.setState(workspace: ws2, id: "REQ-999", state: "candidate", today: "2026-10-05")
}

// MARK: - propose / confirm / reject

section("breakdown")
let ws3 = tempWorkspace("breakdown")
let req3 = try! RequirementsCore.createRequirement(workspace: ws3, title: "拆分我", body: "把这件事拆开。", source: "test", today: "2026-10-04")
eq(req3.id, "REQ-000001", "first requirement is six-digit")
let req3Id = req3.id
let items = [BreakdownItem(title: "事项 A", boundary: "只做 A", dependsOn: []),
             BreakdownItem(title: "事项 B", boundary: "依赖 A", dependsOn: ["事项 A"])]
let proposed = try! RequirementsCore.propose(workspace: ws3, id: req3Id, items: items, today: "2026-10-04")
eq(proposed.body.contains("json proposal"), true, "proposal fence written")
eq(RequirementsCore.parseProposal(proposed.body)?.count, 2, "proposal round-trips")
eq(RequirementsCore.parseProposal(proposed.body)?[1].dependsOn, ["事项 A"], "dependsOn round-trips")

// Negative gate: confirm without a proposal must fail (design §10 "门要能自证").
let ws4 = tempWorkspace("nogate")
let req4 = try! RequirementsCore.createRequirement(workspace: ws4, title: "无提案", body: nil, source: nil, today: "2026-10-04")
expectError("confirm without proposal -> noProposal", .noProposal) {
    _ = try RequirementsCore.confirm(workspace: ws4, id: req4.id, today: "2026-10-04")
}

let createdWs = try! RequirementsCore.confirm(workspace: ws3, id: req3Id, today: "2026-10-04")
eq(createdWs.count, 2, "confirm creates one WS per item")
eq(createdWs[0].id, "WS-000001", "first WS id is six-digit")
eq(createdWs[1].id, "WS-000002", "second WS id is six-digit")
eq(createdWs[0].requirement, req3Id, "WS points back at the requirement")
eq(createdWs[0].stage, "planning", "new WS starts in planning")
check(FileManager.default.fileExists(atPath: RequirementsCore.workstreamPath(ws3, id: "WS-000002")), "second WS written")

let afterConfirm = RequirementsCore.load(workspace: ws3)
eq(afterConfirm.requirements[0].proposal == nil, true, "proposal cleared after confirm")
eq(afterConfirm.requirements[0].effectiveState, .split, "confirmed requirement shows split")
eq(afterConfirm.requirements[0].children.count, 2, "children visible after confirm")
let reqTextAfterConfirm = RequirementsCore.readText(RequirementsCore.requirementPath(ws3, id: req3Id)) ?? ""
check(reqTextAfterConfirm.contains("workstreams: [WS-000001, WS-000002]"),
      "REQ frontmatter links the created workstreams")
expectError("confirm is not repeatable", .noProposal) {
    _ = try RequirementsCore.confirm(workspace: ws3, id: req3Id, today: "2026-10-04")
}
check(!files(in: RequirementsCore.workstreamsDir(ws3)).contains(where: { $0.contains(".tmp-") }), "no temp WS files")

// Standard confirmed table: 标识 | 事项 | 边界 | 依赖 (no 状态 persisted).
let confirmedRows = RequirementsCore.parseConfirmed(reqTextAfterConfirm)
eq(confirmedRows.count, 2, "parseConfirmed reads both rows")
eq(confirmedRows[0].id, "WS-000001", "confirmed row carries the WS id")
eq(confirmedRows[0].title, "事项 A", "confirmed row title")
eq(confirmedRows[0].boundary, "只做 A", "confirmed row boundary")
eq(confirmedRows[1].dependsOn, ["WS-000001"], "dependsOn mapped to the WS id")
check(reqTextAfterConfirm.contains("| 标识 | 事项 | 边界 | 依赖 |"), "standard header written")
check(!reqTextAfterConfirm.contains("| 状态 |"), "no status column persisted")

// A broken-down requirement is frozen (edit is refused at the model layer).
check(RequirementsCore.hasWorkstreams(workspace: ws3, id: req3Id), "confirmed requirement reports workstreams")
expectError("update after breakdown -> breakdownLocked", .breakdownLocked(req3Id)) {
    _ = try RequirementsCore.updateRequirement(workspace: ws3, id: req3Id, title: "改不动", body: "x", today: "2026-10-06")
}

// reject
_ = try! RequirementsCore.propose(workspace: ws3, id: req3Id, items: items, today: "2026-10-04")
let rejected = try! RequirementsCore.reject(workspace: ws3, id: req3Id, today: "2026-10-04")
eq(RequirementsCore.parseProposal(rejected.body), nil, "reject clears the proposal")
expectError("reject without proposal -> noProposal", .noProposal) {
    _ = try RequirementsCore.reject(workspace: ws3, id: req3Id, today: "2026-10-04")
}

check(RequirementsCore.breakdownPrompt("REQ-001", title: "想法").contains("/api/requirements/breakdown/propose"), "prompt points at the propose endpoint")
check(RequirementsCore.breakdownPrompt("REQ-042", title: "想法").contains("REQ-042"), "prompt names the requirement")
check(RequirementsCore.breakdownPrompt("REQ-042", title: "想法").contains("@.dsh/requirements/REQ-042.md"), "prompt references the card path")
check(RequirementsCore.breakdownPrompt("REQ-042", title: "想法").contains("等待用户确认『待确认提案』"), "prompt waits for the human to confirm")
let rejectPrompt = RequirementsCore.rejectPrompt("REQ-042", title: "想法", reason: "粒度太粗")
check(rejectPrompt.contains("REQ-042「想法」@.dsh/requirements/REQ-042.md，需求拆解已驳回。"), "reject prompt header")
check(rejectPrompt.contains("驳回原因：粒度太粗"), "reject prompt carries the reason")
check(rejectPrompt.contains("重新提交待确认提案"), "reject prompt asks to re-propose")
check(rejectPrompt.contains("等待用户确认『待确认提案』"), "reject prompt waits for confirmation")
let rejectNoReason = RequirementsCore.rejectPrompt("REQ-042", title: "想法", reason: nil)
check(!rejectNoReason.contains("驳回原因"), "no reason → no reason line")
check(rejectNoReason.contains("请修改拆解方案。"), "no reason still asks to revise")
check(RequirementsCore.refinementPrompt("REQ-042", title: "想法").contains("REQ-042"), "refinement prompt names the requirement")
check(RequirementsCore.refinementPrompt("REQ-042", title: "想法").contains("/api/requirements/update"), "refinement prompt points at the update endpoint")
check(RequirementsCore.refinementPrompt("REQ-042", title: "想法").contains("不要修改代码"), "refinement prompt keeps the read-only rule")
check(RequirementsCore.refinementPrompt("REQ-042", title: "想法").contains("@.dsh/requirements/REQ-042.md"), "refinement prompt references the card path")
check(RequirementsCore.refinementPrompt("REQ-042", title: "想法").contains("等待用户进行「需求拆解」"), "refinement prompt waits for the human breakdown")

// MARK: - confirmed table parsing (legacy tolerance)

section("confirmed parsing")
let legacyThreeCol = """
## 拆解（agent 提案 / 人工确认）

| 事项 | 边界 | 状态 |
|---|---|---|
| WS-001 架构模型修订 | 只改架构文档 + 索引 | 已交付（PR #78 merged） |
| （候选）需求池面板设计 | 独立面板 | 未确认 |
"""
let legacyRows = RequirementsCore.parseConfirmed(legacyThreeCol)
eq(legacyRows.count, 2, "3-column legacy table parses")
eq(legacyRows[0].id, "WS-001", "legacy id split out of the 事项 cell")
eq(legacyRows[0].title, "架构模型修订", "legacy title keeps only the text")
eq(legacyRows[1].id, nil, "candidate row has no id")
eq(legacyRows[1].title, "（候选）需求池面板设计", "candidate title kept whole")

let legacyFourCol = """
## 拆解（agent 提案 / 人工确认）
| 事项 | 边界 | 状态 | 依赖 |
|---|---|---|---|
| WS-007 规划模板 | 只改设计文档 | 规划中 | — |
| WS-008 门禁 | 只加 regression | 规划中 | WS-007 之后 |
"""
let fourRows = RequirementsCore.parseConfirmed(legacyFourCol)
eq(fourRows.count, 2, "4-column legacy table parses")
eq(fourRows[1].dependsOn, ["WS-007"], "prose deps extract the WS id")
eq(RequirementsCore.parseConfirmed("## 诉求\n\n没有表。\n").count, 0, "no table -> empty")
eq(RequirementsCore.parseConfirmed("").count, 0, "empty body -> empty")

// MARK: - WorkstreamDisplay merge (REQ content + WS status)

section("workstream merge")
let mergeConfirmed = [ConfirmedItem(id: "WS-001", title: "甲", boundary: "边界甲", dependsOn: []),
                      ConfirmedItem(id: "WS-999", title: "缺失", boundary: "", dependsOn: []),
                      ConfirmedItem(id: nil, title: "候选", boundary: "候选边界", dependsOn: [])]
let mergeChildren = [WorkstreamSummary(id: "WS-001", title: "甲卡", requirement: "REQ-001", stage: "design", outcome: nil, path: "/ws/1"),
                     WorkstreamSummary(id: "WS-002", title: "表外", requirement: "REQ-001", stage: "delivery", outcome: "merged", path: "/ws/2")]
let merged = WorkstreamDisplay.merged(confirmed: mergeConfirmed, children: mergeChildren)
eq(merged.count, 4, "confirmed rows lead, unmatched WS children appended")
eq(merged[0].id, "WS-001", "first row id")
eq(merged[0].stage, "design", "status joined from the WS card")
eq(merged[0].boundary, "边界甲", "boundary from REQ")
eq(merged[0].missingCard, false, "matched row is not missing")
eq(merged[1].missingCard, true, "confirmed id without a WS card is flagged")
eq(merged[2].id, nil, "candidate row keeps no id")
eq(merged[2].stage, nil, "candidate row has no status")
eq(merged[3].id, "WS-002", "WS child absent from the table appended")
eq(merged[3].notInPlan, true, "tableless WS child is flagged")

let fallback = WorkstreamDisplay.merged(confirmed: [], children: mergeChildren)
eq(fallback.count, 2, "empty table falls back to all children")
eq(fallback.allSatisfy { !$0.notInPlan && !$0.missingCard }, true, "fallback carries no flags")

// MARK: - composer + help view models (RequirementsUI.swift)

section("composer")
let emptyComposer = RequirementComposerModel.build()
eq(emptyComposer.canSubmit, false, "empty composer cannot submit")
eq(emptyComposer.title, "", "empty composer has no title")
eq(emptyComposer.isPristine, true, "empty composer is pristine")

let typedComposer = RequirementComposerModel.build().typed(content: "  标题一  \n第二行\n第三行")
eq(typedComposer.title, "标题一", "first line (trimmed) is the title")
eq(typedComposer.body, "第二行\n第三行", "remaining lines are the statement")
eq(typedComposer.canSubmit, true, "a title enables submit")
eq(RequirementComposerModel.build().typed(content: "只有一行").body, "只有一行", "a single line is both title and statement")

let blank = RequirementComposerModel.build().typed(content: "   ")
eq(blank.problemKey, nil, "no problem before a submit attempt")
eq(blank.attemptedSubmit().problemKey, "requirements.newProblem", "blank title reports the problem after submit")
eq(emptyComposer.attemptedSubmit().problemKey, "requirements.newProblem", "pristine composer reports the problem after submit")

section("help")
let helpSpec = RequirementsHelpSpec.build()
eq(helpSpec.sections.count, 2, "help has two sections (create / breakdown)")
eq(helpSpec.sections[0].lineKeys, ["requirements.help.create.panel", "requirements.help.create.chat"], "create covers panel + conversation")
eq(helpSpec.sections[1].lineKeys, ["requirements.help.breakdown.panel", "requirements.help.breakdown.chat"], "breakdown covers panel + conversation")
eq(helpSpec.titleKey, "requirements.help.title", "help title key")
eq(helpSpec.introKey, "requirements.help.intro", "help intro key")
check(helpSpec.sections.allSatisfy {
    $0.headingKey.hasPrefix("requirements.help.") && $0.lineKeys.allSatisfy { $0.hasPrefix("requirements.help.") }
}, "every help key stays namespaced under requirements.help.")

// MARK: - statement + updateRequirement (content preview / editing)

section("statement")
let statementFixture = """
---
id: REQ-003
title: T
---
## 诉求

这是一段诉求。
"""
let parsedStatement = RequirementsCore.parseCard(statementFixture)
eq(RequirementsCore.statement(from: parsedStatement.body), "这是一段诉求。",
   "statement reads the 诉求 section")
eq(RequirementsCore.statement(from: "\n# Heading\nplain text\n"), "plain text",
   "statement falls back to the heading-stripped body")

section("update")
let ws5 = tempWorkspace("update")
let req5 = try! RequirementsCore.createRequirement(workspace: ws5, title: "旧标题", body: "旧诉求", source: nil, today: "2026-10-04")
let req5Id = req5.id
let edited = try! RequirementsCore.updateRequirement(workspace: ws5, id: req5Id, title: "新标题", body: "新诉求", today: "2026-10-05")
eq(edited.title, "新标题", "update: title changed")
eq(edited.statement, "新诉求", "update: statement changed")
eq(edited.updated, "2026-10-05", "update: updated bumped")
_ = try! RequirementsCore.setState(workspace: ws5, id: req5Id, state: "evaluating", today: "2026-10-05")
_ = try! RequirementsCore.propose(workspace: ws5, id: req5Id,
                                  items: [BreakdownItem(title: "A", boundary: "b", dependsOn: [])],
                                  today: "2026-10-05")
let edited2 = try! RequirementsCore.updateRequirement(workspace: ws5, id: req5Id, title: "再改", body: "新诉求2", today: "2026-10-06")
eq(edited2.state, "evaluating", "update: state untouched")
eq(edited2.updated, "2026-10-06", "update: updated bumped again")
eq(RequirementsCore.parseProposal(edited2.body)?.count, 1, "update: pending proposal untouched")
check(!RequirementsCore.hasWorkstreams(workspace: ws5, id: req5Id), "proposal-only requirement is not locked")
expectError("update: empty title refused", .missingTitle) {
    _ = try RequirementsCore.updateRequirement(workspace: ws5, id: req5Id, title: "  ", body: nil, today: "2026-10-06")
}
expectError("update: unknown requirement refused", .unknownRequirement("REQ-999")) {
    _ = try RequirementsCore.updateRequirement(workspace: ws5, id: "REQ-999", title: "x", body: nil, today: "2026-10-06")
}

section("session binding")
let ws6 = tempWorkspace("session")
let withSession = try! RequirementsCore.createRequirement(workspace: ws6, title: "会话来源", body: "x", source: nil, today: "2026-10-04", session: "s-abc")
eq(withSession.session, "s-abc", "created card carries the source session")
let reloaded = RequirementsCore.load(workspace: ws6)
eq(reloaded.requirements.first?.requirement.session, "s-abc", "load reads the session binding back")
check(files(in: RequirementsCore.requirementsDir(ws6)).contains("local.json"), "the binding lives in local.json (runtime, ignored)")
let plain = try! RequirementsCore.createRequirement(workspace: ws6, title: "面板来源", body: nil, source: nil, today: "2026-10-04")
eq(plain.session, nil, "panel-created card has no source session")

section("composer edit")
let editModel = RequirementComposerModel.edit(edited2)
eq(editModel.mode.isCreate, false, "edit model is not create")
eq(editModel.mode.requirementID, req5Id, "edit model carries the id")
eq(editModel.title, "再改", "edit model title parsed from content")
eq(editModel.body, "新诉求2", "edit model body parsed from content")
eq(editModel.submitKey, "requirements.save", "edit model submits as save")
eq(editModel.headingKey, "requirements.editTitle", "edit model heading is the edit title")
eq(RequirementComposerModel.build().showsRefineButton, true, "create composer shows 创建并细化")
eq(editModel.showsRefineButton, false, "edit composer hides 创建并细化")
eq(RequirementComposerModel.build().refineKey, "requirements.createAndRefine", "refine button key")

section("reject reason")
var reject = RejectReasonModel.build()
eq(reject.canSubmit, false, "an empty rejection cannot submit")
eq(reject.problemKey, nil, "no problem before an attempted submit")
reject = reject.attemptedSubmit()
eq(reject.problemKey, "requirements.reject.problem", "empty rejection shows the problem after submit")
reject = reject.typed(content: "  粒度太粗  ")
eq(reject.reason, "粒度太粗", "the reason is trimmed")
eq(reject.canSubmit, true, "a non-empty reason can submit")
eq(reject.typed(content: "x").submitKey, "requirements.reject.submit", "reject submit key")
eq(reject.typed(content: "x").contentCaptionKey, "requirements.reject.content", "reject content caption key")

section("result")
print("requirements model: " + String(checks - failures) + "/" + String(checks) + " passed")
if failures > 0 { exit(1) }
