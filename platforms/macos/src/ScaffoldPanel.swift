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

    var name: String { L10n.isZh ? nameZh : nameEn }
    var desc: String { L10n.isZh ? descriptionZh : descriptionEn }
}

// MARK: - StageCatalogLoader（加载/解析/校验，坏清单隔离）

struct StageCatalogLoader {
    struct LoadResult {
        var stages: [ScaffoldStage] = []
        var errors: [String] = []
    }

    /// 搜索链：内置（bundle Resources）→ DSH_SCAFFOLD_STAGES（追加，不覆盖同名）。
    static func searchDirs() -> [String] {
        var dirs: [String] = []
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

    /// 按目录顺序加载；同名 id 先到先得（内置优先，env 追加不覆盖）。坏清单隔离。
    static func load(dirs: [String] = searchDirs()) -> LoadResult {
        var result = LoadResult()
        var seen = Set<String>()
        let fm = FileManager.default
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
                    let stage = try loadStage(from: stageDir)
                    if seen.contains(stage.id) {
                        result.errors.append("\(stage.id): 跳过重复环节（同名已加载）/ duplicate stage skipped")
                    } else {
                        seen.insert(stage.id)
                        result.stages.append(stage)
                    }
                } catch {
                    result.errors.append("\(name): 加载失败：\(error.localizedDescription) / load failed")
                }
            }
        }
        return result
    }

    static func loadStage(from dir: String) throws -> ScaffoldStage {
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
                             directory: dir)
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
                      projectName: String, parentDir: String) -> Result {
        var r = Result()
        r.projectName = projectName
        r.projectSlug = slugify(projectName)
        if !parentDir.isEmpty {
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
            context["ciLint"] = lintCmd.isEmpty ? "echo 'no lint command configured'" : lintCmd
            context["ciTest"] = !testCmd.isEmpty ? testCmd : (!backendTest.isEmpty ? backendTest : "echo 'no test command configured'")
            context["ciBuild"] = !backendBuild.isEmpty ? backendBuild : (!frontendBuild.isEmpty ? frontendBuild : "echo 'no build command configured'")
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
    /// 必填参数（带校验器）的标签引用：值为空时红色，有值恢复次级色。
    var requiredLabels: [String: NSTextField] = [:]

    init(stage: ScaffoldStage, onToggle: @escaping () -> Void) {
        self.stage = stage
        card = ScaffoldStageCard(stage: stage)
        card.onToggle = onToggle

        for param in stage.params {
            // 项目简介（techSummary）移到步骤 1 填写，步骤 3 不再重复显示
            if stage.id == "agents-md" && param.key == "techSummary" { continue }
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
        // 同步字段值（预设/重置时）后再刷新必填高亮
        updateRequiredHighlights()
    }

    /// 从控件读出当前值（供 params 字典）。
    func collectValues() -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in stringControls { out[k] = v.stringValue }
        for (k, v) in selectControls { out[k] = v.selectedItem?.title ?? "" }
        for (k, v) in boolControls { out[k] = (v.state == .on) ? "true" : "false" }
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
        case "generic": return L10n.isZh ? "通用" : "Generic"
        default: return value
        }
    }

    /// 环节在工程中的先后顺序（展示与参数步骤共用；未列出的按目录序排后）。
    private static let stageOrder: [String] = [
        "git-init", "agents-md", "repo-knowledge", "git-conventions", "docs-standards",
        "conventions", "docker", "makefile", "ci-cd", "deploy",
    ]
    private func stageIndex(_ id: String) -> Int {
        Self.stageOrder.firstIndex(of: id) ?? Int.max
    }

    private enum Step: Int, CaseIterable {
        case target = 1, stages = 2, params = 3, preview = 4
        var titleKey: String {
            switch self {
            case .target: return "scaffold.step.target"
            case .stages: return "scaffold.step.stages"
            case .params: return "scaffold.step.params"
            case .preview: return "scaffold.step.preview"
            }
        }
    }
    private var currentStep: Step = .target

    // MARK: 子视图

    private let headerTitle = NSTextField(labelWithString: "")
    private var openButton: CustomIconButton!
    private var finderButton: CustomIconButton!
    private var hideButton: CustomIconButton!

    private let railStack = NSStackView()
    private var stepItems: [ScaffoldStepItem] = []

    private let contentContainer = NSView()
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
        }
        refreshPlan()
        updateStatus("")
    }

    // MARK: 公共 API（AppDelegate 调用）

    /// 面板显示时：加载环节库（幂等）并刷新预览。
    func ensureLoaded() {
        if catalog.isEmpty { loadCatalog() }
        refreshPlan()
    }

    /// dsh web 就绪（M3 深化按钮门控预留）。
    func serverReady(port: Int) {
        serverReadyPort = port
    }

    /// 语言切换后刷新文案。
    func refreshTooltips() {
        openButton?.toolTip = L10n.tr("scaffold.openDirHint")
        finderButton?.toolTip = L10n.tr("scaffold.viewInFinderHint")
        hideButton?.toolTip = L10n.tr("preview.closePanel")
        headerTitle.stringValue = L10n.tr("scaffold.title")
        rebuildPresetButtons()
        rebuildStepRail()
        rebuildStageList()
        rebuildParamsStep()
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
        headerTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        headerTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)

        openButton = CustomIconButton(glyph: .openInApp, tooltip: L10n.tr("scaffold.openDirHint"))
        openButton.onAction = { [weak self] in self?.openTargetDir() }
        finderButton = CustomIconButton(glyph: .reveal, tooltip: L10n.tr("scaffold.viewInFinderHint"))
        finderButton.onAction = { [weak self] in self?.revealInFinder() }
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

        let actions = NSStackView(views: [prevButton, nextButton, openButton, finderButton, hideButton])
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
            header.heightAnchor.constraint(equalToConstant: 44),
        ])

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
        view.addSubview(rail)
        view.addSubview(contentContainer)
        view.addSubview(statusBar)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            rail.topAnchor.constraint(equalTo: header.bottomAnchor),
            rail.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rail.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            contentContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.topAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        buildTargetStep()
        buildStagesStep()
        buildParamsStep()
        buildPreviewStep()
        rebuildStepRail()
        setStep(.target)
    }

    // MARK: 步骤视图

    private func buildTargetStep() {
        let title = NSTextField(labelWithString: L10n.tr("scaffold.step.target"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitle = NSTextField(labelWithString: L10n.tr("scaffold.targetHint"))
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2
        subtitle.lineBreakMode = .byWordWrapping

        // 位置（Location）在最上
        let dirLabel = NSTextField(labelWithString: L10n.tr("scaffold.parentDir"))
        dirLabel.font = .systemFont(ofSize: 13, weight: .medium)
        dirButton.title = L10n.tr("scaffold.pickDir")
        dirButton.bezelStyle = .rounded
        dirButton.controlSize = .regular
        dirButton.font = .systemFont(ofSize: 12)
        dirButton.target = self
        dirButton.action = #selector(pickDirTapped(_:))
        dirButton.translatesAutoresizingMaskIntoConstraints = false
        dirButton.widthAnchor.constraint(equalToConstant: 160).isActive = true

        let dirRow = NSStackView(views: [dirLabel, dirButton])
        dirRow.orientation = .horizontal
        dirRow.spacing = 10
        dirRow.alignment = .centerY
        dirRow.translatesAutoresizingMaskIntoConstraints = false

        // 项目名（= 目录名 说明已由「将创建目录」预览承担，标签不再赘述）
        let projectLabel = NSTextField(labelWithString: L10n.tr("scaffold.projectName"))
        projectLabel.font = .systemFont(ofSize: 13, weight: .medium)
        projectNameField.placeholderString = L10n.tr("scaffold.projectNamePlaceholder")
        projectNameField.font = .systemFont(ofSize: 14)
        projectNameField.controlSize = .large
        projectNameField.target = self
        projectNameField.action = #selector(projectNameChanged(_:))
        projectNameField.translatesAutoresizingMaskIntoConstraints = false
        projectNameField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let nameRow = NSStackView(views: [projectLabel, projectNameField])
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

        let stack = NSStackView(views: [title, subtitle, dirRow, nameRow, summaryRow, targetRootLabel])
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

    private func buildStagesStep() {
        stagesHeader.font = .systemFont(ofSize: 13, weight: .medium)
        stagesHeader.translatesAutoresizingMaskIntoConstraints = false

        // 按目的预设（快捷勾选，不影响自由组合）
        let presetLabel = NSTextField(labelWithString: L10n.tr("scaffold.presetTitle"))
        presetLabel.font = .systemFont(ofSize: 12, weight: .medium)
        presetLabel.textColor = .secondaryLabelColor
        presetLabel.translatesAutoresizingMaskIntoConstraints = false
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
        v.addSubview(presetLabel)
        v.addSubview(presetRow)
        v.addSubview(stageScroll)
        NSLayoutConstraint.activate([
            stagesHeader.topAnchor.constraint(equalTo: v.topAnchor, constant: 14),
            stagesHeader.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            stagesHeader.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -16),
            presetLabel.topAnchor.constraint(equalTo: stagesHeader.bottomAnchor, constant: 10),
            presetLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            presetLabel.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -16),
            presetRow.topAnchor.constraint(equalTo: presetLabel.bottomAnchor, constant: 6),
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
        for item in stepItems {
            guard let step = Step(rawValue: item.number) else { continue }
            switch step {
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
        targetStepView?.isHidden = step != .target
        stagesStepView?.isHidden = step != .stages
        paramsStepView?.isHidden = step != .params
        previewStepView?.isHidden = step != .preview
        // 进入滚动步骤：开启置顶时间窗（布局落定后由 handleRootLayout 执行）
        if step == .stages || step == .params {
            scrollTopDeadline = Date().addingTimeInterval(1.0)
            handleRootLayout()
        }
        // 参数步骤在隐藏期间布局会塌陷（嵌套行零尺寸），进入时强制重建一次
        if step == .params { rebuildParamsStep() }
        updateStepRail()
        updateFooter()
    }

    private func updateFooter() {
        prevButton.isEnabled = currentStep != .target
        if currentStep == .preview {
            nextButton.title = L10n.tr("scaffold.generate")
            nextButton.action = #selector(generateTapped(_:))
            if let p = plan { updateGenerateEnabled(p) }
        } else {
            nextButton.title = L10n.tr("scaffold.next")
            nextButton.action = #selector(nextTapped(_:))
            nextButton.isEnabled = true
        }
    }

    @objc private func prevTapped(_ sender: Any?) {
        guard let prev = Step(rawValue: currentStep.rawValue - 1) else { return }
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
        rebuildStageList()
    }

    private func rebuildPresetButtons() {
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

        let categories = ["foundation", "examples", "collaboration"]
        for cat in categories {
            // 按工程先后顺序排列（未在 stageOrder 中的按目录序排后）
            let stages = catalog.filter { $0.category == cat }
                .sorted { stageIndex($0.id) < stageIndex($1.id) }
            guard !stages.isEmpty else { continue }
            let titleLabel = NSTextField(labelWithString: L10n.tr("scaffold.stageCategory.\(cat)"))
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
        params["agents-md", default: [:]][Self.techSummaryKey] = projectSummaryField.stringValue
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
        // 项目简介在步骤 1 填写，直接带入 agents-md 的 techSummary 参数
        params["agents-md", default: [:]][Self.techSummaryKey] = projectSummaryField.stringValue
        let p = ScaffoldPlan.build(catalog: catalog, selection: selection, params: params,
                                   projectName: projectName, parentDir: parentDir)
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
        guard let url = targetURL() else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealInFinder() {
        guard let url = targetURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
