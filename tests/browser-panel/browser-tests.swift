// Headless unit tests for the Browser panel model layer (BrowserPanel.swift +
// BrowserAPI.swift). Compiled as main.swift together with stubs.swift.
// Covers: log buffer, URL normalization, HTTP request parsing, REST routing.

import AppKit
import Foundation

var failures = 0
var passed = 0

func check(_ cond: Bool, _ name: String, _ detail: String = "") {
    if cond {
        passed += 1
        print("PASS \(name)")
    } else {
        failures += 1
        print("FAIL \(name) \(detail)")
    }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ name: String) {
    check(a == b, name, "expected \(b), got \(a)")
}

// MARK: - BrowserLogBuffer

func testLogBuffer() {
    let buf = BrowserLogBuffer(maxEntries: 5)
    eq(buf.entries().count, 0, "log: starts empty")
    buf.append(level: "log", text: "a")
    buf.append(level: "error", text: "b")
    buf.append(level: "network", text: "c")
    eq(buf.entries().count, 3, "log: three entries")
    eq(buf.entries(level: "error").count, 1, "log: level filter")
    eq(buf.entries(level: "error").first?.text, "b", "log: filtered text")
    eq(buf.entries(limit: 2).count, 2, "log: limit")
    eq(buf.entries(limit: 2).last?.text, "c", "log: limit takes latest")
    for i in 0..<6 { buf.append(level: "log", text: "x\(i)") }
    eq(buf.entries().count, 5, "log: ring cap")
    eq(buf.entries().first?.text, "x1", "log: ring drops oldest")
    buf.clear()
    eq(buf.entries().count, 0, "log: clear")
}

// MARK: - BrowserURL.normalize

func testURLNormalize() {
    eq(BrowserURL.normalize("example.com"), "https://example.com", "url: bare domain gets https")
    eq(BrowserURL.normalize("https://example.com"), "https://example.com", "url: https kept")
    eq(BrowserURL.normalize("http://localhost:3000/"), "http://localhost:3000/", "url: http localhost kept")
    eq(BrowserURL.normalize("about:blank"), "about:blank", "url: about:blank kept")
    eq(BrowserURL.normalize("file:///tmp/x.html"), "file:///tmp/x.html", "url: file kept")
    eq(BrowserURL.normalize("data:text/html,<h1>hi</h1>"), "data:text/html,<h1>hi</h1>", "url: data kept")
    eq(BrowserURL.normalize("  example.com  "), "https://example.com", "url: trims whitespace")
    eq(BrowserURL.normalize(""), nil, "url: empty -> nil")
    eq(BrowserURL.normalize("   "), nil, "url: blank -> nil")
    eq(BrowserURL.normalize("not a url with spaces"), nil, "url: invalid -> nil")
}

// MARK: - HTTPRequest.parse

func testHTTPParse() {
    let get = "GET /api/browser/status?level=error&limit=10 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
    let req = HTTPRequest.parse(Data(get.utf8))
    check(req != nil, "http: parses GET")
    eq(req?.method, "GET", "http: method")
    eq(req?.path, "/api/browser/status", "http: path")
    eq(req?.query["level"], "error", "http: query level")
    eq(req?.query["limit"], "10", "http: query limit")
    eq(req?.headers["host"], "127.0.0.1", "http: header lowercase")

    let post = "POST /api/browser/open HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 27\r\n\r\n{\"url\":\"example.com\",\"tab\":\"new\"}"
    let req2 = HTTPRequest.parse(Data(post.utf8))
    check(req2 != nil, "http: parses POST")
    eq(req2?.method, "POST", "http: post method")
    eq(req2?.jsonBody()?["url"] as? String, "example.com", "http: json body url")
    eq(req2?.jsonBody()?["tab"] as? String, "new", "http: json body tab")

    check(HTTPRequest.parse(Data("garbage".utf8)) == nil, "http: malformed -> nil")
    check(HTTPRequest.parse(Data("GET / HTTP/1.1\r\n\r\n".utf8)) != nil, "http: minimal GET")
}

// MARK: - BrowserAPIRouter

final class FakeDelegate: BrowserAPIDelegate {
    var visible = false
    var statusCalled = 0
    var openURLs: [(String, String?)] = []
    var navigates: [String] = []
    var evals: [String] = []
    var clearCount = 0

    var apiPanelVisible: Bool { visible }
    func apiShowPanel() { visible = true }
    func apiHidePanel() { visible = false }
    func apiStatus() -> [String: Any] {
        statusCalled += 1
        return ["panelVisible": visible, "tabs": [], "activeTabId": 0]
    }
    func apiOpenURL(_ url: String, tab: String?) -> [String: Any] {
        openURLs.append((url, tab))
        return ["ok": true, "tabId": 7]
    }
    func apiTabAction(_ action: String, tabId: Int64?) -> [String: Any] { ["ok": true] }
    func apiNavigate(_ action: String, tabId: Int64?) -> [String: Any] {
        navigates.append(action)
        return ["ok": true]
    }
    func apiEval(_ expression: String) -> [String: Any] {
        evals.append(expression)
        return ["ok": true, "result": "hello"]
    }
    func apiConsole(level: String?, limit: Int?) -> [String: Any] {
        ["ok": true, "entries": []]
    }
    func apiClearConsole() { clearCount += 1 }
    func apiScreenshot() -> Data? { Data([0x89, 0x50, 0x4E, 0x47]) }
}

func testRouter() {
    let delegate = FakeDelegate()

    // OPTIONS 预检
    let opt = HTTPRequest.parse(Data("OPTIONS /api/browser/status HTTP/1.1\r\n\r\n".utf8))!
    let optResp = BrowserAPIRouter.route(opt, delegate: delegate)
    eq(optResp.status, 204, "router: OPTIONS -> 204")

    // status
    let statusReq = HTTPRequest.parse(Data("GET /api/browser/status HTTP/1.1\r\n\r\n".utf8))!
    let statusResp = BrowserAPIRouter.route(statusReq, delegate: delegate)
    eq(statusResp.status, 200, "router: status 200")
    eq(delegate.statusCalled, 1, "router: status dispatched")

    // open（POST body + 自动展开）
    let openReq = HTTPRequest.parse(Data("POST /api/browser/open HTTP/1.1\r\nContent-Length: 21\r\n\r\n{\"url\":\"example.com\"}".utf8))!
    let openResp = BrowserAPIRouter.route(openReq, delegate: delegate)
    eq(openResp.status, 200, "router: open 200")
    eq(delegate.visible, true, "router: open shows panel")
    eq(delegate.openURLs.first?.0, "example.com", "router: open url")
    eq(delegate.openURLs.first?.1, nil, "router: open default tab")

    // open with show:false 不展开
    let openHidden = HTTPRequest.parse(Data("POST /api/browser/open HTTP/1.1\r\nContent-Length: 38\r\n\r\n{\"url\":\"a.com\",\"show\":false}".utf8))!
    let d2 = FakeDelegate()
    _ = BrowserAPIRouter.route(openHidden, delegate: d2)
    eq(d2.visible, false, "router: open show:false keeps hidden")

    // 缺 url -> 400
    let openBad = HTTPRequest.parse(Data("POST /api/browser/open HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}".utf8))!
    eq(BrowserAPIRouter.route(openBad, delegate: delegate).status, 400, "router: open missing url 400")

    // 导航路由
    for action in ["back", "forward", "reload", "stop"] {
        let navReq = HTTPRequest.parse(Data("POST /api/browser/\(action) HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}".utf8))!
        let r = BrowserAPIRouter.route(navReq, delegate: delegate)
        eq(r.status, 200, "router: navigate \(action) 200")
    }
    eq(delegate.navigates, ["back", "forward", "reload", "stop"], "router: navigate actions")

    // eval
    let evalReq = HTTPRequest.parse(Data("POST /api/browser/eval HTTP/1.1\r\nContent-Length: 28\r\n\r\n{\"expression\":\"1+1\"}".utf8))!
    let evalResp = BrowserAPIRouter.route(evalReq, delegate: delegate)
    eq(evalResp.status, 200, "router: eval 200")
    eq(delegate.evals, ["1+1"], "router: eval expression")

    // console clear
    let clearReq = HTTPRequest.parse(Data("POST /api/browser/console/clear HTTP/1.1\r\n\r\n".utf8))!
    eq(BrowserAPIRouter.route(clearReq, delegate: delegate).status, 200, "router: clear 200")
    eq(delegate.clearCount, 1, "router: clear dispatched")

    // screenshot -> PNG content type
    let shotReq = HTTPRequest.parse(Data("GET /api/browser/screenshot HTTP/1.1\r\n\r\n".utf8))!
    let shotResp = BrowserAPIRouter.route(shotReq, delegate: delegate)
    eq(shotResp.status, 200, "router: screenshot 200")
    eq(shotResp.contentType, "image/png", "router: screenshot content type")
    eq(shotResp.body.count, 4, "router: screenshot body")

    // hide
    let hideReq = HTTPRequest.parse(Data("POST /api/browser/hide HTTP/1.1\r\n\r\n".utf8))!
    _ = BrowserAPIRouter.route(hideReq, delegate: delegate)
    eq(delegate.visible, false, "router: hide hides panel")

    // 404
    let nfReq = HTTPRequest.parse(Data("GET /api/browser/nope HTTP/1.1\r\n\r\n".utf8))!
    eq(BrowserAPIRouter.route(nfReq, delegate: delegate).status, 404, "router: unknown 404")

    // CORS 头
    let cors = BrowserAPIRouter.withCORS(statusResp)
    eq(cors["Access-Control-Allow-Origin"], "*", "router: CORS origin")
    eq(cors["Content-Type"], statusResp.contentType, "router: CORS content type")
}

testLogBuffer()
testURLNormalize()
testHTTPParse()
testRouter()

print("== browser panel tests: \(passed) passed, \(failures) failed")
if failures > 0 {
    exit(1)
}
