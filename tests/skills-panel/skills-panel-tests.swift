import Foundation

// Headless tests for the Skills manager model layer:
//   SkillsCore.swift   — frontmatter IO, root scanning + levels, store
//   SkillSources.swift — address parsing, registries, fetch, install, remove
// Everything runs against a temp fixture home with fake transports.
// Usage: tests/skills-panel/run.sh

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("ok  - " + msg) } else { failures += 1; print("FAIL - " + msg) }
}

let fm = FileManager.default
guard let root = ProcessInfo.processInfo.environment["TEST_ROOT"], !root.isEmpty else {
    print("FAIL - TEST_ROOT env required"); exit(1)
}
let home = (root as NSString).appendingPathComponent("home")
let workspace = (root as NSString).appendingPathComponent("ws")
let userSkills = (home as NSString).appendingPathComponent("skills")
let sharedSkills = (root as NSString).appendingPathComponent("agents/skills")
let projectSkills = (workspace as NSString).appendingPathComponent(".dsh/skills")
let marker = ".ohmy-dsh-managed"

func writeSkill(_ dir: String, name: String, description: String = "desc",
                extraFrontmatter: String = "", body: String = "# body\n") {
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let text = "---\nname: " + name + "\ndescription: " + description + "\n"
        + extraFrontmatter + "---\n\n" + body
    try? text.write(toFile: (dir as NSString).appendingPathComponent("SKILL.md"),
                    atomically: true, encoding: .utf8)
}

func readFile(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

// ---------------------------------------------------------------- frontmatter

let plain = "---\nname: demo\ndescription: A demo skill\n---\n\n# Demo\n"
if let p = SkillFrontmatterIO.parse(plain) {
    check(p.name == "demo", "frontmatter: name parsed")
    check(p.description == "A demo skill", "frontmatter: description parsed")
    check(p.effectiveUserInvocable, "frontmatter: user-invocable defaults true")
    check(p.effectiveModelInvocable, "frontmatter: model-invocable defaults true")
    check(p.userInvocable == nil && p.disableModelInvocation == nil, "frontmatter: absent keys stay nil")
} else {
    check(false, "frontmatter: plain file parses")
}

let flags = "---\nname: demo\ndescription: d\nuser-invocable: no\ndisable-model-invocation: \"1\"\n---\nbody\n"
if let p = SkillFrontmatterIO.parse(flags) {
    check(p.effectiveUserInvocable == false, "frontmatter: user-invocable: no => false")
    check(p.effectiveModelInvocable == false, "frontmatter: quoted \"1\" => true (disabled)")
} else {
    check(false, "frontmatter: flag file parses")
}

check(SkillFrontmatterIO.parse("# no frontmatter\nhello\n") == nil, "frontmatter: missing block rejected")
check(SkillFrontmatterIO.parse("---\nname: demo\n---\nbody\n") == nil, "frontmatter: missing description rejected")

// Round-trip: setting a flag then removing it restores the exact bytes.
do {
    let added = try SkillFrontmatterIO.settingInvocation(plain, userInvocable: false, disableModelInvocation: true)
    check(added.contains("user-invocable: false"), "frontmatter: key inserted")
    check(added.contains("disable-model-invocation: true"), "frontmatter: second key inserted")
    let restored = try SkillFrontmatterIO.settingInvocation(added, userInvocable: nil, disableModelInvocation: nil)
    check(restored == plain, "frontmatter: removing keys restores exact bytes")
} catch {
    check(false, "frontmatter: edit does not throw (" + String(describing: error) + ")")
}

// CRLF + comment + quoted description survive an edit untouched.
do {
    let crlf = "---\r\nname: demo\r\ndescription: 'a desc' # keep\r\ntools: [a, b]\r\n---\r\nbody\r\n"
    let edited = try SkillFrontmatterIO.settingInvocation(crlf, userInvocable: false, disableModelInvocation: nil)
    check(edited.contains("tools: [a, b]\r\n"), "frontmatter: unrelated keys preserved")
    check(edited.contains("description: 'a desc' # keep\r\n"), "frontmatter: comment line preserved")
    let back = try SkillFrontmatterIO.settingInvocation(edited, userInvocable: nil, disableModelInvocation: nil)
    check(back == crlf, "frontmatter: CRLF round-trip byte-identical")
} catch {
    check(false, "frontmatter: CRLF edit threw")
}

do {
    _ = try SkillFrontmatterIO.settingInvocation("no frontmatter", userInvocable: true, disableModelInvocation: nil)
    check(false, "frontmatter: editing without frontmatter throws")
} catch {
    check(true, "frontmatter: editing without frontmatter throws")
}

check(SkillNameRule.isValid("web-dev-tools"), "name: kebab accepted")
check(!SkillNameRule.isValid("Web_Tools"), "name: uppercase/underscore rejected")
check(!SkillNameRule.isValid("a--b"), "name: double hyphen rejected")

// -------------------------------------------------------------------- scanning

writeSkill((userSkills as NSString).appendingPathComponent("web-dev-tools"), name: "web-dev-tools")
try? "managed\n".write(toFile: (userSkills as NSString).appendingPathComponent("web-dev-tools/" + marker),
                       atomically: true, encoding: .utf8)
writeSkill((userSkills as NSString).appendingPathComponent("my-tool"), name: "my-tool")
writeSkill((sharedSkills as NSString).appendingPathComponent("shared-tool"), name: "shared-tool")
writeSkill((projectSkills as NSString).appendingPathComponent("proj-tool"), name: "proj-tool")
// Same name as the built-in, but project level: shadows it, stays project.
writeSkill((projectSkills as NSString).appendingPathComponent("web-dev-tools"), name: "web-dev-tools")

let userRoot = SkillRoot(kind: .userDsh, level: .user, path: userSkills, rank: SkillRoots.rankUserDsh)
let sharedRoot = SkillRoot(kind: .userAgents, level: .shared, path: sharedSkills, rank: SkillRoots.rankUserAgents)
let projectRoot = SkillRoot(kind: .projectDsh, level: .project, path: projectSkills, rank: SkillRoots.rankProjectDsh)

let scanned = SkillScanner.scan([userRoot, sharedRoot, projectRoot])
func find(_ name: String) -> [InstalledSkill] { scanned.filter { $0.name == name } }

check(scanned.count == 5, "scan: five skills found (got " + String(scanned.count) + ")")
if let builtin = find("web-dev-tools").first(where: { $0.level == .builtin }) {
    check(!builtin.canEditInvocation, "scan: builtin is read-only")
    check(!builtin.canRemove, "scan: builtin cannot be removed")
} else {
    check(false, "scan: builtin detected by root+name+marker")
}
if let project = find("web-dev-tools").first(where: { $0.level == .project }) {
    check(project.shadowedBy == nil, "scan: project copy wins by rank (100 < 400)")
} else {
    check(false, "scan: project copy present")
}
if let builtin = find("web-dev-tools").first(where: { $0.level == .builtin }) {
    check(builtin.shadowedBy == .project, "scan: builtin marked shadowed by the project copy")
}
if let user = find("my-tool").first {
    check(user.level == .user && user.canEditInvocation && user.canRemove, "scan: user level writable/removable")
}
if let shared = find("shared-tool").first {
    check(shared.level == .shared, "scan: shared level detected")
    check(shared.canEditInvocation && !shared.canRemove, "scan: shared editable but not removable")
}
if let project = find("proj-tool").first {
    check(project.level == .project && project.canRemove, "scan: project level detected")
}

// Flat .md files at a root are skills too.
try? "# flat\n".write(toFile: (userSkills as NSString).appendingPathComponent("flat.md"),
                      atomically: true, encoding: .utf8)
try? ("---\nname: flat-one\ndescription: flat\n---\nbody\n").write(
    toFile: (userSkills as NSString).appendingPathComponent("flat.md"), atomically: true, encoding: .utf8)
let withFlat = SkillScanner.scan([userRoot])
check(withFlat.contains(where: { $0.name == "flat-one" }), "scan: flat .md recognised")
try? fm.removeItem(atPath: (userSkills as NSString).appendingPathComponent("flat.md"))

// ------------------------------------------------------------------ store/level guards

let store = SkillStore(home: home)
let builtinSkill = scanned.first { $0.level == .builtin }!
let builtinTextBefore = readFile(builtinSkill.skillFile)
do {
    _ = try SkillInstallService.applyInvocation(builtinSkill, userInvocable: false,
                                                disableModelInvocation: true, store: store)
    check(false, "guard: builtin invocation edit rejected")
} catch let e as SkillPanelError {
    check(e == .builtinReadOnly, "guard: builtin invocation edit -> builtinReadOnly")
} catch { check(false, "guard: unexpected error type") }
check(readFile(builtinSkill.skillFile) == builtinTextBefore,
      "guard: builtin file untouched after refusal")

let sharedSkill = scanned.first { $0.level == .shared }!
do {
    try SkillInstallService.remove(sharedSkill, store: store)
    check(false, "guard: shared remove rejected")
} catch let e as SkillPanelError {
    check(e == .sharedNotRemovable, "guard: shared remove -> sharedNotRemovable")
} catch { check(false, "guard: unexpected error type") }
check(fm.fileExists(atPath: sharedSkill.dir), "guard: shared dir still present")

do {
    _ = try SkillInstallService.remove(builtinSkill, store: store)
    check(false, "guard: builtin remove rejected")
} catch let e as SkillPanelError {
    check(e == .builtinReadOnly, "guard: builtin remove -> builtinReadOnly")
} catch { check(false, "guard: unexpected error type") }

// ---------------------------------------------------------------- invocation flags

let userSkill = scanned.first { $0.name == "my-tool" }!
do {
    let updated = try SkillInstallService.applyInvocation(userSkill, userInvocable: false,
                                                          disableModelInvocation: true, store: store)
    check(updated.userInvocable == false && updated.modelInvocable == false, "flags: scan reflects new values")
    let text = readFile(userSkill.skillFile)
    check(text.contains("user-invocable: false"), "flags: user-invocable written")
    check(text.contains("disable-model-invocation: true"), "flags: disable-model-invocation written")
    check(store.invocationRecord("my-tool") != nil, "flags: invocation record stored")

    // Back to the file's own baseline: keys are removed, bytes restored.
    let restored = try SkillInstallService.applyInvocation(updated, userInvocable: true,
                                                           disableModelInvocation: false, store: store)
    check(restored.userInvocable && restored.modelInvocable, "flags: restored to defaults")
    check(!readFile(userSkill.skillFile).contains("user-invocable"), "flags: key removed again")
    check(readFile(userSkill.skillFile) == restoredText(for: "my-tool"),
          "flags: round-trip restores original bytes")
} catch {
    check(false, "flags: apply threw " + String(describing: error))
}

func restoredText(for name: String) -> String {
    "---\nname: " + name + "\ndescription: desc\n---\n\n# body\n"
}

// ---------------------------------------------------------------- install / remove

let userRootAgain = userRoot
let fakeSkill = FetchedSkill(name: "installed-tool",
                             description: "from a registry",
                             files: ["SKILL.md": Data(("---\nname: installed-tool\ndescription: from a registry\n---\nbody\n").utf8),
                                     "references/notes.md": Data("# notes\n".utf8)],
                             sourceLabel: "acme/skills",
                             sourceType: "github",
                             sourceUrl: "https://github.com/acme/skills",
                             ref: nil,
                             path: "skills/installed-tool/SKILL.md")
do {
    let installed = try SkillInstallService.install(fakeSkill, into: userRootAgain, store: store)
    check(installed.level == .user, "install: lands at user level")
    check(installed.dir == (userSkills as NSString).appendingPathComponent("installed-tool"),
          "install: directory is <DSH_HOME>/skills/<name>")
    check(fm.fileExists(atPath: (installed.dir as NSString).appendingPathComponent("references/notes.md")),
          "install: sibling files copied")
    check(installed.extraFiles == 1, "install: extra file counted")
    check(store.installRecord("installed-tool")?.source == "acme/skills", "install: record written")

    do {
        _ = try SkillInstallService.install(fakeSkill, into: userRootAgain, store: store)
        check(false, "install: existing target rejected")
    } catch let e as SkillPanelError {
        check(e == .targetExists(installed.dir), "install: existing target -> targetExists")
    }
    _ = try SkillInstallService.install(fakeSkill, into: userRootAgain, store: store, overwrite: true)
    check(fm.fileExists(atPath: installed.skillFile), "install: overwrite allowed")

    // Invalid names never reach the disk.
    var bad = fakeSkill
    bad.name = "Bad_Name"
    do {
        _ = try SkillInstallService.install(bad, into: userRootAgain, store: store)
        check(false, "install: invalid name rejected")
    } catch let e as SkillPanelError {
        check(e == .invalidName("Bad_Name"), "install: invalid name -> invalidName")
    }

    // Shared / builtin levels are not install targets.
    do {
        _ = try SkillInstallService.install(fakeSkill, into: sharedRoot, store: store)
        check(false, "install: shared target rejected")
    } catch let e as SkillPanelError {
        check(e == .unsupportedTarget, "install: shared target -> unsupportedTarget")
    }

    // Path traversal inside a fetched skill.
    var evil = fakeSkill
    evil.name = "evil-tool"
    evil.files = ["../evil.md": Data("x".utf8)]
    do {
        _ = try SkillInstallService.install(evil, into: userRootAgain, store: store)
        check(false, "install: path traversal rejected")
    } catch let e as SkillPanelError {
        check(e == .unsafePath("../evil.md"), "install: path traversal -> unsafePath")
    }

    // Project-level install lands in the workspace.
    var projectSkill = fakeSkill
    projectSkill.name = "proj-installed"
    let atProject = try SkillInstallService.install(projectSkill, into: projectRoot, store: store)
    check(atProject.level == .project, "install: project level")
    check(atProject.dir.hasPrefix(projectSkills), "install: project directory under .dsh/skills")

    // Remove clears the directory + records.
    try SkillInstallService.remove(installed, store: store)
    check(!fm.fileExists(atPath: installed.dir), "remove: directory deleted")
    check(store.installRecord("installed-tool") == nil, "remove: install record cleared")
} catch {
    check(false, "install/remove threw " + String(describing: error))
}

// ----------------------------------------------------------------- registry store

let store2 = SkillStore(home: (root as NSString).appendingPathComponent("home2"))
store2.seedDefaultRegistriesIfEmpty()
check(store2.data.registries.count == 1, "registry: default seed")
check(store2.data.registries[0].id == "skills-sh", "registry: default is skills.sh")
check(store2.data.registries[0].catalog == .none, "registry: skills.sh has no catalog")
check((store2.data.registries[0].searchURL ?? "").contains("/api/search?q={q}"),
      "registry: search template present")
store2.upsertRegistry(SkillRegistryRecord(id: "acme", label: "Acme",
                                          searchURL: nil, catalog: .githubRepo, catalogURL: "acme/skills"))
check(store2.data.registries.count == 2, "registry: upsert adds")
store2.reload()
check(store2.registry(id: "acme")?.catalogURL == "acme/skills", "registry: persisted to disk")
store2.removeRegistry(id: "acme")
check(store2.data.registries.count == 1, "registry: remove")

// ------------------------------------------------------------------- addresses

func addressKind(_ input: String) -> String {
    guard let a = SkillAddressParser.parse(input) else { return "nil" }
    switch a {
    case .github(let o, let r, let ref, let sub, let skill):
        return "github:" + o + "/" + r + ":" + (ref ?? "-") + ":" + (sub ?? "-") + ":" + (skill ?? "-")
    case .git: return "git"
    case .wellKnown: return "wellKnown"
    case .local: return "local"
    }
}
check(addressKind("vercel-labs/agent-skills") == "github:vercel-labs/agent-skills:-:-:-", "address: owner/repo")
check(addressKind("vercel-labs/agent-skills@find-skills") == "github:vercel-labs/agent-skills:-:-:find-skills",
      "address: owner/repo@skill")
check(addressKind("https://github.com/anthropics/skills/tree/main/skills/skill-creator")
      == "github:anthropics/skills:main:skills/skill-creator:-", "address: github tree URL")
check(addressKind("https://github.com/anthropics/skills") == "github:anthropics/skills:-:-:-", "address: github URL")
check(addressKind("https://example.com/.git") == "git", "address: git URL")
check(addressKind("https://skills.acme.dev/") == "wellKnown", "address: well-known URL")
check(addressKind("/tmp/some-skill") == "local", "address: local path")

// --------------------------------------------------------------------- registry

do {
    let rendered = try SkillRegistryClient.renderSearchURL("https://skills.sh/api/search?q={q}&limit={limit}",
                                                           query: "react native", limit: 5)
    check(rendered.hasPrefix("https://skills.sh/api/search?q="), "search: template rendered")
    check(rendered.contains("react%20native"), "search: query URL-encoded")
    check(rendered.hasSuffix("limit=5"), "search: limit substituted")
} catch {
    check(false, "search: render threw")
}

let wellKnownIndex = """
{"skills":[{"name":"alpha","description":"A skill","files":["SKILL.md","references/x.md"]},
{"name":"bad","description":"absolute","files":["/etc/passwd"]},
{"name":"escape","description":"traversal","files":["SKILL.md","../../x"]},
{"name":"nodef","files":["SKILL.md"]}]}
"""
do {
    let entries = try SkillRegistryClient.parseWellKnownIndex(Data(wellKnownIndex.utf8))
    check(entries.count == 1 && entries[0].name == "alpha",
          "well-known: only valid entries kept (got " + String(entries.count) + ")")
} catch {
    check(false, "well-known: index parse threw")
}

let searchJSON = """
{"query":"react","skills":[{"id":"a/b/react-x","skillId":"react-x","name":"react-x","installs":1234,"source":"a/b"},
{"name":"","installs":1,"source":"a/b"}]}
"""
do {
    let found = try SkillRegistryClient.parseSearchResponse(Data(searchJSON.utf8))
    check(found.count == 1, "search: response parsed")
    check(found[0].name == "react-x" && found[0].installs == 1234, "search: fields mapped")
    check(addressKindOf(found[0].address) == "github:a/b:-:-:react-x", "search: candidate carries skill filter")
} catch {
    check(false, "search: response parse threw")
}

func addressKindOf(_ a: SkillAddress) -> String {
    switch a {
    case .github(let o, let r, let ref, let sub, let skill):
        return "github:" + o + "/" + r + ":" + (ref ?? "-") + ":" + (sub ?? "-") + ":" + (skill ?? "-")
    case .git: return "git"
    case .wellKnown: return "wellKnown"
    case .local: return "local"
    }
}

// Fake transport: a registry base serving index.json + skill files.
let fakeBase = "https://registry.example"
SkillTransport.fetch = { request in
    let url = request.url?.absoluteString ?? ""
    if url == fakeBase + "/.well-known/skills/index.json" {
        let json = "{\"skills\":[{\"name\":\"alpha\",\"description\":\"A skill\",\"files\":[\"SKILL.md\"]}]}"
        return (200, Data(json.utf8))
    }
    if url == fakeBase + "/.well-known/skills/alpha/SKILL.md" {
        return (200, Data("---\nname: alpha\ndescription: A skill\n---\nbody\n".utf8))
    }
    if url.hasPrefix("https://skills.sh/api/search") {
        return (200, Data(searchJSON.utf8))
    }
    return (404, nil)
}
SkillTransport.run = { _, _, _ in (1, "git unavailable in tests") }

do {
    let wk = SkillRegistryRecord(id: "wk", label: "wk", searchURL: nil, catalog: .wellKnown, catalogURL: fakeBase)
    let listed = try SkillRegistryClient.catalog(wk)
    check(listed.count == 1 && listed[0].name == "alpha", "catalog: well-known listing")
    let fetched = try SkillFetcher.fetch(listed[0].address, temp: SkillFetcher.makeTempDir())
    check(fetched.count == 1 && fetched[0].name == "alpha", "fetch: well-known skill body")
    check(fetched[0].description == "A skill", "fetch: frontmatter parsed from the registry")
} catch {
    check(false, "catalog/fetch threw " + String(describing: error))
}

do {
    let noneReg = SkillRegistryRecord(id: "s", label: "s",
                                      searchURL: "https://skills.sh/api/search?q={q}&limit={limit}",
                                      catalog: .none, catalogURL: "")
    _ = try SkillRegistryClient.catalog(noneReg)
    check(false, "catalog: none-registry rejected")
} catch let e as SkillPanelError {
    check(e == .noCatalog, "catalog: none-registry -> noCatalog")
} catch { check(false, "catalog: unexpected error") }

do {
    _ = try SkillRegistryClient.search(SkillRegistryRecord(id: "s", label: "s",
                                                           searchURL: "https://skills.sh/api/search?q={q}&limit={limit}",
                                                           catalog: .none, catalogURL: ""), query: "a")
    check(false, "search: one-char query rejected")
} catch let e as SkillPanelError {
    check(e == .queryTooShort, "search: one-char query -> queryTooShort")
} catch { check(false, "search: unexpected error") }

// popular(): search-only registries have no listing endpoint, so the default
// view merges a few broad queries and sorts everything by installs.
SkillTransport.fetch = { request in
    let url = request.url?.absoluteString ?? ""
    let dup = #"{"name":"alpha","installs":100,"source":"acme/skills"}"#
    if url.contains("q=sk") {
        return (200, Data(("{\"skills\":[{\"name\":\"find-skills\",\"installs\":3406311,\"source\":\"vercel-labs/skills\"}," + dup + "]}").utf8))
    }
    if url.contains("q=ag") {
        return (200, Data(("{\"skills\":[{\"name\":\"agent-browser\",\"installs\":855964,\"source\":\"vercel-labs/agent-browser\"}," + dup + "]}").utf8))
    }
    return (404, nil)
}
do {
    let searchOnly = SkillRegistryRecord(id: "s", label: "s",
                                         searchURL: "https://skills.sh/api/search?q={q}&limit={limit}",
                                         catalog: .none, catalogURL: "",
                                         popularQueries: ["sk", "ag"])
    let merged = try SkillRegistryClient.popular(searchOnly, limit: 10)
    check(merged.count == 3, "popular: duplicate entries merged (got " + String(merged.count) + ")")
    check(merged.first?.name == "find-skills", "popular: highest installs first")
    check(merged[1].name == "agent-browser", "popular: sorted by installs desc")
    let top2 = try SkillRegistryClient.popular(searchOnly, limit: 2)
    check(top2.count == 2, "popular: limit applied")
    let defaults = SkillRegistryRecord(id: "d", label: "d",
                                       searchURL: "https://skills.sh/api/search?q={q}&limit={limit}",
                                       catalog: .none, catalogURL: "")
    check(defaults.popularQueries.isEmpty, "popular: user registries carry no seeded queries")
    let seeded = SkillRegistryRecord.defaultSkillsSh()
    check(seeded.popularQueries == SkillRegistryRecord.defaultPopularQueries,
          "popular: the built-in skills.sh registry seeds the default queries")
} catch {
    check(false, "popular threw " + String(describing: error))
}

// popularQueries survive a store round-trip.
do {
    let home3 = (root as NSString).appendingPathComponent("home3")
    let s3 = SkillStore(home: home3)
    s3.upsertRegistry(SkillRegistryRecord(id: "x", label: "X",
                                          searchURL: "https://x/api/search?q={q}",
                                          catalog: .none, catalogURL: "",
                                          popularQueries: ["aa", "bb"]))
    s3.reload()
    check(s3.registry(id: "x")?.popularQueries == ["aa", "bb"], "store: popularQueries persisted")
} catch {
    check(false, "store popularQueries threw")
}

// GitHub catalog via a fake git clone that materialises a repo tree.
SkillTransport.run = { launch, args, cwd in
    guard launch == SkillTransport.gitPath, let dest = args.last, let cwd = cwd else { return (1, "bad args") }
    let repo = (dest as NSString).appendingPathComponent("skills/acme-tool")
    try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
    try? "---\nname: acme-tool\ndescription: repo skill\n---\nbody\n".write(
        toFile: (repo as NSString).appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    _ = cwd
    return (0, "")
}
do {
    let gh = SkillRegistryRecord(id: "gh", label: "acme/skills", searchURL: nil,
                                 catalog: .githubRepo, catalogURL: "acme/skills")
    let listed = try SkillRegistryClient.catalog(gh)
    check(listed.count == 1 && listed[0].name == "acme-tool", "catalog: github repo listing via clone")
    check(addressKindOf(listed[0].address) == "github:acme/skills:-:-:acme-tool",
          "catalog: github candidate carries skill filter")
} catch {
    check(false, "catalog: github listing threw " + String(describing: error))
}

// probe: three shapes
check(SkillRegistryClient.probe("acme/skills")?.catalog == .githubRepo, "probe: owner/repo -> githubRepo")
check(SkillRegistryClient.probe("https://skills.acme.dev", probeNetwork: false)?.catalog == SkillCatalogKind.none,
      "probe: without a network probe the URL falls back to a search registry")
SkillTransport.fetch = { request in
    let url = request.url?.absoluteString ?? ""
    if url == "https://skills.acme.dev/.well-known/skills/index.json" {
        let json = "{\"skills\":[{\"name\":\"alpha\",\"description\":\"A skill\",\"files\":[\"SKILL.md\"]}]}"
        return (200, Data(json.utf8))
    }
    return (404, nil)
}
check(SkillRegistryClient.probe("https://skills.acme.dev")?.catalog == .wellKnown,
      "probe: well-known index detected")
SkillTransport.fetch = { _ in (500, nil) }
let fallback = SkillRegistryClient.probe("https://skills.example")
check(fallback?.catalog == SkillCatalogKind.none && (fallback?.searchURL ?? "").contains("/api/search"),
      "probe: unknown URL falls back to search endpoint")

if failures > 0 {
    print("FAILED: " + String(failures) + " check(s)")
    exit(1)
}
print("all skills panel checks passed")
