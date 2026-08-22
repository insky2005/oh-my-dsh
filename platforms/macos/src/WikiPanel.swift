//
//  WikiPanel.swift — Repo Wiki panel for oh-my-dsh.
//
//  Implements the "Repo Wiki" design (docs/repo-wiki-design.md):
//    - Model: frontmatter parsing, page scanning, stale detection, backlinks
//    - Renderer: lightweight Markdown -> NSAttributedString (headings, bold /
//      italic, inline + fenced code, lists, links, quotes, hr; soft newlines
//      preserved)
//    - Generation: repo-knowledge skill + session.create/prompt RPC
//      (mode: queue) + status polling, all against the dsh web server
//    - Maintenance: incremental update / rebuild index triggers, AGENTS.md
//      registration block (idempotent), manual-page protection, wiki root
//      modes (in-repo .dsh/wiki or DSH_HOME private)
//
//  Localization strings live in AppDelegate's L10n table (see main.swift).

import AppKit
import Foundation

// MARK: - Wiki paths & settings

enum WikiPaths {

    static let rootModeKey = "wikiRootMode"
    static let autoRegenerateKey = "wikiAutoRegenerate"
    static let registerAgentsMdKey = "wikiRegisterAgentsMd"

    static var rootMode: String {
        UserDefaults.standard.string(forKey: rootModeKey) ?? "in-repo"
    }

    /// Default in-repo wiki root: <repoRoot>/.dsh/wiki/
    /// Configurable alternative: $DSH_HOME/repo-wiki/<stable-hash-of-repo>/
    static func wikiRoot(for repoRoot: String) -> String {
        if rootMode == "dsh-home" {
            let home = ProcessInfo.processInfo.environment["DSH_HOME"] ?? (NSHomeDirectory() + "/.dsh")
            return (home as NSString).appendingPathComponent("repo-wiki/\(stableHash(repoRoot))")
        }
        return (repoRoot as NSString).appendingPathComponent(".dsh/wiki")
    }

    /// Stable (process-independent) 12-hex hash of a path — used for the
    /// dsh-home layout key (String.hashValue is not stable across launches).
    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h = (h ^ UInt64(b)) &* 0x100000001b3
        }
        let hex = String(h, radix: 16, uppercase: false)
        return hex.count > 12 ? String(hex.prefix(12)) : hex
    }
}

// MARK: - Frontmatter

enum WikiFrontmatter {

    /// Split a wiki page file into (meta: [String: String], body). The meta
    /// block is the leading `--- ... ---` section; simple `key: value` lines,
    /// `tags: [a, b]` and `sources:` list items are supported; anything else
    /// is ignored. Returns an empty meta when there is no frontmatter.
    static func parse(_ text: String) -> (meta: [String: String], body: String) {
        var meta: [String: String] = [:]
        let lines = text.components(separatedBy: .newlines)
        guard lines.count >= 2, lines[0].trimmingCharacters(in: .whitespaces) == "---" else {
            return (meta, text)
        }
        var i = 1
        var currentKey: String?
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                i += 1
                break
            }
            if trimmed.hasPrefix("- ") {
                // list item — append to the current key (space separated)
                if let key = currentKey {
                    let v = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    let existing = meta[key] ?? ""
                    meta[key] = existing.isEmpty ? v : existing + " " + v
                }
            } else if let colon = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("[") && value.hasSuffix("]") {
                    value = String(value.dropFirst().dropLast())
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .joined(separator: " ")
                }
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                meta[key] = value
                currentKey = key
            } else {
                currentKey = nil
            }
            i += 1
        }
        let body = lines[i...].joined(separator: "\n")
        return (meta, body)
    }

    static func bool(_ meta: [String: String], _ key: String) -> Bool {
        (meta[key] ?? "").lowercased() == "true"
    }

    /// Parse an ISO-8601 timestamp (with or without fractional seconds).
    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - Page model

struct WikiPage: Equatable {
    let path: String          // absolute path
    let title: String         // frontmatter title or filename
    let tags: [String]
    let updated: Date         // frontmatter `updated`, else file mtime
    let sources: [String]     // relative paths the page was generated from
    let manual: Bool          // user-managed; never overwritten by generation
    let truncated: Bool       // file exceeded the read cap
    let isStale: Bool         // a source changed after `updated`
    let body: String          // markdown body (frontmatter stripped)

    var displayName: String {
        var name = title
        if manual { name += " ✎" }
        if isStale { name += " ⚠" }
        return name
    }
}

// MARK: - Wiki scanner (pages + backlinks + stale)

enum WikiScanner {

    /// Per-page read cap (design 4.2: ≤ 200 lines / 20 KB).
    static let pageCapBytes = 20 * 1024
    /// Maximum scan depth under the wiki root.
    static let maxDepth = 4

    struct Index {
        var pages: [WikiPage] = []
        var backlinks: [String: [String]] = [:]   // page abs path -> linking page abs paths
        var repoRoot: String?
        /// path -> mtime signature used for change detection.
        var signature: [String: Date] = [:]
    }

    static func scan(root: String, repoRoot: String?) -> Index {
        var idx = Index()
        idx.repoRoot = repoRoot
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return idx }

        var rawFiles: [(path: String, mtime: Date)] = []
        for case let url as URL in enumerator {
            let relDepth = url.pathComponents.count - rootURL.pathComponents.count
            if relDepth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                let name = url.lastPathComponent
                if name == "_meta" || name == ".DS_Store" { enumerator.skipDescendants() }
                continue
            }
            guard url.pathExtension.lowercased() == "md" else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date.distantPast
            rawFiles.append((url.path, mtime))
        }

        var pages: [WikiPage] = []
        for (path, mtime) in rawFiles {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { continue }
            let truncated = data.count > pageCapBytes
            let text = String(decoding: data.prefix(pageCapBytes), as: UTF8.self)
            let (meta, body) = WikiFrontmatter.parse(text)
            let title = meta["title"] ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let tags = (meta["tags"] ?? "").split(separator: " ").map(String.init)
            let updated = WikiFrontmatter.date(meta["updated"] ?? "") ?? mtime
            let sources = (meta["sources"] ?? "").split(separator: " ").map(String.init)
            let manual = WikiFrontmatter.bool(meta, "manual")
            let isStale = computeStale(sources: sources, updated: updated,
                                       pagePath: path, repoRoot: repoRoot)
            pages.append(WikiPage(path: path, title: title, tags: tags, updated: updated,
                                  sources: sources, manual: manual, truncated: truncated,
                                  isStale: isStale, body: body))
            idx.signature[path] = mtime
        }
        pages.sort { a, b in
            let aIsIndex = (a.path as NSString).lastPathComponent == "index.md"
            let bIsIndex = (b.path as NSString).lastPathComponent == "index.md"
            if aIsIndex != bIsIndex { return aIsIndex }
            return a.path.localizedStandardCompare(b.path) == .orderedAscending
        }
        idx.pages = pages
        idx.backlinks = buildBacklinks(pages: pages)
        return idx
    }

    /// Stale = the newest source file's mtime is newer than the page's
    /// `updated` timestamp. Sources resolve against repoRoot (or the page's
    /// own directory as a fallback). No sources / unknown root -> not stale.
    private static func computeStale(sources: [String], updated: Date,
                                     pagePath: String, repoRoot: String?) -> Bool {
        guard !sources.isEmpty else { return false }
        let fm = FileManager.default
        var newest = Date.distantPast
        for src in sources {
            let p: String
            if src.hasPrefix("/") {
                p = src
            } else if let root = repoRoot {
                p = (root as NSString).appendingPathComponent(src)
            } else {
                p = ((pagePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(src)
            }
            if let m = try? fm.attributesOfItem(atPath: p)[.modificationDate] as? Date {
                if m > newest { newest = m }
            }
        }
        return newest > updated.addingTimeInterval(1)
    }

    /// Reverse link map: for each page, every relative markdown link
    /// `](target)` that resolves to another scanned page records a backlink.
    private static func buildBacklinks(pages: [WikiPage]) -> [String: [String]] {
        var byPath: [String: String] = [:]   // standardized abs path -> canonical page path
        for p in pages {
            byPath[(p.path as NSString).standardizingPath] = p.path
        }
        var back: [String: [String]] = [:]
        let pattern = #"\[[^\]]*\]\(([^)]+)\)"#
        for p in pages {
            let dir = (p.path as NSString).deletingLastPathComponent
            let ns = p.body as NSString
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = re.matches(in: p.body, range: NSRange(location: 0, length: ns.length))
            for m in matches {
                guard m.numberOfRanges > 1 else { continue }
                let target = ns.substring(with: m.range(at: 1))
                guard !target.hasPrefix("http"), !target.hasPrefix("#"), !target.hasPrefix("mailto:"),
                      !target.hasPrefix("qmd"), !target.hasPrefix("dshwiki") else { continue }
                let resolved: String
                if target.hasPrefix("/") {
                    resolved = target
                } else {
                    resolved = (dir as NSString).appendingPathComponent(target)
                }
                let std = (resolved as NSString).standardizingPath
                if let canonical = byPath[std] {
                    var list = back[canonical] ?? []
                    if !list.contains(p.path) { list.append(p.path) }
                    back[canonical] = list
                }
            }
        }
        return back
    }

    /// A cheap change signature (path -> mtime) for the panel's refresh timer.
    static func signature(root: String) -> [String: Date] {
        var sig: [String: Date] = [:]
        let fm = FileManager.default
        func walk(_ dir: String, depth: Int) {
            guard depth <= maxDepth else { return }
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                if name.hasPrefix(".") { continue }
                let full = (dir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                _ = fm.fileExists(atPath: full, isDirectory: &isDir)
                if isDir.boolValue {
                    if name != "_meta" { walk(full, depth: depth + 1) }
                } else if (full as NSString).pathExtension.lowercased() == "md" {
                    let m = (try? fm.attributesOfItem(atPath: full)[.modificationDate] as? Date) ?? Date.distantPast
                    sig[full] = m
                }
            }
        }
        walk(root, depth: 0)
        return sig
    }
}

// MARK: - Markdown renderer

enum WikiMarkdownRenderer {

    /// Unicode LINE SEPARATOR — renders as a tight line break in NSTextView
    /// without creating a new paragraph (no paragraphSpacing), preserving the
    /// source's soft line breaks the way the design requires.
    static let softBreak = "\u{2028}"

    private static let bodyFont = NSFont.systemFont(ofSize: 13)
    private static let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let headingSizes: [CGFloat] = [24, 20, 18, 16, 15, 14]
    private static let codeBG = NSColor.quaternaryLabelColor.withAlphaComponent(0.22)

    /// Render wiki markdown into an attributed string. Internal relative links
    /// become `dshwiki://page/<abs-path>` URLs (the panel's NSTextView
    /// delegate navigates them); http(s) links stay real URLs. Soft newlines
    /// inside a paragraph are preserved (single \n), blank lines separate
    /// paragraphs — matching the "don't merge line breaks" requirement.
    static func render(markdown: String, wikiRoot: String, pagePath: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let blocks = parse(markdown)
        for block in blocks {
            switch block.kind {
            case .heading(let level):
                let text = block.lines.first ?? ""
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: headingSizes[min(max(level, 1), 6) - 1]),
                    .foregroundColor: NSColor.textColor,
                ]
                out.append(NSAttributedString(string: text + "\n", attributes: attrs))
            case .para:
                // Soft line breaks: join the block's lines with the Unicode
                // LINE SEPARATOR (U+2028). A plain "\n" is a PARAGRAPH
                // boundary in NSTextView, so it would apply paragraphSpacing
                // after every source line — each line looking like its own
                // paragraph. U+2028 renders as a tight line break and keeps
                // the whole block one paragraph.
                appendInline(out, block.lines.joined(separator: softBreak), base: bodyFont,
                             wikiRoot: wikiRoot, pagePath: pagePath, spacing: 6)
            case .code:
                let code = NSMutableAttributedString()
                for (i, line) in block.lines.enumerated() {
                    code.append(NSAttributedString(string: line + (i < block.lines.count - 1 ? "\n" : ""),
                                                   attributes: [.font: monoFont, .foregroundColor: NSColor.textColor]))
                }
                code.addAttribute(.backgroundColor, value: codeBG,
                                  range: NSRange(location: 0, length: code.length))
                out.append(code)
                out.append(NSAttributedString(string: "\n"))
            case .quote:
                let text = block.lines.joined(separator: softBreak)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12.5),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
                appendInline(out, text, base: attrs[.font] as! NSFont,
                             wikiRoot: wikiRoot, pagePath: pagePath, spacing: 6, prefix: "│ ")
            case .list(let indent, let marker):
                for line in block.lines {
                    let bullet = marker.range(of: #"^\d"#, options: .regularExpression) != nil
                        ? marker.trimmingCharacters(in: .whitespaces) + " " : "• "
                    appendInline(out, line, base: bodyFont, wikiRoot: wikiRoot,
                                 pagePath: pagePath, spacing: 2,
                                 prefix: String(repeating: "  ", count: indent) + bullet)
                    // Each item is its own line: without a separator the items
                    // would run together on one row.
                    out.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
                }
            case .hr:
                let line = NSAttributedString(string: String(repeating: "─", count: 40) + "\n",
                                              attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                                                           .font: NSFont.systemFont(ofSize: 11)])
                out.append(line)
            }
        }
        return out
    }

    // MARK: block parsing

    private enum BlockKind {
        case heading(Int), para, code(String), quote, list(Int, String), hr
    }
    private struct Block { let kind: BlockKind; let lines: [String] }

    private static func isHR(_ t: String) -> Bool {
        t.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil
    }

    private static func listMarker(_ t: String) -> String? {
        guard let r = t.range(of: #"^([-*+]|\d+[.)])\s+"#, options: .regularExpression) else { return nil }
        return String(t[r])
    }

    private static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        let lines = markdown.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                i += 1 // skip the closing fence
                blocks.append(Block(kind: .code(""), lines: code))
            } else if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                blocks.append(Block(kind: .heading(min(level, 6)), lines: [text]))
                i += 1
            } else if isHR(trimmed) {
                blocks.append(Block(kind: .hr, lines: []))
                i += 1
            } else if trimmed.hasPrefix(">") {
                var q: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(">") {
                        q.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                        i += 1
                    } else { break }
                }
                blocks.append(Block(kind: .quote, lines: q))
            } else if let marker = listMarker(trimmed) {
                let indent = line.prefix(while: { $0 == " " }).count / 2
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard let mm = listMarker(t) else {
                        if t.isEmpty { break }
                        break
                    }
                    items.append(String(t.dropFirst(mm.count)).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(Block(kind: .list(indent, marker), lines: items))
            } else if trimmed.isEmpty {
                i += 1
            } else {
                var para: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { break }
                    if t.hasPrefix("#") || t.hasPrefix("```") || t.hasPrefix(">")
                        || listMarker(t) != nil || isHR(t) { break }
                    para.append(t); i += 1
                }
                blocks.append(Block(kind: .para, lines: para))
            }
        }
        return blocks
    }

    // MARK: inline tokens

    private static let inlinePattern =
        #"(`[^`]+`|\*\*[^*]+\*\*|\*[^*]+\*|\[[^\]]*\]\([^)]*\))"#

    /// Append one text run with inline formatting (code / bold / italic /
    /// links). `prefix` (e.g. list bullet / quote marker) is prepended plain.
    private static func appendInline(_ out: NSMutableAttributedString, _ text: String,
                                     base: NSFont, wikiRoot: String, pagePath: String,
                                     spacing: CGFloat, prefix: String = "") {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = spacing
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: base,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: para,
        ]
        if !prefix.isEmpty {
            out.append(NSAttributedString(string: prefix, attributes: baseAttrs))
        }
        let ns = text as NSString
        guard let re = try? NSRegularExpression(pattern: inlinePattern) else {
            out.append(NSAttributedString(string: text, attributes: baseAttrs))
            return
        }
        var pos = 0
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            if m.range.location > pos {
                out.append(NSAttributedString(string: ns.substring(with: NSRange(location: pos, length: m.range.location - pos)),
                                              attributes: baseAttrs))
            }
            let token = ns.substring(with: m.range)
            appendToken(out, token, base: base, baseAttrs: baseAttrs,
                        wikiRoot: wikiRoot, pagePath: pagePath)
            pos = m.range.location + m.range.length
        }
        if pos < ns.length {
            out.append(NSAttributedString(string: ns.substring(from: pos), attributes: baseAttrs))
        }
    }

    private static func appendToken(_ out: NSMutableAttributedString, _ token: String,
                                    base: NSFont, baseAttrs: [NSAttributedString.Key: Any],
                                    wikiRoot: String, pagePath: String) {
        if token.hasPrefix("`") {
            let code = String(token.dropFirst().dropLast())
            var attrs = baseAttrs
            attrs[.font] = monoFont
            attrs[.backgroundColor] = codeBG
            out.append(NSAttributedString(string: code, attributes: attrs))
        } else if token.hasPrefix("**") {
            let inner = String(token.dropFirst(2).dropLast(2))
            var attrs = baseAttrs
            attrs[.font] = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
            out.append(NSAttributedString(string: inner, attributes: attrs))
        } else if token.hasPrefix("*") {
            let inner = String(token.dropFirst().dropLast())
            var attrs = baseAttrs
            attrs[.font] = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
            out.append(NSAttributedString(string: inner, attributes: attrs))
        } else if token.hasPrefix("[") {
            // [title](target)
            guard let close = token.firstIndex(of: "]") else {
                out.append(NSAttributedString(string: token, attributes: baseAttrs))
                return
            }
            let title = String(token[token.index(after: token.startIndex)..<close])
            let rest = token[token.index(after: close)...]
            guard rest.hasPrefix("("), rest.hasSuffix(")") else {
                out.append(NSAttributedString(string: token, attributes: baseAttrs))
                return
            }
            let target = String(rest.dropFirst().dropLast())
            if target.hasPrefix("http://") || target.hasPrefix("https://") {
                var attrs = baseAttrs
                attrs[.link] = URL(string: target)
                attrs[.foregroundColor] = NSColor.linkColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                out.append(NSAttributedString(string: title, attributes: attrs))
            } else {
                // internal wiki link -> dshwiki:// URL handled by the panel
                let abs: String
                if target.hasPrefix("/") {
                    abs = target
                } else {
                    abs = ((pagePath as NSString).deletingLastPathComponent as NSString)
                        .appendingPathComponent(target)
                }
                let std = (abs as NSString).standardizingPath
                if FileManager.default.fileExists(atPath: std) || !target.hasSuffix(".md") {
                    if let url = internalURL(std) {
                        var attrs = baseAttrs
                        attrs[.link] = url
                        attrs[.foregroundColor] = NSColor.linkColor
                        attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                        out.append(NSAttributedString(string: title, attributes: attrs))
                        return
                    }
                }
                out.append(NSAttributedString(string: title, attributes: baseAttrs))
            }
        } else {
            out.append(NSAttributedString(string: token, attributes: baseAttrs))
        }
    }

    /// Internal link URL: dshwiki://page/<abs-path>. URLComponents keeps the
    /// path properly percent-encoded so spaces/special chars survive.
    static func internalURL(_ absPath: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "dshwiki"
        comps.host = "page"
        comps.path = absPath
        return comps.url
    }
}

// MARK: - Generation prompts (thin shell; skill is the single source of truth)

enum WikiPrompts {

    enum Kind: String {
        case initial = "初始生成"
        case update = "增量更新"
        case rebuildIndex = "重建 index"
        var en: String {
            switch self {
            case .initial: return "initial generation"
            case .update: return "incremental update"
            case .rebuildIndex: return "index rebuild"
            }
        }
    }

    static func prompt(kind: Kind, repoRoot: String, wikiRoot: String, zh: Bool) -> String {
        let target = zh ? kind.rawValue : kind.en
        if zh {
            return """
            请加载 repo-knowledge skill 并执行【\(target)】。
            仓库根目录：\(repoRoot)
            知识库输出目录：\(wikiRoot)

            若 repo-knowledge skill 不可用，请按以下内嵌说明执行：
            \(fallbackInstructions(zh: true))

            完成后简短回复「知识库已\(kind == .rebuildIndex ? "重建索引" : "更新")」即可，无需汇报细节。
            """
        }
        return """
        Load the repo-knowledge skill and run \(target).
        Repository root: \(repoRoot)
        Wiki output directory: \(wikiRoot)

        If the repo-knowledge skill is unavailable, follow these inline instructions:
        \(fallbackInstructions(zh: false))

        Reply briefly "wiki \(kind == .rebuildIndex ? "index rebuilt" : "updated")" when done.
        """
    }

    private static func fallbackInstructions(zh: Bool) -> String {
        if zh {
            return """
            目标：在 \(WikiPaths.wikiRoot(for: "/")) 位置 生成/维护知识库（页面结构见下）。
            - 页面：index.md / overview.md / architecture.md / data-model.md / conventions.md / tasks.md / modules/<模块>.md，≤ 20 页，单页 ≤ 200 行；
            - 每页带 frontmatter（title/tags/updated/sources/manual: false）；
            - 只写可证实的事实，禁止编造；脱敏（跳过 .env*/密钥/口令）；增量更新只重写受影响的页面，manual: true 不碰；最后更新 index.md；
            - 完成后若仓库是 git：执行 `git add .dsh/wiki` 并 `git commit`（**不 push**），commit message 由你概括本次实际变更（如「docs(wiki): 同步 v1.8.0 发布流程与 IssueRunner 面板文档」），无变更则跳过。
            """
        }
        return """
        Generate/maintain the wiki at <repoRoot>/.dsh/wiki/:
        - Pages: index.md, overview.md, architecture.md, data-model.md, conventions.md, tasks.md, modules/<name>.md (≤ 20 pages, ≤ 200 lines each);
        - Every page carries frontmatter (title/tags/updated/sources/manual: false);
        - Only write verifiable facts, never fabricate; redact secrets (.env*, credentials); incremental updates rewrite only affected pages and never touch manual: true pages; refresh index.md at the end;
        - When done, if the repo is a git repo: run `git add .dsh/wiki` and `git commit` (do NOT push), writing a commit message that summarizes the actual changes (e.g. "docs(wiki): sync v1.8.0 release flow and IssueRunner panel docs"); skip if there are no changes.
        """
    }
}

// MARK: - Generation RPC (same client-request envelope as DSHSessionRPC)

enum WikiRPC {

    private static func call(_ method: String, _ payload: [String: Any],
                             port: Int, timeout: TimeInterval = 6) -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/\(method)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let rpcId = UUID().uuidString
        let body: [String: Any] = [
            "type": "client-request",
            "rpcId": rpcId,
            "method": method,
            "payload": payload,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { semaphore.signal() }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["rpcId"] as? String) == rpcId,
                  let res = json["result"] as? [String: Any],
                  (res["ok"] as? Bool) == true,
                  let value = res["value"] as? [String: Any] else { return }
            result = value
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1)
        task.cancel()
        return result
    }

    /// session.create { workspaceId | cwd } -> { sessionId }. Passing the
    /// registered workspace's id (like the dsh web client does) groups the
    /// session under that workspace instead of leaving it Ungrouped; `cwd` is
    /// the fallback when no matching workspace exists.
    static func createSession(port: Int, cwd: String, workspaceId: String?) -> String? {
        let payload: [String: Any]
        if let wid = workspaceId, !wid.isEmpty {
            payload = ["workspaceId": wid]
        } else {
            payload = ["cwd": cwd]
        }
        guard let value = call("session.create", payload, port: port),
              let sid = value["sessionId"] as? String else { return nil }
        return sid
    }

    /// Canonical form of a path (standardized + symlinks resolved) so session
    /// cwds and workspace paths compare reliably.
    static func canonical(_ p: String) -> String {
        URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// workspace.list -> raw item dictionaries.
    static func workspaceList(port: Int) -> [[String: Any]] {
        guard let value = call("workspace.list", [:], port: port),
              let items = value["items"] as? [[String: Any]] else { return [] }
        return items
    }

    /// The registered workspace whose path matches `cwd`, if any.
    static func resolveWorkspaceId(port: Int, cwd: String) -> String? {
        let target = canonical(cwd)
        for ws in workspaceList(port: port) {
            guard let path = ws["path"] as? String else { continue }
            if canonical(path) == target { return ws["workspaceId"] as? String }
        }
        return nil
    }

    /// session.prompt { sessionId, mode: "queue", content: [{type:"text",...}] }
    static func prompt(port: Int, sessionId: String, text: String) -> Bool {
        let content: [[String: Any]] = [["type": "text", "text": text]]
        let payload: [String: Any] = ["sessionId": sessionId, "mode": "queue", "content": content]
        return call("session.prompt", payload, port: port) != nil
    }

    /// True while the generation session is still running (session.list).
    static func sessionRunning(port: Int, sessionId: String) -> Bool {
        guard let value = call("session.list", [:], port: port),
              let items = value["items"] as? [[String: Any]] else { return false }
        for item in items {
            guard (item["sessionId"] as? String) == sessionId else { continue }
            return (item["running"] as? Bool) ?? false
        }
        return false
    }

    /// session.cancel { sessionId } — user-initiated cancellation.
    static func cancel(port: Int, sessionId: String) -> Bool {
        call("session.cancel", ["sessionId": sessionId], port: port) != nil
    }
}

// MARK: - AGENTS.md registration block (idempotent, explicit opt-in)

enum WikiAgentsMD {

    private static let openMarker = "<!-- repo-wiki:managed -->"
    private static let closeMarker = "<!-- /repo-wiki:managed -->"

    private static let block = """
    \(openMarker)
    本仓库维护有知识库 `.dsh/wiki/index.md`。涉及架构、模块、约定、常见任务时，先读取 index.md 并按需打开相关页面；不确定时再深入源码。以源码为准，wiki 仅作指引。
    This repository keeps a knowledge base at `.dsh/wiki/index.md`. When working on architecture, modules, conventions or common tasks, read index.md first and open related pages as needed; fall back to source when unsure. Source code is authoritative.
    \(closeMarker)
    """

    /// Append the marker block to <repoRoot>/AGENTS.md (creating the file if
    /// absent, or appending to CLAUDE.md when only that exists). Idempotent.
    @discardableResult
    static func register(repoRoot: String) -> Bool {
        let path = agentsPath(repoRoot)
        do {
            var content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            if content.contains(openMarker) { return true }
            if !content.hasSuffix("\n") && !content.isEmpty { content += "\n" }
            content += "\n" + block + "\n"
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            AppLog.shared.log("wiki AGENTS.md registered: \(path)")
            return true
        } catch {
            AppLog.shared.log("wiki AGENTS.md register failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Remove the marker block, if present. Leaves the rest of the file intact.
    @discardableResult
    static func unregister(repoRoot: String) -> Bool {
        let path = agentsPath(repoRoot)
        guard var content = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        guard let open = content.range(of: openMarker),
              let close = content.range(of: closeMarker) else { return true }
        var range = open.lowerBound..<content.index(after: close.upperBound)
        // also swallow a preceding newline so no blank gap is left
        if range.lowerBound > content.startIndex {
            let prev = content.index(before: range.lowerBound)
            if content[prev] == "\n" { range = prev..<range.upperBound }
        }
        content.removeSubrange(range)
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
        AppLog.shared.log("wiki AGENTS.md unregistered: \(path)")
        return true
    }

    private static func agentsPath(_ repoRoot: String) -> String {
        let fm = FileManager.default
        let agents = (repoRoot as NSString).appendingPathComponent("AGENTS.md")
        if !fm.fileExists(atPath: agents) {
            let claude = (repoRoot as NSString).appendingPathComponent("CLAUDE.md")
            if fm.fileExists(atPath: claude) { return claude }
        }
        return agents
    }
}

// MARK: - Wiki panel

/// Panel root. Mirrors TerminalPanel's `TerminalRootView` fix
/// (docs/terminal-header-fix.md): `isOpaque = false` forces Core Animation to
/// composite every child (header / toolbar / content / status bar) correctly,
/// so an opaque content view's drawing can never bleed over the header's
/// buttons in the layer-backed window. The background is drawn here instead.
final class WikiRootView: NSView {
    var kind: DynamicFillView.Kind = .window {
        didSet { needsDisplay = true }
    }
    override var isOpaque: Bool { false }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color: NSColor
        switch kind {
        case .window:
            color = dark ? NSColor(calibratedWhite: 0.28, alpha: 1) : NSColor(calibratedWhite: 0.94, alpha: 1)
        case .control:
            color = dark ? NSColor(calibratedWhite: 0.20, alpha: 1) : NSColor(calibratedWhite: 0.86, alpha: 1)
        case .custom(let c):
            color = c
        }
        color.setFill()
        dirtyRect.fill()
    }
}

/// Translucent mode-aware backdrop for the "Generating…" overlay.
final class WikiOverlayView: NSView {
    /// Translucent mode-aware backdrop for the generating overlay. Best-effort:
    /// if the custom fill does not draw in some environment, the overlay is
    /// simply transparent and the NSTextField label still shows on top.
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = dark ? NSColor(white: 0.15, alpha: 0.82) : NSColor(white: 0.97, alpha: 0.82)
        color.setFill()
        dirtyRect.fill()
    }
}

final class WikiPanelController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                 NSTextViewDelegate, NSSplitViewDelegate, NSSearchFieldDelegate {
    /// Root view mounted directly as the right pane of the main split view.
    /// WikiRootView = DynamicFillView with isOpaque=false so the header and
    /// its buttons are properly composited in the layer-backed window (same
    /// fix as TerminalRootView, see docs/terminal-header-fix.md).
    let view = WikiRootView()
    /// Invoked when the user hits the panel's "Close" button.
    var onRequestHide: (() -> Void)?
    /// Supplies the dsh web server port (generation RPC + project resolution).
    var serverPortProvider: (() -> Int)?
    /// Invoked when the panel changes the auto-update setting (e.g. via the
    /// first-generation prompt) so the menu checkbox can be rebuilt.
    var onAutoUpdateSettingChanged: (() -> Void)?

    static let minWidth: CGFloat = 260

    // MARK: subviews

    private let headerTitle = HeaderLabel()
    private var generateButton: CustomIconButton!
    private var revealButton: CustomIconButton!
    private var openButton: CustomIconButton!
    private var hideButton: CustomIconButton!
    private let searchField = NSSearchField()
    private let infoLabel = HeaderLabel()
    private let treeScroll = NSScrollView()
    private let treeOutline = NSOutlineView()
    private let contentContainer = NSView()
    private var contentSplit: NSSplitView!
    private let statusBar = DynamicFillView()
    private let statusLabel = HeaderLabel()
    private let statusSpinner = NSProgressIndicator()
    /// The transient "Generating…" overlay added on top of the reader pane
    /// (never clears the existing content — the layout must stay visible).
    private var generatingOverlay: NSView?

    // MARK: state

    private final class Section {
        let title: String
        var pages: [WikiPage]
        init(title: String, pages: [WikiPage]) { self.title = title; self.pages = pages }
    }
    private var sections: [Section] = []
    private var wikiRoot: String?
    private var repoRoot: String?
    private var index = WikiScanner.Index()
    private var selectedPath: String?
    private var serverReadyPort: Int?
    private var deferredLoad = false

    /// One in-flight generation per repository, keyed by canonical repo path.
    /// Generation state is tied to the WORKSPACE DIRECTORY, not to the panel:
    /// switching workspaces mid-generation keeps the other repo's session
    /// running in the background while the panel UI reflects only the current
    /// repo's generation.
    private struct Generation {
        let repo: String
        let sessionId: String
        let kind: WikiPrompts.Kind
        let start: Date
    }
    private var generations: [String: Generation] = [:]
    private var pollTimer: Timer?
    private var elapsedTimer: Timer?
    private var refreshTimer: Timer?
    private var lastSignature: [String: Date] = [:]

    /// The generation belonging to the repo currently shown in the panel.
    private var activeGenerationForCurrentRepo: Generation? {
        guard let repo = repoRoot else { return nil }
        return generations[WikiRPC.canonical(repo)]
    }

    /// True when a generation for the CURRENT repo is running (blocks the +).
    private var isGeneratingCurrentRepo: Bool { activeGenerationForCurrentRepo != nil }

    override init() {
        super.init()
        buildUI()
        showEmptyState()
        startRefreshTimer()
    }

    deinit {
        pollTimer?.invalidate()
        elapsedTimer?.invalidate()
        refreshTimer?.invalidate()
    }

    // MARK: UI

    private func buildUI() {
        headerTitle.text = L10n.tr("wiki.title")
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        headerTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)

        generateButton = CustomIconButton(glyph: .plus, tooltip: L10n.tr("wiki.generateHint"))
        generateButton.onAction = { [weak self] in self?.generateTapped() }
        revealButton = CustomIconButton(glyph: .reveal, tooltip: L10n.tr("preview.revealInFinderHint"))
        revealButton.onAction = { [weak self] in self?.revealInFinder() }
        openButton = CustomIconButton(glyph: .openInApp, tooltip: L10n.tr("preview.openInDefaultAppHint"))
        openButton.onAction = { [weak self] in self?.openInDefaultApp() }
        hideButton = CustomIconButton(glyph: .close, tooltip: L10n.tr("preview.closePanel"))
        hideButton.onAction = { [weak self] in
            // 关闭面板 = 停掉轮询/计时器 + 清空打开的页面与树（释放资源；
            // 重开时重新扫描加载）
            self?.stopPolling()
            self?.stopElapsedTimer()
            self?.contentContainer.subviews.forEach { $0.removeFromSuperview() }
            self?.selectedPath = nil
            self?.sections = []
            self?.treeOutline.reloadData()
            self?.onRequestHide?()
        }

        let actions = NSStackView(views: [generateButton, openButton, revealButton, hideButton])
        actions.orientation = .horizontal
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false

        let header = DynamicFillView()
        header.kind = .window
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerTitle)
        header.addSubview(actions)
        NSLayoutConstraint.activate([
            headerTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            headerTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerTitle.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),
            actions.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            actions.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),
        ])

        // toolbar: search + info. The toolbar is an opaque DynamicFillView
        // sitting directly below the header; give it its own backing layer +
        // clipping so its fill can never bleed over the header's buttons
        // (same compositing trap the terminal panel hit). Background uses the
        // same .window shade as the header so the top region reads as one
        // continuous strip, matching the preview/terminal panels.
        searchField.placeholderString = L10n.tr("wiki.searchPlaceholder")
        searchField.font = .systemFont(ofSize: 12)
        searchField.controlSize = .small
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        infoLabel.text = ""
        infoLabel.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = DynamicFillView()
        toolbar.kind = .window
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.masksToBounds = true
        toolbar.addSubview(searchField)
        toolbar.addSubview(infoLabel)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 8),
            searchField.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 4),
            searchField.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -4),
            searchField.widthAnchor.constraint(equalToConstant: 150),
            infoLabel.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 10),
            infoLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            infoLabel.trailingAnchor.constraint(lessThanOrEqualTo: toolbar.trailingAnchor, constant: -8),
            toolbar.heightAnchor.constraint(equalToConstant: 28),
        ])

        // tree
        treeOutline.headerView = nil
        let treeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        treeOutline.addTableColumn(treeColumn)
        treeOutline.outlineTableColumn = treeColumn
        treeOutline.rowSizeStyle = .small
        treeOutline.dataSource = self
        treeOutline.delegate = self
        treeOutline.autoresizesOutlineColumn = true

        treeScroll.documentView = treeOutline
        treeScroll.hasVerticalScroller = true
        treeScroll.autohidesScrollers = true
        // Non-opaque: an opaque NSScrollView background would bleed into the
        // shared root layer (mirrors PreviewPanel's treeScroll setup).
        treeScroll.drawsBackground = false
        treeScroll.translatesAutoresizingMaskIntoConstraints = false

        let treePane = NSView()
        treePane.translatesAutoresizingMaskIntoConstraints = false
        treePane.addSubview(treeScroll)
        NSLayoutConstraint.activate([
            treeScroll.leadingAnchor.constraint(equalTo: treePane.leadingAnchor),
            treeScroll.trailingAnchor.constraint(equalTo: treePane.trailingAnchor),
            treeScroll.topAnchor.constraint(equalTo: treePane.topAnchor),
            treeScroll.bottomAnchor.constraint(equalTo: treePane.bottomAnchor),
        ])

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        // Layer-isolate the reader side so its opaque text view / scroll view
        // drawing never bleeds over the header (terminal panel fix pattern).
        contentContainer.wantsLayer = true
        contentContainer.layer?.masksToBounds = true

        // Separator between the toolbar and the content area — mirrors the
        // preview/terminal panels' tab-bar underline (NSBox separator).
        let toolbarUnderline = NSBox()
        toolbarUnderline.boxType = .separator
        toolbarUnderline.translatesAutoresizingMaskIntoConstraints = false

        let contentSplit = NSSplitView()
        contentSplit.isVertical = true
        contentSplit.dividerStyle = .thin
        contentSplit.delegate = self
        contentSplit.translatesAutoresizingMaskIntoConstraints = false
        contentSplit.addSubview(treePane)
        contentSplit.addSubview(contentContainer)
        contentSplit.setHoldingPriority(NSLayoutConstraint.Priority(rawValue: 260), forSubviewAt: 1)
        self.contentSplit = contentSplit

        // status bar (hidden until a generation runs)
        statusBar.kind = .control
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = ""
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusSpinner.style = .spinning
        statusSpinner.controlSize = .small
        statusSpinner.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(statusSpinner)
        statusBar.addSubview(statusLabel)
        // Compositing trap (docs/terminal-header-fix.md): this bottom strip is
        // an OPAQUE DynamicFillView with no backing layer. When it becomes
        // visible (isHidden=false during generation) its fill is composited
        // into the panel root's layer and BLANKS every sibling (header,
        // toolbar, tree, reader) — exactly the "whole panel content gone, only
        // the bottom Generating… remains" report. Isolate it with its own
        // layer + clipping (the proven terminal-panel fix).
        statusBar.wantsLayer = true
        statusBar.layer?.masksToBounds = true
        NSLayoutConstraint.activate([
            statusSpinner.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            statusSpinner.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusSpinner.widthAnchor.constraint(equalToConstant: 12),
            statusSpinner.heightAnchor.constraint(equalToConstant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: statusSpinner.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusBar.trailingAnchor, constant: -8),
            statusBar.heightAnchor.constraint(equalToConstant: 26),
        ])
        statusBar.isHidden = true

        view.addSubview(header)
        view.addSubview(toolbar)
        view.addSubview(toolbarUnderline)
        view.addSubview(contentSplit)
        view.addSubview(statusBar)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            toolbar.topAnchor.constraint(equalTo: header.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            toolbarUnderline.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            toolbarUnderline.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbarUnderline.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            contentSplit.topAnchor.constraint(equalTo: toolbarUnderline.bottomAnchor),
            contentSplit.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentSplit.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentSplit.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: public API (called from AppDelegate)

    /// The server became reachable — resolve deferred root loads. Also
    /// resolves the root when the panel has never been opened, so background
    /// monitoring (stale detection + auto-update / update prompts while the
    /// user works in normal dsh sessions) works without showing the panel.
    func serverReady(port: Int) {
        serverReadyPort = port
        if deferredLoad || wikiRoot == nil {
            deferredLoad = false
            resolveAndLoad()
        }
    }

    /// Called when the panel is shown: resolve the wiki root and scan it.
    func ensureWikiLoaded() {
        if wikiRoot != nil {
            refresh()
            return
        }
        if let port = serverReadyPort ?? serverPortProvider?(), port > 0 {
            resolveAndLoad()
        } else {
            deferredLoad = true
        }
    }

    /// 语言切换后刷新头部按钮 tooltip。
    func refreshTooltips() {
        generateButton?.toolTip = L10n.tr("wiki.generateHint")
        revealButton?.toolTip = L10n.tr("preview.revealInFinderHint")
        openButton?.toolTip = L10n.tr("preview.openInDefaultAppHint")
        hideButton?.toolTip = L10n.tr("preview.closePanel")
    }

    /// Re-resolve the root (e.g. wikiRootMode changed) and reload.
    func reloadRoot() {
        repoRoot = nil
        wikiRoot = nil
        selectedPath = nil
        sections = []
        treeOutline.reloadData()
        if let port = serverReadyPort ?? serverPortProvider?(), port > 0 {
            resolveAndLoad()
        } else {
            deferredLoad = true
        }
    }

    /// Current repo root (used by the AppDelegate's AGENTS.md menu toggle).
    var currentRepoRoot: String? { repoRoot }

    // MARK: root resolution & scan

    private func resolveAndLoad() {
        guard let port = serverReadyPort ?? serverPortProvider?() else {
            deferredLoad = true
            return
        }
        // QA hook: point the panel at a fixture wiki root directly.
        if let testPath = ProcessInfo.processInfo.environment["DSH_WIKI_TEST_PATH"],
           !testPath.isEmpty {
            wikiRoot = testPath
            repoRoot = testPath
            scanAndReload()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            DSHSessionRPC.resolveProjectDirectory(port: port, timeout: 6) { dir in
                DispatchQueue.main.async {
                    guard let dir = dir else { return }
                    self.repoRoot = dir
                    self.wikiRoot = WikiPaths.wikiRoot(for: dir)
                    self.scanAndReload()
                }
            }
        }
    }

    private func scanAndReload() {
        guard let root = wikiRoot else { return }
        index = WikiScanner.scan(root: root, repoRoot: repoRoot)
        lastSignature = WikiScanner.signature(root: root)
        rebuildSections()
        treeOutline.reloadData()
        if index.pages.isEmpty {
            showEmptyState()
        } else if selectedPath == nil {
            // open the index page by default
            if let first = index.pages.first(where: { ($0.path as NSString).lastPathComponent == "index.md" })
                ?? index.pages.first {
                selectedPath = first.path
                showPage(first)
            }
        } else if let page = index.pages.first(where: { $0.path == selectedPath }) {
            showPage(page)
        } else {
            selectedPath = nil
            showEmptyState()
        }
        updateInfoLabel()
        AppLog.shared.log("wiki scan: \(index.pages.count) pages, root=\(root)")
        applyInitialTreeWidthIfNeeded()
        syncGenerationUI()
    }

    /// Whether the tree pane's default width has been applied (NSSplitView
    /// would otherwise equal-split the tree and the reader — half and half).
    private var treeWidthInitialized = false
    private func applyInitialTreeWidthIfNeeded() {
        guard !treeWidthInitialized, contentSplit.bounds.width > 0 else { return }
        treeWidthInitialized = true
        contentSplit.setPosition(160, ofDividerAt: 0)
        contentSplit.adjustSubviews()
        AppLog.shared.log("wiki tree width initialized: 160pt")
    }

    /// Rebuild the grouped tree (sections) honoring the search query.
    private func rebuildSections() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        var rootPages: [WikiPage] = []
        var byDir: [String: [WikiPage]] = [:]
        for page in index.pages {
            if !query.isEmpty {
                let hay = (page.title + " " + (page.path as NSString).lastPathComponent).lowercased()
                guard hay.contains(query) else { continue }
            }
            let rel = relPath(page.path)
            if rel == "index.md" {
                // index.md has its own dedicated section (empty query); during
                // a search it falls back into the root bucket.
                if query.isEmpty { continue }
                rootPages.insert(page, at: 0)
            } else if !rel.contains("/") {
                rootPages.append(page)
            } else {
                let dir = (rel as NSString).deletingLastPathComponent
                byDir[dir, default: []].append(page)
            }
        }
        var newSections: [Section] = []
        let indexPages = index.pages.filter { relPath($0.path) == "index.md" }
        if !indexPages.isEmpty && query.isEmpty {
            newSections.append(Section(title: "index", pages: indexPages))
        }
        if !rootPages.isEmpty {
            newSections.append(Section(title: "·", pages: rootPages))
        }
        for dir in byDir.keys.sorted() {
            newSections.append(Section(title: dir, pages: byDir[dir]!))
        }
        sections = newSections
    }

    private func relPath(_ path: String) -> String {
        guard let root = wikiRoot else { return path }
        let rootStd = (root as NSString).standardizingPath
        let pStd = (path as NSString).standardizingPath
        if pStd.hasPrefix(rootStd + "/") {
            return String(pStd.dropFirst(rootStd.count + 1))
        }
        return pStd
    }

    private func updateInfoLabel() {
        let stale = index.pages.filter { $0.isStale }.count
        let manual = index.pages.filter { $0.manual }.count
        let total = index.pages.count
        if total == 0 {
            infoLabel.text = ""
        } else {
            infoLabel.text = L10n.tr("wiki.info", total, stale, manual)
        }
    }

    // MARK: refresh watcher

    private func startRefreshTimer() {
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshIfChanged()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func refreshIfChanged() {
        guard let root = wikiRoot else { return }
        let sig = WikiScanner.signature(root: root)
        if sig != lastSignature {
            lastSignature = sig
            if isGeneratingCurrentRepo {
                // Live progress: pages appear in the tree while the agent
                // writes them; the content area keeps the generating view
                // until the run finishes.
                index = WikiScanner.scan(root: root, repoRoot: repoRoot)
                rebuildSections()
                treeOutline.reloadData()
                updateInfoLabel()
            } else {
                scanAndReload()
            }
        }
        if !isGeneratingCurrentRepo { maybeAutoRegenerate() }
    }

    /// Optional auto-maintenance (setting `wikiAutoRegenerate`, off by
    /// default): when at least 3 pages are stale and the index is older than
    /// 1h, start an incremental update — at most once per hour per panel.
    /// With the setting ON it runs silently; with it OFF the shell still
    /// notices (e.g. while the user works in a normal dsh session) and asks
    /// the user instead.
    private var lastAutoTrigger = Date.distantPast
    private func maybeAutoRegenerate() {
        guard !isGeneratingCurrentRepo, repoRoot != nil else { return }
        guard Date().timeIntervalSince(lastAutoTrigger) > 3600 else { return }
        let staleCount = index.pages.filter { $0.isStale }.count
        let indexAge = index.pages
            .first { ($0.path as NSString).lastPathComponent == "index.md" }
            .map { Date().timeIntervalSince($0.updated) } ?? .greatestFiniteMagnitude
        guard staleCount >= 3 && indexAge > 3600 else { return }
        lastAutoTrigger = Date()
        if UserDefaults.standard.object(forKey: WikiPaths.autoRegenerateKey) as? Bool == true {
            AppLog.shared.log("wiki auto-regenerate: stale=\(staleCount) indexAge=\(Int(indexAge))s")
            startGeneration(.update)
        } else {
            // Auto-update off: still surface the need during normal work
            // (business conversations change the code) and let the user
            // decide — without opening the wiki panel.
            promptForUpdate(staleCount: staleCount)
        }
    }

    /// Ask the user whether to run an incremental update now.
    private func promptForUpdate(staleCount: Int) {
        AppLog.shared.log("wiki update prompt: stale=\(staleCount)")
        let alert = NSAlert()
        alert.messageText = L10n.tr("wiki.updatePromptTitle")
        alert.informativeText = L10n.tr("wiki.updatePromptInfo", staleCount)
        alert.addButton(withTitle: L10n.tr("wiki.updateNow"))
        alert.addButton(withTitle: L10n.tr("wiki.updateLater"))
        if alert.runModal() == .alertFirstButtonReturn {
            startGeneration(.update)
        }
    }

    func refresh() {
        guard let root = wikiRoot else { return }
        lastSignature = WikiScanner.signature(root: root)
        scanAndReload()
    }

    // MARK: generation

    private func generateTapped() {
        if isGeneratingCurrentRepo { return }
        let kind: WikiPrompts.Kind = index.pages.isEmpty ? .initial : .update
        startGeneration(kind)
    }

    private func startGeneration(_ kind: WikiPrompts.Kind) {
        guard !isGeneratingCurrentRepo else { return }
        guard let repo = repoRoot else {
            ensureWikiLoaded()
            return
        }
        guard let port = serverReadyPort ?? serverPortProvider?(), port > 0 else {
            setStatus(L10n.tr("wiki.needServer"), spin: false)
            return
        }
        // The repo-knowledge skill is provisioned globally at app startup
        // (SkillInstaller), so the agent can load it in any workspace.
        let wiki = WikiPaths.wikiRoot(for: repo)
        do {
            try FileManager.default.createDirectory(atPath: wiki, withIntermediateDirectories: true)
        } catch {
            AppLog.shared.log("wiki mkdir failed: \(error.localizedDescription)")
        }

        // Optimistic immediate feedback (session.create below can take a few
        // seconds): show the overlay + status right away.
        showGeneratingOverlay()
        setStatus(L10n.tr("wiki.generating"), spin: true)
        generateButton.isEnabled = false
        startElapsedTimer()

        let zh = L10n.isZh
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let prompt = WikiPrompts.prompt(kind: kind, repoRoot: repo, wikiRoot: wiki, zh: zh)
            // Create the session under the current workspace (like the dsh web
            // client) so the generation session is not left Ungrouped.
            let wid = WikiRPC.resolveWorkspaceId(port: port, cwd: repo)
            guard let sid = WikiRPC.createSession(port: port, cwd: repo, workspaceId: wid) else {
                DispatchQueue.main.async { self.generationFailed(repo: repo) }
                return
            }
            guard WikiRPC.prompt(port: port, sessionId: sid, text: prompt) else {
                DispatchQueue.main.async { self.generationFailed(repo: repo) }
                return
            }
            DispatchQueue.main.async {
                let key = WikiRPC.canonical(repo)
                self.generations[key] = Generation(repo: repo, sessionId: sid, kind: kind, start: Date())
                self.ensurePolling(port: port)
                self.syncGenerationUI()
                AppLog.shared.log("wiki generation started: repo=\(repo) session=\(sid) kind=\(kind.rawValue)")
            }
        }
    }

    /// One shared poll timer iterating every in-flight generation.
    private func ensurePolling(port: Int) {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let snapshot = self.generations
            DispatchQueue.global(qos: .userInitiated).async {
                var finished: [(String, Generation)] = []
                for (key, gen) in snapshot {
                    if !WikiRPC.sessionRunning(port: port, sessionId: gen.sessionId) {
                        finished.append((key, gen))
                    }
                }
                DispatchQueue.main.async {
                    for (key, gen) in finished {
                        self.generations.removeValue(forKey: key)
                        self.generationSettled(key: key, gen: gen, ok: true)
                    }
                    self.syncGenerationUI()
                    if self.generations.isEmpty {
                        self.stopPolling()
                        self.stopElapsedTimer()
                        self.hideStatus()
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// A generation for one repo settled (ok: session finished; false: failed
    /// to start). Only the repo currently shown is refreshed in place; other
    /// repos' files are picked up when the user switches to them.
    private func generationSettled(key: String, gen: Generation, ok: Bool) {
        if ok, UserDefaults.standard.object(forKey: WikiPaths.registerAgentsMdKey) as? Bool == true {
            _ = WikiAgentsMD.register(repoRoot: gen.repo)
        }
        if let repo = repoRoot, WikiRPC.canonical(repo) == key {
            if ok {
                lastSignature = [:]
                refresh()
                if gen.kind == .initial,
                   UserDefaults.standard.object(forKey: WikiPaths.autoRegenerateKey) == nil {
                    promptEnableAutoUpdate()
                }
                // Auto-commit the changed wiki docs (add + commit, NO push).
                // Runs off the main thread; a successful commit refreshes the
                // tree so stale-detection reflects the new file mtimes.
                DispatchQueue.global(qos: .utility).async {
                    WikiAutoCommit.commitWikiChanges(repoRoot: gen.repo)
                    DispatchQueue.main.async { [weak self] in
                        self?.refresh()
                    }
                }
            } else {
                setStatus(L10n.tr("wiki.failed"), spin: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    self?.hideStatus()
                }
                lastSignature = [:]
                refresh()
            }
        }
        AppLog.shared.log("wiki generation settled: repo=\(gen.repo) ok=\(ok)")
    }

    private func generationFailed(repo: String) {
        let key = WikiRPC.canonical(repo)
        let gen = generations.removeValue(forKey: key)
        syncGenerationUI()
        if generations.isEmpty {
            stopPolling()
            stopElapsedTimer()
        }
        if let gen = gen {
            generationSettled(key: key, gen: gen, ok: false)
        }
    }

    /// First-generation follow-up: offer to turn on auto-updating.
    private func promptEnableAutoUpdate() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("wiki.autoPromptTitle")
        alert.informativeText = L10n.tr("wiki.autoPromptInfo")
        alert.addButton(withTitle: L10n.tr("wiki.autoPromptEnable"))
        alert.addButton(withTitle: L10n.tr("wiki.autoPromptLater"))
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            UserDefaults.standard.set(true, forKey: WikiPaths.autoRegenerateKey)
            AppLog.shared.log("wiki auto-update enabled via first-generation prompt")
            onAutoUpdateSettingChanged?()
        }
    }

    // MARK: generation progress UI

    /// Show "Generating…" as an OVERLAY on top of the reader pane — the
    /// existing page (and the whole layout) stays visible underneath; nothing
    /// is cleared. The label uses the proven empty-state rendering
    /// (NSTextField in a centered stack); the overlay backdrop is best-effort
    /// (falls back to transparent if the custom fill does not draw).
    private func showGeneratingOverlay() {
        // Not showing a page anymore — clear the stale page title.
        headerTitle.text = L10n.tr("wiki.title")
        generatingOverlay?.removeFromSuperview()
        let overlay = WikiOverlayView()
        overlay.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: L10n.tr("wiki.generating"))
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(stack)
        contentContainer.addSubview(overlay)
        generatingOverlay = overlay
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])
    }

    /// Sync every generation-related UI element with the state for the repo
    /// currently shown: the overlay, the bottom status strip, and the +
    /// button's enabled state. Called on every scan/reload (so workspace
    /// switches re-sync automatically) and whenever a generation starts or
    /// settles.
    private func syncGenerationUI() {
        guard repoRoot != nil else {
            generatingOverlay?.removeFromSuperview()
            generatingOverlay = nil
            generateButton.isEnabled = true
            hideStatus()
            return
        }
        let active = activeGenerationForCurrentRepo
        // The + button is only blocked while THIS repo is generating.
        generateButton.isEnabled = active == nil
        if let gen = active {
            showGeneratingOverlay()
            let secs = Int(Date().timeIntervalSince(gen.start))
            statusLabel.text = L10n.tr("wiki.generatingElapsed", secs)
            statusBar.isHidden = false
            statusSpinner.startAnimation(nil)
        } else {
            generatingOverlay?.removeFromSuperview()
            generatingOverlay = nil
            if let other = generations.values.first {
                let name = (other.repo as NSString).lastPathComponent
                statusLabel.text = L10n.tr("wiki.generatingOther", name)
                statusBar.isHidden = false
                statusSpinner.startAnimation(nil)
            } else {
                hideStatus()
            }
        }
    }

    private func startElapsedTimer() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if let gen = self.activeGenerationForCurrentRepo {
                let secs = Int(Date().timeIntervalSince(gen.start))
                self.statusLabel.text = L10n.tr("wiki.generatingElapsed", secs)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func setStatus(_ text: String, spin: Bool) {
        statusLabel.text = text
        statusBar.isHidden = false
        if spin {
            statusSpinner.startAnimation(nil)
        } else {
            statusSpinner.stopAnimation(nil)
        }
    }

    private func hideStatus() {
        statusSpinner.stopAnimation(nil)
        statusBar.isHidden = true
    }

    // MARK: actions

    private func revealInFinder() {
        guard let sel = selectedPage() else {
            if let root = wikiRoot { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root)]) }
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: sel.path)])
    }

    private func openInDefaultApp() {
        guard let sel = selectedPage() else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: sel.path))
    }

    private func selectedPage() -> WikiPage? {
        guard let path = selectedPath else { return nil }
        return index.pages.first { $0.path == path }
    }

    // MARK: rendering

    private func showEmptyState() {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        // Reset the header title — the panel is no longer showing any page
        // (e.g. after switching to a workspace whose directory has no wiki).
        selectedPath = nil
        headerTitle.text = L10n.tr("wiki.title")
        let iconView = BakedIconView(symbol: "book.closed")
        let label = NSTextField(wrappingLabelWithString: L10n.tr("wiki.empty"))
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.preferredMaxLayoutWidth = 280
        let stack = NSStackView(views: [iconView, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentContainer.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentContainer.trailingAnchor, constant: -20),
            iconView.widthAnchor.constraint(equalToConstant: 48),
            iconView.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    private func showPage(_ page: WikiPage) {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 12, height: 12)
        tv.delegate = self
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = tv

        guard let root = wikiRoot else { return }
        let body = NSMutableAttributedString(attributedString:
            WikiMarkdownRenderer.render(markdown: page.body, wikiRoot: root, pagePath: page.path))
        appendBacklinksFooter(body, for: page)
        tv.textStorage?.setAttributedString(body)

        contentContainer.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        headerTitle.text = page.displayName
        // scroll to top
        if let doc = scroll.documentView, doc.frame.height > 0 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: doc.bounds.maxY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func appendBacklinksFooter(_ body: NSMutableAttributedString, for page: WikiPage) {
        let links = index.backlinks[page.path] ?? []
        guard !links.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        body.append(NSAttributedString(string: "\n\n" + String(repeating: "─", count: 40) + "\n",
                                       attributes: attrs))
        body.append(NSAttributedString(string: L10n.tr("wiki.backlinks") + "\n", attributes: attrs))
        let linkAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        for linkPath in links {
            guard let url = WikiMarkdownRenderer.internalURL(linkPath) else { continue }
            var a = linkAttrs
            a[.link] = url
            let title = ((linkPath as NSString).lastPathComponent as NSString).deletingPathExtension
            body.append(NSAttributedString(string: "• " + title + "\n", attributes: a))
        }
    }

    // MARK: NSTextViewDelegate (link clicks)

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL else { return false }
        if url.scheme == "dshwiki" {
            let path = url.path
            if let page = index.pages.first(where: { $0.path == path }) {
                selectedPath = path
                showPage(page)
                selectRow(for: path)
            } else if FileManager.default.fileExists(atPath: path) {
                // an un-indexed markdown file — try to show it raw
                selectedPath = path
                let (meta, body) = WikiFrontmatter.parse((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
                _ = meta
                if wikiRoot != nil {
                    let page = WikiPage(path: path,
                                        title: ((path as NSString).lastPathComponent as NSString).deletingPathExtension,
                                        tags: [], updated: Date(), sources: [], manual: false,
                                        truncated: false, isStale: false, body: body)
                    showPage(page)
                }
            }
            return true
        }
        NSWorkspace.shared.open(url)
        return true
    }

    // MARK: NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        rebuildSections()
        treeOutline.reloadData()
    }

    // MARK: NSOutlineView data source / delegate

    private func selectRow(for path: String) {
        for sectionIndex in 0..<sections.count {
            if let row = sections[sectionIndex].pages.firstIndex(where: { $0.path == path }) {
                treeOutline.expandItem(sections[sectionIndex])
                let outlineRow = treeOutline.row(forItem: sections[sectionIndex].pages[row])
                if outlineRow >= 0 {
                    treeOutline.selectRowIndexes(IndexSet(integer: outlineRow), byExtendingSelection: false)
                }
                return
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return sections.count }
        guard let section = item as? Section else { return 0 }
        return section.pages.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return sections[index] }
        return (item as! Section).pages[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is Section
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let ident = NSUserInterfaceItemIdentifier("wikiCell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: ident, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = ident
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            cell.textField = tf
            cell.addSubview(tf)
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        if let section = item as? Section {
            cell.textField?.stringValue = section.title
            cell.textField?.font = .systemFont(ofSize: 11, weight: .semibold)
            cell.textField?.textColor = .secondaryLabelColor
        } else if let page = item as? WikiPage {
            cell.textField?.stringValue = page.displayName
            cell.textField?.font = .systemFont(ofSize: 12)
            cell.textField?.textColor = .textColor
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = treeOutline.selectedRow
        guard row >= 0 else { return }
        if let page = treeOutline.item(atRow: row) as? WikiPage {
            selectedPath = page.path
            showPage(page)
        }
    }

    // MARK: NSSplitViewDelegate (tree | reader)

    /// Keep the tree narrow but usable when dragging the divider.
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        160
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        360
    }
}

// MARK: - Wiki auto-commit (git add + commit, no push)

/// After a wiki generation/update settles, auto-commit the changed wiki docs
/// under `<repoRoot>/.dsh/wiki/` — but NEVER push. Committing keeps the wiki
/// history reviewable and shareable; pushing is left to the user (or the
/// IssueRunner task panel's explicit flows).
enum WikiAutoCommit {

    /// True when `repoRoot` is inside a git work tree.
    static func isGitRepo(_ repoRoot: String) -> Bool {
        runGit(["rev-parse", "--is-inside-work-tree"], repoRoot) == "true"
    }

    /// Run a git command in repoRoot; returns trimmed stdout or nil on failure.
    @discardableResult
    static func runGit(_ args: [String], _ repoRoot: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", repoRoot] + args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fallback commit: the repo-knowledge skill instructs the AGENT to commit
    /// (with its own summarized message) after an update. This only fires when
    /// the agent did NOT commit (e.g. git unusable in its session, or it chose
    /// to skip) — i.e. there are still uncommitted .dsh/wiki changes here.
    /// Never pushes. Failures are logged only (never block or alert the user).
    static func commitWikiChanges(repoRoot: String) {
        guard isGitRepo(repoRoot) else { return }
        // Nothing changed under .dsh/wiki → nothing to commit.
        let status = runGit(["status", "--porcelain", "--", ".dsh/wiki"], repoRoot)
        guard let status = status, !status.isEmpty else { return }

        guard runGit(["add", "--", ".dsh/wiki"], repoRoot) != nil else {
            AppLog.shared.log("wiki auto-commit: git add failed")
            return
        }
        // Fallback message summarizes the actual changed content.
        let diff = runGit(["diff", "--cached", "--", ".dsh/wiki"], repoRoot)
        let message = commitMessage(status: status, diff: diff)
        guard runGit(["commit", "-m", message], repoRoot) != nil else {
            AppLog.shared.log("wiki auto-commit: git commit failed (no identity? nothing staged?)")
            return
        }
        AppLog.shared.log("wiki auto-commit (fallback): committed .dsh/wiki changes (not pushed): \(message)")
    }

    /// Build a commit message that reflects the ACTUAL content changed:
    /// groups by 新增/更新/删除 and, for each page, quotes the first
    /// meaningful added line (frontmatter noise like the always-changing
    /// `updated:` timestamp, separators and diff headers are filtered out).
    ///
    ///   diff --git a/.dsh/wiki/overview.md b/.dsh/wiki/overview.md
    ///   @@ -95,0 +96 @@ …
    ///   +# 新增的真实内容
    ///
    /// → "docs(wiki): 更新 overview：新增的真实内容"
    static func commitMessage(status: String, diff: String? = nil) -> String {
        // per-file summaries: path → first meaningful added line (trimmed).
        var content: [String: String] = [:]
        if let diff = diff {
            var currentFile: String?
            for line in diff.split(separator: "\n") {
                let s = String(line)
                if s.hasPrefix("diff --git ") {
                    // diff --git a/.dsh/wiki/X b/.dsh/wiki/X
                    let parts = s.split(separator: " ")
                    if parts.count >= 4 {
                        currentFile = String(parts[3]).replacingOccurrences(of: "b/", with: "")
                    } else {
                        currentFile = nil
                    }
                    continue
                }
                guard let file = currentFile, file.hasPrefix(".dsh/wiki/") else { continue }
                guard s.hasPrefix("+"), !s.hasPrefix("+++") else { continue }
                let trimmed = s.dropFirst().trimmingCharacters(in: .whitespaces)
                // Filter frontmatter / structural noise.
                guard !trimmed.isEmpty,
                      trimmed != "---",
                      !trimmed.hasPrefix("updated:"),
                      !trimmed.hasPrefix("title:"),
                      !trimmed.hasPrefix("tags:"),
                      !trimmed.hasPrefix("sources:"),
                      !trimmed.hasPrefix("#"),
                      !trimmed.hasPrefix("-"),
                      !trimmed.hasPrefix("*"),
                      content[file] == nil else { continue }
                let snippet = trimmed.count > 30 ? String(trimmed.prefix(30)) + "…" : trimmed
                content[file] = snippet
            }
        }
        // Path relative to repo root, with the .dsh/wiki/ prefix stripped.
        func relPath(_ p: String) -> String {
            String(p.replacingOccurrences(of: ".dsh/wiki/", with: ""))
        }
        func annotated(_ p: String) -> String {
            let rel = relPath(p)
            guard let snippet = content[p] else { return rel }
            return "\(rel)：\(snippet)"
        }

        var added: [String] = []
        var modified: [String] = []
        var deleted: [String] = []
        for line in status.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }
            let flag = String(parts[0])
            let path = String(parts[1])
            if flag.contains("D") { deleted.append(relPath(path)) }
            else if flag.contains("?") || flag.contains("A") { added.append(annotated(path)) }
            else { modified.append(annotated(path)) }
        }
        var summary: [String] = []
        if !added.isEmpty { summary.append("新增 \(added.joined(separator: "、"))") }
        if !modified.isEmpty { summary.append("更新 \(modified.joined(separator: "、"))") }
        if !deleted.isEmpty { summary.append("删除 \(deleted.joined(separator: "、"))") }
        let detail = summary.isEmpty
            ? "知识库增量更新"
            : summary.joined(separator: "；")
        return "docs(wiki): \(detail)"
    }
}
