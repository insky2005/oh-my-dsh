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
    /// The workspace's default integration mode (the tasks-panel setting), used for a
    /// queue that has no per-queue override.
    var defaultIntegration: QueueIntegration = .pr
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
    /// The text handed to the agent. `brief` is the 交接简报 for a task that has
    /// work in front of it in its queue (nil when there is nothing to hand over).
    var promptText: (_ task: TaskItem, _ queue: TaskQueue?, _ brief: String?) -> String
    /// The agent's LAST text message of a session — its final report — or nil.
    /// BLOCKING (it reads a session log through the shell's core bridge), so the
    /// runner only calls it inside its background step.
    var sessionReport: (_ sessionId: String) -> String? = { _ in nil }
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
        var commits: [String]
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
            for commit in brief.commits { lines.append("  " + commit) }
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
        "**必须**在结束时汇报：改了什么、怎么验证的、结果如何（没做完或失败也要说清楚，不要沉默收尾）——这段文字会写回任务卡片，队列里后面的任务也会看到它；"

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
                      brief: String? = nil, shape: TaskRepoShape = .github) -> String {
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
        let list = requirements(branch: branch, queueName: queueName, base: base, shape: shape)
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
                             shape: TaskRepoShape) -> [String] {
        var requirements: [String] = []
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
        // 要求与 issue 任务**完全共用**（TaskPrompts.requirements）：两种来源的提示词
        // 只有头不同，规则必须一模一样 —— 各写一份的那段历史，正是 issue 任务被留在
        // 「会 push、PR 由面板开」的旧政策里的原因。
        lines.append("")
        lines.append("要求：")
        let list = requirements(branch: branch, queueName: queueName, base: base, shape: shape)
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
        // 要发布的就是那个队列的那条分支，抬头与字段一致，两边读起来是一回事。
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
        lines.append("5. 这个会话不要改任何代码：只做发布；")
        lines.append("6. **必须**在最后一行给出 PR 的完整链接（https://github.com/<owner>/<repo>/pull/<编号>）；真开不出来就说清楚卡在哪一步（权限 / 网络 / token / 分支状态），不要沉默收尾。")
        return lines.joined(separator: "\n")
    }

    /// 收尾会话的提示词：队列干完的活**怎么落地**。三种模式由队列 / 全局默认选择，
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
            text = "队列「\(queueName ?? branch ?? "")」的工作流是「无」——不需要任何收尾动作。"
        }
        // A reused ORIGINATING session is a real conversation: require this marker so
        // the shell adopts only OUR turn's report.
        guard let marker = marker else { return text }
        return text + "\n\n最后**单独一行**原样输出完成标记（供壳层确认本次收尾结束）：" + marker
    }

    /// 本地合并进 base（有远端才推送）。冲突尽量现场解；超出确定范围就停下请用户介入；
    /// base 被保护时如实报错（用户自己处理，比如改仓库设置或改用 PR）。
    /// hasRemote == false：只做本地合并，明确不推送——本地仓库也能收尾。
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
                lines.append("   失败：\(task.error ?? "失败")")
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

    private struct Active {
        var taskID: String
        var queueID: String?
        var branch: String?
        var sessionId: String
        var startedAt: Date
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
        case failed(TaskFailure, String?)
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
            _ = renameSession(sessionId, TasksRunner.taskSessionTitlePrefix + title)
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
            // The stored 汇报 first: the runner writes it back when a task ends (so it
            // survives a deleted session), and only a task that ended before that
            // existed has to be read out of the session log again.
            return TaskPrompts.QueueBrief.Earlier(title: task.title, state: task.state,
                                                  errorKey: task.error,
                                                  report: task.report ?? task.sessionId.flatMap { sessionReport($0) })
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
        // The queue's PR is opened once, when its LAST task finishes: every task in a
        // queue shares one branch, and GitHub allows one open PR per head.
        let queueHasMore = queue?.taskIds.contains { id in
            id != active.taskID && (board.task(id)?.state == .queued || board.task(id)?.state == .running)
        } ?? false
        // LANDING POLICY: a task session ONLY COMMITS. Pushing / merging / opening a
        // PR is a job of its own, done by a dedicated 收尾会话 once the queue is done
        // (startQueueIntegration) — which is why nothing here asks the agent to push,
        // checks whether it did, or talks to the GitHub API at all.
        // 工作流「无」= 明确不收尾，所以即使 autoPR 开着也不起收尾会话。
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

        phase = .finishing(taskID)
        var outcome: FinishOutcome = .done
        var report: String? = nil
        env.perform({
            // The 汇报 is read HERE, while the session still exists, and written back
            // onto the task: the card shows it, and the next task of the queue gets it
            // as its 前置汇报 even if this session is deleted tomorrow.
            report = sessionReport(active.sessionId)
        }, {
            self.applyFinish(taskID: taskID, outcome: outcome, now: now, report: report,
                             finalizeQueueID: wantsFinalize ? queue?.id : nil)
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
        let mode = board.integration(forQueue: queueID, default: env.defaultIntegration)
        // 「无」是明确的选择，不是失败：什么都不做，也不在队列上记错误。
        if mode == .none {
            env.log("tasks: queue " + queueID + " 的工作流是「无」——不收尾")
            return false
        }
        // Mode-specific requirements: refuse with a reason on the queue rather than
        // starting a session that cannot succeed.
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
            // 「直接推送」必须有地方可推；merge 是本地操作，没远端就只合并、不推送。
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
        // The session that created this queue (nil for a manually created queue).
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
                                originSession: String? = nil) -> PRRun? {
        // What the branch carries, for the session context: it still reads the diff
        // itself (that is the point), but the commit list saves it from starting with
        // 「what is this branch」.
        let commits = branch.flatMap { _ in env.git.commits(base: base) } ?? []
        let hasRemote = env.git.remoteName() != nil
        // Prefer the queue's ORIGINATING session (user 2026-10-01): the queue was
        // created there and its completion is reported there, so finalize in the same
        // conversation. A unique MARKER is required back, because that session is a
        // real conversation — its last report may be an unrelated turn.
        if let origin = originSession, !origin.isEmpty {
            let marker = TasksRunner.makeMarker()
            let text = TaskPrompts.integration(mode: mode, queueName: name, branch: branch,
                                               base: base, commits: commits, hasRemote: hasRemote,
                                               marker: marker)
            if env.promptSession(origin, text) {
                return PRRun(queueID: queueID, mode: mode, branch: branch ?? base, base: base,
                             sessionId: origin, startedAt: Date(), marker: marker, reused: true)
            }
            env.log("tasks: could not prompt the originating session " + origin
                    + " — falling back to a fresh finalize session")
        }
        let text = TaskPrompts.integration(mode: mode, queueName: name, branch: branch, base: base,
                                           commits: commits, hasRemote: hasRemote)
        guard let sessionId = env.createSession(env.repoRoot) else { return nil }
        let sessionNameKey = mode == .pr ? "tasks.queue.prSessionName" : "tasks.queue.finalizeSessionName"
        _ = env.renameSession(sessionId, L10n.tr(sessionNameKey, name))
        guard env.promptSession(sessionId, text) else {
            _ = env.cancelSession(sessionId)
            return nil
        }
        return PRRun(queueID: queueID, mode: mode, branch: branch ?? base, base: base,
                     sessionId: sessionId, startedAt: Date(), marker: nil, reused: false)
    }

    /// A marker the finalize session must echo back verbatim on its own last line.
    static func makeMarker() -> String {
        "DSH-FINALIZE-" + UUID().uuidString.prefix(8).uppercased()
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
        let findExistingPR = env.findExistingPR
        let sessionReport = env.sessionReport
        var prUrl: String?
        var report: String?
        env.perform({
            report = sessionReport(run.sessionId)
            prUrl = TasksRunner.prURL(in: report) ?? findExistingPR(run.branch)
        }, {
            // A reused ORIGINATING session only counts when OUR turn's marker came
            // back: its last report may otherwise belong to the user's conversation.
            if let marker = run.marker, report?.contains(marker) != true {
                self.prLookupInFlight = false
                return
            }
            self.applyPRRun(run, prUrl: prUrl, report: report)
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
        let env = self.env
        phase = .startingPR(queueID)
        var fresh: PRRun?
        env.perform({
            fresh = TasksRunner.makeFinalizeRun(env: env, queueID: queueID, mode: mode,
                                                name: name, branch: branch, base: base,
                                                originSession: nil)
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

    private func applyPRRun(_ run: PRRun, prUrl: String?, report: String?) {
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
        if run.mode == .pr {
            if let prUrl = prUrl {
                _ = updateQueue(run.queueID, prUrl: prUrl)
                _ = board.setQueuePRError(run.queueID, nil)
                env.log("tasks: queue " + run.queueID + " has its PR: " + prUrl)
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
        }
        persist()
        _ = pump()
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
                     integration: QueueIntegration? = nil) -> TaskQueue {
        let queue = board.createQueue(name: name, branch: branch, baseBranch: baseBranch,
                                      autoPR: autoPR, integration: integration)
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
                     integration: QueueIntegration?? = nil) -> Bool {
        guard let qi = board.index(ofQueue: queueID) else { return false }
        if let name = name { board.queues[qi].name = name }
        if let branch = branch { board.queues[qi].branch = branch }
        if let baseBranch = baseBranch { board.queues[qi].baseBranch = baseBranch }
        if let autoPR = autoPR { board.queues[qi].autoPR = autoPR }
        if let prUrl = prUrl { board.queues[qi].prUrl = prUrl }
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
    func startIssueTask(_ taskID: String) -> String? {
        guard let task = board.task(taskID), task.source == .github else { return nil }
        dropUnswitchableBranch(ofTask: taskID)
        return startStandaloneTask(task, queue: {
            TaskQueue.auto(for: task,
                           baseBranch: env.defaultBaseBranch,
                           switchesBranch: env.canSwitchBranches,
                           opensPR: env.canOpenPR())
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
