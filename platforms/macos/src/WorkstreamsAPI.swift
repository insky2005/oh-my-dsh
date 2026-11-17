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
//  Focus channel: any route may carry `focus` (a body field on writes, a query
//  value on reads). On a handled request the panel lights up and, when the route
//  names / creates a workstream, highlights that card. `focus` defaults false so
//  an ordinary agent write never steals the panel.
//
//  Routes (see the queue task and docs/design/panels/workstream-panel-design.md):
//    GET  /api/workstreams/list     ?workspace=...
//    GET  /api/workstreams/bound    ?session=$DSH_SESSION_ID   (reverse lookup)
//    POST /api/workstreams/create   {workspace?, title, requirement?, stage?, body?, session?}
//    POST /api/workstreams/update   {workspace?, id, title?|requirement?|body?, session?}
//    POST /api/workstreams/stage    {workspace?, id, stage, session?}
//    POST /api/workstreams/plan     {workspace?, id, heading?, text, session?}
//    POST /api/workstreams/queues   {workspace?, id, queues:["q-1"], session?}
//    POST /api/workstreams/task/create  {workspace?, id, stage?, titles?[]|body?, session?}
//    GET  /api/workstreams/task/list    ?workspace=...
//    POST /api/workstreams/queue/start  {workspace?, id, stage?, session?}
//    POST /api/workstreams/queue/pause  {workspace?, id, session?}
//    POST /api/workstreams/covered  {workspace?, id, covered:{paths,base,head}|null, session?}
//    POST /api/workstreams/delivery {workspace?, id, delivery:{pr,url,state,merged,abandoned}|null, session?}
//    POST /api/workstreams/deliver  {workspace?, id, session?}   (initiate delivery)
//
//  covered / delivery are the two FACT writes the store design reserves for the
//  panel (store design §3.2 / §5): covered is the point record (paths + immutable
//  base/head anchors); delivery holds the pr / url facts. delivery.outcome is a
//  DERIVED cache (PR status -> outcome) and is explicitly refused here.
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
    /// The workstream's execution queue ids (0..1; design A9 / D16).
    var queues: [String]
    var session: String?
}

struct WorkstreamsStageConfirmRequest: Equatable {
    var workspace: String?
    var id: String
    var stage: WorkstreamStage?
    var note: String?
    var session: String?
}

struct WorkstreamsStageRejectRequest: Equatable {
    var workspace: String?
    var id: String
    var reason: String
    var target: WorkstreamStage?
    var session: String?
}

/// Create one or more waiting-state tasks for a workstream stage. The panel turns
/// each title into a full WorkstreamHandoff prompt body (stage default action).
/// `stage` nil = the card current stage (the delegate resolves it); either
/// `titles` (non-empty) or `body` (non-blank) must be present.
struct WorkstreamsTaskCreateRequest: Equatable {
    var workspace: String?
    var id: String
    var stage: WorkstreamStage?
    var titles: [String]
    var body: String?
    var session: String?
}

/// Start a workstream queue. `stage` nil = item-level (run the whole queue FIFO);
/// a stage = stage-level (run only that stage tasks, design A3 / D18).
struct WorkstreamsQueueStartRequest: Equatable {
    var workspace: String?
    var id: String
    var stage: WorkstreamStage?
    var session: String?
}

/// Pause a workstream queue.
struct WorkstreamsQueuePauseRequest: Equatable {
    var workspace: String?
    var id: String
    var session: String?
}

/// Record the acceptance point record (store design 3.2). Only facts: the changed
/// paths anchored to immutable content ids (base/head). A nil covered clears it.
struct WorkstreamsCoveredRequest: Equatable {
    var workspace: String?
    var id: String
    var covered: CoveredRecord?
    var session: String?
}

/// Record the delivery block (store design 5). Only pr / url are facts; the
/// outcome is a derived cache and is refused by the router. state / merged /
/// abandoned are the PR observations the delegate turns into that cache.
struct WorkstreamsDeliveryRequest: Equatable {
    var workspace: String?
    var id: String
    var pr: Int?
    var url: String?
    var state: String?
    var merged: Bool
    var abandoned: Bool
    var session: String?
}

/// 发起交付 (the panel「交付」button's equivalent, design A10): run the git /
/// GitHub / token admission checks, enqueue the delivery prompt as a
/// last-stage task (delivery is an operation, A17). A refusal carries a
/// stable WSDeliveryBlocker code as `error` with its reason as `message`.
struct WorkstreamsDeliverRequest: Equatable {
    var workspace: String?
    var id: String
    var session: String?
}

/// Read the optional session field from any write body (trimmed, nil when empty).
func workstreamsSession(_ body: [String: Any]) -> String? {
    wsNonEmpty(body["session"] as? String)
}

/// The focus channel flag, read from a write body (`focus`) or a read query
/// (`?focus=`). A Bool, a number, or the strings true/1/yes/on count; anything
/// else is false. Default false keeps an agent write from stealing the panel
/// unless it explicitly asks (`focus:true`).
func workstreamsFocusFlag(_ raw: Any?) -> Bool {
    if let flag = raw as? Bool { return flag }
    if let number = raw as? NSNumber { return number.boolValue }
    if let text = raw as? String {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }
    return false
}

// MARK: - Delegate

/// Implemented by the Workstreams panel controller (wired through BrowserAPIBridge,
/// always called on the main thread — same rule as the tasks / requirements panels).
protocol WorkstreamsAPIDelegate: AnyObject {
    func apiWorkstreamsList(workspace: String?) -> [String: Any]
    /// Reverse lookup: the workstream(s) bound to a dsh session (design §6).
    func apiWorkstreamsBound(session: String) -> [String: Any]
    func apiWorkstreamsCreate(_ request: WorkstreamsCreateRequest) -> [String: Any]
    func apiWorkstreamsUpdate(_ request: WorkstreamsUpdateRequest) -> [String: Any]
    func apiWorkstreamsStage(_ request: WorkstreamsStageRequest) -> [String: Any]
    func apiWorkstreamsPlan(_ request: WorkstreamsPlanRequest) -> [String: Any]
    func apiWorkstreamsQueues(_ request: WorkstreamsQueuesRequest) -> [String: Any]
    func apiWorkstreamsStageConfirm(_ request: WorkstreamsStageConfirmRequest) -> [String: Any]
    func apiWorkstreamsStageReject(_ request: WorkstreamsStageRejectRequest) -> [String: Any]
    /// Create waiting-state stage tasks (design A14).
    func apiWorkstreamsTaskCreate(_ request: WorkstreamsTaskCreateRequest) -> [String: Any]
    /// List a workspace queue board tasks (design A14 / A13).
    func apiWorkstreamsTaskList(workspace: String?) -> [String: Any]
    /// Start a workstream queue, item-level or stage-level (design A3 / A14).
    func apiWorkstreamsQueueStart(_ request: WorkstreamsQueueStartRequest) -> [String: Any]
    /// Pause a workstream queue.
    func apiWorkstreamsQueuePause(_ request: WorkstreamsQueuePauseRequest) -> [String: Any]
    /// Record the acceptance point record (facts only, store design 3.2).
    func apiWorkstreamsCovered(_ request: WorkstreamsCoveredRequest) -> [String: Any]
    /// Record the delivery facts; the derived outcome cache is computed here, not
    /// accepted from the caller (store design 5).
    func apiWorkstreamsDelivery(_ request: WorkstreamsDeliveryRequest) -> [String: Any]
    /// 发起交付: the panel button and this route go through one shared path
    /// (WorkstreamsPanel.initiateDelivery) so the two can never drift. Failures
    /// carry a WSDeliveryBlocker code (+ no-queue / start-failed) as `error`.
    func apiWorkstreamsDeliver(_ request: WorkstreamsDeliverRequest) -> [String: Any]
    /// The focus channel: bring the workstreams panel forward and, when an id is
    /// given, highlight + scroll to that card. The router calls it for any route
    /// carrying focus. A default no-op keeps headless fakes simple.
    func apiWorkstreamsFocus(workspace: String?, id: String?)
}

extension WorkstreamsAPIDelegate {
    func apiWorkstreamsFocus(workspace: String?, id: String?) {}
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

    /// One card as JSON. The session argument is the machine-scoped binding kept
    /// in local.json (design §6); the panel attaches it, it is never read from the
    /// card itself.
    static func card(_ card: WorkstreamCard, session: String? = nil) -> [String: Any] {
        var out: [String: Any] = ["id": card.id, "title": card.title, "stage": card.stage.rawValue]
        if let session = wsNonEmpty(session) { out["session"] = session }
        if let r = card.requirement { out["requirement"] = r }
        if let c = card.covered { out["covered"] = covered(c) }
        if let r = card.regression { out["regression"] = r }
        if !card.queues.isEmpty { out["queues"] = card.queues }
        if let d = card.delivery { out["delivery"] = delivery(d) }
        if let c = card.created { out["created"] = c }
        if let u = card.updated { out["updated"] = u }
        out["body"] = card.body
        return out
    }

    /// The sessions argument is the WS-id -> sessionId binding map (local.json);
    /// every card gets its bound session attached when present (design §6).
    static func snapshot(_ snap: WorkstreamsSnapshot,
                         sessions: [String: String] = [:]) -> [String: Any] {
        var out: [String: Any] = [
            "ok": true,
            "workspace": snap.workspace,
            "dshExists": snap.dshExists,
            "workstreams": snap.workstreams.map { card($0, session: wsNonEmpty(sessions[$0.id])) },
        ]
        if !snap.unparsed.isEmpty { out["unparsed"] = snap.unparsed }
        return out
    }

    /// One tertiary (task) card as JSON. Kept primitive so this file compiles
    /// headlessly without the queue engine (the panel maps WSTaskItem here).
    static func task(_ id: String, title: String, state: String,
                     workstreamId: String? = nil, stage: WorkstreamStage? = nil,
                     sessionId: String? = nil, error: String? = nil,
                     report: String? = nil) -> [String: Any] {
        var out: [String: Any] = ["id": id, "title": title, "state": state]
        if let workstreamId = workstreamId, !workstreamId.isEmpty { out["workstreamId"] = workstreamId }
        if let stage = stage { out["stage"] = stage.rawValue }
        if let sessionId = sessionId, !sessionId.isEmpty { out["session"] = sessionId }
        if let error = error, !error.isEmpty { out["error"] = error }
        if let report = report, !report.isEmpty { out["report"] = report }
        return out
    }

    /// One execution queue as JSON.
    static func queue(_ id: String, name: String, workstreamId: String,
                      state: String, taskIds: [String]) -> [String: Any] {
        ["id": id, "name": name, "workstreamId": workstreamId,
         "state": state, "taskIds": taskIds]
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

    /// Parse the queues write body into queue ids. Canonical form is a list of
    /// strings (["q-1"]); the legacy [{id, stage}] mapping is accepted by taking
    /// each entry's id and dropping its stage (design A9 / D16 read-compat).
    /// A workstream has at most one queue.
    static func parseQueues(_ raw: Any?) -> (queues: [String], error: (code: String, message: String)?) {
        guard let array = raw as? [Any] else {
            return ([], ("invalid-queue", "queues must be a list of queue ids"))
        }
        var out: [String] = []
        for entry in array {
            let id: String?
            if let text = entry as? String {
                id = wsNonEmpty(text)
            } else if let object = entry as? [String: Any] {
                id = wsNonEmpty(object["id"] as? String)
            } else {
                id = nil
            }
            guard let value = id else {
                return ([], ("invalid-queue", "queue entry is missing id"))
            }
            out.append(value)
        }
        if out.count > 1 { return ([], ("invalid-queue", "at most one queue per workstream")) }
        return (out, nil)
    }

    /// Parse the optional task-create titles into a list of non-blank strings.
    /// A present-but-not-a-list value is a hard error; absent / blank entries are
    /// simply dropped (the body fallback may still satisfy the request).
    static func parseTaskTitles(_ raw: Any?) -> (titles: [String], error: (code: String, message: String)?) {
        guard let raw = raw else { return ([], nil) }
        guard let array = raw as? [Any] else {
            return ([], ("invalid-titles", "titles must be a list of strings"))
        }
        var out: [String] = []
        for entry in array {
            guard let text = entry as? String else {
                return ([], ("invalid-titles", "titles entries must be strings"))
            }
            if let trimmed = wsNonEmpty(text) { out.append(trimmed) }
        }
        return (out, nil)
    }

    /// A parsed delivery write. Only pr / url are facts; state / merged /
    /// abandoned are the PR observations the delegate turns into the derived
    /// outcome cache. outcome is never a field here (it is refused earlier).
    struct WSDeliveryParse {
        var pr: Int? = nil
        var url: String? = nil
        var state: String? = nil
        var merged: Bool = false
        var abandoned: Bool = false
        var error: (code: String, message: String)? = nil
    }

    /// Parse the covered write value. Canonical form is an object with a non-empty
    /// paths list plus optional immutable base / head anchors; an explicit null
    /// clears the record. A present-but-wrong shape is a hard error.
    static func parseCovered(_ raw: Any?) -> (covered: CoveredRecord?, error: (code: String, message: String)?) {
        if raw == nil || raw is NSNull { return (nil, nil) }
        guard let object = raw as? [String: Any] else {
            return (nil, ("invalid-covered", "covered must be an object with a paths list"))
        }
        guard let pathsRaw = object["paths"] as? [Any] else {
            return (nil, ("missing-covered-paths", "covered.paths must be a list of changed paths"))
        }
        var paths: [String] = []
        for entry in pathsRaw {
            guard let text = entry as? String, let trimmed = wsNonEmpty(text) else {
                return (nil, ("invalid-covered", "covered.paths entries must be non-blank strings"))
            }
            paths.append(trimmed)
        }
        guard !paths.isEmpty else {
            return (nil, ("missing-covered-paths", "covered.paths must not be empty"))
        }
        return (CoveredRecord(paths: paths,
                              base: wsNonEmpty(object["base"] as? String),
                              head: wsNonEmpty(object["head"] as? String)), nil)
    }

    /// Parse the delivery write value. An outcome inside the block is refused: it
    /// is a derived cache (PR status -> outcome), not a caller-written field.
    static func parseDelivery(_ raw: Any?) -> WSDeliveryParse {
        if raw == nil || raw is NSNull { return WSDeliveryParse() }
        guard let object = raw as? [String: Any] else {
            return WSDeliveryParse(error: ("invalid-delivery", "delivery must be an object with pr / url facts"))
        }
        if object.keys.contains("outcome") {
            return WSDeliveryParse(error: ("outcome-derived",
                "outcome is a derived cache (PR status -> outcome); write only pr / url facts"))
        }
        var parsed = WSDeliveryParse()
        if let prRaw = object["pr"], !(prRaw is NSNull) {
            if let n = prRaw as? Int {
                parsed.pr = n
            } else if let s = prRaw as? String, let n = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                parsed.pr = n
            } else {
                return WSDeliveryParse(error: ("invalid-delivery", "delivery.pr must be an integer PR number"))
            }
        }
        parsed.url = wsNonEmpty(object["url"] as? String)
        parsed.state = wsNonEmpty(object["state"] as? String)
        parsed.merged = (object["merged"] as? Bool) ?? false
        parsed.abandoned = (object["abandoned"] as? Bool) ?? false
        return parsed
    }

    /// Returns a response when the request belongs to this panel, nil otherwise
    /// (so BrowserAPIRouter can fall through to the other panels / 404).
    ///
    /// Wraps `dispatch` with the focus channel: a request carrying `focus` (a body
    /// field on writes, a query value on reads) asks the panel to light up and,
    /// when the route names a workstream, highlight it. `focus:true` on a write
    /// therefore performs the write AND brings the card into view.
    static func route(_ request: HTTPRequest, delegate: WorkstreamsAPIDelegate?) -> HTTPResponse? {
        guard request.path.hasPrefix(prefix) else { return nil }
        let response = dispatch(request, delegate: delegate)
        // Only a handled (200) request focuses: validation failures and unknown
        // endpoints never yank the panel forward.
        guard let response = response, response.status == 200 else { return response }
        let body = request.jsonBody()
        let focused = workstreamsFocusFlag(body?["focus"]) || workstreamsFocusFlag(request.query["focus"])
        if focused, let delegate = delegate {
            delegate.apiWorkstreamsFocus(workspace: focusWorkspace(request: request, body: body),
                                         id: focusID(body: body, response: response))
        }
        return response
    }

    /// The workspace a focus request refers to (body first, then query).
    static func focusWorkspace(request: HTTPRequest, body: [String: Any]?) -> String? {
        WorkstreamsAPIWorkspace.normalize(body?["workspace"] as? String)
            ?? WorkstreamsAPIWorkspace.normalize(request.query["workspace"])
    }

    /// The workstream a focus request should highlight: the route's id, or the
    /// freshly created card's id (create has no request id).
    static func focusID(body: [String: Any]?, response: HTTPResponse) -> String? {
        if let id = wsNonEmpty(body?["id"] as? String) { return id }
        // create has no request id: take the fresh card id from the JSON body.
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let created = object["workstream"] as? [String: Any] else { return nil }
        return wsNonEmpty(created["id"] as? String)
    }

    /// The routing switch itself (see workstreams-panel-design.md for every
    /// route). Kept separate so the focus channel wraps it in one place.
    static func dispatch(_ request: HTTPRequest, delegate: WorkstreamsAPIDelegate?) -> HTTPResponse? {
        guard request.path.hasPrefix(prefix) else { return nil }
        switch (request.method, request.path) {

        case ("GET", "/api/workstreams/list"):
            guard let delegate = delegate else { return unavailable() }
            let workspace = WorkstreamsAPIWorkspace.normalize(request.query["workspace"])
            let result = delegate.apiWorkstreamsList(workspace: workspace)
            return .json(status(for: result), result)

        case ("GET", "/api/workstreams/bound"):
            guard let delegate = delegate else { return unavailable() }
            guard let session = wsNonEmpty(request.query["session"]) else {
                return missingSession()
            }
            let bound = delegate.apiWorkstreamsBound(session: session)
            return .json(status(for: bound), bound)

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
                                   "hint": "expected {\"id\": \"WS-000001\", \"queues\": [\"q-1\"]}"])
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

        case ("POST", "/api/workstreams/stage/confirm"):
            guard let body = request.jsonBody() else { return missingBody() }
            guard let id = wsNonEmpty(body["id"] as? String) else { return missingId() }
            var expected: WorkstreamStage? = nil
            if let raw = wsNonEmpty(body["stage"] as? String) {
                guard let parsed = WorkstreamStage.parse(raw) else { return invalidStage(raw) }
                expected = parsed
            }
            guard let delegate = delegate else { return unavailable() }
            let confirm = WorkstreamsStageConfirmRequest(workspace: WorkstreamsAPIWorkspace.normalize(body["workspace"] as? String),
                                                         id: id, stage: expected,
                                                         note: wsNonEmpty(body["note"] as? String),
                                                         session: workstreamsSession(body))
            let confirmed = delegate.apiWorkstreamsStageConfirm(confirm)
            return .json(status(for: confirmed), confirmed)

        case ("POST", "/api/workstreams/stage/reject"):
            guard let body = request.jsonBody() else { return missingBody() }
            guard let id = wsNonEmpty(body["id"] as? String) else { return missingId() }
            let reason = ((body["reason"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reason.isEmpty else {
                return .json(400, ["ok": false, "error": "missing-reason",
                                   "hint": "expected {\"id\": \"WS-000001\", \"reason\": \"...\"}"])
            }
            var target: WorkstreamStage? = nil
            if let raw = wsNonEmpty(body["target"] as? String) {
                guard let parsed = WorkstreamStage.parse(raw) else { return invalidStage(raw) }
                target = parsed
            }
            guard let delegate = delegate else { return unavailable() }
            let reject = WorkstreamsStageRejectRequest(workspace: WorkstreamsAPIWorkspace.normalize(body["workspace"] as? String),
                                                       id: id, reason: reason, target: target,
                                                       session: workstreamsSession(body))
            let rejected = delegate.apiWorkstreamsStageReject(reject)
            return .json(status(for: rejected), rejected)

        case ("POST", "/api/workstreams/task/create"):
            guard let body = request.jsonBody() else { return missingBody() }
            guard let id = wsNonEmpty(body["id"] as? String) else { return missingId() }
            var taskStage: WorkstreamStage? = nil
            if let raw = wsNonEmpty(body["stage"] as? String) {
                guard let parsed = WorkstreamStage.parse(raw) else { return invalidStage(raw) }
                taskStage = parsed
            } else if body.keys.contains("stage") {
                return missingStage()
            }
            let parsedTitles = parseTaskTitles(body["titles"])
            if let error = parsedTitles.error {
                return .json(400, ["ok": false, "error": error.code, "message": error.message])
            }
            let taskBody = wsNonEmpty(body["body"] as? String)
            guard !parsedTitles.titles.isEmpty || taskBody != nil else {
                return .json(400, ["ok": false, "error": "missing-titles",
                                   "hint": "expected {\"id\": \"WS-000001\", \"titles\": [\"...\"]} or {\"body\": \"...\"}"])
            }
            guard let delegate = delegate else { return unavailable() }
            let createTask = WorkstreamsTaskCreateRequest(
                workspace: WorkstreamsAPIWorkspace.normalize(body["workspace"] as? String),
                id: id, stage: taskStage, titles: parsedTitles.titles, body: taskBody,
                session: workstreamsSession(body))
            let created = delegate.apiWorkstreamsTaskCreate(createTask)
            return .json(status(for: created), created)

        case ("GET", "/api/workstreams/task/list"):
            guard let delegate = delegate else { return unavailable() }
            let workspace = WorkstreamsAPIWorkspace.normalize(request.query["workspace"])
            let listed = delegate.apiWorkstreamsTaskList(workspace: workspace)
            return .json(status(for: listed), listed)

        case ("POST", "/api/workstreams/queue/start"):
            guard let body = request.jsonBody() else { return missingBody() }
            guard let id = wsNonEmpty(body["id"] as? String) else { return missingId() }
            var startStage: WorkstreamStage? = nil
            if let raw = wsNonEmpty(body["stage"] as? String) {
                guard let parsed = WorkstreamStage.parse(raw) else { return invalidStage(raw) }
                startStage = parsed
            } else if body.keys.contains("stage") {
                return missingStage()
            }
            guard let delegate = delegate else { return unavailable() }
            let start = WorkstreamsQueueStartRequest(
                workspace: WorkstreamsAPIWorkspace.normalize(body["workspace"] as? String),
                id: id, stage: startStage, session: workstreamsSession(body))
            let started = delegate.apiWorkstreamsQueueStart(start)
            return .json(status(for: started), started)

        case ("POST", "/api/workstreams/queue/pause"):
            guard let body = request.jsonBody() else { return missingBody() }
            guard let id = wsNonEmpty(body["id"] as? String) else { return missingId() }
            guard let delegate = delegate else { return unavailable() }
            let pause = WorkstreamsQueuePauseRequest(
                workspace: WorkstreamsAPIWorkspace.normalize(body["workspace"] as? String),
                id: id, session: workstreamsSession(body))
            let paused = delegate.apiWorkstreamsQueuePause(pause)
            return .json(status(for: paused), paused)

        case ("POST", "/api/workstreams/covered"):
            guard let body = request.jsonBody() else { return missingBody() }
            guard let id = wsNonEmpty(body["id"] as? String) else { return missingId() }
            guard body.keys.contains("covered") else {
                return .json(400, ["ok": false, "error": "missing-covered",
                                   "hint": "expected {\"id\": \"WS-000001\", \"covered\": {\"paths\": [\"docs/x.md\"], \"base\": \"blob-a\", \"head\": \"tree-b\"}}"])
            }
            let parsed = parseCovered(body["covered"])
            if let error = parsed.error {
                return .json(400, ["ok": false, "error": error.code, "message": error.message])
            }
            guard let delegate = delegate else { return unavailable() }
            let covered = WorkstreamsCoveredRequest(
                workspace: WorkstreamsAPIWorkspace.normalize(body["workspace"] as? String),
                id: id, covered: parsed.covered, session: workstreamsSession(body))
            let coveredResult = delegate.apiWorkstreamsCovered(covered)
            return .json(status(for: coveredResult), coveredResult)

        case ("POST", "/api/workstreams/delivery"):
            guard let body = request.jsonBody() else { return missingBody() }
            guard let id = wsNonEmpty(body["id"] as? String) else { return missingId() }
            guard body.keys.contains("delivery") else {
                return .json(400, ["ok": false, "error": "missing-delivery",
                                   "hint": "expected {\"id\": \"WS-000001\", \"delivery\": {\"pr\": 42, \"url\": \"https://github.com/o/r/pull/42\"}}"])
            }
            // A top-level outcome is just as illegal as one inside the block.
            if body.keys.contains("outcome") {
                return .json(400, ["ok": false, "error": "outcome-derived",
                                   "message": "outcome is a derived cache; write only pr / url facts"])
            }
            let facts = parseDelivery(body["delivery"])
            if let error = facts.error {
                return .json(400, ["ok": false, "error": error.code, "message": error.message])
            }
            guard let delegate = delegate else { return unavailable() }
            let delivery = WorkstreamsDeliveryRequest(
                workspace: WorkstreamsAPIWorkspace.normalize(body["workspace"] as? String),
                id: id, pr: facts.pr, url: facts.url, state: facts.state,
                merged: facts.merged, abandoned: facts.abandoned,
                session: workstreamsSession(body))
            let deliveryResult = delegate.apiWorkstreamsDelivery(delivery)
            return .json(status(for: deliveryResult), deliveryResult)

        case ("POST", "/api/workstreams/deliver"):
            // 发起交付: the git / GitHub / token admission checks plus the
            // enqueue-and-start the panel「交付」button performs — same path.
            guard let body = request.jsonBody() else { return missingBody() }
            guard let id = wsNonEmpty(body["id"] as? String) else { return missingId() }
            guard let delegate = delegate else { return unavailable() }
            let deliver = WorkstreamsDeliverRequest(
                workspace: WorkstreamsAPIWorkspace.normalize(body["workspace"] as? String),
                id: id, session: workstreamsSession(body))
            let delivered = delegate.apiWorkstreamsDeliver(deliver)
            return .json(status(for: delivered), delivered)

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
        case "no-queue": return 404
        case "panel-unavailable": return 503
        case "write-failed": return 500
        case "evidence-missing": return 409
        case "stage-changed": return 409
        // 发起交付: a workstream that is not in the delivery stage is a state
        // conflict; a failed start is a server-side failure. The other
        // WSDeliveryBlocker reasons are bad-state 400s (default).
        case "not-delivery-stage": return 409
        case "start-failed": return 500
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

    static func missingSession() -> HTTPResponse {
        .json(400, ["ok": false, "error": "missing-session",
                    "hint": "expected ?session=$DSH_SESSION_ID"])
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
