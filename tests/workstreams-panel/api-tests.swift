//
//  api-tests.swift — headless tests for WorkstreamsAPIRouter (no AppKit, no disk).
//  Provides minimal HTTPRequest / HTTPResponse stand-ins so it compiles with only
//  WorkstreamsCore.swift + WorkstreamsAPI.swift.
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

final class FakeWorkstreamsAPI: WorkstreamsAPIDelegate {
    var listResult: [String: Any] = ["ok": true, "workstreams": []]
    var createResult: [String: Any] = ["ok": true]
    var updateResult: [String: Any] = ["ok": true]
    var stageResult: [String: Any] = ["ok": true]
    var planResult: [String: Any] = ["ok": true]
    var queuesResult: [String: Any] = ["ok": true]

    var lastListWorkspace: String?
    var lastCreate: WorkstreamsCreateRequest?
    var lastUpdate: WorkstreamsUpdateRequest?
    var lastStage: WorkstreamsStageRequest?
    var lastPlan: WorkstreamsPlanRequest?
    var lastQueues: WorkstreamsQueuesRequest?

    func apiWorkstreamsList(workspace: String?) -> [String: Any] {
        lastListWorkspace = workspace
        return listResult
    }
    func apiWorkstreamsCreate(_ request: WorkstreamsCreateRequest) -> [String: Any] {
        lastCreate = request
        return createResult
    }
    func apiWorkstreamsUpdate(_ request: WorkstreamsUpdateRequest) -> [String: Any] {
        lastUpdate = request
        return updateResult
    }
    func apiWorkstreamsStage(_ request: WorkstreamsStageRequest) -> [String: Any] {
        lastStage = request
        return stageResult
    }
    func apiWorkstreamsPlan(_ request: WorkstreamsPlanRequest) -> [String: Any] {
        lastPlan = request
        return planResult
    }
    func apiWorkstreamsQueues(_ request: WorkstreamsQueuesRequest) -> [String: Any] {
        lastQueues = request
        return queuesResult
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
let fake = FakeWorkstreamsAPI()
check(WorkstreamsAPIRouter.route(HTTPRequest(method: "GET", path: "/api/browser/status"), delegate: fake) == nil,
      "non-workstreams path falls through (nil)")
check(WorkstreamsAPIRouter.route(HTTPRequest(method: "GET", path: "/api/tasks/task/list"), delegate: fake) == nil,
      "tasks path falls through (nil)")
check(WorkstreamsAPIRouter.route(HTTPRequest(method: "GET", path: "/api/requirements/list"), delegate: fake) == nil,
      "requirements path falls through (nil)")

let unavailable = WorkstreamsAPIRouter.route(HTTPRequest(method: "GET", path: "/api/workstreams/list"), delegate: nil)
eq(unavailable?.status, 503, "no delegate -> 503")
eq(unavailable?.json?["error"] as? String, "panel-unavailable", "503 error code")

let unknown = WorkstreamsAPIRouter.route(HTTPRequest(method: "GET", path: "/api/workstreams/nope"), delegate: fake)
eq(unknown?.status, 404, "unknown workstreams endpoint -> 404")
eq(unknown?.json?["error"] as? String, "not-found", "unknown endpoint error code")

section("list")
let list = WorkstreamsAPIRouter.route(HTTPRequest(method: "GET", path: "/api/workstreams/list", query: ["workspace": "~/repo/"]), delegate: fake)
eq(list?.status, 200, "list 200")
eq(fake.lastListWorkspace?.hasSuffix("/repo"), true, "workspace normalized (tilde expanded, trailing slash dropped)")
let listWrongMethod = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/list"), delegate: fake)
eq(listWrongMethod?.status, 404, "list is GET-only")

section("create")
let createNoBody = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/create"), delegate: fake)
eq(createNoBody?.status, 400, "create without body -> 400")
eq(createNoBody?.json?["error"] as? String, "missing-body", "missing-body code")

let createNoTitle = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/create", json: ["title": "   "]), delegate: fake)
eq(createNoTitle?.status, 400, "create without title -> 400")
eq(createNoTitle?.json?["error"] as? String, "missing-title", "missing-title code")

let createInvalidStage = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/create", json: ["title": "x", "stage": "flying"]), delegate: fake)
eq(createInvalidStage?.status, 400, "create with invalid stage -> 400")
eq(createInvalidStage?.json?["error"] as? String, "invalid-stage", "invalid-stage code (negative path)")

let createOK = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/create", json: ["title": "  事项  ", "requirement": " REQ-000001 ", "body": "正文", "workspace": "/tmp/ws", "session": " s-9 "]), delegate: fake)
eq(createOK?.status, 200, "create 200")
eq(fake.lastCreate?.title, "事项", "create title trimmed")
eq(fake.lastCreate?.requirement, "REQ-000001", "create requirement trimmed")
eq(fake.lastCreate?.stage, .planning, "create stage defaults to planning")
eq(fake.lastCreate?.body, "正文", "create body passed through")
eq(fake.lastCreate?.workspace, "/tmp/ws", "create workspace normalized")
eq(fake.lastCreate?.session, "s-9", "create carries the (trimmed) source session")

let createExplicitStage = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/create", json: ["title": "x", "stage": " acceptance "]), delegate: fake)
eq(createExplicitStage?.status, 200, "create with explicit stage 200")
eq(fake.lastCreate?.stage, .acceptance, "create stage parsed")
let createBlankStage = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/create", json: ["title": "x", "stage": "  "]), delegate: fake)
eq(createBlankStage?.json?["error"] as? String, "missing-stage", "blank explicit stage -> missing-stage")

section("update")
let updateNoId = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/update", json: ["title": "x"]), delegate: fake)
eq(updateNoId?.status, 400, "update without id -> 400")
eq(updateNoId?.json?["error"] as? String, "missing-id", "update missing-id code")

let updateNoFields = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/update", json: ["id": "WS-000001"]), delegate: fake)
eq(updateNoFields?.status, 400, "update without any field -> 400")
eq(updateNoFields?.json?["error"] as? String, "no-fields", "no-fields code (negative path)")

let updateBlankTitle = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/update", json: ["id": "WS-000001", "title": "  "]), delegate: fake)
eq(updateBlankTitle?.status, 400, "update with blank title -> 400")
eq(updateBlankTitle?.json?["error"] as? String, "missing-title", "update blank-title code")

let updateOK = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/update", json: ["id": "WS-000001", "title": " 新标题 ", "requirement": "REQ-000002", "body": "新正文", "workspace": "/tmp/ws"]), delegate: fake)
eq(updateOK?.status, 200, "update 200")
eq(fake.lastUpdate?.id, "WS-000001", "update id routed")
eq(fake.lastUpdate?.title, "新标题", "update title trimmed")
eq(fake.lastUpdate?.requirement, "REQ-000002", "update requirement passed through")
eq(fake.lastUpdate?.body, "新正文", "update body passed through")

let updateClear = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/update", json: ["id": "WS-000001", "requirement": ""]), delegate: fake)
eq(updateClear?.status, 200, "update clearing requirement 200")
eq(fake.lastUpdate?.requirement, "", "explicit empty requirement clears (non-nil)")
eq(fake.lastUpdate?.title == nil, true, "absent title stays nil (unchanged)")
eq(fake.lastUpdate?.body == nil, true, "absent body stays nil (unchanged)")

section("stage")
let stageNoId = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/stage", json: ["stage": "design"]), delegate: fake)
eq(stageNoId?.json?["error"] as? String, "missing-id", "stage missing-id code")

let stageNoStage = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/stage", json: ["id": "WS-000001"]), delegate: fake)
eq(stageNoStage?.status, 400, "stage without stage -> 400")
eq(stageNoStage?.json?["error"] as? String, "missing-stage", "stage missing-stage code")

let stageInvalid = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/stage", json: ["id": "WS-000001", "stage": "nope"]), delegate: fake)
eq(stageInvalid?.status, 400, "stage invalid -> 400")
eq(stageInvalid?.json?["error"] as? String, "invalid-stage", "stage invalid-stage code")

let stageOK = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/stage", json: ["id": "WS-000001", "stage": " delivery "]), delegate: fake)
eq(stageOK?.status, 200, "stage 200")
eq(fake.lastStage?.stage, .delivery, "stage parsed")
eq(fake.lastStage?.id, "WS-000001", "stage id routed")

section("plan")
let planNoId = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/plan", json: ["text": "x"]), delegate: fake)
eq(planNoId?.json?["error"] as? String, "missing-id", "plan missing-id code")

let planNoText = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/plan", json: ["id": "WS-000001"]), delegate: fake)
eq(planNoText?.status, 400, "plan without text -> 400")
eq(planNoText?.json?["error"] as? String, "missing-text", "missing-text code (negative path)")

let planDefaultHeading = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/plan", json: ["id": "WS-000001", "text": "- 目标：…"]), delegate: fake)
eq(planDefaultHeading?.status, 200, "plan 200")
eq(fake.lastPlan?.heading, "## 规划", "plan heading defaults to ## 规划")
eq(fake.lastPlan?.text, "- 目标：…", "plan text passed through")

let planBareHeading = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/plan", json: ["id": "WS-000001", "heading": "设计", "text": "x"]), delegate: fake)
eq(fake.lastPlan?.heading, "## 设计", "bare plan heading gets the ## prefix")
let planFullHeading = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/plan", json: ["id": "WS-000001", "heading": "## 规划确认（人）", "text": "x"]), delegate: fake)
eq(fake.lastPlan?.heading, "## 规划确认（人）", "explicit markdown heading kept verbatim")

section("queues")
let queuesNoId = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/queues", json: ["queues": []]), delegate: fake)
eq(queuesNoId?.json?["error"] as? String, "missing-id", "queues missing-id code")

let queuesMissing = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/queues", json: ["id": "WS-000001"]), delegate: fake)
eq(queuesMissing?.status, 400, "queues without queues -> 400")
eq(queuesMissing?.json?["error"] as? String, "missing-queues", "missing-queues code")

let queuesBadEntry = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/queues", json: ["id": "WS-000001", "queues": [["stage": "planning"]]]), delegate: fake)
eq(queuesBadEntry?.status, 400, "queue entry without id -> 400")
eq(queuesBadEntry?.json?["error"] as? String, "invalid-queue", "invalid-queue code (negative path)")

let queuesBadStage = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/queues", json: ["id": "WS-000001", "queues": [["id": "q-1", "stage": "warp"]]]), delegate: fake)
eq(queuesBadStage?.json?["error"] as? String, "invalid-stage", "queue invalid-stage code")

let queuesOK = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/queues", json: ["id": "WS-000001", "queues": [["id": " q-1 ", "stage": "planning"], ["id": "q-2"]]]), delegate: fake)
eq(queuesOK?.status, 200, "queues 200")
eq(fake.lastQueues?.queues.count, 2, "two queue entries parsed")
eq(fake.lastQueues?.queues[0].id, "q-1", "queue id trimmed")
eq(fake.lastQueues?.queues[0].stage, .planning, "queue stage parsed")
eq(fake.lastQueues?.queues[1].stage == nil, true, "missing queue stage stays nil")
let queuesClear = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/queues", json: ["id": "WS-000001", "queues": []]), delegate: fake)
eq(queuesClear?.status, 200, "empty queues clears (200)")
eq(fake.lastQueues?.queues.isEmpty, true, "empty queues passes through")
let queuesNotList = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/queues", json: ["id": "WS-000001", "queues": "q-1"]), delegate: fake)
eq(queuesNotList?.json?["error"] as? String, "invalid-queue", "non-list queues -> invalid-queue")

section("error mapping")
fake.listResult = ["ok": false, "error": "no-workspace"]
eq(WorkstreamsAPIRouter.route(HTTPRequest(method: "GET", path: "/api/workstreams/list"), delegate: fake)?.status, 400, "no-workspace -> 400")
fake.stageResult = ["ok": false, "error": "unknown-workstream"]
eq(WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/stage", json: ["id": "WS-9", "stage": "design"]), delegate: fake)?.status, 404, "unknown-workstream -> 404")
fake.updateResult = ["ok": false, "error": "write-failed"]
eq(WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/update", json: ["id": "WS-000001", "title": "x"]), delegate: fake)?.status, 500, "write-failed -> 500")
fake.createResult = ["ok": false, "error": "malformed-frontmatter"]
eq(WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/create", json: ["title": "x"]), delegate: fake)?.status, 400, "malformed-frontmatter -> 400")
eq(WorkstreamsAPIRouter.status(for: ["ok": false, "error": "panel-unavailable"]), 503, "panel-unavailable -> 503")
eq(WorkstreamsAPIRouter.status(for: ["ok": false, "error": "something-new"]), 400, "unknown error code -> 400")

section("WorkstreamError alignment")
let cases: [WorkstreamError] = [
    .noWorkspace, .unknownWorkstream("WS-1"), .missingId, .missingTitle, .missingStage,
    .invalidStage("x"), .invalidQueue("x"), .malformedFrontmatter("x"),
    .missingField("f"), .writeFailed("x"),
]
for errorCase in cases {
    let result = errorCase.apiResult
    eq(result["error"] as? String, errorCase.code, "apiResult carries the model code: " + errorCase.code)
    eq(result["message"] as? String, errorCase.message, "apiResult carries the model message: " + errorCase.code)
    eq(WorkstreamsAPIRouter.status(for: result), errorCase.status, "router status matches WorkstreamError.status for " + errorCase.code)
}

section("response shapes")
let card = WorkstreamCard(id: "WS-000001", title: "事项", requirement: "REQ-000001", stage: .design,
                          covered: CoveredRecord(paths: ["a.swift"], base: "blob-a", head: "tree-b"),
                          regression: "REG-001",
                          queues: [WorkstreamQueue(id: "q-1", stage: .design), WorkstreamQueue(id: "q-2", stage: nil)],
                          delivery: DeliveryInfo(pr: 42, url: "https://example/pull/42", outcome: "merged"),
                          created: "2026-10-06", updated: "2026-10-07", path: "/p/WS-000001.md", body: "# body")
let cardJSON = WorkstreamsAPIResponse.card(card)
eq(cardJSON["id"] as? String, "WS-000001", "card id in JSON")
eq(cardJSON["stage"] as? String, "design", "card stage as raw value")
eq(cardJSON["requirement"] as? String, "REQ-000001", "card requirement in JSON")
eq(cardJSON["regression"] as? String, "REG-001", "card regression in JSON")
eq((cardJSON["covered"] as? [String: Any])?["base"] as? String, "blob-a", "covered base in JSON")
eq((cardJSON["covered"] as? [String: Any])?["paths"] as? [String], ["a.swift"], "covered paths in JSON")
let queuesJSON = cardJSON["queues"] as? [[String: Any]]
eq(queuesJSON?.count, 2, "card queues in JSON")
eq(queuesJSON?[0]["stage"] as? String, "design", "queue stage in JSON")
eq(queuesJSON?[1]["stage"] == nil, true, "legacy queue without stage omits the key")
eq((cardJSON["delivery"] as? [String: Any])?["pr"] as? Int, 42, "delivery pr in JSON")
eq((cardJSON["delivery"] as? [String: Any])?["outcome"] as? String, "merged", "delivery outcome in JSON")
eq(cardJSON["body"] as? String, "# body", "card body in JSON")

let bare = WorkstreamCard(id: "WS-000002", title: "bare", requirement: nil, stage: .planning,
                          covered: nil, regression: nil, queues: [], delivery: nil,
                          created: nil, updated: nil, path: "", body: "")
let bareJSON = WorkstreamsAPIResponse.card(bare)
eq(bareJSON["requirement"] == nil, true, "no requirement -> key absent")
eq(bareJSON["covered"] == nil, true, "no covered -> key absent")
eq(bareJSON["queues"] == nil, true, "no queues -> key absent")
eq(bareJSON["delivery"] == nil, true, "no delivery -> key absent")

let snapshot = WorkstreamsSnapshot(workspace: "/w", dshExists: true, workstreams: [card], unparsed: ["/w/WS-bad.md"])
let snapJSON = WorkstreamsAPIResponse.snapshot(snapshot)
eq(snapJSON["ok"] as? Bool, true, "snapshot ok")
eq(snapJSON["workspace"] as? String, "/w", "snapshot workspace")
eq(snapJSON["dshExists"] as? Bool, true, "snapshot dshExists")
eq((snapJSON["workstreams"] as? [[String: Any]])?.count, 1, "snapshot workstreams")
eq(snapJSON["unparsed"] as? [String], ["/w/WS-bad.md"], "snapshot unparsed")
let emptySnap = WorkstreamsAPIResponse.snapshot(WorkstreamsSnapshot(workspace: "/w", dshExists: false, workstreams: [], unparsed: []))
eq(emptySnap["unparsed"] == nil, true, "no unparsed -> key absent")

section("result")
print("workstreams api: " + String(checks - failures) + "/" + String(checks) + " passed")
if failures > 0 { exit(1) }
