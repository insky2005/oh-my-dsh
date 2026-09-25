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
    /// 0…1 for the progress bar (a queue with no tasks reads 0).
    var progressFraction: Double
    var stateKey: String
    var tone: TaskTone
    var failedCount: Int
    var queuedCount: Int
    var runningCount: Int
    var doneCount: Int
    var totalCount: Int
    var canStart: Bool
    var canPause: Bool
    var canOpenPR: Bool
    var autoPR: Bool
    var isAutoCreated: Bool
    var prUrl: String?

    static func build(_ queue: TaskQueue, board: TaskBoard, collapsed: Bool) -> QueueHeaderModel {
        let tasks = queue.taskIds.compactMap { board.task($0) }
        let doneCount = tasks.filter { $0.state == .done }.count
        let failedCount = tasks.filter { $0.state == .failed }.count
        let queuedCount = tasks.filter { $0.state == .queued }.count
        let runningCount = tasks.filter { $0.state == .running }.count

        let branchText = queue.branch.map { $0 + " → " + queue.baseBranch }
            ?? L10n.tr("tasks.queue.noBranch")

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
                                progressFraction: tasks.isEmpty
                                    ? 0 : Double(doneCount) / Double(tasks.count),
                                stateKey: stateKey,
                                tone: tone,
                                failedCount: failedCount,
                                queuedCount: queuedCount,
                                runningCount: runningCount,
                                doneCount: doneCount,
                                totalCount: tasks.count,
                                canStart: queuedCount > 0 && queue.state != .active,
                                canPause: queue.state == .active,
                                canOpenPR: queue.autoPR && queue.prUrl == nil
                                    && queue.state == .done && queue.branch != nil,
                                autoPR: queue.autoPR,
                                isAutoCreated: queue.autoCreated,
                                prUrl: queue.prUrl)
    }
}

/// One counter of the summary strip (队列 / 排队 / 运行 / 失败).
struct TaskStatChip: Equatable {
    var key: String
    var count: Int
    var tone: TaskTone

    /// A zero counter stays quiet; only 失败 lights up once it is not zero.
    static func tone(forCount count: Int, negativeWhenPositive: Bool) -> TaskTone {
        (negativeWhenPositive && count > 0) ? .negative : .neutral
    }
}

/// The summary strip: how many queues there are and what they are doing.
struct TasksSummaryModel: Equatable {
    var queues: Int
    var queued: Int
    var running: Int
    var failed: Int
    var text: String
    /// The same counts as one-chip-per-number, in reading order.
    var chips: [TaskStatChip]

    static func build(_ board: TaskBoard) -> TasksSummaryModel {
        let counts = board.summary()
        return TasksSummaryModel(
            queues: counts.queues,
            queued: counts.queued,
            running: counts.running,
            failed: counts.failed,
            text: L10n.tr("tasks.summary", counts.queues, counts.queued,
                          counts.running, counts.failed),
            chips: [
                TaskStatChip(key: "tasks.stat.queues", count: counts.queues, tone: .neutral),
                TaskStatChip(key: "tasks.stat.queued", count: counts.queued, tone: .neutral),
                TaskStatChip(key: "tasks.stat.running", count: counts.running,
                             tone: TaskStatChip.tone(forCount: counts.running,
                                                     negativeWhenPositive: false)),
                TaskStatChip(key: "tasks.stat.failed", count: counts.failed,
                             tone: TaskStatChip.tone(forCount: counts.failed,
                                                     negativeWhenPositive: true)),
            ])
    }
}

/// The centred empty state: what it says, which symbol it shows, and whether it
/// offers the inline 新建任务 button. A filter that matches nothing offers
/// nothing — the way out there is to switch the filter back.
struct TasksEmptyStateModel: Equatable {
    var messageKey: String
    var symbol: String
    var showsNewTask: Bool

    static func build(filtered: Bool, githubRepo: Bool) -> TasksEmptyStateModel {
        if filtered {
            return TasksEmptyStateModel(messageKey: "tasks.emptyFiltered",
                                        symbol: "line.3.horizontal.decrease.circle",
                                        showsNewTask: false)
        }
        return TasksEmptyStateModel(messageKey: githubRepo ? "tasks.empty" : "tasks.emptyManualOnly",
                                    symbol: "checklist",
                                    showsNewTask: true)
    }
}

// MARK: - Inline forms (created in the panel, never in a dialog)
//
// 新建任务 / 新建队列 used to raise an NSAlert: it covered the list, it could
// not be moved, and it forgot everything the moment it closed. Both are now
// ordinary cards inside the panel — same widgets, same colors, same list — and
// the two models below decide what a form shows and when it may be submitted.
// The views own the text fields and forward typing; nothing else lives there.

/// 新建任务 / 编辑任务 — the inline composer. Two fields, nothing else
/// (决策 6); the queue is chosen later, from the card.
struct TaskComposerModel: Equatable {

    enum Mode: Equatable {
        case create
        case edit(taskID: String)

        var isCreate: Bool { self == .create }

        var taskID: String? {
            if case .edit(let id) = self { return id }
            return nil
        }
    }

    var mode: Mode
    var title: String
    var body: String
    /// Set once the submit button was pressed on an incomplete draft, so the
    /// hint shows up when it is actually needed rather than while typing.
    var attempted: Bool

    var headingKey: String { mode.isCreate ? "tasks.new.title" : "tasks.new.editTitle" }
    var submitKey: String { mode.isCreate ? "tasks.new.create" : "tasks.new.save" }
    var infoKey: String { mode.isCreate ? "tasks.new.info" : "tasks.new.editInfo" }

    /// What would be created / saved right now.
    var draft: TaskDraft { TaskDraft(title: title, body: body) }
    var canSubmit: Bool { draft.isValid }

    /// The first problem as an L10n key — shown only after a submit attempt
    /// (the button stays disabled until the draft is complete, so the form never
    /// nags while it is being typed into).
    var problemKey: String? {
        attempted ? draft.problem : nil
    }

    var isPristine: Bool {
        draft.normalizedTitle.isEmpty && draft.normalizedBody.isEmpty
    }

    /// The form as it is while the user types (live, so the submit button
    /// follows what is actually in the two fields).
    func typed(title: String, body: String) -> TaskComposerModel {
        var copy = self
        copy.title = title
        copy.body = body
        return copy
    }

    /// The form after a submit attempt (turns on the problem hint).
    func attemptedSubmit() -> TaskComposerModel {
        var copy = self
        copy.attempted = true
        return copy
    }

    static func build(mode: Mode, title: String = "", body: String = "") -> TaskComposerModel {
        TaskComposerModel(mode: mode, title: title, body: body, attempted: false)
    }

    /// The composer for editing an existing task, prefilled from the board.
    static func edit(_ task: TaskItem) -> TaskComposerModel {
        build(mode: .edit(taskID: task.id), title: task.title, body: task.body ?? "")
    }
}

/// 新建队列 / 队列设置 — the inline queue form. Its fields are the queue's own
/// properties (决策 6): 队列名 / 分支 / 基于分支 / 完成后创建 PR.
struct QueueComposerModel: Equatable {

    enum Mode: Equatable {
        /// A brand-new queue. A taskID (when present) joins it right after
        /// creation — that is the 加入队列 ▾ → 新建队列 path.
        case create(taskID: String?)
        /// The queue's own settings, edited in place under its header.
        case edit(queueID: String)

        var isCreate: Bool {
            if case .create = self { return true }
            return false
        }

        var taskID: String? {
            if case .create(let id) = self { return id }
            return nil
        }

        var queueID: String? {
            if case .edit(let id) = self { return id }
            return nil
        }
    }

    var mode: Mode
    var name: String
    /// What the user typed. Empty means 自动生成 while creating, and 不切分支
    /// while editing — the two hints differ, see effectiveBranchHint.
    var branch: String
    var baseBranch: String
    var autoPR: Bool
    /// Whether GitHub is available in this workspace. Without it the form does
    /// not offer a PR switch at all (a dead checkbox is worse than a sentence).
    var prAvailable: Bool
    /// Whether the 高级设置 section (分支 / 基于分支 / PR 开关) is open. The branch
    /// is derived from the name, so creating a queue only asks for a name; editing
    /// a queue's settings opens everything, because that is what the user came for.
    var showsAdvanced: Bool
    var attempted: Bool

    var headingKey: String { mode.isCreate ? "tasks.queue.newTitle" : "tasks.queue.editTitle" }
    var infoKey: String { mode.isCreate ? "tasks.queue.newInfo" : "tasks.queue.editInfo" }

    /// 创建并入队 (from a task) / 创建 (standalone) / 保存 (editing).
    var submitKey: String {
        guard mode.isCreate else { return "tasks.new.save" }
        return mode.taskID == nil ? "tasks.queue.createOnly" : "tasks.queue.create"
    }

    var normalizedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The branch the queue will really use, as the hint next to the field.
    ///
    /// Creating never ends up without one: an empty field derives a branch from the
    /// queue name (feature/<slug>, or feature/queue-<id4> when the name has no ASCII
    /// slug at all). Editing takes an empty field literally — the queue stops
    /// switching branches and its tasks run wherever the worktree already is.
    var effectiveBranchHint: String {
        let typed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        guard mode.isCreate else { return L10n.tr("tasks.queue.noBranch") }
        let slug = TaskBranch.slug(normalizedName)
        return slug.isEmpty ? L10n.tr("tasks.queue.branchAuto") : "feature/" + slug
    }

    /// Strictly about validity — an untouched, empty form is still not
    /// submittable (the hint only appears once the user tried, see problemKey).
    var canSubmit: Bool { !normalizedName.isEmpty }

    var problemKey: String? {
        guard attempted, normalizedName.isEmpty else { return nil }
        return "tasks.errQueueName"
    }

    /// nil = derive the default from the name; "" = do not switch branches.
    var branchValue: String? {
        let value = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var normalizedBaseBranch: String {
        let value = baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "main" : value
    }

    func typed(name: String, branch: String, baseBranch: String, autoPR: Bool) -> QueueComposerModel {
        var copy = self
        copy.name = name
        copy.branch = branch
        copy.baseBranch = baseBranch
        copy.autoPR = autoPR
        return copy
    }

    /// What the branch field shows while it is EMPTY. The two modes mean different
    /// things here, so they say different things — the old single line ("留空 =
    /// 自动生成（不带分支则不切分支）") mixed both and read as a contradiction.
    var branchPlaceholder: String {
        let typed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        guard mode.isCreate else { return L10n.tr("tasks.queue.branchPlaceholderEdit") }
        let slug = TaskBranch.slug(normalizedName)
        return slug.isEmpty ? L10n.tr("tasks.queue.branchPlaceholderCreate") : "feature/" + slug
    }

    func attemptedSubmit() -> QueueComposerModel {
        var copy = self
        copy.attempted = true
        return copy
    }

    /// Show / hide the 高级设置 section.
    func togglingAdvanced() -> QueueComposerModel {
        var copy = self
        copy.showsAdvanced.toggle()
        return copy
    }

    /// 新建队列 (standalone, no task to join).
    static func create() -> QueueComposerModel {
        QueueComposerModel(mode: .create(taskID: nil), name: "", branch: "", baseBranch: "main",
                           autoPR: false, prAvailable: false, showsAdvanced: false, attempted: false)
    }

    /// 新建队列 from a task's 加入队列 ▾ menu: the new queue takes the task.
    static func create(taskID: String) -> QueueComposerModel {
        var model = create()
        model.mode = .create(taskID: taskID)
        return model
    }

    /// The queue's settings, prefilled — with 高级设置 already open: editing a
    /// queue IS editing its branch and PR switch.
    static func edit(_ queue: TaskQueue, prAvailable: Bool) -> QueueComposerModel {
        QueueComposerModel(mode: .edit(queueID: queue.id), name: queue.name,
                           branch: queue.branch ?? "", baseBranch: queue.baseBranch,
                           autoPR: queue.autoPR, prAvailable: prAvailable,
                           showsAdvanced: true, attempted: false)
    }
}
