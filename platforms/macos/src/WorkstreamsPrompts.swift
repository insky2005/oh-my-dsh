import Foundation

// MARK: - 阶段交接提示词（design D15 / workstream-handoff-prompt-design）
//
// 把「一个事项的当前阶段」交给新会话时，壳层生成这段提示词并注入**阶段队列任务的
// body**（design §2 原则 1：提示词是指针，不是状态副本；§2 原则 3：变量从卡片注入）。
// 这里是纯函数：不 import AppKit、不读磁盘、不引用任务面板，输入一张 WorkstreamCard
// 即可，因此可以 headless 单测。
//
// (stage, action) 映射见 design §4；执行阶段的完成协议仍是 runner 注入的完成 marker
// （completionMarkerInstruction / injectingCompletionMarker），本文件只负责把要求写进
// 提示词正文。

// MARK: - (stage, action)

/// design §4「stage → action」表的动作。执行阶段有两个动作：先「拆分任务」，人确认
/// 后再「启动实施」。
enum WSStageAction: String, CaseIterable, Equatable {
    case confirmPlanning
    case produceDesign
    case splitTasks
    case startImplementation
    case verify
    case deliver

    /// 该动作所属的阶段（执行阶段的两个动作都归 .task）。
    var stage: WorkstreamStage {
        switch self {
        case .confirmPlanning: return .planning
        case .produceDesign: return .design
        case .splitTasks, .startImplementation: return .task
        case .verify: return .acceptance
        case .deliver: return .delivery
        }
    }

    /// 写进提示词「本步动作」的中文名。
    var label: String {
        switch self {
        case .confirmPlanning: return "确认规划"
        case .produceDesign: return "出设计"
        case .splitTasks: return "拆分任务"
        case .startImplementation: return "启动实施"
        case .verify: return "校验"
        case .deliver: return "交付"
        }
    }

    /// 每个阶段的默认动作（执行阶段从「拆分任务」开始，确认后才「启动实施」）。
    static func defaultAction(for stage: WorkstreamStage) -> WSStageAction {
        switch stage {
        case .planning: return .confirmPlanning
        case .design: return .produceDesign
        case .task: return .splitTasks
        case .acceptance: return .verify
        case .delivery: return .deliver
        }
    }
}

// MARK: - 生成器

/// 面板生成阶段提示词的唯一入口。所有输出都是确定性的纯文本（卡片同 -> 提示词同），
/// 便于测试与「提示词是卡片的函数」这条原则。
enum WorkstreamHandoff {
    /// 面板生成的提示词一定包含这两句；runner 用它判断任务 body 是不是一段完整的
    /// 阶段交接提示词（是则原样发送，不再包任务模板）。
    static let factsMarker = "本步事实："
    static let stageMarker = "当前 stage："

    /// 阶段的中文名（面板设计 §4：用「执行」而非「任务」）。
    static func stageLabel(_ stage: WorkstreamStage) -> String {
        switch stage {
        case .planning: return "规划"
        case .design: return "设计"
        case .task: return "执行"
        case .acceptance: return "验收"
        case .delivery: return "交付"
        }
    }

    /// 一段提示词是不是面板生成的阶段交接提示词。
    static func isHandoff(_ text: String) -> Bool {
        text.contains(factsMarker) && text.contains(stageMarker)
    }

    // MARK: 提示词

    /// 按阶段默认动作生成。
    static func prompt(card: WorkstreamCard,
                       stage: WorkstreamStage,
                       workspace: String = "",
                       repoName: String? = nil) -> String {
        prompt(card: card, action: .defaultAction(for: stage),
               workspace: workspace, repoName: repoName)
    }

    /// 生成 (stage, action) 的完整交接提示词：
    /// design §3 公共头 + §4 动作段 + §4 模型规则（强制）。
    static func prompt(card: WorkstreamCard,
                       action: WSStageAction,
                       workspace: String = "",
                       repoName: String? = nil) -> String {
        var lines: [String] = []
        lines.append("你在 " + resolvedRepoName(repoName, workspace: workspace) + " 处理一个事项。")
        lines.append("")
        lines.append(factsMarker)
        lines.append("- 事项：.dsh/workstreams/" + card.id + ".md")
        if let requirement = nonEmpty(card.requirement) {
            lines.append("- 需求：.dsh/requirements/" + requirement + ".md")
        }
        lines.append("- 存储约定：.dsh/requirements/README.md（通用规则见工作区 AGENTS.md）")
        lines.append("")
        lines.append(stageMarker + stageLabel(action.stage) + "      本步动作：" + action.label)
        if let goal = planningGoal(card.body) {
            lines.append("目标：" + goal)
        }
        lines.append("")
        lines.append(actionSection(action))
        lines.append("")
        lines.append(rulesSection(card))
        return lines.joined(separator: "\n")
    }

    /// 面板建阶段队列任务：提示词由壳层生成、注入任务 body（design §2 原则 1/3）。
    static func stageTask(title: String,
                          card: WorkstreamCard,
                          action: WSStageAction,
                          workspace: String = "",
                          repoName: String? = nil) -> WSTaskDraft {
        WSTaskDraft(title: title,
                    body: prompt(card: card, action: action,
                                 workspace: workspace, repoName: repoName))
    }

    /// 把阶段提示词注入一条已存在的任务 body（补任务 / 重建阶段队列时）。
    static func injectingStagePrompt(into task: WSTaskItem,
                                     card: WorkstreamCard,
                                     action: WSStageAction,
                                     workspace: String = "",
                                     repoName: String? = nil) -> WSTaskItem {
        var copy = task
        copy.body = prompt(card: card, action: action, workspace: workspace, repoName: repoName)
        return copy
    }

    // MARK: 完成 marker（执行阶段沿用）

    /// 完成标记要求（P1 完成协议）：追加在提示词末尾，会话须在最后一行原样回显。
    static func completionMarkerInstruction(_ marker: String) -> String {
        "完成前，请在最后一行原样输出以下标记（供面板识别本次任务已结束）：\n" + marker
    }

    /// 把完成 marker 注入提示词末尾。执行阶段沿用 runner 的 marker 完成协议；
    /// marker 为空时原样返回（legacy / headless 路径）。
    static func injectingCompletionMarker(_ prompt: String, marker: String?) -> String {
        guard let marker = nonEmpty(marker) else { return prompt }
        return prompt + "\n\n" + completionMarkerInstruction(marker)
    }

    // MARK: 动作段（design §4）

    /// 每个动作的「做什么」+「何时停下」。
    static func actionSection(_ action: WSStageAction) -> String {
        switch action {
        case .confirmPlanning:
            return section([
                "本步做「确认规划」：",
                "- 用 `/api/workstreams/plan` 补齐本事项卡片「## 规划」的四件套——目标（WHAT）/ 边界 / 验收标准（AC<n>）/ 阶段裁剪声明；**不直接改 `.dsh` 文件**。",
                "- 四件套齐后**停下请人确认规划**；人确认前不得进入设计。",
            ])
        case .produceDesign:
            return section([
                "本步做「出设计」：",
                "- 在 `docs/design/**` 写本事项的设计文档，把待确认问题列成 Q 表。",
                "- **只写设计，不写实现**；写完**停下请人确认设计**。",
            ])
        case .splitTasks:
            return section([
                "本步做「拆分任务」：",
                "- 用 `/task-todo` 建**等待态队列 + 批量入队**（= 任务拆分本身，只建不启动）。",
                "- 用 `/api/workstreams/queues` 把阶段 ↔ 队列映射记进卡片 `queues`；**停下请人确认拆分合理**。",
            ])
        case .startImplementation:
            return section([
                "本步做「启动实施」：",
                "- 人确认拆分后，用 `/task-todo 启动队列`（`queue/start`）启动实施。",
                "- 在已确认的边界内改代码 / 跑测试 / commit：切分支、conventional commits。",
            ])
        case .verify:
            return section([
                "本步做「校验」：",
                "- 跑回归门与机检证据（覆盖 / 测试 / 产物校验）。",
                "- **必须由人 sign-off，agent 不自签**。",
            ])
        case .deliver:
            return section([
                "本步做「交付」：",
                "- push / 开 PR；交付事实（`covered` / PR）由面板记录，**不直接改 `.dsh` 文件**。",
                "- `outcome` 是派生谓词缓存，**不手写**。",
            ])
        }
    }

    /// 共用模型规则（design §4，强制）；回归门一条只在卡片登记了 REG-* 时出现。
    static func rulesSection(_ card: WorkstreamCard) -> String {
        var lines: [String] = ["规则（强制）："]
        lines.append("- 改事项卡片一律走 `/api/workstreams/*`（`workstream-panel` 技能）；**不直接改 `.dsh` 文件**。")
        lines.append("- 回边合法但必须留痕；跳过 / 裁剪必须在「规划」声明。")
        lines.append("- 只拆不胀：范围外的新发现回需求池（R5），不就地吸收。")
        lines.append("- 裁决是点记录；覆盖锚变更；终态是派生谓词（不写 `closed` / `outcome`）。")
        if let regression = nonEmpty(card.regression) {
            lines.append("- 回归门 " + regression + "：若改动其覆盖路径，交付前运行。")
        }
        lines.append("- 任务阶段用 `/task-todo` 落地（拆分 = 建等待态队列、实施 = 启动、交付 = deliver）。")
        lines.append("- 不改其它会话的在途文件。")
        return lines.joined(separator: "\n")
    }

    // MARK: 目标（design §6：卡片的「规划.目标」）

    /// 从卡片正文「## 规划」段里取「目标」条目的值；没有就返回 nil（公共头省略该行）。
    /// 兼容「- 目标：…」「- 目标（WHAT）：…」以及缩进续行。
    static func planningGoal(_ body: String) -> String? {
        guard let sectionText = WorkstreamsCore.sectionText(body, heading: "## 规划") else { return nil }
        let lines = sectionText.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { goalValue($0) != nil }) else { return nil }
        var parts: [String] = []
        if let first = goalValue(lines[index]) { parts.append(first) }
        let baseIndent = indent(lines[index])
        var i = index + 1
        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            if indent(raw) <= baseIndent { break }
            if trimmed.hasPrefix("-") { break }
            parts.append(trimmed)
            i += 1
        }
        let value = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: 小工具

    /// 一行是不是「目标」条目；是则返回冒号后的值。
    private static func goalValue(_ line: String) -> String? {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("- ") { text = String(text.dropFirst(2)) }
        else if text.hasPrefix("-") { text = String(text.dropFirst()) }
        text = text.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("目标") else { return nil }
        guard let colon = text.firstIndex(where: { $0 == "：" || $0 == ":" }) else { return nil }
        let value = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func indent(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    private static func resolvedRepoName(_ explicit: String?, workspace: String) -> String {
        if let explicit = nonEmpty(explicit) { return explicit }
        let path = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return "当前工作区" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? "当前工作区" : name
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
    }

    private static func section(_ lines: [String]) -> String { lines.joined(separator: "\n") }
}
