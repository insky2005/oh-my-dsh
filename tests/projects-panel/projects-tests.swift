import Foundation

// Headless unit tests for the Projects panel model (ProjectsCore.swift): the
// projects-root resolution, the folder-name rules, the directory listing and the
// dsh-registry merge. Pure Foundation — no AppKit, no dsh server.
//
// Usage: tests/projects-panel/run.sh

var failures = 0
func test(_ name: String, _ cond: Bool) {
    print((cond ? "ok  - " : "FAIL- ") + name)
    if !cond { failures += 1 }
}
func eq<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    test("\(name) (got \(got), want \(want))", got == want)
}

let fm = FileManager.default

// MARK: - Root resolution

eq(ProjectsCore.defaultRoot(dshHome: "/x/.dsh"), "/x/.dsh/oh-my-dsh/projects", "default root lives under the dsh home")

var res = ProjectsCore.resolvedRoot(configValue: nil, dshHome: "/x/.dsh", envOverride: nil)
eq(res.path, "/x/.dsh/oh-my-dsh/projects", "no config -> built-in default")
eq(res.source, .fallback, "no config -> source = fallback")

res = ProjectsCore.resolvedRoot(configValue: "   ", dshHome: "/x/.dsh", envOverride: nil)
eq(res.source, .fallback, "blank config is the same as no config")

res = ProjectsCore.resolvedRoot(configValue: "/p/projects", dshHome: "/x/.dsh", envOverride: nil)
eq(res.path, "/p/projects", "configured absolute path wins")
eq(res.source, .config, "configured -> source = config")

res = ProjectsCore.resolvedRoot(configValue: "~/proj", dshHome: "/x/.dsh", envOverride: nil)
eq(res.path, NSHomeDirectory() + "/proj", "~ is expanded")
eq(res.source, .config, "an expanded ~ path is a valid config")

res = ProjectsCore.resolvedRoot(configValue: "relative/dir", dshHome: "/x/.dsh", envOverride: nil)
eq(res.path, "/x/.dsh/oh-my-dsh/projects", "a relative path is rejected, not resolved against the cwd")
eq(res.source, .invalidConfig, "a relative path is reported as invalid config")

res = ProjectsCore.resolvedRoot(configValue: "/p/projects", dshHome: "/x/.dsh", envOverride: "/qa/root")
eq(res.path, "/qa/root", "the QA env override beats the configured value")
eq(res.source, .environment, "env override -> source = environment")

res = ProjectsCore.resolvedRoot(configValue: "/p/projects", dshHome: "/x/.dsh", envOverride: "  ")
eq(res.source, .config, "a blank env override is ignored")

// MARK: - Name rules

func nameError(_ raw: String) -> ProjectsCore.NameError? {
    if case .failure(let e) = ProjectsCore.validateName(raw) { return e }
    return nil
}
func validName(_ raw: String) -> String? {
    if case .success(let n) = ProjectsCore.validateName(raw) { return n }
    return nil
}

eq(validName("abc"), "abc", "a plain name is accepted")
eq(validName("  abc  "), "abc", "surrounding whitespace is trimmed")
eq(validName("my-project_2.0"), "my-project_2.0", "dots and dashes inside a name are fine")
eq(nameError(""), .empty, "an empty name is rejected")
eq(nameError("   "), .empty, "an all-whitespace name is rejected")
eq(nameError("a/b"), .separator, "a slash is rejected (single path segment only)")
eq(nameError("a:b"), .separator, "a colon is rejected (HFS rewrites it to a slash)")
eq(nameError("a\u{1}b"), .illegalCharacter, "a control character is rejected")
eq(nameError("."), .dot, "a single dot is rejected")
eq(nameError(".."), .dot, "a double dot is rejected")
eq(nameError(".hidden"), .hidden, "a leading dot is rejected (the panel never lists it)")
eq(nameError(String(repeating: "a", count: 65)), .tooLong, "65 characters is too long")
eq(validName(String(repeating: "a", count: 64)), String(repeating: "a", count: 64), "64 characters is fine")

eq(ProjectsCore.workspacePath(root: "/p/projects", name: "abc"), "/p/projects/abc", "workspacePath joins root and name")
eq(ProjectsCore.workspacePath(root: "/p/projects/", name: "abc"), "/p/projects/abc", "workspacePath does not double the slash")

// MARK: - Listing

// NSTemporaryDirectory() ends with a slash; appendingPathComponent keeps the
// fixture paths free of doubles (they are used as literal prefixes below).
let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("projects-core-" + UUID().uuidString)
let outside = (NSTemporaryDirectory() as NSString).appendingPathComponent("projects-outside-" + UUID().uuidString)
try! fm.createDirectory(atPath: root, withIntermediateDirectories: true)
try! fm.createDirectory(atPath: outside, withIntermediateDirectories: true)

for dir in ["alpha", "Beta", "gamma dir"] {
    try! fm.createDirectory(atPath: root + "/" + dir, withIntermediateDirectories: true)
}
try! Data("not a workspace".utf8).write(to: URL(fileURLWithPath: root + "/notes.txt"))
try! fm.createDirectory(atPath: root + "/.hidden", withIntermediateDirectories: true)
// A symlink onto an existing repo (adopting a directory outside the root) and a
// symlink onto a plain file (must NOT become a workspace).
try! fm.createSymbolicLink(atPath: root + "/linked", withDestinationPath: outside)
try! fm.createSymbolicLink(atPath: root + "/linkfile", withDestinationPath: root + "/notes.txt")

let listed = ProjectsCore.listDirectories(root: root, fileManager: fm)
eq(listed.map(\.name), ["alpha", "Beta", "gamma dir", "linked"], "listing: directories + dir-symlinks, sorted case-insensitively")
test("listing: plain files are not workspaces", !listed.contains { $0.name == "notes.txt" })
test("listing: hidden directories are skipped", !listed.contains { $0.name == ".hidden" })
test("listing: a file symlink is not a workspace", !listed.contains { $0.name == "linkfile" })
// The listing reports file-system paths (on macOS /private/var/... for a fixture
// under /var), so the property to pin is the one the feature relies on: every
// entry canonicalizes to canonical(root)/<name> — the same comparison the
// registry merge performs.
test("listing: every entry canonicalizes to root + name",
     listed.allSatisfy {
         DshWorkspaceStore.canonical($0.path)
             == DshWorkspaceStore.canonical(ProjectsCore.workspacePath(root: root, name: $0.name))
     })
test("listing: mtime is reported when the file system offers it", listed.allSatisfy { $0.modifiedAt != nil })

eq(ProjectsCore.listDirectories(root: root + "/missing", fileManager: fm).count, 0,
   "listing: a missing root is an empty list, never an error")

// MARK: - Registry merge

let canonical: (String) -> String = { DshWorkspaceStore.canonical($0) }
let registry: [[String: Any]] = [
    ["workspaceId": "w-alpha", "path": root + "/alpha", "sessionIds": ["s1", "s2"]],
    ["workspaceId": "w-beta-slash", "path": root + "/Beta/", "sessionIds": []],
    ["workspaceId": "w-linked", "path": outside, "sessionIds": ["s9"]],
    ["workspaceId": "w-dup", "path": root + "/alpha", "sessionIds": ["ignored"]],
    ["title": "no path at all"],
]
let merged = ProjectsCore.merge(entries: listed, registry: registry, canonical: canonical)

func workspace(_ name: String) -> ProjectWorkspace? { merged.first { $0.name == name } }
eq(merged.count, listed.count, "merge: keeps every listed directory")
eq(workspace("alpha")?.registered, true, "merge: a matching path is registered")
eq(workspace("alpha")?.workspaceId, "w-alpha", "merge: the workspaceId is carried over")
eq(workspace("alpha")?.sessionCount, 2, "merge: sessionCount = sessionIds.count")
eq(workspace("gamma dir")?.registered, false, "merge: an unregistered directory stays visible, just unregistered")
eq(workspace("gamma dir")?.sessionCount, 0, "merge: an unregistered directory has no sessions")
eq(workspace("Beta")?.registered, true, "merge: a trailing slash on the registry path still matches")
eq(workspace("linked")?.workspaceId, "w-linked", "merge: a symlinked workspace matches its resolved registry path")
eq(ProjectsCore.merge(entries: listed, registry: [], canonical: canonical).filter { $0.registered }.count, 0,
   "merge: an empty registry (dsh <= 0.1.1 / unreadable store) leaves everything unregistered")
eq(ProjectsCore.merge(entries: listed, registry: registry, canonical: { _ in "same" }).count, listed.count,
   "merge: a canonicalizer that collapses everything still maps 1:1 per entry")

// MARK: - Cleanup

try? fm.removeItem(atPath: root)
try? fm.removeItem(atPath: outside)

print(failures == 0 ? "projects model tests passed" : "projects model tests FAILED (\(failures))")
exit(failures == 0 ? 0 : 1)
