//
//  WorkstreamsRunState.swift — derived runtime state (design A13 / D18).
//
//  A workstream's authoritative `stage` only moves through the human
//  confirmation gate (R10). The RUN state is a separate, automatic, DERIVED view:
//
//      task states  ->  stage run state  ->  workstream run state
//
//  Nothing in this file writes: it reads the queue engine's task states (and the
//  card's human-decision audit trail, for the back edge) and returns one of five
//  labels the panel shows as a badge. The authoritative `stage` is NEVER
//  touched here — a stage that reads "done" is one the human already confirmed,
//  not one this predicate advanced.
//
//      notStarted           未开始  the stage has no started work yet
//      inProgress           进行中  a live queue / running (or partly done) work
//      awaitingConfirmation 待确认  every task is done, waiting on a person (R10)
//      done                 完成    a human confirmed it (the stage moved past it)
//      blocked              阻塞    a task failed/cancelled, or evidence is missing
//
//  Pure Foundation: no AppKit, no L10n, no tasks-panel types. Asserted headlessly
//  in tests/workstreams-panel/ui-tests.swift.
//

import Foundation

// MARK: - Run state

/// The five derived run states. The same enum labels a stage and (rolled up) a
/// whole workstream: the workstream state is the strongest of its four stages.
enum WSRunState: String, Equatable, CaseIterable {
    case notStarted
    case inProgress
    case awaitingConfirmation
    case done
    case blocked

    /// How strongly a state claims the workstream's headline. A completed
    /// (confirmed) stage does NOT make the workstream done — that is the whole
    /// point of acceptanceConfirmed; it only outranks "not started yet". The
    /// strongest live claim wins: blocked > awaiting > in progress.
    var severity: Int {
        switch self {
        case .notStarted: return 0
        case .done: return 1
        case .inProgress: return 2
        case .awaitingConfirmation: return 3
        case .blocked: return 4
        }
    }
}

// MARK: - Derivation

extension WSRunState {

    /// The stage a back edge (reject) last sent back for rework, or nil when the
    /// most recent human decision was not a reject. A reject with a target means
    /// "go back to that stage"; without one it means "rework where you are".
    static func reworkStage(_ history: [WSStageHistoryEntry]) -> WorkstreamStage? {
        guard let last = history.last, last.action == .reject else { return nil }
        return last.target ?? last.stage
    }

    /// The terminal acceptance stage was confirmed. Acceptance has no next
    /// stage, so a confirm of it leaves `stage` at acceptance and is only
    /// visible in the audit trail. Legacy cards whose 交付 confirm was written
    /// when delivery was a stage parse to acceptance too (read-compat), so they
    /// still read as confirmed.
    static func acceptanceConfirmed(_ history: [WSStageHistoryEntry]) -> Bool {
        history.contains { $0.action == .confirm && $0.stage == .acceptance }
    }

    /// The runtime state of one stage, derived from the queue engine's tasks and
    /// the authoritative stage position. `stage` is only READ.
    ///
    /// - Parameters:
    ///   - stage: the stage being described.
    ///   - current: the card's authoritative stage (moved only by the human gate).
    ///   - tasks: the queue tasks whose own `stage` is `stage` (legacy
    ///     tasks without a stage belong to the current stage — see the UI model).
    ///   - queueState: the workstream's execution queue, when known. A draft
    ///     queue whose tasks have only been *created* (waiting state) is not
    ///     "in progress" yet.
    ///   - gateState: the machine-evidence gate for the current stage, when known.
    ///   - history: the card's human-decision audit trail (back edges / terminal
    ///     confirmation).
    static func stage(stage: WorkstreamStage,
                      current: WorkstreamStage,
                      tasks: [WSTaskItem],
                      queueState: WSQueueState? = nil,
                      gateState: WSStageGateState? = nil,
                      history: [WSStageHistoryEntry] = []) -> WSRunState {
        // A confirmed terminal stage is the one stage the position rule cannot
        // resolve (acceptance never advances).
        if stage == .acceptance && acceptanceConfirmed(history) { return .done }
        // The authoritative stage advanced past this one — and it only advances
        // through a human confirmation, so this stage is done.
        if stage.orderIndex < current.orderIndex { return .done }
        // A stage the workstream has not reached yet.
        if stage.orderIndex > current.orderIndex { return .notStarted }

        // The current stage: derived from the queue state and its tasks.
        if tasks.contains(where: { $0.state == .failed || $0.state == .cancelled
            || $0.state == .needsReview }) { return .blocked }

        let allDone = !tasks.isEmpty && tasks.allSatisfy { $0.state == .done }
        if allDone {
            // A rejected stage that has not been re-confirmed is rework, not a
            // fresh waiting-on-confirmation.
            if reworkStage(history) == stage { return .inProgress }
            if gateState == .evidenceMissing { return .blocked }
            return .awaitingConfirmation
        }

        // Started (or was started): the queue is live, was resumed, or already
        // produced a finished task. A merely-draft queue has not started.
        // A stage with no tasks has nothing running, whatever the shared queue
        // is doing with other stages' tasks.
        if tasks.isEmpty { return .notStarted }
        if tasks.contains(where: { $0.state == .running }) { return .inProgress }
        switch queueState {
        case .active?, .paused?, .done?: return .inProgress
        default:
            // A draft (or absent) queue: a finished task still means work began.
            return tasks.contains(where: { $0.state == .done }) ? .inProgress : .notStarted
        }
    }

    /// The workstream run state: the roll-up of its four stage run states. A
    /// confirmed terminal wins; otherwise the strongest stage claim wins.
    static func workstream(_ stages: [WSRunState],
                           history: [WSStageHistoryEntry] = []) -> WSRunState {
        if acceptanceConfirmed(history) { return .done }
        return stages.max(by: { $0.severity < $1.severity }) ?? .notStarted
    }
}
