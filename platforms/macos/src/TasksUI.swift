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

    /// What the card's primary control does when it is pressed.
    enum PrimaryAction: Equatable {
        /// 加入队列 — the control is the DROPDOWN, so the panel opens the queue
        /// picker instead of acting on the task (see TaskCardView.primaryControl).
        case joinQueue
        /// 处理 an issue task: build (or reuse) its single-task queue and start.
        case processIssue
        case dequeue
        case cancel
        // 打开 PR 不再是卡片动作：队列头上那个按钮负责它（见 .done 分支的注释）。
        case openIssue
        /// 重试 — put the task back into ITS queue (and resume it). clearsBranch
        /// additionally drops the queue's branch first (the not-a-git-repo repair).
        case retry(clearsBranch: Bool)
    }

    /// The card's primary control. nil = this card has NO primary action (a finished
    /// manual task: there is nothing left to do with it — its PR, if any, belongs to
    /// the queue and is opened from the queue header).
    var primaryKey: String?
    var primaryEnabled: Bool
    /// What pressing the primary control DOES. The panel switches on this instead
    /// of on the task's state: the state alone cannot tell 重试 (put it back into
    /// its queue) from 加入队列 / 处理 (that queue is gone — deleted — so there is
    /// nothing left to retry into).
    var primaryAction: PrimaryAction?
    /// The task failed because its queue asked for a branch in a directory that
    /// is not a git repository. That failure is fixable in one click — drop the
    /// queue's branch and run again — so the card's primary action does exactly
    /// that instead of offering a 重试 that would fail the same way.
    var clearsBranchOnRetry: Bool
    var canQueue: Bool
    var canDequeue: Bool
    var canCancel: Bool
    var canRetry: Bool
    /// 跳过并继续: keep this failure's record and let the queue walk PAST it to the
    /// next queued task (TasksRunner.skip). Offered only when there IS a next task
    /// — skipping the last one would resume a queue with nothing left to do.
    var canSkip: Bool
    /// Why the primary control is greyed out (nil while it is live): a dead button
    /// with no explanation is worse than a sentence.
    var primaryDisabledHintKey: String?
    var canCommentClose: Bool
    var canEdit: Bool
    var canDelete: Bool

    /// The dsh session this task runs in (nil until it started): the card offers
    /// 打开会话 / 审查改动 on it — the panel hands the id to the shell, which has
    /// had the bridge all along (ChannelPanel uses the same one).
    var sessionId: String?
    /// How long a RUNNING task has been running ("12:03"), nil for everything else.
    var runningFor: String?
    /// 1-based position inside its queue, when it is waiting.
    var queuePosition: Int?
    /// Whether the task sits INSIDE a queue lane (or is one of the 未入队 cards
    /// standing directly on the panel). The card's fill follows it: nested cards
    /// take the recessed level, top-level ones the raised one — the audit
    /// panel's nesting ladder (ReviewInk.sessionFill → ReviewInk.blockFill).
    var isNested: Bool
    var source: TaskSource
    var state: TaskState

    /// Build the card for a task. githubRepo is false in a non-GitHub workspace,
    /// which hides everything that would talk to GitHub.
    static func build(_ task: TaskItem,
                      board: TaskBoard,
                      expanded: Bool,
                      githubRepo: Bool,
                      now: Date = Date(),
                      timeoutMinutes: Int = 60) -> TaskCardModel {
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

        // A running task shows its clock FIRST: "is it stuck?" is the question the
        // card is asked most while it runs.
        let runningFor = task.startedAt.map { started in
            task.state == .running ? TaskCardModel.duration(from: started, to: now) : nil
        } ?? nil

        var meta: [String] = []
        if let runningFor = runningFor {
            // The deadline is part of the clock: a task is cancelled at it, and
            // finding that out from a failed card is too late.
            meta.append(L10n.tr("tasks.card.runningFor", runningFor, timeoutMinutes))
        }
        if !task.labels.isEmpty { meta.append(task.labels.joined(separator: ", ")) }
        // The branch a task is ABOUT to use is the queue's; task.branch is only a
        // record of where it ran (and leaving a queue clears it — see dequeue).
        if let branch = queue?.branch ?? task.branch { meta.append(branch) }
        if let pr = task.prUrl { meta.append(L10n.tr("tasks.detailPR", Self.shortPR(pr))) }

        var detailLines: [String] = []
        if let queue = queue, !queue.autoCreated {
            detailLines.append(L10n.tr("tasks.detailQueue", queue.name))
        }
        if let session = task.sessionId { detailLines.append(L10n.tr("tasks.detailSession", session)) }
        if let error = task.error { detailLines.append(L10n.tr(error)) }
        // 单行任务的描述就是标题：卡片标题已经说了，详情不再重复一遍。
        if let body = task.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty,
           body != task.title.trimmingCharacters(in: .whitespacesAndNewlines) {
            detailLines.append("")
            detailLines.append(body)
        }
        // The agent 汇报, written back onto the task by the runner when it finished:
        // last, because it is the newest thing about this task — and the reason the
        // card still tells the story after the session is deleted.
        if let report = task.report?.trimmingCharacters(in: .whitespacesAndNewlines), !report.isEmpty {
            detailLines.append("")
            detailLines.append(L10n.tr("tasks.detailReport"))
            detailLines.append(report)
        }

        // A queue branch that cannot be entered (the directory is not a git
        // repository) is the ONE failure the card can fix by itself, so it is
        // recognized here and not left to the panel's own state.
        let clearsBranchOnRetry = task.state == .failed
            && task.error == TaskFailure.notGitRepo.rawValue
            && queue?.branch != nil

        // 加入队列 for a manual task with NO queue to run in: while creating (state
        // .pending) and also after its queue was DELETED. The old rule keyed off the
        // state alone, so a failed task whose queue was gone still said 重试 — which
        // cannot retry anything: it flipped the card back to 待处理 and only THEN
        // showed 加入队列, one click later.
        let hasQueue = queue != nil
        let joinQueue = task.source == .manual && !hasQueue
            && (task.state == .pending || task.state == .failed || task.state == .cancelled)

        // nil = 这张卡片没有主操作（见下面 .done：完成的手动任务没什么可点的）。
        var primaryKey: String? = "tasks.detailProcess"
        var primaryEnabled = true
        var primaryAction: TaskCardModel.PrimaryAction? = .processIssue
        // Is there anything to walk PAST this failure to?
        let hasQueuedSibling = queue?.taskIds.contains { id in
            id != task.id && board.task(id)?.state == .queued
        } ?? false

        var canQueue = false
        var canDequeue = false
        var canCancel = false
        var canRetry = false
        var canSkip = false
        var primaryDisabledHintKey: String?
        switch task.state {
        case .pending:
            // A manual task has no queue yet: the primary action IS 加入队列.
            if joinQueue {
                primaryKey = "tasks.queue.add"
                primaryAction = .joinQueue
                canQueue = true
            } else {
                primaryKey = "tasks.detailProcess"
                primaryAction = .processIssue
            }
        case .queued:
            primaryKey = "tasks.queue.remove"
            primaryAction = .dequeue
            canDequeue = true
        case .running:
            primaryKey = "tasks.detailCancelTask"
            primaryAction = .cancel
            canCancel = true
        case .done:
            // 卡片上没有「打开 PR」（用户 2026-09-27）：PR 是**队列**的产物（队列跑完后由
            // 那个专门的会话开），打开它也在队列头上 —— 卡片再放一个按钮，只是在重复一件
            // 别处已经说清楚的事（此前那个按钮还常常是灰的，因为它要求的 PR 属于队列）。
            // issue 任务留着「打开 Issue」：那是这条任务自己的东西；手动任务完成之后没有
            // 任何待办动作，于是**没有主按钮**（primaryKey == nil）。
            if task.source == .github {
                primaryKey = "tasks.detailOpenIssue"
                primaryAction = .openIssue
            } else {
                primaryKey = nil
                primaryAction = nil
            }
        case .failed, .cancelled:
            if joinQueue {
                // Its queue is gone: offer the honest next step instead of a 重试
                // that only resets the card.
                primaryKey = "tasks.queue.add"
                primaryAction = .joinQueue
                canQueue = true
            } else if hasQueue {
                primaryKey = clearsBranchOnRetry ? "tasks.detailRetryNoBranch" : "tasks.detailRetry"
                primaryAction = .retry(clearsBranch: clearsBranchOnRetry)
                canRetry = true
                canSkip = hasQueuedSibling
            } else {
                // An ISSUE task with no queue (its auto queue was deleted): 处理
                // rebuilds that queue and starts — same as a pending issue task.
                primaryKey = "tasks.detailProcess"
                primaryAction = .processIssue
            }
        case .closed:
            primaryKey = "tasks.detailOpenIssue"
            primaryAction = .openIssue
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
                             primaryAction: primaryAction,
                             clearsBranchOnRetry: clearsBranchOnRetry,
                             canQueue: canQueue,
                             canDequeue: canDequeue,
                             canCancel: canCancel,
                             canRetry: canRetry,
                             canSkip: canSkip,
                             primaryDisabledHintKey: primaryDisabledHintKey,
                             // A finished issue task is commentable whether or not a PR
                             // came out of it: 评论并关闭 needs no PR link (it just mentions
                             // one when there is one). Requiring one hid the whole action
                             // exactly when the run had gone wrong.
                             canCommentClose: task.source == .github && githubRepo
                                 && task.state == .done,
                             // 已完成的任务与 github 任务一样只是记录：不再可编辑、不可删除
                             // （用户 2026-09-27 的规则，也终于与 README 里那句「运行中/已执行
                             // 的任务与 github 任务不可编辑删除」一致）。
                             canEdit: task.source == .manual && task.state.isEditable,
                             canDelete: task.source == .manual && task.state.isEditable,
                             sessionId: task.sessionId,
                             runningFor: runningFor,
                             queuePosition: position,
                             isNested: task.queueId != nil,
                             source: task.source,
                             state: task.state)
    }

    /// mm:ss (hh:mm:ss past an hour). Wall-clock, not locale: it is a duration,
    /// and the card has no room for words.
    static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start).rounded(.down)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
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

/// What the 处理 (全部处理) button is: how much is waiting, whether it can be
/// pressed, and what pressing it would do.
///
/// It is NOT a GitHub-only action — its meaning is "start everything that is still
/// waiting". Issue tasks run each in their own single-task queue (v1's
/// one-issue-one-branch-one-PR rule) and so do MANUAL tasks, so a batch never
/// silently bundles unrelated changes onto one branch. Only the PR *half* of it
/// needs a GitHub remote: a non-GitHub workspace gets branches without PRs, which
/// is exactly what its queues do.
struct TasksRunAllModel: Equatable {
    var issueCount: Int
    var manualCount: Int
    var enabled: Bool
    /// The button's tooltip — and ONLY that: what the control does (it is an icon
    /// button, so the tooltip is its label), or, when it is greyed out, why.
    ///
    /// Counts and policy deliberately do NOT live here: how many tasks are waiting
    /// is visible in the content area's 统计信息 card, and what a batch will do to
    /// branches/PRs belongs in the confirmation dialog — the moment the user
    /// actually commits. A tooltip is not the place to narrate business rules.
    var tooltip: String
    /// The confirmation dialog's body: what pressing it will really do here.
    var confirmationText: String

    var total: Int { issueCount + manualCount }

    /// What 全部处理 starts: everything that is still waiting ON ITS OWN.
    ///
    /// - `.pending` — never ran;
    /// - `.failed` / `.cancelled` **with no queue**: deleting a queue returns its
    ///   tasks to 未入队 in exactly that state, and then the batch is the natural
    ///   way to pick them all up again (their cards only offer 加入队列 one by one);
    /// - NOT tasks that still sit in a queue, whatever their state: the lane owns
    ///   them (重试 / 跳过并继续), and a global batch must not silently resurrect a
    ///   paused queue.
    static func isStartable(_ task: TaskItem, board: TaskBoard) -> Bool {
        switch task.state {
        case .pending:
            return true
        case .failed, .cancelled:
            return task.queueId.flatMap { board.queue($0) } == nil
        default:
            return false
        }
    }

    /// Those tasks in board order — the panel starts exactly this list, so the
    /// counts below and what actually runs can never disagree.
    static func startable(in board: TaskBoard) -> [TaskItem] {
        board.tasks.filter { isStartable($0, board: board) }
    }

    static func build(_ board: TaskBoard, githubAvailable: Bool,
                      gitAvailable: Bool = true) -> TasksRunAllModel {
        let startable = startable(in: board)
        let issueCount = startable.filter { $0.source == .github }.count
        let manualCount = startable.filter { $0.source == .manual }.count
        let enabled = issueCount + manualCount > 0
        // The body: the count (it is the fact the user is confirming) and what a
        // batch really does on THIS workspace — one queue and branch per task, run
        // one at a time, and whether a PR comes out of it. Each count shape gets its
        // OWN L10n call: passing an [CVarArg] array to the variadic L10n.tr() types
        // the ARRAY as the single argument and %d prints its address (that shipped
        // once as 「全部处理：7935328 个手动任务」).
        // Three shapes, because the promise differs: a git workspace with a GitHub
        // remote opens PRs, one without only branches, and a directory that is not a
        // repository does neither (its queues get no branch at all — §V2-7).
        let body: String
        if !gitAvailable {
            body = L10n.tr("tasks.runAllInfoNoGit", issueCount + manualCount)
        } else {
            let detailLine = githubAvailable ? L10n.tr("tasks.runAllInfoWithPR") : L10n.tr("tasks.runAllInfoNoPR")
            body = L10n.tr("tasks.runAllInfo", issueCount + manualCount) + " " + detailLine
        }
        return TasksRunAllModel(
            issueCount: issueCount,
            manualCount: manualCount,
            enabled: enabled,
            // Tooltip = the control's label, or the reason it is dead.
            tooltip: enabled ? L10n.tr("tasks.runAllHint") : L10n.tr("tasks.runAllNone"),
            confirmationText: enabled
                ? body
                : L10n.tr("tasks.runAllNone"))   // nothing to confirm when it is disabled
    }
}

/// What a finished task may have changed about the workspace it ran in.
///
/// The panel decides everything about a workspace when it ADOPTS it — is it a git
/// repository at all, does it have a GitHub remote — and hands the same facts to the
/// runner's env (a branchless queue in a non-git directory never touches git, §V2-7).
/// A task can make all of that stale, and 「初始化 git 仓库」 is the plainest example:
/// the user asks for a repository and gets a header that still says 非 Git 仓库.
///
/// This is the pure half of noticing: the panel supplies what it believed and what is
/// true now, and gets back whether the workspace has to be re-adopted (the I/O half —
/// `git rev-parse`, `git remote -v`, rebuilding the runner — stays in the panel).
struct TaskWorkspaceShape: Equatable {
    /// A workspace is a git repository now, and was not when it was adopted.
    var becameGit = false
    /// It has a GitHub remote now, and had none when it was adopted.
    var becameRemote = false

    var changed: Bool { becameGit || becameRemote }

    /// The status line to show, or nil when nothing changed.
    var messageKey: String? {
        if becameGit { return "tasks.gitAppeared" }
        if becameRemote { return "tasks.remoteAppeared" }
        return nil
    }

    static func change(wasGit: Bool, hadRemote: Bool,
                       isGitNow: Bool, hasRemoteNow: Bool) -> TaskWorkspaceShape? {
        let shape = TaskWorkspaceShape(becameGit: !wasGit && isGitNow,
                                       becameRemote: !hadRemote && hasRemoteNow)
        return shape.changed ? shape : nil
    }
}

/// Where this board lives, as the panel's header says it — plus whether the
/// GitHub-only controls can do anything here.
///
/// 「非 git 目录」和「git 仓库但没有 GitHub 远端」是两件事：前者队列连分支都切不了
/// （§V2-7），后者只是没有 issue / PR。头部把这两句**分开说**（这正是旧文案把两者
/// 混成一句「非 GitHub 仓库」的地方），而三个 GitHub 专属按钮统一按「有没有 GitHub
/// 远端」决定可用性 —— 在非 GitHub 工作区里它们点了什么都不会发生（reloadIssues /
/// runAll 本来就 guard 掉了 repo），灰掉并说明原因，而不是留一个「点了没反应」的控件。
struct TaskWorkspaceModel: Equatable {
    /// The header's second line: owner/repo, 目录名 · 非 GitHub 仓库, …
    var title: String
    /// 配置 GitHub Token / 刷新 Issues / 全部处理 这三个 GitHub 专属按钮能不能用。
    var githubAvailable: Bool
    /// 不能用时按钮 tooltip 里的原因（能用时为 nil）。
    var disabledHint: String?

    static func build(owner: String?, repo: String?, workspacePath: String?,
                      isGitRepo: Bool) -> TaskWorkspaceModel {
        if let owner = owner, let repo = repo, !owner.isEmpty, !repo.isEmpty {
            return TaskWorkspaceModel(title: owner + "/" + repo,
                                      githubAvailable: true, disabledHint: nil)
        }
        // No workspace resolved at all: the panel has nothing to name.
        guard let path = workspacePath, !path.isEmpty else {
            return TaskWorkspaceModel(title: L10n.tr("tasks.noRepo"), githubAvailable: false,
                                      disabledHint: L10n.tr("tasks.errNoWorkspace"))
        }
        let name = (path as NSString).lastPathComponent
        let kind = isGitRepo ? L10n.tr("tasks.noRepoShort") : L10n.tr("tasks.noGitShort")
        return TaskWorkspaceModel(title: name + " · " + kind, githubAvailable: false,
                                  disabledHint: L10n.tr("tasks.githubUnavailable"))
    }
}

/// Everything a queue header shows: how many queues exist and where each one is.
/// Display name and icon of an 工作流. The keys live under `tasks.integration.*`
/// so the user-facing wording can change without touching the model — the enum raw
/// values stay the API's vocabulary.
extension QueueIntegration {
    var labelKey: String { "tasks.integration." + rawValue }
    var label: String { L10n.tr(labelKey) }

    /// The order every picker shows them in: 「无」FIRST (user 2026-10-01), then the
    /// three publishing workflows. A display order, not the enum's storage order.
    static var displayOrder: [QueueIntegration] { [.none, .pr, .merge, .push] }
    /// The icon the queue header's publish button carries for this mode.
    var publishSymbol: String {
        switch self {
        case .pr: return "arrow.up.right.square"
        case .merge: return "arrow.triangle.merge"
        case .push: return "arrow.up.circle"
        // Unreachable: .none hides the publish control (canOpenPR is false).
        case .none: return "nosign"
        }
    }
    /// The publish button's tooltip key for this mode.
    var publishHintKey: String {
        switch self {
        case .pr: return "tasks.queue.openPR"
        case .merge: return "tasks.queue.mergePush"
        case .push: return "tasks.queue.pushOnly"
        case .none: return "tasks.integration.none"
        }
    }

    /// Why a picker greys this mode out in the current workspace (nil-reachable keys:
    /// .none is never disabled, so its key is unused).
    var unavailableHintKey: String {
        switch self {
        case .pr: return "tasks.integration.unavailablePr"
        case .merge: return "tasks.integration.unavailableMerge"
        case .push: return "tasks.integration.unavailablePush"
        case .none: return "tasks.integration.none"
        }
    }
}

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
    /// What the ▶ button really does here: 开始 (nothing has run yet / the user
    /// paused it) or 继续 — walk PAST the failed entry and run the next task.
    /// The tooltip used to say 开始 in both cases, which is not what the runner
    /// does after a failure (TasksCore.resumeQueue).
    var startHintKey: String
    var canPause: Bool
    /// 队列设置（名字 / 分支 / 基线 / PR 开关）与 删除队列 —— 已完成的队列两者都没有：
    /// 它是一条记录，改了设置也不会再跑（用户 2026-09-27 的规则）。
    var canEdit: Bool
    var canDelete: Bool
    /// 关闭队列（手动终态）——已关闭的队列没有这个动作。
    var canClose: Bool
    var canOpenPR: Bool
    var autoPR: Bool
    var isAutoCreated: Bool
    var prUrl: String?
    /// Why the last publish attempt did not even START (no branch / no remote /
    /// another finalize session running; an L10n key), or nil. Shown as a warning ROW
    /// on the card — never as the 发布 button's tooltip, which always says what the
    /// button does (user 2026-10-01).
    var prErrorKey: String?
    /// Whether this workspace can carry a PR at all (it has a GitHub remote).
    /// False hides the 自动开 PR switch — a dead control is worse than no control
    /// (the queue form's switch obeys the same rule).
    var prAvailable: Bool
    /// Whether this queue was created by a dsh session (board.local.queueSessions), so
    /// its completion will be reported back there. The header shows a small ↺ glyph.
    var reportsToSession: Bool
    /// The 工作流 resolved for THIS queue (its own override, else the panel default).
    /// Decides the publish button's icon/label and whether a PR is required.
    var integration: QueueIntegration
    /// The last finalize session's report (the whole thing, capped by the runner):
    /// nil = never finalized. A collapsed card shows its first line; 展开 shows the
    /// rest (user 2026-10-01).
    var integrationNote: String?
    /// Whether the result row is currently expanded (panel state, per queue).
    var integrationNoteExpanded: Bool

    /// The note split into lines (empty lines kept: a report may have blank lines).
    var integrationNoteLines: [String] {
        (integrationNote ?? "").components(separatedBy: "\n")
    }
    /// What a collapsed card shows: the first non-empty line.
    var integrationNoteFirstLine: String? {
        integrationNoteLines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    /// Whether there is more to the note than that first line (a long single line
    /// counts too — expanding lets it wrap).
    var canExpandIntegrationNote: Bool {
        integrationNoteLines.count > 1 || (integrationNote ?? "").count > 80
    }

    /// The 自动开 PR toggle is shown while PRs are possible; a queue that already
    /// HAS autoPR on keeps showing it (disabled, explained) even in a workspace
    /// that can no longer open one, so its state is never hidden.
    var showsAutoPRToggle: Bool { prAvailable || autoPR }
    /// …and it is only clickable where a PR is possible.
    var autoPREnabled: Bool { prAvailable }

    /// `isCurrent` = this is the queue the runner is working on right now. Several
    /// queues can be 活跃 at once (开始 on a second one just re-points the runner),
    /// and the others used to show 活跃 while nothing whatsoever happened in them.
    static func build(_ queue: TaskQueue, board: TaskBoard, collapsed: Bool,
                      prAvailable: Bool = true, isCurrent: Bool = true,
                      integration: QueueIntegration = .pr,
                      hasRemote: Bool = true,
                      noteExpanded: Bool = false) -> QueueHeaderModel {
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
        case .active:
            // 等待中: it IS active (the ▶ is gone, its tasks are queued), but the
            // runner is busy with another queue — saying 活跃 there was a lie the
            // user could not act on.
            stateKey = isCurrent ? "tasks.queue.state.active" : "tasks.queue.state.waiting"
            tone = isCurrent ? .running : .warning
        case .draft:
            // 从未启动：动作是「开始」，不是「继续」——paused 才是启动过但停了。
            stateKey = "tasks.queue.state.draft"
            tone = .warning
        case .paused: stateKey = "tasks.queue.state.paused"; tone = failedCount > 0 ? .negative : .warning
        case .done: stateKey = "tasks.queue.state.finished"; tone = .positive
        // 关闭 = 手动终态：中性灰，与「暂停（橙）」「失败（红）」区分开（用户 2026-10-01）。
        case .closed: stateKey = "tasks.queue.state.closed"; tone = .neutral
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
                                canStart: queuedCount > 0 && queue.state != .active && queue.state != .closed,
                                startHintKey: (queue.state == .paused && failedCount > 0 && queuedCount > 0)
                                    ? "tasks.queue.continue" : "tasks.queue.start",
                                canPause: queue.state == .active,
                                // .done 仍是「收尾」：设置/删除不回到行上（避免把名字挤没），
                                // 但可以继续追加任务、发布、或手动关闭。
                                canEdit: queue.state != .done && queue.state != .closed,
                                canDelete: queue.state != .done,
                                canClose: queue.state == .done || queue.state == .paused,
                                // 发布与 autoPR 解耦：只要工作区能承担这种工作流、队列有分支、
                                // 任务已收尾，就能手动收尾（prUrl 已存在时是「更新」）。pr 需要 GitHub
                                // 远端；merge 只做本地合并，不需要远端；push 必须有一个可推送的远端；
                                // 「无」是明确的不收尾，没有发布按钮。
                                canOpenPR: queue.state == .done && queue.branch != nil
                                    && integration != .none
                                    && (integration == .pr ? prAvailable
                                        : integration == .push ? hasRemote : true),
                                autoPR: queue.autoPR,
                                isAutoCreated: queue.autoCreated,
                                prUrl: queue.prUrl,
                                prErrorKey: queue.prError,
                                prAvailable: prAvailable,
                                reportsToSession: board.local.queueSessions[queue.id] != nil,
                                integration: integration,
                                integrationNote: queue.integrationNote,
                                integrationNoteExpanded: noteExpanded)
    }
}

/// The toolbar's source tabs (全部 / Issue / 手动) as a PURE rule.
///
/// `matches` says which tasks a tab accepts; `cards(of:in:)` and `shows(_:in:)` say
/// which lanes are worth drawing and what goes inside them. The lane half is the one
/// that was wrong (2026-09-27): the panel used to decide lanes by `autoCreated` —
/// 「auto queue = issue queue」 — but 全部处理 builds AUTO queues for MANUAL tasks too,
/// so the Issue tab listed lanes named after manual tasks (with every card filtered
/// away: an empty lane) while the 手动 tab, which showed only user queues, looked
/// empty. A lane now shows while it HOLDS at least one accepted card.
enum TaskSourceFilter: Int, CaseIterable {
    // 顺序 = 页签顺序（全部 / 手动 / Issue，用户 2026-09-27 把「手动」提到前面）。
    // 页面标题由 allCases 生成，rawValue 与下标一一对应 —— 顺序只在这一处定义，
    // 标题数组与它不可能再各说各话（上一版的 bug 就是「下标」与「含义」对不上）。
    case all = 0, manual = 1, issues = 2

    /// The tab's own label (the panel builds the strip from `allCases`).
    var titleKey: String {
        switch self {
        case .all: return "tasks.filter.all"
        case .manual: return "tasks.filter.manual"
        case .issues: return "tasks.filter.issues"
        }
    }

    func matches(_ task: TaskItem) -> Bool {
        switch self {
        case .all: return true
        case .issues: return task.source == .github
        case .manual: return task.source == .manual
        }
    }

    /// The same filter as the models want it (nil = everything): the summary counters
    /// and the task cards must agree with the lanes on screen.
    var source: TaskSource? {
        switch self {
        case .all: return nil
        case .issues: return .github
        case .manual: return .manual
        }
    }

    /// The cards this tab shows of one lane (in board order).
    func cards(of queue: TaskQueue, in board: TaskBoard) -> [TaskItem] {
        board.tasks(inQueue: queue.id).filter { matches($0) }
    }

    /// Is this lane worth drawing under this tab?
    ///
    /// - 「全部」: every lane, always (an empty lane the user made is still theirs).
    /// - 手动: every USER lane (a lane the user built is the manual side of the board,
    ///   empty or not — that is where the next manual task goes), plus the auto lanes
    ///   that actually hold a manual task (全部处理 gives manual tasks auto lanes too).
    /// - Issue: only lanes that HOLD an issue task — an auto lane named after a manual
    ///   task, or an empty user lane, has nothing to show there.
    func shows(_ queue: TaskQueue, in board: TaskBoard) -> Bool {
        switch self {
        case .all: return true
        case .manual: return !queue.autoCreated || !cards(of: queue, in: board).isEmpty
        case .issues: return !cards(of: queue, in: board).isEmpty
        }
    }
}

/// One counter of the summary card (队列 / 排队 / 运行 / 失败): its label, its
/// number, and the tone the number reads in. The card joins the four into ONE
/// line — the review panel's summary card体例 ("会话 3/12 · +120 −30").
struct TaskSummaryPart: Equatable {
    var key: String
    var count: Int
    var tone: TaskTone

    /// A zero counter stays quiet; only 失败 lights up once it is not zero.
    static func tone(forCount count: Int, negativeWhenPositive: Bool) -> TaskTone {
        (negativeWhenPositive && count > 0) ? .negative : .neutral
    }

    /// What the card prints for this counter ("队列 12").
    var text: String { L10n.tr(key) + " " + String(count) }
}

/// The board's counters: how many queues there are and what they are doing.
/// Rendered as the content area's first row (任务面板 content 1「统计信息」),
/// NOT as toolbar pills anymore.
struct TasksSummaryModel: Equatable {
    var queues: Int
    var queued: Int
    var running: Int
    var failed: Int
    /// The four counters in reading order — the card's whole content.
    var parts: [TaskSummaryPart]

    /// `source` narrows the counters to what the list is showing (nil = all):
    /// the counts live in the same content area as the (filtered) lanes, so they
    /// have to agree with them.
    static func build(_ board: TaskBoard, source: TaskSource? = nil) -> TasksSummaryModel {
        let counts = board.summary(source: source)
        return TasksSummaryModel(
            queues: counts.queues,
            queued: counts.queued,
            running: counts.running,
            failed: counts.failed,
            parts: [
                TaskSummaryPart(key: "tasks.stat.queues", count: counts.queues, tone: .neutral),
                TaskSummaryPart(key: "tasks.stat.queued", count: counts.queued, tone: .neutral),
                TaskSummaryPart(key: "tasks.stat.running", count: counts.running,
                                tone: TaskSummaryPart.tone(forCount: counts.running,
                                                           negativeWhenPositive: false)),
                TaskSummaryPart(key: "tasks.stat.failed", count: counts.failed,
                                tone: TaskSummaryPart.tone(forCount: counts.failed,
                                                           negativeWhenPositive: true)),
            ])
    }
}

/// One row of the 加入队列 dropdown. **新建队列 comes first** and the queues follow
/// in creation order: creating a lane is the step that most often comes next, and
/// it must not end up under a long list of existing queues. The panel turns these
/// into menu items (this is the headlessly asserted half of the dropdown).
struct QueuePickerItem: Equatable {
    var title: String
    /// nil = 新建队列…
    var queueID: String?
    var branch: String?

    var isNewQueue: Bool { queueID == nil }

    static func build(_ choices: [QueueChoice]) -> [QueuePickerItem] {
        var items = [QueuePickerItem(title: L10n.tr("tasks.queue.new"), queueID: nil, branch: nil)]
        items.append(contentsOf: choices.map {
            QueuePickerItem(title: $0.name, queueID: $0.id, branch: $0.branch)
        })
        return items
    }
}

/// The centred empty state: what it says, which symbol it shows, and whether it
/// offers the inline 新建任务 button. A filter that matches nothing offers
/// nothing — the way out there is to switch the filter back.
struct TasksEmptyStateModel: Equatable {
    var messageKey: String
    var symbol: String
    var showsNewTask: Bool
    /// The unfiltered empty board ALSO shows the 使用说明 inline (the user's request:
    /// no queues / no tasks → the content area teaches the panel). A filter that
    /// matches nothing must NOT: the way out there is to switch the filter back.
    var showsHelp: Bool

    static func build(filtered: Bool, githubRepo: Bool) -> TasksEmptyStateModel {
        if filtered {
            return TasksEmptyStateModel(messageKey: "tasks.emptyFiltered",
                                        symbol: "line.3.horizontal.decrease.circle",
                                        showsNewTask: false, showsHelp: false)
        }
        return TasksEmptyStateModel(messageKey: githubRepo ? "tasks.empty" : "tasks.emptyManualOnly",
                                    symbol: "checklist",
                                    showsNewTask: true, showsHelp: true)
    }
}

/// 使用说明 —— shown INLINE while the board is empty, and in the 帮助 drawer once it
/// has content. Keys only, so a language switch just re-renders it.
struct TasksHelpModel: Equatable {
    struct Section: Equatable {
        var headingKey: String
        var lineKeys: [String]
    }
    var titleKey: String
    var introKey: String
    var sections: [Section]

    /// Every key is prefixed `tasks.help.` — asserted by the ui tests, so a new
    /// section cannot ship without its bilingual strings (tests/l10n also lints them).
    static func build() -> TasksHelpModel {
        TasksHelpModel(
            titleKey: "tasks.help.title",
            introKey: "tasks.help.intro",
            sections: [
                Section(headingKey: "tasks.help.create.heading",
                        lineKeys: ["tasks.help.create.body"]),
                Section(headingKey: "tasks.help.queue.heading",
                        lineKeys: ["tasks.help.queue.body"]),
                Section(headingKey: "tasks.help.workflow.heading",
                        lineKeys: ["tasks.help.workflow.body"]),
                Section(headingKey: "tasks.help.session.heading",
                        lineKeys: ["tasks.help.session.body"])
            ])
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
    /// The composer's ONE box, exactly as typed: first line = title, the lines
    /// after it = description (a single line is both — see TaskDraft.composed).
    var content: String
    /// Set once the submit button was pressed on an incomplete draft, so the
    /// hint shows up when it is actually needed rather than while typing.
    var attempted: Bool

    var headingKey: String { mode.isCreate ? "tasks.new.title" : "tasks.new.editTitle" }
    var submitKey: String { mode.isCreate ? "tasks.new.create" : "tasks.new.save" }
    var infoKey: String { mode.isCreate ? "tasks.new.info" : "tasks.new.editInfo" }

    /// What would be created / saved right now — the box parsed into a title and
    /// a description.
    var draft: TaskDraft { TaskDraft.composed(from: content) }
    /// The two things the box currently means (read-only views of the parse).
    var title: String { draft.normalizedTitle }
    var body: String { draft.normalizedBody }
    var canSubmit: Bool { draft.isValid }

    /// The first problem as an L10n key — shown only after a submit attempt
    /// (the button stays disabled until the draft is complete, so the form never
    /// nags while it is being typed into).
    var problemKey: String? {
        attempted ? draft.problem : nil
    }

    var isPristine: Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The form as it is while the user types (live, so the submit button follows
    /// what is actually in the box).
    func typed(content: String) -> TaskComposerModel {
        var copy = self
        copy.content = content
        return copy
    }

    /// The form after a submit attempt (turns on the problem hint).
    func attemptedSubmit() -> TaskComposerModel {
        var copy = self
        copy.attempted = true
        return copy
    }

    static func build(mode: Mode, content: String = "") -> TaskComposerModel {
        TaskComposerModel(mode: mode, content: content, attempted: false)
    }

    /// The composer for editing an existing task, prefilled from the board: its
    /// title and description go back into the one box (and a one-line task comes
    /// back as one line, not as the same sentence twice).
    static func edit(_ task: TaskItem) -> TaskComposerModel {
        build(mode: .edit(taskID: task.id),
              content: TaskDraft.combined(title: task.title, body: task.body))
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
    /// while editing — the two hints differ, see effectiveBranchHint. The two
    /// are not symmetrical on purpose: creating a queue in a git repository is
    /// the common case and it wants a branch, while clearing the field of an
    /// existing queue is the only way to say "run where it is".
    var branch: String
    var baseBranch: String
    var autoPR: Bool
    /// 不切分支: the queue leaves git alone and its tasks run wherever the
    /// worktree already is. Explicit, so 「留空」 no longer has to carry two
    /// meanings — the old shape could not express "no branch" while creating,
    /// which made every queue created in a non-git directory fail with
    /// tasks.errNotGit (docs/issue-runner-design.md §V2-7).
    var skipsBranch: Bool
    /// Whether GitHub is available in this workspace. Without it the form does
    /// not offer a PR switch at all (a dead checkbox is worse than a sentence).
    var prAvailable: Bool
    /// Whether the workspace is a git repository at all. Without one the branch
    /// fields are taken away and the form says why, instead of promising a
    /// branch switch the runner can only fail on.
    var gitAvailable: Bool
    /// Whether the workspace has ANY remote to push to (GitHub or an internal one).
    /// 直接推送 needs it; 合并到基线 does not (it merges locally). Defaults true so a
    /// model that only drives the text fields is not accidentally restricted.
    var remoteAvailable: Bool = true
    /// The workspace's OWN default branch (origin/HEAD, else main/master/current):
    /// the placeholder of 基于分支 and the fallback when the field is left empty.
    /// Assuming "main" made a master-based repo fail its first task.
    var defaultBaseBranch: String
    /// Whether the 高级设置 section (分支 / 基于分支 / 工作流 / 自动收尾) is open. The
    /// branch is derived from the name, so creating a queue only asks for a name;
    /// editing a queue's settings opens everything, because that is what the user
    /// came for.
    var showsAdvanced: Bool
    var attempted: Bool
    /// This queue's own 工作流 (决策: 全局默认 + 队列级覆盖). nil = 跟随设置.
    var integration: QueueIntegration?
    /// The panel's global default, shown by the 跟随设置 item as 「当前」.
    var defaultIntegration: QueueIntegration = .pr
    /// What THIS workspace usually wants — a recommendation shown in the picker,
    /// never enforced (github→pr / git→merge / 普通目录→push).
    var recommendedIntegration: QueueIntegration = .pr

    /// The mode this queue will really use: its own override, else the panel default.
    var effectiveIntegration: QueueIntegration { integration ?? defaultIntegration }

    /// The picker's items, in order: 跟随工作区设置 first (the default), then the modes.
    var integrationChoices: [QueueIntegration?] { [nil] + QueueIntegration.displayOrder }

    /// Whether a mode can actually run in THIS workspace: the picker greys out the
    /// rest and says why (the runner would refuse them anyway).
    func isIntegrationAvailable(_ mode: QueueIntegration) -> Bool {
        QueueIntegration.available(mode, isGit: gitAvailable, hasGitHubRemote: prAvailable,
                                   hasRemote: remoteAvailable)
    }

    /// Follow the panel setting, or pin this queue to one mode.
    func typedIntegration(_ mode: QueueIntegration?) -> QueueComposerModel {
        var copy = self
        copy.integration = mode
        return copy
    }

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
        if skipsBranch { return L10n.tr("tasks.queue.noBranch") }
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

    /// nil = derive the default from the name; "" = do not switch branches
    /// (the board reads the empty string as nil — see TaskBoard.createQueue).
    var branchValue: String? {
        if skipsBranch { return "" }
        let value = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var normalizedBaseBranch: String {
        let value = baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? defaultBaseBranch : value
    }

    func typed(name: String, branch: String, baseBranch: String, autoPR: Bool,
               skippingBranch: Bool? = nil) -> QueueComposerModel {
        var copy = self
        copy.name = name
        copy.branch = branch
        copy.baseBranch = baseBranch
        copy.autoPR = autoPR
        // nil = the caller does not own this switch (the headless models that
        // only drive the text fields); the view always passes it.
        if let skippingBranch = skippingBranch { copy.skipsBranch = skippingBranch }
        return copy
    }

    /// What the branch field shows while it is EMPTY. The two modes mean different
    /// things here, so they say different things — the old single line ("留空 =
    /// 自动生成（不带分支则不切分支）") mixed both and read as a contradiction.
    var branchPlaceholder: String {
        // 不切分支 already says what the field would hold: the two placeholders
        // differ by mode, and the "no branch" state is the same in both.
        if skipsBranch { return L10n.tr("tasks.queue.branchPlaceholderEdit") }
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

    /// 新建队列 (standalone, no task to join). Defaults describe a git
    /// repository that cannot open a PR; forWorkspace(git:pr:) narrows them to
    /// the workspace the form is really being filled in for.
    static func create() -> QueueComposerModel {
        QueueComposerModel(mode: .create(taskID: nil), name: "", branch: "", baseBranch: "main",
                           autoPR: false, skipsBranch: false, prAvailable: false,
                           gitAvailable: true, defaultBaseBranch: "main",
                           showsAdvanced: false, attempted: false)
    }

    /// 新建队列 from a task's 加入队列 ▾ menu: the new queue takes the task.
    static func create(taskID: String) -> QueueComposerModel {
        var model = create()
        model.mode = .create(taskID: taskID)
        return model
    }

    /// The queue's settings, prefilled — with 高级设置 already open: editing a
    /// queue IS editing its branch and PR switch. A queue with no branch opens
    /// on 不切分支, which is what its cards are already doing.
    static func edit(_ queue: TaskQueue, prAvailable: Bool,
                     gitAvailable: Bool = true,
                     hasRemote: Bool = true,
                     defaultBaseBranch: String = "main",
                     defaultIntegration: QueueIntegration = .pr) -> QueueComposerModel {
        var model = QueueComposerModel(mode: .edit(queueID: queue.id), name: queue.name,
                                       branch: queue.branch ?? "", baseBranch: queue.baseBranch,
                                       autoPR: queue.autoPR, skipsBranch: queue.branch == nil,
                                       prAvailable: prAvailable, gitAvailable: gitAvailable,
                                       remoteAvailable: hasRemote,
                                       defaultBaseBranch: defaultBaseBranch,
                                       showsAdvanced: true, attempted: false)
        model.integration = queue.integration
        model.defaultIntegration = defaultIntegration
        model.recommendedIntegration = QueueIntegration.recommended(isGit: gitAvailable,
                                                                    hasGitHubRemote: prAvailable)
        return model
    }

    /// Narrow the form to what THIS workspace can actually do.
    ///
    /// A directory that is not a git repository cannot switch branches at all,
    /// so a queue created there starts as 不切分支 — a queue that asks for a
    /// branch would be created happily and then fail its first task with
    /// tasks.errNotGit. Editing is left alone: an existing queue keeps its
    /// branch visible (and clearable) rather than having it silently dropped.
    func forWorkspace(git: Bool, pr: Bool, hasRemote: Bool = true,
                      defaultBase: String = "main",
                      defaultIntegration: QueueIntegration = .pr) -> QueueComposerModel {
        var copy = self
        copy.gitAvailable = git
        copy.prAvailable = pr
        copy.remoteAvailable = hasRemote
        copy.defaultBaseBranch = defaultBase
        copy.defaultIntegration = defaultIntegration
        // The recommendation follows the workspace, not the global default: a
        // GitHub repo suggests pr, another git repo a local merge, a plain folder
        // a plain push. It is only ever a suggestion.
        copy.recommendedIntegration = QueueIntegration.recommended(isGit: git, hasGitHubRemote: pr)
        // Prefill the workspace's own default branch so the user sees what the
        // queue will really be based on (it stays editable).
        if mode.isCreate, baseBranch.isEmpty || baseBranch == "main" { copy.baseBranch = defaultBase }
        if !git, mode.isCreate {
            copy.skipsBranch = true
            copy.branch = ""
        }
        return copy
    }
}
