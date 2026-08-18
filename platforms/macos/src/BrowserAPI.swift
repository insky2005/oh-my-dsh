// BrowserAPI.swift — 浏览器面板的 localhost REST API（Agent / 用户 curl 驱动）。
//
// 极简 HTTP/1.1 服务（POSIX socket，127.0.0.1 绑定，默认端口 3081，
// DSH_BROWSER_PORT 覆盖，占用自动递增）。路由面在 WKWebView 回退方案下与
// 原 CEF 方案保持一致（仅不提供 /cdp）。无鉴权：仅本机用户可连，与 dsh web
// 3080 同一信任模型。
//
// 可单测的纯模型（HTTPRequest / BrowserAPIRouter / BrowserLogBuffer /
// BrowserURL）与 I/O 分离，无头测试直接编译本文件 + BrowserPanel.swift。

import Foundation

// MARK: - HTTP 请求解析（纯模型，可单测）

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    /// 解析 HTTP/1.1 请求（请求行 + 头 + 可选 Content-Length 体）。
    /// 畸形输入返回 nil（服务端回 400）。
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data.subdata(in: data.startIndex..<headerEnd.lowerBound)
        let body = data.subdata(in: headerEnd.upperBound..<data.endIndex)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // path?query 拆分
        let path: String
        let query: [String: String]
        if let qIndex = target.firstIndex(of: "?") {
            path = String(target[..<qIndex])
            query = Self.parseQuery(String(target[target.index(after: qIndex)...]))
        } else {
            path = target
            query = [:]
        }
        return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
    }

    private static func parseQuery(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            result[key] = value
        }
        return result
    }

    func jsonBody() -> [String: Any]? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return obj
    }
}

// MARK: - 响应

struct HTTPResponse {
    let status: Int
    let contentType: String
    let body: Data

    static func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func png(_ data: Data) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "image/png", body: data)
    }
}

// MARK: - 面板委托（由 BrowserAPIBridge 实现，桥接到面板控制器 + 壳层）

protocol BrowserAPIDelegate: AnyObject {
    var apiPanelVisible: Bool { get }
    func apiShowPanel()
    func apiHidePanel()
    func apiStatus() -> [String: Any]
    /// 返回 [String: Any]：{ok, tabId?} 或 {ok:false, error}
    func apiOpenURL(_ url: String, tab: String?) -> [String: Any]
    func apiTabAction(_ action: String, tabId: Int64?) -> [String: Any]
    func apiNavigate(_ action: String, tabId: Int64?) -> [String: Any]
    /// 同步阻塞直至求值完成（内部经主线程 + 信号量），带超时。
    func apiEval(_ expression: String) -> [String: Any]
    func apiConsole(level: String?, limit: Int?) -> [String: Any]
    func apiClearConsole()
    /// 同步阻塞直至截图完成，带超时；失败返回 nil。
    func apiScreenshot() -> Data?
}

// MARK: - 路由（纯模型，可单测）

enum BrowserAPIRouter {
    static func route(_ request: HTTPRequest, delegate: BrowserAPIDelegate) -> HTTPResponse {
        // CORS 预检
        if request.method == "OPTIONS" {
            return HTTPResponse(status: 204, contentType: "text/plain", body: Data())
        }

        switch (request.method, request.path) {
        case ("GET", "/api/browser/status"):
            return .json(200, delegate.apiStatus())

        case ("POST", "/api/browser/open"):
            let body = request.jsonBody() ?? [:]
            let url = (body["url"] as? String) ?? request.query["url"] ?? ""
            let tab = body["tab"] as? String
            guard !url.isEmpty else { return .json(400, ["ok": false, "error": "missing url"]) }
            let show = (body["show"] as? Bool) ?? true
            if show { delegate.apiShowPanel() }
            let result = delegate.apiOpenURL(url, tab: tab)
            let status = (result["ok"] as? Bool) == true ? 200 : 400
            return .json(status, result)

        case ("POST", "/api/browser/tabs"):
            let body = request.jsonBody() ?? [:]
            let action = (body["action"] as? String) ?? ""
            let tabId = (body["tabId"] as? NSNumber)?.int64Value
            let result = delegate.apiTabAction(action, tabId: tabId)
            return .json((result["ok"] as? Bool) == true ? 200 : 400, result)

        case ("POST", "/api/browser/back"),
             ("POST", "/api/browser/forward"),
             ("POST", "/api/browser/reload"),
             ("POST", "/api/browser/stop"):
            let action = request.path.split(separator: "/").last.map(String.init) ?? ""
            let body = request.jsonBody() ?? [:]
            let tabId = (body["tabId"] as? NSNumber)?.int64Value
            let result = delegate.apiNavigate(action, tabId: tabId)
            return .json((result["ok"] as? Bool) == true ? 200 : 400, result)

        case ("POST", "/api/browser/eval"):
            let body = request.jsonBody() ?? [:]
            let expression = (body["expression"] as? String) ?? ""
            guard !expression.isEmpty else { return .json(400, ["ok": false, "error": "missing expression"]) }
            return .json(200, delegate.apiEval(expression))

        case ("GET", "/api/browser/console"):
            let level = request.query["level"]
            let limit = request.query["limit"].flatMap { Int($0) }
            return .json(200, delegate.apiConsole(level: level, limit: limit))

        case ("POST", "/api/browser/console/clear"):
            delegate.apiClearConsole()
            return .json(200, ["ok": true])

        case ("GET", "/api/browser/screenshot"):
            if let png = delegate.apiScreenshot() {
                return .png(png)
            }
            return .json(500, ["ok": false, "error": "screenshot failed"])

        case ("POST", "/api/browser/hide"):
            delegate.apiHidePanel()
            return .json(200, ["ok": true])

        default:
            return .json(404, ["ok": false, "error": "not found"])
        }
    }

    /// 统一加 CORS 头（localStorage 之外，页面内 fetch 跨域也放行）。
    static func withCORS(_ response: HTTPResponse) -> [String: String] {
        [
            "Content-Type": response.contentType,
            "Content-Length": "\(response.body.count)",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
            "Access-Control-Max-Age": "86400",
            "Connection": "close",
        ]
    }
}

// MARK: - 委托适配（面板控制器 → API 协议）

/// 把 BrowserPanelController + 壳层显隐桥接成 BrowserAPIDelegate。
/// 异步操作（eval/screenshot）经主线程派发 + 信号量同步等待（带超时）。
final class BrowserAPIBridge: BrowserAPIDelegate {
    weak var panel: BrowserPanelController?
    var showPanel: () -> Void = {}
    var hidePanel: () -> Void = {}
    var isPanelVisible: () -> Bool = { false }

    var apiPanelVisible: Bool { isPanelVisible() }

    func apiShowPanel() {
        DispatchQueue.main.async { [weak self] in self?.showPanel() }
    }

    func apiHidePanel() {
        DispatchQueue.main.async { [weak self] in self?.hidePanel() }
    }

    func apiStatus() -> [String: Any] {
        var snapshot: [String: Any] = ["panelVisible": apiPanelVisible, "tabs": [], "activeTabId": 0]
        DispatchQueue.main.sync { [weak self] in
            snapshot = self?.panel?.statusSnapshot() ?? snapshot
        }
        return snapshot
    }

    func apiOpenURL(_ url: String, tab: String?) -> [String: Any] {
        var result: [String: Any] = ["ok": false, "error": "no panel"]
        DispatchQueue.main.sync { [weak self] in
            guard let panel = self?.panel else { return }
            if let tabId = panel.openURL(url, tab: tab) {
                result = ["ok": true, "tabId": tabId]
            } else {
                result = ["ok": false, "error": "invalid url"]
            }
        }
        return result
    }

    func apiTabAction(_ action: String, tabId: Int64?) -> [String: Any] {
        var result: [String: Any] = ["ok": false, "error": "unknown action"]
        DispatchQueue.main.sync { [weak self] in
            guard let panel = self?.panel else { return }
            switch action {
            case "new":
                let tab = panel.newTab(url: nil)
                result = ["ok": true, "tabId": tab.id]
            case "close":
                if let tabId = tabId, let tab = panel.tab(withId: tabId) {
                    panel.closeTab(tab)
                    result = ["ok": true]
                } else {
                    result = ["ok": false, "error": "no such tab"]
                }
            case "activate":
                if let tabId = tabId, let tab = panel.tab(withId: tabId) {
                    panel.selectTab(tab)
                    result = ["ok": true]
                } else {
                    result = ["ok": false, "error": "no such tab"]
                }
            default:
                result = ["ok": false, "error": "unknown action: \(action)"]
            }
        }
        return result
    }

    func apiNavigate(_ action: String, tabId: Int64?) -> [String: Any] {
        var result: [String: Any] = ["ok": false, "error": "no panel"]
        DispatchQueue.main.sync { [weak self] in
            guard let panel = self?.panel else { return }
            let target = tabId.flatMap { panel.tab(withId: $0) } ?? panel.activeTab
            guard let tab = target else {
                result = ["ok": false, "error": "no tab"]
                return
            }
            switch action {
            case "back": CEFShim.goBack(tab.browserId)
            case "forward": CEFShim.goForward(tab.browserId)
            case "reload": CEFShim.reload(tab.browserId)
            case "stop": CEFShim.stop(tab.browserId)
            default:
                result = ["ok": false, "error": "unknown action: \(action)"]
                return
            }
            result = ["ok": true]
        }
        return result
    }

    func apiEval(_ expression: String) -> [String: Any] {
        var result: [String: Any] = ["ok": false, "error": "timeout"]
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { [weak self] in
            guard let panel = self?.panel else {
                result = ["ok": false, "error": "no panel"]
                semaphore.signal()
                return
            }
            panel.evaluate(expression: expression) { evalResult in
                switch evalResult {
                case .success(let value):
                    result = ["ok": true, "result": value ?? NSNull()]
                case .failure(let error):
                    result = ["ok": false, "error": (error as NSError).localizedDescription]
                }
                semaphore.signal()
            }
        }
        _ = semaphore.wait(timeout: .now() + 10)
        return result
    }

    func apiConsole(level: String?, limit: Int?) -> [String: Any] {
        var entries: [[String: Any]] = []
        DispatchQueue.main.sync { [weak self] in
            guard let tab = self?.panel?.activeTab else { return }
            entries = tab.logBuffer.entries(level: level, limit: limit).map {
                ["ts": $0.timestamp, "level": $0.level, "text": $0.text]
            }
        }
        return ["ok": true, "entries": entries]
    }

    func apiClearConsole() {
        DispatchQueue.main.async { [weak self] in
            self?.panel?.activeTab?.logBuffer.clear()
        }
    }

    func apiScreenshot() -> Data? {
        var png: Data?
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { [weak self] in
            self?.panel?.screenshot { data in
                png = data
                semaphore.signal()
            }
        }
        _ = semaphore.wait(timeout: .now() + 10)
        return png
    }
}

// MARK: - HTTP 服务（POSIX socket）

final class BrowserAPIServer {
    private var listenerFD: Int32 = -1
    private var running = false
    /// 并发队列：accept 循环占一个执行槽，各连接处理并行执行
    /// （串行队列会让 acceptLoop 永远阻塞，handler 排不上队）。
    private let queue = DispatchQueue(label: "oh-my-dsh.browser-api", attributes: .concurrent)
    private weak var delegate: BrowserAPIDelegate?
    private(set) var port: Int = 0

    /// 启动监听；preferredPort 被占用时递增尝试（最多 +5）。
    /// 返回实际生效端口（0 = 启动失败）。写 port 文件便于 Agent/技能发现。
    @discardableResult
    func start(preferredPort: Int, delegate: BrowserAPIDelegate, portFile: String) -> Int {
        self.delegate = delegate
        for attempt in 0...5 {
            let candidate = preferredPort + attempt
            let fd = Self.listen(port: candidate)
            if fd >= 0 {
                listenerFD = fd
                port = candidate
                running = true
                writePortFile(port, to: portFile)
                queue.async { [weak self] in self?.acceptLoop() }
                return port
            }
        }
        return 0
    }

    func stop() {
        running = false
        if listenerFD >= 0 {
            close(listenerFD)
            listenerFD = -1
        }
    }

    // MARK: 监听 / 连接

    private static func listen(port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult != 0 || Darwin.listen(fd, 8) != 0 {
            close(fd)
            return -1
        }
        return fd
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(listenerFD, nil, nil)
            guard clientFD >= 0 else {
                if !running { break }
                continue
            }
            queue.async { [weak self] in self?.handle(clientFD: clientFD) }
        }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }
        guard let request = Self.readRequest(clientFD) else {
            Self.writeResponse(clientFD, status: 400, headers: [:], body: Data("bad request".utf8))
            return
        }
        guard let delegate = delegate else {
            Self.writeResponse(clientFD, status: 500, headers: [:], body: Data("no delegate".utf8))
            return
        }
        let response = BrowserAPIRouter.route(request, delegate: delegate)
        Self.writeResponse(clientFD, status: response.status,
                           headers: BrowserAPIRouter.withCORS(response), body: response.body)
    }

    /// 读请求：头（≤64KB）+ Content-Length 体，poll 5s 超时。
    private static func readRequest(_ fd: Int32) -> HTTPRequest? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, 200)
            if pr < 0 { return nil }
            if pr == 0 { continue }  // 超时继续（整体 5s 上限）
            // 注意：向 C API 传 Swift 数组缓冲区必须用 withUnsafeMutableBytes
            // （&array 传的是数组结构头，不是元素字节，见 docs/terminal-input-fix.md）。
            let n = chunk.withUnsafeMutableBytes { raw -> Int in
                read(fd, raw.baseAddress, raw.count)
            }
            if n > 0 {
                buffer.append(contentsOf: chunk.prefix(n))
                if buffer.count > 65536 { return nil }
                // 头部完整？
                if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let headerText = String(data: buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound), encoding: .utf8)
                    let contentLength = headerText?.split(separator: "\r\n")
                        .compactMap { line -> Int? in
                            let parts = line.split(separator: ":", maxSplits: 1)
                            guard parts.count == 2,
                                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length",
                                  let v = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
                            return v
                        }.first ?? 0
                    let bodyStart = headerEnd.upperBound
                    if buffer.count - bodyStart >= contentLength {
                        return HTTPRequest.parse(buffer)
                    }
                }
            } else if n == 0 {
                return nil
            } else {
                return nil
            }
        }
        return nil
    }

    private static func writeResponse(_ fd: Int32, status: Int, headers: [String: String], body: Data) {
        let reason = status == 200 ? "OK" : (status == 204 ? "No Content" : (status == 400 ? "Bad Request" : "Error"))
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (k, v) in headers {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        out.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < out.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), out.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    private func writePortFile(_ port: Int, to path: String) {
        do {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try "\(port)\n".write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            // 端口文件仅用于 Agent 发现，写失败不阻塞服务。
        }
    }
}
