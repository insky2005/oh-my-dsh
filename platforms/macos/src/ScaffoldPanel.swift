//
//  ScaffoldPanel.swift — 工程脚手架（Scaffold Workbench）面板
//
//  M1 范围（docs/scaffold-workbench-design.md 第 11 节）：
//    StageCatalogLoader / ScaffoldTemplateRenderer / ScaffoldPlan / ScaffoldApplier /
//    ScaffoldPanelController + 工程基础 10 环节 + 预设 3 组。
//  M3（Agent 深化）与示例栈（M2）不在本文件当前实现内。
//
//  设计约束：
//   - 不改动任何 DeepSeek Harness 源码；一切通过壳层面板 + 本地确定性渲染实现；
//   - 环节库 stage.yaml 为 YAML 子集（MiniYAML 解析），坏清单隔离不拖垮内置环节；
//   - 模板语法 v1 刻意最小：{{var}} + {{#if key}}…{{/if}}，{{{{ / }}}} 转义字面量；
//   - 引擎（解析/渲染/规划/落盘）不依赖面板与网络，可在 CI 无头测试。
//

import AppKit
import Foundation

// MARK: - MiniYAML（stage.yaml 子集解析器）

/// YAML 子集节点。仅支持本工程 stage.yaml 用到的结构：
/// 顶层 map、嵌套 map（缩进）、list（"- " 项，可内嵌 map）、
/// 内联 list "[a, b]"、内联 map "{ k: v, k2: v2 }"、引号/裸标量。
enum YAMLNode {
    case scalar(String)
    case map([String: YAMLNode])
    case list([YAMLNode])

    func scalarValue() -> String? {
        if case .scalar(let s) = self { return s }
        return nil
    }
    func mapValue() -> [String: YAMLNode]? {
        if case .map(let m) = self { return m }
        return nil
    }
    func listValue() -> [YAMLNode]? {
        if case .list(let l) = self { return l }
        return nil
    }
}

enum MiniYAMLError: Error, CustomStringConvertible {
    case parse(String)
    var description: String {
        switch self {
        case .parse(let m): return "YAML 解析失败 / YAML parse error: \(m)"
        }
    }
}

enum MiniYAML {
    struct Line {
        let indent: Int
        let content: String
        let number: Int
    }

    static func parse(_ text: String) throws -> YAMLNode {
        let lines = try preprocess(text)
        guard let first = lines.first else { return .map([:]) }
        let (node, _) = try parseBlock(lines, at: 0, indent: first.indent)
        return node
    }

    // MARK: preprocess

    private static func preprocess(_ text: String) throws -> [Line] {
        var raw = text
        if raw.hasPrefix("\u{FEFF}") { raw.removeFirst() }
        let split = raw.components(separatedBy: "\n")
        var out: [Line] = []
        for (idx, line) in split.enumerated() {
            var indent = 0
            for ch in line {
                if ch == " " { indent += 1 } else { break }
            }
            var content = String(line.dropFirst(indent))
            content = stripInlineComment(content)
            content = content.trimmingCharacters(in: .whitespaces)
            if content.isEmpty { continue }
            if content.hasPrefix("#") { continue }
            out.append(Line(indent: indent, content: content, number: idx + 1))
        }
        return out
    }

    /// 去掉行内注释：引号外的 " #…"（# 前为空白）。
    private static func stripInlineComment(_ s: String) -> String {
        var inDouble = false
        var inSingle = false
        var prev: Character = " "
        for (i, ch) in s.enumerated() {
            if ch == "\"" && !inSingle { inDouble.toggle() }
            else if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "#", !inDouble, !inSingle, prev == " " || prev == "\t" {
                return String(s.prefix(i))
            }
            prev = ch
        }
        return s
    }

    // MARK: block parsing

    private static func parseBlock(_ lines: [Line], at index: Int, indent: Int) throws -> (YAMLNode, Int) {
        let content = lines[index].content
        if content == "-" || content.hasPrefix("- ") {
            return try parseList(lines, at: index, indent: indent)
        }
        return try parseMap(lines, at: index, indent: indent)
    }

    private static func parseMap(_ lines: [Line], at index: Int, indent: Int) throws -> (YAMLNode, Int) {
        var map: [String: YAMLNode] = [:]
        var i = index
        while i < lines.count {
            let line = lines[i]
            if line.indent != indent { break }
            let content = line.content
            if content.hasPrefix("-") { break }
            guard let colon = firstColon(in: content) else { break }
            let key = String(content[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { throw MiniYAMLError.parse("空键名 / empty key at line \(line.number)") }
            let valueStr = String(content[content.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if valueStr.isEmpty {
                if i + 1 < lines.count, lines[i + 1].indent > indent {
                    let (child, ni) = try parseBlock(lines, at: i + 1, indent: lines[i + 1].indent)
                    map[key] = child
                    i = ni
                } else {
                    map[key] = .map([:])
                    i += 1
                }
            } else {
                map[key] = try parseInline(valueStr)
                i += 1
            }
        }
        return (.map(map), i)
    }

    private static func parseList(_ lines: [Line], at index: Int, indent: Int) throws -> (YAMLNode, Int) {
        var items: [YAMLNode] = []
        var i = index
        while i < lines.count {
            let line = lines[i]
            if line.indent != indent { break }
            let content = line.content
            if content == "-" {
                if i + 1 < lines.count, lines[i + 1].indent > indent {
                    let (child, ni) = try parseBlock(lines, at: i + 1, indent: lines[i + 1].indent)
                    items.append(child)
                    i = ni
                } else {
                    items.append(.map([:]))
                    i += 1
                }
                continue
            }
            guard content.hasPrefix("- ") else { break }
            let rest = String(content.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                if i + 1 < lines.count, lines[i + 1].indent > indent {
                    let (child, ni) = try parseBlock(lines, at: i + 1, indent: lines[i + 1].indent)
                    items.append(child)
                    i = ni
                } else {
                    items.append(.map([:]))
                    i += 1
                }
                continue
            }
            if let colon = firstColon(in: rest) {
                // map 项："- key: value"，后续更深缩进行继续属于同一 map
                let key = String(rest[..<colon]).trimmingCharacters(in: .whitespaces)
                let valueStr = String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                var map: [String: YAMLNode] = [:]
                if valueStr.isEmpty {
                    if i + 1 < lines.count, lines[i + 1].indent > indent {
                        let (child, ni) = try parseBlock(lines, at: i + 1, indent: lines[i + 1].indent)
                        map[key] = child
                        i = ni
                    } else {
                        map[key] = .map([:])
                        i += 1
                    }
                } else {
                    map[key] = try parseInline(valueStr)
                    i += 1
                }
                if i < lines.count, lines[i].indent > indent {
                    let itemIndent = lines[i].indent
                    while i < lines.count, lines[i].indent == itemIndent {
                        let l = lines[i]
                        if l.content.hasPrefix("-") { break }
                        guard let c = firstColon(in: l.content) else { break }
                        let k = String(l.content[..<c]).trimmingCharacters(in: .whitespaces)
                        let v = String(l.content[l.content.index(after: c)...]).trimmingCharacters(in: .whitespaces)
                        if v.isEmpty {
                            if i + 1 < lines.count, lines[i + 1].indent > itemIndent {
                                let (child, ni) = try parseBlock(lines, at: i + 1, indent: lines[i + 1].indent)
                                map[k] = child
                                i = ni
                            } else {
                                map[k] = .map([:])
                                i += 1
                            }
                        } else {
                            map[k] = try parseInline(v)
                            i += 1
                        }
                    }
                }
                items.append(.map(map))
            } else {
                items.append(try parseInline(rest))
                i += 1
            }
        }
        return (.list(items), i)
    }

    private static func firstColon(in s: String) -> String.Index? {
        var inDouble = false
        var inSingle = false
        for (i, ch) in s.enumerated() {
            if ch == "\"" && !inSingle { inDouble.toggle() }
            else if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == ":", !inDouble, !inSingle {
                return s.index(s.startIndex, offsetBy: i)
            }
        }
        return nil
    }

    // MARK: inline values

    private static func parseInline(_ s: String) throws -> YAMLNode {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("[") {
            guard let close = findClosing(t, open: "[", close: "]") else {
                throw MiniYAMLError.parse("内联 list 未闭合 / unclosed inline list: \(t)")
            }
            let inner = String(t[t.index(after: t.startIndex)..<close])
            let parts = splitTopLevel(inner, separator: ",")
            let items = parts.map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            return .list(items.map { .scalar($0) })
        }
        if t.hasPrefix("{") {
            guard let close = findClosing(t, open: "{", close: "}") else {
                throw MiniYAMLError.parse("内联 map 未闭合 / unclosed inline map: \(t)")
            }
            let inner = String(t[t.index(after: t.startIndex)..<close])
            let parts = splitTopLevel(inner, separator: ",")
            var map: [String: YAMLNode] = [:]
            for part in parts {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                guard let colon = firstColon(in: trimmed) else { continue }
                let k = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                let v = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                map[k] = .scalar(unquote(v))
            }
            return .map(map)
        }
        return .scalar(unquote(t))
    }

    /// 返回与 open 匹配的 close 的索引（忽略引号内字符）。
    private static func findClosing(_ s: String, open: Character, close: Character) -> String.Index? {
        var depth = 0
        var inDouble = false
        var inSingle = false
        for (i, ch) in s.enumerated() {
            if ch == "\"" && !inSingle { inDouble.toggle() }
            else if ch == "'" && !inDouble { inSingle.toggle() }
            else if !inDouble, !inSingle {
                if ch == open { depth += 1 }
                else if ch == close {
                    depth -= 1
                    if depth == 0 { return s.index(s.startIndex, offsetBy: i) }
                }
            }
        }
        return nil
    }

    private static func splitTopLevel(_ s: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var inDouble = false
        var inSingle = false
        for ch in s {
            if ch == "\"" && !inSingle { inDouble.toggle() }
            else if ch == "'" && !inDouble { inSingle.toggle() }
            if ch == separator, !inDouble, !inSingle {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts
    }

    private static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2 {
            let first = t.first!
            let last = t.last!
            if first == "\"", last == "\"" {
                var inner = String(t.dropFirst().dropLast())
                inner = inner.replacingOccurrences(of: "\\\"", with: "\"")
                inner = inner.replacingOccurrences(of: "\\\\", with: "\\")
                return inner
            }
            if first == "'", last == "'" {
                return String(t.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
        }
        return t
    }
}

// MARK: - 环节模型（stage.yaml 数据）

struct StageParam {
    let key: String
    let labelZh: String
    let labelEn: String
    let type: String        // string | select | bool
    let options: [String]
    let defaultValue: String
    let validate: String

    var label: String { L10n.isZh ? labelZh : labelEn }
}

struct StageFile {
    enum Condition {
        case always
        case truthy(String)
        case equals(String, String)
    }
    let pathTemplate: String
    let templateName: String
    let condition: Condition

    func isActive(params: [String: String]) -> Bool {
        switch condition {
        case .always: return true
        case .truthy(let k): return ScaffoldTemplateRenderer.isTruthy(params[k])
        case .equals(let k, let v): return params[k] == v
        }
    }
}

struct ScaffoldStage {
    let id: String
    let nameZh: String
    let nameEn: String
    let category: String
    let descriptionZh: String
    let descriptionEn: String
    let params: [StageParam]
    let files: [StageFile]
    let commands: [String]
    /// 环节目录（stage.yaml + templates/ 所在），渲染时定位模板文件。
    let directory: String
    /// 是否来自用户环节库（自定义：覆盖内置或新建；内置修改保存后即为 true）。
    let isCustom: Bool

    var name: String { L10n.isZh ? nameZh : nameEn }
    var desc: String { L10n.isZh ? descriptionZh : descriptionEn }
}

// MARK: - StageCatalogLoader（加载/解析/校验，坏清单隔离）

struct StageCatalogLoader {
    struct LoadResult {
        var stages: [ScaffoldStage] = []
        var errors: [String] = []
        /// 内置环节库中存在的环节 id（无论是否被用户覆盖），用于「已修改内置 vs 新建自定义」判定。
        var builtinIDs: Set<String> = []
    }

    /// 用户环节库根目录：DSH_SCAFFOLD_USER_STAGES（QA/测试覆盖）→ $DSH_HOME/scaffold-stages。
    static func userStagesDir() -> String {
        if let env = ProcessInfo.processInfo.environment["DSH_SCAFFOLD_USER_STAGES"], !env.isEmpty {
            return env
        }
        let home = ProcessInfo.processInfo.environment["DSH_HOME"] ?? (NSHomeDirectory() + "/.dsh")
        return (home as NSString).appendingPathComponent("scaffold-stages")
    }

    /// 搜索链：用户环节库（同名覆盖内置）→ 内置（bundle Resources）→ DSH_SCAFFOLD_STAGES（追加，不覆盖）。
    static func searchDirs() -> [String] {
        var dirs: [String] = []
        let user = userStagesDir()
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: user, isDirectory: &isDir), isDir.boolValue {
            dirs.append(user)
        }
        if let res = Bundle.main.resourceURL {
            let p = res.appendingPathComponent("scaffold-stages").path
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                dirs.append(p)
            }
        }
        if let env = ProcessInfo.processInfo.environment["DSH_SCAFFOLD_STAGES"], !env.isEmpty {
            dirs.append(env)
        }
        return dirs
    }

    /// 内置环节库目录（bundle Resources；headless 下不存在）。
    static func builtinBundleDir() -> String? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let p = res.appendingPathComponent("scaffold-stages").path
        var isDir: ObjCBool = false
        return (FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue) ? p : nil
    }

    /// 按目录顺序加载；同名 id 先到先得，但用户环节库恒优先（无论目录顺序，用户库同名
    /// 环节覆盖此前加载的内置/env 环节；内置/env 之间的重复保持旧语义：跳过 + 报错）。
    /// builtinDir/userDir 影响标记而非加载：builtinDir 的 id 计入 builtinIDs（无论是否被覆盖）；
    /// 来自 userDir 的环节 isCustom=true。
    static func load(dirs: [String] = searchDirs(), builtinDir: String? = nil, userDir: String? = nil) -> LoadResult {
        var result = LoadResult()
        var seen = Set<String>()
        var customWinner = Set<String>()
        let fm = FileManager.default
        let user = URL(fileURLWithPath: userDir ?? userStagesDir()).standardizedFileURL.path
        for dir in dirs {
            let entries = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            for name in entries.sorted() {
                guard !name.hasPrefix(".") else { continue }
                let stageDir = (dir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: stageDir, isDirectory: &isDir), isDir.boolValue else { continue }
                let yamlPath = (stageDir as NSString).appendingPathComponent("stage.yaml")
                guard fm.fileExists(atPath: yamlPath) else { continue }
                do {
                    let isCustom = URL(fileURLWithPath: dir).standardizedFileURL.path == user
                    let stage = try loadStage(from: stageDir, isCustom: isCustom)
                    if !seen.contains(stage.id) {
                        seen.insert(stage.id)
                        if isCustom { customWinner.insert(stage.id) }
                        result.stages.append(stage)
                    } else if isCustom, let idx = result.stages.firstIndex(where: { $0.id == stage.id }) {
                        // 用户库同名：覆盖先前加载的内置/env 环节（用户优先）
                        result.stages[idx] = stage
                        customWinner.insert(stage.id)
                    } else if !customWinner.contains(stage.id) {
                        // 内置/env 之间的重复：跳过 + 报错（env 追加语义，不覆盖）
                        result.errors.append("\(stage.id): 跳过重复环节（同名已加载）/ duplicate stage skipped")
                    }
                    // customWinner 已决的重复（内置/env 与用户库同名）→ 静默跳过（覆盖为预期行为）
                } catch {
                    result.errors.append("\(name): 加载失败：\(error.localizedDescription) / load failed")
                }
            }
        }
        // builtinIDs：扫描内置目录（独立于加载结果，被覆盖的 id 也在列）
        if let bd = builtinDir ?? builtinBundleDir() {
            result.builtinIDs = collectIDs(in: bd)
        }
        return result
    }

    /// 收集目录下所有 stage.yaml 的 id（坏清单静默跳过，仅用于内置标记）。
    static func collectIDs(in dir: String) -> Set<String> {
        var out = Set<String>()
        let fm = FileManager.default
        for name in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() {
            guard !name.hasPrefix(".") else { continue }
            let stageDir = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: stageDir, isDirectory: &isDir), isDir.boolValue else { continue }
            let yamlPath = (stageDir as NSString).appendingPathComponent("stage.yaml")
            guard fm.fileExists(atPath: yamlPath) else { continue }
            if let text = try? String(contentsOfFile: yamlPath, encoding: .utf8),
               let id = try? parseStageID(from: text), !id.isEmpty {
                out.insert(id)
            }
        }
        return out
    }

    /// 从 stage.yaml 文本解析 id（供保存校验/内置扫描）。
    static func parseStageID(from yaml: String) throws -> String {
        let node = try MiniYAML.parse(yaml)
        guard let map = node.mapValue() else { throw ScaffoldCatalogError.message("stage.yaml 顶层须为 map / top level must be a map") }
        guard let id = map["id"]?.scalarValue(), !id.isEmpty else { throw ScaffoldCatalogError.message("缺少 id / missing id") }
        return id
    }

    /// 环节 id 合法性：小写字母/数字/连字符，非空。
    static func validateStageID(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        return id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// 用户库中某环节的目录（<user>/<id>）。
    static func userStageDir(id: String) -> String {
        (userStagesDir() as NSString).appendingPathComponent(id)
    }

    /// 保存用户环节：建目录 → （可选）复制来源目录的 templates/ → 写 stage.yaml。
    static func saveUserStage(id: String, yaml: String, templatesFrom: String? = nil) throws {
        let dir = userStageDir(id: id)
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // 复制模板目录（修改内置时模板需一并带到用户库）
        if let src = templatesFrom, !src.isEmpty {
            let srcTpl = (src as NSString).appendingPathComponent("templates")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: srcTpl, isDirectory: &isDir), isDir.boolValue {
                let dstTpl = (dir as NSString).appendingPathComponent("templates")
                if fm.fileExists(atPath: dstTpl) { try? fm.removeItem(atPath: dstTpl) }
                try fm.copyItem(atPath: srcTpl, toPath: dstTpl)
            }
        }
        let yamlPath = (dir as NSString).appendingPathComponent("stage.yaml")
        try yaml.write(toFile: yamlPath, atomically: true, encoding: .utf8)
    }

    /// 删除用户环节（恢复内置 = 删除覆盖拷贝；删除自定义 = 删除整个目录）。
    @discardableResult
    static func removeUserStage(id: String) -> Bool {
        let dir = userStageDir(id: id)
        guard FileManager.default.fileExists(atPath: dir) else { return false }
        return (try? FileManager.default.removeItem(atPath: dir)) != nil
    }

    static func loadStage(from dir: String, isCustom: Bool = false) throws -> ScaffoldStage {
        let yamlPath = (dir as NSString).appendingPathComponent("stage.yaml")
        let text: String
        do { text = try String(contentsOfFile: yamlPath, encoding: .utf8) }
        catch { throw ScaffoldCatalogError.message("无法读取 stage.yaml / cannot read stage.yaml") }
        let node = try MiniYAML.parse(text)
        guard let map = node.mapValue() else { throw ScaffoldCatalogError.message("stage.yaml 顶层须为 map / top level must be a map") }

        func str(_ key: String) -> String? { map[key]?.scalarValue() }
        func strIn(_ key: String, _ sub: String) -> String? { map[key]?.mapValue()?[sub]?.scalarValue() }

        guard let id = str("id"), !id.isEmpty else { throw ScaffoldCatalogError.message("缺少 id / missing id") }
        let nameZh = strIn("name", "zh") ?? id
        let nameEn = strIn("name", "en") ?? id
        let category = str("category") ?? "foundation"
        let descZh = strIn("description", "zh") ?? nameZh
        let descEn = strIn("description", "en") ?? nameEn

        var params: [StageParam] = []
        if let paramNodes = map["params"]?.listValue() {
            for pn in paramNodes {
                guard let pm = pn.mapValue(), let key = pm["key"]?.scalarValue(), !key.isEmpty else {
                    throw ScaffoldCatalogError.message("\(id): params 项缺少 key / param item missing key")
                }
                params.append(StageParam(
                    key: key,
                    labelZh: pm["label"]?.mapValue()?["zh"]?.scalarValue() ?? key,
                    labelEn: pm["label"]?.mapValue()?["en"]?.scalarValue() ?? key,
                    type: pm["type"]?.scalarValue() ?? "string",
                    options: pm["options"]?.listValue()?.compactMap { $0.scalarValue() } ?? [],
                    defaultValue: pm["default"]?.scalarValue() ?? "",
                    validate: pm["validate"]?.scalarValue() ?? ""
                ))
            }
        }

        var files: [StageFile] = []
        if let fileNodes = map["files"]?.listValue() {
            for fn in fileNodes {
                guard let fm = fn.mapValue(),
                      let path = fm["path"]?.scalarValue(), !path.isEmpty,
                      let tpl = fm["template"]?.scalarValue(), !tpl.isEmpty else {
                    throw ScaffoldCatalogError.message("\(id): files 项缺少 path/template / file item missing path or template")
                }
                var condition = StageFile.Condition.always
                if let cond = fm["if"]?.scalarValue(), !cond.isEmpty {
                    if let eq = cond.range(of: "=") {
                        let k = String(cond[..<eq.lowerBound]).trimmingCharacters(in: .whitespaces)
                        let v = String(cond[eq.upperBound...]).trimmingCharacters(in: .whitespaces)
                        condition = .equals(k, v)
                    } else {
                        condition = .truthy(cond)
                    }
                }
                files.append(StageFile(pathTemplate: path, templateName: tpl, condition: condition))
            }
        }

        let commands = map["commands"]?.listValue()?.compactMap { $0.scalarValue() } ?? []

        return ScaffoldStage(id: id, nameZh: nameZh, nameEn: nameEn, category: category,
                             descriptionZh: descZh, descriptionEn: descEn,
                             params: params, files: files, commands: commands,
                             directory: dir, isCustom: isCustom)
    }
}

// MARK: - ScaffoldStageOrder（环节排序：用户排序 + 默认排序 + 目录序合并）

enum ScaffoldStageOrder {
    /// 合并规则：saved（仅保留存在于 catalog 的 id，保序）→ defaults（未在 saved 中）→ catalog 剩余（目录序）。
    static func merge(saved: [String]?, defaults: [String], catalogIDs: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        let idSet = Set(catalogIDs)
        for id in (saved ?? []) where idSet.contains(id) && !seen.contains(id) {
            seen.insert(id)
            result.append(id)
        }
        for id in defaults where !seen.contains(id) && idSet.contains(id) {
            seen.insert(id)
            result.append(id)
        }
        for id in catalogIDs where !seen.contains(id) {
            seen.insert(id)
            result.append(id)
        }
        return result
    }
}

enum ScaffoldCatalogError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let m): return m
        }
    }
}

// MARK: - ScaffoldTemplateRenderer（{{var}} / {{#if}} / {{{{ }}}} 转义）

enum ScaffoldRenderError: Error, CustomStringConvertible {
    case malformed(String)
    case missingVariable(String)
    case unclosedIf(String)
    var description: String {
        switch self {
        case .malformed(let m): return "模板语法错误 / template syntax error: \(m)"
        case .missingVariable(let k): return "缺少变量 / missing variable: \(k)"
        case .unclosedIf(let m): return "{{#if}} 未闭合 / unclosed if: \(m)"
        }
    }
}

struct ScaffoldTemplateRenderer {
    /// 真值：非空且非 "false"/"0"（大小写不敏感）。
    static func isTruthy(_ value: String?) -> Bool {
        guard let v = value else { return false }
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if t.lowercased() == "false" || t == "0" { return false }
        return true
    }

    static func render(_ template: String, context: [String: String]) throws -> String {
        var out = ""
        var i = template.startIndex
        while i < template.endIndex {
            if template[i...].hasPrefix("{{{{") {
                out += "{{"
                i = template.index(i, offsetBy: 4)
                continue
            }
            if template[i...].hasPrefix("}}}}") {
                out += "}}"
                i = template.index(i, offsetBy: 4)
                continue
            }
            if template[i...].hasPrefix("{{") {
                let rest = template[i...]
                if rest.hasPrefix("{{#if ") {
                    let openEnd = template.index(i, offsetBy: 6)
                    guard let close = findSubstring("}}", in: template, from: openEnd) else {
                        throw ScaffoldRenderError.malformed("unclosed {{#if")
                    }
                    let key = String(template[openEnd..<close]).trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { throw ScaffoldRenderError.malformed("empty {{#if}} key") }
                    let bodyStart = template.index(close, offsetBy: 2)
                    let (body, after) = try findIfBody(template, bodyStart: bodyStart)
                    if isTruthy(context[key]) {
                        out += try render(String(body), context: context)
                    }
                    i = after
                    continue
                }
                let keyStart = template.index(i, offsetBy: 2)
                guard let close = findSubstring("}}", in: template, from: keyStart) else {
                    throw ScaffoldRenderError.malformed("unclosed {{")
                }
                let key = String(template[keyStart..<close]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { throw ScaffoldRenderError.malformed("empty {{}}") }
                guard let value = context[key] else {
                    throw ScaffoldRenderError.missingVariable(key)
                }
                out += value
                i = template.index(close, offsetBy: 2)
                continue
            }
            out.append(template[i])
            i = template.index(after: i)
        }
        return out
    }

    private static func findSubstring(_ needle: String, in s: String, from start: String.Index) -> String.Index? {
        var pos = start
        while pos < s.endIndex {
            if s[pos...].hasPrefix(needle) { return pos }
            pos = s.index(after: pos)
        }
        return nil
    }

    private static func findIfBody(_ template: String, bodyStart: String.Index) throws -> (Substring, String.Index) {
        var depth = 1
        var pos = bodyStart
        while pos < template.endIndex {
            if template[pos...].hasPrefix("{{#if ") {
                depth += 1
                pos = template.index(pos, offsetBy: 6)
                continue
            }
            if template[pos...].hasPrefix("{{/if}}") {
                depth -= 1
                if depth == 0 {
                    let after = template.index(pos, offsetBy: 7)
                    return (template[bodyStart..<pos], after)
                }
                pos = template.index(pos, offsetBy: 7)
                continue
            }
            pos = template.index(after: pos)
        }
        throw ScaffoldRenderError.unclosedIf("missing {{/if}}")
    }
}

// MARK: - ScaffoldValidators（内置校验器）

enum ScaffoldValidators {
    static let javaReserved: Set<String> = [
        "abstract","assert","boolean","break","byte","case","catch","char","class","const","continue",
        "default","do","double","else","enum","extends","final","finally","float","for","goto","if",
        "implements","import","instanceof","int","interface","long","native","new","package","private",
        "protected","public","return","short","static","strictfp","super","switch","synchronized","this",
        "throw","throws","transient","try","void","volatile","while","var","record","sealed","permits",
        "true","false","null"
    ]

    /// 返回 nil 表示通过，否则返回错误文案（中英）。
    static func validate(_ kind: String, value: String) -> String? {
        // 空值：仅 nonEmpty 校验器视为缺失；slug/safePath/javaPackage 对可选空参数放行
        // （如 deploy.remoteHost 空 = 本机部署）。
        if kind != "nonEmpty", value.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        switch kind {
        case "nonEmpty":
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "不能为空 / must not be empty"
            }
            return nil
        case "slug":
            let t = value.trimmingCharacters(in: .whitespaces)
            if t.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) == nil {
                return "须为 slug（字母/数字开头，仅含字母数字 . _ -）/ must be a slug (alnum start, alnum . _ - only)"
            }
            return nil
        case "safePath":
            if value.contains("..") { return "不允许路径穿越（..）/ path traversal (..) not allowed" }
            if value.hasPrefix("/") { return "不允许绝对路径 / absolute path not allowed" }
            if value.hasPrefix("~") { return "不允许主目录路径（~）/ home path (~) not allowed" }
            if value.contains("\0") { return "包含非法字符 / contains NUL" }
            return nil
        case "javaPackage":
            let t = value.trimmingCharacters(in: .whitespaces)
            let segments = t.split(separator: ".")
            for seg in segments {
                guard let first = seg.first, first.isLetter || first == "_" else {
                    return "包名段「\(seg)」不能以数字开头 / segment must not start with a digit"
                }
                if seg.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) == nil {
                    return "包名段「\(seg)」含非法字符 / invalid characters in segment"
                }
                if javaReserved.contains(String(seg)) {
                    return "包名段「\(seg)」为 Java 保留字 / reserved word"
                }
            }
            return nil
        default:
            return nil
        }
    }
}

// MARK: - ScaffoldPlan（组合规划：文件清单、冲突、参数校验、渲染）

struct ScaffoldPlan {
    struct Entry {
        let stageId: String
        let path: String
        let content: String
    }
    struct Conflict {
        let path: String
        let stageIds: [String]   // 写顺序，最后一个覆盖
    }
    struct Result {
        var projectName = ""
        var projectSlug = ""
        var targetRoot = ""
        var entries: [Entry] = []
        var conflicts: [Conflict] = []
        var validationErrors: [String] = []
        var stageErrors: [String] = []
        var hints: [String] = []
        var context: [String: String] = [:]
        var stageParams: [String: [String: String]] = [:]
        var commandSequence: [String] = []

        /// 可生成条件：无参数错误且无渲染错误。
        var isValid: Bool { validationErrors.isEmpty && stageErrors.isEmpty }
    }

    /// 项目名 → ASCII slug（去重音；非 ASCII 字母/数字一律转 -；保底 project）。
    static func slugify(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US"))
        var out = ""
        var lastWasDash = false
        for scalar in folded.unicodeScalars {
            let ch = Character(scalar)
            if scalar.isASCII, ch.isLetter || ch.isNumber {
                out += String(ch).lowercased()
                lastWasDash = false
            } else {
                if !out.isEmpty, !lastWasDash {
                    out += "-"
                    lastWasDash = true
                }
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "project" : out
    }

    static func build(catalog: [ScaffoldStage], selection: [String], params: [String: [String: String]],
                      projectName: String, parentDir: String, existingTargetRoot: String = "") -> Result {
        var r = Result()
        r.projectName = projectName
        r.projectSlug = slugify(projectName)
        if !existingTargetRoot.isEmpty {
            // 初始化/更新已有目录：直接把目标根指向该目录（不走 parentDir/slug 拼目录）
            r.targetRoot = existingTargetRoot
        } else if !parentDir.isEmpty {
            r.targetRoot = (parentDir as NSString).appendingPathComponent(r.projectSlug)
        }

        // 1. 选中环节（保序、去重）
        var selected: [ScaffoldStage] = []
        var seen = Set<String>()
        for id in selection {
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            if let stage = catalog.first(where: { $0.id == id }) {
                selected.append(stage)
            }
        }

        // 2. 生效参数（默认值 + 用户覆盖）与校验
        var effective: [String: [String: String]] = [:]
        for stage in selected {
            var p: [String: String] = [:]
            for param in stage.params {
                p[param.key] = param.defaultValue
            }
            if let user = params[stage.id] {
                for (k, v) in user { p[k] = v }
            }
            effective[stage.id] = p
            for param in stage.params {
                let value = p[param.key] ?? ""
                if let err = ScaffoldValidators.validate(param.validate, value: value) {
                    r.validationErrors.append("\(stage.id).\(param.key): \(err)")
                }
            }
        }

        // 3. 上下文：内置变量 + 派生标志 + 环节参数
        var context: [String: String] = [
            "projectName": projectName,
            "projectSlug": r.projectSlug,
            "targetPath": r.targetRoot,
            "year": String(Calendar.current.component(.year, from: Date())),
            // 跨环节引用兜底默认值（git-conventions 的 trunk / deploy 的镜像参数 / jenkins agent）
            "trunk": "main",
            "imageRepo": "your-registry",
            "imageTag": "latest",
            "jenkinsAgentLabel": "linux",
            // 项目简介兜底（git-init 的 README 引用；未选 agents-md 时给占位）
            "techSummary": "",
            "techSummaryEmpty": "true",
        ]
        for stage in selected {
            context["has\(capitalize(stage.id))"] = "true"
        }
        for stage in selected {
            let p = effective[stage.id] ?? [:]
            for param in stage.params {
                let value = p[param.key] ?? ""
                context[param.key] = value
                if param.type == "bool" {
                    context[param.key] = value
                } else if param.type == "select" {
                    for opt in param.options {
                        context["\(param.key).\(opt)"] = (opt == value ? "true" : "false")
                    }
                } else if param.type == "multiselect" {
                    let selected = Set(value.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init))
                    context[param.key] = value
                    for opt in param.options {
                        context["\(param.key).\(opt)"] = selected.contains(opt) ? "true" : "false"
                    }
                    context["\(param.key)Empty"] = selected.isEmpty ? "true" : "false"
                    context["\(param.key)Any"] = selected.isEmpty ? "false" : "true"
                } else {
                    context["\(param.key)Empty"] = value.isEmpty ? "true" : "false"
                }
            }
        }

        // 4. CI 派生命令（ci-cd 引用 makefile 参数）
        if seen.contains("ci-cd") {
            let mk = effective["makefile"] ?? [:]
            let testCmd = mk["testCmd"] ?? ""
            let backendTest = mk["backendTest"] ?? ""
            let backendBuild = mk["backendBuild"] ?? ""
            let frontendBuild = mk["frontendBuild"] ?? ""
            let frontendInstall = mk["frontendInstall"] ?? ""
            let lintCmd = mk["lintCmd"] ?? ""
            // makefile 语言预设（lang，可多选）提供的默认命令，镜像 Makefile.tmpl。
            // 多语言时以第一个选中的语言为准（ci 的 build/test/lint 用单一命令）。
            let firstLang = (mk["lang"] ?? "").split(whereSeparator: { $0 == " " || $0 == "," }).first.map(String.init) ?? ""
            func langDefault(_ kind: String) -> String {
                switch firstLang {
                case "java":
                    switch kind {
                    case "build": return "mvn -q package"
                    case "test": return "mvn -q test"
                    case "lint": return "mvn -q spotless:check"
                    default: return ""
                    }
                case "node":
                    switch kind {
                    case "build": return "npm run build"
                    case "test": return "npm test"
                    case "lint": return "npm run lint"
                    default: return ""
                    }
                case "go":
                    switch kind {
                    case "build": return "go build -o bin/app ."
                    case "test": return "go test ./..."
                    case "lint": return "golangci-lint run"
                    default: return ""
                    }
                case "python":
                    switch kind {
                    case "build": return "echo 'no compile step for Python'"
                    case "test": return "pytest"
                    case "lint": return "ruff check ."
                    default: return ""
                    }
                default: return ""
                }
            }
            let lang = mk["lang"] ?? ""
            let buildCmd = mk["buildCmd"] ?? ""
            // 语言预设模式（lang 非空）：以通用 buildCmd/testCmd 或 lang 默认命令为准；
            // 多端模式（lang 未选）才回退到 backend/frontend 命令。
            if lang.trimmingCharacters(in: .whitespaces).isEmpty {
                context["ciLint"] = !lintCmd.isEmpty ? lintCmd : "echo 'no lint command configured'"
                context["ciTest"] = !testCmd.isEmpty ? testCmd : (!backendTest.isEmpty ? backendTest : "echo 'no test command configured'")
                context["ciBuild"] = !backendBuild.isEmpty ? backendBuild : (!frontendBuild.isEmpty ? frontendBuild : "echo 'no build command configured'")
            } else {
                context["ciLint"] = !lintCmd.isEmpty ? lintCmd : langDefault("lint")
                context["ciTest"] = !testCmd.isEmpty ? testCmd : langDefault("test")
                context["ciBuild"] = !buildCmd.isEmpty ? buildCmd : langDefault("build")
            }
            let front = [frontendInstall, frontendBuild].filter { !$0.isEmpty }.joined(separator: "\n")
            context["ciFrontend"] = front.isEmpty ? "echo 'no frontend commands configured'" : front
        }

        r.context = context
        r.stageParams = effective

        // 5. 渲染（按选中顺序；环节渲染失败 → 整环节跳过并报告）
        for stage in selected {
            let p = effective[stage.id] ?? [:]
            do {
                for file in stage.files {
                    guard file.isActive(params: p) else { continue }
                    let renderedPath = try ScaffoldTemplateRenderer.render(file.pathTemplate, context: context)
                    guard !renderedPath.isEmpty else {
                        throw ScaffoldRenderError.malformed("渲染后路径为空 / empty rendered path")
                    }
                    guard !renderedPath.contains(".."), !renderedPath.hasPrefix("/") else {
                        throw ScaffoldRenderError.malformed("路径不安全 / unsafe path: \(renderedPath)")
                    }
                    let templatePath = (stage.directory as NSString).appendingPathComponent(file.templateName)
                    let templateText = try String(contentsOfFile: templatePath, encoding: .utf8)
                    let content = try ScaffoldTemplateRenderer.render(templateText, context: context)
                    r.entries.append(Entry(stageId: stage.id, path: renderedPath, content: content))
                }
                r.commandSequence.append(contentsOf: stage.commands)
            } catch {
                r.stageErrors.append("\(stage.id): 渲染失败：\(error.localizedDescription) / render failed")
            }
        }

        // 6. 同路径冲突（后写覆盖）
        var byPath: [String: [Entry]] = [:]
        for e in r.entries {
            byPath[e.path, default: []].append(e)
        }
        for (path, list) in byPath where list.count > 1 {
            r.conflicts.append(Conflict(path: path, stageIds: list.map { $0.stageId }))
        }

        // 7. 参数自洽性提示（9.7：仅提示不强制）
        if seen.contains("deploy"), !seen.contains("docker") {
            r.hints.append("该组合可能需要 docker 环节（镜像构建），请确认 / this combo may need the docker stage (image build), please confirm")
        }
        if seen.contains("ci-cd") {
            let ci = effective["ci-cd"] ?? [:]
            if ci["hasFrontend"] == "true", !seen.contains("makefile") {
                r.hints.append("选了含前端的 CI，但未选 makefile 环节，命令可能为空 / frontend CI selected without the makefile stage")
            }
        }
        return r
    }

    private static func capitalize(_ s: String) -> String {
        let parts = s.split(separator: "-").map { String($0) }
        let joined = parts.map { p in
            guard let first = p.first else { return p }
            return String(first).uppercased() + p.dropFirst()
        }.joined()
        return joined.isEmpty ? s : joined
    }
}

// MARK: - ScaffoldApplier（落盘 / 备份 / 命令 / state.json）

struct ScaffoldApplier {
    struct Options {
        var backupConflicts = true
    }
    struct CommandResult {
        let command: String
        let exitCode: Int32?
        let error: String?
    }
    struct Result {
        var written: [String] = []
        var backups: [String] = []
        var removed: [String] = []
        var commandResults: [CommandResult] = []
        var statePath = ""
    }

    static func apply(plan: ScaffoldPlan.Result, options: Options) -> Result {
        var r = Result()
        let fm = FileManager.default
        let root = plan.targetRoot
        guard !root.isEmpty else { return r }

        do {
            try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        } catch {
            r.commandResults.append(CommandResult(command: "mkdir", exitCode: 1, error: error.localizedDescription))
            return r
        }

        let backupRoot = (root as NSString).appendingPathComponent(".scaffold-backup")
        for entry in plan.entries {
            let full = (root as NSString).appendingPathComponent(entry.path)
            do {
                let parent = (full as NSString).deletingLastPathComponent
                try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
                if fm.fileExists(atPath: full) {
                    if let existing = try? String(contentsOfFile: full, encoding: .utf8),
                       existing != entry.content, options.backupConflicts {
                        let backupPath = (backupRoot as NSString).appendingPathComponent(entry.path)
                        try fm.createDirectory(atPath: (backupPath as NSString).deletingLastPathComponent,
                                               withIntermediateDirectories: true)
                        if fm.fileExists(atPath: backupPath) {
                            try fm.removeItem(atPath: backupPath)
                        }
                        try fm.copyItem(atPath: full, toPath: backupPath)
                        r.backups.append(entry.path)
                    }
                }
                try entry.content.write(toFile: full, atomically: true, encoding: .utf8)
                r.written.append(entry.path)
            } catch {
                r.commandResults.append(CommandResult(command: "write \(entry.path)", exitCode: 1, error: error.localizedDescription))
            }
        }

        // 环节命令（git init 等）：失败不阻断其余（9.5）
        for cmd in plan.commandSequence {
            let res = runCommand(cmd, in: root)
            r.commandResults.append(res)
        }

        // 清理孤儿文件：上一次生成由脚手架管理的、本次不再生成的（如 license 从 MIT 改 none 后移除 LICENSE）
        do {
            let statePath = (root as NSString).appendingPathComponent(".scaffold/state.json")
            let newPaths = Set(plan.entries.map { $0.path })
            if let oldData = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
               let oldJSON = try? JSONSerialization.jsonObject(with: oldData) as? [String: Any],
               let oldFiles = oldJSON["files"] as? [String] {
                for path in oldFiles where !newPaths.contains(path) {
                    guard !path.contains(".."), !path.hasPrefix("/"), !path.hasPrefix("~") else { continue }
                    let full = (root as NSString).appendingPathComponent(path)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
                    if (try? fm.removeItem(atPath: full)) != nil {
                        r.removed.append(path)
                    }
                }
            }
        }

        // state.json
        do {
            let statePath = (root as NSString).appendingPathComponent(".scaffold/state.json")
            try fm.createDirectory(atPath: (statePath as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            let iso = ISO8601DateFormatter()
            var stagesJSON: [[String: Any]] = []
            for (sid, sp) in plan.stageParams {
                var p: [String: Any] = [:]
                for (k, v) in sp { p[k] = v }
                stagesJSON.append(["id": sid, "params": p])
            }
            let dict: [String: Any] = [
                "version": "1",
                "createdAt": iso.string(from: Date()),
                "projectName": plan.projectName,
                "projectSlug": plan.projectSlug,
                "targetRoot": root,
                "stages": stagesJSON,
                "files": plan.entries.map { $0.path }.sorted(),
            ]
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: statePath))
            r.statePath = statePath
        } catch {
            r.commandResults.append(CommandResult(command: "state.json", exitCode: 1, error: error.localizedDescription))
        }
        return r
    }

    private static func runCommand(_ command: String, in dir: String) -> CommandResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", command]
        proc.currentDirectoryURL = URL(fileURLWithPath: dir)
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return CommandResult(command: command, exitCode: proc.terminationStatus, error: nil)
        } catch {
            return CommandResult(command: command, exitCode: nil, error: error.localizedDescription)
        }
    }
}

// MARK: - ScaffoldPreset（预设组合：快捷勾选，不限制自由组合）

struct ScaffoldPreset {
    let id: String
    let stageIds: [String]
    let paramDefaults: [String: [String: String]]

    static let backend = ScaffoldPreset(
        id: "backend",
        stageIds: ["git-init", "git-conventions", "agents-md", "conventions", "docs-standards",
                   "makefile", "ci-cd", "docker", "deploy", "repo-knowledge"],
        paramDefaults: [
            "ci-cd": ["hasBackend": "true", "hasFrontend": "false"],
            "docker": ["runtime": "java"],
        ]
    )
    static let fullstack = ScaffoldPreset(
        id: "fullstack",
        stageIds: ["git-init", "git-conventions", "agents-md", "conventions", "docs-standards",
                   "makefile", "ci-cd", "docker", "deploy", "repo-knowledge"],
        paramDefaults: [
            "ci-cd": ["hasBackend": "true", "hasFrontend": "true"],
            "makefile": ["frontendInstall": "npm ci", "frontendBuild": "npm run build"],
        ]
    )
    static let foundation = ScaffoldPreset(
        id: "foundation",
        stageIds: ["git-init", "git-conventions", "agents-md", "docs-standards", "conventions", "repo-knowledge"],
        paramDefaults: [:]
    )
    static let all: [ScaffoldPreset] = [backend, fullstack, foundation]
}

/// 设置列表行内的小按钮（闭包回调，避免 @objc selector 爆破）。
private final class ActionButton: NSButton {
    var onAction: (() -> Void)?
    /// 工厂：AppKit 中编程创建的 NSButton 默认 translatesAutoresizingMaskIntoConstraints=true，
    /// 必须显式关闭，否则显式约束与 autoresizing 掩码约束冲突（按钮帧错位/重叠）。
    static func make(title: String) -> ActionButton {
        let b = ActionButton(title: title, target: nil, action: nil)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }
    override func mouseDown(with event: NSEvent) {
        if isEnabled { onAction?() }
    }
}

/// 环节类型徽标（内置 / 自定义·已修改 / 自定义·新建）：圆角色块 + 文字。
private final class StageTypeBadge: NSView {
    enum Kind {
        case builtin        // 内置
        case modified       // 自定义 · 已修改内置
        case custom         // 自定义 · 新建
    }
    var kind: Kind = .builtin { didSet { needsDisplay = true } }

    override var isOpaque: Bool { false }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    private var text: String {
        switch kind {
        case .builtin: return L10n.tr("scaffold.stageBuiltin")
        case .modified: return L10n.tr("scaffold.stageModified")
        case .custom: return L10n.tr("scaffold.stageNew")
        }
    }
    func textWidth() -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]
        return (text as NSString).size(withAttributes: attrs).width + 14
    }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color: NSColor
        switch kind {
        case .builtin: color = dark ? NSColor(white: 0.6, alpha: 1) : NSColor(white: 0.5, alpha: 1)
        case .modified: color = .systemOrange
        case .custom: color = .systemBlue
        }
        color.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                                withAttributes: attrs)
    }
}

/// 环节管理设置列表行：名称 + 类型徽标 + 分类，右侧 上移/下移/编辑/恢复或删除。
private final class StageSettingsRow: NSView {
    let stage: ScaffoldStage
    var onEdit: (() -> Void)?
    var onRestore: (() -> Void)?   // 已修改内置 → 恢复
    var onDelete: (() -> Void)?    // 新建自定义 → 删除
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    private let badge = StageTypeBadge()
    private let nameLabel: NSTextField
    private let detailLabel: NSTextField

    init(stage: ScaffoldStage, isModifiedBuiltin: Bool, isFirst: Bool, isLast: Bool) {
        self.stage = stage
        nameLabel = NSTextField(labelWithString: stage.name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel = NSTextField(labelWithString: stage.category)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        badge.kind = stage.isCustom ? (isModifiedBuiltin ? .modified : .custom) : .builtin
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        addSubview(nameLabel)
        addSubview(detailLabel)

        let up = ActionButton.make(title: "↑")
        up.controlSize = .small
        up.bezelStyle = .rounded
        up.toolTip = L10n.tr("scaffold.moveUp")
        up.isEnabled = !isFirst
        up.onAction = { [weak self] in self?.onMoveUp?() }

        let down = ActionButton.make(title: "↓")
        down.controlSize = .small
        down.bezelStyle = .rounded
        down.toolTip = L10n.tr("scaffold.moveDown")
        down.isEnabled = !isLast
        down.onAction = { [weak self] in self?.onMoveDown?() }

        let restoreBtn = ActionButton.make(title: L10n.tr("scaffold.restoreStage"))
        restoreBtn.controlSize = .small
        restoreBtn.bezelStyle = .rounded
        restoreBtn.isHidden = !(stage.isCustom && isModifiedBuiltin)
        restoreBtn.onAction = { [weak self] in self?.onRestore?() }

        let deleteBtn = ActionButton.make(title: L10n.tr("scaffold.deleteStage"))
        deleteBtn.controlSize = .small
        deleteBtn.bezelStyle = .rounded
        deleteBtn.isHidden = !(stage.isCustom && !isModifiedBuiltin)
        deleteBtn.onAction = { [weak self] in self?.onDelete?() }

        let editBtn = ActionButton.make(title: L10n.tr("scaffold.editStage"))
        editBtn.controlSize = .small
        editBtn.bezelStyle = .rounded
        editBtn.onAction = { [weak self] in self?.onEdit?() }

        let btnRow = NSStackView(views: [up, down, editBtn, restoreBtn, deleteBtn])
        btnRow.orientation = .horizontal
        btnRow.spacing = 4
        btnRow.translatesAutoresizingMaskIntoConstraints = false

        addSubview(btnRow)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            badge.widthAnchor.constraint(equalToConstant: badge.textWidth()),
            badge.heightAnchor.constraint(equalToConstant: 18),
            nameLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: btnRow.leadingAnchor, constant: -8),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: btnRow.leadingAnchor, constant: -8),
            btnRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            btnRow.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 52),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// 环节编辑器中的单个文件（stage.yaml 或 templates/ 下某模板）。
/// 对齐 Files 面板的编辑模式：每个文件一个标签页 + CodeEditorView 实例，
/// 切换标签时复用 live editor（内存未保存编辑不丢失）。
private final class StageEditorFile {
    /// 相对环节目录的路径："stage.yaml" / "templates/xxx.tmpl"。
    let relativePath: String
    /// 标签标题（文件名）。
    let displayName: String
    /// 读取来源（内置目录或用户库）；"" = 新建（内存缓冲）。
    var loadPath: String
    /// 写入目标（用户库路径）。
    var savePath: String
    /// live editor（切换标签时保留）。
    var editor: CodeEditorView?
    var isDirty = false
    /// 尚未落盘的新文件（新建环节骨架 / 新建模板）。
    var isNewFile = false
    /// 新文件的初始内容（骨架 YAML 等；loadPath 为空时编辑器以此为种子）。
    var initialText = ""
    let tabButton: ActionButton

    init(relativePath: String, displayName: String, loadPath: String, savePath: String) {
        self.relativePath = relativePath
        self.displayName = displayName
        self.loadPath = loadPath
        self.savePath = savePath
        tabButton = ActionButton.make(title: displayName)
        tabButton.bezelStyle = .texturedRounded
        tabButton.setButtonType(.pushOnPushOff)
        tabButton.state = .off
        tabButton.cell?.lineBreakMode = .byTruncatingTail
        tabButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tabButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabButton.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
    }
}

// MARK: - Scaffold 面板（M1.1 UI 优化：向导式时间线 + 卡片环节 + tree 预览）

/// 面板根视图。镜像 WikiRootView/TerminalRootView 的 layer 合成规避约定
/// （docs/terminal-header-fix.md）：isOpaque=false 强制每个子视图独立合成。
final class ScaffoldRootView: NSView {
    /// 每次 layout 后回调（用于在布局落定后修正滚动位置）。
    var onLayout: (() -> Void)?
    override var isOpaque: Bool { false }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        onLayout?()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color: NSColor = dark ? NSColor(calibratedWhite: 0.28, alpha: 1) : NSColor(calibratedWhite: 0.94, alpha: 1)
        color.setFill()
        dirtyRect.fill()
    }
}

/// 步骤时间线条目（数字徽标 + 标题，可点击）。
/// 翻转容器：作为滚动 documentView，内容比视口短时贴顶显示（避免贴底）。
private final class FlippedWorkspaceView: NSView {
    override var isFlipped: Bool { true }
}

private final class ScaffoldStepItem: NSView {
    enum State { case idle, current, done, error }
    var state: State = .idle { didSet { needsDisplay = true } }
    let number: Int
    let title: String
    var onAction: (() -> Void)?

    init(number: Int, title: String) {
        self.number = number
        self.title = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 40).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onAction?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // 当前步骤高亮胶囊背景
        if state == .current {
            let bg = dark ? NSColor.controlAccentColor.withAlphaComponent(0.30)
                          : NSColor.controlAccentColor.withAlphaComponent(0.15)
            bg.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8).fill()
        }
        // 徽标：数字 / ✓ / ⚠
        let badgeRect = NSRect(x: 12, y: (bounds.height - 22) / 2, width: 22, height: 22)
        let badgeColor: NSColor
        switch state {
        case .idle: badgeColor = dark ? NSColor(white: 0.42, alpha: 1) : NSColor(white: 0.62, alpha: 1)
        case .current: badgeColor = NSColor.controlAccentColor
        case .done: badgeColor = NSColor.systemGreen
        case .error: badgeColor = NSColor.systemRed
        }
        badgeColor.setFill()
        NSBezierPath(ovalIn: badgeRect).fill()
        let textColor = NSColor.white
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: textColor]
        var glyph: NSString
        switch state {
        case .done: glyph = "✓"
        case .error: glyph = "!"
        default: glyph = "\(number)" as NSString
        }
        let size = glyph.size(withAttributes: attrs)
        glyph.draw(at: NSPoint(x: badgeRect.midX - size.width / 2, y: badgeRect.midY - size.height / 2), withAttributes: attrs)

        // 标题
        let titleColor: NSColor
        switch state {
        case .idle: titleColor = dark ? NSColor(white: 0.72, alpha: 1) : NSColor(white: 0.45, alpha: 1)
        case .current: titleColor = dark ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.12, alpha: 1)
        case .done: titleColor = dark ? NSColor(white: 0.8, alpha: 1) : NSColor(white: 0.3, alpha: 1)
        case .error: titleColor = NSColor.systemRed
        }
        let tAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: titleColor]
        let tSize = (title as NSString).size(withAttributes: tAttrs)
        (title as NSString).draw(at: NSPoint(x: 46, y: (bounds.height - tSize.height) / 2), withAttributes: tAttrs)
    }
}

/// 卡片勾选徽标（○ / ✓）。
private final class ScaffoldBadge: NSView {
    var isChecked = false { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let color: NSColor = isChecked ? NSColor.controlAccentColor
                                       : (dark ? NSColor(white: 0.55, alpha: 1) : NSColor(white: 0.65, alpha: 1))
        color.setStroke()
        let circle = NSBezierPath(ovalIn: rect)
        circle.lineWidth = 1.5
        circle.stroke()
        if isChecked {
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: rect.minX + 4.5, y: rect.midY))
            check.line(to: NSPoint(x: rect.midX - 1, y: rect.maxY - 4))
            check.line(to: NSPoint(x: rect.maxX - 3, y: rect.minY + 4))
            check.lineWidth = 2
            NSColor.white.setStroke()
            check.stroke()
        }
    }
}

/// 环节卡片：点击整卡切换选中，右侧勾选徽标 + 名称 + 描述。
private final class ScaffoldStageCard: NSView {
    let stage: ScaffoldStage
    var onToggle: (() -> Void)?
    var isSelected = false {
        didSet {
            needsDisplay = true
            badge.isChecked = isSelected
        }
    }
    private let badge = ScaffoldBadge()
    private let nameLabel: NSTextField
    private let descLabel: NSTextField

    init(stage: ScaffoldStage) {
        self.stage = stage
        nameLabel = NSTextField(labelWithString: stage.name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        descLabel = NSTextField(labelWithString: stage.desc)
        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = .secondaryLabelColor
        descLabel.lineBreakMode = .byTruncatingTail
        descLabel.maximumNumberOfLines = 2
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        addSubview(nameLabel)
        addSubview(descLabel)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 22),
            badge.heightAnchor.constraint(equalToConstant: 22),
            nameLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            descLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            descLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            descLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            descLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
        ])
        heightAnchor.constraint(greaterThanOrEqualToConstant: 62).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { false }
    override func mouseDown(with event: NSEvent) { onToggle?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bg: NSColor = isSelected
            ? (dark ? NSColor.controlAccentColor.withAlphaComponent(0.30) : NSColor.controlAccentColor.withAlphaComponent(0.14))
            : (dark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.97, alpha: 1))
        bg.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        let border: NSColor = isSelected ? NSColor.controlAccentColor : NSColor.separatorColor
        border.setStroke()
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        p.lineWidth = isSelected ? 1.5 : 1
        p.stroke()
    }
}

/// 当前项目首页里展示环节/参数的配置卡片：背景与描边在 draw() 里按 effectiveAppearance
/// 显式取色，并覆写 viewDidChangeEffectiveAppearance，跟随系统深浅色切换。
/// （layer 上烘焙的 CGColor 是创建时的快照，不会随外观变化重取。）
private final class WorkspaceStageCardView: NSView {
    override var isOpaque: Bool { false }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bg: NSColor = dark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.97, alpha: 1)
        bg.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let border: NSColor = dark ? NSColor(white: 0.35, alpha: 1) : NSColor(white: 0.7, alpha: 1)
        border.setStroke()
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        p.lineWidth = 1
        p.stroke()
    }
}

/// 环节编辑单元：卡片（步骤 2）+ 参数控件栈（步骤 3）。
private final class StageEditor {
    let stage: ScaffoldStage
    let card: ScaffoldStageCard
    /// 参数控件行（扁平，直接挂到参数步骤的文档 stack，避免嵌套 stack 塌陷）。
    var paramRows: [NSView] = []
    var stringControls: [String: NSTextField] = [:]
    var selectControls: [String: NSPopUpButton] = [:]
    var boolControls: [String: NSButton] = [:]
    var radioGroups: [String: [NSButton]] = [:]
    var multiControls: [String: [NSButton]] = [:]
    /// 必填参数（带校验器）的标签引用：值为空时红色，有值恢复次级色。
    var requiredLabels: [String: NSTextField] = [:]

    init(stage: ScaffoldStage, onToggle: @escaping () -> Void) {
        self.stage = stage
        card = ScaffoldStageCard(stage: stage)
        card.onToggle = onToggle

        for param in stage.params {
            let isRequired = !param.validate.isEmpty
            let label = NSTextField(labelWithString: isRequired ? param.label + " *" : param.label)
            label.font = .systemFont(ofSize: 12)
            label.textColor = isRequired ? .systemRed : .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            if isRequired { requiredLabels[param.key] = label }
            let controlRow = NSStackView(views: [label])
            controlRow.orientation = .horizontal
            controlRow.spacing = 10
            controlRow.alignment = .centerY
            controlRow.translatesAutoresizingMaskIntoConstraints = false
            // 整行贴合内容宽度：文档 stack 的拉伸在此让位，参数控件靠左簇拥
            controlRow.setContentHuggingPriority(.required, for: .horizontal)

            let currentValue = param.defaultValue
            if param.type == "bool" {
                let cb = NSButton(checkboxWithTitle: "", target: nil, action: nil)
                cb.identifier = NSUserInterfaceItemIdentifier("\(stage.id).\(param.key)")
                cb.state = ScaffoldTemplateRenderer.isTruthy(currentValue) ? .on : .off
                boolControls[param.key] = cb
                controlRow.addArrangedSubview(cb)
            } else if param.type == "select" {
                if param.options.count < 5 {
                    // 选项少于 5 个 → radio 组（比下拉更直观；显示本地化标签，值按索引取原始）
                    let radios = param.options.enumerated().map { idx, opt -> NSButton in
                        let b = NSButton(radioButtonWithTitle: ScaffoldPanelController.optionLabel(opt), target: nil, action: nil)
                        b.identifier = NSUserInterfaceItemIdentifier("\(stage.id).\(param.key)")
                        b.tag = idx
                        b.font = .systemFont(ofSize: 12)
                        return b
                    }
                    if let idx = param.options.firstIndex(of: currentValue) {
                        radios[idx].state = .on
                    } else if let first = radios.first {
                        first.state = .on   // 兜底：默认值不在选项中时选中第一个
                    }
                    radioGroups["\(stage.id).\(param.key)"] = radios
                    let row = NSStackView(views: radios)
                    row.orientation = .horizontal
                    row.spacing = 12
                    row.translatesAutoresizingMaskIntoConstraints = false
                    row.setContentHuggingPriority(.required, for: .horizontal)
                    row.setContentCompressionResistancePriority(.required, for: .horizontal)
                    // 钉死 radio 组宽度 = fitting 尺寸，打破「行宽依赖组宽、组宽又被撑满」的循环
                    let fitW = row.fittingSize.width
                    if fitW > 0 {
                        row.widthAnchor.constraint(equalToConstant: fitW).isActive = true
                    }
                    controlRow.addArrangedSubview(row)
                } else {
                    let pop = NSPopUpButton(frame: .zero, pullsDown: false)
                    pop.addItems(withTitles: param.options.map { ScaffoldPanelController.optionLabel($0) })
                    if let idx = param.options.firstIndex(of: currentValue) {
                        pop.selectItem(at: idx)
                    }
                    pop.controlSize = .regular
                    pop.font = .systemFont(ofSize: 12)
                    pop.identifier = NSUserInterfaceItemIdentifier("\(stage.id).\(param.key)")
                    selectControls[param.key] = pop
                    controlRow.addArrangedSubview(pop)
                }
            } else if param.type == "multiselect" {
                // 多选（如 AGENTS.md 主语言）：每个选项一个 checkbox，纵向堆叠。
                let boxes = param.options.enumerated().map { idx, opt -> NSButton in
                    let b = NSButton(checkboxWithTitle: ScaffoldPanelController.optionLabel(opt), target: nil, action: nil)
                    b.identifier = NSUserInterfaceItemIdentifier("\(stage.id).\(param.key)")
                    b.tag = idx
                    b.font = .systemFont(ofSize: 12)
                    return b
                }
                let selected = currentValue.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
                for (i, opt) in param.options.enumerated() where selected.contains(opt) {
                    boxes[i].state = .on
                }
                multiControls["\(stage.id).\(param.key)"] = boxes
                let col = NSStackView(views: boxes)
                col.orientation = .vertical
                col.alignment = .leading
                col.spacing = 4
                col.translatesAutoresizingMaskIntoConstraints = false
                col.setContentHuggingPriority(.required, for: .horizontal)
                col.setContentCompressionResistancePriority(.required, for: .horizontal)
                controlRow.addArrangedSubview(col)
            } else {
                let field = NSTextField(string: currentValue)
                field.font = .systemFont(ofSize: 13)
                field.controlSize = .regular
                field.identifier = NSUserInterfaceItemIdentifier("\(stage.id).\(param.key)")
                field.translatesAutoresizingMaskIntoConstraints = false
                field.widthAnchor.constraint(equalToConstant: 220).isActive = true
                stringControls[param.key] = field
                // 必填：空值时红框高亮（由 updateRequiredHighlights 维护）
                if isRequired {
                    field.wantsLayer = true
                    field.layer?.cornerRadius = 4
                    field.layer?.borderWidth = 1
                }
                controlRow.addArrangedSubview(field)
            }
            // 钉死行宽 = 内容 fitting 宽度（行内有 field/radio 时避免被文档拉伸）
            let rowFit = controlRow.fittingSize.width
            if rowFit > 0 {
                controlRow.widthAnchor.constraint(equalToConstant: rowFit).isActive = true
            }
            paramRows.append(controlRow)
        }
    }

    /// 必填参数高亮：以输入框当前值为准——值为空 → 标签红 + 红框；有值 → 恢复正常色。
    /// 注意不能读 params 字典（只含用户改过的项），否则非空默认值会被误判为空。
    func updateRequiredHighlights() {
        for param in stage.params where !param.validate.isEmpty {
            let value = stringControls[param.key]?.stringValue ?? ""
            let empty = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if let field = stringControls[param.key] {
                field.layer?.borderColor = empty ? NSColor.systemRed.cgColor : NSColor.clear.cgColor
            }
            if let label = requiredLabels[param.key] {
                label.textColor = empty ? .systemRed : .secondaryLabelColor
            }
        }
    }

    /// 用给定值同步控件显示（预设 / 重置时）。
    func syncControls(values: [String: String]) {
        for (key, field) in stringControls {
            field.stringValue = values[key] ?? stage.params.first(where: { $0.key == key })?.defaultValue ?? ""
        }
        for (key, pop) in selectControls {
            let val = values[key] ?? stage.params.first(where: { $0.key == key })?.defaultValue ?? ""
            if let idx = stage.params.first(where: { $0.key == key })?.options.firstIndex(of: val) {
                pop.selectItem(at: idx)
            }
        }
        for (key, cb) in boolControls {
            let val = values[key] ?? stage.params.first(where: { $0.key == key })?.defaultValue ?? ""
            cb.state = ScaffoldTemplateRenderer.isTruthy(val) ? .on : .off
        }
        for (key, radios) in radioGroups {
            let param = stage.params.first(where: { $0.key == key })
            let val = values[key] ?? param?.defaultValue ?? ""
            if let idx = param?.options.firstIndex(of: val), idx >= 0, idx < radios.count {
                for (i, b) in radios.enumerated() { b.state = (i == idx) ? .on : .off }
            } else {
                radios.first?.state = .on
            }
        }
        for (key, boxes) in multiControls {
            let param = stage.params.first(where: { $0.key == key })
            let val = values[key] ?? param?.defaultValue ?? ""
            let selected = Set(val.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init))
            for (i, opt) in (param?.options ?? []).enumerated() where i < boxes.count {
                boxes[i].state = selected.contains(opt) ? .on : .off
            }
        }
        // 同步字段值（预设/重置时）后再刷新必填高亮
        updateRequiredHighlights()
    }

    /// 从控件读出当前值（供 params 字典）。
    func collectValues() -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in stringControls { out[k] = v.stringValue }
        for (k, v) in selectControls { out[k] = v.selectedItem?.title ?? "" }
        for (k, v) in boolControls { out[k] = (v.state == .on) ? "true" : "false" }
        for (key, boxes) in multiControls {
            let param = stage.params.first(where: { $0.key == key })
            let opts = param?.options ?? []
            let chosen = boxes.enumerated().compactMap { idx, b -> String? in
                (b.state == .on && idx < opts.count) ? opts[idx] : nil
            }
            out[key] = chosen.joined(separator: " ")
        }
        return out
    }
}

/// 文件清单树节点。
private final class FileTreeNode {
    let name: String
    let fullPath: String
    var isDirectory: Bool
    var children: [FileTreeNode] = []
    var conflictStages: [String] = []
    init(name: String, fullPath: String, isDirectory: Bool) {
        self.name = name
        self.fullPath = fullPath
        self.isDirectory = isDirectory
    }
}

final class ScaffoldPanelController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// 根视图，由 setRightPanel 直接挂载为右侧面板。
    let view = ScaffoldRootView()
    var onRequestHide: (() -> Void)?
    /// 提供 dsh web 端口（M3 深化门控预留）。
    var serverPortProvider: (() -> Int)?
    static let minWidth: CGFloat = 400

    // MARK: 步骤

    /// select 选项的展示文案（值保持原始，仅展示层本地化，避免 bilingual 等看不懂）。
    static func optionLabel(_ value: String) -> String {
        switch value {
        case "zh": return L10n.isZh ? "中文" : "Chinese"
        case "en": return L10n.isZh ? "英文" : "English"
        case "bilingual": return L10n.isZh ? "中英双语" : "Bilingual"
        case "github": return "GitHub"
        case "gitlab": return "GitLab"
        case "github-actions": return "GitHub Actions"
        case "gitlab-ci": return "GitLab CI"
        case "jenkins": return "Jenkins"
        case "java": return "Java"
        case "node": return "Node.js"
        case "static": return L10n.isZh ? "静态站点" : "Static site"
        case "typescript": return "TypeScript"
        case "javascript": return "JavaScript"
        case "python": return "Python"
        case "go": return "Go"
        case "rust": return "Rust"
        case "csharp": return "C#"
        case "swift": return "Swift"
        case "kotlin": return "Kotlin"
        case "php": return "PHP"
        case "ruby": return "Ruby"
        case "shell": return L10n.isZh ? "Shell 脚本" : "Shell"
        case "other": return L10n.isZh ? "其他" : "Other"
        case "generic": return L10n.isZh ? "通用" : "Generic"
        default: return value
        }
    }

    /// 环节在工程中的默认先后顺序（展示与参数步骤共用；未列出的按目录序排后）。
    /// 用户可在「环节管理」设置中调整排序，持久化到 scaffoldStageOrder（UserDefaults）。
    static let defaultStageOrder: [String] = [
        "git-init", "repo-knowledge", "agents-md", "git-conventions", "docs-standards",
        "conventions", "docker", "makefile", "ci-cd", "deploy",
    ]
    static let stageOrderKey = "scaffoldStageOrder"

    /// 有效顺序：用户排序（仅保留 catalog 存在者）→ 默认排序 → catalog 剩余（目录序）。
    private func effectiveStageOrder() -> [String] {
        let saved = UserDefaults.standard.stringArray(forKey: Self.stageOrderKey)
        return ScaffoldStageOrder.merge(saved: saved, defaults: Self.defaultStageOrder,
                                        catalogIDs: catalog.map { $0.id })
    }
    private func stageIndex(_ id: String) -> Int {
        effectiveStageOrder().firstIndex(of: id) ?? Int.max
    }

    private enum Step: Int, CaseIterable {
        case workspace = 1, target = 2, stages = 3, params = 4, preview = 5
        var titleKey: String {
            switch self {
            case .workspace: return "scaffold.step.workspace"
            case .target: return "scaffold.step.target"
            case .stages: return "scaffold.step.stages"
            case .params: return "scaffold.step.params"
            case .preview: return "scaffold.step.preview"
            }
        }
    }
    private var currentStep: Step = .target
    /// 是否进入过向导（新建/初始化/更新配置）且未取消。Back 返回「当前项目」首页
    /// 视为取消（hasEnteredWizard 复位），时间线折叠回仅显示 workspace 一项。
    private var hasEnteredWizard = false

    // MARK: 子视图

    private let headerTitle = NSTextField(labelWithString: "")
    private var openButton: CustomIconButton!
    private var finderButton: CustomIconButton!
    private var newProjectButton: NSButton!
    private var initProjectButton: NSButton!
    private var updateConfigButton: NSButton!
    private var hideButton: CustomIconButton!

    private let railStack = NSStackView()
    private var stepItems: [ScaffoldStepItem] = []
    /// 工具栏行 / 步骤栏容器（设置视图激活时隐藏）。
    private var toolbarView: NSView?
    private var railView: NSView?
    private var toolbarUnderlineView: NSView?
    /// 设置视图激活时的 contentContainer 布局（顶/左切到全宽全高）。
    private var contentTopSettings: NSLayoutConstraint?
    private var contentTopNormal: NSLayoutConstraint?
    private var contentLeadingSettings: NSLayoutConstraint?
    private var contentLeadingNormal: NSLayoutConstraint?

    private let contentContainer = NSView()
    private var workspaceStepView: NSView!
    private var targetStepView: NSView!
    private var stagesStepView: NSView!
    private var paramsStepView: NSView!
    private var previewStepView: NSView!

    // 步骤 1：目标与位置
    private let projectNameField = NSTextField()
    private let projectSummaryField = NSTextField()
    private var projectSummaryLabel: NSTextField!
    private let dirButton = NSButton()
    private let targetRootLabel = NSTextField(labelWithString: "")
    // 步骤 1 静态标签（语言切换时重建文案）
    private let targetTitleLabel = NSTextField(labelWithString: "")
    private let targetSubtitleLabel = NSTextField(labelWithString: "")
    private let parentDirLabel = NSTextField(labelWithString: "")
    private let projectNameLabel = NSTextField(labelWithString: "")
    // 步骤 2「按目的预设」标题（语言切换时重建）
    private let presetTitleLabel = NSTextField(labelWithString: "")
    private var presetButtons: [NSButton] = []

    // 步骤 2：选择环节（卡片）
    private let stagesHeader = NSTextField(labelWithString: "")
    private let stageScroll = NSScrollView()
    private let stageStack = NSStackView()

    // 步骤 3：参数配置
    private let paramsHeader = NSTextField(labelWithString: "")
    private let paramsScroll = NSScrollView()
    private let paramsStack = NSStackView()

    // 步骤 4：预览与生成（tree）
    private let previewHeaderLabel = NSTextField(labelWithString: "")
    private let messageScroll = NSScrollView()
    private let messageStack = NSStackView()
    private let fileScroll = NSScrollView()
    private let fileOutline = NSOutlineView()
    private var fileTree: FileTreeNode?

    // 底部导航（位于头部）
    private let prevButton = NSButton()
    private let nextButton = NSButton()

    // 状态条
    private let statusBar = DynamicFillView()
    private let statusLabel = HeaderLabel()
    private let statusSpinner = NSProgressIndicator()

    // MARK: 环节管理设置（右上角 ⚙）

    private var settingsButton: CustomIconButton!
    /// 设置视图是否激活（激活时隐藏步骤栏/工具栏/向导视图，显示环节管理列表）。
    private var settingsActive = false
    /// 编辑器是否处于「新建」模式（isNew=true 时允许且必须改 id）。
    private var editorStageID = ""
    private var editorIsNew = false
    /// 一行的编辑目标：内置环节的来源目录（修改内置后 templates 复制跟随）；nil = 新建。
    private var editorTemplatesFrom: String?
    /// 内置环节库 id（用于「已修改内置」判定与恢复可用性）。
    private var builtinIDs: Set<String> = []
    private var settingsView: NSView!
    private let settingsHeader = DynamicFillView()
    private let settingsTitleLabel = NSTextField(labelWithString: "")
    private let settingsScroll = NSScrollView()
    private let settingsStack = NSStackView()
    /// 设置列表滚动 doc（重建列表后用 fittingSize 驱动文档高度，否则内容溢出区不可点击）。
    private var settingsDoc: FlippedWorkspaceView!
    private let settingsFooterLabel = NSTextField(labelWithString: "")
    // 编辑器（Files 风格：文件标签页 + CodeEditorView）
    private let editorView = NSView()
    private let editorTitleLabel = NSTextField(labelWithString: "")
    private let editorErrorLabel = NSTextField(labelWithString: "")
    private let editorHintLabel = NSTextField(labelWithString: "")
    /// 文件标签页模型（stage.yaml + templates/ 下每个文件一个）。
    private var editorFiles: [StageEditorFile] = []
    private var editorSelectedTab = 0
    private let editorFileBar = NSScrollView()
    private let editorFileStack = NSStackView()
    private let editorContent = NSView()
    private var editorSaveBtn: ActionButton!

    // MARK: 状态

    private var catalog: [ScaffoldStage] = []
    private var catalogErrors: [String] = []
    private var editors: [String: StageEditor] = [:]
    private var radioGroups: [String: [NSButton]] = [:]
    private var selection: [String] = []
    private var params: [String: [String: String]] = [:]
    private var projectName = ""
    private var parentDir = ""
    private var plan: ScaffoldPlan.Result?
    private var lastApply: ScaffoldApplier.Result?
    private var serverReadyPort: Int?
    private var isGenerating = false
    /// 当前工作区（项目目录）：由壳层注入，跟随用户查看的会话。
    var workspacePath: (() -> String?)?
    /// 非空表示向导目标是已存在的目录（初始化此目录 / 更新配置），而非新建子目录。
    private var initTarget: String?
    /// 步骤 3 中 AGENTS.md 的 techSummary 是否被用户独立改过（改过后不再被步骤 1 覆盖）。
    private var techSummaryLocked = false
    /// 当前工作区目录（workspace 步骤检测到的项目目录）。
    private var currentWorkspaceDir: String?
    private let workspaceScroll = NSScrollView()
    private let workspaceDoc = FlippedWorkspaceView()
    private let workspaceStack = NSStackView()

    /// 解析出的项目脚手架配置（来自 .scaffold/state.json）。
    private struct WorkspaceConfig {
        var projectName = ""
        var targetRoot = ""
        var stages: [String] = []
        var params: [String: [String: String]] = [:]
        var files: [String] = []
    }
    /// 进入滚动步骤后的置顶时间窗：窗口内每次布局都强制滚回顶部，
    /// 避免 NSScrollView 在布局时把文档重置到错误位置（内容贴底）。
    private var scrollTopDeadline: Date = .distantPast

    /// agents-md 的项目简介参数键（步骤 1 填写后带入）。
    static let techSummaryKey = "techSummary"

    /// 设置键（壳层 UserDefaults，默认值见文档 7.3）。
    static let enabledKey = "scaffoldEnabled"
    static let lastDirKey = "scaffoldLastDir"
    static let backupConflictsKey = "scaffoldBackupConflicts"

    static func scaffoldEnabledDefault() -> Bool {
        (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true
    }
    static func backupConflicts() -> Bool {
        (UserDefaults.standard.object(forKey: backupConflictsKey) as? Bool) ?? true
    }

    override init() {
        super.init()
        view.onLayout = { [weak self] in self?.handleRootLayout() }
        buildUI()
        loadCatalog()
        if let dir = ProcessInfo.processInfo.environment["DSH_SCAFFOLD_TEST_DIR"], !dir.isEmpty {
            setParentDir(dir)
            hasEnteredWizard = true
            setStep(.target)   // QA 钩子：直达新建向导（跳过 workspace 首页）
        }
        refreshPlan()
        updateStatus("")
    }

    // MARK: 公共 API（AppDelegate 调用）

    /// 面板显示时：加载环节库（幂等）并刷新预览。
    func ensureLoaded() {
        if catalog.isEmpty { loadCatalog() }
        refreshPlan()
        updateToolbarState()
        if currentStep == .workspace { rebuildWorkspaceStep() }
    }

    /// 当前工作区（项目目录）变化时：真正切换了工作区则回到「当前项目」首页并隐藏向导步骤；
    /// 仅会话变化（同目录）时只刷新工具栏态。
    func workspaceChanged() {
        let newDir = resolveCurrentWorkspace()
        if newDir != currentWorkspaceDir {
            hasEnteredWizard = false
            selection = []
            params = [:]
            projectName = ""
            parentDir = ""
            techSummaryLocked = false
            initTarget = nil
            projectNameField.stringValue = ""
            projectSummaryField.stringValue = ""
            if settingsActive { hideSettings() }
            setStep(.workspace)
        } else {
            updateToolbarState()
            if currentStep == .workspace { rebuildWorkspaceStep() }
        }
    }

    /// 工具栏操作按钮的可用态：New project 恒可用；Init / Update config 视当前工作区而定。
    private func updateToolbarState() {
        newProjectButton?.isEnabled = true
        if let dir = currentWorkspaceDir {
            initProjectButton?.isEnabled = directoryIsEmpty(dir)
            updateConfigButton?.isEnabled = (loadWorkspaceConfig(dir) != nil)
        } else {
            initProjectButton?.isEnabled = false
            updateConfigButton?.isEnabled = false
        }
    }

    /// dsh web 就绪（M3 深化按钮门控预留）。
    func serverReady(port: Int) {
        serverReadyPort = port
    }

    /// 语言切换后刷新文案。
    func refreshTooltips() {
        openButton?.toolTip = L10n.tr("scaffold.openDirHint")
        finderButton?.toolTip = L10n.tr("scaffold.viewInFinderHint")
        newProjectButton?.title = L10n.tr("scaffold.newProject")
        initProjectButton?.title = L10n.tr("scaffold.initThisDir")
        updateConfigButton?.title = L10n.tr("scaffold.updateConfig")
        settingsButton?.toolTip = L10n.tr("scaffold.settingsTitle")
        hideButton?.toolTip = L10n.tr("preview.closePanel")
        headerTitle.stringValue = L10n.tr("scaffold.title")
        rebuildPresetButtons()
        rebuildTargetStep()
        rebuildStepRail()
        rebuildStageList()
        rebuildParamsStep()
        updateFooter()
        if currentStep == .workspace { rebuildWorkspaceStep() }
        refreshPlan()
    }

    // MARK: 环境/测试钩子

    func setParentDir(_ dir: String) {
        parentDir = dir
        UserDefaults.standard.set(dir, forKey: Self.lastDirKey)
        dirButton.title = dir.isEmpty ? L10n.tr("scaffold.pickDir") : (dir as NSString).lastPathComponent
        dirButton.toolTip = dir
        refreshPlan()
    }

    // MARK: UI 构建

    private func buildUI() {
        // 头部
        headerTitle.stringValue = L10n.tr("scaffold.title")
        headerTitle.font = .systemFont(ofSize: 14)
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        headerTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)

        openButton = CustomIconButton(glyph: .openInApp, tooltip: L10n.tr("scaffold.openDirHint"))
        openButton.onAction = { [weak self] in self?.openTargetDir() }
        finderButton = CustomIconButton(glyph: .reveal, tooltip: L10n.tr("scaffold.viewInFinderHint"))
        finderButton.onAction = { [weak self] in self?.revealInFinder() }
        settingsButton = CustomIconButton(glyph: .symbol("gearshape"), tooltip: L10n.tr("scaffold.settingsTitle"))
        settingsButton.onAction = { [weak self] in self?.toggleSettings() }
        hideButton = CustomIconButton(glyph: .close, tooltip: L10n.tr("preview.closePanel"))
        hideButton.onAction = { [weak self] in self?.onRequestHide?() }

        prevButton.title = L10n.tr("scaffold.prev")
        prevButton.bezelStyle = .rounded
        prevButton.controlSize = .small
        prevButton.font = .systemFont(ofSize: 12)
        prevButton.target = self
        prevButton.action = #selector(prevTapped(_:))
        prevButton.translatesAutoresizingMaskIntoConstraints = false
        nextButton.title = L10n.tr("scaffold.next")
        nextButton.bezelStyle = .rounded
        nextButton.controlSize = .small
        nextButton.font = .systemFont(ofSize: 12)
        nextButton.target = self
        nextButton.action = #selector(nextTapped(_:))
        nextButton.translatesAutoresizingMaskIntoConstraints = false
        nextButton.widthAnchor.constraint(equalToConstant: 88).isActive = true

        let actions = NSStackView(views: [openButton, finderButton, settingsButton, hideButton])
        actions.orientation = .horizontal
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false

        let header = DynamicFillView()
        header.kind = .window
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerTitle)
        header.addSubview(actions)
        NSLayoutConstraint.activate([
            headerTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            headerTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerTitle.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),
            actions.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            actions.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),
        ])

        // 工具栏：Back / Next、分隔符、New project / Init project / Update config。
        let toolbar = DynamicFillView()
        toolbar.kind = .window
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.masksToBounds = true
        toolbarView = toolbar

        newProjectButton = NSButton(title: L10n.tr("scaffold.newProject"), target: self, action: #selector(newProjectTapped(_:)))
        newProjectButton.bezelStyle = .rounded
        newProjectButton.controlSize = .small
        newProjectButton.font = .systemFont(ofSize: 12)
        newProjectButton.translatesAutoresizingMaskIntoConstraints = false

        initProjectButton = NSButton(title: L10n.tr("scaffold.initThisDir"), target: self, action: #selector(initCurrentTapped(_:)))
        initProjectButton.bezelStyle = .rounded
        initProjectButton.controlSize = .small
        initProjectButton.font = .systemFont(ofSize: 12)
        initProjectButton.translatesAutoresizingMaskIntoConstraints = false

        updateConfigButton = NSButton(title: L10n.tr("scaffold.updateConfig"), target: self, action: #selector(updateConfigTapped(_:)))
        updateConfigButton.bezelStyle = .rounded
        updateConfigButton.controlSize = .small
        updateConfigButton.font = .systemFont(ofSize: 12)
        updateConfigButton.translatesAutoresizingMaskIntoConstraints = false

        let toolbarSeparator = NSBox()
        toolbarSeparator.boxType = .separator
        toolbarSeparator.translatesAutoresizingMaskIntoConstraints = false
        toolbarSeparator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        toolbarSeparator.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let toolbarStack = NSStackView(views: [prevButton, nextButton, toolbarSeparator, newProjectButton, initProjectButton, updateConfigButton])
        toolbarStack.orientation = .horizontal
        toolbarStack.spacing = 6
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(toolbarStack)
        NSLayoutConstraint.activate([
            toolbarStack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 14),
            toolbarStack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 32),
        ])

        // toolbar 与内容区之间的分隔线（与其他面板一致的视觉）
        let toolbarUnderline = NSBox()
        toolbarUnderline.boxType = .separator
        toolbarUnderline.translatesAutoresizingMaskIntoConstraints = false
        toolbarUnderlineView = toolbarUnderline

        // 步骤时间线（左栏）
        railStack.orientation = .vertical
        railStack.alignment = .leading
        railStack.spacing = 6
        railStack.translatesAutoresizingMaskIntoConstraints = false
        let rail = DynamicFillView()
        rail.kind = .control
        rail.translatesAutoresizingMaskIntoConstraints = false
        rail.wantsLayer = true
        rail.layer?.masksToBounds = true
        rail.addSubview(railStack)
        railView = rail
        NSLayoutConstraint.activate([
            rail.widthAnchor.constraint(equalToConstant: 160),
            railStack.topAnchor.constraint(equalTo: rail.topAnchor, constant: 14),
            railStack.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: 6),
            railStack.trailingAnchor.constraint(equalTo: rail.trailingAnchor, constant: -6),
            railStack.widthAnchor.constraint(equalToConstant: 148),
        ])

        // 内容区
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true
        contentContainer.layer?.masksToBounds = true

        // 状态条
        statusBar.kind = .control
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.wantsLayer = true
        statusBar.layer?.masksToBounds = true
        statusLabel.text = ""
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusSpinner.style = .spinning
        statusSpinner.controlSize = .small
        statusSpinner.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(statusSpinner)
        statusBar.addSubview(statusLabel)
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
        view.addSubview(rail)
        view.addSubview(contentContainer)
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

            rail.topAnchor.constraint(equalTo: toolbarUnderline.bottomAnchor),
            rail.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rail.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            toolbarUnderline.heightAnchor.constraint(equalToConstant: 1),

            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.topAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // contentContainer 顶/左双态：正常（rail + toolbar 下方）vs 设置视图（全宽全高）
        contentTopNormal = contentContainer.topAnchor.constraint(equalTo: toolbarUnderline.bottomAnchor)
        contentTopSettings = contentContainer.topAnchor.constraint(equalTo: header.bottomAnchor)
        contentLeadingNormal = contentContainer.leadingAnchor.constraint(equalTo: rail.trailingAnchor)
        contentLeadingSettings = contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        contentTopNormal?.isActive = true
        contentLeadingNormal?.isActive = true

        buildWorkspaceStep()
        buildTargetStep()
        buildStagesStep()
        buildParamsStep()
        buildPreviewStep()
        rebuildStepRail()
        buildSettingsViews()
        setStep(.workspace)
    }


    private func buildWorkspaceStep() {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.masksToBounds = true

        // 可滚动：用「翻转容器」作 documentView，内容短时贴顶而非贴底。
        workspaceStack.orientation = .vertical
        workspaceStack.alignment = .leading
        workspaceStack.spacing = 10
        workspaceStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        workspaceStack.translatesAutoresizingMaskIntoConstraints = false
        workspaceDoc.translatesAutoresizingMaskIntoConstraints = false
        workspaceDoc.addSubview(workspaceStack)
        NSLayoutConstraint.activate([
            workspaceStack.topAnchor.constraint(equalTo: workspaceDoc.topAnchor),
            workspaceStack.leadingAnchor.constraint(equalTo: workspaceDoc.leadingAnchor),
            workspaceStack.widthAnchor.constraint(equalTo: workspaceDoc.widthAnchor),
        ])
        workspaceScroll.documentView = workspaceDoc
        workspaceScroll.hasVerticalScroller = true
        workspaceScroll.autohidesScrollers = true
        workspaceScroll.drawsBackground = false
        workspaceScroll.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(workspaceScroll)
        NSLayoutConstraint.activate([
            workspaceScroll.topAnchor.constraint(equalTo: v.topAnchor),
            workspaceScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            workspaceScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            workspaceScroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        workspaceStepView = v
        contentContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            v.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        rebuildWorkspaceStep()
    }

    private func rebuildWorkspaceStep() {
        for sub in workspaceStack.arrangedSubviews {
            workspaceStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        let dir = resolveCurrentWorkspace()
        currentWorkspaceDir = dir
        updateToolbarState()

        let title = NSTextField(labelWithString: L10n.tr("scaffold.workspaceTitle"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        workspaceStack.addArrangedSubview(title)

        if let dir = dir {
            let path = NSTextField(labelWithString: dir)
            path.font = .systemFont(ofSize: 12)
            path.textColor = .secondaryLabelColor
            path.lineBreakMode = .byTruncatingTail
            path.maximumNumberOfLines = 1
            workspaceStack.addArrangedSubview(path)
            path.widthAnchor.constraint(equalTo: workspaceStack.widthAnchor, constant: -32).isActive = true
            // 打开目录 / 在 Finder 中显示：放在目录路径下方
            appendRowButtons(dir: dir)
        }

        if let dir = dir, let cfg = loadWorkspaceConfig(dir) {
            renderGenerated(cfg, dir: dir)
        } else {
            renderInitPrompt(dir: dir)
        }
        // 让滚动视图的内容高度跟随 stack 的 fitting 尺寸（否则超长内容无法滚动）
        workspaceStack.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let fitting = self.workspaceStack.fittingSize
            if fitting.height > 0 {
                let w = max(fitting.width, self.workspaceScroll.contentView.bounds.width)
                self.workspaceStack.setFrameSize(NSSize(width: w, height: fitting.height))
                self.workspaceDoc.setFrameSize(NSSize(width: w, height: fitting.height))
            }
            self.view.layoutSubtreeIfNeeded()
        }
    }

    private func resolveCurrentWorkspace() -> String? {
        guard let p = workspacePath?(), !p.isEmpty,
              FileManager.default.fileExists(atPath: p) else { return nil }
        return p
    }

    private func loadWorkspaceConfig(_ dir: String) -> WorkspaceConfig? {
        let p = (dir as NSString).appendingPathComponent(".scaffold/state.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stagesArr = json["stages"] as? [[String: Any]] else { return nil }
        var cfg = WorkspaceConfig()
        cfg.projectName = json["projectName"] as? String ?? ""
        cfg.targetRoot = json["targetRoot"] as? String ?? dir
        cfg.files = json["files"] as? [String] ?? []
        for s in stagesArr {
            guard let id = s["id"] as? String else { continue }
            cfg.stages.append(id)
            var p: [String: String] = [:]
            if let dict = s["params"] as? [String: Any] {
                for (k, v) in dict { p[k] = String(describing: v) }
            }
            cfg.params[id] = p
        }
        return cfg
    }

    private func stageName(_ id: String) -> String {
        catalog.first(where: { $0.id == id })?.name ?? id
    }

    private func renderGenerated(_ cfg: WorkspaceConfig, dir: String) {
        let badge = NSTextField(labelWithString: L10n.tr("scaffold.workspaceGenerated"))
        badge.font = .systemFont(ofSize: 13, weight: .semibold)
        badge.textColor = .systemGreen
        workspaceStack.addArrangedSubview(badge)

        let count = NSTextField(labelWithString: L10n.tr("scaffold.workspaceFiles", cfg.files.count))
        count.font = .systemFont(ofSize: 12)
        count.textColor = .secondaryLabelColor
        workspaceStack.addArrangedSubview(count)

        // 环节顺序与向导「选择环节/参数配置」一致：按工程先后顺序（stageOrder）。
        let orderedStages = cfg.stages.sorted { stageIndex($0) < stageIndex($1) }
        for id in orderedStages {
            let pairs = orderedParams(id: id, dict: cfg.params[id] ?? [:])
            let card = stageCard(name: stageName(id), params: pairs)
            workspaceStack.addArrangedSubview(card)
            // 卡片宽度约束必须在加入 workspaceStack 之后再激活（同一视图层级）
            card.widthAnchor.constraint(equalTo: workspaceStack.widthAnchor, constant: -32).isActive = true
        }

        _ = dir
    }

    /// 环节参数的人类可读标签（取 stage.yaml 的 label，缺失回退 key）。
    private func paramLabel(_ stageId: String, _ key: String) -> String {
        guard let stage = catalog.first(where: { $0.id == stageId }),
              let param = stage.params.first(where: { $0.key == key }) else { return key }
        return param.label
    }

    /// 参数顺序与「参数配置」步骤一致：按 stage.yaml 的 params 定义顺序，仅取非空值。
    private func orderedParams(id: String, dict: [String: String]) -> [(String, String)] {
        if let stage = catalog.first(where: { $0.id == id }) {
            var out: [(String, String)] = []
            for p in stage.params {
                if let v = dict[p.key], !v.isEmpty {
                    out.append((p.label, v))
                }
            }
            return out
        }
        // 回退：环节不在目录中时按 key 排序
        return dict.filter { !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .map { (paramLabel(id, $0.key), $0.value) }
    }

    /// 配置卡片：圆角描边，内部为「环节名 + 参数行」。
    private func stageCard(name: String, params: [(String, String)]) -> NSView {
        let card = WorkspaceStageCardView()
        card.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        // 用约束内边距（而非 edgeInsets）让参数与卡片边框留出间距
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
        ])

        let nameL = NSTextField(labelWithString: name)
        nameL.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(nameL)

        for (l, v) in params {
            let row = paramRow(label: l, value: v)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return card
    }

    /// 参数行：label（次级色）+ value（主色），可换行。
    private func paramRow(label: String, value: String) -> NSTextField {
        let t = NSTextField(labelWithString: "")
        t.font = .systemFont(ofSize: 12)
        t.lineBreakMode = .byWordWrapping
        t.maximumNumberOfLines = 2
        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(string: label + ": ",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 12)]))
        attr.append(NSAttributedString(string: value,
            attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 12)]))
        t.attributedStringValue = attr
        return t
    }

    private func renderInitPrompt(dir: String?) {
        guard let dir = dir else {
            let msg = NSTextField(labelWithString: L10n.tr("scaffold.workspaceNoDir"))
            msg.font = .systemFont(ofSize: 13)
            msg.textColor = .labelColor
            msg.lineBreakMode = .byWordWrapping
            msg.maximumNumberOfLines = 3
            msg.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
            workspaceStack.addArrangedSubview(msg)
            return
        }
        // 未用脚手架初始化：仅空目录才允许初始化
        if directoryIsEmpty(dir) {
            let msg = NSTextField(labelWithString: L10n.tr("scaffold.workspaceNotGenerated"))
            msg.font = .systemFont(ofSize: 13)
            msg.textColor = .labelColor
            msg.lineBreakMode = .byWordWrapping
            msg.maximumNumberOfLines = 3
            msg.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
            workspaceStack.addArrangedSubview(msg)

            let desc = NSTextField(labelWithString: L10n.tr("scaffold.workspaceInitHint"))
            desc.font = .systemFont(ofSize: 12)
            desc.textColor = .secondaryLabelColor
            desc.lineBreakMode = .byWordWrapping
            desc.maximumNumberOfLines = 3
            desc.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
            workspaceStack.addArrangedSubview(desc)
        } else {
            let msg = NSTextField(labelWithString: L10n.tr("scaffold.workspaceNotEmpty"))
            msg.font = .systemFont(ofSize: 13)
            msg.textColor = .labelColor
            msg.lineBreakMode = .byWordWrapping
            msg.maximumNumberOfLines = 3
            msg.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
            workspaceStack.addArrangedSubview(msg)

            let desc = NSTextField(labelWithString: L10n.tr("scaffold.workspaceNotEmptyHint"))
            desc.font = .systemFont(ofSize: 12)
            desc.textColor = .secondaryLabelColor
            desc.lineBreakMode = .byWordWrapping
            desc.maximumNumberOfLines = 3
            desc.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
            workspaceStack.addArrangedSubview(desc)
        }
    }

    /// 目录是否为空（无任何文件/子目录）。
    private func directoryIsEmpty(_ dir: String) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).isEmpty
    }

    private func appendRowButtons(dir: String) {
        let open = NSButton(title: L10n.tr("scaffold.openDir"), target: self, action: #selector(openWorkspaceTapped(_:)))
        open.bezelStyle = .rounded
        open.controlSize = .small
        let finder = NSButton(title: L10n.tr("scaffold.viewInFinder"), target: self, action: #selector(revealWorkspaceTapped(_:)))
        finder.bezelStyle = .rounded
        finder.controlSize = .small
        let row = NSStackView(views: [open, finder])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        workspaceStack.addArrangedSubview(row)
        _ = dir
    }

    // MARK: 步骤视图

    private func buildTargetStep() {
        targetTitleLabel.stringValue = L10n.tr("scaffold.step.target")
        targetTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        targetSubtitleLabel.stringValue = L10n.tr("scaffold.targetHint")
        targetSubtitleLabel.font = .systemFont(ofSize: 12)
        targetSubtitleLabel.textColor = .secondaryLabelColor
        targetSubtitleLabel.maximumNumberOfLines = 2
        targetSubtitleLabel.lineBreakMode = .byWordWrapping

        // 位置（Location）在最上
        parentDirLabel.stringValue = L10n.tr("scaffold.parentDir")
        parentDirLabel.font = .systemFont(ofSize: 13, weight: .medium)
        dirButton.title = L10n.tr("scaffold.pickDir")
        dirButton.bezelStyle = .rounded
        dirButton.controlSize = .regular
        dirButton.font = .systemFont(ofSize: 12)
        dirButton.target = self
        dirButton.action = #selector(pickDirTapped(_:))
        dirButton.translatesAutoresizingMaskIntoConstraints = false
        dirButton.widthAnchor.constraint(equalToConstant: 160).isActive = true

        let dirRow = NSStackView(views: [parentDirLabel, dirButton])
        dirRow.orientation = .horizontal
        dirRow.spacing = 10
        dirRow.alignment = .centerY
        dirRow.translatesAutoresizingMaskIntoConstraints = false

        // 项目名（= 目录名 说明已由「将创建目录」预览承担，标签不再赘述）
        projectNameLabel.stringValue = L10n.tr("scaffold.projectName")
        projectNameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        projectNameField.placeholderString = L10n.tr("scaffold.projectNamePlaceholder")
        projectNameField.font = .systemFont(ofSize: 14)
        projectNameField.controlSize = .large
        projectNameField.target = self
        projectNameField.action = #selector(projectNameChanged(_:))
        projectNameField.translatesAutoresizingMaskIntoConstraints = false
        projectNameField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let nameRow = NSStackView(views: [projectNameLabel, projectNameField])
        nameRow.orientation = .horizontal
        nameRow.spacing = 10
        nameRow.alignment = .centerY
        nameRow.translatesAutoresizingMaskIntoConstraints = false

        // 项目简介（必填，带入 AGENTS.md 的 techSummary）
        projectSummaryLabel = NSTextField(labelWithString: L10n.tr("scaffold.projectSummary") + " *")
        projectSummaryLabel.font = .systemFont(ofSize: 13, weight: .medium)
        projectSummaryLabel.textColor = .systemRed
        projectSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        projectSummaryField.placeholderString = L10n.tr("scaffold.projectSummaryPlaceholder")
        projectSummaryField.font = .systemFont(ofSize: 13)
        projectSummaryField.controlSize = .regular
        projectSummaryField.target = self
        projectSummaryField.action = #selector(summaryChanged(_:))
        projectSummaryField.translatesAutoresizingMaskIntoConstraints = false
        projectSummaryField.wantsLayer = true
        projectSummaryField.layer?.cornerRadius = 4
        projectSummaryField.layer?.borderWidth = 1
        projectSummaryField.widthAnchor.constraint(equalToConstant: 340).isActive = true

        let summaryRow = NSStackView(views: [projectSummaryLabel, projectSummaryField])
        summaryRow.orientation = .horizontal
        summaryRow.spacing = 10
        summaryRow.alignment = .centerY
        summaryRow.translatesAutoresizingMaskIntoConstraints = false

        targetRootLabel.font = .systemFont(ofSize: 12)
        targetRootLabel.textColor = .secondaryLabelColor
        targetRootLabel.lineBreakMode = .byTruncatingTail
        targetRootLabel.maximumNumberOfLines = 1

        let stack = NSStackView(views: [targetTitleLabel, targetSubtitleLabel, dirRow, nameRow, summaryRow, targetRootLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -8),
            dirRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            nameRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            summaryRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            targetRootLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        targetStepView = v
        contentContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            v.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    /// 语言切换后重建步骤 1（目标与位置）的静态标签文案。
    private func rebuildTargetStep() {
        targetTitleLabel.stringValue = L10n.tr("scaffold.step.target")
        targetSubtitleLabel.stringValue = L10n.tr("scaffold.targetHint")
        parentDirLabel.stringValue = L10n.tr("scaffold.parentDir")
        dirButton.title = parentDir.isEmpty ? L10n.tr("scaffold.pickDir") : (parentDir as NSString).lastPathComponent
        projectNameLabel.stringValue = L10n.tr("scaffold.projectName")
        projectNameField.placeholderString = L10n.tr("scaffold.projectNamePlaceholder")
        projectSummaryLabel?.stringValue = L10n.tr("scaffold.projectSummary") + " *"
        projectSummaryField.placeholderString = L10n.tr("scaffold.projectSummaryPlaceholder")
    }

    private func buildStagesStep() {
        stagesHeader.font = .systemFont(ofSize: 13, weight: .medium)
        stagesHeader.translatesAutoresizingMaskIntoConstraints = false

        // 按目的预设（快捷勾选，不影响自由组合）
        presetTitleLabel.stringValue = L10n.tr("scaffold.presetTitle")
        presetTitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        presetTitleLabel.textColor = .secondaryLabelColor
        presetTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        let presetRow = NSStackView()
        presetRow.orientation = .horizontal
        presetRow.spacing = 8
        presetRow.translatesAutoresizingMaskIntoConstraints = false
        let presets = ScaffoldPreset.all
        for (idx, preset) in presets.enumerated() {
            let b = NSButton(title: presetTitle(preset.id), target: self, action: #selector(presetTapped(_:)))
            b.tag = idx
            b.bezelStyle = .rounded
            b.controlSize = .regular
            b.font = .systemFont(ofSize: 12)
            b.translatesAutoresizingMaskIntoConstraints = false
            presetRow.addArrangedSubview(b)
            presetButtons.append(b)
        }

        stageStack.orientation = .vertical
        stageStack.alignment = .width
        stageStack.spacing = 10
        stageStack.translatesAutoresizingMaskIntoConstraints = false
        stageScroll.documentView = stageStack
        stageScroll.hasVerticalScroller = true
        stageScroll.autohidesScrollers = true
        stageScroll.drawsBackground = false
        stageScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stageStack.leadingAnchor.constraint(equalTo: stageScroll.contentView.leadingAnchor),
            stageStack.trailingAnchor.constraint(equalTo: stageScroll.contentView.trailingAnchor),
            stageStack.topAnchor.constraint(equalTo: stageScroll.contentView.topAnchor),
        ])

        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stagesHeader)
        v.addSubview(presetTitleLabel)
        v.addSubview(presetRow)
        v.addSubview(stageScroll)
        NSLayoutConstraint.activate([
            stagesHeader.topAnchor.constraint(equalTo: v.topAnchor, constant: 14),
            stagesHeader.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            stagesHeader.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -16),
            presetTitleLabel.topAnchor.constraint(equalTo: stagesHeader.bottomAnchor, constant: 10),
            presetTitleLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            presetTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -16),
            presetRow.topAnchor.constraint(equalTo: presetTitleLabel.bottomAnchor, constant: 6),
            presetRow.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            presetRow.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -16),
            stageScroll.topAnchor.constraint(equalTo: presetRow.bottomAnchor, constant: 10),
            stageScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            stageScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            stageScroll.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
        ])
        stagesStepView = v
        contentContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            v.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    private func buildParamsStep() {
        paramsHeader.font = .systemFont(ofSize: 13, weight: .medium)
        paramsHeader.translatesAutoresizingMaskIntoConstraints = false

        paramsStack.orientation = .vertical
        // .leading：行贴合内容簇拥左侧（标题/错误行有显式 width==doc 约束铺满）。
        // 文档宽度由 leading/trailing 约束锚定 contentView，不会形成循环。
        paramsStack.alignment = .leading
        paramsStack.spacing = 10
        paramsStack.translatesAutoresizingMaskIntoConstraints = false
        paramsScroll.documentView = paramsStack
        paramsScroll.hasVerticalScroller = true
        paramsScroll.autohidesScrollers = true
        paramsScroll.drawsBackground = false
        paramsScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            paramsStack.leadingAnchor.constraint(equalTo: paramsScroll.contentView.leadingAnchor),
            paramsStack.trailingAnchor.constraint(equalTo: paramsScroll.contentView.trailingAnchor),
            paramsStack.topAnchor.constraint(equalTo: paramsScroll.contentView.topAnchor),
        ])

        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(paramsHeader)
        v.addSubview(paramsScroll)
        NSLayoutConstraint.activate([
            paramsHeader.topAnchor.constraint(equalTo: v.topAnchor, constant: 14),
            paramsHeader.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            paramsHeader.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -16),
            paramsScroll.topAnchor.constraint(equalTo: paramsHeader.bottomAnchor, constant: 8),
            paramsScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            paramsScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            paramsScroll.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
        ])
        paramsStepView = v
        contentContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            v.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    private func buildPreviewStep() {
        previewHeaderLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        previewHeaderLabel.translatesAutoresizingMaskIntoConstraints = false

        messageStack.orientation = .vertical
        messageStack.alignment = .leading
        messageStack.spacing = 3
        messageStack.translatesAutoresizingMaskIntoConstraints = false
        messageScroll.documentView = messageStack
        messageScroll.hasVerticalScroller = true
        messageScroll.autohidesScrollers = true
        messageScroll.drawsBackground = false
        messageScroll.translatesAutoresizingMaskIntoConstraints = false
        messageScroll.heightAnchor.constraint(equalToConstant: 64).isActive = true
        NSLayoutConstraint.activate([
            messageStack.leadingAnchor.constraint(equalTo: messageScroll.contentView.leadingAnchor),
            messageStack.trailingAnchor.constraint(equalTo: messageScroll.contentView.trailingAnchor),
            messageStack.topAnchor.constraint(equalTo: messageScroll.contentView.topAnchor),
        ])

        fileOutline.headerView = nil
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        fileOutline.addTableColumn(col)
        fileOutline.outlineTableColumn = col
        fileOutline.dataSource = self
        fileOutline.delegate = self
        fileOutline.rowSizeStyle = .medium
        fileOutline.autoresizesOutlineColumn = true
        fileOutline.allowsMultipleSelection = false
        fileScroll.documentView = fileOutline
        fileScroll.hasVerticalScroller = true
        fileScroll.autohidesScrollers = true
        fileScroll.drawsBackground = false
        fileScroll.translatesAutoresizingMaskIntoConstraints = false

        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(previewHeaderLabel)
        v.addSubview(messageScroll)
        v.addSubview(fileScroll)
        NSLayoutConstraint.activate([
            previewHeaderLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 14),
            previewHeaderLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            previewHeaderLabel.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -16),
            messageScroll.topAnchor.constraint(equalTo: previewHeaderLabel.bottomAnchor, constant: 6),
            messageScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            messageScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            fileScroll.topAnchor.constraint(equalTo: messageScroll.bottomAnchor, constant: 4),
            fileScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            fileScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            fileScroll.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
        ])
        previewStepView = v
        contentContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            v.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    private func presetTitle(_ id: String) -> String {
        switch id {
        case "backend": return L10n.tr("scaffold.presetBackend")
        case "fullstack": return L10n.tr("scaffold.presetFullstack")
        case "foundation": return L10n.tr("scaffold.presetFoundation")
        default: return id
        }
    }

    // MARK: 步骤导航

    private func rebuildStepRail() {
        for sub in railStack.arrangedSubviews {
            railStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        stepItems.removeAll()
        let steps = Step.allCases.sorted { $0.rawValue < $1.rawValue }
        for step in steps {
            let item = ScaffoldStepItem(number: step.rawValue, title: L10n.tr(step.titleKey))
            item.onAction = { [weak self] in self?.setStep(step) }
            railStack.addArrangedSubview(item)
            stepItems.append(item)
        }
        updateStepRail()
    }

    private func updateStepRail() {
        let targetDone = !projectName.isEmpty && !parentDir.isEmpty
        let stagesDone = !selection.isEmpty
        let paramsDone = (plan?.validationErrors.isEmpty ?? true)
        let previewError = !(plan?.stageErrors.isEmpty ?? true)
        // 在「当前项目」首页且尚未进入向导（或 Back 取消复位后）时，步骤 2~5 折叠隐藏；
        // 进入向导后展开，步骤切换走时间线/导航。
        let onlyWorkspace = (currentStep == .workspace && !hasEnteredWizard)
        for item in stepItems {
            guard let step = Step(rawValue: item.number) else { continue }
            item.isHidden = (onlyWorkspace && step != .workspace)
            switch step {
            case .workspace:
                item.state = (step == currentStep) ? .current : .done
            case .target:
                item.state = (step == currentStep) ? .current : (targetDone ? .done : .idle)
            case .stages:
                item.state = (step == currentStep) ? .current : (stagesDone ? .done : .idle)
            case .params:
                if step == currentStep {
                    item.state = paramsDone ? .current : .error
                } else {
                    item.state = stagesDone ? (paramsDone ? .done : .error) : .idle
                }
            case .preview:
                if step == currentStep {
                    item.state = previewError ? .error : .current
                } else {
                    item.state = stagesDone ? (previewError ? .error : .done) : .idle
                }
            }
        }
    }

    private func setStep(_ step: Step) {
        currentStep = step
        workspaceStepView?.isHidden = step != .workspace
        targetStepView?.isHidden = step != .target
        stagesStepView?.isHidden = step != .stages
        paramsStepView?.isHidden = step != .params
        previewStepView?.isHidden = step != .preview
        if step == .workspace { rebuildWorkspaceStep() }
        // 进入滚动步骤：开启置顶时间窗（布局落定后由 handleRootLayout 执行）
        if step == .workspace || step == .stages || step == .params {
            scrollTopDeadline = Date().addingTimeInterval(1.0)
            handleRootLayout()
        }
        // 参数步骤在隐藏期间布局会塌陷（嵌套行零尺寸），进入时强制重建一次
        if step == .params { rebuildParamsStep() }
        updateStepRail()
        updateFooter()
    }

    private func updateFooter() {
        prevButton.title = L10n.tr("scaffold.prev")
        // 目标步骤的 Back 作为「取消/返回当前项目」：从向导任意步骤都能回到首页；
        // 回到首页即折叠步骤 2~5（见 prevTapped 的 hasEnteredWizard 复位）。
        prevButton.isEnabled = (currentStep != .workspace)
        if currentStep == .preview {
            nextButton.title = L10n.tr("scaffold.generate")
            nextButton.action = #selector(generateTapped(_:))
            if let p = plan { updateGenerateEnabled(p) }
        } else if currentStep == .workspace {
            // 当前项目首页：不提供向导前进/后退，仅经操作按钮进入向导。
            nextButton.title = L10n.tr("scaffold.next")
            nextButton.action = #selector(nextTapped(_:))
            nextButton.isEnabled = false
        } else {
            nextButton.title = L10n.tr("scaffold.next")
            nextButton.action = #selector(nextTapped(_:))
            nextButton.isEnabled = true
        }
    }

    @objc private func prevTapped(_ sender: Any?) {
        guard let prev = Step(rawValue: currentStep.rawValue - 1) else { return }
        // Back 回到「当前项目」首页即视为取消向导：复位入口状态，时间线折叠回仅显示当前项目。
        if prev == .workspace { hasEnteredWizard = false }
        setStep(prev)
    }

    @objc private func nextTapped(_ sender: Any?) {
        guard let next = Step(rawValue: currentStep.rawValue + 1) else { return }
        setStep(next)
    }

    // MARK: 环节库加载与列表

    private func loadCatalog() {
        let result = StageCatalogLoader.load()
        catalog = result.stages
        catalogErrors = result.errors
        builtinIDs = result.builtinIDs
        rebuildStageList()
    }

    private func rebuildPresetButtons() {
        presetTitleLabel.stringValue = L10n.tr("scaffold.presetTitle")
        let presets = ScaffoldPreset.all
        for (idx, b) in presetButtons.enumerated() {
            if idx < presets.count { b.title = presetTitle(presets[idx].id) }
        }
    }

    /// 重建环节卡片列表（按 category 分组，勾选状态保留）。
    private func rebuildStageList() {
        for sub in stageStack.arrangedSubviews {
            stageStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        editors.removeAll()

        // 分类：内置三类在前，用户环节可能的其他分类（自定义 yaml category）追加在后
        var categories = ["foundation", "examples", "collaboration"]
        categories += Set(catalog.map { $0.category }).subtracting(categories).sorted()
        for cat in categories {
            // 按工程先后顺序排列（未在 stageOrder 中的按目录序排后）
            let stages = catalog.filter { $0.category == cat }
                .sorted { stageIndex($0.id) < stageIndex($1.id) }
            guard !stages.isEmpty else { continue }
            let isKnown = cat == "foundation" || cat == "examples" || cat == "collaboration"
            let titleLabel = NSTextField(labelWithString: isKnown ? L10n.tr("scaffold.stageCategory.\(cat)") : cat)
            titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            titleLabel.textColor = .secondaryLabelColor
            titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            // 先加入 stack 再激活宽度约束（约束需共同祖先）
            stageStack.addArrangedSubview(titleLabel)
            titleLabel.widthAnchor.constraint(equalTo: stageStack.widthAnchor).isActive = true
            for stage in stages {
                let editor = StageEditor(stage: stage) { [weak self] in
                    self?.toggleStage(stage.id)
                }
                editor.card.isSelected = selection.contains(stage.id)
                editors[stage.id] = editor
                // 接线 radio 按钮（radio 组按 stage.param 标识）
                for (key, buttons) in editor.radioGroups {
                    radioGroups[key] = buttons
                    for b in buttons {
                        b.target = self
                        b.action = #selector(paramRadioChanged(_:))
                    }
                }
                // 接线 string / select / bool / multiselect 控件（参数步骤可编辑）
                for (_, field) in editor.stringControls {
                    field.target = self
                    field.action = #selector(paramStringChanged(_:))
                }
                for (_, pop) in editor.selectControls {
                    pop.target = self
                    pop.action = #selector(paramSelectChanged(_:))
                }
                for (_, cb) in editor.boolControls {
                    cb.target = self
                    cb.action = #selector(paramBoolChanged(_:))
                }
                for (_, boxes) in editor.multiControls {
                    for b in boxes {
                        b.target = self
                        b.action = #selector(paramMultiChanged(_:))
                    }
                }
                stageStack.addArrangedSubview(editor.card)
            }
        }
        if catalog.isEmpty {
            let empty = NSTextField(labelWithString: catalogErrors.isEmpty
                ? L10n.tr("scaffold.catalogEmpty")
                : L10n.tr("scaffold.catalogErrors", catalogErrors.joined(separator: "；")))
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            stageStack.addArrangedSubview(empty)
        } else if !catalogErrors.isEmpty {
            let err = NSTextField(labelWithString: L10n.tr("scaffold.catalogErrors", catalogErrors.joined(separator: "；")))
            err.font = .systemFont(ofSize: 12)
            err.textColor = .systemOrange
            stageStack.addArrangedSubview(err)
        }
        scrollToTop(stageScroll)
    }

    /// 根视图每次布局后的回调：时间窗内把当前滚动步骤滚回顶部。
    private func handleRootLayout() {
        guard Date() < scrollTopDeadline else { return }
        if currentStep == .stages { scrollToTop(stageScroll) }
        if currentStep == .params { scrollToTop(paramsScroll) }
    }

    /// 把滚动容器滚到文档顶部（clip bounds 原点置零）。
    private func scrollToTop(_ scroll: NSScrollView) {
        let clip = scroll.contentView
        clip.scroll(to: .zero)
        scroll.reflectScrolledClipView(clip)
    }

    /// 重建参数步骤（按选中顺序列出各环节参数卡片）。
    private func rebuildParamsStep() {
        for sub in paramsStack.arrangedSubviews {
            paramsStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        if selection.isEmpty {
            let empty = NSTextField(labelWithString: L10n.tr("scaffold.paramsEmpty"))
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            paramsStack.addArrangedSubview(empty)
            return
        }
        // 按环节聚合校验错误（格式 "stageId.paramKey: message"）
        var errorsByStage: [String: [String]] = [:]
        for err in plan?.validationErrors ?? [] {
            if let dot = err.firstIndex(of: ".") {
                let sid = String(err[..<dot])
                errorsByStage[sid, default: []].append(err)
            }
        }
        // 与步骤 2 的展示顺序保持一致（工程先后顺序；未列出的按 catalog 顺序）
        let orderedSelection = selection.sorted { lhs, rhs in
            let a = stageIndex(lhs), b = stageIndex(rhs)
            if a != b { return a < b }
            let ia = catalog.firstIndex { $0.id == lhs } ?? 0
            let ib = catalog.firstIndex { $0.id == rhs } ?? 0
            return ia < ib
        }
        for id in orderedSelection {
            guard let editor = editors[id] else { continue }
            // 无参数的环节（如 repo-knowledge）步骤 3 不显示参数区
            if editor.paramRows.isEmpty { continue }
            // 用当前 params 同步控件显示（如 AGENTS.md 的 techSummary 默认取步骤 1 项目简介）
            editor.syncControls(values: params[id] ?? [:])
            let title = NSTextField(labelWithString: editor.stage.name)
            title.font = .systemFont(ofSize: 14, weight: .semibold)
            title.setContentHuggingPriority(.defaultLow, for: .horizontal)
            title.translatesAutoresizingMaskIntoConstraints = false
            paramsStack.addArrangedSubview(title)
            title.widthAnchor.constraint(equalTo: paramsStack.widthAnchor).isActive = true
            // 参数行扁平加入（避免嵌套 stack 塌陷）
            for row in editor.paramRows {
                paramsStack.addArrangedSubview(row)
            }
            // 该环节的校验错误 → 红色行内提示（可读文案，非 stageId.paramKey）
            if let errs = errorsByStage[id] {
                for e in errs {
                    let l = NSTextField(labelWithString: "⚠ " + friendlyError(e))
                    l.font = .systemFont(ofSize: 11)
                    l.textColor = .systemRed
                    l.lineBreakMode = .byWordWrapping
                    l.maximumNumberOfLines = 2
                    l.setContentHuggingPriority(.defaultLow, for: .horizontal)
                    l.translatesAutoresizingMaskIntoConstraints = false
                    paramsStack.addArrangedSubview(l)
                    l.widthAnchor.constraint(equalTo: paramsStack.widthAnchor).isActive = true
                }
            }
            // 必填参数空值 → 红框高亮（以输入框当前值为准，值变化时刷新）
            editor.updateRequiredHighlights()
            // 环节分区间距
            if let lastRow = editor.paramRows.last {
                paramsStack.setCustomSpacing(14, after: lastRow)
            }
        }
        // 嵌套行在文档滚动视图里首轮布局会塌陷（帧陈旧）：重建后强制把文档帧
        // 设为其 fitting 尺寸并再做一次布局——行按内容宽度簇拥左侧、高度正确。
        paramsStack.invalidateIntrinsicContentSize()
        if currentStep == .params {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let fitting = self.paramsStack.fittingSize
                if fitting.height > 0 {
                    let w = max(fitting.width, self.paramsScroll.contentView.bounds.width)
                    self.paramsStack.setFrameSize(NSSize(width: w, height: fitting.height))
                }
                self.view.layoutSubtreeIfNeeded()
            }
        }
    }

    /// 把引擎错误（"stageId.paramKey: message"）转成可读文案（"环节名 · 参数标签：message"）。
    private func friendlyError(_ raw: String) -> String {
        guard let colon = raw.firstIndex(of: ":") else { return raw }
        let head = String(raw[..<colon])
        let message = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        let parts = head.split(separator: ".").map(String.init)
        if parts.count == 2,
           let editor = editors[parts[0]],
           let param = editor.stage.params.first(where: { $0.key == parts[1] }) {
            return "\(editor.stage.name) · \(param.label)：\(message)"
        }
        return raw
    }

    // MARK: 交互

    private func toggleStage(_ id: String) {
        if selection.contains(id) {
            selection.removeAll { $0 == id }
        } else {
            selection.append(id)
        }
        editors[id]?.card.isSelected = selection.contains(id)
        refreshPlan()
    }

    @objc private func projectNameChanged(_ sender: Any?) {
        projectName = projectNameField.stringValue
        refreshPlan()
    }

    @objc private func summaryChanged(_ sender: Any?) {
        // 仅当步骤 3 的 AGENTS.md techSummary 未被独立改过时，才把它同步成步骤 1 的项目简介
        if !techSummaryLocked {
            params["agents-md", default: [:]][Self.techSummaryKey] = projectSummaryField.stringValue
        }
        refreshPlan()
    }

    @objc private func pickDirTapped(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.tr("scaffold.pickDirMessage")
        if let last = UserDefaults.standard.string(forKey: Self.lastDirKey), FileManager.default.fileExists(atPath: last) {
            panel.directoryURL = URL(fileURLWithPath: last)
        }
        if let win = view.window {
            panel.beginSheetModal(for: win) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                guard let self = self else { return }
                // 直接选择目标目录：父目录 = 所选目录的上一级，项目名默认取所选目录
                // 的最后一级（用户仍可修改，修改后目标目录会相应变化）。
                self.setParentDir(url.deletingLastPathComponent().path)
                self.projectNameField.stringValue = url.lastPathComponent
                self.refreshPlan()
            }
        }
    }

    @objc private func paramStringChanged(_ sender: NSTextField) {
        guard let id = sender.identifier?.rawValue else { return }
        let parts = id.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        if parts[0] == "agents-md", parts[1] == Self.techSummaryKey {
            techSummaryLocked = true
        }
        params[parts[0], default: [:]][parts[1]] = sender.stringValue
        refreshPlan()
    }

    @objc private func paramSelectChanged(_ sender: NSPopUpButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let parts = id.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let stage = editors[parts[0]]?.stage,
              let param = stage.params.first(where: { $0.key == parts[1] }) else { return }
        let idx = sender.indexOfSelectedItem
        if idx >= 0, idx < param.options.count {
            params[parts[0], default: [:]][parts[1]] = param.options[idx]
        }
        refreshPlan()
    }

    @objc private func paramBoolChanged(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let parts = id.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        params[parts[0], default: [:]][parts[1]] = (sender.state == .on) ? "true" : "false"
        refreshPlan()
    }

    @objc private func paramRadioChanged(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let parts = id.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let group = radioGroups[id],
              let stage = editors[parts[0]]?.stage,
              let param = stage.params.first(where: { $0.key == parts[1] }) else { return }
        // 选项展示为本地化标签，值按索引取原始选项
        if let selected = group.first(where: { $0.state == .on }), selected.tag >= 0, selected.tag < param.options.count {
            params[parts[0], default: [:]][parts[1]] = param.options[selected.tag]
        }
        refreshPlan()
    }

    @objc private func paramMultiChanged(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let parts = id.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let stage = editors[parts[0]]?.stage,
              let param = stage.params.first(where: { $0.key == parts[1] }),
              let boxes = editors[parts[0]]?.multiControls[id] else { return }
        let chosen = boxes.enumerated().compactMap { idx, b -> String? in
            (b.state == .on && idx < param.options.count) ? param.options[idx] : nil
        }
        params[parts[0], default: [:]][parts[1]] = chosen.joined(separator: " ")
        refreshPlan()
    }


    @objc private func newProjectTapped(_ sender: Any?) { beginNewProject() }

    @objc private func initCurrentTapped(_ sender: Any?) {
        guard let dir = currentWorkspaceDir else { return }
        beginInitCurrent(dir)
    }

    @objc private func updateConfigTapped(_ sender: Any?) {
        guard let dir = currentWorkspaceDir, let cfg = loadWorkspaceConfig(dir) else { return }
        beginRegenerate(cfg)
    }

    @objc private func openWorkspaceTapped(_ sender: Any?) { openDir(currentWorkspaceDir ?? "") }
    @objc private func revealWorkspaceTapped(_ sender: Any?) { revealDir(currentWorkspaceDir ?? "") }

    /// 右上角「初始化项目脚手架」：进入新建项目向导（默认行为）。
    private func beginNewProject() {
        initTarget = nil
        hasEnteredWizard = true
        setStep(.target)
    }

    /// 初始化当前目录：把脚手架生成到该目录内（不改名、不新建子目录）。
    private func beginInitCurrent(_ dir: String) {
        initTarget = dir
        hasEnteredWizard = true
        loadProjectTarget(dir: dir)
        setStep(.stages)
    }

    /// 更新已有配置：载入 state.json 的环节/参数到向导，重新生成。
    private func beginRegenerate(_ cfg: WorkspaceConfig) {
        initTarget = cfg.targetRoot.isEmpty ? currentWorkspaceDir : cfg.targetRoot
        hasEnteredWizard = true
        selection = cfg.stages
        params = cfg.params
        if let ts = cfg.params["agents-md"]?[Self.techSummaryKey], !ts.isEmpty {
            projectSummaryField.stringValue = ts
            techSummaryLocked = true
        } else {
            techSummaryLocked = false
        }
        loadProjectTarget(dir: initTarget ?? "")
        rebuildStageList()
        refreshPlan()
        // 与新建向导一致：先停在步骤 2（目标）确认目录/项目名，再下一步进入已载入的环节/参数。
        setStep(.target)
    }

    /// 把向导目标设为一个已存在目录：parentDir=父目录、projectName=目录名。
    private func loadProjectTarget(dir: String) {
        guard !dir.isEmpty else { return }
        let ns = dir as NSString
        let parent = ns.deletingLastPathComponent
        let name = ns.lastPathComponent
        parentDir = parent
        projectName = name
        projectNameField.stringValue = name
        dirButton.title = parent.isEmpty ? L10n.tr("scaffold.pickDir") : (parent as NSString).lastPathComponent
        dirButton.toolTip = parent
        refreshPlan()
    }

    private func openDir(_ path: String) {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func revealDir(_ path: String) {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func presetTapped(_ sender: NSButton) {
        let presets = ScaffoldPreset.all
        guard sender.tag >= 0, sender.tag < presets.count else { return }
        applyPreset(presets[sender.tag])
    }

    private func applyPreset(_ preset: ScaffoldPreset) {
        selection = preset.stageIds
        for (sid, pv) in preset.paramDefaults {
            for (k, v) in pv {
                params[sid, default: [:]][k] = v
            }
        }
        for (id, editor) in editors {
            editor.card.isSelected = selection.contains(id)
            editor.syncControls(values: params[id] ?? [:])
        }
        refreshPlan()
    }

    // MARK: 规划与预览

    private func refreshPlan() {
        projectName = projectNameField.stringValue
        // 项目简介在步骤 1 填写，作为 AGENTS.md techSummary 的默认值；
        // 一旦用户在步骤 3 独立改过（techSummaryLocked），就不再覆盖。
        if !techSummaryLocked {
            params["agents-md", default: [:]][Self.techSummaryKey] = projectSummaryField.stringValue
        }
        let p = ScaffoldPlan.build(catalog: catalog, selection: selection, params: params,
                                   projectName: projectName, parentDir: parentDir,
                                   existingTargetRoot: initTarget ?? "")
        plan = p
        updateTargetRootLabel(p)
        // 步骤 1 项目简介（必填）动态高亮
        let summaryEmpty = projectSummaryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        projectSummaryField.layer?.borderColor = summaryEmpty ? NSColor.systemRed.cgColor : NSColor.clear.cgColor
        projectSummaryLabel?.textColor = summaryEmpty ? .systemRed : .secondaryLabelColor
        updateStagesHeader()
        updateParamsHeader()
        rebuildParamsStep()
        rebuildPreview(p)
        updateGenerateEnabled(p)
        updateStepRail()
    }

    private func updateTargetRootLabel(_ p: ScaffoldPlan.Result) {
        if p.targetRoot.isEmpty {
            if parentDir.isEmpty {
                targetRootLabel.stringValue = L10n.tr("scaffold.willCreateDir") + ": " + L10n.tr("scaffold.willCreateDirHint")
            } else {
                targetRootLabel.stringValue = L10n.tr("scaffold.willCreateDir") + ": " + parentDir + "/<" + L10n.tr("scaffold.projectName") + ">"
            }
        } else {
            targetRootLabel.stringValue = L10n.tr("scaffold.willCreateDir") + ": " + p.targetRoot
        }
    }

    private func updateStagesHeader() {
        stagesHeader.stringValue = selection.isEmpty
            ? L10n.tr("scaffold.stagesHeader")
            : L10n.tr("scaffold.stagesHeader") + "  ·  " + L10n.tr("scaffold.stagesSelected", selection.count)
    }

    private func updateParamsHeader() {
        paramsHeader.stringValue = L10n.tr("scaffold.paramsHeader")
    }

    private func updateGenerateEnabled(_ p: ScaffoldPlan.Result) {
        let ready = !projectName.isEmpty && !parentDir.isEmpty && p.isValid && !isGenerating
        // 只有第 4 步的按钮是「生成」，才需要门控；1-3 步的「下一步」始终可点。
        nextButton.isEnabled = (currentStep == .preview) ? ready : true
    }

    private func rebuildPreview(_ p: ScaffoldPlan.Result) {
        // 消息区：校验错误 / 渲染错误 / 提示
        for sub in messageStack.arrangedSubviews {
            messageStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        for err in p.validationErrors {
            let l = NSTextField(labelWithString: "⚠ " + friendlyError(err))
            l.font = .systemFont(ofSize: 11)
            l.textColor = .systemOrange
            l.lineBreakMode = .byTruncatingTail
            l.maximumNumberOfLines = 1
            messageStack.addArrangedSubview(l)
        }
        for err in p.stageErrors {
            let l = NSTextField(labelWithString: "⛔ " + err)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .systemRed
            l.lineBreakMode = .byTruncatingTail
            l.maximumNumberOfLines = 1
            messageStack.addArrangedSubview(l)
        }
        for hint in p.hints {
            let l = NSTextField(labelWithString: "💡 " + hint)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.lineBreakMode = .byTruncatingTail
            l.maximumNumberOfLines = 1
            messageStack.addArrangedSubview(l)
        }
        messageScroll.isHidden = p.validationErrors.isEmpty && p.stageErrors.isEmpty && p.hints.isEmpty

        // 文件树
        fileTree = buildFileTree(p)
        fileOutline.reloadData()
        if let tree = fileTree, tree.children.count > 0 {
            fileOutline.expandItem(tree)
        }
        if selection.isEmpty {
            previewHeaderLabel.stringValue = L10n.tr("scaffold.previewEmpty")
            fileScroll.isHidden = true
        } else {
            previewHeaderLabel.stringValue = L10n.tr("scaffold.previewCount", p.entries.count)
            fileScroll.isHidden = false
        }
    }

    private func buildFileTree(_ p: ScaffoldPlan.Result) -> FileTreeNode? {
        guard !p.entries.isEmpty else { return nil }
        let root = FileTreeNode(name: p.projectSlug, fullPath: "", isDirectory: true)
        var conflictByPath: [String: [String]] = [:]
        for c in p.conflicts { conflictByPath[c.path] = c.stageIds }
        for e in p.entries {
            let comps = e.path.split(separator: "/").map(String.init)
            var node = root
            var path = ""
            for (i, comp) in comps.enumerated() {
                path = path.isEmpty ? comp : path + "/" + comp
                let isDir = i < comps.count - 1
                if let existing = node.children.first(where: { $0.name == comp }) {
                    node = existing
                } else {
                    let child = FileTreeNode(name: comp, fullPath: path, isDirectory: isDir)
                    node.children.append(child)
                    node = child
                }
            }
            node.isDirectory = false
            if let stages = conflictByPath[e.path] {
                node.conflictStages = stages
            }
        }
        func sort(_ n: FileTreeNode) {
            n.children.sort { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
                return a.name < b.name
            }
            for c in n.children { sort(c) }
        }
        sort(root)
        return root
    }

    // MARK: NSOutlineView

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? FileTreeNode { return node.children.count }
        return fileTree == nil ? 0 : 1
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? FileTreeNode { return node.children[index] }
        return fileTree!
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileTreeNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileTreeNode else { return nil }
        let cellID = NSUserInterfaceItemIdentifier("fileCell")
        let cell = outlineView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = cellID
        let label: NSTextField
        if let tf = cell.textField {
            label = tf
        } else {
            label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.textField = label
        }
        label.font = .systemFont(ofSize: 12)
        let icon = node.isDirectory ? "📁 " : "📄 "
        if node.conflictStages.isEmpty {
            label.stringValue = icon + node.name
            label.textColor = .labelColor
        } else {
            label.stringValue = icon + node.name + "  🔶 " + L10n.tr("scaffold.conflictDetail", node.conflictStages.joined(separator: "→"))
            label.textColor = .systemOrange
        }
        return cell
    }

    // MARK: 生成

    @objc private func generateTapped(_ sender: Any?) {
        guard let p = plan, !isGenerating else { return }
        if !p.isValid {
            updateStatus(L10n.tr("scaffold.failed", L10n.tr("scaffold.invalidParams")))
            return
        }
        guard !p.targetRoot.isEmpty else { return }

        // 9.1：目标目录已存在且非空 → 确认弹窗（覆盖 + 备份）
        if directoryExistsAndNotEmpty(p.targetRoot) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.tr("scaffold.confirmOverwriteTitle")
            alert.informativeText = L10n.tr("scaffold.confirmOverwriteMessage")
            alert.addButton(withTitle: L10n.tr("scaffold.confirmOverwriteOK"))
            alert.addButton(withTitle: L10n.tr("btn.cancel"))
            guard let win = view.window else { return }
            alert.beginSheetModal(for: win) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.runGenerate(p)
            }
        } else {
            runGenerate(p)
        }
    }

    private func directoryExistsAndNotEmpty(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return false }
        return ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).count > 0
    }

    private func runGenerate(_ p: ScaffoldPlan.Result) {
        isGenerating = true
        updateGenerateEnabled(p)
        statusBar.isHidden = false
        statusSpinner.startAnimation(nil)
        updateStatus(L10n.tr("scaffold.generating"))

        let options = ScaffoldApplier.Options(backupConflicts: Self.backupConflicts())
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = ScaffoldApplier.apply(plan: p, options: options)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isGenerating = false
                self.statusSpinner.stopAnimation(nil)
                self.lastApply = result
                self.updateGenerateEnabled(p)
                if result.written.isEmpty {
                    self.updateStatus(L10n.tr("scaffold.failed", result.commandResults.first?.error ?? "unknown"))
                } else {
                    var msg = L10n.tr("scaffold.done")
                    let failed = result.commandResults.filter { $0.exitCode != nil && $0.exitCode != 0 }
                    if !failed.isEmpty {
                        msg += "  " + L10n.tr("scaffold.notGitInit", failed.first?.command ?? "")
                    }
                    self.updateStatus(msg)
                }
                // 生成成功后，best-effort 把新项目登记为 dsh web 工作区（幂等；服务未就绪则跳过）；
                // 新建工作区时还会顺带创建一个空 session，dsh web 立即显示可用会话。
                if let port = self.serverReadyPort, result.written.isEmpty == false {
                    let root = p.targetRoot
                    DispatchQueue.global(qos: .utility).async {
                        ScaffoldWorkspaceRPC.ensure(port: port, path: root)
                    }
                }
                self.refreshPlan()
            }
        }
    }

    private func updateStatus(_ text: String) {
        statusLabel.text = text
        statusBar.isHidden = text.isEmpty
    }

    // MARK: 打开目录

    private func targetURL() -> URL? {
        guard let p = plan, !p.targetRoot.isEmpty else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p.targetRoot, isDirectory: &isDir) else { return nil }
        return URL(fileURLWithPath: p.targetRoot)
    }

    private func openTargetDir() {
        if let url = targetURL() {
            NSWorkspace.shared.open(url)
        } else if let dir = currentWorkspaceDir {
            openDir(dir)
        }
    }

    private func revealInFinder() {
        if let url = targetURL() {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if let dir = currentWorkspaceDir {
            revealDir(dir)
        }
    }

    // MARK: 环节管理设置（右上角 ⚙）

    private func buildSettingsViews() {
        // —— 设置视图：头部（返回 + 标题 + 新建环节） + 滚动列表 + footer ——
        let settingsContainer = NSView()
        settingsContainer.translatesAutoresizingMaskIntoConstraints = false
        settingsContainer.wantsLayer = true
        settingsContainer.layer?.masksToBounds = true

        settingsHeader.kind = .window
        settingsHeader.translatesAutoresizingMaskIntoConstraints = false
        settingsTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        settingsTitleLabel.lineBreakMode = .byTruncatingTail
        settingsTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        settingsTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        let backBtn = ActionButton.make(title: "‹ " + L10n.tr("scaffold.back"))
        backBtn.bezelStyle = .rounded
        backBtn.controlSize = .small
        backBtn.onAction = { [weak self] in self?.toggleSettings() }
        let newBtn = ActionButton.make(title: L10n.tr("scaffold.newStage"))
        newBtn.bezelStyle = .rounded
        newBtn.controlSize = .small
        newBtn.onAction = { [weak self] in self?.beginNewStage() }
        settingsHeader.addSubview(backBtn)
        settingsHeader.addSubview(settingsTitleLabel)
        settingsHeader.addSubview(newBtn)
        NSLayoutConstraint.activate([
            backBtn.leadingAnchor.constraint(equalTo: settingsHeader.leadingAnchor, constant: 10),
            backBtn.centerYAnchor.constraint(equalTo: settingsHeader.centerYAnchor),
            settingsTitleLabel.leadingAnchor.constraint(equalTo: backBtn.trailingAnchor, constant: 10),
            settingsTitleLabel.centerYAnchor.constraint(equalTo: settingsHeader.centerYAnchor),
            settingsTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: newBtn.leadingAnchor, constant: -8),
            newBtn.trailingAnchor.constraint(equalTo: settingsHeader.trailingAnchor, constant: -10),
            newBtn.centerYAnchor.constraint(equalTo: settingsHeader.centerYAnchor),
            settingsHeader.heightAnchor.constraint(equalToConstant: 36),
        ])

        settingsStack.orientation = .vertical
        settingsStack.alignment = .leading
        settingsStack.spacing = 8
        settingsStack.edgeInsets = NSEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        settingsStack.translatesAutoresizingMaskIntoConstraints = false
        settingsDoc = FlippedWorkspaceView()
        settingsDoc.translatesAutoresizingMaskIntoConstraints = false
        settingsDoc.addSubview(settingsStack)
        NSLayoutConstraint.activate([
            settingsStack.topAnchor.constraint(equalTo: settingsDoc.topAnchor),
            settingsStack.leadingAnchor.constraint(equalTo: settingsDoc.leadingAnchor),
            settingsStack.widthAnchor.constraint(equalTo: settingsDoc.widthAnchor),
        ])
        settingsScroll.documentView = settingsDoc
        settingsScroll.hasVerticalScroller = true
        settingsScroll.autohidesScrollers = true
        settingsScroll.drawsBackground = false
        settingsScroll.translatesAutoresizingMaskIntoConstraints = false

        settingsFooterLabel.font = .systemFont(ofSize: 11)
        settingsFooterLabel.textColor = .secondaryLabelColor
        settingsFooterLabel.lineBreakMode = .byTruncatingTail
        settingsFooterLabel.maximumNumberOfLines = 2
        settingsFooterLabel.translatesAutoresizingMaskIntoConstraints = false

        settingsContainer.addSubview(settingsHeader)
        settingsContainer.addSubview(settingsScroll)
        settingsContainer.addSubview(settingsFooterLabel)
        NSLayoutConstraint.activate([
            settingsHeader.topAnchor.constraint(equalTo: settingsContainer.topAnchor),
            settingsHeader.leadingAnchor.constraint(equalTo: settingsContainer.leadingAnchor),
            settingsHeader.trailingAnchor.constraint(equalTo: settingsContainer.trailingAnchor),
            settingsScroll.topAnchor.constraint(equalTo: settingsHeader.bottomAnchor),
            settingsScroll.leadingAnchor.constraint(equalTo: settingsContainer.leadingAnchor),
            settingsScroll.trailingAnchor.constraint(equalTo: settingsContainer.trailingAnchor),
            settingsFooterLabel.topAnchor.constraint(equalTo: settingsScroll.bottomAnchor, constant: 6),
            settingsFooterLabel.leadingAnchor.constraint(equalTo: settingsContainer.leadingAnchor, constant: 12),
            settingsFooterLabel.trailingAnchor.constraint(equalTo: settingsContainer.trailingAnchor, constant: -12),
            settingsFooterLabel.bottomAnchor.constraint(equalTo: settingsContainer.bottomAnchor, constant: -8),
        ])
        settingsView = settingsContainer

        // —— 编辑器视图：头部（返回 + 标题 + 保存） + ID 行 + YAML 文本区 + 错误/提示 ——
        editorView.translatesAutoresizingMaskIntoConstraints = false
        editorView.wantsLayer = true
        editorView.layer?.masksToBounds = true

        // —— 单文件编辑器（Files 风格）：头部 + 文件标签页 + CodeEditorView ——
        let editorHeader = DynamicFillView()
        editorHeader.kind = .window
        editorHeader.translatesAutoresizingMaskIntoConstraints = false
        editorTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        editorTitleLabel.lineBreakMode = .byTruncatingTail
        editorTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        editorTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        let editorBack = ActionButton.make(title: "‹ " + L10n.tr("scaffold.back"))
        editorBack.bezelStyle = .rounded
        editorBack.controlSize = .small
        editorBack.onAction = { [weak self] in self?.closeEditor() }
        let newTemplateBtn = ActionButton.make(title: L10n.tr("scaffold.newTemplate"))
        newTemplateBtn.bezelStyle = .rounded
        newTemplateBtn.controlSize = .small
        newTemplateBtn.onAction = { [weak self] in self?.newTemplateFile() }
        let saveBtn = ActionButton.make(title: L10n.tr("scaffold.save"))
        saveBtn.bezelStyle = .rounded
        saveBtn.controlSize = .small
        saveBtn.onAction = { [weak self] in self?.saveStageEditor() }
        saveBtn.isEnabled = false
        editorSaveBtn = saveBtn
        editorHeader.addSubview(editorBack)
        editorHeader.addSubview(editorTitleLabel)
        editorHeader.addSubview(newTemplateBtn)
        editorHeader.addSubview(saveBtn)
        NSLayoutConstraint.activate([
            editorBack.leadingAnchor.constraint(equalTo: editorHeader.leadingAnchor, constant: 10),
            editorBack.centerYAnchor.constraint(equalTo: editorHeader.centerYAnchor),
            editorTitleLabel.leadingAnchor.constraint(equalTo: editorBack.trailingAnchor, constant: 10),
            editorTitleLabel.centerYAnchor.constraint(equalTo: editorHeader.centerYAnchor),
            editorTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: newTemplateBtn.leadingAnchor, constant: -8),
            newTemplateBtn.trailingAnchor.constraint(equalTo: saveBtn.leadingAnchor, constant: -6),
            newTemplateBtn.centerYAnchor.constraint(equalTo: editorHeader.centerYAnchor),
            saveBtn.trailingAnchor.constraint(equalTo: editorHeader.trailingAnchor, constant: -10),
            saveBtn.centerYAnchor.constraint(equalTo: editorHeader.centerYAnchor),
            editorHeader.heightAnchor.constraint(equalToConstant: 36),
        ])

        // 文件标签页栏（横向滚动，镜像 Files 面板 tab bar：fileStack 即 documentView）
        editorFileStack.orientation = .horizontal
        editorFileStack.spacing = 6
        editorFileStack.alignment = .centerY
        editorFileStack.distribution = .gravityAreas
        editorFileStack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        editorFileStack.translatesAutoresizingMaskIntoConstraints = false
        editorFileBar.documentView = editorFileStack
        editorFileBar.hasHorizontalScroller = true
        editorFileBar.hasVerticalScroller = false
        editorFileBar.drawsBackground = false
        editorFileBar.scrollerStyle = .overlay
        editorFileBar.autohidesScrollers = true
        editorFileBar.translatesAutoresizingMaskIntoConstraints = false

        let fileBarUnderline = NSBox()
        fileBarUnderline.boxType = .separator
        fileBarUnderline.translatesAutoresizingMaskIntoConstraints = false

        // 内容区：CodeEditorView 嵌入（行号槽 + 语法高亮 + 撤销）。
        // masksToBounds：约束 CodeEditorView 内容不得越界向上覆盖编辑器头部/文件标签栏。
        editorContent.translatesAutoresizingMaskIntoConstraints = false
        editorContent.wantsLayer = true
        editorContent.layer?.masksToBounds = true

        editorErrorLabel.font = .systemFont(ofSize: 11)
        editorErrorLabel.textColor = .systemRed
        editorErrorLabel.lineBreakMode = .byWordWrapping
        editorErrorLabel.maximumNumberOfLines = 3
        editorErrorLabel.translatesAutoresizingMaskIntoConstraints = false

        editorHintLabel.font = .systemFont(ofSize: 11)
        editorHintLabel.textColor = .secondaryLabelColor
        editorHintLabel.lineBreakMode = .byWordWrapping
        editorHintLabel.maximumNumberOfLines = 3
        editorHintLabel.translatesAutoresizingMaskIntoConstraints = false

        let editorFinderBtn = ActionButton.make(title: L10n.tr("scaffold.openInFinder"))
        editorFinderBtn.bezelStyle = .rounded
        editorFinderBtn.controlSize = .small
        editorFinderBtn.onAction = { [weak self] in self?.revealUserStages() }

        editorView.addSubview(editorHeader)
        editorView.addSubview(editorFileBar)
        editorView.addSubview(fileBarUnderline)
        editorView.addSubview(editorContent)
        editorView.addSubview(editorErrorLabel)
        editorView.addSubview(editorHintLabel)
        editorView.addSubview(editorFinderBtn)
        NSLayoutConstraint.activate([
            editorHeader.topAnchor.constraint(equalTo: editorView.topAnchor),
            editorHeader.leadingAnchor.constraint(equalTo: editorView.leadingAnchor),
            editorHeader.trailingAnchor.constraint(equalTo: editorView.trailingAnchor),
            editorFileBar.topAnchor.constraint(equalTo: editorHeader.bottomAnchor),
            editorFileBar.leadingAnchor.constraint(equalTo: editorView.leadingAnchor),
            editorFileBar.trailingAnchor.constraint(equalTo: editorView.trailingAnchor),
            editorFileBar.heightAnchor.constraint(equalToConstant: 28),
            editorFileStack.leadingAnchor.constraint(equalTo: editorFileBar.contentView.leadingAnchor),
            editorFileStack.topAnchor.constraint(equalTo: editorFileBar.contentView.topAnchor),
            editorFileStack.bottomAnchor.constraint(equalTo: editorFileBar.contentView.bottomAnchor),
            editorFileStack.widthAnchor.constraint(greaterThanOrEqualTo: editorFileBar.contentView.widthAnchor),
            fileBarUnderline.topAnchor.constraint(equalTo: editorFileBar.bottomAnchor),
            fileBarUnderline.leadingAnchor.constraint(equalTo: editorView.leadingAnchor),
            fileBarUnderline.trailingAnchor.constraint(equalTo: editorView.trailingAnchor),
            editorContent.topAnchor.constraint(equalTo: fileBarUnderline.bottomAnchor, constant: 8),
            editorContent.leadingAnchor.constraint(equalTo: editorView.leadingAnchor, constant: 12),
            editorContent.trailingAnchor.constraint(equalTo: editorView.trailingAnchor, constant: -12),
            editorErrorLabel.topAnchor.constraint(equalTo: editorContent.bottomAnchor, constant: 6),
            editorErrorLabel.leadingAnchor.constraint(equalTo: editorView.leadingAnchor, constant: 12),
            editorErrorLabel.trailingAnchor.constraint(equalTo: editorView.trailingAnchor, constant: -12),
            editorHintLabel.topAnchor.constraint(equalTo: editorErrorLabel.bottomAnchor, constant: 2),
            editorHintLabel.leadingAnchor.constraint(equalTo: editorView.leadingAnchor, constant: 12),
            editorHintLabel.trailingAnchor.constraint(equalTo: editorView.trailingAnchor, constant: -12),
            editorFinderBtn.topAnchor.constraint(equalTo: editorHintLabel.bottomAnchor, constant: 8),
            editorFinderBtn.leadingAnchor.constraint(equalTo: editorView.leadingAnchor, constant: 12),
            editorFinderBtn.bottomAnchor.constraint(equalTo: editorView.bottomAnchor, constant: -10),
        ])

        contentContainer.addSubview(settingsView)
        contentContainer.addSubview(editorView)
        NSLayoutConstraint.activate([
            settingsView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            settingsView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            settingsView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            settingsView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            editorView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            editorView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            editorView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            editorView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        settingsView.isHidden = true
        editorView.isHidden = true
    }

    /// 右上角 ⚙：开关环节管理设置视图。
    private func toggleSettings() {
        if settingsActive {
            hideSettings()
        } else {
            showSettings()
        }
    }

    private func showSettings() {
        settingsActive = true
        settingsButton?.showsBackground = true
        toolbarView?.isHidden = true
        railView?.isHidden = true
        toolbarUnderlineView?.isHidden = true
        for v in [workspaceStepView, targetStepView, stagesStepView, paramsStepView, previewStepView] {
            v?.isHidden = true
        }
        contentTopSettings?.isActive = true
        contentTopNormal?.isActive = false
        contentLeadingSettings?.isActive = true
        contentLeadingNormal?.isActive = false
        rebuildSettingsList()
        settingsView?.isHidden = false
        editorView.isHidden = true
        updateStatus("")
    }

    private func hideSettings() {
        settingsActive = false
        settingsButton?.showsBackground = false
        toolbarView?.isHidden = false
        railView?.isHidden = false
        toolbarUnderlineView?.isHidden = false
        settingsView?.isHidden = true
        editorView.isHidden = true
        contentTopSettings?.isActive = false
        contentTopNormal?.isActive = true
        contentLeadingSettings?.isActive = false
        contentLeadingNormal?.isActive = true
        if currentStep == .workspace { rebuildWorkspaceStep() }
        setStep(currentStep)
        updateStatus("")
    }

    /// 重建环节管理列表（按有效顺序全量显示，标记内置/自定义）。
    private func rebuildSettingsList() {
        for sub in settingsStack.arrangedSubviews {
            settingsStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        settingsTitleLabel.stringValue = L10n.tr("scaffold.settingsTitle")
        let order = effectiveStageOrder()
        let ordered = catalog.sorted { (order.firstIndex(of: $0.id) ?? Int.max) < (order.firstIndex(of: $1.id) ?? Int.max) }
        for (i, stage) in ordered.enumerated() {
            let row = StageSettingsRow(stage: stage,
                                       isModifiedBuiltin: builtinIDs.contains(stage.id),
                                       isFirst: i == 0,
                                       isLast: i == ordered.count - 1)
            row.onEdit = { [weak self] in self?.beginEditStage(stage.id) }
            row.onRestore = { [weak self] in self?.confirmRestoreStage(stage.id) }
            row.onDelete = { [weak self] in self?.confirmDeleteStage(stage.id) }
            row.onMoveUp = { [weak self] in self?.moveStage(stage.id, delta: -1) }
            row.onMoveDown = { [weak self] in self?.moveStage(stage.id, delta: 1) }
            settingsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: settingsStack.widthAnchor).isActive = true
        }
        if catalog.isEmpty {
            let empty = NSTextField(labelWithString: L10n.tr("scaffold.catalogEmpty"))
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            settingsStack.addArrangedSubview(empty)
        }
        settingsFooterLabel.stringValue = L10n.tr("scaffold.settingsFooter", StageCatalogLoader.userStagesDir())
        // 文档帧 = stack 的 fitting 尺寸：否则首轮布局后文档高度陈旧（clip 高度/0），
        // 列表渲染出来但超出文档 bounds 的区域 hitTest 失败 → 行内按钮不可点击。
        settingsStack.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let fitting = self.settingsStack.fittingSize
            if fitting.height > 0 {
                let w = max(fitting.width, self.settingsScroll.contentView.bounds.width)
                self.settingsStack.setFrameSize(NSSize(width: w, height: fitting.height))
                self.settingsDoc.setFrameSize(NSSize(width: w, height: fitting.height))
            }
            self.view.layoutSubtreeIfNeeded()
        }
    }

    /// 调整环节排序并持久化。
    private func moveStage(_ id: String, delta: Int) {
        var order = effectiveStageOrder()
        guard let from = order.firstIndex(of: id) else { return }
        let to = from + delta
        guard to >= 0, to < order.count else { return }
        order.remove(at: from)
        order.insert(id, at: to)
        UserDefaults.standard.set(order, forKey: Self.stageOrderKey)
        rebuildSettingsList()
        rebuildStageList()
        rebuildParamsStep()
        refreshPlan()
        updateStatus(L10n.tr("scaffold.stageReorderOK"))
    }

    // MARK: 环节编辑（YAML）

    /// 新建环节：预填骨架 YAML（一个文件标签），打开编辑器。
    private func beginNewStage() {
        editorStageID = ""
        editorIsNew = true
        editorTemplatesFrom = nil
        let skeleton = """
        id: my-stage
        name:
          zh: 我的环节
          en: My Stage
        category: foundation
        description:
          zh: 新环节描述（可修改）
          en: New stage description (editable)
        """
        let yamlFile = StageEditorFile(relativePath: "stage.yaml", displayName: "stage.yaml",
                                       loadPath: "", savePath: "")
        yamlFile.isNewFile = true
        yamlFile.initialText = skeleton
        editorFiles = [yamlFile]
        openEditor()
    }

    /// 编辑已有环节：文件标签页 = stage.yaml + templates/ 下所有文件。
    private func beginEditStage(_ id: String) {
        guard let stage = catalog.first(where: { $0.id == id }) else { return }
        editorStageID = id
        editorIsNew = false
        // 内置环节：保存时把 templates/ 复制到用户库；自定义环节已在用户库，无需复制
        editorTemplatesFrom = stage.isCustom ? nil : stage.directory
        let userDir = StageCatalogLoader.userStageDir(id: id)
        var files: [StageEditorFile] = []
        // stage.yaml
        let yamlLoad = (stage.directory as NSString).appendingPathComponent("stage.yaml")
        let yamlSave = (userDir as NSString).appendingPathComponent("stage.yaml")
        files.append(StageEditorFile(relativePath: "stage.yaml", displayName: "stage.yaml",
                                     loadPath: yamlLoad, savePath: yamlSave))
        // templates/ 下文件（立即目录；子目录暂不展开）
        let tplDir = (stage.directory as NSString).appendingPathComponent("templates")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tplDir)) ?? []
        for name in names.sorted() {
            let load = (tplDir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: load, isDirectory: &isDir), !isDir.boolValue else { continue }
            files.append(StageEditorFile(relativePath: "templates/" + name, displayName: name,
                                         loadPath: load,
                                         savePath: (userDir as NSString).appendingPathComponent("templates/" + name)))
        }
        editorFiles = files
        openEditor()
    }

    /// 打开编辑器：重建文件标签栏 + 选中第一个文件（stage.yaml）。
    private func openEditor() {
        editorTitleLabel.stringValue = editorIsNew
            ? L10n.tr("scaffold.editorTitleNew")
            : L10n.tr("scaffold.editorTitleEdit", editorStageID)
        editorErrorLabel.stringValue = ""
        editorHintLabel.stringValue = L10n.tr("scaffold.editorHint")
        rebuildEditorTabs()
        settingsView?.isHidden = true
        editorView.isHidden = false
        editorSelectedTab = 0
        selectEditorFile(index: 0)
    }

    /// 重建文件标签栏（清空并追加全部文件的 tab 按钮）。
    private func rebuildEditorTabs() {
        for sub in editorFileStack.arrangedSubviews {
            editorFileStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        for (i, file) in editorFiles.enumerated() {
            file.tabButton.title = file.isDirty ? file.displayName + " *" : file.displayName
            file.tabButton.state = .off
            file.tabButton.onAction = { [weak self] in self?.selectEditorFile(index: i) }
            editorFileStack.addArrangedSubview(file.tabButton)
        }
    }

    /// 切换文件标签：live editor 复用（未保存编辑不丢失），否则新建 CodeEditorView。
    private func selectEditorFile(index: Int) {
        guard editorFiles.indices.contains(index) else { return }
        editorSelectedTab = index
        for (i, file) in editorFiles.enumerated() {
            file.tabButton.state = (i == index) ? .on : .off
        }
        let file = editorFiles[index]
        // 卸载当前 editor（如有）
        editorContent.subviews.forEach { $0.removeFromSuperview() }
        if let editor = file.editor {
            // tab 与文件固定绑定：live editor 创建后永远复用（内存未保存编辑不丢失）
            embedEditor(editor)
        } else {
            let text = file.isNewFile ? file.initialText : loadFileText(file)
            let ext = (file.relativePath as NSString).pathExtension.lowercased()
            let names: [NSAppearance.Name] = [.darkAqua, .aqua]
            let dark = view.effectiveAppearance.bestMatch(from: names) == .darkAqua
            let editor = CodeEditorView(path: file.savePath, text: text,
                                        language: CodeEditorView.language(forExtension: ext), dark: dark)
            editor.onDirtyChange = { [weak self] (dirty: Bool) in
                file.isDirty = dirty
                self?.refreshTabTitle(file)
                self?.refreshEditorSaveState()
            }
            editor.onSaveError = { [weak self] message in
                self?.editorErrorLabel.stringValue = L10n.tr("scaffold.stageYAMLError", message)
            }
            file.editor = editor
            embedEditor(editor)
        }
        editorErrorLabel.stringValue = ""
        refreshEditorSaveState()
    }

    private func embedEditor(_ editor: CodeEditorView) {
        editor.translatesAutoresizingMaskIntoConstraints = false
        editorContent.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: editorContent.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: editorContent.trailingAnchor),
            editor.topAnchor.constraint(equalTo: editorContent.topAnchor),
            editor.bottomAnchor.constraint(equalTo: editorContent.bottomAnchor),
        ])
    }

    /// 读取文件内容（新建文件返回空串；读取失败返回注释占位）。
    private func loadFileText(_ file: StageEditorFile) -> String {
        guard !file.loadPath.isEmpty else { return "" }
        return (try? String(contentsOfFile: file.loadPath, encoding: .utf8)) ?? "# 读取失败 / read failed"
    }

    /// 刷新标签标题（dirty 标记 *）。
    private func refreshTabTitle(_ file: StageEditorFile) {
        file.tabButton.title = file.isDirty ? file.displayName + " *" : file.displayName
    }

    /// 保存按钮可用性：当前文件有未保存修改时可保存。
    private func refreshEditorSaveState() {
        guard editorFiles.indices.contains(editorSelectedTab) else {
            editorSaveBtn?.isEnabled = false
            return
        }
        editorSaveBtn?.isEnabled = editorFiles[editorSelectedTab].isDirty
    }

    /// 新建模板文件：输入文件名 → 加标签并打开（未落盘，保存时写入用户库）。
    private func newTemplateFile() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("scaffold.newTemplate")
        alert.informativeText = L10n.tr("scaffold.templateNamePrompt")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "README.tmpl"
        alert.accessoryView = input
        alert.addButton(withTitle: L10n.tr("btn.ok"))
        alert.addButton(withTitle: L10n.tr("btn.cancel"))
        guard let win = view.window else { return }
        alert.beginSheetModal(for: win) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains("/"), !name.contains("..") else {
                self.editorErrorLabel.stringValue = L10n.tr("scaffold.templateNameInvalid")
                return
            }
            guard !self.editorFiles.contains(where: { $0.displayName == name }) else {
                self.editorErrorLabel.stringValue = L10n.tr("scaffold.templateNameTaken")
                return
            }
            let userDir = StageCatalogLoader.userStageDir(id: self.editorStageID)
            let file = StageEditorFile(relativePath: "templates/" + name, displayName: name,
                                       loadPath: "",
                                       savePath: (userDir as NSString).appendingPathComponent("templates/" + name))
            file.isNewFile = true
            self.editorFiles.append(file)
            self.rebuildEditorTabs()
            self.selectEditorFile(index: self.editorFiles.count - 1)
        }
    }

    private func closeEditor() {
        editorView.isHidden = true
        settingsView?.isHidden = false
        editorFiles = []
        editorFileStack.arrangedSubviews.forEach { sub in
            editorFileStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        editorContent.subviews.forEach { $0.removeFromSuperview() }
        rebuildSettingsList()
    }

    /// 在 Finder 中打开用户环节库（模板文件 templates/ 由此添加/修改）。
    /// 已保存的环节打开其自身目录；新建未保存时打开环节库根目录。
    private func revealUserStages() {
        let root = StageCatalogLoader.userStagesDir()
        let fm = FileManager.default
        if !fm.fileExists(atPath: root) {
            try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        }
        guard fm.fileExists(atPath: root) else { return }
        var target = root
        if !editorStageID.isEmpty {
            let stageDir = StageCatalogLoader.userStageDir(id: editorStageID)
            if fm.fileExists(atPath: stageDir) { target = stageDir }
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
        updateStatus(L10n.tr("scaffold.settingsFooter", target))
    }

    /// 保存编辑器内容（校验 YAML + id 规则）。
    /// 保存当前文件标签页（Files 风格：保存后留在编辑器，不关闭）。
    private func saveStageEditor() {
        guard editorFiles.indices.contains(editorSelectedTab) else { return }
        let file = editorFiles[editorSelectedTab]

        if file.relativePath == "stage.yaml" {
            saveYamlFile(file)
        } else {
            saveTemplateFile(file)
        }
    }

    /// 保存 stage.yaml：校验 id → 写用户库（内置时 templates 复制跟随）→ 刷新路径与目录。
    private func saveYamlFile(_ file: StageEditorFile) {
        let yaml = file.editor?.text ?? loadFileText(file)
        let parsedID: String
        do {
            parsedID = try StageCatalogLoader.parseStageID(from: yaml)
        } catch {
            editorErrorLabel.stringValue = L10n.tr("scaffold.stageYAMLError", error.localizedDescription)
            return
        }
        guard StageCatalogLoader.validateStageID(parsedID) else {
            editorErrorLabel.stringValue = L10n.tr("scaffold.stageIDInvalid")
            return
        }
        if editorIsNew {
            // 新建：id 必须唯一（目录中不存在 / 目录中未加载）
            let existing = Set(catalog.map { $0.id })
            if existing.contains(parsedID)
                || FileManager.default.fileExists(atPath: StageCatalogLoader.userStageDir(id: parsedID)) {
                editorErrorLabel.stringValue = L10n.tr("scaffold.stageIDTaken", parsedID)
                return
            }
        } else {
            guard parsedID == editorStageID else {
                editorErrorLabel.stringValue = L10n.tr("scaffold.stageIDChanged")
                return
            }
        }
        do {
            try StageCatalogLoader.saveUserStage(id: parsedID, yaml: yaml, templatesFrom: editorTemplatesFrom)
        } catch {
            editorErrorLabel.stringValue = L10n.tr("scaffold.stageYAMLError", error.localizedDescription)
            return
        }
        // 保存后环节转为自定义：id 确定、路径指向用户库、无需再复制内置模板
        let idChanged = (editorStageID != parsedID)
        let becameReal = editorIsNew
        editorStageID = parsedID
        editorIsNew = false
        editorTemplatesFrom = nil
        if idChanged { refreshEditorFilePaths() }
        if becameReal {
            // 新建环节首次保存：标题改为「编辑环节：id」
            editorTitleLabel.stringValue = L10n.tr("scaffold.editorTitleEdit", parsedID)
        }
        file.isDirty = false
        file.editor?.markClean()
        refreshTabTitle(file)
        reloadCatalog()
        updateStatus(L10n.tr("scaffold.stageSaveOK", parsedID))
        refreshEditorSaveState()
    }

    /// 保存模板文件：先确保环节已物化到用户库（内置/新建时），再写回用户库路径。
    private func saveTemplateFile(_ file: StageEditorFile) {
        if editorIsNew {
            // 新建环节尚未确定 id：必须先保存 stage.yaml
            editorErrorLabel.stringValue = L10n.tr("scaffold.saveYamlFirst")
            return
        }
        guard !editorStageID.isEmpty else {
            editorErrorLabel.stringValue = L10n.tr("scaffold.saveYamlFirst")
            return
        }
        // 内置环节（未物化）：先写 stage.yaml 基线 + 复制内置模板到用户库
        let userStageDir = StageCatalogLoader.userStageDir(id: editorStageID)
        if !FileManager.default.fileExists(atPath: userStageDir) {
            guard let yamlFile = editorFiles.first(where: { $0.relativePath == "stage.yaml" }) else { return }
            let yaml = yamlFile.editor?.text ?? loadFileText(yamlFile)
            do {
                try StageCatalogLoader.saveUserStage(id: editorStageID, yaml: yaml,
                                                     templatesFrom: editorTemplatesFrom)
            } catch {
                editorErrorLabel.stringValue = L10n.tr("scaffold.stageYAMLError", error.localizedDescription)
                return
            }
            editorTemplatesFrom = nil
            // 物化后所有文件路径对准用户库（内置来源路径 → 用户库路径）
            refreshEditorFilePaths()
        }
        // 写模板文件（确保 templates/ 目录存在）
        let targetDir = (file.savePath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
            let content = file.editor?.text ?? ""
            try content.write(toFile: file.savePath, atomically: true, encoding: .utf8)
        } catch {
            editorErrorLabel.stringValue = L10n.tr("scaffold.stageYAMLError", error.localizedDescription)
            return
        }
        file.isDirty = false
        file.editor?.markClean()
        refreshTabTitle(file)
        reloadCatalog()
        updateStatus(L10n.tr("scaffold.stageSaveOK", editorStageID + "/" + file.relativePath))
        refreshEditorSaveState()
    }

    /// 环节 id 变化（新建保存）后，把所有文件的写入目标改到新 id 的用户库目录。
    private func refreshEditorFilePaths() {
        let userDir = StageCatalogLoader.userStageDir(id: editorStageID)
        for f in editorFiles {
            f.savePath = (userDir as NSString).appendingPathComponent(f.relativePath)
        }
    }

    // MARK: 恢复 / 删除

    /// 恢复内置：删除用户库覆盖拷贝 → 回到内置版本。
    private func confirmRestoreStage(_ id: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("scaffold.confirmRestoreTitle")
        alert.informativeText = L10n.tr("scaffold.confirmRestoreMessage", stageName(id))
        alert.addButton(withTitle: L10n.tr("scaffold.restoreStage"))
        alert.addButton(withTitle: L10n.tr("btn.cancel"))
        guard let win = view.window else { return }
        alert.beginSheetModal(for: win) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            StageCatalogLoader.removeUserStage(id: id)
            self.reloadCatalog()
            self.updateStatus(L10n.tr("scaffold.stageRestored", stageName(id)))
        }
    }

    /// 删除自定义环节（新建的；已修改内置走恢复）。
    private func confirmDeleteStage(_ id: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("scaffold.confirmDeleteTitle")
        alert.informativeText = L10n.tr("scaffold.confirmDeleteMessage", stageName(id))
        alert.addButton(withTitle: L10n.tr("scaffold.deleteStage"))
        alert.addButton(withTitle: L10n.tr("btn.cancel"))
        guard let win = view.window else { return }
        alert.beginSheetModal(for: win) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            StageCatalogLoader.removeUserStage(id: id)
            self.reloadCatalog()
            self.updateStatus(L10n.tr("scaffold.stageDeleted", stageName(id)))
        }
    }

    /// 环节库变更后全量刷新：加载 + 清理向导状态 + 重建列表/参数/预览/设置列表。
    private func reloadCatalog() {
        let result = StageCatalogLoader.load()
        catalog = result.stages
        catalogErrors = result.errors
        builtinIDs = result.builtinIDs
        let valid = Set(catalog.map { $0.id })
        selection = selection.filter { valid.contains($0) }
        params = params.filter { valid.contains($0.key) }
        rebuildStageList()
        rebuildParamsStep()
        refreshPlan()
        if settingsActive { rebuildSettingsList() }
    }
}


// MARK: - dsh web workspace 注册（生成后把新项目登记为工作区，幂等）

enum ScaffoldWorkspaceRPC {
    private static func call(_ method: String, _ payload: [String: Any],
                             port: Int, timeout: TimeInterval = 6) -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/\(method)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let rpcId = UUID().uuidString
        let body: [String: Any] = ["type": "client-request", "rpcId": rpcId, "method": method, "payload": payload]
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

    private static func canonical(_ p: String) -> String {
        URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// 幂等地把 <path> 登记为 dsh web 工作区：已存在（按 canonical path 匹配）则不创建。
    /// 若确实新建了工作区，顺带在里面创建一个空 session（dsh 会展示为一个可用的新会话）。
    static func ensure(port: Int, path: String) {
        let target = canonical(path)
        var wid: String?
        var created = false
        // 已存在 → 复用，不创建
        if let list = call("workspace.list", [:], port: port),
           let items = list["items"] as? [[String: Any]] {
            for ws in items {
                guard let p = ws["path"] as? String else { continue }
                if canonical(p) == target {
                    wid = ws["workspaceId"] as? String
                    break
                }
            }
        }
        if wid == nil {
            if let value = call("workspace.create", ["path": path], port: port),
               let ws = value["workspace"] as? [String: Any],
               let id = ws["workspaceId"] as? String {
                wid = id
                created = (value["created"] as? Bool) ?? true
            }
        }
        // 新建工作区时，同时创建一个空 session
        if created, let wid = wid {
            _ = call("session.create", ["workspaceId": wid], port: port)
        }
    }
}

