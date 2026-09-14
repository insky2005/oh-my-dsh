import AppKit

// Headless regression tests for ReviewPanelController: the panel must not
// freeze on the first read of a session log.
//
// The bug this pins down: a *new* session was audited the moment it became the
// session dsh web was showing — i.e. while its log still held nothing but the
// header — and that empty result was cached by session id forever. The session
// row stayed visible ("0 文件") and no file ever appeared inside it, however
// much the agent changed afterwards. A session log is a live document, so the
// cache has to be keyed by the *log's identity*, not just its id.
//
// Everything here is driven through the fake CoreBridge: the panel is never
// told what to do, and the assertions are on what it asks for and renders.

var failures = 0
func test(_ name: String, _ cond: Bool) {
    print((cond ? "ok" : "FAIL") + " - " + name)
    if !cond { failures += 1 }
}

_ = NSApplication.shared

let root = NSTemporaryDirectory() + "/reviewpanel-" + UUID().uuidString
let workspace = root + "/ws"
let logDir = root + "/sessions/--ws--/session-aaaa1111-2222-3333-4444-555566667777"
let logPath = logDir + "/session.jsonl.zstd"
try! FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)

/// Bytes present when the panel first looked: the "empty, brand-new session".
try! Data(repeating: 0x28, count: 64).write(to: URL(fileURLWithPath: logPath))
let sizeAtFirstRead = (try! FileManager.default.attributesOfItem(atPath: logPath)[.size] as! NSNumber).doubleValue

let sessionId = "session-aaaa1111-2222-3333-4444-555566667777"

func sessionsJSON() -> String {
    let attributes = try! FileManager.default.attributesOfItem(atPath: logPath)
    let size = (attributes[.size] as! NSNumber).doubleValue
    let mtime = (attributes[.modificationDate] as! Date).timeIntervalSince1970 * 1000
    return """
    {"sessions":[{"id":"\(sessionId)","dir":"\(logDir)","file":"\(logPath)","cwd":"\(workspace)",
    "createdAt":1,"parentSession":null,"delegationDepth":0,"compressed":true,
    "sizeBytes":\(size),"mtimeMs":\(mtime)}],"total":1,"diagnostics":[]}
    """
}

/// The audit the fake CLI reports: empty while the log still holds only what it
/// held at first read, one changed file once it grew — i.e. exactly what dsh
/// would write as the conversation goes on.
func auditJSON() -> String {
    let size = (try! FileManager.default.attributesOfItem(atPath: logPath)[.size] as! NSNumber).doubleValue
    guard size > sizeAtFirstRead else {
        return """
        {"session":{"id":"\(sessionId)","cwd":"\(workspace)","createdAt":1,"parentSession":null,"delegationDepth":0},
        "turns":[],"entries":[],
        "stats":{"entries":0,"mutations":0,"files":0,"added":0,"removed":0,"nested":0,"bashCalls":0,"bashSuspect":0,"failed":0},
        "diagnostics":[]}
        """
    }
    return """
    {"session":{"id":"\(sessionId)","cwd":"\(workspace)","createdAt":1,"parentSession":null,"delegationDepth":0},
    "turns":[{"turn":1,"prompt":"改一下 a.txt","startedAt":2}],
    "entries":[{"seq":9,"order":0,"turn":1,"step":1,"tool":"edit","surface":"top","status":"ok","category":"diff",
    "path":"a.txt","pathAbs":"\(workspace)/a.txt","command":null,"suspicion":null,
    "hunks":[{"oldText":"one","newText":"two"}],"added":2,"removed":1,"note":"applied-hunks"}],
    "stats":{"entries":1,"mutations":1,"files":1,"added":2,"removed":1,"nested":0,"bashCalls":0,"bashSuspect":0,"failed":0},
    "diagnostics":[]}
    """
}

CoreBridge.handler = { args in
    guard args.first == "review" else { return nil }
    switch args.count > 1 ? args[1] : "" {
    case "sessions": return sessionsJSON()
    case "audit": return auditJSON()
    default: return nil
    }
}

let panel = ReviewPanelController()
panel.workspacePath = { workspace }
panel.portProvider = { 0 }        // no dsh web: the panel falls back to short ids
panel.auditPollInterval = 0.05    // the live cadence is seconds; run it fast here

// The panel is on screen for the whole test — that is the situation being
// reproduced (the user watching the Review panel while the session runs). The
// follow-the-log tick only runs for a panel that is actually mounted, so an
// off-screen controller must not stand in for it.
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                      styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = panel.view
window.contentView?.layoutSubtreeIfNeeded()
test("panel is mounted (the tick only runs on screen)",
     panel.view.superview != nil && panel.view.window != nil && panel.view.frame.width > 1)

/// Every label currently in the tree (the panel's rendering is text fields).
func labels(_ view: NSView) -> [String] {
    var out: [String] = []
    if let field = view as? NSTextField { out.append(field.stringValue) }
    for sub in view.subviews { out.append(contentsOf: labels(sub)) }
    return out
}

/// Pump the main run loop until `predicate` holds or `seconds` elapse.
@discardableResult
func waitUntil(_ seconds: TimeInterval, _ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if predicate() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return predicate()
}

panel.ensureLoaded()

// 1. The brand-new session: listed, audited once, and honestly reported empty.
let sawSession = waitUntil(3) { labels(panel.view).contains { $0.contains("review.filesShort") } }
test("session row renders after the listing", sawSession)
// Wait for the read to land (the session row carries its stats only afterwards).
let firstReadLanded = waitUntil(3) { labels(panel.view).contains { $0.contains("0 review.filesShort") } }
test("first read of a brand-new session shows no files", firstReadLanded)
test("empty audit says so instead of showing nothing",
     labels(panel.view).contains { $0 == "review.empty" })
test("exactly one audit ran for the first read", CoreBridge.count("audit") == 1)

// 2. The conversation goes on: dsh appends to the log (new frames).
let handle = try! FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
handle.seekToEndOfFile()
handle.write(Data(repeating: 0x28, count: 4096))
try! handle.close()
test("fixture log grew", (try! FileManager.default.attributesOfItem(atPath: logPath)[.size] as! NSNumber).doubleValue > sizeAtFirstRead)

// The panel is on screen (mounted) and the tick is running: it must notice by
// itself — no reopen, no refresh button.
let sawFiles = waitUntil(5) { labels(panel.view).contains { $0.contains("1 review.filesShort") } }
test("growing log is re-read without any user action", CoreBridge.count("audit") == 2)
test("changed file appears in the tree", sawFiles)
test("the 对话 level shows the file",
     labels(panel.view).contains { $0.contains("review.turn 1") })
test("the file path is shown", labels(panel.view).contains { $0 == "a.txt" })
test("per-file line counts are shown", labels(panel.view).contains { $0 == "+2 −1" })

// 3. An unchanged log must NOT be re-read: one stat per tick, no CLI spawn.
RunLoop.main.run(until: Date().addingTimeInterval(0.6))
test("unchanged log is not re-audited", CoreBridge.count("audit") == 2)

print(failures == 0 ? "done" : "FAILED (\(failures))")
exit(failures == 0 ? 0 : 1)
