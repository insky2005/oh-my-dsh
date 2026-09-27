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
}

func topLevel(_ body: [String: Any]) -> HTTPRequest {
    HTTPRequest(method: "POST", path: "/api/tasks/create", json: body)
}

// MARK: - routing

section("routing")
let fake = FakeTasksAPI()
check(TasksAPIRouter.route(HTTPRequest(method: "GET", path: "/api/browser/status"), delegate: fake) == nil,
      "browser routes are left to the browser panel")
check(TasksAPIRouter.route(HTTPRequest(method: "GET", path: "/nope"), delegate: fake) == nil,
      "unknown paths return nil (the caller still owns the 404)")
check(TasksAPIRouter.route(HTTPRequest(method: "POST", path: "/api/tasks/list"), delegate: fake) == nil,
      "list is GET-only")
check(TasksAPIRouter.route(HTTPRequest(method: "GET", path: "/api/tasks/create"), delegate: fake) == nil,
      "create is POST-only")

section("no delegate yet (the panel is not wired up)")
let unavailable = TasksAPIRouter.route(HTTPRequest(method: "POST", path: "/api/tasks/create",
                                                   json: ["tasks": ["t"]]), delegate: nil)
eq(unavailable?.status, 503, "panel-unavailable status")
eq(unavailable?.json["error"] as? String, "panel-unavailable", "panel-unavailable error")
check(TasksAPIRouter.route(HTTPRequest(method: "GET", path: "/api/tasks/list"), delegate: nil)?.status == 503,
      "list says panel-unavailable too")

section("GET /api/tasks/list")
let list = TasksAPIRouter.route(HTTPRequest(method: "GET", path: "/api/tasks/list",
                                            query: ["workspace": "~/repo"]), delegate: fake)
eq(list?.status, 200, "list status")
eq(fake.listWorkspaces.count, 1, "the delegate is asked once")
eq(fake.listWorkspaces.first ?? nil, "~/repo", "the workspace query is forwarded verbatim")
eq(list?.json["ok"] as? Bool, true, "list body passthrough")

section("POST /api/tasks/create — request shapes")
let noBody = TasksAPIRouter.route(HTTPRequest(method: "POST", path: "/api/tasks/create"), delegate: fake)
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

// MARK: - POST /api/tasks/create — what the panel receives

section("POST /api/tasks/create — delegation and response")
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

print("api tests: \(checks) checks, \(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
