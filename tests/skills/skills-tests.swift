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
    let legacy: [(String, BuiltinSkill)] = [
        ("shell-browser", .webDevTools),
        ("repo-wiki", .repoKnowledge),
        ("issue-fix", .issueResolve),
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
}

if failures > 0 { print("\(failures) FAILURE(S)"); exit(1) }
print("skills tests (\(mode)) passed")
