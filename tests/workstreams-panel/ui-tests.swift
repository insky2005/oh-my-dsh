//
//  ui-tests.swift — headless tests for the Workstreams panel's pure view models
//  (WorkstreamsUI.swift: the three-level card model, the stage filter and the
//  empty state). No AppKit, no window.
//  Built by tests/workstreams-panel/run.sh (top-level code must live in main.swift).
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

func card(id: String,
          title: String = "事项",
          requirement: String? = nil,
          stage: WorkstreamStage = .planning,
          covered: CoveredRecord? = nil,
          regression: String? = nil,
          queues: [String] = [],
          delivery: DeliveryInfo? = nil,
          updated: String? = "2026-10-06",
          path: String? = nil,
          body: String = "# body") -> WorkstreamCard {
    WorkstreamCard(id: id, title: title, requirement: requirement, stage: stage,
                   covered: covered, regression: regression, queues: queues,
                   delivery: delivery, created: "2026-10-06", updated: updated,
                   path: path ?? ("/tmp/" + id + ".md"), body: body)
}

// MARK: - Stage labels / tones

section("stage labels / tones")
eq(wsStageLabelKey(.planning), "workstreams.stage.planning", "planning label key")
eq(wsStageLabelKey(.design), "workstreams.stage.design", "design label key")
eq(wsStageLabelKey(.task), "workstreams.stage.task", "task label key")
eq(wsStageLabelKey(.acceptance), "workstreams.stage.acceptance", "acceptance label key")
eq(wsStageLabelKey(.delivery), "workstreams.stage.delivery", "delivery label key")
eq(wsStageTone(.planning), .neutral, "planning tone")
eq(wsStageTone(.design), .neutral, "design tone")
eq(wsStageTone(.task), .running, "task tone")
eq(wsStageTone(.acceptance), .warning, "acceptance tone")
eq(wsStageTone(.delivery), .positive, "delivery tone")

// MARK: - Three-level card model

section("primary card")
let full = card(id: "WS-000042", title: "事项面板 UI", requirement: "REQ-000011",
                stage: .task, regression: "REG-001",
                queues: ["q-a"])
let model = WSCardModel.build(from: full)
eq(model.id, "WS-000042", "id")
eq(model.title, "事项面板 UI", "title")
eq(model.requirement, "REQ-000011", "requirement")
eq(model.stage, .task, "stage")
eq(model.tone, .running, "primary tone from stage")
eq(model.path, "/tmp/WS-000042.md", "path")
eq(model.isExpanded, true, "primary card starts expanded")
eq(model.detail, "# body", "detail is the trimmed body")
eq(model.stageLabelKey, "workstreams.stage.task", "stage label key")

section("primary meta")
eq(model.meta.map { $0.labelKey },
   ["workstreams.meta.requirement", "workstreams.meta.queues", "workstreams.meta.regression", "workstreams.meta.updated"],
   "meta line keys")
eq(model.meta.map { $0.value }, ["REQ-000011", "1", "REG-001", "2026-10-06"], "meta line values")
let bare = WSCardModel.build(from: card(id: "WS-000043", queues: [], updated: nil))
eq(bare.meta, [], "a bare card has no meta lines")

section("five stage cards")
eq(model.stages.count, 5, "exactly five stage cards")
eq(model.stages.map { $0.stage },
   [.planning, .design, .task, .acceptance, .delivery],
   "stage cards in canonical order")
eq(model.stages.map { $0.labelKey },
   ["workstreams.stage.planning", "workstreams.stage.design", "workstreams.stage.task",
    "workstreams.stage.acceptance", "workstreams.stage.delivery"],
   "stage card label keys")
eq(model.stages.filter { $0.isCurrent }.map { $0.stage }, [.task], "exactly one current stage")
eq(model.stages.first { $0.stage == .task }?.isCurrent, true, "current is the card stage")

section("the workstream queue lands on the current stage card")
let byStage = Dictionary(uniqueKeysWithValues: model.stages.map { ($0.stage, $0) })
eq(byStage[.task]?.queueIDs, ["q-a"], "the queue is shown on the current stage")
eq(byStage[.task]?.hasQueue, true, "the current stage has a queue")
eq(byStage[.planning]?.queueIDs, [], "other stages carry no queue")
eq(byStage[.design]?.hasQueue, false, "a non-current stage has no queue")

section("the queue follows the current stage")
let legacy = WSCardModel.build(from: card(id: "WS-000044", stage: .design, queues: ["q-legacy"]))
eq(legacy.stages.first { $0.stage == .design }?.queueIDs, ["q-legacy"],
   "the queue lands in the card's current stage")

section("stage evidence")
let evidenceCard = card(id: "WS-000045", stage: .delivery,
                        covered: CoveredRecord(paths: ["docs/a.md", "docs/b.md"], base: "base1", head: "head1"),
                        delivery: DeliveryInfo(pr: 78, url: "https://example.test/pull/78", outcome: "merged"))
let evidenceModel = WSCardModel.build(from: evidenceCard)
let acceptance = evidenceModel.stages.first { $0.stage == .acceptance }
eq(acceptance?.evidence.map { $0.labelKey },
   ["workstreams.evidence.covered", "workstreams.evidence.base", "workstreams.evidence.head"],
   "acceptance evidence keys")
eq(acceptance?.evidence.first?.value, "docs/a.md, docs/b.md", "covered paths joined")
let delivery = evidenceModel.stages.first { $0.stage == .delivery }
eq(delivery?.evidence.map { $0.labelKey },
   ["workstreams.evidence.pr", "workstreams.evidence.outcome", "workstreams.evidence.url"],
   "delivery evidence keys")
eq(delivery?.evidence.first?.value, "#78", "pr prefixed with #")
eq(delivery?.evidence.last?.value, "https://example.test/pull/78", "delivery url")
eq(WSCardModel.build(from: card(id: "WS-000046")).stages.first { $0.stage == .acceptance }?.evidence,
   [], "no covered -> no acceptance evidence")

section("task cards")
let stageWithTask = WSStageCardModel(stage: .task, isCurrent: true, queueIDs: ["q-b"],
                                     tasks: [WSTaskCardModel.build(id: "t-1", title: "改代码", tone: .running)],
                                     evidence: [], isExpanded: false)
eq(stageWithTask.taskCount, 1, "task count")
eq(stageWithTask.hasQueue, true, "has queue")
eq(stageWithTask.tasks.first?.stateKey, nil, "task state key defaults to nil")

// MARK: - Tertiary cards from the queue engine

section("task state keys / tones")
eq(wsTaskStateKey(.pending), "workstreams.task.state.pending", "pending state key")
eq(wsTaskStateKey(.running), "workstreams.task.state.running", "running state key")
eq(wsTaskStateKey(.needsReview), "workstreams.task.state.needsReview", "needs-review state key")
eq(wsTaskTone(.done), .positive, "done tone")
eq(wsTaskTone(.failed), .negative, "failed tone")
eq(wsTaskTone(.queued), .neutral, "queued tone")

section("tasks group onto their own stage card")
var queueBoard = WSBoard()
let q = queueBoard.createQueue(name: "Q", workstreamID: "WS-000080")
queueBoard.tasks.append(WSTaskItem(id: "wt-1", title: "规划任务", workstreamId: "WS-000080", stage: .planning))
queueBoard.tasks.append(WSTaskItem(id: "wt-2", title: "执行任务", workstreamId: "WS-000080", stage: .task))
_ = queueBoard.enqueue(taskID: "wt-1", into: q.id)
_ = queueBoard.enqueue(taskID: "wt-2", into: q.id)
queueBoard.markRunning("wt-2")
if let i = queueBoard.index(ofTask: "wt-2") { queueBoard.tasks[i].sessionId = "session-2" }
let grouped = WSCardModel.build(from: card(id: "WS-000080", stage: .task, queues: [q.id]), board: queueBoard)
let wsPlanningStage = grouped.stages.first { $0.stage == .planning }
let wsExecutionStage = grouped.stages.first { $0.stage == .task }
eq(wsPlanningStage?.tasks.map { $0.id }, ["wt-1"], "the planning task lands on the planning stage card")
eq(wsExecutionStage?.tasks.map { $0.id }, ["wt-2"], "the execution task lands on the execution stage card")
eq(wsExecutionStage?.tasks.first?.stateKey, "workstreams.task.state.running", "task state key from the engine")
eq(wsExecutionStage?.tasks.first?.tone, .running, "task tone from the engine state")
eq(wsExecutionStage?.tasks.first?.sessionId, "session-2", "task session surfaces on the card")
check((wsPlanningStage?.tasks.first?.sessionId ?? "").isEmpty, "a task without a session has none")
let failedTask = WSTaskCardModel.build(from: WSTaskItem(id: "wt-3", title: "失败", state: .failed,
                                                      error: "workstreams.errPrompt"))
eq(failedTask.errorKey, "workstreams.errPrompt", "task error key surfaces")
eq(failedTask.stateKey, "workstreams.task.state.failed", "failed task state key")

// MARK: - Stage filter

section("stage filter")
eq(WSStageFilter.allCases.count, 6, "全部 + five stages")
eq(WSStageFilter.allCases.first, .all, "all is first")
eq(WSStageFilter.allCases.dropFirst().compactMap { $0.stage },
   [.planning, .design, .task, .acceptance, .delivery], "filter stages in order")
eq(WSStageFilter.all.labelKey, "workstreams.filter.all", "all label key")
eq(WSStageFilter.stage(.delivery).labelKey, "workstreams.stage.delivery", "stage filter label key")
check(WSStageFilter.all.isAll, "all isAll")
check(!WSStageFilter.stage(.design).isAll, "a stage is not all")
eq(WSStageFilter.all.stage, nil, "all has no stage")

let planning = card(id: "WS-000050", stage: .planning)
let design = card(id: "WS-000051", stage: .design)
let tasks = card(id: "WS-000052", stage: .task)
let all = [planning, design, tasks]
eq(WSStageFilter.all.filter(all).map { $0.id }, ["WS-000050", "WS-000051", "WS-000052"],
   "all keeps every card")
eq(WSStageFilter.stage(.design).filter(all).map { $0.id }, ["WS-000051"],
   "a stage filter keeps only its stage")
eq(WSStageFilter.stage(.acceptance).filter(all).map { $0.id }, [],
   "a stage with no card yields an empty list")
check(WSStageFilter.stage(.planning).matches(planning), "matches its own stage")
check(!WSStageFilter.stage(.planning).matches(design), "does not match another stage")

// MARK: - Empty state

section("empty state")
let noWorkspace = WSEmptyStateModel.build(hasWorkspace: false, totalCount: 0, filter: .all)
eq(noWorkspace.messageKey, "workstreams.needsWorkspace", "no workspace message")
eq(noWorkspace.isPoolEmpty, false, "no workspace is not an empty pool")
let emptyPool = WSEmptyStateModel.build(hasWorkspace: true, totalCount: 0, filter: .all)
eq(emptyPool.messageKey, "workstreams.empty", "empty pool message")
eq(emptyPool.isPoolEmpty, true, "empty pool flag")
let filtered = WSEmptyStateModel.build(hasWorkspace: true, totalCount: 3, filter: .stage(.delivery))
eq(filtered.messageKey, "workstreams.empty.filter", "filter miss message")
eq(filtered.isPoolEmpty, false, "filter miss is not an empty pool")

// MARK: - Board model

section("board")
func snapshot(_ cards: [WorkstreamCard]) -> WorkstreamsSnapshot {
    WorkstreamsSnapshot(workspace: "/tmp/ws", dshExists: true, workstreams: cards, unparsed: [])
}
let boardAll = WSBoardModel.build(snapshot: snapshot(all), filter: .all)
eq(boardAll.cards.map { $0.id }, ["WS-000050", "WS-000051", "WS-000052"], "board all cards")
eq(boardAll.totalCount, 3, "board total count")
eq(boardAll.isEmpty, false, "non-empty board")
eq(boardAll.emptyState, nil, "no empty state when the board has cards")

let boardDesign = WSBoardModel.build(snapshot: snapshot(all), filter: .stage(.design))
eq(boardDesign.cards.map { $0.id }, ["WS-000051"], "filtered board")
eq(boardDesign.emptyState, nil, "filtered board with a hit has no empty state")

let boardMiss = WSBoardModel.build(snapshot: snapshot(all), filter: .stage(.acceptance))
check(boardMiss.cards.isEmpty, "filter miss yields no cards")
eq(boardMiss.emptyState?.messageKey, "workstreams.empty.filter", "filter miss empty state")
eq(boardMiss.totalCount, 3, "filter miss still knows the pool size")

let boardNoWorkspace = WSBoardModel.build(
    snapshot: WorkstreamsSnapshot(workspace: "", dshExists: false, workstreams: [], unparsed: []),
    filter: .all)
eq(boardNoWorkspace.emptyState?.messageKey, "workstreams.needsWorkspace", "no workspace board")

let boardEmptyPool = WSBoardModel.build(snapshot: snapshot([]), filter: .all)
eq(boardEmptyPool.emptyState?.messageKey, "workstreams.empty", "empty pool board")

// MARK: - Parse round-trip

section("parsed card feeds the card model")
let parsed = try WorkstreamsCore.parseCard("""
---
id: WS-000060
title: 解析后的事项
requirement: REQ-000011
stage: acceptance
covered:
  - platforms/macos/src/WorkstreamsPanel.swift
  base: 46e83f791115699ed012498586a81ebd055646e6
queues: [q-111]
updated: 2026-10-06
---

# WS-000060
""", path: "/tmp/WS-000060.md")
let parsedModel = WSCardModel.build(from: parsed)
eq(parsedModel.id, "WS-000060", "parsed id")
eq(parsedModel.stage, .acceptance, "parsed stage")
eq(parsedModel.stages.first { $0.stage == .acceptance }?.queueIDs, ["q-111"],
   "parsed queue lands on the current (acceptance) stage")
eq(parsedModel.stages.first { $0.stage == .task }?.queueIDs, [], "non-current stages carry no queue")
eq(parsedModel.stages.first { $0.stage == .acceptance }?.evidence.first?.value,
   "platforms/macos/src/WorkstreamsPanel.swift", "parsed covered evidence")

// MARK: - Stage gate surfaces on the card model

section("stage gate on the card model")
let fullPlanBody = """
## 规划

- 目标（WHAT）：交付门。
- 边界（做）：事项面板。
- 阶段裁剪声明：不裁剪。
- 验收标准：
  - AC1 通过。
"""
let gateCard = card(id: "WS-000070", stage: .planning, body: fullPlanBody)
let gate = WorkstreamsStageGate.evaluate(gateCard, carrier: .none)
let gatedModel = WSCardModel.build(from: gateCard, gate: gate)
let planningStage = gatedModel.stages.first { $0.stage == .planning }
eq(planningStage?.gateState, .awaitingConfirmation, "awaiting gate surfaces on the current stage")
eq(planningStage?.awaitingConfirmation, true, "awaiting flag")
eq(gatedModel.stages.first { $0.stage == .design }?.gateState == nil, true, "other stages carry no gate state")

let blockedCard = card(id: "WS-000071", stage: .planning, body: "## 规划\n")
let blockedGate = WorkstreamsStageGate.evaluate(blockedCard, carrier: .none)
let blockedModel = WSCardModel.build(from: blockedCard, gate: blockedGate)
let blockedStage = blockedModel.stages.first { $0.stage == .planning }
eq(blockedStage?.evidenceMissing, true, "evidence-missing flag")
check((blockedStage?.missingEvidenceKeys.isEmpty ?? true) == false, "missing evidence keys surface")

// MARK: - Derived run state (design A13 / D18)

func runTask(_ id: String, _ state: WSTaskState) -> WSTaskItem {
    WSTaskItem(id: id, title: id, state: state)
}

section("run state keys / tones")
eq(wsRunStateKey(.notStarted), "workstreams.run.notStarted", "notStarted key")
eq(wsRunStateKey(.inProgress), "workstreams.run.inProgress", "inProgress key")
eq(wsRunStateKey(.awaitingConfirmation), "workstreams.run.awaitingConfirmation", "awaiting key")
eq(wsRunStateKey(.done), "workstreams.run.done", "done key")
eq(wsRunStateKey(.blocked), "workstreams.run.blocked", "blocked key")
eq(wsRunStateTone(.notStarted), .neutral, "notStarted tone")
eq(wsRunStateTone(.inProgress), .running, "inProgress tone")
eq(wsRunStateTone(.awaitingConfirmation), .warning, "awaiting tone")
eq(wsRunStateTone(.done), .positive, "done tone")
eq(wsRunStateTone(.blocked), .negative, "blocked tone")

section("stage run state: position is authoritative")
eq(WSRunState.stage(stage: .acceptance, current: .task, tasks: []), .notStarted,
   "a future stage is not started")
eq(WSRunState.stage(stage: .planning, current: .task, tasks: []), .done,
   "a stage the human moved past is done")
eq(WSRunState.stage(stage: .planning, current: .task,
                    tasks: [runTask("x", .running)]), .done,
   "a past stage ignores its own tasks: the confirmed position is authoritative")

section("current stage from queue + task state")
eq(WSRunState.stage(stage: .task, current: .task, tasks: [runTask("a", .queued)],
                    queueState: .draft), .notStarted,
   "queued in a draft queue: created but not started")
eq(WSRunState.stage(stage: .task, current: .task, tasks: [runTask("a", .queued)],
                    queueState: .active), .inProgress,
   "queued in an active queue: in progress")
eq(WSRunState.stage(stage: .task, current: .task, tasks: [runTask("a", .running)],
                    queueState: .active), .inProgress,
   "a running task: in progress")
eq(WSRunState.stage(stage: .task, current: .task, tasks: [], queueState: .draft), .notStarted,
   "a current stage with no tasks is not started")

section("all done, not yet confirmed")
eq(WSRunState.stage(stage: .task, current: .task,
                    tasks: [runTask("a", .done), runTask("b", .done)], queueState: .done),
   .awaitingConfirmation, "all tasks done -> awaiting confirmation (R10)")
eq(WSRunState.stage(stage: .task, current: .task, tasks: [runTask("a", .done)],
                    queueState: .done, gateState: .evidenceMissing), .blocked,
   "all done but evidence missing -> blocked")
eq(WSRunState.stage(stage: .task, current: .task,
                    tasks: [runTask("a", .done), runTask("b", .running)], queueState: .active),
   .inProgress, "some done with work still open -> in progress")

section("blocked by a task")
for state in [WSTaskState.failed, .needsReview, .cancelled] {
    eq(WSRunState.stage(stage: .task, current: .task, tasks: [runTask("a", state)],
                        queueState: .paused), .blocked,
       "task " + state.rawValue + " -> blocked")
}

section("back edge: reject forces rework")
let rejectEntry = WSStageHistoryEntry(date: "2026-10-07", action: .reject, stage: .task,
                                      target: nil, reason: "没做完")
eq(WSRunState.reworkStage([rejectEntry]), .task, "reject without a target reworks in place")
eq(WSRunState.stage(stage: .task, current: .task, tasks: [runTask("a", .done)], queueState: .done,
                    history: [rejectEntry]), .inProgress,
   "a rejected all-done stage is rework, not awaiting")
let confirmEntry = WSStageHistoryEntry(date: "2026-10-08", action: .confirm, stage: .task,
                                       target: .acceptance, reason: nil)
eq(WSRunState.stage(stage: .task, current: .task, tasks: [runTask("a", .done)], queueState: .done,
                    history: [rejectEntry, confirmEntry]), .awaitingConfirmation,
   "a later confirm clears the rework")
let backEntry = WSStageHistoryEntry(date: "2026-10-09", action: .reject, stage: .acceptance,
                                    target: .planning, reason: "回到规划")
eq(WSRunState.reworkStage([backEntry]), .planning, "reject with a target reworks the target stage")
eq(WSRunState.stage(stage: .planning, current: .planning, tasks: [], queueState: .done,
                    history: [backEntry]), .notStarted, "planning sent back: rework not started")
eq(WSRunState.stage(stage: .task, current: .planning, tasks: [runTask("a", .done)],
                    queueState: .done, history: [backEntry]), .notStarted,
   "a stage after the sent-back position is future again")
let reworkBody = """
## 执行

## 阶段确认

- 2026-10-07 · reject · task · 需要返工
"""
let parsedRework = WorkstreamsStageGate.parseHistory(reworkBody)
eq(WSRunState.stage(stage: .task, current: .task, tasks: [runTask("a", .done)], queueState: .done,
                    history: parsedRework), .inProgress,
   "a reject parsed from the card body forces rework")

section("workstream run state: roll-up")
eq(WSRunState.workstream([.notStarted, .notStarted]), .notStarted, "all not started")
eq(WSRunState.workstream([.done, .inProgress, .notStarted]), .inProgress,
   "in progress outranks done / not started")
eq(WSRunState.workstream([.inProgress, .awaitingConfirmation]), .awaitingConfirmation,
   "awaiting confirmation outranks in progress")
eq(WSRunState.workstream([.awaitingConfirmation, .blocked]), .blocked,
   "blocked outranks awaiting confirmation")
let deliveryConfirm = WSStageHistoryEntry(date: "2026-10-10", action: .confirm, stage: .delivery,
                                          target: nil, reason: nil)
eq(WSRunState.workstream([.inProgress, .blocked], history: [deliveryConfirm]), .done,
   "a confirmed terminal delivery is done")
eq(WSRunState.deliveryConfirmed([deliveryConfirm]), true, "delivery confirmed")
eq(WSRunState.deliveryConfirmed([rejectEntry]), false, "a reject is not a delivery confirmation")

section("run state on the card model")
var runBoard = WSBoard()
let runQueue = runBoard.createQueue(name: "Q", workstreamID: "WS-000090")
runBoard.tasks.append(WSTaskItem(id: "wt-run", title: "执行任务",
                                 workstreamId: "WS-000090", stage: .task))
_ = runBoard.enqueue(taskID: "wt-run", into: runQueue.id)
_ = runBoard.resumeQueue(runQueue.id)
let runCard = WSCardModel.build(from: card(id: "WS-000090", stage: .task, queues: [runQueue.id]),
                                board: runBoard)
eq(runCard.stages.first { $0.stage == .task }?.runState, .inProgress,
   "card model surfaces the stage run state")
eq(runCard.stages.first { $0.stage == .task }?.runStateKey, "workstreams.run.inProgress",
   "stage run state key")
eq(runCard.stages.first { $0.stage == .task }?.runStateTone, .running, "stage run state tone")
eq(runCard.stages.first { $0.stage == .planning }?.runState, .done,
   "a confirmed earlier stage reads done")
eq(runCard.stages.first { $0.stage == .delivery }?.runState, .notStarted,
   "a future stage reads not started")
eq(runCard.runState, .inProgress, "card model surfaces the workstream run state")
eq(runCard.runStateKey, "workstreams.run.inProgress", "workstream run state key")

var awaitingBoard = WSBoard()
let awaitingQueue = awaitingBoard.createQueue(name: "Q2", workstreamID: "WS-000091")
awaitingBoard.tasks.append(WSTaskItem(id: "wt-a", title: "验收任务",
                                      workstreamId: "WS-000091", stage: .acceptance))
_ = awaitingBoard.enqueue(taskID: "wt-a", into: awaitingQueue.id)
awaitingBoard.markDone("wt-a")
let awaitingCard = WSCardModel.build(from: card(id: "WS-000091", stage: .acceptance,
                                                queues: [awaitingQueue.id]), board: awaitingBoard)
eq(awaitingCard.stages.first { $0.stage == .acceptance }?.runState, .awaitingConfirmation,
   "all done unconfirmed on the card model")
eq(awaitingCard.runState, .awaitingConfirmation, "the workstream waits for the human")

var blockedBoard = WSBoard()
let blockedQueue = blockedBoard.createQueue(name: "Q3", workstreamID: "WS-000092")
blockedBoard.tasks.append(WSTaskItem(id: "wt-f", title: "失败任务",
                                     workstreamId: "WS-000092", stage: .task))
_ = blockedBoard.enqueue(taskID: "wt-f", into: blockedQueue.id)
_ = blockedBoard.markFailed("wt-f", error: "workstreams.errPrompt")
let blockedRunCard = WSCardModel.build(from: card(id: "WS-000092", stage: .task,
                                                  queues: [blockedQueue.id]), board: blockedBoard)
eq(blockedRunCard.stages.first { $0.stage == .task }?.runState, .blocked,
   "a failed task blocks the stage")
eq(blockedRunCard.runState, .blocked, "a blocked stage blocks the workstream")

// MARK: - Focus channel

section("focus channel")
eq(wsFocusedID("  WS-000001  "), "WS-000001", "focus id trimmed")
eq(wsFocusedID("   "), nil, "blank focus id is nil")
eq(wsFocusedID(nil), nil, "nil focus id is nil")

let focusSnapshot = snapshot(all)
let focusAll = WSFocusTarget.resolve("WS-000051", snapshot: focusSnapshot, filter: .all)
eq(focusAll?.workstreamID, "WS-000051", "focus resolves the target id")
eq(focusAll?.filter, .all, "an all filter is kept")
eq(focusAll?.index, 1, "index within the all board")

let focusMatching = WSFocusTarget.resolve(" WS-000051 ", snapshot: focusSnapshot, filter: .stage(.design))
eq(focusMatching?.filter, .stage(.design), "a matching stage filter is kept")
eq(focusMatching?.index, 0, "index within the stage-filtered board")

let focusHidden = WSFocusTarget.resolve("WS-000050", snapshot: focusSnapshot, filter: .stage(.design))
eq(focusHidden?.filter, .all, "a hidden target falls back to the all view")
eq(focusHidden?.index, 0, "index within the all board after fallback")

eq(WSFocusTarget.resolve("WS-000099", snapshot: focusSnapshot, filter: .all), nil,
   "unknown workstream resolves to nil")
eq(WSFocusTarget.resolve("  ", snapshot: focusSnapshot, filter: .all), nil,
   "blank id resolves to nil")

// MARK: - Report

print("")
if failures == 0 {
    print("workstreams-ui model tests passed (\(checks) checks)")
} else {
    print("workstreams-ui model tests FAILED: \(failures)/\(checks)")
    exit(1)
}
