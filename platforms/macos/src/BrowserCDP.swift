// BrowserCDP.swift — Chrome DevTools Protocol 客户端（浏览器面板的
// console/网络/eval/截图通道）。
//
// 每个标签页一个 CDPClient：从 http://127.0.0.1:<cdpPort>/json 取页面 target
// 的 webSocketDebuggerUrl 直连（CEF 151 验证过 flat/session 模式命令不响应，
// 直连页面 ws 最可靠）。事件（Runtime.consoleAPICalled / exceptionThrown /
// Network.* / Log.entryAdded）经 delegate 写入标签页日志缓冲；命令
// Runtime.evaluate / Page.captureScreenshot。

import Foundation
import Network

/// CDP 事件回调（主队列派发）。
protocol BrowserCDPDelegate: AnyObject {
    func cdpEvent(level: String, text: String)
}

/// 一个页面 target 的 CDP 连接。
final class BrowserCDPClient {
    enum Error: Swift.Error {
        case invalidURL, disconnected, timedOut
    }

    weak var delegate: BrowserCDPDelegate?

    /// 连接的页面 ws 地址（DevTools 前端拼接用）。
    private(set) var webSocketURL: String?

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "oh-my-dsh.browser-cdp")
    private var nextId = 1
    private var pending: [Int: (Result<[String: Any], Swift.Error>) -> Void] = [:]
    /// Network 事件按 requestId 关联：requestId → (method, url)
    private var networkRequests: [String: (method: String, url: String)] = [:]
    private var started = false

    /// 连接一个页面 ws（如 ws://127.0.0.1:9333/devtools/page/<id>）。
    func connect(webSocketURL: String) {
        guard let url = URL(string: webSocketURL), url.scheme == "ws" else { return }
        self.webSocketURL = webSocketURL
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback

        let conn = NWConnection(to: .url(url), using: params)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.onReady()
            }
        }
        conn.start(queue: queue)
        started = true
    }

    func disconnect() {
        started = false
        connection?.cancel()
        connection = nil
        pending.removeAll()
        networkRequests.removeAll()
    }

    private func onReady() {
        receiveLoop()
        // 订阅事件域
        let domains = [
            "Runtime.enable",
            "Log.enable",
            "Network.enable",
            "Page.enable",
        ]
        for method in domains {
            sendRaw(method: method, params: [:]) { _ in }
        }
    }

    private func receiveLoop() {
        connection?.receiveMessage { [weak self] data, context, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.handleMessage(data)
            }
            if self.started, error == nil {
                self.receiveLoop()
            }
        }
    }

    private func handleMessage(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = obj["id"] as? Int {
            // 命令响应
            let callback = pending.removeValue(forKey: id)
            if obj["error"] != nil {
                callback?(.failure(Error.disconnected))
            } else {
                callback?(.success(obj))
            }
            return
        }
        guard let method = obj["method"] as? String,
              let params = obj["params"] as? [String: Any] else { return }
        handleEvent(method: method, params: params)
    }

    private func handleEvent(method: String, params: [String: Any]) {
        let text: String
        let level: String
        switch method {
        case "Runtime.consoleAPICalled":
            let type = params["type"] as? String ?? "log"
            let args = (params["args"] as? [[String: Any]]) ?? []
            let parts = args.map { arg -> String in
                if let value = arg["value"] {
                    if let s = value as? String { return s }
                    if let data = try? JSONSerialization.data(withJSONObject: value) {
                        return String(data: data, encoding: .utf8) ?? String(describing: value)
                    }
                    return String(describing: value)
                }
                if let desc = arg["description"] as? String { return desc }
                return ""
            }
            text = parts.joined(separator: " ")
            level = type

        case "Runtime.exceptionThrown":
            let details = params["exceptionDetails"] as? [String: Any] ?? [:]
            let exc = details["exception"] as? [String: Any]
            let desc = (details["text"] as? String) ?? (exc?["description"] as? String) ?? "exception"
            let url = (details["url"] as? String) ?? ""
            let line = details["lineNumber"] as? Int ?? 0
            text = "\(desc) @ \(url):\(line + 1)"
            level = "error"

        case "Network.requestWillBeSent":
            let request = params["request"] as? [String: Any] ?? [:]
            let requestId = params["requestId"] as? String ?? ""
            let method = request["method"] as? String ?? ""
            let url = request["url"] as? String ?? ""
            networkRequests[requestId] = (method, url)
            return  // 等 responseReceived/loadingFailed 再落一条

        case "Network.responseReceived":
            let requestId = params["requestId"] as? String ?? ""
            let response = params["response"] as? [String: Any] ?? [:]
            let status = response["status"] as? Int ?? 0
            let url = (networkRequests[requestId]?.url) ?? (response["url"] as? String ?? "")
            let method = networkRequests[requestId]?.method ?? ""
            text = "\(status >= 400 ? "FAIL" : "OK") \(status) \(method) \(url)"
            level = "network"
            networkRequests.removeValue(forKey: requestId)

        case "Network.loadingFailed":
            let requestId = params["requestId"] as? String ?? ""
            let err = params["errorText"] as? String ?? "failed"
            let url = networkRequests[requestId]?.url ?? ""
            text = "ERR \(url) (\(err))"
            level = "network"
            networkRequests.removeValue(forKey: requestId)

        case "Log.entryAdded":
            let entry = params["entry"] as? [String: Any] ?? [:]
            text = entry["text"] as? String ?? ""
            level = entry["level"] as? String ?? "log"

        default:
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.cdpEvent(level: level, text: text)
        }
    }

    // MARK: 命令

    private func sendRaw(method: String, params: [String: Any],
                         completion: @escaping (Result<[String: Any], Swift.Error>) -> Void) {
        guard let connection = connection else {
            completion(.failure(Error.disconnected))
            return
        }
        let id = nextId
        nextId += 1
        pending[id] = completion
        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            pending.removeValue(forKey: id)
            completion(.failure(Error.invalidURL))
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "cdp", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in })
    }

    /// 同步执行 CDP 命令（自带超时；在非主队列调用）。
    func command(method: String, params: [String: Any] = [:], timeout: TimeInterval = 8) -> Result<[String: Any], Swift.Error> {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[String: Any], Swift.Error> = .failure(Error.timedOut)
        queue.async { [weak self] in
            guard let self = self else {
                semaphore.signal()
                return
            }
            self.sendRaw(method: method, params: params) { r in
                result = r
                semaphore.signal()
            }
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        return result
    }

    /// 执行 JS 求值（阻塞直至结果，适合 REST API 场景）。
    func evaluate(expression: String) -> Result<Any, Swift.Error> {
        let result = command(method: "Runtime.evaluate",
                             params: ["expression": expression, "returnByValue": true])
        switch result {
        case .success(let obj):
            // 响应形如 {result: {result: {type,value}, exceptionDetails}} —— 两层 result。
            guard let envelope = obj["result"] as? [String: Any] else {
                return .failure(NSError(domain: "BrowserCDP", code: 2,
                                        userInfo: [NSLocalizedDescriptionKey: "malformed response"]))
            }
            if let exc = envelope["exceptionDetails"] as? [String: Any] {
                let text = (exc["text"] as? String) ?? "exception"
                return .failure(NSError(domain: "BrowserCDP", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: text]))
            }
            if let evalResult = envelope["result"] as? [String: Any],
               let value = evalResult["value"] {
                return .success(value)
            }
            return .success(NSNull())
        case .failure(let error):
            return .failure(error)
        }
    }

    /// 截图（PNG Data）。
    func screenshot() -> Result<Data, Swift.Error> {
        let result = command(method: "Page.captureScreenshot", params: ["format": "png"])
        switch result {
        case .success(let obj):
            guard let base64 = (obj["result"] as? [String: Any])?["data"] as? String,
                  let data = Data(base64Encoded: base64) else {
                return .failure(Error.invalidURL)
            }
            return .success(data)
        case .failure(let error):
            return .failure(error)
        }
    }
}

// MARK: - CDP 端口 / target 发现

enum BrowserCDP {
    /// 有效 CDP 端口：DSH_CDP_PORT 覆盖，默认 9333（与 CEFShim 初始化一致）。
    static var port: Int {
        ProcessInfo.processInfo.environment["DSH_CDP_PORT"].flatMap { Int($0) } ?? 9333
    }

    /// 列出页面 target（不含 about:devtools 等内部页）。异步：后台拉取
    /// http://127.0.0.1:<port>/json（带 3s 超时），完成后主队列回调。
    /// 注意：绝不能在主线程同步拉取——CDP 响应依赖主线程驱动 CEF 消息泵，
    /// 同步等待会与主线程互相死锁（曾导致 API/UI 全挂）。
    static func pageTargets(completion: @escaping ([[String: Any]]) -> Void) {
        DispatchQueue.global().async {
            var list: [[String: Any]] = []
            if let url = URL(string: "http://127.0.0.1:\(port)/json") {
                var request = URLRequest(url: url)
                request.timeoutInterval = 3
                let semaphore = DispatchSemaphore(value: 0)
                URLSession.shared.dataTask(with: request) { data, _, _ in
                    if let data = data,
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                        list = obj
                    }
                    semaphore.signal()
                }.resume()
                _ = semaphore.wait(timeout: .now() + 4)
            }
            DispatchQueue.main.async { completion(list) }
        }
    }

    /// 找一个未被占用的页面 target（异步，见 pageTargets）。
    static func findUnclaimedTarget(claimed: Set<String>, completion: @escaping ([String: Any]?) -> Void) {
        pageTargets { list in
            completion(list.first { target in
                guard let id = target["id"] as? String else { return false }
                return !claimed.contains(id)
            })
        }
    }
}
