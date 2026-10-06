import Foundation

// MARK: - 事项面板自有队列引擎：模型 + 存储（design A1 / A10 / D8）
//
// 这是「事项面板」的队列/三级任务模型。按裁决 A10 从任务面板的
// TasksCore / TasksStore「复制 + 重命名 + 改造」，但：
//   - 不 import / 不调用 / 不继承任务面板任何代码（A1 clean-room）；
//   - 队列与三级任务只落 .dsh/workstreams/（ignored），**绝不读写 .dsh/tasks/**（D8）；
//   - 队列新增 workstreamId；任务新增 workstreamId + stage（一事项一队列，
//     阶段是任务的属性，design A9 / A12）：事项启动 = 启动该事项的队列。
//
// 纯值类型 + 纯 Foundation：无 AppKit、无定时器、无磁盘副作用（存储走 WSStore），
// 因此可以在 headless 测试里直接驱动。

// MARK: - 三级任务状态

/// 队内一条任务的生命周期。与任务面板 TaskState 同形，但归事项面板所有。
enum WSTaskState: String {
    case pending
    case queued
    case running
    case done
    case failed
    /// 待确认：会话结束了，但没拿到本次完成标记（断网 / 被打断 / 漏写）。不是成功也
    /// 未必是失败——判断权交回用户（重试 / 标记完成），行为与失败一致：队列暂停。
    case needsReview
    case cancelled

    var isFinished: Bool {
        switch self {
        case .done, .failed, .needsReview, .cancelled: return true
        case .pending, .queued, .running: return false
        }
    }

    /// 是否可以（再次）入队：失败 / 待确认 / 已取消都允许重试。
    var isQueueable: Bool {
        switch self {
        case .pending, .failed, .needsReview, .cancelled: return true
        case .queued, .running, .done: return false
        }
    }
}

// MARK: - 队列状态

/// 队列状态，沿用存储设计约定：
/// - draft：建好但从未启动（等待态）；
/// - active：正在跑，串行取任务；
/// - paused：启动过但停了（失败 / 取消 / 重启），用户「继续」；
/// - done：当前一批任务都结束，活泳道，可追加；
/// - closed：用户手动关闭的终态，保留记录、不再接收动作。
enum WSQueueState: String {
    case draft
    case active
    case paused
    case done
    case closed
}

// MARK: - 三级任务

/// 队内一条任务（三级卡片）。dsh 会话 id 是机器私有，只进 local.json。
struct WSTaskItem: Equatable {
    var id: String
    var title: String
    var body: String?
    var state: WSTaskState
    var queueId: String?
    /// The workstream this task belongs to (design A12 / D17): the task is a
    /// direct member of a workstream, not only of a queue.
    var workstreamId: String?
    /// The stage this task executes (design A12 / D17). Stage is a task property,
    /// so the stage view groups tasks by it. Optional for read-compatibility with
    /// entries written before the field existed.
    var stage: WorkstreamStage?
    var sessionId: String?
    var error: String?
    var startedAt: Date?
    var finishedAt: Date?
    /// 代理结束时的汇报（runner 写回，随卡展示，也作为队内下一任务的前置信息）。
    var report: String?
    /// 本次尝试的完成 marker（runner 生成、写进提示词，会话须在最后一行回显）。
    var completionMarker: String?
    var markerVerified: Bool
    /// 人看过待确认任务后按「标记完成」放行（P2）。与 markerVerified 一起构成
    /// 任务级完成证据；阶段门用它判断执行阶段是否拿到证据（P1-P5）。
    var userConfirmed: Bool

    init(id: String,
         title: String,
         body: String? = nil,
         state: WSTaskState = .pending,
         queueId: String? = nil,
         workstreamId: String? = nil,
         stage: WorkstreamStage? = nil,
         sessionId: String? = nil,
         error: String? = nil,
         startedAt: Date? = nil,
         finishedAt: Date? = nil,
         report: String? = nil,
         completionMarker: String? = nil,
         markerVerified: Bool = false,
         userConfirmed: Bool = false) {
        self.id = id
        self.title = title
        self.body = body
        self.state = state
        self.queueId = queueId
        self.workstreamId = workstreamId
        self.stage = stage
        self.sessionId = sessionId
        self.error = error
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.report = report
        self.completionMarker = completionMarker
        self.markerVerified = markerVerified
        self.userConfirmed = userConfirmed
    }

    /// ISO-8601，与仓库既有 .dsh 文件同形（2026-08-20T15:26:43Z）。
    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 一条新任务 id：wt- + 8 位小写十六进制。
    static func newID() -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return "wt-" + String(token).lowercased()
    }

    func dictionary() -> [String: Any] {
        var d: [String: Any] = ["id": id, "title": title, "state": state.rawValue]
        if let body = body, !body.isEmpty { d["body"] = body }
        if let workstreamId = workstreamId, !workstreamId.isEmpty { d["workstreamId"] = workstreamId }
        if let stage = stage { d["stage"] = stage.rawValue }
        if let error = error { d["error"] = error }
        if userConfirmed { d["userConfirmed"] = true }
        if let startedAt = startedAt { d["startedAt"] = WSTaskItem.iso8601.string(from: startedAt) }
        if let finishedAt = finishedAt { d["finishedAt"] = WSTaskItem.iso8601.string(from: finishedAt) }
        return d
    }

    static func from(_ d: [String: Any]) -> WSTaskItem? {
        guard let id = d["id"] as? String, let title = d["title"] as? String else { return nil }
        return WSTaskItem(id: id,
                          title: title,
                          body: d["body"] as? String,
                          state: WSTaskState(rawValue: (d["state"] as? String) ?? "pending") ?? .pending,
                          workstreamId: (d["workstreamId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                          stage: (d["stage"] as? String).flatMap { WorkstreamStage.parse($0) },
                          error: d["error"] as? String,
                          startedAt: (d["startedAt"] as? String).flatMap { WSTaskItem.iso8601.date(from: $0) },
                          finishedAt: (d["finishedAt"] as? String).flatMap { WSTaskItem.iso8601.date(from: $0) },
                          userConfirmed: (d["userConfirmed"] as? Bool) ?? false)
    }
}

// MARK: - 队列

/// 一条执行队列：一个事项至多一条队列（design A9 / D16），五个阶段的任务共用它，
/// 队内任务严格串行。
///
/// workstreamId 是本次「复制 + 改造」相对任务面板新增的适配点（design A10）：队列
/// 知道它属于哪个事项，runner 才能实现「事项启动 = 启动该事项的队列」。stage 已
/// 降级为可选的历史字段——队列不再按阶段划分，阶段是**任务**的属性（A12 / D17）。
struct WSQueue: Equatable {
    var id: String
    var name: String
    var workstreamId: String
    /// 兼容旧数据：队列以前带阶段；新写入不再标阶段。
    var stage: WorkstreamStage?
    var taskIds: [String]
    var state: WSQueueState
    var createdAt: Date?

    init(id: String,
         name: String,
         workstreamId: String = "",
         stage: WorkstreamStage? = nil,
         taskIds: [String] = [],
         state: WSQueueState = .draft,
         createdAt: Date? = nil) {
        self.id = id
        self.name = name
        self.workstreamId = workstreamId
        self.stage = stage
        self.taskIds = taskIds
        self.state = state
        self.createdAt = createdAt
    }

    /// 一条新队列 id：wq- + 8 位小写十六进制。
    static func newID() -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return "wq-" + String(token).lowercased()
    }

    /// 1-based position inside the queue, nil when the task is not in it.
    func order(of taskID: String) -> Int? {
        guard let i = taskIds.firstIndex(of: taskID) else { return nil }
        return i + 1
    }

    func dictionary() -> [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "name": name,
            "workstreamId": workstreamId,
            "taskIds": taskIds,
            "state": state.rawValue,
        ]
        if let stage = stage { d["stage"] = stage.rawValue }
        if let createdAt = createdAt { d["createdAt"] = WSTaskItem.iso8601.string(from: createdAt) }
        return d
    }

    static func from(_ d: [String: Any]) -> WSQueue? {
        guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
        // stage is a legacy field (queue no longer carries a stage): keep it when
        // present, otherwise nil. Never default it to a real stage.
        let stage = (d["stage"] as? String).flatMap { WorkstreamStage.parse($0) }
        return WSQueue(id: id,
                       name: name,
                       workstreamId: (d["workstreamId"] as? String) ?? "",
                       stage: stage,
                       taskIds: (d["taskIds"] as? [String]) ?? [],
                       state: WSQueueState(rawValue: (d["state"] as? String) ?? "draft") ?? .draft,
                       createdAt: (d["createdAt"] as? String).flatMap { WSTaskItem.iso8601.date(from: $0) })
    }
}

// MARK: - 任务草稿

/// 建任务 / 入队表单的纯值：标题必填，描述缺省回落标题。
struct WSTaskDraft: Equatable {
    var title: String
    var body: String

    init(title: String = "", body: String = "") {
        self.title = title
        self.body = body
    }

    var normalizedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalizedBody: String { body.trimmingCharacters(in: .whitespacesAndNewlines) }
    var effectiveBody: String { normalizedBody.isEmpty ? normalizedTitle : normalizedBody }
    var isValid: Bool { !normalizedTitle.isEmpty }
}

// MARK: - local.json（机器私有 overlay）

/// 只属于本机的运行时绑定：任务 → dsh 会话、汇报、完成 marker、当前活跃队列。
struct WSLocalState: Equatable {
    /// task id -> dsh sessionId.
    var sessions: [String: String] = [:]
    /// task id -> 代理汇报。
    var reports: [String: String] = [:]
    var activeQueueID: String?
    var runningTaskID: String?
    /// task id -> 本次尝试的完成 marker。
    var taskMarkers: [String: String] = [:]
    /// task id -> marker 是否已校验通过。
    var taskMarkerVerified: [String: Bool] = [:]

    static func from(_ d: [String: Any]) -> WSLocalState {
        var s = WSLocalState()
        if let raw = d["sessions"] as? [String: Any] {
            for (key, value) in raw {
                guard let entry = value as? [String: Any],
                      let sessionId = entry["sessionId"] as? String else { continue }
                s.sessions[key] = sessionId
            }
        }
        if let raw = d["reports"] as? [String: String] {
            for (key, text) in raw where !text.isEmpty { s.reports[key] = text }
        }
        s.activeQueueID = d["activeQueueId"] as? String
        s.runningTaskID = d["runningTaskId"] as? String
        if let raw = d["taskMarkers"] as? [String: String] {
            for (key, text) in raw where !text.isEmpty { s.taskMarkers[key] = text }
        }
        if let raw = d["taskMarkerVerified"] as? [String: Any] {
            for (key, value) in raw where (value as? Bool) != nil {
                s.taskMarkerVerified[key] = value as? Bool
            }
        }
        return s
    }

    func dictionary() -> [String: Any] {
        var sessionsOut: [String: Any] = [:]
        for (id, sessionId) in sessions {
            sessionsOut[id] = ["sessionId": sessionId,
                               "updatedAt": WSTaskItem.iso8601.string(from: Date())]
        }
        var d: [String: Any] = ["sessions": sessionsOut]
        if !reports.isEmpty { d["reports"] = reports }
        if !taskMarkers.isEmpty { d["taskMarkers"] = taskMarkers }
        if !taskMarkerVerified.isEmpty { d["taskMarkerVerified"] = taskMarkerVerified }
        if let activeQueueID = activeQueueID { d["activeQueueId"] = activeQueueID }
        if let runningTaskID = runningTaskID { d["runningTaskId"] = runningTaskID }
        return d
    }
}

// MARK: - Board

/// 事项面板的队列板：任务 + 队列 + 机器私有 overlay。所有面板与 runner 共用的
/// 规则都在这里；纯值类型，无定时器 / 无 I/O / 无 AppKit。
struct WSBoard {
    var tasks: [WSTaskItem] = []
    var queues: [WSQueue] = []
    var local = WSLocalState()

    // MARK: lookups

    func task(_ id: String) -> WSTaskItem? { tasks.first { $0.id == id } }

    func queue(_ id: String) -> WSQueue? { queues.first { $0.id == id } }

    func index(ofTask id: String) -> Int? { tasks.firstIndex { $0.id == id } }

    func index(ofQueue id: String) -> Int? { queues.firstIndex { $0.id == id } }

    func tasks(inQueue queueID: String) -> [WSTaskItem] {
        guard let queue = queue(queueID) else { return [] }
        return queue.taskIds.compactMap { task($0) }
    }

    /// 某事项的执行队列：优先按 WS 卡 committed 的 queues=[q-...] 映射，回落到
    /// 引擎自带的 workstreamId 标记。一个事项至多一条队列（A9 / D16），故映射只
    /// 需第一条。
    func queue(forWorkstream workstreamID: String, mapping: [String] = []) -> WSQueue? {
        if let mapped = mapping.first, let q = queue(mapped) { return q }
        return queues.first { $0.workstreamId == workstreamID }
    }

    // MARK: queue membership

    /// 追加一条任务到队列（FIFO）。已在别的队列里的会先移出；同队列幂等。
    @discardableResult
    mutating func enqueue(taskID: String, into queueID: String) -> Bool {
        guard let ti = index(ofTask: taskID) else { return false }
        guard let qi = index(ofQueue: queueID), queues[qi].state != .closed else { return false }
        guard tasks[ti].state.isQueueable else { return false }
        if tasks[ti].queueId == queueID { return false }
        if tasks[ti].queueId != nil { _ = dequeue(taskID: taskID) }
        tasks[ti].state = .queued
        tasks[ti].queueId = queueID
        if !queues[qi].taskIds.contains(taskID) { queues[qi].taskIds.append(taskID) }
        // 追加到已完成队列：回到待启动的活泳道；paused 保持暂停。
        if queues[qi].state == .done { queues[qi].state = .draft }
        return true
    }

    /// 移出队列（仅等待中的任务）：回到未入队。
    @discardableResult
    mutating func dequeue(taskID: String) -> Bool {
        guard let ti = index(ofTask: taskID), let queueID = tasks[ti].queueId,
              let qi = index(ofQueue: queueID), tasks[ti].state == .queued else { return false }
        queues[qi].taskIds.removeAll { $0 == taskID }
        tasks[ti].queueId = nil
        tasks[ti].state = .pending
        return true
    }

    /// 从所有队列里摘掉一条任务（删除任务时用）。
    mutating func detach(taskID: String) {
        for i in queues.indices { queues[i].taskIds.removeAll { $0 == taskID } }
        guard let ti = index(ofTask: taskID) else { return }
        tasks[ti].queueId = nil
        if tasks[ti].state == .queued { tasks[ti].state = .pending }
    }

    @discardableResult
    mutating func removeQueue(_ queueID: String) -> Bool {
        guard let qi = index(ofQueue: queueID) else { return false }
        if queues[qi].taskIds.contains(where: { task($0)?.state == .running }) { return false }
        for id in queues[qi].taskIds {
            guard let ti = index(ofTask: id) else { continue }
            tasks[ti].queueId = nil
            if tasks[ti].state == .queued { tasks[ti].state = .pending }
        }
        queues.remove(at: qi)
        if local.activeQueueID == queueID { local.activeQueueID = nil }
        return true
    }

    /// 关闭队列（手动终态）：保留记录，不再接收任何动作。
    @discardableResult
    mutating func closeQueue(_ queueID: String) -> Bool {
        guard let qi = index(ofQueue: queueID), queues[qi].state != .closed else { return false }
        if queues[qi].taskIds.contains(where: { task($0)?.state == .running }) { return false }
        queues[qi].state = .closed
        if local.activeQueueID == queueID { local.activeQueueID = nil }
        return true
    }

    /// 建一条用户队列（draft，等待态）。
    @discardableResult
    mutating func createQueue(name: String,
                             workstreamID: String = "",
                             createdAt: Date = Date()) -> WSQueue {
        let queue = WSQueue(id: WSQueue.newID(), name: name, workstreamId: workstreamID,
                            stage: nil, taskIds: [], state: .draft, createdAt: createdAt)
        queues.append(queue)
        return queue
    }

    /// runner 当前工作的队列：指定且 active 的优先，否则第一条 active。
    func activeQueue() -> WSQueue? {
        if let id = local.activeQueueID, let q = queue(id), q.state == .active { return q }
        return queues.first { $0.state == .active }
    }

    /// 现在应该启动的任务，nil = 没有。串行由构造保证：只要有任一任务在跑，
    /// 就不启动别的；只有 active 队列贡献候选；失败 / 已完成 / 已取消的条目跳过。
    ///
    /// `stage`（design A3 / D18）是「阶段级启动」的过滤：只把该阶段的任务算作候选，
    /// 其余任务保持 queued，由 runner 在该阶段跑完后暂停队列。nil = 事项级，不看阶段。
    func nextStartable(stage: WorkstreamStage? = nil) -> String? {
        if local.runningTaskID != nil { return nil }
        if tasks.contains(where: { $0.state == .running }) { return nil }
        if let queue = activeQueue(), let id = firstQueued(in: queue, stage: stage) { return id }
        for queue in queues where queue.state == .active {
            if let id = firstQueued(in: queue, stage: stage) { return id }
        }
        return nil
    }

    private func firstQueued(in queue: WSQueue, stage: WorkstreamStage? = nil) -> String? {
        queue.taskIds.first { id in
            guard let task = task(id), task.state == .queued else { return false }
            guard let stage = stage else { return true }
            // A task stage is a direct property (A12); a legacy task without one
            // falls back to the queue own legacy stage, never to a real default.
            return (task.stage ?? queue.stage) == stage
        }
    }

    // MARK: transitions

    mutating func markRunning(_ taskID: String, at date: Date = Date()) {
        guard let i = index(ofTask: taskID) else { return }
        tasks[i].state = .running
        tasks[i].startedAt = date
        tasks[i].error = nil
        if let queueID = tasks[i].queueId, let qi = index(ofQueue: queueID) {
            queues[qi].state = .active
            local.activeQueueID = queueID
        }
        local.runningTaskID = taskID
    }

    mutating func markDone(_ taskID: String, report: String? = nil, at date: Date = Date()) {
        guard let i = index(ofTask: taskID) else { return }
        tasks[i].state = .done
        tasks[i].finishedAt = date
        recordReport(taskID, report)
        local.runningTaskID = nil
        refreshQueueCompletion()
    }

    mutating func recordReport(_ taskID: String, _ report: String?) {
        guard let text = report?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let i = index(ofTask: taskID) else { return }
        tasks[i].report = text
        local.reports[taskID] = text
    }

    mutating func recordAttemptMarker(_ taskID: String, _ marker: String) {
        guard let i = index(ofTask: taskID) else { return }
        tasks[i].completionMarker = marker
        tasks[i].markerVerified = false
        local.taskMarkers[taskID] = marker
        local.taskMarkerVerified[taskID] = false
    }

    mutating func recordMarkerVerified(_ taskID: String, _ verified: Bool) {
        guard let i = index(ofTask: taskID) else { return }
        tasks[i].markerVerified = verified
        local.taskMarkerVerified[taskID] = verified
    }

    @discardableResult
    mutating func markFailed(_ taskID: String, error: String, report: String? = nil,
                             at date: Date = Date()) -> String? {
        guard let i = index(ofTask: taskID) else { return nil }
        tasks[i].state = .failed
        tasks[i].error = error
        tasks[i].finishedAt = date
        recordReport(taskID, report)
        local.runningTaskID = nil
        return pauseQueue(containing: tasks[i])
    }

    @discardableResult
    mutating func markNeedsReview(_ taskID: String, reason: String, report: String? = nil,
                                  at date: Date = Date()) -> String? {
        guard let i = index(ofTask: taskID) else { return nil }
        tasks[i].state = .needsReview
        tasks[i].error = reason
        tasks[i].finishedAt = date
        recordReport(taskID, report)
        local.runningTaskID = nil
        return pauseQueue(containing: tasks[i])
    }

    mutating func confirmDone(_ taskID: String, at date: Date = Date()) {
        guard let i = index(ofTask: taskID), tasks[i].state == .needsReview else { return }
        tasks[i].error = nil
        tasks[i].userConfirmed = true
        markDone(taskID, at: date)
    }

    @discardableResult
    mutating func markCancelled(_ taskID: String, at date: Date = Date()) -> String? {
        guard let i = index(ofTask: taskID) else { return nil }
        tasks[i].state = .cancelled
        tasks[i].finishedAt = date
        local.runningTaskID = nil
        return pauseQueue(containing: tasks[i])
    }

    @discardableResult
    mutating func retryAndResume(_ taskID: String) -> Bool {
        guard let i = index(ofTask: taskID), tasks[i].state.isQueueable else { return false }
        tasks[i].error = nil
        tasks[i].finishedAt = nil
        tasks[i].report = nil
        local.reports[taskID] = nil
        tasks[i].completionMarker = nil
        tasks[i].markerVerified = false
        local.taskMarkers[taskID] = nil
        local.taskMarkerVerified[taskID] = nil
        if let queueID = tasks[i].queueId, let qi = index(ofQueue: queueID) {
            tasks[i].state = .queued
            queues[qi].state = .active
            local.activeQueueID = queueID
        } else {
            tasks[i].state = .pending
        }
        return true
    }

    @discardableResult
    mutating func resumeQueue(_ queueID: String) -> Bool {
        guard let qi = index(ofQueue: queueID), queues[qi].state != .closed else { return false }
        queues[qi].state = .active
        local.activeQueueID = queueID
        return true
    }

    @discardableResult
    mutating func pauseQueue(_ queueID: String) -> Bool {
        guard let qi = index(ofQueue: queueID) else { return false }
        queues[qi].state = .paused
        return true
    }

    /// 队列内没有 queued/running 任务时置 done。
    mutating func refreshQueueCompletion() {
        for i in queues.indices {
            let open = queues[i].taskIds.contains { id in
                guard let state = task(id)?.state else { return false }
                return state == .queued || state == .running
            }
            if !open && !queues[i].taskIds.isEmpty
                && queues[i].state != .done && queues[i].state != .closed {
                queues[i].state = .done
            }
        }
    }

    private mutating func pauseQueue(containing task: WSTaskItem) -> String? {
        guard let queueID = task.queueId, let qi = index(ofQueue: queueID),
              queues[qi].state == .active else { return nil }
        queues[qi].state = .paused
        return queueID
    }

    // MARK: repair / restart

    /// queue.taskIds 是成员关系的权威，逐任务的 queueId 是反规范化副本；加载后
    /// 重新推导，避免两者漂移（并去掉重复 id）。
    mutating func reindexQueueMembership() {
        for qi in queues.indices {
            var seen = Set<String>()
            queues[qi].taskIds = queues[qi].taskIds.filter { seen.insert($0).inserted }
        }
        for i in tasks.indices { tasks[i].queueId = nil }
        for queue in queues {
            for id in queue.taskIds {
                guard let ti = index(ofTask: id) else { continue }
                tasks[ti].queueId = queue.id
                if tasks[ti].state == .pending { tasks[ti].state = .queued }
            }
        }
    }

    mutating func attachSessions(_ sessions: [String: String], reports: [String: String] = [:],
                                 markers: [String: String] = [:],
                                 markerVerified: [String: Bool] = [:]) {
        for i in tasks.indices {
            if let sessionId = sessions[tasks[i].id] { tasks[i].sessionId = sessionId }
            if let report = reports[tasks[i].id] { tasks[i].report = report }
            if let marker = markers[tasks[i].id] { tasks[i].completionMarker = marker }
            if let verified = markerVerified[tasks[i].id] { tasks[i].markerVerified = verified }
        }
    }

    /// 重启恢复：running 的任务不可能还在跑（会话随 App 一起死），置 failed(中断)；
    /// active 的队列置 paused，等用户显式「继续」。绝不自动起跑。
    @discardableResult
    mutating func reconcileAfterRestart(interruptedError: String) -> (interrupted: [String], pausedQueues: [String]) {
        var interrupted: [String] = []
        for i in tasks.indices where tasks[i].state == .running {
            tasks[i].state = .failed
            tasks[i].error = interruptedError
            interrupted.append(tasks[i].id)
        }
        var paused: [String] = []
        for i in queues.indices where queues[i].state == .active {
            queues[i].state = .paused
            paused.append(queues[i].id)
        }
        local.runningTaskID = nil
        return (interrupted, paused)
    }
}

// MARK: - 存储（.dsh/workstreams/）

/// 事项面板的磁盘布局，落点 <repoRoot>/.dsh/workstreams/：
///
///   queues.json  local  队列定义、FIFO 顺序与三级任务（同文件，ignored）
///   local.json   local  任务 → dsh session、汇报、完成 marker、活跃队列（ignored）
///
/// **硬约束（design D8）**：只碰 .dsh/workstreams/，绝不读写 .dsh/tasks/。
/// 读取宽容：文件缺失 / 损坏一律返回空状态，读永不删改数据。
enum WSStore {
    static let queuesFile = "queues.json"
    static let localFile = "local.json"

    /// .dsh/workstreams/，按需创建。
    static func workstreamsDir(_ repoRoot: String) -> String {
        let dir = (repoRoot as NSString).appendingPathComponent(".dsh/workstreams")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    static func path(_ repoRoot: String, file: String) -> String {
        (workstreamsDir(repoRoot) as NSString).appendingPathComponent(file)
    }

    static func readJSON(_ file: String) -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    static func writeJSON(_ file: String, _ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: file))
    }

    static func loadQueues(_ repoRoot: String) -> [WSQueue] {
        let entries = readJSON(path(repoRoot, file: queuesFile))["queues"] as? [[String: Any]] ?? []
        return entries.compactMap { WSQueue.from($0) }
    }

    static func loadTasks(_ repoRoot: String) -> [WSTaskItem] {
        let entries = readJSON(path(repoRoot, file: queuesFile))["tasks"] as? [[String: Any]] ?? []
        return entries.compactMap { WSTaskItem.from($0) }
    }

    static func saveQueues(_ repoRoot: String, queues: [WSQueue], tasks: [WSTaskItem]) {
        writeJSON(path(repoRoot, file: queuesFile),
                  ["version": 1,
                   "queues": queues.map { $0.dictionary() },
                   "tasks": tasks.map { $0.dictionary() }])
    }

    static func loadLocal(_ repoRoot: String) -> WSLocalState {
        WSLocalState.from(readJSON(path(repoRoot, file: localFile)))
    }

    static func saveLocal(_ repoRoot: String, _ state: WSLocalState) {
        writeJSON(path(repoRoot, file: localFile), state.dictionary())
    }

    /// 读全板：队列 + 任务 + 机器 overlay，应用会话并重推成员关系。
    static func load(_ repoRoot: String) -> WSBoard {
        var board = WSBoard()
        board.queues = loadQueues(repoRoot)
        board.tasks = loadTasks(repoRoot)
        board.local = loadLocal(repoRoot)
        board.attachSessions(board.local.sessions, reports: board.local.reports,
                             markers: board.local.taskMarkers,
                             markerVerified: board.local.taskMarkerVerified)
        board.reindexQueueMembership()
        return board
    }

    /// 落盘全板（queues.json + local.json）。
    static func save(_ repoRoot: String, _ board: WSBoard) {
        saveQueues(repoRoot, queues: board.queues, tasks: board.tasks)
        saveLocal(repoRoot, board.local)
    }
}
