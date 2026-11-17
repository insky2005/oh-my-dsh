//
//  stage-gate-tests.swift — headless tests for WorkstreamsStageGate.
//  Built by tests/workstreams-panel/run.sh with WorkstreamsCore.swift.
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
    if actual != expected {
        failures += 1
        print("  FAIL " + label + ": got " + String(describing: actual) + ", want " + String(describing: expected))
    }
}

func section(_ name: String) { print("--- " + name + " ---") }

func expectError<T>(_ label: String, _ expected: WorkstreamError, _ body: () throws -> T) {
    checks += 1
    do {
        _ = try body()
        failures += 1
        print("  FAIL " + label + ": no error thrown")
    } catch let error as WorkstreamError {
        if error != expected { failures += 1; print("  FAIL " + label + ": got " + String(describing: error)) }
    } catch {
        failures += 1
        print("  FAIL " + label + ": unexpected error " + String(describing: error))
    }
}

func tempWorkspace(_ tag: String) -> String {
    let path = NSTemporaryDirectory() + "ws-gate-" + tag + "-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

func card(stage: WorkstreamStage, body: String,
          covered: CoveredRecord? = nil, delivery: DeliveryInfo? = nil,
          queues: [String] = []) -> WorkstreamCard {
    WorkstreamCard(id: "WS-000001", title: "门", requirement: nil, stage: stage,
                   covered: covered, regression: nil, queues: queues, delivery: delivery,
                   created: "2026-10-06", updated: "2026-10-06",
                   path: "/tmp/WS-000001.md", body: body)
}

let fullPlan = """
## 规划

- 目标（WHAT）：交付事项阶段门。
- 边界（做）：只改事项面板。
- 阶段裁剪声明：不裁剪。
- 验收标准（规划完成证据）：
  - AC1 缺证据时门拒绝推进。
"""

let fullDesign = """
## 设计

见 docs/design/panels/workstreams-stage-gate.md。
"""

let acceptanceBody = "## 验收\n\n- 证据：测试绿。\n- 判定：人 sign-off。\n"
let evidenceOnlyBody = "## 验收\n\n证据\n"

// MARK: - Stage order

section("stage order")
eq(WorkstreamStage.ordered, [.planning, .design, .task, .acceptance], "canonical order (four stages)")
eq(WorkstreamStage.planning.next, .design, "planning -> design")
eq(WorkstreamStage.design.next, .task, "design -> execution")
eq(WorkstreamStage.task.next, .acceptance, "execution -> acceptance")
eq(WorkstreamStage.acceptance.next == nil, true, "acceptance is the last stage")

// MARK: - Planning (four-piece set)

section("planning evidence")
let planItems = WorkstreamsStageGate.planningEvidence(fullPlan)
eq(planItems.count, 4, "four pieces")
check(planItems.allSatisfy { $0.passed }, "full plan passes")
check(WorkstreamsStageGate.planningEvidence("## 规划").contains { !$0.passed }, "empty plan fails")
let noBoundary = fullPlan.replacingOccurrences(of: "- 边界（做）：只改事项面板。", with: "")
check(WorkstreamsStageGate.planningEvidence(noBoundary).first { $0.key == "workstreams.evidence.planning.boundary" }?.passed == false,
      "missing boundary fails")
let noAC = fullPlan.replacingOccurrences(of: "  - AC1 缺证据时门拒绝推进。", with: "")
check(WorkstreamsStageGate.planningEvidence(noAC).first { $0.key == "workstreams.evidence.planning.acceptance" }?.passed == false,
      "acceptance without AC<n> fails")
let noTrim = fullPlan.replacingOccurrences(of: "- 阶段裁剪声明：不裁剪。", with: "")
check(WorkstreamsStageGate.planningEvidence(noTrim).first { $0.key == "workstreams.evidence.planning.trim" }?.passed == false,
      "missing trim declaration fails")

// MARK: - Design (doc exists + Q closed)

section("design evidence")
let designItems = WorkstreamsStageGate.designEvidence(fullDesign, workspace: "/w") { $0.hasSuffix("workstreams-stage-gate.md") }
check(designItems.allSatisfy { $0.passed }, "existing referenced doc + no Q passes")
let noDoc = WorkstreamsStageGate.designEvidence(fullDesign, workspace: "/w") { _ in false }
check(noDoc.first { $0.key == "workstreams.evidence.design.doc" }?.passed == false, "missing referenced doc fails")
let openQ = fullDesign + "\n| Q1 | 待确认问题 | 开着 |\n"
let openItems = WorkstreamsStageGate.designEvidence(openQ, workspace: "/w") { _ in true }
check(openItems.first { $0.key == "workstreams.evidence.design.questions" }?.passed == false, "open Q fails")
let closedQ = fullDesign + "\n| Q1 | 问题 | 已确认 |\n"
let closedItems = WorkstreamsStageGate.designEvidence(closedQ, workspace: "/w") { _ in true }
check(closedItems.first { $0.key == "workstreams.evidence.design.questions" }?.passed == true, "closed Q passes")
let trimmedDesign = "## 设计（裁剪）\n\n设计随 PR 承载，无独立文档。"
let trimmedItems = WorkstreamsStageGate.designEvidence(trimmedDesign, workspace: "/w") { _ in false }
check(trimmedItems.first { $0.key == "workstreams.evidence.design.doc" }?.passed == true,
      "declared trim waives the doc requirement")
eq(WorkstreamsStageGate.referencedDocPaths(fullDesign), ["docs/design/panels/workstreams-stage-gate.md"],
   "referenced doc paths extracted")

// MARK: - Execution (marker / product)

section("execution evidence")
let ready = WSStageCarrier(hasQueue: true, done: true, taskCount: 2,
                           allTasksDone: true, allEvidenceVerified: true)
check(WorkstreamsStageGate.executionEvidence(ready).allSatisfy { $0.passed }, "queue done + evidence passes")
check(WorkstreamsStageGate.executionEvidence(.none).contains { !$0.passed }, "no queue fails")
let running = WSStageCarrier(hasQueue: true, done: false, taskCount: 2,
                             allTasksDone: false, allEvidenceVerified: false)
check(WorkstreamsStageGate.executionEvidence(running).contains { !$0.passed }, "unfinished queue fails")
let unverified = WSStageCarrier(hasQueue: true, done: true, taskCount: 1,
                                allTasksDone: true, allEvidenceVerified: false)
check(WorkstreamsStageGate.executionEvidence(unverified).first { $0.key == "workstreams.evidence.task.marker" }?.passed == false,
      "done task without marker/confirm fails")

// MARK: - Acceptance (the last stage)

section("acceptance evidence (covered + sign-off)")
let acceptanceCard = card(stage: .acceptance, body: acceptanceBody,
                          covered: CoveredRecord(paths: ["a.swift"], base: "b", head: "h"))
check(WorkstreamsStageGate.acceptanceEvidence(acceptanceCard).allSatisfy { $0.passed }, "covered + record passes")
check(WorkstreamsStageGate.acceptanceEvidence(card(stage: .acceptance, body: evidenceOnlyBody)).contains { !$0.passed },
      "missing covered fails")
check(WorkstreamsStageGate.acceptanceEvidence(card(stage: .acceptance, body: evidenceOnlyBody,
                                                   covered: CoveredRecord(paths: ["a.swift"], base: nil, head: nil))).contains { !$0.passed },
      "covered without base/head fails")
// 交付是操作（design A17）：门没有交付证据分支，验收证据只有「验收记录 + covered」。
let acceptanceItems = WorkstreamsStageGate.acceptanceEvidence(acceptanceCard)
eq(acceptanceItems.count, 2, "acceptance gate = record + covered only")
check(acceptanceItems.allSatisfy { !$0.key.contains("delivery") },
      "no delivery evidence branch in the stage gate")
// 交付事实仍是卡片的一部分（交付模块读它做准入），只是不参与阶段门。
let deliveryCard = card(stage: .acceptance, body: "## 验收\n",
                        delivery: DeliveryInfo(pr: 42, url: "u", outcome: "merged"))
eq(deliveryCard.delivery?.pr, 42, "delivery facts still live on the card for the operation")
eq(WorkstreamsStageGate.evaluate(deliveryCard, carrier: .none).evidence.items.count, 2,
   "the gate evaluates acceptance only, never the delivery facts")

// MARK: - Accepted (the terminal-state prerequisite)

section("accepted")
let acceptedBody = "## 阶段确认\n\n- 2026-10-07 · confirm · acceptance → done · source:panel"
check(WorkstreamsStageGate.accepted(card(stage: .acceptance, body: acceptedBody)),
      "acceptance confirm -> accepted")
check(WorkstreamsStageGate.accepted(body: acceptedBody), "body overload agrees")
check(!WorkstreamsStageGate.accepted(card(stage: .acceptance, body: "## 阶段确认\n\n- 2026-10-07 · confirm · planning → design")),
      "an earlier stage confirm is not accepted")
check(!WorkstreamsStageGate.accepted(card(stage: .acceptance, body: "## 阶段确认\n\n- 2026-10-07 · reject · acceptance · 返工")),
      "a reject is not accepted")
check(!WorkstreamsStageGate.accepted(card(stage: .acceptance, body: "## 验收\n\n- 证据：测试绿。")),
      "missing history section is not accepted")
check(WorkstreamsStageGate.accepted(card(stage: .acceptance, body: "## 阶段确认\n\n- 2026-10-03 · confirm · delivery → done")),
      "legacy delivery confirm still counts (read-compat)")

// MARK: - Gate state

section("gate state")
let planGate = WorkstreamsStageGate.evaluate(card(stage: .planning, body: fullPlan), carrier: .none)
eq(planGate.state, .awaitingConfirmation, "full planning evidence + no carrier -> awaiting")
eq(planGate.canConfirm, true, "canConfirm")
let blocked = WorkstreamsStageGate.evaluate(card(stage: .planning, body: "## 规划\n"), carrier: .none)
eq(blocked.state, .evidenceMissing, "empty planning evidence -> evidenceMissing")
eq(blocked.canConfirm, false, "cannot confirm without evidence")
eq(blocked.evidence.missingKeys.isEmpty, false, "missing keys reported")
let inProgress = WorkstreamsStageGate.evaluate(card(stage: .task, body: ""), carrier: running)
eq(inProgress.state, .inProgress, "unfinished queue -> inProgress")
let execGate = WorkstreamsStageGate.evaluate(card(stage: .task, body: ""), carrier: ready)
eq(execGate.state, .awaitingConfirmation, "finished queue + evidence -> awaiting")
eq(WorkstreamsStageGate.evaluate(card(stage: .task, body: ""), carrier: unverified).state, .evidenceMissing,
   "finished queue without task evidence -> evidenceMissing")

// MARK: - JSON

section("gate json")
let json = WorkstreamsStageGate.json(planGate)
eq(json["state"] as? String, "awaitingConfirmation", "state in JSON")
eq(json["canConfirm"] as? Bool, true, "canConfirm in JSON")
eq((json["evidence"] as? [[String: Any]])?.count, 4, "evidence items in JSON")
eq((json["missing"] as? [String])?.isEmpty, true, "no missing in JSON")

// MARK: - Human confirmation advances

section("confirm stage")
let ws = tempWorkspace("confirm")
let created = try WorkstreamsCore.create(workspace: ws, title: "门", stage: .planning, today: "2026-10-06")
_ = try WorkstreamsCore.update(workspace: ws, id: created.id, body: fullPlan, today: "2026-10-06")
let confirmed = try WorkstreamsCore.confirmStage(workspace: ws, id: created.id,
                                                 expectedStage: .planning, carrier: .none,
                                                 today: "2026-10-07")
eq(confirmed.stage, .design, "confirmation advances planning -> design")
let history = WorkstreamsStageGate.parseHistory(confirmed.body)
eq(history.count, 1, "one history entry")
eq(history[0].action, .confirm, "confirm action recorded")
eq(history[0].stage, .planning, "acted stage recorded")
eq(history[0].target, .design, "target recorded")
check(confirmed.body.contains("## 阶段确认"), "history section written to the body")

let bad = try WorkstreamsCore.create(workspace: ws, title: "缺证据", stage: .planning, today: "2026-10-06")
_ = try WorkstreamsCore.update(workspace: ws, id: bad.id, body: "## 规划\n\n- 目标：x\n", today: "2026-10-06")
expectError("missing evidence does not advance",
            .evidenceMissing(["workstreams.evidence.planning.boundary",
                              "workstreams.evidence.planning.acceptance",
                              "workstreams.evidence.planning.trim"])) {
    try WorkstreamsCore.confirmStage(workspace: ws, id: bad.id, carrier: .none, today: "2026-10-07")
}
eq(try WorkstreamsCore.loadCard(workspace: ws, id: bad.id).stage, .planning,
   "stage unchanged after a refused confirmation")

expectError("stale confirmation is refused", .stageChanged("task", "design")) {
    try WorkstreamsCore.confirmStage(workspace: ws, id: created.id, expectedStage: .task,
                                     carrier: .none, today: "2026-10-07")
}

let terminalCard = try WorkstreamsCore.create(workspace: ws, title: "验收终态", stage: .acceptance, today: "2026-10-06")
_ = try WorkstreamsCore.update(workspace: ws, id: terminalCard.id, body: acceptanceBody, today: "2026-10-06")
_ = try WorkstreamsCore.setCovered(workspace: ws, id: terminalCard.id,
                                   covered: CoveredRecord(paths: ["a.swift"], base: "b", head: "h"),
                                   today: "2026-10-06")
_ = try WorkstreamsCore.setDelivery(workspace: ws, id: terminalCard.id,
                                    delivery: DeliveryInfo(pr: 9, url: "u", outcome: "merged"),
                                    today: "2026-10-06")
let terminal = try WorkstreamsCore.confirmStage(workspace: ws, id: terminalCard.id, carrier: .none,
                                                today: "2026-10-07")
eq(terminal.stage, .acceptance, "acceptance stays terminal after confirmation")
eq(WorkstreamsStageGate.parseHistory(terminal.body).first?.target == nil, true,
   "terminal confirmation has no target")
// 旧卡把「交付」当阶段写进审计痕迹：读兼容后等同验收确认（target 为空）。
let legacyTerminal = WorkstreamsStageGate.parseHistory("""
## 阶段确认

- 2026-10-07 · confirm · delivery → done
""")
eq(legacyTerminal.first?.stage, .acceptance, "a legacy delivery confirm reads as acceptance")
eq(legacyTerminal.first?.target, nil, "the legacy terminal confirm keeps no target")

// MARK: - Back edge

section("reject stage (back edge)")
let rejCard = try WorkstreamsCore.create(workspace: ws, title: "退回", stage: .design, today: "2026-10-06")
_ = try WorkstreamsCore.update(workspace: ws, id: rejCard.id, body: "## 设计\n\nx\n", today: "2026-10-06")
let rejected = try WorkstreamsCore.rejectStage(workspace: ws, id: rejCard.id,
                                               reason: "边界未定", today: "2026-10-07")
eq(rejected.stage, .design, "reject keeps the stage (rework in place)")
let rejHistory = WorkstreamsStageGate.parseHistory(rejected.body)
eq(rejHistory.count, 1, "reject recorded")
eq(rejHistory[0].action, .reject, "reject action")
eq(rejHistory[0].reason, "边界未定", "reason recorded")
check(rejected.body.contains("边界未定"), "reason stays in the card body")

let back = try WorkstreamsCore.rejectStage(workspace: ws, id: rejCard.id,
                                           reason: "回到规划", target: .planning, today: "2026-10-08")
eq(back.stage, .planning, "reject target moves the card back")
let backHistory = WorkstreamsStageGate.parseHistory(back.body)
eq(backHistory.count, 2, "both decisions kept")
eq(backHistory[1].target, .planning, "back target recorded")

expectError("reject needs a reason", .missingReason) {
    try WorkstreamsCore.rejectStage(workspace: ws, id: rejCard.id, reason: "   ", today: "2026-10-08")
}

// MARK: - Source marker (R10: panel tap vs session authorization)

section("gate source marker")
eq(WSStageSource.panel.marker, "panel", "panel marker")
eq(WSStageSource.session("s-42").marker, "session s-42", "session marker with id")
eq(WSStageSource.session("  ").marker, "session", "blank session id collapses to session")
eq(WSStageSource.from(session: " s-7 "), .session("s-7"), "session field maps to session source")
eq(WSStageSource.from(session: "   "), .panel, "blank session field falls back to panel")
eq(WSStageSource.from(session: nil), .panel, "missing session field falls back to panel")
eq(WSStageSource.parse("panel"), .panel, "panel parses")
eq(WSStageSource.parse("session s-9"), .session("s-9"), "session parses")
eq(WSStageSource.parse("nonsense"), nil, "unknown marker rejected")

let srcCard = try WorkstreamsCore.create(workspace: ws, title: "来源", stage: .planning, today: "2026-10-06")
_ = try WorkstreamsCore.update(workspace: ws, id: srcCard.id, body: fullPlan, today: "2026-10-06")
let panelConfirmed = try WorkstreamsCore.confirmStage(workspace: ws, id: srcCard.id,
                                                      expectedStage: .planning, carrier: .none,
                                                      today: "2026-10-07")
eq(WorkstreamsStageGate.parseHistory(panelConfirmed.body).first?.source, .panel,
   "a default confirmation records the panel source")
check(panelConfirmed.body.contains("source:panel"), "panel source stays in the card body")

let sessionCard = try WorkstreamsCore.create(workspace: ws, title: "会话授权", stage: .planning, today: "2026-10-06")
_ = try WorkstreamsCore.update(workspace: ws, id: sessionCard.id, body: fullPlan, today: "2026-10-06")
let sessionConfirmed = try WorkstreamsCore.confirmStage(workspace: ws, id: sessionCard.id,
                                                        expectedStage: .planning, carrier: .none,
                                                        source: WSStageSource.from(session: "s-42"),
                                                        today: "2026-10-07")
let sessionHistory = WorkstreamsStageGate.parseHistory(sessionConfirmed.body).first
eq(sessionHistory?.source, .session("s-42"), "a session-authorized confirmation records the session id")
check(sessionConfirmed.body.contains("source:session s-42"), "session source stays in the card body")

let sessionRejectCard = try WorkstreamsCore.create(workspace: ws, title: "会话退回", stage: .design, today: "2026-10-06")
_ = try WorkstreamsCore.update(workspace: ws, id: sessionRejectCard.id, body: "## 设计\n\nx\n", today: "2026-10-06")
let sessionReject = try WorkstreamsCore.rejectStage(workspace: ws, id: sessionRejectCard.id,
                                                    reason: "边界未定", source: WSStageSource.from(session: "s-9"),
                                                    today: "2026-10-07")
let sessionRejectHistory = WorkstreamsStageGate.parseHistory(sessionReject.body).first
eq(sessionRejectHistory?.source, .session("s-9"), "a session-authorized reject records the session id")
eq(sessionRejectHistory?.reason, "边界未定", "the reason is still parsed next to the source")

let legacyBody = """
## 阶段确认

- 2026-10-07 · confirm · planning → design
- 2026-10-07 · reject · task → planning · 旧记录
"""
let legacyHistory = WorkstreamsStageGate.parseHistory(legacyBody)
eq(legacyHistory.count, 2, "legacy entries still parse")
eq(legacyHistory[0].source, nil, "a legacy confirm has no source")
eq(legacyHistory[1].source, nil, "a legacy reject has no source")
eq(legacyHistory[1].reason, "旧记录", "a legacy reject reason is unchanged")

let sourceGate = WSStageGate(stage: .planning, state: .awaitingConfirmation,
                             evidence: WSStageEvidence(stage: .planning, items: []),
                             queueDone: true, history: [sessionHistory!])
let sourceJSON = WorkstreamsStageGate.json(sourceGate)
eq((sourceJSON["history"] as? [[String: Any]])?.first?["source"] as? String, "session s-42",
   "the source marker is exposed in the gate JSON")

// MARK: - Report

print("")
if failures == 0 {
    print("workstreams stage-gate tests passed (" + String(checks) + " checks)")
} else {
    print("workstreams stage-gate tests FAILED: " + String(failures) + "/" + String(checks))
    exit(1)
}
