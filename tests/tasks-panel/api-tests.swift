import Foundation

// Headless tests for the tasks panel's local API (TasksAPI.swift): routing, request
// parsing, workspace resolution and the response shapes the task-todo skill relies on.
//
// TasksAPI.swift is deliberately AppKit-free, so this file compiles it directly and
// carries only the SHAPE of the shell's HTTP types (BrowserAPI.swift owns the real ones
// and is covered by the app build + the CI compile check). No window, no server.

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

// MARK: - minimal HTTP stand-ins (same shape TasksAPIRouter touches)

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let body: Data

    init(method: String, path: String, query: [String: String] = [:], json: [String: Any]? = nil) {
        self.method = method
        self.path = path
        self.query = query
        self.body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
    }

    func jsonBody() -> [String: Any]? {
        guard !body.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

struct HTTPResponse {
    let status: Int
    let contentType: String
    let body: Data

    static func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }
}

// MARK: - a delegate that records what the router asked of it

final class FakeTasksAPI: TasksAPIDelegate {
    var listResult: [String: Any] = ["ok": true, "tasks": [], "queues": []]
    var createResult: [String: Any] = ["ok": true, "created": [], "rejected": []]
    private(set) var listWorkspaces: [String?] = []
    private(set) var createCalls: [(workspace: String?, focus: Bool, drafts: [TaskCreateDraft])] = []

    func apiTaskList(workspace: String?) -> [String: Any] {
        listWorkspaces.append(workspace)
        return listResult
    }

    func apiTaskCreate(workspace: String?, focus: Bool, drafts: [TaskCreateDraft]) -> [String: Any] {
        createCalls.append((workspace, focus, drafts))
        return createResult
    }

    var queueCreateResult: [String: Any] = ["ok": true, "created": [], "rejected": []]
    var queueStartResult: [String: Any] = ["ok": true, "started": []]
    private(set) var queueCreates: [TaskQueueCreateRequest] = []
    private(set) var queueStarts: [TaskQueueStartRequest] = []

    func apiTaskQueueCreate(_ request: TaskQueueCreateRequest) -> [String: Any] {
        queueCreates.append(request)
        return queueCreateResult
    }

    func apiTaskQueueStart(_ request: TaskQueueStartRequest) -> [String: Any] {
        queueStarts.append(request)
        return queueStartResult
    }

    var queueAppendResult: [String: Any] = ["ok": true, "created": [], "rejected": []]
    private(set) var queueAppends: [TaskQueueAppendRequest] = []
    func apiTaskQueueAppend(_ request: TaskQueueAppendRequest) -> [String: Any] {
        queueAppends.append(request)
        return queueAppendResult
    }

    var queueDeliverResult: [String: Any] = ["ok": true, "delivering": ["q-1"]]
    private(set) var queueDelivers: [TaskQueueDeliverRequest] = []
    func apiTaskQueueDeliver(_ request: TaskQueueDeliverRequest) -> [String: Any] {
        queueDelivers.append(request)
        return queueDeliverResult
    }
}

func topLevel(_ body: [String: Any]) -> HTTPRequest {
    HTTPRequest(method: "POST", path: "/api/tasks/task/create", json: body)
}

// MARK: - routing

section("routing")
let fake = FakeTasksAPI()
check(TasksAPIRouter.route(HTTPRequest(method: "GET", path: "/api/browser/status"), delegate: fake) == nil,
      "browser routes are left to the browser panel")
check(TasksAPIRouter.route(HTTPRequest(method: "GET", path: "/nope"), delegate: fake) == nil,
      "unknown paths return nil (the caller still owns the 404)")
check(TasksAPIRouter.route(HTTPRequest(method: "POST", path: "/api/tasks/task/list"), delegate: fake) == nil,
      "list is GET-only")
check(TasksAPIRouter.route(HTTPRequest(method: "GET", path: "/api/tasks/task/create"), delegate: fake) == nil,
      "create is POST-only")
check(TasksAPIRouter.route(HTTPRequest(method: "GET", path: "/api/tasks/queue/create"), delegate: fake) == nil,
      "queue/create is POST-only")
check(TasksAPIRouter.route(HTTPRequest(method: "GET", path: "/api/tasks/queue/start"), delegate: fake) == nil,
      "queue/start is POST-only")
check(TasksAPIRouter.route(HTTPRequest(method: "GET", path: "/api/tasks/queue/deliver"), delegate: fake) == nil,
      "queue/deliver is POST-only")
// 旧的无资源段路径（/api/tasks/list、/create）保留为 alias：装了旧版技能的用户机器不会断。
// 用独立的 delegate，避免污染上面 fake 的调用记录。
check(TasksAPIRouter.route(HTTPRequest(method: "GET", path: "/api/tasks/list"),
                           delegate: FakeTasksAPI()) != nil,
      "old /api/tasks/list alias still routes")
check(TasksAPIRouter.route(HTTPRequest(method: "POST", path: "/api/tasks/create",
                                       json: ["tasks": ["t"]]), delegate: FakeTasksAPI()) != nil,
      "old /api/tasks/create alias still routes")

section("no delegate yet (the panel is not wired up)")
let unavailable = TasksAPIRouter.route(HTTPRequest(method: "POST", path: "/api/tasks/task/create",
                                                   json: ["tasks": ["t"]]), delegate: nil)
eq(unavailable?.status, 503, "panel-unavailable status")
eq(unavailable?.json["error"] as? String, "panel-unavailable", "panel-unavailable error")
check(TasksAPIRouter.route(HTTPRequest(method: "GET", path: "/api/tasks/task/list"), delegate: nil)?.status == 503,
      "list says panel-unavailable too")

section("GET /api/tasks/task/list")
let list = TasksAPIRouter.route(HTTPRequest(method: "GET", path: "/api/tasks/task/list",
                                            query: ["workspace": "~/repo"]), delegate: fake)
eq(list?.status, 200, "list status")
eq(fake.listWorkspaces.count, 1, "the delegate is asked once")
eq(fake.listWorkspaces.first ?? nil, "~/repo", "the workspace query is forwarded verbatim")
eq(list?.json["ok"] as? Bool, true, "list body passthrough")

section("POST /api/tasks/task/create — request shapes")
let noBody = TasksAPIRouter.route(HTTPRequest(method: "POST", path: "/api/tasks/task/create"), delegate: fake)
eq(noBody?.status, 400, "missing body status")
eq(noBody?.json["error"] as? String, "missing-body", "missing body error")

let noTasks = TasksAPIRouter.route(topLevel(["workspace": "/tmp/x"]), delegate: fake)
eq(noTasks?.status, 400, "missing tasks status")
eq(noTasks?.json["error"] as? String, "missing-tasks", "missing tasks error")
eq((noTasks?.json["rejected"] as? [[String: Any]])?.first?["error"] as? String, "missing-tasks",
   "missing tasks is reported in rejected")

let emptyOnly = TasksAPIRouter.route(topLevel(["tasks": ["", "   "]]), delegate: fake)
eq(emptyOnly?.status, 400, "only empty titles → 400")
eq(emptyOnly?.json["error"] as? String, "no-tasks", "only empty titles → no-tasks")
eq((emptyOnly?.json["rejected"] as? [[String: Any]])?.count, 2, "both empties are rejected")
eq(fake.createCalls.count, 0, "nothing was created, so the panel is never called")

// MARK: - parseCreate

section("parseCreate")
let parsed = TasksAPIRouter.parseCreate([
    "workspace": " /tmp/repo ",
    "tasks": ["只有标题", ["title": "  带描述  ", "body": " 说明 "], ["body": "没有标题"]],
])
eq(parsed.workspace, "/tmp/repo", "workspace is trimmed")
eq(parsed.focus, true, "focus defaults to true")
eq(parsed.drafts.count, 2, "two usable drafts")
eq(parsed.drafts[0].title, "只有标题", "a plain string is a title")
eq(parsed.drafts[0].body, nil, "a plain string has no body")
eq(parsed.drafts[1].title, "带描述", "object title is trimmed")
eq(parsed.drafts[1].body, "说明", "object body is trimmed")
eq(parsed.rejected.count, 1, "the titleless entry is rejected")
eq(parsed.rejected[0]["error"] as? String, "empty-title", "rejected reason")

let notObject = TasksAPIRouter.parseCreate(["tasks": [12]])
eq(notObject.rejected.first?["error"] as? String, "not-an-object", "non-object entry reason")
eq(notObject.drafts.count, 0, "non-object entry creates nothing")

let blankBody = TasksAPIRouter.parseCreate(["tasks": [["title": "t", "body": "   "]]])
eq(blankBody.drafts.first?.body, nil, "a blank body is no body (the panel falls back to the title)")

let focusOff = TasksAPIRouter.parseCreate(["focus": false, "tasks": ["t"]])
eq(focusOff.focus, false, "focus can be turned off")

let many = TasksAPIRouter.parseCreate(["tasks": (0..<60).map { "t\($0)" }])
eq(many.drafts.count, TasksAPIRouter.maxTasksPerCall, "the per-call cap is enforced")
eq(many.rejected.count, 60 - TasksAPIRouter.maxTasksPerCall, "the overflow is rejected")
eq(many.rejected.first?["error"] as? String, "too-many", "overflow reason")

// MARK: - POST /api/tasks/task/create — what the panel receives

section("POST /api/tasks/task/create — delegation and response")
let callFake = FakeTasksAPI()
callFake.createResult = ["ok": true,
                         "workspace": "/tmp/repo",
                         "created": [["id": "manual-1", "title": "一件事"]],
                         "rejected": [["title": "空", "error": "empty-title"]]]
let created = TasksAPIRouter.route(topLevel([
    "workspace": "/tmp/repo",
    "focus": false,
    "tasks": ["一件事", "另一件事"],
]), delegate: callFake)
eq(created?.status, 200, "create status")
eq(callFake.createCalls.count, 1, "one batched call, not one per task")
eq(callFake.createCalls.first?.focus, false, "focus is forwarded")
eq(callFake.createCalls.first?.workspace, "/tmp/repo", "workspace is forwarded")
eq(callFake.createCalls.first?.drafts.count, 2, "both drafts are handed over in one call")
let createdList = created?.json["created"] as? [[String: Any]] ?? []
eq(createdList.count, 1, "created tasks pass through")
eq(createdList.first?["id"] as? String, "manual-1", "the created task's id survives")
eq(createdList.first?["title"] as? String, "一件事", "the created task's title survives")
eq((created?.json["rejected"] as? [[String: Any]])?.count, 1, "panel rejections survive")

let partial = FakeTasksAPI()
partial.createResult = ["created": [["id": "manual-2", "title": "t"]], "rejected": []]
let mixed = TasksAPIRouter.route(topLevel(["tasks": ["t", ""]]), delegate: partial)
eq(mixed?.status, 200, "one usable task is a 200 even with a rejected sibling")
eq(mixed?.json["ok"] as? Bool, true, "ok is derived from created when the panel omits it")
eq((mixed?.json["rejected"] as? [[String: Any]])?.count, 1, "parse-level rejections are merged in")

let nothing = FakeTasksAPI()
nothing.createResult = ["created": [], "rejected": []]
eq(TasksAPIRouter.route(topLevel(["tasks": ["t"]]), delegate: nothing)?.status, 400,
   "no created task → 400")

// MARK: - POST /api/tasks/queue/create — 建「等待态」队列 + 批量入队

section("POST /api/tasks/queue/create")
let qc = FakeTasksAPI()
qc.queueCreateResult = ["ok": true, "workspace": "/repo",
                        "queue": ["id": "q-1", "name": "外观", "state": "draft"],
                        "created": [["id": "manual-1", "title": "t1"]]]
let qCreated = TasksAPIRouter.route(HTTPRequest(method: "POST", path: "/api/tasks/queue/create",
    json: ["workspace": "/repo", "session": "session-x", "focus": false,
           "name": "外观", "branch": "feature/x", "autoPR": true,
           "tasks": [["title": "t1", "body": "b1"], "t2"]]), delegate: qc)
eq(qCreated?.status, 200, "queue create 200")
eq(qc.queueCreates.count, 1, "queue create delegates once")
eq(qc.queueCreates.first?.session, "session-x", "session forwarded")
eq(qc.queueCreates.first?.name, "外观", "name forwarded")
eq(qc.queueCreates.first?.branch, "feature/x", "branch forwarded")
eq(qc.queueCreates.first?.autoPR, true, "autoPR forwarded")
eq(qc.queueCreates.first?.focus, false, "focus forwarded")
eq(qc.queueCreates.first?.drafts.count, 2, "both drafts forwarded in one call")
eq((qCreated?.json["queue"] as? [String: Any])?["state"] as? String, "draft", "queue state passthrough")

let noUsable = TasksAPIRouter.route(HTTPRequest(method: "POST", path: "/api/tasks/queue/create",
    json: ["tasks": ["", "  "]]), delegate: FakeTasksAPI())
eq(noUsable?.status, 400, "no usable tasks → 400")
eq(noUsable?.json["error"] as? String, "no-tasks", "no usable tasks error")
let noBodyQ = TasksAPIRouter.route(HTTPRequest(method: "POST", path: "/api/tasks/queue/create"), delegate: FakeTasksAPI())
eq(noBodyQ?.json["error"] as? String, "missing-body", "queue create missing body")

section("parseQueueCreate")
let parsedQ = TasksAPIRouter.parseQueueCreate(["name": "  ", "tasks": ["由标题命名"], "session": "  s-1 "])
eq(parsedQ.name, "由标题命名", "empty name falls back to the first task title")
eq(parsedQ.session, "s-1", "session is trimmed")
eq(TasksAPIRouter.parseQueueCreate(["session": "   ", "tasks": ["t"]]).session, nil, "blank session → nil")
eq(TasksAPIRouter.parseQueueCreate(["name": "q"]).rejected.first?["error"] as? String, "missing-tasks",
   "missing tasks rejected")
check(TasksAPIRouter.parseQueueCreate(["tasks": ["t"]]).branch == nil, "absent branch stays nil (derive)")
eq(TasksAPIRouter.parseQueueCreate(["tasks": ["t"], "branch": ""]).branch, "", "explicit empty branch means no branch")

// MARK: - POST /api/tasks/queue/start

section("POST /api/tasks/queue/start")
let qs = FakeTasksAPI()
qs.queueStartResult = ["ok": true, "started": ["q-1"]]
let started = TasksAPIRouter.route(HTTPRequest(method: "POST", path: "/api/tasks/queue/start",
    json: ["workspace": "/repo", "session": "s-1"]), delegate: qs)
eq(started?.status, 200, "start 200")
eq(qs.queueStarts.first?.session, "s-1", "start session forwarded")
check(qs.queueStarts.first?.queueId == nil, "start queueId is nil when omitted")

let ambiguous = FakeTasksAPI()
ambiguous.queueStartResult = ["ok": false, "error": "ambiguous-queue", "queues": []]
eq(TasksAPIRouter.route(HTTPRequest(method: "POST", path: "/api/tasks/queue/start", json: [:]), delegate: ambiguous)?.status,
   409, "ambiguous queue → 409")
let noQueue = FakeTasksAPI()
noQueue.queueStartResult = ["ok": false, "error": "no-queue"]
eq(TasksAPIRouter.route(HTTPRequest(method: "POST", path: "/api/tasks/queue/start", json: [:]), delegate: noQueue)?.status,
   404, "no queue → 404")
eq(TasksAPIRouter.route(HTTPRequest(method: "POST", path: "/api/tasks/queue/start", json: ["queueId": " q-1 "]), delegate: qs)?.status,
   200, "queueId with whitespace still starts")
eq(qs.queueStarts.last?.queueId, "q-1", "queueId is trimmed")

// start by NAME: the disambiguation the skill can use without listing first.
let namedStart = TasksAPIRouter.route(HTTPRequest(method: "POST", path: "/api/tasks/queue/start",
    json: ["name": "  外观  "]), delegate: qs)
eq(namedStart?.status, 200, "start by name")
eq(qs.queueStarts.last?.name, "外观", "name is trimmed and forwarded")
eq(TasksAPIRouter.parseQueueStart(["name": "  "]).name, nil, "blank name → nil")
check(TasksAPIRouter.parseQueueStart(["name": "外观"]).queueId == nil, "name alone leaves queueId nil")

section("POST /api/tasks/queue/append")
let qa = FakeTasksAPI()
qa.queueAppendResult = ["ok": true, "workspace": "/repo",
                        "queue": ["id": "q-1", "name": "外观", "state": "draft"],
                        "created": [["id": "manual-9", "title": "t9"]]]
let appended = TasksAPIRouter.route(HTTPRequest(method: "POST", path: "/api/tasks/queue/append",
    json: ["workspace": "/repo", "session": "s-1", "name": "外观",
           "tasks": [["title": "再补一条", "body": "b"]]]), delegate: qa)
eq(appended?.status, 200, "append 200")
eq(qa.queueAppends.count, 1, "append delegates once")
eq(qa.queueAppends.first?.name, "外观", "append name forwarded")
eq(qa.queueAppends.first?.session, "s-1", "append session forwarded")
eq(qa.queueAppends.first?.drafts.count, 1, "append drafts forwarded")
eq((appended?.json["queue"] as? [String: Any])?["state"] as? String, "draft", "append queue state passthrough")

let noTarget = TasksAPIRouter.route(HTTPRequest(method: "POST", path: "/api/tasks/queue/append",
    json: ["tasks": ["t"]]), delegate: FakeTasksAPI())
eq(noTarget?.json["error"] as? String, "no-queue-target", "append without a target is rejected")
let noTasksAppend = TasksAPIRouter.route(HTTPRequest(method: "POST", path: "/api/tasks/queue/append",
    json: ["queueId": "q-1"]), delegate: FakeTasksAPI())
eq(noTasksAppend?.json["error"] as? String, "missing-tasks", "append without tasks is rejected")
check(TasksAPIRouter.route(HTTPRequest(method: "GET", path: "/api/tasks/queue/append"), delegate: qa) == nil,
      "queue/append is POST-only")
let parsedAppend = TasksAPIRouter.parseQueueAppend(["queueId": " q-1 ", "name": " ", "session": " s ", "tasks": ["t"]])
eq(parsedAppend.queueId, "q-1", "append queueId trimmed")
check(parsedAppend.name == nil, "append blank name -> nil")
eq(parsedAppend.session, "s", "append session trimmed")

// MARK: - POST /api/tasks/queue/deliver

section("POST /api/tasks/queue/deliver")
let qd = FakeTasksAPI()
qd.queueDeliverResult = ["ok": true, "workspace": "/repo",
                         "queue": ["id": "q-1", "name": "外观", "state": "done"],
                         "delivering": ["q-1"]]
let delivered = TasksAPIRouter.route(HTTPRequest(method: "POST", path: "/api/tasks/queue/deliver",
    json: ["workspace": "/repo", "session": "s-1", "name": "外观"]), delegate: qd)
eq(delivered?.status, 200, "deliver 200")
eq(qd.queueDelivers.count, 1, "deliver delegates once")
eq(qd.queueDelivers.first?.session, "s-1", "deliver session forwarded")
eq(qd.queueDelivers.first?.name, "外观", "deliver name forwarded")
eq(delivered?.json["delivering"] as? [String], ["q-1"], "delivering passthrough")

// 目标定位与 start 同一套解析（queueId 优先、name 次之、session 最后）。
let parsedDeliver = TasksAPIRouter.parseQueueDeliver(["queueId": " q-1 ", "name": "外观", "session": " s "])
eq(parsedDeliver.queueId, "q-1", "deliver queueId trimmed")
eq(parsedDeliver.name, "外观", "deliver name kept")
eq(parsedDeliver.session, "s", "deliver session trimmed")
check(TasksAPIRouter.parseQueueDeliver(["queueId": "  "]).queueId == nil, "blank queueId -> nil")

// HTTP 状态：已有交付会话在跑 / 队列名歧义 → 409；找不到队列 → 404；其余 400。
let busy = FakeTasksAPI()
busy.queueDeliverResult = ["ok": false, "error": "busy"]
eq(TasksAPIRouter.route(HTTPRequest(method: "POST", path: "/api/tasks/queue/deliver", json: ["queueId": "q-1"]), delegate: busy)?.status,
   409, "busy delivery -> 409")
let deliverAmbiguous = FakeTasksAPI()
deliverAmbiguous.queueDeliverResult = ["ok": false, "error": "ambiguous-queue", "queues": []]
eq(TasksAPIRouter.route(HTTPRequest(method: "POST", path: "/api/tasks/queue/deliver", json: ["queueId": "q-1"]), delegate: deliverAmbiguous)?.status,
   409, "ambiguous queue -> 409")
let deliverNoQueue = FakeTasksAPI()
deliverNoQueue.queueDeliverResult = ["ok": false, "error": "no-queue"]
eq(TasksAPIRouter.route(HTTPRequest(method: "POST", path: "/api/tasks/queue/deliver", json: ["queueId": "q-1"]), delegate: deliverNoQueue)?.status,
   404, "no queue -> 404")
let notDone = FakeTasksAPI()
notDone.queueDeliverResult = ["ok": false, "error": "not-deliverable", "state": "active"]
eq(TasksAPIRouter.route(HTTPRequest(method: "POST", path: "/api/tasks/queue/deliver", json: ["queueId": "q-1"]), delegate: notDone)?.status,
   400, "not finished -> 400")
let noBodyDeliver = TasksAPIRouter.route(HTTPRequest(method: "POST", path: "/api/tasks/queue/deliver"), delegate: FakeTasksAPI())
eq(noBodyDeliver?.json["error"] as? String, "missing-body", "deliver missing body")
let noTargetDeliver = TasksAPIRouter.route(HTTPRequest(method: "POST", path: "/api/tasks/queue/deliver",
    json: ["workspace": "/repo"]), delegate: FakeTasksAPI())
eq(noTargetDeliver?.status, 400, "deliver without a queue target → 400")
eq(noTargetDeliver?.json["error"] as? String, "no-queue-target", "deliver without a target is rejected")

// MARK: - workspace resolution

section("workspace resolution")
eq(TasksAPIWorkspace.resolve(requested: "/repo/a", candidates: ["/repo/a", "/repo/b"]), "/repo/a",
   "exact match wins")
eq(TasksAPIWorkspace.resolve(requested: "/repo/a/sub/dir", candidates: ["/repo/a", "/repo/b"]), "/repo/a",
   "a cwd inside the workspace resolves to the workspace (agents run in subdirectories)")
eq(TasksAPIWorkspace.resolve(requested: "/repo/a/sub", candidates: ["/repo/a/sub", "/repo/a"]), "/repo/a/sub",
   "the deepest tracked ancestor wins")
eq(TasksAPIWorkspace.resolve(requested: "/elsewhere/x", candidates: ["/repo/a"]), "/elsewhere/x",
   "an unrelated path is passed through (the caller checks it exists)")
eq(TasksAPIWorkspace.resolve(requested: nil, candidates: ["/repo/a"]), nil,
   "no workspace requested → the panel picks")
eq(TasksAPIWorkspace.resolve(requested: "  ", candidates: ["/repo/a"]), nil, "blank workspace → the panel picks")
eq(TasksAPIWorkspace.resolve(requested: "/repo/a/", candidates: ["/repo/a"]), "/repo/a",
   "a trailing slash still matches")
check(TasksAPIWorkspace.isAncestor("/repo/a", of: "/repo/ab/thing") == false,
      "a shared prefix is not an ancestor (/repo/a vs /repo/ab)")

// MARK: - response shapes

section("task / queue dictionaries")
let manual = TaskItem.manual(title: "标题", body: "描述", id: "manual-ab12cd34")
let taskDict = TasksAPIRouter.taskDictionary(manual, queueName: nil)
eq(taskDict["id"] as? String, "manual-ab12cd34", "task id")
eq(taskDict["title"] as? String, "标题", "task title")
eq(taskDict["state"] as? String, "pending", "task state")
eq(taskDict["source"] as? String, "manual", "task source")
eq(taskDict["body"] as? String, "描述", "task body")
check(taskDict["queueName"] == nil, "no queue → no queueName key")

var queued = manual
queued.queueId = "q1"
queued.state = .queued
let queuedDict = TasksAPIRouter.taskDictionary(queued, queueName: "队列一")
eq(queuedDict["queueName"] as? String, "队列一", "queue name is looked up by the caller")
eq(queuedDict["queueId"] as? String, "q1", "queue id")

let queue = TaskQueue(id: "q1", name: "队列一", branch: "feature/x", baseBranch: "main",
                      taskIds: ["manual-ab12cd34"], state: .active)
let queueDict = TasksAPIRouter.queueDictionary(queue)
eq(queueDict["name"] as? String, "队列一", "queue name")
eq(queueDict["branch"] as? String, "feature/x", "queue branch")
eq(queueDict["tasks"] as? Int, 1, "queue size")
check(queueDict["reportsToSession"] == nil, "no report flag by default")
check(TasksAPIRouter.queueDictionary(queue, reportsToSession: true)["reportsToSession"] as? Bool == true,
      "the report flag appears when asked")

print("api tests: \(checks) checks, \(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
