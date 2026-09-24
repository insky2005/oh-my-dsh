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
    var current = "main"
    var worktreeClean = true
    var remote: String? = "origin"
    var pushed: Set<String> = []
    var knownBranches: Set<String> = ["main"]
    var failing: Set<String> = []
    private(set) var calls: [String] = []
    private(set) var checkouts: [String] = []

    func git() -> TaskGit {
        TaskGit(run: { [unowned self] args in self.run(args) },
                remoteName: { [unowned self] in self.remote })
    }

    private func run(_ args: [String]) -> String? {
        let key = args.joined(separator: " ")
        calls.append(key)
        if failing.contains(key) { return nil }
        guard let first = args.first else { return nil }
        switch first {
        case "rev-parse":
            if args.count >= 2, args[1] == "--abbrev-ref" { return current }
            if args.count >= 2, args[1] == "--verify" {
                let name = args.last ?? ""
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

final class Harness {
    let repo = FakeRepo()
    let dsh = FakeDsh()
    let rec = Recorder()
    let runner: TasksRunner
    var board: TaskBoard { runner.board }

    init(board: TaskBoard,
         github: Bool = true,
         timeout: TimeInterval = 30 * 60) {
        let repo = self.repo
        let dsh = self.dsh
        let rec = self.rec
        let env = TaskRunnerEnv(
            git: repo.git(),
            repoRoot: "/tmp/repo",
            createSession: { _ in dsh.create() },
            renameSession: { id, title in dsh.rename(id, title) },
            promptSession: { id, text in dsh.prompt(id, text) },
            sessionRunning: { id in dsh.running.contains(id) },
            cancelSession: { id in dsh.cancel(id) },
            findExistingPR: { branch in github ? rec.existingPRs[branch] : nil },
            createPR: { branch, base, _, _ in
                rec.prCalls.append((branch: branch, base: base))
                return github ? "https://example.test/pull/" + String(rec.prCalls.count) : nil
            },
            prText: { task, branch in
                (title: "fix(#" + String(task.number ?? 0) + ")", body: branch)
            },
            promptText: { task, queue in
                TaskPrompts.manual(title: task.title, body: task.body,
                                   branch: queue?.branch, queueName: queue?.name)
            },
            persist: { board in rec.persistCount += 1; _ = board },
            persistIssueTask: { task in rec.issueWrites.append(task.id) },
            log: { message in rec.logs.append(message) },
            perform: { blocking, completion in blocking(); completion() }
        )
        runner = TasksRunner(board: board, env: env, timeout: timeout)
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
    // A PR that cannot be opened (internal remote / no permission) is not a
    // task failure: the branch is pushed and the user opens it by hand.
    let (board, taskID, queueID) = singleTaskBoard()
    let h = Harness(board: board, github: false)
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    h.dsh.finishAll()
    h.repo.pushed.insert("feature/docs-cleanup")
    _ = h.runner.step()
    check(h.board.task(taskID)?.state == .done, "the task is done without a PR")
    check(h.board.task(taskID)?.prUrl == nil, "no PR url")
    check(h.rec.logged("PR not created"), "the missing PR is logged")
}
do {
    let (board, taskID, queueID) = singleTaskBoard()
    let h = Harness(board: board, github: false)
    h.repo.remote = nil
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    check(h.repo.calls.contains("pull --ff-only") == false, "no pull without a remote")
    h.dsh.finishAll()
    _ = h.runner.step()
    check(h.board.task(taskID)?.state == .done, "a local-only repo still finishes")
    check(h.rec.logged("no remote"), "the missing remote is logged")
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

section("cancel, retry and skip")
do {
    let (board, taskID, queueID) = singleTaskBoard()
    let h = Harness(board: board)
    _ = h.runner.enqueue(taskID: taskID, into: queueID)
    check(h.runner.cancelRunning(), "cancel is accepted")
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
    let queue = board.createQueue(name: "Lane", autoPR: false)
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    _ = board.enqueue(taskID: t2.id, into: queue.id)
    let h = Harness(board: board)
    h.repo.pushed.insert("feature/lane")
    _ = h.runner.startQueue(queue.id)
    h.dsh.finishAll()
    _ = h.runner.step()
    check(h.runner.runningTaskID == t2.id, "the second task follows")

    h.dsh.finishAll()
    h.repo.pushed.removeAll()
    _ = h.runner.step()
    check(h.board.task(t2.id)?.state == .failed, "the second task failed (unpushed)")
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

if failures == 0 {
    print("ok - \(checks) checks passed")
} else {
    print("FAILED - \(failures) of \(checks) checks failed")
    exit(1)
}
