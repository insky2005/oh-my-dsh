import Foundation

// MARK: - Failure reasons

/// Why a task failed. The raw value IS the L10n key stored in the board and
/// shown on the card (the panel renders L10n.tr(error)), so a missing entry
/// surfaces in tests/l10n rather than on screen.
///
/// It lives here with the board that persists it: the VIEW layer needs one of
/// these keys too — a card whose task failed with .notGitRepo offers
/// 「不切分支并重试」 and must recognize the failure without the runner
/// (TasksUI.swift).
enum TaskFailure: String {
    case interrupted = "tasks.errInterrupted"
    /// The task's session disappeared from dsh (deleted in the sidebar, or the
    /// server was restarted) — nobody can say what became of the work.
    case sessionGone = "tasks.errSessionGone"
    case notGitRepo = "tasks.errNotGit"
    case dirtyWorktree = "tasks.errDirtyTree"
    /// 多仓库预检：目标仓库的工作区不干净（design §5.2）。detail 带上仓库 id。
    case repoDirty = "tasks.errRepoDirty"
    /// 多仓库预检：目标仓库的基线分支解析不出来（本地与远端追踪都没有）。
    case repoNoBase = "tasks.errRepoNoBase"
    /// 多仓库进入分支：前面的仓库已经切好，某个仓库失败（不回滚）。
    case repoBranch = "tasks.errRepoBranch"
    case checkout = "tasks.errBranch"
    case pull = "tasks.errPull"
    case session = "tasks.errSession"
    case prompt = "tasks.errPrompt"
    case timeout = "tasks.errTimeout"
    case noPush = "tasks.errNoPush"
    /// 会话结束了，但本次尝试的完成 marker 没有回显：无法证明任务真的做完（断网导致
    /// 的 turn 结束与正常结束在 dsh 列表里长得一样）。P1 先以「失败 + 待确认」落地，
    /// P2 会把它换成独立的 needsReview 状态。
    case unverified = "tasks.errUnverified"
}

// MARK: - Source & state

/// Where a task came from — drives the source badge on a task card
/// (Issue #12 vs 手动).
enum TaskSource: String {
    case github
    case manual
}

/// One task's lifecycle.
///
/// v2 adds queued (a task waiting for its serial slot inside a queue);
/// pending therefore means "not in any queue" and is never started
/// implicitly. The remaining cases keep v1's raw values, so an existing
/// index.json needs no migration.
enum TaskState: String {
    case pending
    case queued
    case running
    case done
    case failed
    case cancelled
    case closed

    var isFinished: Bool {
        switch self {
        case .done, .failed, .cancelled, .closed: return true
        case .pending, .queued, .running: return false
        }
    }

    /// May be put into a queue (again).
    var isQueueable: Bool {
        switch self {
        case .pending, .failed, .cancelled: return true
        case .queued, .running, .done, .closed: return false
        }
    }

    /// Can this task still be edited or deleted from its card?
    ///
    /// The user's rule (2026-09-27): **a finished task is a record, not a todo** — its
    /// 编辑 / 删除 buttons are gone. Running belongs to the agent, so it is out too; what
    /// is left is exactly the states that may still run (or run again): 未入队 / 队列中 /
    /// 失败 / 已取消 —— where fixing the wording before a retry is the whole point of
    /// having an edit button.
    var isEditable: Bool {
        switch self {
        case .pending, .queued, .failed, .cancelled: return true
        case .running, .done, .closed: return false
        }
    }

    /// One-glyph badge for the compact list (the cards get colored labels).
    var badge: String {
        switch self {
        case .pending: return "·"
        case .queued: return "≡"
        case .running: return "…"
        case .done: return "✓"
        case .failed: return "✗"
        case .cancelled: return "−"
        case .closed: return "☑"
        }
    }
}

/// A queue's own state.
///
/// - draft: created but never started — the 等待态 a session-created queue sits in
///   until the user (or the originating session) says 启动队列;
/// - active: runs its tasks one at a time;
/// - paused: was started and stopped (a task failed, it was cancelled, or the app
///   restarted) — the user CONTINUES rather than starts;
/// - done: every current task finished. **Not a record**: the lane is still open —
///   appending a task moves it back to .draft (and re-arms the completion report),
///   and 交付/关闭 stay available;
/// - closed: the user's MANUAL terminal state. The lane keeps its record (tasks,
///   branch, PR) but accepts nothing more: no start, no append, no publish.
///
/// draft is deliberately NOT paused: 「从未启动」与「启动过但停了」是两种状态、两种
/// 动作（开始 vs 继续），而完成回传只挂在 done 上。
enum QueueState: String {
    case draft
    case active
    case paused
    case done
    case closed
}

// MARK: - Task

/// One task — a GitHub issue or a locally created manual task.
///
/// The dsh session id is NOT part of the task's own record: a session only
/// exists on the machine that created it, so it lives in local.json
/// (TaskLocalState.sessions), exactly like v1's issue to session overlay.
struct TaskItem: Equatable {
    var id: String
    var source: TaskSource
    var number: Int?
    var title: String
    var body: String?
    var labels: [String]
    var state: TaskState
    var queueId: String?
    var branch: String?
    var prUrl: String?
    var sessionId: String?
    var error: String?
    /// 失败时补充给用户的细节（多仓库失败点名具体仓库，见 design §5.2）。它跟着
    /// `error` 一起持久化，卡片渲染为 `L10n.tr(error, errorDetail)`；nil = 今天的
    /// 单值错误文案。
    var errorDetail: String?
    var startedAt: Date?
    var finishedAt: Date?
    /// What the agent said when it finished — its 汇报, written back onto the task by
    /// the runner (see TasksRunner.finish) instead of living only inside the session
    /// log. The card shows it, and the next task of the queue receives it as its
    /// 前置汇报 (so the hand-over survives a deleted session).
    ///
    /// Machine-scoped like sessionId (a report is the last text of a session that
    /// exists only on this machine): it belongs to local.json, never to manual.json /
    /// index.json — the committed index keeps its v1 shape and stays shareable.
    var report: String?
    /// 本次尝试的完成 marker（runner 生成、写进提示词，会话须在最后一行回显）。它只
    /// 进 local.json / 内存，绝不进 index.json / manual.json：机器私有，且重启恢复后
    /// 据此判断这次尝试是否已被校验过（见 markerVerified）。
    var completionMarker: String?
    /// 本次尝试的 marker 是否已经校验通过（会话最后一行回显了它）。只有通过才判
    /// done；否则进入「待确认」（P1 先以 failed + unverified 落地）。
    var markerVerified: Bool

    init(id: String,
         source: TaskSource,
         number: Int? = nil,
         title: String,
         body: String? = nil,
         labels: [String] = [],
         state: TaskState = .pending,
         queueId: String? = nil,
         branch: String? = nil,
         prUrl: String? = nil,
         sessionId: String? = nil,
         error: String? = nil,
         errorDetail: String? = nil,
         startedAt: Date? = nil,
         finishedAt: Date? = nil,
         report: String? = nil,
         completionMarker: String? = nil,
         markerVerified: Bool = false) {
        self.id = id
        self.source = source
        self.number = number
        self.title = title
        self.body = body
        self.labels = labels
        self.state = state
        self.queueId = queueId
        self.branch = branch
        self.prUrl = prUrl
        self.sessionId = sessionId
        self.error = error
        self.errorDetail = errorDetail
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.report = report
        self.completionMarker = completionMarker
        self.markerVerified = markerVerified
    }

    /// ISO-8601 in the exact shape v1 wrote (2026-08-20T15:26:43Z).
    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: ids

    static func githubID(_ number: Int) -> String { "issue-\(number)" }

    static func manualID(_ token: String) -> String { "manual-\(token)" }

    /// A fresh manual id: manual- followed by 8 lowercase hex characters.
    static func newManualID() -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return manualID(String(token).lowercased())
    }

    /// "issue-12" -> (.github, 12); "manual-ab12cd34" -> (.manual, nil).
    static func parse(id: String) -> (source: TaskSource, number: Int?)? {
        if id.hasPrefix("issue-"), let n = Int(id.dropFirst("issue-".count)) { return (.github, n) }
        if id.hasPrefix("manual-") { return (.manual, nil) }
        return nil
    }

    // MARK: factories

    static func github(number: Int, title: String, body: String? = nil, labels: [String] = []) -> TaskItem {
        TaskItem(id: githubID(number), source: .github, number: number,
                 title: title, body: body, labels: labels)
    }

    static func manual(title: String, body: String? = nil, id: String = TaskItem.newManualID()) -> TaskItem {
        TaskItem(id: id, source: .manual, title: title, body: body)
    }

    // MARK: persistence

    /// manual.json entry (machine-scoped). The session id is deliberately
    /// absent — it lives in local.json.
    func manualDictionary() -> [String: Any] {
        var d: [String: Any] = ["id": id, "title": title, "state": state.rawValue, "source": source.rawValue]
        if let body = body { d["body"] = body }
        if let queueId = queueId { d["queueId"] = queueId }
        if let branch = branch { d["branch"] = branch }
        if let prUrl = prUrl { d["prUrl"] = prUrl }
        if let error = error { d["error"] = error }
        if let errorDetail = errorDetail { d["errorDetail"] = errorDetail }
        if let startedAt = startedAt { d["startedAt"] = TaskItem.iso8601.string(from: startedAt) }
        if let finishedAt = finishedAt { d["finishedAt"] = TaskItem.iso8601.string(from: finishedAt) }
        return d
    }

    static func fromManual(_ d: [String: Any]) -> TaskItem? {
        guard let id = d["id"] as? String, id.hasPrefix("manual-") else { return nil }
        return TaskItem(id: id,
                        source: .manual,
                        number: nil,
                        title: (d["title"] as? String) ?? id,
                        body: d["body"] as? String,
                        labels: [],
                        state: TaskState(rawValue: (d["state"] as? String) ?? "pending") ?? .pending,
                        queueId: d["queueId"] as? String,
                        branch: d["branch"] as? String,
                        prUrl: d["prUrl"] as? String,
                        sessionId: nil,
                        error: d["error"] as? String,
                        errorDetail: d["errorDetail"] as? String,
                        startedAt: (d["startedAt"] as? String).flatMap { TaskItem.iso8601.date(from: $0) },
                        finishedAt: (d["finishedAt"] as? String).flatMap { TaskItem.iso8601.date(from: $0) })
    }

    /// index.json entry — the v1 committed shape (keyed by issue number), so
    /// existing files, teammates and external tools keep working unchanged.
    /// body is written as NSNull when absent, which v1 used as "already looked
    /// up, nothing there" (only the single-issue endpoint can fill it later).
    func indexDictionary() -> [String: Any] {
        var d: [String: Any] = [
            "issue": number ?? 0,
            "source": source.rawValue,
            "title": title,
            "state": state.rawValue,
            "labels": labels,
        ]
        if let body = body { d["body"] = body } else { d["body"] = NSNull() }
        if let branch = branch { d["branch"] = branch }
        if let prUrl = prUrl { d["prUrl"] = prUrl }
        if let error = error { d["error"] = error }
        if let errorDetail = errorDetail { d["errorDetail"] = errorDetail }
        if let startedAt = startedAt { d["startedAt"] = TaskItem.iso8601.string(from: startedAt) }
        if let finishedAt = finishedAt { d["finishedAt"] = TaskItem.iso8601.string(from: finishedAt) }
        return d
    }

    static func fromIndex(_ d: [String: Any]) -> TaskItem? {
        guard let number = d["issue"] as? Int else { return nil }
        return TaskItem(id: githubID(number),
                        source: .github,
                        number: number,
                        title: (d["title"] as? String) ?? "issue #\(number)",
                        body: d["body"] as? String,
                        labels: (d["labels"] as? [String]) ?? [],
                        state: TaskState(rawValue: (d["state"] as? String) ?? "pending") ?? .pending,
                        queueId: nil,
                        branch: d["branch"] as? String,
                        prUrl: d["prUrl"] as? String,
                        sessionId: nil,
                        error: d["error"] as? String,
                        errorDetail: d["errorDetail"] as? String,
                        startedAt: (d["startedAt"] as? String).flatMap { TaskItem.iso8601.date(from: $0) },
                        finishedAt: (d["finishedAt"] as? String).flatMap { TaskItem.iso8601.date(from: $0) })
    }
}

// MARK: - Branch naming

/// Branch names — one place, shared by the panel, the runner and the tests.
enum TaskBranch {

    /// Lower-cased, ASCII letters/digits only, every other run collapsed into a
    /// single dash, trimmed, at most 40 characters. A name without any ASCII
    /// letter or digit at all (a pure Chinese queue name) yields an empty
    /// string, and the caller falls back to the queue id.
    static func slug(_ name: String) -> String {
        var out = ""
        for ch in name.lowercased() {
            let keep = ch.isASCII && (ch.isLetter || ch.isNumber)
            if keep {
                out.append(ch)
            } else if !out.isEmpty && !out.hasSuffix("-") {
                out.append("-")
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        var trimmed = String(out.prefix(40))
        while trimmed.hasSuffix("-") { trimmed.removeLast() }
        return trimmed
    }

    /// feature/ plus the name's slug; when the name has no usable slug at all
    /// the default falls back to the queue id (feature/queue-7f3a) instead of an
    /// empty branch name. Never returns an empty string.
    static func defaultBranch(queueName: String, queueID: String) -> String {
        let s = slug(queueName)
        if s.isEmpty { return "feature/queue-" + String(queueID.suffix(4)) }
        return "feature/" + s
    }

    /// The branch a queue should be based on — what the repo itself says, rather
    /// than an assumed "main".
    ///
    /// A repo whose default branch is `master` (or `develop`) used to fail its
    /// very first issue task: the pipeline starts with `git checkout main`
    /// (TasksRunner.enter) and stops there with 「切换分支失败」.
    ///
    /// The caller digs the facts out of git; the decision chain lives here so it
    /// can be asserted without a repo:
    ///   1. the remote's HEAD (`origin/main` → `main`),
    ///   2. a local `main`,
    ///   3. a local `master`,
    ///   4. whatever is checked out right now,
    ///   5. "main" (nothing could be learned).
    static func defaultBaseBranch(symbolicRef: String?, current: String?,
                                  hasMain: Bool, hasMaster: Bool) -> String {
        if let ref = symbolicRef?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty {
            // "origin/main" / "refs/remotes/origin/main" → the branch name.
            // "origin/HEAD" is an UNRESOLVED symref (dangling): it says nothing
            // about a branch name, so the chain keeps looking.
            if let slash = ref.lastIndex(of: "/") {
                let tail = String(ref[ref.index(after: slash)...])
                if !tail.isEmpty, tail != "HEAD" { return tail }
            } else if ref != "HEAD" {
                return ref
            }
        }
        if hasMain { return "main" }
        if hasMaster { return "master" }
        if let current = current?.trimmingCharacters(in: .whitespacesAndNewlines),
           !current.isEmpty, current != "HEAD" {
            return current
        }
        return "main"
    }

    /// v1 rule kept intact (docs/process/git-workflow.md): feature-class issues get
    /// feature/issue-N, everything else fix/issue-N.
    static func issueBranch(number: Int, labels: [String]) -> String {
        let lowered = labels.map { $0.lowercased() }
        let isFeature = lowered.contains { $0.contains("feature") || $0.contains("enhancement") }
        return isFeature ? "feature/issue-\(number)" : "fix/issue-\(number)"
    }
}

// MARK: - Workspace repositories (multi-repo workspace)

/// A GitHub remote, split into the two halves every GitHub API call needs.
struct GitHubRepo: Equatable {
    var owner: String
    var name: String
}

/// One directory inside a workspace that can be used as a git target.
struct WorkspaceRepo: Equatable {
    /// Workspace-relative path; "." is the root itself. Stable id for persistence.
    var id: String
    var absolutePath: String
    var isGit: Bool
    /// This repo's own default branch (main / master differ per repo).
    var defaultBase: String = "main"
    /// Preferred push remote (github > origin > first), or nil for a local-only repo.
    var remoteName: String?
    /// Set when a github.com remote exists.
    var github: GitHubRepo?
    /// "." → the root directory's last path component; otherwise the relative path.
    var displayName: String
}

/// How a workspace's repository layout is classified — the compatibility matrix of
/// docs/design/panels/multi-repo-workspace-design.md §4.3.
enum WorkspaceRepoMode: Equatable {
    /// No repository at all — today's 非 Git 目录.
    case plain
    /// Root is a repository and no participating child repo exists — today's shape.
    case single
    /// Anything else with at least one repository (root + children, or children only).
    /// One child repo is already multi: adding/removing a repo never flips the paradigm.
    case multi
}

/// The repositories a workspace contains. Pure value type; detection reads the
/// outside world through an injectable `WorkspaceRepoProbe`.
struct WorkspaceRepoSet: Equatable {
    var repos: [WorkspaceRepo] = []
    /// The user's explicit pick when it still exists, else root, else the first
    /// GitHub repo, else the first git repo, else nil.
    var primary: WorkspaceRepo?

    var gitRepos: [WorkspaceRepo] { repos.filter(\.isGit) }
    var gitAvailable: Bool { !gitRepos.isEmpty }
    /// Any repo can open a PR (issue-area availability).
    var prAvailable: Bool { repos.contains { $0.github != nil } }
    /// Whether EVERY target repo can open a PR (the PR delivery mode).
    func allCanOpenPR(_ targets: [WorkspaceRepo]) -> Bool {
        !targets.isEmpty && targets.allSatisfy { $0.github != nil }
    }

    /// Only「root is a repo and no participating child」is the legacy single-repo
    /// shape; everything else with a repo is multi, even a lone child repo.
    var mode: WorkspaceRepoMode {
        if repos.isEmpty { return .plain }
        if repos.count == 1, repos[0].id == "." { return .single }
        return .multi
    }

    var isSingleRepo: Bool { mode == .single }
    var isMultiRepo: Bool { mode == .multi }
}

/// The outside-world facts `WorkspaceRepoSet.detect` needs, injected so a test can
/// describe a directory tree without running git. The filesystem defaults are real;
/// the git answers default to "nothing is a repository", so a test overrides only
/// what it cares about. `.live` is the real thing (Process + the real .gitmodules).
struct WorkspaceRepoProbe {
    var isDirectory: (String) -> Bool
    var directoryEntries: (String) -> [String]
    var hasGitEntry: (String) -> Bool
    /// True only when the directory is itself a work-tree top level (not a subdir).
    var isGitRepoRoot: (String) -> Bool
    /// Submodule paths declared by the root .gitmodules (workspace-relative).
    var submodulePaths: (String) -> [String]
    var defaultBase: (String) -> String
    var remoteName: (String) -> String?
    var github: (String) -> GitHubRepo?

    init(isDirectory: @escaping (String) -> Bool = { path in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
            return isDir.boolValue
        },
        directoryEntries: @escaping (String) -> [String] = { path in
            (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        },
        hasGitEntry: @escaping (String) -> Bool = { path in
            FileManager.default.fileExists(atPath: path + "/.git")
        },
        isGitRepoRoot: @escaping (String) -> Bool = { _ in false },
        submodulePaths: @escaping (String) -> [String] = { root in
            guard let text = try? String(contentsOfFile: root + "/.gitmodules", encoding: .utf8) else { return [] }
            return WorkspaceRepoProbe.parseGitmodules(text)
        },
        defaultBase: @escaping (String) -> String = { _ in "main" },
        remoteName: @escaping (String) -> String? = { _ in nil },
        github: @escaping (String) -> GitHubRepo? = { _ in nil }) {
        self.isDirectory = isDirectory
        self.directoryEntries = directoryEntries
        self.hasGitEntry = hasGitEntry
        self.isGitRepoRoot = isGitRepoRoot
        self.submodulePaths = submodulePaths
        self.defaultBase = defaultBase
        self.remoteName = remoteName
        self.github = github
    }

    /// The real probe: git through `/usr/bin/git`, the tree through FileManager.
    /// Everything here is BLOCKING, so callers run detection on a background queue.
    static let live = WorkspaceRepoProbe(
        isGitRepoRoot: { path in
            guard runGit(path, ["rev-parse", "--is-inside-work-tree"]) == "true",
                  let top = runGit(path, ["rev-parse", "--show-toplevel"]) else { return false }
            return (top as NSString).standardizingPath == (path as NSString).standardizingPath
        },
        submodulePaths: { root in
            guard let text = try? String(contentsOfFile: root + "/.gitmodules", encoding: .utf8) else { return [] }
            return parseGitmodules(text)
        },
        defaultBase: { path in
            let remote = pushRemoteName(path)
            let remoteHead = remote.flatMap { name in
                runGit(path, ["symbolic-ref", "--short", "refs/remotes/\(name)/HEAD"])
            }
            let current = runGit(path, ["rev-parse", "--abbrev-ref", "HEAD"])
            let hasMain = runGit(path, ["rev-parse", "--verify", "--quiet", "main"]) != nil
            let hasMaster = runGit(path, ["rev-parse", "--verify", "--quiet", "master"]) != nil
            return TaskBranch.defaultBaseBranch(symbolicRef: remoteHead, current: current,
                                                hasMain: hasMain, hasMaster: hasMaster)
        },
        remoteName: { path in pushRemoteName(path) },
        github: { path in
            guard let out = runGit(path, ["remote", "-v"]) else { return nil }
            return githubRepo(fromRemotes: parseGitRemotes(out))
        })

    /// The `path = …` lines of a .gitmodules file, in order.
    static func parseGitmodules(_ text: String) -> [String] {
        var paths: [String] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            guard trimmed[..<eq].trimmingCharacters(in: .whitespaces) == "path" else { continue }
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { paths.append(value) }
        }
        return paths
    }

    /// `git remote -v` → one (name, url) per remote, first line wins.
    static func parseGitRemotes(_ output: String) -> [(name: String, url: String)] {
        var seen: Set<String> = []
        var remotes: [(name: String, url: String)] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let name = String(parts[0])
            guard !seen.contains(name) else { continue }
            seen.insert(name)
            remotes.append((name, String(parts[1])))
        }
        return remotes
    }

    /// The github.com remote, preferring the one literally named "github".
    static func githubRepo(fromRemotes remotes: [(name: String, url: String)]) -> GitHubRepo? {
        let url = remotes.first { $0.name == "github" && $0.url.contains("github.com") }?.url
            ?? remotes.first { $0.url.contains("github.com") }?.url
        guard let url = url,
              let range = url.range(of: "github.com[/:]", options: .regularExpression) else { return nil }
        let tail = String(url[range.upperBound...])
        let parts = tail.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        let owner = String(parts[0])
        let name = String(parts[1]).replacingOccurrences(of: ".git", with: "")
        guard !owner.isEmpty, !name.isEmpty else { return nil }
        return GitHubRepo(owner: owner, name: name)
    }

    /// The remote used to push: "github", else "origin", else the first one.
    static func pushRemoteName(_ path: String) -> String? {
        guard let out = runGit(path, ["remote"]) else { return nil }
        let names = out.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        if names.contains("github") { return "github" }
        if names.contains("origin") { return "origin" }
        return names.first
    }

    /// git with these arguments in `path`; nil when it fails or cannot launch.
    static func runGit(_ path: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", path] + args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension WorkspaceRepoSet {

    /// Directories never scanned for repositories: heavy build leaves (the hidden
    /// ones are already covered by the dot rule, but the list documents intent).
    static let excludedDirectoryNames: Set<String> = ["node_modules", ".build", ".cache", "dist"]

    /// Detect the workspace's repositories (design §4.1): the root when it IS a
    /// work-tree top level (id "."), plus every direct child directory carrying a
    /// .git entry, minus hidden / excluded directories and the root .
    /// gitmodules submodules. `primaryRepoID` is the user's
    /// `tasksPrimaryRepoByWorkspace` pick; a stale one falls back to the auto rule.
    static func detect(root: String,
                       primaryRepoID: String? = nil,
                       probe: WorkspaceRepoProbe = .live) -> WorkspaceRepoSet {
        var repos: [WorkspaceRepo] = []
        if probe.isGitRepoRoot(root) {
            repos.append(makeRepo(id: ".", path: root, root: root, probe: probe))
        }
        let submodules = Set(probe.submodulePaths(root))
        for name in probe.directoryEntries(root).sorted() {
            guard !name.hasPrefix("."), !excludedDirectoryNames.contains(name) else { continue }
            let path = root + "/" + name
            guard probe.isDirectory(path) else { continue }
            // A submodule is managed by the parent repo: not an independent target.
            let isSubmodule = submodules.contains(name)
                || submodules.contains { $0.hasPrefix(name + "/") }
            guard !isSubmodule, probe.hasGitEntry(path) else { continue }
            repos.append(makeRepo(id: name, path: path, root: root, probe: probe))
        }
        return WorkspaceRepoSet(repos: repos, primary: resolvePrimary(repos, specifiedID: primaryRepoID))
    }

    /// User pick (when it still exists) → root → first GitHub repo → first git repo.
    static func resolvePrimary(_ repos: [WorkspaceRepo], specifiedID: String?) -> WorkspaceRepo? {
        if let id = specifiedID, let picked = repos.first(where: { $0.id == id }) { return picked }
        if let root = repos.first(where: { $0.id == "." }) { return root }
        if let github = repos.first(where: { $0.github != nil }) { return github }
        return repos.first(where: { $0.isGit })
    }

    private static func makeRepo(id: String, path: String, root: String,
                                 probe: WorkspaceRepoProbe) -> WorkspaceRepo {
        WorkspaceRepo(id: id,
                      absolutePath: path,
                      isGit: true,
                      defaultBase: probe.defaultBase(path),
                      remoteName: probe.remoteName(path),
                      github: probe.github(path),
                      displayName: id == "." ? (root as NSString).lastPathComponent : id)
    }
}

// MARK: - Manual task draft

/// What the user typed in 新建任务 — ONE box (2026-09-26): the first line is the
/// title, every line after it is the description, and a single line is BOTH. The
/// queue is still chosen later, from the card, so creating a task never forces a
/// decision about branches or PRs.
struct TaskDraft: Equatable {
    var title: String
    var body: String

    init(title: String = "", body: String = "") {
        self.title = title
        self.body = body
    }

    var normalizedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalizedBody: String { body.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// What actually gets stored: a draft that carries no description of its own
    /// keeps the TITLE as its description too — a one-line task hands the agent
    /// that line, and the line is also what names the card and the session.
    var effectiveBody: String { normalizedBody.isEmpty ? normalizedTitle : normalizedBody }

    var isValid: Bool { problem == nil }

    /// The first problem as an L10n key, or nil when the draft is fine. Only the
    /// TITLE is required now: the description can always fall back to it (see
    /// effectiveBody), so a single line is a complete task.
    var problem: String? { normalizedTitle.isEmpty ? "tasks.errName" : nil }

    /// The composer's ONE box, split into the two things a task is made of:
    /// first line = title, the lines after it = description.
    static func composed(from content: String) -> TaskDraft {
        let lines = content.components(separatedBy: .newlines)
        let title = (lines.first ?? "").trimmingCharacters(in: .whitespaces)
        let rest = lines.dropFirst().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 只有一行（或其余行都是空白）时，这一行同时作为标题与描述。
        return TaskDraft(title: title, body: rest.isEmpty ? title : rest)
    }

    /// The inverse of composed(from:), for prefilling that box while editing: a
    /// task whose description IS its title goes back to a single line instead of
    /// showing the same sentence twice.
    static func combined(title: String, body: String?) -> String {
        let raw = body ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return title }
        if trimmed == title.trimmingCharacters(in: .whitespacesAndNewlines) { return title }
        return title + "\n" + raw
    }
}

/// One entry of the 加入队列 ▾ picker.
struct QueueChoice: Equatable {
    var id: String
    var name: String
    var branch: String?
    var taskCount: Int
    var state: QueueState
}

// MARK: - Queue

/// How a queue's finished work LANDS. Chosen per queue, or by the workspace default
/// in the tasks-panel settings; always performed by the delivery session (never by
/// the shell directly — pushing / merging needs credentials and judgement).
enum QueueIntegration: String, CaseIterable {
    /// Push the queue's branch and open/update its pull request; review and merge
    /// happen outside the shell.
    case pr
    /// Merge the queue's branch into its base locally, then push the base branch.
    case merge
    /// Push the current branch itself (develop-on-main workflows).
    case push
    /// 不交付：队列跑完就结束，代码留在原地，由用户自己处理。非 git 目录的默认，
    /// 也是「别让它自动碰远端」的明确选择。
    case none

    /// The mode a workspace like this usually wants — a UI RECOMMENDATION, never
    /// enforced: a GitHub remote points at review (pr); another git repo at a LOCAL
    /// merge (no remote required — the merge happens in the worktree and the push is
    /// best-effort); a plain directory has nothing to publish at all → none.
    static func recommended(isGit: Bool, hasGitHubRemote: Bool) -> QueueIntegration {
        if hasGitHubRemote { return .pr }
        if isGit { return .merge }
        return .none
    }

    /// Whether this workflow can actually run in a workspace with these capabilities.
    /// It mirrors the runner's own refusals (TasksRunner.startQueueIntegration): PR
    /// needs a GitHub remote, merge needs a repository (it merges locally, so no
    /// remote is required), push needs a remote to push to, and 无 always works.
    /// The pickers grey out the modes that cannot run instead of letting the user
    /// choose a guaranteed failure.
    static func available(_ mode: QueueIntegration, isGit: Bool, hasGitHubRemote: Bool,
                          hasRemote: Bool) -> Bool {
        switch mode {
        case .none: return true
        case .pr: return hasGitHubRemote
        case .merge: return isGit
        case .push: return isGit && hasRemote
        }
    }

    func isAvailable(isGit: Bool, hasGitHubRemote: Bool, hasRemote: Bool) -> Bool {
        Self.available(self, isGit: isGit, hasGitHubRemote: hasGitHubRemote, hasRemote: hasRemote)
    }

    // MARK: - 多仓库：按仓库能力降级（design §7.2）

    /// 该仓库对某个 intent 能否**原生**做到。
    /// PR 需要 GitHub 远端；push 需要远端；本地合并只需要是 git 仓库；
    /// 「无」永远成立。
    static func supports(_ mode: QueueIntegration, repo: WorkspaceRepo, hasRemote: Bool) -> Bool {
        switch mode {
        case .none: return true
        case .pr: return repo.github != nil
        case .merge: return repo.isGit
        case .push: return repo.isGit && hasRemote
        }
    }

    /// 按仓库能力降级：PR → 推送 → 本地合并 → 不做。混合能力的工作区不再整体
    /// 拒绝 —— 每个仓库落到自己能做的那一档，交付结果也按仓库分别记录。
    static func effective(_ intent: QueueIntegration, repo: WorkspaceRepo, hasRemote: Bool) -> QueueIntegration {
        if supports(intent, repo: repo, hasRemote: hasRemote) { return intent }
        switch intent {
        case .pr: return hasRemote ? .push : (repo.isGit ? .merge : .none)
        case .push: return repo.isGit ? .merge : .none
        case .merge: return .none
        case .none: return .none
        }
    }

    /// 选项可用性：只要「有一个」目标能原生做到就可选（单仓库时即今天的可用性）。
    static func available(_ intent: QueueIntegration, targets: [WorkspaceRepo],
                          hasRemote: (WorkspaceRepo) -> Bool) -> Bool {
        guard !targets.isEmpty else { return intent == .none }
        return intent == .none || targets.contains { supports(intent, repo: $0, hasRemote: hasRemote($0)) }
    }

    /// 队列级覆盖未设置时，每个目标仓库用它自己的按仓库默认值作为 intent
    /// （design §7.2/§8.1）：intent(repo) = queue.integration ?? perRepoDefault(repo)。
    static func intent(queueOverride: QueueIntegration?, perRepoDefault: QueueIntegration) -> QueueIntegration {
        queueOverride ?? perRepoDefault
    }
}

/// 一个目标仓库在一次交付里走到了哪一步（design §7.1）。
enum RepoRunStatus: String {
    case pending
    case running
    case done
    case failed
    case skipped
}

/// 一个队列对**一个**目标仓库的交付记录（design §7.1）。各仓库独立处理：
/// 某个失败不丢弃已成功的仓库，卡片按仓库逐行展示结果。
struct QueueRepoRun: Equatable {
    /// WorkspaceRepo.id（相对工作区根的路径，"." = 工作区根）。
    var repoID: String
    var branch: String
    var base: String
    /// 队列对该仓库的**意图**（= 队列级交付模式，或该仓库的按仓库默认值）。
    var intent: QueueIntegration
    /// 按该仓库能力降级后的**实际动作**。
    var effective: QueueIntegration
    var status: RepoRunStatus
    var prUrl: String?
    /// 失败原因或成功摘要（L10n 键或纯文本）。
    var note: String?

    init(repoID: String, branch: String = "", base: String = "main",
         intent: QueueIntegration = .none, effective: QueueIntegration = .none,
         status: RepoRunStatus = .pending, prUrl: String? = nil, note: String? = nil) {
        self.repoID = repoID
        self.branch = branch
        self.base = base
        self.intent = intent
        self.effective = effective
        self.status = status
        self.prUrl = prUrl
        self.note = note
    }

    func dictionary() -> [String: Any] {
        var d: [String: Any] = [
            "repoID": repoID,
            "branch": branch,
            "base": base,
            "intent": intent.rawValue,
            "effective": effective.rawValue,
            "status": status.rawValue,
        ]
        if let prUrl = prUrl { d["prUrl"] = prUrl }
        if let note = note { d["note"] = note }
        return d
    }

    static func from(_ d: [String: Any]) -> QueueRepoRun? {
        guard let repoID = d["repoID"] as? String else { return nil }
        return QueueRepoRun(
            repoID: repoID,
            branch: (d["branch"] as? String) ?? "",
            base: (d["base"] as? String) ?? "main",
            intent: (d["intent"] as? String).flatMap { QueueIntegration(rawValue: $0) } ?? .none,
            effective: (d["effective"] as? String).flatMap { QueueIntegration(rawValue: $0) } ?? .none,
            status: (d["status"] as? String).flatMap { RepoRunStatus(rawValue: $0) } ?? .pending,
            prUrl: d["prUrl"] as? String,
            note: d["note"] as? String)
    }
}

/// A queue is a lane: every task in it shares ONE branch and runs strictly in
/// order, so a later task sees the earlier task's commits.
struct TaskQueue: Equatable {
    var id: String
    var name: String
    /// The branch every task of this queue works on. nil = do not switch
    /// branches at all (run on whatever is checked out).
    var branch: String?
    var baseBranch: String
    var taskIds: [String]
    var state: QueueState
    /// true for the single-task queue the panel creates for an ISSUE task
    /// (rendered compactly, but counted like any other queue).
    var autoCreated: Bool
    /// Whether the queue opens a PR once it is finished. Requires a GitHub
    /// workspace; false everywhere else (an internal repo has no PR to open).
    var autoPR: Bool
    var prUrl: String?
    /// Why the PR session did not produce a PR (an L10n key), or nil. The queue keeps
    /// its 已完成 state — a PR that could not be opened is not failed work — but the
    /// reason is shown instead of silently disappearing into the log.
    var prError: String?
    /// 本队列的目标仓库（WorkspaceRepo.id 列表；"." = 工作区根）。nil / 空 =
    /// 默认主仓库 primary（design §7.1 / §5.2）。P2 用它做「按仓库预检 + 切分支」，
    /// 交付阶段（P3）在此基础上按仓库记录 repoRuns。
    var repos: [String]?
    /// 每个目标仓库的交付结果（design §7.1/§7.3，各仓库独立处理）。旧数据没有这个
    /// 键时为空数组 = 旧行为。
    var repoRuns: [QueueRepoRun]
    /// Per-queue override of the workspace's integration default; nil = follow the
    /// tasks-panel setting.
    var integration: QueueIntegration?
    /// The last finalize session's result shown on the card: its report's first line
    /// on success, the failure reason otherwise. nil = never finalized.
    var integrationNote: String?
    var createdAt: Date?

    init(id: String,
         name: String,
         branch: String? = nil,
         baseBranch: String = "main",
         taskIds: [String] = [],
         state: QueueState = .paused,
         autoCreated: Bool = false,
         autoPR: Bool = false,
         prUrl: String? = nil,
         prError: String? = nil,
         repos: [String]? = nil,
         repoRuns: [QueueRepoRun] = [],
         integration: QueueIntegration? = nil,
         integrationNote: String? = nil,
         createdAt: Date? = nil) {
        self.id = id
        self.name = name
        self.branch = branch
        self.baseBranch = baseBranch
        self.taskIds = taskIds
        self.state = state
        self.autoCreated = autoCreated
        self.autoPR = autoPR
        self.prUrl = prUrl
        self.prError = prError
        self.repos = repos
        self.repoRuns = repoRuns
        self.integration = integration
        self.integrationNote = integrationNote
        self.createdAt = createdAt
    }

    static func newID() -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return "q-" + String(token).lowercased()
    }

    /// The single-task queue an issue task runs in (decision 5): created on
    /// 处理, reused on retry, so v1's one-issue-one-branch-one-PR rule — and its
    /// fix/issue-N naming — survive untouched.
    ///
    /// It starts with NO tasks: the task joins through TaskBoard.enqueue, the one
    /// place that owns membership (and writes the task's queueId). Pre-loading the
    /// id here AS WELL made every issue task show up twice in its own lane
    /// (taskIds = ["issue-7","issue-7"] → two identical cards, progress 0/2, and
    /// 「队列内 2 个任务」 in the delete dialog).
    /// The single-task queue an ISSUE task runs in when 处理 is clicked. Its shape is
    /// the manual one (2026-09-27): one task, its own branch, its own PR — **unless the
    /// workspace says otherwise**. `switchesBranch` / `opensPR` come from the runner's
    /// env (is this a git repository? does it have a GitHub remote?), exactly like
    /// auto(forManual:): handing a branch to a queue in a plain directory is how every
    /// task there failed with tasks.errNotGit — and issue tasks were no exception,
    /// because this factory used to hard-code both flags.
    static func auto(for task: TaskItem,
                     baseBranch: String = "main",
                     switchesBranch: Bool = true,
                     opensPR: Bool = true,
                     repos: [String]? = nil) -> TaskQueue {
        let number = task.number ?? 0
        return TaskQueue(id: TaskQueue.newID(),
                         name: "Issue #\(number)",
                         branch: switchesBranch
                             ? TaskBranch.issueBranch(number: number, labels: task.labels)
                             : nil,
                         baseBranch: baseBranch,
                         taskIds: [],
                         state: .draft,
                         autoCreated: true,
                         autoPR: opensPR,
                         prUrl: nil,
                         repos: repos,
                         createdAt: Date())
    }

    /// The single-task queue a MANUAL task runs in when 全部处理 is asked to run it
    /// on its own: one task, its own branch, its own PR — the same shape an issue
    /// task gets (决策 5), so batching manual work can never silently bundle
    /// unrelated changes onto one branch.
    ///
    /// The branch follows the task's title (`feature/<slug>`), falling back to
    /// `feature/manual-<id4>` when the title has no ASCII slug at all — **unless the
    /// workspace cannot switch branches at all** (`switchesBranch: false`, i.e. the
    /// directory is not a git repository): then the queue has NO branch, exactly like
    /// a queue created from the form there (§V2-7). Handing such a queue a branch is
    /// how 全部处理 made every task fail with tasks.errNotGit.
    ///
    /// Like the issue queue it starts EMPTY: one writer owns membership (enqueue).
    static func auto(forManual task: TaskItem,
                     baseBranch: String = "main",
                     switchesBranch: Bool = true,
                     opensPR: Bool = true) -> TaskQueue {
        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = TaskBranch.slug(title)
        let derived = slug.isEmpty ? "feature/manual-" + String(task.id.suffix(4)) : "feature/" + slug
        let branch: String? = switchesBranch ? derived : nil
        return TaskQueue(id: TaskQueue.newID(),
                         name: title,
                         branch: branch,
                         baseBranch: baseBranch,
                         taskIds: [],
                         state: .draft,
                         autoCreated: true,
                         autoPR: opensPR,
                         prUrl: nil,
                         createdAt: Date())
    }

    /// Queues newest-first for DISPLAY: the lane just created is at the top. A
    /// queue without a stamp (written before createdAt existed) sorts last; equal
    /// stamps keep their existing order (stable by index). Storage order is never
    /// changed — this is only what the panel and the picker render.
    static func newestFirst(_ queues: [TaskQueue]) -> [TaskQueue] {
        queues.enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element.createdAt ?? .distantPast
                let right = rhs.element.createdAt ?? .distantPast
                if left != right { return left > right }
                return lhs.offset < rhs.offset
            }
            .map { $0.element }
    }

    /// 1-based position inside the queue, nil when the task is not in it.
    func order(of taskID: String) -> Int? {
        guard let i = taskIds.firstIndex(of: taskID) else { return nil }
        return i + 1
    }

    func dictionary() -> [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "name": name,
            "baseBranch": baseBranch,
            "taskIds": taskIds,
            "state": state.rawValue,
            "autoCreated": autoCreated,
            "autoPR": autoPR,
        ]
        if let branch = branch { d["branch"] = branch }
        if let prUrl = prUrl { d["prUrl"] = prUrl }
        if let prError = prError { d["prError"] = prError }
        if let repos = repos { d["repos"] = repos }
        if !repoRuns.isEmpty { d["repoRuns"] = repoRuns.map { $0.dictionary() } }
        if let integration = integration { d["integration"] = integration.rawValue }
        if let integrationNote = integrationNote { d["integrationNote"] = integrationNote }
        if let createdAt = createdAt { d["createdAt"] = TaskItem.iso8601.string(from: createdAt) }
        return d
    }

    static func from(_ d: [String: Any]) -> TaskQueue? {
        guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
        return TaskQueue(id: id,
                         name: name,
                         branch: d["branch"] as? String,
                         baseBranch: (d["baseBranch"] as? String) ?? "main",
                         taskIds: (d["taskIds"] as? [String]) ?? [],
                         state: QueueState(rawValue: (d["state"] as? String) ?? "paused") ?? .paused,
                         autoCreated: (d["autoCreated"] as? Bool) ?? false,
                         autoPR: (d["autoPR"] as? Bool) ?? false,
                         prUrl: d["prUrl"] as? String,
                         prError: d["prError"] as? String,
                         repos: d["repos"] as? [String],
                         repoRuns: (d["repoRuns"] as? [[String: Any]])?.compactMap { QueueRepoRun.from($0) } ?? [],
                         integration: (d["integration"] as? String).flatMap { QueueIntegration(rawValue: $0) },
                         integrationNote: d["integrationNote"] as? String,
                         createdAt: (d["createdAt"] as? String).flatMap { TaskItem.iso8601.date(from: $0) })
    }
}

// MARK: - Machine-scoped overlay (local.json)

/// The part of the board that belongs to THIS machine: the dsh session each
/// task was run in, plus the queue the user last worked on.
struct TaskLocalState: Equatable {
    /// task id -> dsh sessionId.
    var sessions: [String: String] = [:]
    /// task id -> ISO-8601 stamp of the last write for that session, kept so
    /// rewriting the file does not invent new timestamps for old sessions.
    var sessionUpdatedAt: [String: String] = [:]
    /// task id -> the agent's 汇报, written back when the task finished (see
    /// TaskItem.report). Machine-scoped: it is the last text of a local session.
    var reports: [String: String] = [:]
    var activeQueueID: String?
    var runningTaskID: String?
    /// queue id -> the dsh session that CREATED it (the task-todo skill passes its
    /// $DSH_SESSION_ID). Machine-scoped like `sessions` — the session exists only on
    /// this machine — and the queue's completion report is sent back to it.
    var queueSessions: [String: String] = [:]
    /// queue id -> ISO-8601 stamp of the completion report already sent. Keeps the
    /// report idempotent and lets a restart pick up one the app never got to send.
    var queueNotified: [String: String] = [:]
    /// task id -> 本次尝试的完成 marker（P1 完成校验）。机器私有，只进 local.json；
    /// 会话日志与卡片正文都不该出现它。
    var taskMarkers: [String: String] = [:]
    /// task id -> 该 marker 是否已校验通过。重启恢复后据此判断，无需重新问会话。
    var taskMarkerVerified: [String: Bool] = [:]

    /// v1 keyed sessions by ISSUE NUMBER ("6"); v2 keys them by task id
    /// ("issue-6"). Reading accepts both and rewrites nothing on load.
    static func taskID(fromStoredKey key: String) -> String {
        let digits = CharacterSet(charactersIn: "0123456789")
        if !key.isEmpty, key.rangeOfCharacter(from: digits.inverted) == nil {
            return TaskItem.githubID(Int(key) ?? 0)
        }
        return key
    }

    static func from(_ d: [String: Any]) -> TaskLocalState {
        var s = TaskLocalState()
        if let raw = d["sessions"] as? [String: Any] {
            for (key, value) in raw {
                guard let entry = value as? [String: Any],
                      let sessionId = entry["sessionId"] as? String else { continue }
                let id = taskID(fromStoredKey: key)
                s.sessions[id] = sessionId
                if let updatedAt = entry["updatedAt"] as? String { s.sessionUpdatedAt[id] = updatedAt }
            }
        }
        if let raw = d["reports"] as? [String: String] {
            for (key, text) in raw where !text.isEmpty { s.reports[taskID(fromStoredKey: key)] = text }
        }
        s.activeQueueID = d["activeQueueId"] as? String
        s.runningTaskID = d["runningTaskId"] as? String
        if let raw = d["queueSessions"] as? [String: String] { s.queueSessions = raw }
        if let raw = d["queueNotified"] as? [String: String] { s.queueNotified = raw }
        if let raw = d["taskMarkers"] as? [String: String] {
            for (key, text) in raw where !text.isEmpty { s.taskMarkers[taskID(fromStoredKey: key)] = text }
        }
        if let raw = d["taskMarkerVerified"] as? [String: Any] {
            for (key, value) in raw {
                if let verified = value as? Bool { s.taskMarkerVerified[taskID(fromStoredKey: key)] = verified }
            }
        }
        return s
    }

    func dictionary() -> [String: Any] {
        var out: [String: Any] = [:]
        for (id, sessionId) in sessions {
            out[id] = [
                "sessionId": sessionId,
                "updatedAt": sessionUpdatedAt[id] ?? TaskItem.iso8601.string(from: Date()),
            ]
        }
        var d: [String: Any] = ["sessions": out]
        if !reports.isEmpty { d["reports"] = reports }
        if !queueSessions.isEmpty { d["queueSessions"] = queueSessions }
        if !queueNotified.isEmpty { d["queueNotified"] = queueNotified }
        if !taskMarkers.isEmpty { d["taskMarkers"] = taskMarkers }
        if !taskMarkerVerified.isEmpty { d["taskMarkerVerified"] = taskMarkerVerified }
        if let activeQueueID = activeQueueID { d["activeQueueId"] = activeQueueID }
        if let runningTaskID = runningTaskID { d["runningTaskId"] = runningTaskID }
        return d
    }
}

// MARK: - Board

/// Tasks plus queues plus the machine overlay, with every rule the panel and
/// the runner share. Pure value type: no timers, no I/O, no AppKit — the runner
/// (step 3) and the UI (step 6) only call into this.
struct TaskBoard {
    var tasks: [TaskItem] = []
    var queues: [TaskQueue] = []
    var local = TaskLocalState()

    // MARK: lookups

    func task(_ id: String) -> TaskItem? { tasks.first { $0.id == id } }

    func queue(_ id: String) -> TaskQueue? { queues.first { $0.id == id } }

    func index(ofTask id: String) -> Int? { tasks.firstIndex { $0.id == id } }

    func index(ofQueue id: String) -> Int? { queues.firstIndex { $0.id == id } }

    /// Tasks that are in no queue at all — the 未入队 area.
    var unqueued: [TaskItem] { tasks.filter { $0.queueId == nil && $0.state != .running } }

    func tasks(inQueue queueID: String) -> [TaskItem] {
        guard let queue = queue(queueID) else { return [] }
        return queue.taskIds.compactMap { task($0) }
    }

    /// The auto (issue-task) queue a task already runs in, if any.
    func autoQueueID(forTask taskID: String) -> String? {
        queues.first { $0.autoCreated && $0.taskIds.contains(taskID) }?.id
    }

    /// The queues offered by 加入队列 ▾. User queues only: an issue task's auto
    /// single-task queue is never a destination for a manual task.
    func queueChoices() -> [QueueChoice] {
        // Closed lanes are terminal: they must not be offered as an append target.
        // Newest-first, so the lane the user just created is the first row.
        TaskQueue.newestFirst(queues.filter { !$0.autoCreated && $0.state != .closed }).map { queue in
            QueueChoice(id: queue.id, name: queue.name, branch: queue.branch,
                        taskCount: queue.taskIds.count, state: queue.state)
        }
    }

    /// Counts for the summary strip: queues, queued, running, failed.
    /// Every queue counts, auto ones included (decision 8).
    /// Counters for the summary card. `source` narrows them to the tasks the list
    /// is currently showing (nil = everything): a filtered list whose header still
    /// counts the hidden half reads as a bug.
    func summary(source: TaskSource? = nil) -> (queues: Int, queued: Int, running: Int, failed: Int) {
        let source = source
        let shown = source.map { wanted in tasks.filter { $0.source == wanted } } ?? tasks
        let shownIDs = Set(shown.map { $0.id })
        // A queue counts when it holds at least one of the shown tasks: the issue
        // task's auto queue disappears with the 手动 filter, exactly like its lane.
        let shownQueues = source == nil ? queues.count
            : queues.filter { queue in queue.taskIds.contains { shownIDs.contains($0) } }.count
        return (shownQueues,
                shown.filter { $0.state == .queued }.count,
                shown.filter { $0.state == .running }.count,
                shown.filter { $0.state == .failed }.count)
    }

    // MARK: queue membership

    /// Append a task to a queue (FIFO). Moving a task that already sits in a
    /// different queue moves it out first. Idempotent for the same queue.
    @discardableResult
    mutating func enqueue(taskID: String, into queueID: String) -> Bool {
        guard let ti = index(ofTask: taskID) else { return false }
        guard let qi = index(ofQueue: queueID), queues[qi].state != .closed else { return false }
        guard tasks[ti].state.isQueueable else { return false }
        if tasks[ti].queueId == queueID { return false }
        if tasks[ti].queueId != nil { _ = dequeue(taskID: taskID) }
        tasks[ti].state = .queued
        tasks[ti].queueId = queueID
        // One id per queue, ever: the lane renders from taskIds, so a duplicate
        // would draw the same card twice (and inflate progress and every count
        // derived from it).
        if !queues[qi].taskIds.contains(taskID) { queues[qi].taskIds.append(taskID) }
        // 追加到已完成的队列：它回到「待启动」的活泳道（用户再启动），并重臂完成
        // 回传 —— 否则第二轮完成会被 queueNotified 当成「已回传过」而跳过。
        // .paused 保持暂停（有失败要处理，不能被追加悄悄复活）。
        if queues[qi].state == .done {
            queues[qi].state = .draft
            local.queueNotified[queueID] = nil
        }
        return true
    }

    /// Take a task out of its queue while it is still waiting — it returns to
    /// the 未入队 area. A running task cannot be dequeued (that is 取消).
    @discardableResult
    mutating func dequeue(taskID: String) -> Bool {
        guard let ti = index(ofTask: taskID), let queueID = tasks[ti].queueId,
              let qi = index(ofQueue: queueID), tasks[ti].state == .queued else { return false }
        queues[qi].taskIds.removeAll { $0 == taskID }
        tasks[ti].queueId = nil
        tasks[ti].state = .pending
        // 分支是队列的属性：离开队列就不再属于它。留着会让人以为这个任务还会跑在
        // 那条分支上（而且它会被当成「这个任务要用的分支」传给下一个队列/提示词）。
        tasks[ti].branch = nil
        return true
    }

    /// Remove a task from every queue regardless of its state — used when the
    /// task itself is deleted. A waiting task goes back to 未入队.
    mutating func detach(taskID: String) {
        for i in queues.indices { queues[i].taskIds.removeAll { $0 == taskID } }
        guard let ti = index(ofTask: taskID) else { return }
        tasks[ti].queueId = nil
        tasks[ti].branch = nil
        if tasks[ti].state == .queued { tasks[ti].state = .pending }
    }

    /// Delete a queue. Tasks that never started go back to 未入队; finished ones
    /// keep their record but lose the membership. Refused while one of its tasks
    /// is running (cancel it first).
    @discardableResult
    mutating func removeQueue(_ queueID: String) -> Bool {
        guard let qi = index(ofQueue: queueID) else { return false }
        let ids = queues[qi].taskIds
        if ids.contains(where: { task($0)?.state == .running }) { return false }
        for id in ids {
            guard let ti = index(ofTask: id) else { continue }
            tasks[ti].queueId = nil
            if tasks[ti].state == .queued { tasks[ti].state = .pending }
            // Same rule as 移出队列: the branch belonged to the queue.
            tasks[ti].branch = nil
        }
        queues.remove(at: qi)
        if local.activeQueueID == queueID { local.activeQueueID = nil }
        return true
    }

    /// Close a queue: the user's MANUAL terminal state. It keeps its record (tasks,
    /// branch, PR) but accepts nothing more — no start, no append, no publish.
    /// Refused while one of its tasks is running, exactly like removeQueue.
    @discardableResult
    mutating func closeQueue(_ queueID: String) -> Bool {
        guard let qi = index(ofQueue: queueID), queues[qi].state != .closed else { return false }
        if queues[qi].taskIds.contains(where: { task($0)?.state == .running }) { return false }
        queues[qi].state = .closed
        if local.activeQueueID == queueID { local.activeQueueID = nil }
        return true
    }

    /// The integration mode a queue should use: its own override, else the workspace
    /// default the caller passes down (the tasks-panel setting).
    func integration(forQueue queueID: String, default fallback: QueueIntegration) -> QueueIntegration {
        queue(queueID)?.integration ?? fallback
    }

    /// Create a user queue. A nil branch derives the default from the name; an
    /// explicit empty string means "do not switch branches at all".
    @discardableResult
    mutating func createQueue(name: String,
                              branch: String? = nil,
                              baseBranch: String = "main",
                              autoPR: Bool = false,
                              autoCreated: Bool = false,
                              repos: [String]? = nil,
                              integration: QueueIntegration? = nil) -> TaskQueue {
        let queueID = TaskQueue.newID()
        let resolved: String?
        if let branch = branch {
            resolved = branch.isEmpty ? nil : branch
        } else {
            resolved = TaskBranch.defaultBranch(queueName: name, queueID: queueID)
        }
        let queue = TaskQueue(id: queueID, name: name, branch: resolved, baseBranch: baseBranch,
                              taskIds: [], state: .draft, autoCreated: autoCreated,
                              autoPR: autoPR, prUrl: nil, repos: repos,
                              integration: integration, createdAt: Date())
        queues.append(queue)
        return queue
    }

    /// The queue the runner works on: the selected one while it is active, else
    /// the first active queue (covers a restart that did not persist the id).
    func activeQueue() -> TaskQueue? {
        if let id = local.activeQueueID, let q = queue(id), q.state == .active { return q }
        return queues.first { $0.state == .active }
    }

    /// The task the runner should start now, or nil. Serial by construction:
    /// while ANY task runs nothing else may start, and only the active queue
    /// contributes. Failed/cancelled/done entries are skipped rather than
    /// blocking the queue (that is what 跳过并继续 means).
    func nextStartable() -> String? {
        if local.runningTaskID != nil { return nil }
        if tasks.contains(where: { $0.state == .running }) { return nil }
        // The queue the user last pointed the runner at wins…
        if let queue = activeQueue(), let id = firstQueued(in: queue) { return id }
        // …but when it has nothing left to start, ANY other active queue with a
        // queued task does. Without this the runner stalled: 全部处理 makes one
        // single-task queue per task, and once the current one emptied, the runner
        // sat there while other lanes showed 活跃 and never moved.
        for queue in queues where queue.state == .active {
            if let id = firstQueued(in: queue) { return id }
        }
        return nil
    }

    /// The first task of a queue that is waiting for its turn.
    private func firstQueued(in queue: TaskQueue) -> String? {
        queue.taskIds.first { task($0)?.state == .queued }
    }

    /// 1-based position of a task inside its queue.
    func order(of taskID: String) -> Int? {
        guard let queueID = task(taskID)?.queueId, let queue = queue(queueID) else { return nil }
        return queue.order(of: taskID)
    }

    // MARK: transitions

    /// Start a task: it becomes the one running task and its queue becomes the
    /// active one. The queue's branch is authoritative, so it is copied onto the
    /// task for display and traceability.
    mutating func markRunning(_ taskID: String, at date: Date = Date()) {
        guard let i = index(ofTask: taskID) else { return }
        tasks[i].state = .running
        tasks[i].startedAt = date
        tasks[i].error = nil
        tasks[i].errorDetail = nil
        if let queueID = tasks[i].queueId, let qi = index(ofQueue: queueID) {
            queues[qi].state = .active
            local.activeQueueID = queueID
            // A new run invalidates the previous finalize result shown on the card —
            // both the success summary and the publish-failure reason.
            queues[qi].integrationNote = nil
            queues[qi].prError = nil
            queues[qi].repoRuns = []
            if let branch = queues[qi].branch { tasks[i].branch = branch }
        }
        local.runningTaskID = taskID
    }

    mutating func markDone(_ taskID: String, prUrl: String? = nil, report: String? = nil,
                           at date: Date = Date()) {
        guard let i = index(ofTask: taskID) else { return }
        tasks[i].state = .done
        tasks[i].finishedAt = date
        if let prUrl = prUrl { tasks[i].prUrl = prUrl }
        recordReport(taskID, report)
        local.runningTaskID = nil
        refreshQueueCompletion()
    }

    /// Write the agent's 汇报 back onto the task (card + local.json), so it is not
    /// locked inside a session log that may be deleted tomorrow. An empty report is
    /// not a report: nothing is written, and a previous one stays.
    mutating func recordReport(_ taskID: String, _ report: String?) {
        guard let text = report?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let i = index(ofTask: taskID) else { return }
        tasks[i].report = text
        local.reports[taskID] = text
    }

    /// 记录本次尝试的完成 marker（runner 在任务启动时调用，随提示词注入）。重试会
    /// 覆盖它：marker 属于「这一次尝试」，不是任务的永久属性。只落 local.json。
    mutating func recordAttemptMarker(_ taskID: String, _ marker: String) {
        guard let i = index(ofTask: taskID) else { return }
        tasks[i].completionMarker = marker
        tasks[i].markerVerified = false
        local.taskMarkers[taskID] = marker
        local.taskMarkerVerified[taskID] = false
    }

    /// 标记本次尝试的 marker 是否通过校验（会话最后一行是否回显了它）。
    mutating func recordMarkerVerified(_ taskID: String, _ verified: Bool) {
        guard let i = index(ofTask: taskID) else { return }
        tasks[i].markerVerified = verified
        local.taskMarkerVerified[taskID] = verified
    }

    /// Fail a task. A queue containing it is PAUSED and its id returned: inside
    /// a queue every task shares one branch, so running the next one would build
    /// on half-finished work. The user then chooses 重试 or 跳过并继续.
    @discardableResult
    mutating func markFailed(_ taskID: String, error: String, report: String? = nil,
                             errorDetail: String? = nil,
                             at date: Date = Date()) -> String? {
        guard let i = index(ofTask: taskID) else { return nil }
        tasks[i].state = .failed
        tasks[i].error = error
        tasks[i].errorDetail = errorDetail
        tasks[i].finishedAt = date
        // A failed run's last words matter MORE than a successful one's: they say how
        // far it got (the next task in the queue receives them as its 前置汇报).
        recordReport(taskID, report)
        local.runningTaskID = nil
        return pauseQueue(containing: tasks[i])
    }

    /// Cancel a task (user-initiated). Cancelling frees the serial slot without
    /// marking the task done, so its queue is paused exactly like a failure.
    @discardableResult
    mutating func markCancelled(_ taskID: String, at date: Date = Date()) -> String? {
        guard let i = index(ofTask: taskID) else { return nil }
        tasks[i].state = .cancelled
        tasks[i].finishedAt = date
        local.runningTaskID = nil
        return pauseQueue(containing: tasks[i])
    }

    /// Close a GitHub task (its issue was closed) — only meaningful for issue
    /// tasks; the record is kept for traceability.
    mutating func markClosed(_ taskID: String) {
        guard let i = index(ofTask: taskID) else { return }
        tasks[i].state = .closed
    }

    /// Record why a queue PR session produced no PR (an L10n key), or clear it once
    /// one did. The queue keeps its own state: a PR that could not be opened is not
    /// failed work, but the reason belongs on the card rather than only in app.log.
    /// Record the last finalize session's result (its report first line / failure).
    /// Shown on the queue card; a new run clears it (see markRunning).
    @discardableResult
    mutating func setQueueIntegrationNote(_ queueID: String, _ note: String?) -> Bool {
        guard let i = index(ofQueue: queueID) else { return false }
        queues[i].integrationNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return true
    }

    /// 逐仓库记录本次交付的结果（design §7.1/§7.3）。一个仓库失败不影响其他仓库。
    @discardableResult
    mutating func setQueueRepoRuns(_ queueID: String, _ runs: [QueueRepoRun]) -> Bool {
        guard let i = index(ofQueue: queueID) else { return false }
        queues[i].repoRuns = runs
        return true
    }

    @discardableResult
    mutating func setQueuePRError(_ queueID: String, _ key: String?) -> Bool {
        guard let i = index(ofQueue: queueID) else { return false }
        queues[i].prError = key
        if key != nil { queues[i].prUrl = nil }
        return true
    }

    /// Retry a failed/cancelled task and resume its queue (the card's 重试).
    /// A task with no queue simply returns to 未入队.
    @discardableResult
    mutating func retryAndResume(_ taskID: String) -> Bool {
        guard let i = index(ofTask: taskID), tasks[i].state.isQueueable else { return false }
        tasks[i].error = nil
        tasks[i].errorDetail = nil
        tasks[i].finishedAt = nil
        // The old report described the run being retried: it must not be handed to the
        // next task in the queue as if it were this run's outcome.
        tasks[i].report = nil
        local.reports[taskID] = nil
        // The next attempt gets a fresh marker: the old one must never confirm it.
        tasks[i].completionMarker = nil
        tasks[i].markerVerified = false
        local.taskMarkers[taskID] = nil
        local.taskMarkerVerified[taskID] = nil
        if let queueID = tasks[i].queueId, let qi = index(ofQueue: queueID) {
            tasks[i].state = .queued
            queues[qi].state = .active
            local.activeQueueID = queueID
        } else {
            tasks[i].state = .pending
        }
        return true
    }

    /// Resume a paused queue without retrying anything (跳过并继续): the runner
    /// walks past the failed entry and takes the next queued task.
    @discardableResult
    mutating func resumeQueue(_ queueID: String) -> Bool {
        guard let qi = index(ofQueue: queueID), queues[qi].state != .closed else { return false }
        queues[qi].state = .active
        local.activeQueueID = queueID
        return true
    }

    @discardableResult
    mutating func pauseQueue(_ queueID: String) -> Bool {
        guard let qi = index(ofQueue: queueID) else { return false }
        queues[qi].state = .paused
        return true
    }

    /// Mark a queue done when it has no queued/running task left.
    mutating func refreshQueueCompletion() {
        for i in queues.indices {
            let open = queues[i].taskIds.contains { id in
                guard let state = task(id)?.state else { return false }
                return state == .queued || state == .running
            }
            if !open && !queues[i].taskIds.isEmpty
                && queues[i].state != .done && queues[i].state != .closed {
                queues[i].state = .done
            }
        }
    }

    /// Pause the queue a task belongs to (only while it is active). Returns the
    /// paused queue's id.
    private mutating func pauseQueue(containing task: TaskItem) -> String? {
        guard let queueID = task.queueId, let qi = index(ofQueue: queueID),
              queues[qi].state == .active else { return nil }
        queues[qi].state = .paused
        return queueID
    }

    // MARK: repair / restart

    /// The queue's taskIds is the source of truth for membership; the per-task
    /// queueId is a denormalized copy. Re-derive it after loading so the two can
    /// never drift apart (and a task listed in a queue but still pending becomes
    /// queued again).
    mutating func reindexQueueMembership() {
        // A duplicated id draws TWO cards in one lane, so the list is cleaned while
        // it is read: every board written before that rule existed (each issue
        // task's auto queue had its id added twice) repairs itself on the next
        // load instead of needing a migration.
        for qi in queues.indices {
            var seen = Set<String>()
            queues[qi].taskIds = queues[qi].taskIds.filter { seen.insert($0).inserted }
        }
        for i in tasks.indices { tasks[i].queueId = nil }
        for queue in queues {
            for id in queue.taskIds {
                guard let ti = index(ofTask: id) else { continue }
                tasks[ti].queueId = queue.id
                if tasks[ti].state == .pending { tasks[ti].state = .queued }
            }
        }
    }

    /// Attach the machine-scoped half of a loaded board: the dsh session each task
    /// ran in, and the 汇报 each one left behind.
    mutating func attachSessions(_ sessions: [String: String], reports: [String: String] = [:],
                                 markers: [String: String] = [:],
                                 markerVerified: [String: Bool] = [:]) {
        for i in tasks.indices {
            if let sessionId = sessions[tasks[i].id] { tasks[i].sessionId = sessionId }
            if let report = reports[tasks[i].id] { tasks[i].report = report }
            if let marker = markers[tasks[i].id] { tasks[i].completionMarker = marker }
            if let verified = markerVerified[tasks[i].id] { tasks[i].markerVerified = verified }
        }
    }

    /// Bring a board loaded from disk in line with reality after a restart: a
    /// task recorded as running cannot still be running (its dsh session died
    /// with the app), and a queue recorded as active is paused so that nothing
    /// starts before the user says so.
    @discardableResult
    mutating func reconcileAfterRestart(interruptedError: String) -> (interrupted: [String], pausedQueues: [String]) {
        var interrupted: [String] = []
        for i in tasks.indices where tasks[i].state == .running {
            tasks[i].state = .failed
            tasks[i].error = interruptedError
            interrupted.append(tasks[i].id)
        }
        var paused: [String] = []
        for i in queues.indices where queues[i].state == .active {
            queues[i].state = .paused
            paused.append(queues[i].id)
        }
        local.runningTaskID = nil
        return (interrupted, paused)
    }
}

// MARK: - Per-repo panel settings (design §8.1)

/// 面板设置的「按仓库」存储与解析链（多仓库工作区）。
///
/// 四张映射与 ShellConfig 的键一一对应，IssueRunnerPanel 只做
/// [String: Any] ⇄ 类型化字典的转换；这里是纯值类型，所以 model-tests 能直接驱动
/// 「写入 / 旧值回退 / 跟随主仓库 / 独立存储」而不需要真的配置文件。
///
/// 两层并存是刻意为之：
///   - 旧的**按工作区**值（tasksIntegrationByWorkspace /
///     tasksAutoCloseOnPublishByWorkspace）仍是主仓库的兜底，既有安装无需迁移；
///   - 新的**按仓库**值**只在显式设置时写入** —— 缺失 = 「跟随主仓库」。
struct RepoSettings: Equatable {

    // 旧的按工作区值（兼容既有数据）。
    var integrationByWorkspace: [String: String] = [:]
    var autoCloseByWorkspace: [String: Bool] = [:]

    // 新的按仓库值。缺失 = 跟随主仓库，不存任何默认值。
    var integrationByRepo: [String: String] = [:]
    var autoCloseByRepo: [String: Bool] = [:]

    // 工作区 → 用户指定的主仓库 repoID。
    var primaryByWorkspace: [String: String] = [:]

    // 工作区 → issue 归属仓库 repoID（design §9）。缺失 = 跟随主仓库；用户切换后
    // 才写入，此后即为显式指定，不再跟随。
    var issueRepoByWorkspace: [String: String] = [:]

    /// 路径 → repoID 的分隔符：换行不会出现在文件路径或 repoID 里，两半永不混淆。
    static let keySeparator = "\n"

    /// 与 IssueRunnerPanel.workspaceSettingsKey 同一套规范化：尾斜杠 / .. 不会
    /// 造出第二个键。
    static func workspaceKey(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        if standardized.count > 1, standardized.hasSuffix("/") {
            return String(standardized.dropLast())
        }
        return standardized
    }

    static func scopedKey(path: String, repoID: String) -> String {
        workspaceKey(path) + keySeparator + repoID
    }

    // MARK: - 显式读取

    /// 该仓库是否自己显式存过值。nil = 没存 = 跟随主仓库。
    func explicitIntegration(forWorkspace path: String, repoID: String) -> QueueIntegration? {
        guard let raw = integrationByRepo[Self.scopedKey(path: path, repoID: repoID)] else { return nil }
        return QueueIntegration(rawValue: raw)
    }

    func explicitAutoClose(forWorkspace path: String, repoID: String) -> Bool? {
        autoCloseByRepo[Self.scopedKey(path: path, repoID: repoID)]
    }

    /// 旧的工作区值（主仓库兜底用）。
    func legacyIntegration(forWorkspace path: String) -> QueueIntegration? {
        guard let raw = integrationByWorkspace[Self.workspaceKey(path)] else { return nil }
        return QueueIntegration(rawValue: raw)
    }

    func legacyAutoClose(forWorkspace path: String) -> Bool {
        autoCloseByWorkspace[Self.workspaceKey(path)] ?? false
    }

    /// 用户指定的主仓库 repoID，或 nil（未指定 / 已失效由调用方的 detect 回退）。
    func storedPrimaryRepoID(forWorkspace path: String) -> String? {
        guard let id = primaryByWorkspace[Self.workspaceKey(path)], !id.isEmpty else { return nil }
        return id
    }

    // MARK: - 显式写入（nil = 删除 → 回到「跟随主仓库」）

    mutating func setIntegration(_ mode: QueueIntegration?, forWorkspace path: String, repoID: String) {
        let key = Self.scopedKey(path: path, repoID: repoID)
        if let mode = mode {
            integrationByRepo[key] = mode.rawValue
        } else {
            integrationByRepo.removeValue(forKey: key)
        }
    }

    mutating func setAutoClose(_ on: Bool?, forWorkspace path: String, repoID: String) {
        let key = Self.scopedKey(path: path, repoID: repoID)
        if let on = on {
            autoCloseByRepo[key] = on
        } else {
            autoCloseByRepo.removeValue(forKey: key)
        }
    }

    mutating func setLegacyIntegration(_ mode: QueueIntegration, forWorkspace path: String) {
        integrationByWorkspace[Self.workspaceKey(path)] = mode.rawValue
    }

    mutating func setLegacyAutoClose(_ on: Bool, forWorkspace path: String) {
        autoCloseByWorkspace[Self.workspaceKey(path)] = on
    }

    mutating func setPrimaryRepoID(_ id: String?, forWorkspace path: String) {
        let key = Self.workspaceKey(path)
        if let id = id, !id.isEmpty {
            primaryByWorkspace[key] = id
        } else {
            primaryByWorkspace.removeValue(forKey: key)
        }
    }

    // MARK: - issue 归属仓库（design §9）

    /// 用户显式切换过的 issue 归属仓库（nil = 从未切换 / 已失效，跟随主仓库）。
    func storedIssueRepoID(forWorkspace path: String) -> String? {
        guard let id = issueRepoByWorkspace[Self.workspaceKey(path)], !id.isEmpty else { return nil }
        return id
    }

    /// 写入 issue 归属（nil = 删除 → 回到「跟随主仓库」）。用户在 issue 区切过一次
    /// 之后这就是显式指定，不再跟随。
    mutating func setIssueRepoID(_ id: String?, forWorkspace path: String) {
        let key = Self.workspaceKey(path)
        if let id = id, !id.isEmpty {
            issueRepoByWorkspace[key] = id
        } else {
            issueRepoByWorkspace.removeValue(forKey: key)
        }
    }

    /// 解析 issue 归属：显式指定且该仓库仍存在 → 用它；否则跟随主仓库（primary）。
    /// 两者都没有时 nil（plain 工作区）。
    func resolvedIssueRepoID(forWorkspace path: String, repoSet: WorkspaceRepoSet) -> String? {
        if let id = storedIssueRepoID(forWorkspace: path),
           repoSet.repos.contains(where: { $0.id == id }) {
            return id
        }
        return repoSet.primary?.id
    }

    /// 是否处于「显式指定」状态（用户切换过且该仓库仍存在）。
    func isIssueRepoExplicit(forWorkspace path: String, repoSet: WorkspaceRepoSet) -> Bool {
        guard let id = storedIssueRepoID(forWorkspace: path) else { return false }
        return repoSet.repos.contains(where: { $0.id == id })
    }

    // MARK: - 解析链

    /// 1. 该仓库的显式按仓库值 → 用它；
    /// 2. 非主仓库且未显式设置（默认跟随）→ 用主仓库的解析结果；
    /// 3. 主仓库未显式设置 → 旧的工作区值（兼容）→ recommended。
    func resolvedIntegration(forWorkspace path: String, repoID: String, primaryID: String?,
                             recommended: QueueIntegration) -> QueueIntegration {
        if let explicit = explicitIntegration(forWorkspace: path, repoID: repoID) { return explicit }
        if let primaryID = primaryID, primaryID != repoID {
            return resolvedIntegration(forWorkspace: path, repoID: primaryID,
                                       primaryID: primaryID, recommended: recommended)
        }
        return legacyIntegration(forWorkspace: path) ?? recommended
    }

    /// 同一解析链；主仓库的兜底是旧工作区值，最终 false（自动关闭默认关）。
    func resolvedAutoClose(forWorkspace path: String, repoID: String, primaryID: String?) -> Bool {
        if let explicit = explicitAutoClose(forWorkspace: path, repoID: repoID) { return explicit }
        if let primaryID = primaryID, primaryID != repoID {
            return resolvedAutoClose(forWorkspace: path, repoID: primaryID, primaryID: primaryID)
        }
        return legacyAutoClose(forWorkspace: path)
    }

    /// 当前是否「跟随主仓库」：只有**非主仓库**且没有任何显式值时才跟随；
    /// 主仓库本身就是来源，永不跟随。
    func followsPrimary(forWorkspace path: String, repoID: String, primaryID: String?) -> Bool {
        guard let primaryID = primaryID, primaryID != repoID else { return false }
        return explicitIntegration(forWorkspace: path, repoID: repoID) == nil
            && explicitAutoClose(forWorkspace: path, repoID: repoID) == nil
    }
}
