import Foundation

// MARK: - 阶段队列引擎（WorkstreamsRunner，design A10）
//
// 按裁决 A10 从任务面板的 TasksRunner「复制 + 重命名 + 改造」：
//   - 保留 step / pump 串行相位机：任何时刻最多一条任务在跑，队列内严格 FIFO；
//   - 保留「建会话 → 命名 → prompt → 轮询 → 取消 / 重试」这条会话生命周期；
//   - 保留重启恢复（running → failed(中断)、active → paused，绝不自动起跑）。
//
// 改造点（design A9 / A12 / D8 / A3）：
//   - 一个事项至多一条队列，任务带 workstreamId + stage；
//     事项启动 = 启动该事项的队列（startWorkstream(_:) / queue(forWorkstream:mapping:)）；
//   - 存储只走 WSStore（.dsh/workstreams/），绝不读写 .dsh/tasks/、不依赖 /api/tasks/*；
//   - 不 import / 不调用任务面板任何代码（A1 clean-room）。
//
// 阻塞工作（dsh RPC）一律交给 env.perform，在后台线程跑完再回调，因此所有 board
// 变更加都在一处；测试传入同步 perform 即可 headless 驱动整条流水线。

// MARK: - dsh 对会话状态的回答

/// dsh 此刻对一个会话的判定。Bool 无法区分「RPC 失败」与「会话不在列表里」，而
/// 这两者都曾被当成「会话结束」——一次网络抖动就宣布任务完成。这里保持四分。
enum WSSessionState: Equatable {
    /// dsh 说它正在工作。
    case running
    /// dsh 列出它且说它不再工作 → 任务结束。
    case idle
    /// 答不上来（RPC 失败）：不假设任何事，下个 tick 再问。
    case unknown
    /// dsh 根本不在列表里（已从侧栏删除 / 服务重启）。只有持续缺席才算失败。
    case missing
}

// MARK: - 失败原因（L10n 键）

/// 引擎写进 board 的失败 / 待确认原因，raw value 就是 L10n 键。
enum WSFailure: String {
    case interrupted = "workstreams.errInterrupted"
    case sessionGone = "workstreams.errSessionGone"
    case session = "workstreams.errSession"
    case prompt = "workstreams.errPrompt"
    case timeout = "workstreams.errTimeout"
    case unverified = "workstreams.errUnverified"
}

// MARK: - 取消结果

/// 取消任务实际发生了什么（与任务面板 CancelOutcome 同形）：Bool 说不清 .starting
/// 与 .finishing 两个用户看不见的窗口，面板需要据此解释而不是沉默。
enum WSCancelOutcome: Equatable {
    /// 已取消运行中的会话，队列暂停。
    case cancelled
    /// 任务仍在启动：请求被记住，会话一出现就取消。
    case deferred
    /// 任务已经在收尾：没有可取消的会话。
    case finishing
    /// 没有任务在跑。
    case idle
}

// MARK: - 提示词

/// 事项面板自有的提示词构造（复制 + 改造自 TaskPrompts 的最小集）。纯函数，
/// 可在后台步骤里调用。
///
/// 阶段交接提示词（设计 D15）由 `WorkstreamHandoff`（WorkstreamsPrompts.swift）生成、
/// 注入任务 body；这里只负责运行时的包装：body 已是完整交接提示词时原样发送，否则
/// 回落到任务面板同形的短模板。完成 marker 也委托给 `WorkstreamHandoff`，一处维护。
enum WSPrompts {
    /// 各阶段的简短说明，用于提示词头部。
    static func stageLabel(_ stage: WorkstreamStage) -> String {
        WorkstreamHandoff.stageLabel(stage)
    }

    /// 一条三级任务的完整提示词：阶段上下文 + 任务标题/描述 + 要求清单。
    /// body 是面板生成的阶段交接提示词时原样使用（design §2 原则 1：提示词是指针）。
    static func task(_ task: WSTaskItem, queue: WSQueue?) -> String {
        if let body = task.body?.trimmingCharacters(in: .whitespacesAndNewlines),
           !body.isEmpty, body != task.title, WorkstreamHandoff.isHandoff(body) {
            return body
        }
        var lines: [String] = []
        // Stage is a task property (design A12); fall back to the legacy queue
        // stage, then to the execution default.
        let stage = (task.stage ?? queue?.stage).map(stageLabel) ?? "执行"
        let workstreamID = task.workstreamId ?? queue?.workstreamId ?? ""
        if !workstreamID.isEmpty {
            lines.append("你正在推进事项 " + workstreamID + " 的「" + stage + "」阶段。")
        } else {
            lines.append("你正在推进一个事项的「" + stage + "」阶段。")
        }
        lines.append("")
        lines.append("任务：" + task.title)
        if let body = task.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty,
           body != task.title {
            lines.append("")
            lines.append(body)
        }
        lines.append("")
        lines.append("要求：")
        lines.append("- 只做这一条任务；完成后把改动留在仓库（需要时 commit）。")
        lines.append("- 不要直接改动事项面板的运行态文件（.dsh/workstreams/ 下的 queues.json / local.json）。")
        lines.append("- 结束时用一两句话汇报结果。")
        return lines.joined(separator: "\n")
    }

    /// 完成标记要求（P1 完成协议）：追加在提示词末尾，会话须在最后一行原样回显。
    static func completionMarkerInstruction(_ marker: String) -> String {
        WorkstreamHandoff.completionMarkerInstruction(marker)
    }

    /// 重试续跑的短提示词：一句「从未完成处继续」+ 标题；不重发完整要求。
    static func retryContinuation(title: String, marker: String?) -> String {
        var text = "上一轮因中断或未拿到完成证据而停止，请从未完成处继续本任务：" + title + "。\n"
            + "（不要重做已经完成的部分。）"
        text = WorkstreamHandoff.injectingCompletionMarker(text, marker: marker)
        return text
    }
}

// MARK: - 注入的外部副作用

/// runner 需要的外部世界。面板传真实的 dsh RPC；测试传脚本化假件——正是这一点
/// 让整条流水线（建会话 → 命名 → prompt → 轮询 → 取消）可以 headless 跑。
struct WSRunnerEnv {
    /// 会话的工作目录（工作区根）。
    var repoRoot: String
    var createSession: (_ cwd: String) -> String?
    var renameSession: (_ sessionId: String, _ title: String) -> Bool
    var promptSession: (_ sessionId: String, _ text: String) -> Bool
    /// dsh 对某会话的判定（见 WSSessionState）。
    var sessionState: (_ sessionId: String) -> WSSessionState
    var cancelSession: (_ sessionId: String) -> Bool
    /// 会话最后的文本汇报（阻塞；runner 只在后台步骤里调用）。
    var sessionReport: (_ sessionId: String) -> String? = { _ in nil }
    /// 交给代理的提示词。缺省用 WSPrompts.task。
    var promptText: (_ task: WSTaskItem, _ queue: WSQueue?) -> String = { WSPrompts.task($0, queue: $1) }
    /// P1 完成校验：任务会话是否必须在最后一行回显 runner 注入的完成 marker。真实面板
    /// 开启；legacy / headless env 默认关闭。
    var requireCompletionMarker: Bool = false
    /// 落盘机器私有的一半（queues.json / local.json）。
    var persist: (WSBoard) -> Void
    var log: (String) -> Void
    /// 把阻塞工作放到主线程之外，再回调。测试传同步实现。
    var perform: (_ blocking: @escaping () -> Void, _ completion: @escaping () -> Void) -> Void

    /// 两边都就地跑——headless 缺省。
    static func synchronous(_ blocking: () -> Void, _ completion: () -> Void) {
        blocking()
        completion()
    }
}

// MARK: - Runner

/// 驱动队列板：永远一次一条任务，队列内按顺序推进。
///
/// runner 独占 board 的所有变更（入队 / 启动 / 结束 / 取消 / 重启恢复），面板只负责
/// 渲染和调进来。阻塞工作（dsh RPC）交给 env.perform，在后台线程完成再回调。
///
/// step() 是唯一的定时器入口：串行槽空闲时启动下一条、推进运行中的那条，并报告是否
/// 还有任务在飞。测试用同步 perform 驱动它。
final class WorkstreamsRunner {

    private(set) var board: WSBoard
    private var env: WSRunnerEnv
    private let timeout: TimeInterval

    private struct Active {
        var taskID: String
        var queueID: String?
        var sessionId: String
        var startedAt: Date
        /// 本次尝试的完成 marker（P1）：只有会话最后一行回显了它才算做完。
        var marker: String?
    }

    private enum Phase {
        case idle
        case starting(String)
        case active(Active)
        case finishing(String)
    }

    private enum StartResult {
        case started(sessionId: String)
        /// 失败时若已建出会话，带上它（一个建了但没命名的会话在 dsh web 里仍可找到）。
        case failed(WSFailure, String?)
    }

    private enum FinishOutcome {
        /// 会话停了，且本次完成 marker 回来了。
        case done
        /// 会话结束了，但没有本次完成 marker：队列暂停，等用户重试或标记完成。
        case needsReview
        case failed(WSFailure)
    }

    /// 自上次确认答案以来「答不上来 / 找不到」的轮询次数。见 WSSessionState。
    private var unknownPolls = 0
    private var missingPolls = 0
    /// 连续多少轮报告会话消失才判失败（面板每 3s 轮询一次，约 30s 静默）。
    static let missingSessionPolls = 10

    private var phase: Phase = .idle
    /// 启动期间就要求取消：等 applyStart 一有会话就兑现；每次启动前清零。
    private var cancelRequested = false

    /// task id -> 真正收到过提示词的会话（P5 重试续跑）。建了会话但 prompt 失败的
    /// 故意不记：续跑到它会继续一段空对话。只在内存里——重启后安全回退新会话。
    private var promptedSessions: [String: String] = [:]
    /// 点了重试、尚未启动的任务（P5）。是显式标记，不是「看 sessionId」。
    private var pendingRetries: Set<String> = []

    /// 一条任务可运行的时长上限，超时取消其会话。
    static let defaultTimeout: TimeInterval = 60 * 60

    /// 每条任务会话标题带的前缀，让 dsh web 侧栏一眼可辨。
    static let taskSessionTitlePrefix = "WS: "

    var timeoutMinutes: Int { Int(timeout / 60) }

    init(board: WSBoard, env: WSRunnerEnv, timeout: TimeInterval = WorkstreamsRunner.defaultTimeout) {
        self.board = board
        self.env = env
        self.timeout = timeout
    }

    var isBusy: Bool {
        if case .idle = phase { return false }
        return true
    }

    var runningTaskID: String? {
        switch phase {
        case .starting(let id), .finishing(let id): return id
        case .active(let active): return active.taskID
        case .idle: return nil
        }
    }

    /// 正在被处理的任务所在队列（没在跑时 nil）：面板用它标「活跃」。
    var runningQueueID: String? {
        guard let id = runningTaskID else { return nil }
        return board.task(id)?.queueId
    }

    /// 在不触碰运行状态的前提下改 board——面板用它合并新取到的事项。
    func updateBoard(_ transform: (inout WSBoard) -> Void) {
        transform(&board)
        persist()
    }

    /// 换一块板（从磁盘加载后）。什么都不自动启动：重启必须显式「继续」。
    func adopt(_ board: WSBoard) {
        self.board = board
        phase = .idle
    }

    /// 重启恢复：曾 running 的任务不可能还在跑，active 队列暂停。
    @discardableResult
    func reconcileAfterRestart() -> (interrupted: [String], pausedQueues: [String]) {
        let result = board.reconcileAfterRestart(interruptedError: WSFailure.interrupted.rawValue)
        phase = .idle
        persist()
        return result
    }

    // MARK: - 定时器入口

    /// 走一步。只要还有任务在飞就返回 true。
    @discardableResult
    func step(now: Date = Date()) -> Bool {
        switch phase {
        case .starting, .finishing:
            return true
        case .idle:
            _ = pump(now: now)
            return isBusy
        case .active(let active):
            switch env.sessionState(active.sessionId) {
            case .running:
                unknownPolls = 0
                missingPolls = 0
                if now.timeIntervalSince(active.startedAt) > timeout {
                    env.log("workstreams: " + active.taskID + " timed out after "
                            + String(Int(timeout)) + "s")
                    _ = env.cancelSession(active.sessionId)
                    phase = .idle
                    board.markFailed(active.taskID, error: WSFailure.timeout.rawValue, at: now)
                    persist()
                    _ = pump(now: now)
                }
                return isBusy
            case .idle:
                // dsh 列出会话且说它结束了：任务结束。
                finish(active: active, now: now)
                return isBusy
            case .unknown:
                // dsh 答不上来（RPC 失败 / 服务忙）。不假设任何事，下个 tick 再问。
                missingPolls = 0
                if unknownPolls % 10 == 0 {
                    env.log("workstreams: " + active.taskID
                            + " — dsh could not report on its session; still waiting")
                }
                unknownPolls += 1
                return isBusy
            case .missing:
                // dsh 根本不在列表里：侧栏删除，或服务重启。只有持续缺席才算失败。
                unknownPolls = 0
                missingPolls += 1
                if missingPolls >= WorkstreamsRunner.missingSessionPolls {
                    env.log("workstreams: " + active.taskID + " — its session is gone from dsh after "
                            + String(missingPolls) + " polls")
                    phase = .idle
                    board.markFailed(active.taskID, error: WSFailure.sessionGone.rawValue, at: now)
                    persist()
                    _ = pump(now: now)
                }
                return isBusy
            }
        }
    }

    // MARK: - 启动

    /// 串行槽空闲时启动下一条可启动的任务，返回其 id。
    ///
    /// 被 retry() 标记的任务（pendingRetries）可以 CONTINUE 上一轮的会话；其它
    /// pump（skip / 队列推进 / 首次启动）一律开新会话。
    @discardableResult
    func pump(now: Date = Date()) -> String? {
        guard case .idle = phase else { return nil }
        guard let taskID = board.nextStartable(), let task = board.task(taskID) else { return nil }
        let queue = task.queueId.flatMap { board.queue($0) }
        let title = task.title
        let createSession = env.createSession
        let renameSession = env.renameSession
        let promptSession = env.promptSession
        let promptText = env.promptText
        let sessionState = env.sessionState
        let cancelSession = env.cancelSession
        let repoRoot = env.repoRoot
        let log = env.log
        // P5 重试续跑：只在这条 pump 由重试触发、且上一轮真把提示词发给了那个会话时
        // 才复用。消费 pendingRetries 只在真正选中这条任务时发生。
        let isRetry = pendingRetries.remove(taskID) != nil
        let previousSession = task.sessionId
        let promptedSessionsNow = promptedSessions

        phase = .starting(taskID)
        cancelRequested = false
        unknownPolls = 0
        missingPolls = 0
        board.markRunning(taskID, at: now)
        // 本次尝试的完成 marker（P1）：随提示词注入并记在任务 / local.json 上。
        let marker: String? = env.requireCompletionMarker ? WorkstreamsRunner.makeTaskMarker() : nil
        if let marker = marker { board.recordAttemptMarker(taskID, marker) }
        persist()
        log("workstreams: starting " + taskID + " (" + task.title + ")")

        var startResult: StartResult = .failed(.session, nil)
        env.perform({
            // P5：只有「这次是重试 + 上一轮真的 prompt 过这个会话 + 会话现在空闲」三条
            // 同时成立才复用。.running 先取消再回退。
            var resumed: String? = nil
            if isRetry, let previous = previousSession, !previous.isEmpty,
               promptedSessionsNow[taskID] == previous {
                switch sessionState(previous) {
                case .idle:
                    resumed = previous
                case .running:
                    _ = cancelSession(previous)
                    log("workstreams: " + taskID + " — previous session was still running; cancelled it and starting fresh")
                case .unknown, .missing:
                    break
                }
            }
            if let resumed = resumed {
                let continuation = WSPrompts.retryContinuation(title: title, marker: marker)
                if promptSession(resumed, continuation) {
                    log("workstreams: " + taskID + " continuing its previous session " + resumed)
                    startResult = .started(sessionId: resumed)
                    return
                }
                log("workstreams: " + taskID + " could not continue " + resumed + " — starting a fresh one")
            }
            // 阶段提示词（面板生成、注入 body）+ 本次完成 marker（执行阶段的完成协议）。
            let prompt = WorkstreamHandoff.injectingCompletionMarker(promptText(task, queue),
                                                                     marker: marker)
            guard let sessionId = createSession(repoRoot) else {
                startResult = .failed(.session, nil)
                return
            }
            _ = renameSession(sessionId, WorkstreamsRunner.taskSessionTitlePrefix + title)
            guard promptSession(sessionId, prompt) else {
                startResult = .failed(.prompt, sessionId)
                return
            }
            startResult = .started(sessionId: sessionId)
        }, {
            self.applyStart(taskID: taskID, result: startResult, now: now)
        })
        return taskID
    }

    private func applyStart(taskID: String, result: StartResult, now: Date) {
        phase = .idle
        switch result {
        case .started(let sessionId):
            if cancelRequested {
                // 启动期间用户要求取消：会话已存在，取消它而不是让代理继续跑。
                cancelRequested = false
                _ = env.cancelSession(sessionId)
                board.local.sessions[taskID] = sessionId
                if let i = board.index(ofTask: taskID) { board.tasks[i].sessionId = sessionId }
                board.markCancelled(taskID)
                persist()
                env.log("workstreams: " + taskID + " cancelled as soon as its session existed")
                _ = pump(now: now)
                return
            }
            promptedSessions[taskID] = sessionId
            let queueID = board.task(taskID)?.queueId
            phase = .active(Active(taskID: taskID, queueID: queueID, sessionId: sessionId,
                                   startedAt: now, marker: board.task(taskID)?.completionMarker))
            board.local.sessions[taskID] = sessionId
            if let i = board.index(ofTask: taskID) { board.tasks[i].sessionId = sessionId }
            env.log("workstreams: " + taskID + " running in " + sessionId)
            persist()
        case .failed(let failure, let sessionId):
            if let sessionId = sessionId {
                board.local.sessions[taskID] = sessionId
                if let i = board.index(ofTask: taskID) { board.tasks[i].sessionId = sessionId }
            }
            env.log("workstreams: " + taskID + " could not start (" + failure.rawValue + ")")
            board.markFailed(taskID, error: failure.rawValue, at: now)
            persist()
            _ = pump(now: now)
        }
    }

    // MARK: - 结束

    private func finish(active: Active, now: Date) {
        let taskID = active.taskID
        let marker = active.marker
        phase = .finishing(taskID)
        var report: String? = nil
        // 没有 marker 的是 legacy 路径：不设门槛；有 marker 必须由本次 turn 最后一行回显。
        var verified = (marker == nil)
        let sessionReport = env.sessionReport
        env.perform({
            // 汇报在这里读，趁会话还在，并写回任务（卡片展示 + 下一个任务的前置信息）。
            let raw = sessionReport(active.sessionId)
            if let marker = marker {
                verified = WorkstreamsRunner.markerConfirmed(in: raw, marker: marker)
                report = WorkstreamsRunner.strippingMarker(raw, marker: marker)
            } else {
                report = raw
            }
        }, {
            self.board.recordMarkerVerified(taskID, verified)
            if !verified {
                self.env.log("workstreams: " + taskID + " 会话结束但最后汇报没有本次完成标记——待确认（不判 done）")
            }
            let outcome: FinishOutcome = verified ? .done : .needsReview
            self.applyFinish(taskID: taskID, outcome: outcome, now: now, report: report,
                             reviewReason: WSFailure.unverified.rawValue)
        })
    }

    private func applyFinish(taskID: String, outcome: FinishOutcome, now: Date,
                             report: String? = nil, reviewReason: String? = nil) {
        phase = .idle
        switch outcome {
        case .done:
            board.markDone(taskID, report: report, at: now)
            env.log("workstreams: " + taskID + " done")
        case .needsReview:
            let reason = reviewReason ?? WSFailure.unverified.rawValue
            board.markNeedsReview(taskID, reason: reason, report: report, at: now)
            env.log("workstreams: " + taskID + " needs review (" + reason + ") — queue paused")
        case .failed(let failure):
            board.markFailed(taskID, error: failure.rawValue, report: report, at: now)
            env.log("workstreams: " + taskID + " failed (" + failure.rawValue + ")")
        }
        persist()
        _ = pump(now: now)
    }

    // MARK: - 面板动作

    /// 建一条队列（draft，等待态）。附带事项 id；队列不再带阶段（阶段是任务的属性）。
    @discardableResult
    func createQueue(name: String, workstreamID: String = "") -> WSQueue {
        let queue = board.createQueue(name: name, workstreamID: workstreamID)
        persist()
        return queue
    }

    /// 在 draft 队列里批量建任务（建队列 + 入队，唯一入口）。什么都不启动。
    /// 任务带 workstreamId + stage（design A12 / D17）。
    @discardableResult
    func createQueueWithTasks(name: String, workstreamID: String = "",
                              stage: WorkstreamStage? = nil,
                              drafts: [WSTaskDraft]) -> (queue: WSQueue, created: [WSTaskItem]) {
        let queue = board.createQueue(name: name, workstreamID: workstreamID)
        var created: [WSTaskItem] = []
        for draft in drafts where draft.isValid {
            let task = WSTaskItem(id: WSTaskItem.newID(), title: draft.normalizedTitle,
                                  body: draft.effectiveBody,
                                  workstreamId: workstreamID.isEmpty ? nil : workstreamID,
                                  stage: stage)
            board.tasks.append(task)
            board.enqueue(taskID: task.id, into: queue.id)
            created.append(task)
        }
        persist()
        env.log("workstreams: created queue " + queue.id + " (" + queue.name + ") with "
                + String(created.count) + " task(s)")
        return (board.queue(queue.id) ?? queue, created)
    }

    /// 面板建「阶段队列」：按阶段默认动作（或指定动作）生成交接提示词，注入每条任务的
    /// body（design D15 / workstream-handoff-prompt-design §2）。只建等待态队列，不启动；
    /// 卡片的 queues 映射由面板另行写回 WS 卡。queue.name 用阶段中文名。
    @discardableResult
    func createStageQueue(card: WorkstreamCard, stage: WorkstreamStage,
                          workspace: String = "",
                          titles: [String],
                          action: WSStageAction? = nil) -> (queue: WSQueue, created: [WSTaskItem]) {
        let chosen = action ?? WSStageAction.defaultAction(for: stage)
        let drafts = titles.map { title in
            WorkstreamHandoff.stageTask(title: title, card: card, action: chosen,
                                        workspace: workspace)
        }
        return createQueueWithTasks(name: WorkstreamHandoff.stageLabel(stage),
                                    workstreamID: card.id, stage: stage, drafts: drafts)
    }

    /// 往已有队列追加任务（对话里「再补几条」）。不自动启动。任务继承队列的事项，
    /// 阶段由调用方给出（队列不再带阶段；旧队列的 stage 作为兜底）。
    @discardableResult
    func appendTasks(toQueueID queueID: String, stage: WorkstreamStage? = nil,
                     drafts: [WSTaskDraft]) -> [WSTaskItem] {
        guard let queue = board.queue(queueID), queue.state != .closed else { return [] }
        var created: [WSTaskItem] = []
        for draft in drafts where draft.isValid {
            // Inherit the workstream of the queue the task joins (A12).
            let task = WSTaskItem(id: WSTaskItem.newID(), title: draft.normalizedTitle,
                                  body: draft.effectiveBody,
                                  workstreamId: queue.workstreamId.isEmpty ? nil : queue.workstreamId,
                                  stage: stage ?? queue.stage)
            board.tasks.append(task)
            if board.enqueue(taskID: task.id, into: queueID) { created.append(task) }
        }
        persist()
        env.log("workstreams: appended " + String(created.count) + " task(s) to queue " + queueID)
        return created
    }

    /// 入队并在串行槽空闲时启动（「加入队列」=「开始」）。
    @discardableResult
    func enqueue(taskID: String, into queueID: String) -> Bool {
        let wasEmpty = board.queue(queueID)?.taskIds.isEmpty ?? true
        let ok = board.enqueue(taskID: taskID, into: queueID)
        guard ok else { return false }
        if wasEmpty { activateQueueIfIdle(queueID) }
        persist()
        _ = pump()
        return true
    }

    private func activateQueueIfIdle(_ queueID: String) {
        guard board.activeQueue() == nil else { return }
        _ = board.resumeQueue(queueID)
    }

    @discardableResult
    func dequeue(taskID: String) -> Bool {
        let ok = board.dequeue(taskID: taskID)
        if ok { persist() }
        return ok
    }

    /// 开始 / 继续一条队列。
    @discardableResult
    func startQueue(_ queueID: String) -> Bool {
        let ok = board.resumeQueue(queueID)
        if ok {
            persist()
            _ = pump()
        }
        return ok
    }

    @discardableResult
    func pauseQueue(_ queueID: String) -> Bool {
        let ok = board.pauseQueue(queueID)
        if ok { persist() }
        return ok
    }

    /// 指向某条队列：runner 接下来处理它。
    func focus(onQueue queueID: String) {
        guard board.queue(queueID) != nil else { return }
        board.local.activeQueueID = queueID
        persist()
    }

    /// 重试一条失败 / 已取消 / 待确认的任务，并恢复其队列。
    @discardableResult
    func retry(taskID: String) -> Bool {
        let ok = board.retryAndResume(taskID)
        guard ok else { return false }
        persist()
        // P5：显式标记这次是重试——只有它允许续跑上一轮的会话。
        pendingRetries.insert(taskID)
        _ = pump()
        return true
    }

    /// 跳过并继续：保留失败记录，恢复队列，跑下一条。
    @discardableResult
    func skip(taskID: String) -> Bool {
        guard let queueID = board.task(taskID)?.queueId else { return false }
        let ok = board.resumeQueue(queueID)
        if ok {
            persist()
            _ = pump()
        }
        return ok
    }

    /// 标记完成：用户看过待确认任务后确认它真的做完了。
    @discardableResult
    func confirmDone(taskID: String) -> Bool {
        guard let task = board.task(taskID), task.state == .needsReview else { return false }
        let queueID = task.queueId
        board.confirmDone(taskID)
        persist()
        env.log("workstreams: " + taskID + " confirmed done by the user")
        if let queueID = queueID, let queue = board.queue(queueID), queue.state == .paused {
            _ = board.resumeQueue(queueID)
            persist()
        }
        _ = pump()
        return true
    }

    @discardableResult
    func removeQueue(_ queueID: String) -> Bool {
        let removed = board.removeQueue(queueID)
        if removed { persist() }
        return removed
    }

    @discardableResult
    func closeQueue(_ queueID: String) -> Bool {
        let ok = board.closeQueue(queueID)
        if ok {
            persist()
            env.log("workstreams: queue " + queueID + " closed")
        }
        return ok
    }

    /// 取消正在跑的任务：取消会话，保留记录，暂停队列。
    @discardableResult
    func cancelRunning() -> WSCancelOutcome {
        switch phase {
        case .active(let active):
            _ = env.cancelSession(active.sessionId)
            phase = .idle
            board.markCancelled(active.taskID)
            persist()
            env.log("workstreams: " + active.taskID + " cancelled")
            _ = pump()
            return .cancelled
        case .starting(let taskID):
            cancelRequested = true
            env.log("workstreams: cancel requested while " + taskID + " was starting")
            return .deferred
        case .finishing:
            return .finishing
        case .idle:
            return .idle
        }
    }

    // MARK: - 事项启动 = 当前阶段的队列

    /// 某事项的执行队列（一个事项至多一条）；没有就 nil。
    func workstreamQueue(for card: WorkstreamCard) -> WSQueue? {
        board.queue(forWorkstream: card.id, mapping: card.queues)
    }

    /// 某事项下所有已知队列（引擎自有 + WS 卡映射到的）。
    func queues(forWorkstream workstreamID: String) -> [WSQueue] {
        board.queues.filter { $0.workstreamId == workstreamID }
    }

    /// 事项启动 = 启动该事项的队列（design A3 / A9）。直接 resume + pump。
    @discardableResult
    func startWorkstream(_ card: WorkstreamCard) -> Bool {
        guard let queue = workstreamQueue(for: card) else {
            env.log("workstreams: " + card.id + " has no queue")
            return false
        }
        env.log("workstreams: starting " + card.id + " queue " + queue.id)
        return startQueue(queue.id)
    }

    /// 便捷入口：直接给事项 id（+ 可选的 WS 卡队列映射 [q-...]）。
    @discardableResult
    func startWorkstream(_ workstreamID: String, mapping: [String] = []) -> Bool {
        guard let queue = board.queue(forWorkstream: workstreamID, mapping: mapping) else {
            return false
        }
        return startQueue(queue.id)
    }

    // MARK: - marker helpers

    static func makeMarker(prefix: String = "DSH-FINALIZE-") -> String {
        prefix + UUID().uuidString.prefix(8).uppercased()
    }

    /// 事项任务会话的完成 marker（P1）：每任务、每次尝试唯一。
    static func makeTaskMarker() -> String {
        makeMarker(prefix: "DSH-WS-DONE-")
    }

    /// 会话最后的汇报是否回显了本次 marker。只认最后一个非空行。
    static func markerConfirmed(in report: String?, marker: String) -> Bool {
        guard let report = report else { return false }
        let last = report.split(separator: "\n", omittingEmptySubsequences: true)
            .last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return last.contains(marker)
    }

    /// 把 marker 从汇报里去掉：它是壳层的机械信号，不是代理的汇报内容。
    static func strippingMarker(_ report: String?, marker: String?) -> String? {
        guard let report = report, let marker = marker else { return report }
        return report.replacingOccurrences(of: marker, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func persist() {
        env.persist(board)
    }
}
