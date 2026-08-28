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

// MARK: - Scaffold 面板

/// 面板根视图。镜像 WikiRootView/TerminalRootView 的 layer 合成规避约定
/// （docs/terminal-header-fix.md）：isOpaque=false 强制每个子视图独立合成，
/// 避免不透明内容视图的背景漏到头部按钮上。
final class ScaffoldRootView: NSView {
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
        let color: NSColor = dark ? NSColor(calibratedWhite: 0.28, alpha: 1) : NSColor(calibratedWhite: 0.94, alpha: 1)
        color.setFill()
        dirtyRect.fill()
    }
}

/// 环节列表中的一行：checkbox + 名称 + 描述 + （勾选后展开的）参数表单。
private final class ScaffoldStageRow {
    let stage: ScaffoldStage
    let checkbox: NSButton
    let nameLabel: HeaderLabel
    let descLabel: HeaderLabel
    let paramsStack: NSStackView
    /// 控件：string → NSTextField / select → NSPopUpButton / bool → NSButton
    var stringControls: [String: NSTextField] = [:]
    var selectControls: [String: NSPopUpButton] = [:]
    var boolControls: [String: NSButton] = [:]

    init(stage: ScaffoldStage) {
        self.stage = stage
        checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        checkbox.identifier = NSUserInterfaceItemIdentifier(stage.id)
        checkbox.toolTip = stage.name
        nameLabel = HeaderLabel()
        nameLabel.text = stage.name
        descLabel = HeaderLabel()
        descLabel.text = stage.desc
        paramsStack = NSStackView()
        paramsStack.orientation = .vertical
        paramsStack.alignment = .leading
        paramsStack.spacing = 4
        paramsStack.edgeInsets = NSEdgeInsets(top: 2, left: 24, bottom: 4, right: 4)
        paramsStack.isHidden = true
    }
}

final class ScaffoldPanelController: NSObject {
    /// 根视图，由 setRightPanel 直接挂载为右侧面板。
    let view = ScaffoldRootView()
    var onRequestHide: (() -> Void)?
    /// 提供 dsh web 端口（M3 深化门控预留）。
    var serverPortProvider: (() -> Int)?
    static let minWidth: CGFloat = 320

    // MARK: 子视图

    private let headerTitle = HeaderLabel()
    private var openButton: CustomIconButton!
    private var finderButton: CustomIconButton!
    private var generateButton: NSButton!
    private var hideButton: CustomIconButton!

    private let projectNameField = NSTextField()
    private let dirButton = NSButton()
    private let targetRootLabel = HeaderLabel()
    private var presetButtons: [NSButton] = []

    private let stageScroll = NSScrollView()
    private let stageStack = NSStackView()

    private let previewScroll = NSScrollView()
    private let previewStack = NSStackView()
    private let previewHeaderLabel = HeaderLabel()

    private let statusBar = DynamicFillView()
    private let statusLabel = HeaderLabel()
    private let statusSpinner = NSProgressIndicator()

    // MARK: 状态

    private var catalog: [ScaffoldStage] = []
    private var catalogErrors: [String] = []
    private var stageRows: [String: ScaffoldStageRow] = [:]
    private var selection: [String] = []
    private var params: [String: [String: String]] = [:]
    private var projectName = ""
    private var parentDir = ""
    private var plan: ScaffoldPlan.Result?
    private var lastApply: ScaffoldApplier.Result?
    private var serverReadyPort: Int?
    private var isGenerating = false

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
        generateButton?.title = L10n.tr("scaffold.generate")
        headerTitle.text = L10n.tr("scaffold.title")
        rebuildPresetButtons()
        rebuildStageList()
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
        headerTitle.text = L10n.tr("scaffold.title")
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        headerTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)

        openButton = CustomIconButton(glyph: .openInApp, tooltip: L10n.tr("scaffold.openDirHint"))
        openButton.onAction = { [weak self] in self?.openTargetDir() }
        finderButton = CustomIconButton(glyph: .reveal, tooltip: L10n.tr("scaffold.viewInFinderHint"))
        finderButton.onAction = { [weak self] in self?.revealInFinder() }
        hideButton = CustomIconButton(glyph: .close, tooltip: L10n.tr("preview.closePanel"))
        hideButton.onAction = { [weak self] in self?.onRequestHide?() }

        generateButton = NSButton(title: L10n.tr("scaffold.generate"), target: self, action: #selector(generateTapped(_:)))
        generateButton.bezelStyle = .rounded
        generateButton.controlSize = .small
        generateButton.font = .systemFont(ofSize: 11)
        generateButton.translatesAutoresizingMaskIntoConstraints = false
        generateButton.widthAnchor.constraint(equalToConstant: 72).isActive = true

        let actions = NSStackView(views: [openButton, finderButton, generateButton, hideButton])
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

        // 目标区：项目名 / 位置 / 解析出的目标根 / 预设
        let targetArea = DynamicFillView()
        targetArea.kind = .window
        targetArea.translatesAutoresizingMaskIntoConstraints = false
        targetArea.wantsLayer = true
        targetArea.layer?.masksToBounds = true

        let projectLabel = HeaderLabel()
        projectLabel.text = L10n.tr("scaffold.projectName")
        projectNameField.placeholderString = L10n.tr("scaffold.projectNamePlaceholder")
        projectNameField.font = .systemFont(ofSize: 11)
        projectNameField.controlSize = .small
        projectNameField.target = self
        projectNameField.action = #selector(projectNameChanged(_:))
        projectNameField.translatesAutoresizingMaskIntoConstraints = false

        let dirLabel = HeaderLabel()
        dirLabel.text = L10n.tr("scaffold.parentDir")
        dirButton.title = L10n.tr("scaffold.pickDir")
        dirButton.bezelStyle = .rounded
        dirButton.controlSize = .small
        dirButton.font = .systemFont(ofSize: 11)
        dirButton.target = self
        dirButton.action = #selector(pickDirTapped(_:))
        dirButton.translatesAutoresizingMaskIntoConstraints = false

        let row1 = NSStackView(views: [projectLabel, projectNameField, dirLabel, dirButton])
        row1.orientation = .horizontal
        row1.spacing = 6
        row1.alignment = .centerY
        row1.translatesAutoresizingMaskIntoConstraints = false
        projectNameField.widthAnchor.constraint(equalToConstant: 140).isActive = true
        dirButton.widthAnchor.constraint(equalToConstant: 90).isActive = true

        targetRootLabel.translatesAutoresizingMaskIntoConstraints = false
        targetRootLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let presetRow = NSStackView()
        presetRow.orientation = .horizontal
        presetRow.spacing = 6
        presetRow.translatesAutoresizingMaskIntoConstraints = false
        let presets = ScaffoldPreset.all
        for (idx, preset) in presets.enumerated() {
            let b = NSButton(title: presetTitle(preset.id), target: self, action: #selector(presetTapped(_:)))
            b.tag = idx
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.translatesAutoresizingMaskIntoConstraints = false
            presetRow.addArrangedSubview(b)
            presetButtons.append(b)
        }

        targetArea.addSubview(row1)
        targetArea.addSubview(targetRootLabel)
        targetArea.addSubview(presetRow)
        NSLayoutConstraint.activate([
            row1.topAnchor.constraint(equalTo: targetArea.topAnchor, constant: 6),
            row1.leadingAnchor.constraint(equalTo: targetArea.leadingAnchor, constant: 10),
            row1.trailingAnchor.constraint(lessThanOrEqualTo: targetArea.trailingAnchor, constant: -10),
            targetRootLabel.topAnchor.constraint(equalTo: row1.bottomAnchor, constant: 4),
            targetRootLabel.leadingAnchor.constraint(equalTo: targetArea.leadingAnchor, constant: 10),
            targetRootLabel.trailingAnchor.constraint(lessThanOrEqualTo: targetArea.trailingAnchor, constant: -10),
            presetRow.topAnchor.constraint(equalTo: targetRootLabel.bottomAnchor, constant: 4),
            presetRow.leadingAnchor.constraint(equalTo: targetArea.leadingAnchor, constant: 10),
            presetRow.trailingAnchor.constraint(lessThanOrEqualTo: targetArea.trailingAnchor, constant: -10),
            presetRow.bottomAnchor.constraint(equalTo: targetArea.bottomAnchor, constant: -6),
        ])

        // 环节列表（分组滚动）
        stageStack.orientation = .vertical
        stageStack.alignment = .leading
        stageStack.spacing = 2
        stageStack.translatesAutoresizingMaskIntoConstraints = false
        stageScroll.documentView = stageStack
        stageScroll.hasVerticalScroller = true
        stageScroll.autohidesScrollers = true
        stageScroll.drawsBackground = false
        stageScroll.translatesAutoresizingMaskIntoConstraints = false

        // 预览区
        previewStack.orientation = .vertical
        previewStack.alignment = .leading
        previewStack.spacing = 1
        previewStack.translatesAutoresizingMaskIntoConstraints = false
        previewScroll.documentView = previewStack
        previewScroll.hasVerticalScroller = true
        previewScroll.autohidesScrollers = true
        previewScroll.drawsBackground = false
        previewScroll.translatesAutoresizingMaskIntoConstraints = false

        previewHeaderLabel.translatesAutoresizingMaskIntoConstraints = false

        let previewBox = DynamicFillView()
        previewBox.kind = .window
        previewBox.translatesAutoresizingMaskIntoConstraints = false
        previewBox.wantsLayer = true
        previewBox.layer?.masksToBounds = true
        previewBox.addSubview(previewHeaderLabel)
        previewBox.addSubview(previewScroll)
        NSLayoutConstraint.activate([
            previewHeaderLabel.topAnchor.constraint(equalTo: previewBox.topAnchor, constant: 4),
            previewHeaderLabel.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 10),
            previewHeaderLabel.trailingAnchor.constraint(lessThanOrEqualTo: previewBox.trailingAnchor, constant: -10),
            previewScroll.topAnchor.constraint(equalTo: previewHeaderLabel.bottomAnchor, constant: 2),
            previewScroll.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 6),
            previewScroll.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor, constant: -6),
            previewScroll.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: -4),
        ])

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

        let sep1 = NSBox()
        sep1.boxType = .separator
        sep1.translatesAutoresizingMaskIntoConstraints = false
        let sep2 = NSBox()
        sep2.boxType = .separator
        sep2.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        view.addSubview(targetArea)
        view.addSubview(sep1)
        view.addSubview(stageScroll)
        view.addSubview(sep2)
        view.addSubview(previewBox)
        view.addSubview(statusBar)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            targetArea.topAnchor.constraint(equalTo: header.bottomAnchor),
            targetArea.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            targetArea.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            sep1.topAnchor.constraint(equalTo: targetArea.bottomAnchor),
            sep1.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sep1.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            stageScroll.topAnchor.constraint(equalTo: sep1.bottomAnchor),
            stageScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stageScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            sep2.topAnchor.constraint(equalTo: stageScroll.bottomAnchor),
            sep2.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sep2.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            previewBox.topAnchor.constraint(equalTo: sep2.bottomAnchor),
            previewBox.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewBox.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewBox.heightAnchor.constraint(equalToConstant: 150),

            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.topAnchor.constraint(equalTo: previewBox.bottomAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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

    /// 重建环节分组列表（勾选状态保留）。
    private func rebuildStageList() {
        for sub in stageStack.arrangedSubviews {
            stageStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        stageRows.removeAll()

        let categories = ["foundation", "examples", "collaboration"]
        for cat in categories {
            let stages = catalog.filter { $0.category == cat }
            guard !stages.isEmpty else { continue }
            let titleLabel = HeaderLabel()
            titleLabel.text = L10n.tr("scaffold.stageCategory.\(cat)")
            stageStack.addArrangedSubview(titleLabel)
            for stage in stages {
                let row = makeStageRow(stage)
                stageRows[stage.id] = row
                stageStack.addArrangedSubview(row.paramsStack)
            }
        }
        // 无环节时提示
        if catalog.isEmpty {
            let empty = HeaderLabel()
            empty.text = catalogErrors.isEmpty
                ? L10n.tr("scaffold.catalogEmpty")
                : L10n.tr("scaffold.catalogErrors", catalogErrors.joined(separator: "；"))
            stageStack.addArrangedSubview(empty)
        } else if !catalogErrors.isEmpty {
            let err = HeaderLabel()
            err.text = L10n.tr("scaffold.catalogErrors", catalogErrors.joined(separator: "；"))
            stageStack.addArrangedSubview(err)
        }
    }

    private func makeStageRow(_ stage: ScaffoldStage) -> ScaffoldStageRow {
        let row = ScaffoldStageRow(stage: stage)
        row.checkbox.target = self
        row.checkbox.action = #selector(stageChecked(_:))
        row.checkbox.state = selection.contains(stage.id) ? .on : .off

        let nameDesc = NSStackView(views: [row.nameLabel, row.descLabel])
        nameDesc.orientation = .vertical
        nameDesc.alignment = .leading
        nameDesc.spacing = 0

        let line = NSStackView(views: [row.checkbox, nameDesc])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 4
        line.edgeInsets = NSEdgeInsets(top: 1, left: 6, bottom: 1, right: 4)

        // 参数表单
        for param in stage.params {
            let label = HeaderLabel()
            label.text = param.label
            let controlRow = NSStackView(views: [label])
            controlRow.orientation = .horizontal
            controlRow.spacing = 4
            controlRow.alignment = .centerY

            let currentValue = params[stage.id]?[param.key] ?? param.defaultValue
            if param.type == "bool" {
                let cb = NSButton(checkboxWithTitle: "", target: self, action: #selector(paramBoolChanged(_:)))
                cb.identifier = NSUserInterfaceItemIdentifier("\(stage.id).\(param.key)")
                cb.state = ScaffoldTemplateRenderer.isTruthy(currentValue) ? .on : .off
                row.boolControls[param.key] = cb
                controlRow.addArrangedSubview(cb)
            } else if param.type == "select" {
                let pop = NSPopUpButton(frame: .zero, pullsDown: false)
                pop.addItems(withTitles: param.options)
                if let idx = param.options.firstIndex(of: currentValue) {
                    pop.selectItem(at: idx)
                }
                pop.controlSize = .small
                pop.font = .systemFont(ofSize: 11)
                pop.target = self
                pop.action = #selector(paramSelectChanged(_:))
                pop.identifier = NSUserInterfaceItemIdentifier("\(stage.id).\(param.key)")
                row.selectControls[param.key] = pop
                controlRow.addArrangedSubview(pop)
            } else {
                let field = NSTextField(string: currentValue)
                field.font = .systemFont(ofSize: 11)
                field.controlSize = .small
                field.target = self
                field.action = #selector(paramStringChanged(_:))
                field.identifier = NSUserInterfaceItemIdentifier("\(stage.id).\(param.key)")
                field.translatesAutoresizingMaskIntoConstraints = false
                field.widthAnchor.constraint(equalToConstant: 200).isActive = true
                row.stringControls[param.key] = field
                controlRow.addArrangedSubview(field)
            }
            row.paramsStack.addArrangedSubview(controlRow)
        }
        row.paramsStack.isHidden = !(row.checkbox.state == .on)

        stageStack.addArrangedSubview(line)
        return row
    }

    // MARK: 交互

    @objc private func projectNameChanged(_ sender: Any?) {
        projectName = projectNameField.stringValue
        refreshPlan()
    }

    @objc private func pickDirTapped(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.tr("scaffold.pickDirMessage")
        if let last = UserDefaults.standard.string(forKey: Self.lastDirKey), FileManager.default.fileExists(atPath: last) {
            panel.directoryURL = URL(fileURLWithPath: last)
        }
        if let win = view.window {
            panel.beginSheetModal(for: win) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                self?.setParentDir(url.path)
            }
        }
    }

    @objc private func stageChecked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if sender.state == .on {
            if !selection.contains(id) { selection.append(id) }
        } else {
            selection.removeAll { $0 == id }
        }
        stageRows[id]?.paramsStack.isHidden = sender.state != .on
        refreshPlan()
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
        guard parts.count == 2, let value = sender.selectedItem?.title else { return }
        params[parts[0], default: [:]][parts[1]] = value
        refreshPlan()
    }

    @objc private func paramBoolChanged(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let parts = id.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        params[parts[0], default: [:]][parts[1]] = (sender.state == .on) ? "true" : "false"
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
        // 同步 UI：勾选 + 参数控件
        for (id, row) in stageRows {
            let on = selection.contains(id)
            row.checkbox.state = on ? .on : .off
            row.paramsStack.isHidden = !on
            for (key, field) in row.stringControls {
                field.stringValue = params[id]?[key] ?? row.stage.params.first(where: { $0.key == key })?.defaultValue ?? ""
            }
            for (key, pop) in row.selectControls {
                let val = params[id]?[key] ?? row.stage.params.first(where: { $0.key == key })?.defaultValue ?? ""
                if let idx = row.stage.params.first(where: { $0.key == key })?.options.firstIndex(of: val) {
                    pop.selectItem(at: idx)
                }
            }
            for (key, cb) in row.boolControls {
                let val = params[id]?[key] ?? row.stage.params.first(where: { $0.key == key })?.defaultValue ?? ""
                cb.state = ScaffoldTemplateRenderer.isTruthy(val) ? .on : .off
            }
        }
        refreshPlan()
    }

    // MARK: 规划与预览

    private func refreshPlan() {
        projectName = projectNameField.stringValue
        let p = ScaffoldPlan.build(catalog: catalog, selection: selection, params: params,
                                   projectName: projectName, parentDir: parentDir)
        plan = p
        updateTargetRootLabel(p)
        rebuildPreview(p)
        updateGenerateEnabled(p)
    }

    private func updateTargetRootLabel(_ p: ScaffoldPlan.Result) {
        if p.targetRoot.isEmpty {
            targetRootLabel.text = L10n.tr("scaffold.targetRoot")
        } else {
            targetRootLabel.text = L10n.tr("scaffold.targetRoot") + ": " + p.targetRoot
        }
    }

    private func updateGenerateEnabled(_ p: ScaffoldPlan.Result) {
        let ready = !projectName.isEmpty && !parentDir.isEmpty && p.isValid && !isGenerating
        generateButton?.isEnabled = ready
    }

    private func rebuildPreview(_ p: ScaffoldPlan.Result) {
        for sub in previewStack.arrangedSubviews {
            previewStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }

        // 校验错误 / 渲染错误 / 提示（行内展示）
        for err in p.validationErrors {
            let l = HeaderLabel()
            l.text = "⚠ " + err
            previewStack.addArrangedSubview(l)
        }
        for err in p.stageErrors {
            let l = HeaderLabel()
            l.text = "⛔ " + err
            previewStack.addArrangedSubview(l)
        }
        for hint in p.hints {
            let l = HeaderLabel()
            l.text = "💡 " + hint
            previewStack.addArrangedSubview(l)
        }

        if selection.isEmpty {
            previewHeaderLabel.text = L10n.tr("scaffold.previewEmpty")
            return
        }
        guard !p.validationErrors.isEmpty || !p.stageErrors.isEmpty || !p.entries.isEmpty else {
            previewHeaderLabel.text = L10n.tr("scaffold.previewEmpty")
            return
        }

        previewHeaderLabel.text = L10n.tr("scaffold.previewCount", p.entries.count)
        let conflictPaths = Set(p.conflicts.map { $0.path })
        for entry in p.entries {
            let l = HeaderLabel()
            if conflictPaths.contains(entry.path), let conflict = p.conflicts.first(where: { $0.path == entry.path }) {
                l.text = "🔶 " + entry.path + "  " + L10n.tr("scaffold.conflictDetail", conflict.stageIds.joined(separator: "→"))
            } else {
                l.text = "• " + entry.path
            }
            previewStack.addArrangedSubview(l)
        }
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
