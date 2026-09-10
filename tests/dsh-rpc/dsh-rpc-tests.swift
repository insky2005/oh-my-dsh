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

print(failures == 0 ? "dsh-rpc tests passed" : "dsh-rpc tests FAILED (\(failures))")
exit(failures == 0 ? 0 : 1)
