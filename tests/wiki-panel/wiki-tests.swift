// Headless unit tests for the Repo Wiki model layer (WikiPanel.swift).
// Compiled as main.swift together with stubs.swift + WikiPanel.swift.

import AppKit
import Foundation

var failures = 0
var passed = 0

func check(_ cond: Bool, _ name: String, _ detail: String = "") {
    if cond {
        passed += 1
        print("PASS \(name)")
    } else {
        failures += 1
        print("FAIL \(name) \(detail)")
    }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ name: String) {
    check(a == b, name, "expected \(b), got \(a)")
}

func tmpDir(_ name: String) -> String {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("wiki-tests-\(name)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d.path
}

func write(_ path: String, _ content: String) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    try! content.write(toFile: path, atomically: true, encoding: .utf8)
}

func setMtime(_ path: String, _ date: Date) {
    try! FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
}

// MARK: - Frontmatter

let fm1 = WikiFrontmatter.parse("just text\nno frontmatter")
check(fm1.meta.isEmpty, "frontmatter: absent -> empty meta")
eq(fm1.body, "just text\nno frontmatter", "frontmatter: absent -> full body")

let fm2 = WikiFrontmatter.parse("""
---
title: 认证模块
tags: [auth, security]
updated: 2026-08-15T10:00:00Z
sources:
  - src/auth/
  - package.json
manual: true
---
# Body

content
""")
eq(fm2.meta["title"] ?? "", "认证模块", "frontmatter: title")
eq(fm2.meta["tags"] ?? "", "auth security", "frontmatter: tags inline")
eq(fm2.meta["updated"] ?? "", "2026-08-15T10:00:00Z", "frontmatter: updated")
eq(fm2.meta["sources"] ?? "", "src/auth/ package.json", "frontmatter: sources list")
eq(fm2.meta["manual"] ?? "", "true", "frontmatter: manual")
check(fm2.body.hasPrefix("# Body"), "frontmatter: body stripped", fm2.body)

// MARK: - Scanner / stale / backlinks

let root = tmpDir("scan")
let authMd = root + "/modules/auth.md"
write(authMd, """
---
title: 认证
tags: [auth]
updated: 2026-08-10T00:00:00Z
sources: [src/auth]
---
# 认证模块
""")
// index links to modules/auth.md -> backlink
write(root + "/index.md", """
---
title: 索引
updated: 2026-08-10T00:00:00Z
---
# 索引
参见 [认证模块](modules/auth.md)。
""")
// stale: source file newer than updated
let repoRootDir = (root as NSString).deletingLastPathComponent   // tmpDir
let srcFile = repoRootDir + "/src/auth/handler.swift"
write(srcFile, "// newer code\n")
setMtime(srcFile, Date(timeIntervalSince1970: 1_800_000_000))

let idx = WikiScanner.scan(root: root, repoRoot: repoRootDir)
eq(idx.pages.count, 2, "scan: page count")
let indexPage = idx.pages.first { $0.title == "索引" }
let authPage = idx.pages.first { $0.title == "认证" }
check(indexPage != nil, "scan: index page found")
check(authPage != nil, "scan: auth page found")
if let auth = authPage, let index = indexPage {
    check(auth.isStale, "stale: source newer than updated")
    check(!index.isStale, "stale: index not stale (no sources)")
    let back = idx.backlinks[auth.path] ?? []
    check(back.contains(index.path), "backlinks: index -> auth", "backlinks=\(back)")
}

// manual flag
write(root + "/manual.md", "---\ntitle: 手写\nmanual: true\n---\ncontent")
let manualIdx = WikiScanner.scan(root: root, repoRoot: repoRootDir)
let manualPage = manualIdx.pages.first { $0.title == "手写" }
check(manualPage?.manual == true, "scan: manual flag parsed")

// MARK: - Renderer

let rendered = WikiMarkdownRenderer.render(markdown: """
# 标题

第一段 **加粗** 与 *斜体* 与 `code`。

- 项 A
- 项 B

```swift
let x = 1
```

参见 [认证模块](modules/auth.md) 与 [外部](https://example.com)。

软换行
保留
""", wikiRoot: root, pagePath: root + "/index.md")
let text = rendered.string
check(text.contains("标题"), "render: heading text")
check(text.contains("加粗"), "render: bold text")
check(text.contains("斜体"), "render: italic text")
check(text.contains("code"), "render: inline code text")
check(text.contains("项 A"), "render: list item")
check(text.contains("let x = 1"), "render: fenced code")
check(text.contains("软换行\u{2028}保留"), "render: soft newline preserved (U+2028)", "text=\(text)")
check(!text.contains("软换行\n保留"), "render: soft newline not a paragraph break")
check(text.contains("项 A\n• 项 B"), "render: list items on separate lines", "text=\(text)")

// link attributes: internal (dshwiki) + external (https)
var hasInternal = false
var hasExternal = false
rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
    if let url = value as? URL {
        if url.scheme == "dshwiki" {
            hasInternal = hasInternal || url.path == (root as NSString).appendingPathComponent("modules/auth.md")
        } else if url.scheme == "https" {
            hasExternal = true
        }
    }
}
check(hasInternal, "render: internal dshwiki link target")
check(hasExternal, "render: external https link")

// MARK: - WikiPaths

let p1 = WikiPaths.stableHash("/tmp/repo-A")
let p2 = WikiPaths.stableHash("/tmp/repo-A")
eq(p1, p2, "paths: stableHash deterministic")
check(p1.count == 12, "paths: stableHash length 12", p1)
let savedMode = WikiPaths.rootMode
UserDefaults.standard.set("in-repo", forKey: WikiPaths.rootModeKey)
check(WikiPaths.wikiRoot(for: "/tmp/repo-A").hasSuffix(".dsh/wiki"), "paths: in-repo root")
UserDefaults.standard.set("dsh-home", forKey: WikiPaths.rootModeKey)
let home = WikiPaths.wikiRoot(for: "/tmp/repo-A")
check(home.contains("repo-wiki"), "paths: dsh-home root", home)
UserDefaults.standard.set(savedMode, forKey: WikiPaths.rootModeKey)

// MARK: - AGENTS.md registration

let repo = tmpDir("agents")
let agentsPath = repo + "/AGENTS.md"
check(WikiAgentsMD.register(repoRoot: repo), "agents: register")
let once = try! String(contentsOfFile: agentsPath, encoding: .utf8)
check(once.contains("repo-wiki:managed"), "agents: marker present")
check(WikiAgentsMD.register(repoRoot: repo), "agents: register idempotent")
let twice = try! String(contentsOfFile: agentsPath, encoding: .utf8)
eq(once, twice, "agents: idempotent (no duplicate)")
let userContent = "# my instructions\n"
write(repo + "/notes.txt", userContent)
check(WikiAgentsMD.unregister(repoRoot: repo), "agents: unregister")
let after = try! String(contentsOfFile: agentsPath, encoding: .utf8)
check(!after.contains("repo-wiki:managed"), "agents: marker removed")
eq(after, "", "agents: file left empty (no garbage)")

// manual file preserved
write(repo + "/AGENTS.md", "# custom\nkeep me\n")
try! (userContent + "# keep\n").write(toFile: repo + "/AGENTS.md", atomically: true, encoding: .utf8)
check(WikiAgentsMD.register(repoRoot: repo), "agents: register into existing")
let withCustom = try! String(contentsOfFile: agentsPath, encoding: .utf8)
check(withCustom.contains("# my instructions") && withCustom.contains("repo-wiki:managed"), "agents: existing content preserved")
check(WikiAgentsMD.unregister(repoRoot: repo), "agents: unregister again")
let after2 = try! String(contentsOfFile: agentsPath, encoding: .utf8)
check(after2.contains("# my instructions") && !after2.contains("repo-wiki:managed"), "agents: custom content kept after unregister", after2)

print("----")
print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
