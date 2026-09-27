// TasksAPI.swift — 任务面板的 localhost REST API（Agent / 用户 curl 驱动）。
//
// 与浏览器面板共用同一个壳层 HTTP 服务（BrowserAPIServer，127.0.0.1，端口见
// $DSH_HOME/shell-api.port 与 browser-api.port），按前缀分工：/api/browser/* 归
// 浏览器面板，/api/tasks/* 归任务面板。
//
// 设计：docs/task-todo-skill-design.md。配套技能 task-todo 在用户明确要求时
// 把沟通结论批量写进任务面板。
//
// 本文件只放**纯模型**（路由 + 请求解析 + 工作区解析 + 响应形状），不含 AppKit、
// 不碰磁盘：无头测试直接编译本文件 + BrowserAPI.swift（HTTPRequest/Response 所在）
// 加一个假 delegate 即可（tests/tasks-panel/api-tests.swift）。

import Foundation

// MARK: - 委派协议（任务面板控制器实现）

/// 一条由 API 提交的任务草稿：标题必填，描述可选（空则回退为标题，与面板内
/// 单行新建同语义 —— TaskDraft.effectiveBody）。
struct TaskCreateDraft: Equatable {
    let title: String
    let body: String?
}

/// 任务面板 API 的实现方（IssueRunnerPanelController）。
///
/// 两个方法都在**主线程**上被调用：board 的读改写必须与面板的 step 定时器同一条
/// 线程，否则两个写者会互相覆盖。桥接层负责派发到主线程。
protocol TasksAPIDelegate: AnyObject {
    /// 面板/工作区当前的任务与队列快照。workspace 为 nil 表示面板当前 board。
    func apiTaskList(workspace: String?) -> [String: Any]
    /// 批量创建手动任务（待处理、未入队）。focus 为真时切到该工作区并展开面板。
    func apiTaskCreate(workspace: String?, focus: Bool, drafts: [TaskCreateDraft]) -> [String: Any]
}

// MARK: - 工作区解析（纯函数）

enum TasksAPIWorkspace {

    /// 请求里的工作区路径归一化：去空白、展开 ~、标准化（不解析符号链接，也不
    /// 要求存在 —— 存在性由面板判）。
    static func normalize(_ path: String?) -> String? {
        guard let raw = path?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }

    /// 把请求里的工作区解析成面板真正要写的 board 根。
    ///
    /// Agent 的 cwd 是**会话工作区**，但可能落在子目录（pwd ≠ workspace 根），
    /// 所以先精确匹配、再找最近祖先：
    ///   1. 与候选（面板当前 board + 已跟踪 board）完全一致 → 用它；
    ///   2. 候选里是它祖先的、最深的那个 → 用它（cwd 在 workspace 子目录里的常态）；
    ///   3. 都不匹配 → 原样返回请求路径（调用方判它是不是存在的目录）。
    /// 没传 workspace 时返回 nil（调用方回落到面板当前 board）。
    static func resolve(requested: String?, candidates: [String]) -> String? {
        guard let path = normalize(requested) else { return nil }
        let normalized = candidates.compactMap { normalize($0) }
        if normalized.contains(path) { return path }
        let ancestors = normalized.filter { isAncestor($0, of: path) }
        if let deepest = ancestors.max(by: { $0.count < $1.count }) { return deepest }
        return path
    }

    /// parent 是 path 的祖先目录（或相等）时为真。逐段比较，避免 "/a/bc" 被
    /// "/a/b" 误判为祖先。
    static func isAncestor(_ parent: String, of path: String) -> Bool {
        if parent == path { return true }
        let base = parent.hasSuffix("/") ? String(parent.dropLast()) : parent
        guard !base.isEmpty else { return false }
        return path.hasPrefix(base + "/")
    }
}

// MARK: - 路由（纯模型，可单测）

enum TasksAPIRouter {

    /// 一次请求最多创建多少条任务：批量是常态（沟通结论一次落盘），但面板不是
    /// 批量导入工具，超过就退化成误操作噪音。
    static let maxTasksPerCall = 50

    /// 请求解析结果。rejected 是解析阶段就否掉的那些（标题空、不是对象、超过
    /// 上限），面板侧的失败（如工作区不存在）另算，路由最后合并成一份。
    struct ParsedCreate {
        var workspace: String?
        var focus: Bool = true
        var drafts: [TaskCreateDraft] = []
        var rejected: [[String: Any]] = []
        /// 请求体里到底有没有 tasks 键（区分 missing-tasks 与 no-tasks）。
        var tasksProvided: Bool = false
    }

    /// 命中 /api/tasks/* 时返回响应；不是本面板的路径返回 nil（调用方继续走原
    /// 来的路由 —— 任务面板不吞浏览器面板的端点，也不吞 404）。
    static func route(_ request: HTTPRequest, delegate: TasksAPIDelegate?) -> HTTPResponse? {
        switch (request.method, request.path) {

        case ("GET", "/api/tasks/list"):
            guard let delegate = delegate else { return unavailable() }
            let result = delegate.apiTaskList(workspace: request.query["workspace"])
            return .json((result["ok"] as? Bool) == true ? 200 : 400, result)

        case ("POST", "/api/tasks/create"):
            guard let body = request.jsonBody() else {
                return .json(400, ["ok": false,
                                   "error": "missing-body",
                                   "hint": "expected a JSON object like {\"tasks\": [\"标题\", {\"title\": \"标题\", \"body\": \"描述\"}]}"])
            }
            let parsed = parseCreate(body)
            guard !parsed.drafts.isEmpty else {
                // 两种空：请求里根本没有 tasks（调用方写错了），与有 tasks 但没有
                // 一条能用（全都空标题）。错误码区分开，Agent 一眼知道改哪儿。
                return .json(400, ["ok": false,
                                   "error": parsed.tasksProvided ? "no-tasks" : "missing-tasks",
                                   "rejected": parsed.rejected])
            }
            guard let delegate = delegate else { return unavailable() }
            var result = delegate.apiTaskCreate(workspace: parsed.workspace,
                                                focus: parsed.focus,
                                                drafts: parsed.drafts)
            // 解析阶段否掉的与面板阶段否掉的合成一份，调用方只看 rejected 即可。
            let panelRejected = result["rejected"] as? [[String: Any]] ?? []
            result["rejected"] = parsed.rejected + panelRejected
            if result["ok"] == nil {
                result["ok"] = !((result["created"] as? [Any]) ?? []).isEmpty
            }
            return .json((result["ok"] as? Bool) == true ? 200 : 400, result)

        default:
            return nil
        }
    }

    static func unavailable() -> HTTPResponse {
        .json(503, ["ok": false,
                    "error": "panel-unavailable",
                    "hint": "oh-my-dsh is not serving the tasks API (is the app running?)"])
    }

    /// 解析 create 请求体（纯函数）。
    ///
    /// tasks 每项支持两种写法：
    ///   "标题"                                —— 只有标题，描述回退为标题
    ///   {"title": "…", "body": "…"}           —— 推荐：描述就是给下一棒的执行说明
    static func parseCreate(_ body: [String: Any]) -> ParsedCreate {
        var parsed = ParsedCreate()
        parsed.workspace = TasksAPIWorkspace.normalize(body["workspace"] as? String)
        parsed.focus = (body["focus"] as? Bool) ?? true

        guard let raw = body["tasks"] as? [Any] else {
            parsed.rejected.append(["title": "", "error": "missing-tasks"])
            return parsed
        }
        parsed.tasksProvided = true

        for element in raw {
            var rawTitle: String?
            var rawBody: String?
            switch element {
            case let text as String:
                rawTitle = text
            case let dict as [String: Any]:
                rawTitle = dict["title"] as? String
                rawBody = dict["body"] as? String
            default:
                parsed.rejected.append(["title": "", "error": "not-an-object"])
                continue
            }

            let title = (rawTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                parsed.rejected.append(["title": rawTitle ?? "", "error": "empty-title"])
                continue
            }
            guard parsed.drafts.count < maxTasksPerCall else {
                parsed.rejected.append(["title": title, "error": "too-many"])
                continue
            }
            let body = rawBody?.trimmingCharacters(in: .whitespacesAndNewlines)
            parsed.drafts.append(TaskCreateDraft(title: title,
                                                 body: (body?.isEmpty ?? true) ? nil : body))
        }
        return parsed
    }

    // MARK: 响应里的一条任务 / 一个队列（形状单点定义）

    static func taskDictionary(_ task: TaskItem, queueName: String?) -> [String: Any] {
        var d: [String: Any] = [
            "id": task.id,
            "title": task.title,
            "state": task.state.rawValue,
            "source": task.source.rawValue,
        ]
        if let body = task.body, !body.isEmpty { d["body"] = body }
        if let queueId = task.queueId { d["queueId"] = queueId }
        if let queueName = queueName { d["queueName"] = queueName }
        if let number = task.number { d["issue"] = number }
        if let branch = task.branch { d["branch"] = branch }
        if let error = task.error { d["error"] = error }
        return d
    }

    static func queueDictionary(_ queue: TaskQueue) -> [String: Any] {
        var d: [String: Any] = ["id": queue.id,
                                "name": queue.name,
                                "state": queue.state.rawValue,
                                "tasks": queue.taskIds.count]
        if let branch = queue.branch { d["branch"] = branch }
        if !queue.autoCreated { d["userQueue"] = true }
        return d
    }
}

