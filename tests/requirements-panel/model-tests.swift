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
eq(created.id, "REQ-008", "next id after REQ-007")
eq(created.title, "新需求", "title trimmed")
eq(created.state, "candidate", "new requirement is a candidate")
check(FileManager.default.fileExists(atPath: RequirementsCore.requirementPath(ws2, id: "REQ-008")), "card written")
check(!files(in: RequirementsCore.requirementsDir(ws2)).contains(where: { $0.contains(".tmp-") }), "no temp files left behind")
check(created.body.contains("新需求"), "empty body falls back to the title")

expectError("empty title throws missingTitle", .missingTitle) {
    _ = try RequirementsCore.createRequirement(workspace: ws2, title: "   ", body: nil, source: nil, today: "2026-10-04")
}

let evaluating = try! RequirementsCore.setState(workspace: ws2, id: "REQ-008", state: "evaluating", today: "2026-10-05")
eq(evaluating.state, "evaluating", "state updated")
eq(evaluating.updated, "2026-10-05", "updated date bumped")
expectError("derived state rejected on write", .unknownState("split")) {
    _ = try RequirementsCore.setState(workspace: ws2, id: "REQ-008", state: "split", today: "2026-10-05")
}
expectError("unknown requirement throws", .unknownRequirement("REQ-999")) {
    _ = try RequirementsCore.setState(workspace: ws2, id: "REQ-999", state: "candidate", today: "2026-10-05")
}

// MARK: - propose / confirm / reject

section("breakdown")
let ws3 = tempWorkspace("breakdown")
_ = try! RequirementsCore.createRequirement(workspace: ws3, title: "拆分我", body: "把这件事拆开。", source: "test", today: "2026-10-04")
let items = [BreakdownItem(title: "事项 A", boundary: "只做 A", dependsOn: []),
             BreakdownItem(title: "事项 B", boundary: "依赖 A", dependsOn: ["事项 A"])]
let proposed = try! RequirementsCore.propose(workspace: ws3, id: "REQ-001", items: items, today: "2026-10-04")
eq(proposed.body.contains("json proposal"), true, "proposal fence written")
eq(RequirementsCore.parseProposal(proposed.body)?.count, 2, "proposal round-trips")
eq(RequirementsCore.parseProposal(proposed.body)?[1].dependsOn, ["事项 A"], "dependsOn round-trips")

// Negative gate: confirm without a proposal must fail (design §10 "门要能自证").
let ws4 = tempWorkspace("nogate")
_ = try! RequirementsCore.createRequirement(workspace: ws4, title: "无提案", body: nil, source: nil, today: "2026-10-04")
expectError("confirm without proposal -> noProposal", .noProposal) {
    _ = try RequirementsCore.confirm(workspace: ws4, id: "REQ-001", today: "2026-10-04")
}

let createdWs = try! RequirementsCore.confirm(workspace: ws3, id: "REQ-001", today: "2026-10-04")
eq(createdWs.count, 2, "confirm creates one WS per item")
eq(createdWs[0].id, "WS-001", "first WS id")
eq(createdWs[1].id, "WS-002", "second WS id")
eq(createdWs[0].requirement, "REQ-001", "WS points back at the requirement")
eq(createdWs[0].stage, "planning", "new WS starts in planning")
check(FileManager.default.fileExists(atPath: RequirementsCore.workstreamPath(ws3, id: "WS-002")), "second WS written")

let afterConfirm = RequirementsCore.load(workspace: ws3)
eq(afterConfirm.requirements[0].proposal == nil, true, "proposal cleared after confirm")
eq(afterConfirm.requirements[0].effectiveState, .split, "confirmed requirement shows split")
eq(afterConfirm.requirements[0].children.count, 2, "children visible after confirm")
expectError("confirm is not repeatable", .noProposal) {
    _ = try RequirementsCore.confirm(workspace: ws3, id: "REQ-001", today: "2026-10-04")
}
check(!files(in: RequirementsCore.workstreamsDir(ws3)).contains(where: { $0.contains(".tmp-") }), "no temp WS files")

// reject
_ = try! RequirementsCore.propose(workspace: ws3, id: "REQ-001", items: items, today: "2026-10-04")
let rejected = try! RequirementsCore.reject(workspace: ws3, id: "REQ-001", today: "2026-10-04")
eq(RequirementsCore.parseProposal(rejected.body), nil, "reject clears the proposal")
expectError("reject without proposal -> noProposal", .noProposal) {
    _ = try RequirementsCore.reject(workspace: ws3, id: "REQ-001", today: "2026-10-04")
}

check(RequirementsCore.breakdownPrompt("REQ-001").contains("/api/requirements/breakdown/propose"), "prompt points at the propose endpoint")
check(RequirementsCore.breakdownPrompt("REQ-042").contains("REQ-042"), "prompt names the requirement")

section("result")
print("requirements model: " + String(checks - failures) + "/" + String(checks) + " passed")
if failures > 0 { exit(1) }
