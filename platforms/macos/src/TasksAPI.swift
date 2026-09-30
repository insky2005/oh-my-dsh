// TasksAPI.swift — 任务面板的 localhost REST API（Agent / 用户 curl 驱动）。
//
// 与浏览器面板共用同一个壳层 HTTP 服务（BrowserAPIServer，127.0.0.1，端口见
// $DSH_HOME/oh-my-dsh/shell-api.port 与 browser-api.port），按前缀分工：/api/browser/* 归
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

/// POST /api/tasks/queue/create：一个「等待态」队列 + 加入它的任务。session 是发起
/// 请求的 dsh 会话 —— 队列到达 .done 时把完成情况回传给它（缺省不回传）。
struct TaskQueueCreateRequest: Equatable {
    var workspace: String?
    var session: String?
    var focus: Bool
    var name: String
    /// nil = 按队列名派生默认分支；"" = 完全不切分支。
    var branch: String?
    var baseBranch: String?
    /// nil = 按工作区能力决定（有 GitHub 远端才自动开 PR）。
    var autoPR: Bool?
    var drafts: [TaskCreateDraft]
}

/// POST /api/tasks/queue/start：按 id 启动，或在 id 缺省时启动「本会话创建的那个等待队列」。
struct TaskQueueStartRequest: Equatable {
    var workspace: String?
    var session: String?
    var queueId: String?
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
    /// 建一个「等待态」队列（.draft）并把任务批量入队；不启动任何东西。
    func apiTaskQueueCreate(_ request: TaskQueueCreateRequest) -> [String: Any]
    /// 启动一个队列（.draft / .paused → .active）；queueId 可缺省，按 session 定位。
    func apiTaskQueueStart(_ request: TaskQueueStartRequest) -> [String: Any]
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

    /// queue/create 的解析结果。
    struct ParsedQueueCreate {
        var workspace: String?
        var session: String?
        var focus: Bool = true
        var name: String = ""
        var branch: String?
        var baseBranch: String?
        var autoPR: Bool?
        var drafts: [TaskCreateDraft] = []
        var rejected: [[String: Any]] = []
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

        case ("POST", "/api/tasks/queue/create"):
            guard let body = request.jsonBody() else { return missingBody() }
            let parsed = parseQueueCreate(body)
            guard !parsed.drafts.isEmpty else {
                return .json(400, ["ok": false,
                                   "error": parsed.tasksProvided ? "no-tasks" : "missing-tasks",
                                   "rejected": parsed.rejected])
            }
            guard !parsed.name.isEmpty else {
                return .json(400, ["ok": false, "error": "missing-name",
                                   "hint": "give the queue a name, or at least one task whose title can name it"])
            }
            guard let delegate = delegate else { return unavailable() }
            var result = delegate.apiTaskQueueCreate(TaskQueueCreateRequest(
                workspace: parsed.workspace, session: parsed.session, focus: parsed.focus,
                name: parsed.name, branch: parsed.branch, baseBranch: parsed.baseBranch,
                autoPR: parsed.autoPR, drafts: parsed.drafts))
            let queueRejected = result["rejected"] as? [[String: Any]] ?? []
            result["rejected"] = parsed.rejected + queueRejected
            if result["ok"] == nil { result["ok"] = !((result["created"] as? [Any]) ?? []).isEmpty }
            return .json((result["ok"] as? Bool) == true ? 200 : 400, result)

        case ("POST", "/api/tasks/queue/start"):
            guard let body = request.jsonBody() else { return missingBody() }
            guard let delegate = delegate else { return unavailable() }
            let result = delegate.apiTaskQueueStart(parseQueueStart(body))
            return .json(startStatus(result), result)

        default:
            return nil
        }
    }

    /// /api/tasks/queue/start 的 HTTP 状态：启动了 200，队列名有歧义 409（调用方补
    /// queueId 再来），找不到 404，其余 400。
    static func startStatus(_ result: [String: Any]) -> Int {
        if (result["ok"] as? Bool) == true { return 200 }
        switch result["error"] as? String {
        case "ambiguous-queue": return 409
        case "no-queue": return 404
        default: return 400
        }
    }

    static func missingBody() -> HTTPResponse {
        .json(400, ["ok": false, "error": "missing-body",
                    "hint": "expected a JSON object like {\"name\": \"…\", \"tasks\": [\"标题\"]}"])
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

    /// 解析 queue/create 请求体（纯函数）。任务部分复用 create 的规则（字符串简写、
    /// 对象、空标题、50 条上限）；队列名缺省时用第一条任务的标题兜底。
    static func parseQueueCreate(_ body: [String: Any]) -> ParsedQueueCreate {
        var parsed = ParsedQueueCreate()
        parsed.workspace = TasksAPIWorkspace.normalize(body["workspace"] as? String)
        parsed.session = normalizeSession(body["session"] as? String)
        parsed.focus = (body["focus"] as? Bool) ?? true
        parsed.name = ((body["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw = body["branch"] as? String {
            parsed.branch = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let base = (body["baseBranch"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        parsed.baseBranch = (base?.isEmpty ?? true) ? nil : base
        parsed.autoPR = body["autoPR"] as? Bool

        guard let raw = body["tasks"] as? [Any] else {
            parsed.rejected.append(["title": "", "error": "missing-tasks"])
            return parsed
        }
        parsed.tasksProvided = true
        let tasks = parseCreate(["tasks": raw])
        parsed.drafts = tasks.drafts
        parsed.rejected.append(contentsOf: tasks.rejected)
        if parsed.name.isEmpty { parsed.name = parsed.drafts.first?.title ?? "" }
        return parsed
    }

    static func parseQueueStart(_ body: [String: Any]) -> TaskQueueStartRequest {
        let raw = (body["queueId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TaskQueueStartRequest(workspace: TasksAPIWorkspace.normalize(body["workspace"] as? String),
                                     session: normalizeSession(body["session"] as? String),
                                     queueId: (raw?.isEmpty ?? true) ? nil : raw)
    }

    /// 来源会话 id，缺省 / 空白 → nil（队列照建，只是不回传）。
    static func normalizeSession(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
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

    static func queueDictionary(_ queue: TaskQueue, reportsToSession: Bool = false) -> [String: Any] {
        var d: [String: Any] = ["id": queue.id,
                                "name": queue.name,
                                "state": queue.state.rawValue,
                                "tasks": queue.taskIds.count]
        if let branch = queue.branch { d["branch"] = branch }
        if !queue.autoCreated { d["userQueue"] = true }
        // The session id itself stays machine-private; the caller only says WHETHER a
        // report will go back, so a UI / agent can show it without leaking the id.
        if reportsToSession { d["reportsToSession"] = true }
        return d
    }
}

