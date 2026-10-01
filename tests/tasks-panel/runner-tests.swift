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
    var current = "main"
    var worktreeClean = true
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
            if args.count >= 2, args[1] == "--verify" {
                let name = args.last ?? ""
                if name == "HEAD" { return unborn ? nil : "0f0f0f0f" }
                return knownBranches.contains(name) ? "0f0f0f0f" : nil
            }
            return nil
        case "status":
            return worktreeClean ? "" : " M Sources/x.swift"
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

    func report(_ id: String) -> String? {
        reportCalls.append(id)
        return reports[id]
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
         defaultBaseBranch: String = "main") {
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
    check(h.repo.calls.contains("status --porcelain"), "the clean check ran before switching")
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
    check(!empty.calls.contains("status --porcelain"), "空仓库里「工作区脏」这条不适用：没有提交可以丢")
    check(!empty.calls.contains("pull --ff-only"), "也没有远端可 pull")

    // 有提交的普通仓库完全不变：先干净、先切基线、再 pull、再开分支。
    let normal = FakeRepo()
    eq(normal.git().enter(branch: "feature/x", base: "main"), .switched, "普通仓库照旧")
    check(normal.calls.contains("status --porcelain"), "普通仓库仍然先查工作区")
    check(normal.calls.contains("checkout main"), "先切基线")
    check(normal.calls.contains("pull --ff-only"), "有远端就 pull")

    // 脏工作区在普通仓库里依然拦住 —— 空仓库是唯一的例外。
    let dirty = FakeRepo()
    dirty.worktreeClean = false
    eq(dirty.git().enter(branch: "feature/x", base: "main"), .dirtyWorktree,
       "普通仓库脏了就停下，绝不覆盖用户的改动")
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

section("工作流：队列级覆盖决定收尾会话（merge 不需要 GitHub）")
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

if failures == 0 {
    print("ok - \(checks) checks passed")
} else {
    print("FAILED - \(failures) of \(checks) checks failed")
    exit(1)
}
