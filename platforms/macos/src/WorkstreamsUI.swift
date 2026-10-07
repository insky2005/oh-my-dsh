//
//  WorkstreamsUI.swift — pure view models for the Workstreams panel (slot #11).
//
//  The panel renders a THREE-LEVEL card tree (design A2 / §3.1):
//
//      WS 主卡 (primary)     one workstream, its stage history and its queues
//        └─ 阶段二级卡 (stage)  planning / design / task / acceptance / delivery
//             └─ 任务三级卡 (task)  the stage queue's entries
//
//  Every rule that decides WHAT a card says — the card model, the top stage
//  filter and the empty state — lives here and is asserted headlessly in
//  tests/workstreams-panel/ui-tests.swift. The views only place labels and
//  forward clicks. Foundation only: no AppKit, no L10n, no task-panel types
//  (mirrors TasksUI.swift / RequirementsUI.swift).
//

import Foundation

// MARK: - Tone

/// Visual weight of a badge. The views map it to the shell's existing palette
/// (PanelControl / system colors) — this file introduces no colour token.
enum WSTone: Equatable {
    case neutral
    case running
    case positive
    case warning
    case negative
}

// MARK: - Stage labels

/// L10n key for a stage label. Written as a switch (not "workstreams.stage." +
/// rawValue) so the L10n lint can see every key.
func wsStageLabelKey(_ stage: WorkstreamStage) -> String {
    switch stage {
    case .planning: return "workstreams.stage.planning"
    case .design: return "workstreams.stage.design"
    case .task: return "workstreams.stage.task"
    case .acceptance: return "workstreams.stage.acceptance"
    case .delivery: return "workstreams.stage.delivery"
    }
}

/// The stage's tone in the badge ladder: 执行 is the panel's "current" (a running
/// task), 验收 waits on a human (warning), 交付 is the positive terminal.
func wsStageTone(_ stage: WorkstreamStage) -> WSTone {
    switch stage {
    case .planning: return .neutral
    case .design: return .neutral
    case .task: return .running
    case .acceptance: return .warning
    case .delivery: return .positive
    }
}

// MARK: - Task state (tertiary card)

/// L10n key + tone for one queue task state. A switch (not a string built from
/// the raw value) so the L10n lint can see every key.
func wsTaskStateKey(_ state: WSTaskState) -> String {
    switch state {
    case .pending: return "workstreams.task.state.pending"
    case .queued: return "workstreams.task.state.queued"
    case .running: return "workstreams.task.state.running"
    case .done: return "workstreams.task.state.done"
    case .failed: return "workstreams.task.state.failed"
    case .needsReview: return "workstreams.task.state.needsReview"
    case .cancelled: return "workstreams.task.state.cancelled"
    }
}

func wsTaskTone(_ state: WSTaskState) -> WSTone {
    switch state {
    case .running: return .running
    case .done: return .positive
    case .failed: return .negative
    case .needsReview, .cancelled: return .warning
    case .pending, .queued: return .neutral
    }
}

// MARK: - Derived run state (design A13)

/// L10n key for a derived run state (a stage's, rolled up to the workstream's).
/// A switch, not a string built from the raw value, so the L10n lint sees every
/// key. The state itself is computed in WorkstreamsRunState.swift.
func wsRunStateKey(_ state: WSRunState) -> String {
    switch state {
    case .notStarted: return "workstreams.run.notStarted"
    case .inProgress: return "workstreams.run.inProgress"
    case .awaitingConfirmation: return "workstreams.run.awaitingConfirmation"
    case .done: return "workstreams.run.done"
    case .blocked: return "workstreams.run.blocked"
    }
}

func wsRunStateTone(_ state: WSRunState) -> WSTone {
    switch state {
    case .notStarted: return .neutral
    case .inProgress: return .running
    case .awaitingConfirmation: return .warning
    case .done: return .positive
    case .blocked: return .negative
    }
}

// MARK: - Card lines

/// One label + value line on a card (meta / stage evidence). labelKey is an L10n
/// key; value is raw authored text the view renders verbatim.
struct WSLine: Equatable {
    var labelKey: String
    var value: String
}

// MARK: - Tertiary card (task)

/// One tertiary card: a task of the workstream queue (design A2 / A12). The card
/// shows the task state badge and its dsh session, so the stage view is the place
/// the run is observed (design §5 / D18).
struct WSTaskCardModel: Equatable {
    var id: String
    var title: String
    /// State badge (an L10n key).
    var stateKey: String?
    var tone: WSTone
    var detail: String
    /// The dsh session the task runs in (machine-private, shown read-only).
    var sessionId: String?
    /// A failure / review reason (an L10n key), rendered in its tone.
    var errorKey: String?
    var isExpanded: Bool

    static func build(id: String,
                      title: String,
                      stateKey: String? = nil,
                      tone: WSTone = .neutral,
                      detail: String = "",
                      sessionId: String? = nil,
                      errorKey: String? = nil,
                      isExpanded: Bool = false) -> WSTaskCardModel {
        WSTaskCardModel(id: id, title: title, stateKey: stateKey, tone: tone,
                        detail: detail, sessionId: sessionId, errorKey: errorKey,
                        isExpanded: isExpanded)
    }

    /// Build from the queue engine's task item (design A13): state -> badge tone,
    /// report -> detail, error -> L10n key.
    static func build(from task: WSTaskItem, isExpanded: Bool = false) -> WSTaskCardModel {
        let report = task.report?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return WSTaskCardModel(id: task.id,
                               title: task.title,
                               stateKey: wsTaskStateKey(task.state),
                               tone: wsTaskTone(task.state),
                               detail: report,
                               sessionId: task.sessionId,
                               errorKey: task.error,
                               isExpanded: isExpanded)
    }
}

// MARK: - Secondary card (stage)

/// One secondary card: a stage of one workstream. A stage is a STATE, not a
/// site (design §3.2), so every workstream renders all five stage cards in the
/// canonical order; exactly one isCurrent, and history / future read the same.
struct WSStageCardModel: Equatable {
    var stage: WorkstreamStage
    var isCurrent: Bool
    var tasks: [WSTaskCardModel]
    var evidence: [WSLine]
    var isExpanded: Bool
    /// Gate state for the current stage; nil on the other four stage cards.
    var gateState: WSStageGateState? = nil
    /// L10n keys of the machine evidence still missing (a blocked gate).
    var missingEvidenceKeys: [String] = []
    /// The DERIVED runtime state (design A13): task states -> stage run state.
    /// It is not the authoritative stage, which only the human gate moves.
    var runState: WSRunState = .notStarted

    var labelKey: String { wsStageLabelKey(stage) }
    var tone: WSTone { wsStageTone(stage) }
    var runStateKey: String { wsRunStateKey(runState) }
    var runStateTone: WSTone { wsRunStateTone(runState) }
    var taskCount: Int { tasks.count }
    /// The stage queue finished with evidence and waits for a person (R10).
    var awaitingConfirmation: Bool { isCurrent && gateState == .awaitingConfirmation }
    /// The stage queue finished but the machine predicate fails: cannot advance.
    var evidenceMissing: Bool { isCurrent && gateState == .evidenceMissing }
}

// MARK: - Primary card (workstream)

/// One primary card: a workstream plus its five stage cards.
struct WSCardModel: Equatable {
    var id: String
    var title: String
    var requirement: String?
    var stage: WorkstreamStage
    /// The workstream's queue ids, shown as neutral badges on the MAIN card's
    /// title row. There is at most one queue per workstream (design A9 / D16);
    /// a queue belongs to the workstream, not to whichever stage is current.
    var queueIDs: [String]
    var tone: WSTone
    var meta: [WSLine]
    var detail: String
    var stages: [WSStageCardModel]
    var isExpanded: Bool
    var path: String
    /// The DERIVED workstream runtime state (design A13): the roll-up of the
    /// five stage run states. The authoritative `stage` above is untouched.
    var runState: WSRunState = .notStarted

    var stageLabelKey: String { wsStageLabelKey(stage) }
    var runStateKey: String { wsRunStateKey(runState) }
    var runStateTone: WSTone { wsRunStateTone(runState) }

    /// Build one workstream card. All five stage cards are always present (in
    /// WorkstreamStage.allCases order). The workstream's queue ids hang off the
    /// MAIN card (design A9 / D16) and are never repeated on a stage card; each
    /// stage's tasks are grouped by the task's own `stage` (A12 / D17). `board`
    /// is the queue engine's board (nil while there is no queue storage yet:
    /// every task list is then empty).
    static func build(from card: WorkstreamCard, gate: WSStageGate? = nil,
                      board: WSBoard? = nil) -> WSCardModel {
        let queue = board?.queue(forWorkstream: card.id, mapping: card.queues)
        let queueTasks = queue.flatMap { board?.tasks(inQueue: $0.id) } ?? []
        // The human-decision audit trail (confirm / reject, R2 / R10): the back
        // edge is what tells a rejected stage apart from a freshly finished one.
        let history = WorkstreamsStageGate.parseHistory(card.body)
        let stages = WorkstreamStage.allCases.map { stage -> WSStageCardModel in
            let stageGate = (gate?.stage == stage) ? gate : nil
            // A task's stage is a direct property (A12); a legacy task without one
            // belongs to the card's current stage.
            let stageItems = queueTasks.filter { ($0.stage ?? card.stage) == stage }
            let stageTasks = stageItems.map { WSTaskCardModel.build(from: $0) }
            // Derived run state (A13): pure function of the task states plus the
            // authoritative position. Never moves `card.stage`.
            let runState = WSRunState.stage(stage: stage, current: card.stage,
                                            tasks: stageItems,
                                            queueState: queue?.state,
                                            gateState: stageGate?.state,
                                            history: history)
            return WSStageCardModel(stage: stage,
                                    isCurrent: stage == card.stage,
                                    tasks: stageTasks,
                                    evidence: evidence(for: stage, card: card),
                                    isExpanded: false,
                                    gateState: stageGate?.state,
                                    missingEvidenceKeys: stageGate?.evidence.missingKeys ?? [],
                                    runState: runState)
        }
        var meta: [WSLine] = []
        if let requirement = card.requirement, !requirement.isEmpty {
            meta.append(WSLine(labelKey: "workstreams.meta.requirement", value: requirement))
        }
        if !card.queues.isEmpty {
            meta.append(WSLine(labelKey: "workstreams.meta.queues", value: String(card.queues.count)))
        }
        if let regression = card.regression, !regression.isEmpty {
            meta.append(WSLine(labelKey: "workstreams.meta.regression", value: regression))
        }
        if let updated = card.updated, !updated.isEmpty {
            meta.append(WSLine(labelKey: "workstreams.meta.updated", value: updated))
        }
        return WSCardModel(id: card.id,
                           title: card.title,
                           requirement: card.requirement,
                           stage: card.stage,
                           queueIDs: card.queues,
                           tone: wsStageTone(card.stage),
                           meta: meta,
                           detail: card.body.trimmingCharacters(in: .whitespacesAndNewlines),
                           stages: stages,
                           isExpanded: true,
                           path: card.path,
                           runState: WSRunState.workstream(stages.map { $0.runState },
                                                           history: history))
    }

    /// The stage-level machine evidence (store design §3.2): covered at 验收,
    /// the delivery facts at 交付.
    static func evidence(for stage: WorkstreamStage, card: WorkstreamCard) -> [WSLine] {
        switch stage {
        case .acceptance:
            guard let covered = card.covered, !covered.paths.isEmpty else { return [] }
            var lines = [WSLine(labelKey: "workstreams.evidence.covered",
                                value: covered.paths.joined(separator: ", "))]
            if let base = covered.base, !base.isEmpty {
                lines.append(WSLine(labelKey: "workstreams.evidence.base", value: base))
            }
            if let head = covered.head, !head.isEmpty {
                lines.append(WSLine(labelKey: "workstreams.evidence.head", value: head))
            }
            return lines
        case .delivery:
            guard let delivery = card.delivery else { return [] }
            var lines: [WSLine] = []
            if let pr = delivery.pr {
                lines.append(WSLine(labelKey: "workstreams.evidence.pr", value: "#" + String(pr)))
            }
            if let outcome = delivery.outcome, !outcome.isEmpty {
                lines.append(WSLine(labelKey: "workstreams.evidence.outcome", value: outcome))
            }
            if let url = delivery.url, !url.isEmpty {
                lines.append(WSLine(labelKey: "workstreams.evidence.url", value: url))
            }
            return lines
        default:
            return []
        }
    }
}

// MARK: - Stage filter

/// The top stage view / filter: 全部 plus the five stage views.
enum WSStageFilter: Equatable, CaseIterable {
    case all
    case stage(WorkstreamStage)

    static var allCases: [WSStageFilter] {
        [.all] + WorkstreamStage.allCases.map { WSStageFilter.stage($0) }
    }

    var stage: WorkstreamStage? {
        if case .stage(let stage) = self { return stage }
        return nil
    }

    var isAll: Bool { self == .all }

    var labelKey: String {
        switch self {
        case .all: return "workstreams.filter.all"
        case .stage(let stage): return wsStageLabelKey(stage)
        }
    }

    /// 全部 matches everything; a stage view only its own stage (a stage is a
    /// state, so a workstream appears under exactly one stage filter).
    func matches(_ card: WorkstreamCard) -> Bool {
        guard let stage = stage else { return true }
        return card.stage == stage
    }

    func filter(_ cards: [WorkstreamCard]) -> [WorkstreamCard] {
        cards.filter(matches)
    }
}

// MARK: - Empty state

/// What the centered empty area says. Three distinct states: no workspace, no
/// workstreams at all, and no workstream in the selected stage.
struct WSEmptyStateModel: Equatable {
    var messageKey: String
    /// True only when the pool itself is empty (a filter miss is not).
    var isPoolEmpty: Bool

    static func build(hasWorkspace: Bool, totalCount: Int, filter: WSStageFilter) -> WSEmptyStateModel {
        if !hasWorkspace {
            return WSEmptyStateModel(messageKey: "workstreams.needsWorkspace", isPoolEmpty: false)
        }
        if totalCount == 0 {
            return WSEmptyStateModel(messageKey: "workstreams.empty", isPoolEmpty: true)
        }
        return WSEmptyStateModel(messageKey: "workstreams.empty.filter", isPoolEmpty: false)
    }
}

// MARK: - Default expansion (UX)

/// The default expansion of a rendered board (UX): only the FIRST workstream
/// that is not 完成 (runState != .done) starts expanded; every other card is
/// collapsed. When every workstream is done, nothing is expanded. "Unprocessed"
/// is the derived run state (design A13: notStarted / inProgress /
/// awaitingConfirmation / blocked); the authoritative `stage` is not consulted.
func wsDefaultExpandedID(_ cards: [WSCardModel]) -> String? {
    cards.first { $0.runState != .done }?.id
}

/// Apply the default expansion to freshly built cards: exactly the card named by
/// `wsDefaultExpandedID` (if any) is expanded, the rest are collapsed. Called on
/// every load / redraw so the board always opens on the first unprocessed item.
func wsApplyingDefaultExpansion(_ cards: [WSCardModel]) -> [WSCardModel] {
    let expandedID = wsDefaultExpandedID(cards)
    return cards.map { card in
        var card = card
        card.isExpanded = (card.id == expandedID)
        return card
    }
}

/// The FIRST unprocessed stage of a workstream (UX: the「拆分任务」button target):
/// the first stage in canonical order (`WorkstreamStage.allCases`) whose derived
/// run state is not 完成. "Unprocessed" reuses the A13 derived run state, so the
/// authoritative `stage` is never consulted and a stage the human already
/// confirmed reads `.done`. Returns nil when every stage is done (nothing to
/// split). Pure: asserted headlessly in ui-tests.swift.
func wsFirstUnprocessedStage(_ card: WSCardModel) -> WorkstreamStage? {
    card.stages.first { $0.runState != .done }?.stage
}

// MARK: - Stage task composer (「创建任务」drawer, UX)

/// The 「创建任务」drawer's pure view model: a stage selector plus ONE box whose
/// first line is the title and whose remaining lines are the task content. It is
/// the panel's direct counterpart to the agent-facing `task/create` route: the
/// task is created in the WAITING state and appended to the workstream's single
/// queue — nothing starts here (the workstream card's 「启动事项」 does).
///
/// The stage defaults to the workstream's first unprocessed stage
/// (`wsFirstUnprocessedStage`), the same A13-derived target the 「拆分任务」
/// button uses. Pure, so the typing / submit rules are asserted headlessly.
struct WSStageTaskComposerModel: Equatable {
    var stage: WorkstreamStage
    /// The box exactly as typed: first line = title, the lines after it = content.
    var content: String
    /// Set once submit was pressed on an incomplete draft, so the hint shows up
    /// when it is actually needed rather than while typing.
    var attempted: Bool

    /// The stages the selector offers, in canonical order.
    static let stages = WorkstreamStage.allCases

    /// The first line, trimmed — the task title (empty means "not submittable").
    var title: String {
        (content.components(separatedBy: .newlines).first ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The lines after the first, trimmed — the task content appended below the
    /// stage handoff prompt. Empty when only a title was typed.
    var body: String {
        content.components(separatedBy: .newlines).dropFirst()
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSubmit: Bool { !title.isEmpty }

    /// The first problem as an L10n key — shown only after a submit attempt (the
    /// button stays disabled until the title is there, so the form never nags
    /// while it is being typed into).
    var problemKey: String? { attempted && !canSubmit ? "workstreams.task.create.empty" : nil }

    var headingKey: String { "workstreams.task.create.title" }
    var submitKey: String { "workstreams.task.create.submit" }
    var infoKey: String { "workstreams.task.create.message" }

    var isPristine: Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The form as it is while the user types (live, so the submit button follows
    /// what is actually in the box).
    func typed(content: String) -> WSStageTaskComposerModel {
        var copy = self
        copy.content = content
        return copy
    }

    /// Pick a different stage in the selector.
    func typed(stage: WorkstreamStage) -> WSStageTaskComposerModel {
        var copy = self
        copy.stage = stage
        return copy
    }

    /// The form after a submit attempt (turns on the problem hint).
    func attemptedSubmit() -> WSStageTaskComposerModel {
        var copy = self
        copy.attempted = true
        return copy
    }

    static func build(stage: WorkstreamStage, content: String = "") -> WSStageTaskComposerModel {
        WSStageTaskComposerModel(stage: stage, content: content, attempted: false)
    }

    /// The drawer's default for one rendered card: the first unprocessed stage,
    /// falling back to the authoritative stage when every stage is done.
    static func forCard(_ card: WSCardModel) -> WSStageTaskComposerModel {
        build(stage: wsFirstUnprocessedStage(card) ?? card.stage)
    }
}

// MARK: - The filtered board

/// The whole board the panel renders: the cards for the active filter, the
/// filter itself, and (when nothing matches) the empty state.
struct WSBoardModel: Equatable {
    var cards: [WSCardModel]
    var filter: WSStageFilter
    var hasWorkspace: Bool
    var totalCount: Int

    var isEmpty: Bool { cards.isEmpty }

    var emptyState: WSEmptyStateModel? {
        guard isEmpty else { return nil }
        return WSEmptyStateModel.build(hasWorkspace: hasWorkspace,
                                       totalCount: totalCount,
                                       filter: filter)
    }

    static func build(snapshot: WorkstreamsSnapshot, filter: WSStageFilter,
                      gates: [String: WSStageGate] = [:],
                      board: WSBoard? = nil) -> WSBoardModel {
        let selected = filter.filter(snapshot.workstreams)
        let built = selected.map { WSCardModel.build(from: $0, gate: gates[$0.id], board: board) }
        // UX: on load / redraw only the first unprocessed card opens (see
        // wsApplyingDefaultExpansion); every other card starts collapsed.
        let cards = wsApplyingDefaultExpansion(built)
        return WSBoardModel(cards: cards,
                            filter: filter,
                            hasWorkspace: !snapshot.workspace.isEmpty,
                            totalCount: snapshot.workstreams.count)
    }
}

// MARK: - Focus channel

/// Trim a focus id; nil when blank. Shared by the panel and the API hook so a
/// whitespace-only id never counts as a focus request.
func wsFocusedID(_ raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    return trimmed
}

/// Where one focus request lands (the focus channel): which workstream to
/// highlight, the filter that makes it visible, and its index in that filter's
/// board. The panel turns it into an accent ring + a scroll. Pure, so the rule
/// "a card hidden by the active stage filter falls back to 全部" is unit-tested
/// without AppKit.
struct WSFocusTarget: Equatable {
    var workstreamID: String
    var filter: WSStageFilter
    var index: Int

    /// nil when the id is blank or no card carries it. The index counts within
    /// the RESOLVED filter's card list; the filter is the active one unless it
    /// hides the card, in which case 全部 is used so the highlight is never
    /// invisible.
    static func resolve(_ id: String?, snapshot: WorkstreamsSnapshot,
                        filter: WSStageFilter) -> WSFocusTarget? {
        guard let id = wsFocusedID(id) else { return nil }
        guard let card = snapshot.workstreams.first(where: { $0.id == id }) else { return nil }
        if filter.matches(card) {
            let index = filter.filter(snapshot.workstreams).firstIndex { $0.id == id } ?? 0
            return WSFocusTarget(workstreamID: id, filter: filter, index: index)
        }
        let index = snapshot.workstreams.firstIndex { $0.id == id } ?? 0
        return WSFocusTarget(workstreamID: id, filter: .all, index: index)
    }
}
