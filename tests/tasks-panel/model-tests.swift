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

// MARK: - auto queue for issue tasks

section("auto queue for issue tasks")
let issue = TaskItem.github(number: 12, title: "Fix dark mode", body: "body", labels: ["bug"])
let autoQueue = TaskQueue.auto(for: issue)
check(autoQueue.autoCreated, "the auto queue is flagged")
check(autoQueue.autoPR, "the auto queue opens a PR")
check(autoQueue.branch == "fix/issue-12", "the auto branch follows the issue rule")
eq(autoQueue.taskIds, [issue.id], "the auto queue holds exactly its task")
check(autoQueue.order(of: issue.id) == 1, "the auto queue position is 1")
let featureIssue = TaskItem.github(number: 7, title: "Add X", labels: ["kind/feature"])
check(TaskQueue.auto(for: featureIssue).branch == "feature/issue-7", "the auto branch for a feature issue")

var boardAuto = TaskBoard()
boardAuto.tasks = [issue]
boardAuto.queues = [autoQueue]
boardAuto.reindexQueueMembership()
check(boardAuto.autoQueueID(forTask: issue.id) == autoQueue.id, "the auto queue is found by task")
check(boardAuto.task(issue.id)?.state == .queued, "membership made the issue task queued")

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
