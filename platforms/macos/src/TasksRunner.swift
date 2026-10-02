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


/// The git half of the runner. Every command goes through the injected closure,
/// so a test can script a repository without touching the disk.
///
/// v1 ran checkout and pull with their exit codes IGNORED, which let a task
/// start from the previous task's branch or from a stale commit — the exact
/// problem docs/design/panels/issue-runner-design.md §V2-5 fixes. Here every step is checked
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

    /// Whether the worktree has TRACKED local changes (staged or unstaged).
    ///
    /// Untracked files are deliberately NOT counted. `git checkout` only refuses when
    /// an untracked file would be overwritten by the target branch, and it says so
    /// itself; treating every scratch file as a blocker froze queues that git would
    /// have switched happily (user 2026-10-02: `.tmp/` + local research docs blocked
    /// a branch switch). Fails CLOSED: a status command that cannot run counts as
    /// having changes.
    func hasTrackedChanges() -> Bool {
        guard let out = run(["status", "--porcelain", "--untracked-files=no"]) else { return true }
        return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func branchExists(_ name: String) -> Bool {
        run(["rev-parse", "--verify", "--quiet", name]) != nil
    }

    /// Whether `base` can be resolved for a checkout: the local branch, or — when
    /// there is a remote — its remote-tracking branch (a fresh clone may only have
    /// `origin/main`; `git checkout main` would create it, but a bare
    /// `rev-parse --verify main` would not). Used by the multi-repo pre-flight
    /// (design §5.2), which must not reject a base that `enter` could actually use.
    func baseIsResolvable(_ base: String) -> Bool {
        guard !base.isEmpty else { return false }
        if branchExists(base) { return true }
        guard let remote = remoteName(), !remote.isEmpty else { return false }
        return run(["rev-parse", "--verify", "--quiet", remote + "/" + base]) != nil
    }

    /// Whether this repository has any commit at all. False for a directory that was
    /// just `git init`ed — HEAD is unborn there (`git rev-parse --verify HEAD` fails).
    func hasCommits() -> Bool {
        run(["rev-parse", "--verify", "--quiet", "HEAD"]) != nil
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
        // anything at all. Nothing can be lost in a repository that has no commit:
        // the branch is created from the unborn HEAD, and the task's work simply
        // becomes the first commit. (Untracked files no longer count as dirty — see
        // hasTrackedChanges — but the missing base still needs this exception.)
        let empty = !hasCommits()
        if !empty {
            guard !hasTrackedChanges() else { return .dirtyWorktree }
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
    /// The workspace's default integration mode (the tasks-panel setting), used for a
    /// queue that has no per-queue override.
    var defaultIntegration: QueueIntegration = .pr
    /// per-repo default
    var defaultIntegrationFor: ((WorkspaceRepo) -> QueueIntegration)?
    /// 交付成功后自动关闭队列 (a PER-WORKSPACE panel setting): when true, a queue in
    /// THIS workspace whose delivery session succeeds is moved to .closed. Off by
    /// default so nothing closes a queue behind the user's back.
    var autoCloseOnPublish: Bool = false
    /// Whether this workspace is a git repository at all. A queue created where it
    /// is false gets NO branch (the pipeline then never touches git — §V2-7), which
    /// is exactly what 全部处理 has to honour when it builds one queue per task.
    var canSwitchBranches: Bool = true
    /// Whether this workspace can open a pull request at all (a GitHub remote). It
    /// decides whether a finished queue gets a 开 PR 会话 at all (see startQueuePR).
    var canOpenPR: () -> Bool = { true }
    var cancelSession: (_ sessionId: String) -> Bool
    /// Existing open PR for the head branch, or nil — the FALLBACK used when a PR
    /// session ends without naming the PR it opened (a session that opened the PR
    /// through an API it did not quote back). There is deliberately no "createPR"
    /// here any more: the PR is written by the session, from the real diff (its
    /// title and body are a summary, not a template).
    var findExistingPR: (_ branch: String) -> String?
    /// 按仓库查询已有 PR（design §7.4）：多仓库交付时对每个目标仓库兜底。nil = 回落
    /// 单仓库的 findExistingPR（legacy env）。
    var findExistingPRFor: ((WorkspaceRepo, String) -> String?)?
    /// The text handed to the agent. `brief` is the 交接简报 for a task that has
    /// work in front of it in its queue (nil when there is nothing to hand over).
    var promptText: (_ task: TaskItem, _ queue: TaskQueue?, _ brief: String?) -> String
    /// The agent's LAST text message of a session — its final report — or nil.
    /// BLOCKING (it reads a session log through the shell's core bridge), so the
    /// runner only calls it inside its background step.
    var sessionReport: (_ sessionId: String) -> String? = { _ in nil }
    /// P1 完成校验：任务会话是否必须在最后一行回显 runner 注入的完成 marker。真实面板
    /// 开启；legacy / 无 sessionReport 的 headless env 默认关闭（不设门槛，维持旧行为）。
    var requireCompletionMarker: Bool = false
    /// Deliver the queue-completion report to the session that CREATED the queue.
    /// The runner calls it inside env.perform (never on the main thread). Defaults to
    /// "nothing delivered" so every existing test that does not care still compiles.
    var notifySession: (_ sessionId: String, _ text: String) -> Bool = { _, _ in false }
    /// Persist the machine-scoped half of the board (manual.json / queues.json /
    /// local.json).
    var persist: (TaskBoard) -> Void
    /// Persist one github task into the committed index.
    var persistIssueTask: (TaskItem) -> Void
    var log: (String) -> Void
    /// Run blocking work (git, HTTP, RPC) off the main thread, then hop back.
    /// Tests pass an immediate, synchronous implementation.
    var perform: (_ blocking: @escaping () -> Void, _ completion: @escaping () -> Void) -> Void
    /// The workspace's repositories (multi-repo, design §5.1). Empty on every
    /// legacy path — a single-repo env carries exactly one root repo, a plain one
    /// none — and nothing reads it unless a target actually comes from it.
    var repos: [WorkspaceRepo] = []
    /// Per-repo git handle (design §5.1). nil = fall back to `git` (the root /
    /// primary handle), so a legacy single-repo env needs nothing new.
    var gitFor: ((WorkspaceRepo) -> TaskGit)?
    /// The primary repository's id when `repos` is present (design §5.1 / Q2): the
    /// default target for a queue that names none. nil = fall back to the root /
    /// first-GitHub / first-git rule inside `resolveTargets`.
    var primaryRepoID: String?
    /// Runtime re-probe (design §5.1): the workspace's repositories AS THEY ARE when a
    /// task starts, plus the resolved primary. A queue task may add or remove a
    /// repository, so the set is asked for again on the runner's background queue
    /// inside `pump` (the same philosophy as the prompt's live shape probe).
    /// nil = use the `repos` / `primaryRepoID` snapshot (a legacy / headless env).
    var repoSetProvider: (() -> WorkspaceRepoSet)?

    /// The git handle for a target repo: its own when the env carries one, else
    /// the single legacy handle. This is what the per-repo pipeline will use (P2);
    /// the legacy `git` field keeps every current call site working unchanged.
    func gitHandle(for repo: WorkspaceRepo) -> TaskGit { gitFor?(repo) ?? git }

    /// 该仓库的交付默认值（design §7.2）：面板按仓库注入，legacy env 回落单一值。
    func integrationDefault(for repo: WorkspaceRepo) -> QueueIntegration {
        defaultIntegrationFor?(repo) ?? defaultIntegration
    }

    /// 该仓库已有 PR 的兜底查询（design §7.4）。
    func existingPR(for repo: WorkspaceRepo, branch: String) -> String? {
        findExistingPRFor?(repo, branch) ?? findExistingPR(branch)
    }

    /// A perform that runs both closures right here — the headless default.
    static func synchronous(_ blocking: () -> Void, _ completion: () -> Void) {
        blocking()
        completion()
    }
}

// MARK: - Multi-repo targets (design §5)

extension TasksRunner {
    /// The repositories THIS queue works on: its own list when it names one, else
    /// the primary (design §5.2 / Q2). Unknown ids (a repository that was removed)
    /// are dropped; if none of them resolves, fall back to the primary. An empty
    /// `repos` is a legacy env: return [] and the caller keeps the single `git`.
    static func resolveTargets(queue: TaskQueue?, repos: [WorkspaceRepo],
                               primaryRepoID: String? = nil) -> [WorkspaceRepo] {
        guard !repos.isEmpty else { return [] }
        if let ids = queue?.repos, !ids.isEmpty {
            let chosen = ids.compactMap { id in repos.first { $0.id == id } }
            if !chosen.isEmpty { return chosen }
        }
        let primary = primaryRepoID.flatMap { id in repos.first { $0.id == id } }
            ?? repos.first { $0.id == "." }
            ?? repos.first { $0.github != nil }
            ?? repos.first { $0.isGit }
        return primary.map { [$0] } ?? []
    }

    /// The two-phase branch entry (design §5.2).
    ///
    /// Phase 1 pre-flights EVERY target (`isGit` / clean worktree / resolvable base):
    /// one failure aborts before anything is touched. Phase 2 enters them one by one;
    /// a mid-way failure does NOT roll back (checking out a branch is non-destructive)
    /// and its detail names the repositories that already switched.
    ///
    /// An UNBORN repository (fresh `git init`, no commit) is skipped by the base and
    /// clean checks, exactly like `TaskGit.enter`: there is no committed state to
    /// lose and no base to resolve.
    static func enterTargets(_ targets: [WorkspaceRepo], branch: String?, base: String?,
                             gitFor: (WorkspaceRepo) -> TaskGit) -> (failure: TaskFailure?, detail: String?) {
        let single = targets.count == 1
        let queueBase = base?.trimmingCharacters(in: .whitespacesAndNewlines)
        func repoBase(_ repo: WorkspaceRepo) -> String {
            // The legacy single ROOT repo keeps the queue's own 基于分支 (today's
            // behavior); a child repo — or any target of a multi-repo queue — uses
            // its own defaultBase (design §4.3 / §5.2).
            if single, repo.id == ".", let queueBase = queueBase, !queueBase.isEmpty { return queueBase }
            return repo.defaultBase
        }
        // One target is the LEGACY path: it must keep today's error keys (no 「多仓库」
        // wording for a workspace that has exactly one repository), so a single target
        // maps the pre-flight failures back onto the old reasons and carries no detail.
        // Several targets get the explicit multi-repo reasons + the failing repo id.
        // Phase 1: pre-flight. A failure here leaves every repository where it was.
        //
        // "只保护 checkout"（2026-10-02）：干净 / 基线检查只在**真的要切**时才做。
        // enter() 不碰 git 的三种情况一律跳过——队列没有分支（.noBranch）、已经在
        // 目标分支上（.alreadyOnBranch）、空仓库没有提交可丢（直接 checkout -b）——
        // 否则「已在分支 + 有改动」会被预检拦下，而 enter() 根本不会 checkout。
        for repo in targets {
            guard repo.isGit else { return (.notGitRepo, single ? nil : repo.id) }
            let git = gitFor(repo)
            guard let wanted = branch, !wanted.isEmpty, git.hasCommits(),
                  git.currentBranch() != wanted else { continue }
            guard !git.hasTrackedChanges() else {
                return (single ? .dirtyWorktree : .repoDirty, single ? nil : repo.id)
            }
            guard git.baseIsResolvable(repoBase(repo)) else {
                return (single ? .checkout : .repoNoBase,
                        single ? nil : repo.id + "（" + repoBase(repo) + "）")
            }
        }
        // Phase 2: enter. No rollback — the detail says what already switched.
        var switched: [String] = []
        for repo in targets {
            let entered = gitFor(repo).enter(branch: branch, base: repoBase(repo))
            if let failure = failure(for: entered) {
                // First failure: the specific reason (checkout / branch / pull). A
                // failure AFTER another repo switched: the explicitly non-rolling-back
                // reason, whose detail names what already moved.
                guard switched.isEmpty else {
                    return (.repoBranch, repo.id + "（已切换：" + switched.joined(separator: "、") + "）")
                }
                return (failure, single ? nil : repo.id)
            }
            if entered == .switched || entered == .alreadyOnBranch { switched.append(repo.id) }
        }
        return (nil, nil)
    }

    /// 本队列每个目标仓库的交付计划（design §7.2）：intent = 队列覆盖 ?? 该仓库的
    /// 按仓库默认值；effective = 按该仓库能力降级（PR → push → 本地合并 → 不做），
    /// 各仓库互不影响。
    static func deliveryPlan(queue: TaskQueue?,
                             targets: [WorkspaceRepo],
                             queueOverride: QueueIntegration?,
                             perRepoDefault: (WorkspaceRepo) -> QueueIntegration,
                             hasRemote: (WorkspaceRepo) -> Bool) -> [QueueRepoRun] {
        let single = targets.count == 1
        let queueBase = queue?.baseBranch
        let branch = queue?.branch ?? ""
        return targets.map { repo in
            let intent = QueueIntegration.intent(queueOverride: queueOverride,
                                                 perRepoDefault: perRepoDefault(repo))
            let effective = QueueIntegration.effective(intent, repo: repo, hasRemote: hasRemote(repo))
            // 单目标的工作区根沿用队列自己的「基于分支」，其余用仓库自己的默认分支。
            let base: String
            if single, repo.id == ".", let queueBase = queueBase, !queueBase.isEmpty {
                base = queueBase
            } else {
                base = repo.defaultBase
            }
            return QueueRepoRun(repoID: repo.id,
                                branch: branch.isEmpty ? base : branch,
                                base: base,
                                intent: intent,
                                effective: effective,
                                status: .pending)
        }
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

/// One repository a prompt describes. `repoID` "." is the workspace root; anything
/// else is a workspace-relative child path (design §6).
struct TaskPromptTarget: Equatable {
    var repoID: String
    var shape: TaskRepoShape
    /// The repo's own default branch (the multi-repo branch line names it).
    var defaultBase: String = "main"
}

/// The commits ONE repository carries on top of its base — the per-repo group of a
/// 交接简报 (design §5.3). One group keeps today's flat rendering; several groups
/// are rendered under a per-repo heading.
struct RepoCommits: Equatable {
    var repoID: String
    var commits: [String]
}

/// Texts handed to the agent. Both task sources share ONE requirement list
/// (requirements below, 2026-09-27): the prompt's head is all that differs.
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
        /// 每个目标仓库在分支上已有的提交（单仓库时只有一个分组，渲染与今天一致）。
        var commits: [RepoCommits]
        /// 多目标队列按仓库分组渲染提交（design §5.3）——即使只有一个仓库有提交，
        /// 也要保留仓库抬头，否则接着干的人看不出这条提交属于哪个仓库。单目标
        /// （或 legacy env）保持今天的分行文本。
        var groupedByRepo: Bool = false
    }

    /// The brief as prompt text, or nil when there is nothing to hand over.
    static func briefSection(_ brief: QueueBrief?) -> String? {
        guard let brief = brief else { return nil }
        guard !brief.earlier.isEmpty || !brief.commits.isEmpty else { return nil }
        var lines: [String] = []
        // 与开 PR 会话的 `## 队列信息` 是同一套字段、同一个抬头（用户的要求：两处统一）：
        // 队列 → 分支/基线 → 分支上已有的提交 → 前面任务的汇报。谁在哪个队列里、在哪条
        // 分支上、前面干了什么，读到同一个段落就知道。
        lines.append("## 队列信息")
        lines.append("队列：\(brief.queueName)（本任务是第 \(brief.position)/\(brief.total) 个）")
        if let branch = brief.branch, !branch.isEmpty {
            lines.append("分支：\(branch)（基于 \(brief.base)）")
        } else {
            lines.append("基于：\(brief.base)")
        }
        if !brief.commits.isEmpty {
            lines.append("分支上已有的提交：")
            if !brief.groupedByRepo {
                // 单目标（根或子仓库）：与今天逐字一致 —— 只有一组，不打仓库抬头。
                for commit in brief.commits[0].commits { lines.append("  " + commit) }
            } else {
                // 多仓库：按仓库分组（design §5.3）。
                for group in brief.commits {
                    let name = group.repoID == "." ? "（工作区根）" : group.repoID + "/"
                    lines.append("  " + name + "：")
                    for commit in group.commits { lines.append("    " + commit) }
                }
            }
        }
        if !brief.earlier.isEmpty {
            lines.append("前面任务的汇报：")
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
        // 收尾这句只对「真有前一棒」成立：队列的第一个任务也可能拿到这一段（分支上已经
        // 有提交），那时说「不要重做前面任务」就是无的放矢。
        if brief.earlier.isEmpty {
            lines.append("这些提交是这条分支上已有的改动（上一轮留下的）：不要重做它们，只做本任务。")
        } else {
            lines.append("不要重做已完成的部分，只做本任务；")
            lines.append("如果发现前面留下的问题，先说明再决定是否顺手修。")
        }
        return lines.joined(separator: "\n")
    }

    /// 自查与汇报两条 rail，issue 任务与手动任务共用同一份措辞（用户的要求：
    /// 测试那条要照顾「文档类没有测试可跑」，汇报那条是**必须**，且会被写回卡片）。
    static let verifyRequirement =
        "改完自查：代码类改动跑相关测试并确保通过；文档 / 配置类做能做的校验（命令能跑通、路径与链接存在、示例可执行），确实没有可跑的就说明「本次没有可跑的测试」；"

    static let reportRequirement =
        "**必须**在结束时汇报：改了什么、怎么验证的、结果如何（没做完或失败也要说清楚，不要沉默结束）——这段文字会写回任务卡片，队列里后面的任务也会看到它；"

    /// 任务会话的完成标记要求（P1 完成协议）：会话必须在最后单独一行原样回显 runner
    /// 生成、随提示词注入的每任务唯一 marker。壳层据此判断「这次 turn 真的做完」——
    /// dsh 不提供结束原因，断网导致的 turn 结束与正常完成在会话列表里长得一样，只有
    /// 这个 marker 能把两者分开。与交付会话的 DSH-FINALIZE- 同一约定、两套独立。
    static func completionMarkerInstruction(_ marker: String) -> String {
        "最后**单独一行**原样输出完成标记（供壳层确认本任务已完成）：" + marker
    }

    /// The issue task's prompt: the issue itself, then **the same requirements a
    /// manual task gets**.
    ///
    /// 2026-09-27 起 issue 与手动任务对齐。过去 issue 走的是一段写死的 5 条，第 1 条
    /// 要求「加载 issue-resolve skill 并严格按其流程执行」—— 而那个技能停在旧世界：
    /// 它让任务自己 `git push`、并说「PR 由面板创建」。同一个面板里于是有两种政策：
    /// issue 任务 push、手动任务只 commit（后者才是壳层现在的政策 —— push 与 PR 由
    /// 队列的「开 PR 会话」负责）。现在两者共用 requirements(...)：按工作区形状出条目、
    /// 按队列说分支、都要自查与汇报、都带队列交接简报，只在 **头的部分**不同
    /// （issue 头 = 编号/标题/标签/正文；手动任务头 = 标题/描述）。
    static func issue(number: Int, title: String, body: String?, labels: [String],
                      branch: String?, queueName: String?, base: String? = nil,
                      brief: String? = nil, shape: TaskRepoShape = .github,
                      targets: [TaskPromptTarget]? = nil) -> String {
        var lines: [String] = []
        lines.append("请完成以下 GitHub issue 的修复：")
        lines.append("")
        lines.append("## Issue #\(number)")
        lines.append("标题：\(title)")
        if !labels.isEmpty {
            lines.append("标签：" + labels.joined(separator: ", "))
        }
        // The issue BODY is this task's description — the same place a manual task's
        // description sits, and the same待遇: handed over directly. It used to be
        // omitted, so an issue task had to go and fetch its own issue from GitHub
        // while a manual task just read its description.
        let issueBody = body?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let issueBody = issueBody, !issueBody.isEmpty,
           issueBody != title.trimmingCharacters(in: .whitespacesAndNewlines) {
            lines.append("")
            lines.append(issueBody)
        }
        lines.append("")
        lines.append("要求：")
        // The requirements follow the TARGETS (design §4.3/§6): one target keeps
        // today's text (a legacy caller passes only `shape`, i.e. the root); two
        // or more get the multi-repo inventory.
        let targetList = targets ?? [TaskPromptTarget(repoID: ".", shape: shape)]
        let list = requirements(branch: branch, queueName: queueName, base: base, targets: targetList)
        for (index, requirement) in list.enumerated() {
            lines.append("\(index + 1). " + requirement)
        }
        // 队列里前面那些任务留下了什么 —— 与手动任务同一段落、同一个落点（所有要求之后）。
        if let brief = brief, !brief.isEmpty {
            lines.append("")
            lines.append(brief)
        }
        return lines.joined(separator: "\n")
    }

    /// The 要求 list BOTH task sources share (issue / manual) — one place, so the two
    /// prompts cannot drift apart again.
    ///
    /// 条目按「这个工作区现在是什么 + 这个队列会做什么」生成，编号由顺序算出：
    /// 不适用的条目**不出现**（非 git 目录没有分支要求、非 GitHub 工作区没有 token
    /// 要求）。push / PR 一律不在这里：那是壳层那一半，由队列结束后的「开 PR 会话」做 ——
    /// 说了就是让代理操心不属于它的事。
    static func requirements(branch: String?, queueName: String?, base: String?,
                             shape: TaskRepoShape,
                             targetRepoID: String? = nil) -> [String] {
        var requirements: [String] = []
        // A single target that is NOT the workspace root gets ONE extra line at the
        // head (design §4.3): every git command has to run inside that child. The
        // root target gets nothing, so the legacy single-repo prompt is byte-for-byte
        // what it always was.
        if let repoID = targetRepoID, repoID != ".", !repoID.isEmpty {
            requirements.append(Self.childWorkdirRequirement(repoID: repoID))
        }
        if let queueName = queueName {
            requirements.append("本任务是队列「\(queueName)」中的一项，与其他任务共享同一分支与改动；")
        } else {
            // 措辞避开「与其他任务共享」这几个字：独立任务不是在否定一件事，而是在
            // 说明它的形状（队列里的任务才会共享分支与改动）。
            requirements.append("本任务独立执行，不共享分支与改动；")
        }
        // 分支：只有存在仓库时才有这句话；切不切、切哪条，按队列说。
        //
        // 有分支时点名分支，并给出它还没建立时的来路（基于 base 新建）；不切分支的队列
        // 说清它就在主分支上做 —— 用户的原话是「本任务须在分支 X 上处理（若无分支，须基于
        // xxx 分支新建）」与「本队列不切分支：直接在主分支 xxx 上处理（不要新建分支）」。
        if shape != .plain {
            let baseName = base?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let branch = branch, !branch.isEmpty {
                if let baseName = baseName, !baseName.isEmpty, baseName != branch {
                    requirements.append("本任务须在分支 \(branch) 上处理（若该分支不存在，须基于 \(baseName) 分支新建）；")
                } else {
                    requirements.append("本任务须在分支 \(branch) 上处理（若该分支不存在，须新建它）；")
                }
            } else if let baseName = baseName, !baseName.isEmpty {
                requirements.append("本队列不切分支：直接在主分支 \(baseName) 上处理（不要新建分支）；")
            } else {
                requirements.append("本队列不切分支：就在当前已检出的分支上处理（不要新建分支）；")
            }
        }
        requirements.append(Self.verifyRequirement)
        // commit：**有仓库就必须 commit**（含任务自己刚 git init 出来的仓库）。
        if shape == .plain {
            requirements.append("这里还不是 git 仓库：不要求 commit；任务本身要你建仓库（git init）时，建好后把改动 commit 掉（建议 feat/fix: 简述）；")
        } else {
            requirements.append("完成前 commit（建议 feat/fix: 简述）；")
        }
        // token：只有 GitHub 工作区需要（不是 GitHub 仓库就整条不出现）。
        if shape == .github {
            requirements.append("需要 GitHub 写操作时，token 在 $DSH_HOME/oh-my-dsh/tokens/<owner>-<repo> 或 $DSH_HOME/oh-my-dsh/gh-token（默认目录 ~/.dsh；cat 读取即可，绝不在对话/汇报中回显）；")
        }
        // 汇报：每个任务都必须，而且这份汇报会被写回任务卡片。
        requirements.append(Self.reportRequirement)
        return requirements
    }

    /// The one line a single CHILD-repo target adds (design §4.3): the workspace
    /// root is only a container, so every git command has to run inside the child.
    static func childWorkdirRequirement(repoID: String) -> String {
        let q = "\u{60}"
        return "本工作区的 git 仓库位于子目录 " + q + repoID + "/" + q
            + "；所有 git 命令请加 " + q + "-C " + repoID + "/" + q
            + "（或先 " + q + "cd" + q + " 进去），不要在工作区根执行 git。"
    }

    /// Dispatch on the NUMBER of target repositories (design §4.3 / §6).
    ///
    /// ONE target — the root or a child — is today's single-repo text, byte for
    /// byte (a child only prepends the work-directory line). TWO or more switch to
    /// the multi-repo inventory text. The wording follows the TARGETS, never the
    /// workspace mode: a multi-repo workspace whose queue targets only the primary
    /// still gets the single-repo text.
    static func requirements(branch: String?, queueName: String?, base: String?,
                             targets: [TaskPromptTarget]) -> [String] {
        if targets.count <= 1 {
            let target = targets.first
            return requirements(branch: branch, queueName: queueName, base: base,
                                shape: target?.shape ?? .plain,
                                targetRepoID: target?.repoID)
        }
        return multiRepoRequirements(branch: branch, queueName: queueName, targets: targets)
    }

    /// The multi-repo 要求 list (design §6): every repository is named, each is
    /// committed in separately, and a single git status must not stand in for all
    /// of them.
    static func multiRepoRequirements(branch: String?, queueName: String?,
                                      targets: [TaskPromptTarget]) -> [String] {
        let q = "\u{60}"
        var requirements: [String] = []
        if let queueName = queueName {
            requirements.append("本任务是队列「\(queueName)」中的一项，与其他任务共享同一分支与改动；")
        } else {
            requirements.append("本任务独立执行，不共享分支与改动；")
        }
        // 涉及仓库清单：逐个点名，相对工作区根。
        let inventory = targets.map { q + $0.repoID + "/" + q }.joined(separator: "、")
        requirements.append("本队列涉及仓库：\(inventory)（相对工作区根）；")
        // 分支：同一分支名贯穿所有仓库，但每个仓库基于自己的默认分支。
        let bases = targets.map { q + $0.repoID + q + " 基于 " + q + $0.defaultBase + q }.joined(separator: "，")
        if let branch = branch, !branch.isEmpty {
            requirements.append("**每个**仓库都须在其分支 " + q + branch + q + " 上处理（各自基于自己的默认分支：\(bases)）；")
        } else {
            requirements.append("本队列不切分支：各仓库直接在自己的默认分支上处理（\(bases)），不要新建分支；")
        }
        requirements.append(Self.verifyRequirement)
        requirements.append("在有改动的仓库里**分别** " + q + "git -C <repo> add/commit" + q + "（建议 feat/fix: 简述）；没有改动的仓库不用提交；")
        // token：只要任一目标仓库是 GitHub 就出现（token 文件按 owner-repo 组织）。
        if targets.contains(where: { $0.shape == .github }) {
            requirements.append("需要 GitHub 写操作时，token 在 $DSH_HOME/oh-my-dsh/tokens/<owner>-<repo> 或 $DSH_HOME/oh-my-dsh/gh-token（默认目录 ~/.dsh；cat 读取即可，绝不在对话/汇报中回显）；")
        }
        requirements.append("不要用一把 " + q + "git status" + q + " 概括全部，逐仓库 " + q + "git -C <repo> status" + q + " 确认；")
        requirements.append(Self.reportRequirement)
        return requirements
    }

    /// Manual task: the user's own title and description plus the same rails.
    ///
    /// `shape` follows the WORKSPACE (see TaskRepoShape): it decides which rails
    /// exist at all (no branch rail without a repository, no token rail without a
    /// GitHub remote). The push / PR policy is deliberately NOT here: that half is
    /// the shell's, performed by a dedicated 开 PR 会话 once the queue is done.
    /// `base` is the branch the queue treats as its base (queue.baseBranch, or the
    /// workspace default for a task without a queue): it is what the branch rail names
    /// when there is no branch yet, and what 「主分支」 means for a queue that does not
    /// switch branches at all.
    static func manual(title: String, body: String?, branch: String?, queueName: String?,
                       base: String? = nil,
                       brief: String? = nil,
                       shape: TaskRepoShape = .github,
                       targets: [TaskPromptTarget]? = nil) -> String {
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
        // 要求与 issue 任务**完全共用**（TaskPrompts.requirements）：两种来源的提示词
        // 只有头不同，规则必须一模一样 —— 各写一份的那段历史，正是 issue 任务被留在
        // 「会 push、PR 由面板开」的旧政策里的原因。
        lines.append("")
        lines.append("要求：")
        // The requirements follow the TARGETS (design §4.3/§6): one target keeps
        // today's text (a legacy caller passes only `shape`, i.e. the root); two
        // or more get the multi-repo inventory.
        let targetList = targets ?? [TaskPromptTarget(repoID: ".", shape: shape)]
        let list = requirements(branch: branch, queueName: queueName, base: base, targets: targetList)
        for (index, requirement) in list.enumerated() {
            lines.append("\(index + 1). " + requirement)
        }
        // 队列里前面那些任务留下了什么（各自会话里的最后一段汇报 + 分支上已有的提交）
        // —— 按用户的要求整段放在**所有要求之后**。
        if let brief = brief, !brief.isEmpty {
            lines.append("")
            lines.append(brief)
        }
        return lines.joined(separator: "\n")
    }

    /// The prompt of the dedicated 开 PR 会话（§V2-6）—— the ONLY place that pushes and
    /// opens a pull request. Task sessions only commit; this one reads what the branch
    /// actually did, writes the title and body itself, pushes, opens (or reuses) the PR
    /// and says the URL out loud, because the runner reads it back off the report and
    /// puts it on the queue's card.
    static func pullRequest(queueName: String?, branch: String, base: String, commits: [String]) -> String {
        var lines: [String] = []
        // 一句话说清「谁的、哪条分支、要做什么」—— 这条会话的来意就是它。
        if let queueName = queueName, !queueName.isEmpty {
            lines.append("队列「\(queueName)」的任务已完成，推送分支 \(branch)，并发起 pull request：")
        } else {
            lines.append("分支 \(branch) 的任务已完成，请推送它并发起 pull request：")
        }
        lines.append("")
        // 与手里任务的 `## 队列信息` 同一套字段（队列 → 分支/基线 → 提交）：这条会话
        // 要交付的就是那个队列的那条分支，抬头与字段一致，两边读起来是一回事。
        lines.append("## 队列信息")
        if let queueName = queueName, !queueName.isEmpty { lines.append("队列：\(queueName)") }
        lines.append("分支：\(branch)（基于 \(base)）")
        if !commits.isEmpty {
            lines.append("分支上已有的提交：")
            for commit in commits { lines.append("  " + commit) }
        }
        lines.append("")
        lines.append("要求：")
        lines.append("1. 先看清这个分支到底改了什么（git log \(base)..\(branch)、git diff \(base)...\(branch)，以及涉及的代码与文档），不要凭队列名字猜；")
        lines.append("2. 把分支 push 到远端（远端名优先 github，其次 origin；分支还没推送过就 -u 推送）；")
        lines.append("3. 用 GitHub token 开 PR：token 在 $DSH_HOME/oh-my-dsh/tokens/<owner>-<repo> 或 $DSH_HOME/oh-my-dsh/gh-token（默认目录 ~/.dsh；cat 读取即可，绝不在对话/汇报中回显）；base = \(base)，head = \(branch)；GitHub 上已经有同一个 head 的 PR 就复用它，不要重复创建；")
        lines.append("4. PR 标题与正文由你**按实际改动**写：标题一句话说清这次合并做了什么，正文分条列出改动要点、怎么验证的、需要注意的地方；不要只写队列名，也不要套模板；")
        lines.append("5. 这个会话不要改任何代码：只做交付；")
        lines.append("6. **必须**在最后一行给出 PR 的完整链接（https://github.com/<owner>/<repo>/pull/<编号>）；真开不出来就说清楚卡在哪一步（权限 / 网络 / token / 分支状态），不要沉默结束。")
        return lines.joined(separator: "\n")
    }

    /// 交付会话的提示词：队列干完的活**怎么交付**。三种模式由队列 / 全局默认选择，
    /// 会话负责执行（凭据与判断都在它这边），壳层只记录它汇报的结果。
    static func integration(mode: QueueIntegration, queueName: String?, branch: String?, base: String,
                            commits: [String], hasRemote: Bool = true,
                            marker: String? = nil) -> String {
        let text: String
        switch mode {
        case .pr:
            text = pullRequest(queueName: queueName, branch: branch ?? base, base: base, commits: commits)
        case .merge:
            text = mergeAndPush(queueName: queueName, branch: branch ?? base, base: base,
                                commits: commits, hasRemote: hasRemote)
        case .push:
            text = pushOnly(queueName: queueName, branch: branch, base: base)
        case .none:
            // Unreachable: startQueueIntegration refuses .none before a session exists.
            text = "队列「\(queueName ?? branch ?? "")」的工作流是「无」——不需要任何交付动作。"
        }
        // A reused ORIGINATING session is a real conversation: require this marker so
        // the shell adopts only OUR turn's report.
        guard let marker = marker else { return text }
        return text + "\n\n最后**单独一行**原样输出完成标记（供壳层确认本次交付结束）：" + marker
    }

    /// 多仓库交付会话的提示词（design §7.3）：对每个目标仓库给出它的 effective 动作，
    /// 要求逐仓库执行并在最后**逐行**输出可解析结果。单目标（工作区根）保持今天
    /// 逐字节相同的单仓库交付文本。
    static func integration(queueName: String?, branch: String?, base: String,
                            runs: [QueueRepoRun], commits: [String] = [],
                            marker: String? = nil,
                            forceGrouped: Bool = false) -> String {
        // forceGrouped：单独重试一个仓库时即使只有一个目标，也用逐行格式要求会话
        // 输出 `<repoID>: <action> <结果>`，结果才能被逐仓库解析（design §7.4）。
        if !forceGrouped, runs.count <= 1 {
            let run = runs.first
            let text: String
            if let run = run, run.repoID != "." {
                text = "本工作区要交付的仓库位于子目录 " + run.repoID + "/；请在其中执行下面的交付动作。\n\n"
                    + integration(mode: run.effective, queueName: queueName, branch: branch,
                                  base: run.base, commits: commits)
            } else {
                text = integration(mode: run?.effective ?? .none, queueName: queueName, branch: branch,
                                   base: base, commits: commits)
            }
            guard let marker = marker else { return text }
            return text + "\n\n最后**单独一行**原样输出完成标记（供壳层确认本次交付结束）：" + marker
        }
        let q = "\u{60}"
        var lines: [String] = []
        lines.append("队列「\(queueName ?? branch ?? "队列")」的任务已完成。本队列涉及多个仓库，请**逐仓库**按它自己的实际动作交付：")
        lines.append("")
        lines.append("## 队列信息")
        if let queueName = queueName, !queueName.isEmpty { lines.append("队列：\(queueName)") }
        if let branch = branch, !branch.isEmpty { lines.append("分支：\(branch)") }
        lines.append("")
        lines.append("## 各仓库及实际动作")
        for run in runs {
            lines.append("- " + repoLabel(run.repoID) + "（分支 " + q + run.branch + q + "，基于 "
                         + q + run.base + q + "）：" + actionDescription(run))
        }
        lines.append("")
        lines.append("要求：")
        lines.append("1. 每个仓库都在它自己的目录里执行（" + q + "git -C <repo> …" + q + " 或先 "
                     + q + "cd <repo>" + q + "）；不要用一把 git 命令概括全部；")
        lines.append("2. **按上面给出的实际动作分别执行**：写「开 PR」的推送分支并开 / 复用 PR；写「直接推送」的推送当前分支；写「本地合并」的把分支合进基线（有远端才推送基线）；写「不交付」的什么都不做；")
        lines.append("3. 某个仓库失败**不要丢弃**已经成功的仓库，也不要把别的仓库的失败算到它头上；")
        lines.append("4. 需要 GitHub 写操作时，token 在 $DSH_HOME/oh-my-dsh/tokens/<owner>-<repo> 或 $DSH_HOME/oh-my-dsh/gh-token（默认目录 ~/.dsh；cat 读取即可，绝不在对话/汇报中回显）；")
        lines.append("")
        lines.append("最后**逐行**输出每个仓库的结果，格式固定（一行一个仓库，行首必须是 "
                     + q + "<repoID>: <action> <结果>" + q + "，action 取 " + q + "pr" + q
                     + " / " + q + "push" + q + " / " + q + "merge" + q + " / " + q + "none" + q + "）：")
        lines.append(q + "<repoID>" + q + ": pr https://github.com/<owner>/<repo>/pull/<编号>")
        lines.append(q + "<repoID>" + q + ": push 已推送 <branch> <短hash>")
        lines.append(q + "<repoID>" + q + ": merge 已合并到 <base> <短hash>")
        lines.append(q + "<repoID>" + q + ": none 不交付")
        var text = lines.joined(separator: "\n")
        if let marker = marker {
            text += "\n\n最后**单独一行**原样输出完成标记（供壳层确认本次交付结束）：" + marker
        }
        return text
    }

    /// 仓库在提示词里的抬头：根是「（工作区根）」，子仓库是「repo/」。
    static func repoLabel(_ repoID: String) -> String {
        repoID == "." ? "（工作区根）" : repoID + "/"
    }

    /// 一个仓库的实际交付动作（含降级说明），写进多仓库交付提示词。
    static func actionDescription(_ run: QueueRepoRun) -> String {
        let base: String
        switch run.effective {
        case .pr: base = "开 PR（推送分支并开 / 复用 pull request）"
        case .push: base = "直接推送（不合并、不开 PR）"
        case .merge: base = "本地合并（合进基线，不开 PR）"
        case .none: base = "不交付（不做任何 git / 远端操作）"
        }
        guard run.intent != run.effective else { return base }
        let intent: String
        switch run.intent {
        case .pr: intent = "PR"
        case .push: intent = "推送"
        case .merge: intent = "本地合并"
        case .none: intent = "不交付"
        }
        return base + "（原意图「" + intent + "」因该仓库能力不足而降级）"
    }

    /// 本地合并进 base（有远端才推送）。冲突尽量现场解；超出确定范围就停下请用户介入；
    /// base 被保护时如实报错（用户自己处理，比如改仓库设置或改用 PR）。
    /// hasRemote == false：只做本地合并，明确不推送——本地仓库也能交付。
    static func mergeAndPush(queueName: String?, branch: String, base: String, commits: [String],
                             hasRemote: Bool = true) -> String {
        var lines: [String] = []
        let head = "队列「\(queueName ?? branch)」的任务已完成。请把它**本地合并进 \(base)"
        lines.append(hasRemote ? head + "，并推送 \(base)**（不开 PR）：" : head + "**（不开 PR）：")
        lines.append("")
        lines.append("步骤：")
        lines.append("1. 先看清分支 \(branch) 到底改了什么（git log \(base)..\(branch)、git diff \(base)...\(branch)）；")
        lines.append("2. git checkout \(base)，并确认工作区干净（有未提交改动就先停下说明）；")
        lines.append("3. git merge \(branch)。**产生冲突时尽你所能现场解决**，解完说明你改了什么；")
        lines.append("   如果冲突范围超出你能确定的范围，**停下来**把冲突文件与取舍点列清楚、请用户介入，不要猜；")
        if !commits.isEmpty {
            lines.append("")
            lines.append("分支上已有的提交：")
            for commit in commits { lines.append("  " + commit) }
        }
        lines.append("")
        if hasRemote {
            lines.append("4. 把 \(base) 推送到远端（远端名优先 github，其次 origin）；被分支保护 / non-fast-forward / 需要 PR 拒绝时，")
            lines.append("   **如实报错**并把服务端原文贴出来，提示用户可改用 PR 模式或调整仓库设置——**不要强推**；")
            lines.append("5. 最后一行给出结果：成功则写「已合并并推送 \(base)」+ merge 后的短 hash；失败则写清卡在哪一步。")
        } else {
            lines.append("4. 这个工作区**没有远端**：不要尝试推送，本地合并完成即可；")
            lines.append("5. 最后一行给出结果：写「已合并到 \(base)（无远端，未推送）」+ merge 后的短 hash；失败则写清卡在哪一步。")
        }
        return lines.joined(separator: "\n")
    }

    /// 直接推送当前分支（主分支直推的工作流）：不合并、不开 PR。
    static func pushOnly(queueName: String?, branch: String?, base: String) -> String {
        let target = branch ?? "当前分支"
        var lines: [String] = []
        lines.append("队列「\(queueName ?? target)」的任务已完成。请**直接推送 \(target)**（不合并、不开 PR）：")
        lines.append("")
        lines.append("1. 确认当前就在 \(target)、工作区干净；")
        lines.append("2. 推送到远端（远端名优先 github，其次 origin）；被分支保护拒绝时**如实报错**并贴出服务端原文，")
        lines.append("   提示用户调整仓库设置或改用 PR 模式；")
        lines.append("3. 最后一行给出结果：成功则写「已推送 \(target)」+ 短 hash；失败则写清原因。")
        return lines.joined(separator: "\n")
    }

    /// The completion report handed back to the session that created a queue — sent
    /// when the queue reaches .done (see TasksRunner.notifyFinishedQueues).
    ///
    /// It carries each task's FULL 汇报 (and a failed task's reason), the queue branch,
    /// the commits it carries and the PR, so the user can actually 验收. It deliberately
    /// asks the receiving agent to do NOTHING but acknowledge: the report lands in a
    /// conversation as a user turn, and nobody asked for more work.
    ///
    /// `commits` is the queue branch's `git log --oneline base..HEAD`; empty, or a
    /// branchless queue (a non-git workspace), drops the section entirely.
    static func queueFinishedSummary(queue: TaskQueue, tasks: [TaskItem], commits: [String] = []) -> String {
        let done = tasks.filter { $0.state == .done }.count
        var lines: [String] = ["【任务面板】队列「\(queue.name)」已全部完成（\(done)/\(tasks.count)）"]
        if let branch = queue.branch, !branch.isEmpty {
            lines.append("分支：\(branch) → \(queue.baseBranch)")
        }
        lines.append(contentsOf: Self.timingLine(tasks))
        lines.append("")
        for (index, task) in tasks.enumerated() {
            let mark: String
            switch task.state {
            case .done: mark = "✓"
            case .failed: mark = "✗"
            case .cancelled: mark = "−"
            default: mark = "·"
            }
            lines.append("\(index + 1). \(mark) \(task.title)")
            if task.state == .failed {
                let detail = task.errorDetail.map { "：" + $0 } ?? ""
                lines.append("   失败：\(task.error ?? "失败")\(detail)")
            } else if task.state == .cancelled {
                lines.append("   已取消")
            }
            if let report = task.report?.trimmingCharacters(in: .whitespacesAndNewlines), !report.isEmpty {
                let text = report.count > 1500
                    ? String(report.prefix(1500)) + "\n…（汇报过长，已截断）"
                    : report
                lines.append("   汇报：")
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("     " + String(line))
                }
            }
            if let prUrl = task.prUrl { lines.append("   PR：\(prUrl)") }
        }
        if let prUrl = queue.prUrl {
            lines.append("")
            lines.append("队列 PR：\(prUrl)")
        } else if let prError = queue.prError {
            lines.append("")
            lines.append("队列 PR：未开（\(prError)）")
        }
        if queue.branch != nil, !commits.isEmpty {
            lines.append("")
            lines.append("分支上相对 \(queue.baseBranch) 的提交：")
            for commit in commits { lines.append("  " + commit) }
        }
        lines.append("")
        lines.append("这是任务面板的完成通知。请用一两句话确认收到并等待用户验收，不要主动改代码或新建任务。")
        return lines.joined(separator: "\n")
    }

    /// "耗时：14:03 → 14:25（22 分钟）", or nothing when the board has no timestamps.
    private static func timingLine(_ tasks: [TaskItem]) -> [String] {
        let starts = tasks.compactMap { $0.startedAt }
        let finishes = tasks.compactMap { $0.finishedAt }
        guard let start = starts.min(), let finish = finishes.max(), finish >= start else { return [] }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let minutes = Int(finish.timeIntervalSince(start) / 60)
        return ["耗时：\(formatter.string(from: start)) → \(formatter.string(from: finish))（\(minutes) 分钟）"]
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

    /// The panel's 默认工作流 can change while this board is loaded (设置抽屉). The env
    /// was snapshotted at adopt time, so the runner is told here instead of being
    /// rebuilt — a rebuild would drop the current phase (and a running task).
    func setDefaultIntegration(_ mode: QueueIntegration) { env.defaultIntegration = mode }

    /// 交付成功后自动关闭队列 (this workspace's value) can change while this board is
    /// loaded (the same drawer as the workflow default), so the runner is told here.
    func setAutoCloseOnPublish(_ on: Bool) { env.autoCloseOnPublish = on }

    /// The workflow a queue will actually use in THIS workspace: its own override,
    /// else the workspace default the runner was built with. The API's deliver
    /// endpoint answers 「能不能交付」 from it before starting anything.
    func resolvedIntegration(forQueue queueID: String) -> QueueIntegration {
        board.integration(forQueue: queueID, default: env.defaultIntegration)
    }

    private struct Active {
        var taskID: String
        var queueID: String?
        var branch: String?
        var sessionId: String
        var startedAt: Date
        /// 本次尝试的完成 marker（P1）：只有会话最后的汇报回显了它，才算这次 turn
        /// 真的做完。nil = legacy / 无 marker 的旧路径。
        var marker: String?
    }

    /// The dedicated 开 PR 会话 of a finished queue (§V2-6): the session that pushes
    /// the branch, summarizes the diff and opens the pull request.
    struct PRRun {
        var queueID: String
        var mode: QueueIntegration
        var branch: String
        var base: String
        var sessionId: String
        var startedAt: Date
        /// Set when this run went to the queue's ORIGINATING session: the prompt ends
        /// with this marker and only a report carrying it is adopted — that session is
        /// a real conversation, so its last report may belong to another turn.
        var marker: String?
        /// Whether sessionId is the originating session. We never cancel it.
        var reused: Bool
        /// 本队列的目标仓库（design §7.3）：多仓库交付时按顺序记录每个仓库的
        /// intent / effective / 结果。legacy 单仓库 env 为空。
        var targets: [WorkspaceRepo] = []
        /// 每个目标仓库的交付计划（含 effective）；空 = legacy 单仓库路径。
        var runs: [QueueRepoRun] = []
        /// 单独重试失败仓库（design §7.3 / P4）时，只替换这些 repoID 的旧结果，
        /// 已成功仓库的记录原样保留。空 = 整队列交付（覆盖全部）。
        var replacesRepoIDs: [String] = []
    }

    private enum Phase {
        case idle
        case starting(String)
        case active(Active)
        case finishing(String)
        /// The PR session is being created (dsh RPC is blocking).
        case startingPR(String)
        /// The PR session is running (or its result is being looked up).
        case openingPR(PRRun)
    }

    private enum StartResult {
        case started(sessionId: String, branch: String?)
        /// The session id is carried along when one was created before the
        /// failure (a started-but-unnamed session is still findable in dsh web).
        /// The third value is the per-repo detail the card appends to the reason
        /// (a multi-repo pre-flight names the repository that failed).
        case failed(TaskFailure, String?, String?)
    }

    private enum FinishOutcome {
        /// The session stopped. Its work is done; its PR (if its queue wants one) is
        /// a separate session's business — see startQueuePR.
        case done
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
    /// A PR run's result is being looked up (the session log + the GitHub API, both
    /// blocking). The phase stays .openingPR while that happens, so this keeps the
    /// next ticks from starting a second lookup.
    private var prLookupInFlight = false
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

    /// The sidebar prefix every task session's title carries, so a queue-spawned
    /// session is recognizable in dsh web at a glance ("TASK: 改 README").
    static let taskSessionTitlePrefix = "TASK: "

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
        case .idle, .startingPR, .openingPR: return nil
        }
    }

    /// The queue whose PR session is in flight right now, or nil. The panel shows it
    /// instead of 「正在处理 #N」 — no task is running during a PR run (`isBusy` is
    /// still true: the serial slot belongs to the PR session).
    var openingPRQueueID: String? {
        switch phase {
        case .startingPR(let queueID): return queueID
        case .openingPR(let run): return run.queueID
        default: return nil
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
        case .starting, .finishing, .startingPR:
            return true
        case .openingPR(let run):
            return stepPRRun(run, now: now)
        case .idle:
            // A restart between 「已完成」 and its report: pick the report up here.
            notifyFinishedQueues(now: now)
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
        // Target repositories are resolved for THIS task (design §5.2). The live
        // re-probe happens inside env.perform below; the snapshot is the fallback for
        // a legacy / headless env.
        let gitFor = env.gitFor
        let reposSnapshot = env.repos
        let primarySnapshot = env.primaryRepoID
        let repoSetProvider = env.repoSetProvider

        phase = .starting(taskID)
        cancelRequested = false
        unknownPolls = 0
        missingPolls = 0
        board.markRunning(taskID, at: now)
        // 本次尝试的完成 marker（P1）：随提示词注入，并记在任务 / local.json 上。
        // 只有这次 turn 的汇报回显了它，finish() 才判 done。legacy env 不设门槛。
        let marker: String? = env.requireCompletionMarker ? TasksRunner.makeTaskMarker() : nil
        if let marker = marker { board.recordAttemptMarker(taskID, marker) }
        persist()
        log("tasks: starting " + taskID + " on " + (branch ?? "the current branch"))

        var startResult: StartResult = .failed(.session, nil, nil)
        env.perform({
            // Re-probe the workspace's repositories HERE, on the runner's background
            // queue (design §5.1): a workspace can gain or lose repositories between
            // two tasks. resolveTargets then applies the queue's own list (or the
            // primary default). Empty on a legacy env → the old single-git path below.
            let liveRepos: [WorkspaceRepo]
            let livePrimaryID: String?
            if let live = repoSetProvider?() {
                liveRepos = live.repos
                livePrimaryID = live.primary?.id
            } else {
                liveRepos = reposSnapshot
                livePrimaryID = primarySnapshot
            }
            let targets = TasksRunner.resolveTargets(queue: queue, repos: liveRepos,
                                                     primaryRepoID: livePrimaryID)
            if targets.isEmpty {
                let entered = git.enter(branch: branch, base: base)
                if let failure = TasksRunner.failure(for: entered) {
                    startResult = .failed(failure, nil, nil)
                    return
                }
            } else {
                // Two-phase: pre-flight every target, THEN enter them (design §5.2).
                let entered = TasksRunner.enterTargets(targets, branch: branch, base: base,
                                                       gitFor: { gitFor?($0) ?? git })
                if let failure = entered.failure {
                    log("tasks: " + taskID + " 预检/切分支失败（" + failure.rawValue + "）"
                        + (entered.detail.map { "：" + $0 } ?? ""))
                    startResult = .failed(failure, nil, entered.detail)
                    return
                }
            }
            // The 交接简报 is built HERE, off the main thread: it reads the earlier
            // tasks' session logs (a core-bridge call) and asks each target repo for
            // the commits the branch already carries (grouped per repo, design §5.3).
            let brief = TasksRunner.brief(taskID: taskID, queue: queue, board: boardNow,
                                          git: git, sessionReport: sessionReport,
                                          branch: branch, base: base, position: nil,
                                          targets: targets, gitFor: gitFor)
            if let brief = brief, !brief.isEmpty {
                log("tasks: brief for " + taskID + " is " + String(brief.count) + " chars")
            }
            // 完成标记追加在提示词最后一行：任务会话的汇报必须回显它（P1）。
            var prompt = promptText(task, queue, brief)
            if let marker = marker {
                prompt += "\n\n" + TaskPrompts.completionMarkerInstruction(marker)
            }
            guard let sessionId = createSession(repoRoot) else {
                startResult = .failed(.session, nil, nil)
                return
            }
            _ = renameSession(sessionId, TasksRunner.taskSessionTitlePrefix + title)
            guard promptSession(sessionId, prompt) else {
                startResult = .failed(.prompt, sessionId, nil)
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
                                   sessionId: sessionId, startedAt: now,
                                   marker: board.task(taskID)?.completionMarker))
            board.local.sessions[taskID] = sessionId
            if let i = board.index(ofTask: taskID) { board.tasks[i].sessionId = sessionId }
            env.log("tasks: " + taskID + " running in " + sessionId)
            persist()
        case .failed(let failure, let sessionId, let errorDetail):
            if let sessionId = sessionId {
                board.local.sessions[taskID] = sessionId
                if let i = board.index(ofTask: taskID) { board.tasks[i].sessionId = sessionId }
            }
            env.log("tasks: " + taskID + " could not start (" + failure.rawValue + ")")
            board.markFailed(taskID, error: failure.rawValue, errorDetail: errorDetail, at: now)
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
                      position: Int?,
                      targets: [WorkspaceRepo] = [],
                      gitFor: ((WorkspaceRepo) -> TaskGit)? = nil) -> String? {
        guard let queue = queue else { return nil }
        let index = position ?? queue.taskIds.firstIndex(of: taskID).map { $0 + 1 } ?? 1
        let earlier = queue.taskIds.prefix(max(0, index - 1)).compactMap { id -> TaskPrompts.QueueBrief.Earlier? in
            guard let task = board.task(id) else { return nil }
            // Everything that is BEHIND us counts, however it ended: a failed or
            // cancelled task left work and a story the next task must know (else
            // the retry re-explores from scratch).
            guard task.state == .done || task.state == .failed || task.state == .cancelled else { return nil }
            // The stored 汇报 first: the runner writes it back when a task ends (so it
            // survives a deleted session), and only a task that ended before that
            // existed has to be read out of the session log again.
            return TaskPrompts.QueueBrief.Earlier(title: task.title, state: task.state,
                                                  errorKey: task.error,
                                                  report: task.report ?? task.sessionId.flatMap { sessionReport($0) })
        }
        // The commits the branch already carries, GROUPED per target repository
        // (design §5.3). A legacy env (no targets) keeps the single unlabeled group;
        // one target also renders flat, so今天 的单仓库文本逐字不变.
        let commits: [RepoCommits]
        if let branch = branch, !branch.isEmpty {
            if targets.isEmpty {
                commits = [RepoCommits(repoID: ".", commits: git.commits(base: base) ?? [])]
                    .filter { !$0.commits.isEmpty }
            } else {
                let single = targets.count == 1
                commits = targets.map { repo -> RepoCommits in
                    let handle = gitFor?(repo) ?? git
                    let repoBase = single && repo.id == "." && !base.isEmpty ? base : repo.defaultBase
                    return RepoCommits(repoID: repo.id, commits: handle.commits(base: repoBase) ?? [])
                }.filter { !$0.commits.isEmpty }
            }
        } else {
            commits = []
        }
        let heading = TaskPrompts.QueueBrief(queueName: queue.name, position: index,
                                             total: queue.taskIds.count, earlier: earlier,
                                             branch: branch, base: base, commits: commits,
                                             groupedByRepo: targets.count > 1)
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
        // The queue's PR is opened once, when its LAST task finishes: every task in a
        // queue shares one branch, and GitHub allows one open PR per head.
        let queueHasMore = queue?.taskIds.contains { id in
            id != active.taskID && (board.task(id)?.state == .queued || board.task(id)?.state == .running)
        } ?? false
        // LANDING POLICY: a task session ONLY COMMITS. Pushing / merging / opening a
        // Delivery is a job of its own, done by a dedicated 交付会话 once the queue is done
        // (startQueueIntegration) — which is why nothing here asks the agent to push,
        // checks whether it did, or talks to the GitHub API at all.
        // 工作流「无」= 明确不交付，所以即使 autoPR 开着也不起交付会话。
        let resolvedMode = active.queueID.map {
            board.integration(forQueue: $0, default: env.defaultIntegration)
        }
        // NOTE: resolvedMode is Optional — write QueueIntegration.none in full, or
        // Swift binds ".none" to Optional.none and this becomes "is non-nil" (true
        // for every queue), silently ignoring the 无 setting.
        let wantsFinalize = (queue?.autoPR ?? false) && !queueHasMore
            && resolvedMode != QueueIntegration.none
        let log = env.log
        let taskID = active.taskID
        let sessionReport = env.sessionReport
        if !wantsFinalize, queue?.autoPR == true {
            log("tasks: " + taskID + " finishes its own work — the queue's finalize session runs later")
        }

        let marker = active.marker
        phase = .finishing(taskID)
        var report: String? = nil
        // 没有 marker 的是 legacy / 旧路径：不设门槛。有 marker 就必须由本次 turn 的
        // 最后一行回显它，否则进入「待确认」——不允许再写死 done。
        var verified = (marker == nil)
        env.perform({
            // The 汇报 is read HERE, while the session still exists, and written back
            // onto the task: the card shows it, and the next task of the queue gets it
            // as its 前置汇报 even if this session is deleted tomorrow.
            let raw = sessionReport(active.sessionId)
            if let marker = marker {
                // P1 完成协议：只认本次 turn 最后一行回显的 marker；写回卡片的汇报里
                // 去掉 marker（它是壳层的机械信号，不是代理的汇报内容）。
                verified = TasksRunner.markerConfirmed(in: raw, marker: marker)
                report = TasksRunner.strippingMarker(raw, marker: marker)
            } else {
                report = raw
            }
        }, {
            self.board.recordMarkerVerified(taskID, verified)
            if !verified {
                log("tasks: " + taskID + " 会话结束但最后汇报没有本次完成标记——待确认（不判 done）")
            }
            let outcome: FinishOutcome = verified ? .done : .failed(.unverified)
            self.applyFinish(taskID: taskID, outcome: outcome, now: now, report: report,
                             finalizeQueueID: (wantsFinalize && verified) ? queue?.id : nil)
        })
    }

    private func applyFinish(taskID: String, outcome: FinishOutcome, now: Date,
                             report: String? = nil, finalizeQueueID: String? = nil) {
        phase = .idle
        let isIssue = board.task(taskID)?.source == .github
        switch outcome {
        case .done:
            board.markDone(taskID, report: report, at: now)
            env.log("tasks: " + taskID + " done")
        case .failed(let failure):
            board.markFailed(taskID, error: failure.rawValue, report: report, at: now)
            env.log("tasks: " + taskID + " failed (" + failure.rawValue + ")")
        }
        if isIssue, let task = board.task(taskID) { env.persistIssueTask(task) }
        persist()
        // A queue that just reached .done reports back to the session that created it.
        // This is deliberately BEFORE the PR run and does NOT wait for it (decision:
        // 「任务全做完立刻回传，PR 会话不阻塞」).
        notifyFinishedQueues(now: now)
        // Only a queue that ENDED WELL hands its branch over to a PR session: a failed
        // task pauses the queue, and half-finished work is not what anyone wants merged.
        if case .done = outcome, let queueID = finalizeQueueID { startQueueIntegration(queueID) }
        _ = pump(now: now)
    }

    // MARK: - The queue PR session

    /// Start the PR session of a queue — the ONE place that pushes a branch and opens
    /// a pull request (§V2-6). Task sessions only commit; this session reads what the
    /// branch actually did, writes the title and body from it, pushes, opens (or
    /// reuses) the PR and says the URL out loud.
    ///
    /// Called automatically when a queue with 「完成后自动开 PR」 finishes its last task,
    /// and by the queue header 开 PR button — which is why it does not care whether
    /// autoPR is on. Refused (with a log line and a reason on the queue, never a
    /// session that cannot succeed) when a PR run is already in flight, when the queue
    /// has no branch to publish, or when the workspace has no GitHub remote.
    @discardableResult
    func startQueueIntegration(_ queueID: String) -> Bool {
        guard let queue = board.queue(queueID) else { return false }
        // Resolve the queue FIRST so a refusal can always leave its reason on the card.
        guard case .idle = phase else {
            env.log("tasks: a finalize session is already in flight — not starting one for " + queueID)
            _ = board.setQueuePRError(queueID, "tasks.errPRBusy")
            persist()
            return false
        }
        // 目标仓库：运行期重探测优先（design §5.1），否则用 adopt 快照。空 = legacy
        // 单仓库 env，走今天的单仓库交付路径（逐字节不变）。
        let liveSet = env.repoSetProvider?()
        let repos = liveSet?.repos ?? env.repos
        let primaryID = liveSet?.primary?.id ?? env.primaryRepoID
        let targets = TasksRunner.resolveTargets(queue: queue, repos: repos, primaryRepoID: primaryID)
        if targets.isEmpty {
            return startLegacyIntegration(queue)
        }
        // 多仓库：每个仓库的 intent = 队列覆盖 ?? 该仓库默认，再按能力降级
        // （design §7.2）。「无」是整队列的明确选择，不做。
        let env = self.env
        if queue.integration == .some(.none) {
            env.log("tasks: queue " + queueID + " 的工作流是「无」——不交付")
            return false
        }
        let runs = TasksRunner.deliveryPlan(
            queue: queue, targets: targets,
            queueOverride: queue.integration,
            perRepoDefault: { env.integrationDefault(for: $0) },
            hasRemote: { repo in repo.remoteName != nil || env.gitHandle(for: repo).remoteName() != nil })
        // 只要**任意一个**目标 effective != none 就继续；全都没得交付才拒绝。
        guard runs.contains(where: { $0.effective != .none }) else {
            env.log("tasks: queue " + queueID + " 的每个目标仓库都没有可交付的动作")
            _ = board.setQueuePRError(queueID, "tasks.errPRNoRemote")
            persist()
            return false
        }
        // mode 只用于日志 / legacy 判定：取最强的 effective。
        let mode = runs.first { $0.effective == .pr }?.effective
            ?? runs.first { $0.effective == .push }?.effective
            ?? runs.first { $0.effective == .merge }?.effective ?? .none
        let base = queue.baseBranch
        let name = queue.name
        let branch = queue.branch
        let origin = board.local.queueSessions[queueID]
        phase = .startingPR(queueID)
        var run: PRRun?
        env.perform({
            run = TasksRunner.makeFinalizeRun(env: env, queueID: queueID, mode: mode, name: name,
                                              branch: branch, base: base,
                                              originSession: origin,
                                              targets: targets, runs: runs)
        }, {
            guard let run = run else {
                self.phase = .idle
                self.env.log("tasks: could not start a finalize session for queue " + queueID)
                _ = self.board.setQueuePRError(queueID, "tasks.errPRSession")
                self.persist()
                return
            }
            self.beginPRRun(run)
        })
        return true
    }

    /// 单独重试一个交付失败的仓库（design §7.3 / P4）：只对这一个仓库重开一次交付
    /// 会话，结果并回 queue.repoRuns —— 已成功的仓库记录原样保留，不整队列重跑。
    @discardableResult
    func retryFailedRepo(queueID: String, repoID: String) -> Bool {
        guard let queue = board.queue(queueID),
              let existing = queue.repoRuns.first(where: { $0.repoID == repoID && $0.status == .failed })
        else { return false }
        guard case .idle = phase else {
            env.log("tasks: a finalize session is already in flight — not retrying " + repoID)
            _ = board.setQueuePRError(queueID, "tasks.errPRBusy")
            persist()
            return false
        }
        // 目标仓库运行期重探测（与 startQueueIntegration 同一入口）。
        let liveSet = env.repoSetProvider?()
        let repos = liveSet?.repos ?? env.repos
        let primaryID = liveSet?.primary?.id ?? env.primaryRepoID
        let targets = TasksRunner.resolveTargets(queue: queue, repos: repos, primaryRepoID: primaryID)
        guard let target = targets.first(where: { $0.id == repoID }) else {
            env.log("tasks: cannot retry " + repoID + " — it is no longer a target of queue " + queueID)
            return false
        }
        let env = self.env
        let hasRemote = target.remoteName != nil || env.gitHandle(for: target).remoteName() != nil
        let effective = QueueIntegration.effective(existing.intent, repo: target, hasRemote: hasRemote)
        guard effective != .none else {
            // 该仓库本就无可交付动作：把旧失败记录改为「已跳过」，不再开会话。
            var runs = queue.repoRuns
            if let idx = runs.firstIndex(where: { $0.repoID == repoID }) {
                runs[idx].status = .skipped
                runs[idx].effective = .none
                _ = board.setQueueRepoRuns(queueID, runs)
            }
            persist()
            return true
        }
        let plan = QueueRepoRun(repoID: target.id, branch: existing.branch, base: existing.base,
                                intent: existing.intent, effective: effective, status: .pending)
        // 卡片上先显示「交付中」。
        var runs = queue.repoRuns
        if let idx = runs.firstIndex(where: { $0.repoID == repoID }) {
            runs[idx].status = .running
            runs[idx].note = nil
            _ = board.setQueueRepoRuns(queueID, runs)
        }
        let name = queue.name
        let branch = queue.branch
        let base = queue.baseBranch
        let origin = board.local.queueSessions[queueID]
        phase = .startingPR(queueID)
        var run: PRRun?
        env.perform({
            run = TasksRunner.makeFinalizeRun(env: env, queueID: queueID, mode: effective,
                                              name: name, branch: branch, base: base,
                                              originSession: origin,
                                              targets: [target], runs: [plan],
                                              replacesRepoIDs: [repoID])
        }, {
            guard let run = run else {
                self.phase = .idle
                self.env.log("tasks: could not start a retry session for " + repoID)
                _ = self.board.setQueuePRError(queueID, "tasks.errPRSession")
                // 恢复为失败，别让它停在「交付中」。
                var restore = self.board.queue(queueID)?.repoRuns ?? []
                if let idx = restore.firstIndex(where: { $0.repoID == repoID }) {
                    restore[idx].status = .failed
                    _ = self.board.setQueueRepoRuns(queueID, restore)
                }
                self.persist()
                return
            }
            self.beginPRRun(run)
        })
        persist()
        return true
    }

    /// 单仓库（或 legacy）交付：与今天逐字节相同的守卫与路径。
    private func startLegacyIntegration(_ queue: TaskQueue) -> Bool {
        let queueID = queue.id
        let mode = board.integration(forQueue: queueID, default: env.defaultIntegration)
        // 「无」是明确的选择，不是失败：什么都不做，也不在队列上记错误。
        if mode == .none {
            env.log("tasks: queue " + queueID + " 的工作流是「无」——不交付")
            return false
        }
        if mode == .pr || mode == .merge {
            guard let branch = queue.branch, !branch.isEmpty else {
                env.log("tasks: queue " + queueID + " has no branch — nothing to " + mode.rawValue)
                _ = board.setQueuePRError(queueID, "tasks.errPRNoBranch")
                persist()
                return false
            }
        }
        if mode == .pr {
            guard env.canOpenPR() else {
                env.log("tasks: queue " + queueID + " — this workspace has no GitHub remote, so there is no PR to open")
                _ = board.setQueuePRError(queueID, "tasks.errPRNoRemote")
                persist()
                return false
            }
        }
        if mode == .push {
            guard env.git.remoteName() != nil else {
                env.log("tasks: queue " + queueID + " — this workspace has no git remote to push to")
                _ = board.setQueuePRError(queueID, "tasks.errPRNoRemote")
                persist()
                return false
            }
        }
        let env = self.env
        let base = queue.baseBranch
        let name = queue.name
        let origin = board.local.queueSessions[queueID]
        phase = .startingPR(queueID)
        var run: PRRun?
        env.perform({
            run = TasksRunner.makeFinalizeRun(env: env, queueID: queueID, mode: mode, name: name,
                                              branch: queue.branch, base: base,
                                              originSession: origin)
        }, {
            guard let run = run else {
                self.phase = .idle
                self.env.log("tasks: could not start a finalize session for queue " + queueID)
                _ = self.board.setQueuePRError(queueID, "tasks.errPRSession")
                self.persist()
                return
            }
            self.beginPRRun(run)
        })
        return true
    }

    /// Create the PR session itself: two blocking dsh RPCs (create + prompt), static so
    /// it can run inside the background step. Returns nil when either fails — the caller
    /// then records the reason on the queue instead of leaving a half-created session.
    static func makeFinalizeRun(env: TaskRunnerEnv, queueID: String, mode: QueueIntegration,
                                name: String, branch: String?, base: String,
                                originSession: String? = nil,
                                targets: [WorkspaceRepo] = [],
                                runs: [QueueRepoRun] = [],
                                replacesRepoIDs: [String] = []) -> PRRun? {
        // What the branch carries, for the session context: it still reads the diff
        // itself (that is the point), but the commit list saves it from starting with
        // 「what is this branch」.
        let commits = branch.flatMap { _ in env.git.commits(base: base) } ?? []
        let hasRemote = env.git.remoteName() != nil
        // 多仓库交付用逐仓库提示词（design §7.3）；legacy / 单仓库保持今天文本。
        func prompt(_ marker: String?) -> String {
            if runs.isEmpty {
                return TaskPrompts.integration(mode: mode, queueName: name, branch: branch,
                                               base: base, commits: commits, hasRemote: hasRemote,
                                               marker: marker)
            }
            return TaskPrompts.integration(queueName: name, branch: branch, base: base,
                                           runs: runs, commits: commits, marker: marker,
                                           forceGrouped: !replacesRepoIDs.isEmpty)
        }
        // Prefer the queue's ORIGINATING session (user 2026-10-01): the queue was
        // created there and its completion is reported there, so finalize in the same
        // conversation. A unique MARKER is required back, because that session is a
        // real conversation — its last report may be an unrelated turn.
        if let origin = originSession, !origin.isEmpty {
            let marker = TasksRunner.makeMarker()
            if env.promptSession(origin, prompt(marker)) {
                return PRRun(queueID: queueID, mode: mode, branch: branch ?? base, base: base,
                             sessionId: origin, startedAt: Date(), marker: marker, reused: true,
                             targets: targets, runs: runs, replacesRepoIDs: replacesRepoIDs)
            }
            env.log("tasks: could not prompt the originating session " + origin
                    + " — falling back to a fresh finalize session")
        }
        let text = prompt(nil)
        guard let sessionId = env.createSession(env.repoRoot) else { return nil }
        // 交付会话的名字：三种工作流统一叫「交付：<队列名>」（具体动作由提示词说）。
        _ = env.renameSession(sessionId, L10n.tr("tasks.queue.finalizeSessionName", name))
        guard env.promptSession(sessionId, text) else {
            _ = env.cancelSession(sessionId)
            return nil
        }
        return PRRun(queueID: queueID, mode: mode, branch: branch ?? base, base: base,
                     sessionId: sessionId, startedAt: Date(), marker: nil, reused: false,
                     targets: targets, runs: runs, replacesRepoIDs: replacesRepoIDs)
    }

    /// A marker a session must echo back verbatim on its own last line.
    static func makeMarker(prefix: String = "DSH-FINALIZE-") -> String {
        prefix + UUID().uuidString.prefix(8).uppercased()
    }

    /// 任务会话的完成 marker（P1）：每任务、每次尝试唯一，形如
    /// DSH-TASK-DONE-XXXXXXXX。与交付会话的 DSH-FINALIZE- 两套独立、互不干扰。
    static func makeTaskMarker() -> String {
        makeMarker(prefix: "DSH-TASK-DONE-")
    }

    /// 会话最后的汇报是否回显了**本次** marker。只认最后一个非空行，且必须是本次
    /// 尝试的随机串 —— 旧 turn / 别处复述的 marker 不算数。
    static func markerConfirmed(in report: String?, marker: String) -> Bool {
        guard let report = report else { return false }
        let last = report.split(separator: "\n", omittingEmptySubsequences: true)
            .last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return last.contains(marker)
    }

    /// 把 marker 从会话汇报里去掉：它是壳层的机械信号，不是代理的汇报内容。
    static func strippingMarker(_ report: String?, marker: String?) -> String? {
        guard let report = report, let marker = marker else { return report }
        return report.replacingOccurrences(of: marker, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func beginPRRun(_ run: PRRun) {
        phase = .openingPR(run)
        _ = board.setQueuePRError(run.queueID, nil)
        env.log("tasks: finalize session " + run.sessionId + " (" + run.mode.rawValue
                + (run.reused ? ", origin" : ", fresh") + ") for queue " + run.queueID)
        persist()
    }

    /// One tick of a PR run: wait for the session, then ask what it produced.
    private func stepPRRun(_ run: PRRun, now: Date) -> Bool {
        guard !prLookupInFlight else { return true }
        switch env.sessionState(run.sessionId) {
        case .running:
            unknownPolls = 0
            missingPolls = 0
            if now.timeIntervalSince(run.startedAt) > timeout {
                if run.reused {
                    // Never cancel the user's conversation.
                    fallbackToNewSession(run)
                } else {
                    env.log("tasks: PR session " + run.sessionId + " timed out after "
                            + String(Int(timeout)) + "s; cancelling it")
                    _ = env.cancelSession(run.sessionId)
                    finishPRRun(run)
                }
            }
            return isBusy
        case .idle:
            unknownPolls = 0
            missingPolls = 0
            finishPRRun(run)
            return isBusy
        case .unknown:
            missingPolls = 0
            if unknownPolls % 10 == 0 {
                env.log("tasks: PR session " + run.sessionId + " — dsh could not report on it; still waiting")
            }
            unknownPolls += 1
            return isBusy
        case .missing:
            unknownPolls = 0
            missingPolls += 1
            if missingPolls >= TasksRunner.missingSessionPolls {
                if run.reused {
                    fallbackToNewSession(run)
                } else {
                    env.log("tasks: PR session " + run.sessionId + " is gone from dsh — looking for the PR anyway")
                    finishPRRun(run)
                }
            }
            return isBusy
        }
    }

    /// Ask what the PR session produced: the URL it reported, else whatever PR GitHub
    /// already has open for the branch.
    private func finishPRRun(_ run: PRRun) {
        prLookupInFlight = true
        let sessionReport = env.sessionReport
        let planned = run.runs
        let targets = run.targets
        let env = self.env
        var prUrl: String?
        var report: String?
        var resolved: [QueueRepoRun] = []
        env.perform({
            report = sessionReport(run.sessionId)
            if planned.isEmpty {
                // legacy 单仓库：与今天逐字节相同。
                prUrl = TasksRunner.prURL(in: report) ?? env.findExistingPR(run.branch)
            } else {
                // 多仓库：逐行解析 + 按仓库 findExistingPR 兜底（design §7.4）。
                resolved = TasksRunner.resolveRepoRuns(
                    planned, targets: targets,
                    results: TasksRunner.repoResults(in: report),
                    findExistingPR: { repo, branch in env.existingPR(for: repo, branch: branch) })
            }
        }, {
            // A reused ORIGINATING session only counts when OUR turn's marker came
            // back: its last report may otherwise belong to the user's conversation.
            if let marker = run.marker, report?.contains(marker) != true {
                self.prLookupInFlight = false
                return
            }
            self.applyPRRun(run, prUrl: prUrl, report: report, repoRuns: resolved)
        })
    }

    /// The originating session did not run the queued finalize in time (or is gone
    /// from dsh). It is the USER's conversation — never cancel it; hand the work to a
    /// dedicated session instead. (The prompts inspect the repo first, so a re-run
    /// after the work already happened is a no-op rather than a duplicate.)
    private func fallbackToNewSession(_ run: PRRun) {
        env.log("tasks: originating session " + run.sessionId
                + " did not run the finalize — using a fresh session for queue " + run.queueID)
        let queueID = run.queueID
        let mode = run.mode
        let name = board.queue(queueID)?.name ?? queueID
        let branch = run.branch
        let base = run.base
        let targets = run.targets
        let runs = run.runs
        let replaces = run.replacesRepoIDs
        let env = self.env
        phase = .startingPR(queueID)
        var fresh: PRRun?
        env.perform({
            fresh = TasksRunner.makeFinalizeRun(env: env, queueID: queueID, mode: mode,
                                                name: name, branch: branch, base: base,
                                                originSession: nil,
                                                targets: targets, runs: runs,
                                                replacesRepoIDs: replaces)
        }, {
            guard let fresh = fresh else {
                self.phase = .idle
                self.env.log("tasks: could not start a fallback finalize session for queue " + queueID)
                _ = self.board.setQueuePRError(queueID, "tasks.errPRSession")
                self.persist()
                return
            }
            self.beginPRRun(fresh)
        })
    }

    private func applyPRRun(_ run: PRRun, prUrl: String?, report: String?,
                           repoRuns: [QueueRepoRun] = []) {
        prLookupInFlight = false
        phase = .idle
        // The card shows the session's report; the FIRST line is what a collapsed card
        // reads, the rest is available by expanding (user 2026-10-01). Keep the whole
        // report (capped), not just the first line.
        var full = report?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A reused session's marker is shell-internal plumbing, not part of the result.
        if let marker = run.marker {
            full = full.replacingOccurrences(of: marker, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let firstLine = full.split(separator: "\n").first.map(String.init) ?? ""
        let note = full.isEmpty ? nil : String(full.prefix(4000))
        _ = board.setQueueIntegrationNote(run.queueID, note)
        // 多仓库：各仓库独立记账（design §7.3）。某个失败不丢弃已成功的仓库；队列仍
        // 进入 done，卡片按仓库逐行展示 N 成功 / M 失败。
        if !run.runs.isEmpty {
            let resolved = repoRuns.isEmpty ? run.runs : repoRuns
            // 单独重试失败仓库（P4）：只替换这些仓库的旧记录，已成功仓库原样保留。
            let runs: [QueueRepoRun]
            if run.replacesRepoIDs.isEmpty {
                runs = resolved
            } else {
                let incoming = run.replacesRepoIDs
                var merged = board.queue(run.queueID)?.repoRuns ?? run.runs
                for result in resolved where incoming.contains(result.repoID) {
                    if let idx = merged.firstIndex(where: { $0.repoID == result.repoID }) {
                        merged[idx] = result
                    } else {
                        merged.append(result)
                    }
                }
                runs = merged
            }
            _ = board.setQueueRepoRuns(run.queueID, runs)
            let successes = runs.filter { $0.status == .done }
            let failures = runs.filter { $0.status == .failed }
            if let url = successes.compactMap({ $0.prUrl }).first {
                _ = updateQueue(run.queueID, prUrl: url)
            }
            if failures.isEmpty || !successes.isEmpty {
                _ = board.setQueuePRError(run.queueID, nil)
            } else {
                _ = board.setQueuePRError(run.queueID, "tasks.errPR")
            }
            env.log("tasks: queue " + run.queueID + " finalized per repo — "
                    + runs.map { $0.repoID + ":" + $0.status.rawValue }.joined(separator: "、"))
            let published = failures.isEmpty && !successes.isEmpty
            if published { autoCloseAfterPublish(run.queueID) }
            persist()
            _ = pump()
            return
        }
        var published = false
        if run.mode == .pr {
            if let prUrl = prUrl {
                _ = updateQueue(run.queueID, prUrl: prUrl)
                _ = board.setQueuePRError(run.queueID, nil)
                env.log("tasks: queue " + run.queueID + " has its PR: " + prUrl)
                published = true
            } else {
                // No URL in the report and no open PR for the branch. The session is the
                // only place that knows why (it was asked to say so).
                env.log("tasks: no PR for queue " + run.queueID + " — session " + run.sessionId
                        + " ended saying: " + String((note ?? "(no report)").prefix(200)))
                _ = board.setQueuePRError(run.queueID, "tasks.errPR")
            }
        } else {
            env.log("tasks: queue " + run.queueID + " finalized (" + run.mode.rawValue + "): "
                    + (note ?? "(no report)"))
            published = Self.finalizeSucceeded(mode: run.mode, report: full)
        }
        // 交付成功后自动关闭队列 (the panel setting): close only after a delivery the shell
        // can actually see succeeded, and only while the queue is still .done.
        if published { autoCloseAfterPublish(run.queueID) }
        persist()
        _ = pump()
    }

    /// Whether a finalize run counts as a successful publish, from what the shell can
    /// observe. .pr has a definitive signal (a PR URL, checked by the caller); merge
    /// and push have none in the API, so the shell looks for the result wording the
    /// finalize prompt explicitly asks the agent for (「已合并…」 / 「已推送…」). A
    /// report it cannot read is NOT a success: better to leave the queue open than to
    /// close it over a failure.
    static func finalizeSucceeded(mode: QueueIntegration, report: String?) -> Bool {
        let text = report ?? ""
        switch mode {
        case .merge: return text.contains("已合并")
        case .push: return text.contains("已推送")
        case .pr, .none: return false
        }
    }

    /// 交付成功后自动关闭队列: close the queue a delivery session just delivered — but
    /// ONLY when it is .done. A paused queue still holds a failed task, and closing it
    /// would hide the failure behind a neutral 「已关闭」 badge.
    private func autoCloseAfterPublish(_ queueID: String) {
        guard env.autoCloseOnPublish, board.queue(queueID)?.state == .done else { return }
        if closeQueue(queueID) {
            env.log("tasks: queue " + queueID + " auto-closed after a successful publish")
        }
    }

    /// The PR URL inside a session report: the first github.com/<owner>/<repo>/pull/<n>
    /// link. The report is the agent own words (TaskPrompts.pullRequest asks for the
    /// full URL on the last line), so this is a search rather than a parse of a fixed
    /// format — and a missing URL is not an error: findExistingPR answers next.
    static func prURL(in report: String?) -> String? {
        guard let report = report else { return nil }
        guard let range = report.range(of: "https?://[^\\s]*github\\.com/[^\\s]*/pull/[0-9]+",
                                       options: .regularExpression) else { return nil }
        return String(report[range])
    }

    /// 交付会话逐行输出的一个仓库结果（design §7.4）：`<repoID>: <action> <结果>`。
    struct RepoResult: Equatable {
        var repoID: String
        var action: QueueIntegration
        var detail: String
        var prUrl: String?
    }

    /// 从交付会话的汇报里解析**每个仓库**的一行结果（design §7.4）。宽松匹配：
    /// 只有行首是「repoID: action …」且 action 是四种之一才算；解析不到的仓库交给
    /// findExistingPR 兜底，不把解析成功当唯一判据。
    static func repoResults(in report: String?) -> [RepoResult] {
        guard let report = report else { return [] }
        var results: [RepoResult] = []
        for rawLine in report.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let repoID = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            guard !repoID.isEmpty, !repoID.contains(" ") else { continue }
            let rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let tokens = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let first = tokens.first,
                  let action = QueueIntegration(rawValue: String(first).lowercased()) else { continue }
            let detail = tokens.count > 1 ? String(tokens[1]) : ""
            results.append(RepoResult(repoID: repoID, action: action, detail: detail,
                                      prUrl: prURL(in: detail)))
        }
        return results
    }

    /// 把解析结果与兜底查询套到交付计划上，得到每个仓库的最终状态（design §7.3/§7.4）。
    /// 某个仓库失败不影响其他仓库；effective 为「不做」的仓库记账为 skipped。
    static func resolveRepoRuns(_ runs: [QueueRepoRun],
                                targets: [WorkspaceRepo],
                                results: [RepoResult],
                                findExistingPR: (WorkspaceRepo, String) -> String?) -> [QueueRepoRun] {
        runs.map { run in
            var out = run
            let repo = targets.first { $0.id == run.repoID }
            let parsed = results.first { $0.repoID == run.repoID }
            func existing() -> String? {
                guard let repo = repo else { return nil }
                return findExistingPR(repo, run.branch)
            }
            if let detail = parsed?.detail, !detail.isEmpty { out.note = detail }
            if run.effective == .none {
                out.status = .skipped
                if out.note == nil { out.note = "不交付" }
                return out
            }
            if let parsed = parsed {
                switch parsed.action {
                case .pr:
                    if let url = parsed.prUrl {
                        out.status = .done; out.prUrl = url
                    } else if let url = existing() {
                        out.status = .done; out.prUrl = url
                    } else {
                        out.status = .failed
                    }
                case .merge:
                    out.status = parsed.detail.contains("已合并") ? .done : .failed
                case .push:
                    out.status = parsed.detail.contains("已推送") ? .done : .failed
                case .none:
                    out.status = .skipped
                }
                // 该仓库本来要做 PR，但会话没有按 pr 报：仍然用 GitHub 兜底找已有 PR。
                if run.effective == .pr, out.status != .done, parsed.action != .pr,
                   let url = existing() {
                    out.status = .done; out.prUrl = url
                }
                return out
            }
            // 会话没有逐行报这个仓库：按 effective 兜底。
            switch run.effective {
            case .pr:
                if let url = existing() {
                    out.status = .done; out.prUrl = url
                } else {
                    out.status = .failed
                }
            case .merge, .push:
                out.status = .failed
            case .none:
                out.status = .skipped
            }
            return out
        }
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
                     autoPR: Bool = false,
                     repos: [String]? = nil,
                     integration: QueueIntegration? = nil) -> TaskQueue {
        let queue = board.createQueue(name: name, branch: branch, baseBranch: baseBranch,
                                      autoPR: autoPR, repos: repos, integration: integration)
        persist()
        return queue
    }

    /// Create a queue in the 等待态 (.draft) and put the given drafts in it — the ONE
    /// entry point the tasks API (task-todo skill) uses for 「建队列 + 批量入队」.
    ///
    /// Membership is written through TaskBoard.enqueue DIRECTLY, not runner.enqueue:
    /// the latter ACTIVATES a queue when the runner is idle (「加入队列」=「开始」 for
    /// the panel), which would start a queue that must wait for 启动队列. Nothing here
    /// starts anything — the caller or the user starts it later.
    ///
    /// `branch`: nil derives the default from the name; "" means no branch at all (a
    /// non-git workspace is forced to no branch, exactly like the panel's form).
    /// `autoPR`: nil means "whatever this workspace can do".`originSession`, when
    /// present, is remembered so the queue can report back to it when it reaches .done.
    @discardableResult
    func createQueueWithTasks(name: String,
                              branch: String? = nil,
                              baseBranch: String? = nil,
                              autoPR: Bool? = nil,
                              integration: QueueIntegration? = nil,
                              originSession: String? = nil,
                              drafts: [TaskDraft]) -> (queue: TaskQueue, created: [TaskItem]) {
        let branchArg: String?
        if let branch = branch {
            branchArg = branch
        } else if env.canSwitchBranches {
            branchArg = nil
        } else {
            branchArg = ""
        }
        let queue = board.createQueue(name: name,
                                      branch: branchArg,
                                      baseBranch: baseBranch ?? env.defaultBaseBranch,
                                      autoPR: autoPR ?? false,
                                      integration: integration)
        var created: [TaskItem] = []
        for draft in drafts where draft.isValid {
            let task = TaskItem.manual(title: draft.normalizedTitle, body: draft.effectiveBody)
            board.tasks.append(task)
            board.enqueue(taskID: task.id, into: queue.id)
            created.append(task)
        }
        if let originSession = originSession, !originSession.isEmpty {
            board.local.queueSessions[queue.id] = originSession
        }
        persist()
        env.log("tasks: created queue " + queue.id + " (" + queue.name + ") with "
                + String(created.count) + " task(s)"
                + (originSession.map { " — reports back to " + $0 } ?? ""))
        return (board.queue(queue.id) ?? queue, created)
    }

    /// Append tasks to an EXISTING queue — the conversational loop's 「再补几条」.
    ///
    /// Membership goes through TaskBoard.enqueue, so a `.done` queue returns to
    /// `.draft` and re-arms its completion report (the next finish reports again),
    /// while a `.paused` queue stays paused. Nothing starts here: the caller / the
    /// user starts the queue when ready.
    @discardableResult
    func appendTasks(toQueueID queueID: String, drafts: [TaskDraft]) -> [TaskItem] {
        guard let queue = board.queue(queueID), queue.state != .closed else { return [] }
        var created: [TaskItem] = []
        for draft in drafts where draft.isValid {
            let task = TaskItem.manual(title: draft.normalizedTitle, body: draft.effectiveBody)
            board.tasks.append(task)
            if board.enqueue(taskID: task.id, into: queueID) { created.append(task) }
        }
        persist()
        env.log("tasks: appended " + String(created.count) + " task(s) to queue " + queueID)
        return created
    }

    /// Send the completion report of every 已完成 queue that has an originating session
    /// and has not reported yet, then mark it reported.
    ///
    /// Idempotent and cheap (a filter over queues), so it runs both right after a task
    /// finishes (the transition into .done) and on an idle step (a restart between
    /// 「已完成」 and the report). A delivery failure still marks the queue reported:
    /// the report is information, and retrying forever is worse than losing it.
    func notifyFinishedQueues(now: Date = Date()) {
        let pending = board.queues.filter { queue in
            queue.state == .done
                && board.local.queueSessions[queue.id] != nil
                && board.local.queueNotified[queue.id] == nil
        }
        guard !pending.isEmpty else { return }
        for queue in pending {
            guard let session = board.local.queueSessions[queue.id] else { continue }
            let tasks = queue.taskIds.compactMap { board.task($0) }
            // Mark BEFORE the RPC: a second step must never queue the same report twice.
            board.local.queueNotified[queue.id] = TaskItem.iso8601.string(from: now)
            let notify = env.notifySession
            let log = env.log
            let git = env.git
            let branch = queue.branch
            env.perform({
                // The commit list is a blocking git call, so it lives in the background
                // half. A branchless queue (non-git workspace / 不切分支) has none.
                let commits = (branch?.isEmpty == false)
                    ? (git.commits(base: queue.baseBranch) ?? []) : []
                let text = TaskPrompts.queueFinishedSummary(queue: queue, tasks: tasks, commits: commits)
                _ = notify(session, text)
            }, {
                log("tasks: queue " + queue.id + " finished — reported to " + session)
            })
        }
        persist()
    }

    /// Edit a queue's settings. A double-optional branch distinguishes "leave it
    /// alone" (nil) from "no branch at all" (.some(nil)).
    @discardableResult
    func updateQueue(_ queueID: String,
                     name: String? = nil,
                     branch: String?? = nil,
                     baseBranch: String? = nil,
                     autoPR: Bool? = nil,
                     prUrl: String? = nil,
                     repos: [String]?? = nil,
                     integration: QueueIntegration?? = nil) -> Bool {
        guard let qi = board.index(ofQueue: queueID) else { return false }
        if let name = name { board.queues[qi].name = name }
        if let branch = branch { board.queues[qi].branch = branch }
        if let baseBranch = baseBranch { board.queues[qi].baseBranch = baseBranch }
        if let autoPR = autoPR { board.queues[qi].autoPR = autoPR }
        if let prUrl = prUrl { board.queues[qi].prUrl = prUrl }
        // .some(nil) clears the target list (back to the primary), nil leaves it.
        if let repos = repos { board.queues[qi].repos = repos }
        if let integration = integration { board.queues[qi].integration = integration }
        persist()
        return true
    }

    @discardableResult
    func removeQueue(_ queueID: String) -> Bool {
        let removed = board.removeQueue(queueID)
        if removed { persist() }
        return removed
    }

    /// 关闭队列: the user's MANUAL terminal state. Keeps the record (tasks / branch /
    /// PR); afterwards it accepts no start, no append and no publish. Refused while
    /// a task is running (cancel first), exactly like removeQueue.
    @discardableResult
    func closeQueue(_ queueID: String) -> Bool {
        let ok = board.closeQueue(queueID)
        if ok {
            persist()
            env.log("tasks: queue " + queueID + " closed")
        }
        return ok
    }

    /// Put a task into a queue and start it when nothing else is running.
    ///
    /// A task added while NO queue is active makes its own queue the active one:
    /// that is what makes 「加入队列」equal 「开始」while the runner is idle. A
    /// queue restored as paused after a restart is never activated this way —
    /// that path loads the board instead of calling enqueue.
    @discardableResult
    func enqueue(taskID: String, into queueID: String) -> Bool {
        // 新建的空队列被加入任务时照旧「加入即开始」；向**已有**队列追加任务则不
        // 自动启动 —— 用户先验收再显式开始（`.done` 追加后回到 `.draft` 就是这个意思）。
        let wasEmpty = board.queue(queueID)?.taskIds.isEmpty ?? true
        let ok = board.enqueue(taskID: taskID, into: queueID)
        guard ok else { return false }
        if wasEmpty { activateQueueIfIdle(queueID) }
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
    func startIssueTask(_ taskID: String, repos: [String]? = nil) -> String? {
        guard let task = board.task(taskID), task.source == .github else { return nil }
        dropUnswitchableBranch(ofTask: taskID)
        return startStandaloneTask(task, queue: {
            TaskQueue.auto(for: task,
                           baseBranch: env.defaultBaseBranch,
                           switchesBranch: env.canSwitchBranches,
                           opensPR: env.canOpenPR(),
                           repos: repos)
        })
    }

    /// A queue built before this rule existed (or built in a git workspace and then
    /// carried into this one) may still ask for a branch this directory cannot switch
    /// to: drop it first, or the retry fails with tasks.errNotGit exactly like the
    /// first attempt did. Both task sources go through it — the issue half hard-coded
    /// its branch and its PR flag until 2026-09-27, so a plain directory could not run
    /// an issue task at all.
    private func dropUnswitchableBranch(ofTask taskID: String) {
        guard !env.canSwitchBranches, let existing = board.autoQueueID(forTask: taskID),
              board.queue(existing)?.branch != nil else { return }
        updateQueue(existing, branch: .some(nil))
        env.log("tasks: " + taskID + "'s queue no longer switches branches — this workspace is not a git repository")
    }

    /// 处理 one MANUAL task on its own: the same single-task queue shape as an
    /// issue task — one branch, one PR (决策 5, applied to manual work). 全部处理
    /// uses this so a batch never bundles unrelated changes onto one branch.
    @discardableResult
    func startManualTask(_ taskID: String) -> String? {
        guard let task = board.task(taskID), task.source == .manual else { return nil }
        dropUnswitchableBranch(ofTask: taskID)
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
        case .startingPR, .openingPR:
            // The PR session is already publishing this queue: there is no task to
            // cancel (stop that session in dsh if it is going the wrong way).
            return .finishing
        case .idle:
            return .idle
        }
    }
}
