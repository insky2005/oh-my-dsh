import Foundation

// MARK: - 任务会话 → 主场会话汇总（会话模型：事项 = 主场会话 + 任务会话）
//
// 一条任务会话跑完就消失，事项的进展必须回到**主场会话**（人看的那条对话）。
// runner 在 applyFinish 之后按两种粒度回报：
//   - **阶段批量**：一个阶段的任务都结束了，汇总一次（正常路径）；
//   - **例外即时**：失败 / 待确认立刻回报（不等阶段收尾——阶段可能永远收不了尾）。
//
// 本模块只做**纯文本**：状态 + 每条任务的汇报 + PR / 提交事实。发到哪条会话由
// 调用方决定（面板读 .dsh/workstreams/local.json 的 workstreamSessions，
// **无绑定不发**，见 WorkstreamsSummary.homeSession）。
//
// 不 import AppKit、不碰磁盘、不碰 git —— 事实（PR / 提交）由调用方注入，
// 因此整段文案可以在 headless 测试里逐字断言。

// MARK: - 汇总事实（PR / 提交）

/// 汇总里的事实。runner 不碰 git 与卡片：面板从 WS 卡的 delivery / covered 读
/// 事实后注入；没有事实就省略对应的两行。
struct WSSummaryFacts: Equatable {
    /// PR 链接或编号（如 "https://github.com/o/r/pull/7" / "PR #7"）。
    var pr: String?
    /// 提交（短 sha 或 "base..head"）。
    var commit: String?

    init(pr: String? = nil, commit: String? = nil) {
        self.pr = WSSummary.trimmed(pr)
        self.commit = WSSummary.trimmed(commit)
    }

    var isEmpty: Bool { pr == nil && commit == nil }
}

// MARK: - 参与汇总的任务快照

/// 汇总里的一条任务：是任务状态的**快照**，不是可变的 board 条目。
struct WSSummaryTask: Equatable {
    var id: String
    var title: String
    var state: WSTaskState
    var report: String?
    /// 失败 / 待确认原因的原文（runner 写的是 L10n 键，如 workstreams.errTimeout）。
    var error: String?

    init(_ task: WSTaskItem) {
        self.id = task.id
        self.title = task.title
        self.state = task.state
        self.report = WSSummary.trimmed(task.report)
        self.error = WSSummary.trimmed(task.error)
    }

    var stateLabel: String { WSSummary.stateLabel(state) }

    /// 失败 / 待确认的中文原因；其它状态或没有原因时为 nil。
    var reasonLabel: String? {
        guard state == .failed || state == .needsReview else { return nil }
        return WSSummary.reasonLabel(error)
    }

    /// 汇报的首行（截断），没有汇报时 nil。汇报是写给下一个任务 / 人的，不是日志转储。
    var reportLine: String? {
        guard let report = report else { return nil }
        let first = report.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line = first else { return nil }
        return WSSummary.excerpt(line)
    }
}

// MARK: - 汇总

/// 汇总的两种粒度。
enum WSSummaryKind: Equatable {
    /// 阶段批量：一个阶段的任务都结束了。
    case stageBatch
    /// 例外即时：某条任务失败 / 待确认，立刻回报。
    case exception

    var title: String {
        switch self {
        case .stageBatch: return "阶段完成"
        case .exception: return "例外"
        }
    }
}

/// 发往事项主场会话的一条汇总。
struct WSSummary: Equatable {
    var kind: WSSummaryKind
    var workstreamID: String
    var stage: WorkstreamStage?
    var tasks: [WSSummaryTask]
    var facts: WSSummaryFacts

    init(kind: WSSummaryKind, workstreamID: String, stage: WorkstreamStage?,
         tasks: [WSSummaryTask], facts: WSSummaryFacts = WSSummaryFacts()) {
        self.kind = kind
        self.workstreamID = workstreamID
        self.stage = stage
        self.tasks = tasks
        self.facts = facts
    }

    /// 发给主场会话的正文。
    var text: String { WSSummary.render(self) }

    /// 同事项同阶段的一次批量只能汇总一次：key 用于 runner 去重（同阶段下一批
    /// 任务启动时重置）。
    static func stageKey(workstream: String, stage: WorkstreamStage) -> String {
        workstream + "\u{1F}" + stage.rawValue
    }
}

// MARK: - 纯文案

extension WSSummary {
    /// 四种状态的中文名（任务卡 / 汇总共用这一套说法）。
    static func stateLabel(_ state: WSTaskState) -> String {
        switch state {
        case .pending: return "待启动"
        case .queued: return "排队"
        case .running: return "运行中"
        case .done: return "完成"
        case .failed: return "失败"
        case .needsReview: return "待确认"
        case .cancelled: return "已取消"
        }
    }

    static func stageName(_ stage: WorkstreamStage) -> String {
        switch stage {
        case .planning: return "规划"
        case .design: return "设计"
        case .task: return "执行"
        case .acceptance: return "验收"
        }
    }

    /// runner 写进任务的失败原因都是 L10n 键。汇总发给代理（不是面板），用它读得懂的
    /// 中文；键表与 WorkstreamsRunner.WSFailure 对齐，未知值原样返回。
    static func reasonLabel(_ raw: String?) -> String? {
        guard let raw = trimmed(raw) else { return nil }
        switch raw {
        case "workstreams.errInterrupted": return "应用退出 / 重启，会话随之中断"
        case "workstreams.errSessionGone": return "会话在 dsh 里消失（被删除或服务重启）"
        case "workstreams.errSession": return "无法创建会话"
        case "workstreams.errPrompt": return "提示词发送失败"
        case "workstreams.errTimeout": return "超时"
        case "workstreams.errUnverified": return "会话结束但最后一行没有本次完成标记（完成校验未通过）"
        default: return raw
        }
    }

    static func trimmed(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    /// 汇报里出现的第一条 GitHub PR 链接（没有注入 PR 事实时的兜底）。
    static func prURL(in text: String?) -> String? {
        guard let text = text,
              let range = text.range(of: #"https?://[^\s]*github\.com/[^\s]*/pull/[0-9]+"#,
                                     options: .regularExpression) else { return nil }
        return String(text[range])
    }

    static func excerpt(_ line: String, limit: Int = 120) -> String {
        guard line.count > limit else { return line }
        return String(line.prefix(max(0, limit - 1))) + "…"
    }

    /// 状态行：只报实际出现的档位，避免「0 失败」这类噪音。
    static func statusLine(_ tasks: [WSSummaryTask]) -> String {
        let done = tasks.filter { $0.state == .done }.count
        let failed = tasks.filter { $0.state == .failed }.count
        let review = tasks.filter { $0.state == .needsReview }.count
        let cancelled = tasks.filter { $0.state == .cancelled }.count
        let other = tasks.count - done - failed - review - cancelled
        var parts: [String] = []
        if done > 0 { parts.append("\(done) 完成") }
        if failed > 0 { parts.append("\(failed) 失败") }
        if review > 0 { parts.append("\(review) 待确认") }
        if cancelled > 0 { parts.append("\(cancelled) 已取消") }
        if other > 0 { parts.append("\(other) 进行中") }
        return parts.isEmpty ? "无任务" : parts.joined(separator: " / ")
    }

    static func render(_ summary: WSSummary) -> String {
        var lines: [String] = []
        lines.append("【事项汇总 · " + summary.kind.title + "】" + summary.workstreamID)
        lines.append("阶段：" + (summary.stage.map(stageName) ?? "未标阶段"))
        lines.append("状态：" + statusLine(summary.tasks))
        if summary.kind == .exception, let first = summary.tasks.first,
           let reason = first.reasonLabel {
            lines.append("原因：" + reason)
        }
        if !summary.tasks.isEmpty {
            lines.append("任务：")
            for task in summary.tasks {
                var head = "- [" + task.stateLabel + "] " + task.title
                if let reason = task.reasonLabel {
                    head += "（" + reason + "）"
                }
                lines.append(head)
                if let report = task.reportLine {
                    lines.append("  汇报：" + report)
                }
            }
        }
        // PR 事实优先；没有注入时再看任务汇报里有没有 PR 链接。
        let pr = summary.facts.pr ?? summary.tasks.compactMap { prURL(in: $0.report) }.first
        if let pr = pr { lines.append("PR：" + pr) }
        if let commit = summary.facts.commit { lines.append("提交：" + commit) }
        lines.append(summary.kind == .exception
            ? "说明：这是任务队列的自动汇总，不代表人已确认；队列已暂停，请到事项面板处理（重试 / 标记完成 / 退回）。"
            : "说明：这是任务队列的自动汇总，不代表人已确认；阶段推进仍由人在面板确认，不要自行调用 stage/confirm。")
        return lines.joined(separator: "\n")
    }
}

// MARK: - 发到哪条会话（无绑定不发）

extension WorkstreamsSummary {
    /// 汇总的主场会话：只认 local.json 的 workstreamSessions（A16）。
    /// 没有绑定 / 绑定为空 → nil → **不发**（不凭空起会话，也不回退当前会话）。
    static func homeSession(for workstreamID: String, in local: WSLocalState) -> String? {
        guard let workstreamID = WSSummary.trimmed(workstreamID) else { return nil }
        return WSSummary.trimmed(local.workstreamSessions[workstreamID])
    }
}

// MARK: - Board 侧的选择（纯查询，不改状态）

extension WSBoard {
    /// 任务所属事项：任务自带 workstreamId；旧任务回落到它所在队列的 workstreamId。
    func workstreamID(ofTask taskID: String) -> String? {
        guard let task = task(taskID) else { return nil }
        if let id = WSSummary.trimmed(task.workstreamId) { return id }
        guard let queueID = task.queueId, let queue = queue(queueID),
              let id = WSSummary.trimmed(queue.workstreamId) else { return nil }
        return id
    }

    /// 任务所处阶段：任务自带 stage；旧任务回落到队列的旧 stage 字段。
    func stage(ofTask taskID: String) -> WorkstreamStage? {
        guard let task = task(taskID) else { return nil }
        if let stage = task.stage { return stage }
        guard let queueID = task.queueId, let queue = queue(queueID) else { return nil }
        return queue.stage
    }

    /// 同事项同阶段的任务（板上创建顺序）。旧任务缺 workstreamId / stage 时回落队列。
    func tasks(forWorkstream workstream: String, stage: WorkstreamStage) -> [WSTaskItem] {
        tasks.filter { task in
            let ws = WSSummary.trimmed(task.workstreamId)
                ?? task.queueId.flatMap { queue($0)?.workstreamId }
            let st = task.stage ?? task.queueId.flatMap { queue($0)?.stage }
            return ws == workstream && st == stage
        }
    }

    /// 该事项该阶段的任务是否都结束了（失败 / 待确认 / 已取消也算结束）。
    /// 无任务 = false：没有东西可汇总。
    func stageFinished(forWorkstream workstream: String, stage: WorkstreamStage) -> Bool {
        let items = tasks(forWorkstream: workstream, stage: stage)
        return !items.isEmpty && items.allSatisfy { $0.state.isFinished }
    }
}

// 汇总与「发到哪条会话」的命名空间（纯函数，无副作用）。
enum WorkstreamsSummary {}
