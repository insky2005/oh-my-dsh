//
//  WorkstreamsCore.swift — pure model for the Workstreams panel (slot #11).
//
//  The panel treats ".dsh/workstreams/WS-*.md" as the single source of truth
//  (docs/design/panels/requirements-workstream-store-design.md §3.2,
//   docs/design/panels/workstream-panel-design.md). This file owns the model
//  layer and nothing else:
//
//    1. what is on disk?            -> load() / loadCard()
//    2. parse one card              -> parseCard()   (frontmatter + body)
//    3. validate / serialize        -> validate() / serialize()
//    4. write one card, atomically  -> create() / update() / setStage() / queues
//
//  Foundation only: no AppKit, no networking, and no reference to the task
//  panel (TasksCore / TasksStore / ...) or the requirements panel. The panel and
//  its localhost API both call in here, so the whole model is unit-testable
//  headlessly (tests/workstreams-panel/run.sh).
//

import Foundation

// MARK: - Errors

/// Model errors, each mapped to one API error code + one bilingual panel message.
enum WorkstreamError: Error, Equatable {
    case noWorkspace
    case unknownWorkstream(String)
    case missingId
    case missingTitle
    case missingStage
    case invalidStage(String)
    case invalidQueue(String)
    case malformedFrontmatter(String)
    case missingField(String)
    case writeFailed(String)

    /// The stable code the localhost API returns (align with /api/requirements/*).
    var code: String {
        switch self {
        case .noWorkspace: return "no-workspace"
        case .unknownWorkstream: return "unknown-workstream"
        case .missingId: return "missing-id"
        case .missingTitle: return "missing-title"
        case .missingStage: return "missing-stage"
        case .invalidStage: return "invalid-stage"
        case .invalidQueue: return "invalid-queue"
        case .malformedFrontmatter: return "malformed-frontmatter"
        case .missingField: return "missing-field"
        case .writeFailed: return "write-failed"
        }
    }

    /// The HTTP status the router maps this onto.
    var status: Int {
        switch self {
        case .unknownWorkstream: return 404
        case .writeFailed: return 500
        default: return 400
        }
    }

    var message: String {
        switch self {
        case .noWorkspace: return "workspace is missing or not a directory"
        case .unknownWorkstream(let id): return "no such workstream: " + id
        case .missingId: return "workstream id is required"
        case .missingTitle: return "title is required"
        case .missingStage: return "stage is required"
        case .invalidStage(let s): return "unknown workstream stage: " + s
        case .invalidQueue(let why): return "invalid queue entry: " + why
        case .malformedFrontmatter(let why): return "malformed frontmatter: " + why
        case .missingField(let f): return "missing required field: " + f
        case .writeFailed(let why): return "write failed: " + why
        }
    }
}

// MARK: - Value types

/// The five stages a workstream moves through. stage is a STATE, not a site:
/// back edges / skips / parking are allowed (workstream-panel-design §3.2 / §4).
enum WorkstreamStage: String, CaseIterable, Equatable {
    case planning
    case design
    case task
    case acceptance
    case delivery

    /// Parse a raw frontmatter value; nil when it is not one of the five stages.
    static func parse(_ raw: String) -> WorkstreamStage? {
        WorkstreamStage(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// One queues entry: the authoritative stage / queue mapping kept in the card
/// (committed). stage is optional for read-compatibility with the legacy bare
/// [q-...] list, but new writes always carry it.
struct WorkstreamQueue: Equatable {
    var id: String
    var stage: WorkstreamStage?
}

/// The covered point record (store design §3.2): the changed paths a stage
/// accepted, anchored to immutable content ids (blob / tree), never a branch
/// or a bare commit.
struct CoveredRecord: Equatable {
    var paths: [String]
    var base: String?
    var head: String?
}

/// The delivery block. pr / url are facts; outcome is the derived cache written
/// by delivery tracking (never hand-written, store design §5).
struct DeliveryInfo: Equatable {
    var pr: Int?
    var url: String?
    var outcome: String?
}

/// One workstream card: frontmatter + body.
struct WorkstreamCard: Equatable {
    var id: String
    var title: String
    /// 0..1 authoritative forward pointer to the owning requirement.
    var requirement: String?
    var stage: WorkstreamStage
    var covered: CoveredRecord?
    /// 0..1 regression gate (REG-*).
    var regression: String?
    var queues: [WorkstreamQueue]
    var delivery: DeliveryInfo?
    var created: String?
    var updated: String?
    var path: String
    var body: String
}

/// Everything a panel render / API list needs at once.
struct WorkstreamsSnapshot: Equatable {
    var workspace: String
    var dshExists: Bool
    var workstreams: [WorkstreamCard]
    /// Cards that exist but could not be parsed (bad YAML / missing required).
    var unparsed: [String]
}

// MARK: - Frontmatter nodes

/// A permissive frontmatter block. .dsh cards mix sequence items and mapping
/// entries under one key (the covered point record is the canonical example:
/// "- docs/..." plus base: / head:), which strict YAML rejects. The parser
/// therefore keeps both shapes instead of forcing a single YAML type.
struct YAMLBlock: Equatable {
    var scalar: String?
    var items: [YAMLBlock] = []
    var entries: [String: YAMLBlock] = [:]
}

// MARK: - Core

enum WorkstreamsCore {

    // MARK: Paths

    static func dshDir(_ workspace: String) -> String {
        (workspace as NSString).appendingPathComponent(".dsh")
    }

    static func workstreamsDir(_ workspace: String) -> String {
        (dshDir(workspace) as NSString).appendingPathComponent("workstreams")
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

    /// Split a card into its frontmatter block and the body after it. nil when
    /// the card has no complete --- ... --- block.
    static func splitCard(_ text: String) -> (frontmatter: String, body: String)? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmed == "---" }) else { return nil }
        guard let end = lines[(start + 1)...].firstIndex(where: { $0.trimmed == "---" }) else { return nil }
        let frontmatter = lines[(start + 1)..<end].joined(separator: "\n")
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (frontmatter, body)
    }

    /// Parse a card into (frontmatter block, body), rejecting malformed YAML.
    static func parseFrontmatter(_ text: String) throws -> (block: YAMLBlock, body: String) {
        guard let (front, body) = splitCard(text) else {
            throw WorkstreamError.malformedFrontmatter("missing --- frontmatter block")
        }
        let lines = front.components(separatedBy: "\n")
        var index = 0
        let block = try parseBlock(lines, &index, 0)
        return (block, body)
    }

    /// Recursive indentation parser for the permissive frontmatter subset. Throws
    /// on a line that is neither a key: value entry nor a - item under the
    /// current indent -- that is the bad YAML negative case.
    static func parseBlock(_ lines: [String], _ index: inout Int, _ indent: Int) throws -> YAMLBlock {
        var block = YAMLBlock()
        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }
            // A whole-line YAML comment is not a key/value entry.
            if trimmed.hasPrefix("#") { index += 1; continue }
            let lineIndent = raw.prefix(while: { $0 == " " }).count
            if lineIndent < indent { break }
            if lineIndent > indent {
                throw WorkstreamError.malformedFrontmatter("unexpected indent: " + trimmed)
            }

            if trimmed == "-" || trimmed.hasPrefix("- ") {
                let content = (trimmed == "-" ? "" : String(trimmed.dropFirst(2))).trimmed
                index += 1
                var item = YAMLBlock()
                if let colon = keyColon(in: content) {
                    let key = String(content[..<colon]).trimmed
                    let value = String(content[content.index(after: colon)...]).trimmed
                    if value.isEmpty {
                        item.entries[key] = try parseChild(lines, &index, parentIndent: lineIndent)
                    } else {
                        item.entries[key] = YAMLBlock(scalar: parseScalar(value))
                    }
                    // A mapping sequence entry continues on deeper-indented lines,
                    // e.g. "  - id: q-1" then "    stage: planning".
                    if let next = nextContentIndent(lines, index), next > lineIndent {
                        let cont = try parseBlock(lines, &index, next)
                        for (k, v) in cont.entries where item.entries[k] == nil { item.entries[k] = v }
                        if !cont.items.isEmpty { item.items.append(contentsOf: cont.items) }
                    }
                } else if content.isEmpty {
                    item = try parseChild(lines, &index, parentIndent: lineIndent)
                } else {
                    item.scalar = parseScalar(content)
                }
                block.items.append(item)
            } else if let colon = keyColon(in: trimmed) {
                let key = String(trimmed[..<colon]).trimmed
                let value = String(trimmed[trimmed.index(after: colon)...]).trimmed
                if block.entries[key] != nil {
                    throw WorkstreamError.malformedFrontmatter("duplicate key: " + key)
                }
                index += 1
                if value.isEmpty {
                    block.entries[key] = try parseChild(lines, &index, parentIndent: lineIndent)
                } else {
                    block.entries[key] = YAMLBlock(scalar: parseScalar(value))
                }
            } else {
                throw WorkstreamError.malformedFrontmatter("expected 'key: value': " + trimmed)
            }
        }
        return block
    }

    /// The first colon on a key line is the separator: keys never contain spaces
    /// or colons, while values (urls) may.
    static func keyColon(in text: String) -> String.Index? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let key = text[..<colon].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains(" ") else { return nil }
        return colon
    }

    /// Parse a nested block whose parent entry has an empty value. An empty block
    /// is returned when the next content line is not indented past the parent.
    static func parseChild(_ lines: [String], _ index: inout Int, parentIndent: Int) throws -> YAMLBlock {
        guard let next = nextContentIndent(lines, index), next > parentIndent else { return YAMLBlock() }
        return try parseBlock(lines, &index, next)
    }

    /// Indent of the next non-blank line at or after index, or nil at EOF.
    static func nextContentIndent(_ lines: [String], _ index: Int) -> Int? {
        var i = index
        while i < lines.count {
            if !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                return lines[i].prefix(while: { $0 == " " }).count
            }
            i += 1
        }
        return nil
    }

    static func parseScalar(_ raw: String) -> String {
        var v = raw.trimmingCharacters(in: .whitespaces)
        if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") { return String(v.dropFirst().dropLast()) }
        if v.count >= 2, v.hasPrefix("'"), v.hasSuffix("'") { return String(v.dropFirst().dropLast()) }
        // Strip a trailing YAML inline comment: a '#' preceded by whitespace.
        // Real cards carry e.g. "outcome: merged   # 派生自 PR 状态", and the
        // derived outcome must compare equal to "merged".
        if let hash = v.range(of: " #") {
            v = String(v[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return v
    }

    /// [a, b] -> ["a", "b"]; anything else -> nil.
    static func parseInlineList(_ raw: String) -> [String]? {
        let v = raw.trimmingCharacters(in: .whitespaces)
        guard v.hasPrefix("["), v.hasSuffix("]") else { return nil }
        let inner = String(v.dropFirst().dropLast())
        return inner.split(separator: ",").map { parseScalar(String($0)) }.filter { !$0.isEmpty }
    }

    // MARK: Block accessors

    static func scalar(_ block: YAMLBlock, _ key: String) -> String? {
        guard let node = block.entries[key], let s = node.scalar else { return nil }
        let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    /// Materialise a queues block. Accepts the canonical [{id, stage}]
    /// list-of-maps and the legacy bare [q-...] list (stage stays nil).
    static func parseQueues(_ block: YAMLBlock) -> [WorkstreamQueue] {
        var out: [WorkstreamQueue] = []
        if let inline = block.scalar {
            for id in (parseInlineList(inline) ?? []) where !id.isEmpty {
                out.append(WorkstreamQueue(id: id, stage: nil))
            }
            return out
        }
        for item in block.items {
            if let id = item.scalar, !id.isEmpty {
                out.append(WorkstreamQueue(id: id, stage: nil))
                continue
            }
            guard let id = scalar(item, "id"), !id.isEmpty else { continue }
            var stage: WorkstreamStage?
            if let raw = scalar(item, "stage"), let parsed = WorkstreamStage.parse(raw) {
                stage = parsed
            }
            out.append(WorkstreamQueue(id: id, stage: stage))
        }
        return out
    }

    /// Materialise a covered point record (mixed list + base/head block, or the
    /// inline list shorthand).
    static func parseCovered(_ block: YAMLBlock?) -> CoveredRecord? {
        guard let block = block else { return nil }
        var paths: [String] = []
        for item in block.items { if let s = item.scalar, !s.isEmpty { paths.append(s) } }
        if paths.isEmpty, let inline = block.scalar { paths = parseInlineList(inline) ?? [] }
        let base = scalar(block, "base")
        let head = scalar(block, "head")
        if paths.isEmpty && base == nil && head == nil { return nil }
        return CoveredRecord(paths: paths, base: base, head: head)
    }

    static func parseDelivery(_ block: YAMLBlock?) -> DeliveryInfo? {
        guard let block = block else { return nil }
        let pr = scalar(block, "pr").flatMap { Int($0) }
        let url = scalar(block, "url")
        let outcome = scalar(block, "outcome")
        if pr == nil && url == nil && outcome == nil { return nil }
        return DeliveryInfo(pr: pr, url: url, outcome: outcome)
    }

    // MARK: Card

    /// Typed card from a parsed frontmatter block. Required fields (id / title /
    /// stage) are enforced here; the missing ones map to their own error.
    static func card(from root: YAMLBlock, body: String, path: String) throws -> WorkstreamCard {
        guard let id = scalar(root, "id") else { throw WorkstreamError.missingId }
        guard let title = scalar(root, "title") else { throw WorkstreamError.missingTitle }
        guard let rawStage = scalar(root, "stage") else { throw WorkstreamError.missingStage }
        guard let stage = WorkstreamStage.parse(rawStage) else { throw WorkstreamError.invalidStage(rawStage) }
        return WorkstreamCard(id: id,
                              title: title,
                              requirement: scalar(root, "requirement"),
                              stage: stage,
                              covered: parseCovered(root.entries["covered"]),
                              regression: scalar(root, "regression"),
                              queues: parseQueues(root.entries["queues"] ?? YAMLBlock()),
                              delivery: parseDelivery(root.entries["delivery"]),
                              created: scalar(root, "created"),
                              updated: scalar(root, "updated"),
                              path: path,
                              body: body)
    }

    /// Parse one card file. Throws WorkstreamError for malformed YAML or a
    /// missing required field.
    static func parseCard(_ text: String, path: String) throws -> WorkstreamCard {
        let (block, body) = try parseFrontmatter(text)
        return try card(from: block, body: body, path: path)
    }

    /// Field-level issues that do not stop a card from loading, but are reported
    /// to the writer. covered is required once a card reaches acceptance /
    /// delivery (store design §3.2).
    static func validate(_ card: WorkstreamCard) -> [String] {
        var issues: [String] = []
        if card.stage == .acceptance || card.stage == .delivery {
            if card.covered == nil || (card.covered?.paths.isEmpty ?? true) {
                issues.append("covered is required at stage " + card.stage.rawValue)
            }
        }
        for q in card.queues where q.id.isEmpty { issues.append("queue entry is missing id") }
        return issues
    }

    // MARK: Serialization

    /// Canonical serialization: fixed key order (store design §7.1 / §3.2) and
    /// the exact body that came in. Round-trips with parseCard.
    static func serialize(_ card: WorkstreamCard) -> String {
        var lines: [String] = []
        lines.append("id: " + card.id)
        lines.append("title: " + card.title)
        if let r = card.requirement, !r.isEmpty { lines.append("requirement: " + r) }
        lines.append("stage: " + card.stage.rawValue)
        if let covered = card.covered { lines.append(contentsOf: coveredLines(covered)) }
        if let r = card.regression, !r.isEmpty { lines.append("regression: " + r) }
        if !card.queues.isEmpty { lines.append(contentsOf: queueLines(card.queues)) }
        if let d = card.delivery { lines.append(contentsOf: deliveryLines(d)) }
        if let c = card.created, !c.isEmpty { lines.append("created: " + c) }
        if let u = card.updated, !u.isEmpty { lines.append("updated: " + u) }
        return "---\n" + lines.joined(separator: "\n") + "\n---\n" + card.body
    }

    static func coveredLines(_ covered: CoveredRecord) -> [String] {
        var out = ["covered:"]
        for path in covered.paths { out.append("  - " + path) }
        if let base = covered.base, !base.isEmpty { out.append("  base: " + base) }
        if let head = covered.head, !head.isEmpty { out.append("  head: " + head) }
        return out
    }

    static func queueLines(_ queues: [WorkstreamQueue]) -> [String] {
        var out = ["queues:"]
        for q in queues {
            out.append("  - id: " + q.id)
            if let stage = q.stage { out.append("    stage: " + stage.rawValue) }
        }
        return out
    }

    static func deliveryLines(_ delivery: DeliveryInfo) -> [String] {
        var out = ["delivery:"]
        if let pr = delivery.pr { out.append("  pr: " + String(pr)) }
        if let url = delivery.url, !url.isEmpty { out.append("  url: " + url) }
        if let outcome = delivery.outcome, !outcome.isEmpty { out.append("  outcome: " + outcome) }
        return out
    }

    // MARK: Loading

    /// List .dsh/workstreams/WS-*.md in id order. Bad cards land in unparsed
    /// instead of failing the whole load.
    static func load(workspace: String, fileManager: FileManager = .default) -> WorkstreamsSnapshot {
        let workspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspace.isEmpty, isDirectory(workspace, fileManager) else {
            return WorkstreamsSnapshot(workspace: workspace, dshExists: false, workstreams: [], unparsed: [])
        }
        let dshExists = fileManager.fileExists(atPath: dshDir(workspace))
        var workstreams: [WorkstreamCard] = []
        var unparsed: [String] = []
        for name in markdownFiles(workstreamsDir(workspace), fileManager: fileManager) {
            let path = (workstreamsDir(workspace) as NSString).appendingPathComponent(name)
            guard let text = readText(path) else { unparsed.append(path); continue }
            do {
                workstreams.append(try parseCard(text, path: path))
            } catch {
                unparsed.append(path)
            }
        }
        workstreams.sort { numericPart($0.id) < numericPart($1.id) }
        return WorkstreamsSnapshot(workspace: workspace,
                                   dshExists: dshExists,
                                   workstreams: workstreams,
                                   unparsed: unparsed)
    }

    static func loadCard(workspace: String, id: String,
                         fileManager: FileManager = .default) throws -> WorkstreamCard {
        let path = workstreamPath(workspace, id: id)
        guard let text = readText(path) else { throw WorkstreamError.unknownWorkstream(id) }
        return try parseCard(text, path: path)
    }

    // MARK: Filesystem helpers

    static func markdownFiles(_ dir: String, fileManager: FileManager = .default) -> [String] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: dir) else { return [] }
        return names
            .filter { $0.hasPrefix("WS-") && $0.hasSuffix(".md") && $0 != "README.md" }
            .sorted { numericPart($0) < numericPart($1) }
    }

    static func numericPart(_ name: String) -> Int {
        let digits = name.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
        return Int(digits) ?? 0
    }

    static func isDirectory(_ path: String, _ fileManager: FileManager = .default) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    static func readText(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    static func ensureDirectories(_ workspace: String, fileManager: FileManager = .default) throws {
        guard !workspace.isEmpty, isDirectory(workspace, fileManager) else { throw WorkstreamError.noWorkspace }
        do {
            try fileManager.createDirectory(atPath: workstreamsDir(workspace), withIntermediateDirectories: true)
        } catch {
            throw WorkstreamError.writeFailed(error.localizedDescription)
        }
    }

    /// Atomic write: temp file in the same directory, then rename over the target
    /// (store design §7.1 "临时文件 + rename").
    static func atomicWrite(_ text: String, to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        let tmp = (dir as NSString).appendingPathComponent("." + (path as NSString).lastPathComponent
            + ".tmp-\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try text.write(toFile: tmp, atomically: false, encoding: .utf8)
        } catch {
            throw WorkstreamError.writeFailed(error.localizedDescription)
        }
        if rename(tmp, path) != 0 {
            try? FileManager.default.removeItem(atPath: tmp)
            throw WorkstreamError.writeFailed("rename failed: \(String(cString: strerror(errno)))")
        }
    }

    /// Next id, six-digit zero-padded (WS-000012). numericPart() parses any width,
    /// so older three-digit cards keep sorting and keep receiving the next number.
    static func nextId(in dir: String, fileManager: FileManager = .default) -> String {
        let maxN = markdownFiles(dir, fileManager: fileManager).map(numericPart).max() ?? 0
        return String(format: "WS-%06d", maxN + 1)
    }

    // MARK: Writes

    static func create(workspace: String,
                       title: String,
                       requirement: String? = nil,
                       stage: WorkstreamStage = .planning,
                       body: String? = nil,
                       today: String,
                       fileManager: FileManager = .default) throws -> WorkstreamCard {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw WorkstreamError.missingTitle }
        let workspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        try ensureDirectories(workspace, fileManager: fileManager)
        let id = nextId(in: workstreamsDir(workspace), fileManager: fileManager)
        let path = workstreamPath(workspace, id: id)
        let body = body ?? "# \(id) \(title)\n"
        let card = WorkstreamCard(id: id,
                                  title: title,
                                  requirement: clean(requirement),
                                  stage: stage,
                                  covered: nil,
                                  regression: nil,
                                  queues: [],
                                  delivery: nil,
                                  created: today,
                                  updated: today,
                                  path: path,
                                  body: body)
        try atomicWrite(serialize(card), to: path)
        return card
    }

    static func update(workspace: String,
                       id: String,
                       title: String? = nil,
                       requirement: String? = nil,
                       body: String? = nil,
                       today: String,
                       fileManager: FileManager = .default) throws -> WorkstreamCard {
        var card = try loadCard(workspace: workspace, id: id, fileManager: fileManager)
        if let title = title {
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { throw WorkstreamError.missingTitle }
            card.title = t
        }
        if let requirement = requirement { card.requirement = clean(requirement) }
        if let body = body { card.body = body }
        card.updated = today
        return try write(card)
    }

    /// Advance (or move back) stage. The stage is a state, not a site, so every
    /// transition is allowed and the card history is the audit trail (R2).
    static func setStage(workspace: String,
                         id: String,
                         stage: WorkstreamStage,
                         today: String,
                         fileManager: FileManager = .default) throws -> WorkstreamCard {
        var card = try loadCard(workspace: workspace, id: id, fileManager: fileManager)
        card.stage = stage
        card.updated = today
        return try write(card)
    }

    static func setQueues(workspace: String,
                          id: String,
                          queues: [WorkstreamQueue],
                          today: String,
                          fileManager: FileManager = .default) throws -> WorkstreamCard {
        for q in queues where q.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw WorkstreamError.invalidQueue("id is required")
        }
        var card = try loadCard(workspace: workspace, id: id, fileManager: fileManager)
        card.queues = queues
        card.updated = today
        return try write(card)
    }

    static func setCovered(workspace: String,
                           id: String,
                           covered: CoveredRecord?,
                           today: String,
                           fileManager: FileManager = .default) throws -> WorkstreamCard {
        var card = try loadCard(workspace: workspace, id: id, fileManager: fileManager)
        card.covered = covered
        card.updated = today
        return try write(card)
    }

    static func setDelivery(workspace: String,
                            id: String,
                            delivery: DeliveryInfo?,
                            today: String,
                            fileManager: FileManager = .default) throws -> WorkstreamCard {
        var card = try loadCard(workspace: workspace, id: id, fileManager: fileManager)
        card.delivery = delivery
        card.updated = today
        return try write(card)
    }

    /// Serialize and atomically replace one card, returning the re-parsed result
    /// (so callers see exactly what landed on disk).
    static func write(_ card: WorkstreamCard, fileManager: FileManager = .default) throws -> WorkstreamCard {
        try atomicWrite(serialize(card), to: card.path)
        return try parseCard(readText(card.path) ?? "", path: card.path)
    }

    // MARK: Section helpers (used by the API plan route and panel body edits)

    /// The text of a level-2 section (without its heading), or nil when absent.
    static func sectionText(_ body: String, heading: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix(heading) }) else { return nil }
        var end = start + 1
        while end < lines.count, !lines[end].hasPrefix("## ") { end += 1 }
        let text = lines[(start + 1)..<end].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
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

    // MARK: Small helpers

    /// Trim and turn an empty string into nil (a cleared optional pointer).
    private static func clean(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
