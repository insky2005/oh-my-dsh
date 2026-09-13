import Foundation

// Headless unit tests for WorkspaceTabMemory (the Files panel's per-workspace
// "which tabs were open" bookkeeping). Pure Foundation, no AppKit and no
// window, so it runs anywhere. Usage: tests/file-panel/run.sh

func test(_ name: String, _ cond: Bool) {
    print((cond ? "ok" : "FAIL") + " - " + name)
    if !cond { exit(1) }
}

// --- a workspace remembers its open tabs, in order, plus the selection ---

var memory = WorkspaceTabMemory()

test("nothing is remembered before the first switch", memory.snapshot(for: "/w/a") == nil)
test("a fresh memory is empty", memory.isEmpty)

memory.remember(paths: ["/w/a/one.md", "/w/a/src/two.swift"], selectedPath: "/w/a/src/two.swift", for: "/w/a")

test("the remembered tab order round-trips",
     memory.snapshot(for: "/w/a")?.paths == ["/w/a/one.md", "/w/a/src/two.swift"])
test("the remembered selection round-trips",
     memory.snapshot(for: "/w/a")?.selectedPath == "/w/a/src/two.swift")
test("an empty snapshot carries no selection",
     memory.snapshot(for: "/w/a")?.selectedPath != nil)
test("a workspace with tabs is no longer empty", !memory.isEmpty)
test("an unvisited workspace has no snapshot", memory.snapshot(for: "/w/b") == nil)

// --- workspaces are independent (switching back and forth) ---

memory.remember(paths: ["/w/b/b.md"], selectedPath: "/w/b/b.md", for: "/w/b")

test("a second workspace keeps its own tabs",
     memory.snapshot(for: "/w/b")?.paths == ["/w/b/b.md"])
test("remembering B left A untouched",
     memory.snapshot(for: "/w/a")?.paths == ["/w/a/one.md", "/w/a/src/two.swift"])

// --- re-remembering replaces the previous snapshot ---

memory.remember(paths: ["/w/a/three.txt"], selectedPath: nil, for: "/w/a")

test("re-remembering replaces the tab list",
     memory.snapshot(for: "/w/a")?.paths == ["/w/a/three.txt"])
test("a nil selection stays nil", memory.snapshot(for: "/w/a")?.selectedPath == nil)
test("re-remembering another workspace did not affect B",
     memory.snapshot(for: "/w/b")?.paths == ["/w/b/b.md"])

// --- remembering an empty set forgets the workspace ---

memory.remember(paths: [], selectedPath: "/w/a/three.txt", for: "/w/a")

test("an empty tab list forgets the workspace", memory.snapshot(for: "/w/a") == nil)
test("forgetting A kept B", memory.snapshot(for: "/w/b")?.paths == ["/w/b/b.md"])

// --- per-workspace forget vs. forget-all (the panel's Close button) ---

memory.remember(paths: ["/w/a/one.md"], selectedPath: "/w/a/one.md", for: "/w/a")
memory.forget(workspacePath: "/w/a")
test("forget(workspacePath:) drops exactly that workspace", memory.snapshot(for: "/w/a") == nil)
test("forget(workspacePath:) kept the other workspace",
     memory.snapshot(for: "/w/b")?.paths == ["/w/b/b.md"])

memory.forget(workspacePath: "/w/never-visited")
test("forgetting an unknown workspace is a no-op",
     memory.snapshot(for: "/w/b")?.paths == ["/w/b/b.md"])

memory.forgetAll()
test("forgetAll drops every workspace", memory.snapshot(for: "/w/b") == nil)
test("forgetAll leaves the memory empty", memory.isEmpty)

// --- key normalization: the same directory under different spellings ---

test("a trailing slash names the same workspace",
     WorkspaceTabMemory.key(for: "/w/a/") == WorkspaceTabMemory.key(for: "/w/a"))
test("a doubled slash names the same workspace",
     WorkspaceTabMemory.key(for: "/w//a") == WorkspaceTabMemory.key(for: "/w/a"))
test("a dot segment names the same workspace",
     WorkspaceTabMemory.key(for: "/w/x/../a") == WorkspaceTabMemory.key(for: "/w/a"))
test("a trailing dot segment names the same workspace",
     WorkspaceTabMemory.key(for: "/w/a/.") == WorkspaceTabMemory.key(for: "/w/a"))
test("the root path is never truncated to empty", WorkspaceTabMemory.key(for: "/") == "/")

var slashMemory = WorkspaceTabMemory()
slashMemory.remember(paths: ["/w/a/one.md"], selectedPath: nil, for: "/w/a/")
test("a snapshot written with a trailing slash is found without it",
     slashMemory.snapshot(for: "/w/a")?.paths == ["/w/a/one.md"])
slashMemory.remember(paths: [], selectedPath: nil, for: "/w/a")
test("forgetting through either spelling removes the entry", slashMemory.snapshot(for: "/w/a/") == nil)

// --- distinct directories must not collide ---

test("sibling directories differ", WorkspaceTabMemory.key(for: "/w/a") != WorkspaceTabMemory.key(for: "/w/ab"))
test("a parent directory differs from its child",
     WorkspaceTabMemory.key(for: "/w") != WorkspaceTabMemory.key(for: "/w/a"))

print("done")
