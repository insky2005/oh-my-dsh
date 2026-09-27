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
            findExistingPR: { branch in github ? rec.existingPRs[branch] : nil },
            createPR: { branch, base, _, _ in
                rec.prCalls.append((branch: branch, base: base))
                return github ? "https://example.test/pull/" + String(rec.prCalls.count) : nil
            },
            prText: { task, branch in
                (title: "fix(#" + String(task.number ?? 0) + ")", body: branch)
            },
            promptText: { task, queue, brief in
                // Same rules the panel uses: only a queue that will open a PR asks
                // the agent to push, and only a SHARED queue claims to share a
                // branch (a single-task queue does not).
                // Same rules the panel uses — including the SHAPE of the workspace,
                // which the panel probes at prompt time (a queue's first task can be
                // the one that inits the repo or adds the GitHub remote).
                let shape = TaskRepoShape.detect(isGit: gitRepo, hasGitHubRemote: github)
                let sharedName = queue.flatMap { $0.autoCreated ? nil : $0.name }
                return TaskPrompts.manual(title: task.title, body: task.body,
                                          branch: queue?.branch, queueName: sharedName,
                                          pushes: (queue?.autoPR ?? false) && shape == .github,
                                          brief: brief,
                                          shape: shape)
            },
            sessionReport: { id in dsh.report(id) },
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
    check(h.dsh.titles["session-1"] == "Polish README", "the session was renamed")
    check((h.dsh.prompts["session-1"] ?? "").contains("Docs Cleanup"), "the prompt names the queue")
    check(h.rec.persistCount > 0, "state was persisted while starting")

    check(h.runner.step() == true, "still busy while the session runs")
    h.dsh.finishAll()
    h.repo.pushed.insert("feature/docs-cleanup")
    check(h.runner.step() == false, "the step finishes the task")
    check(h.board.task(taskID)?.state == .done, "the task is done")
    check(h.board.task(taskID)?.prUrl == "https://example.test/pull/1", "the PR url is recorded")
    eq(h.rec.prCalls.count, 1, "one PR was created")
    eq(h.rec.prCalls.first?.branch, "feature/docs-cleanup", "PR head is the queue branch")
    eq(h.rec.prCalls.first?.base, "main", "PR base is the queue base branch")
    check(h.rec.issueWrites.isEmpty, "a manual task is not written to the committed index")
    check(h.board.queue(queueID)?.state == .done, "the finished queue is done")
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
    check(h.runner.step() == false, "the task finishes without a push check")
    check(h.board.task(taskID)?.state == .done, "the task is done")
    check(h.rec.prCalls.isEmpty, "no PR without a branch")
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
    h.repo.pushed.insert("feature/dark-mode")
    _ = h.runner.step()
    check(h.board.task(t1.id)?.state == .done, "the first task is done")
    check(h.board.task(t1.id)?.prUrl == nil, "no PR while the queue still has work")
    eq(h.rec.prCalls.count, 0, "the queue PR waits for the last task")

    check(h.board.task(t2.id)?.state == .running, "the second task started automatically")
    eq(h.repo.checkouts.count, 2, "the second task does not switch branch again")
    check(h.runner.runningTaskID == t2.id, "the second task owns the slot")
    h.dsh.finishAll()
    h.rec.existingPRs["feature/dark-mode"] = "https://example.test/pull/7"
    _ = h.runner.step()
    check(h.board.task(t2.id)?.state == .done, "the second task is done")
    check(h.board.task(t2.id)?.prUrl == "https://example.test/pull/7", "the existing PR is reused")
    eq(h.rec.prCalls.count, 0, "no second PR is opened for the same head")
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
    let (board, taskID, queueID) = singleTaskBoard()
    let h = Harness(board: board)
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    h.dsh.finishAll()
    _ = h.runner.step()
    check(h.board.task(taskID)?.error == "tasks.errNoPush", "an unpushed branch is reported")
    eq(h.board.queue(queueID)?.state, QueueState.paused, "the queue is paused")
    check(h.rec.prCalls.isEmpty, "no PR for an unpushed branch")
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
    // No GitHub remote ⇒ this queue will never open a PR ⇒ the task does not push
    // at all: commit-only, no push check, no PR attempt (push policy 2026-09-27).
    let (board, taskID, queueID) = singleTaskBoard()
    let h = Harness(board: board, github: false)
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    h.dsh.finishAll()
    _ = h.runner.step()
    check(h.board.task(taskID)?.state == .done, "the task is done")
    check(h.board.task(taskID)?.prUrl == nil, "no PR url")
    check(h.rec.prCalls.isEmpty, "and no PR was even attempted")
    check(h.repo.calls.contains { $0.hasPrefix("ls-remote") } == false,
          "the push was never checked — nothing is going to be pushed")
    check(h.dsh.prompts["session-1"]?.contains("不要 push") == true,
          "the agent was told to commit only")
    check(h.rec.logged("keeps its work local"), "and the log says why")
}
do {
    // A queue that DOES want a PR, in a repo with no remote at all: the check is
    // skipped with a log (there is nothing to push to).
    let (board, taskID, queueID) = singleTaskBoard()
    let h = Harness(board: board, github: true)
    h.repo.remote = nil
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    check(h.repo.calls.contains("pull --ff-only") == false, "no pull without a remote")
    h.dsh.finishAll()
    _ = h.runner.step()
    check(h.board.task(taskID)?.state == .done, "a local-only repo still finishes")
    check(h.rec.logged("no remote"), "the missing remote is logged")
}
do {
    // …and when the check itself cannot RUN (private remote, no credentials), that
    // is unknown — NOT "the agent forgot to push". It used to fail the task.
    let (board, taskID, queueID) = singleTaskBoard()
    let h = Harness(board: board, github: true)
    h.repo.failing.insert("ls-remote --heads origin feature/docs-cleanup")
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    h.dsh.finishAll()
    _ = h.runner.step()
    check(h.rec.logged("could not tell whether"), "the unknown answer is reported")
    check(h.board.task(taskID)?.state == .done, "and it does NOT fail the task")
    eq(h.rec.prCalls.count, 1, "the PR is still attempted")
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
    h.repo.pushed.insert("feature/lane")
    _ = h.runner.startQueue(queue.id)
    h.dsh.finishAll()
    _ = h.runner.step()
    check(h.board.task(t1.id)?.state == .done, "the first task is done")
    check(h.runner.runningTaskID == t2.id, "the second task follows")

    h.dsh.finishAll()
    h.repo.pushed.removeAll()
    _ = h.runner.step()
    check(h.board.task(t2.id)?.state == .failed, "the LAST task fails when the branch was never pushed")
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
    h.repo.pushed.insert("fix/issue-12")
    _ = h.runner.step()
    check(h.board.task("issue-12")?.state == .done, "the issue task is done")
    eq(h.rec.prCalls.count, 1, "the issue task opened a PR")
    eq(h.rec.issueWrites, ["issue-12"], "the issue task is written to the committed index")

    // retry reuses the same auto queue instead of creating another one
    var failedBoard = h.board
    if let i = failedBoard.index(ofTask: "issue-12") { failedBoard.tasks[i].state = .failed }
    let h2 = Harness(board: failedBoard)
    let before = h2.board.queues.count
    _ = h2.runner.startIssueTask("issue-12")
    eq(h2.board.queues.count, before, "retry reuses the auto queue")
    check(h2.runner.runningTaskID == "issue-12", "the retried issue task runs")
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
    eq(choices.first?.name, "Docs Cleanup", "choices keep the creation order")
    eq(choices.first?.taskCount, 0, "an empty queue reports zero tasks")
    check(choices.allSatisfy { $0.branch?.hasPrefix("feature/") == true }, "each choice carries its branch")

    check(h.runner.enqueue(taskID: id, into: q1.id), "the task joins the chosen queue")
    check(h.board.task(id)?.queueId == q1.id, "the membership is recorded")
    check(h.board.task(id)?.state == .running, "it starts right away (the runner was idle)")
    eq(h.runner.queueChoices().first?.taskCount, 1, "the choice count follows the queue")
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
            createPR: { _, _, _, _ in nil },
            prText: { _, branch in (title: "t", body: branch) },
            promptText: { task, _, brief in TaskPrompts.manual(title: task.title, body: task.body,
                                                              branch: nil, queueName: nil, pushes: false,
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

    h.dsh.finishAll()
    _ = h.runner.step()
    let second = h.dsh.prompts["session-2"] ?? ""
    check(second.contains("## 队列上下文"), "第二个任务带上简报")
    check(second.contains("队列「认证重构」"), "报队列名")
    check(second.contains("第 2/2 个"), "报位次")
    check(second.contains("「抽出 TokenStore」 —— 已完成"), "报上一棒的标题与结局")
    check(second.contains("已完成：抽出了 TokenStore，测试通过。"), "上一棒的汇报原样带上")
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
    check(!prompt.contains("队列上下文"), "单任务队列没有前一棒")
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

    h.dsh.finishAll()
    _ = h.runner.step()
    eq(h.runner.runningTaskID, a.id, "第二个接着跑")
    h.dsh.finishAll()
    _ = h.runner.step()
    eq(h.runner.runningTaskID, b.id, "第三个接着跑")
    h.dsh.finishAll()
    _ = h.runner.step()
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
    check(alone.contains("当前分支应为 feature/alone"), "而是把它自己那条分支说清楚")
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

section("非 git 目录里的提示词：壳层不碰 git，但任务要求就照做")
do {
    var board = TaskBoard()
    let task = TaskItem.manual(title: "初始化 git 仓库", body: nil, id: "manual-gg004444")
    board.tasks = [task]
    let h = Harness(board: board, github: false, gitRepo: false)
    _ = h.runner.startManualTask(task.id)
    let prompt = h.dsh.prompts["session-1"] ?? ""
    check(prompt.contains("这不是 git 仓库"), "明说这里不是仓库")
    check(prompt.contains("壳层不会切分支、不会提交、不会推送"), "说清壳层那一半：管线不碰 git")
    check(prompt.contains("任务本身要求初始化仓库或提交时，照任务做"), "但任务自己要的事照做")
    check(!prompt.contains("不要 git init"), "不再反过来禁止任务要的事")
    check(prompt.contains("默认不要 commit、不要 push"), "默认仍然不 commit / push")
    check(!prompt.contains("commit（建议 feat/fix"), "不会自相矛盾地要求 commit")
    check(prompt.contains("git init（若还没建）→ git remote add origin"), "给出转换路径：init → remote add → push")
}

section("git 仓库但没有 GitHub 远端：说「没有远端」，不说「这个队列没开自动 PR」")
do {
    // 「队列开不开 PR」（队列设置）与「这个目录能不能开 PR」（有没有 GitHub 远端）是两件事。
    // 旧文案把后者说成前者 —— 理由错在用户最需要真话的地方；而且这时候代理手里唯一有用的
    // 那一步（git remote add origin <url>）一个字都没提。
    var board = TaskBoard()
    let task = TaskItem.manual(title: "把项目发到 GitHub", body: nil, id: "manual-gg005555")
    board.tasks = [task]
    let queue = board.createQueue(name: "Lane", branch: "feature/publish", autoPR: false)
    _ = board.enqueue(taskID: task.id, into: queue.id)
    let h = Harness(board: board, github: false, gitRepo: true)
    _ = h.runner.startQueue(queue.id)
    let prompt = h.dsh.prompts["session-1"] ?? ""
    check(prompt.contains("当前分支应为 feature/publish"), "仓库里照旧点名队列的分支")
    check(prompt.contains("这个仓库还没有 GitHub 远端"), "说清真正的原因：没有远端")
    check(!prompt.contains("这个队列没有开自动 PR"), "不再拿队列设置当理由")
    check(prompt.contains("git remote add origin"), "给出把它变成 GitHub 仓库的那一步")
    check(prompt.contains("不要 push"), "远端出现之前仍然不 push")

    // 有 GitHub 远端时一切照旧：这个队列会开 PR，所以要求 push。
    var prBoard = TaskBoard()
    let prTask = TaskItem.manual(title: "改 README", body: nil, id: "manual-gg006666")
    prBoard.tasks = [prTask]
    let prQueue = prBoard.createQueue(name: "Lane", branch: "feature/docs", autoPR: true)
    _ = prBoard.enqueue(taskID: prTask.id, into: prQueue.id)
    let h2 = Harness(board: prBoard, github: true, gitRepo: true)
    _ = h2.runner.startQueue(prQueue.id)
    let prPrompt = h2.dsh.prompts["session-1"] ?? ""
    check(prPrompt.contains("这个队列最后会开 PR"), "GitHub 工作区：要求 push（队列会开 PR）")
    check(!prPrompt.contains("这个仓库还没有 GitHub 远端"), "不会反过来念叨没有远端")
    check(!prPrompt.contains("git remote add origin"), "也不会给已经不需要的转换步骤")
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

if failures == 0 {
    print("ok - \(checks) checks passed")
} else {
    print("FAILED - \(failures) of \(checks) checks failed")
    exit(1)
}
