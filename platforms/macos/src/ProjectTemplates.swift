import Foundation

// MARK: - 项目面板模型层（纯 Foundation，无 AppKit 依赖 —— 可无头单测）
//
// 职责（见 docs/plans/PROJECT_PLAN-project-panel.md）：
//   1. 模板扫描/解析/合并（内置 ∪ 用户，用户同名覆盖内置）
//   2. 占位符渲染（{{var}} / {{folderName}} / {{currentYear}}）
//   3. Dry-run 计划（创建/跳过/覆盖/git/命令）
//   4. 执行（原子写、git init、command 步骤、幂等、路径穿越防护）
//   5. 复制模板（slug 冲突自动后缀）
//
// UI（ProjectPanel.swift）只消费本层，不在本层引入 AppKit。

// MARK: - 模型

struct TemplateVariable: Codable, Equatable {
    var key: String
    var label: String
    var defaultValue: String
    var required: Bool

    enum CodingKeys: String, CodingKey {
        case key, label, required
        case defaultValue = "default"
    }
}

enum TemplateStepType: String, Codable {
    case files, git, command
}

struct TemplateStep: Codable, Equatable {
    var type: TemplateStepType
    var source: String?      // files: files/<source>/ 子目录
    var label: String?       // 勾选项展示
    var overwrite: Bool?     // files
    var branch: String?      // git: 默认 main
    var initialCommit: Bool? // git
    var program: String?     // command
    var args: [String]?      // command

    var displayLabel: String {
        label ?? (type == .files ? source ?? "files" : type.rawValue)
    }
    var gitBranch: String { branch ?? "main" }
    var wantsInitialCommit: Bool { initialCommit ?? false }
    var overwrites: Bool { overwrite ?? false }
}

struct ProjectTemplateManifest: Codable {
    var id: String?
    var name: String
    var description: String
    var variables: [TemplateVariable]
    var steps: [TemplateStep]
}

struct ProjectTemplate {
    let slug: String         // 模板目录名
    let dirPath: String      // 模板目录绝对路径
    let isBuiltin: Bool
    let sourceKey: String    // "builtin" / "user"
    let manifest: ProjectTemplateManifest

    var id: String { manifest.id ?? slug }
    var name: String { manifest.name.isEmpty ? slug : manifest.name }
    var description: String { manifest.description }

    func stepPath(_ step: TemplateStep) -> String {
        let base = (dirPath as NSString).appendingPathComponent("files")
        return (base as NSString).appendingPathComponent(step.source ?? "")
    }
}

// MARK: - 扫描与合并

enum ProjectTemplateStore {

    /// 扫描两个模板根（内置/用户），返回合并后的模板列表（用户同名 slug 覆盖内置）。
    /// 损坏清单的目录跳过（返回 [] 但给出 skippedSlugs 供上层记日志）。
    static func scan(builtinDir: String, userDir: String) -> (templates: [ProjectTemplate], skippedSlugs: [String]) {
        var bySlug: [String: ProjectTemplate] = [:]
        var skipped: [String] = []
        scanDir(builtinDir, isBuiltin: true, into: &bySlug, skipped: &skipped)
        scanDir(userDir, isBuiltin: false, into: &bySlug, skipped: &skipped)
        let ordered = bySlug.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (ordered, skipped)
    }

    private static func scanDir(_ root: String, isBuiltin: Bool, into bySlug: inout [String: ProjectTemplate], skipped: inout [String]) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root) else { return }
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return }
        for entry in entries.sorted() {
            let dir = (root as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            let manifestPath = (dir as NSString).appendingPathComponent("template.json")
            guard fm.fileExists(atPath: manifestPath),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
                  let manifest = try? JSONDecoder().decode(ProjectTemplateManifest.self, from: data) else {
                skipped.append(entry)
                continue
            }
            bySlug[entry] = ProjectTemplate(slug: entry, dirPath: dir, isBuiltin: isBuiltin,
                                            sourceKey: isBuiltin ? "builtin" : "user", manifest: manifest)
        }
    }

    /// 复制模板到用户目录；slug 冲突自动加后缀（foo → foo-2 → foo-3…）。返回新模板 slug。
    static func duplicate(template: ProjectTemplate, into userDir: String) -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: userDir, withIntermediateDirectories: true)
        var slug = template.slug
        var n = 2
        while fm.fileExists(atPath: (userDir as NSString).appendingPathComponent(slug)) {
            slug = "\(template.slug)-\(n)"
            n += 1
        }
        let dest = (userDir as NSString).appendingPathComponent(slug)
        do {
            // 浅复制目录（含 files/ 与 template.json）；不跟随符号链接
            try fm.copyItem(atPath: template.dirPath, toPath: dest)
            return slug
        } catch {
            return nil
        }
    }
}

// MARK: - 占位符

enum TemplatePlaceholders {

    /// 渲染文本中的 {{placeholder}}。内建：folderName / currentYear。
    /// 未知占位符保持原样（并计入 warnings，由调用方提示）。
    static func render(_ text: String, variables: [String: String], folderName: String, warnings: inout [String]) -> String {
        var result = ""
        var rest = text[...]
        while let open = rest.range(of: "{{") {
            result += rest[..<open.lowerBound]
            rest = rest[open.upperBound...]
            guard let close = rest.range(of: "}}") else {
                result += "{{"
                rest = rest[rest.startIndex...]
                continue
            }
            let key = String(rest[..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
            // 自动移除紧跟 {{ 与 }} 的空白：{{ projectName }} 也能匹配
            let normalized = key
            rest = rest[close.upperBound...]
            if let v = variables[normalized] {
                result += v
            } else if normalized == "folderName" {
                result += folderName
            } else if normalized == "currentYear" {
                result += String(Calendar.current.component(.year, from: Date()))
            } else {
                warnings.append(normalized)
                result += "{{" + normalized + "}}"
            }
        }
        result += rest
        return result
    }

    /// 判定是否可做文本占位符替换：UTF-8 可解码且不含 NUL（与 FilePanel.looksLikeText 同思路）。
    static func looksLikeText(_ data: Data) -> Bool {
        guard !data.contains(0) else { return false }
        return String(data: data, encoding: .utf8) != nil
    }
}

// MARK: - 计划（dry-run）

struct PlanFileEntry: Equatable {
    let sourceIndex: Int           // 所属 files step 在 manifest.steps 中的下标
    let relativePath: String       // 相对项目根
    let action: String             // "create" / "skip" / "overwrite"
}

struct GitPlan: Equatable {
    let initRepo: Bool             // 需要 git init
    let initialCommit: Bool
}

struct CommandPlan: Equatable {
    let display: String            // 完整命令行展示
    let program: String
    let args: [String]
}

struct ApplyPlan: Equatable {
    var files: [PlanFileEntry] = []
    var git: GitPlan?
    var commands: [CommandPlan] = []
    var warnings: [String] = []

    var creates: Int { files.filter { $0.action == "create" }.count }
    var skips: Int { files.filter { $0.action == "skip" }.count }
    var overwrites: Int { files.filter { $0.action == "overwrite" }.count }
}

// MARK: - 执行

struct ApplyLogLine: Equatable {
    let ok: Bool
    let text: String
}

struct ApplyResult: Equatable {
    var log: [ApplyLogLine] = []
    var createdPaths: [String] = []
    var cancelled = false
}

// MARK: - 执行器

enum TemplateExecutor {

    /// 规划：计算目标目录下的创建/跳过/覆盖清单与 git/命令动作。enabledSteps = 勾选的步骤下标。
    static func plan(template: ProjectTemplate, targetDir: String,
                     variables: [String: String], enabledSteps: Set<Int>) -> ApplyPlan {
        var plan = ApplyPlan()
        let fm = FileManager.default
        let isRepo = fm.fileExists(atPath: (targetDir as NSString).appendingPathComponent(".git"))

        for (idx, step) in template.manifest.steps.enumerated() where enabledSteps.contains(idx) {
            switch step.type {
            case .files:
                let srcDir = template.stepPath(step)
                guard fm.fileExists(atPath: srcDir) else {
                    plan.warnings.append("template step '\(step.displayLabel)': source \(srcDir) missing")
                    continue
                }
                guard let enumerator = fm.enumerator(atPath: srcDir) else { continue }
                while let rel = enumerator.nextObject() as? String {
                    let fullSrc = (srcDir as NSString).appendingPathComponent(rel)
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: fullSrc, isDirectory: &isDir)
                    if isDir.boolValue { continue }
                    // 路径穿越防护：相对路径不允许包含 ".." 组件
                    let components = rel.split(separator: "/").map(String.init)
                    if components.contains("..") { plan.warnings.append("unsafe path in template: \(rel)"); continue }
                    let target = (targetDir as NSString).appendingPathComponent(rel)
                    if fm.fileExists(atPath: target) {
                        plan.files.append(PlanFileEntry(sourceIndex: idx, relativePath: rel, action: step.overwrites ? "overwrite" : "skip"))
                    } else {
                        plan.files.append(PlanFileEntry(sourceIndex: idx, relativePath: rel, action: "create"))
                    }
                }
            case .git:
                // 已是 git 仓库：整体跳过（不重复 init / 不自动 commit，保持幂等；
                // 既有项目模式也不应代用户提交模板文件）。
                if !isRepo {
                    plan.git = GitPlan(initRepo: true, initialCommit: plan.git?.initialCommit ?? step.wantsInitialCommit)
                }
            case .command:
                guard let program = step.program else { continue }
                let args = step.args ?? []
                let display = ([program] + args).joined(separator: " ")
                plan.commands.append(CommandPlan(display: display, program: program, args: args))
            }
        }
        return plan
    }

    /// 执行计划。同步运行；调用方负责放到后台队列并逐行回调 log。
    /// 返回最终结果；cancelled 标志在步骤间检查（回调可以置位）。
    static func execute(plan: ApplyPlan, template: ProjectTemplate, targetDir: String,
                        variables: [String: String],
                        cancelled: () -> Bool,
                        logLine: (String) -> Void) -> ApplyResult {
        var result = ApplyResult()
        let fm = FileManager.default
        var warnings: [String] = []
        let folderName = (targetDir as NSString).lastPathComponent

        // 1) files
        for entry in plan.files where !cancelled() {
            if entry.action == "skip" { continue }
            guard entry.sourceIndex < template.manifest.steps.count else { continue }
            let srcRoot = template.stepPath(template.manifest.steps[entry.sourceIndex])
            let src = (srcRoot as NSString).appendingPathComponent(entry.relativePath)
            let target = (targetDir as NSString).appendingPathComponent(entry.relativePath)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: src)) else {
                result.log.append(ApplyLogLine(ok: false, text: "读取模板文件失败: \(entry.relativePath)"))
                continue
            }
            var toWrite = data
            if TemplatePlaceholders.looksLikeText(data) {
                if let text = String(data: data, encoding: .utf8) {
                    let rendered = TemplatePlaceholders.render(text, variables: variables, folderName: folderName, warnings: &warnings)
                    toWrite = Data(rendered.utf8)
                }
            }
            do {
                let parent = (target as NSString).deletingLastPathComponent
                try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
                try toWrite.write(to: URL(fileURLWithPath: target), options: .atomic)
                result.log.append(ApplyLogLine(ok: true, text: "创建 \(entry.relativePath)"))
                result.createdPaths.append(entry.relativePath)
            } catch {
                result.log.append(ApplyLogLine(ok: false, text: "写入失败 \(entry.relativePath): \(error.localizedDescription)"))
            }
        }

        // 2) git
        if let git = plan.git, !cancelled() {
            if git.initRepo {
                let initArgs = ["-C", targetDir, "init", "-b", template.manifest.steps.first { $0.type == .git }?.gitBranch ?? "main"]
                if runGit(initArgs, cwd: targetDir) != nil {
                    result.log.append(ApplyLogLine(ok: true, text: "git init (\(initArgs.last ?? "main"))"))
                } else {
                    result.log.append(ApplyLogLine(ok: false, text: "git init 失败"))
                }
            }
            if git.initialCommit {
                _ = runGit(["-C", targetDir, "add", "-A"], cwd: targetDir)
                if runGit(["-C", targetDir, "commit", "-m", "Initial commit"], cwd: targetDir) != nil {
                    result.log.append(ApplyLogLine(ok: true, text: "初始提交完成"))
                } else {
                    result.log.append(ApplyLogLine(ok: false, text: "初始提交失败（无 git 身份或没有变更，不阻塞）"))
                }
            }
        }

        // 3) commands
        for cmd in plan.commands where !cancelled() {
            result.log.append(ApplyLogLine(ok: true, text: "执行: \(cmd.display)"))
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: cmd.program)
            proc.arguments = cmd.args
            proc.currentDirectoryURL = URL(fileURLWithPath: targetDir)
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            do {
                try proc.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    result.log.append(ApplyLogLine(ok: true, text: "完成: \(cmd.display)"))
                } else {
                    let tail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let brief = tail.isEmpty ? "exit \(proc.terminationStatus)" : tail.split(separator: "\n").suffix(3).joined(separator: "\n")
                    result.log.append(ApplyLogLine(ok: false, text: "失败(exit \(proc.terminationStatus)): \(brief)"))
                }
            } catch {
                result.log.append(ApplyLogLine(ok: false, text: "无法启动: \(cmd.display)"))
            }
        }

        if cancelled() { result.cancelled = true }
        for w in warnings { result.log.append(ApplyLogLine(ok: false, text: "提示: 未知占位符 {{" + w + "}} 已保留原样")) }
        return result
    }

    // MARK: - helpers

    private static func runGit(_ args: [String], cwd: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
