import Foundation

// Headless tests for the workstreams queue engine (WorkstreamsQueues.swift +
// WorkstreamsRunner.swift). Driven by a scripted dsh session layer, so the whole
// pipeline (create session -> name -> prompt -> poll -> cancel / retry) runs with
// no window, no server, no AppKit and no git:
//   - serial pump: one task at a time, FIFO inside a queue;
//   - session lifecycle: create / TITLE prefix / prompt / poll / cancel / retry;
//   - restart recovery: running -> failed(interrupted), active -> paused;
//   - storage: queues + tasks + local overlay under .dsh/workstreams/ (never .dsh/tasks/);
//   - 事项启动 = 启动该事项的队列；任务直连 workstreamId + stage.

var checks = 0
var failures = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { failures += 1; print("  FAIL " + label) }
}

func eq<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("  FAIL " + label + ": got " + String(describing: actual) + ", want " + String(describing: expected))
    }
}

func section(_ name: String) { print("--- " + name + " ---") }

// MARK: - Scripted dsh

final class FakeDsh {
    private(set) var sessions: [String] = []
    var running: Set<String> = []
    /// Force a state for a session (unknown / missing cases).
    var stateOverride: [String: WSSessionState] = [:]
    /// sessionId -> the agent's last words.
    var reports: [String: String] = [:]
    /// Whether the simulated agent echoes the completion marker on its last line.
    var echoesTaskMarkers = true
    private(set) var titles: [String: String] = [:]
    private(set) var prompts: [String: String] = [:]
    private(set) var cancelled: [String] = []
    private(set) var createCalls = 0
    var createFails = false
    var promptFails = false

    func create() -> String? {
        createCalls += 1
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

    func state(_ id: String) -> WSSessionState {
        if let forced = stateOverride[id] { return forced }
        return running.contains(id) ? .running : .idle
    }

    func report(_ id: String) -> String? {
        var text = reports[id] ?? ""
        if echoesTaskMarkers, let marker = Self.wsMarker(in: prompts[id] ?? "") {
            if !text.contains(marker) {
                text = text.isEmpty ? marker : text + "\n" + marker
            }
        }
        return text.isEmpty ? nil : text
    }

    /// The WS completion marker (DSH-WS-DONE-XXXXXXXX) in a prompt, or nil.
    static func wsMarker(in prompt: String) -> String? {
        guard let range = prompt.range(of: "DSH-WS-DONE-", options: .backwards) else { return nil }
        let tail = prompt[range.upperBound...].prefix { $0.isHexDigit }
        let hex = String(tail.prefix(8))
        return hex.count == 8 ? "DSH-WS-DONE-" + hex : nil
    }

    func cancel(_ id: String) -> Bool {
        cancelled.append(id)
        running.remove(id)
        return true
    }

    func finish(_ id: String) { running.remove(id) }
}

final class Recorder {
    var persistCount = 0
    var logs: [String] = []
    func logged(_ needle: String) -> Bool { logs.contains { $0.contains(needle) } }
}

/// Blocking work the runner handed to an asynchronous perform but nobody ran yet.
final class WorkQueue {
    var items: [() -> Void] = []
}

// MARK: - Harness

final class Harness {
    let dsh = FakeDsh()
    let rec = Recorder()
    let runner: WorkstreamsRunner
    var board: WSBoard { runner.board }

    private let work = WorkQueue()
    private let asynchronous: Bool

    init(board: WSBoard,
         timeout: TimeInterval = 30 * 60,
         asynchronous: Bool = false,
         requireMarker: Bool = false) {
        self.asynchronous = asynchronous
        let work = self.work
        let asynchronous = asynchronous
        let dsh = self.dsh
        let rec = self.rec
        let env = WSRunnerEnv(
            repoRoot: "/tmp/ws",
            createSession: { _ in dsh.create() },
            renameSession: { id, title in dsh.rename(id, title) },
            promptSession: { id, text in dsh.prompt(id, text) },
            sessionState: { id in dsh.state(id) },
            cancelSession: { id in dsh.cancel(id) },
            sessionReport: { id in dsh.report(id) },
            requireCompletionMarker: requireMarker,
            persist: { _ in rec.persistCount += 1 },
            log: { message in rec.logs.append(message) },
            perform: { blocking, completion in
                if asynchronous {
                    work.items.append { blocking(); completion() }
                } else {
                    blocking(); completion()
                }
            })
        runner = WorkstreamsRunner(board: board, env: env, timeout: timeout)
    }

    /// Run the blocking work the runner queued, the way its background queue would.
    func flush() {
        while !work.items.isEmpty { work.items.removeFirst()() }
    }

    var pendingWork: Int { work.items.count }
}

// MARK: - Fixtures

@discardableResult
func seededBoard(titles: [String], stage: WorkstreamStage = .task,
                 workstream: String = "WS-1",
                 queueState: WSQueueState = .active) -> (board: WSBoard, queueID: String, taskIDs: [String]) {
    var board = WSBoard()
    let queue = board.createQueue(name: "Q-" + stage.rawValue, workstreamID: workstream)
    var ids: [String] = []
    for title in titles {
        let task = WSTaskItem(id: WSTaskItem.newID(), title: title,
                              workstreamId: workstream, stage: stage)
        board.tasks.append(task)
        _ = board.enqueue(taskID: task.id, into: queue.id)
        ids.append(task.id)
    }
    if queueState == .active { _ = board.resumeQueue(queue.id) }
    else if queueState == .paused { _ = board.pauseQueue(queue.id) }
    return (board, queue.id, ids)
}

func wsCard(id: String, stage: WorkstreamStage, queues: [String]) -> WorkstreamCard {
    WorkstreamCard(id: id, title: "T", requirement: nil, stage: stage, covered: nil,
                   regression: nil, queues: queues, delivery: nil, created: nil,
                   updated: nil, path: "/tmp/" + id + ".md", body: "")
}

// MARK: - Tests

section("serial pump: one task at a time, FIFO")
do {
    let seeded = seededBoard(titles: ["A", "B", "C"])
    let h = Harness(board: seeded.board)
    _ = h.runner.step()
    eq(h.dsh.sessions.count, 1, "only one session for the first task")
    eq(h.runner.board.task(seeded.taskIDs[0])?.state, .running, "first task running")
    eq(h.runner.board.task(seeded.taskIDs[1])?.state, .queued, "second task still queued")
    eq(h.runner.board.task(seeded.taskIDs[2])?.state, .queued, "third task still queued")
    eq(h.runner.runningTaskID, seeded.taskIDs[0], "runningTaskID is the first task")
    // Stepping again while it runs must not start anything.
    _ = h.runner.step()
    eq(h.dsh.sessions.count, 1, "still only one session while running")
    // Finish the first: the second starts.
    h.dsh.finish(h.dsh.sessions[0])
    _ = h.runner.step()
    eq(h.runner.board.task(seeded.taskIDs[0])?.state, .done, "first done")
    eq(h.runner.board.task(seeded.taskIDs[1])?.state, .running, "second running")
    eq(h.dsh.sessions.count, 2, "second session created")
    // Walk the rest out.
    h.dsh.finish(h.dsh.sessions[1])
    _ = h.runner.step()
    eq(h.runner.board.task(seeded.taskIDs[2])?.state, .running, "third running")
    h.dsh.finish(h.dsh.sessions[2])
    _ = h.runner.step()
    eq(h.runner.board.task(seeded.taskIDs[2])?.state, .done, "third done")
    eq(h.runner.board.queue(seeded.queueID)?.state, .done, "queue done when the lane empties")
    eq(h.dsh.sessions.count, 3, "exactly three sessions for three tasks")
    eq(h.runner.isBusy, false, "runner idle once the queue is done")
}

section("session lifecycle: create -> title -> prompt")
do {
    let seeded = seededBoard(titles: ["设计鉴权"], stage: .design)
    let h = Harness(board: seeded.board)
    _ = h.runner.step()
    let session = h.dsh.sessions[0]
    eq(h.dsh.titles[session], "WS: 设计鉴权", "session title carries the WS prefix and the task title")
    let prompt = h.dsh.prompts[session] ?? ""
    check(prompt.contains("设计鉴权"), "prompt names the task")
    check(prompt.contains("设计"), "prompt names the stage")
    check(prompt.contains("WS-1"), "prompt names the workstream")
}

section("failure pauses the queue; skip resumes and runs the next")
do {
    let seeded = seededBoard(titles: ["A", "B"])
    let h = Harness(board: seeded.board)
    h.dsh.promptFails = true
    _ = h.runner.step()
    eq(h.runner.board.task(seeded.taskIDs[0])?.state, .failed, "prompt failure fails the task")
    eq(h.runner.board.task(seeded.taskIDs[0])?.error, "workstreams.errPrompt", "failure key is the prompt key")
    eq(h.runner.board.queue(seeded.queueID)?.state, .paused, "queue pauses on failure")
    _ = h.runner.step()
    eq(h.dsh.sessions.count, 1, "no auto restart while paused")
    h.dsh.promptFails = false
    _ = h.runner.skip(taskID: seeded.taskIDs[0])
    eq(h.runner.board.task(seeded.taskIDs[1])?.state, .running, "skip starts the next task")
}

section("cancel running; cancel while starting is deferred")
do {
    let seeded = seededBoard(titles: ["A", "B"])
    let h = Harness(board: seeded.board)
    _ = h.runner.step()
    eq(h.runner.cancelRunning(), .cancelled, "cancel returns .cancelled")
    eq(h.dsh.cancelled.count, 1, "the session was cancelled")
    eq(h.runner.board.task(seeded.taskIDs[0])?.state, .cancelled, "task cancelled")
    eq(h.runner.board.queue(seeded.queueID)?.state, .paused, "queue pauses on cancel")
}
do {
    let seeded = seededBoard(titles: ["A"])
    let h = Harness(board: seeded.board, asynchronous: true)
    _ = h.runner.step()
    eq(h.pendingWork, 1, "the start work is queued (still .starting)")
    eq(h.runner.cancelRunning(), .deferred, "cancel during starting is deferred")
    h.flush()
    eq(h.dsh.cancelled.count, 1, "session cancelled as soon as it existed")
    eq(h.runner.board.task(seeded.taskIDs[0])?.state, .cancelled, "task ends cancelled")
}

section("retry resumes an idle previous session; a failed prompt does not")
do {
    let seeded = seededBoard(titles: ["A"])
    let h = Harness(board: seeded.board, requireMarker: true)
    _ = h.runner.step()
    let first = h.dsh.sessions[0]
    h.dsh.finish(first)
    h.dsh.echoesTaskMarkers = false
    h.dsh.reports[first] = "干了一半"
    _ = h.runner.step()
    eq(h.runner.board.task(seeded.taskIDs[0])?.state, .needsReview, "no marker -> needsReview")
    eq(h.runner.board.queue(seeded.queueID)?.state, .paused, "queue paused for review")
    h.dsh.echoesTaskMarkers = true
    _ = h.runner.retry(taskID: seeded.taskIDs[0])
    eq(h.dsh.sessions.count, 1, "retry reused the idle previous session")
    check((h.dsh.prompts[first] ?? "").contains("继续"), "continuation prompt was sent")
    eq(h.runner.board.task(seeded.taskIDs[0])?.state, .running, "task running again")
}
do {
    let seeded = seededBoard(titles: ["A"])
    let h = Harness(board: seeded.board)
    h.dsh.promptFails = true
    _ = h.runner.step()
    eq(h.runner.board.task(seeded.taskIDs[0])?.state, .failed, "prompt failure")
    h.dsh.promptFails = false
    _ = h.runner.retry(taskID: seeded.taskIDs[0])
    eq(h.dsh.sessions.count, 2, "a prompt that never landed is NOT resumed: fresh session")
}

section("restart recovery: running -> failed(interrupted), active -> paused")
do {
    let seeded = seededBoard(titles: ["A", "B"], queueState: .paused)
    var board = seeded.board
    // Simulate a crash: task A was running and the queue was active when the app died.
    let qi = board.index(ofQueue: seeded.queueID)!
    board.queues[qi].state = .active
    let ti = board.index(ofTask: seeded.taskIDs[0])!
    board.tasks[ti].state = .running
    board.local.runningTaskID = seeded.taskIDs[0]
    board.local.activeQueueID = seeded.queueID
    let h = Harness(board: board)
    let result = h.runner.reconcileAfterRestart()
    eq(result.interrupted, [seeded.taskIDs[0]], "the running task was interrupted")
    eq(result.pausedQueues, [seeded.queueID], "the active queue was paused")
    eq(h.runner.board.task(seeded.taskIDs[0])?.error, "workstreams.errInterrupted", "interrupted key")
    eq(h.runner.board.queue(seeded.queueID)?.state, .paused, "queue paused")
    _ = h.runner.step()
    eq(h.dsh.sessions.count, 0, "nothing auto-starts after a restart")
    _ = h.runner.startQueue(seeded.queueID)
    eq(h.runner.board.task(seeded.taskIDs[1])?.state, .running, "explicit 继续 runs the next queued task")
}

section("marker gate: echoed marker -> done, missing -> needsReview + confirmDone")
do {
    let seeded = seededBoard(titles: ["A", "B"])
    let h = Harness(board: seeded.board, requireMarker: true)
    _ = h.runner.step()
    h.dsh.finish(h.dsh.sessions[0])
    _ = h.runner.step()
    eq(h.runner.board.task(seeded.taskIDs[0])?.state, .done, "echoed marker counts as done")
    eq(h.runner.board.task(seeded.taskIDs[0])?.markerVerified, true, "marker recorded verified")
    // Now make the second session NOT echo.
    h.dsh.echoesTaskMarkers = false
    h.dsh.reports[h.dsh.sessions[1]] = "没完成"
    h.dsh.finish(h.dsh.sessions[1])
    _ = h.runner.step()
    eq(h.runner.board.task(seeded.taskIDs[1])?.state, .needsReview, "missing marker -> needsReview")
    _ = h.runner.confirmDone(taskID: seeded.taskIDs[1])
    eq(h.runner.board.task(seeded.taskIDs[1])?.state, .done, "confirmDone promotes it")
    eq(h.runner.board.queue(seeded.queueID)?.state, .done, "queue then finishes")
}

section("timeout cancels the session and fails the task")
do {
    let seeded = seededBoard(titles: ["A"])
    let h = Harness(board: seeded.board, timeout: 60)
    _ = h.runner.step()
    let future = Date().addingTimeInterval(120)
    _ = h.runner.step(now: future)
    eq(h.runner.board.task(seeded.taskIDs[0])?.state, .failed, "timed-out task failed")
    eq(h.runner.board.task(seeded.taskIDs[0])?.error, "workstreams.errTimeout", "timeout key")
    eq(h.dsh.cancelled.count, 1, "its session was cancelled")
}

section("dsh losing the session: only persistent absence fails")
do {
    let seeded = seededBoard(titles: ["A"])
    let h = Harness(board: seeded.board)
    _ = h.runner.step()
    let session = h.dsh.sessions[0]
    h.dsh.stateOverride[session] = .missing
    for _ in 0..<(WorkstreamsRunner.missingSessionPolls - 1) { _ = h.runner.step() }
    eq(h.runner.board.task(seeded.taskIDs[0])?.state, .running, "one missing poll is not a failure")
    _ = h.runner.step()
    eq(h.runner.board.task(seeded.taskIDs[0])?.state, .failed, "persistent absence fails the task")
    eq(h.runner.board.task(seeded.taskIDs[0])?.error, "workstreams.errSessionGone", "session-gone key")
}

section("事项启动 = 启动该事项的一条队列")
do {
    // One execution queue per workstream (design A9); its tasks carry the stage.
    var board = WSBoard()
    let queue = board.createQueue(name: "执行", workstreamID: "WS-9")
    for (title, stage) in [("规划任务", WorkstreamStage.planning), ("设计任务", .design)] {
        let task = WSTaskItem(id: WSTaskItem.newID(), title: title,
                              workstreamId: "WS-9", stage: stage)
        board.tasks.append(task)
        _ = board.enqueue(taskID: task.id, into: queue.id)
    }
    let h = Harness(board: board)
    let card = wsCard(id: "WS-9", stage: .design, queues: [queue.id])
    _ = h.runner.startWorkstream(card)
    eq(h.runner.board.queue(queue.id)?.state, .active, "the workstream queue was started")
    eq(h.dsh.sessions.count, 1, "one session created")
    check((h.dsh.prompts[h.dsh.sessions[0]] ?? "").contains("规划任务"), "the first queued task was prompted")
}
do {
    // Fallback: no card mapping, the engine's own workstreamId decides.
    var board = WSBoard()
    let queue = board.createQueue(name: "D", workstreamID: "WS-7")
    let task = WSTaskItem(id: WSTaskItem.newID(), title: "执行任务",
                          workstreamId: "WS-7", stage: .task)
    board.tasks.append(task)
    _ = board.enqueue(taskID: task.id, into: queue.id)
    let h = Harness(board: board)
    _ = h.runner.startWorkstream("WS-7")
    eq(h.runner.board.queue(queue.id)?.state, .active, "fallback start by workstreamId")
    eq(h.runner.board.task(task.id)?.state, .running, "its task is running")
}

section("storage: queues + tasks + local under .dsh/workstreams, never .dsh/tasks")
do {
    let root = NSTemporaryDirectory() + "ws-runner-" + UUID().uuidString
    var board = WSBoard()
    let queue = board.createQueue(name: "Q", workstreamID: "WS-1")
    let task = WSTaskItem(id: WSTaskItem.newID(), title: "持久化",
                          workstreamId: "WS-1", stage: .task)
    board.tasks.append(task)
    _ = board.enqueue(taskID: task.id, into: queue.id)
    _ = board.resumeQueue(queue.id)
    board.local.sessions[task.id] = "session-xyz"
    board.local.reports[task.id] = "汇报存档"
    WSStore.save(root, board)

    let fm = FileManager.default
    check(fm.fileExists(atPath: root + "/.dsh/workstreams/queues.json"), "queues.json written")
    check(fm.fileExists(atPath: root + "/.dsh/workstreams/local.json"), "local.json written")
    check(!fm.fileExists(atPath: root + "/.dsh/tasks"), "no .dsh/tasks directory is ever created")

    let loaded = WSStore.load(root)
    eq(loaded.queues.count, 1, "one queue round-trips")
    eq(loaded.tasks.count, 1, "one task round-trips")
    eq(loaded.queue(queue.id)?.stage == nil, true, "new queues carry no stage")
    eq(loaded.queue(queue.id)?.workstreamId, "WS-1", "queue workstreamId round-trips")
    eq(loaded.task(task.id)?.workstreamId, "WS-1", "task workstreamId round-trips")
    eq(loaded.task(task.id)?.stage, .task, "task stage round-trips")
    eq(loaded.task(task.id)?.sessionId, "session-xyz", "session overlay reapplied")
    eq(loaded.task(task.id)?.state, .queued, "membership re-derived on load")
    try? fm.removeItem(atPath: root)
}

section("storage: a running board reloads and reconciles as interrupted")
do {
    let root = NSTemporaryDirectory() + "ws-runner-" + UUID().uuidString
    var board = WSBoard()
    let queue = board.createQueue(name: "Q", workstreamID: "WS-1")
    let task = WSTaskItem(id: WSTaskItem.newID(), title: "跑着",
                          workstreamId: "WS-1", stage: .task)
    board.tasks.append(task)
    _ = board.enqueue(taskID: task.id, into: queue.id)
    _ = board.resumeQueue(queue.id)
    board.markRunning(task.id)
    WSStore.save(root, board)

    let reloaded = WSStore.load(root)
    let h = Harness(board: reloaded)
    _ = h.runner.reconcileAfterRestart()
    eq(h.runner.board.task(task.id)?.state, .failed, "reloaded running task is failed after reconcile")
    eq(h.runner.board.queue(queue.id)?.state, .paused, "reloaded active queue is paused")
    try? FileManager.default.removeItem(atPath: root)
}

section("store compat: legacy entries without workstreamId / stage")
do {
    let root = NSTemporaryDirectory() + "ws-compat-" + UUID().uuidString
    let dir = WSStore.workstreamsDir(root)
    let legacy = """
    {
      "version": 1,
      "queues": [
        {"id": "wq-old", "name": "旧队列", "workstreamId": "WS-1", "stage": "design",
         "taskIds": ["wt-old"], "state": "paused"}
      ],
      "tasks": [
        {"id": "wt-old", "title": "老任务", "state": "queued"}
      ]
    }
    """
    try? legacy.write(toFile: dir + "/queues.json", atomically: true, encoding: .utf8)
    let loaded = WSStore.load(root)
    eq(loaded.queue("wq-old")?.stage, .design, "legacy queue stage still reads (optional)")
    eq(loaded.queue("wq-old")?.workstreamId, "WS-1", "legacy queue workstream reads")
    eq(loaded.task("wt-old")?.workstreamId == nil, true, "task without workstreamId parses as nil")
    eq(loaded.task("wt-old")?.stage == nil, true, "task without stage parses as nil")
    eq(loaded.task("wt-old")?.state, .queued, "legacy task still loads")
    try? FileManager.default.removeItem(atPath: root)
}
do {
    let dict = WSTaskItem(id: "wt-1", title: "x", workstreamId: "WS-1", stage: .task).dictionary()
    eq(dict["workstreamId"] as? String, "WS-1", "task serialization carries workstreamId")
    eq(dict["stage"] as? String, "task", "task serialization carries stage")
}

section("adopt / createQueueWithTasks: build a waiting queue, never auto-start")
do {
    let h = Harness(board: WSBoard())
    let built = h.runner.createQueueWithTasks(name: "规划", workstreamID: "WS-1", stage: .planning,
                                              drafts: [WSTaskDraft(title: "T1", body: ""),
                                                       WSTaskDraft(title: "T2", body: "")])
    eq(built.created.count, 2, "two tasks created")
    eq(built.created.map { $0.stage }, [.planning, .planning], "tasks carry the stage")
    eq(built.created.map { $0.workstreamId }, ["WS-1", "WS-1"], "tasks carry the workstream id")
    eq(built.queue.stage == nil, true, "the queue no longer carries a stage")
    eq(h.runner.board.queue(built.queue.id)?.state, .draft, "queue stays draft")
    eq(h.dsh.sessions.count, 0, "nothing started")
    _ = h.runner.startQueue(built.queue.id)
    eq(h.dsh.sessions.count, 1, "explicit start runs the first")
}

section("createStageQueue appends to the workstream's single queue (A9 / D16)")
do {
    let h = Harness(board: WSBoard())
    let card = wsCard(id: "WS-5", stage: .planning, queues: [])
    let first = h.runner.createStageQueue(card: card, stage: .planning, workspace: "/tmp/ws", titles: ["规划一"])
    let second = h.runner.createStageQueue(card: card, stage: .design, workspace: "/tmp/ws", titles: ["设计一"])
    eq(h.runner.board.queues.count, 1, "one queue for the workstream")
    eq(second.queue.id, first.queue.id, "the second batch reuses the same queue")
    eq(h.runner.board.task(first.created[0].id)?.stage, .planning, "first task carries planning")
    eq(h.runner.board.task(second.created[0].id)?.stage, .design, "second task carries design")
    eq(h.runner.board.queue(first.queue.id)?.taskIds.count, 2, "both tasks live in the one queue")
    eq(h.runner.board.queue(first.queue.id)?.state, .draft, "the queue stays waiting")
    eq(h.dsh.sessions.count, 0, "nothing auto-starts")
    eq(h.runner.board.task(first.created[0].id)?.workstreamId, "WS-5", "tasks carry the workstream id")
}

section("stage-level start runs only that stage and pauses when it ends (A3 / D18)")
do {
    var board = WSBoard()
    let queue = board.createQueue(name: "Q", workstreamID: "WS-9")
    var ids: [WorkstreamStage: String] = [:]
    for (title, stage) in [("规划", WorkstreamStage.planning), ("设计", .design), ("执行", .task)] {
        let task = WSTaskItem(id: WSTaskItem.newID(), title: title, workstreamId: "WS-9", stage: stage)
        board.tasks.append(task)
        _ = board.enqueue(taskID: task.id, into: queue.id)
        ids[stage] = task.id
    }
    let h = Harness(board: board)
    let card = wsCard(id: "WS-9", stage: .design, queues: [queue.id])
    _ = h.runner.startWorkstream(card, stage: .design)
    eq(h.runner.board.task(ids[.design]!)?.state, .running, "only the design task runs")
    eq(h.runner.board.task(ids[.planning]!)?.state, .queued, "planning stays queued")
    eq(h.runner.board.task(ids[.task]!)?.state, .queued, "execution stays queued")
    eq(h.dsh.sessions.count, 1, "exactly one session")
    h.dsh.finish(h.dsh.sessions[0])
    _ = h.runner.step()
    eq(h.runner.board.task(ids[.design]!)?.state, .done, "the design task finished")
    eq(h.runner.board.task(ids[.planning]!)?.state, .queued, "planning is still waiting after the stage run")
    eq(h.runner.board.task(ids[.task]!)?.state, .queued, "execution is still waiting after the stage run")
    eq(h.runner.board.queue(queue.id)?.state, .paused, "the queue pauses when the stage run ends")
    eq(h.runner.stageFilter == nil, true, "the stage filter is cleared")
    _ = h.runner.step()
    eq(h.dsh.sessions.count, 1, "no other stage auto-starts")
}

section("enqueueDelivery: a delivery-stage task carrying the delivery prompt (A10)")
do {
    let h = Harness(board: WSBoard())
    let card = wsCard(id: "WS-7", stage: .delivery, queues: [])
    let built = h.runner.enqueueDelivery(card: card, prompt: "事项交付提示词 body")
    eq(h.runner.board.queues.count, 1, "a delivery enqueue creates the workstream queue")
    eq(built.created.count, 1, "one delivery task")
    eq(h.runner.board.task(built.created[0].id)?.stage, .delivery, "the task carries the delivery stage")
    eq(h.runner.board.task(built.created[0].id)?.body, "事项交付提示词 body", "the delivery prompt lands as the body")
    eq(h.runner.board.task(built.created[0].id)?.workstreamId, "WS-7", "the task carries the workstream id")
    eq(h.runner.board.queue(built.queue.id)?.state, .draft, "the queue stays waiting")
    eq(h.dsh.sessions.count, 0, "nothing auto-starts")
}

print("")
if failures == 0 {
    print("runner tests passed (" + String(checks) + " checks)")
} else {
    print(String(failures) + " of " + String(checks) + " checks FAILED")
    exit(1)
}
