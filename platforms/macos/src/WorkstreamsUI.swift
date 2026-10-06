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

// MARK: - Card lines

/// One label + value line on a card (meta / stage evidence). labelKey is an L10n
/// key; value is raw authored text the view renders verbatim.
struct WSLine: Equatable {
    var labelKey: String
    var value: String
}

// MARK: - Tertiary card (task)

/// One tertiary card: a task owned by a stage queue. Task storage is the queue
/// runner's deliverable, so the panel renders whatever the local queue store
/// hands it and stays empty until that lands.
struct WSTaskCardModel: Equatable {
    var id: String
    var title: String
    /// Optional state badge (an L10n key); nil until the queue store exists.
    var stateKey: String?
    var tone: WSTone
    var detail: String
    var isExpanded: Bool

    static func build(id: String,
                      title: String,
                      stateKey: String? = nil,
                      tone: WSTone = .neutral,
                      detail: String = "",
                      isExpanded: Bool = false) -> WSTaskCardModel {
        WSTaskCardModel(id: id, title: title, stateKey: stateKey, tone: tone,
                        detail: detail, isExpanded: isExpanded)
    }
}

// MARK: - Secondary card (stage)

/// One secondary card: a stage of one workstream. A stage is a STATE, not a
/// site (design §3.2), so every workstream renders all five stage cards in the
/// canonical order; exactly one isCurrent, and history / future read the same.
struct WSStageCardModel: Equatable {
    var stage: WorkstreamStage
    var isCurrent: Bool
    /// Queue ids mapped to this stage (WS.queues [{id, stage}]).
    var queueIDs: [String]
    var tasks: [WSTaskCardModel]
    var evidence: [WSLine]
    var isExpanded: Bool

    var labelKey: String { wsStageLabelKey(stage) }
    var tone: WSTone { wsStageTone(stage) }
    var hasQueue: Bool { !queueIDs.isEmpty }
    var taskCount: Int { tasks.count }
}

// MARK: - Primary card (workstream)

/// One primary card: a workstream plus its five stage cards.
struct WSCardModel: Equatable {
    var id: String
    var title: String
    var requirement: String?
    var stage: WorkstreamStage
    var tone: WSTone
    var meta: [WSLine]
    var detail: String
    var stages: [WSStageCardModel]
    var isExpanded: Bool
    var path: String

    var stageLabelKey: String { wsStageLabelKey(stage) }

    /// Build one workstream card. All five stage cards are always present (in
    /// WorkstreamStage.allCases order). A queue lands in its own stage; a legacy
    /// queue with no stage stays read-compatible by falling back to the card's
    /// current stage (design §9.1).
    static func build(from card: WorkstreamCard) -> WSCardModel {
        let stages = WorkstreamStage.allCases.map { stage -> WSStageCardModel in
            let queueIDs = card.queues
                .filter { effectiveStage($0, fallback: card.stage) == stage }
                .map { $0.id }
            return WSStageCardModel(stage: stage,
                                    isCurrent: stage == card.stage,
                                    queueIDs: queueIDs,
                                    tasks: [],
                                    evidence: evidence(for: stage, card: card),
                                    isExpanded: false)
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
                           tone: wsStageTone(card.stage),
                           meta: meta,
                           detail: card.body.trimmingCharacters(in: .whitespacesAndNewlines),
                           stages: stages,
                           isExpanded: true,
                           path: card.path)
    }

    /// The stage whose card a queue belongs to (legacy nil falls back).
    static func effectiveStage(_ queue: WorkstreamQueue, fallback: WorkstreamStage) -> WorkstreamStage {
        queue.stage ?? fallback
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

    static func build(snapshot: WorkstreamsSnapshot, filter: WSStageFilter) -> WSBoardModel {
        let selected = filter.filter(snapshot.workstreams)
        return WSBoardModel(cards: selected.map(WSCardModel.build(from:)),
                            filter: filter,
                            hasWorkspace: !snapshot.workspace.isEmpty,
                            totalCount: snapshot.workstreams.count)
    }
}
