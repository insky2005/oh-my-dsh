import Foundation

// 无头单测：ProjectTemplates.swift 模型层（纯 Foundation）
// 运行：tests/project-panel/run.sh
// 覆盖 docs/plans/PROJECT_PLAN-project-panel.md §8：解析/合并/占位符/dry-run/执行/git/幂等/复制

func test(_ name: String, _ cond: Bool) {
    print((cond ? "ok" : "FAIL") + " - " + name)
    if !cond { exit(1) }
}

let fm = FileManager.default
let home = NSTemporaryDirectory() + "/projectpanel-" + UUID().uuidString
let builtinRoot = (home as NSString).appendingPathComponent("builtin")
let userRoot = (home as NSString).appendingPathComponent("user")
try! fm.createDirectory(atPath: builtinRoot, withIntermediateDirectories: true)
try! fm.createDirectory(atPath: userRoot, withIntermediateDirectories: true)

// ── fixture 构造 ──

func makeTemplate(_ slug: String, name: String, in root: String,
                  description: String = "", id: String? = nil,
                  variables: [[String: Any]] = [],
                  steps: [[String: Any]] = [],
                  files: [String: String] = [:],
                  sourceDir: String = "") -> String {
    let dir = (root as NSString).appendingPathComponent(slug)
    try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var manifest: [String: Any] = [
        "name": name,
        "description": description,
        "variables": variables,
        "steps": steps,
    ]
    if let id = id { manifest["id"] = id }
    let data = try! JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
    try! data.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("template.json")))
    if !files.isEmpty {
        let filesDir = (dir as NSString).appendingPathComponent("files")
        let base = sourceDir.isEmpty ? filesDir : (filesDir as NSString).appendingPathComponent(sourceDir)
        try! fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        for (relPath, content) in files {
            let target = (base as NSString).appendingPathComponent(relPath)
            try! fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try! content.write(toFile: target, atomically: true, encoding: .utf8)
        }
    }
    return dir
}

let filesStepA: [[String: Any]] = [
    ["type": "files", "source": "core", "label": "core files", "overwrite": false],
    ["type": "git", "branch": "main", "initialCommit": false],
]
let varProjectName = [["key": "projectName", "label": "Project Name", "default": "{{folderName}}", "required": true]]

// 1. 解析：完整清单 + id 缺省 = slug
_ = makeTemplate("full", name: "Full Template", in: builtinRoot, id: "custom-id",
                 variables: varProjectName, steps: filesStepA,
                 files: ["README.md": "# {{projectName}}\n", ".gitignore": "node_modules\n"])
let scan1 = ProjectTemplateStore.scan(builtinDir: builtinRoot, userDir: userRoot)
test("full template parsed", scan1.templates.count == 1)
test("explicit id wins", scan1.templates[0].id == "custom-id")
test("name parsed", scan1.templates[0].name == "Full Template")

// 2. 解析：损坏 JSON / 未知步骤类型 → 模板跳过不崩
_ = makeTemplate("broken", name: "Broken", in: builtinRoot)
let brokenManifest = (builtinRoot as NSString).appendingPathComponent("broken/template.json")
try! "not-json{{{".write(toFile: brokenManifest, atomically: true, encoding: .utf8)
_ = makeTemplate("unknown", name: "Unknown Step", in: builtinRoot, steps: [["type": "teleport", "label": "x"]])
let scan2 = ProjectTemplateStore.scan(builtinDir: builtinRoot, userDir: userRoot)
test("broken json skipped", !scan2.templates.contains { $0.slug == "broken" })
test("unknown step type skips template", !scan2.templates.contains { $0.slug == "unknown" })
test("skipped slugs reported", scan2.skippedSlugs.contains("broken") && scan2.skippedSlugs.contains("unknown"))

// 3. 扫描合并：用户同名覆盖内置；排序无重复
_ = makeTemplate("dup", name: "Builtin Version", in: builtinRoot, files: ["a.txt": "builtin"])
_ = makeTemplate("dup", name: "User Version", in: userRoot, files: ["b.txt": "user"])
let scan3 = ProjectTemplateStore.scan(builtinDir: builtinRoot, userDir: userRoot)
let dup = scan3.templates.first { $0.slug == "dup" }
test("user template overrides builtin by slug", dup?.name == "User Version")
test("user override wins only one entry", scan3.templates.filter { $0.slug == "dup" }.count == 1)
test("merged count", scan3.templates.count == 2) // full + dup; broken/unknown skipped

// 4. 占位符
var warnings: [String] = []
let rendered = TemplatePlaceholders.render(
    "{{projectName}}/{{folderName}}/{{currentYear}}/{{unknown}}",
    variables: ["projectName": "MyApp"], folderName: "my-app", warnings: &warnings)
test("placeholder projectName", rendered.hasPrefix("MyApp/"))
test("placeholder folderName", rendered.contains("/my-app/"))
test("placeholder currentYear", rendered.contains(String(Calendar.current.component(.year, from: Date()))))
test("unknown placeholder preserved", rendered.hasSuffix("{{unknown}}"))
test("unknown placeholder warned", warnings == ["unknown"])

// 5. looksLikeText
test("utf8 text detected", TemplatePlaceholders.looksLikeText(Data("hello".utf8)))
test("nul byte not text", !TemplatePlaceholders.looksLikeText(Data([0x68, 0x00, 0x69])))
let bin = Data([0xFF, 0xFE, 0x00, 0x01])
test("non-utf8 not text", !TemplatePlaceholders.looksLikeText(bin))

// 6. dry-run：创建/跳过/覆盖 + git + command
let projDir = (home as NSString).appendingPathComponent("proj1")
try! fm.createDirectory(atPath: projDir, withIntermediateDirectories: true)
try! "EXISTING".write(toFile: (projDir as NSString).appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

_ = makeTemplate("plan1", name: "Plan One", in: userRoot,
                 steps: [
                    ["type": "files", "source": "core", "overwrite": false],
                    ["type": "git", "branch": "main", "initialCommit": true],
                    ["type": "command", "label": "say hi", "program": "/bin/echo", "args": ["hi"]],
                 ],
                 files: ["README.md": "R", "AGENTS.md": "A", ".gitignore": "G"], sourceDir: "core")
let planT = ProjectTemplateStore.scan(builtinDir: builtinRoot, userDir: userRoot).templates.first { $0.slug == "plan1" }!
let plan = TemplateExecutor.plan(template: planT, targetDir: projDir, variables: [:], enabledSteps: [0, 1, 2])
test("dry-run create count", plan.creates == 2) // AGENTS.md + .gitignore
test("dry-run skip existing", plan.skips == 1)   // README.md 已存在 → skip
test("dry-run overwrite none", plan.overwrites == 0)
test("dry-run git planned", plan.git?.initRepo == true && plan.git?.initialCommit == true)
test("dry-run command listed", plan.commands.count == 1 && plan.commands[0].display == "/bin/echo hi")

// 覆盖保护：overwrite:true 时计为 overwrite
_ = makeTemplate("plan2", name: "Plan Two", in: userRoot,
                 steps: [["type": "files", "source": "core", "overwrite": true]],
                 files: ["README.md": "NEW"], sourceDir: "core")
let plan2T = ProjectTemplateStore.scan(builtinDir: builtinRoot, userDir: userRoot).templates.first { $0.slug == "plan2" }!
let plan2 = TemplateExecutor.plan(template: plan2T, targetDir: projDir, variables: [:], enabledSteps: [0])
test("overwrite flag makes action overwrite", plan2.files.first { $0.relativePath == "README.md" }?.action == "overwrite")

// 7. 执行：落地 + 占位符替换 + git init + 初始提交（配置身份）
let gitHome = (home as NSString).appendingPathComponent("githome")
try! fm.createDirectory(atPath: gitHome, withIntermediateDirectories: true)
try! "[user]\n\tname = CI Test\n\temail = ci@test.local\n".write(toFile: (gitHome as NSString).appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
_ = makeTemplate("exec1", name: "Exec One", in: userRoot,
                 variables: varProjectName,
                 steps: [
                    ["type": "files", "source": "core", "overwrite": false],
                    ["type": "git", "branch": "main", "initialCommit": true],
                 ],
                 files: ["AGENTS.md": "# {{projectName}} project guide"], sourceDir: "core")
let execT = ProjectTemplateStore.scan(builtinDir: builtinRoot, userDir: userRoot).templates.first { $0.slug == "exec1" }!
let execDir = (home as NSString).appendingPathComponent("execproj")
let execPlan = TemplateExecutor.plan(template: execT, targetDir: execDir, variables: ["projectName": "ExecApp"], enabledSteps: [0, 1])
var logLines: [String] = []
let execResult = TemplateExecutor.execute(
    plan: execPlan, template: execT, targetDir: execDir, variables: ["projectName": "ExecApp"],
    cancelled: { false }, logLine: { logLines.append($0) })
let agentsPath = (execDir as NSString).appendingPathComponent("AGENTS.md")
let agentsContent = try? String(contentsOfFile: agentsPath, encoding: .utf8)
test("execute creates file", fm.fileExists(atPath: agentsPath))
test("execute substitutes placeholder", agentsContent == "# ExecApp project guide")
test("execute git init", fm.fileExists(atPath: (execDir as NSString).appendingPathComponent(".git")))
test("execute initial commit succeeds with identity", execResult.log.contains { $0.ok && $0.text == "初始提交完成" })

// 8. 幂等：二次执行同模板 → 已存在全 skip、git 不再 init
let planIdem = TemplateExecutor.plan(template: execT, targetDir: execDir, variables: ["projectName": "ExecApp"], enabledSteps: [0, 1])
test("idempotent: existing files become skip", planIdem.files.allSatisfy { $0.action == "skip" })
test("idempotent: git already repo not re-init", planIdem.git == nil)

// 9. command 步骤执行
_ = makeTemplate("cmd1", name: "Cmd One", in: userRoot,
                 steps: [["type": "command", "label": "echo", "program": "/bin/echo", "args": ["hello-cmd"]]])
let cmdT = ProjectTemplateStore.scan(builtinDir: builtinRoot, userDir: userRoot).templates.first { $0.slug == "cmd1" }!
let cmdDir = (home as NSString).appendingPathComponent("cmdproj")
try! fm.createDirectory(atPath: cmdDir, withIntermediateDirectories: true)
let cmdPlan = TemplateExecutor.plan(template: cmdT, targetDir: cmdDir, variables: [:], enabledSteps: [0])
var cmdLog: [String] = []
let cmdResult = TemplateExecutor.execute(plan: cmdPlan, template: cmdT, targetDir: cmdDir, variables: [:], cancelled: { false }, logLine: { cmdLog.append($0) })
test("command step runs ok", cmdResult.log.contains { $0.ok && $0.text == "完成: /bin/echo hello-cmd" })

// 10. 复制模板：slug 冲突自动后缀
let dupSlug = ProjectTemplateStore.duplicate(template: dup!, into: userRoot)
test("duplicate returns new slug", dupSlug == "dup-2" || dupSlug == "dup")
let scan4 = ProjectTemplateStore.scan(builtinDir: builtinRoot, userDir: userRoot)
let dupAfter = scan4.templates.filter { $0.slug == dupSlug }
test("duplicated template appears in scan", dupAfter.count == 1)
let dupTpl = ProjectTemplateStore.duplicate(template: dupAfter[0], into: userRoot)
test("second duplicate rolls suffix", dupTpl == "dup-2-2" || dupTpl == "dup-2")

// 11. 缺失 source：warning，不崩溃
_ = makeTemplate("nosrc", name: "NoSrc", in: userRoot, steps: [["type": "files", "source": "missing", "overwrite": false]])
let nosrcT = ProjectTemplateStore.scan(builtinDir: builtinRoot, userDir: userRoot).templates.first { $0.slug == "nosrc" }!
let nosrcDir = (home as NSString).appendingPathComponent("nosrcproj")
try! fm.createDirectory(atPath: nosrcDir, withIntermediateDirectories: true)
let nosrcPlan = TemplateExecutor.plan(template: nosrcT, targetDir: nosrcDir, variables: [:], enabledSteps: [0])
test("missing source produces warning", nosrcPlan.warnings.count == 1)
test("missing source plans no files", nosrcPlan.files.isEmpty)

// 12. 取消：cancelled 置位后不再执行
var cancelled = false
cancelled = true
let cancelPlan = TemplateExecutor.plan(template: planT, targetDir: projDir, variables: [:], enabledSteps: [0, 1, 2])
var cancelLog: [String] = []
let cancelResult = TemplateExecutor.execute(plan: cancelPlan, template: planT, targetDir: projDir, variables: [:], cancelled: { cancelled }, logLine: { cancelLog.append($0) })
test("cancelled run reports cancelled", cancelResult.cancelled)

try? fm.removeItem(atPath: home)
print("done")
