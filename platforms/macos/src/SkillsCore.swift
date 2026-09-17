//
//  SkillsCore.swift — Foundation-only model layer for the Skills manager panel.
//
//  Mirrors what dsh actually discovers (@deepseek-ai/dsh-skill-filesystem):
//  four local roots with fixed ranks, directory bundles (<dir>/SKILL.md) plus
//  flat *.md files, and the frontmatter that decides invocation:
//
//    user-invocable            (default true)
//    disable-model-invocation  (default false)
//
//  Legacy camelCase keys are REJECTED by dsh (the whole file is ignored), so the
//  editor only ever writes the canonical kebab-case keys. Everything here is
//  Foundation-only so it compiles headless in tests (see tests/skills-panel).
//

import Foundation

// MARK: - Levels

/// Where a skill lives, in the vocabulary the panel shows. Four levels:
/// builtin (app-managed, read-only), user ($DSH_HOME/skills), shared
/// (~/.agents/skills, owned by external tools) and project (inside the
/// current workspace).
enum SkillLevel: String, Codable {
    case builtin
    case user
    case shared
    case project

    /// Localization key suffix for the row badge.
    var badgeKey: String { "skills.badge." + rawValue }
}

/// One dsh skill-discovery root.
enum SkillRootKind: String, Codable {
    case userDsh
    case userAgents
    case projectDsh
    case projectAgents

    /// Key suffix for the root's display name.
    var labelKey: String {
        switch self {
        case .userDsh: return "skills.root.userDsh"
        case .userAgents: return "skills.root.userAgents"
        case .projectDsh: return "skills.root.projectDsh"
        case .projectAgents: return "skills.root.projectAgents"
        }
    }
}

struct SkillRoot {
    let kind: SkillRootKind
    /// Level of the skills found here; $DSH_HOME/skills upgrades individual
    /// entries to .builtin when they carry the app-managed marker.
    let level: SkillLevel
    let path: String
    /// dsh discovery rank — smaller wins a duplicate name.
    let rank: Int
}

enum SkillRoots {

    static let rankProjectDsh = 100
    static let rankProjectAgents = 200
    static let rankUserDsh = 400
    static let rankUserAgents = 500

    /// $DSH_HOME or ~/.dsh (dev builds rewrite DSH_HOME to ~/.dsh-dev).
    static func dshHome() -> String {
        let env = ProcessInfo.processInfo.environment
        if let h = env["DSH_HOME"], !h.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return expand(h)
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".dsh")
    }

    /// $DSH_AGENTS_HOME or ~/.agents.
    static func agentsHome() -> String {
        let env = ProcessInfo.processInfo.environment
        if let h = env["DSH_AGENTS_HOME"], !h.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return expand(h)
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".agents")
    }

    static func expand(_ path: String) -> String {
        (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    /// The roots dsh would scan for a workspace, ordered by rank.
    static func defaultRoots(workspace: String?, home: String? = nil, agentsRoot: String? = nil) -> [SkillRoot] {
        var roots: [SkillRoot] = []
        if let ws = workspace, !ws.isEmpty {
            roots.append(SkillRoot(kind: .projectDsh, level: .project,
                                   path: join(ws, ".dsh/skills"), rank: rankProjectDsh))
            roots.append(SkillRoot(kind: .projectAgents, level: .project,
                                   path: join(ws, ".agents/skills"), rank: rankProjectAgents))
        }
        roots.append(SkillRoot(kind: .userDsh, level: .user,
                               path: join(home ?? dshHome(), "skills"), rank: rankUserDsh))
        roots.append(SkillRoot(kind: .userAgents, level: .shared,
                               path: join(agentsRoot ?? agentsHome(), "skills"), rank: rankUserAgents))
        return roots.sorted { $0.rank < $1.rank }
    }

    static func join(_ base: String, _ rel: String) -> String {
        (base as NSString).appendingPathComponent(rel)
    }
}

// MARK: - Frontmatter

struct SkillFrontmatter {
    var name: String
    var description: String
    /// Raw values as written in the file (nil = key absent).
    var userInvocable: Bool?
    var disableModelInvocation: Bool?

    var effectiveUserInvocable: Bool { userInvocable ?? true }
    var effectiveModelInvocable: Bool { !(disableModelInvocation ?? false) }
}

/// Minimal, byte-preserving frontmatter reader/writer.
///
/// Deliberately NOT a YAML round-trip: the panel edits at most two keys, and
/// everything else in the file (ordering, quoting, comments, line endings, the
/// body) must survive untouched — the built-in skills' installed copies are
/// compared byte-for-byte against the app's embedded markdown.
enum SkillFrontmatterIO {

    enum EditError: Error {
        case missingFrontmatter
    }

    struct Line {
        var content: String
        var terminator: String

        var text: String { content + terminator }
    }

    // MARK: line handling

    static func splitLines(_ text: String) -> [Line] {
        var out: [Line] = []
        var content = ""
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "\n" {
                out.append(Line(content: content, terminator: "\n"))
                content = ""
            } else if c == "\r\n" {
                // Swift treats CRLF as ONE grapheme cluster, so it needs its own
                // branch before the lone-CR case.
                out.append(Line(content: content, terminator: "\r\n"))
                content = ""
            } else if c == "\r" {
                let next = text.index(after: i)
                if next < text.endIndex, text[next] == "\n" {
                    out.append(Line(content: content, terminator: "\r\n"))
                    i = next
                } else {
                    out.append(Line(content: content, terminator: "\r"))
                }
                content = ""
            } else {
                content.append(c)
            }
            i = text.index(after: i)
        }
        if !content.isEmpty { out.append(Line(content: content, terminator: "")) }
        return out
    }

    static func joinLines(_ lines: [Line]) -> String {
        var s = ""
        for l in lines { s += l.text }
        return s
    }

    static func indentWidth(_ s: String) -> Int {
        var n = 0
        for c in s {
            if c == " " || c == "\t" { n += 1 } else { break }
        }
        return n
    }

    /// (open, close) line indices of the leading --- block, nil when absent.
    static func frontmatterBounds(_ lines: [Line]) -> (open: Int, close: Int)? {
        let first = lines.first?.content.trimmingCharacters(in: .whitespaces) ?? ""
        guard first == "---" else { return nil }
        var i = 1
        while i < lines.count {
            let t = lines[i].content.trimmingCharacters(in: .whitespaces)
            if t == "---" { return (0, i) }
            i += 1
        }
        return nil
    }

    struct TopEntry {
        var key: String
        var value: String          // raw scalar text after the colon
        var lineIndex: Int
        /// Value was a block scalar (| or >): continuation lines, trimmed.
        var blockLines: [String]
    }

    /// Top-level "key: value" entries of a line range (indent 0 only).
    static func topEntries(_ lines: [Line], from: Int, to: Int) -> [TopEntry] {
        var out: [TopEntry] = []
        var i = from
        while i < to {
            let raw = lines[i].content
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { i += 1; continue }
            guard indentWidth(raw) == 0, let colon = raw.firstIndex(of: ":") else { i += 1; continue }
            let key = String(raw[raw.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            var block: [String] = []
            if value == "|" || value == ">" || value == "|-" || value == ">-" {
                var j = i + 1
                while j < to {
                    let l = lines[j]
                    let lt = l.content.trimmingCharacters(in: .whitespaces)
                    if lt.isEmpty { block.append(""); j += 1; continue }
                    if indentWidth(l.content) == 0 { break }
                    block.append(lt)
                    j += 1
                }
                out.append(TopEntry(key: key, value: value, lineIndex: i, blockLines: block))
                i = j
                continue
            }
            out.append(TopEntry(key: key, value: value, lineIndex: i, blockLines: block))
            i += 1
        }
        return out
    }

    // MARK: scalars

    /// Unquote/normalize a scalar; block scalars collapse their lines.
    static func scalar(_ entry: TopEntry) -> String {
        if !entry.blockLines.isEmpty {
            return entry.blockLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }
        var v = entry.value
        if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            return String(v.dropFirst().dropLast())
        }
        if let r = v.range(of: " #") {
            v = String(v[v.startIndex..<r.lowerBound])
        }
        return v.trimmingCharacters(in: .whitespaces)
    }

    /// dsh's frontmatterBoolean acceptance (bool / 1 / 0 / yes/no/on/off).
    static func boolValue(_ raw: String) -> Bool? {
        var v = raw.trimmingCharacters(in: .whitespaces)
        if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        if let r = v.range(of: " #") { v = String(v[v.startIndex..<r.lowerBound]) }
        switch v.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    }

    // MARK: public API

    /// Parsed frontmatter, nil when the file has none or lacks name/description.
    static func parse(_ text: String) -> SkillFrontmatter? {
        let lines = splitLines(text)
        guard let b = frontmatterBounds(lines) else { return nil }
        let entries = topEntries(lines, from: b.open + 1, to: b.close)
        var name = ""
        var description = ""
        var ui: Bool?
        var dmi: Bool?
        for e in entries {
            switch e.key {
            case "name": name = scalar(e)
            case "description": description = scalar(e)
            case "user-invocable": ui = boolValue(e.value) ?? ui
            case "disable-model-invocation": dmi = boolValue(e.value) ?? dmi
            default: break
            }
        }
        guard !name.isEmpty, !description.isEmpty else { return nil }
        return SkillFrontmatter(name: name, description: description,
                                userInvocable: ui, disableModelInvocation: dmi)
    }

    /// Rewrite user-invocable / disable-model-invocation only. nil removes the
    /// key, so "back to the dsh default" restores the file's exact bytes.
    static func settingInvocation(_ text: String,
                                  userInvocable: Bool?,
                                  disableModelInvocation: Bool?) throws -> String {
        var lines = splitLines(text)
        guard let b = frontmatterBounds(lines) else { throw EditError.missingFrontmatter }
        let header = Array(lines[(b.open + 1)..<b.close])
        let terminator = header.first(where: { !$0.terminator.isEmpty })?.terminator ?? "\n"
        var newHeader: [Line] = []
        var sawUI = false
        var sawDMI = false
        for line in header {
            let raw = line.content
            guard indentWidth(raw) == 0, let colon = raw.firstIndex(of: ":") else {
                newHeader.append(line)
                continue
            }
            let key = String(raw[raw.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            if key == "user-invocable" {
                sawUI = true
                if let v = userInvocable {
                    newHeader.append(Line(content: "user-invocable: " + (v ? "true" : "false"),
                                          terminator: line.terminator))
                }
                continue
            }
            if key == "disable-model-invocation" {
                sawDMI = true
                if let v = disableModelInvocation {
                    newHeader.append(Line(content: "disable-model-invocation: " + (v ? "true" : "false"),
                                          terminator: line.terminator))
                }
                continue
            }
            newHeader.append(line)
        }
        if !sawUI, let v = userInvocable {
            newHeader.append(Line(content: "user-invocable: " + (v ? "true" : "false"), terminator: terminator))
        }
        if !sawDMI, let v = disableModelInvocation {
            newHeader.append(Line(content: "disable-model-invocation: " + (v ? "true" : "false"), terminator: terminator))
        }
        lines.replaceSubrange((b.open + 1)..<b.close, with: newHeader)
        return joinLines(lines)
    }
}

// MARK: - Scanner

struct InstalledSkill {
    var name: String
    var description: String
    /// Absolute path of SKILL.md (or of the flat .md file).
    var skillFile: String
    /// Directory holding the skill (the flat-file case points at the root).
    var dir: String
    var root: SkillRoot
    var level: SkillLevel
    var userInvocable: Bool
    var modelInvocable: Bool
    var rawUserInvocable: Bool?
    var rawDisableModelInvocation: Bool?
    /// Set on entries hidden by a higher-ranked skill of the same name.
    var shadowedBy: SkillLevel?
    /// Files shipped with the skill beyond SKILL.md.
    var extraFiles: Int

    /// Built-in skills are app-managed: the panel never writes to them.
    var canEditInvocation: Bool { level != .builtin }
    /// Shared-level skills belong to external tools (skills CLI): list and flag
    /// editing only, never removed from here.
    var canRemove: Bool { level == .user || level == .project }
}

enum SkillScanner {

    /// $DSH_HOME/skills/<name> carrying the app-managed marker AND a built-in
    /// name is the app's own skill. All three conditions must hold, otherwise a
    /// user-installed skill that happens to share a built-in's name would be
    /// mislabelled (and wrongly locked).
    static func isBuiltinDirectory(name: String, dir: String, root: SkillRoot,
                                   fm: FileManager = .default) -> Bool {
        guard root.kind == .userDsh else { return false }
        guard BuiltinSkillNames.contains(name) else { return false }
        return fm.fileExists(atPath: SkillRoots.join(dir, SkillInstaller.managedMarker))
    }

    /// All skills under the roots, sorted by rank then name; duplicates keep the
    /// best-ranked entry and mark the rest with shadowedBy.
    static func scan(_ roots: [SkillRoot], fm: FileManager = .default) -> [InstalledSkill] {
        var found: [InstalledSkill] = []
        for root in roots.sorted(by: { $0.rank < $1.rank }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let entries = (try? fm.contentsOfDirectory(atPath: root.path))?.sorted() ?? []
            for entry in entries {
                if entry.hasPrefix(".") { continue }
                if root.kind == .userDsh, entry == ".system" { continue }
                let full = SkillRoots.join(root.path, entry)
                var entryIsDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &entryIsDir) else { continue }
                let skill: InstalledSkill?
                if entryIsDir.boolValue {
                    skill = scanDirectory(root: root, dir: full, fm: fm)
                } else if entry.hasSuffix(".md") {
                    skill = scanFlatFile(root: root, file: full, fm: fm)
                } else {
                    skill = nil
                }
                if let s = skill { found.append(s) }
            }
        }
        var winners: [String: InstalledSkill] = [:]
        var out: [InstalledSkill] = []
        for var s in found {
            if let winner = winners[s.name] {
                s.shadowedBy = winner.level
                out.append(s)
            } else {
                winners[s.name] = s
                out.append(s)
            }
        }
        return out.sorted { a, b in
            if a.root.rank != b.root.rank { return a.root.rank < b.root.rank }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    static func scanDirectory(root: SkillRoot, dir: String, fm: FileManager = .default) -> InstalledSkill? {
        let file = SkillRoots.join(dir, "SKILL.md")
        guard let text = try? String(contentsOfFile: file, encoding: .utf8),
              let parsed = SkillFrontmatterIO.parse(text) else { return nil }
        let level: SkillLevel = isBuiltinDirectory(name: parsed.name, dir: dir, root: root, fm: fm)
            ? .builtin : root.level
        return InstalledSkill(name: parsed.name,
                              description: parsed.description,
                              skillFile: file,
                              dir: dir,
                              root: root,
                              level: level,
                              userInvocable: parsed.effectiveUserInvocable,
                              modelInvocable: parsed.effectiveModelInvocable,
                              rawUserInvocable: parsed.userInvocable,
                              rawDisableModelInvocation: parsed.disableModelInvocation,
                              shadowedBy: nil,
                              extraFiles: max(0, countFiles(dir, fm: fm) - 1))
    }

    static func scanFlatFile(root: SkillRoot, file: String, fm: FileManager = .default) -> InstalledSkill? {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8),
              let parsed = SkillFrontmatterIO.parse(text) else { return nil }
        return InstalledSkill(name: parsed.name,
                              description: parsed.description,
                              skillFile: file,
                              dir: root.path,
                              root: root,
                              level: root.level,
                              userInvocable: parsed.effectiveUserInvocable,
                              modelInvocable: parsed.effectiveModelInvocable,
                              rawUserInvocable: parsed.userInvocable,
                              rawDisableModelInvocation: parsed.disableModelInvocation,
                              shadowedBy: nil,
                              extraFiles: 0)
    }

    /// Files inside dir (recursive, hidden entries skipped).
    static func countFiles(_ dir: String, fm: FileManager = .default) -> Int {
        guard let en = fm.enumerator(atPath: dir) else { return 0 }
        var n = 0
        for case let rel as String in en {
            if (rel as NSString).lastPathComponent.hasPrefix(".") { continue }
            var isDir: ObjCBool = false
            let full = SkillRoots.join(dir, rel)
            if fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue { n += 1 }
        }
        return n
    }
}

/// Names owned by the app (current + legacy spellings).
enum BuiltinSkillNames {
    static func contains(_ name: String) -> Bool {
        for skill in BuiltinSkill.allCases where skill.dirName == name || skill.legacyName == name {
            return true
        }
        return false
    }
    static var all: [String] { BuiltinSkill.allCases.map { $0.dirName } }
}

enum SkillNameRule {
    /// dsh's grammar. A name outside it makes dsh ignore the whole skill.
    static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        for part in name.split(separator: "-", omittingEmptySubsequences: false) {
            if part.isEmpty { return false }
            for c in part {
                let ok = (c >= "a" && c <= "z") || (c >= "0" && c <= "9")
                if !ok { return false }
            }
        }
        return true
    }
}

// MARK: - Store

enum SkillCatalogKind: String, Codable {
    case none
    case wellKnown
    case githubRepo

    var labelKey: String {
        switch self {
        case .none: return "skills.registry.catalogNone"
        case .wellKnown: return "skills.registry.catalogWellKnown"
        case .githubRepo: return "skills.registry.catalogGitHub"
        }
    }
}

struct SkillRegistryRecord: Codable, Equatable {
    var id: String
    var label: String
    var enabled: Bool
    /// URL template with {q} and {limit}; nil = registry cannot be searched.
    var searchURL: String?
    var catalog: SkillCatalogKind
    /// well-known base URL, or "owner/repo" for a GitHub catalog.
    var catalogURL: String
    /// Broad queries used to build the DEFAULT "popular" list for search-only
    /// registries (skills.sh has no listing endpoint; a wide query returns the
    /// ecosystem sorted by installs).
    var popularQueries: [String]

    enum CodingKeys: String, CodingKey {
        case id, label, enabled, searchURL, catalog, catalogURL, popularQueries
    }

    init(id: String, label: String, enabled: Bool = true,
         searchURL: String? = nil, catalog: SkillCatalogKind = .none, catalogURL: String = "",
         popularQueries: [String] = []) {
        self.id = id
        self.label = label
        self.enabled = enabled
        self.searchURL = searchURL
        self.catalog = catalog
        self.catalogURL = catalogURL
        self.popularQueries = popularQueries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        label = (try? c.decode(String.self, forKey: .label)) ?? id
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        searchURL = try? c.decodeIfPresent(String.self, forKey: .searchURL)
        catalog = (try? c.decode(SkillCatalogKind.self, forKey: .catalog)) ?? .none
        catalogURL = (try? c.decode(String.self, forKey: .catalogURL)) ?? ""
        popularQueries = (try? c.decode([String].self, forKey: .popularQueries)) ?? []
    }

    /// Wide queries that make skills.sh's search endpoint behave like a
    /// leaderboard: the API has no listing endpoint (/api/leaderboard and
    /// /api/skills both 404), but a broad query returns the ecosystem SORTED BY
    /// INSTALLS (measured: q=sk&limit=100 -> 3.4M … 357K installs, covering
    /// vercel-labs, anthropics, mattpocock, microsoft, …).
    static let defaultPopularQueries = ["sk", "ag"]

    /// skills.sh itself: keyword search only, no enumerable catalog.
    static func defaultSkillsSh() -> SkillRegistryRecord {
        let env = ProcessInfo.processInfo.environment["SKILLS_API_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = env.isEmpty ? "https://skills.sh" : env
        return SkillRegistryRecord(id: "skills-sh",
                                   label: "skills.sh",
                                   enabled: true,
                                   searchURL: base + "/api/search?q={q}&limit={limit}",
                                   catalog: .none,
                                   catalogURL: "",
                                   popularQueries: SkillRegistryRecord.defaultPopularQueries)
    }
}

struct SkillInvocationRecord: Codable {
    /// What the file said before the panel ever touched it.
    var baselineUserInvocable: Bool?
    var baselineDisableModelInvocation: Bool?
    /// What the user chose.
    var userInvocable: Bool
    var disableModelInvocation: Bool
    var updatedAt: String
}

struct SkillInstallRecord: Codable {
    var source: String
    var sourceType: String
    var sourceUrl: String
    var ref: String?
    var path: String
    var level: String
    /// Flags of the source file at install time (replay baseline).
    var baseUserInvocable: Bool?
    var baseDisableModelInvocation: Bool?
    var contentHash: String
    var installedAt: String
    var updatedAt: String
}

struct SkillStoreFile: Codable {
    var version: Int = 1
    var registries: [SkillRegistryRecord] = []
    var invocation: [String: SkillInvocationRecord] = [:]
    var installed: [String: SkillInstallRecord] = [:]

    enum CodingKeys: String, CodingKey {
        case version, registries, invocation, installed
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        registries = (try? c.decode([SkillRegistryRecord].self, forKey: .registries)) ?? []
        invocation = (try? c.decode([String: SkillInvocationRecord].self, forKey: .invocation)) ?? [:]
        installed = (try? c.decode([String: SkillInstallRecord].self, forKey: .installed)) ?? [:]
    }
}

/// Shell-owned metadata for the Skills panel, kept in
/// $DSH_HOME/shell/skills.json next to shell/config.json.
///
/// Deliberately a plain, app-owned JSON file (not ShellConfig): values are
/// structured, mutated in bursts, and must stay readable/writable without the
/// core CLI's per-key subprocess.
final class SkillStore {

    let home: String
    private(set) var data: SkillStoreFile

    var filePath: String { SkillRoots.join(home, "shell/skills.json") }

    init(home: String = SkillRoots.dshHome()) {
        self.home = home
        self.data = SkillStore.read(file: SkillRoots.join(home, "shell/skills.json"))
    }

    static func read(file: String) -> SkillStoreFile {
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: file)),
              let decoded = try? JSONDecoder().decode(SkillStoreFile.self, from: raw) else {
            return SkillStoreFile()
        }
        return decoded
    }

    func reload() {
        data = SkillStore.read(file: filePath)
    }

    @discardableResult
    func save() -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let raw = try? enc.encode(data) else { return false }
        let dir = (filePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do {
            try raw.write(to: URL(fileURLWithPath: filePath), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: registries

    /// Ensure the default skills.sh registry exists (idempotent).
    func seedDefaultRegistriesIfEmpty() {
        guard data.registries.isEmpty else { return }
        data.registries = [SkillRegistryRecord.defaultSkillsSh()]
        save()
    }

    func registry(id: String) -> SkillRegistryRecord? {
        data.registries.first { $0.id == id }
    }

    func upsertRegistry(_ entry: SkillRegistryRecord) {
        if let i = data.registries.firstIndex(where: { $0.id == entry.id }) {
            data.registries[i] = entry
        } else {
            data.registries.append(entry)
        }
        save()
    }

    func removeRegistry(id: String) {
        data.registries.removeAll { $0.id == id }
        save()
    }

    // MARK: invocation + install records

    func invocationRecord(_ name: String) -> SkillInvocationRecord? { data.invocation[name] }
    func installRecord(_ name: String) -> SkillInstallRecord? { data.installed[name] }

    func setInvocationRecord(_ rec: SkillInvocationRecord, name: String) {
        data.invocation[name] = rec
    }

    func clearInvocationRecord(_ name: String) {
        data.invocation.removeValue(forKey: name)
    }

    func setInstallRecord(_ rec: SkillInstallRecord, name: String) {
        data.installed[name] = rec
    }

    func clearRecords(_ name: String) {
        data.installed.removeValue(forKey: name)
        data.invocation.removeValue(forKey: name)
    }

    /// Non-cryptographic content fingerprint (change detection only).
    static func contentHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    static func now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}
