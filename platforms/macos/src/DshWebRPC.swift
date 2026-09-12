import Foundation

// MARK: - Native dsh web RPC (both API generations)
//
// The panels' native clients (WikiRPC, IssueRunner, DSHSessionRPC) used to speak
// only the dsh <= 0.1.1 wire shape: POST /api/<dot.method> with the request args
// as the payload and no authentication. dsh >= 0.1.2 changed both halves:
//
//   * /api is fenced by a browser cookie minted from the per-instance launch
//     token: GET /?token=<token> -> 303 + Set-Cookie dsh-auth-*;
//   * endpoints moved to slash paths and wrap their args in
//     payload.args.<request|_request> (the field name differs per endpoint).
//
// call() hides the difference: it tries the modern endpoint first and falls back
// to the legacy method when the running server does not know it, remembering the
// decision per (port, endpoint) — a server may serve session/list but not
// workspace/list, so this is not a per-server switch.
//
// The cookie is handled by URLSession's own (ephemeral) cookie store: visiting
// the advertised token URL once is enough for every later /api request on the
// same session. WebView cookies are NOT visible here (WKWebView keeps them in
// its own data store), which is why the token is passed in explicitly.
//
// Docs: docs/dsh-version-impact.md (R1), docs/plans/dsh-012rc1-compat-audit.md.

enum DshWebRPC {

    /// One logical call on both surfaces.
    struct Endpoint {
        let modern: String
        let legacy: String
        let field: String
        init(_ modern: String, _ legacy: String, field: String = "request") {
            self.modern = modern
            self.legacy = legacy
            self.field = field
        }
    }

    static let sessionList = Endpoint("session/list", "session.list", field: "_request")
    static let sessionCreate = Endpoint("session/create", "session.create")
    static let sessionRename = Endpoint("session/rename", "session.rename")
    static let sessionPrompt = Endpoint("session/prompt", "session.prompt")
    static let sessionCancel = Endpoint("session/cancel", "session.cancel")
    /// Removed on dsh >= 0.1.2 (served as a workspace/follow stream there), so the
    /// modern attempt is expected to fail and callers fall back to the persisted
    /// store (see DshWorkspaceStore).
    static let workspaceList = Endpoint("workspace/list", "workspace.list", field: "_request")

    /// Launch token from the URL dsh web advertises (nil on dsh <= 0.1.1).
    /// ServerManager sets it once dsh web is up; never logged.
    static var token: String?

    /// Single HTTP seam — tests inject a fake to exercise the fallback logic.
    static var perform: (URLRequest) -> (status: Int, body: Data?) = { request in
        DshWebRPCTransport.shared.perform(request)
    }

    private static var authenticatedPorts: Set<Int> = []
    /// "port:modern endpoint" -> server speaks it (nil = not decided yet).
    private static var surface: [String: Bool] = [:]
    private static let lock = NSLock()

    /**
     * Run one RPC and return its `result.value` (nil when the call failed).
     * `modernExtras` are merged into the request only on the dsh >= 0.1.2 surface
     * (e.g. the requestId session/prompt now requires).
     */
    static func call(_ endpoint: Endpoint, _ payload: [String: Any], port: Int,
                     timeout: TimeInterval = 6,
                     modernExtras: [String: Any] = [:]) -> [String: Any]? {
        let key = "\(port):\(endpoint.modern)"
        let known = lock.lock_run { surface[key] }
        if known != false {
            var args = payload
            for (k, v) in modernExtras { args[k] = v }
            let modern = post(method: endpoint.modern, payload: ["args": [endpoint.field: args]],
                              port: port, timeout: timeout)
            if let value = modernValue(modern.json) {
                lock.lock_run { surface[key] = true }
                return value
            }
            // Only a genuinely ABSENT endpoint (404/405) means this server wants
            // the legacy dot method. Pinning on anything else was a trap: one
            // transient failure (401 while the launch token is still being
            // exchanged, a timeout on a busy server, a business error) disabled
            // the slash endpoint for the whole process — and on dsh >= 0.1.2 every
            // later call then fell through to <dot.method>, which it does not
            // serve, so the feature stayed dead until the app was restarted.
            if modern.status == 404 || modern.status == 405 {
                lock.lock_run { surface[key] = false }
            }
        }
        let legacy = post(method: endpoint.legacy, payload: payload, port: port, timeout: timeout)
        return legacyValue(legacy.json)
    }

    /// The client-request envelope (pure — unit tested).
    static func envelope(method: String, payload: [String: Any], rpcId: String = UUID().uuidString) -> [String: Any] {
        ["type": "client-request", "rpcId": rpcId, "method": method, "payload": payload]
    }

    /// A usable dsh >= 0.1.2 answer: ok AND a value (parsers answer 404/ok:false).
    static func modernValue(_ json: [String: Any]?) -> [String: Any]? {
        guard let result = json?["result"] as? [String: Any],
              (result["ok"] as? Bool) == true,
              let value = result["value"] as? [String: Any] else { return nil }
        return value
    }

    /// A usable dsh <= 0.1.1 answer (some legacy methods answer ok with no value).
    static func legacyValue(_ json: [String: Any]?) -> [String: Any]? {
        guard let result = json?["result"] as? [String: Any],
              (result["ok"] as? Bool) == true else { return nil }
        return (result["value"] as? [String: Any]) ?? [:]
    }

    private static func post(method: String, payload: [String: Any], port: Int,
                             timeout: TimeInterval) -> (status: Int, json: [String: Any]?) {
        authenticate(port: port, timeout: timeout)
        var res = send(method: method, payload: payload, port: port, timeout: timeout)
        if res.status == 401, let token = token, !token.isEmpty {
            // Cookie outlived the dsh web process that minted it — re-exchange once.
            markUnauthenticated(port)
            authenticate(port: port, timeout: timeout)
            res = send(method: method, payload: payload, port: port, timeout: timeout)
        }
        guard let body = res.body else { return (res.status, nil) }
        return (res.status, (try? JSONSerialization.jsonObject(with: body)) as? [String: Any])
    }

    private static func send(method: String, payload: [String: Any], port: Int,
                             timeout: TimeInterval) -> (status: Int, body: Data?) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/\(method)") else { return (-1, nil) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: envelope(method: method, payload: payload))
        return perform(request)
    }

    /// Visit the advertised token URL once per port so the cookie lands in the
    /// transport's cookie store (dsh >= 0.1.2). Older dsh needs no cookie.
    static func authenticate(port: Int, timeout: TimeInterval = 6) {
        if lock.lock_run({ authenticatedPorts.contains(port) }) { return }
        guard let token = token, !token.isEmpty,
              let url = URL(string: "http://127.0.0.1:\(port)/?token=\(token)") else { return }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        // Remember the port only when the exchange actually answered: a timed-out
        // GET stores no cookie, and marking it anyway left every later call on
        // that port answering 401 forever.
        let res = perform(request)
        guard res.status == 200 || res.status == 302 || res.status == 303 else { return }
        _ = lock.lock_run { authenticatedPorts.insert(port) }
    }

    private static func markUnauthenticated(_ port: Int) {
        lock.lock_run { authenticatedPorts.remove(port) }
    }

    /// Test hook: forget cached surface decisions / auth state.
    static func resetForTests() {
        lock.lock_run {
            authenticatedPorts.removeAll()
            surface.removeAll()
        }
    }
}

/// A dedicated URLSession for native dsh RPC. Its cookie store is separate from
/// the WKWebView's (and from any other URLSession), ephemeral and in-memory, so
/// the exchanged dsh-auth-* cookie never leaks to unrelated requests.
final class DshWebRPCTransport {
    static let shared = DshWebRPCTransport()
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    func perform(_ request: URLRequest) -> (status: Int, body: Data?) {
        let semaphore = DispatchSemaphore(value: 0)
        var status = -1
        var body: Data?
        let task = session.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? -1
            body = data
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + (request.timeoutInterval + 2))
        return (status, body)
    }
}

// MARK: - Workspace list

/// The dsh workspaces of a server: the live RPC when that server still serves it
/// (dsh <= 0.1.1), otherwise the store dsh persists at
/// `$DSH_HOME/storages/workspace.json` (dsh >= 0.1.2 has no workspace.list).
/// Mirrors core/lib/workspace-store.js so shell and core agree on the fallback.
enum DshWorkspaceStore {

    /// dsh data home (env DSH_HOME or ~/.dsh).
    static func dataHome() -> String {
        if let h = ProcessInfo.processInfo.environment["DSH_HOME"],
           !h.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return h.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".dsh")
    }

    /// The domain this reader understands (dsh-workspace/lib/invariant.js:
    /// `defineDomain({ name: "workspace", version: 2, … })`). The persisted layout is
    /// PRIVATE to dsh — it may rename fields, move the file or bump this version
    /// without notice — so a mismatch is reported rather than silently returning [].
    static let supportedDomainName = "workspace"
    static let supportedDomainVersion = 2

    /// Outcome of reading the persisted store (items are best-effort even when the
    /// layout is not the one we know).
    struct StoreRead {
        var items: [[String: Any]]
        var reason: String            // ok | missing | unreadable | unexpected | version
        var name: String?
        var version: Int?
        var file: String

        /// Line to log, or nil when there is nothing to report.
        var diagnostic: String? {
            switch reason {
            case "ok", "missing":
                return nil
            case "version":
                return "persisted workspace store \(file) is domain \(name ?? "?") v\(version.map(String.init) ?? "?")"
                    + ", this build understands v\(DshWorkspaceStore.supportedDomainVersion)"
                    + (items.isEmpty ? " — cannot read it" : " — read best-effort")
            case "unexpected":
                return "persisted workspace store \(file) has an unexpected shape (no tables.workspaces / domain name)"
            default:
                return "persisted workspace store \(file) could not be read (\(reason))"
            }
        }
    }

    /// Workspaces persisted by dsh, in dsh web's own order (`global.workspaceIds`).
    /// Each item mirrors the old workspace.list shape:
    /// `{workspaceId, path, title, sessionIds, createdAt, updatedAt}`.
    static func readStore(dshHome: String? = nil) -> StoreRead {
        let home = dshHome ?? dataHome()
        let file = (home as NSString).appendingPathComponent("storages/workspace.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)) else {
            return StoreRead(items: [], reason: FileManager.default.fileExists(atPath: file) ? "unreadable" : "missing", file: file)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return StoreRead(items: [], reason: "unreadable", file: file)
        }
        let unit = json["unit"] as? [String: Any]
        let name = unit?["name"] as? String
        let version = unit?["version"] as? Int
        guard let tables = json["tables"] as? [String: Any],
              let workspaces = tables["workspaces"] as? [String: Any] else {
            return StoreRead(items: [], reason: "unexpected", name: name, version: version, file: file)
        }
        let order = (json["global"] as? [String: Any])?["workspaceIds"] as? [String] ?? []
        let ids = order.filter { workspaces[$0] != nil }
            + workspaces.keys.filter { !order.contains($0) }.sorted()
        var items: [[String: Any]] = []
        for id in ids {
            guard let ws = workspaces[id] as? [String: Any],
                  let path = ws["path"] as? String, !path.isEmpty else { continue }
            var item: [String: Any] = [
                "workspaceId": id,
                "path": path,
                "title": (ws["title"] as? String) ?? "",
                "sessionIds": (ws["sessionIds"] as? [String]) ?? [],
            ]
            if let created = ws["createdAt"] { item["createdAt"] = created }
            if let updated = ws["updatedAt"] { item["updatedAt"] = updated }
            items.append(item)
        }
        if name != supportedDomainName {
            return StoreRead(items: items, reason: "unexpected", name: name, version: version, file: file)
        }
        if version != supportedDomainVersion {
            return StoreRead(items: items, reason: "version", name: name, version: version, file: file)
        }
        return StoreRead(items: items, reason: "ok", name: name, version: version, file: file)
    }

    /// Persisted workspaces; `log` receives a diagnostic when the store is not the
    /// layout we know (callers pass AppLog so this never degrades silently).
    static func persistedItems(dshHome: String? = nil, log: ((String) -> Void)? = nil) -> [[String: Any]] {
        let read = readStore(dshHome: dshHome)
        if let note = read.diagnostic { log?("[workspace-store] " + note) }
        return read.items
    }

    /// Live workspace.list when the server still serves it, else the persisted store.
    static func items(port: Int?, timeout: TimeInterval = 6, dshHome: String? = nil,
                      log: ((String) -> Void)? = nil) -> [[String: Any]] {
        if let port = port,
           let value = DshWebRPC.call(DshWebRPC.workspaceList, [:], port: port, timeout: timeout),
           let items = value["items"] as? [[String: Any]] {
            return items
        }
        return persistedItems(dshHome: dshHome, log: log)
    }

    /// Canonical form of a path (standardized + symlinks resolved) so session cwds
    /// and workspace paths compare reliably.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The workspaceId of the workspace whose path matches `path` (nil when unknown).
    static func workspaceId(forPath path: String, port: Int?, dshHome: String? = nil,
                            log: ((String) -> Void)? = nil) -> String? {
        let target = canonical(path)
        for ws in items(port: port, dshHome: dshHome, log: log) {
            guard let wsPath = ws["path"] as? String else { continue }
            if canonical(wsPath) == target { return ws["workspaceId"] as? String }
        }
        return nil
    }
}

private extension NSLock {
    /// Run `body` with the lock held (keeps the call sites readable).
    func lock_run<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
