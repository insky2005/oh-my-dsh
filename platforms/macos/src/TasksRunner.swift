import Foundation

// MARK: - Failure reasons

/// Why a task failed. The raw value IS the L10n key stored in the board and
/// shown on the card (the panel renders L10n.tr(error)), so a missing entry
/// surfaces in tests/l10n rather than on screen.
enum TaskFailure: String {
    case interrupted = "tasks.errInterrupted"
    case notGitRepo = "tasks.errNotGit"
    case dirtyWorktree = "tasks.errDirtyTree"
    case checkout = "tasks.errBranch"
    case pull = "tasks.errPull"
    case session = "tasks.errSession"
    case prompt = "tasks.errPrompt"
    case timeout = "tasks.errTimeout"
    case noPush = "tasks.errNoPush"
}

// MARK: - git

/// Where entering a queue's branch ended up.
enum GitEnterResult: Equatable {
    /// The queue has no branch: git is left completely alone.
    case noBranch
    /// Queue tasks after the first: the branch is already checked out.
    case alreadyOnBranch
    case switched
    case notGitRepo
    case dirtyWorktree
    case checkoutFailed
    case pullFailed
    case createBranchFailed
}

/// The git half of the runner. Every command goes through the injected closure,
/// so a test can script a repository without touching the disk.
///
/// v1 ran checkout and pull with their exit codes IGNORED, which let a task
/// start from the previous task's branch or from a stale commit — the exact
/// problem docs/issue-runner-design.md §V2-5 fixes. Here every step is checked
/// and every failure is reported.
struct TaskGit {
    /// git with these arguments in the repo root; nil when the command failed or
    /// could not be launched at all.
    var run: ([String]) -> String?
    /// Preferred remote name (github > origin > first), or nil for a repo with
    /// no remote at all — local-only repos are legitimate: no pull, no push
    /// check, no PR.
    var remoteName: () -> String?

    func currentBranch() -> String? {
        run(["rev-parse", "--abbrev-ref", "HEAD"])
    }

    /// Fails CLOSED: a status command that cannot run counts as not clean.
    func isWorktreeClean() -> Bool {
        guard let out = run(["status", "--porcelain"]) else { return false }
        return out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func branchExists(_ name: String) -> Bool {
        run(["rev-parse", "--verify", "--quiet", name]) != nil
    }

    /// True when the branch exists on the push remote. A repo without a remote
    /// counts as nothing-to-push here; the caller reports that case separately.
    func isBranchPushed(_ branch: String) -> Bool {
        guard let remote = remoteName() else { return true }
        let out = run(["ls-remote", "--heads", remote, branch])
        return out?.contains(branch) == true
    }

    /// Put the worktree on the queue's branch:
    ///   clean check -> checkout <base> -> pull --ff-only -> checkout[-b] <branch>
    /// Every step must succeed; the pull is skipped when there is no remote
    /// (a local-only repo has nothing to fast-forward from).
    func enter(branch: String?, base: String) -> GitEnterResult {
        guard let branch = branch, !branch.isEmpty else { return .noBranch }
        guard let current = currentBranch() else { return .notGitRepo }
        if current == branch { return .alreadyOnBranch }
        guard isWorktreeClean() else { return .dirtyWorktree }
        guard run(["checkout", base]) != nil else { return .checkoutFailed }
        if remoteName() != nil, run(["pull", "--ff-only"]) == nil { return .pullFailed }
        if branchExists(branch) {
            guard run(["checkout", branch]) != nil else { return .checkoutFailed }
        } else {
            guard run(["checkout", "-b", branch]) != nil else { return .createBranchFailed }
        }
        return .switched
    }
}

// MARK: - Session / repo side effects (injected)

/// Everything the runner needs from the outside world. The panel passes the real
/// dsh RPC plus git; tests pass scripted fakes, which is what makes the whole
/// pipeline (branch → session → prompt → poll → push → PR) headless.
struct TaskRunnerEnv {
    var git: TaskGit
    /// The session's working directory (the repo root).
    var repoRoot: String
    var createSession: (_ cwd: String) -> String?
    var renameSession: (_ sessionId: String, _ title: String) -> Bool
    var promptSession: (_ sessionId: String, _ text: String) -> Bool
    var sessionRunning: (_ sessionId: String) -> Bool
    var cancelSession: (_ sessionId: String) -> Bool
    /// Existing open PR for the head branch, or nil. Only called when the queue
    /// wants a PR (a GitHub workspace).
    var findExistingPR: (_ branch: String) -> String?
    var createPR: (_ branch: String, _ base: String, _ title: String, _ body: String) -> String?
    /// Title and body for the queue's pull request.
    var prText: (_ task: TaskItem, _ branch: String) -> (title: String, body: String)
    /// The text handed to the agent.
    var promptText: (_ task: TaskItem, _ queue: TaskQueue?) -> String
    /// Persist the machine-scoped half of the board (manual.json / queues.json /
    /// local.json).
    var persist: (TaskBoard) -> Void
    /// Persist one github task into the committed index.
    var persistIssueTask: (TaskItem) -> Void
    var log: (String) -> Void
    /// Run blocking work (git, HTTP, RPC) off the main thread, then hop back.
    /// Tests pass an immediate, synchronous implementation.
    var perform: (_ blocking: @escaping () -> Void, _ completion: @escaping () -> Void) -> Void

    /// A perform that runs both closures right here — the headless default.
    static func synchronous(_ blocking: () -> Void, _ completion: () -> Void) {
        blocking()
        completion()
    }
}

// MARK: - Prompts

/// Texts handed to the agent: v1's issue-resolve instruction for issue tasks
/// plus a generic one for manual tasks, with the same safety rails (one branch,
/// run the tests, commit, push, never echo the token).
enum TaskPrompts {

    static func issue(number: Int, title: String, branch: String) -> String {
        var lines: [String] = []
        lines.append("请加载 issue-resolve skill 并完成以下 GitHub issue 的修复：")
        lines.append("")
        lines.append("## Issue #\(number)")
        lines.append("标题：\(title)")
        lines.append("")
        lines.append("要求：")
        lines.append("1. 加载全局 $DSH_HOME/skills/issue-resolve/SKILL.md（或内嵌说明）并严格按其流程执行（读 issue → 改代码 → 跑测试 → commit → push）；")
        lines.append("2. 当前分支应为 \(branch)，只在此分支上工作；")
        lines.append("3. 推送私有仓库/需要认证的 GitHub 调用时，token 在 $DSH_HOME/tokens/<owner>-<repo> 或 $DSH_HOME/gh-token（默认目录 ~/.dsh；cat 读取即可，绝不在对话/汇报中回显）；")
        lines.append("4. 完成后简短汇报改动与测试结果。")
        return lines.joined(separator: "\n")
    }

    /// Manual task: the user's own title and description plus the same rails.
    static func manual(title: String, body: String?, branch: String?, queueName: String?) -> String {
        var lines: [String] = []
        lines.append("请完成以下任务：")
        lines.append("")
        lines.append("## 任务")
        lines.append(title)
        if let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            lines.append("")
            lines.append(body)
        }
        lines.append("")
        lines.append("要求：")
        if let queueName = queueName {
            lines.append("1. 本任务是队列「\(queueName)」中的一项，与其他任务共享同一分支与改动；")
        } else {
            lines.append("1. 本任务独立执行；")
        }
        if let branch = branch, !branch.isEmpty {
            lines.append("2. 当前分支应为 \(branch)，只在此分支上工作（不要新建分支）；")
        } else {
            lines.append("2. 在当前已检出的分支上工作（不要新建分支）；")
        }
        lines.append("3. 改完代码后跑相关测试，确保通过；")
        lines.append("4. commit（建议 feat/fix: 简述）并把当前分支 push 到远端；")
        lines.append("5. 需要 GitHub 写操作时，token 在 $DSH_HOME/tokens/<owner>-<repo> 或 $DSH_HOME/gh-token（默认目录 ~/.dsh；cat 读取即可，绝不在对话/汇报中回显）；")
        lines.append("6. 完成后简短汇报改动与测试结果。")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Runner

/// Drives the board: one task at a time, always, and a whole queue in order.
///
/// The runner owns every mutation of the board (enqueue / start / finish /
/// cancel / restart recovery) so the panel only renders and calls in. Blocking
/// work (git, HTTP, dsh RPC) is handed to env.perform, which runs it away from
/// the main thread and calls back — leaving every board mutation in one place.
///
/// step() is the single timer entry: it starts the next task when the serial
/// slot is free, advances the running one, and reports whether anything is in
/// flight. Tests drive it with a synchronous perform.
final class TasksRunner {

    private(set) var board: TaskBoard
    private var env: TaskRunnerEnv
    private let timeout: TimeInterval

    private struct Active {
        var taskID: String
        var queueID: String?
        var branch: String?
        var sessionId: String
        var startedAt: Date
    }

    private enum Phase {
        case idle
        case starting(String)
        case active(Active)
        case finishing(String)
    }

    private enum StartResult {
        case started(sessionId: String, branch: String?)
        /// The session id is carried along when one was created before the
        /// failure (a started-but-unnamed session is still findable in dsh web).
        case failed(TaskFailure, String?)
    }

    private enum FinishOutcome {
        case done(prUrl: String?)
        case failed(TaskFailure)
    }

    private var phase: Phase = .idle

    init(board: TaskBoard, env: TaskRunnerEnv, timeout: TimeInterval = 30 * 60) {
        self.board = board
        self.env = env
        self.timeout = timeout
    }

    var isBusy: Bool {
        if case .idle = phase { return false }
        return true
    }

    var runningTaskID: String? {
        switch phase {
        case .starting(let id), .finishing(let id): return id
        case .active(let active): return active.taskID
        case .idle: return nil
        }
    }

    /// Replace the board (after loading from disk). Nothing starts by itself: a
    /// restart must be an explicit 开始.
    func adopt(_ board: TaskBoard) {
        self.board = board
        phase = .idle
    }

    /// The restart pass: a task that was running cannot still be running (its
    /// session died with the app), and an active queue is paused.
    @discardableResult
    func reconcileAfterRestart() -> (interrupted: [String], pausedQueues: [String]) {
        let result = board.reconcileAfterRestart(interruptedError: TaskFailure.interrupted.rawValue)
        phase = .idle
        persist()
        return result
    }

    // MARK: - The timer entry

    /// One step. Returns true while any task is still in flight.
    @discardableResult
    func step(now: Date = Date()) -> Bool {
        switch phase {
        case .starting, .finishing:
            return true
        case .idle:
            _ = pump(now: now)
            return isBusy
        case .active(let active):
            if env.sessionRunning(active.sessionId) {
                if now.timeIntervalSince(active.startedAt) > timeout {
                    env.log("tasks: " + active.taskID + " timed out after " + String(Int(timeout)) + "s")
                    _ = env.cancelSession(active.sessionId)
                    phase = .idle
                    board.markFailed(active.taskID, error: TaskFailure.timeout.rawValue, at: now)
                    persist()
                    _ = pump(now: now)
                }
                return isBusy
            }
            finish(active: active, now: now)
            return isBusy
        }
    }

    // MARK: - Starting

    /// Start the next startable task, if the serial slot is free. Returns its id.
    @discardableResult
    func pump(now: Date = Date()) -> String? {
        guard case .idle = phase else { return nil }
        guard let taskID = board.nextStartable(), let task = board.task(taskID) else { return nil }
        let queue = task.queueId.flatMap { board.queue($0) }
        let branch = queue?.branch
        let base = queue?.baseBranch ?? "main"
        let title = task.title
        let prompt = env.promptText(task, queue)
        let git = env.git
        let repoRoot = env.repoRoot
        let createSession = env.createSession
        let renameSession = env.renameSession
        let promptSession = env.promptSession
        let log = env.log

        phase = .starting(taskID)
        board.markRunning(taskID, at: now)
        persist()
        log("tasks: starting " + taskID + " on " + (branch ?? "the current branch"))

        var startResult: StartResult = .failed(.session, nil)
        env.perform({
            let entered = git.enter(branch: branch, base: base)
            if let failure = TasksRunner.failure(for: entered) {
                startResult = .failed(failure, nil)
                return
            }
            guard let sessionId = createSession(repoRoot) else {
                startResult = .failed(.session, nil)
                return
            }
            _ = renameSession(sessionId, title)
            guard promptSession(sessionId, prompt) else {
                startResult = .failed(.prompt, sessionId)
                return
            }
            startResult = .started(sessionId: sessionId, branch: branch)
        }, {
            self.applyStart(taskID: taskID, result: startResult, now: now)
        })
        return taskID
    }

    private func applyStart(taskID: String, result: StartResult, now: Date) {
        phase = .idle
        switch result {
        case .started(let sessionId, let branch):
            let queueID = board.task(taskID)?.queueId
            phase = .active(Active(taskID: taskID, queueID: queueID, branch: branch,
                                   sessionId: sessionId, startedAt: now))
            board.local.sessions[taskID] = sessionId
            if let i = board.index(ofTask: taskID) { board.tasks[i].sessionId = sessionId }
            env.log("tasks: " + taskID + " running in " + sessionId)
            persist()
        case .failed(let failure, let sessionId):
            if let sessionId = sessionId {
                board.local.sessions[taskID] = sessionId
                if let i = board.index(ofTask: taskID) { board.tasks[i].sessionId = sessionId }
            }
            env.log("tasks: " + taskID + " could not start (" + failure.rawValue + ")")
            board.markFailed(taskID, error: failure.rawValue, at: now)
            persist()
            _ = pump(now: now)
        }
    }

    private static func failure(for entered: GitEnterResult) -> TaskFailure? {
        switch entered {
        case .noBranch, .alreadyOnBranch, .switched: return nil
        case .notGitRepo: return .notGitRepo
        case .dirtyWorktree: return .dirtyWorktree
        case .checkoutFailed, .createBranchFailed: return .checkout
        case .pullFailed: return .pull
        }
    }

    // MARK: - Finishing

    private func finish(active: Active, now: Date) {
        let queue = active.queueID.flatMap { board.queue($0) }
        let branch = active.branch
        let base = queue?.baseBranch ?? "main"
        // The queue's PR is opened once, when its LAST task finishes: every task
        // in a queue shares one branch, and GitHub allows one open PR per head.
        let queueHasMore = queue?.taskIds.contains { id in
            id != active.taskID && (board.task(id)?.state == .queued || board.task(id)?.state == .running)
        } ?? false
        let wantsPR = (queue?.autoPR ?? false) && !queueHasMore
        let prText = board.task(active.taskID).map { env.prText($0, branch ?? base) }
        let git = env.git
        let findExistingPR = env.findExistingPR
        let createPR = env.createPR
        let log = env.log
        let taskID = active.taskID

        phase = .finishing(taskID)
        var outcome: FinishOutcome = .done(prUrl: nil)
        env.perform({
            if let branch = branch {
                if git.remoteName() == nil {
                    log("tasks: " + taskID + " has no remote — skipping the push check")
                } else if !git.isBranchPushed(branch) {
                    outcome = .failed(.noPush)
                    return
                }
            }
            guard wantsPR, let branch = branch, let prText = prText else {
                outcome = .done(prUrl: nil)
                return
            }
            if let existing = findExistingPR(branch) {
                log("tasks: reusing the open PR for " + branch)
                outcome = .done(prUrl: existing)
                return
            }
            if let url = createPR(branch, base, prText.title, prText.body) {
                outcome = .done(prUrl: url)
            } else {
                // A PR that cannot be opened (internal remote, no permission) is
                // NOT a task failure: the branch is pushed and the user can open
                // it by hand.
                log("tasks: PR not created for " + branch + " — the branch is pushed")
                outcome = .done(prUrl: nil)
            }
        }, {
            self.applyFinish(taskID: taskID, outcome: outcome, now: now)
        })
    }

    private func applyFinish(taskID: String, outcome: FinishOutcome, now: Date) {
        phase = .idle
        let isIssue = board.task(taskID)?.source == .github
        switch outcome {
        case .done(let prUrl):
            board.markDone(taskID, prUrl: prUrl, at: now)
            let suffix = prUrl.map { " (" + $0 + ")" } ?? ""
            env.log("tasks: " + taskID + " done" + suffix)
        case .failed(let failure):
            board.markFailed(taskID, error: failure.rawValue, at: now)
            env.log("tasks: " + taskID + " failed (" + failure.rawValue + ")")
        }
        if isIssue, let task = board.task(taskID) { env.persistIssueTask(task) }
        persist()
        _ = pump(now: now)
    }

    private func persist() {
        env.persist(board)
    }

    // MARK: - Panel-facing mutations

    @discardableResult
    func createQueue(name: String,
                     branch: String? = nil,
                     baseBranch: String = "main",
                     autoPR: Bool = false) -> TaskQueue {
        let queue = board.createQueue(name: name, branch: branch, baseBranch: baseBranch, autoPR: autoPR)
        persist()
        return queue
    }

    @discardableResult
    func updateQueue(_ queueID: String,
                     name: String? = nil,
                     branch: String?? = nil,
                     baseBranch: String? = nil,
                     autoPR: Bool? = nil) -> Bool {
        guard let qi = board.index(ofQueue: queueID) else { return false }
        if let name = name { board.queues[qi].name = name }
        if let branch = branch { board.queues[qi].branch = branch }
        if let baseBranch = baseBranch { board.queues[qi].baseBranch = baseBranch }
        if let autoPR = autoPR { board.queues[qi].autoPR = autoPR }
        persist()
        return true
    }

    @discardableResult
    func removeQueue(_ queueID: String) -> Bool {
        let removed = board.removeQueue(queueID)
        if removed { persist() }
        return removed
    }

    /// Put a task into a queue and start it when nothing else is running.
    ///
    /// A task added while NO queue is active makes its own queue the active one:
    /// that is what makes 「加入队列」equal 「开始」while the runner is idle. A
    /// queue restored as paused after a restart is never activated this way —
    /// that path loads the board instead of calling enqueue.
    @discardableResult
    func enqueue(taskID: String, into queueID: String) -> Bool {
        let ok = board.enqueue(taskID: taskID, into: queueID)
        guard ok else { return false }
        activateQueueIfIdle(queueID)
        persist()
        _ = pump()
        return true
    }

    /// Make this queue the active one when nothing is active yet.
    private func activateQueueIfIdle(_ queueID: String) {
        guard board.activeQueue() == nil else { return }
        _ = board.resumeQueue(queueID)
    }

    /// 移出队列: only meaningful while the task is still waiting.
    @discardableResult
    func dequeue(taskID: String) -> Bool {
        let ok = board.dequeue(taskID: taskID)
        if ok { persist() }
        return ok
    }

    /// Create the single-task queue an issue task runs in (决策 5) and start it.
    @discardableResult
    func startIssueTask(_ taskID: String) -> String? {
        guard let task = board.task(taskID), task.source == .github else { return nil }
        if let existing = board.autoQueueID(forTask: taskID) {
            // Reuse the queue; a failed/cancelled task goes through retry so it
            // becomes queued again instead of being skipped as a finished entry.
            if task.state == .failed || task.state == .cancelled {
                _ = board.retryAndResume(taskID)
            } else {
                _ = board.resumeQueue(existing)
            }
            persist()
            _ = pump()
            return existing
        }
        let queue = TaskQueue.auto(for: task)
        board.queues.append(queue)
        _ = board.enqueue(taskID: taskID, into: queue.id)
        _ = board.resumeQueue(queue.id)   // 处理 = 开始：issue 任务不等用户再点一次
        persist()
        _ = pump()
        return queue.id
    }

    /// 开始队列.
    @discardableResult
    func startQueue(_ queueID: String) -> Bool {
        let ok = board.resumeQueue(queueID)
        if ok {
            persist()
            _ = pump()
        }
        return ok
    }

    @discardableResult
    func pauseQueue(_ queueID: String) -> Bool {
        let ok = board.pauseQueue(queueID)
        if ok { persist() }
        return ok
    }

    /// 重试 a failed/cancelled task (and resume its queue).
    @discardableResult
    func retry(taskID: String) -> Bool {
        let ok = board.retryAndResume(taskID)
        guard ok else { return false }
        persist()
        _ = pump()
        return true
    }

    /// 跳过并继续: keep the failed record, resume the queue, run the next task.
    @discardableResult
    func skip(taskID: String) -> Bool {
        guard let queueID = board.task(taskID)?.queueId else { return false }
        let ok = board.resumeQueue(queueID)
        if ok {
            persist()
            _ = pump()
        }
        return ok
    }

    /// 取消 the running task: cancel its session, keep the branch and session for
    /// traceability, pause its queue.
    @discardableResult
    func cancelRunning() -> Bool {
        guard case .active(let active) = phase else { return false }
        _ = env.cancelSession(active.sessionId)
        phase = .idle
        board.markCancelled(active.taskID)
        if let task = board.task(active.taskID), task.source == .github { env.persistIssueTask(task) }
        persist()
        env.log("tasks: " + active.taskID + " cancelled")
        _ = pump()
        return true
    }
}
