//
//  RequirementsCore.swift — pure model for the Requirements Pool panel (right-side slot #10).
//
//  The panel treats ".dsh/requirements/REQ-*.md" + ".dsh/workstreams/WS-*.md" as the
//  single source of truth (docs/design/panels/requirements-workstream-store-design.md).
//  This file owns the four model-level questions and nothing else:
//
//    1. what is on disk?              -> load()          (parse cards, aggregate children)
//    2. what is the effective state?  -> effectiveState() (discarded > closed > split > state)
//    3. where is the pending breakdown? -> parseProposal() / propose()
//    4. write one card, atomically    -> createRequirement() / setState() / confirm() / reject()
//
//  No AppKit, no networking: the panel (RequirementsPanel.swift) and the localhost API
//  (RequirementsAPI.swift) both call in here, so the whole model is unit-testable
//  headlessly (tests/requirements-panel/run.sh).
//
//  Design: docs/design/panels/requirements-pool-panel-design.md (§3).
//

import Foundation

// MARK: - Errors

/// Model errors, each mapped to one API error code + one bilingual panel message.
enum PoolError: Error, Equatable {
    case noWorkspace
    case unknownRequirement(String)
    case noProposal
    case unknownState(String)
    case missingTitle
    case noItems
    case breakdownLocked(String)
    case invalidTransition(String, String)
    case writeFailed(String)

    /// The stable code the localhost API returns (design §4).
    var code: String {
        switch self {
        case .noWorkspace: return "no-workspace"
        case .unknownRequirement: return "unknown-requirement"
        case .noProposal: return "no-proposal"
        case .unknownState: return "unknown-state"
        case .missingTitle: return "missing-title"
        case .noItems: return "no-items"
        case .breakdownLocked: return "breakdown-locked"
        case .invalidTransition: return "invalid-transition"
        case .writeFailed: return "write-failed"
        }
    }

    /// The HTTP status the router maps this onto.
    var status: Int {
        switch self {
        case .unknownRequirement: return 404
        case .noProposal: return 409
        case .breakdownLocked: return 409
        case .invalidTransition: return 409
        case .writeFailed: return 500
        default: return 400
        }
    }

    var message: String {
        switch self {
        case .noWorkspace: return "workspace is missing or not a directory"
        case .unknownRequirement(let id): return "no such requirement: " + id
        case .noProposal: return "no pending breakdown proposal"
        case .unknownState(let s): return "unknown requirement state: " + s
        case .missingTitle: return "title is required"
        case .noItems: return "breakdown proposal needs at least one item"
        case .breakdownLocked(let id): return "requirement already has workstreams, cannot edit: " + id
        case .invalidTransition(let from, let to): return "state transition not allowed: " + from + " -> " + to
        case .writeFailed(let why): return "write failed: " + why
        }
    }
}

// MARK: - Value types

/// The derived pool state a requirement shows in the panel. split / closed are never
/// written to the card (design §3.3 / store design §5).
enum ReqEffectiveState: String, Equatable, CaseIterable {
    case candidate
    case evaluating
    case evaluated
    case suspended
    case discarded
    case split
    case closed
}

/// One requirement card (frontmatter + body). Only the fields the panel needs.
struct RequirementCard: Equatable {
    var id: String
    var title: String
    /// Manual judgement only (candidate / evaluating / suspended / discarded); nil = candidate.
    var state: String?
    var source: String
    var created: String
    var updated: String
    var path: String
    var body: String
    /// The dsh session that captured this card — a machine-scoped runtime binding
    /// kept in .dsh/requirements/local.json (gitignored), never in the card. nil
    /// for cards created from the panel.
    var session: String? = nil
}

extension RequirementCard {
    /// The `## 诉求` text (or the body with headings stripped) — what the card
    /// shows as its content preview.
    var statement: String { RequirementsCore.statement(from: body) }
}

/// One workstream card, summarised (the panel shows it read-only).
struct WorkstreamSummary: Equatable {
    var id: String
    var title: String
    var requirement: String?
    var stage: String
    /// delivery.outcome derived cache (read-only; nil = unknown / not delivered).
    var outcome: String?
    var path: String
}

/// One line of a pending breakdown proposal.
struct BreakdownItem: Equatable {
    var title: String
    var boundary: String
    var dependsOn: [String]
}

/// One row of the CONFIRMED breakdown list in the requirement's 拆解 section.
/// This is the REQ-authoritative CONTENT (id / title / boundary / deps). 状态 is
/// deliberately NOT stored here: stage / outcome always come from the WS card.
struct ConfirmedItem: Equatable {
    /// 标识: the workstream id, or nil for a candidate row that has no card.
    var id: String?
    var title: String
    var boundary: String
    /// 依赖: workstream ids (raw text preserved when it holds no WS id).
    var dependsOn: [String]
}

/// A requirement as the panel renders it: card + derived state + children + proposal
/// + the confirmed breakdown list read from the card body.
struct PoolItem: Equatable {
    var requirement: RequirementCard
    var effectiveState: ReqEffectiveState
    var children: [WorkstreamSummary]
    /// Pending (unconfirmed) breakdown proposal; nil = none.
    var proposal: [BreakdownItem]?
    /// Confirmed breakdown rows (拆解 table); empty when not broken down yet.
    var confirmed: [ConfirmedItem] = []
}

/// Everything a panel render / API list needs at once.
struct PoolSnapshot: Equatable {
    var workspace: String
    var dshExists: Bool
    var requirements: [PoolItem]
    var workstreams: [WorkstreamSummary]
    var unparsed: [String]
}

// MARK: - Core

enum RequirementsCore {

    /// Manual pool states (design §3.3); split / closed are derived and must not appear.
    static let manualStates: [String] = ["candidate", "evaluating", "evaluated", "suspended", "discarded"]

    /// Delivery outcomes that make a workstream terminal (store design §5/§6).
    static let terminalOutcomes: Set<String> = ["merged", "closed", "abandoned"]

    static let breakdownHeading = "## 拆解"

    // MARK: Paths

    static func dshDir(_ workspace: String) -> String {
        (workspace as NSString).appendingPathComponent(".dsh")
    }

    static func requirementsDir(_ workspace: String) -> String {
        (dshDir(workspace) as NSString).appendingPathComponent("requirements")
    }

    static func workstreamsDir(_ workspace: String) -> String {
        (dshDir(workspace) as NSString).appendingPathComponent("workstreams")
    }

    static func requirementPath(_ workspace: String, id: String) -> String {
        (requirementsDir(workspace) as NSString).appendingPathComponent(id + ".md")
    }

    /// Machine-scoped runtime bindings (REQ-id -> capturing dsh session). Ignored
    /// by git (see .gitignore / store design §4).
    static func localSessionsPath(_ workspace: String) -> String {
        (requirementsDir(workspace) as NSString).appendingPathComponent("local.json")
    }

    static func loadSessions(workspace: String) -> [String: String] {
        guard let text = readText(localSessionsPath(workspace)),
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = object["sessions"] as? [String: String] else { return [:] }
        return sessions
    }

    /// Best-effort: a missing binding only means "fall back to the current session".
    static func rememberSession(workspace: String, id: String, session: String) {
        guard !session.isEmpty else { return }
        var sessions = loadSessions(workspace: workspace)
        sessions[id] = session
        guard let data = try? JSONSerialization.data(withJSONObject: ["sessions": sessions],
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        try? atomicWrite(text, to: localSessionsPath(workspace))
    }

    static func workstreamPath(_ workspace: String, id: String) -> String {
        (workstreamsDir(workspace) as NSString).appendingPathComponent(id + ".md")
    }

    /// Today as the card date format (injectable so tests never depend on the clock).
    static func today(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: Frontmatter parsing

    /// Split a card into its frontmatter block and the body after it. nil when the
    /// card has no complete --- ... --- block.
    static func splitCard(_ text: String) -> (frontmatter: String, body: String)? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        guard let end = lines[(start + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        let frontmatter = lines[(start + 1)..<end].joined(separator: "\n")
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (frontmatter, body)
    }

    /// Parse a card into (frontmatter, body). Supported shapes:
    ///   * scalar          key: value
    ///   * inline list     key: [a, b]
    ///   * indented list   key:\n  - a
    ///   * nested map      key:\n  k: v     (covers delivery:)
    /// Values keep their full text (we do NOT token-truncate like derive-status.mjs).
    static func parseCard(_ text: String) -> (fm: [String: Any], body: String) {
        guard let (front, body) = splitCard(text) else { return ([:], text) }
        var fm: [String: Any] = [:]
        var pendingKey: String?
        for raw in front.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let indent = raw.prefix(while: { $0 == " " }).count
            if indent == 0 {
                pendingKey = nil
                guard let colon = trimmed.firstIndex(of: ":") else { continue }
                let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if value.isEmpty {
                    // Decide map vs list lazily, when the first indented line arrives.
                    fm[key] = [String: String]()
                    pendingKey = key
                } else if let list = parseInlineList(value) {
                    fm[key] = list
                } else {
                    fm[key] = parseScalar(value)
                }
                continue
            }
            guard let key = pendingKey else { continue }
            if trimmed.hasPrefix("- ") {
                let item = parseScalar(String(trimmed.dropFirst(2)))
                var list = (fm[key] as? [String]) ?? []
                list.append(item)
                fm[key] = list
            } else if let colon = trimmed.firstIndex(of: ":") {
                let k = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                let v = parseScalar(String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
                var map = (fm[key] as? [String: String]) ?? [:]
                map[k] = v
                fm[key] = map
            }
        }
        return (fm, body)
    }

    static func parseScalar(_ raw: String) -> String {
        let v = raw.trimmingCharacters(in: .whitespaces)
        if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") { return String(v.dropFirst().dropLast()) }
        if v.count >= 2, v.hasPrefix("'"), v.hasSuffix("'") { return String(v.dropFirst().dropLast()) }
        return v
    }

    /// [a, b] -> ["a", "b"]; anything else -> nil.
    static func parseInlineList(_ raw: String) -> [String]? {
        let v = raw.trimmingCharacters(in: .whitespaces)
        guard v.hasPrefix("["), v.hasSuffix("]") else { return nil }
        let inner = String(v.dropFirst().dropLast())
        let parts = inner.split(separator: ",").map { parseScalar(String($0)) }.filter { !$0.isEmpty }
        return parts
    }

    // frontmatter accessors
    static func string(_ fm: [String: Any], _ key: String) -> String? {
        (fm[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    static func list(_ fm: [String: Any], _ key: String) -> [String] {
        (fm[key] as? [String]) ?? []
    }
    static func nested(_ fm: [String: Any], _ key: String, _ field: String) -> String? {
        (fm[key] as? [String: String])?[field]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    // MARK: Loading

    private static func markdownFiles(_ dir: String, prefix: String, fileManager: FileManager) -> [String] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: dir) else { return [] }
        return names
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".md") && $0 != "README.md" }
            .sorted { numericPart($0) < numericPart($1) }
    }

    private static func numericPart(_ name: String) -> Int {
        let digits = name.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
        return Int(digits) ?? 0
    }

    static func card(from text: String, path: String) -> RequirementCard? {
        let (fm, body) = parseCard(text)
        guard let id = string(fm, "id") else { return nil }
        return RequirementCard(id: id,
                               title: string(fm, "title") ?? id,
                               state: string(fm, "state"),
                               source: string(fm, "source") ?? "",
                               created: string(fm, "created") ?? "",
                               updated: string(fm, "updated") ?? "",
                               path: path,
                               body: body)
    }

    static func workstream(from text: String, path: String) -> WorkstreamSummary? {
        let (fm, _) = parseCard(text)
        guard let id = string(fm, "id") else { return nil }
        return WorkstreamSummary(id: id,
                                 title: string(fm, "title") ?? id,
                                 requirement: string(fm, "requirement"),
                                 stage: string(fm, "stage") ?? "planning",
                                 outcome: nested(fm, "delivery", "outcome"),
                                 path: path)
    }

    static func isTerminal(_ ws: WorkstreamSummary) -> Bool {
        ws.stage == "delivery" && terminalOutcomes.contains(ws.outcome ?? "")
    }

    static func effectiveState(state: String?, children: [WorkstreamSummary]) -> ReqEffectiveState {
        if state == "discarded" { return .discarded }
        if !children.isEmpty && children.allSatisfy({ isTerminal($0) }) { return .closed }
        if !children.isEmpty { return .split }
        switch state {
        case "evaluating": return .evaluating
        case "evaluated": return .evaluated
        case "suspended": return .suspended
        default: return .candidate
        }
    }

    /// The DERIVED half of the state, shown as its own badge next to the manual one:
    /// `split` when the requirement owns open workstreams, `closed` when all of them
    /// are terminal, nil when there is no breakdown (then the manual state is all there
    /// is to show). This is deliberately separate from the manual state — a broken-down
    /// requirement can still carry a manual judgement (e.g. suspended + split).
    static func derivedState(children: [WorkstreamSummary]) -> ReqEffectiveState? {
        if children.isEmpty { return nil }
        return children.allSatisfy({ isTerminal($0) }) ? .closed : .split
    }

    /// The manual states reachable from the current one. The lifecycle is
    /// FORWARD-ONLY (candidate → evaluating → evaluated) with suspended / discarded
    /// as side paths, and the DERIVED state is a precondition (design §3.3.1):
    ///   * `discarded` is a one-way door → no options;
    ///   * derived `closed` (every workstream terminal) is a terminal too → no options
    ///     (reopen by opening a NEW requirement, 原则 15);
    ///   * derived `split` (open workstreams) never offers `candidate`.
    static func allowedStates(from state: String?, derived: ReqEffectiveState?) -> [String] {
        let current = state ?? "candidate"
        if current == "discarded" { return [] }
        if derived == .closed { return [] }
        var options: [String]
        switch current {
        case "candidate": options = ["evaluating", "suspended", "discarded"]
        case "evaluating": options = ["evaluated", "suspended", "discarded"]
        case "evaluated": options = ["suspended", "discarded"]
        case "suspended": options = ["evaluating", "evaluated", "discarded"]
        default: options = ["evaluating", "evaluated", "suspended", "discarded"]
        }
        if derived == .split { options.removeAll { $0 == "candidate" } }
        return options
    }

    static func load(workspace: String, fileManager: FileManager = .default) -> PoolSnapshot {
        let workspace = workspace.trimmed
        guard !workspace.isEmpty, isDirectory(workspace, fileManager) else {
            return PoolSnapshot(workspace: workspace, dshExists: false, requirements: [], workstreams: [], unparsed: [])
        }
        let dshExists = fileManager.fileExists(atPath: dshDir(workspace))
        var unparsed: [String] = []

        var workstreams: [WorkstreamSummary] = []
        for name in markdownFiles(workstreamsDir(workspace), prefix: "WS-", fileManager: fileManager) {
            let path = (workstreamsDir(workspace) as NSString).appendingPathComponent(name)
            guard let text = readText(path), let ws = workstream(from: text, path: path) else {
                unparsed.append(path)
                continue
            }
            workstreams.append(ws)
        }

        var childrenOf: [String: [WorkstreamSummary]] = [:]
        for ws in workstreams {
            guard let req = ws.requirement else { continue }
            childrenOf[req, default: []].append(ws)
        }

        let sessions = loadSessions(workspace: workspace)
        var items: [PoolItem] = []
        for name in markdownFiles(requirementsDir(workspace), prefix: "REQ-", fileManager: fileManager) {
            let path = (requirementsDir(workspace) as NSString).appendingPathComponent(name)
            guard let text = readText(path), var card = card(from: text, path: path) else {
                unparsed.append(path)
                continue
            }
            card.session = sessions[card.id]
            let children = (childrenOf[card.id] ?? []).sorted { numericPart($0.id) < numericPart($1.id) }
            items.append(PoolItem(requirement: card,
                                  effectiveState: effectiveState(state: card.state, children: children),
                                  children: children,
                                  proposal: parseProposal(card.body),
                                  confirmed: parseConfirmed(card.body)))
        }

        return PoolSnapshot(workspace: workspace,
                            dshExists: dshExists,
                            requirements: items,
                            workstreams: workstreams,
                            unparsed: unparsed)
    }

    // MARK: Breakdown proposal

    /// Decode the pending proposal from a requirement body: a fenced block whose info
    /// string is "json proposal". Returns nil when absent or unparseable.
    static func parseProposal(_ body: String) -> [BreakdownItem]? {
        let lines = body.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            let isTilde = trimmed.hasPrefix("~~~")
            let isTick = trimmed.hasPrefix("```")
            if isTilde || isTick {
                let fence = isTilde ? "~~~" : "```"
                let info = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                if info == "json proposal" {
                    var json: [String] = []
                    var j = i + 1
                    while j < lines.count, !lines[j].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        json.append(lines[j])
                        j += 1
                    }
                    return decodeProposal(json.joined(separator: "\n"))
                }
            }
            i += 1
        }
        return nil
    }

    static func decodeProposal(_ json: String) -> [BreakdownItem]? {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var out: [BreakdownItem] = []
        for obj in arr {
            guard let title = (obj["title"] as? String)?.trimmed.nilIfEmpty else { continue }
            out.append(BreakdownItem(title: title,
                                     boundary: (obj["boundary"] as? String)?.trimmed ?? "",
                                     dependsOn: (obj["dependsOn"] as? [String]) ?? []))
        }
        return out.isEmpty ? nil : out
    }

    static func proposalSection(_ items: [BreakdownItem]) -> String {
        let array: [[String: Any]] = items.map {
            ["title": $0.title, "boundary": $0.boundary, "dependsOn": $0.dependsOn]
        }
        let data = (try? JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted])) ?? Data("[]".utf8)
        let json = String(data: data, encoding: .utf8) ?? "[]"
        return breakdownHeading + "（agent 提案 / 人工确认）\n\n" + "```json proposal\n" + json + "\n```\n"
    }

    /// The standard confirmed table: 标识 | 事项 | 边界 | 依赖.
    /// 状态 is intentionally absent (the panel joins it live from the WS card);
    /// 依赖 is written as WS ids when the proposal's dependency titles map onto the
    /// created workstreams. See docs/design/panels/requirements-breakdown-standard-design.md.
    static func confirmedSection(items: [BreakdownItem], ids: [String], today: String) -> String {
        var idByTitle: [String: String] = [:]
        for (i, item) in items.enumerated() where i < ids.count { idByTitle[item.title] = ids[i] }
        var out = breakdownHeading + "（agent 提案 / 人工确认）\n\n"
            + "| 标识 | 事项 | 边界 | 依赖 |\n"
            + "|---|---|---|---|\n"
        for (i, item) in items.enumerated() {
            let id = i < ids.count ? ids[i] : "—"
            let deps = item.dependsOn.isEmpty
                ? "—"
                : item.dependsOn.map { idByTitle[$0] ?? $0 }.joined(separator: "、")
            let boundary = item.boundary.replacingOccurrences(of: "|", with: "/")
            let title = item.title.replacingOccurrences(of: "|", with: "/")
            out += "| " + id + " | " + title + " | " + boundary + " | " + deps + " |\n"
        }
        out += "\n确认记录（" + today + "）：人确认拆解，生成 " + ids.joined(separator: "、") + "。\n"
        return out
    }

    /// Parse the CONFIRMED breakdown table out of a requirement body's 拆解 section.
    /// Column names drive the mapping, so legacy hand-written tables (3/4 columns,
    /// an extra 状态, candidate rows, prose deps) still parse. Any 状态 column is
    /// ignored on purpose. Returns [] when there is no table (e.g. a pending proposal).
    static func parseConfirmed(_ body: String) -> [ConfirmedItem] {
        guard let section = sectionText(body, heading: breakdownHeading) else { return [] }
        let lines = section.components(separatedBy: "\n")
        guard let headerIndex = lines.firstIndex(where: { line in
            tableCells(line).contains { normalizeColumn($0) == "title" }
        }) else { return [] }
        let header = tableCells(lines[headerIndex])
        var out: [ConfirmedItem] = []
        for line in lines.dropFirst(headerIndex + 1) {
            let cells = tableCells(line)
            guard !cells.isEmpty else { continue }
            if cells.allSatisfy({ isSeparatorCell($0) }) { continue }
            var row: [String: String] = [:]
            for (i, name) in header.enumerated() {
                let key = normalizeColumn(name)
                if row[key] != nil { continue }
                row[key] = i < cells.count ? cleanCell(cells[i]) : ""
            }
            let rawTitle = row["title"] ?? ""
            var id = (row["id"] ?? "").nilIfEmpty
            var title = rawTitle
            if id == nil, let found = workstreamIds(in: rawTitle).first {
                id = found
                if let range = rawTitle.range(of: found) {
                    title = String(rawTitle[range.upperBound...])
                        .trimmingCharacters(in: CharacterSet(charactersIn: " ：:—-"))
                }
            }
            let boundary = row["boundary"] ?? ""
            if id == nil && title.isEmpty && boundary.isEmpty { continue }
            if title.isEmpty { title = id ?? "" }
            out.append(ConfirmedItem(id: id,
                                     title: title,
                                     boundary: boundary,
                                     dependsOn: workstreamIds(in: row["depends"] ?? "")))
        }
        return out
    }

    /// Split a markdown table row into trimmed cells; a line without a pipe
    /// (prose / fence) yields an empty array.
    static func tableCells(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return [] }
        var body = trimmed
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func normalizeColumn(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "标识", "id", "编号": return "id"
        case "事项", "title", "标题": return "title"
        case "边界", "boundary", "范围": return "boundary"
        case "依赖", "依赖顺序", "depends", "depends on", "dependency": return "depends"
        default: return raw.trimmingCharacters(in: .whitespaces).lowercased()
        }
    }

    static func isSeparatorCell(_ cell: String) -> Bool {
        let dashes = cell.filter { $0 == "-" }.count
        return dashes >= 2 && cell.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
    }

    static func cleanCell(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed == "—" || trimmed == "–" || trimmed == "-" { return "" }
        return trimmed
    }

    /// Every WS-<digits> token in a string, in order (no regex).
    static func workstreamIds(in text: String) -> [String] {
        let chars = Array(text)
        var out: [String] = []
        var i = 0
        while i + 2 < chars.count {
            if (chars[i] == "W" || chars[i] == "w"),
               (chars[i + 1] == "S" || chars[i + 1] == "s"),
               chars[i + 2] == "-" {
                var j = i + 3
                var digits = ""
                while j < chars.count, chars[j].isNumber { digits.append(chars[j]); j += 1 }
                if !digits.isEmpty {
                    out.append("WS-" + digits)
                    i = j
                    continue
                }
            }
            i += 1
        }
        return out
    }

    /// Replace (or append) a level-2 section, identified by a heading prefix.
    static func replaceSection(_ body: String, heading: String, with newSection: String) -> String {
        let lines = body.components(separatedBy: "\n")
        let newLines = newSection.hasSuffix("\n")
            ? String(newSection.dropLast()).components(separatedBy: "\n")
            : newSection.components(separatedBy: "\n")
        if let start = lines.firstIndex(where: { $0.hasPrefix(heading) }) {
            var end = start + 1
            while end < lines.count, !lines[end].hasPrefix("## ") { end += 1 }
            var out = Array(lines[0..<start])
            out.append(contentsOf: newLines)
            if end < lines.count { out.append(contentsOf: Array(lines[end...])) }
            return out.joined(separator: "\n")
        }
        var base = body
        if !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { base += "\n\n" }
        base += newSection
        return base
    }

    /// The text of a level-2 section (without its heading), or nil when absent/empty.
    static func sectionText(_ body: String, heading: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix(heading) }) else { return nil }
        var end = start + 1
        while end < lines.count, !lines[end].hasPrefix("## ") { end += 1 }
        let text = lines[(start + 1)..<end].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// What a card shows as its content: the `## 诉求` section, or the body with
    /// markdown headings stripped when there is none.
    static func statement(from body: String) -> String {
        if let statement = sectionText(body, heading: "## 诉求") { return statement }
        return body.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("#") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func recompose(_ text: String, body: String) -> String {
        guard let (fm, _) = splitCard(text) else { return text }
        return "---\n" + fm + "\n---\n" + body
    }

    /// Set (or insert) top-level frontmatter fields, preserving everything else.
    static func setFrontmatterFields(_ text: String, fields: [String: String]) -> String {
        guard let (fm, body) = splitCard(text) else { return text }
        var lines = fm.components(separatedBy: "\n")
        for (key, value) in fields {
            if let idx = lines.firstIndex(where: { $0.hasPrefix(key + ":") }) {
                lines[idx] = key + ": " + value
            } else {
                let anchor = lines.firstIndex(where: { $0.hasPrefix("title:") })
                    ?? lines.firstIndex(where: { $0.hasPrefix("id:") })
                    ?? 0
                lines.insert(key + ": " + value, at: min(anchor + 1, lines.count))
            }
        }
        return "---\n" + lines.joined(separator: "\n") + "\n---\n" + body
    }

    // MARK: Writes

    static func isDirectory(_ path: String, _ fileManager: FileManager = .default) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    static func readText(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    static func ensureDirectories(_ workspace: String, fileManager: FileManager = .default) throws {
        guard !workspace.isEmpty, isDirectory(workspace, fileManager) else { throw PoolError.noWorkspace }
        for dir in [requirementsDir(workspace), workstreamsDir(workspace)] {
            do {
                try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
            } catch {
                throw PoolError.writeFailed(error.localizedDescription)
            }
        }
    }

    /// Atomic write: temp file in the same directory, then rename over the target
    /// (store design §7.1 "临时文件 + rename").
    static func atomicWrite(_ text: String, to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        let tmp = (dir as NSString).appendingPathComponent("." + (path as NSString).lastPathComponent + ".tmp-\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try text.write(toFile: tmp, atomically: false, encoding: .utf8)
        } catch {
            throw PoolError.writeFailed(error.localizedDescription)
        }
        if rename(tmp, path) != 0 {
            try? FileManager.default.removeItem(atPath: tmp)
            throw PoolError.writeFailed("rename failed: \(String(cString: strerror(errno)))")
        }
    }

    static func nextId(prefix: String, in dir: String, fileManager: FileManager = .default) -> String {
        let files = markdownFiles(dir, prefix: prefix, fileManager: fileManager)
        let maxN = files.map(numericPart).max() ?? 0
        // Six-digit ids (REQ-000008 / WS-000009): three digits ran out too soon.
        // numericPart() parses any width, so older three-digit cards keep sorting
        // and keep receiving the next number.
        return prefix + String(format: "%06d", maxN + 1)
    }

    // MARK: Requirement writes

    static func createRequirement(workspace: String,
                                  title: String,
                                  body: String?,
                                  source: String?,
                                  today: String,
                                  session: String? = nil,
                                  fileManager: FileManager = .default) throws -> RequirementCard {
        let title = title.trimmed
        guard !title.isEmpty else { throw PoolError.missingTitle }
        let workspace = workspace.trimmed
        try ensureDirectories(workspace, fileManager: fileManager)
        let id = nextId(prefix: "REQ-", in: requirementsDir(workspace), fileManager: fileManager)
        let statement = (body?.trimmed.nilIfEmpty) ?? title
        let src = (source?.trimmed.nilIfEmpty) ?? "panel"
        let text = "---\n"
            + "id: " + id + "\n"
            + "title: " + title + "\n"
            + "state: candidate\n"
            + "source: " + src + "\n"
            + "created: " + today + "\n"
            + "updated: " + today + "\n"
            + "workstreams: []\n"
            + "---\n\n## 诉求\n\n" + statement + "\n"
        let path = requirementPath(workspace, id: id)
        try atomicWrite(text, to: path)
        if let session = session?.trimmed, !session.isEmpty {
            rememberSession(workspace: workspace, id: id, session: session)
        }
        guard var card = card(from: text, path: path) else { throw PoolError.writeFailed("created card did not parse") }
        card.session = session?.trimmed.nilIfEmpty
        return card
    }

    static func setState(workspace: String,
                         id: String,
                         state: String,
                         today: String,
                         fileManager: FileManager = .default) throws -> RequirementCard {
        guard manualStates.contains(state) else { throw PoolError.unknownState(state) }
        let path = requirementPath(workspace, id: id)
        guard let text = readText(path) else { throw PoolError.unknownRequirement(id) }
        guard let existing = card(from: text, path: path) else { throw PoolError.writeFailed("card did not parse") }
        // The derived state gates the manual transition (design §3.3.1). Same-state is
        // an idempotent no-op, so it always passes.
        if state != existing.state {
            let children = workstreams(workspace: workspace, id: id, fileManager: fileManager)
            let derived = derivedState(children: children)
            guard allowedStates(from: existing.state, derived: derived).contains(state) else {
                throw PoolError.invalidTransition(existing.state ?? "candidate", state)
            }
        }
        let updated = setFrontmatterFields(text, fields: ["state": state, "updated": today])
        try atomicWrite(updated, to: path)
        guard let card = card(from: updated, path: path) else { throw PoolError.writeFailed("card did not parse") }
        return card
    }

    /// The workstream cards that point back at this requirement. The forward pointer
    /// is the membership authority (REQ.workstreams is only a cache).
    static func workstreams(workspace: String, id: String,
                            fileManager: FileManager = .default) -> [WorkstreamSummary] {
        var out: [WorkstreamSummary] = []
        for name in markdownFiles(workstreamsDir(workspace), prefix: "WS-", fileManager: fileManager) {
            let path = (workstreamsDir(workspace) as NSString).appendingPathComponent(name)
            guard let text = readText(path), let ws = workstream(from: text, path: path) else { continue }
            if ws.requirement == id { out.append(ws) }
        }
        return out
    }

    /// Whether any workstream card points back at this requirement. Once broken
    /// down the requirement is frozen (design: 已确认的映射表不追溯修改 / 重开另起需求).
    static func hasWorkstreams(workspace: String, id: String,
                               fileManager: FileManager = .default) -> Bool {
        !workstreams(workspace: workspace, id: id, fileManager: fileManager).isEmpty
    }

    /// Edit a card's title and (optionally) its 诉求. Only the frontmatter `title`
    /// and the `## 诉求` section change; state, breakdown and mapping stay.
    /// A requirement that already owns workstreams is LOCKED: editing it would make
    /// the confirmed breakdown no longer match the requirement (open a new one instead).
    static func updateRequirement(workspace: String,
                                  id: String,
                                  title: String,
                                  body: String?,
                                  today: String,
                                  fileManager: FileManager = .default) throws -> RequirementCard {
        let trimmedTitle = title.trimmed
        guard !trimmedTitle.isEmpty else { throw PoolError.missingTitle }
        let path = requirementPath(workspace, id: id)
        guard let text = readText(path) else { throw PoolError.unknownRequirement(id) }
        guard !hasWorkstreams(workspace: workspace, id: id, fileManager: fileManager) else {
            throw PoolError.breakdownLocked(id)
        }
        let (_, oldBody) = parseCard(text)
        var newBody = oldBody
        if let statement = body?.trimmed, !statement.isEmpty {
            newBody = replaceSection(oldBody, heading: "## 诉求", with: "## 诉求\n\n" + statement + "\n")
        }
        let rewritten = setFrontmatterFields(recompose(text, body: newBody),
                                             fields: ["title": trimmedTitle, "updated": today])
        try atomicWrite(rewritten, to: path)
        guard let card = card(from: rewritten, path: path) else { throw PoolError.writeFailed("card did not parse") }
        return card
    }

    static func propose(workspace: String,
                        id: String,
                        items: [BreakdownItem],
                        today: String) throws -> RequirementCard {
        guard !items.isEmpty else { throw PoolError.noItems }
        let path = requirementPath(workspace, id: id)
        guard let text = readText(path) else { throw PoolError.unknownRequirement(id) }
        let (fm, body) = parseCard(text)
        let newBody = replaceSection(body, heading: breakdownHeading, with: proposalSection(items))
        var fields: [String: String] = ["updated": today]
        // A submitted 拆解提案 moves a candidate into 评估中 (design §3.3.1).
        let current = string(fm, "state")
        if current == nil || current == "candidate" { fields["state"] = "evaluating" }
        let rewritten = setFrontmatterFields(recompose(text, body: newBody), fields: fields)
        try atomicWrite(rewritten, to: path)
        guard let card = card(from: rewritten, path: path) else { throw PoolError.writeFailed("card did not parse") }
        return card
    }

    static func confirm(workspace: String,
                        id: String,
                        today: String,
                        fileManager: FileManager = .default) throws -> [WorkstreamSummary] {
        let path = requirementPath(workspace, id: id)
        guard let text = readText(path) else { throw PoolError.unknownRequirement(id) }
        let (fm, body) = parseCard(text)
        guard let proposal = parseProposal(body), !proposal.isEmpty else { throw PoolError.noProposal }
        try ensureDirectories(workspace, fileManager: fileManager)

        var created: [WorkstreamSummary] = []
        var ids: [String] = []
        for item in proposal {
            let wsId = nextId(prefix: "WS-", in: workstreamsDir(workspace), fileManager: fileManager)
            // nextId sees already-written cards on the next iteration, so ids stay unique.
            let wsPath = workstreamPath(workspace, id: wsId)
            let deps = item.dependsOn.isEmpty ? "无" : item.dependsOn.joined(separator: "、")
            let wsText = "---\n"
                + "id: " + wsId + "\n"
                + "title: " + item.title + "\n"
                + "requirement: " + id + "\n"
                + "stage: planning\n"
                + "created: " + today + "\n"
                + "updated: " + today + "\n"
                + "---\n\n# " + wsId + " " + item.title + "\n\n## 规划\n\n"
                + "- 目标：" + (item.boundary.isEmpty ? item.title : item.boundary) + "\n"
                + "- 依赖：" + deps + "\n\n"
                + "## 备注\n\n- 由需求池面板拆解自 " + id + "（确认 " + today + "）。\n"
            try atomicWrite(wsText, to: wsPath)
            ids.append(wsId)
            if let summary = workstream(from: wsText, path: wsPath) { created.append(summary) }
        }

        // Link the created workstreams back in the requirement's OWN frontmatter
        // (`workstreams: [WS-…]`) — the panel derives children from the WS cards'
        // `requirement:` back-refs, but the REQ card must carry the list too.
        var workstreamList = list(fm, "workstreams")
        for wsId in ids where !workstreamList.contains(wsId) { workstreamList.append(wsId) }
        let newBody = replaceSection(body, heading: breakdownHeading, with: confirmedSection(items: proposal, ids: ids, today: today))
        var fields: [String: String] = ["updated": today,
                                        "workstreams": "[" + workstreamList.joined(separator: ", ") + "]"]
        // A confirmed breakdown moves candidate / evaluating into 已评估 (design §3.3.1).
        let current = string(fm, "state")
        if current == nil || current == "candidate" || current == "evaluating" { fields["state"] = "evaluated" }
        let rewritten = setFrontmatterFields(recompose(text, body: newBody), fields: fields)
        try atomicWrite(rewritten, to: path)
        return created
    }

    static func reject(workspace: String,
                       id: String,
                       today: String) throws -> RequirementCard {
        let path = requirementPath(workspace, id: id)
        guard let text = readText(path) else { throw PoolError.unknownRequirement(id) }
        let (_, body) = parseCard(text)
        guard parseProposal(body) != nil else { throw PoolError.noProposal }
        let newBody = replaceSection(body, heading: breakdownHeading, with: breakdownHeading + "（agent 提案 / 人工确认）\n")
        let rewritten = setFrontmatterFields(recompose(text, body: newBody), fields: ["updated": today])
        try atomicWrite(rewritten, to: path)
        guard let card = card(from: rewritten, path: path) else { throw PoolError.writeFailed("card did not parse") }
        return card
    }

    // MARK: Prompt

    /// The text a panel-created requirement starts its refinement session with
    /// (design §5.4): the card exists, the agent only discusses / clarifies, and
    /// card edits go through the API so the session stays the single thread.
    static func refinementPrompt(_ requirementId: String, title: String) -> String {
        return requirementId + "「" + title + "」@.dsh/requirements/" + requirementId + ".md\n"
            + "请和我一起细化这条需求：澄清目标、边界、验收标准；\n"
            + "\n"
            + "注意：\n"
            + "- 只讨论、只澄清，不要修改代码或其它文件。\n"
            + "- 须修改需求时，用 POST /api/requirements/update（带上 session，保持同一会话）。\n"
            + "- 细化后，等待用户进行「需求拆解」。"
    }

    /// The handoff text the panel copies when the user clicks "拆解" (design §6). It
    /// points the agent at the card and the propose endpoint; the human still confirms.
    static func breakdownPrompt(_ requirementId: String, title: String) -> String {
        return requirementId + "「" + title + "」@.dsh/requirements/" + requirementId + ".md，需求已确认。\n"
            + "根据需求，将需求拆解为可依次落地的事项。\n"
            + "请给出拆解方案：每个事项的标题、边界、依赖顺序。\n"
            + "\n"
            + "注意：\n"
            + "- 只拆不胀，范围外的新发现回池。\n"
            + "- 提交待确认提案（不要建卡、不要自签）。" + proposeAPIHint(requirementId) + "\n"
            + "- 提交后，等待用户确认『待确认提案』。"
    }

    /// 「驳回」后请 agent 改方案再提案；`reason` 为空时省略「驳回原因：…」一行，
    /// 其余与拆解提示词一致（design §5.7 ④⑤）。
    static func rejectPrompt(_ requirementId: String, title: String, reason: String?) -> String {
        var text = requirementId + "「" + title + "」@.dsh/requirements/" + requirementId + ".md，需求拆解已驳回。\n"
        if let reason = reason, !reason.isEmpty {
            text += "驳回原因：" + reason + "\n"
        }
        text += "请修改拆解方案。\n"
            + "\n"
            + "注意：\n"
            + "- 只拆不胀，范围外的新发现回池。\n"
            + "- 重新提交待确认提案（不要建卡、不要自签）。" + proposeAPIHint(requirementId) + "\n"
            + "- 提交后，等待用户确认『待确认提案』。"
        return text
    }

    /// The propose-endpoint line shared by 拆解 / 驳回（一处维护，避免两处漂移）。
    private static func proposeAPIHint(_ requirementId: String) -> String {
        return "调用 拆解器 API `POST /api/requirements/breakdown/propose  {\"id\":\"" + requirementId
            + "\",\"items\":[{\"title\":\"...\",\"boundary\":\"...\",\"dependsOn\":[\"...\"]}]}` 提交。"
    }
}

// MARK: - Small helpers

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
