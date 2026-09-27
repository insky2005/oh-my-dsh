import Foundation

// Headless tests for the Tasks panel model layer. Everything here is real code:
// TasksCore.swift (model) and TasksStore.swift (persistence) are compiled in.
// No AppKit, no window, no dsh server.

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

func text(at path: String) -> String {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
}

func write(_ body: String, to path: String) {
    try? body.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
}

func tempRepo(_ tag: String) -> String {
    let dir = NSTemporaryDirectory() + "tasks-" + tag + "-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - ids

section("task ids")
eq(TaskItem.githubID(12), "issue-12", "github id")
let freshManual = TaskItem.newManualID()
check(freshManual.hasPrefix("manual-"), "manual id prefix")
eq(freshManual.count, 15, "manual id is manual- plus 8 characters")
check(TaskItem.parse(id: "issue-7")?.source == .github, "parse github source")
check(TaskItem.parse(id: "issue-7")?.number == 7, "parse github number")
check(TaskItem.parse(id: "manual-ab12cd34")?.source == .manual, "parse manual source")
check(TaskItem.parse(id: "manual-ab12cd34")?.number == nil, "parse manual has no number")
check(TaskItem.parse(id: "nonsense") == nil, "parse rejects an unknown id")
check(TaskItem.github(number: 3, title: "t", labels: ["bug"]).id == "issue-3", "github factory id")

// MARK: - branch naming

section("branch naming")
eq(TaskBranch.slug("Dark Mode"), "dark-mode", "slug: space becomes dash")
eq(TaskBranch.slug("  Fix:   the  thing! "), "fix-the-thing", "slug: runs collapse and trim")
eq(TaskBranch.slug("深色模式改造"), "", "slug: pure Chinese yields empty")
eq(TaskBranch.slug("Café 面板 v2"), "caf-v2", "slug: non-ASCII letters dropped")
eq(TaskBranch.slug(String(repeating: "a", count: 60)).count, 40, "slug: 40 character cap")
eq(TaskBranch.defaultBranch(queueName: "Dark Mode", queueID: "q-7f3a"), "feature/dark-mode", "default branch from the name")
eq(TaskBranch.defaultBranch(queueName: "深色模式改造", queueID: "q-7f3a"), "feature/queue-7f3a", "default branch falls back to the queue id")
eq(TaskBranch.issueBranch(number: 3, labels: ["bug"]), "fix/issue-3", "issue branch for a bug")
eq(TaskBranch.issueBranch(number: 3, labels: ["kind/feature"]), "feature/issue-3", "issue branch for a feature label")
eq(TaskBranch.issueBranch(number: 3, labels: ["Enhancement"]), "feature/issue-3", "issue branch label match is case-insensitive")

// MARK: - queue membership

section("queue membership")
var board = TaskBoard()
let a = TaskItem.manual(title: "A", id: "manual-aaaa0001")
let b = TaskItem.manual(title: "B", id: "manual-aaaa0002")
board.tasks = [a, b]
let queue = board.createQueue(name: "Dark Mode")

eq(queue.branch, "feature/dark-mode", "queue branch default")
eq(queue.state, QueueState.paused, "a new queue is paused")
eq(queue.autoPR, false, "autoPR is off by default")
check(queue.autoCreated == false, "a user queue is not auto")
check(board.enqueue(taskID: a.id, into: queue.id), "enqueue A")
check(board.enqueue(taskID: a.id, into: queue.id) == false, "enqueue is idempotent")
check(board.enqueue(taskID: b.id, into: queue.id), "enqueue B")
check(board.task(a.id)?.state == .queued, "A is queued")
check(board.task(a.id)?.queueId == queue.id, "A knows its queue")
check(board.order(of: a.id) == 1, "A is position 1")
check(board.order(of: b.id) == 2, "B is position 2")
eq(board.queue(queue.id)?.taskIds.count, 2, "queue holds both tasks")
eq(board.unqueued.count, 0, "nothing is left unqueued")

check(board.dequeue(taskID: b.id), "dequeue B")
check(board.task(b.id)?.state == .pending, "B is back to pending")
check(board.task(b.id)?.queueId == nil, "B left the queue")
check(board.order(of: b.id) == nil, "B has no queue position")
eq(board.queue(queue.id)?.taskIds, [a.id], "the queue kept only A")
eq(board.unqueued.count, 1, "B shows up in the unqueued area")

board.markRunning(a.id)
check(board.dequeue(taskID: a.id) == false, "a running task cannot be dequeued")
check(board.task(a.id)?.state == .running, "A is running")
eq(board.queue(queue.id)?.state, QueueState.active, "the queue is active while running")
eq(board.local.activeQueueID, queue.id, "the active queue is recorded")
check(board.task(a.id)?.branch == "feature/dark-mode", "the queue branch is copied onto the task")
check(board.nextStartable() == nil, "nothing else starts while a task runs")

board.markDone(a.id, prUrl: "https://example.test/pull/1")
check(board.task(a.id)?.state == .done, "A is done")
check(board.task(a.id)?.prUrl == "https://example.test/pull/1", "the PR is recorded")
eq(board.queue(queue.id)?.state, QueueState.done, "an empty queue becomes done")

// MARK: - failure pauses the queue

section("failure pauses the queue")
var boardF = TaskBoard()
let f1 = TaskItem.manual(title: "F1", id: "manual-bbbb0001")
let f2 = TaskItem.manual(title: "F2", id: "manual-bbbb0002")
boardF.tasks = [f1, f2]
let fq = boardF.createQueue(name: "Payment Refactor", baseBranch: "develop", autoPR: true)
check(boardF.queue(fq.id)?.branch == "feature/payment-refactor", "queue branch from the name")
check(boardF.queue(fq.id)?.baseBranch == "develop", "base branch kept")
check(boardF.queue(fq.id)?.autoPR == true, "autoPR option kept")
_ = boardF.enqueue(taskID: f1.id, into: fq.id)
_ = boardF.enqueue(taskID: f2.id, into: fq.id)
boardF.resumeQueue(fq.id)
boardF.markRunning(f1.id)
let pausedQueue = boardF.markFailed(f1.id, error: "boom")
check(pausedQueue == fq.id, "failing pauses its queue")
eq(boardF.queue(fq.id)?.state, QueueState.paused, "the queue is paused")
check(boardF.task(f2.id)?.state == .queued, "the next task stays queued")
check(boardF.task(f1.id)?.error == "boom", "the error is recorded")
check(boardF.nextStartable() == nil, "a paused queue starts nothing")

check(boardF.retryAndResume(f1.id), "retry is accepted")
check(boardF.task(f1.id)?.state == .queued, "the task is queued again")
check(boardF.task(f1.id)?.error == nil, "the error is cleared")
eq(boardF.queue(fq.id)?.state, QueueState.active, "retry resumes the queue")
check(boardF.nextStartable() == f1.id, "the retried task is next")

boardF.markRunning(f1.id)
_ = boardF.markFailed(f1.id, error: "boom again")
boardF.resumeQueue(fq.id)
check(boardF.nextStartable() == f2.id, "skipping the failed task picks the next queued one")

var boardLone = TaskBoard()
let lonely = TaskItem.manual(title: "Lonely", id: "manual-bbbb0003")
boardLone.tasks = [lonely]
boardLone.markRunning(lonely.id)
check(boardLone.markFailed(lonely.id, error: "nope") == nil, "a task with no queue pauses nothing")
check(boardLone.task(lonely.id)?.state == .failed, "the task still fails")

// MARK: - the default base branch chain

section("默认基线分支：问 git，而不是假设 main")
do {
    eq(TaskBranch.defaultBaseBranch(symbolicRef: "origin/develop", current: "main",
                                    hasMain: true, hasMaster: false), "develop",
       "远端 HEAD 说了算")
    eq(TaskBranch.defaultBaseBranch(symbolicRef: "origin/master", current: "main",
                                    hasMain: true, hasMaster: true), "master",
       "master 仓库拿到的是 master —— 这正是旧代码硬编码 main 会失败的那种仓库")
    eq(TaskBranch.defaultBaseBranch(symbolicRef: "refs/remotes/origin/main", current: "dev",
                                    hasMain: true, hasMaster: false), "main",
       "完整 ref 形状也认")
    eq(TaskBranch.defaultBaseBranch(symbolicRef: nil, current: "main",
                                    hasMain: true, hasMaster: false), "main",
       "没有远端 HEAD：退回本地 main")
    eq(TaskBranch.defaultBaseBranch(symbolicRef: nil, current: "dev",
                                    hasMain: false, hasMaster: false), "dev",
       "本地既没有 main 也没有 master：就用当前分支")
    eq(TaskBranch.defaultBaseBranch(symbolicRef: nil, current: "HEAD",
                                    hasMain: false, hasMaster: false), "main",
       "游离头：最后退回 main")
    eq(TaskBranch.defaultBaseBranch(symbolicRef: "origin/HEAD", current: "dev",
                                    hasMain: false, hasMaster: false), "dev",
       "symbolic ref 只指着 HEAD 时不算数，继续往下找")
}

// MARK: - auto queue for issue tasks

section("auto queue for issue tasks")
let issue = TaskItem.github(number: 12, title: "Fix dark mode", body: "body", labels: ["bug"])
let autoQueue = TaskQueue.auto(for: issue)
check(autoQueue.autoCreated, "the auto queue is flagged")
check(autoQueue.autoPR, "the auto queue opens a PR")
check(autoQueue.branch == "fix/issue-12", "the auto branch follows the issue rule")
// The queue starts EMPTY and the task joins through enqueue — the one writer of
// membership. It used to pre-load the id AND enqueue it, so the lane drew the
// same card twice (progress 0/2).
eq(autoQueue.taskIds, [], "a brand-new auto queue holds nothing yet")
check(autoQueue.order(of: issue.id) == nil, "so the task has no position in it yet")
let featureIssue = TaskItem.github(number: 7, title: "Add X", labels: ["kind/feature"])
check(TaskQueue.auto(for: featureIssue).branch == "feature/issue-7", "the auto branch for a feature issue")

var boardAuto = TaskBoard()
boardAuto.tasks = [issue]
boardAuto.queues = [autoQueue]
boardAuto.reindexQueueMembership()
check(boardAuto.autoQueueID(forTask: issue.id) == nil, "an empty queue holds no task")
check(boardAuto.enqueue(taskID: issue.id, into: autoQueue.id), "the task joins it through enqueue")
eq(boardAuto.queue(autoQueue.id)?.taskIds, [issue.id], "exactly once")
eq(boardAuto.tasks(inQueue: autoQueue.id).count, 1, "one card in the lane, not two")
check(boardAuto.autoQueueID(forTask: issue.id) == autoQueue.id, "the auto queue is found by task")
check(boardAuto.task(issue.id)?.state == .queued, "membership made the issue task queued")
check(boardAuto.enqueue(taskID: issue.id, into: autoQueue.id) == false,
      "enqueueing the same task into the same queue again is refused")
eq(boardAuto.queue(autoQueue.id)?.taskIds, [issue.id], "so the id can never be doubled")

// A board written by the buggy version (the id listed twice) repairs itself when
// it is loaded: reindexQueueMembership drops the repeat.
var boardDup = TaskBoard()
let dupIssue = TaskItem.github(number: 21, title: "Legacy")
boardDup.tasks = [dupIssue]
var dupQueue = TaskQueue.auto(for: dupIssue)
dupQueue.taskIds = [dupIssue.id, dupIssue.id]
boardDup.queues = [dupQueue]
boardDup.reindexQueueMembership()
eq(boardDup.queue(dupQueue.id)?.taskIds, [dupIssue.id], "a duplicated id is de-duplicated on load")
eq(boardDup.tasks(inQueue: dupQueue.id).count, 1, "so the lane shows one card again")

// MARK: - manual single-task queues (全部处理)

section("全部处理：手动任务也有自己的单任务队列")
do {
    let task = TaskItem.manual(title: "改 README", body: nil, id: "manual-ff001234")
    let queue = TaskQueue.auto(forManual: task, baseBranch: "develop")
    check(queue.autoCreated, "标记为自动队列（不进「加入队列」候选、默认折叠）")
    check(queue.autoPR, "对齐 issue 的语义：完成时开 PR")
    eq(queue.name, "改 README", "队列名就是任务标题")
    eq(queue.branch, "feature/readme", "分支按标题派生")
    eq(queue.baseBranch, "develop", "基线用工作区自己的默认分支")
    eq(queue.taskIds, [], "从空开始：成员关系只有 enqueue 一个写者")

    // 纯中文标题没有 ASCII slug：退回带 id 后缀的名字（唯一、可用）。
    let chinese = TaskQueue.auto(forManual: TaskItem.manual(title: "升级依赖", id: "manual-ff00abcd"))
    eq(chinese.branch, "feature/manual-abcd", "纯中文标题退回 feature/manual-<id4>")
    eq(chinese.name, "升级依赖", "名字仍然是标题")
}

section("全部处理：多个单任务队列按顺序推进（不卡在空转的那个）")
do {
    var board = TaskBoard()
    let a = TaskItem.manual(title: "A", id: "manual-ff01aaaa")
    let b = TaskItem.manual(title: "B", id: "manual-ff02bbbb")
    board.tasks = [a, b]
    let qa = TaskQueue.auto(forManual: a)
    let qb = TaskQueue.auto(forManual: b)
    board.queues = [qa, qb]
    _ = board.enqueue(taskID: a.id, into: qa.id)
    _ = board.enqueue(taskID: b.id, into: qb.id)
    _ = board.resumeQueue(qa.id)
    _ = board.resumeQueue(qb.id)          // 批量时两个队列都是活跃的
    eq(board.nextStartable(), b.id, "先跑 runner 被指到的那个（最后 resume 的）")

    board.markRunning(a.id)
    board.markDone(a.id, prUrl: nil)      // 第一个跑完 → 队列变 done
    eq(board.queue(qa.id)?.state, QueueState.done, "完成的单任务队列变成 done")
    eq(board.nextStartable(), b.id, "接着跑下一个活跃队列 —— 旧实现在这里会卡住")

    board.markRunning(b.id)
    board.markDone(b.id, prUrl: nil)
    eq(board.nextStartable(), nil, "都跑完了：没有可启动的")
}

// MARK: - branch belongs to the queue

section("离开队列之后不再保留那条分支（分支是队列的属性）")
do {
    var board = TaskBoard()
    let task = TaskItem.manual(title: "One", id: "manual-ii001111")
    board.tasks = [task]
    let queue = board.createQueue(name: "Lane")          // feature/lane
    _ = board.enqueue(taskID: task.id, into: queue.id)
    board.markRunning(task.id)
    eq(board.task(task.id)?.branch, "feature/lane", "跑起来时把「跑在哪条分支上」记到任务上")
    _ = board.markFailed(task.id, error: "tasks.errSession")
    _ = board.retryAndResume(task.id)                    // 回到 queued，才能移出队列
    check(board.dequeue(taskID: task.id), "移出队列")
    eq(board.task(task.id)?.branch, nil, "分支不再保留 —— 它属于队列")
    eq(board.task(task.id)?.state, .pending, "任务回到未入队")

    // 删除队列同理：队内任务一起交还分支。
    var removed = TaskBoard()
    let a = TaskItem.manual(title: "A", id: "manual-ii002222")
    let b = TaskItem.manual(title: "B", id: "manual-ii003333")
    removed.tasks = [a, b]
    let lane = removed.createQueue(name: "Lane")
    _ = removed.enqueue(taskID: a.id, into: lane.id)
    _ = removed.enqueue(taskID: b.id, into: lane.id)
    removed.markRunning(a.id)
    _ = removed.markFailed(a.id, error: "tasks.errSession")
    if let i = removed.index(ofTask: b.id) { removed.tasks[i].branch = "feature/lane" }
    check(removed.removeQueue(lane.id), "删除队列")
    eq(removed.task(a.id)?.branch, nil, "失败的那条也交还分支")
    eq(removed.task(b.id)?.branch, nil, "队内其余任务一样")

    // 重新入队到另一条队列：下一次开跑时会换上那条队列的分支。
    let other = removed.createQueue(name: "Other")        // feature/other
    _ = removed.enqueue(taskID: a.id, into: other.id)
    eq(removed.task(a.id)?.branch, nil, "入队本身不写分支（开跑时才记）")
}

// MARK: - summary and restart recovery

section("summary and restart recovery")
var boardR = TaskBoard()
let r1 = TaskItem.manual(title: "R1", id: "manual-dddd0001")
let r2 = TaskItem.manual(title: "R2", id: "manual-dddd0002")
let r3 = TaskItem.github(number: 5, title: "Issue five")
boardR.tasks = [r1, r2, r3]
let rq = boardR.createQueue(name: "Release prep")
_ = boardR.enqueue(taskID: r1.id, into: rq.id)
_ = boardR.enqueue(taskID: r2.id, into: rq.id)
boardR.markRunning(r1.id)
let summary = boardR.summary()
eq(summary.queues, 1, "summary counts queues")
eq(summary.running, 1, "summary counts running")
eq(summary.queued, 1, "summary counts queued")
eq(summary.failed, 0, "summary counts failed")

let recovered = boardR.reconcileAfterRestart(interruptedError: "tasks.errInterrupted")
eq(recovered.interrupted, [r1.id], "the interrupted task is reported")
eq(recovered.pausedQueues, [rq.id], "the active queue is paused")
check(boardR.task(r1.id)?.state == .failed, "a running task becomes failed")
check(boardR.task(r1.id)?.error == "tasks.errInterrupted", "the interrupted error is recorded")
eq(boardR.queue(rq.id)?.state, QueueState.paused, "the queue is paused after a restart")
check(boardR.local.runningTaskID == nil, "no lingering running task")
check(boardR.nextStartable() == nil, "nothing starts right after a restart")

// MARK: - removing a queue

section("removing a queue")
var boardQ = TaskBoard()
let qt = TaskItem.manual(title: "Q", id: "manual-eeee0001")
boardQ.tasks = [qt]
let qq = boardQ.createQueue(name: "Temp")
_ = boardQ.enqueue(taskID: qt.id, into: qq.id)
check(boardQ.removeQueue(qq.id), "the queue is removed")
check(boardQ.task(qt.id)?.state == .pending, "its task is back to pending")
check(boardQ.task(qt.id)?.queueId == nil, "the membership is cleared")
eq(boardQ.queues.count, 0, "the queue is gone")

var boardBusy = TaskBoard()
let bt = TaskItem.manual(title: "Busy", id: "manual-eeee0002")
boardBusy.tasks = [bt]
let bq = boardBusy.createQueue(name: "Busy")
_ = boardBusy.enqueue(taskID: bt.id, into: bq.id)
boardBusy.markRunning(bt.id)
check(boardBusy.removeQueue(bq.id) == false, "a queue with a running task is kept")

// A FAILED task is not "running", so its queue can be deleted: the record (and its
// failure) survives, only the membership goes — which is why the card can no longer
// offer 重试 afterwards (nothing to retry into, see TaskCardModel).
var boardDropped = TaskBoard()
let droppedTask = TaskItem.manual(title: "Failed", id: "manual-eeee0003")
boardDropped.tasks = [droppedTask]
let droppedQueue = boardDropped.createQueue(name: "Failed lane")
_ = boardDropped.enqueue(taskID: droppedTask.id, into: droppedQueue.id)
boardDropped.markRunning(droppedTask.id)
_ = boardDropped.markFailed(droppedTask.id, error: "tasks.errSession")
check(boardDropped.removeQueue(droppedQueue.id), "a queue whose task failed can be deleted")
check(boardDropped.task(droppedTask.id)?.state == .failed, "the failure record is kept")
check(boardDropped.task(droppedTask.id)?.error == "tasks.errSession", "including WHY it failed")
check(boardDropped.task(droppedTask.id)?.queueId == nil, "only the queue membership is cleared")
check(boardDropped.nextStartable() == nil, "and nothing is left to start")

// MARK: - local overlay

section("local overlay and legacy session keys")
var local = TaskLocalState.from([
    "sessions": [
        "6": ["sessionId": "session-old"],
        "manual-ab12cd34": ["sessionId": "session-m"],
        "issue-9": ["sessionId": "session-new"],
    ],
])
eq(local.sessions["issue-6"], "session-old", "a numeric key maps to issue-N")
eq(local.sessions["manual-ab12cd34"], "session-m", "a task id key is kept")
eq(local.sessions["issue-9"], "session-new", "an issue-N key is kept")
local.activeQueueID = "q-1234"
local.runningTaskID = "issue-6"
let dumpedLocal = local.dictionary()
let dumpedSessions = dumpedLocal["sessions"] as? [String: Any] ?? [:]
check(dumpedSessions["issue-6"] != nil, "writing uses task id keys")
check(dumpedSessions["6"] == nil, "no numeric key is written")
check(dumpedLocal["activeQueueId"] as? String == "q-1234", "the active queue is persisted")
check(dumpedLocal["runningTaskId"] as? String == "issue-6", "the running task is persisted")
eq(TaskLocalState.taskID(fromStoredKey: "42"), "issue-42", "legacy key translation")
eq(TaskLocalState.taskID(fromStoredKey: "issue-42"), "issue-42", "a task id key is untouched")

// MARK: - 汇报写回

section("汇报写回：落在任务上、落在 local.json 里、重试时清掉")
do {
    // The agent 汇报 is written back when its task ends (runner → markDone(report:)),
    // kept in the MACHINE-scoped overlay (a report is the last text of a local
    // session), and never in manual.json / index.json — those travel with the repo.
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "改 README", body: nil, id: "manual-rr001111")
    board.tasks = [t1]
    board.markRunning(t1.id)
    board.markDone(t1.id, report: "改完了，用 markdownlint 校验过。")
    eq(board.task(t1.id)?.report, "改完了，用 markdownlint 校验过。", "汇报落在任务上")
    eq(board.local.reports[t1.id], "改完了，用 markdownlint 校验过。", "也落在 local.json 的状态里")
    check(board.task(t1.id)?.manualDictionary()["report"] == nil,
          "manual.json 不写汇报：它是这台机器的会话产物")
    check(board.task(t1.id)?.indexDictionary()["report"] == nil, "committed index 同理")

    // A failure keeps its last words too — that is what the next task needs.
    board.markRunning(t1.id)
    _ = board.markFailed(t1.id, error: "tasks.errTimeout", report: "做到一半，还差测试。")
    eq(board.task(t1.id)?.report, "做到一半，还差测试。", "失败的汇报同样留下")

    // …and a retry starts a NEW run: the old report must not read as this run outcome.
    _ = board.retryAndResume(t1.id)
    eq(board.task(t1.id)?.report, nil, "重试清掉上一轮的汇报")
    check(board.local.reports[t1.id] == nil, "local 那份也清掉")

    // An empty report is not a report.
    board.markRunning(t1.id)
    board.markDone(t1.id, report: "   ")
    eq(board.task(t1.id)?.report, nil, "空白汇报不写")

    // Round-trip through local.json, and through the loader that attaches it.
    let repo = tempRepo("reports")
    var store = TaskBoard()
    let stored = TaskItem.manual(title: "带汇报的任务", body: nil, id: "manual-rr002222")
    store.tasks = [stored]
    store.markDone(stored.id, report: "存起来的汇报")
    TasksStore.saveLocalHalf(repo, store)
    let loaded = TasksStore.load(repo)
    eq(loaded.task(stored.id)?.report, "存起来的汇报", "local.json 往返之后汇报还在")
    var fresh = TaskBoard()
    fresh.tasks = [stored]
    fresh.attachSessions(["manual-rr002222": "session-x"],
                         reports: ["manual-rr002222": "从 local.json 回来的汇报"])
    eq(fresh.task(stored.id)?.report, "从 local.json 回来的汇报", "attachSessions 也带上汇报")
}

// MARK: - persistence

section("persistence: four files")
let repo = tempRepo("store")
var boardS = TaskBoard()
let m1 = TaskItem.manual(title: "Polish README", body: "tidy the install section")
boardS.tasks = [m1]
let sq = boardS.createQueue(name: "Docs Cleanup")
_ = boardS.enqueue(taskID: m1.id, into: sq.id)
boardS.local.sessions[m1.id] = "session-manual-1"
TasksStore.saveLocalHalf(repo, boardS)

let manualJSON = text(at: TasksStore.path(repo, file: "manual.json"))
check(manualJSON.contains("Polish README"), "manual.json holds the task")
check(manualJSON.contains("tidy the install section"), "manual.json holds the body")
check(!manualJSON.contains("session-manual-1"), "manual.json carries no session id")
let queuesJSON = text(at: TasksStore.path(repo, file: "queues.json"))
check(queuesJSON.contains("Docs Cleanup"), "queues.json holds the name")
// Foundation escapes "/" as "\/" inside JSON strings, so assert on the parsed
// value rather than the raw text (a literal "feature/docs-cleanup" is never
// present in the file bytes).
let queueEntries = TasksStore.readJSON(TasksStore.path(repo, file: "queues.json"))["queues"] as? [[String: Any]] ?? []
check(queueEntries.first?["branch"] as? String == "feature/docs-cleanup", "queues.json holds the derived branch")
let localJSON = text(at: TasksStore.path(repo, file: "local.json"))
check(localJSON.contains("session-manual-1"), "local.json holds the session")
check(!FileManager.default.fileExists(atPath: TasksStore.path(repo, file: "index.json")),
      "the committed index is not touched by a local save")

let reloaded = TasksStore.load(repo)
check(reloaded.task(m1.id) != nil, "the manual task reloads")
eq(reloaded.tasks(inQueue: sq.id).count, 1, "the membership reloads")
check(reloaded.task(m1.id)?.sessionId == "session-manual-1", "the session is re-attached")
check(reloaded.task(m1.id)?.body == "tidy the install section", "the body round-trips")
check(reloaded.queue(sq.id)?.branch == "feature/docs-cleanup", "the queue branch round-trips")
check(reloaded.task(m1.id)?.state == .queued, "the queued state round-trips")

// MARK: - index.json compatibility

section("index.json v1 compatibility")
let repoLegacy = tempRepo("legacy")
let v1Index = """
{
  "tasks" : [
    {
      "body" : null,
      "branch" : "fix/issue-6",
      "finishedAt" : "2026-08-20T14:58:06Z",
      "issue" : 6,
      "labels" : [],
      "prUrl" : "https://example.test/pull/20",
      "startedAt" : "2026-08-20T14:53:20Z",
      "state" : "closed",
      "title" : "Appearance switching"
    }
  ],
  "version" : 1
}
"""
write(v1Index, to: TasksStore.path(repoLegacy, file: "index.json"))
let legacy = TasksStore.load(repoLegacy)
eq(legacy.tasks.count, 1, "one legacy task loads")
check(legacy.tasks.first?.id == "issue-6", "the legacy id derives from the issue number")
check(legacy.tasks.first?.state == .closed, "the legacy state is kept")
check(legacy.tasks.first?.body == nil, "a null body reads as nil")
check(legacy.tasks.first?.startedAt != nil, "the timestamp parses")
check(legacy.tasks.first?.labels.isEmpty == true, "labels load")

TasksStore.mergeIssueTask(repoLegacy, issue: 3, update: ["title": "third", "state": "pending"])
let indexObject = TasksStore.readJSON(TasksStore.path(repoLegacy, file: "index.json"))
eq(indexObject["version"] as? Int, 1, "the index version stays 1")
let entries = indexObject["tasks"] as? [[String: Any]] ?? []
eq(entries.count, 2, "both entries are present")
eq(entries.first?["issue"] as? Int, 3, "entries stay sorted by issue number")
check(entries.last?["title"] as? String == "Appearance switching", "the existing entry is preserved")

// MARK: - corrupt files

section("corrupt files are tolerated")
let repoBroken = tempRepo("broken")
write("not json at all", to: TasksStore.path(repoBroken, file: "manual.json"))
write("{ \"tasks\": 5 }", to: TasksStore.path(repoBroken, file: "queues.json"))
write("[1, 2, 3]", to: TasksStore.path(repoBroken, file: "local.json"))
let broken = TasksStore.load(repoBroken)
eq(broken.tasks.count, 0, "corrupt manual.json yields no tasks")
eq(broken.queues.count, 0, "corrupt queues.json yields no queues")
eq(broken.local.sessions.count, 0, "corrupt local.json yields no sessions")
check(FileManager.default.fileExists(atPath: TasksStore.path(repoBroken, file: "manual.json")),
      "a corrupt file is never deleted by a read")

// MARK: - membership repair

section("membership repair on load")
let repoDrift = tempRepo("drift")
write("""
{ "tasks" : [ { "id" : "manual-ffff0001", "title" : "Drifted", "state" : "pending" } ], "version" : 1 }
""", to: TasksStore.path(repoDrift, file: "manual.json"))
write("""
{ "queues" : [ { "autoCreated" : false, "autoPR" : false, "baseBranch" : "main",
  "branch" : "feature/drift", "id" : "q-drift1", "name" : "Drift",
  "state" : "paused", "taskIds" : [ "manual-ffff0001" ] } ], "version" : 1 }
""", to: TasksStore.path(repoDrift, file: "queues.json"))
let repaired = TasksStore.load(repoDrift)
check(repaired.task("manual-ffff0001")?.queueId == "q-drift1", "the queue id is re-derived from the queue")
check(repaired.task("manual-ffff0001")?.state == .queued, "a listed pending task becomes queued")
check(repaired.task("manual-ffff0001")?.title == "Drifted", "the rest of the task is untouched")

for dir in [repo, repoLegacy, repoBroken, repoDrift] {
    try? FileManager.default.removeItem(atPath: dir)
}

if failures == 0 {
    print("ok - \(checks) checks passed")
} else {
    print("FAILED - \(failures) of \(checks) checks failed")
    exit(1)
}
