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
    var boundResult: [String: Any] = ["ok": true, "workstreams": []]
    var createResult: [String: Any] = ["ok": true]
    var updateResult: [String: Any] = ["ok": true]
    var stageResult: [String: Any] = ["ok": true]
    var planResult: [String: Any] = ["ok": true]
    var queuesResult: [String: Any] = ["ok": true]
    var stageConfirmResult: [String: Any] = ["ok": true]
    var stageRejectResult: [String: Any] = ["ok": true]
    var taskCreateResult: [String: Any] = ["ok": true]
    var taskListResult: [String: Any] = ["ok": true, "tasks": []]
    var queueStartResult: [String: Any] = ["ok": true]
    var queuePauseResult: [String: Any] = ["ok": true]
    var coveredResult: [String: Any] = ["ok": true]
    var deliveryResult: [String: Any] = ["ok": true]
    var deliverResult: [String: Any] = ["ok": true]

    var lastListWorkspace: String?
    var lastBoundSession: String?
    var lastCreate: WorkstreamsCreateRequest?
    var lastUpdate: WorkstreamsUpdateRequest?
    var lastStage: WorkstreamsStageRequest?
    var lastPlan: WorkstreamsPlanRequest?
    var lastQueues: WorkstreamsQueuesRequest?
    var lastStageConfirm: WorkstreamsStageConfirmRequest?
    var lastStageReject: WorkstreamsStageRejectRequest?
    var lastTaskCreate: WorkstreamsTaskCreateRequest?
    var lastTaskListWorkspace: String?
    var taskListCalls = 0
    var lastQueueStart: WorkstreamsQueueStartRequest?
    var lastQueuePause: WorkstreamsQueuePauseRequest?
    var lastCovered: WorkstreamsCoveredRequest?
    var lastDelivery: WorkstreamsDeliveryRequest?
    var lastDeliver: WorkstreamsDeliverRequest?

    func apiWorkstreamsList(workspace: String?) -> [String: Any] {
        lastListWorkspace = workspace
        return listResult
    }
    func apiWorkstreamsBound(session: String) -> [String: Any] {
        lastBoundSession = session
        return boundResult
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
    func apiWorkstreamsStageConfirm(_ request: WorkstreamsStageConfirmRequest) -> [String: Any] {
        lastStageConfirm = request
        return stageConfirmResult
    }
    func apiWorkstreamsStageReject(_ request: WorkstreamsStageRejectRequest) -> [String: Any] {
        lastStageReject = request
        return stageRejectResult
    }
    func apiWorkstreamsTaskCreate(_ request: WorkstreamsTaskCreateRequest) -> [String: Any] {
        lastTaskCreate = request
        return taskCreateResult
    }
    func apiWorkstreamsTaskList(workspace: String?) -> [String: Any] {
        lastTaskListWorkspace = workspace
        taskListCalls += 1
        return taskListResult
    }
    func apiWorkstreamsQueueStart(_ request: WorkstreamsQueueStartRequest) -> [String: Any] {
        lastQueueStart = request
        return queueStartResult
    }
    func apiWorkstreamsQueuePause(_ request: WorkstreamsQueuePauseRequest) -> [String: Any] {
        lastQueuePause = request
        return queuePauseResult
    }
    func apiWorkstreamsCovered(_ request: WorkstreamsCoveredRequest) -> [String: Any] {
        lastCovered = request
        return coveredResult
    }
    func apiWorkstreamsDelivery(_ request: WorkstreamsDeliveryRequest) -> [String: Any] {
        lastDelivery = request
        return deliveryResult
    }
    func apiWorkstreamsDeliver(_ request: WorkstreamsDeliverRequest) -> [String: Any] {
        lastDeliver = request
        return deliverResult
    }

    var focusCalls: [(workspace: String?, id: String?)] = []
    func apiWorkstreamsFocus(workspace: String?, id: String?) {
        focusCalls.append((workspace, id))
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

section("bound (reverse session lookup)")
let boundUnavailable = WorkstreamsAPIRouter.route(HTTPRequest(method: "GET", path: "/api/workstreams/bound", query: ["session": "s-1"]), delegate: nil)
eq(boundUnavailable?.status, 503, "bound without delegate -> 503")
let boundNoSession = WorkstreamsAPIRouter.route(HTTPRequest(method: "GET", path: "/api/workstreams/bound"), delegate: fake)
eq(boundNoSession?.status, 400, "bound without session -> 400")
eq(boundNoSession?.json?["error"] as? String, "missing-session", "missing-session code")
let boundBlankSession = WorkstreamsAPIRouter.route(HTTPRequest(method: "GET", path: "/api/workstreams/bound", query: ["session": "   "]), delegate: fake)
eq(boundBlankSession?.status, 400, "bound with blank session -> 400")
eq(boundBlankSession?.json?["error"] as? String, "missing-session", "blank session -> missing-session")
fake.boundResult = ["ok": true, "session": "s-1", "workstreams": [["id": "WS-000001"]]]
let boundOK = WorkstreamsAPIRouter.route(HTTPRequest(method: "GET", path: "/api/workstreams/bound", query: ["session": "  s-1  "]), delegate: fake)
eq(boundOK?.status, 200, "bound 200")
eq(fake.lastBoundSession, "s-1", "bound session trimmed and routed")
eq((boundOK?.json?["workstreams"] as? [[String: Any]])?.count, 1, "bound returns the bound workstreams")
let boundWrongMethod = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/bound", json: ["session": "s-1"]), delegate: fake)
eq(boundWrongMethod?.status, 404, "bound is GET-only")

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
eq(fake.lastStage?.stage, .acceptance, "legacy stage: delivery parses as acceptance")
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

// Legacy [{id, stage}] is still accepted for read-compat: the id is taken and the
// stage dropped (design A9 / D16).
let queuesLegacy = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/queues", json: ["id": "WS-000001", "queues": [["id": " q-1 ", "stage": "planning"]]]), delegate: fake)
eq(queuesLegacy?.status, 200, "legacy queue mapping accepted")
eq(fake.lastQueues?.queues, ["q-1"], "legacy queue id taken, stage dropped, id trimmed")

let queuesOK = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/queues", json: ["id": "WS-000001", "queues": ["q-1"]]), delegate: fake)
eq(queuesOK?.status, 200, "canonical [q-...] queues 200")
eq(fake.lastQueues?.queues, ["q-1"], "canonical queue id parsed")

let queuesTooMany = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/queues", json: ["id": "WS-000001", "queues": ["q-1", "q-2"]]), delegate: fake)
eq(queuesTooMany?.json?["error"] as? String, "invalid-queue", "more than one queue -> invalid-queue (0..1)")

let queuesClear = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/queues", json: ["id": "WS-000001", "queues": []]), delegate: fake)
eq(queuesClear?.status, 200, "empty queues clears (200)")
eq(fake.lastQueues?.queues.isEmpty, true, "empty queues passes through")
let queuesNotList = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/queues", json: ["id": "WS-000001", "queues": "q-1"]), delegate: fake)
eq(queuesNotList?.json?["error"] as? String, "invalid-queue", "non-list queues -> invalid-queue")

section("covered write route")
let coveredNoId = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/covered", json: ["covered": ["paths": ["a"]]]), delegate: fake)
eq(coveredNoId?.json?["error"] as? String, "missing-id", "covered missing-id code")
let coveredMissing = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/covered", json: ["id": "WS-000001"]), delegate: fake)
eq(coveredMissing?.status, 400, "covered without covered -> 400")
eq(coveredMissing?.json?["error"] as? String, "missing-covered", "missing-covered code")
let coveredNotObject = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/covered", json: ["id": "WS-000001", "covered": "docs/a.md"]), delegate: fake)
eq(coveredNotObject?.json?["error"] as? String, "invalid-covered", "non-object covered -> invalid-covered")
let coveredNoPaths = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/covered", json: ["id": "WS-000001", "covered": ["base": "blob-a"]]), delegate: fake)
eq(coveredNoPaths?.json?["error"] as? String, "missing-covered-paths", "covered without paths -> missing-covered-paths")
let coveredEmptyPaths = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/covered", json: ["id": "WS-000001", "covered": ["paths": []]]), delegate: fake)
eq(coveredEmptyPaths?.json?["error"] as? String, "missing-covered-paths", "empty covered.paths -> missing-covered-paths (negative path)")
let coveredBlankPath = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/covered", json: ["id": "WS-000001", "covered": ["paths": ["   "]]]), delegate: fake)
eq(coveredBlankPath?.json?["error"] as? String, "invalid-covered", "blank covered path -> invalid-covered")
let coveredOK = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/covered", json: ["id": "WS-000001", "covered": ["paths": [" docs/a.md ", " src/b.swift "], "base": " blob-a ", "head": "tree-b"], "workspace": "/tmp/ws", "session": "s-1"]), delegate: fake)
eq(coveredOK?.status, 200, "covered 200")
eq(fake.lastCovered?.id, "WS-000001", "covered id routed")
eq(fake.lastCovered?.covered?.paths, ["docs/a.md", "src/b.swift"], "covered paths trimmed")
eq(fake.lastCovered?.covered?.base, "blob-a", "covered base trimmed")
eq(fake.lastCovered?.covered?.head, "tree-b", "covered head passed through")
eq(fake.lastCovered?.workspace, "/tmp/ws", "covered workspace normalized")
eq(fake.lastCovered?.session, "s-1", "covered carries session")
let coveredClear = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/covered", json: ["id": "WS-000001", "covered": NSNull()]), delegate: fake)
eq(coveredClear?.status, 200, "covered null clears (200)")
eq(fake.lastCovered?.covered == nil, true, "explicit null covered -> nil (clears)")

section("delivery write route (facts only, derived outcome)")
let deliveryNoId = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/delivery", json: ["delivery": ["pr": 1]]), delegate: fake)
eq(deliveryNoId?.json?["error"] as? String, "missing-id", "delivery missing-id code")
let deliveryMissing = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/delivery", json: ["id": "WS-000001"]), delegate: fake)
eq(deliveryMissing?.status, 400, "delivery without delivery -> 400")
eq(deliveryMissing?.json?["error"] as? String, "missing-delivery", "missing-delivery code")
let deliveryNotObject = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/delivery", json: ["id": "WS-000001", "delivery": "merged"]), delegate: fake)
eq(deliveryNotObject?.json?["error"] as? String, "invalid-delivery", "non-object delivery -> invalid-delivery")
let deliveryBadPr = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/delivery", json: ["id": "WS-000001", "delivery": ["pr": "not-a-number"]]), delegate: fake)
eq(deliveryBadPr?.json?["error"] as? String, "invalid-delivery", "non-numeric pr -> invalid-delivery")
// outcome is a derived cache: hand-writing it is refused both inside the block
// and at the top level (store design 5).
let deliveryHandwritten = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/delivery", json: ["id": "WS-000001", "delivery": ["pr": 42, "outcome": "merged"]]), delegate: fake)
eq(deliveryHandwritten?.status, 400, "hand-written outcome inside delivery -> 400")
eq(deliveryHandwritten?.json?["error"] as? String, "outcome-derived", "outcome-derived code (inside the block)")
let deliveryTopOutcome = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/delivery", json: ["id": "WS-000001", "delivery": ["pr": 42], "outcome": "merged"]), delegate: fake)
eq(deliveryTopOutcome?.json?["error"] as? String, "outcome-derived", "outcome-derived code (top level)")
let deliveryOK = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/delivery", json: ["id": "WS-000001", "delivery": ["pr": " 42 ", "url": " https://github.com/o/r/pull/42 ", "state": "open"], "workspace": "/tmp/ws", "session": "s-2"]), delegate: fake)
eq(deliveryOK?.status, 200, "delivery 200")
eq(fake.lastDelivery?.id, "WS-000001", "delivery id routed")
eq(fake.lastDelivery?.pr, 42, "delivery pr parsed from a numeric string")
eq(fake.lastDelivery?.url, "https://github.com/o/r/pull/42", "delivery url trimmed")
eq(fake.lastDelivery?.state, "open", "delivery PR observation passed through")
eq(fake.lastDelivery?.merged, false, "delivery merged defaults to false")
eq(fake.lastDelivery?.workspace, "/tmp/ws", "delivery workspace normalized")
eq(fake.lastDelivery?.session, "s-2", "delivery carries session")
let deliveryMerged = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/delivery", json: ["id": "WS-000001", "delivery": ["pr": 42, "merged": true]]), delegate: fake)
eq(fake.lastDelivery?.merged, true, "delivery merged observation passed through")
let deliveryClear = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/delivery", json: ["id": "WS-000001", "delivery": NSNull()]), delegate: fake)
eq(deliveryClear?.status, 200, "delivery null clears (200)")
eq(fake.lastDelivery?.pr == nil, true, "explicit null delivery -> nil facts")
eq(WorkstreamsAPIRouter.status(for: ["ok": false, "error": "outcome-derived"]), 400, "outcome-derived -> 400")

section("deliver route (initiate delivery: git/GitHub/token admission + start)")
// 发起交付 = 面板「交付」按钮的同一条路径。路由只做校验与透传；准入与入队/启动由
// 面板的 initiateDelivery 落地（源码守卫固定两条入口共用它）。
let deliverNoBody = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/deliver"), delegate: fake)
eq(deliverNoBody?.status, 400, "deliver without body -> 400")
eq(deliverNoBody?.json?["error"] as? String, "missing-body", "deliver missing-body code")
let deliverNoId = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/deliver", json: ["workspace": "/tmp/ws"]), delegate: fake)
eq(deliverNoId?.status, 400, "deliver without id -> 400")
eq(deliverNoId?.json?["error"] as? String, "missing-id", "deliver missing-id code")
let deliverUnavailable = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/deliver", json: ["id": "WS-000001"]), delegate: nil)
eq(deliverUnavailable?.status, 503, "deliver without delegate -> 503")
let deliverOK = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/deliver", json: ["id": " WS-000001 ", "workspace": "~/repo/", "session": " s-3 "]), delegate: fake)
eq(deliverOK?.status, 200, "deliver 200")
eq(fake.lastDeliver?.id, "WS-000001", "deliver id trimmed and routed")
eq(fake.lastDeliver?.workspace?.hasSuffix("/repo"), true, "deliver workspace normalized")
eq(fake.lastDeliver?.session, "s-3", "deliver carries session")
// 每个失败原因码都原样回传；not-delivery-stage 是状态冲突（409），start-failed 是
// 服务端失败（500），其余准入失败是 400，队列缺失沿用 404。
let deliverFailures: [(String, Int)] = [
    ("not-delivery-stage", 409), ("not-git-repo", 400), ("no-branch", 400),
    ("no-remote", 400), ("no-github-remote", 400), ("no-token", 400),
    ("no-queue", 404), ("start-failed", 500),
]
for (code, expected) in deliverFailures {
    fake.deliverResult = ["ok": false, "error": code, "message": "reason: " + code]
    let response = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/deliver", json: ["id": "WS-000001"]), delegate: fake)
    eq(response?.status, expected, "deliver " + code + " -> " + String(expected))
    eq(response?.json?["error"] as? String, code, "deliver carries the " + code + " reason")
}
fake.deliverResult = ["ok": true]

section("stage gate routes")
let confirmNoId = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/stage/confirm", json: ["stage": "design"]), delegate: fake)
eq(confirmNoId?.json?["error"] as? String, "missing-id", "confirm missing-id code")

let confirmBadStage = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/stage/confirm", json: ["id": "WS-000001", "stage": "warp"]), delegate: fake)
eq(confirmBadStage?.status, 400, "confirm invalid stage -> 400")
eq(confirmBadStage?.json?["error"] as? String, "invalid-stage", "confirm invalid-stage code")

let confirmOK = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/stage/confirm", json: ["id": "WS-000001", "stage": " design ", "note": " 通过 ", "workspace": "/tmp/ws", "session": "s-1"]), delegate: fake)
eq(confirmOK?.status, 200, "confirm 200")
eq(fake.lastStageConfirm?.id, "WS-000001", "confirm id routed")
eq(fake.lastStageConfirm?.stage, .design, "confirm expected stage parsed")
eq(fake.lastStageConfirm?.note, "通过", "confirm note trimmed")
eq(fake.lastStageConfirm?.session, "s-1", "confirm carries session")
eq(fake.lastStageConfirm?.workspace, "/tmp/ws", "confirm workspace normalized")

let confirmNoStage = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/stage/confirm", json: ["id": "WS-000001"]), delegate: fake)
eq(confirmNoStage?.status, 200, "confirm without expected stage is allowed")
eq(fake.lastStageConfirm?.stage == nil, true, "absent expected stage stays nil")

let rejectNoId = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/stage/reject", json: ["reason": "x"]), delegate: fake)
eq(rejectNoId?.json?["error"] as? String, "missing-id", "reject missing-id code")

let rejectNoReason = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/stage/reject", json: ["id": "WS-000001", "reason": "   "]), delegate: fake)
eq(rejectNoReason?.status, 400, "reject without reason -> 400")
eq(rejectNoReason?.json?["error"] as? String, "missing-reason", "missing-reason code (negative path)")

let rejectBadTarget = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/stage/reject", json: ["id": "WS-000001", "reason": "x", "target": "warp"]), delegate: fake)
eq(rejectBadTarget?.json?["error"] as? String, "invalid-stage", "reject invalid target -> invalid-stage")

let rejectOK = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/stage/reject", json: ["id": "WS-000001", "reason": " 边界未定 ", "target": " planning ", "workspace": "/tmp/ws"]), delegate: fake)
eq(rejectOK?.status, 200, "reject 200")
eq(fake.lastStageReject?.reason, "边界未定", "reject reason trimmed")
eq(fake.lastStageReject?.target, .planning, "reject target parsed")

section("stage task create / list and queue start / pause")
let taskCreateNoId = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/task/create", json: ["titles": ["x"]]), delegate: fake)
eq(taskCreateNoId?.json?["error"] as? String, "missing-id", "task/create missing-id code")
let taskCreateNoTitles = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/task/create", json: ["id": "WS-000001"]), delegate: fake)
eq(taskCreateNoTitles?.status, 400, "task/create without titles/body -> 400")
eq(taskCreateNoTitles?.json?["error"] as? String, "missing-titles", "missing-titles code (negative path)")
let taskCreateBadTitles = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/task/create", json: ["id": "WS-000001", "titles": "x"]), delegate: fake)
eq(taskCreateBadTitles?.json?["error"] as? String, "invalid-titles", "non-list titles -> invalid-titles")
let taskCreateBadStage = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/task/create", json: ["id": "WS-000001", "stage": "warp", "titles": ["x"]]), delegate: fake)
eq(taskCreateBadStage?.json?["error"] as? String, "invalid-stage", "task/create invalid stage -> invalid-stage")
let taskCreateBlankStage = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/task/create", json: ["id": "WS-000001", "stage": "  ", "titles": ["x"]]), delegate: fake)
eq(taskCreateBlankStage?.json?["error"] as? String, "missing-stage", "task/create blank explicit stage -> missing-stage")
let taskCreateOK = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/task/create", json: ["id": "WS-000001", "stage": " planning ", "titles": [" 出规划 ", "", "  "], "workspace": "/tmp/ws", "session": "s-1"]), delegate: fake)
eq(taskCreateOK?.status, 200, "task/create 200")
eq(fake.lastTaskCreate?.id, "WS-000001", "task/create id routed")
eq(fake.lastTaskCreate?.stage, .planning, "task/create stage parsed")
eq(fake.lastTaskCreate?.titles, ["出规划"], "task/create titles trimmed and blanks dropped")
eq(fake.lastTaskCreate?.workspace, "/tmp/ws", "task/create workspace normalized")
eq(fake.lastTaskCreate?.session, "s-1", "task/create carries session")
let taskCreateBody = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/task/create", json: ["id": "WS-000001", "body": "正文"]), delegate: fake)
eq(taskCreateBody?.status, 200, "task/create body-only 200")
eq(fake.lastTaskCreate?.body, "正文", "task/create body passed through")
eq(fake.lastTaskCreate?.titles.isEmpty, true, "body-only leaves titles empty (delegate derives one)")
eq(fake.lastTaskCreate?.stage == nil, true, "absent stage stays nil (delegate falls back to the card stage)")
// 阶段原始枚举值是 task/create 的线上契约：四个原始值必须各自解析到对应阶段，
// 而不是因为动作叫「拆分任务」就被改写成 task（bug: 规划拆分落到执行）。旧的
// delivery 保留读兼容，映射到 acceptance（design A17）。
let stageRawValues: [(String, WorkstreamStage)] = [
    ("planning", .planning), ("design", .design), ("task", .task),
    ("acceptance", .acceptance), ("delivery", .acceptance),
]
for (raw, expected) in stageRawValues {
    let created = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/task/create",
                                                          json: ["id": "WS-000001", "stage": raw, "titles": ["x"]]), delegate: fake)
    eq(created?.status, 200, "task/create accepts raw stage " + raw)
    eq(fake.lastTaskCreate?.stage, expected, "raw stage " + raw + " maps to " + expected.rawValue)
}

let taskList = WorkstreamsAPIRouter.route(HTTPRequest(method: "GET", path: "/api/workstreams/task/list", query: ["workspace": "~/repo/"]), delegate: fake)
eq(taskList?.status, 200, "task/list 200")
eq(fake.lastTaskListWorkspace?.hasSuffix("/repo"), true, "task/list workspace normalized")
let taskListWrongMethod = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/task/list"), delegate: fake)
eq(taskListWrongMethod?.status, 404, "task/list is GET-only")

let queueStartNoId = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/queue/start", json: ["stage": "design"]), delegate: fake)
eq(queueStartNoId?.json?["error"] as? String, "missing-id", "queue/start missing-id code")
let queueStartBadStage = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/queue/start", json: ["id": "WS-000001", "stage": "warp"]), delegate: fake)
eq(queueStartBadStage?.json?["error"] as? String, "invalid-stage", "queue/start invalid-stage code")
let queueStartItem = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/queue/start", json: ["id": "WS-000001", "workspace": "/tmp/ws", "session": "s-2"]), delegate: fake)
eq(queueStartItem?.status, 200, "item-level queue/start 200")
eq(fake.lastQueueStart?.stage == nil, true, "item-level start carries no stage")
eq(fake.lastQueueStart?.workspace, "/tmp/ws", "queue/start workspace normalized")
eq(fake.lastQueueStart?.session, "s-2", "queue/start carries session")
let queueStartStage = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/queue/start", json: ["id": "WS-000001", "stage": " design "]), delegate: fake)
eq(queueStartStage?.status, 200, "stage-level queue/start 200")
eq(fake.lastQueueStart?.stage, .design, "queue/start stage parsed")
let queueStartBlankStage = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/queue/start", json: ["id": "WS-000001", "stage": " "]), delegate: fake)
eq(queueStartBlankStage?.json?["error"] as? String, "missing-stage", "queue/start blank stage -> missing-stage")

let queuePauseNoId = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/queue/pause", json: [:]), delegate: fake)
eq(queuePauseNoId?.json?["error"] as? String, "missing-id", "queue/pause missing-id code")
let queuePauseOK = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/queue/pause", json: ["id": "WS-000001", "workspace": "/tmp/ws"]), delegate: fake)
eq(queuePauseOK?.status, 200, "queue/pause 200")
eq(fake.lastQueuePause?.id, "WS-000001", "queue/pause id routed")
eq(WorkstreamsAPIRouter.status(for: ["ok": false, "error": "no-queue"]), 404, "no-queue -> 404")

let taskJSON = WorkstreamsAPIResponse.task("wt-1", title: "T", state: "running",
                                           workstreamId: "WS-1", stage: .task,
                                           sessionId: "session-1", error: nil, report: "汇报")
eq(taskJSON["id"] as? String, "wt-1", "task json id")
eq(taskJSON["state"] as? String, "running", "task json state")
eq(taskJSON["stage"] as? String, "task", "task json stage")
eq(taskJSON["session"] as? String, "session-1", "task json session")
eq(taskJSON["report"] as? String, "汇报", "task json report")
let bareTaskJSON = WorkstreamsAPIResponse.task("wt-2", title: "T2", state: "pending")
eq(bareTaskJSON["workstreamId"] == nil, true, "task json omits empty workstreamId")
eq(bareTaskJSON["session"] == nil, true, "task json omits empty session")
let queueJSON = WorkstreamsAPIResponse.queue("wq-1", name: "Q", workstreamId: "WS-1",
                                             state: "active", taskIds: ["wt-1"])
eq(queueJSON["id"] as? String, "wq-1", "queue json id")
eq(queueJSON["taskIds"] as? [String], ["wt-1"], "queue json taskIds")

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
eq(WorkstreamsAPIRouter.status(for: ["ok": false, "error": "evidence-missing"]), 409, "evidence-missing -> 409")
eq(WorkstreamsAPIRouter.status(for: ["ok": false, "error": "stage-changed"]), 409, "stage-changed -> 409")
eq(WorkstreamsAPIRouter.status(for: ["ok": false, "error": "something-new"]), 400, "unknown error code -> 400")

section("WorkstreamError alignment")
let cases: [WorkstreamError] = [
    .noWorkspace, .unknownWorkstream("WS-1"), .missingId, .missingTitle, .missingStage,
    .invalidStage("x"), .invalidQueue("x"), .malformedFrontmatter("x"),
    .missingField("f"), .writeFailed("x"),
    .evidenceMissing(["a", "b"]), .stageChanged("planning", "design"), .missingReason,
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
                          queues: ["q-1"],
                          delivery: DeliveryInfo(pr: 42, url: "https://example/pull/42", outcome: "merged"),
                          created: "2026-10-06", updated: "2026-10-07", path: "/p/WS-000001.md", body: "# body")
let cardJSON = WorkstreamsAPIResponse.card(card)
eq(cardJSON["id"] as? String, "WS-000001", "card id in JSON")
eq(cardJSON["stage"] as? String, "design", "card stage as raw value")
eq(cardJSON["requirement"] as? String, "REQ-000001", "card requirement in JSON")
eq(cardJSON["regression"] as? String, "REG-001", "card regression in JSON")
eq((cardJSON["covered"] as? [String: Any])?["base"] as? String, "blob-a", "covered base in JSON")
eq((cardJSON["covered"] as? [String: Any])?["paths"] as? [String], ["a.swift"], "covered paths in JSON")
eq(cardJSON["queues"] as? [String], ["q-1"], "card queues as an id list in JSON")
eq((cardJSON["delivery"] as? [String: Any])?["pr"] as? Int, 42, "delivery pr in JSON")
eq((cardJSON["delivery"] as? [String: Any])?["outcome"] as? String, "merged", "delivery outcome in JSON")
eq(cardJSON["body"] as? String, "# body", "card body in JSON")
let cardBound = WorkstreamsAPIResponse.card(card, session: "s-7")
eq(cardBound["session"] as? String, "s-7", "card carries the bound session")
let cardNoBound = WorkstreamsAPIResponse.card(card, session: "   ")
eq(cardNoBound["session"] == nil, true, "blank session stays absent from the card")

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
let snapBound = WorkstreamsAPIResponse.snapshot(snapshot, sessions: ["WS-000001": "s-9"])
let boundCardJSON = (snapBound["workstreams"] as? [[String: Any]])?.first
eq(boundCardJSON?["session"] as? String, "s-9", "snapshot attaches the session binding")

section("focus channel")
// A write can ask the panel to light up and highlight the card it just wrote
// (focus:true). Default false: an ordinary agent write must not steal the panel.
// Dedicated fake: earlier sections leave the shared fake in a failure state.
let focusFake = FakeWorkstreamsAPI()
focusFake.stageResult = ["ok": true]
let focusOff = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/stage", json: ["id": "WS-000001", "stage": "design"]), delegate: focusFake)
eq(focusOff?.status, 200, "write without focus still 200")
eq(focusFake.focusCalls.count, 0, "focus absent -> no focus call")
let focusFalse = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/stage", json: ["id": "WS-000001", "stage": "design", "focus": false]), delegate: focusFake)
eq(focusFalse?.status, 200, "focus:false write 200")
eq(focusFake.focusCalls.count, 0, "focus:false -> no focus call")
let focusWrite = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/stage", json: ["id": " WS-000001 ", "stage": "design", "focus": true, "workspace": "~/repo/"]), delegate: focusFake)
eq(focusWrite?.status, 200, "focus:true write 200")
eq(focusFake.focusCalls.count, 1, "focus:true -> one focus call")
eq(focusFake.focusCalls.last?.id, "WS-000001", "focus highlights the written workstream id")
eq(focusFake.focusCalls.last?.workspace?.hasSuffix("/repo"), true, "focus carries the normalized workspace")
// A string/number flag is accepted on the query side (reads light the panel only).
focusFake.focusCalls.removeAll()
let focusList = WorkstreamsAPIRouter.route(HTTPRequest(method: "GET", path: "/api/workstreams/list", query: ["workspace": "/tmp/ws", "focus": "1"]), delegate: focusFake)
eq(focusList?.status, 200, "list?focus=1 200")
eq(focusFake.focusCalls.count, 1, "query focus -> one focus call")
eq(focusFake.focusCalls.last?.id == nil, true, "plain list focus carries no workstream id")
eq(focusFake.focusCalls.last?.workspace, "/tmp/ws", "read focus carries the query workspace")
// Reverse lookup is the one read route that names a card: bound returns the first
// bound workstream, so focus:true on it highlights that card (switch matrix 对话 → 面板).
focusFake.focusCalls.removeAll()
focusFake.boundResult = ["ok": true, "session": "s-1",
                         "workstreams": [["id": "WS-000001"]],
                         "workstream": ["id": "WS-000001"]]
let focusBound = WorkstreamsAPIRouter.route(HTTPRequest(method: "GET", path: "/api/workstreams/bound",
    query: ["session": "s-1", "focus": "true"]), delegate: focusFake)
eq(focusBound?.status, 200, "bound?focus=true 200")
eq(focusFake.focusCalls.count, 1, "bound focus -> one focus call")
eq(focusFake.focusCalls.last?.id, "WS-000001", "bound focus highlights the reverse-looked-up workstream")
// create has no request id: the fresh card id from the response is focused.
focusFake.focusCalls.removeAll()
focusFake.createResult = ["ok": true, "workstream": ["id": "WS-000042"]]
let focusCreate = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/create", json: ["title": "x", "focus": "true"]), delegate: focusFake)
eq(focusCreate?.status, 200, "create focus 200")
eq(focusFake.focusCalls.last?.id, "WS-000042", "create focus uses the created card id")
focusFake.focusCalls.removeAll()
// Validation failures and unknown endpoints never reach the focus channel.
let focusBad = WorkstreamsAPIRouter.route(HTTPRequest(method: "POST", path: "/api/workstreams/create", json: ["title": " ", "focus": true]), delegate: focusFake)
eq(focusBad?.status, 400, "invalid focus write -> 400")
eq(focusFake.focusCalls.count, 0, "a rejected write does not focus")
let focusUnknown = WorkstreamsAPIRouter.route(HTTPRequest(method: "GET", path: "/api/workstreams/nope", query: ["focus": "true"]), delegate: focusFake)
eq(focusUnknown?.status, 404, "unknown endpoint with focus -> 404")
eq(focusFake.focusCalls.count, 0, "unknown endpoint does not focus")
// focus on an unavailable panel is harmless (no delegate).
let focusNoDelegate = WorkstreamsAPIRouter.route(HTTPRequest(method: "GET", path: "/api/workstreams/list", query: ["focus": "true"]), delegate: nil)
eq(focusNoDelegate?.status, 503, "focus without delegate -> 503")

section("result")
print("workstreams api: " + String(checks - failures) + "/" + String(checks) + " passed")
if failures > 0 { exit(1) }
