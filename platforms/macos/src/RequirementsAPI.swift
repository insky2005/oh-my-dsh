//
//  RequirementsAPI.swift — the requirements pool panel's localhost REST API.
//
//  Shares the shell HTTP service (BrowserAPIServer, 127.0.0.1) with the browser and
//  tasks panels, split by prefix: /api/requirements/* belongs to this panel. This
//  file is PURE MODEL (routing + request DTOs + response shapes): no AppKit, no disk.
//  Headless tests compile it together with RequirementsCore.swift and a fake delegate
//  (tests/requirements-panel/api-tests.swift).
//
//  Design: docs/design/panels/requirements-pool-panel-design.md (§4).
//

import Foundation

// MARK: - Request DTOs

struct RequirementsCreateRequest: Equatable {
    var workspace: String?
    var focus: Bool = true
    var title: String
    var body: String?
    var source: String?
    /// The capturing dsh session ($DSH_SESSION_ID); remembered as the card's
    /// source session so the panel can send a later 拆解 prompt back to it.
    var session: String?
}

struct RequirementsStateRequest: Equatable {
    var workspace: String?
    var id: String
    var state: String
}

struct RequirementsBreakdownRequest: Equatable {
    var workspace: String?
    var id: String
    var items: [BreakdownItem] = []
}

struct RequirementsTargetRequest: Equatable {
    var workspace: String?
    var id: String
}

/// POST /api/requirements/update: edit a card's title + 诉求.
struct RequirementsUpdateRequest: Equatable {
    var workspace: String?
    var id: String
    var title: String
    var body: String?
}

// MARK: - Delegate

/// Implemented by the requirements panel controller (wired through BrowserAPIBridge,
/// always called on the main thread — same rule as the tasks panel).
protocol RequirementsAPIDelegate: AnyObject {
    func apiRequirementsList(workspace: String?) -> [String: Any]
    func apiRequirementsCreate(_ request: RequirementsCreateRequest) -> [String: Any]
    func apiRequirementsSetState(_ request: RequirementsStateRequest) -> [String: Any]
    func apiRequirementsUpdate(_ request: RequirementsUpdateRequest) -> [String: Any]
    func apiRequirementsPropose(_ request: RequirementsBreakdownRequest) -> [String: Any]
    func apiRequirementsConfirm(_ request: RequirementsTargetRequest) -> [String: Any]
    func apiRequirementsReject(_ request: RequirementsTargetRequest) -> [String: Any]
}

// MARK: - Workspace normalization

/// Same rules as the tasks panel's TasksAPIWorkspace.normalize (trim, expand ~,
/// standardize). Duplicated here on purpose: the API test compiles this file without
/// the tasks model files.
enum RequirementsAPIWorkspace {
    static func normalize(_ path: String?) -> String? {
        guard let raw = path?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }
}

// MARK: - Response shapes (pure, shared with the panel)

enum RequirementsAPIResponse {

    static func workstream(_ ws: WorkstreamSummary) -> [String: Any] {
        var out: [String: Any] = ["id": ws.id, "title": ws.title, "stage": ws.stage]
        if let req = ws.requirement { out["requirement"] = req }
        if let outcome = ws.outcome { out["outcome"] = outcome }
        return out
    }

    static func proposal(_ items: [BreakdownItem]) -> [[String: Any]] {
        items.map { ["title": $0.title, "boundary": $0.boundary, "dependsOn": $0.dependsOn] }
    }

    static func requirement(_ card: RequirementCard) -> [String: Any] {
        var out: [String: Any] = ["id": card.id, "title": card.title]
        if let state = card.state { out["state"] = state }
        if !card.source.isEmpty { out["source"] = card.source }
        if !card.created.isEmpty { out["created"] = card.created }
        if !card.updated.isEmpty { out["updated"] = card.updated }
        return out
    }

    static func item(_ item: PoolItem) -> [String: Any] {
        var out = requirement(item.requirement)
        out["effectiveState"] = item.effectiveState.rawValue
        out["children"] = item.children.map(workstream)
        if let proposal = item.proposal { out["proposal"] = self.proposal(proposal) }
        return out
    }
}

// MARK: - Router

enum RequirementsAPIRouter {

    static let prefix = "/api/requirements/"

    /// Returns a response when the request belongs to this panel, nil otherwise
    /// (so BrowserAPIRouter can fall through to the browser routes / 404).
    static func route(_ request: HTTPRequest, delegate: RequirementsAPIDelegate?) -> HTTPResponse? {
        guard request.path.hasPrefix(prefix) else { return nil }
        switch (request.method, request.path) {

        case ("GET", "/api/requirements/list"):
            guard let delegate = delegate else { return unavailable() }
            let workspace = RequirementsAPIWorkspace.normalize(request.query["workspace"])
            let result = delegate.apiRequirementsList(workspace: workspace)
            return .json(status(for: result), result)

        case ("POST", "/api/requirements/create"):
            guard let body = request.jsonBody() else { return missingBody() }
            let title = ((body["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                return .json(400, ["ok": false, "error": "missing-title", "hint": "expected {\"title\": \"...\"}"])
            }
            guard let delegate = delegate else { return unavailable() }
            let req = RequirementsCreateRequest(workspace: RequirementsAPIWorkspace.normalize(body["workspace"] as? String),
                                                focus: (body["focus"] as? Bool) ?? true,
                                                title: title,
                                                body: body["body"] as? String,
                                                source: body["source"] as? String,
                                                session: (body["session"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
            let result = delegate.apiRequirementsCreate(req)
            return .json(status(for: result), result)

        case ("POST", "/api/requirements/state"):
            guard let body = request.jsonBody() else { return missingBody() }
            guard let id = (body["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                return .json(400, ["ok": false, "error": "missing-id"])
            }
            guard let state = (body["state"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                return .json(400, ["ok": false, "error": "missing-state"])
            }
            guard let delegate = delegate else { return unavailable() }
            let req = RequirementsStateRequest(workspace: RequirementsAPIWorkspace.normalize(body["workspace"] as? String),
                                               id: id, state: state)
            let result = delegate.apiRequirementsSetState(req)
            return .json(status(for: result), result)

        case ("POST", "/api/requirements/update"):
            guard let body = request.jsonBody() else { return missingBody() }
            guard let id = (body["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                return .json(400, ["ok": false, "error": "missing-id"])
            }
            let title = ((body["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                return .json(400, ["ok": false, "error": "missing-title", "hint": "expected {\"id\": \"REQ-1\", \"title\": \"...\"}"])
            }
            guard let delegate = delegate else { return unavailable() }
            let update = RequirementsUpdateRequest(workspace: RequirementsAPIWorkspace.normalize(body["workspace"] as? String),
                                                   id: id, title: title, body: body["body"] as? String)
            let updated = delegate.apiRequirementsUpdate(update)
            return .json(status(for: updated), updated)

        case ("POST", "/api/requirements/breakdown/propose"):
            guard let body = request.jsonBody() else { return missingBody() }
            guard let id = (body["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                return .json(400, ["ok": false, "error": "missing-id"])
            }
            let items = parseItems(body["items"])
            guard !items.isEmpty else {
                return .json(400, ["ok": false, "error": "no-items",
                                   "hint": "expected {\"items\": [{\"title\": \"...\", \"boundary\": \"...\"}]}"])
            }
            guard let delegate = delegate else { return unavailable() }
            let req = RequirementsBreakdownRequest(workspace: RequirementsAPIWorkspace.normalize(body["workspace"] as? String),
                                                   id: id, items: items)
            let result = delegate.apiRequirementsPropose(req)
            return .json(status(for: result), result)

        case ("POST", "/api/requirements/breakdown/confirm"),
             ("POST", "/api/requirements/breakdown/reject"):
            guard let body = request.jsonBody() else { return missingBody() }
            guard let id = (body["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                return .json(400, ["ok": false, "error": "missing-id"])
            }
            guard let delegate = delegate else { return unavailable() }
            let req = RequirementsTargetRequest(workspace: RequirementsAPIWorkspace.normalize(body["workspace"] as? String), id: id)
            let result = request.path.hasSuffix("/confirm")
                ? delegate.apiRequirementsConfirm(req)
                : delegate.apiRequirementsReject(req)
            return .json(status(for: result), result)

        default:
            return .json(404, ["ok": false, "error": "not-found"])
        }
    }

    static func parseItems(_ raw: Any?) -> [BreakdownItem] {
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap { obj in
            guard let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                return nil
            }
            return BreakdownItem(title: title,
                                 boundary: ((obj["boundary"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                 dependsOn: (obj["dependsOn"] as? [String]) ?? [])
        }
    }

    /// Map a delegate result onto an HTTP status (the delegate carries the error code).
    static func status(for result: [String: Any]) -> Int {
        if (result["ok"] as? Bool) == true { return 200 }
        switch result["error"] as? String {
        case "unknown-requirement": return 404
        case "no-proposal": return 409
        case "panel-unavailable": return 503
        case "write-failed": return 500
        default: return 400
        }
    }

    static func missingBody() -> HTTPResponse {
        .json(400, ["ok": false, "error": "missing-body",
                    "hint": "expected a JSON object"])
    }

    static func unavailable() -> HTTPResponse {
        .json(503, ["ok": false, "error": "panel-unavailable",
                    "hint": "the requirements pool panel is not ready"])
    }
}

// MARK: - Core error -> API result

extension PoolError {
    /// The result dictionary the delegate returns for this error.
    var apiResult: [String: Any] {
        ["ok": false, "error": code, "message": message]
    }
}
