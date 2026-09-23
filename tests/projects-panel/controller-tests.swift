import AppKit

// Headless tests for ProjectsPanelController: the panel is driven through the
// same entry points the UI uses (createWorkspace / ensureLoaded / the card
// closures), with a fake dsh HTTP transport. The assertions are on what the
// panel created on disk, what it asked dsh for, and what it handed back to the
// shell (onEnterWorkspace / onOpenPanel / onCreateSession).
//
// Usage: tests/projects-panel/run.sh

var failures = 0
func test(_ name: String, _ cond: Bool) {
    print((cond ? "ok  - " : "FAIL- ") + name)
    if !cond { failures += 1 }
}

_ = NSApplication.shared

// MARK: - Fixture: a temp dsh home, a projects root with two workspaces

// /private-prefixed: a directory listing reports the resolved form on macOS, so
// building the fixture the same way lets the assertions compare paths literally.
let home = ("/private" + NSTemporaryDirectory() as NSString).appendingPathComponent("projects-panel-" + UUID().uuidString)
let root = home + "/projects"
let alphaPath = root + "/alpha"
let betaPath = root + "/beta"
let fm = FileManager.default
try! fm.createDirectory(atPath: alphaPath, withIntermediateDirectories: true)
try! fm.createDirectory(atPath: betaPath, withIntermediateDirectories: true)
try! fm.createDirectory(atPath: root + "/.hidden", withIntermediateDirectories: true)
try! Data("not a workspace".utf8).write(to: URL(fileURLWithPath: root + "/notes.txt"))

// dsh's persisted workspace registry: alpha is registered with two sessions,
// beta is not registered at all (a folder the user created in Finder).
try! fm.createDirectory(atPath: home + "/storages", withIntermediateDirectories: true)
let store: [String: Any] = [
    "unit": ["name": "workspace", "version": 2],
    "global": ["workspaceIds": ["w-alpha"]],
    "tables": ["workspaces": [
        "w-alpha": ["path": alphaPath, "title": "alpha", "sessionIds": ["s-1", "s-2"]],
    ]],
]
try! JSONSerialization.data(withJSONObject: store)
    .write(to: URL(fileURLWithPath: home + "/storages/workspace.json"))

setenv("DSH_HOME", home, 1)
setenv("DSH_PROJECTS_TEST_ROOT", root, 1)

// MARK: - Fake dsh transport

final class FakeTransport {
    var workspaceCreates: [[String: Any]] = []
    var requests: [String] = []
    /// workspaceId -> the id workspace/create answers with.
    var nextWorkspaceId: String? = "w-created"
    var rejectWorkspaceCreate = false

    func perform(_ request: URLRequest) -> (status: Int, body: Data?) {
        let url = request.url?.absoluteString ?? ""
        let method = request.httpMethod ?? "GET"
        let key = method + " " + url.replacingOccurrences(of: "http://127.0.0.1:", with: "")
            .replacingOccurrences(of: "^[0-9]+", with: "", options: .regularExpression)
        requests.append(key)
        if key.hasPrefix("GET ") { return (303, nil) }
        var args: [String: Any] = [:]
        if let body = request.httpBody,
           let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let payload = obj["payload"] as? [String: Any],
           let wrapped = payload["args"] as? [String: Any],
           let request_ = wrapped["request"] as? [String: Any] {
            args = request_
        }
        if key.contains("workspace/create") {
            if rejectWorkspaceCreate { return (404, Data("nope".utf8)) }
            workspaceCreates.append(args)
            let value: [String: Any] = ["workspace": ["workspaceId": nextWorkspaceId ?? "", "path": args["path"] ?? ""],
                                        "created": true]
            return (200, try? JSONSerialization.data(withJSONObject: ["result": ["ok": true, "value": value]]))
        }
        // workspace/list (the live registry probe) is absent on dsh >= 0.1.2.
        return (404, Data("not found".utf8))
    }
}

let fake = FakeTransport()
DshWebRPC.resetForTests()
DshWebRPC.token = "test-token"
DshWebRPC.perform = { fake.perform($0) }

// MARK: - Helpers

func labels(_ view: NSView) -> [String] {
    var out: [String] = []
    if let field = view as? NSTextField { out.append(field.stringValue) }
    for sub in view.subviews { out.append(contentsOf: labels(sub)) }
    return out
}

func cards(_ view: NSView) -> [ProjectCardView] {
    var out: [ProjectCardView] = []
    if let card = view as? ProjectCardView { out.append(card) }
    for sub in view.subviews { out.append(contentsOf: cards(sub)) }
    return out
}

@discardableResult
func waitUntil(_ seconds: TimeInterval, _ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if predicate() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return predicate()
}

// MARK: - The panel, mounted (the create sheet and the picker need a window)

let panel = ProjectsPanelController()
panel.portProvider = { 6010 }
panel.dshHomeProvider = { home }
var current = alphaPath
panel.currentWorkspacePath = { current }

var entered: [String] = []
var opened: [(path: String, target: ProjectTargetPanel)] = []
var newSessions: [String] = []
panel.onEnterWorkspace = { entered.append($0) }
panel.onOpenPanel = { opened.append(($0, $1)) }
panel.onCreateSession = { newSessions.append($0) }

let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
                      styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = panel.view
window.contentView?.layoutSubtreeIfNeeded()
test("panel is mounted", panel.view.window != nil && panel.view.frame.width > 1)

// MARK: - Listing

panel.ensureLoaded()
test("the root line shows the effective root",
     waitUntil(2) { labels(panel.view).contains { $0.hasPrefix("projects.rootLabel") } })
test("two workspaces are listed (hidden dirs and files are not)",
     waitUntil(3) { panel.workspaces.count == 2 })
test("workspaces are sorted by name", panel.workspaces.map(\.name) == ["alpha", "beta"])
test("alpha is reported as registered with dsh",
     panel.workspaces.first { $0.name == "alpha" }?.registered == true)
test("the registered workspace carries its dsh session count",
     panel.workspaces.first { $0.name == "alpha" }?.sessionCount == 2)
test("beta is visible but unregistered",
     panel.workspaces.first { $0.name == "beta" }?.registered == false)
test("one card per workspace", cards(panel.view).count == 2)
test("the registered badge is rendered",
     labels(panel.view).contains { $0.contains("projects.registered") })
test("the unregistered badge is rendered",
     labels(panel.view).contains { $0 == "projects.unregistered" })
test("the empty state is hidden while workspaces exist", panel.isEmptyStateVisible == false)

// MARK: - Creating a workspace

let createCountBefore = fake.workspaceCreates.count
test("an invalid name creates nothing", panel.createWorkspace(named: "a/b") == false)
test("an invalid name does not reach dsh", fake.workspaceCreates.count == createCountBefore)
test("an invalid name says why",
     labels(panel.view).contains { $0 == "projects.invalidName" })
test("a name with a colon creates nothing", panel.createWorkspace(named: "a:b") == false)
test("a name with a colon does not reach dsh", fake.workspaceCreates.count == createCountBefore)

test("a valid name creates the directory", panel.createWorkspace(named: "gamma") == true)
var isDir: ObjCBool = false
test("the directory exists on disk",
     fm.fileExists(atPath: root + "/gamma", isDirectory: &isDir) && isDir.boolValue)
test("the creation is reported",
     waitUntil(2) { labels(panel.view).contains { $0.hasPrefix("projects.created") } })
// The panel standardizes the configured root before using it (which drops a
// /private prefix), so compare the two spellings through the same canonicalizer
// the registry match uses.
func samePath(_ a: String?, _ b: String) -> Bool {
    guard let a = a else { return false }
    return DshWorkspaceStore.canonical(a) == DshWorkspaceStore.canonical(b)
}
test("dsh was asked to register it",
     waitUntil(3) { fake.workspaceCreates.contains { samePath($0["path"] as? String, root + "/gamma") } })
test("the new workspace appears in the list", waitUntil(3) { panel.workspaces.count == 3 })

// An existing directory (created in Finder) is adopted, not complained about.
try! fm.createDirectory(atPath: root + "/delta", withIntermediateDirectories: true)
test("an existing directory is accepted", panel.createWorkspace(named: "delta") == true)
test("an existing directory says so instead of failing",
     waitUntil(2) { labels(panel.view).contains { $0 == "projects.nameExists" } })

// MARK: - A server that cannot serve the verb

fake.rejectWorkspaceCreate = true
try! fm.createDirectory(atPath: root + "/epsilon", withIntermediateDirectories: true)
test("registering without a server still succeeds locally",
     panel.createWorkspace(named: "epsilon") == true)
test("the pending registration is reported",
     waitUntil(3) { labels(panel.view).contains { $0 == "projects.registerPending" } })
test("the directory stays on disk after a rejected registration",
     fm.fileExists(atPath: root + "/epsilon"))
fake.rejectWorkspaceCreate = false

// MARK: - Card wiring (the quick entries and the two workspace actions)

panel.reload()
_ = waitUntil(3) { cards(panel.view).count >= 2 }
let alphaCard = cards(panel.view).first { $0.workspace.name == "alpha" }
test("the alpha card is rendered", alphaCard != nil)
alphaCard?.onPanel?(.terminal)
test("a quick entry hands the workspace path and the target panel to the shell",
     opened.count == 1 && opened.first?.path == alphaPath && opened.first?.target == .terminal)
alphaCard?.onPanel?(.review)
test("every quick entry target is forwarded", opened.last?.target == .review)
alphaCard?.onNewSession?()
test("new session hands the workspace path to the shell",
     newSessions == [alphaPath])
alphaCard?.onOpen?()
test("clicking the card asks the shell to open the workspace in dsh", entered == [alphaPath])

// The current workspace (ProjectDirectory) marks exactly one card.
test("the current workspace is the one flagged on the card",
     alphaCard?.isCurrentWorkspace == true)
let betaCard = cards(panel.view).first { $0.workspace.name == "beta" }
test("the other card is not flagged", betaCard?.isCurrentWorkspace == false)

// MARK: - The root follows the setting

let otherRoot = home + "/other-projects"
try! fm.createDirectory(atPath: otherRoot + "/only", withIntermediateDirectories: true)
ShellConfig.shared.set(otherRoot, forKey: ProjectsCore.configKey)
unsetenv("DSH_PROJECTS_TEST_ROOT")
panel.reload()
test("changing the root re-lists from the new root",
     waitUntil(3) { panel.workspaces.map(\.name) == ["only"] })
test("the root line follows", samePath(panel.rootPath, otherRoot))

// Removing the setting falls back to the default root under DSH_HOME.
ShellConfig.shared.removeObject(forKey: ProjectsCore.configKey)
panel.reload()
test("the default root is <DSH_HOME>/oh-my-dsh/projects",
     waitUntil(3) { panel.rootPath == ProjectsCore.defaultRoot(dshHome: home) })
test("a missing default root lists nothing and is not created",
     waitUntil(3) { panel.workspaces.isEmpty }
        && !fm.fileExists(atPath: ProjectsCore.defaultRoot(dshHome: home)))
test("the empty state is offered when there is no workspace",
     waitUntil(2) { panel.isEmptyStateVisible })
test("a missing root is reported in the panel",
     waitUntil(2) { labels(panel.view).contains { $0.hasPrefix("projects.rootMissing") } })

// MARK: - Cleanup

try? fm.removeItem(atPath: home)
print(failures == 0 ? "projects panel tests passed" : "projects panel tests FAILED (\(failures))")
exit(failures == 0 ? 0 : 1)
