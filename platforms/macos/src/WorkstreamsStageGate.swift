//
//  WorkstreamsStageGate.swift — per-stage completion evidence + the human gate.
//
//  A workstream moves planning -> design -> execution -> acceptance. Acceptance
//  is the last stage; delivery is an OPERATION on the workstream (design A17),
//  so it has no stage gate of its own.
//  Each stage is complete only when BOTH hold (design A4 / R10 / D3):
//
//    1. a MACHINE predicate passes (this file), and
//    2. a HUMAN confirms it (confirmStage) — via a panel tap, or via a session
//       the user explicitly authorized in that session (R10). An agent never
//       self-signs; the signature is always the person's.
//
//  A stage queue reaching .done is therefore NOT stage completion: it parks the
//  stage in "待确认" (awaitingConfirmation) until a person confirms or sends it
//  back. Sending it back is an allowed back edge and always leaves a trace in
//  the card body ("## 阶段确认"), recording WHO triggered it (source marker:
//  "panel" tap vs "session <id>" authorization).
//
//  Foundation only, so the whole gate is unit-testable headless.
//

import Foundation

// MARK: - Stage order

extension WorkstreamStage {
    /// Canonical order (planning -> ... -> acceptance).
    static var ordered: [WorkstreamStage] {
        [.planning, .design, .task, .acceptance]
    }

    var orderIndex: Int { WorkstreamStage.ordered.firstIndex(of: self) ?? 0 }

    /// The stage this one advances to on confirmation; nil at acceptance, the
    /// last stage (delivery is an operation, not a stage).
    var next: WorkstreamStage? {
        let all = WorkstreamStage.ordered
        let i = orderIndex
        return i + 1 < all.count ? all[i + 1] : nil
    }
}

// MARK: - Carrier (what the queue engine observed)

struct WSStageCarrier: Equatable {
    var hasQueue: Bool
    var done: Bool
    var taskCount: Int
    var allTasksDone: Bool
    var allEvidenceVerified: Bool

    static let none = WSStageCarrier(hasQueue: false, done: true, taskCount: 0,
                                     allTasksDone: true, allEvidenceVerified: true)
}

// MARK: - Evidence

/// One machine-checked evidence line. `key` is the L10n key the panel shows for
/// a missing item, so failures are explained rather than silent.
struct WSStageEvidenceItem: Equatable {
    var key: String
    var passed: Bool
    var detail: String

    init(key: String, passed: Bool, detail: String = "") {
        self.key = key
        self.passed = passed
        self.detail = detail
    }
}

struct WSStageEvidence: Equatable {
    var stage: WorkstreamStage
    var items: [WSStageEvidenceItem]

    var passed: Bool { items.allSatisfy { $0.passed } }
    var missing: [WSStageEvidenceItem] { items.filter { !$0.passed } }
    var missingKeys: [String] { missing.map { $0.key } }
}

// MARK: - Gate

enum WSStageGateState: String, Equatable {
    /// The carrier is still running (or evidence is only being assembled).
    case inProgress
    /// The carrier is done and the machine predicate passes: a human may confirm.
    case awaitingConfirmation
    /// The carrier is done but the machine predicate fails: cannot advance.
    case evidenceMissing
}

struct WSStageGate: Equatable {
    var stage: WorkstreamStage
    var state: WSStageGateState
    var evidence: WSStageEvidence
    var queueDone: Bool
    var history: [WSStageHistoryEntry]

    var canConfirm: Bool { state == .awaitingConfirmation }
    var isAwaitingConfirmation: Bool { state == .awaitingConfirmation }
    var isEvidenceMissing: Bool { state == .evidenceMissing }
}

// MARK: - Source (who triggered the human gate)

/// R10 allows exactly two ways for a person's signature to reach the card: they
/// tap the panel button (`.panel`), or they explicitly authorize a session and
/// the agent in that session relays the call (`.session(id)`). The marker is
/// written into "## 阶段确认", so the audit trail says which one it was. An
/// agent still never self-signs.
enum WSStageSource: Equatable {
    case panel
    case session(String)

    /// The literal marker stored in the card body.
    var marker: String {
        switch self {
        case .panel:
            return "panel"
        case .session(let id):
            let trimmed = id.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "session" : "session " + trimmed
        }
    }

    /// Map an API `session` field to a source: a session-authorized call records
    /// `session <id>`; a session-less call is a direct human action, recorded as
    /// a panel tap (there is no session to attribute it to).
    static func from(session: String?) -> WSStageSource {
        guard let raw = session?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .panel
        }
        return .session(raw)
    }

    static func parse(_ raw: String) -> WSStageSource? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text == "panel" { return .panel }
        if text == "session" { return .session("") }
        if text.hasPrefix("session ") {
            return .session(String(text.dropFirst("session ".count)))
        }
        return nil
    }
}

// MARK: - History (back-edge trace)

struct WSStageHistoryEntry: Equatable {
    enum Action: String {
        case confirm
        case reject
    }

    var date: String
    var action: Action
    var stage: WorkstreamStage
    var target: WorkstreamStage?
    var reason: String?
    /// The R10 source marker; nil for entries written before the marker existed.
    var source: WSStageSource? = nil

    var line: String {
        var text: String
        switch action {
        case .confirm:
            let to = target.map { $0.rawValue } ?? "done"
            text = "- " + date + " \u{00B7} confirm \u{00B7} " + stage.rawValue + " \u{2192} " + to
        case .reject:
            text = "- " + date + " \u{00B7} reject \u{00B7} " + stage.rawValue
            if let target = target, target != stage { text += " \u{2192} " + target.rawValue }
            if let reason = reason, !reason.isEmpty { text += " \u{00B7} " + reason }
        }
        if let source = source { text += " \u{00B7} source:" + source.marker }
        return text
    }
}

// MARK: - The gate

enum WorkstreamsStageGate {

    /// The body section that carries the human-decision audit trail.
    static let historyHeading = "## 阶段确认"

    static let planningHeading = "## 规划"
    static let designHeading = "## 设计"
    static let acceptanceHeading = "## 验收"

    // MARK: Evaluate

    static func evaluate(_ card: WorkstreamCard,
                         carrier: WSStageCarrier = .none,
                         workspace: String = "",
                         fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> WSStageGate {
        let evidence = evaluateEvidence(card, carrier: carrier, workspace: workspace, fileExists: fileExists)
        let queueDone = carrier.hasQueue ? carrier.done : true
        let state: WSStageGateState
        if queueDone && evidence.passed {
            state = .awaitingConfirmation
        } else if queueDone {
            state = .evidenceMissing
        } else {
            state = .inProgress
        }
        return WSStageGate(stage: card.stage, state: state, evidence: evidence,
                           queueDone: queueDone, history: parseHistory(card.body))
    }

    static func evaluateEvidence(_ card: WorkstreamCard,
                                 carrier: WSStageCarrier,
                                 workspace: String,
                                 fileExists: (String) -> Bool) -> WSStageEvidence {
        let items: [WSStageEvidenceItem]
        switch card.stage {
        case .planning:
            items = planningEvidence(card.body)
        case .design:
            items = designEvidence(card.body, workspace: workspace, fileExists: fileExists)
        case .task:
            items = executionEvidence(carrier)
        case .acceptance:
            items = acceptanceEvidence(card)
        }
        return WSStageEvidence(stage: card.stage, items: items)
    }

    // MARK: Planning — the four-piece set (planning-template §4)

    static func planningEvidence(_ body: String) -> [WSStageEvidenceItem] {
        let section = WorkstreamsCore.sectionText(body, heading: planningHeading) ?? ""
        let target = matches(section, pattern: #"(?m)^[ \t]*[-*]?[ \t]*目标([ \t]*[（(][ \t]*WHAT[ \t]*[)）])?[ \t]*[：:][ \t]*\S"#)
        let boundary = matches(section, pattern: #"(?m)^[ \t]*[-*]?[ \t]*边界"#)
        let hasCriteria = section.contains("验收标准")
        let hasAC = matches(section, pattern: #"(?i)AC[ \t]*\d"#)
        let trim = section.contains("阶段裁剪声明")
        return [
            WSStageEvidenceItem(key: "workstreams.evidence.planning.target", passed: target),
            WSStageEvidenceItem(key: "workstreams.evidence.planning.boundary", passed: boundary),
            WSStageEvidenceItem(key: "workstreams.evidence.planning.acceptance", passed: hasCriteria && hasAC,
                                detail: hasCriteria ? (hasAC ? "" : "AC<n>") : ""),
            WSStageEvidenceItem(key: "workstreams.evidence.planning.trim", passed: trim),
        ]
    }

    // MARK: Design — design doc exists + Q closed

    static func designEvidence(_ body: String, workspace: String,
                               fileExists: (String) -> Bool) -> [WSStageEvidenceItem] {
        let section = WorkstreamsCore.sectionText(body, heading: designHeading) ?? ""
        let hasSection = !section.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let declaredTrim = section.contains("裁剪") || body.contains("## 设计（裁剪）")
        let paths = referencedDocPaths(section)
        let docsExist = declaredTrim || paths.contains { fileExists(resolve($0, workspace: workspace)) }
        let open = openQuestions(section)
        return [
            WSStageEvidenceItem(key: "workstreams.evidence.design.section", passed: hasSection),
            WSStageEvidenceItem(key: "workstreams.evidence.design.doc", passed: docsExist,
                                detail: declaredTrim ? "裁剪" : paths.joined(separator: ", ")),
            WSStageEvidenceItem(key: "workstreams.evidence.design.questions", passed: open.isEmpty,
                                detail: open.joined(separator: ", ")),
        ]
    }

    static func referencedDocPaths(_ section: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"docs/[A-Za-z0-9_./-]+\.md"#) else { return [] }
        let ns = section as NSString
        var out: [String] = []
        for match in regex.matches(in: section, range: NSRange(location: 0, length: ns.length)) {
            let path = ns.substring(with: match.range)
            if !out.contains(path) { out.append(path) }
        }
        return out
    }

    static func resolve(_ path: String, workspace: String) -> String {
        if path.hasPrefix("/") { return path }
        guard !workspace.isEmpty else { return path }
        return (workspace as NSString).appendingPathComponent(path)
    }

    static func openQuestions(_ section: String) -> [String] {
        let closedMarkers = ["已确认", "已定", "已关闭", "已拍板", "关闭", "✅", "resolved", "closed"]
        guard let regex = try? NSRegularExpression(pattern: #"(?i)Q[ \t]*[0-9]+"#) else { return [] }
        var open: [String] = []
        for raw in section.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard let match = regex.firstMatch(in: line, range: range) else { continue }
            let token = ns.substring(with: match.range)
            if !closedMarkers.contains(where: { line.contains($0) }) { open.append(token) }
        }
        return open
    }

    // MARK: Execution — marker / product (P1-P5)

    static func executionEvidence(_ carrier: WSStageCarrier) -> [WSStageEvidenceItem] {
        let hasQueue = carrier.hasQueue
        let queueDone = hasQueue && carrier.done
        let hasEvidence = hasQueue && carrier.taskCount > 0
            && carrier.allTasksDone && carrier.allEvidenceVerified
        return [
            WSStageEvidenceItem(key: "workstreams.evidence.task.queue", passed: hasQueue),
            WSStageEvidenceItem(key: "workstreams.evidence.task.done", passed: queueDone),
            WSStageEvidenceItem(key: "workstreams.evidence.task.marker", passed: hasEvidence),
        ]
    }

    // MARK: Acceptance — evidence + covered anchor

    static func acceptanceEvidence(_ card: WorkstreamCard) -> [WSStageEvidenceItem] {
        let section = WorkstreamsCore.sectionText(card.body, heading: acceptanceHeading) ?? ""
        let hasSection = !section.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let covered = card.covered
        let hasCovered = covered != nil && !(covered!.paths.isEmpty)
            && !((covered!.base ?? "").isEmpty) && !((covered!.head ?? "").isEmpty)
        return [
            WSStageEvidenceItem(key: "workstreams.evidence.acceptance.section", passed: hasSection),
            WSStageEvidenceItem(key: "workstreams.evidence.acceptance.covered", passed: hasCovered),
        ]
    }

    // No delivery evidence branch: acceptance is the LAST stage. Delivery is an
    // OPERATION on the workstream (design A17), so the gate never evaluates it;
    // the delivery module reads the card's delivery facts for its own admission
    // checks (WorkstreamsDelivery), not through this gate.

    // MARK: History

    static func parseHistory(_ body: String) -> [WSStageHistoryEntry] {
        guard let text = WorkstreamsCore.sectionText(body, heading: historyHeading) else { return [] }
        var out: [WSStageHistoryEntry] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ") else { continue }
            let fields = String(line.dropFirst(2)).components(separatedBy: " · ")
            guard fields.count >= 3 else { continue }
            let date = fields[0].trimmingCharacters(in: .whitespaces)
            guard let action = WSStageHistoryEntry.Action(rawValue: fields[1].trimmingCharacters(in: .whitespaces)) else { continue }
            let head = fields[2].components(separatedBy: "→").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let stage = WorkstreamStage.parse(head[0]) else { continue }
            let target = head.count > 1 ? WorkstreamStage.parse(head[1]) : nil
            var source: WSStageSource? = nil
            var rest: [String] = []
            for field in fields.dropFirst(3) {
                if field.hasPrefix("source:") {
                    source = WSStageSource.parse(String(field.dropFirst("source:".count)))
                } else {
                    rest.append(field)
                }
            }
            let reason = rest.isEmpty ? nil : rest.joined(separator: " · ")
            out.append(WSStageHistoryEntry(date: date, action: action, stage: stage,
                                           target: target, reason: reason, source: source))
        }
        return out
    }

    static func appendingHistory(_ body: String, entry: WSStageHistoryEntry) -> String {
        let existing = WorkstreamsCore.sectionText(body, heading: historyHeading) ?? ""
        var lines = existing.isEmpty ? [] : existing.components(separatedBy: "\n")
        lines.append(entry.line)
        let section = historyHeading + "\n\n" + lines.joined(separator: "\n")
        return WorkstreamsCore.replaceSection(body, heading: historyHeading, with: section)
    }

    // MARK: JSON

    static func json(_ gate: WSStageGate) -> [String: Any] {
        var out: [String: Any] = [
            "stage": gate.stage.rawValue,
            "state": gate.state.rawValue,
            "queueDone": gate.queueDone,
            "canConfirm": gate.canConfirm,
            "passed": gate.evidence.passed,
            "evidence": gate.evidence.items.map { item -> [String: Any] in
                ["key": item.key, "passed": item.passed, "detail": item.detail]
            },
            "missing": gate.evidence.missingKeys,
        ]
        if !gate.history.isEmpty {
            out["history"] = gate.history.map { entry -> [String: Any] in
                var e: [String: Any] = ["date": entry.date, "action": entry.action.rawValue,
                                        "stage": entry.stage.rawValue]
                if let target = entry.target { e["target"] = target.rawValue }
                if let reason = entry.reason { e["reason"] = reason }
                if let source = entry.source { e["source"] = source.marker }
                return e
            }
        }
        return out
    }

    static func matches(_ text: String, pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression]) != nil
    }
}

// MARK: - Human confirmation gate (R10)

extension WorkstreamsCore {

    /// Evaluate the gate for a loaded card + carrier.
    static func stageGate(_ card: WorkstreamCard, carrier: WSStageCarrier = .none,
                          workspace: String = "",
                          fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> WSStageGate {
        WorkstreamsStageGate.evaluate(card, carrier: carrier, workspace: workspace, fileExists: fileExists)
    }

    /// The human confirmation gate (R10). Advances the stage ONLY when the
    /// machine predicate passes; otherwise throws .evidenceMissing and leaves the
    /// card untouched (the "missing evidence does not advance" rule).
    @discardableResult
    static func confirmStage(workspace: String,
                             id: String,
                             expectedStage: WorkstreamStage? = nil,
                             carrier: WSStageCarrier = .none,
                             note: String? = nil,
                             source: WSStageSource = .panel,
                             today: String,
                             fileManager: FileManager = .default) throws -> WorkstreamCard {
        var card = try loadCard(workspace: workspace, id: id, fileManager: fileManager)
        if let expected = expectedStage, expected != card.stage {
            throw WorkstreamError.stageChanged(expected.rawValue, card.stage.rawValue)
        }
        let gate = WorkstreamsStageGate.evaluate(card, carrier: carrier, workspace: workspace)
        guard gate.canConfirm else {
            throw WorkstreamError.evidenceMissing(gate.evidence.missingKeys)
        }
        let target = card.stage.next
        let clearNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = WSStageHistoryEntry(date: today, action: .confirm, stage: card.stage,
                                        target: target,
                                        reason: (clearNote?.isEmpty ?? true) ? nil : clearNote,
                                        source: source)
        card.body = WorkstreamsStageGate.appendingHistory(card.body, entry: entry)
        if let target = target { card.stage = target }
        card.updated = today
        return try write(card, fileManager: fileManager)
    }

    /// The back edge (R2): a human sends the stage back for rework. Always leaves
    /// a trace with a reason; target may move the card to an earlier stage.
    @discardableResult
    static func rejectStage(workspace: String,
                            id: String,
                            reason: String,
                            target: WorkstreamStage? = nil,
                            source: WSStageSource = .panel,
                            today: String,
                            fileManager: FileManager = .default) throws -> WorkstreamCard {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { throw WorkstreamError.missingReason }
        var card = try loadCard(workspace: workspace, id: id, fileManager: fileManager)
        let entry = WSStageHistoryEntry(date: today, action: .reject, stage: card.stage,
                                        target: target, reason: reason, source: source)
        card.body = WorkstreamsStageGate.appendingHistory(card.body, entry: entry)
        if let target = target { card.stage = target }
        card.updated = today
        return try write(card, fileManager: fileManager)
    }
}
