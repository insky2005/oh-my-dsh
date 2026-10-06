//
//  WorkstreamsAPI.swift — the Workstreams panel's localhost REST API.
//
//  Shares the shell HTTP service (BrowserAPIServer, 127.0.0.1) with the browser,
//  tasks and requirements panels, split by prefix: /api/workstreams/* belongs to
//  this panel. This file is PURE MODEL (routing + request DTOs + response shapes):
//  no AppKit, no disk, no reference to the task panel. Headless tests compile it
//  together with WorkstreamsCore.swift and a fake delegate
//  (tests/workstreams-panel/api-tests.swift).
//
//  Error codes / status mapping deliberately mirror /api/requirements/* (and the
//  WorkstreamError.status the model layer already defines).
//
//  Routes (see the queue task and docs/design/panels/workstream-panel-design.md):
//    GET  /api/workstreams/list     ?workspace=...
//    POST /api/workstreams/create   {workspace?, title, requirement?, stage?, body?, session?}
//    POST /api/workstreams/update   {workspace?, id, title?|requirement?|body?, session?}
//    POST /api/workstreams/stage    {workspace?, id, stage, session?}
//    POST /api/workstreams/plan     {workspace?, id, heading?, text, session?}
//    POST /api/workstreams/queues   {workspace?, id, queues:[{id, stage?}], session?}
//

import Foundation

// MARK: - Request DTOs

struct WorkstreamsCreateRequest: Equatable {
    var workspace: String?
    var title: String
    /// 0..1 authoritative forward pointer to the owning requirement (REQ-...).
    var requirement: String?
    /// Defaults to .planning when the body omits it.
    var stage: WorkstreamStage
    var body: String?
    /// The dsh session the write came from; remembered for the runtime binding
    /// (.dsh/workstreams/local.json) once the panel persists it.
    var session: String?
}

struct WorkstreamsUpdateRequest: Equatable {
    var workspace: String?
    var id: String
    /// nil = leave unchanged; a non-nil value (even "") is the new value.
    var title: String?
    /// nil = leave unchanged; "" clears the requirement pointer.
    var requirement: String?
    /// nil = leave unchanged; "" clears the body.
    var body: String?
    var session: String?
}

struct WorkstreamsStageRequest: Equatable {
    var workspace: String?
    var id: String
    var stage: WorkstreamStage
    var session: String?
}

/// Replace one level-2 body section (the planning / design prose). heading keeps
/// its "## " prefix so WorkstreamsCore.replaceSection can find it.
struct WorkstreamsPlanRequest: Equatable {
    var workspace: String?
    var id: String
    var heading: String
    var text: String
    var session: String?
}

struct WorkstreamsQueuesRequest: Equatable {
    var workspace: String?
    var id: String
    var queues: [WorkstreamQueue]
    var session: String?
}

/// Read the optional session field from any write body (trimmed, nil when empty).
func workstreamsSession(_ body: [String: Any]) -> String? {
    wsNonEmpty(body["session"] as? String)
}

// MARK: - Delegate

/// Implemented by the Workstreams panel controller (wired through BrowserAPIBridge,
/// always called on the main thread — same rule as the tasks / requirements panels).
protocol WorkstreamsAPIDelegate: AnyObject {
    func apiWorkstreamsList(workspace: String?) -> [String: Any]
    func apiWorkstreamsCreate(_ request: WorkstreamsCreateRequest) -> [String: Any]
    func apiWorkstreamsUpdate(_ request: WorkstreamsUpdateRequest) -> [String: Any]
    func apiWorkstreamsStage(_ request: WorkstreamsStageRequest) -> [String: Any]
    func apiWorkstreamsPlan(_ request: WorkstreamsPlanRequest) -> [String: Any]
    func apiWorkstreamsQueues(_ request: WorkstreamsQueuesRequest) -> [String: Any]
}

// MARK: - Workspace normalization

/// Same rules as the tasks / requirements panels (trim, expand ~, standardize).
/// Duplicated on purpose: the API test compiles this file without the other models.
/// Trim and nil-if-empty. Kept local (rather than reusing RequirementsCore's
/// `nilIfEmpty`) so this file compiles headlessly with WorkstreamsCore alone.
func wsNonEmpty(_ raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    return trimmed
}

enum WorkstreamsAPIWorkspace {
    static func normalize(_ path: String?) -> String? {
        guard let raw = path?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }
}

// MARK: - Response shapes (pure, shared with the panel)

enum WorkstreamsAPIResponse {

    static func queue(_ q: WorkstreamQueue) -> [String: Any] {
        var out: [String: Any] = ["id": q.id]
        if let stage = q.stage { out["stage"] = stage.rawValue }
        return out
    }

    static func covered(_ c: CoveredRecord) -> [String: Any] {
        var out: [String: Any] = ["paths": c.paths]
        if let base = c.base { out["base"] = base }
        if let head = c.head { out["head"] = head }
        return out
    }

    static func delivery(_ d: DeliveryInfo) -> [String: Any] {
        var out: [String: Any] = [:]
        if let pr = d.pr { out["pr"] = pr }
        if let url = d.url { out["url"] = url }
        if let outcome = d.outcome { out["outcome"] = outcome }
        return out
    }

    static func card(_ card: WorkstreamCard) -> [String: Any] {
        var out: [String: Any] = ["id": card.id, "title": card.title, "stage": card.stage.rawValue]
        if let r = card.requirement { out["requirement"] = r }
        if let c = card.covered { out["covered"] = covered(c) }
        if let r = card.regression { out["regression"] = r }
        if !card.queues.isEmpty { out["queues"] = card.queues.map(queue) }
        if let d = card.delivery { out["delivery"] = delivery(d) }
        if let c = card.created { out["created"] = c }
        if let u = card.updated { out["updated"] = u }
        out["body"] = card.body
        return out
    }

    static func snapshot(_ snap: WorkstreamsSnapshot) -> [String: Any] {
        var out: [String: Any] = [
            "ok": true,
            "workspace": snap.workspace,
            "dshExists": snap.dshExists,
            "workstreams": snap.workstreams.map(card),
        ]
        if !snap.unparsed.isEmpty { out["unparsed"] = snap.unparsed }
        return out
    }
}

// MARK: - Router

enum WorkstreamsAPIRouter {

    static let prefix = "/api/workstreams/"

    /// The heading the plan route writes when the caller omits one. Real cards use
    /// "## 规划" for the planning four-piece (planning-template-design §4).
    static let defaultPlanHeading = "## 规划"

    /// Normalize a plan heading: trimmed, empty -> default, and always carrying a
    /// markdown heading prefix so WorkstreamsCore.replaceSection can match it.
    static func planHeading(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultPlanHeading }
        return trimmed.hasPrefix("#") ? trimmed : "## " + trimmed
    }

    /// Parse [{id, stage?}] into the model type, validating ids and stages.
    /// Returns nil (plus a reason) so the caller can shape the error.
    static func parseQueues(_ raw: Any?) -> (queues: [WorkstreamQueue], error: (code: String, message: String)?) {
        guard let array = raw as? [[String: Any]] else {
            return ([], ("invalid-queue", "queues must be a list of {id, stage}"))
        }
        var out: [WorkstreamQueue] = []
        for entry in array {
            guard let id = wsNonEmpty(entry["id"] as? String) else {
                return ([], ("invalid-queue", "queue entry is missing id"))
            }
            var stage: WorkstreamStage?
            if let rawStage = entry["stage"] as? String,
               !(rawStage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                guard let parsed = WorkstreamStage.parse(rawStage) else {
                    return ([], ("invalid-stage", "unknown workstream stage: " + rawStage.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                stage = parsed
            }
            out.append(WorkstreamQueue(id: id, stage: stage))
        }
        return (out, nil)
    }

    /// Returns a response when the request belongs to this panel, nil otherwise
    /// (so BrowserAPIRouter can fall through to the other panels / 404).
    static func route(_ request: HTTPRequest, delegate: WorkstreamsAPIDelegate?) -> HTTPResponse? {
        guard request.path.hasPrefix(prefix) else { return nil }
        switch (request.method, request.path) {

        case ("GET", "/api/workstreams/list"):
            guard let delegate = delegate else { return unavailable() }
            let workspace = WorkstreamsAPIWorkspace.normalize(request.query["workspace"])
            let result = delegate.apiWorkstreamsList(workspace: workspace)
            return .json(status(for: result), result)

        case ("POST", "/api/workstreams/create"):
            guard let body = request.jsonBody() else { return missingBody() }
            let title = ((body["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                return .json(400, ["ok": false, "error": "missing-title",
                                   "hint": "expected {\"title\": \"...\"}"])
            }
            var stage: WorkstreamStage = .planning
            if body.keys.contains("stage") {
                let rawStage = ((body["stage"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawStage.isEmpty else { return missingStage() }
                guard let parsed = WorkstreamStage.parse(rawStage) else { return invalidStage(rawStage) }
                stage = parsed
            }
            guard let delegate = delegate else { return unavailable() }
            let req = WorkstreamsCreateRequest(workspace: WorkstreamsAPIWorkspace.normalize(body["workspace"] as? String),
                                               title: title,
                                               requirement: wsNonEmpty(body["requirement"] as? String),
                                               stage: stage,
                                               body: body["body"] as? String,
                                               session: workstreamsSession(body))
            let result = delegate.apiWorkstreamsCreate(req)
            return .json(status(for: result), result)

        case ("POST", "/api/workstreams/update"):
            guard let body = request.jsonBody() else { return missingBody() }
            guard let id = wsNonEmpty(body["id"] as? String) else {
                return missingId()
            }
            let hasTitle = body.keys.contains("title")
            let hasRequirement = body.keys.contains("requirement")
            let hasBody = body.keys.contains("body")
            guard hasTitle || hasRequirement || hasBody else {
                return .json(400, ["ok": false, "error": "no-fields",
                                   "hint": "expected at least one of title / requirement / body"])
            }
            var title: String?
            if hasTitle {
                let t = ((body["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return .json(400, ["ok": false, "error": "missing-title",
                                                           "hint": "title must not be blank"]) }
                title = t
            }
            guard let delegate = delegate else { return unavailable() }
            let update = WorkstreamsUpdateRequest(workspace: WorkstreamsAPIWorkspace.normalize(body["workspace"] as? String),
                                                  id: id,
                                                  title: title,
                                                  requirement: hasRequirement ? ((body["requirement"] as? String) ?? "") : nil,
                                                  body: hasBody ? ((body["body"] as? String) ?? "") : nil,
                                                  session: workstreamsSession(body))
            let result = delegate.apiWorkstreamsUpdate(update)
            return .json(status(for: result), result)

        case ("POST", "/api/workstreams/stage"):
            guard let body = request.jsonBody() else { return missingBody() }
            guard let id = wsNonEmpty(body["id"] as? String) else {
                return missingId()
            }
            let rawStage = ((body["stage"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawStage.isEmpty else { return missingStage() }
            guard let stage = WorkstreamStage.parse(rawStage) else { return invalidStage(rawStage) }
            guard let delegate = delegate else { return unavailable() }
            let req = WorkstreamsStageRequest(workspace: WorkstreamsAPIWorkspace.normalize(body["workspace"] as? String),
                                              id: id, stage: stage, session: workstreamsSession(body))
            let result = delegate.apiWorkstreamsStage(req)
            return .json(status(for: result), result)

        case ("POST", "/api/workstreams/plan"):
            guard let body = request.jsonBody() else { return missingBody() }
            guard let id = wsNonEmpty(body["id"] as? String) else {
                return missingId()
            }
            guard body.keys.contains("text"), let text = body["text"] as? String else {
                return .json(400, ["ok": false, "error": "missing-text",
                                   "hint": "expected {\"id\": \"WS-000001\", \"text\": \"...\"}"])
            }
            guard let delegate = delegate else { return unavailable() }
            let req = WorkstreamsPlanRequest(workspace: WorkstreamsAPIWorkspace.normalize(body["workspace"] as? String),
                                             id: id,
                                             heading: planHeading(body["heading"] as? String),
                                             text: text,
                                             session: workstreamsSession(body))
            let result = delegate.apiWorkstreamsPlan(req)
            return .json(status(for: result), result)

        case ("POST", "/api/workstreams/queues"):
            guard let body = request.jsonBody() else { return missingBody() }
            guard let id = wsNonEmpty(body["id"] as? String) else {
                return missingId()
            }
            guard body.keys.contains("queues") else {
                return .json(400, ["ok": false, "error": "missing-queues",
                                   "hint": "expected {\"id\": \"WS-000001\", \"queues\": [{\"id\": \"q-1\", \"stage\": \"planning\"}]}"])
            }
            let parsed = parseQueues(body["queues"])
            if let error = parsed.error {
                return .json(400, ["ok": false, "error": error.code, "message": error.message])
            }
            guard let delegate = delegate else { return unavailable() }
            let req = WorkstreamsQueuesRequest(workspace: WorkstreamsAPIWorkspace.normalize(body["workspace"] as? String),
                                               id: id, queues: parsed.queues, session: workstreamsSession(body))
            let result = delegate.apiWorkstreamsQueues(req)
            return .json(status(for: result), result)

        default:
            return .json(404, ["ok": false, "error": "not-found"])
        }
    }

    /// Map a delegate result onto an HTTP status (the delegate carries the error
    /// code). Mirrors RequirementsAPIRouter.status(for:) and WorkstreamError.status.
    static func status(for result: [String: Any]) -> Int {
        if (result["ok"] as? Bool) == true { return 200 }
        switch result["error"] as? String {
        case "unknown-workstream": return 404
        case "panel-unavailable": return 503
        case "write-failed": return 500
        default: return 400
        }
    }

    static func missingBody() -> HTTPResponse {
        .json(400, ["ok": false, "error": "missing-body",
                    "hint": "expected a JSON object"])
    }

    static func missingId() -> HTTPResponse {
        .json(400, ["ok": false, "error": "missing-id"])
    }

    static func missingStage() -> HTTPResponse {
        .json(400, ["ok": false, "error": "missing-stage"])
    }

    static func invalidStage(_ raw: String) -> HTTPResponse {
        .json(400, ["ok": false, "error": "invalid-stage",
                    "message": "unknown workstream stage: " + raw,
                    "hint": "one of " + WorkstreamStage.allCases.map { $0.rawValue }.joined(separator: " / ")])
    }

    static func unavailable() -> HTTPResponse {
        .json(503, ["ok": false, "error": "panel-unavailable",
                    "hint": "the workstreams panel is not ready"])
    }
}

// MARK: - Core error -> API result

extension WorkstreamError {
    /// The result dictionary the delegate returns for this error.
    var apiResult: [String: Any] {
        ["ok": false, "error": code, "message": message]
    }
}
