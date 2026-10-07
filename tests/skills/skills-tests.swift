import Foundation

// Headless tests for SkillInstaller.swift. Two modes via TEST_MODE env:
//   migrate  - legacy skill dir renames on a fresh home
//   install  - fresh install / update / skip-user-managed / idempotency
var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("ok  - \(msg)") } else { failures += 1; print("FAIL - \(msg)") }
}

guard let repoRoot = ProcessInfo.processInfo.environment["REPO_ROOT"], !repoRoot.isEmpty else {
    print("FAIL - REPO_ROOT env required"); exit(1)
}
let srcSkills = (repoRoot as NSString).appendingPathComponent(".dsh/skills")
let fm = FileManager.default

func installedPath(_ s: BuiltinSkill) -> String {
    (SkillInstaller.dshHomeDir() as NSString).appendingPathComponent("skills/\(s.dirName)/SKILL.md")
}
func installedDir(_ s: BuiltinSkill) -> String {
    (SkillInstaller.dshHomeDir() as NSString).appendingPathComponent("skills/\(s.dirName)")
}
func repoFile(_ s: BuiltinSkill) -> String {
    (srcSkills as NSString).appendingPathComponent("\(s.dirName)/SKILL.md")
}
func marker(_ s: BuiltinSkill) -> String { installedDir(s) + "/" + SkillInstaller.managedMarker }
func read(_ p: String) -> String? { try? String(contentsOfFile: p, encoding: .utf8) }

let mode = ProcessInfo.processInfo.environment["TEST_MODE"] ?? "install"

if mode == "migrate" {
    // issue-fix is deliberately NOT here any more: its skill (issue-resolve) retired
    // 2026-09-27 — an app-managed copy is removed instead of renamed (step 3 below).
    let legacy: [(String, BuiltinSkill)] = [
        ("shell-browser", .webDevTools),
        ("repo-wiki", .repoKnowledge),
    ]
    // Seed legacy skill dirs (old per-repo/global names) on a fresh home.
    for (name, _) in legacy {
        let d = (SkillInstaller.dshHomeDir() as NSString).appendingPathComponent("skills/\(name)")
        try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        try? "legacy".write(toFile: (d as NSString).appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }
    _ = SkillInstaller.installBuiltinSkills()
    for (name, skill) in legacy {
        let legacyDir = (SkillInstaller.dshHomeDir() as NSString).appendingPathComponent("skills/\(name)")
        check(!fm.fileExists(atPath: legacyDir), "legacy migrated away \(name)")
        check(fm.fileExists(atPath: installedPath(skill)), "new installed \(skill.dirName)")
        check(read(installedPath(skill)) == read(repoFile(skill)), "migrated byte-identical \(skill.dirName)")
        check(fm.fileExists(atPath: marker(skill)), "migrated marker \(skill.dirName)")
    }
    // Legacy kept (not deleted) when the new name already exists.
    let l = (SkillInstaller.dshHomeDir() as NSString).appendingPathComponent("skills/shell-browser")
    try? fm.createDirectory(atPath: l, withIntermediateDirectories: true)
    try? "keep".write(toFile: (l as NSString).appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    _ = SkillInstaller.installBuiltinSkills()
    check(fm.fileExists(atPath: l), "legacy kept when new exists")

    // 3. Retired skills. An app-managed copy (marker present) is DELETED; a copy the
    // user touched (no marker, or a stranger's own skill of the same name) is kept.
    let home = SkillInstaller.dshHomeDir()
    let managed = (home as NSString).appendingPathComponent("skills/issue-resolve")
    try? fm.createDirectory(atPath: managed, withIntermediateDirectories: true)
    try? "old".write(toFile: (managed as NSString).appendingPathComponent("SKILL.md"),
                     atomically: true, encoding: .utf8)
    try? "managed".write(toFile: (managed as NSString).appendingPathComponent(SkillInstaller.managedMarker),
                         atomically: true, encoding: .utf8)
    let userOwned = (home as NSString).appendingPathComponent("skills/issue-fix")
    try? fm.createDirectory(atPath: userOwned, withIntermediateDirectories: true)
    try? "mine".write(toFile: (userOwned as NSString).appendingPathComponent("SKILL.md"),
                      atomically: true, encoding: .utf8)
    _ = SkillInstaller.installBuiltinSkills()
    check(!fm.fileExists(atPath: managed), "retired managed skill removed")
    check(fm.fileExists(atPath: userOwned), "retired user-managed copy kept")
    check(read((userOwned as NSString).appendingPathComponent("SKILL.md")) == "mine",
          "retired user copy untouched")
    check(!BuiltinSkill.allCases.contains { $0.dirName == "issue-resolve" },
          "issue-resolve is no longer a built-in")
} else {
    // 1. Fresh install on an empty home.
    let results = SkillInstaller.installBuiltinSkills()
    check(results.count == BuiltinSkill.allCases.count, "install returns N results")
    for skill in BuiltinSkill.allCases {
        check(fm.fileExists(atPath: installedPath(skill)), "installed \(skill.dirName)")
        check(read(installedPath(skill)) == read(repoFile(skill)), "byte-identical \(skill.dirName)")
        check(fm.fileExists(atPath: marker(skill)), "marker present \(skill.dirName)")
        check(results.first(where: { $0.skill == skill })?.action == "installed", "action installed \(skill.dirName)")
    }
    // 2. Idempotent: second run is upToDate, no rewrite (mtime unchanged).
    let p = installedPath(.webDevTools)
    let m0 = (try? fm.attributesOfItem(atPath: p)[.modificationDate] as? Date)
    Thread.sleep(forTimeInterval: 0.05)
    let r2 = SkillInstaller.installBuiltinSkills()
    let m1 = (try? fm.attributesOfItem(atPath: p)[.modificationDate] as? Date)
    check(r2.first(where: { $0.skill == .webDevTools })?.action == "upToDate", "idempotent upToDate")
    check(m0 == m1, "idempotent no rewrite (mtime)")
    // 3. Update: content differs, marker present -> overwrite.
    try? "stale".write(toFile: p, atomically: true, encoding: .utf8)
    let r3 = SkillInstaller.installBuiltinSkills()
    check(r3.first(where: { $0.skill == .webDevTools })?.action == "updated", "update action")
    check(read(p) == read(repoFile(.webDevTools)), "update restored content")
    // 4. Skip user-managed: no marker, content differs -> preserved.
    try? fm.removeItem(atPath: marker(.webDevTools))
    try? "user edit".write(toFile: p, atomically: true, encoding: .utf8)
    let r4 = SkillInstaller.installBuiltinSkills()
    check(r4.first(where: { $0.skill == .webDevTools })?.action == "skippedUserManaged", "skip user-managed action")
    check(read(p) == "user edit", "user edit preserved")
    // 5. Retired skills (2026-09-27): the app-managed copy goes, a user's stays.
    let home = SkillInstaller.dshHomeDir()
    let retired = (home as NSString).appendingPathComponent("skills/issue-resolve")
    try? fm.createDirectory(atPath: retired, withIntermediateDirectories: true)
    try? "old".write(toFile: (retired as NSString).appendingPathComponent("SKILL.md"),
                     atomically: true, encoding: .utf8)
    try? "managed".write(toFile: (retired as NSString).appendingPathComponent(SkillInstaller.managedMarker),
                         atomically: true, encoding: .utf8)
    let owned = (home as NSString).appendingPathComponent("skills/issue-fix")
    try? fm.createDirectory(atPath: owned, withIntermediateDirectories: true)
    try? "mine".write(toFile: (owned as NSString).appendingPathComponent("SKILL.md"),
                      atomically: true, encoding: .utf8)
    _ = SkillInstaller.installBuiltinSkills()
    check(!fm.fileExists(atPath: retired), "retired managed skill removed")
    check(fm.fileExists(atPath: owned), "retired user-managed copy kept")
    check(!BuiltinSkill.allCases.contains { $0.dirName == "issue-resolve" },
          "issue-resolve is no longer a built-in")
}

// 6. Write-permission reversal (2026-10): the workstream-panel skill tells the
// agent to edit WS cards through /api/workstreams/* and never to touch .dsh
// files directly. Guard both the presence and the wording.
check(BuiltinSkill.workstreamPanel.dirName == "workstream-panel", "workstream-panel dirName")
let wsSkill = read(repoFile(.workstreamPanel))
check(wsSkill != nil, "workstream-panel repo copy exists")
if let text = wsSkill {
    check(text.contains("name: workstream-panel"), "workstream-panel frontmatter name")
    check(text.contains("/api/workstreams/"), "workstream-panel points at the panel API")
    check(text.contains("不直接改 .dsh 文件"), "workstream-panel forbids direct .dsh edits")
    check(text.contains("stage/confirm"), "workstream-panel keeps the human confirmation gate")
    // 2026-10-06 (A14 / D19): the skill documents the panel's own engine, not /task-todo.
    check(text.contains("/api/workstreams/task/create"), "workstream-panel documents stage task create")
    check(text.contains("/api/workstreams/task/list"), "workstream-panel documents task list")
    check(text.contains("/api/workstreams/queue/start"), "workstream-panel documents queue start")
    check(text.contains("/api/workstreams/queue/pause"), "workstream-panel documents queue pause")
    check(text.contains("等待态"), "workstream-panel creates waiting-state tasks (build, do not start)")
    check(text.contains("stage/reject"), "workstream-panel keeps the reject gate")
    check(!text.contains("/task-todo"), "workstream-panel no longer points at /task-todo")
    check(text.contains("不自签"), "workstream-panel: the agent never self-signs a gate")
    // 2026-10-07: covered / delivery now have write routes; outcome stays derived.
    check(text.contains("/api/workstreams/covered"), "workstream-panel documents the covered write route")
    check(text.contains("/api/workstreams/delivery"), "workstream-panel documents the delivery write route")
    check(text.contains("outcome-derived") || text.contains("派生缓存"), "workstream-panel: outcome is a derived cache, not hand-written")
    // 2026-10-07 (A11 / D6): session -> workstream reverse lookup + the focus channel.
    check(text.contains("/api/workstreams/bound"), "workstream-panel documents the session reverse lookup route")
    check(text.contains("$DSH_SESSION_ID"), "workstream-panel reverse lookup uses $DSH_SESSION_ID")
    check(text.contains("反查"), "workstream-panel explains the reverse lookup")
    check(text.contains("focus: true") && text.contains("focus=true"), "workstream-panel documents the focus flag (body + query)")
    check(text.contains("聚焦") || text.contains("高亮"), "workstream-panel explains focusing / highlighting the panel")
    // 2026-10-07 (A15 / A16): focus + home session. The binding is a single
    // last-writer-wins home session, NOT a permanent promise, and ephemeral
    // sessions must not overwrite it. bound?focus highlights the reverse lookup.
    check(text.contains("主场会话"), "workstream-panel explains the home session")
    check(text.contains("后写覆盖") || text.contains("last-writer-wins"), "workstream-panel: the binding is last-writer-wins")
    check(text.contains("临时会话"), "workstream-panel warns ephemeral sessions not to overwrite the home session")
    check(text.contains("bound") && (text.contains("高亮") || text.contains("聚焦")), "workstream-panel: bound?focus highlights the reverse lookup")
    // 2026-10-07 (task 28): in-conversation split / start entry + routing context.
    check(text.contains("对话中发起拆分 / 启动"), "workstream-panel documents the in-conversation split/start entry")
    check(text.contains("首个未处理阶段"), "workstream-panel: split targets the FIRST unprocessed stage")
    check(text.contains("面板主卡「**拆分任务**」按钮 = 同一条拆分语义"), "workstream-panel: panel split button == same session-prompt semantics")
    // 2026-10-07 (UX): the stage card's start button is gone; the workstream
    // card is the panel's single start entry, and it runs in canonical stage order.
    check(text.contains("面板阶段卡已去掉「**启动阶段**」按钮") && text.contains("唯一的启动入口"),
          "workstream-panel: the stage card has no start button; the workstream card is the single start entry")
    check(text.contains("阶段 canonical 顺序"), "workstream-panel: workstream start runs in canonical stage order")
    // 2026-10-07 (task 34): the human gate is no longer "never call". The skill is
    // user-invocable, and stage/confirm + stage/reject may be called ONLY when the
    // user explicitly authorizes it in this session, after restating evidence
    // (confirm) / obtaining the human's reason (reject). The 409 gate stays hard.
    check(!text.contains("user-invocable: false"), "workstream-panel is user-invocable (no user-invocable: false key)")
    check(text.contains("可被用户直接调用"), "workstream-panel documents direct user invocation")
    check(text.contains("/workstream-panel 确认规划"), "workstream-panel documents /workstream-panel confirm invocation")
    check(text.contains("/api/workstreams/stage/confirm"), "workstream-panel documents the full confirm route")
    check(text.contains("/api/workstreams/stage/reject"), "workstream-panel documents the full reject route")
    check(text.contains("仅当用户在本会话明确发出确认"), "workstream-panel: gates open only on explicit per-session user intent")
    check(text.contains("不得主动代签"), "workstream-panel: the agent never signs on the user's behalf")
    check(text.contains("复述结论与证据"), "workstream-panel: confirm restates evidence and requests confirmation")
    check(text.contains("必须拿到人的原因"), "workstream-panel: reject requires the human's reason")
    check(text.contains("由人给"), "workstream-panel: the reject reason comes from the human, not the agent")
    check(text.contains("不得重试硬推"), "workstream-panel: 409 evidence-missing / stage-changed are not force-retried")
}

if failures > 0 { print("\(failures) FAILURE(S)"); exit(1) }
print("skills tests (\(mode)) passed")
