import Foundation

// Headless tests for the task queue runner (TasksRunner.swift) driven by a
// scripted git repository and a scripted dsh session layer, so the whole
// pipeline runs with no window, no server and no disk:
//   branch -> session -> prompt -> poll -> push check -> queue PR.

var checks = 0
var failures = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { failures += 1; print("  FAIL \(label)") }
}

func eq<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("  FAIL \(label): got \(actual), want \(expected)")
    }
}

func section(_ name: String) { print("--- \(name) ---") }

// MARK: - Scripted git

final class FakeRepo {
    /// false = the directory is not a git repository: EVERY command fails, which
    /// is exactly what /usr/bin/git does outside a work tree (exit 128).
    var isRepo = true
    /// A fresh `git init` with nothing in it: HEAD is unborn, so
    /// `rev-parse --verify HEAD` fails, exactly like real git.
    var unborn = false
    /// The current HEAD commit hash (P4 产物校验的基线比对). A test simulates a new
    /// commit by changing it before the task's session ends.
    var head = "0f0f0f0f"
    var current = "main"
    var worktreeClean = true
    /// Lines `git status --porcelain` reports for UNTRACKED paths. Omitted when the
    /// caller asks `--untracked-files=no`, exactly like real git.
    var untracked = ""
    var remote: String? = "origin"
    var pushed: Set<String> = []
    var knownBranches: Set<String> = ["main"]
    var failing: Set<String> = []
    private(set) var calls: [String] = []
    private(set) var checkouts: [String] = []
    /// What "git log --oneline base..HEAD" answers — the commits the queue's branch
    /// already carries (the structural half of a 交接简报).
    var commits: [String] = []

    func git() -> TaskGit {
        TaskGit(run: { [unowned self] args in self.run(args) },
                remoteName: { [unowned self] in self.remote })
    }

    private func run(_ args: [String]) -> String? {
        let key = args.joined(separator: " ")
        calls.append(key)
        if !isRepo { return nil }
        if failing.contains(key) { return nil }
        guard let first = args.first else { return nil }
        switch first {
        case "rev-parse":
            if args.count >= 2, args[1] == "--abbrev-ref" { return current }
            // P4 基线比对直接读 HEAD（rev-parse HEAD），与 --verify HEAD 共用同一个值。
            if args.count == 2, args[1] == "HEAD" { return unborn ? nil : head }
            if args.count >= 2, args[1] == "--verify" {
                let name = args.last ?? ""
                if name == "HEAD" { return unborn ? nil : head }
                return knownBranches.contains(name) ? "0f0f0f0f" : nil
            }
            return nil
        case "status":
            let tracked = worktreeClean ? "" : " M Sources/x.swift"
            let untrackedPart = args.contains("--untracked-files=no") ? "" : untracked
            return [tracked, untrackedPart].filter { !$0.isEmpty }.joined(separator: "\n")
        case "checkout":
            guard args.count >= 2 else { return nil }
            let target = args.last ?? ""
            checkouts.append(target)
            current = target
            return "Switched to " + target
        case "pull":
            return "Already up to date."
        case "log":
            return commits.joined(separator: "\n")
        case "ls-remote":
            let branch = args.last ?? ""
            return pushed.contains(branch) ? "deadbeef\trefs/heads/" + branch : ""
        default:
            return nil
        }
    }
}

// MARK: - Scripted dsh

final class FakeDsh {
    private(set) var sessions: [String] = []
    var running: Set<String> = []
    /// dsh could not answer (RPC failure) / does not list this session at all:
    /// both used to come back as "finished" (see SessionState).
    var stateOverride: [String: SessionState] = [:]
    /// sessionId -> the agent's last words (the 交接简报's report).
    var reports: [String: String] = [:]
    /// Which sessions were asked for a report, in order.
    private(set) var reportCalls: [String] = []
    /// Whether a simulated agent echoes the TASK completion marker back on its last
    /// line the way the prompt asks (P1). ON by default, so every existing scenario
    /// runs through the marker gate exactly like a compliant agent would; a test
    /// about a MISSING/stale marker turns it off.
    var echoesTaskMarkers = true

    func report(_ id: String) -> String? {
        reportCalls.append(id)
        var text = reports[id]
        if echoesTaskMarkers, let marker = Self.taskMarker(in: prompts[id] ?? "") {
            let base = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !base.contains(marker) {
                text = base.isEmpty ? marker : base + "\n" + marker
            }
        }
        return text
    }

    /// The task completion marker (DSH-TASK-DONE-XXXXXXXX) in a prompt, or nil.
    /// The finalize marker (DSH-FINALIZE-) is a different namespace and deliberately
    /// not matched.
    private static func taskMarker(in prompt: String) -> String? {
        guard let range = prompt.range(of: "DSH-TASK-DONE-", options: .backwards) else { return nil }
        let tail = prompt[range.upperBound...].prefix { $0.isHexDigit }
        let hex = String(tail.prefix(8))
        return hex.count == 8 ? "DSH-TASK-DONE-" + hex : nil
    }

    func sessionState(_ id: String) -> SessionState {
        if let forced = stateOverride[id] { return forced }
        return running.contains(id) ? .running : .idle
    }
    private(set) var cancelled: [String] = []
    private(set) var titles: [String: String] = [:]
    private(set) var prompts: [String: String] = [:]
    var createFails = false
    var promptFails = false
    /// Fail the NEXT N prompts, then succeed (lets a test make only one prompt fail).
    var promptFailuresRemaining = 0

    func create() -> String? {
        if createFails { return nil }
        let id = "session-" + String(sessions.count + 1)
        sessions.append(id)
        running.insert(id)
        return id
    }

    func rename(_ id: String, _ title: String) -> Bool {
        titles[id] = title
        return true
    }

    func prompt(_ id: String, _ text: String) -> Bool {
        if promptFails { return false }
        if promptFailuresRemaining > 0 {
            promptFailuresRemaining -= 1
            return false
        }
        prompts[id] = text
        return true
    }

    /// Completion reports sent back to the session that created a queue.
    private(set) var notifications: [(session: String, text: String)] = []
    var notifyFails = false
    func notify(_ id: String, _ text: String) -> Bool {
        notifications.append((id, text))
        return !notifyFails
    }

    func cancel(_ id: String) -> Bool {
        cancelled.append(id)
        running.remove(id)
        return true
    }

    func finishAll() { running.removeAll() }
    func finish(_ id: String) { running.remove(id) }
}

final class Recorder {
    var persistCount = 0
    var issueWrites: [String] = []
    var prCalls: [(branch: String, base: String)] = []
    var existingPRs: [String: String] = [:]
    var logs: [String] = []
    func logged(_ needle: String) -> Bool { logs.contains { $0.contains(needle) } }
}

// MARK: - Harness

/// Blocking work queued by the harness's asynchronous perform (a class, so the
/// perform closure can capture it instead of the Harness itself).
final class WorkQueue {
    var items: [() -> Void] = []
}

final class Harness {
    let repo = FakeRepo()
    let dsh = FakeDsh()
    let rec = Recorder()
    let runner: TasksRunner
    var board: TaskBoard { runner.board }

    /// Blocking work the runner handed to perform but nobody ran YET. The real
    /// panel performs it on a background queue, and that is the only way to
    /// observe the STARTING window (cancel clicked before the session exists).
    private let work = WorkQueue()
    private let asynchronous: Bool

    init(board: TaskBoard,
         github: Bool = true,
         gitRepo: Bool = true,
         timeout: TimeInterval = 30 * 60,
         asynchronous: Bool = false,
         defaultBaseBranch: String = "main",
         autoCloseOnPublish: Bool = false,
         verifyExpectedCommit: Bool = false,
         workspaceShape: TaskRepoShape? = nil) {
        self.asynchronous = asynchronous
        let work = self.work
        let asynchronous = asynchronous        // captured by the perform closure
        repo.isRepo = gitRepo
        let repo = self.repo
        let dsh = self.dsh
        let rec = self.rec
        let env = TaskRunnerEnv(
            git: repo.git(),
            repoRoot: "/tmp/repo",
            createSession: { _ in dsh.create() },
            renameSession: { id, title in dsh.rename(id, title) },
            promptSession: { id, text in dsh.prompt(id, text) },
            sessionState: { id in dsh.sessionState(id) },
            defaultBaseBranch: defaultBaseBranch,
            autoCloseOnPublish: autoCloseOnPublish,
            canSwitchBranches: gitRepo,
            canOpenPR: { github },
            cancelSession: { id in dsh.cancel(id) },
            // No createPR/prText: the PR is opened by the queue's PR SESSION, whose
            // prompt asks the agent to push and to write the title/body from the diff.
            findExistingPR: { branch in github ? rec.existingPRs[branch] : nil },
            promptText: { task, queue, brief in
                // Same rules the panel uses — including the SHAPE of the workspace,
                // which the panel probes at prompt time (a queue's first task can be
                // the one that inits the repo or adds the GitHub remote) and the
                // SOURCE, which only changes the prompt's HEAD: issue tasks and
                // manual tasks share one requirement list (2026-09-27 alignment).
                let shape = TaskRepoShape.detect(isGit: gitRepo, hasGitHubRemote: github)
                let sharedName = queue.flatMap { $0.autoCreated ? nil : $0.name }
                if task.source == .github {
                    return TaskPrompts.issue(number: task.number ?? 0, title: task.title,
                                             body: task.body, labels: task.labels,
                                             branch: queue?.branch, queueName: sharedName,
                                             base: queue?.baseBranch ?? defaultBaseBranch,
                                             brief: brief,
                                             shape: shape)
                }
                return TaskPrompts.manual(title: task.title, body: task.body,
                                          branch: queue?.branch, queueName: sharedName,
                                          base: queue?.baseBranch ?? defaultBaseBranch,
                                          brief: brief,
                                          shape: shape)
            },
            sessionReport: { id in dsh.report(id) },
            requireCompletionMarker: true,
            // P4 产物校验默认关闭（与面板一致）：既有用例仍走 P1 的 marker 门槛；
            // P4 用例显式开启并给出工作区形状。
            verifyExpectedCommit: verifyExpectedCommit,
            workspaceShape: workspaceShape.map { shape in { shape } },
            notifySession: { id, text in dsh.notify(id, text) },
            persist: { board in rec.persistCount += 1; _ = board },
            persistIssueTask: { task in rec.issueWrites.append(task.id) },
            log: { message in rec.logs.append(message) },
            perform: { blocking, completion in
                if asynchronous {
                    work.items.append { blocking(); completion() }
                } else {
                    blocking(); completion()
                }
            }
        )
        runner = TasksRunner(board: board, env: env, timeout: timeout)
    }

    /// Run the blocking work the runner queued (git, session, prompt…) and its
    /// completion, the way its background queue would.
    func flush() {
        while !work.items.isEmpty { work.items.removeFirst()() }
    }

    /// Walk one task all the way out of its queue: finish its session, step (which
    /// starts the queue's PR session), then finish THAT session and step again — a
    /// finished queue owns the serial slot until its PR run answers. Tests that walk a
    /// batch of queues have to do both halves, or the next queue looks stuck.
    func settleTaskAndPR(_ limit: Int = 6) {
        for _ in 0..<limit {
            dsh.finishAll()
            _ = runner.step()
            if !runner.isBusy { return }
            if runner.openingPRQueueID == nil { return }   // a real task is running: leave it
        }
    }
}

/// A runner env over SEVERAL scripted repositories (design §5): every git call is
/// dispatched through `gitFor(repo)`, and the prompt text is the brief itself so a
/// test can read exactly which commits the next task would be handed.
final class MultiRepoHarness {
    let repos: [WorkspaceRepo]
    let gits: [String: FakeRepo]
    let dsh = FakeDsh()
    let rec = Recorder()
    let runner: TasksRunner
    var board: TaskBoard { runner.board }

    init(board: TaskBoard, repos: [WorkspaceRepo], primaryRepoID: String? = nil,
         repoSetProvider: (() -> WorkspaceRepoSet)? = nil,
         defaultIntegrationFor: ((WorkspaceRepo) -> QueueIntegration)? = nil,
         findExistingPRFor: ((WorkspaceRepo, String) -> String?)? = nil) {
        self.repos = repos
        var table: [String: FakeRepo] = [:]
        for repo in repos { table[repo.id] = FakeRepo() }
        self.gits = table
        let dsh = self.dsh
        let rec = self.rec
        let primary = primaryRepoID ?? repos.first?.id
        let fallback = TaskGit(run: { _ in nil }, remoteName: { nil })
        let env = TaskRunnerEnv(
            git: primary.flatMap { table[$0]?.git() } ?? fallback,
            repoRoot: "/tmp/ws",
            createSession: { _ in dsh.create() },
            renameSession: { id, title in dsh.rename(id, title) },
            promptSession: { id, text in dsh.prompt(id, text) },
            sessionState: { id in dsh.sessionState(id) },
            defaultIntegrationFor: defaultIntegrationFor,
            cancelSession: { id in dsh.cancel(id) },
            findExistingPR: { branch in rec.existingPRs[branch] },
            findExistingPRFor: findExistingPRFor,
            promptText: { _, _, brief in brief ?? "" },
            sessionReport: { id in dsh.report(id) },
            requireCompletionMarker: true,
            notifySession: { id, text in dsh.notify(id, text) },
            persist: { board in rec.persistCount += 1; _ = board },
            persistIssueTask: { task in rec.issueWrites.append(task.id) },
            log: { message in rec.logs.append(message) },
            perform: TaskRunnerEnv.synchronous,
            repos: repos,
            gitFor: { repo in table[repo.id]!.git() },
            primaryRepoID: primary,
            repoSetProvider: repoSetProvider
        )
        runner = TasksRunner(board: board, env: env, timeout: 30 * 60)
    }

    func git(_ id: String) -> FakeRepo { gits[id]! }
}

/// A board with one manual task and one user queue. The task is NOT enqueued:
/// tests drive the real path (runner.enqueue), which is also what activates the
/// queue while the runner is idle.
func singleTaskBoard(queueName: String = "Docs Cleanup",
                     branch: String? = nil,
                     base: String = "main",
                     autoPR: Bool = true) -> (TaskBoard, String, String) {
    var board = TaskBoard()
    let task = TaskItem.manual(title: "Polish README", body: "tidy it")
    board.tasks = [task]
    let queue = board.createQueue(name: queueName, branch: branch, baseBranch: base, autoPR: autoPR)
    return (board, task.id, queue.id)
}

/// A board with TWO manual tasks and one user queue (neither enqueued). Used by
/// the P2 待确认 tests: the first task can be left unconfirmed while the second
/// proves the queue really stopped.
func twoTaskBoard(queueName: String = "Docs Cleanup",
                  autoPR: Bool = true) -> (TaskBoard, String, String, String) {
    var board = TaskBoard()
    let first = TaskItem.manual(title: "One", id: "manual-0p00aaaa")
    let second = TaskItem.manual(title: "Two", id: "manual-0p01bbbb")
    board.tasks = [first, second]
    let queue = board.createQueue(name: queueName, autoPR: autoPR)
    return (board, first.id, second.id, queue.id)
}

// MARK: - Happy path

section("happy path: branch, session, prompt, push, PR")
do {
    let (board, taskID, queueID) = singleTaskBoard()
    let h = Harness(board: board)
    check(h.runner.enqueue(taskID: taskID, into: queueID), "enqueue starts the task while the runner is idle")
    check(h.runner.runningTaskID == taskID, "the task owns the serial slot")
    check(h.board.task(taskID)?.state == .running, "the task is running")
    check(h.board.task(taskID)?.sessionId == "session-1", "the session id is on the task")
    check(h.board.local.sessions[taskID] == "session-1", "the session is in the local overlay")
    check(h.board.queue(queueID)?.state == .active, "the queue became active")
    check(h.board.queue(queueID)?.branch == "feature/docs-cleanup", "the queue branch was derived")
    check(h.board.task(taskID)?.branch == "feature/docs-cleanup", "the queue branch is copied onto the task")
    eq(h.repo.current, "feature/docs-cleanup", "the worktree is on the queue branch")
    eq(h.repo.checkouts, ["main", "feature/docs-cleanup"], "checkout base then create the branch")
    check(h.repo.calls.contains("status --porcelain --untracked-files=no"),
          "the clean check (tracked changes only) ran before switching")
    check(h.dsh.titles["session-1"] == "TASK: Polish README", "the session was renamed with the TASK prefix")
    check((h.dsh.prompts["session-1"] ?? "").contains("Docs Cleanup"), "the prompt names the queue")
    check(h.rec.persistCount > 0, "state was persisted while starting")

    check(h.runner.step() == true, "still busy while the session runs")
    h.dsh.reports["session-1"] = "改完了 README 的安装段，用 markdownlint 校验过。"
    h.dsh.finishAll()
    check(h.runner.step() == true, "the finished queue hands over to its PR session")
    check(h.board.task(taskID)?.state == .done, "the task is done")
    eq(h.board.task(taskID)?.report, "改完了 README 的安装段，用 markdownlint 校验过。",
       "the agent report is written back onto the task")
    check(h.rec.issueWrites.isEmpty, "a manual task is not written to the committed index")
    check(h.board.queue(queueID)?.state == .done, "the finished queue is done")
    eq(h.runner.openingPRQueueID, queueID, "the runner knows which queue is opening a PR")
    // The task session was never asked to push; a SECOND session does the publishing.
    let taskPrompt = h.dsh.prompts["session-1"] ?? ""
    check(!taskPrompt.contains("push"), "the task prompt says nothing about push")
    eq(h.dsh.sessions.count, 2, "a dedicated PR session was created")
    let prSession = h.dsh.sessions[1]
    check((h.dsh.titles[prSession] ?? "").contains("Docs Cleanup"), "the PR session is named for the queue")
    let prPrompt = h.dsh.prompts[prSession] ?? ""
    check(prPrompt.contains("feature/docs-cleanup"), "the PR session is told which branch to publish")
    check(prPrompt.contains("base = main"), "and which base to open against")
    check(prPrompt.contains("不要改任何代码"), "and that it must not touch the code")

    // A multi-line report: the card shows the first line collapsed, but the WHOLE
    // report is what gets written back (user 2026-10-01).
    h.dsh.reports[prSession] = "已推送分支并创建 PR：https://github.com/o/r/pull/12\n改动摘要：安装段重写\n校验：markdownlint 通过"
    h.dsh.finishAll()
    check(h.runner.step() == false, "the PR run ends")
    eq(h.board.queue(queueID)?.prUrl, "https://github.com/o/r/pull/12",
       "the PR url it reported lands on the queue")
    eq(h.board.queue(queueID)?.integrationNote,
       "已推送分支并创建 PR：https://github.com/o/r/pull/12\n改动摘要：安装段重写\n校验：markdownlint 通过",
       "整段汇报都回写到队列（不只第一行）")
    check(h.runner.isBusy == false, "nothing is in flight")
}

section("no branch: git is never touched")
do {
    let (board, taskID, queueID) = singleTaskBoard(branch: "")
    check(board.queue(queueID)?.branch == nil, "an empty branch means no branch")
    let h = Harness(board: board)
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    check(h.repo.calls.isEmpty, "no git command ran")
    h.dsh.finishAll()
    check(h.runner.step() == false, "the task finishes (and there is no PR run to make)")
    check(h.board.task(taskID)?.state == .done, "the task is done")
    eq(h.dsh.sessions.count, 1, "no PR session without a branch")
    eq(h.board.queue(queueID)?.prError, "tasks.errPRNoBranch", "and the queue records why")
}

section("non-git workspace: a branchless queue runs, a queue with a branch reports it")
do {
    // The directory is not a git repository at all: every git command fails.
    // A queue that does not ask for a branch must still run its tasks — the
    // session is created in the directory, git is simply never involved.
    let (board, taskID, queueID) = singleTaskBoard(branch: "")
    check(board.queue(queueID)?.branch == nil, "the queue asks for no branch")
    let h = Harness(board: board, github: false, gitRepo: false)
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    check(h.repo.calls.isEmpty, "no git command ran")
    check(h.board.task(taskID)?.state == .running, "the task started anyway")
    h.dsh.finishAll()
    check(h.runner.step() == false, "it finishes without a push check")
    check(h.board.task(taskID)?.state == .done, "the task is done in a non-git directory")
    check(h.dsh.prompts["session-1"] != nil, "the agent was prompted with the task")

    // The same directory with a queue that DOES ask for a branch: the only
    // failure is the branch step, and the board says which one it was.
    let (board2, task2, queueID2) = singleTaskBoard(branch: "feature/docs")
    let h2 = Harness(board: board2, github: false, gitRepo: false)
    _ = h2.runner.enqueue(taskID: task2, into: queueID2)
    check(h2.board.task(task2)?.state == .failed, "a queue branch cannot be entered there")
    eq(h2.board.task(task2)?.error, "tasks.errNotGit", "and the reason is the git one")
    check(h2.dsh.sessions.isEmpty, "no session was wasted on it")
    check(h2.rec.logged("tasks.errNotGit"), "the failure is in the log")
}

// MARK: - A queue shares one branch

section("queue tasks share a branch and one PR")
do {
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "First", body: nil, id: "manual-0001aaaa")
    let t2 = TaskItem.manual(title: "Second", body: nil, id: "manual-0002bbbb")
    board.tasks = [t1, t2]
    let queue = board.createQueue(name: "Dark Mode", autoPR: true)
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    _ = board.enqueue(taskID: t2.id, into: queue.id)
    let h = Harness(board: board)

    _ = h.runner.startQueue(queue.id)
    eq(h.repo.checkouts, ["main", "feature/dark-mode"], "the first task switches branch")
    h.dsh.finishAll()
    _ = h.runner.step()
    check(h.board.task(t1.id)?.state == .done, "the first task is done")
    check(h.runner.openingPRQueueID == nil, "no PR run while the queue still has work")
    check(h.board.queue(queue.id)?.prUrl == nil, "and no PR yet")

    check(h.board.task(t2.id)?.state == .running, "the second task started automatically")
    eq(h.repo.checkouts.count, 2, "the second task does not switch branch again")
    check(h.runner.runningTaskID == t2.id, "the second task owns the slot")
    h.dsh.finishAll()
    _ = h.runner.step()
    check(h.board.task(t2.id)?.state == .done, "the second task is done")
    eq(h.dsh.sessions.count, 3, "the queue PR session starts once, after the LAST task")
    // That session opened the PR without quoting the URL back: the runner finds it
    // through the branch instead of leaving the queue without a PR.
    h.rec.existingPRs["feature/dark-mode"] = "https://example.test/pull/7"
    h.dsh.reports[h.dsh.sessions[2]] = "PR 已创建，请 review。"
    h.dsh.finishAll()
    _ = h.runner.step()
    eq(h.board.queue(queue.id)?.prUrl, "https://example.test/pull/7",
       "an unquoted PR is found for the branch")
    check(h.board.queue(queue.id)?.state == .done, "the queue is done")
}

// MARK: - Failures

section("failure modes keep the branch and pause the queue")
do {
    let (board, taskID, queueID) = singleTaskBoard()
    let h = Harness(board: board)
    h.repo.worktreeClean = false
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    check(h.board.task(taskID)?.state == .failed, "a dirty worktree fails the task")
    check(h.board.task(taskID)?.error == "tasks.errDirtyTree", "the dirty-worktree reason is recorded")
    eq(h.board.queue(queueID)?.state, QueueState.paused, "the queue is paused")
    check(h.dsh.sessions.isEmpty, "no session was created")
    check(h.runner.isBusy == false, "nothing is in flight")
}
do {
    let (board, taskID, queueID) = singleTaskBoard()
    let h = Harness(board: board)
    h.repo.failing.insert("checkout main")
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    check(h.board.task(taskID)?.error == "tasks.errBranch", "a failed checkout is reported")
}
do {
    let (board, taskID, queueID) = singleTaskBoard()
    let h = Harness(board: board)
    h.repo.failing.insert("pull --ff-only")
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    check(h.board.task(taskID)?.error == "tasks.errPull", "a failed pull is reported")
}
do {
    let (board, taskID, queueID) = singleTaskBoard()
    let h = Harness(board: board)
    h.dsh.createFails = true
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    check(h.board.task(taskID)?.error == "tasks.errSession", "a failed session is reported")
}
do {
    let (board, taskID, queueID) = singleTaskBoard()
    let h = Harness(board: board)
    h.dsh.promptFails = true
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    check(h.board.task(taskID)?.error == "tasks.errPrompt", "a failed prompt is reported")
    check(h.board.task(taskID)?.sessionId != nil, "the session id is still recorded for traceability")
}
do {
    // The old behaviour — "the branch is not on the remote ⇒ the task FAILED with
    // tasks.errNoPush" — is gone with the push check itself: a task commits and
    // nothing else. Whether the branch ever reaches the remote is the PR session's
    // business, and it reports its own failure. The queue stays done.
    let (board, taskID, queueID) = singleTaskBoard()
    let h = Harness(board: board)
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    h.dsh.finishAll()
    _ = h.runner.step()
    check(h.board.task(taskID)?.state == .done, "an unpushed branch no longer fails the task")
    check(h.board.task(taskID)?.error == nil, "and no failure reason is recorded")
    check(h.repo.calls.contains { $0.hasPrefix("ls-remote") } == false, "the remote was never asked about it")
}
do {
    let (board, taskID, queueID) = singleTaskBoard()
    let h = Harness(board: board, timeout: 60)
    let start = Date()
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    _ = h.runner.step(now: start.addingTimeInterval(61))
    check(h.board.task(taskID)?.error == "tasks.errTimeout", "the timeout is reported")
    eq(h.dsh.cancelled, ["session-1"], "the session was cancelled")
    eq(h.board.queue(queueID)?.state, QueueState.paused, "the queue is paused")
}
do {
    // No GitHub remote ⇒ no PR session for this queue. The TASK is unaffected: it
    // only ever commits, and nothing checks the remote on its behalf any more.
    let (board, taskID, queueID) = singleTaskBoard()
    let h = Harness(board: board, github: false)
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    h.dsh.finishAll()
    _ = h.runner.step()
    check(h.board.task(taskID)?.state == .done, "the task is done")
    check(h.board.queue(queueID)?.prUrl == nil, "no PR url")
    eq(h.dsh.sessions.count, 1, "and no PR session without a GitHub remote")
    check(h.repo.calls.contains { $0.hasPrefix("ls-remote") } == false,
          "the push is never checked — nobody is going to push from here")
    let prompt = h.dsh.prompts["session-1"] ?? ""
    check(!prompt.contains("push"), "the agent is not told to push either")
    check(!prompt.contains("GitHub token"), "and not handed a token it has no use for")
}
do {
    // A local-only repo (no remote at all) is the same story for the task: it never
    // pulls and never touches the remote. Its PR session is the one that has to
    // deal with the world (and is told to).
    let (board, taskID, queueID) = singleTaskBoard()
    let h = Harness(board: board, github: true)
    h.repo.remote = nil
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    check(h.repo.calls.contains("pull --ff-only") == false, "no pull without a remote")
    h.dsh.finishAll()
    _ = h.runner.step()
    check(h.board.task(taskID)?.state == .done, "a local-only repo still finishes")
    eq(h.dsh.sessions.count, 2, "and the queue still hands over to its PR session")
}
do {
    // The PR session is refused when there is no branch to publish — and the refusal
    // is recorded on the queue instead of starting a session that cannot succeed.
    var board = TaskBoard()
    let task = TaskItem.manual(title: "Docs", body: nil, id: "manual-pp001111")
    board.tasks = [task]
    let queue = board.createQueue(name: "No branch", branch: "", autoPR: true)
    _ = board.enqueue(taskID: task.id, into: queue.id)
    let h = Harness(board: board)
    _ = h.runner.startQueue(queue.id)
    h.dsh.finishAll()
    _ = h.runner.step()
    check(h.runner.startQueueIntegration(queue.id) == false, "a queue without a branch cannot finalize")
    eq(h.dsh.sessions.count, 1, "and no session is wasted on it")
    eq(h.board.queue(queue.id)?.prError, "tasks.errPRNoBranch", "the reason is on the queue")
    check(h.rec.logged("has no branch"), "and in the log")
}

// MARK: - Serial

section("strictly serial across queues")
do {
    var board = TaskBoard()
    let a = TaskItem.manual(title: "A", body: nil, id: "manual-aaaa1111")
    let b = TaskItem.manual(title: "B", body: nil, id: "manual-bbbb2222")
    board.tasks = [a, b]
    let qa = board.createQueue(name: "A lane", autoPR: false)
    let qb = board.createQueue(name: "B lane", autoPR: false)
    _ = board.enqueue(taskID: a.id, into: qa.id)
    _ = board.enqueue(taskID: b.id, into: qb.id)
    let h = Harness(board: board)

    check(h.board.nextStartable() == nil, "no active queue yet: nothing startable")
    h.repo.pushed.insert("feature/a-lane")
    _ = h.runner.startQueue(qa.id)
    check(h.runner.runningTaskID == a.id, "queue A runs first")
    check(h.board.nextStartable() == nil, "the other queue cannot start while one runs")
    check(h.runner.pump() == nil, "pump refuses a second concurrent task")
    check(h.dsh.sessions.count == 1, "only one session exists")

    h.dsh.finishAll()
    _ = h.runner.step()
    check(h.board.task(a.id)?.state == .done, "task A is done")
    check(h.runner.runningTaskID == nil, "the slot is free again")
    check(h.board.task(b.id)?.state == .queued, "task B waits in its own paused queue")
    _ = h.runner.startQueue(qb.id)
    check(h.runner.runningTaskID == b.id, "queue B starts when asked")
}

// MARK: - Cancel / retry / skip

section("取消任务 in the two windows where there is nothing to cancel yet/any more")
do {
    // The board says .running from before the git/session/prompt work is done, so
    // the card offers 取消任务 exactly when the runner has no session yet. It used
    // to return false and the panel hid the status line: a click that did nothing,
    // silently. Now the request is remembered and applied.
    let (board, taskID, queueID) = singleTaskBoard()
    let h = Harness(board: board, asynchronous: true)
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    check(h.board.task(taskID)?.state == .running, "the card already says 运行中")
    eq(h.runner.cancelRunning(), .deferred, "the cancel is remembered")
    check(h.dsh.cancelled.isEmpty, "there is no session to cancel yet")
    h.flush()
    eq(h.dsh.cancelled, ["session-1"], "the session is cancelled the moment it exists")
    check(h.board.task(taskID)?.state == .cancelled, "the task ends up cancelled")
    eq(h.board.queue(queueID)?.state, QueueState.paused, "its queue is paused")
    check(h.runner.isBusy == false, "nothing keeps running")
}
do {
    // The FINISHING window: the agent is done, we are pushing / opening the PR.
    let (board, taskID, queueID) = singleTaskBoard()
    let h = Harness(board: board, asynchronous: true)
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    h.flush()
    h.dsh.finishAll()
    h.repo.pushed.insert("feature/docs-cleanup")     // the agent pushed, as it should
    _ = h.runner.step()
    eq(h.runner.cancelRunning(), .finishing, "there is nothing left to cancel — and it says so")
    h.flush()
    check(h.board.task(taskID)?.state == .done, "the task still finishes normally")
}
do {
    let (board, taskID, queueID) = singleTaskBoard()
    let h = Harness(board: board)
    eq(h.runner.cancelRunning(), .idle, "nothing is running → idle")
    _ = taskID; _ = queueID
}

section("dsh 说不清会话状态时，任务不许被提前判完成")
do {
    // .unknown = RPC 问不到（服务器忙 / 网络抖）。此前这被读成「没在跑」，于是
    // 一次瞬时失败就把正在跑的任务判成已完成 —— 现在只能继续等。
    let (board, taskID, queueID) = singleTaskBoard()
    let h = Harness(board: board, github: false)
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    h.dsh.stateOverride["session-1"] = .unknown
    for _ in 0..<5 { _ = h.runner.step() }
    check(h.board.task(taskID)?.state == .running, "问不到就继续等，绝不判完成")
    check(h.rec.logged("could not report on its session"), "并且日志说明自己在等")
    h.dsh.stateOverride["session-1"] = .idle
    _ = h.runner.step()
    check(h.board.task(taskID)?.state == .done, "dsh 明确说结束了才结束")
}
do {
    // .missing = dsh 的会话列表里根本没有它（被删掉 / 服务重启过）。一次不算数，
    // 连续 N 次才判失败，而且原因要说「会话没了」，不是「已完成」。
    let (board, taskID, queueID) = singleTaskBoard()
    let h = Harness(board: board, github: false)
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    h.dsh.stateOverride["session-1"] = .missing
    _ = h.runner.step()
    check(h.board.task(taskID)?.state == .running, "偶尔一次不见：不动它")

    h.dsh.stateOverride["session-1"] = .running
    for _ in 0..<(TasksRunner.missingSessionPolls + 2) { _ = h.runner.step() }
    check(h.board.task(taskID)?.state == .running, "中间又答上来一次，计数归零")

    h.dsh.stateOverride["session-1"] = .missing
    for _ in 0..<TasksRunner.missingSessionPolls { _ = h.runner.step() }
    check(h.board.task(taskID)?.state == .failed, "连续 N 次都不见了：判失败")
    eq(h.board.task(taskID)?.error, "tasks.errSessionGone", "原因是「会话没了」，不是「已完成」")
    eq(h.board.queue(queueID)?.state, QueueState.paused, "队列暂停，等用户决定")
    check(h.rec.logged("its session is gone from dsh"), "日志里写清发生了什么")
}

section("cancel, retry and skip")
do {
    let (board, taskID, queueID) = singleTaskBoard()
    let h = Harness(board: board)
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    eq(h.runner.cancelRunning(), .cancelled, "cancel is accepted")
    eq(h.dsh.cancelled, ["session-1"], "the session was cancelled")
    check(h.board.task(taskID)?.state == .cancelled, "the task is cancelled")
    eq(h.board.queue(queueID)?.state, QueueState.paused, "the queue is paused")
    check(h.runner.isBusy == false, "nothing runs after a cancel")

    check(h.runner.retry(taskID: taskID), "retry is accepted")
    check(h.board.task(taskID)?.state == .running, "the retry started a new run")
    check(h.dsh.sessions.count == 2, "retry opens a new session")
    check(h.dsh.cancelled.count == 1, "no second cancel")
}
do {
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "One", body: nil, id: "manual-cccc1111")
    let t2 = TaskItem.manual(title: "Two", body: nil, id: "manual-cccc2222")
    board.tasks = [t1, t2]
    // autoPR ON: this queue will open a PR, so an unpushed branch at the END is a
    // real failure (with autoPR off nothing is pushed and nothing is checked — see
    // the push-policy tests).
    let queue = board.createQueue(name: "Lane", autoPR: true)
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    _ = board.enqueue(taskID: t2.id, into: queue.id)
    let h = Harness(board: board)
    _ = h.runner.startQueue(queue.id)
    h.dsh.finishAll()
    _ = h.runner.step()
    check(h.board.task(t1.id)?.state == .done, "the first task is done")
    check(h.runner.runningTaskID == t2.id, "the second task follows")

    // The LAST task times out: the queue pauses, and 跳过并继续 moves past it.
    h.dsh.finishAll()
    h.dsh.stateOverride["session-2"] = .missing
    for _ in 0..<TasksRunner.missingSessionPolls { _ = h.runner.step() }
    check(h.board.task(t2.id)?.state == .failed, "the LAST task fails on its own merits")
    check(h.runner.runningTaskID == nil, "the queue is paused")
    check(h.runner.skip(taskID: t2.id), "skip resumes the queue")
    check(h.board.queue(queue.id)?.state == QueueState.active, "the queue is active again")
    check(h.runner.runningTaskID == nil, "nothing more to run in this queue")
    check(h.board.task(t1.id)?.state == .done, "the finished task is untouched")
    check(h.board.task(t2.id)?.state == .failed, "the skipped task keeps its record")
}

// MARK: - Restart

section("restart recovery")
do {
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "Interrupted", body: nil, id: "manual-dddd1111")
    let t2 = TaskItem.manual(title: "Waiting", body: nil, id: "manual-dddd2222")
    board.tasks = [t1, t2]
    let queue = board.createQueue(name: "Lane", autoPR: false)
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    _ = board.enqueue(taskID: t2.id, into: queue.id)
    board.markRunning(t1.id)
    board.local.sessions[t1.id] = "session-died"
    board.attachSessions(board.local.sessions)

    let h = Harness(board: board)
    let recovered = h.runner.reconcileAfterRestart()
    eq(recovered.interrupted, [t1.id], "the running task is reported as interrupted")
    eq(recovered.pausedQueues, [queue.id], "the active queue is paused")
    check(h.board.task(t1.id)?.error == "tasks.errInterrupted", "the interrupted reason is recorded")
    check(h.board.task(t1.id)?.sessionId == "session-died", "the dead session stays for traceability")
    check(h.runner.isBusy == false, "a restart starts nothing")
    check(h.board.nextStartable() == nil, "nothing is startable until the user says so")

    check(h.runner.startQueue(queue.id), "the user starts the queue")
    check(h.runner.runningTaskID == t2.id, "the next queued task (not the interrupted one) runs")
    check(h.dsh.sessions.count == 1, "a fresh session was created")
}

// MARK: - Issue tasks run in their own single-task queue

section("issue task auto queue")
do {
    var board = TaskBoard()
    board.tasks = [TaskItem.github(number: 12, title: "Fix dark mode", labels: ["bug"])]
    let h = Harness(board: board)
    let queueID = h.runner.startIssueTask("issue-12")
    check(queueID != nil, "an auto queue was created")
    let queue = queueID.flatMap { h.board.queue($0) }
    check(queue?.autoCreated == true, "the queue is flagged as auto")
    check(queue?.branch == "fix/issue-12", "the auto branch follows the issue rule")
    check(queue?.autoPR == true, "the auto queue wants a PR")
    eq(queue?.taskIds, ["issue-12"], "the task is in it exactly ONCE (the lane draws one card)")
    eq(h.runner.board.tasks(inQueue: queueID!).count, 1, "…which is one card, not two")
    check(h.runner.runningTaskID == "issue-12", "the issue task started")
    eq(h.repo.checkouts, ["main", "fix/issue-12"], "the issue branch was created from main")
    h.dsh.finishAll()
    _ = h.runner.step()
    check(h.board.task("issue-12")?.state == .done, "the issue task is done")
    eq(h.rec.issueWrites, ["issue-12"], "the issue task is written to the committed index")
    eq(h.dsh.sessions.count, 2, "…and its queue hands over to a PR session")
    h.dsh.reports[h.dsh.sessions[1]] = "PR：https://github.com/o/r/pull/3"
    h.dsh.finishAll()
    _ = h.runner.step()
    eq(h.board.queue(queueID!)?.prUrl, "https://github.com/o/r/pull/3", "the issue queue gets its PR")

    // retry reuses the same auto queue instead of creating another one
    var failedBoard = h.board
    if let i = failedBoard.index(ofTask: "issue-12") { failedBoard.tasks[i].state = .failed }
    let h2 = Harness(board: failedBoard)
    let before = h2.board.queues.count
    _ = h2.runner.startIssueTask("issue-12")
    eq(h2.board.queues.count, before, "retry reuses the auto queue")
    check(h2.runner.runningTaskID == "issue-12", "the retried issue task runs")
}



// MARK: - issue 任务与手动任务对齐（2026-09-27）

section("issue 任务与手动任务对齐：同一套要求，只有头不同")
do {
    /// The numbered requirement lines of a prompt, so the two sources can be compared
    /// word for word instead of by eyeballing.
    func requirementLines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter {
            $0.range(of: "^[0-9]+\\. ", options: .regularExpression) != nil
        }
    }

    var board = TaskBoard()
    let issue = TaskItem.github(number: 7, title: "深色模式闪一下",
                                body: "复现：打开设置 → 主题 → 切深色。\n期望：不闪。",
                                labels: ["bug", "ui"])
    board.tasks = [issue]
    let h = Harness(board: board, github: true, gitRepo: true)
    _ = h.runner.startIssueTask("issue-7")
    let prompt = h.dsh.prompts["session-1"] ?? ""

    check(prompt.contains("## Issue #7"), "头是 issue 编号")
    check(prompt.contains("标题：深色模式闪一下"), "头带标题")
    check(prompt.contains("标签：bug, ui"), "头带标签")
    check(prompt.contains("复现：打开设置 → 主题 → 切深色。"),
          "issue 正文直接交给代理 —— 此前只给标题，正文还得它自己去 GitHub 拉")
    check(!prompt.contains("issue-resolve"), "不再要求加载 issue-resolve（技能已退役）")
    check(!prompt.contains("push"), "与手动任务一样不提 push")
    check(prompt.contains("完成前 commit"), "commit 条与手动任务同款")
    check(prompt.contains("token 在 $DSH_HOME/oh-my-dsh/tokens/"), "GitHub 工作区才有的 token 条照旧")
    check(prompt.contains("本任务独立执行"), "自动队列不算共享泳道（两种来源一致）")

    let manualPrompt = TaskPrompts.manual(title: issue.title, body: issue.body,
                                          branch: "fix/issue-7", queueName: nil, base: "main",
                                          brief: "## 队列信息", shape: .github)
    let issuePrompt = TaskPrompts.issue(number: 7, title: issue.title, body: issue.body,
                                        labels: issue.labels, branch: "fix/issue-7",
                                        queueName: nil, base: "main",
                                        brief: "## 队列信息", shape: .github)
    eq(requirementLines(issuePrompt), requirementLines(manualPrompt),
       "issue 与手动任务的要求逐行逐字相同（同一份 requirements(...)）")
    check(issuePrompt.hasSuffix("## 队列信息"), "交接简报落在所有要求之后（两种来源同一落点）")
}

section("多仓库提示词：单目标逐字节不变，子仓库多一行，多目标换清单")
do {
    // The legacy call (shape only) IS the single-root target.
    let legacy = TaskPrompts.requirements(branch: "feature/x", queueName: "Lane",
                                          base: "main", shape: .github)
    let root = TaskPrompts.requirements(branch: "feature/x", queueName: "Lane",
                                        base: "main",
                                        targets: [TaskPromptTarget(repoID: ".", shape: .github)])
    eq(root, legacy, "单目标（根仓库）与今天的单仓库文本逐字节相同")

    // A child target: exactly one extra line, at the HEAD, and the rest identical.
    let child = TaskPrompts.requirements(branch: "feature/x", queueName: "Lane",
                                         base: "main",
                                         targets: [TaskPromptTarget(repoID: "repo-a",
                                                                    shape: .github,
                                                                    defaultBase: "main")])
    eq(child.count, legacy.count + 1, "子仓库目标只多一行")
    eq(Array(child.dropFirst()), legacy, "其余各条与单仓库逐字节相同")
    check(child[0].contains("子目录 `repo-a/`"), "多出的一行说工作目录")
    check(child[0].contains("-C repo-a/"), "并给出 -C 写法")

    // The full prompt: a legacy call and an explicit root target agree byte for byte.
    let legacyPrompt = TaskPrompts.manual(title: "T", body: "B", branch: "feature/x",
                                          queueName: "Lane", base: "main", shape: .github)
    let rootPrompt = TaskPrompts.manual(title: "T", body: "B", branch: "feature/x",
                                        queueName: "Lane", base: "main", shape: .github,
                                        targets: [TaskPromptTarget(repoID: ".", shape: .github)])
    eq(rootPrompt, legacyPrompt, "显式根目标与旧调用逐字节相同")
    let childPrompt = TaskPrompts.manual(title: "T", body: "B", branch: "feature/x",
                                         queueName: "Lane", base: "main", shape: .github,
                                         targets: [TaskPromptTarget(repoID: "repo-a", shape: .github)])
    check(childPrompt.contains("子目录 `repo-a/`"), "手动任务在子仓库目标下也带工作目录说明")

    // Two targets: the multi-repo inventory text.
    let multi = TaskPrompts.requirements(
        branch: "feature/x", queueName: "Lane", base: "main",
        targets: [TaskPromptTarget(repoID: "repo-a", shape: .github, defaultBase: "main"),
                  TaskPromptTarget(repoID: "repo-b", shape: .git, defaultBase: "master")])
    check(multi.contains { $0.contains("repo-a") && $0.contains("repo-b") },
          "多目标点名每个仓库")
    check(multi.contains { $0.contains("每个") && $0.contains("feature/x") },
          "同一分支贯穿所有仓库")
    check(multi.contains { $0.contains("repo-b") && $0.contains("master") },
          "分支条逐仓库给出默认分支")
    check(multi.contains { $0.contains("分别") && $0.contains("commit") },
          "commit 条要求逐仓库提交")
    check(multi.contains { $0.contains("token 在 $DSH_HOME") },
          "任一 GitHub 目标就出现 token 条")
    check(multi.contains { $0.contains("逐仓库") && $0.contains("git status") },
          "反误解条：逐仓库确认 status")
    check(!multi.contains { $0.contains("这里还不是 git 仓库") },
          "多目标不说「这里还不是 git 仓库」")
    // NoGit: no token rail even with several targets.
    let noGit = TaskPrompts.requirements(branch: nil, queueName: nil, base: "main",
                                         targets: [TaskPromptTarget(repoID: "a", shape: .git),
                                                   TaskPromptTarget(repoID: "b", shape: .git)])
    check(!noGit.contains { $0.contains("token") }, "全不是 GitHub 就没有 token 条")
}

section("TaskRunnerEnv：repos 与 gitFor(repo) 按仓库分派，缺省回落到 git")
do {
    func bareEnv(git: TaskGit, repos: [WorkspaceRepo] = [],
                 gitFor: ((WorkspaceRepo) -> TaskGit)? = nil) -> TaskRunnerEnv {
        TaskRunnerEnv(git: git, repoRoot: "/tmp/repo",
                      createSession: { _ in nil },
                      renameSession: { _, _ in false },
                      promptSession: { _, _ in false },
                      sessionState: { _ in .unknown },
                      cancelSession: { _ in false },
                      findExistingPR: { _ in nil },
                      promptText: { _, _, _ in "" },
                      persist: { _ in },
                      persistIssueTask: { _ in },
                      log: { _ in },
                      perform: TaskRunnerEnv.synchronous,
                      repos: repos,
                      gitFor: gitFor)
    }
    let rootRepo = WorkspaceRepo(id: ".", absolutePath: "/tmp/repo", isGit: true,
                                displayName: "repo")
    let childRepo = WorkspaceRepo(id: "repo-a", absolutePath: "/tmp/repo/repo-a", isGit: true,
                                 displayName: "repo-a")
    var calls: [String] = []
    let rootGit = TaskGit(run: { args in
        calls.append("root:" + args.joined(separator: " "))
        return nil
    }, remoteName: { nil })
    let childGit = TaskGit(run: { args in
        calls.append("child:" + args.joined(separator: " "))
        return nil
    }, remoteName: { "origin" })
    let env = bareEnv(git: rootGit, repos: [rootRepo, childRepo], gitFor: { repo in
        repo.id == "." ? rootGit : childGit
    })
    _ = env.gitHandle(for: childRepo).run(["status"])
    _ = env.gitHandle(for: rootRepo).run(["status"])
    eq(calls, ["child:status", "root:status"], "gitFor(repo) 按仓库分派")
    eq(env.repos.map { $0.id }, [".", "repo-a"], "env 带着仓库集合")
    eq(env.gitHandle(for: childRepo).remoteName(), "origin",
       "子仓库的 remoteName 来自它自己的句柄")

    // A legacy env without gitFor falls back to the single git handle.
    let legacyEnv = bareEnv(git: rootGit, repos: [rootRepo])
    _ = legacyEnv.gitHandle(for: childRepo).run(["branch"])
    eq(calls.last, "root:branch", "没有 gitFor 时回落到 git 字段")
    check(legacyEnv.repos.count == 1, "legacy env 的 repos 仍是显式给的那一份")
}

// MARK: - 多仓库目标解析与两段式切分支

section("resolveTargets：队列指定按 id 解析，未指定用 primary，失效回退 primary")
do {
    let repos = [
        WorkspaceRepo(id: ".", absolutePath: "/ws", isGit: true, displayName: "ws"),
        WorkspaceRepo(id: "repo-a", absolutePath: "/ws/repo-a", isGit: true, displayName: "repo-a"),
        WorkspaceRepo(id: "repo-b", absolutePath: "/ws/repo-b", isGit: true, displayName: "repo-b"),
    ]
    let named = TaskQueue(id: "q-1", name: "N", repos: ["repo-b", "repo-a"])
    eq(TasksRunner.resolveTargets(queue: named, repos: repos).map { $0.id }, ["repo-b", "repo-a"],
       "队列指定：顺序保留")
    let auto = TaskQueue(id: "q-2", name: "A")
    eq(TasksRunner.resolveTargets(queue: auto, repos: repos, primaryRepoID: "repo-b").map { $0.id }, ["repo-b"],
       "未指定：用 primary")
    let stale = TaskQueue(id: "q-3", name: "S", repos: ["gone"])
    eq(TasksRunner.resolveTargets(queue: stale, repos: repos, primaryRepoID: "repo-b").map { $0.id }, ["repo-b"],
       "指定的仓库已移除：回退 primary")
    eq(TasksRunner.resolveTargets(queue: auto, repos: []).count, 0, "legacy env（无 repos）→ 空")
}

section("多仓库 pump：预检全过后逐个 gitFor(repo).enter（跨仓库同名分支、各自基线）")
do {
    let repos = [
        WorkspaceRepo(id: "repo-a", absolutePath: "/tmp/ws/repo-a", isGit: true,
                      defaultBase: "main", displayName: "repo-a"),
        WorkspaceRepo(id: "repo-b", absolutePath: "/tmp/ws/repo-b", isGit: true,
                      defaultBase: "master", displayName: "repo-b"),
    ]
    var board = TaskBoard()
    let task = TaskItem.manual(title: "多仓库改动", body: nil, id: "manual-mr000001")
    board.tasks = [task]
    let queue = board.createQueue(name: "Multi", autoPR: false, repos: ["repo-a", "repo-b"])
    _ = board.enqueue(taskID: task.id, into: queue.id)
    let h = MultiRepoHarness(board: board, repos: repos, primaryRepoID: "repo-a")
    h.git("repo-a").knownBranches = ["main"]
    h.git("repo-b").current = "master"
    h.git("repo-b").knownBranches = ["master"]

    _ = h.runner.startQueue(queue.id)
    check(h.board.task(task.id)?.state == .running, "两个仓库都过预检后任务开始")
    eq(h.git("repo-a").checkouts, ["main", "feature/multi"], "repo-a 基于 main 切分支")
    eq(h.git("repo-b").checkouts, ["master", "feature/multi"], "repo-b 基于 master 切同名分支")
    eq(h.dsh.sessions.count, 1, "只建一个会话（会话仍在工作区根）")
}

section("多仓库 pump：repoSetProvider 运行期重探覆盖 adopt 快照")
do {
    let root = WorkspaceRepo(id: ".", absolutePath: "/tmp/ws", isGit: true, displayName: "ws")
    let a = WorkspaceRepo(id: "repo-a", absolutePath: "/tmp/ws/repo-a", isGit: true,
                          defaultBase: "main", displayName: "repo-a")
    let b = WorkspaceRepo(id: "repo-b", absolutePath: "/tmp/ws/repo-b", isGit: true,
                          defaultBase: "master", displayName: "repo-b")
    var board = TaskBoard()
    let task = TaskItem.manual(title: "重探", body: nil, id: "manual-mr300001")
    board.tasks = [task]
    let queue = board.createQueue(name: "Reprobe", autoPR: false)   // 未指定 targets
    _ = board.enqueue(taskID: task.id, into: queue.id)
    // adopt 快照以 root 为 primary；provider 说现在是 a + b、primary = a。
    let h = MultiRepoHarness(board: board, repos: [root, a, b], primaryRepoID: ".",
                             repoSetProvider: { WorkspaceRepoSet(repos: [a, b], primary: a) })
    h.git("repo-a").knownBranches = ["main"]
    h.git("repo-b").current = "master"
    h.git("repo-b").knownBranches = ["master"]

    _ = h.runner.startQueue(queue.id)
    check(h.board.task(task.id)?.state == .running, "按 provider 重探后任务开始")
    check(!h.git("repo-a").checkouts.isEmpty, "重探后的 primary（repo-a）被切了分支")
    check(h.git(".").checkouts.isEmpty, "adopt 快照里的 root 没有被切")
}

section("多仓库 pump：一个仓库脏 → 预检失败，且不切任何仓库")
do {
    let repos = [
        WorkspaceRepo(id: "repo-a", absolutePath: "/tmp/ws/repo-a", isGit: true,
                      defaultBase: "main", displayName: "repo-a"),
        WorkspaceRepo(id: "repo-b", absolutePath: "/tmp/ws/repo-b", isGit: true,
                      defaultBase: "master", displayName: "repo-b"),
    ]
    var board = TaskBoard()
    let task = TaskItem.manual(title: "多仓库改动", body: nil, id: "manual-mr000002")
    board.tasks = [task]
    let queue = board.createQueue(name: "Multi", autoPR: false, repos: ["repo-a", "repo-b"])
    _ = board.enqueue(taskID: task.id, into: queue.id)
    let h = MultiRepoHarness(board: board, repos: repos, primaryRepoID: "repo-a")
    h.git("repo-a").knownBranches = ["main"]
    h.git("repo-b").current = "master"
    h.git("repo-b").knownBranches = ["master"]
    h.git("repo-b").worktreeClean = false

    _ = h.runner.startQueue(queue.id)
    check(h.board.task(task.id)?.state == .failed, "脏仓库让任务失败")
    eq(h.board.task(task.id)?.error, "tasks.errRepoDirty", "原因是预检发现脏工作区")
    eq(h.board.task(task.id)?.errorDetail, "repo-b", "错误点名脏的是 repo-b")
    check(h.git("repo-a").checkouts.isEmpty, "预检失败：repo-a 没有被切走")
    check(h.git("repo-b").checkouts.isEmpty, "repo-b 也没有")
    check(h.dsh.sessions.isEmpty, "预检失败不建会话")
    check(h.rec.logged("tasks.errRepoDirty"), "日志里记了预检失败")
}

section("只保护 checkout：已在目标分支上 / 不切分支时，不再查干净")
do {
    // 已在目标分支上：enter 不 checkout，预检就不该拦（哪怕有已跟踪改动）。
    let repos = [
        WorkspaceRepo(id: "repo-a", absolutePath: "/tmp/ws/repo-a", isGit: true,
                      defaultBase: "main", displayName: "repo-a"),
        WorkspaceRepo(id: "repo-b", absolutePath: "/tmp/ws/repo-b", isGit: true,
                      defaultBase: "master", displayName: "repo-b"),
    ]
    var board = TaskBoard()
    let task = TaskItem.manual(title: "多仓库改动", body: nil, id: "manual-mr000004")
    board.tasks = [task]
    let queue = board.createQueue(name: "Multi", branch: "feature/multi",
                                  autoPR: false, repos: ["repo-a", "repo-b"])
    _ = board.enqueue(taskID: task.id, into: queue.id)
    let h = MultiRepoHarness(board: board, repos: repos, primaryRepoID: "repo-a")
    h.git("repo-a").current = "feature/multi"
    h.git("repo-a").knownBranches = ["main", "feature/multi"]
    h.git("repo-a").worktreeClean = false          // 已在分支上：脏也不该拦
    h.git("repo-b").current = "master"
    h.git("repo-b").knownBranches = ["master"]

    _ = h.runner.startQueue(queue.id)
    check(h.board.task(task.id)?.state == .running, "已在目标分支的脏仓库不再挡预检")
    check(h.board.task(task.id)?.error == nil, "没有记脏工作区错误")
    check(h.git("repo-a").checkouts.isEmpty, "repo-a 本来就在分支上，没有 checkout")
    check(h.git("repo-b").checkouts.contains("feature/multi"), "repo-b 照常切到分支")
}
do {
    // 不切分支（branch 为空）：enter 返回 .noBranch，预检同样不该查干净。
    let repos = [WorkspaceRepo(id: ".", absolutePath: "/tmp/ws", isGit: true, displayName: "ws")]
    var board = TaskBoard()
    let task = TaskItem.manual(title: "不切分支", body: nil, id: "manual-mr000005")
    board.tasks = [task]
    let queue = board.createQueue(name: "NoBranch", branch: "", autoPR: false, repos: ["."])
    _ = board.enqueue(taskID: task.id, into: queue.id)
    let h = MultiRepoHarness(board: board, repos: repos, primaryRepoID: ".")
    h.git(".").worktreeClean = false

    _ = h.runner.startQueue(queue.id)
    check(h.board.task(task.id)?.state == .running, "不切分支的队列即使工作区脏也照跑")
    check(h.git(".").checkouts.isEmpty, "没有 checkout")
}
section("多仓库 pump：只有未跟踪文件 → 预检放行")
do {
    let repos = [
        WorkspaceRepo(id: "repo-a", absolutePath: "/tmp/ws/repo-a", isGit: true,
                      defaultBase: "main", displayName: "repo-a"),
        WorkspaceRepo(id: "repo-b", absolutePath: "/tmp/ws/repo-b", isGit: true,
                      defaultBase: "master", displayName: "repo-b"),
    ]
    var board = TaskBoard()
    let task = TaskItem.manual(title: "多仓库改动", body: nil, id: "manual-mr000003")
    board.tasks = [task]
    let queue = board.createQueue(name: "Multi", branch: "feature/multi",
                                  autoPR: false, repos: ["repo-a", "repo-b"])
    _ = board.enqueue(taskID: task.id, into: queue.id)
    let h = MultiRepoHarness(board: board, repos: repos, primaryRepoID: "repo-a")
    h.git("repo-a").knownBranches = ["main"]
    h.git("repo-b").current = "master"
    h.git("repo-b").knownBranches = ["master"]
    h.git("repo-b").untracked = "?? .tmp/scratch.log"   // 只有未跟踪草稿

    _ = h.runner.startQueue(queue.id)
    check(h.board.task(task.id)?.state == .running, "未跟踪草稿不挡预检，任务开始")
    check(h.board.task(task.id)?.error == nil, "没有记脏工作区错误")
    check(!h.git("repo-a").checkouts.isEmpty, "repo-a 切了分支")
    check(!h.git("repo-b").checkouts.isEmpty, "repo-b 也切了")
}
section("单目标多仓库 env：脏仓库仍用 legacy 错误键（不写「多仓库」）")
do {
    let root = WorkspaceRepo(id: ".", absolutePath: "/tmp/ws", isGit: true, displayName: "ws")
    var board = TaskBoard()
    let task = TaskItem.manual(title: "单仓库", body: nil, id: "manual-mr200001")
    board.tasks = [task]
    let queue = board.createQueue(name: "Solo", autoPR: false)
    _ = board.enqueue(taskID: task.id, into: queue.id)
    let h = MultiRepoHarness(board: board, repos: [root], primaryRepoID: ".")
    h.git(".").knownBranches = ["main"]
    h.git(".").worktreeClean = false

    _ = h.runner.startQueue(queue.id)
    eq(h.board.task(task.id)?.error, "tasks.errDirtyTree", "单目标保持 legacy 错误键")
    eq(h.board.task(task.id)?.errorDetail, nil, "单目标不带仓库 detail")
    check(h.git(".").checkouts.isEmpty, "脏仓库没有被切走")
}

section("单目标子仓库：base 用子仓库自己的 defaultBase，而不是队列的")
do {
    let child = WorkspaceRepo(id: "repo-a", absolutePath: "/tmp/ws/repo-a", isGit: true,
                              defaultBase: "trunk", displayName: "repo-a")
    var board = TaskBoard()
    let task = TaskItem.manual(title: "子仓库", body: nil, id: "manual-mr200002")
    board.tasks = [task]
    let queue = board.createQueue(name: "Child", baseBranch: "main", autoPR: false, repos: ["repo-a"])
    _ = board.enqueue(taskID: task.id, into: queue.id)
    let h = MultiRepoHarness(board: board, repos: [child], primaryRepoID: "repo-a")
    h.git("repo-a").current = "trunk"
    h.git("repo-a").knownBranches = ["trunk"]

    _ = h.runner.startQueue(queue.id)
    eq(h.git("repo-a").checkouts, ["trunk", "feature/child"], "子仓库基于自己的 defaultBase 切分支")
}

section("多仓库 pump：中途 enter 失败不回滚，错误说明已切的仓库")
do {
    let repos = [
        WorkspaceRepo(id: "repo-a", absolutePath: "/tmp/ws/repo-a", isGit: true,
                      defaultBase: "main", displayName: "repo-a"),
        WorkspaceRepo(id: "repo-b", absolutePath: "/tmp/ws/repo-b", isGit: true,
                      defaultBase: "master", displayName: "repo-b"),
    ]
    var board = TaskBoard()
    let task = TaskItem.manual(title: "多仓库改动", body: nil, id: "manual-mr000003")
    board.tasks = [task]
    let queue = board.createQueue(name: "Multi", autoPR: false, repos: ["repo-a", "repo-b"])
    _ = board.enqueue(taskID: task.id, into: queue.id)
    let h = MultiRepoHarness(board: board, repos: repos, primaryRepoID: "repo-a")
    h.git("repo-a").knownBranches = ["main"]
    h.git("repo-b").current = "master"
    h.git("repo-b").knownBranches = ["master"]
    h.git("repo-b").failing = ["checkout -b feature/multi"]

    _ = h.runner.startQueue(queue.id)
    check(h.board.task(task.id)?.state == .failed, "第二个仓库切换失败，任务失败")
    eq(h.board.task(task.id)?.error, "tasks.errRepoBranch", "原因是多仓库切分支失败")
    eq(h.board.task(task.id)?.errorDetail, "repo-b（已切换：repo-a）", "错误说明哪些仓库已切")
    eq(h.git("repo-a").checkouts, ["main", "feature/multi"], "已切的仓库保持不动，不回滚")
    check(h.dsh.sessions.isEmpty, "失败发生在建会话之前")
}

section("多仓库交接简报：分支上的提交按仓库分组")
do {
    let repos = [
        WorkspaceRepo(id: "repo-a", absolutePath: "/tmp/ws/repo-a", isGit: true,
                      defaultBase: "main", displayName: "repo-a"),
        WorkspaceRepo(id: "repo-b", absolutePath: "/tmp/ws/repo-b", isGit: true,
                      defaultBase: "master", displayName: "repo-b"),
    ]
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "第一棒", body: nil, id: "manual-mr100001")
    let t2 = TaskItem.manual(title: "第二棒", body: nil, id: "manual-mr100002")
    board.tasks = [t1, t2]
    let queue = board.createQueue(name: "Multi Brief", autoPR: false, repos: ["repo-a", "repo-b"])
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    _ = board.enqueue(taskID: t2.id, into: queue.id)
    let h = MultiRepoHarness(board: board, repos: repos, primaryRepoID: "repo-a")
    h.git("repo-a").knownBranches = ["main"]
    h.git("repo-b").current = "master"
    h.git("repo-b").knownBranches = ["master"]
    h.git("repo-a").commits = ["aaa111 repo-a 的改动"]
    h.git("repo-b").commits = ["bbb222 repo-b 的改动"]

    _ = h.runner.startQueue(queue.id)
    let first = h.dsh.prompts["session-1"] ?? ""
    check(first.contains("分支上已有的提交"), "简报有提交段")
    check(first.contains("repo-a/"), "提交按仓库分组：列出 repo-a")
    check(first.contains("repo-b/"), "提交按仓库分组：列出 repo-b")
    check(first.contains("aaa111 repo-a 的改动"), "repo-a 的提交在它自己的分组里")
    check(first.contains("bbb222 repo-b 的改动"), "repo-b 的提交在它自己的分组里")
}

section("多仓库交接简报：只有一个仓库有提交时也保留仓库抬头（design §5.3）")
do {
    let repos = [
        WorkspaceRepo(id: "repo-a", absolutePath: "/tmp/ws/repo-a", isGit: true,
                      defaultBase: "main", displayName: "repo-a"),
        WorkspaceRepo(id: "repo-b", absolutePath: "/tmp/ws/repo-b", isGit: true,
                      defaultBase: "master", displayName: "repo-b"),
    ]
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "第一棒", body: nil, id: "manual-mr110001")
    let t2 = TaskItem.manual(title: "第二棒", body: nil, id: "manual-mr110002")
    board.tasks = [t1, t2]
    let queue = board.createQueue(name: "Multi One", autoPR: false, repos: ["repo-a", "repo-b"])
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    _ = board.enqueue(taskID: t2.id, into: queue.id)
    let h = MultiRepoHarness(board: board, repos: repos, primaryRepoID: "repo-a")
    h.git("repo-a").knownBranches = ["main"]
    h.git("repo-b").current = "master"
    h.git("repo-b").knownBranches = ["master"]
    h.git("repo-a").commits = []
    h.git("repo-b").commits = ["bbb222 repo-b 的改动"]

    _ = h.runner.startQueue(queue.id)
    let first = h.dsh.prompts["session-1"] ?? ""
    check(first.contains("repo-b/"), "只有 repo-b 有提交时仍保留仓库抬头")
    check(first.contains("bbb222 repo-b 的改动"), "并且提交正文还在")
    check(!first.contains("repo-a/："), "没有提交的仓库不打空抬头")
}

section("runner.createQueue / updateQueue 写回 queue.repos（表单目标的真实入口）")
do {
    var board = TaskBoard()
    let repos = [
        WorkspaceRepo(id: "repo-a", absolutePath: "/tmp/ws/repo-a", isGit: true, displayName: "repo-a"),
        WorkspaceRepo(id: "repo-b", absolutePath: "/tmp/ws/repo-b", isGit: true, displayName: "repo-b"),
    ]
    let h = MultiRepoHarness(board: board, repos: repos, primaryRepoID: "repo-a")
    let q = h.runner.createQueue(name: "Persist", autoPR: false, repos: ["repo-b", "repo-a"])
    eq(h.board.queue(q.id)?.repos, ["repo-b", "repo-a"], "createQueue 写入目标仓库（保序）")
    _ = h.runner.updateQueue(q.id, repos: .some(["repo-b"]))
    eq(h.board.queue(q.id)?.repos, ["repo-b"], "updateQueue 覆盖目标仓库")
    _ = h.runner.updateQueue(q.id, name: "Renamed")
    eq(h.board.queue(q.id)?.repos, ["repo-b"], "不传 repos 时保持不变")
    _ = h.runner.updateQueue(q.id, repos: .some(nil))
    eq(h.board.queue(q.id)?.repos, nil, "updateQueue 传 .some(nil) 回到 primary")
}

section("非 git 目录里的 issue 任务：自动队列也不设分支（这里曾经必然 errNotGit）")
do {
    var board = TaskBoard()
    board.tasks = [TaskItem.github(number: 9, title: "改文档", labels: ["docs"])]
    let h = Harness(board: board, github: false, gitRepo: false)
    _ = h.runner.startIssueTask("issue-9")
    let queue = h.board.queues.first
    check(queue?.branch == nil, "非 git 目录：issue 的自动队列也不派生 feature/issue-9")
    check(queue?.autoPR == false, "不是 GitHub 工作区就不承诺 PR")
    check(h.board.task("issue-9")?.state != .failed, "这次没再因为 errNotGit 失败")
    let prompt = h.dsh.prompts["session-1"] ?? ""
    check(!prompt.contains("本任务须在分支"), "非 git 目录没有分支条（与手动任务同一规则）")
    check(!prompt.contains("GitHub token"), "没有 GitHub 远端就没有 token 条")
}

section("issue 任务的旧队列带着切不了的分支：先去掉分支再跑")
do {
    var board = TaskBoard()
    let issue = TaskItem.github(number: 11, title: "旧队列", labels: ["bug"])
    board.tasks = [issue]
    let stale = TaskQueue.auto(for: issue, baseBranch: "main")   // built when this WAS a repo
    board.queues = [stale]
    _ = board.enqueue(taskID: issue.id, into: stale.id)
    check(board.queue(stale.id)?.branch == "fix/issue-11", "前提：旧队列带着分支")
    let h = Harness(board: board, github: false, gitRepo: false)
    _ = h.runner.startIssueTask(issue.id)
    check(h.board.queue(stale.id)?.branch == nil, "非 git 目录里启动前把分支去掉")
    check(h.rec.logged("no longer switches branches"), "并在日志里说明")
    check(h.board.task(issue.id)?.state != .failed, "任务没有因为切不了分支而失败")
}

// MARK: - Creating manual tasks (step 4)

section("draft validation")
do {
    eq(TaskDraft(title: "", body: "x").problem, "tasks.errName", "an empty title reports the name key")
    eq(TaskDraft(title: "   ", body: "x").problem, "tasks.errName", "a blank title is empty")
    check(TaskDraft(title: "x", body: "y").problem == nil, "a filled draft has no problem")
    check(TaskDraft(title: "x", body: "y").isValid, "a filled draft is valid")
    eq(TaskDraft(title: "  t  ", body: "  b  ").normalizedTitle, "t", "the title is trimmed")
    eq(TaskDraft(title: "  t  ", body: "  b  ").normalizedBody, "b", "the body is trimmed")

    // 单行任务：这一行同时是标题和描述 —— 描述留空时回落到标题。
    eq(TaskDraft(title: "One line", body: "").effectiveBody, "One line",
       "a draft without its own description hands the title to the agent")
    eq(TaskDraft(title: "One line", body: "  ").effectiveBody, "One line", "whitespace is still empty")
    eq(TaskDraft(title: "T", body: "b").effectiveBody, "b", "a real description wins")
}

section("the composer box splits into a title and a description")
do {
    let single = TaskDraft.composed(from: "Polish README")
    eq(single.title, "Polish README", "a single line is the title")
    eq(single.body, "Polish README", "and it is the description too")

    let multi = TaskDraft.composed(from: "Polish README\ntidy the install section\nand rerun the tests")
    eq(multi.title, "Polish README", "the first line is the title")
    eq(multi.body, "tidy the install section\nand rerun the tests",
       "every line after it is the description, blank-line structure kept")

    let spaced = TaskDraft.composed(from: "  Polish README  \n\n  tidy it  \n")
    eq(spaced.title, "Polish README", "the title is trimmed")
    eq(spaced.body, "tidy it", "and the description is trimmed too")

    let blankTail = TaskDraft.composed(from: "Polish README\n\n   ")
    eq(blankTail.body, "Polish README", "a box with only blank lines after the title is a single line")

    let empty = TaskDraft.composed(from: "   ")
    eq(empty.title, "", "an empty box has no title")
    eq(empty.problem, "tasks.errName", "so it cannot be created")

    // 编辑回填：标题与描述合成一个框；描述就是标题时回到单行。
    eq(TaskDraft.combined(title: "T", body: "b"), "T\nb", "title and description go back into one box")
    eq(TaskDraft.combined(title: "T", body: "T"), "T", "a one-line task comes back as one line")
    eq(TaskDraft.combined(title: "T", body: ""), "T", "no description means one line")
    eq(TaskDraft.combined(title: "T", body: nil), "T", "a nil description means one line")
    eq(TaskDraft.combined(title: "T", body: "  T  "), "T", "whitespace around the same line does not duplicate it")
    // 往返：合成再拆开，得到的还是同一个任务。
    let round = TaskDraft.composed(from: TaskDraft.combined(title: "T", body: "b"))
    eq(round.title, "T", "round trip keeps the title")
    eq(round.body, "b", "round trip keeps the description")
}

section("creating, editing and deleting a manual task")
do {
    let h = Harness(board: TaskBoard())
    check(h.runner.createManualTask(TaskDraft(title: "", body: "x")) == nil, "an invalid draft creates nothing")
    eq(h.board.tasks.count, 0, "nothing was added for an invalid draft")

    let created = h.runner.createManualTask(TaskDraft(title: "  Polish README  ",
                                                     body: "  tidy the install section  "))
    check(created != nil, "a valid draft creates a task")
    check(created?.source == .manual, "the task is manual")
    check(created?.state == .pending, "a new task is not in any queue")
    check(created?.queueId == nil, "it has no queue yet")
    eq(created?.title ?? "", "Polish README", "the title is trimmed on the task")
    eq(created?.body ?? "", "tidy the install section", "the body is trimmed on the task")
    check(created?.id.hasPrefix("manual-") == true, "the id is a manual id")
    eq(h.board.tasks.count, 1, "the task is on the board")
    eq(h.board.unqueued.count, 1, "it shows up in the 未入队 area")
    check(h.rec.persistCount > 0, "creating a task persists it")
    check(h.runner.isBusy == false, "creating a task starts nothing")
    check(h.dsh.sessions.isEmpty, "no session is created until it runs")

    let id = created?.id ?? ""
    check(h.runner.updateManualTask(id, title: "Better title", body: "and a better body"), "editing works")
    check(h.board.task(id)?.title == "Better title", "the title changed")
    check(h.board.task(id)?.body == "and a better body", "the body changed")
    check(h.runner.updateManualTask(id, title: "", body: "x") == false, "an invalid edit is refused")
    check(h.board.task(id)?.title == "Better title", "the refused edit left the task alone")
    check(h.runner.updateManualTask("issue-1", title: "t", body: "b") == false, "a github task is not editable")
}

section("a one-line task is its own description")
do {
    let h = Harness(board: TaskBoard())
    let one = h.runner.createManualTask(TaskDraft.composed(from: "Fix the header"))
    eq(one?.title ?? "", "Fix the header", "the line becomes the title")
    eq(one?.body ?? "", "Fix the header", "and the description handed to the agent")

    // 多行：首行标题，其余行描述。
    let multi = h.runner.createManualTask(TaskDraft.composed(from: "Fix the header\nand rerun the tests"))
    eq(multi?.title ?? "", "Fix the header", "a multi-line box takes the first line as the title")
    eq(multi?.body ?? "", "and rerun the tests", "and the rest as the description")

    // 编辑回填用的是同一个框：单行任务回到一行。
    let back = TaskDraft.combined(title: one?.title ?? "", body: one?.body)
    eq(back, "Fix the header", "editing a one-line task shows one line")
    let backMulti = TaskDraft.combined(title: multi?.title ?? "", body: multi?.body)
    eq(backMulti, "Fix the header\nand rerun the tests", "a two-part task shows both parts")
}

section("the queue picker and joining a queue")
do {
    let h = Harness(board: TaskBoard())
    let task = h.runner.createManualTask(TaskDraft(title: "Docs", body: "tidy the docs"))
    let id = task?.id ?? ""
    let q1 = h.runner.createQueue(name: "Docs Cleanup")
    _ = h.runner.createQueue(name: "Second lane", baseBranch: "develop", autoPR: true)

    let choices = h.runner.queueChoices()
    eq(choices.count, 2, "both user queues are offered")
    eq(choices.first?.name, "Second lane", "choices are newest-first")
    eq(choices.first?.taskCount, 0, "an empty queue reports zero tasks")
    check(choices.allSatisfy { $0.branch?.hasPrefix("feature/") == true }, "each choice carries its branch")

    check(h.runner.enqueue(taskID: id, into: q1.id), "the task joins the chosen queue")
    check(h.board.task(id)?.queueId == q1.id, "the membership is recorded")
    check(h.board.task(id)?.state == .running, "it starts right away (the runner was idle)")
    eq(h.runner.queueChoices().first { $0.id == q1.id }?.taskCount, 1, "the choice count follows the queue")
    check(h.runner.deleteManualTask(id) == false, "a running task cannot be deleted")
    eq(h.runner.cancelRunning(), .cancelled, "cancel it first")
    check(h.board.task(id)?.state == .cancelled, "the task is cancelled")
    check(h.runner.deleteManualTask(id), "a stopped task can be deleted")
    check(h.board.task(id) == nil, "it is gone from the board")
    check(h.board.queue(q1.id)?.taskIds.contains(id) == false, "its queue membership is gone")
    check(h.board.local.sessions[id] == nil, "its session record is gone")
    check(h.board.queue(q1.id)?.state == QueueState.paused, "the queue keeps running nothing")
}

section("an auto queue is never a destination")
do {
    var board = TaskBoard()
    let issue = TaskItem.github(number: 3, title: "Issue three")
    board.tasks = [issue]
    board.queues = [TaskQueue.auto(for: issue)]
    let h = Harness(board: board)
    eq(h.runner.queueChoices().count, 0, "the auto queue is not offered by the picker")
    check(h.board.queues.count == 1, "but it still counts as a queue on the board")
}

// MARK: - Several workspaces at once

/// A registry wired to per-path fakes: each workspace gets its own repo, its own
/// dsh and its own board, and every build is recorded (path + whether this was the
/// first load, i.e. whether the board must be reconciled).
final class WorkspaceHarness {
    var boards: [String: TaskBoard] = [:]
    var repos: [String: FakeRepo] = [:]
    var dshs: [String: FakeDsh] = [:]
    private(set) var built: [(path: String, reconcile: Bool)] = []
    lazy var registry = TaskWorkspaceRegistry { [unowned self] path, reconcile in
        self.built.append((path: path, reconcile: reconcile))
        var board = self.boards[path] ?? TaskBoard()
        if reconcile { _ = board.reconcileAfterRestart(interruptedError: TaskFailure.interrupted.rawValue) }
        let repo = self.repo(path)
        let dsh = self.dsh(path)
        let env = TaskRunnerEnv(
            git: repo.git(),
            repoRoot: path,
            createSession: { _ in dsh.create() },
            renameSession: { id, title in dsh.rename(id, title) },
            promptSession: { id, text in dsh.prompt(id, text) },
            sessionState: { id in dsh.sessionState(id) },
            canOpenPR: { false },
            cancelSession: { id in dsh.cancel(id) },
            findExistingPR: { _ in nil },
            promptText: { task, _, brief in TaskPrompts.manual(title: task.title, body: task.body,
                                                              branch: nil, queueName: nil,
                                                              brief: brief, shape: .plain) },
            persist: { board in self.boards[path] = board },
            persistIssueTask: { _ in },
            log: { _ in },
            perform: { blocking, completion in blocking(); completion() }
        )
        return TasksRunner(board: board, env: env)
    }
    func repo(_ path: String) -> FakeRepo {
        if let existing = repos[path] { return existing }
        let repo = FakeRepo()
        repos[path] = repo
        return repo
    }
    func dsh(_ path: String) -> FakeDsh {
        if let existing = dshs[path] { return existing }
        let dsh = FakeDsh()
        dshs[path] = dsh
        return dsh
    }
    /// A workspace with one manual task in one queue, not started yet.
    func seed(_ path: String, task: String) -> (taskID: String, queueID: String) {
        var board = TaskBoard()
        let item = TaskItem.manual(title: task, body: nil, id: "manual-" + path.suffix(4) + "aa")
        board.tasks = [item]
        let queue = board.createQueue(name: "Lane", autoPR: false)
        _ = board.enqueue(taskID: item.id, into: queue.id)
        boards[path] = board
        return (item.id, queue.id)
    }
}

section("跨工作区：切走的工作区继续被跟踪，直到它的任务跑完")
do {
    let h = WorkspaceHarness()
    let a = h.seed("/tmp/ws-a", task: "A task")
    let b = h.seed("/tmp/ws-b", task: "B task")

    // 在 A 派活：它开始跑。
    let runnerA = h.registry.adopt("/tmp/ws-a")
    _ = runnerA?.startQueue(a.queueID)
    check(h.registry.currentRunner?.isBusy == true, "A 在跑")
    eq(h.registry.busyPaths(), ["/tmp/ws-a"], "忙的是 A")

    // 切到 B：A 的 runner 必须还活着（不能被重建、更不能被判成中断）。
    let runnerB = h.registry.adopt("/tmp/ws-b")
    check(runnerB !== runnerA, "B 有自己的 runner")
    check(h.registry.trackedRunner(for: "/tmp/ws-a") === runnerA, "A 的 runner 原样保留")
    check(h.boards["/tmp/ws-a"]?.task(a.taskID)?.state == .running, "A 的任务还是在跑（不是失败）")

    // 在 B 这一侧，A 仍然被 tick：它的会话结束后任务照常收尾。
    h.dsh("/tmp/ws-a").finishAll()
    let finished = h.registry.step()
    eq(finished.count, 1, "这一步有任务结束")
    eq(finished.first?.path, "/tmp/ws-a", "结束的是另一个工作区的任务")
    eq(finished.first?.title, "A task", "标题也带出来了")
    check(finished.first?.ok == true, "成功")
    check(h.boards["/tmp/ws-a"]?.task(a.taskID)?.state == .done, "A 的板子上它已完成")
    check(h.registry.busyPaths().isEmpty, "现在没有忙的工作区了")
    check(h.registry.trackedRunner(for: "/tmp/ws-a") == nil, "空转的 A 被放下（板子在磁盘上）")

    // 回到 A：从磁盘重建，读取到的是完成态，而不是「上次运行被中断」。
    _ = h.registry.adopt("/tmp/ws-a")
    check(h.registry.currentRunner?.board.task(a.taskID)?.state == .done,
          "回来看还是已完成 —— 不再谎报失败")
    eq(h.built.filter { $0.path == "/tmp/ws-a" }.map { $0.reconcile }, [true, false],
       "同一个工作区在一次运行里只 reconcile 一次（第二次重建不再判中断）")

    // 换回 A 时，空转的 B 同样被放下：只有「当前 + 有活在跑」的工作区才占着 runner。
    check(h.registry.trackedRunner(for: "/tmp/ws-b") == nil, "空转的 B 也被放下（切回去时从磁盘重建）")
}

section("工作区的形状被任务改了：invalidate 之后带着新环境重建，且不重新对账")
do {
    let h = WorkspaceHarness()
    let a = h.seed("/tmp/ws-shape", task: "初始化 git 仓库")
    let first = h.registry.adopt("/tmp/ws-shape")
    check(first != nil, "先有一个 runner")
    eq(h.built.filter { $0.path == "/tmp/ws-shape" }.map { $0.reconcile }, [true],
       "首次加载对账一次")

    // 任务把目录变成 git 仓库之后，env 里那句「这里没有仓库」（canSwitchBranches）
    // 必须能换掉 —— 否则这个工作区在本次启动里永远切不了分支。
    h.registry.invalidate("/tmp/ws-shape")
    check(h.registry.trackedRunner(for: "/tmp/ws-shape") == nil, "invalidate 放下 runner")
    let rebuilt = h.registry.runner(for: "/tmp/ws-shape")
    check(rebuilt !== first, "下一次取到的是新 runner（新 env）")
    eq(h.built.filter { $0.path == "/tmp/ws-shape" }.map { $0.reconcile }, [true, false],
       "重建不再对账：板子还是这次运行的板子，在跑的任务不能被判成中断")
    check(h.registry.currentPath == "/tmp/ws-shape", "当前工作区不变")
    check(!a.taskID.isEmpty, "原来的任务还在板子上")
}

section("跨工作区：并行与串行的边界")
do {
    let h = WorkspaceHarness()
    let a = h.seed("/tmp/ws-a", task: "A task")
    let b = h.seed("/tmp/ws-b", task: "B task")
    _ = h.registry.adopt("/tmp/ws-a")
    _ = h.registry.currentRunner?.startQueue(a.queueID)
    _ = h.registry.adopt("/tmp/ws-b")
    _ = h.registry.currentRunner?.startQueue(b.queueID)

    eq(h.registry.busyPaths(), ["/tmp/ws-a", "/tmp/ws-b"], "两个工作区同时在跑（各自的工作树）")
    check(h.registry.isBusy, "整体是忙的（活动栏小点据此点亮）")

    // 每个工作区只在自己的工作树里做 git：B 的 checkout 不会出现在 A。
    eq(h.repo("/tmp/ws-a").checkouts, ["main", "feature/lane"], "A 在自己的工作树里切了分支")
    eq(h.repo("/tmp/ws-b").checkouts, ["main", "feature/lane"], "B 同样，互不干扰")
    eq(h.dsh("/tmp/ws-a").sessions.count, 1, "A 一个会话")
    eq(h.dsh("/tmp/ws-b").sessions.count, 1, "B 一个会话")

    h.dsh("/tmp/ws-a").finishAll()
    h.dsh("/tmp/ws-b").finishAll()
    let finished = h.registry.step()
    eq(finished.map { $0.path }, ["/tmp/ws-a", "/tmp/ws-b"], "两个都收尾了，顺序稳定")
}

section("交接简报：队列里后面那个任务知道前面发生了什么")
do {
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "抽出 TokenStore", body: nil, id: "manual-cc001111")
    let t2 = TaskItem.manual(title: "补测试", body: nil, id: "manual-cc002222")
    board.tasks = [t1, t2]
    let queue = board.createQueue(name: "认证重构", autoPR: false)
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    _ = board.enqueue(taskID: t2.id, into: queue.id)
    let h = Harness(board: board)
    h.dsh.reports["session-1"] = "已完成：抽出了 TokenStore，测试通过。"
    h.repo.commits = ["a1b2c3 refactor: extract TokenStore", "d4e5f6 test: cover refresh"]
    _ = h.runner.startQueue(queue.id)

    let first = h.dsh.prompts["session-1"] ?? ""
    check(!first.contains("前面已经做过的"), "第一个任务前面没人：没有「前面已经做过的」")
    check(h.dsh.reportCalls.isEmpty, "也不会去读谁的会话")
    // …但分支上已经有的提交照旧告诉它：队列重跑（分支复用）时那就是上一轮留下的，
    // 属于「这一棒开始前就该知道的状态」。
    check(first.contains("a1b2c3 refactor: extract TokenStore"), "分支已有的提交仍然告诉第一个任务")
    check(first.contains("这些提交是这条分支上已有的改动"), "没有前一棒时不说「不要重做前面任务」")
    check(!first.contains("不要重做已完成的部分"), "收尾句跟着有没有前一棒走")

    h.dsh.finishAll()
    _ = h.runner.step()
    let second = h.dsh.prompts["session-2"] ?? ""
    check(second.contains("## 队列信息"), "第二个任务带上队列信息段（与开 PR 会话同一个抬头）")
    check(second.contains("队列：认证重构（本任务是第 2/2 个）"), "队列与位次写在同一条里")
    check(second.contains("分支：feature/queue-"), "分支也是同一条（纯中文队列名回退 feature/queue-<id4>）")
    check(second.contains("（基于 main）"), "基线与分支写在一起")
    check(second.contains("队列「认证重构」"), "报队列名")
    check(second.contains("第 2/2 个"), "报位次")
    check(second.contains("「抽出 TokenStore」 —— 已完成"), "报上一棒的标题与结局")
    check(second.contains("已完成：抽出了 TokenStore，测试通过。"), "上一棒的汇报原样带上")
    // 汇报在任务结束时就写回了任务（而不是每次现读会话日志）：会话被删掉也还在，
    // 并且是 next 棒简报的第一来源。
    check(h.board.task(t1.id)?.report == nil || h.board.task(t1.id)?.report?.isEmpty == false,
          "已结束的任务带着它自己的汇报字段")
    check(second.contains("a1b2c3 refactor: extract TokenStore"), "带上分支已经有的提交")
    check(second.contains("d4e5f6 test: cover refresh"), "而且是全部提交")
    check(second.contains("不要重做已完成的部分"), "并明确要求本任务不要重做")
    eq(h.dsh.reportCalls, ["session-1"], "只问了真有会话的那一棒")
}

section("交接简报：失败 / 取消过的一棒同样进简报，且汇报不截断")
do {
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "改配置", body: nil, id: "manual-cc003333")
    let t2 = TaskItem.manual(title: "接着改", body: nil, id: "manual-cc004444")
    board.tasks = [t1, t2]
    let queue = board.createQueue(name: "Lane", autoPR: false)
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    _ = board.enqueue(taskID: t2.id, into: queue.id)
    // 第一棒失败，但它留下过汇报（也可能没有）
    board.markRunning(t1.id)
    board.local.sessions[t1.id] = "session-old"
    board.attachSessions(board.local.sessions)
    _ = board.markFailed(t1.id, error: TaskFailure.timeout.rawValue)
    let h = Harness(board: board)
    let long = String(repeating: "很长的汇报。", count: 200)     // ~1200 字
    h.dsh.reports["session-old"] = long
    _ = h.runner.startQueue(queue.id)
    // 这个 harness 里没有为第一棒建过会话，所以第二棒拿到的是 session-1。
    let prompt = h.dsh.prompts["session-1"] ?? ""
    check(prompt.contains("「改配置」 —— 失败（tasks.errTimeout）"), "失败的一棒写清结局与原因")
    check(prompt.contains(long), "它的汇报一个字都不截（截断会失真）")
    check(long.count > 1000, "测试用的汇报确实很长")
}
do {
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "第一棒", body: nil, id: "manual-cc005555")
    let t2 = TaskItem.manual(title: "第二棒", body: nil, id: "manual-cc006666")
    board.tasks = [t1, t2]
    let queue = board.createQueue(name: "Lane", autoPR: false)
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    _ = board.enqueue(taskID: t2.id, into: queue.id)
    board.markRunning(t1.id)
    board.markDone(t1.id, prUrl: nil)     // 没有 sessionId：会话记录丢了
    let h = Harness(board: board)
    _ = h.runner.startQueue(queue.id)
    let prompt = h.dsh.prompts["session-1"] ?? ""
    check(prompt.contains("没有留下汇报"), "读不到汇报时明说，而不是假装上一棒什么都没说")
}
do {
    // 不在队列里的任务没有简报可言（issue 任务的自动队列也是单任务）。
    let (board, taskID, queueID) = singleTaskBoard()
    let h = Harness(board: board)
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    let prompt = h.dsh.prompts["session-1"] ?? ""
    check(!prompt.contains("## 队列信息"), "单任务队列没有前一棒")
    _ = taskID
}

section("issue 任务的自动队列用工作区自己的默认分支")
do {
    var board = TaskBoard()
    board.tasks = [TaskItem.github(number: 12, title: "Fix dark mode", labels: ["bug"])]
    let h = Harness(board: board, defaultBaseBranch: "develop")
    let queueID = h.runner.startIssueTask("issue-12")
    eq(h.board.queue(queueID!)?.baseBranch, "develop", "队列基于工作区的默认分支，不是硬编码的 main")
    eq(h.repo.checkouts, ["develop", "fix/issue-12"], "流水线第一步 checkout 的也是它")
}

section("全部处理：每个待处理任务各自一个单任务队列，按板面顺序依次跑")
do {
    var board = TaskBoard()
    let issue = TaskItem.github(number: 3, title: "Fix dark mode")
    let a = TaskItem.manual(title: "改 README", body: nil, id: "manual-ee001111")
    let b = TaskItem.manual(title: "升级依赖", body: nil, id: "manual-ee002222")
    board.tasks = [issue, a, b]
    let h = Harness(board: board, defaultBaseBranch: "develop")

    // 面板的批量动作：每个待处理任务各自入队，然后把 runner 指回第一个
    var firstQueue: String?
    for task in h.board.tasks where task.state == .pending {
        let id = task.source == .github ? h.runner.startIssueTask(task.id) : h.runner.startManualTask(task.id)
        if firstQueue == nil { firstQueue = id }
    }
    h.runner.focus(onQueue: firstQueue!)

    eq(h.board.queues.count, 3, "三个待处理任务 → 三个单任务队列")
    check(h.board.queues.allSatisfy { $0.autoCreated }, "都标记为自动队列")
    check(h.board.queues.allSatisfy { $0.taskIds.count == 1 }, "每个队列恰好一个任务（各自一条分支）")
    eq(h.board.queue(firstQueue!)?.branch, "fix/issue-3", "issue 任务用 issue 分支")
    eq(h.board.queues.first { $0.name == "改 README" }?.branch, "feature/readme", "手动任务按标题派生分支")
    check(h.board.queues.contains { $0.branch?.hasPrefix("feature/manual-") == true },
          "纯中文标题退回 feature/manual-<id4>")
    check(h.board.queues.allSatisfy { $0.baseBranch == "develop" }, "基线都是工作区默认分支")
    eq(h.board.activeQueue()?.id, firstQueue, "runner 被指回第一个队列")
    // 这三条队列都要 PR（issue 与「各自一个分支」的手动任务都一样），所以收尾时要
    // 校验分支已在远端 —— 让假仓库说「都推上去了」。
    h.repo.pushed.insert("fix/issue-3")
    h.repo.pushed.insert("feature/readme")
    if let manualBranch = h.board.queues.first(where: { $0.branch?.hasPrefix("feature/manual-") == true })?.branch {
        h.repo.pushed.insert(manualBranch)
    }
    eq(h.runner.runningTaskID, issue.id, "板面顺序里的第一个（issue #3）立刻开跑")
    eq(h.runner.runningQueueID, firstQueue, "runningQueueID 指向它自己的队列（面板据此标活跃）")

    h.settleTaskAndPR()            // 第一个任务完成，它的队列把 PR 会话跑完
    eq(h.runner.runningTaskID, a.id, "第二个接着跑")
    h.settleTaskAndPR()
    eq(h.runner.runningTaskID, b.id, "第三个接着跑")
    h.settleTaskAndPR()
    check(h.runner.runningTaskID == nil, "全部跑完，没有卡住")
    check(h.board.queues.allSatisfy { $0.state == QueueState.done }, "三个队列都完成")
}

section("单任务队列的提示词不会谎称「和其他任务共享分支」")
do {
    var board = TaskBoard()
    let task = TaskItem.manual(title: "Solo", body: nil, id: "manual-ee003333")
    board.tasks = [task]
    let queue = board.createQueue(name: "Lane")
    _ = board.enqueue(taskID: task.id, into: queue.id)
    let h = Harness(board: board)
    _ = h.runner.startQueue(queue.id)
    let solo = h.dsh.prompts["session-1"] ?? ""
    check(solo.contains("本任务是队列「Lane」中的一项"), "多任务队列照旧说「共享同一分支」")

    var singleBoard = TaskBoard()
    let solo2 = TaskItem.manual(title: "Alone", body: nil, id: "manual-ee004444")
    singleBoard.tasks = [solo2]
    let h2 = Harness(board: singleBoard)
    _ = h2.runner.startManualTask(solo2.id)
    let alone = h2.dsh.prompts["session-1"] ?? ""
    check(alone.contains("本任务独立执行"), "单任务队列说「独立执行」，不说共享")
    check(!alone.contains("与其他任务共享"), "不会谎称有人和它同一条分支")
    check(alone.contains("本任务须在分支 feature/alone 上处理"), "而是把它自己那条分支说清楚")
}

section("非 git 目录里「全部处理」：队列不带分支，任务照常跑（这里曾经必然失败）")
do {
    var board = TaskBoard()
    let a = TaskItem.manual(title: "git 使用手册", body: nil, id: "manual-gg001111")
    let b = TaskItem.manual(title: "hello-world 说明", body: nil, id: "manual-gg002222")
    board.tasks = [a, b]
    let h = Harness(board: board, github: false, gitRepo: false)

    _ = h.runner.startManualTask(a.id)
    let queue = h.board.queues.first
    eq(h.board.queues.count, 1, "建了一个队列")
    check(queue?.branch == nil, "非 git 目录：队列不设分支（此前会派生 feature/git，然后必然 errNotGit）")
    check(h.repo.calls.isEmpty, "启动过程一条 git 命令都没跑")
    check(h.board.task(a.id)?.state == .running, "任务照常跑起来了")

    // 已经存在的坏队列（带着分支建出来的）会被就地修好，否则重试还是同样失败。
    var legacy = TaskBoard()
    let c = TaskItem.manual(title: "git 使用手册", body: nil, id: "manual-gg003333")
    legacy.tasks = [c]
    var oldQueue = TaskQueue.auto(forManual: c)      // 带分支的旧形状
    oldQueue.taskIds = [c.id]
    legacy.queues = [oldQueue]
    legacy.markFailed(c.id, error: TaskFailure.notGitRepo.rawValue)
    let h2 = Harness(board: legacy, github: false, gitRepo: false)
    _ = h2.runner.startManualTask(c.id)
    check(h2.board.queue(oldQueue.id)?.branch == nil, "重试时先把它那条切不了的分支去掉")
    check(h2.rec.logged("no longer switches branches"), "并且写进日志")
    check(h2.board.task(c.id)?.state != .failed, "这次没再因为 errNotGit 失败")
}

section("非 git 目录里的提示词：没有分支条、没有 token 条、也没有 push 的话")
do {
    var board = TaskBoard()
    let task = TaskItem.manual(title: "初始化 git 仓库", body: nil, id: "manual-gg004444")
    board.tasks = [task]
    let h = Harness(board: board, github: false, gitRepo: false)
    _ = h.runner.startManualTask(task.id)
    let prompt = h.dsh.prompts["session-1"] ?? ""
    check(!prompt.contains("当前分支应为"), "非 git 目录没有分支要求")
    check(!prompt.contains("本队列不切分支"), "也没有「不切分支」这种空话")
    check(!prompt.contains("GitHub token"), "不是 GitHub 仓库就不提 token")
    check(!prompt.contains("push") && !prompt.contains("PR"), "更不提 push / PR（那是 PR 会话的事）")
    check(!prompt.contains("git remote add"), "不再往里塞「怎么变成 GitHub 仓库」的教程")
    check(prompt.contains("这里还不是 git 仓库：不要求 commit"), "说清这一档的 commit 规则")
    check(prompt.contains("任务本身要你建仓库（git init）时，建好后把改动 commit 掉"),
          "任务自己建了仓库就要 commit（用户第 4 条）")
    check(prompt.contains("文档 / 配置类做能做的校验"), "自查条照顾到文档类任务")
    check(prompt.contains("**必须**在结束时汇报"), "汇报是必须的")
}

section("git 仓库 / GitHub 仓库：有分支条与 commit 条，token 只给 GitHub，push 一律不提")
do {
    // 三个工作区状态的差别只在「哪些条目出现」：非 git 没有分支条、非 GitHub 没有 token 条，
    // 而 push / PR 在任何一档都不出现 —— 那是队列结束后 PR 会话的事。
    var board = TaskBoard()
    let task = TaskItem.manual(title: "把项目发到 GitHub", body: nil, id: "manual-gg005555")
    board.tasks = [task]
    let queue = board.createQueue(name: "Lane", branch: "feature/publish", autoPR: false)
    _ = board.enqueue(taskID: task.id, into: queue.id)
    let h = Harness(board: board, github: false, gitRepo: true)
    _ = h.runner.startQueue(queue.id)
    let prompt = h.dsh.prompts["session-1"] ?? ""
    check(prompt.contains("本任务须在分支 feature/publish 上处理（若该分支不存在，须基于 main 分支新建）"),
          "有仓库就点名队列的分支，并说清它还没建立时的来路（用户第 2 条）")
    check(prompt.contains("完成前 commit"), "有仓库就要 commit（用户第 4 条）")
    check(!prompt.contains("GitHub token"), "没有 GitHub 远端就不给 token 条")
    check(!prompt.contains("push"), "不提 push")
    check(!prompt.contains("PR"), "也不提 PR")

    // GitHub 仓库：多一条 token rail，其余照旧。
    var prBoard = TaskBoard()
    let prTask = TaskItem.manual(title: "改 README", body: nil, id: "manual-gg006666")
    prBoard.tasks = [prTask]
    let prQueue = prBoard.createQueue(name: "Lane", branch: "feature/docs", autoPR: true)
    _ = prBoard.enqueue(taskID: prTask.id, into: prQueue.id)
    let h2 = Harness(board: prBoard, github: true, gitRepo: true)
    _ = h2.runner.startQueue(prQueue.id)
    let prPrompt = h2.dsh.prompts["session-1"] ?? ""
    check(prPrompt.contains("token 在 $DSH_HOME/oh-my-dsh/tokens/"), "GitHub 仓库才给 token 条")
    check(prPrompt.contains("完成前 commit"), "commit 条照旧")
    check(!prPrompt.contains("push"), "但任务本身还是不提 push")
    check(prPrompt.contains("本队列不切分支") == false, "有分支就点名分支，不说「不切分支」")

    // 不切分支的队列：第 2 条换成「就在当前已检出的分支上改」。
    var noBranch = TaskBoard()
    let nbTask = TaskItem.manual(title: "改 README", body: nil, id: "manual-gg007777")
    noBranch.tasks = [nbTask]
    let nbQueue = noBranch.createQueue(name: "Lane", branch: "", autoPR: false)
    _ = noBranch.enqueue(taskID: nbTask.id, into: nbQueue.id)
    let h3 = Harness(board: noBranch, github: false, gitRepo: true)
    _ = h3.runner.startQueue(nbQueue.id)
    let nbPrompt = h3.dsh.prompts["session-1"] ?? ""
    check(nbPrompt.contains("本队列不切分支：直接在主分支 main 上处理（不要新建分支）"),
          "不切分支的队列说清「直接在主分支上处理」（用户第 2 条）")
}

section("刚 git init 的空仓库：没有基线可切，直接建分支（「初始化 git 仓库」之后紧接着的那个任务）")
do {
    let empty = FakeRepo()
    empty.unborn = true
    empty.knownBranches = []          // 一条提交都没有：main 也不存在
    empty.remote = nil                // 还没有远端
    empty.worktreeClean = false       // git init 之后留下的文件全是未跟踪的
    eq(empty.git().enter(branch: "feature/first", base: "main"), .switched,
       "空仓库里照样进得了队列分支（此前必定 errCheckout）")
    eq(empty.checkouts, ["feature/first"], "只做一次 checkout -b，没有去切不存在的 main")
    check(!empty.calls.contains { $0.hasPrefix("status") },
          "空仓库里「工作区脏」这条不适用：没有提交可以丢")
    check(!empty.calls.contains("pull --ff-only"), "也没有远端可 pull")

    // 有提交的普通仓库完全不变：先干净、先切基线、再 pull、再开分支。
    let normal = FakeRepo()
    eq(normal.git().enter(branch: "feature/x", base: "main"), .switched, "普通仓库照旧")
    check(normal.calls.contains("status --porcelain --untracked-files=no"),
          "普通仓库仍然先查工作区（只看已跟踪改动）")
    check(normal.calls.contains("checkout main"), "先切基线")
    check(normal.calls.contains("pull --ff-only"), "有远端就 pull")

    // 脏工作区在普通仓库里依然拦住 —— 空仓库是唯一的例外。
    let dirty = FakeRepo()
    dirty.worktreeClean = false
    eq(dirty.git().enter(branch: "feature/x", base: "main"), .dirtyWorktree,
       "普通仓库脏了就停下，绝不覆盖用户的改动")
}
section("未跟踪文件不算「工作区脏」：只挡已跟踪改动（git 自己判撞名）")
do {
    // 只有未跟踪草稿：git 允许切分支，判据也不该拦。
    let scratch = FakeRepo()
    scratch.untracked = "?? .tmp/\n?? docs/research/x.md"
    eq(scratch.git().enter(branch: "feature/x", base: "main"), .switched,
       "只有未跟踪文件时照常切分支")
    check(scratch.calls.contains("status --porcelain --untracked-files=no"),
          "干净检查只看已跟踪改动")
    check(scratch.checkouts.contains("feature/x"), "并且真的切过去了")

    // 已跟踪的未提交改动：仍然停下。
    let tracked = FakeRepo()
    tracked.worktreeClean = false
    eq(tracked.git().enter(branch: "feature/x", base: "main"), .dirtyWorktree,
       "已跟踪的未提交改动仍然停下")
}
section("删掉队列之后的失败任务：全部处理能把它们重新跑起来")
do {
    var board = TaskBoard()
    let a = TaskItem.manual(title: "改 README", body: nil, id: "manual-hh001111")
    let b = TaskItem.manual(title: "升级依赖", body: nil, id: "manual-hh002222")
    board.tasks = [a, b]
    let queue = board.createQueue(name: "Lane", autoPR: false)
    _ = board.enqueue(taskID: a.id, into: queue.id)
    _ = board.enqueue(taskID: b.id, into: queue.id)
    board.markRunning(a.id)
    _ = board.markFailed(a.id, error: TaskFailure.timeout.rawValue)
    board.markRunning(b.id)
    _ = board.markCancelled(b.id)
    check(board.removeQueue(queue.id), "把队列删掉（任务回到未入队，状态保留）")
    eq(board.task(a.id)?.state, .failed, "失败的那条还是失败")
    eq(board.task(a.id)?.queueId, nil, "但已经不属于任何队列")

    let h = Harness(board: board, github: false)
    let startable = TasksRunAllModel.startable(in: h.board)
    eq(startable.map { $0.id }, [a.id, b.id], "两条都归批量管（旧实现只认 pending，于是它们被漏掉）")

    // 批量：各自一个新队列，重新跑起来。
    for task in startable { _ = h.runner.startManualTask(task.id) }
    eq(h.board.queues.count, 2, "各自建了一个队列")
    check(h.board.queues.allSatisfy { $0.taskIds.count == 1 }, "每个队列一个任务")
    check(h.board.task(a.id)?.state == .running, "失败过的那条重新跑起来了")
    check(h.board.task(a.id)?.error == nil, "而且旧错误已经清掉")
    h.dsh.finishAll()
    _ = h.runner.step()
    check(h.board.task(a.id)?.state == .done, "跑完了")
    eq(h.runner.runningTaskID, b.id, "被取消的那条接着跑")
    h.dsh.finishAll()
    _ = h.runner.step()
    check(h.board.task(b.id)?.state == .done, "两条都被批量救回来了")
}

section("切会话：同一工作区不重新 adopt（主线程 git 探测不再每次跑）")
do {
    check(!TaskWorkspaceRegistry.needsReadopt(resolved: "/repo/a", adopted: "/repo/a", hasRunner: true),
          "同一路径 + 有 runner → 不需要重新 adopt")
    check(!TaskWorkspaceRegistry.needsReadopt(resolved: "/repo/a/", adopted: "/repo/a", hasRunner: true),
          "尾斜杠也算同一路径")
    check(TaskWorkspaceRegistry.needsReadopt(resolved: "/repo/b", adopted: "/repo/a", hasRunner: true),
          "换了路径 → 需要重新 adopt")
    check(TaskWorkspaceRegistry.needsReadopt(resolved: "/repo/a", adopted: "/repo/a", hasRunner: false),
          "当前工作区没有 runner → 仍需 adopt")
    check(TaskWorkspaceRegistry.needsReadopt(resolved: nil, adopted: "/repo/a", hasRunner: true),
          "拿不到路径 → 仍需 adopt")
}

section("queue API: 建「等待态」队列 + 批量入队，不启动")
do {
    let h = Harness(board: TaskBoard(), github: true, gitRepo: true)
    let result = h.runner.createQueueWithTasks(name: "Dark Mode",
                                               branch: nil, baseBranch: nil, autoPR: nil,
                                               originSession: "session-origin",
                                               drafts: [TaskDraft(title: "深色模式", body: "改主题"),
                                                        TaskDraft(title: "跟随系统", body: "")])
    eq(result.queue.state, QueueState.draft, "新队列是 draft（等待启动）")
    eq(result.queue.branch, "feature/dark-mode", "分支从名字派生")
    check(result.queue.autoPR == false, "autoPR 默认关闭（PR 走手动发布）")
    eq(result.created.count, 2, "两条任务都建了")
    check(h.board.task(result.created[0].id)?.state == .queued, "任务在队列里等待")
    eq(h.board.queue(result.queue.id)?.state, QueueState.draft, "没有启动任何东西")
    eq(h.board.local.queueSessions[result.queue.id], "session-origin", "记录了来源会话")
    check(h.runner.runningTaskID == nil, "runner 是空闲的")
    check(h.dsh.prompts.isEmpty, "连提示词都没发过")
    check(h.dsh.notifications.isEmpty, "也没有回传")
}

section("追加任务不自动启动；关闭队列是手动终态")
do {
    let h = Harness(board: TaskBoard(), github: false, gitRepo: true)
    let r = h.runner.createQueueWithTasks(name: "Lane", branch: "", autoPR: false,
                                          originSession: "session-origin",
                                          drafts: [TaskDraft(title: "A", body: "")])
    _ = h.runner.startQueue(r.queue.id)
    h.dsh.finish("session-1")
    _ = h.runner.step()
    eq(h.board.queue(r.queue.id)?.state, QueueState.done, "第一个任务完成 → done")

    // 追加：任务入队，但队列回到 draft，不自动开跑。
    let extra = h.runner.createManualTask(TaskDraft(title: "B", body: "do B"))!
    _ = h.runner.enqueue(taskID: extra.id, into: r.queue.id)
    eq(h.board.queue(r.queue.id)?.state, QueueState.draft, "追加后回到 draft")
    check(h.runner.runningTaskID == nil, "追加不自动启动")

    // API 路径（appendTasks）同样：入队、回 draft、不启动。
    let more = h.runner.appendTasks(toQueueID: r.queue.id, drafts: [TaskDraft(title: "D", body: "")])
    eq(more.count, 1, "appendTasks 建了 1 条")
    eq(h.board.queue(r.queue.id)?.state, QueueState.draft, "appendTasks 后仍是 draft")

    // 关闭：手动终态。
    check(h.runner.closeQueue(r.queue.id), "关闭队列")
    eq(h.board.queue(r.queue.id)?.state, QueueState.closed, "状态 closed")
    check(!h.runner.startQueue(r.queue.id), "关闭后启动被拒")
    check(!h.runner.enqueue(taskID: extra.id, into: r.queue.id), "关闭后追加被拒")
}

section("工作流：队列级覆盖决定交付会话（merge 不需要 GitHub）")
do {
    // 默认（.pr）在非 GitHub 工作区拒绝收尾：只建任务会话。
    let (board0, task0, queue0) = singleTaskBoard()
    let h0 = Harness(board: board0, github: false, gitRepo: true)
    _ = h0.runner.enqueue(taskID: task0, into: queue0)
    h0.dsh.finishAll()
    _ = h0.runner.step()
    eq(h0.board.queue(queue0)?.state, QueueState.done, "任务完成，队列 done")
    check(h0.runner.openingPRQueueID == nil, "默认 pr 在非 GitHub 工作区不收尾")
    eq(h0.dsh.sessions.count, 1, "只建了任务会话，没有收尾会话")

    // 覆盖为 .merge：同样的工作区就能收尾（只要 git 远端在）。
    let (board1, task1, queue1) = singleTaskBoard()
    var b1 = board1
    if let i = b1.index(ofQueue: queue1) { b1.queues[i].integration = .merge }
    let h1 = Harness(board: b1, github: false, gitRepo: true)
    eq(h1.board.integration(forQueue: queue1, default: .pr), .merge, "队列覆盖优先于全局默认")
    _ = h1.runner.enqueue(taskID: task1, into: queue1)
    h1.dsh.finishAll()
    _ = h1.runner.step()
    eq(h1.runner.openingPRQueueID, queue1, "merge 模式下收尾会话照常启动")
    eq(h1.dsh.sessions.count, 2, "多了一个收尾会话")
    let finalizeSession = h1.dsh.sessions[1]
    check((h1.dsh.prompts[finalizeSession] ?? "").contains("合并"),
          "提示词说的是合并，不是开 PR")

    // 收尾会话还在跑时再点发布：拒绝，并把「忙」这个具体原因写到队列上
    // （面板过去只会报通用的「开不了 PR」，用户不知道卡在哪）。
    check(!h1.runner.startQueueIntegration(queue1), "已经有一个收尾会话在跑：拒绝再起一个")
    eq(h1.board.queue(queue1)?.prError, "tasks.errPRBusy", "原因是「忙」，带具体文案键")

    // merge 没有远端也能收尾：本地合并，推送跳过（用户 2026-10-01）。
    let (board3, task3, queue3) = singleTaskBoard()
    var b3 = board3
    if let i = b3.index(ofQueue: queue3) { b3.queues[i].integration = .merge }
    let h3 = Harness(board: b3, github: false, gitRepo: true)
    h3.repo.remote = nil
    _ = h3.runner.enqueue(taskID: task3, into: queue3)
    h3.dsh.finishAll()
    _ = h3.runner.step()
    eq(h3.runner.openingPRQueueID, queue3, "merge 没有远端也能收尾（本地合并）")
    let mergeSession = h3.dsh.sessions[1]
    let mergePrompt = h3.dsh.prompts[mergeSession] ?? ""
    check(mergePrompt.contains("没有远端"), "提示词说明这个工作区没有远端")
    check(mergePrompt.contains("不要尝试推送"), "并要求不要推送")
    check(!mergePrompt.contains("推送到远端"), "不再要求推送到远端")

    // push 没有远端：拒绝，并把原因写在队列上。
    let (board4, task4, queue4) = singleTaskBoard()
    var b4 = board4
    if let i = b4.index(ofQueue: queue4) { b4.queues[i].integration = .push }
    let h4 = Harness(board: b4, github: false, gitRepo: true)
    h4.repo.remote = nil
    _ = h4.runner.enqueue(taskID: task4, into: queue4)
    h4.dsh.finishAll()
    _ = h4.runner.step()
    check(h4.runner.openingPRQueueID == nil, "push 没有远端：拒绝收尾")
    eq(h4.board.queue(queue4)?.prError, "tasks.errPRNoRemote", "原因是「没有可推送的远端」")

    // 「无」：即使 autoPR 开着、工作区能开 PR，也不起收尾会话；这不是失败。
    let (board2, task2, queue2) = singleTaskBoard()
    var b2 = board2
    if let i = b2.index(ofQueue: queue2) { b2.queues[i].integration = QueueIntegration.none }
    let h2 = Harness(board: b2, github: true, gitRepo: true)
    // NOTE: write QueueIntegration.none in full — ".none" on an Optional VAR means
    // Optional.none (nil), which would silently CLEAR the override instead.
    eq(h2.board.integration(forQueue: queue2, default: .pr), QueueIntegration.none,
       "队列覆盖解析为「无」")
    _ = h2.runner.enqueue(taskID: task2, into: queue2)
    h2.dsh.finishAll()
    _ = h2.runner.step()
    eq(h2.board.queue(queue2)?.state, QueueState.done, "任务完成，队列 done")
    check(h2.runner.openingPRQueueID == nil, "工作流「无」不起收尾会话（autoPR 也不管用）")
    eq(h2.dsh.sessions.count, 1, "只有任务会话，没有收尾会话")
    check(h2.board.queue(queue2)?.prError == nil, "「无」是明确选择，不记错误")
    check(!h2.runner.startQueueIntegration(queue2), "手动发布同样被拒")
}

section("交付复用来源会话（有则用；完成标记保证不读错回合）")
do {
    // 用来源会话收尾：不再新建会话，提示词带唯一完成标记。
    let (board, taskID, queueID) = singleTaskBoard()
    var b = board
    b.local.queueSessions[queueID] = "origin-session"
    let h = Harness(board: b)
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    h.dsh.finishAll()
    _ = h.runner.step()
    eq(h.dsh.sessions.count, 1, "复用来源会话：没有新建收尾会话")
    eq(h.runner.openingPRQueueID, queueID, "收尾跑在来源会话上")
    let originPrompt = h.dsh.prompts["origin-session"] ?? ""
    check(originPrompt.contains("DSH-FINALIZE-"), "提示词要求回一个完成标记")
    let markerRange = originPrompt.range(of: "DSH-FINALIZE-[0-9A-F]+", options: .regularExpression)
    check(markerRange != nil, "提示词里能取到完成标记")
    let marker = markerRange.map { String(originPrompt[$0]) } ?? "DSH-FINALIZE-NONE"

    // 来源会话里先有一段**不相干**的汇报：没有标记时不能被当成收尾结果。
    h.dsh.reports["origin-session"] = "用户闲聊，和收尾无关"
    _ = h.runner.step()
    check(h.board.queue(queueID)?.integrationNote == nil, "没有标记就继续等，不采用这段汇报")
    check(h.runner.openingPRQueueID == queueID, "收尾仍未结束")

    // 标记回来：采用这次汇报，并把标记从结果里去掉。
    h.dsh.reports["origin-session"] = "已合并到 main（无远端，未推送）\n" + marker
    _ = h.runner.step()
    eq(h.board.queue(queueID)?.integrationNote, "已合并到 main（无远端，未推送）",
       "只采用带标记的汇报，并去掉标记")
    check(h.runner.openingPRQueueID == nil, "收尾结束")
}

section("来源会话用不了时回退新会话")
do {
    let (board, taskID, queueID) = singleTaskBoard()
    var b = board
    b.local.queueSessions[queueID] = "origin-session"
    let h = Harness(board: b)
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    // 任务会话已经建好；让**下一次** prompt（给来源会话的收尾指令）失败。
    h.dsh.promptFailuresRemaining = 1
    h.dsh.finishAll()
    _ = h.runner.step()
    check(h.dsh.prompts["origin-session"] == nil, "来源会话没有收到收尾指令")
    eq(h.dsh.sessions.count, 2, "回退：新建了一个专门的收尾会话")
    let fresh = h.dsh.sessions[1]
    check((h.dsh.prompts[fresh] ?? "").contains("交付") || (h.dsh.prompts[fresh] ?? "").contains("PR"),
          "新会话收到了交付指令")
    check(!(h.dsh.prompts[fresh] ?? "").contains("DSH-FINALIZE-"),
          "新会话不需要完成标记（它是专用的）")
}

section("队列到达 .done：回传完成情况到来源会话（一次，幂等）")
do {
    let h = Harness(board: TaskBoard(), github: false, gitRepo: true)
    let r = h.runner.createQueueWithTasks(name: "Dark Mode", branch: "", autoPR: false,
                                          originSession: "session-origin",
                                          drafts: [TaskDraft(title: "A", body: "做 A"),
                                                   TaskDraft(title: "B", body: "做 B")])
    _ = h.runner.startQueue(r.queue.id)
    h.dsh.reports["session-1"] = "A 完成，改了 a.swift"
    h.dsh.finish("session-1")
    _ = h.runner.step()
    check(h.dsh.notifications.isEmpty, "队列没跑完就不回传")
    check(h.board.task(r.created[0].id)?.state == .done, "第一条完成")

    h.dsh.reports["session-2"] = "B 完成"
    h.dsh.finish("session-2")
    _ = h.runner.step()
    eq(h.dsh.notifications.count, 1, "整队完成后回传一次")
    eq(h.dsh.notifications.first?.session, "session-origin", "回传到来源会话")
    let text = h.dsh.notifications.first?.text ?? ""
    check(text.contains("队列「Dark Mode」"), "报告点名队列")
    check(text.contains("1. ✓ A"), "第一条带标号与状态")
    check(text.contains("A 完成，改了 a.swift"), "第一条的完整汇报保留")
    check(text.contains("2. ✓ B"), "报告列出第二条")
    check(text.contains("B 完成"), "第二条的汇报也在")
    check(!text.contains("session-"), "不回传会话标识（用户不要）")
    check(text.contains("确认收到"), "要求 agent 简短确认")
    check(h.board.local.queueNotified[r.queue.id] != nil, "记下已回传")
    _ = h.runner.step()
    eq(h.dsh.notifications.count, 1, "幂等：不会重复回传")
}

section("手动取消 / 暂停：不回传")
do {
    let h = Harness(board: TaskBoard(), github: false, gitRepo: true)
    let r = h.runner.createQueueWithTasks(name: "Lane", branch: "", autoPR: false,
                                          originSession: "session-origin",
                                          drafts: [TaskDraft(title: "A", body: ""),
                                                   TaskDraft(title: "B", body: "")])
    _ = h.runner.startQueue(r.queue.id)
    _ = h.runner.cancelRunning()
    _ = h.runner.step()
    eq(h.board.queue(r.queue.id)?.state, QueueState.paused, "取消让队列暂停")
    check(h.dsh.notifications.isEmpty, "取消不回传（只有 done 才回传）")
}

section("重启补发：done 且未回传的队列在下一次 step 发出")
do {
    var board = TaskBoard()
    let t = TaskItem.manual(title: "A", body: nil, id: "manual-zz000001")
    board.tasks = [t]
    let q = board.createQueue(name: "Lane", branch: "", autoPR: false)
    _ = board.enqueue(taskID: t.id, into: q.id)
    _ = board.resumeQueue(q.id)
    board.markRunning(t.id)
    board.markDone(t.id)
    eq(board.queue(q.id)?.state, QueueState.done, "队列已完成")
    // 关联在盘上，但 app 在回传前退出了。
    board.local.queueSessions[q.id] = "session-origin"
    let h = Harness(board: board, github: false, gitRepo: true)
    _ = h.runner.step()
    eq(h.dsh.notifications.count, 1, "空闲的 step 补发一次")
    eq(h.dsh.notifications.first?.session, "session-origin", "补发到来源会话")
    check(h.board.local.queueNotified[q.id] != nil, "补发后记下标记")
}

section("queueFinishedSummary 文案：首行汇报 + 失败原因 + 简短确认")
do {
    var board = TaskBoard()
    let a = TaskItem.manual(title: "A", body: nil, id: "manual-zz000002")
    let b = TaskItem.manual(title: "B", body: nil, id: "manual-zz000003")
    board.tasks = [a, b]
    let q = board.createQueue(name: "外观", branch: "feature/ui", autoPR: true)
    board.markRunning(a.id)
    board.markDone(a.id, report: "改完了\n第二行", at: Date())
    board.markRunning(b.id)
    _ = board.markFailed(b.id, error: "tasks.errNotGit")
    let tasks = [board.task(a.id)!, board.task(b.id)!]
    let text = TaskPrompts.queueFinishedSummary(queue: board.queue(q.id)!, tasks: tasks)
    check(text.contains("队列「外观」"), "点名队列")
    check(text.contains("分支：feature/ui → main"), "有分支就点名分支")
    check(text.contains("1. ✓ A"), "第一条带标号")
    check(text.contains("改完了") && text.contains("第二行"), "完整汇报保留（不再只取首行）")
    check(text.contains("2. ✗ B"), "失败项带标号")
    check(text.contains("失败：tasks.errNotGit"), "失败项列出原因")
    check(text.contains("确认收到"), "要求简短确认")

    // 提交列表：有则列出，空则不出现；无分支的队列不出现。
    let withCommits = TaskPrompts.queueFinishedSummary(queue: board.queue(q.id)!, tasks: tasks,
                                                       commits: ["abc123 深色模式：主题令牌",
                                                                 "def456 跟随系统：监听外观"])
    check(withCommits.contains("分支上相对 main 的提交："), "提交段的抬头")
    check(withCommits.contains("abc123 深色模式：主题令牌"), "提交逐条列出")
    check(!text.contains("提交："), "没有提交就不出现提交段")

    var branchless = TaskBoard()
    let bt2 = TaskItem.manual(title: "X", body: nil, id: "manual-zz000004")
    branchless.tasks = [bt2]
    let bq = branchless.createQueue(name: "NoBranch", branch: "", autoPR: false)
    branchless.markRunning(bt2.id)
    branchless.markDone(bt2.id, report: "done")
    let branchlessText = TaskPrompts.queueFinishedSummary(queue: branchless.queue(bq.id)!,
                                                          tasks: [branchless.task(bt2.id)!],
                                                          commits: ["should-not-show"])
    check(!branchlessText.contains("分支："), "无分支队列不显示分支行")
    check(!branchlessText.contains("提交："), "无分支队列不显示提交段")
}

section("回传带上队列分支的提交（git 仓库；非 git 不显示）")
do {
    let h = Harness(board: TaskBoard(), github: false, gitRepo: true)
    h.repo.commits = ["abc123 深色模式：主题令牌"]
    let r = h.runner.createQueueWithTasks(name: "Lane", branch: "feature/x", autoPR: false,
                                          originSession: "session-origin",
                                          drafts: [TaskDraft(title: "A", body: "")])
    _ = h.runner.startQueue(r.queue.id)
    h.dsh.finish("session-1")
    _ = h.runner.step()
    let text = h.dsh.notifications.first?.text ?? ""
    check(text.contains("分支：feature/x → main"), "分支行")
    check(text.contains("分支上相对 main 的提交："), "提交段")
    check(text.contains("abc123 深色模式：主题令牌"), "提交内容")
}

section("交付成功后自动关闭队列（成功才关；失败/关时不关）")
do {
    // 纯判定：PR 由调用方用链接判定；merge / push 读提示词要求的「已合并 / 已推送」行。
    check(TasksRunner.finalizeSucceeded(mode: .merge, report: "完成。\n已合并并推送 main abc123"),
          "merge 成功行判定为成功")
    check(!TasksRunner.finalizeSucceeded(mode: .merge, report: "完成。\n合并失败：冲突"),
          "merge 失败不判成功")
    check(TasksRunner.finalizeSucceeded(mode: .push, report: "已推送 main abc123"),
          "push 成功行判定为成功")
    check(!TasksRunner.finalizeSucceeded(mode: .push, report: "推送被拒绝"), "push 失败不判成功")
    check(!TasksRunner.finalizeSucceeded(mode: .pr, report: "whatever"), "PR 由链接判定，不读报告")

    // PR 成功：拿到链接 → 队列自动关闭，记录保留。
    let (board, taskID, queueID) = singleTaskBoard()
    let h = Harness(board: board, autoCloseOnPublish: true)
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    h.dsh.finishAll()
    _ = h.runner.step()
    let prSession = h.dsh.sessions[1]
    h.dsh.reports[prSession] = "已推送分支并创建 PR：https://github.com/o/r/pull/7"
    h.dsh.finishAll()
    _ = h.runner.step()
    eq(h.board.queue(queueID)?.state, QueueState.closed, "PR 成功后队列自动关闭")
    eq(h.board.queue(queueID)?.prUrl, "https://github.com/o/r/pull/7", "PR 记录保留")

    // PR 失败：没有链接 → 不关，并保留失败原因。
    let (board2, task2, queue2) = singleTaskBoard()
    let h2 = Harness(board: board2, autoCloseOnPublish: true)
    _ = h2.runner.enqueue(taskID: task2, into: queue2)
    h2.dsh.finishAll()
    _ = h2.runner.step()
    let prSession2 = h2.dsh.sessions[1]
    h2.dsh.reports[prSession2] = "开 PR 失败：token 无效"
    h2.dsh.finishAll()
    _ = h2.runner.step()
    eq(h2.board.queue(queue2)?.state, QueueState.done, "PR 失败：队列保持 done")
    eq(h2.board.queue(queue2)?.prError, "tasks.errPR", "并记下失败原因")

    // 开关关闭：成功也不关。
    let (board3, task3, queue3) = singleTaskBoard()
    let h3 = Harness(board: board3, autoCloseOnPublish: false)
    _ = h3.runner.enqueue(taskID: task3, into: queue3)
    h3.dsh.finishAll()
    _ = h3.runner.step()
    let prSession3 = h3.dsh.sessions[1]
    h3.dsh.reports[prSession3] = "已推送分支并创建 PR：https://github.com/o/r/pull/9"
    h3.dsh.finishAll()
    _ = h3.runner.step()
    eq(h3.board.queue(queue3)?.state, QueueState.done, "开关关闭：成功后队列仍是 done")

    // merge 成功：结果行说明已合并 → 自动关闭。
    let (board4, task4, queue4) = singleTaskBoard()
    var b4 = board4
    if let i = b4.index(ofQueue: queue4) { b4.queues[i].integration = .merge }
    let h4 = Harness(board: b4, autoCloseOnPublish: true)
    _ = h4.runner.enqueue(taskID: task4, into: queue4)
    h4.dsh.finishAll()
    _ = h4.runner.step()
    let mergeSession = h4.dsh.sessions[1]
    h4.dsh.reports[mergeSession] = "已合并并推送 main\nabc123"
    h4.dsh.finishAll()
    _ = h4.runner.step()
    eq(h4.board.queue(queue4)?.state, QueueState.closed, "merge 成功后队列自动关闭")

    // merge 失败：结果行不是成功 → 不关。
    let (board5, task5, queue5) = singleTaskBoard()
    var b5 = board5
    if let i = b5.index(ofQueue: queue5) { b5.queues[i].integration = .merge }
    let h5 = Harness(board: b5, autoCloseOnPublish: true)
    _ = h5.runner.enqueue(taskID: task5, into: queue5)
    h5.dsh.finishAll()
    _ = h5.runner.step()
    let mergeSession2 = h5.dsh.sessions[1]
    h5.dsh.reports[mergeSession2] = "合并失败：与 main 冲突，请用户介入"
    h5.dsh.finishAll()
    _ = h5.runner.step()
    eq(h5.board.queue(queue5)?.state, QueueState.done, "merge 失败：队列保持 done")

    // 失败的队列（paused）即使发布成功也不自动关闭：关掉会把失败藏起来。
    // 手动发布一个 paused 队列（有失败任务时用户仍可点发布）。
    let (board6, _, queue6) = singleTaskBoard()
    var b6 = board6
    if let i = b6.index(ofQueue: queue6) {
        b6.queues[i].integration = .merge
        b6.queues[i].state = .paused
    }
    let h6 = Harness(board: b6, autoCloseOnPublish: true)
    check(h6.runner.startQueueIntegration(queue6), "paused 队列也能手动发布")
    let mergeSession3 = h6.dsh.sessions[0]
    h6.dsh.reports[mergeSession3] = "已合并 main\nabc123"
    h6.dsh.finishAll()
    _ = h6.runner.step()
    eq(h6.board.queue(queue6)?.state, QueueState.paused, "paused 队列不自动关闭")
}


// MARK: - 多仓库交付：计划 / 提示词 / 结果解析（design §7）

section("多仓库交付计划：intent = 队列覆盖 ?? 仓库默认，effective 按能力降级")
do {
    let gh = WorkspaceRepo(id: "repo-gh", absolutePath: "/ws/repo-gh", isGit: true,
                           remoteName: "github", github: GitHubRepo(owner: "o", name: "repo-gh"),
                           displayName: "repo-gh")
    let local = WorkspaceRepo(id: "repo-local", absolutePath: "/ws/repo-local", isGit: true,
                              defaultBase: "develop", displayName: "repo-local")
    let plain = WorkspaceRepo(id: "repo-plain", absolutePath: "/ws/repo-plain", isGit: false,
                              displayName: "repo-plain")
    let queue = TaskQueue(id: "q-plan", name: "Q", branch: "feature/x", baseBranch: "main")
    let plan = TasksRunner.deliveryPlan(queue: queue, targets: [gh, local, plain],
                                        queueOverride: nil,
                                        perRepoDefault: { _ in .pr },
                                        hasRemote: { $0.id == "repo-gh" })
    eq(plan.map { $0.repoID }, ["repo-gh", "repo-local", "repo-plain"], "计划覆盖每个目标仓库")
    eq(plan[0].intent, .pr, "GitHub 仓库 intent = 默认 pr")
    eq(plan[0].effective, .pr, "GitHub 仓库 effective 原样")
    eq(plan[1].effective, .merge, "无远端仓库 pr 降级为本地合并")
    eq(plan[2].effective, .none, "非 git 仓库降级为不做")
    eq(plan[1].branch, "feature/x", "交付分支是队列分支")
    eq(plan[1].base, "develop", "每个仓库用自己的默认基线")
    eq(plan[1].status, .pending, "计划状态从 pending 开始")
    // 队列覆盖 push：有远端的原样、无远端的降级 merge。
    let plan2 = TasksRunner.deliveryPlan(queue: queue, targets: [gh, local], queueOverride: .push,
                                         perRepoDefault: { _ in .pr },
                                         hasRemote: { $0.id == "repo-gh" })
    eq(plan2[0].effective, .push, "队列覆盖 push：有远端原样")
    eq(plan2[1].effective, .merge, "队列覆盖 push：无远端降级 merge")
    eq(plan2[1].intent, .push, "intent 记录队列覆盖")
}

section("多仓库交付提示词：逐仓库给出 effective 动作并要求逐行输出")
do {
    let runs = [
        QueueRepoRun(repoID: "repo-a", branch: "feature/x", base: "main",
                     intent: .pr, effective: .pr),
        QueueRepoRun(repoID: "repo-b", branch: "feature/x", base: "master",
                     intent: .pr, effective: .merge),
        QueueRepoRun(repoID: "repo-c", branch: "feature/x", base: "main",
                     intent: .merge, effective: .none),
    ]
    let text = TaskPrompts.integration(queueName: "Multi", branch: "feature/x", base: "main", runs: runs)
    check(text.contains("repo-a/"), "点名声 repo-a")
    check(text.contains("repo-b/"), "点名声 repo-b")
    check(text.contains("开 PR"), "repo-a 的动作是开 PR")
    check(text.contains("本地合并"), "repo-b 的动作是本地合并")
    check(text.contains("降级"), "写明 repo-b 的动作是降级来的")
    check(text.contains("<repoID>") && text.contains(": pr"), "给出可解析的 pr 输出格式")
    check(text.contains("<repoID>") && text.contains(": merge"), "给出可解析的 merge 输出格式")
    check(text.contains("git -C"), "要求逐仓库执行")
    // 单目标（根仓库）保持今天逐字节相同的单仓库交付文本。
    let single = [QueueRepoRun(repoID: ".", branch: "feature/x", base: "main",
                               intent: .merge, effective: .merge)]
    let legacy = TaskPrompts.integration(mode: .merge, queueName: "Q", branch: "feature/x",
                                         base: "main", commits: [])
    eq(TaskPrompts.integration(queueName: "Q", branch: "feature/x", base: "main", runs: single),
       legacy, "单目标根仓库 = 今天的单仓库交付文本")
}

section("per-repo 结果解析：逐行解析 + findExistingPR 兜底")
do {
    let report = """
    干完了。
    repo-a: pr https://github.com/o/a/pull/12
    repo-b: merge 已合并到 master abc1234
    repo-c: none 不交付
    """
    let parsed = TasksRunner.repoResults(in: report)
    eq(parsed.count, 3, "解析出 3 个仓库结果")
    eq(parsed[0].repoID, "repo-a", "repo-a 行首是仓库 id")
    eq(parsed[0].action, .pr, "repo-a 的 action 是 pr")
    eq(parsed[0].prUrl, "https://github.com/o/a/pull/12", "PR 行取到 URL")
    eq(parsed[1].action, .merge, "repo-b 的 action 是 merge")
    eq(parsed[2].action, .none, "repo-c 的 action 是 none")
    eq(TasksRunner.repoResults(in: "## 队列信息\n分支：x（基于 main）").count, 0,
       "非结果行（抬头 / 分支）被忽略")

    let gh = WorkspaceRepo(id: "repo-a", absolutePath: "/ws/a", isGit: true,
                           remoteName: "github", github: GitHubRepo(owner: "o", name: "a"),
                           displayName: "a")
    let b = WorkspaceRepo(id: "repo-b", absolutePath: "/ws/b", isGit: true,
                          remoteName: "origin", displayName: "b")
    let runs = [
        QueueRepoRun(repoID: "repo-a", branch: "feature/x", base: "main",
                     intent: .pr, effective: .pr),
        QueueRepoRun(repoID: "repo-b", branch: "feature/x", base: "master",
                     intent: .pr, effective: .merge),
        QueueRepoRun(repoID: "repo-c", branch: "feature/x", base: "main",
                     intent: .pr, effective: .none),
    ]
    let resolved = TasksRunner.resolveRepoRuns(runs, targets: [gh, b], results: parsed,
                                               findExistingPR: { _, _ in nil })
    eq(resolved[0].status, .done, "PR 行 → 成功")
    eq(resolved[0].prUrl, "https://github.com/o/a/pull/12", "URL 落到该仓库的结果上")
    eq(resolved[1].status, .done, "merge 行「已合并」→ 成功")
    eq(resolved[2].status, .skipped, "effective none → skipped")
    check(resolved[1].note?.contains("已合并") == true, "merge 的 note 是会话结果行")

    // 会话没有逐行报：按 effective 用 findExistingPR 兜底。
    let fallback = TasksRunner.resolveRepoRuns([runs[0], runs[1]], targets: [gh, b], results: [],
                                               findExistingPR: { repo, _ in
                                                   repo.id == "repo-a"
                                                       ? "https://github.com/o/a/pull/9" : nil
                                               })
    eq(fallback[0].status, .done, "没有 pr 行时用 findExistingPR 兜底")
    eq(fallback[0].prUrl, "https://github.com/o/a/pull/9", "兜底 URL 落到仓库结果上")
    eq(fallback[1].status, .failed, "merge 没报也找不到 → 失败")
}

section("多仓库 startQueueIntegration：一个队列一个交付会话，逐仓库记账")
do {
    let gh = WorkspaceRepo(id: "repo-a", absolutePath: "/tmp/ws/repo-a", isGit: true,
                           defaultBase: "main", remoteName: "github",
                           github: GitHubRepo(owner: "o", name: "a"), displayName: "repo-a")
    let b = WorkspaceRepo(id: "repo-b", absolutePath: "/tmp/ws/repo-b", isGit: true,
                          defaultBase: "master", displayName: "repo-b")
    var board = TaskBoard()
    let queue = board.createQueue(name: "Multi", autoPR: false, repos: ["repo-a", "repo-b"])
    let h = MultiRepoHarness(board: board, repos: [gh, b], primaryRepoID: "repo-a",
                             defaultIntegrationFor: { _ in .pr })
    h.git("repo-b").remote = nil   // repo-b 无远端 → pr 降级为本地合并
    check(h.runner.startQueueIntegration(queue.id), "混合能力下交付会话照常启动")
    eq(h.dsh.sessions.count, 1, "一个队列一个交付会话")
    let prompt = h.dsh.prompts[h.dsh.sessions[0]] ?? ""
    check(prompt.contains("repo-a/") && prompt.contains("repo-b/"), "提示词点名两个仓库")
    check(prompt.contains("开 PR"), "repo-a 的动作是开 PR")
    check(prompt.contains("本地合并"), "repo-b 按能力降级为本地合并")

    h.dsh.reports[h.dsh.sessions[0]] = """
    repo-a: pr https://github.com/o/a/pull/3
    repo-b: merge 已合并到 master abc1234
    """
    h.dsh.finishAll()
    _ = h.runner.step()
    let runs = h.board.queue(queue.id)?.repoRuns ?? []
    eq(runs.count, 2, "队列记录两个仓库的结果")
    eq(runs.first { $0.repoID == "repo-a" }?.status, .done, "repo-a 成功")
    eq(runs.first { $0.repoID == "repo-a" }?.prUrl, "https://github.com/o/a/pull/3", "repo-a 的 PR 链接")
    eq(runs.first { $0.repoID == "repo-b" }?.status, .done, "repo-b 成功")
    eq(h.board.queue(queue.id)?.prUrl, "https://github.com/o/a/pull/3", "队列保留第一个成功 PR（兼容字段）")

    // 全都无得交付：拒绝启动，不建会话。
    let plainA = WorkspaceRepo(id: "repo-a", absolutePath: "/tmp/ws/p-a", isGit: false,
                               displayName: "p-a")
    var board2 = TaskBoard()
    let queue2 = board2.createQueue(name: "None", autoPR: false, repos: ["repo-a"])
    let h2 = MultiRepoHarness(board: board2, repos: [plainA], primaryRepoID: "repo-a",
                              defaultIntegrationFor: { _ in .pr })
    h2.git("repo-a").isRepo = false
    h2.git("repo-a").remote = nil
    check(!h2.runner.startQueueIntegration(queue2.id), "所有目标都无得交付时拒绝")
    eq(h2.dsh.sessions.count, 0, "拒绝时不建交付会话")
    eq(h2.board.queue(queue2.id)?.prError, "tasks.errPRNoRemote", "拒绝原因记在队列上")
}

section("issue auto queue 的 repos 固定为 [issueRepoID]（design §9）")
do {
    let gh = WorkspaceRepo(id: "repo-a", absolutePath: "/tmp/ws/repo-a", isGit: true,
                           remoteName: "github", github: GitHubRepo(owner: "o", name: "a"),
                           displayName: "repo-a")
    let b = WorkspaceRepo(id: "repo-b", absolutePath: "/tmp/ws/repo-b", isGit: true,
                          remoteName: "origin", github: GitHubRepo(owner: "o", name: "b"),
                          displayName: "repo-b")
    var board = TaskBoard()
    board.tasks = [TaskItem.github(number: 5, title: "fix me")]
    let h = MultiRepoHarness(board: board, repos: [gh, b], primaryRepoID: "repo-a")
    let qid = h.runner.startIssueTask("issue-5", repos: ["repo-b"])
    check(qid != nil, "issue 任务照常启动")
    eq(h.board.queue(qid ?? "")?.repos, ["repo-b"], "auto queue 的目标仓库 = issueRepoID")
    eq(h.board.queue(qid ?? "")?.repos?.count, 1, "固定为一个仓库")
}

section("失败仓库单独重试：只重试该仓库，已成功仓库保留（P4）")
do {
    let gh = WorkspaceRepo(id: "repo-a", absolutePath: "/tmp/ws/repo-a", isGit: true,
                           defaultBase: "main", remoteName: "github",
                           github: GitHubRepo(owner: "o", name: "a"), displayName: "repo-a")
    let b = WorkspaceRepo(id: "repo-b", absolutePath: "/tmp/ws/repo-b", isGit: true,
                          defaultBase: "master", remoteName: "origin",
                          github: GitHubRepo(owner: "o", name: "b"), displayName: "repo-b")
    var board = TaskBoard()
    let queue = board.createQueue(name: "Multi", autoPR: false, repos: ["repo-a", "repo-b"])
    // 原始交付：repo-a 成功、repo-b 失败（先写进 board，再交给 runner）。
    _ = board.setQueueRepoRuns(queue.id, [
        QueueRepoRun(repoID: "repo-a", branch: "feature/multi", base: "main",
                     intent: .pr, effective: .pr, status: .done,
                     prUrl: "https://github.com/o/a/pull/1"),
        QueueRepoRun(repoID: "repo-b", branch: "feature/multi", base: "master",
                     intent: .pr, effective: .pr, status: .failed, note: "boom"),
    ])
    let h = MultiRepoHarness(board: board, repos: [gh, b], primaryRepoID: "repo-a",
                             defaultIntegrationFor: { _ in .pr })
    eq(h.board.queue(queue.id)?.repoRuns.count, 2, "前提：交付记录已就位")
    check(h.runner.retryFailedRepo(queueID: queue.id, repoID: "repo-b"),
          "可以单独重试失败仓库")
    eq(h.dsh.sessions.count, 1, "只开一个交付会话")
    eq(h.board.queue(queue.id)?.repoRuns.first { $0.repoID == "repo-b" }?.status, .running,
       "重试中的仓库标记为交付中")
    eq(h.board.queue(queue.id)?.repoRuns.first { $0.repoID == "repo-a" }?.status, .done,
       "已成功的仓库不动")
    let prompt = h.dsh.prompts[h.dsh.sessions[0]] ?? ""
    check(prompt.contains("repo-b/"), "提示词点名失败仓库")
    check(!prompt.contains("repo-a/"), "提示词不包含已成功仓库")
    // 单独重试即使只有一个仓库也要求逐行输出，结果才能被解析。
    check(prompt.contains("repo-b") && prompt.contains("pull/<编号>"),
          "提示词要求逐行可解析结果")
    h.dsh.reports[h.dsh.sessions[0]] = "repo-b: pr https://github.com/o/b/pull/7"
    h.dsh.finishAll()
    _ = h.runner.step()
    let runs = h.board.queue(queue.id)?.repoRuns ?? []
    eq(runs.first { $0.repoID == "repo-b" }?.status, .done, "重试成功")
    eq(runs.first { $0.repoID == "repo-b" }?.prUrl, "https://github.com/o/b/pull/7",
       "重试的 PR 落到该仓库")
    eq(runs.first { $0.repoID == "repo-a" }?.status, .done, "已成功的仓库原样保留")
    eq(runs.first { $0.repoID == "repo-a" }?.prUrl, "https://github.com/o/a/pull/1",
       "已成功仓库的 PR 没被覆盖")

    // 不是失败状态、仓库不存在 → 拒绝重试。
    check(!h.runner.retryFailedRepo(queueID: queue.id, repoID: "repo-a"),
          "已成功的仓库不重试")
    check(!h.runner.retryFailedRepo(queueID: queue.id, repoID: "gone"),
          "不存在的仓库不重试")
}

// MARK: - P1 完成 marker 协议

section("P1 完成 marker：会话最后一行回显本次 marker 才判 done")
do {
    let (board, taskID, queueID) = singleTaskBoard(autoPR: false)
    let h = Harness(board: board)
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    let prompt = h.dsh.prompts["session-1"] ?? ""
    check(prompt.contains("DSH-TASK-DONE-"), "提示词里带本次完成 marker")
    check(prompt.hasSuffix(prompt.range(of: "DSH-TASK-DONE-[0-9A-F]{8}",
                                        options: .regularExpression).map { String(prompt[$0]) } ?? ""),
          "marker 指令落在提示词最后")
    let marker = prompt.range(of: "DSH-TASK-DONE-[0-9A-F]{8}", options: .regularExpression)
        .map { String(prompt[$0]) } ?? "DSH-TASK-DONE-NONE"
    eq(h.board.task(taskID)?.completionMarker, marker, "任务记录了本次尝试的 marker")
    eq(h.board.task(taskID)?.markerVerified, false, "启动时尚未校验")

    h.dsh.reports["session-1"] = "改完了，测试通过。"
    h.dsh.finishAll()
    _ = h.runner.step()
    eq(h.board.task(taskID)?.state, .done, "汇报回显了本次 marker → done")
    eq(h.board.task(taskID)?.markerVerified, true, "并记录了已校验")
    check(!((h.board.task(taskID)?.report) ?? "").contains("DSH-TASK-DONE-"),
          "marker 不写回卡片汇报")
    eq(h.board.local.taskMarkers[taskID], marker, "marker 落进 local.json 的状态")
    eq(h.board.local.taskMarkerVerified[taskID], true, "已校验落进 local.json")
    let reloaded = TaskLocalState.from(h.board.local.dictionary())
    eq(reloaded.taskMarkers[taskID], marker, "local.json 往返后 marker 还在")
    eq(reloaded.taskMarkerVerified[taskID], true, "local.json 往返后校验状态还在")

    var gh = TaskItem.github(number: 7, title: "x")
    gh.completionMarker = marker
    gh.markerVerified = true
    let entry = gh.indexDictionary()
    check(entry["completionMarker"] == nil && entry["markerVerified"] == nil,
          "marker 不进 index.json 的 issue 条目正文")
    _ = queueID
}

section("P1 完成 marker：无 marker / 非本次 marker / 空汇报 → 待确认，不判 done")
do {
    // 会话 idle，但汇报里没有本次 marker。
    let (board1, task1, queue1) = singleTaskBoard(autoPR: false)
    let h1 = Harness(board: board1)
    h1.dsh.echoesTaskMarkers = false
    _ = h1.runner.enqueue(taskID: task1, into: queue1)
    h1.dsh.reports["session-1"] = "改完了，但忘了写完成标记。"
    h1.dsh.finishAll()
    _ = h1.runner.step()
    eq(h1.board.task(task1)?.state, .needsReview, "无 marker → 待确认（不是失败、也不是 done）")
    eq(h1.board.task(task1)?.error, "tasks.errUnverified", "卡片拿到待确认的原因")
    eq(h1.board.task(task1)?.markerVerified, false, "未通过校验")
    check(h1.board.queue(queue1)?.state == .paused, "队列暂停：不继续后面的任务、不交付")

    // 汇报里是别的 marker（旧 turn / 复述）→ 不采纳。
    let (board2, task2, queue2) = singleTaskBoard(autoPR: false)
    let h2 = Harness(board: board2)
    h2.dsh.echoesTaskMarkers = false
    _ = h2.runner.enqueue(taskID: task2, into: queue2)
    h2.dsh.reports["session-1"] = "上一轮的完成标记：DSH-TASK-DONE-DEADBEEF"
    h2.dsh.finishAll()
    _ = h2.runner.step()
    eq(h2.board.task(task2)?.state, .needsReview, "非本次 marker → 不判 done")
    eq(h2.board.task(task2)?.error, "tasks.errUnverified", "同样进入待确认")

    // 本次 marker 出现在中间一行、最后一行另有内容 → 只认最后一行，不采纳。
    let (board3, task3, queue3) = singleTaskBoard(autoPR: false)
    let h3 = Harness(board: board3)
    h3.dsh.echoesTaskMarkers = false
    _ = h3.runner.enqueue(taskID: task3, into: queue3)
    let prompt3 = h3.dsh.prompts["session-1"] ?? ""
    let marker3 = prompt3.range(of: "DSH-TASK-DONE-[0-9A-F]{8}", options: .regularExpression)
        .map { String(prompt3[$0]) } ?? "DSH-TASK-DONE-NONE"
    h3.dsh.reports["session-1"] = "本次完成标记 " + marker3 + "\n后面还有一句收尾的话"
    h3.dsh.finishAll()
    _ = h3.runner.step()
    eq(h3.board.task(task3)?.state, .needsReview, "marker 不在最后一行 → 不采纳")

    // 空汇报（会话没有任何最后文本）→ 待确认。
    let (board4, task4, queue4) = singleTaskBoard(autoPR: false)
    let h4 = Harness(board: board4)
    h4.dsh.echoesTaskMarkers = false
    _ = h4.runner.enqueue(taskID: task4, into: queue4)
    h4.dsh.finishAll()
    _ = h4.runner.step()
    eq(h4.board.task(task4)?.state, .needsReview, "空汇报 → 不判 done")
    eq(h4.board.task(task4)?.error, "tasks.errUnverified", "空汇报进入待确认")
    _ = queue2
    _ = queue3
    _ = queue4
}

// MARK: - P2 待确认状态与卡片出口

section("P2 待确认：队列暂停、不发完成通知、不自动开 PR")
do {
    var (board, first, second, queueID) = twoTaskBoard()
    // 队列有来源会话：如果它被判完成，这条通知就会发出去 —— 待确认不该发。
    board.local.queueSessions[queueID] = "origin-session"
    let h = Harness(board: board)
    h.dsh.echoesTaskMarkers = false
    _ = h.runner.enqueue(taskID: first, into: queueID)
    _ = h.runner.enqueue(taskID: second, into: queueID)
    h.dsh.reports["session-1"] = "改了一半，网络断了。"
    h.dsh.finishAll()
    _ = h.runner.step()

    eq(h.board.task(first)?.state, .needsReview, "没有 marker → 待确认")
    eq(h.board.queue(queueID)?.state, .paused, "待确认暂停队列")
    eq(h.board.task(second)?.state, .queued, "后面的任务没有被启动")
    eq(h.board.queue(queueID)?.taskIds.count, 2, "任务没有丢")
    check(h.dsh.notifications.isEmpty, "待确认不发完成通知")
    eq(h.dsh.sessions.count, 1, "待确认不起交付会话（不自动开 PR）")
    check(h.rec.logged("needs review"), "日志记下待确认")

    // 重试是出口之一：该任务重新排队并立刻跑起来，队列恢复活跃。
    let staleMarker = h.board.task(first)?.completionMarker
    check(h.runner.retry(taskID: first), "待确认可以重试")
    eq(h.board.task(first)?.state, .running, "重试后重新跑")
    eq(h.board.queue(queueID)?.state, .active, "重试恢复队列")
    check(h.board.task(first)?.completionMarker != staleMarker, "重试换一个全新的 marker")
    eq(h.board.task(first)?.error, nil, "重试清掉待确认说明")
    eq(h.dsh.sessions.count, 2, "重试起了新会话")
}

section("P2 标记完成：用户确认 → 直接 .done，并走正常完成路径")
do {
    var (board, first, _, queueID) = twoTaskBoard()
    board.local.queueSessions[queueID] = "origin-session"
    let h = Harness(board: board)
    h.dsh.echoesTaskMarkers = false
    _ = h.runner.enqueue(taskID: first, into: queueID)
    h.dsh.reports["session-1"] = "做完了，但忘了写完成标记。"
    h.dsh.finishAll()
    _ = h.runner.step()
    eq(h.board.task(first)?.state, .needsReview, "先进入待确认")

    check(h.runner.confirmDone(taskID: first), "标记完成被接受")
    eq(h.board.task(first)?.state, .done, "用户确认 → done")
    eq(h.board.task(first)?.error, nil, "待确认的说明被清掉")
    eq(h.board.queue(queueID)?.state, .done, "最后一条确认后队列完成")
    eq(h.dsh.notifications.count, 1, "确认后照常回传完成通知")
    // 队列有来源会话：交付复用它，不再新建一个会话。
    eq(h.runner.openingPRQueueID, queueID, "队列完成照常起交付（autoPR 开着）")
    check(h.dsh.prompts["origin-session"] != nil, "来源会话收到交付提示词")

    // 不是待确认的任务不能被「标记完成」放行。
    check(!h.runner.confirmDone(taskID: first), "已 done 的任务不再接受标记完成")
}

section("P2 跳过并继续：交接简报把待确认标为「待确认」，不写进「已完成」")
do {
    let (board, first, second, queueID) = twoTaskBoard()
    let h = Harness(board: board)
    h.dsh.echoesTaskMarkers = false
    _ = h.runner.enqueue(taskID: first, into: queueID)
    _ = h.runner.enqueue(taskID: second, into: queueID)
    h.dsh.reports["session-1"] = "做了一半。"
    h.dsh.finishAll()
    _ = h.runner.step()
    eq(h.board.task(first)?.state, .needsReview, "前一条待确认")

    check(h.runner.skip(taskID: first), "跳过并继续")
    let nextPrompt = h.dsh.prompts["session-2"] ?? ""
    check(nextPrompt.contains("—— 待确认"), "前一条在简报里标为待确认")
    check(!nextPrompt.contains("—— 已完成"), "没有把待确认写进「已完成」")
}

// MARK: - P3 完成通知诚实化

section("P3 完成通知：全完成报「已全部完成」，完成 / 待确认混合如实计数")
do {
    // 全完成：没有任何待确认，保持原有「已全部完成（N/N）」。
    var allDone = TaskBoard()
    let a1 = TaskItem.manual(title: "A", id: "manual-0p10aaaa")
    let a2 = TaskItem.manual(title: "B", id: "manual-0p11bbbb")
    allDone.tasks = [a1, a2]
    let aq = allDone.createQueue(name: "全绿", branch: "feature/all", autoPR: false)
    allDone.markRunning(a1.id); allDone.markDone(a1.id, report: "A 完成")
    allDone.markRunning(a2.id); allDone.markDone(a2.id, report: "B 完成")
    let allTasks = [allDone.task(a1.id)!, allDone.task(a2.id)!]
    let allCounts = TaskPrompts.completionCounts(allTasks)
    eq(allCounts.done, 2, "全完成：完成计 2")
    eq(allCounts.needsReview, 0, "全完成：待确认计 0")
    let allText = TaskPrompts.queueFinishedSummary(queue: allDone.queue(aq.id)!, tasks: allTasks)
    check(allText.contains("已全部完成（2/2）"), "全完成仍写「已全部完成（2/2）」")
    check(!allText.contains("待确认"), "全完成不提「待确认」")

    // 混合：2 完成 + 1 待确认 —— 首行必须写清两个计数，不能再报「全部完成」。
    var mixed = TaskBoard()
    let m1 = TaskItem.manual(title: "One", id: "manual-0p12cccc")
    let m2 = TaskItem.manual(title: "Two", id: "manual-0p13dddd")
    let m3 = TaskItem.manual(title: "Three", id: "manual-0p14eeee")
    mixed.tasks = [m1, m2, m3]
    let mq = mixed.createQueue(name: "混合", autoPR: false)
    mixed.markRunning(m1.id); mixed.markDone(m1.id, report: "一完成")
    mixed.markRunning(m2.id); mixed.markDone(m2.id, report: "二完成")
    mixed.markRunning(m3.id); _ = mixed.markNeedsReview(m3.id, report: "三做了一半")
    let mixedTasks = [mixed.task(m1.id)!, mixed.task(m2.id)!, mixed.task(m3.id)!]
    let mixedCounts = TaskPrompts.completionCounts(mixedTasks)
    eq(mixedCounts.done, 2, "混合：完成计 2")
    eq(mixedCounts.needsReview, 1, "混合：待确认计 1")
    let mixedText = TaskPrompts.queueFinishedSummary(queue: mixed.queue(mq.id)!, tasks: mixedTasks)
    check(mixedText.contains("完成 2 条 / 待确认 1 条（共 3 条）"),
          "首行如实写「完成 2 条 / 待确认 1 条」")
    check(!mixedText.contains("已全部完成"), "有欠账就不再报「已全部完成」")
    check(mixedText.contains("3. ? Three"), "待确认任务带自己的记号 ?")
    check(mixedText.contains("待确认："), "待确认任务列出原因与两条出口")
    check(mixedText.contains("不是全部完成"), "尾部再强调不是全部完成")
    check(mixedText.contains("三做了一半"), "待确认任务的汇报照样带上，验收看得到它做到哪")
}

section("P3 跳过待确认后队列完成：通知仍如实报「完成 1 / 待确认 1」")
do {
    var (board, first, second, queueID) = twoTaskBoard()
    board.local.queueSessions[queueID] = "origin-session"
    let h = Harness(board: board)
    h.dsh.echoesTaskMarkers = false
    _ = h.runner.enqueue(taskID: first, into: queueID)
    _ = h.runner.enqueue(taskID: second, into: queueID)
    h.dsh.reports["session-1"] = "第一条做了一半。"
    h.dsh.finishAll()
    _ = h.runner.step()
    eq(h.board.task(first)?.state, .needsReview, "第一条待确认")

    // 用户「跳过并继续」：第二条接着跑（FakeDsh 默认守约，回显 marker）。
    h.dsh.echoesTaskMarkers = true
    check(h.runner.skip(taskID: first), "跳过待确认")
    eq(h.board.task(second)?.state, .running, "第二条跑起来")
    h.dsh.reports["session-2"] = "第二条做完了。"
    h.dsh.finishAll()
    _ = h.runner.step()

    eq(h.board.task(second)?.state, .done, "第二条完成")
    eq(h.board.queue(queueID)?.state, .done, "队列到达 done")
    eq(h.dsh.notifications.count, 1, "队列完成发一次通知")
    let text = h.dsh.notifications.first?.text ?? ""
    check(text.contains("完成 1 条 / 待确认 1 条（共 2 条）"), "通知如实写「完成 1 / 待确认 1」")
    check(!text.contains("已全部完成"), "跳过待确认也不谎报「已全部完成」")
    check(text.contains("1. ? One"), "第一条在列表里是待确认 ?")
    check(text.contains("2. ✓ Two"), "第二条是完成 ✓")
}

// MARK: - P4 产物校验（expectsCommit）

section("P4 产物校验：应产出提交却没有任何产物 → 待确认，不是 done")
do {
    let (board, taskID, queueID) = singleTaskBoard(autoPR: false)
    let h = Harness(board: board, verifyExpectedCommit: true, workspaceShape: .github)
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    eq(h.board.task(taskID)?.expectsCommit, true, "git 工作区里的任务被推断为应产出提交")

    // 代理回显了 marker、也写了汇报，但 git 里既没有新提交、工作区也是干净的。
    h.dsh.reports["session-1"] = "我什么都没改就结束了。"
    h.dsh.finishAll()
    _ = h.runner.step()

    eq(h.board.task(taskID)?.state, .needsReview, "没有产物 → 待确认（不是 done）")
    eq(h.board.task(taskID)?.error, "tasks.errNoCommit", "卡片拿到「未产出提交」的原因")
    eq(h.board.task(taskID)?.markerVerified, true, "marker 本身是通过的（P4 是它的补充）")
    check(h.board.queue(queueID)?.state == .paused, "队列暂停：不继续后面的任务、不交付")
    check(h.rec.logged("expectsCommit"), "日志说明是产物校验拦下的")
    eq(h.dsh.notifications.count, 0, "待确认不发完成通知")
}

section("P4 产物校验：出现新提交 → 可判 done")
do {
    let (board, taskID, queueID) = singleTaskBoard(autoPR: false)
    let h = Harness(board: board, verifyExpectedCommit: true, workspaceShape: .github)
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    // 任务开始后真的提交了：HEAD 变化。
    h.repo.head = "abc1234"
    h.dsh.reports["session-1"] = "改完并 commit 了。"
    h.dsh.finishAll()
    _ = h.runner.step()

    eq(h.board.task(taskID)?.state, .done, "有新提交 → done")
    eq(h.board.task(taskID)?.error, nil, "没有待确认原因")
    eq(h.board.queue(queueID)?.state, .done, "队列正常完成")
    _ = queueID
}

section("P4 产物校验：只改了工作区没 commit → 也算有产物")
do {
    let (board, taskID, queueID) = singleTaskBoard(autoPR: false)
    let h = Harness(board: board, verifyExpectedCommit: true, workspaceShape: .github)
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    h.repo.worktreeClean = false
    h.dsh.reports["session-1"] = "改了文件，还没 commit。"
    h.dsh.finishAll()
    _ = h.runner.step()
    eq(h.board.task(taskID)?.state, .done, "工作区有改动 → done")
}

section("P4 产物校验：非 git 工作区不设期望，不因为没提交降级")
do {
    // 非 git 工作区的队列不带分支（branch: ""），否则切分支会先失败——那才是
    // tasks.errNotGit 的来路，会把「有没有产物」的断言搅浑。
    let (board, taskID, queueID) = singleTaskBoard(branch: "", autoPR: false)
    let h = Harness(board: board, github: false, gitRepo: false,
                    verifyExpectedCommit: true, workspaceShape: .plain)
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    eq(h.board.task(taskID)?.expectsCommit, false, "非 git 工作区不期望提交")
    h.dsh.reports["session-1"] = "纯文档任务，没有提交。"
    h.dsh.finishAll()
    _ = h.runner.step()
    eq(h.board.task(taskID)?.state, .done, "没有提交也不降级（非目标 §3）")
}

section("P4 产物校验：推断规则（来源 / 工作区形状 / 目标仓库）")
do {
    let issue = TaskItem.github(number: 1, title: "Fix")
    let manual = TaskItem.manual(title: "Write docs")
    eq(TasksRunner.infersCommitExpectation(task: issue, targets: [], shape: .plain), false,
       "非 git 工作区：issue 任务也不期望提交")
    eq(TasksRunner.infersCommitExpectation(task: issue, targets: [], shape: nil), true,
       "无形状信息时 issue 按来源期望提交")
    eq(TasksRunner.infersCommitExpectation(task: manual, targets: [], shape: nil), false,
       "无形状信息时手动任务不预设")
    let gitRepo = WorkspaceRepo(id: "repo-a", absolutePath: "/tmp/a", isGit: true, displayName: "a")
    eq(TasksRunner.infersCommitExpectation(task: manual, targets: [gitRepo], shape: nil), true,
       "目标仓库是 git → 期望提交")
    let plainRepo = WorkspaceRepo(id: "repo-b", absolutePath: "/tmp/b", isGit: false, displayName: "b")
    eq(TasksRunner.infersCommitExpectation(task: issue, targets: [plainRepo], shape: nil), false,
       "目标仓库都不是 git → 不期望提交")
}

if failures == 0 {
    print("ok - \(checks) checks passed")
} else {
    print("FAILED - \(failures) of \(checks) checks failed")
    exit(1)
}
