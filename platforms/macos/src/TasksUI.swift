import Foundation

// MARK: - View models for the task list
//
// The card list is pure presentation on top of these: every rule that decides
// WHAT a card says (badges, meta line, which button is offered) lives here and
// is asserted headlessly in tests/tasks-panel. The views themselves only place
// labels and forward clicks.

/// Visual weight of a badge — the views map it to a color.
enum TaskTone: Equatable {
    case neutral
    case running
    case positive
    case warning
    case negative
}

/// Everything one task card shows.
struct TaskCardModel: Equatable {
    var taskID: String
    var isExpanded: Bool
    var sourceBadge: String
    var stateBadge: String
    var tone: TaskTone
    var title: String
    /// Labels, branch and PR — the one-line summary under the title.
    var meta: [String]
    /// Queue name, session id, error and the task body (the expanded area).
    var detail: String

    var primaryKey: String
    var primaryEnabled: Bool
    var canQueue: Bool
    var canDequeue: Bool
    var canCancel: Bool
    var canRetry: Bool
    var canCommentClose: Bool
    var canEdit: Bool
    var canDelete: Bool

    /// 1-based position inside its queue, when it is waiting.
    var queuePosition: Int?
    var source: TaskSource
    var state: TaskState

    /// Build the card for a task. githubRepo is false in a non-GitHub workspace,
    /// which hides everything that would talk to GitHub.
    static func build(_ task: TaskItem,
                      board: TaskBoard,
                      expanded: Bool,
                      githubRepo: Bool) -> TaskCardModel {
        let queue = task.queueId.flatMap { board.queue($0) }
        let position = board.order(of: task.id)

        let sourceBadge: String
        switch task.source {
        case .github: sourceBadge = L10n.tr("tasks.source.github", task.number ?? 0)
        case .manual: sourceBadge = L10n.tr("tasks.source.manual")
        }

        let stateBadge: String
        let tone: TaskTone
        switch task.state {
        case .pending:
            stateBadge = L10n.tr("tasks.state.pending"); tone = .neutral
        case .queued:
            stateBadge = position.map { L10n.tr("tasks.card.queuedAt", $0) } ?? L10n.tr("tasks.state.queued")
            tone = .neutral
        case .running:
            stateBadge = L10n.tr("tasks.state.running"); tone = .running
        case .done:
            stateBadge = L10n.tr("tasks.state.done"); tone = .positive
        case .failed:
            stateBadge = L10n.tr("tasks.state.failed"); tone = .negative
        case .cancelled:
            stateBadge = L10n.tr("tasks.state.cancelled"); tone = .warning
        case .closed:
            stateBadge = L10n.tr("tasks.state.closed"); tone = .neutral
        }

        var meta: [String] = []
        if !task.labels.isEmpty { meta.append(task.labels.joined(separator: ", ")) }
        if let branch = task.branch ?? queue?.branch { meta.append(branch) }
        if let pr = task.prUrl { meta.append(L10n.tr("tasks.detailPR", Self.shortPR(pr))) }

        var detailLines: [String] = []
        if let queue = queue, !queue.autoCreated {
            detailLines.append(L10n.tr("tasks.detailQueue", queue.name))
        }
        if let session = task.sessionId { detailLines.append(L10n.tr("tasks.detailSession", session)) }
        if let error = task.error { detailLines.append(L10n.tr(error)) }
        if let body = task.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            detailLines.append("")
            detailLines.append(body)
        }

        var primaryKey = "tasks.detailProcess"
        var primaryEnabled = true
        var canQueue = false
        var canDequeue = false
        var canCancel = false
        var canRetry = false
        switch task.state {
        case .pending:
            // A manual task has no queue yet: the primary action IS 加入队列.
            if task.source == .manual {
                primaryKey = "tasks.queue.add"
                canQueue = true
            } else {
                primaryKey = "tasks.detailProcess"
            }
        case .queued:
            primaryKey = "tasks.queue.remove"
            canDequeue = true
        case .running:
            primaryKey = "tasks.detailCancelTask"
            canCancel = true
        case .done:
            primaryKey = "tasks.detailOpenPR"
            primaryEnabled = task.prUrl != nil
        case .failed, .cancelled:
            primaryKey = "tasks.detailRetry"
            canRetry = true
        case .closed:
            primaryKey = "tasks.detailOpenIssue"
        }

        return TaskCardModel(taskID: task.id,
                             isExpanded: expanded,
                             sourceBadge: sourceBadge,
                             stateBadge: stateBadge,
                             tone: tone,
                             title: task.title,
                             meta: meta,
                             detail: detailLines.joined(separator: "\n"),
                             primaryKey: primaryKey,
                             primaryEnabled: primaryEnabled,
                             canQueue: canQueue,
                             canDequeue: canDequeue,
                             canCancel: canCancel,
                             canRetry: canRetry,
                             canCommentClose: task.source == .github && githubRepo
                                 && task.state == .done && task.prUrl != nil,
                             canEdit: task.source == .manual && task.state != .running,
                             canDelete: task.source == .manual && task.state != .running,
                             queuePosition: position,
                             source: task.source,
                             state: task.state)
    }

    /// Pull request URLs are long; the card shows owner/repo#123. Both shapes are
    /// handled: the web URL (github.com/owner/repo/pull/42) and the REST one
    /// (api.github.com/repos/owner/repo/pulls/42).
    static func shortPR(_ url: String) -> String {
        guard let range = url.range(of: "/pull") else { return url }
        let number = url[range.upperBound...].drop { !$0.isNumber }
        var parts = url[..<range.lowerBound].split(separator: "/").map(String.init)
        if let repos = parts.firstIndex(of: "repos") { parts.removeFirst(repos + 1) }
        guard parts.count >= 2 else { return "#" + number }
        return parts[parts.count - 2] + "/" + parts[parts.count - 1] + "#" + number
    }
}

/// Everything a queue header shows: how many queues exist and where each one is.
struct QueueHeaderModel: Equatable {
    var queueID: String
    var name: String
    var isCollapsed: Bool
    var branchText: String
    var progress: String
    var stateKey: String
    var tone: TaskTone
    var failedCount: Int
    var queuedCount: Int
    var doneCount: Int
    var totalCount: Int
    var canStart: Bool
    var canPause: Bool
    var canOpenPR: Bool
    var autoPR: Bool
    var prUrl: String?

    static func build(_ queue: TaskQueue, board: TaskBoard, collapsed: Bool) -> QueueHeaderModel {
        let tasks = queue.taskIds.compactMap { board.task($0) }
        let doneCount = tasks.filter { $0.state == .done }.count
        let failedCount = tasks.filter { $0.state == .failed }.count
        let queuedCount = tasks.filter { $0.state == .queued }.count

        let branchText = queue.branch.map { $0 + " → " + queue.baseBranch } ?? L10n.tr("tasks.queue.noBranch")

        let stateKey: String
        let tone: TaskTone
        switch queue.state {
        case .active: stateKey = "tasks.queue.state.active"; tone = .running
        case .paused: stateKey = "tasks.queue.state.paused"; tone = failedCount > 0 ? .negative : .warning
        case .done: stateKey = "tasks.queue.state.finished"; tone = .positive
        }

        return QueueHeaderModel(queueID: queue.id,
                                name: queue.name,
                                isCollapsed: collapsed,
                                branchText: branchText,
                                progress: "\(doneCount)/\(tasks.count)",
                                stateKey: stateKey,
                                tone: tone,
                                failedCount: failedCount,
                                queuedCount: queuedCount,
                                doneCount: doneCount,
                                totalCount: tasks.count,
                                canStart: queuedCount > 0 && queue.state != .active,
                                canPause: queue.state == .active,
                                canOpenPR: queue.autoPR && queue.prUrl == nil
                                    && queue.state == .done && queue.branch != nil,
                                autoPR: queue.autoPR,
                                prUrl: queue.prUrl)
    }
}

/// The summary strip: how many queues there are and what they are doing.
struct TasksSummaryModel: Equatable {
    var queues: Int
    var queued: Int
    var running: Int
    var failed: Int
    var text: String

    static func build(_ board: TaskBoard) -> TasksSummaryModel {
        let counts = board.summary()
        return TasksSummaryModel(queues: counts.queues,
                                 queued: counts.queued,
                                 running: counts.running,
                                 failed: counts.failed,
                                 text: L10n.tr("tasks.summary", counts.queues, counts.queued,
                                               counts.running, counts.failed))
    }
}
