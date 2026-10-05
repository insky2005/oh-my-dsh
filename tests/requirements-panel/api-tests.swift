//
//  api-tests.swift — headless tests for RequirementsAPIRouter (no AppKit, no disk).
//  Provides minimal HTTPRequest / HTTPResponse stand-ins so it compiles with only
//  RequirementsCore.swift + RequirementsAPI.swift + TasksAPI.swift (shared workspace helper).
//

import Foundation

// MARK: - HTTP stand-ins (same shape as BrowserAPI.swift)

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
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
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

    var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

// MARK: - Fake delegate

final class FakeRequirementsAPI: RequirementsAPIDelegate {
    var listResult: [String: Any] = ["ok": true, "requirements": []]
    var createResult: [String: Any] = ["ok": true]
    var stateResult: [String: Any] = ["ok": true]
    var proposeResult: [String: Any] = ["ok": true]
    var confirmResult: [String: Any] = ["ok": true]
    var rejectResult: [String: Any] = ["ok": true]

    var lastListWorkspace: String?
    var lastCreate: RequirementsCreateRequest?
    var lastState: RequirementsStateRequest?
    var updateResult: [String: Any] = ["ok": true]
    var lastUpdate: RequirementsUpdateRequest?
    var lastPropose: RequirementsBreakdownRequest?
    var lastConfirm: RequirementsTargetRequest?
    var lastReject: RequirementsTargetRequest?

    func apiRequirementsList(workspace: String?) -> [String: Any] {
        lastListWorkspace = workspace
        return listResult
    }
    func apiRequirementsCreate(_ request: RequirementsCreateRequest) -> [String: Any] {
        lastCreate = request
        return createResult
    }
    func apiRequirementsSetState(_ request: RequirementsStateRequest) -> [String: Any] {
        lastState = request
        return stateResult
    }
    func apiRequirementsUpdate(_ request: RequirementsUpdateRequest) -> [String: Any] {
        lastUpdate = request
        return updateResult
    }
    func apiRequirementsPropose(_ request: RequirementsBreakdownRequest) -> [String: Any] {
        lastPropose = request
        return proposeResult
    }
    func apiRequirementsConfirm(_ request: RequirementsTargetRequest) -> [String: Any] {
        lastConfirm = request
        return confirmResult
    }
    func apiRequirementsReject(_ request: RequirementsTargetRequest) -> [String: Any] {
        lastReject = request
        return rejectResult
    }
}

var checks = 0
var failures = 0
func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { failures += 1; print("  FAIL " + label) }
}
func eq<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected { failures += 1; print("  FAIL " + label + ": got " + String(describing: actual) + ", want " + String(describing: expected)) }
}
func section(_ name: String) { print("--- " + name + " ---") }

// MARK: - Tests

section("routing")
let fake = FakeRequirementsAPI()
check(RequirementsAPIRouter.route(HTTPRequest(method: "GET", path: "/api/browser/status"), delegate: fake) == nil,
      "non-requirements path falls through (nil)")
check(RequirementsAPIRouter.route(HTTPRequest(method: "GET", path: "/api/tasks/task/list"), delegate: fake) == nil,
      "tasks path falls through (nil)")

let unavailable = RequirementsAPIRouter.route(HTTPRequest(method: "GET", path: "/api/requirements/list"), delegate: nil)
eq(unavailable?.status, 503, "no delegate -> 503")
eq(unavailable?.json?["error"] as? String, "panel-unavailable", "503 error code")

let unknown = RequirementsAPIRouter.route(HTTPRequest(method: "GET", path: "/api/requirements/nope"), delegate: fake)
eq(unknown?.status, 404, "unknown requirements endpoint -> 404")

section("list")
let list = RequirementsAPIRouter.route(HTTPRequest(method: "GET", path: "/api/requirements/list", query: ["workspace": "~/repo/"]), delegate: fake)
eq(list?.status, 200, "list 200")
eq(fake.lastListWorkspace?.hasSuffix("/repo"), true, "workspace normalized (tilde expanded, trailing slash dropped)")
let listWrongMethod = RequirementsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/requirements/list"), delegate: fake)
eq(listWrongMethod?.status, 404, "list is GET-only")

section("create")
let createNoBody = RequirementsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/requirements/create"), delegate: fake)
eq(createNoBody?.status, 400, "create without body -> 400")
eq(createNoBody?.json?["error"] as? String, "missing-body", "missing-body code")

let createNoTitle = RequirementsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/requirements/create", json: ["title": "   "]), delegate: fake)
eq(createNoTitle?.status, 400, "create without title -> 400")
eq(createNoTitle?.json?["error"] as? String, "missing-title", "missing-title code")

let createOK = RequirementsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/requirements/create", json: ["title": "  想法  ", "body": "详述", "workspace": "/tmp/ws"]), delegate: fake)
eq(createOK?.status, 200, "create 200")
eq(fake.lastCreate?.title, "想法", "title trimmed")
eq(fake.lastCreate?.body, "详述", "body passed through")
eq(fake.lastCreate?.focus, true, "focus defaults to true")
eq(fake.lastCreate?.workspace, "/tmp/ws", "workspace normalized")

let createWithSession = RequirementsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/requirements/create", json: ["title": "x", "session": " s-9 "]), delegate: fake)
eq(createWithSession?.status, 200, "create with session 200")
eq(fake.lastCreate?.session, "s-9", "create carries the (trimmed) source session")

let createNoFocus = RequirementsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/requirements/create", json: ["title": "x", "focus": false]), delegate: fake)
eq(createNoFocus?.status, 200, "create with focus=false 200")
eq(fake.lastCreate?.focus, false, "focus=false honoured")

section("state")
let stateNoId = RequirementsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/requirements/state", json: ["state": "evaluating"]), delegate: fake)
eq(stateNoId?.status, 400, "state without id -> 400")
eq(stateNoId?.json?["error"] as? String, "missing-id", "missing-id code")

let stateNoState = RequirementsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/requirements/state", json: ["id": "REQ-001"]), delegate: fake)
eq(stateNoState?.status, 400, "state without state -> 400")

let stateOK = RequirementsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/requirements/state", json: ["id": "REQ-001", "state": "suspended"]), delegate: fake)
eq(stateOK?.status, 200, "state 200")
eq(fake.lastState?.state, "suspended", "state passed to delegate")

section("update")
let updateNoId = RequirementsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/requirements/update", json: ["title": "x"]), delegate: fake)
eq(updateNoId?.status, 400, "update without id -> 400")
eq(updateNoId?.json?["error"] as? String, "missing-id", "update missing-id code")
let updateNoTitle = RequirementsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/requirements/update", json: ["id": "REQ-001", "title": "   "]), delegate: fake)
eq(updateNoTitle?.status, 400, "update without title -> 400")
let updateOK = RequirementsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/requirements/update", json: ["id": "REQ-001", "title": " 新标题 ", "body": "新诉求", "workspace": "/tmp/ws"]), delegate: fake)
eq(updateOK?.status, 200, "update 200")
eq(fake.lastUpdate?.id, "REQ-001", "update routed to the delegate")
eq(fake.lastUpdate?.title, "新标题", "update title trimmed")
eq(fake.lastUpdate?.body, "新诉求", "update body passed through")

section("breakdown")
let proposeNoItems = RequirementsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/requirements/breakdown/propose", json: ["id": "REQ-001"]), delegate: fake)
eq(proposeNoItems?.status, 400, "propose without items -> 400")
eq(proposeNoItems?.json?["error"] as? String, "no-items", "no-items code")

let proposeBlankItems = RequirementsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/requirements/breakdown/propose", json: ["id": "REQ-001", "items": [["boundary": "no title"]]]), delegate: fake)
eq(proposeBlankItems?.status, 400, "items without titles -> 400")

let proposeOK = RequirementsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/requirements/breakdown/propose", json: ["id": "REQ-001", "items": [["title": " A ", "boundary": "边界", "dependsOn": ["X"]], ["title": "B"]]]), delegate: fake)
eq(proposeOK?.status, 200, "propose 200")
eq(fake.lastPropose?.items.count, 2, "two items parsed")
eq(fake.lastPropose?.items[0].title, "A", "item title trimmed")
eq(fake.lastPropose?.items[0].dependsOn, ["X"], "dependsOn parsed")
eq(fake.lastPropose?.items[1].boundary, "", "missing boundary defaults to empty")

let confirm = RequirementsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/requirements/breakdown/confirm", json: ["id": "REQ-001"]), delegate: fake)
eq(confirm?.status, 200, "confirm 200")
eq(fake.lastConfirm?.id, "REQ-001", "confirm routed to confirm")

let reject = RequirementsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/requirements/breakdown/reject", json: ["id": "REQ-001"]), delegate: fake)
eq(reject?.status, 200, "reject 200")
eq(fake.lastReject?.id, "REQ-001", "reject routed to reject")

section("error mapping")
fake.confirmResult = ["ok": false, "error": "no-proposal"]
eq(RequirementsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/requirements/breakdown/confirm", json: ["id": "REQ-001"]), delegate: fake)?.status, 409, "no-proposal -> 409")
fake.stateResult = ["ok": false, "error": "unknown-requirement"]
eq(RequirementsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/requirements/state", json: ["id": "REQ-9", "state": "candidate"]), delegate: fake)?.status, 404, "unknown-requirement -> 404")
fake.createResult = ["ok": false, "error": "no-workspace"]
eq(RequirementsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/requirements/create", json: ["title": "x"]), delegate: fake)?.status, 400, "no-workspace -> 400")
fake.updateResult = ["ok": false, "error": "breakdown-locked"]
eq(RequirementsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/requirements/update", json: ["id": "REQ-001", "title": "x"]), delegate: fake)?.status, 409, "breakdown-locked -> 409")

section("response shapes")
let card = RequirementCard(id: "REQ-001", title: "t", state: "evaluating", source: "s", created: "2026-10-03", updated: "2026-10-04", path: "", body: "")
let item = PoolItem(requirement: card, effectiveState: .split,
                    children: [WorkstreamSummary(id: "WS-001", title: "w", requirement: "REQ-001", stage: "design", outcome: nil, path: "")],
                    proposal: [BreakdownItem(title: "A", boundary: "b", dependsOn: [])])
let dict = RequirementsAPIResponse.item(item)
eq(dict["effectiveState"] as? String, "split", "item effectiveState in JSON")
eq(dict["derivedState"] as? String, "split", "item derivedState in JSON (children present)")
let noChildItem = PoolItem(requirement: card, effectiveState: .candidate, children: [], proposal: nil)
eq(RequirementsAPIResponse.item(noChildItem)["derivedState"] == nil, true, "no children -> no derivedState key")
eq((dict["children"] as? [[String: Any]])?.count, 1, "children array in JSON")
eq((dict["proposal"] as? [[String: Any]])?.count, 1, "proposal array in JSON")
eq(dict["confirmed"] == nil, true, "no confirmed rows -> key absent")

let itemWithConfirmed = PoolItem(requirement: card, effectiveState: .split,
                                 children: item.children, proposal: nil,
                                 confirmed: [ConfirmedItem(id: "WS-001", title: "w", boundary: "b", dependsOn: ["WS-000009"])])
let confirmedDict = RequirementsAPIResponse.item(itemWithConfirmed)
eq((confirmedDict["confirmed"] as? [[String: Any]])?.count, 1, "confirmed array in JSON")
eq((((confirmedDict["confirmed"] as? [[String: Any]])?.first)?["id"]) as? String, "WS-001", "confirmed id in JSON")
eq((((confirmedDict["confirmed"] as? [[String: Any]])?.first)?["dependsOn"]) as? [String], ["WS-000009"], "confirmed deps in JSON")

section("result")
print("requirements api: " + String(checks - failures) + "/" + String(checks) + " passed")
if failures > 0 { exit(1) }
