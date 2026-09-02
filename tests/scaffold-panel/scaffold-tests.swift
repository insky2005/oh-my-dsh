// Headless unit tests for the Scaffold Workbench engine (ScaffoldPanel.swift).
// Compiled as main.swift together with stubs.swift + ScaffoldPanel.swift.
// 覆盖 docs/scaffold-workbench-design.md 10.1 的引擎单测清单：
//  stage.yaml 解析与坏清单隔离 / 校验器 / 渲染器 / 规划（冲突、顺序）/ 落盘（备份、state.json）
//  + 端到端 fixture 组合（纯后端 API / jenkins / git-conventions(enforce) / deploy 全选）。

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
        .appendingPathComponent("scaffold-tests-\(name)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d.path
}

func write(_ path: String, _ content: String) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    try! content.write(toFile: path, atomically: true, encoding: .utf8)
}

func read(_ path: String) -> String {
    try! String(contentsOfFile: path, encoding: .utf8)
}

func exists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
}

// MARK: - 内置环节库（端到端）

let builtinDir = ProcessInfo.processInfo.environment["DSH_SCAFFOLD_STAGES"] ?? ""
check(!builtinDir.isEmpty, "env DSH_SCAFFOLD_STAGES set (run.sh)")
let builtin = StageCatalogLoader.load(dirs: [builtinDir])
eq(builtin.stages.count, 10, "catalog: built-in 10 stages")
check(builtin.errors.isEmpty, "catalog: no load errors", builtin.errors.joined(separator: "; "))
let ids = Set(builtin.stages.map { $0.id })
for want in ["git-init", "git-conventions", "agents-md", "docs-standards", "conventions",
             "makefile", "ci-cd", "docker", "deploy", "repo-knowledge"] {
    check(ids.contains(want), "catalog: has stage \(want)")
}
let gitInit = builtin.stages.first { $0.id == "git-init" }!
eq(gitInit.category, "foundation", "catalog: git-init category")
check(gitInit.files.contains { $0.pathTemplate == "README.md" }, "catalog: git-init README.md")
check(gitInit.commands.contains("git init -b main"), "catalog: git-init command")

// MARK: - 坏清单隔离（9.11）

func fixtureCatalog() -> (dir: String, stages: [ScaffoldStage], errors: [String]) {
    let root = tmpDir("catalog")
    write(root + "/good/stage.yaml", """
    id: good
    name: { zh: 好环节, en: Good stage }
    category: foundation
    files:
      - path: hello.txt
        template: templates/hello.tmpl
    """)
    write(root + "/good/templates/hello.tmpl", "hello {{projectSlug}}")
    // 缺 id
    write(root + "/no-id/stage.yaml", """
    name: { zh: 无 id, en: No id }
    category: foundation
    """)
    // files 项缺 template
    write(root + "/bad-file/stage.yaml", """
    id: bad-file
    name: { zh: 坏文件项, en: Bad file item }
    category: foundation
    files:
      - path: x.txt
    """)
    // 非法 YAML
    write(root + "/broken/stage.yaml", "id: broken\nfiles: [unclosed")
    let res = StageCatalogLoader.load(dirs: [root])
    return (root, res.stages, res.errors)
}

let fixture = fixtureCatalog()
eq(fixture.stages.count, 1, "catalog: bad manifests isolated (only good loads)")
check(fixture.stages.first?.id == "good", "catalog: isolated stage is good")
check(fixture.errors.count >= 3, "catalog: 3 bad manifests reported", "\(fixture.errors.count) errors")

// MARK: - 校验器（10.1 正反例）

check(ScaffoldValidators.validate("nonEmpty", value: "x") == nil, "validator nonEmpty: ok")
check(ScaffoldValidators.validate("nonEmpty", value: "   ") != nil, "validator nonEmpty: reject blank")
check(ScaffoldValidators.validate("slug", value: "my-api") == nil, "validator slug: ok")
check(ScaffoldValidators.validate("slug", value: "my api") != nil, "validator slug: reject space")
check(ScaffoldValidators.validate("slug", value: "1abc") == nil, "validator slug: digit start ok")
check(ScaffoldValidators.validate("safePath", value: "a/b/c.txt") == nil, "validator safePath: ok")
check(ScaffoldValidators.validate("safePath", value: "../etc") != nil, "validator safePath: reject ..")
check(ScaffoldValidators.validate("safePath", value: "/abs") != nil, "validator safePath: reject absolute")
check(ScaffoldValidators.validate("safePath", value: "~/x") != nil, "validator safePath: reject home")
check(ScaffoldValidators.validate("javaPackage", value: "com.example.api") == nil, "validator javaPackage: ok")
check(ScaffoldValidators.validate("javaPackage", value: "com.1example") != nil, "validator javaPackage: reject digit segment")
check(ScaffoldValidators.validate("javaPackage", value: "com.class") != nil, "validator javaPackage: reject reserved word")

// MARK: - 渲染器

let ctx = ["name": "demo", "flag": "true", "off": "false", "empty": "", "projectSlug": "my-proj"]
do {
    let r1 = try ScaffoldTemplateRenderer.render("hi {{name}}!", context: ctx)
    eq(r1, "hi demo!", "render: {{var}} replace")
    let r2 = try ScaffoldTemplateRenderer.render("{{#if flag}}YES{{/if}}", context: ctx)
    eq(r2, "YES", "render: {{#if}} true branch")
    let r3 = try ScaffoldTemplateRenderer.render("{{#if off}}NO{{/if}}", context: ctx)
    eq(r3, "", "render: {{#if}} false branch (false)")
    let r4 = try ScaffoldTemplateRenderer.render("{{#if empty}}NO{{/if}}", context: ctx)
    eq(r4, "", "render: {{#if}} false branch (empty)")
    let r5 = try ScaffoldTemplateRenderer.render("{{#if missing}}NO{{/if}}", context: ctx)
    eq(r5, "", "render: {{#if}} false branch (missing key)")
    let r6 = try ScaffoldTemplateRenderer.render("{{{{name}}}}", context: ctx)
    eq(r6, "{{name}}", "render: {{{{ escape")
    let r7 = try ScaffoldTemplateRenderer.render("a }}}} b", context: ctx)
    eq(r7, "a }} b", "render: }}}} escape")
    let r8 = try ScaffoldTemplateRenderer.render("{{name}}-{{projectSlug}}/file.txt", context: ctx)
    eq(r8, "demo-my-proj/file.txt", "render: filename participates")
    // 缺失变量报错
    do {
        _ = try ScaffoldTemplateRenderer.render("{{nope}}", context: ctx)
        check(false, "render: missing variable throws")
    } catch {
        check(true, "render: missing variable throws")
    }
    // 嵌套 if
    let nested = try ScaffoldTemplateRenderer.render("{{#if flag}}A{{#if flag}}B{{/if}}C{{/if}}", context: ctx)
    eq(nested, "ABC", "render: nested {{#if}}")
    // 空值变量渲染为空串（不报错）
    let r9 = try ScaffoldTemplateRenderer.render("[{{empty}}]", context: ctx)
    eq(r9, "[]", "render: empty value renders empty")
} catch {
    check(false, "render: unexpected throw \(error)")
}

// MARK: - 规划（fixture 两环节 + 同路径冲突）

func planFixtureStages() -> [ScaffoldStage] {
    let root = tmpDir("plan")
    write(root + "/one/stage.yaml", """
    id: one
    name: { zh: 环节一, en: Stage one }
    category: foundation
    params:
      - key: who
        type: string
        default: world
    files:
      - path: one.txt
        template: templates/one.tmpl
    """)
    write(root + "/one/templates/one.tmpl", "one {{who}} {{projectSlug}}")
    write(root + "/two/stage.yaml", """
    id: two
    name: { zh: 环节二, en: Stage two }
    category: foundation
    files:
      - path: README.md
        template: templates/two.tmpl
      - path: one.txt
        template: templates/two.tmpl
    """)
    write(root + "/two/templates/two.tmpl", "two {{projectName}}")
    let res = StageCatalogLoader.load(dirs: [root])
    check(res.errors.isEmpty, "plan: fixture loads", res.errors.joined(separator: "; "))
    return res.stages
}

let planStages = planFixtureStages()
var planP: [String: [String: String]] = [:]
planP["one"] = ["who": "agent"]
let plan = ScaffoldPlan.build(catalog: planStages, selection: ["two", "one"], params: planP,
                              projectName: "我的 API 服务", parentDir: "/tmp/scaffold-plan-base")
eq(plan.projectSlug, "api", "plan: Chinese name slugified")
check(plan.targetRoot.hasSuffix("/tmp/scaffold-plan-base/api"), "plan: target root", plan.targetRoot)
eq(plan.entries.count, 3, "plan: 3 entries (two×2 + one×1)")
let conflict = plan.conflicts.first { $0.path == "one.txt" }
check(conflict != nil, "plan: same-path conflict marked")
check(conflict?.stageIds == ["two", "one"], "plan: conflict sources in write order", "\(conflict?.stageIds ?? [])")
// 后写覆盖：entries 中 one 的内容在后
let oneEntry = plan.entries.last { $0.path == "one.txt" }
eq(oneEntry?.content ?? "", "one agent api", "plan: later stage wins content")
check(plan.isValid, "plan: valid (no errors)")

// 路径安全：渲染后的路径含 ../ → 环节报错不落盘
let rootBad = tmpDir("plan-bad")
write(rootBad + "/evil/stage.yaml", """
id: evil
name: { zh: 恶意, en: Evil }
category: foundation
params:
  - key: out
    type: string
    default: safe
files:
  - path: "{{out}}"
    template: templates/e.tmpl
""")
write(rootBad + "/evil/templates/e.tmpl", "x")
let evilRes = StageCatalogLoader.load(dirs: [rootBad])
let evilPlan = ScaffoldPlan.build(catalog: evilRes.stages, selection: ["evil"],
                                  params: ["evil": ["out": "../escape"]],
                                  projectName: "p", parentDir: "/tmp/x")
check(evilPlan.stageErrors.count == 1, "plan: unsafe rendered path rejected", evilPlan.stageErrors.joined(separator: "; "))
check(evilPlan.entries.isEmpty, "plan: unsafe stage skipped")

// 校验错误：nonEmpty validator 阻断
let rootNE = tmpDir("plan-ne")
write(rootNE + "/ne/stage.yaml", """
id: ne
name: { zh: 必填, en: Required }
category: foundation
params:
  - key: summary
    type: string
    default: ""
    validate: nonEmpty
files:
  - path: out.txt
    template: templates/o.tmpl
""")
write(rootNE + "/ne/templates/o.tmpl", "{{summary}}")
let neRes = StageCatalogLoader.load(dirs: [rootNE])
let neEmpty = ScaffoldPlan.build(catalog: neRes.stages, selection: ["ne"], params: [:],
                                 projectName: "p", parentDir: "/tmp/x")
check(!neEmpty.validationErrors.isEmpty, "plan: nonEmpty validator blocks blank")
let neFilled = ScaffoldPlan.build(catalog: neRes.stages, selection: ["ne"], params: ["ne": ["summary": "ok"]],
                                  projectName: "p", parentDir: "/tmp/x")
check(neFilled.validationErrors.isEmpty, "plan: nonEmpty validator passes filled")

// MARK: - 落盘（fixture 目标目录：内容断言、冲突备份、state.json、幂等）

let applyRoot = tmpDir("apply")
let applyPlan = ScaffoldPlan.build(catalog: planStages, selection: ["one"], params: ["one": ["who": "world"]],
                                   projectName: "demo", parentDir: applyRoot)
let applyRes = ScaffoldApplier.apply(plan: applyPlan, options: ScaffoldApplier.Options(backupConflicts: true))
eq(applyRes.written.count, 1, "apply: one file written")
let targetFile = (applyRoot as NSString).appendingPathComponent("demo/one.txt")
eq(read(targetFile), "one world demo", "apply: content byte-exact")
check(exists((applyRoot as NSString).appendingPathComponent("demo/.scaffold/state.json")), "apply: state.json written")
let stateText = read((applyRoot as NSString).appendingPathComponent("demo/.scaffold/state.json"))
check(stateText.contains("\"projectName\"") && stateText.contains("\"demo\""), "apply: state.json has projectName", stateText)
check(stateText.contains("\"one\""), "apply: state.json has stage id", stateText)

// 二次运行（幂等 9.10）：内容相同不重复备份
let applyAgain = ScaffoldApplier.apply(plan: applyPlan, options: ScaffoldApplier.Options(backupConflicts: true))
check(applyAgain.backups.isEmpty, "apply: idempotent re-run no backup when content same")
// 内容变化 → 备份到 .scaffold-backup/
let applyChanged = ScaffoldPlan.build(catalog: planStages, selection: ["one"], params: ["one": ["who": "changed"]],
                                      projectName: "demo", parentDir: applyRoot)
let applyChangedRes = ScaffoldApplier.apply(plan: applyChanged, options: ScaffoldApplier.Options(backupConflicts: true))
check(applyChangedRes.backups.contains("one.txt"), "apply: changed file backed up", "\(applyChangedRes.backups)")
let backupText = read((applyRoot as NSString).appendingPathComponent("demo/.scaffold-backup/one.txt"))
eq(backupText, "one world demo", "apply: backup holds previous content")
eq(read(targetFile), "one changed demo", "apply: new content written")

// backupConflicts=false → 不备份直接覆盖
write(targetFile, "user content")
let applyNoBackup = ScaffoldApplier.apply(plan: applyPlan, options: ScaffoldApplier.Options(backupConflicts: false))
check(applyNoBackup.backups.isEmpty, "apply: backupConflicts=false no backup")
eq(read(targetFile), "one world demo", "apply: overwritten without backup")
// state.json 记录 files（workspace「更新配置」回读依据）
let stateFinal = read((applyRoot as NSString).appendingPathComponent("demo/.scaffold/state.json"))
check(stateFinal.contains("\"files\"") && stateFinal.contains("one.txt"), "apply: state.json records files list", stateFinal)

// MARK: - 端到端：纯后端 API 预设（10.1）

func loadBuiltin() -> [ScaffoldStage] {
    StageCatalogLoader.load(dirs: [builtinDir]).stages
}

let e2eDir = tmpDir("e2e")
var e2eParams: [String: [String: String]] = [:]
for (sid, defaults) in ScaffoldPreset.backend.paramDefaults {
    e2eParams[sid] = defaults
}
e2eParams["agents-md"] = ["techSummary": "一个纯后端 API 服务 / a backend API service", "primaryLang": "java"]
e2eParams["makefile"] = ["backendBuild": "mvn -q package", "backendTest": "mvn -q test", "testCmd": "mvn -q test", "lintCmd": "mvn -q checkstyle:check"]
e2eParams["git-init"] = ["license": "MIT", "gitIgnorePreset": "java"]
e2eParams["ci-cd"] = ["platform": "github-actions", "hasBackend": "true", "hasFrontend": "false"]
e2eParams["docker"] = ["runtime": "java", "exposePort": "8080", "healthzPath": "/healthz"]
e2eParams["deploy"] = ["deployDocker": "true", "deployK8s": "false", "deployRancher": "false",
                       "imageRepo": "registry.example.com", "imageTag": "1.0.0", "remoteHost": "", "sshUser": "root"]
let e2ePlan = ScaffoldPlan.build(catalog: loadBuiltin(), selection: ScaffoldPreset.backend.stageIds,
                                 params: e2eParams, projectName: "my-api", parentDir: e2eDir)
check(e2ePlan.isValid, "e2e backend: plan valid", (e2ePlan.validationErrors + e2ePlan.stageErrors).joined(separator: "; "))
let e2eApply = ScaffoldApplier.apply(plan: e2ePlan, options: ScaffoldApplier.Options(backupConflicts: true))
check(e2eApply.written.count >= 15, "e2e backend: >=15 files written", "\(e2eApply.written.count)")
let root = (e2eDir as NSString).appendingPathComponent("my-api")

let agentsMD = read((root as NSString).appendingPathComponent("AGENTS.md"))
check(agentsMD.contains("# AGENTS.md — my-api"), "e2e backend: AGENTS.md project name")
check(agentsMD.contains("make build"), "e2e backend: AGENTS.md make commands", agentsMD)
check(agentsMD.contains("docs/conventions/git.md"), "e2e backend: AGENTS.md git conventions ref")
let makefile = read((root as NSString).appendingPathComponent("Makefile"))
check(makefile.contains("mvn -q package"), "e2e backend: Makefile backendBuild", makefile)
check(makefile.contains("backend-test"), "e2e backend: Makefile backend-test target")
for docPath in ["docs/architecture.md", "docs/adr/ADR-0001-template.md", "docs/conventions.md", "docs/ops/runbook.md",
                "docs/conventions/git.md", ".editorconfig", "CONTRIBUTING.md", ".gitignore", "README.md",
                ".gitmessage", "Dockerfile", ".dockerignore", "compose.yaml", "deploy/deploy-docker.sh",
                ".dsh/wiki/README.md"] {
    check(exists((root as NSString).appendingPathComponent(docPath)), "e2e backend: \(docPath) exists")
}
let composeYml = read((root as NSString).appendingPathComponent("compose.yaml"))
check(composeYml.contains("registry.example.com/my-api:1.0.0"), "e2e backend: compose image")
check(composeYml.contains("8080:8080"), "e2e backend: compose port")
let gitignore = read((root as NSString).appendingPathComponent(".gitignore"))
check(gitignore.contains("target/"), "e2e backend: java gitignore")
let license = read((root as NSString).appendingPathComponent("LICENSE"))
check(license.contains("MIT License"), "e2e backend: MIT LICENSE")
// jenkins 组合不生成（github-actions 生效）
check(!exists((root as NSString).appendingPathComponent("Jenkinsfile")), "e2e backend: no Jenkinsfile (github-actions)")

// MARK: - 端到端：platform=jenkins（9.16 凭据占位 / post.always）

let jenkinsDir = tmpDir("jenkins")
let jenkinsParams: [String: [String: String]] = [
    "ci-cd": ["platform": "jenkins", "hasBackend": "true", "hasFrontend": "false"],
    "makefile": ["backendBuild": "mvn -q package", "backendTest": "mvn -q test", "lintCmd": "mvn -q checkstyle:check"],
]
let jenkinsPlan = ScaffoldPlan.build(catalog: loadBuiltin(), selection: ["ci-cd", "makefile"],
                                     params: jenkinsParams, projectName: "ci-app", parentDir: jenkinsDir)
check(jenkinsPlan.isValid, "jenkins: plan valid", (jenkinsPlan.validationErrors + jenkinsPlan.stageErrors).joined(separator: "; "))
let jRoot = (jenkinsDir as NSString).appendingPathComponent("ci-app")
_ = ScaffoldApplier.apply(plan: jenkinsPlan, options: ScaffoldApplier.Options(backupConflicts: true))
let jenkinsfile = read((jRoot as NSString).appendingPathComponent("Jenkinsfile"))
check(jenkinsfile.contains("pipeline {"), "jenkins: declarative pipeline")
check(jenkinsfile.contains("agent { label 'linux' }"), "jenkins: agent label placeholder", jenkinsfile)
check(jenkinsfile.contains("stage('Lint')") && jenkinsfile.contains("stage('Test')") && jenkinsfile.contains("stage('Build')"),
       "jenkins: lint→test→build stages")
check(jenkinsfile.contains("git fetch --tags --force || true"), "jenkins: shallow-clone tag lesson")
check(jenkinsfile.contains("withCredentials([usernamePassword(credentialsId: '<占位>'"), "jenkins: withCredentials placeholder (no inline secret)", jenkinsfile)
check(!jenkinsfile.contains("password = '"), "jenkins: no inline secret pattern")
check(jenkinsfile.contains("params.PUBLISH"), "jenkins: publish gated by param (default off)")
check(jenkinsfile.contains("archiveArtifacts"), "jenkins: post.always archives")
check(jenkinsfile.contains("timestamps()") && jenkinsfile.contains("disableConcurrentBuilds()"), "jenkins: options")
check(!exists((jRoot as NSString).appendingPathComponent(".gitlab-ci.yml")), "jenkins: no gitlab-ci")
check(!exists((jRoot as NSString).appendingPathComponent(".github/workflows/ci.yml")), "jenkins: no gh ci")

// MARK: - 端到端：git-conventions enforce=true（10.1）

let gitConvDir = tmpDir("gitconv")
let gcPlan = ScaffoldPlan.build(catalog: loadBuiltin(), selection: ["git-conventions"],
                                params: ["git-conventions": ["enforce": "true", "trunk": "main"]],
                                projectName: "git-app", parentDir: gitConvDir)
check(gcPlan.isValid, "gitconv: plan valid", gcPlan.stageErrors.joined(separator: "; "))
let gcRoot = (gitConvDir as NSString).appendingPathComponent("git-app")
_ = ScaffoldApplier.apply(plan: gcPlan, options: ScaffoldApplier.Options(backupConflicts: true))
let gitMd = read((gcRoot as NSString).appendingPathComponent("docs/conventions/git.md"))
for type in ["feat", "fix", "docs", "refactor", "perf", "test", "chore", "build", "ci", "revert"] {
    check(gitMd.contains("| \(type) |"), "gitconv: git.md has type \(type)")
}
check(gitMd.contains("feature/<slug>") && gitMd.contains("fix/<slug>") && gitMd.contains("release/X.Y"),
       "gitconv: branch prefixes", gitMd)
check(gitMd.contains("force-push"), "gitconv: no force-push rule")
check(exists((gcRoot as NSString).appendingPathComponent(".gitmessage")), "gitconv: .gitmessage exists")
let hookScript = read((gcRoot as NSString).appendingPathComponent("scripts/install-git-hooks.sh"))
check(hookScript.contains("commit-msg") && hookScript.contains("grep -Eq"), "gitconv: hook script is pure-shell validator")
check(!hookScript.contains("node"), "gitconv: hook script has no node dependency", hookScript)
check(hookScript.contains(".scaffold-backup"), "gitconv: hook backup (9.17)")
// enforce=false → 不生成脚本
let gcDir2 = tmpDir("gitconv2")
let gcPlan2 = ScaffoldPlan.build(catalog: loadBuiltin(), selection: ["git-conventions"],
                                 params: ["git-conventions": ["enforce": "false", "trunk": "master"]],
                                 projectName: "git-app2", parentDir: gcDir2)
let gcRoot2 = (gcDir2 as NSString).appendingPathComponent("git-app2")
_ = ScaffoldApplier.apply(plan: gcPlan2, options: ScaffoldApplier.Options(backupConflicts: true))
check(!exists((gcRoot2 as NSString).appendingPathComponent("scripts/install-git-hooks.sh")), "gitconv: enforce=false no hook script")
let gitMd2 = read((gcRoot2 as NSString).appendingPathComponent("docs/conventions/git.md"))
check(gitMd2.contains("`master`"), "gitconv: trunk=master in git.md")

// MARK: - 端到端：deploy 全选 + remoteHost（10.1）

let deployDir = tmpDir("deploy")
let dp = ScaffoldPlan.build(catalog: loadBuiltin(), selection: ["deploy"],
                            params: ["deploy": ["deployDocker": "true", "deployK8s": "true", "deployRancher": "true",
                                                "imageRepo": "reg.example.com", "imageTag": "2.1.0",
                                                "remoteHost": "prod.example.com", "sshUser": "deploy",
                                                "namespace": "prod", "kubeContext": "prod-cluster",
                                                "rancherServer": "https://rancher.example.com",
                                                "servicePort": "8080", "healthzPath": "/healthz"]],
                            projectName: "deploy-app", parentDir: deployDir)
check(dp.isValid, "deploy: plan valid", (dp.validationErrors + dp.stageErrors).joined(separator: "; "))
let dRoot = (deployDir as NSString).appendingPathComponent("deploy-app")
_ = ScaffoldApplier.apply(plan: dp, options: ScaffoldApplier.Options(backupConflicts: true))
let dockerSh = read((dRoot as NSString).appendingPathComponent("deploy/deploy-docker.sh"))
check(dockerSh.contains("rsync -az --delete"), "deploy: docker script rsync remote branch", dockerSh)
check(dockerSh.contains("ssh \"${SSH_USER}@${REMOTE_HOST}\""), "deploy: docker script ssh remote exec")
check(dockerSh.contains("health check failed — rolling back"), "deploy: docker script health rollback")
check(dockerSh.contains("--dry-run"), "deploy: docker script --dry-run")
check(!dockerSh.contains("sshpass"), "deploy: docker script no inline secret")
let k8sSh = read((dRoot as NSString).appendingPathComponent("deploy/deploy-k8s.sh"))
check(k8sSh.contains("KUBE_CONTEXT"), "deploy: k8s script KUBE_CONTEXT", k8sSh)
check(k8sSh.contains("rollout undo"), "deploy: k8s script rollout undo")
check(k8sSh.contains("kubectl apply --dry-run=client"), "deploy: k8s script dry-run")
check(k8sSh.contains("configmap.yaml"), "deploy: k8s script applies configmap first")
check(exists((dRoot as NSString).appendingPathComponent("deploy/k8s/deployment.yaml")), "deploy: deployment.yaml exists")
let rancherSh = read((dRoot as NSString).appendingPathComponent("deploy/deploy-rancher.sh"))
check(rancherSh.contains("deploy/k8s/"), "deploy: rancher script reuses k8s manifests", rancherSh)
check(rancherSh.contains("RANCHER_SERVER"), "deploy: rancher script RANCHER_SERVER")
check(exists((dRoot as NSString).appendingPathComponent("deploy/rancher/README.md")), "deploy: rancher README exists")
let deployment = read((dRoot as NSString).appendingPathComponent("deploy/k8s/deployment.yaml"))
check(deployment.contains("reg.example.com/deploy-app:2.1.0"), "deploy: deployment image", deployment)
check(deployment.contains("path: /healthz"), "deploy: deployment healthz")
let envExample = read((dRoot as NSString).appendingPathComponent("deploy/.env.example"))
check(envExample.contains("IMAGE_REPO=reg.example.com"), "deploy: .env.example image repo")
check(!dockerSh.contains("BEGIN PRIVATE KEY") && !k8sSh.contains("BEGIN PRIVATE KEY"), "deploy: no private key inlined")

// MARK: - 预设定义（3 组）

eq(ScaffoldPreset.all.count, 3, "presets: 3 groups")
eq(ScaffoldPreset.backend.stageIds.count, 10, "presets: backend = 10 stages")
check(ScaffoldPreset.foundation.stageIds.contains("repo-knowledge"), "presets: foundation includes repo-knowledge")
check(!ScaffoldPreset.foundation.stageIds.contains("ci-cd"), "presets: foundation excludes ci-cd")

// MARK: - 渲染器与 GHA [object Object] 转义（cd.yml 模板）

let cdTemplate = read((builtinDir as NSString).appendingPathComponent("ci-cd/templates/cd.yml.tmpl"))
let cdRendered = try! ScaffoldTemplateRenderer.render(cdTemplate, context: ["ciBuild": "make build", "imageRepo": "reg", "projectSlug": "app", "imageTag": "1"])
check(cdRendered.contains("${{ secrets.DOCKER_USERNAME }}"), "render: GHA ${{ }} escape round-trip", cdRendered)
check(!cdRendered.contains("{{{{"), "render: no leftover escape")


// MARK: - 多语言 AGENTS.md（primaryLang 多选）与 Makefile 语言预设

let multiDir = tmpDir("multi")
let multiPlan = ScaffoldPlan.build(catalog: loadBuiltin(), selection: ["agents-md"],
                                   params: ["agents-md": ["techSummary": "t", "primaryLang": "java node python"]],
                                   projectName: "multi", parentDir: multiDir)
let agentsTmpl = read((builtinDir as NSString).appendingPathComponent("agents-md/templates/AGENTS.md.tmpl"))
let multiAgents = try! ScaffoldTemplateRenderer.render(agentsTmpl, context: multiPlan.context)
check(multiAgents.contains("- Java") && multiAgents.contains("- Node.js") && multiAgents.contains("- Python"),
       "multi: AGENTS.md lists selected languages", multiAgents)
check(!multiAgents.contains("- Go") && !multiAgents.contains("- Rust"), "multi: AGENTS.md omits unselected languages")
check(multiAgents.contains("Primary languages"), "multi: AGENTS.md plural label")

let mkTmpl = read((builtinDir as NSString).appendingPathComponent("makefile/templates/Makefile.tmpl"))
let goPlan = ScaffoldPlan.build(catalog: loadBuiltin(), selection: ["makefile"],
                                params: ["makefile": ["lang": "go"]], projectName: "goapp", parentDir: tmpDir("go"))
let goMk = try! ScaffoldTemplateRenderer.render(mkTmpl, context: goPlan.context)
check(goMk.contains("go test ./...") && goMk.contains("gofmt -w .") && goMk.contains("go run ."), "makefile: go preset targets", goMk)
check(!goMk.contains("mvn") && !goMk.contains("npm ci"), "makefile: go preset no java/node commands")

let pyPlan = ScaffoldPlan.build(catalog: loadBuiltin(), selection: ["makefile"],
                                params: ["makefile": ["lang": "python"]], projectName: "pyapp", parentDir: tmpDir("py"))
let pyMk = try! ScaffoldTemplateRenderer.render(mkTmpl, context: pyPlan.context)
check(pyMk.contains("pytest") && pyMk.contains("ruff check .") && pyMk.contains("pip install -r requirements.txt"), "makefile: python preset targets", pyMk)

let nodePlan = ScaffoldPlan.build(catalog: loadBuiltin(), selection: ["makefile"],
                                  params: ["makefile": ["lang": "node"]], projectName: "nodeapp", parentDir: tmpDir("node"))
let nodeMk = try! ScaffoldTemplateRenderer.render(mkTmpl, context: nodePlan.context)
check(nodeMk.contains("node-build:") && nodeMk.contains("npm run build") && nodeMk.contains("npm test") && nodeMk.contains("npm ci") && nodeMk.contains("npm run dev"), "makefile: node preset targets", nodeMk)

// makefile 多语言：同时选 java + node，生成各自 <lang>-<action> 目标并存
let bothPlan = ScaffoldPlan.build(catalog: loadBuiltin(), selection: ["makefile"],
                                  params: ["makefile": ["lang": "java node"]], projectName: "both", parentDir: tmpDir("both"))
let bothMk = try! ScaffoldTemplateRenderer.render(mkTmpl, context: bothPlan.context)
check(bothMk.contains("java-build:") && bothMk.contains("node-build:"), "makefile: multi-lang both targets", bothMk)
check(bothMk.contains("build: java-build node-build"), "makefile: multi-lang umbrella build chains both", bothMk)

// makefile lang=none：默认仍渲染 backend/frontend 目标（多端模式）
let nonePlan = ScaffoldPlan.build(catalog: loadBuiltin(), selection: ["makefile"],
                                  params: ["makefile": ["backendBuild": "mvn -q package", "backendTest": "mvn -q test"]],
                                  projectName: "none", parentDir: tmpDir("none"))
let noneMk = try! ScaffoldTemplateRenderer.render(mkTmpl, context: nonePlan.context)
check(noneMk.contains("backend-test") && noneMk.contains("mvn -q package"), "makefile: lang=none multi-tier targets", noneMk)

// CI 派生命令随 lang 变化
let ciPlan = ScaffoldPlan.build(catalog: loadBuiltin(), selection: ["ci-cd", "makefile"],
                                params: ["ci-cd": ["platform": "github-actions", "hasBackend": "true", "hasFrontend": "false"],
                                         "makefile": ["lang": "go"]], projectName: "ci-go", parentDir: tmpDir("cigo"))
eq(ciPlan.context["ciTest"] ?? "", "go test ./...", "ci: go test derived")
eq(ciPlan.context["ciBuild"] ?? "", "go build -o bin/app .", "ci: go build derived")
eq(ciPlan.context["ciLint"] ?? "", "golangci-lint run", "ci: go lint derived")


// MARK: - README 使用项目名与项目简介（git-init）

let readmeTmpl = read((builtinDir as NSString).appendingPathComponent("git-init/templates/README.md.tmpl"))
let readmeWith = try! ScaffoldTemplateRenderer.render(readmeTmpl,
    context: ["projectName": "my-api", "techSummary": "内部 API 网关 / internal API gateway", "techSummaryEmpty": "false", "hasMakefile": "true"])
check(readmeWith.contains("# my-api"), "readme: project name heading")
check(readmeWith.contains("内部 API 网关"), "readme: uses step-1 project summary", readmeWith)
let readmeWithout = try! ScaffoldTemplateRenderer.render(readmeTmpl,
    context: ["projectName": "my-api", "techSummary": "", "techSummaryEmpty": "true", "hasMakefile": "true"])
check(readmeWithout.contains("项目简介待补充"), "readme: placeholder when no summary", readmeWithout)


// MARK: - git-init license=none 不产出 LICENSE

let licDir = tmpDir("lic")
let licPlan = ScaffoldPlan.build(catalog: loadBuiltin(), selection: ["git-init"],
                                 params: ["git-init": ["license": "none", "gitIgnorePreset": "generic"]],
                                 projectName: "lic", parentDir: licDir)
let licPaths = licPlan.entries.map { $0.path }
check(!licPaths.contains("LICENSE"), "git-init: license=none => no LICENSE file", licPaths.joined(separator: ", "))
let mitDir = tmpDir("lic-mit")
let mitPlan = ScaffoldPlan.build(catalog: loadBuiltin(), selection: ["git-init"],
                                 params: ["git-init": ["license": "MIT", "gitIgnorePreset": "generic"]],
                                 projectName: "licmit", parentDir: mitDir)
check(mitPlan.entries.contains { $0.path == "LICENSE" && $0.content.contains("MIT License") }, "git-init: license=MIT => MIT LICENSE", mitPlan.entries.map{$0.path}.joined(separator:", "))


// MARK: - 孤儿文件清理（改选后移除上一轮生成的文件：license MIT→none 移除 LICENSE）

let licRegenDir = tmpDir("licregen")
let licA = ScaffoldPlan.build(catalog: loadBuiltin(), selection: ["git-init"],
                              params: ["git-init": ["license": "MIT", "gitIgnorePreset": "generic"]],
                              projectName: "proj", parentDir: licRegenDir)
_ = ScaffoldApplier.apply(plan: licA, options: ScaffoldApplier.Options(backupConflicts: true))
let licRoot = (licRegenDir as NSString).appendingPathComponent("proj")
check(exists((licRoot as NSString).appendingPathComponent("LICENSE")), "regen: MIT first run writes LICENSE")
let licB = ScaffoldPlan.build(catalog: loadBuiltin(), selection: ["git-init"],
                              params: ["git-init": ["license": "none", "gitIgnorePreset": "generic"]],
                              projectName: "proj", parentDir: licRegenDir)
let licBRes = ScaffoldApplier.apply(plan: licB, options: ScaffoldApplier.Options(backupConflicts: true))
check(!exists((licRoot as NSString).appendingPathComponent("LICENSE")), "regen: switch to none removes LICENSE", "\(licBRes.removed)")
check(licBRes.removed.contains("LICENSE"), "regen: LICENSE recorded as removed", "\(licBRes.removed)")
let stateAfter = read((licRoot as NSString).appendingPathComponent(".scaffold/state.json"))
check(!stateAfter.contains("LICENSE"), "regen: state.json files no longer lists LICENSE", stateAfter)

// MARK: - 环节管理设置：用户环节库（覆盖内置 / 新建自定义 / 恢复）+ 排序合并

// 用户库覆盖内置（docker 改名） + 新建自定义（my-custom），与内置库同目录加载
let userRoot = tmpDir("user-stages")
write(userRoot + "/docker/stage.yaml", """
id: docker
name: { zh: 我的 Docker, en: My Docker }
category: examples
description: { zh: 修改过的, en: Modified }
""")
write(userRoot + "/my-custom/stage.yaml", """
id: my-custom
name: { zh: 自定义环节, en: Custom Stage }
category: collaboration
description: { zh: 新建的, en: New }
""")
let mergedRes = StageCatalogLoader.load(dirs: [userRoot, builtinDir], builtinDir: builtinDir, userDir: userRoot)
check(mergedRes.errors.isEmpty, "settings: user override is silent (no duplicate error)", mergedRes.errors.joined(separator: "; "))
eq(mergedRes.stages.count, 11, "settings: 10 builtin + 1 new custom (override not duplicated)")
let dockerS = mergedRes.stages.first { $0.id == "docker" }
check(dockerS?.isCustom == true, "settings: overridden builtin is marked custom")
check(dockerS?.nameZh == "我的 Docker" && dockerS?.nameEn == "My Docker", "settings: user copy wins over builtin definition")
check(mergedRes.builtinIDs.contains("docker"), "settings: builtinIDs keeps overridden id (restore available)")
let customS = mergedRes.stages.first { $0.id == "my-custom" }
check(customS?.isCustom == true, "settings: new custom stage marked custom")
check(!mergedRes.builtinIDs.contains("my-custom"), "settings: new stage not in builtinIDs (delete, no restore)")
let gitInitS = mergedRes.stages.first { $0.id == "git-init" }
check(gitInitS?.isCustom == false, "settings: untouched builtin stays builtin")
// 反向目录顺序也应用户优先（用户库恒胜出）
let reverseRes = StageCatalogLoader.load(dirs: [builtinDir, userRoot], builtinDir: builtinDir, userDir: userRoot)
let dockerRev = reverseRes.stages.first { $0.id == "docker" }
eq(dockerRev?.nameZh, "我的 Docker", "settings: user wins regardless of dir order")

// saveUserStage：写 stage.yaml + 复制 templates（修改内置 → 用户库带模板）
let saveRoot = tmpDir("save-user")
setenv("DSH_SCAFFOLD_USER_STAGES", saveRoot, 1)
let mkYaml = read((builtinDir as NSString).appendingPathComponent("makefile/stage.yaml"))
try! StageCatalogLoader.saveUserStage(id: "makefile", yaml: mkYaml,
                                      templatesFrom: (builtinDir as NSString).appendingPathComponent("makefile"))
check(exists((saveRoot as NSString).appendingPathComponent("makefile/stage.yaml")), "settings: save writes stage.yaml to user library")
check(exists((saveRoot as NSString).appendingPathComponent("makefile/templates/Makefile.tmpl")), "settings: save copies templates/ along")
// removeUserStage（恢复内置 = 删用户拷贝）
check(StageCatalogLoader.removeUserStage(id: "makefile"), "settings: removeUserStage returns true")
check(!exists((saveRoot as NSString).appendingPathComponent("makefile")), "settings: restore deletes user stage dir")
// 删除不存在的 → false
check(!StageCatalogLoader.removeUserStage(id: "no-such-stage"), "settings: removeUserStage false for missing")

// 校验器与 id 解析
check(StageCatalogLoader.validateStageID("my-stage"), "settings: valid id")
check(!StageCatalogLoader.validateStageID("My_Stage"), "settings: uppercase/underscore rejected")
check(!StageCatalogLoader.validateStageID(""), "settings: empty id rejected")
check(!StageCatalogLoader.validateStageID("a b"), "settings: space rejected")
let parsedID = try! StageCatalogLoader.parseStageID(from: "id: abc-123\nname: { zh: X, en: Y }\n")
eq(parsedID, "abc-123", "settings: parseStageID reads id")

// 排序合并：saved → defaults → catalog 剩余；saved 中失效 id 过滤
let orderMerged = ScaffoldStageOrder.merge(
    saved: ["docker", "git-init"],
    defaults: ["git-init", "repo-knowledge", "agents-md", "docker"],
    catalogIDs: ["git-init", "repo-knowledge", "agents-md", "docker", "deploy"])
eq(orderMerged, ["docker", "git-init", "repo-knowledge", "agents-md", "deploy"], "settings: order saved-first then defaults then catalog rest")
let orderFiltered = ScaffoldStageOrder.merge(
    saved: ["ghost", "deploy"], defaults: ["deploy"], catalogIDs: ["deploy", "real"])
eq(orderFiltered, ["deploy", "real"], "settings: stale saved ids dropped")
let orderEmpty = ScaffoldStageOrder.merge(saved: nil, defaults: ["b", "a"], catalogIDs: ["a", "b", "c"])
eq(orderEmpty, ["b", "a", "c"], "settings: no saved = defaults + catalog rest")

// MARK: - 环节编辑器：多文件编辑闭环（templates/ 文件编辑 → 用户库 → 渲染生效）

// 场景 1：内置环节物化后，面板内编辑模板文件（saveTemplateFile 效果）→ 渲染采用用户版模板。
// 物化：saveUserStage 带 templatesFrom 复制内置模板；随后覆盖用户库模板文件模拟面板内保存。
let tplRoot = tmpDir("tpl-user")
setenv("DSH_SCAFFOLD_USER_STAGES", tplRoot, 1)
let tplMkYaml = read((builtinDir as NSString).appendingPathComponent("makefile/stage.yaml"))
try! StageCatalogLoader.saveUserStage(id: "makefile", yaml: tplMkYaml,
                                      templatesFrom: (builtinDir as NSString).appendingPathComponent("makefile"))
// 面板内编辑模板并保存：写入用户库 templates/Makefile.tmpl（覆盖物化复制来的内置版本）
let userMkTpl = (tplRoot as NSString).appendingPathComponent("makefile/templates/Makefile.tmpl")
write(userMkTpl, "# USER-EDITED Makefile for {{projectName}}\nautogenerated: yes\n")
let tplLoaded = StageCatalogLoader.load(dirs: [tplRoot], builtinDir: builtinDir, userDir: tplRoot)
let tplPlan = ScaffoldPlan.build(catalog: tplLoaded.stages, selection: ["makefile"],
                                 params: ["makefile": ["backendBuild": "mvn -q package", "backendTest": "mvn -q test",
                                                       "testCmd": "mvn -q test", "lintCmd": "mvn -q checkstyle:check"]],
                                 projectName: "tpl-app", parentDir: tmpDir("tpl-out"))
check(tplPlan.isValid, "editor: builtin materialized plan valid", (tplPlan.validationErrors + tplPlan.stageErrors).joined(separator: "; "))
let userMkEntry = tplPlan.entries.first { $0.path == "Makefile" }
check(userMkEntry?.content.hasPrefix("# USER-EDITED Makefile for tpl-app") == true,
      "editor: render uses user-library template after in-panel edit",
      userMkEntry?.content ?? "nil")
check(userMkEntry?.content.contains("autogenerated: yes") == true,
      "editor: user template content fully rendered", userMkEntry?.content ?? "nil")

// 场景 2：自定义环节 + 面板内新建模板文件（newTemplateFile 效果）→ 保存后渲染生效。
let customRoot = tmpDir("custom-user")
setenv("DSH_SCAFFOLD_USER_STAGES", customRoot, 1)
let noteYaml = """
id: noter
name: { zh: 笔记环节, en: Noter }
category: foundation
description: { zh: 测试, en: test }
params:
  - key: who
    label: { zh: 谁, en: Who }
    type: input
    default: world
files:
  - path: NOTE.md
    template: templates/note.tmpl
commands: []
"""
try! StageCatalogLoader.saveUserStage(id: "noter", yaml: noteYaml, templatesFrom: nil)
let NoteTplContent = "hello {{who}}, from {{projectName}}!\n"
// 面板内新建模板并保存：创建 templates/ 目录 + 写文件（无内置来源，模板内容由编辑而来）
write((customRoot as NSString).appendingPathComponent("noter/templates/note.tmpl"), NoteTplContent)
let customLoaded = StageCatalogLoader.load(dirs: [customRoot], builtinDir: builtinDir, userDir: customRoot)
let customPlan = ScaffoldPlan.build(catalog: customLoaded.stages, selection: ["noter"],
                                    params: ["noter": ["who": "agent"]],
                                    projectName: "demo-x", parentDir: tmpDir("custom-out"))
check(customPlan.isValid, "editor: custom stage plan valid", (customPlan.validationErrors + customPlan.stageErrors).joined(separator: "; "))
let noteEntry = customPlan.entries.first { $0.path == "NOTE.md" }
eq(noteEntry?.content ?? "nil", "hello agent, from demo-x!\n", "editor: new custom template renders")

print("----")
print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)

