import Foundation

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

/// Is the queue's branch on the remote? THREE answers, because "the question could
/// not be asked" (no credentials for a private remote, network hiccup) is not the
/// same as "it is not there": reading the first as the second marked finished work
/// as failed with 「分支未推送到远端（代理未 push？）」.
enum BranchPushState: Equatable {
    case pushed
    case notPushed
    /// ls-remote itself failed — nobody knows.
    case unknown
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

    /// Whether this repository has any commit at all. False for a directory that was
    /// just `git init`ed — HEAD is unborn there (`git rev-parse --verify HEAD` fails).
    func hasCommits() -> Bool {
        run(["rev-parse", "--verify", "--quiet", "HEAD"]) != nil
    }

    /// Whether the branch exists on the push remote. A repo without a remote is
    /// the caller's business (it logs that case separately); a FAILED ls-remote is
    /// unknown, never "not pushed".
    func branchPushState(_ branch: String) -> BranchPushState {
        guard let remote = remoteName() else { return .pushed }
        guard let out = run(["ls-remote", "--heads", remote, branch]) else { return .unknown }
        return out.contains(branch) ? .pushed : .notPushed
    }

    /// The commits the branch carries on top of `base` ("a1b2c3 subject"), or nil
    /// when git could not answer. This is the STRUCTURAL half of a 交接简报: what
    /// the earlier tasks in the queue actually changed.
    func commits(base: String) -> [String]? {
        guard let out = run(["log", "--oneline", "--no-decorate", base + "..HEAD"]) else { return nil }
        return out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Put the worktree on the queue's branch:
    ///   clean check -> checkout <base> -> pull --ff-only -> checkout[-b] <branch>
    /// Every step must succeed; the pull is skipped when there is no remote
    /// (a local-only repo has nothing to fast-forward from).
    ///
    /// A repository with NO COMMITS YET is the one exception — see below. It is a
    /// normal situation (「初始化 git 仓库」 is an entirely reasonable task, and the
    /// shell may now be looking at the repository that task just created), and the
    /// normal sequence cannot work in it.
    func enter(branch: String?, base: String) -> GitEnterResult {
        guard let branch = branch, !branch.isEmpty else { return .noBranch }
        guard let current = currentBranch() else { return .notGitRepo }
        if current == branch { return .alreadyOnBranch }
        // An UNBORN repository (fresh `git init`, no commits): HEAD points at nothing,
        // so `git checkout <base>` fails with "pathspec … did not match" — the task
        // right after 初始化 git 仓库 failed with tasks.errCheckout before it could do
        // anything at all. Its files are all untracked too, so the worktree is "dirty"
        // by definition and the clean check would stop it as well. Nothing can be lost
        // in a repository that has no commit: the branch is created from the unborn
        // HEAD, and the task's work simply becomes the first commit.
        let empty = !hasCommits()
        if !empty {
            guard isWorktreeClean() else { return .dirtyWorktree }
            guard run(["checkout", base]) != nil else { return .checkoutFailed }
            if remoteName() != nil, run(["pull", "--ff-only"]) == nil { return .pullFailed }
        }
        if branchExists(branch) {
            guard run(["checkout", branch]) != nil else { return .checkoutFailed }
        } else {
            guard run(["checkout", "-b", branch]) != nil else { return .createBranchFailed }
        }
        return .switched
    }
}

// MARK: - Session state

/// What dsh says about a task's session right now.
///
/// A Bool could not tell these apart, and the difference matters: the old code
/// read BOTH "the RPC failed" and "the session is not in the list" as "not
/// running", i.e. as "the task is over" — one transient RPC hiccup declared a
/// task finished while its agent was still working.
enum SessionState: Equatable {
    /// dsh says it is working right now.
    case running
    /// dsh lists it and says it is not working any more → the task is over.
    case idle
    /// The question could not be answered (RPC failed): assume nothing, ask again
    /// on the next tick.
    case unknown
    /// dsh does not list the session at all (deleted from the sidebar, or the
    /// server restarted). Counted; only a persistent absence becomes a failure.
    case missing
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
    /// What dsh says about the running task's session (see SessionState).
    var sessionState: (_ sessionId: String) -> SessionState
    /// The branch an ISSUE task's queue is based on — the workspace's own default
    /// branch (see TaskBranch.defaultBaseBranch), not an assumed "main".
    var defaultBaseBranch: String = "main"
    /// Whether this workspace is a git repository at all. A queue created where it
    /// is false gets NO branch (the pipeline then never touches git — §V2-7), which
    /// is exactly what 全部处理 has to honour when it builds one queue per task.
    var canSwitchBranches: Bool = true
    /// Whether this workspace can open a pull request at all (a GitHub remote).
    /// It decides whether a task pushes at all — see the push policy in finish().
    var canOpenPR: () -> Bool = { true }
    var cancelSession: (_ sessionId: String) -> Bool
    /// Existing open PR for the head branch, or nil. Only called when the queue
    /// wants a PR (a GitHub workspace).
    var findExistingPR: (_ branch: String) -> String?
    var createPR: (_ branch: String, _ base: String, _ title: String, _ body: String) -> String?
    /// Title and body for the queue's pull request.
    var prText: (_ task: TaskItem, _ branch: String) -> (title: String, body: String)
    /// The text handed to the agent. `brief` is the 交接简报 for a task that has
    /// work in front of it in its queue (nil when there is nothing to hand over).
    var promptText: (_ task: TaskItem, _ queue: TaskQueue?, _ brief: String?) -> String
    /// The agent's LAST text message of a session — its final report — or nil.
    /// BLOCKING (it reads a session log through the shell's core bridge), so the
    /// runner only calls it inside its background step.
    var sessionReport: (_ sessionId: String) -> String? = { _ in nil }
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

/// What the workspace directory IS, as a task's prompt has to tell it apart.
///
/// Three states, not two, because the same rail says three different things — and
/// because the states CONVERT, in both directions, by the user's own instructions:
///
/// 1. `.plain` — no repository at all. The shell's pipeline touches no git (§V2-7),
///    and `git init` is exactly how a task turns this into the next state;
/// 2. `.git` — a repository with no GitHub remote: branch and commit are real, a
///    push has nowhere to go, and `git remote add origin <url>` is how it becomes
///    the third. The reason a queue opens no PR here is the MISSING REMOTE, not a
///    queue setting (the old wording blamed the queue);
/// 3. `.github` — a GitHub remote: commit → push → PR is the real pipeline
///    (§ push policy: only a queue that can open a PR asks for a push).
///
/// Probed when the PROMPT is written, never captured when the runner was built:
/// the first task of a queue may be the one that inits the repository or adds the
/// remote, and the task after it must not be told the old story (a queue never
/// goes idle between its own tasks, so the panel's re-detection cannot step in).
enum TaskRepoShape: Equatable {
    case plain
    case git
    case github

    /// "Not a repository" dominates: a directory with no work tree has no remote
    /// either, whatever some probe says about one.
    static func detect(isGit: Bool, hasGitHubRemote: Bool) -> TaskRepoShape {
        guard isGit else { return .plain }
        return hasGitHubRemote ? .github : .git
    }
}

/// Texts handed to the agent: v1's issue-resolve instruction for issue tasks
/// plus a generic one for manual tasks, with the same safety rails (one branch,
/// run the tests, commit, push, never echo the token).
enum TaskPrompts {

    /// What the earlier tasks in a queue left behind — the 交接简报.
    ///
    /// One session per task keeps every context small (and keeps 审查/取消/会话名
    /// per task), but then a task starts with no memory of the one before it. The
    /// brief is how continuity travels: what the earlier tasks were, how they
    /// ended, what the agent said at the end of each, and which commits the branch
    /// already carries. Reports are NOT truncated — a shortened summary distorts
    /// exactly what the next task needs.
    struct QueueBrief: Equatable {
        struct Earlier: Equatable {
            var title: String
            var state: TaskState
            /// The failure's L10n key (its reason), for a task that did not finish.
            var errorKey: String?
            /// The agent's last words in that task's session, or nil.
            var report: String?
        }
        var queueName: String
        /// 1-based position of the task this brief is for.
        var position: Int
        var total: Int
        var earlier: [Earlier]
        var branch: String?
        var base: String
        var commits: [String]
    }

    /// The brief as prompt text, or nil when there is nothing to hand over.
    static func briefSection(_ brief: QueueBrief?) -> String? {
        guard let brief = brief else { return nil }
        guard !brief.earlier.isEmpty || !brief.commits.isEmpty else { return nil }
        var lines: [String] = []
        lines.append("## 队列上下文（前面任务留下的状态）")
        lines.append("本任务属于队列「\(brief.queueName)」，是第 \(brief.position)/\(brief.total) 个。")
        if !brief.earlier.isEmpty {
            lines.append("前面已经做过的：")
            for (index, earlier) in brief.earlier.enumerated() {
                var head = "\(index + 1). 「\(earlier.title)」"
                switch earlier.state {
                case .done: head += " —— 已完成"
                case .failed: head += " —— 失败（\(L10n.tr(earlier.errorKey ?? "tasks.errUnknown"))）"
                case .cancelled: head += " —— 被取消"
                default: head += " —— \(earlier.state.rawValue)"
                }
                lines.append(head)
                if let report = earlier.report, !report.isEmpty {
                    lines.append("   它的汇报：")
                    lines.append(report.split(separator: "\n").map { "   " + $0 }.joined(separator: "\n"))
                } else {
                    lines.append("   它没有留下汇报（会话里没有代理的最后文本）。")
                }
            }
        }
        if let branch = brief.branch, !brief.commits.isEmpty {
            lines.append("分支 \(branch) 上已经有这些提交（基于 \(brief.base)）：")
            for commit in brief.commits { lines.append("  " + commit) }
        }
        lines.append("上面是前面任务留下的状态：不要重做已完成的部分，只做本任务；")
        lines.append("如果发现前面留下的问题，先说明再决定是否顺手修。")
        return lines.joined(separator: "\n")
    }

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
    ///
    /// `pushes` follows the queue: a queue that will open a pull request needs the
    /// branch on the remote, and a queue that will not must NOT push — its work
    /// stays as local commits on the queue's branch (the agent is told so, or it
    /// pushes anyway out of habit).
    ///
    /// `shape` follows the WORKSPACE (see TaskRepoShape): it decides what the rails
    /// may even ask for, and it names the way out of the two states a task can
    /// convert — `git init` and `git remote add origin <url>`.
    static func manual(title: String, body: String?, branch: String?, queueName: String?,
                       pushes: Bool = true, brief: String? = nil,
                       shape: TaskRepoShape = .github) -> String {
        var lines: [String] = []
        lines.append("请完成以下任务：")
        lines.append("")
        lines.append("## 任务")
        lines.append(title)
        // 单行任务：描述就是标题本身 —— 那行已经在上面的「任务」里了，别重复。
        if let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty,
           body != title.trimmingCharacters(in: .whitespacesAndNewlines) {
            lines.append("")
            lines.append(body)
        }
        // The 交接简报 goes between the task and the requirements: context first,
        // then what to do with it.
        if let brief = brief, !brief.isEmpty {
            lines.append("")
            lines.append(brief)
        }
        lines.append("")
        lines.append("要求：")
        if let queueName = queueName {
            lines.append("1. 本任务是队列「\(queueName)」中的一项，与其他任务共享同一分支与改动；")
        } else {
            lines.append("1. 本任务独立执行；")
        }
        if shape == .plain {
            // Not a repository at all (§V2-7): the PIPELINE will not touch git, so
            // say that instead of asking for a branch/commit/push it can never honour.
            //
            // It must not read as a ban on the TASK, though: 「初始化 git 仓库」 is a
            // perfectly reasonable task, and the old wording (「不要 git init」) told the
            // agent to refuse exactly what the user asked for. The rail is "don't do
            // git for the shell's sake", not "don't do git".
            lines.append("2. 这不是 git 仓库：壳层不会切分支、不会提交、不会推送。默认直接在当前目录修改文件即可；任务本身要求初始化仓库或提交时，照任务做；")
        } else if let branch = branch, !branch.isEmpty {
            lines.append("2. 当前分支应为 \(branch)，只在此分支上工作（不要新建分支）；")
        } else {
            lines.append("2. 在当前已检出的分支上工作（不要新建分支）；")
        }
        lines.append("3. 改完代码后跑相关测试，确保通过；")
        // 第 4 条按「这个工作区现在是什么」分四种说法。两处转换都写在里：目录不是仓库
        // 时给出 git init → git remote add → push 这条路（任务很可能就是来建仓库的），
        // 仓库没有 GitHub 远端时给出 git remote add → push 这条路，并说清「这个队列不开
        // PR」的真正原因是**没有远端**，不是队列设置（旧文案错怪了队列设置）。
        if shape == .plain {
            lines.append("4. 默认不要 commit、不要 push（这里还没有仓库）；任务要求建立仓库／提交时才做，并把结果说清楚。要把它变成 GitHub 仓库就是三步：git init（若还没建）→ git remote add origin <GitHub 地址> → push（地址以任务里给的为准，没有就问，别自己编）；壳层随后会重新识别这个工作区，后面的任务就能用分支了；")
        } else if shape == .git {
            lines.append("4. commit（建议 feat/fix: 简述）；**不要 push**：这个仓库还没有 GitHub 远端，壳层不会开 PR，改动留在本地分支上即可；任务本身要求发布到 GitHub 时，先 git remote add origin <GitHub 地址> 再 push（地址以任务里给的为准，没有就问；之后壳层会重新识别这个工作区）；")
        } else if pushes {
            lines.append("4. commit（建议 feat/fix: 简述），并把当前分支 push 到远端（这个队列最后会开 PR，远端必须有这些提交）；")
        } else {
            lines.append("4. commit（建议 feat/fix: 简述）；**不要 push**：这个队列没有开自动 PR，改动只留在本地分支上；")
        }
        lines.append("5. 需要 GitHub 写操作时，token 在 $DSH_HOME/tokens/<owner>-<repo> 或 $DSH_HOME/gh-token（默认目录 ~/.dsh；cat 读取即可，绝不在对话/汇报中回显）；")
        lines.append("6. 完成后简短汇报改动与测试结果。")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Cancel

/// What 取消任务 actually did.
///
/// A Bool could not say WHY it did nothing, and the card's 取消任务 did nothing at
/// all during two windows the user cannot see: .starting (git status/checkout/pull
/// + session + prompt are in flight) and .finishing (push check / PR). The panel
/// uses this to explain instead of going quiet.
enum CancelOutcome: Equatable {
    /// The running session was cancelled and its queue paused.
    case cancelled
    /// The task is still STARTING: the request is remembered and applied the
    /// moment its session exists.
    case deferred
    /// The task is already FINISHING (push / PR): its work is over, there is
    /// nothing left to cancel.
    case finishing
    /// Nothing was running.
    case idle
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

    /// Polls that could not be answered / found nothing, since the last confirmed
    /// answer. See SessionState.
    private var unknownPolls = 0
    private var missingPolls = 0
    /// How many CONSECUTIVE polls must report a session as gone before the task is
    /// failed for it (the panel polls every 3s, so this is ~30s of silence).
    static let missingSessionPolls = 10

    private var phase: Phase = .idle
    /// 取消 asked for while the task was still STARTING: honoured in applyStart,
    /// as soon as there is a session to cancel. Cleared whenever a start begins.
    private var cancelRequested = false

    /// How long a task may run before its session is cancelled.
    ///
    /// 30 minutes used to be hard-coded and quietly killed long work; 60 is the
    /// default now and the panel reads an override from the shell config
    /// ("tasksTimeoutMinutes"). Whatever it is, the running card SHOWS it, so the
    /// deadline is never a surprise.
    static let defaultTimeout: TimeInterval = 60 * 60

    /// The limit in whole minutes (what the card prints).
    var timeoutMinutes: Int { Int(timeout / 60) }

    init(board: TaskBoard, env: TaskRunnerEnv, timeout: TimeInterval = TasksRunner.defaultTimeout) {
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

    /// Mutate the board WITHOUT touching the run state — the panel uses it to
    /// merge freshly fetched issues while a task may be running. Persists the
    /// machine half; the committed index is written per task by the caller.
    func updateBoard(_ transform: (inout TaskBoard) -> Void) {
        transform(&board)
        persist()
    }

    /// Replace the board (after loading from disk). Nothing starts by itself: a
    /// restart must be an explicit 开始. Only meaningful while idle.
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
            switch env.sessionState(active.sessionId) {
            case .running:
                unknownPolls = 0
                missingPolls = 0
                if now.timeIntervalSince(active.startedAt) > timeout {
                    env.log("tasks: " + active.taskID + " timed out after " + String(Int(timeout)) + "s")
                    _ = env.cancelSession(active.sessionId)
                    phase = .idle
                    board.markFailed(active.taskID, error: TaskFailure.timeout.rawValue, at: now)
                    persist()
                    _ = pump(now: now)
                }
                return isBusy
            case .idle:
                // dsh lists the session and says it is done: the task is over.
                finish(active: active, now: now)
                return isBusy
            case .unknown:
                // dsh could not answer (RPC failed / server busy). Assume NOTHING:
                // the task keeps running and we ask again next tick. This used to
                // be read as "not running", i.e. as a finished task.
                missingPolls = 0
                if unknownPolls % 10 == 0 {
                    env.log("tasks: " + active.taskID + " — dsh could not report on its session; still waiting")
                }
                unknownPolls += 1
                return isBusy
            case .missing:
                // dsh does not list it at all: deleted from the sidebar, or the
                // server was restarted. Only a PERSISTENT absence is a failure —
                // one missing poll is not evidence (the list is fetched live).
                unknownPolls = 0
                missingPolls += 1
                if missingPolls >= TasksRunner.missingSessionPolls {
                    env.log("tasks: " + active.taskID + " — its session is gone from dsh after "
                            + String(missingPolls) + " polls; nobody can say how the work ended")
                    phase = .idle
                    board.markFailed(active.taskID, error: TaskFailure.sessionGone.rawValue, at: now)
                    persist()
                    _ = pump(now: now)
                }
                return isBusy
            }
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
        let git = env.git
        let repoRoot = env.repoRoot
        let createSession = env.createSession
        let renameSession = env.renameSession
        let promptSession = env.promptSession
        let promptText = env.promptText
        let sessionReport = env.sessionReport
        let boardNow = board
        let log = env.log

        phase = .starting(taskID)
        cancelRequested = false
        unknownPolls = 0
        missingPolls = 0
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
            // The 交接简报 is built HERE, off the main thread: it reads the earlier
            // tasks' session logs (a core-bridge call) and asks git for the commits
            // the branch already carries.
            let brief = TasksRunner.brief(taskID: taskID, queue: queue, board: boardNow,
                                          git: git, sessionReport: sessionReport,
                                          branch: branch, base: base, position: nil)
            if let brief = brief, !brief.isEmpty {
                log("tasks: brief for " + taskID + " is " + String(brief.count) + " chars")
            }
            let prompt = promptText(task, queue, brief)
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
            if cancelRequested {
                // The user asked to cancel while this was starting: the session
                // exists now, so cancel it instead of letting the agent run on.
                cancelRequested = false
                _ = env.cancelSession(sessionId)
                board.local.sessions[taskID] = sessionId
                if let i = board.index(ofTask: taskID) { board.tasks[i].sessionId = sessionId }
                board.markCancelled(taskID)
                if let task = board.task(taskID), task.source == .github { env.persistIssueTask(task) }
                persist()
                env.log("tasks: " + taskID + " cancelled as soon as its session existed")
                _ = pump(now: now)
                return
            }
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

    /// The 交接简报 for one task: the earlier tasks of its queue (how they ended and
    /// what the agent said), plus the commits the queue's branch already carries.
    ///
    /// Returns the rendered prompt section, or nil when there is nothing to hand
    /// over (the first task of a queue, or a task that is not in one). Static and
    /// self-contained so it can run inside the background step.
    static func brief(taskID: String, queue: TaskQueue?, board: TaskBoard, git: TaskGit,
                      sessionReport: (String) -> String?, branch: String?, base: String,
                      position: Int?) -> String? {
        guard let queue = queue else { return nil }
        let index = position ?? queue.taskIds.firstIndex(of: taskID).map { $0 + 1 } ?? 1
        let earlier = queue.taskIds.prefix(max(0, index - 1)).compactMap { id -> TaskPrompts.QueueBrief.Earlier? in
            guard let task = board.task(id) else { return nil }
            // Everything that is BEHIND us counts, however it ended: a failed or
            // cancelled task left work and a story the next task must know (else
            // the retry re-explores from scratch).
            guard task.state == .done || task.state == .failed || task.state == .cancelled else { return nil }
            return TaskPrompts.QueueBrief.Earlier(title: task.title, state: task.state,
                                                  errorKey: task.error,
                                                  report: task.sessionId.flatMap { sessionReport($0) })
        }
        let commits = branch.map { _ in git.commits(base: base) ?? [] } ?? []
        let heading = TaskPrompts.QueueBrief(queueName: queue.name, position: index,
                                             total: queue.taskIds.count, earlier: earlier,
                                             branch: branch, base: base, commits: commits)
        return TaskPrompts.briefSection(heading)
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
        // PUSH POLICY (2026-09-27): a task pushes ONLY when its queue is about to
        // open a pull request. Otherwise the work stays as local commits on the
        // queue's branch — and there is no "did the agent push?" question to get
        // wrong (that check used to fail finished work on private remotes whose
        // credentials were not cached).
        let queueWantsPR = (queue?.autoPR ?? false) && env.canOpenPR()
        let wantsPR = queueWantsPR && !queueHasMore
        let prText = board.task(active.taskID).map { env.prText($0, branch ?? base) }
        let git = env.git
        let findExistingPR = env.findExistingPR
        let createPR = env.createPR
        let log = env.log
        let taskID = active.taskID
        if !queueWantsPR, branch != nil {
            log("tasks: " + taskID + " keeps its work local — this queue opens no PR (no push, commit only)")
        }

        phase = .finishing(taskID)
        var outcome: FinishOutcome = .done(prUrl: nil)
        env.perform({
            if wantsPR, let branch = branch {
                if git.remoteName() == nil {
                    log("tasks: " + taskID + " has no remote — skipping the push check")
                } else {
                    switch git.branchPushState(branch) {
                    case .pushed:
                        break
                    case .notPushed:
                        // A real miss: the queue asked for a PR and the branch is
                        // not on the remote, so no PR can be opened.
                        outcome = .failed(.noPush)
                        return
                    case .unknown:
                        // The question could not be asked (no credentials for a
                        // private remote, network hiccup). That is NOT "the agent
                        // forgot to push": report it and carry on to the PR.
                        log("tasks: " + taskID + " could not tell whether " + branch + " is pushed — carrying on")
                    }
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

    /// 新建任务 (decision 6): one box, nothing else — its first line is the title
    /// and the rest is the description (a single line is both, see
    /// TaskDraft.effectiveBody). The task lands in the 未入队 area — the queue is
    /// chosen later, from the card — and creating it never starts anything.
    @discardableResult
    func createManualTask(_ draft: TaskDraft) -> TaskItem? {
        guard draft.isValid else { return nil }
        var task = TaskItem.manual(title: draft.normalizedTitle, body: draft.effectiveBody)
        task.state = .pending
        board.tasks.append(task)
        persist()
        env.log("tasks: created " + task.id + " (" + task.title + ")")
        return task
    }

    /// Edit a manual task's title/description. Refused while it is running (the
    /// session already has the old text) and for github tasks (their issue is
    /// the source of truth).
    @discardableResult
    func updateManualTask(_ taskID: String, title: String, body: String) -> Bool {
        let draft = TaskDraft(title: title, body: body)
        guard draft.isValid, let i = board.index(ofTask: taskID),
              board.tasks[i].source == .manual, board.tasks[i].state != .running else { return false }
        board.tasks[i].title = draft.normalizedTitle
        board.tasks[i].body = draft.effectiveBody
        persist()
        return true
    }

    /// Delete a manual task: it leaves every queue and its machine-local session
    /// record goes with it. Refused while it is running — cancel first.
    @discardableResult
    func deleteManualTask(_ taskID: String) -> Bool {
        guard let task = board.task(taskID), task.source == .manual, task.state != .running else { return false }
        board.detach(taskID: taskID)
        guard let i = board.index(ofTask: taskID) else { return false }
        board.tasks.remove(at: i)
        board.local.sessions[taskID] = nil
        board.local.sessionUpdatedAt[taskID] = nil
        persist()
        env.log("tasks: deleted " + taskID)
        return true
    }

    /// The queues offered by 加入队列 ▾ (user queues only).
    func queueChoices() -> [QueueChoice] {
        board.queueChoices()
    }

    @discardableResult
    func createQueue(name: String,
                     branch: String? = nil,
                     baseBranch: String = "main",
                     autoPR: Bool = false) -> TaskQueue {
        let queue = board.createQueue(name: name, branch: branch, baseBranch: baseBranch, autoPR: autoPR)
        persist()
        return queue
    }

    /// Edit a queue's settings. A double-optional branch distinguishes "leave it
    /// alone" (nil) from "no branch at all" (.some(nil)).
    @discardableResult
    func updateQueue(_ queueID: String,
                     name: String? = nil,
                     branch: String?? = nil,
                     baseBranch: String? = nil,
                     autoPR: Bool? = nil,
                     prUrl: String? = nil) -> Bool {
        guard let qi = board.index(ofQueue: queueID) else { return false }
        if let name = name { board.queues[qi].name = name }
        if let branch = branch { board.queues[qi].branch = branch }
        if let baseBranch = baseBranch { board.queues[qi].baseBranch = baseBranch }
        if let autoPR = autoPR { board.queues[qi].autoPR = autoPR }
        if let prUrl = prUrl { board.queues[qi].prUrl = prUrl }
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

    /// 处理 one issue task: create (or reuse) its single-task queue and start it.
    @discardableResult
    func startIssueTask(_ taskID: String) -> String? {
        guard let task = board.task(taskID), task.source == .github else { return nil }
        return startStandaloneTask(task, queue: { TaskQueue.auto(for: task, baseBranch: env.defaultBaseBranch) })
    }

    /// 处理 one MANUAL task on its own: the same single-task queue shape as an
    /// issue task — one branch, one PR (决策 5, applied to manual work). 全部处理
    /// uses this so a batch never bundles unrelated changes onto one branch.
    @discardableResult
    func startManualTask(_ taskID: String) -> String? {
        guard let task = board.task(taskID), task.source == .manual else { return nil }
        // A queue built before this rule existed (or built in a git workspace and
        // then carried into this one) may still ask for a branch this directory
        // cannot switch to: drop it first, or the retry fails with tasks.errNotGit
        // exactly like the first attempt did.
        if !env.canSwitchBranches, let existing = board.autoQueueID(forTask: taskID),
           board.queue(existing)?.branch != nil {
            updateQueue(existing, branch: .some(nil))
            env.log("tasks: " + taskID + "'s queue no longer switches branches — this workspace is not a git repository")
        }
        return startStandaloneTask(task, queue: {
            TaskQueue.auto(forManual: task,
                           baseBranch: env.defaultBaseBranch,
                           switchesBranch: env.canSwitchBranches,
                           opensPR: env.canOpenPR())
        })
    }

    /// Create-or-reuse the single-task queue of one task and start it. A finished
    /// queue is reused too (a task whose queue still exists runs in place); a
    /// failed/cancelled task goes through retry so it becomes queued again instead
    /// of being skipped as a finished entry.
    @discardableResult
    private func startStandaloneTask(_ task: TaskItem, queue makeQueue: () -> TaskQueue) -> String? {
        if let existing = board.autoQueueID(forTask: task.id) {
            if task.state == .failed || task.state == .cancelled {
                _ = board.retryAndResume(task.id)
            } else {
                _ = board.resumeQueue(existing)
            }
            persist()
            _ = pump()
            return existing
        }
        let queue = makeQueue()
        board.queues.append(queue)
        _ = board.enqueue(taskID: task.id, into: queue.id)
        _ = board.resumeQueue(queue.id)   // 处理 = 开始：不等用户再点一次
        persist()
        _ = pump()
        return queue.id
    }

    /// Point the runner at a specific queue: the one it works on NEXT.
    ///
    /// 全部处理 creates one queue per task, and every creation resumes its own
    /// queue — so the last one created would otherwise win the runner's attention.
    /// The panel focuses the FIRST queue after batching, which makes a batch run in
    /// board order.
    func focus(onQueue queueID: String) {
        guard board.queue(queueID) != nil else { return }
        board.local.activeQueueID = queueID
        persist()
    }

    /// The queue of the task being worked on right now (nil when nothing runs):
    /// what the panel marks 活跃 — the board alone cannot say it, because a batch
    /// leaves several queues active at once.
    var runningQueueID: String? {
        guard let id = runningTaskID else { return nil }
        return board.task(id)?.queueId
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
    /// traceability, pause its queue. See CancelOutcome for the two windows where
    /// there is no session to cancel YET (starting) or any more (finishing).
    @discardableResult
    func cancelRunning() -> CancelOutcome {
        switch phase {
        case .active(let active):
            _ = env.cancelSession(active.sessionId)
            phase = .idle
            board.markCancelled(active.taskID)
            if let task = board.task(active.taskID), task.source == .github { env.persistIssueTask(task) }
            persist()
            env.log("tasks: " + active.taskID + " cancelled")
            _ = pump()
            return .cancelled
        case .starting(let taskID):
            cancelRequested = true
            env.log("tasks: cancel requested while " + taskID + " was starting — it will be cancelled as soon as its session exists")
            return .deferred
        case .finishing:
            return .finishing
        case .idle:
            return .idle
        }
    }
}
