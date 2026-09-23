import Foundation

// Headless tests for DshWebRPC / DshWorkspaceStore. The HTTP layer is injected
// through DshWebRPC.perform, so no server is needed.

var failures = 0
func check(_ ok: Bool, _ label: String) {
    if ok { print("ok  - \(label)") } else { failures += 1; print("FAIL- \(label)") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ label: String) { check(a == b, "\(label) (got \(a), want \(b))") }

// MARK: - Fake transport

/// "GET /?token=…" / "POST /api/session/list" — the port is stripped so one fake
/// can serve every test port.
func requestKey(_ request: URLRequest) -> String {
    let method = request.httpMethod ?? "GET"
    let url = request.url?.absoluteString ?? ""
    let path = url
        .replacingOccurrences(of: "http://127.0.0.1:", with: "")
        .replacingOccurrences(of: "^[0-9]+", with: "", options: .regularExpression)
    return "\(method) \(path)"
}

final class FakeTransport {
    /// "METHOD path" -> (status, body)
    var routes: [String: (Int, [String: Any]?)] = [:]
    var requests: [String] = []
    var bodies: [String: [String: Any]] = [:]

    func perform(_ request: URLRequest) -> (status: Int, body: Data?) {
        let key = requestKey(request)
        requests.append(key)
        if let body = request.httpBody, let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            bodies[key] = obj
        }
        guard let route = routes[key] else { return (404, Data("not found".utf8)) }
        guard let obj = route.1 else { return (route.0, Data()) }
        return (route.0, try? JSONSerialization.data(withJSONObject: obj))
    }
}

func okValue(_ value: [String: Any]) -> [String: Any] {
    ["result": ["ok": true, "value": value]]
}

let fake = FakeTransport()
DshWebRPC.perform = { fake.perform($0) }

// MARK: - Envelope + value semantics

let env = DshWebRPC.envelope(method: "session/list", payload: ["args": ["_request": [:]]], rpcId: "r1")
eq(env["type"] as? String, "client-request", "envelope carries the client-request type")
eq(env["method"] as? String, "session/list", "envelope carries the endpoint as method")
eq(env["rpcId"] as? String, "r1", "envelope keeps the rpcId")
check(DshWebRPC.modernValue(["result": ["ok": true, "value": ["items": []]]]) != nil, "modern success needs a value")
check(DshWebRPC.modernValue(["result": ["ok": true, "value": NSNull()]]) == nil, "modern ok without a value is not usable")
check(DshWebRPC.legacyValue(["result": ["ok": true, "value": NSNull()]]) != nil, "legacy ok without a value is usable")
check(DshWebRPC.modernValue(["result": ["ok": false]]) == nil, "failed result is not usable")

// MARK: - dsh >= 0.1.2: slash endpoint + args envelope + token cookie

DshWebRPC.resetForTests()
DshWebRPC.token = "launch-token"
fake.routes = [
    "GET /?token=launch-token": (303, nil),
    "POST /api/session/list": (200, okValue(["items": [["sessionId": "s-1"]]])),
]
var v = DshWebRPC.call(DshWebRPC.sessionList, [:], port: 6001)
eq((v?["items"] as? [[String: Any]])?.count, 1, "0.1.2: slash endpoint answers")
check(fake.requests.first == "GET /?token=launch-token", "0.1.2: launch token exchanged before the first call")
let modernBody = fake.bodies["POST /api/session/list"]
let args = (modernBody?["payload"] as? [String: Any])?["args"] as? [String: Any]
check(args?["_request"] != nil, "session/list wraps args in _request")
check(!fake.requests.contains("POST /api/session.list"), "0.1.2: legacy method not tried once modern works")

// cookie exchange happens once per port
let before = fake.requests.filter { $0.hasPrefix("GET ") }.count
_ = DshWebRPC.call(DshWebRPC.sessionList, [:], port: 6001)
eq(fake.requests.filter { $0.hasPrefix("GET ") }.count, before, "0.1.2: cookie exchange cached per port")

// modernExtras only reach the modern surface (0.1.2 requires requestId)
fake.routes["POST /api/session/prompt"] = (200, okValue(["accepted": true]))
_ = DshWebRPC.call(DshWebRPC.sessionPrompt, ["sessionId": "s-1"], port: 6001,
                   modernExtras: ["requestId": "req-1"])
let promptArgs = ((fake.bodies["POST /api/session/prompt"]?["payload"] as? [String: Any])?["args"] as? [String: Any])?["request"] as? [String: Any]
eq(promptArgs?["requestId"] as? String, "req-1", "0.1.2: modernExtras merged into the modern args")

// MARK: - dsh <= 0.1.1: dot method fallback

DshWebRPC.resetForTests()
DshWebRPC.token = nil
fake.requests = []; fake.bodies = [:]
fake.routes = [
    "POST /api/session/list": (404, nil),
    "POST /api/session.list": (200, okValue(["items": [["sessionId": "s-legacy"]]])),
]
v = DshWebRPC.call(DshWebRPC.sessionList, [:], port: 6002)
eq((v?["items"] as? [[String: Any]])?.first?["sessionId"] as? String, "s-legacy", "0.1.1: dot method answers")
eq(fake.requests, ["POST /api/session/list", "POST /api/session.list"], "0.1.1: modern probed once then legacy")
fake.requests = []
_ = DshWebRPC.call(DshWebRPC.sessionList, [:], port: 6002)
eq(fake.requests, ["POST /api/session.list"], "0.1.1: surface decision is remembered")

// an endpoint the server lacks must not poison another endpoint (0.1.2 has no workspace/list)
DshWebRPC.resetForTests()
DshWebRPC.token = "launch-token"
fake.requests = []
fake.routes = [
    "GET /?token=launch-token": (303, nil),
    "POST /api/session/list": (200, okValue(["items": []])),
]
check(DshWebRPC.call(DshWebRPC.workspaceList, [:], port: 6003) == nil, "0.1.2: workspace/list is unavailable")
v = DshWebRPC.call(DshWebRPC.sessionList, [:], port: 6003)
check(v != nil, "0.1.2: session/list still answered after workspace/list fell back")

// MARK: - Stale cookie re-exchange

DshWebRPC.resetForTests()
DshWebRPC.token = "launch-token"
var unauthorizedOnce = true
fake.requests = []
DshWebRPC.perform = { request in
    let key = requestKey(request)
    fake.requests.append(key)
    if key.hasPrefix("GET ") { return (303, nil) }
    if unauthorizedOnce { unauthorizedOnce = false; return (401, Data("unauthorized".utf8)) }
    return (200, try? JSONSerialization.data(withJSONObject: okValue(["items": [["sessionId": "s-2"]]])))
}
v = DshWebRPC.call(DshWebRPC.sessionList, [:], port: 6004)
eq((v?["items"] as? [[String: Any]])?.first?["sessionId"] as? String, "s-2", "401: cookie re-exchanged once and retried")
eq(fake.requests.filter { $0.hasPrefix("GET ") }.count, 2, "401: exactly one extra token exchange")
DshWebRPC.perform = { fake.perform($0) }

// MARK: - Only an absent endpoint may pin the legacy surface
//
// Any other failure used to disable the slash endpoint for the whole process,
// and on dsh >= 0.1.2 every later call then fell through to <dot.method>, which
// that server does not serve — e.g. the wiki "+" (session/create) died for the
// rest of the app run after a single hiccup.

DshWebRPC.resetForTests()
DshWebRPC.token = "launch-token"
fake.requests = []; fake.bodies = [:]
var postAttempts = 0
DshWebRPC.perform = { request in
    let key = requestKey(request)
    fake.requests.append(key)
    if key.hasPrefix("GET ") { return (303, nil) }
    postAttempts += 1
    if postAttempts <= 2 { return (-1, nil) }   // first call: both surfaces time out
    return (200, try? JSONSerialization.data(withJSONObject: okValue(["sessionId": "s-3"])))
}
check(DshWebRPC.call(DshWebRPC.sessionCreate, ["cwd": "/tmp/x"], port: 6005) == nil,
      "timeout: the call itself still fails")
eq(DshWebRPC.call(DshWebRPC.sessionCreate, ["cwd": "/tmp/x"], port: 6005)?["sessionId"] as? String, "s-3",
   "timeout: the slash endpoint is retried instead of being abandoned")
eq(fake.requests.filter { $0 == "POST /api/session/create" }.count, 2,
   "timeout: both calls went to the slash endpoint")

// A business error (endpoint present, args rejected) is not an absent endpoint.
DshWebRPC.resetForTests()
var calls = 0
DshWebRPC.perform = { request in
    let key = requestKey(request)
    fake.requests.append(key)
    if key.hasPrefix("GET ") { return (303, nil) }
    calls += 1
    if calls <= 2 {
        let err: [String: Any] = ["result": ["ok": false,
                                            "error": ["code": "workspace/not-found", "message": "nope"]]]
        return (200, try? JSONSerialization.data(withJSONObject: err))
    }
    return (200, try? JSONSerialization.data(withJSONObject: okValue(["sessionId": "s-4"])))
}
check(DshWebRPC.call(DshWebRPC.sessionCreate, ["workspaceId": "w-1"], port: 6006) == nil,
      "workspace/not-found: the call fails")
eq(DshWebRPC.call(DshWebRPC.sessionCreate, ["cwd": "/tmp/x"], port: 6006)?["sessionId"] as? String, "s-4",
   "workspace/not-found: the next call still uses the slash endpoint")
DshWebRPC.perform = { fake.perform($0) }

// MARK: - Persisted workspace store (dsh >= 0.1.2 fallback)

let home = NSTemporaryDirectory() + "dsh-rpc-test-" + UUID().uuidString
try? FileManager.default.createDirectory(atPath: home + "/storages", withIntermediateDirectories: true)
let store: [String: Any] = [
    "unit": ["name": "workspace", "version": 2],
    "global": ["workspaceIds": ["w-b", "w-a"]],
    "tables": ["workspaces": [
        "w-a": ["path": "/p/alpha", "title": "Alpha", "sessionIds": ["s-1"], "createdAt": "c", "updatedAt": "u"],
        "w-b": ["path": "/p/beta", "title": "Beta", "sessionIds": []],
        "w-broken": ["title": "no path"],
    ]],
]
try? JSONSerialization.data(withJSONObject: store)
    .write(to: URL(fileURLWithPath: home + "/storages/workspace.json"))

let items = DshWorkspaceStore.persistedItems(dshHome: home)
eq(items.count, 2, "store: skips entries without a path")
eq(items.first?["workspaceId"] as? String, "w-b", "store: keeps dsh web's workspaceIds order")
eq(items.last?["title"] as? String, "Alpha", "store: carries title + path")
eq((items.last?["sessionIds"] as? [String])?.first, "s-1", "store: carries sessionIds")
eq(DshWorkspaceStore.persistedItems(dshHome: home + "/missing").count, 0, "store: missing file is empty, never throws")
eq(DshWorkspaceStore.workspaceId(forPath: "/p/alpha", port: nil, dshHome: home), "w-a", "store: resolves a workspaceId by path")
eq(DshWorkspaceStore.workspaceId(forPath: "/p/unknown", port: nil, dshHome: home), nil, "store: unknown path has no workspaceId")
try? FileManager.default.removeItem(atPath: home)


// MARK: - Persisted store: domain gate + diagnostics (R4)

func storeHome(unit: [String: Any]?, tables: [String: Any]?, order: [String]?) -> String {
    let home = NSTemporaryDirectory() + "dsh-store-" + UUID().uuidString
    let dir = home + "/storages"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var doc: [String: Any] = [:]
    if let unit = unit { doc["unit"] = unit }
    if let order = order { doc["global"] = ["workspaceIds": order] }
    if let tables = tables { doc["tables"] = ["workspaces": tables] }
    try? JSONSerialization.data(withJSONObject: doc).write(to: URL(fileURLWithPath: dir + "/workspace.json"))
    return home
}

let v3Home = storeHome(unit: ["name": "workspace", "version": 3],
                       tables: ["w-1": ["path": "/p/alpha", "title": "Alpha", "sessionIds": []]],
                       order: ["w-1"])
var logs: [String] = []
eq(DshWorkspaceStore.persistedItems(dshHome: v3Home, log: { logs.append($0) }).count, 1,
   "store: a bumped domain version is still read best-effort")
check(logs.contains { $0.contains("understands v2") }, "store: the version mismatch is reported")
eq(DshWorkspaceStore.readStore(dshHome: v3Home).reason, "version", "store: reason = version")

let shapeHome = storeHome(unit: ["name": "workspace", "version": 2], tables: nil, order: [])
logs = []
eq(DshWorkspaceStore.persistedItems(dshHome: shapeHome, log: { logs.append($0) }).count, 0,
   "store: an unexpected shape yields no items")
check(logs.contains { $0.contains("unexpected shape") }, "store: the unexpected shape is reported")

logs = []
eq(DshWorkspaceStore.persistedItems(dshHome: NSTemporaryDirectory() + "missing-" + UUID().uuidString,
                                    log: { logs.append($0) }).count, 0, "store: a missing store yields no items")
eq(logs.count, 0, "store: a missing store stays quiet (normal on dsh <= 0.1.1)")
for h in [v3Home, shapeHome] { try? FileManager.default.removeItem(atPath: h) }


// MARK: - DshWorkspaceOps (Projects panel: register / create session / pick session)

DshWebRPC.resetForTests()
DshWebRPC.token = "launch-token"
fake.requests = []; fake.bodies = [:]
fake.routes = [
    "GET /?token=launch-token": (303, nil),
    "POST /api/workspace/create": (200, okValue(["workspace": ["workspaceId": "w-new", "path": "/p/abc"],
                                                 "created": true])),
]
eq(DshWorkspaceOps.register(port: 6010, path: "/p/abc"), "w-new", "register: answers the workspaceId")
let createArgs = ((fake.bodies["POST /api/workspace/create"]?["payload"] as? [String: Any])?["args"] as? [String: Any])?["request"] as? [String: Any]
eq(createArgs?["path"] as? String, "/p/abc", "register: workspace/create carries path under args.request")

fake.routes["POST /api/workspace/create"] = (200, okValue(["workspace": ["workspaceId": "w-old"], "created": false]))
eq(DshWorkspaceOps.register(port: 6010, path: "/p/abc"), "w-old",
   "register: idempotent — created:false still resolves the workspaceId")

// A server that does not serve the verb (dsh <= 0.1.1, or an older build) must
// degrade to "unregistered", never to an exception or a retry storm.
DshWebRPC.resetForTests()
fake.requests = []
fake.routes = ["POST /api/workspace/create": (404, nil), "POST /api/workspace.create": (404, nil)]
eq(DshWorkspaceOps.register(port: 6011, path: "/p/abc"), nil,
   "register: an absent endpoint yields nil (the caller keeps the directory)")
fake.routes = ["POST /api/workspace/create": (200, okValue(["created": true]))]
eq(DshWorkspaceOps.register(port: 6011, path: "/p/abc"), nil,
   "register: a value without workspaceId yields nil")

// createSession: workspaceId first (so dsh web groups the session), cwd as the
// fallback when the id is rejected.
DshWebRPC.resetForTests()
DshWebRPC.token = "launch-token"
var attempts: [[String: Any]] = []
fake.requests = []
DshWebRPC.perform = { request in
    let key = requestKey(request)
    fake.requests.append(key)
    if key.hasPrefix("GET ") { return (303, nil) }
    if let body = request.httpBody,
       let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
       let payload = obj["payload"] as? [String: Any],
       let args = payload["args"] as? [String: Any],
       let req = args["request"] as? [String: Any] {
        attempts.append(req)
    }
    if attempts.count == 1 {
        let err: [String: Any] = ["result": ["ok": false,
                                             "error": ["code": "workspace/not-found", "message": "nope"]]]
        return (200, try? JSONSerialization.data(withJSONObject: err))
    }
    return (200, try? JSONSerialization.data(withJSONObject: okValue(["sessionId": "s-fallback"])))
}
eq(DshWorkspaceOps.createSession(port: 6012, cwd: "/p/abc", workspaceId: "w-old"), "s-fallback",
   "createSession: falls back to cwd when the workspaceId is rejected")
eq(attempts.first?["workspaceId"] as? String, "w-old", "createSession: the first attempt carries the workspaceId")
eq(attempts.count, 2, "createSession: exactly one fallback attempt")
eq(attempts.last?["cwd"] as? String, "/p/abc", "createSession: the fallback carries the cwd")
DshWebRPC.perform = { fake.perform($0) }

// A missing workspaceId goes straight to the cwd form.
DshWebRPC.resetForTests()
fake.requests = []; fake.bodies = [:]
fake.routes = [
    "GET /?token=launch-token": (303, nil),
    "POST /api/session/create": (200, okValue(["sessionId": "s-cwd"])),
]
eq(DshWorkspaceOps.createSession(port: 6014, cwd: "/p/abc", workspaceId: nil), "s-cwd",
   "createSession: no workspaceId -> plain cwd create")
eq(fake.requests.filter { $0 == "POST /api/session/create" }.count, 1,
   "createSession: no wasted attempt without a workspaceId")

// newestSessionId: running wins, then the most recently updated; the cwd must
// match (trailing slash and symlinked spellings included) and cwd-less sessions
// are never picked.
let sessionItems: [[String: Any]] = [
    ["sessionId": "s-run-old", "cwd": "/p/abc", "running": true, "updatedAt": 5.0],
    ["sessionId": "s-run-new", "cwd": "/p/abc/", "running": true, "updatedAt": 7.0],
    ["sessionId": "s-idle-newest", "cwd": "/p/abc", "running": false, "updatedAt": 900.0],
    ["sessionId": "s-other", "cwd": "/p/other", "running": true, "updatedAt": 9999.0],
    ["sessionId": "s-nocwd", "running": true, "updatedAt": 10000.0],
]
DshWebRPC.resetForTests()
fake.routes = ["GET /?token=launch-token": (303, nil),
               "POST /api/session/list": (200, okValue(["items": sessionItems]))]
eq(DshWorkspaceOps.newestSessionId(port: 6015, inPath: "/p/abc"), "s-run-new",
   "newestSessionId: running first, then updatedAt (trailing slash still matches)")

DshWebRPC.resetForTests()
let idleOnly = sessionItems.map { item -> [String: Any] in
    var copy = item
    copy["running"] = false
    return copy
}
fake.routes = ["GET /?token=launch-token": (303, nil),
               "POST /api/session/list": (200, okValue(["items": idleOnly]))]
eq(DshWorkspaceOps.newestSessionId(port: 6016, inPath: "/p/abc"), "s-idle-newest",
   "newestSessionId: with nothing running the newest session is picked")

DshWebRPC.resetForTests()
fake.routes = ["GET /?token=launch-token": (303, nil),
               "POST /api/session/list": (200, okValue(["items": []])),
               "POST /api/session/list2": (404, nil)]
eq(DshWorkspaceOps.newestSessionId(port: 6017, inPath: "/p/abc"), nil,
   "newestSessionId: a workspace without sessions answers nil (the caller creates one)")

// A BLANK session (never prompted) is skipped even when it is the newest: dsh web
// renders a blank session ONLY while it is the page's current one, so re-opening
// one from outside the page is impossible and it would hide the workspace's real
// sessions. nil means "nothing worth re-opening" — the caller starts a session
// and dsh web answers by REUSING that very blank session.
DshWebRPC.resetForTests()
let withBlank: [[String: Any]] = [
    ["sessionId": "s-blank-newest", "cwd": "/p/abc", "blank": true, "running": false, "updatedAt": 900.0],
    ["sessionId": "s-real-older", "cwd": "/p/abc", "blank": false, "running": false, "updatedAt": 3.0],
]
fake.routes = ["GET /?token=launch-token": (303, nil),
               "POST /api/session/list": (200, okValue(["items": withBlank]))]
eq(DshWorkspaceOps.newestSessionId(port: 6018, inPath: "/p/abc"), "s-real-older",
   "newestSessionId: a blank session is skipped even when it is the newest")

DshWebRPC.resetForTests()
fake.routes = ["GET /?token=launch-token": (303, nil),
               "POST /api/session/list": (200, okValue(["items": [withBlank[0]]]))]
eq(DshWorkspaceOps.newestSessionId(port: 6019, inPath: "/p/abc"), nil,
   "newestSessionId: a workspace whose only session is blank answers nil (the caller reuses it)")

// A plain running blank session must not win over a real idle one either: the
// running flag is only meaningful among sessions that can actually be opened.
DshWebRPC.resetForTests()
let runningBlank: [[String: Any]] = [
    ["sessionId": "s-blank-running", "cwd": "/p/abc", "blank": true, "running": true, "updatedAt": 999.0],
    ["sessionId": "s-real-idle", "cwd": "/p/abc", "blank": false, "running": false, "updatedAt": 1.0],
]
fake.routes = ["GET /?token=launch-token": (303, nil),
               "POST /api/session/list": (200, okValue(["items": runningBlank]))]
eq(DshWorkspaceOps.newestSessionId(port: 6020, inPath: "/p/abc"), "s-real-idle",
   "newestSessionId: a running session only wins among openable (non-blank) ones")

// canonical(): a macOS directory listing reports /private/var/... while the same
// path typed by the user (or stored by dsh) may say /var/... — both must compare
// equal, or the panel reports a registered workspace as unregistered.
let tmpDir = NSTemporaryDirectory()
eq(DshWorkspaceStore.canonical(tmpDir), DshWorkspaceStore.canonical("/private" + tmpDir),
   "canonical: the /var and /private/var spellings of one directory fold together")

print(failures == 0 ? "dsh-rpc tests passed" : "dsh-rpc tests FAILED (\(failures))")
exit(failures == 0 ? 0 : 1)
