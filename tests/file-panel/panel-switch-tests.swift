import AppKit
import Foundation

// Headless end-to-end tests for the Files panel's workspace hand-off: the real
// FilePanelController is instantiated (no window, no dsh server) and driven
// through setProjectDirectory / open(path:) / the Close action, asserting which
// tabs are open afterwards. Usage: tests/file-panel/run.sh

func test(_ name: String, _ cond: Bool) {
    print((cond ? "ok" : "FAIL") + " - " + name)
    if !cond { exit(1) }
}

// AppKit views need an application instance to exist; no run loop is started.
_ = NSApplication.shared

// A throwaway workspace pair: A/{one.md, src/two.swift} and B/{b.md}.
let fm = FileManager.default
let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("file-panel-switch-" + UUID().uuidString)
let wsA = root.appendingPathComponent("A")
let wsB = root.appendingPathComponent("B")
let a1 = wsA.appendingPathComponent("one.md")
let a2 = wsA.appendingPathComponent("src/two.swift")
let aSrc = wsA.appendingPathComponent("src")
let b1 = wsB.appendingPathComponent("b.md")

try! fm.createDirectory(at: aSrc, withIntermediateDirectories: true)
try! fm.createDirectory(at: wsB, withIntermediateDirectories: true)
try! "# one".write(to: a1, atomically: true, encoding: .utf8)
try! "// two".write(to: a2, atomically: true, encoding: .utf8)
try! "# b".write(to: b1, atomically: true, encoding: .utf8)

let panel = FilePanelController()

// --- first root resolution keeps tabs opened before it (file links can open
// tabs while the tree has no root yet) -------------------------------------

panel.open(path: a1.path)
test("a file link opens a tab before any tree root exists", panel.openTabPaths == [a1.path])

panel.setProjectDirectory(wsA.path)
test("the first root resolution keeps that tab", panel.openTabPaths == [a1.path])

// --- switching away closes the old workspace's tabs ------------------------

panel.open(path: a2.path)
panel.open(path: a1.path)   // re-opening an open path selects it
test("tabs are listed in tab-bar order", panel.openTabPaths == [a1.path, a2.path])
test("re-opening an open path selects that tab", panel.selectedTabPath == a1.path)

panel.setProjectDirectory(wsB.path)
test("switching workspace closes the old workspace's tabs", panel.openTabPaths.isEmpty)
test("the closed workspace leaves no selection", panel.selectedTabPath == nil)

// --- switching back reopens them, in order, with the selection -------------

panel.setProjectDirectory(wsA.path)
test("switching back reopens the remembered tabs in order", panel.openTabPaths == [a1.path, a2.path])
test("switching back restores the remembered selection", panel.selectedTabPath == a1.path)

// --- each workspace keeps its own set --------------------------------------

panel.setProjectDirectory(wsB.path)
panel.open(path: b1.path)
test("the other workspace has its own tab", panel.openTabPaths == [b1.path])

panel.setProjectDirectory(wsA.path)
test("returning to A restores A's tabs, not B's", panel.openTabPaths == [a1.path, a2.path])

panel.setProjectDirectory(wsB.path)
test("returning to B restores B's tab", panel.openTabPaths == [b1.path])

// --- a remembered path that disappeared is skipped --------------------------

panel.setProjectDirectory(wsA.path)
panel.open(path: a2.path)                       // select the file we are about to delete
test("A's second tab can be selected", panel.selectedTabPath == a2.path)
panel.setProjectDirectory(wsB.path)
try! fm.removeItem(at: a2)
panel.setProjectDirectory(wsA.path)
test("a remembered file that no longer exists is skipped", panel.openTabPaths == [a1.path])
test("a selection that no longer exists falls back", panel.selectedTabPath == a1.path)

// --- folder tabs count too --------------------------------------------------

panel.open(path: aSrc.path)
test("a folder opens as a tab", panel.openTabPaths == [a1.path, aSrc.path])
panel.setProjectDirectory(wsB.path)
panel.setProjectDirectory(wsA.path)
test("folder tabs are restored as well", panel.openTabPaths == [a1.path, aSrc.path])

// --- re-pointing the same workspace never touches the tabs ------------------

panel.setProjectDirectory(wsA.path)
test("re-pointing the same workspace keeps the tabs", panel.openTabPaths == [a1.path, aSrc.path])
panel.setProjectDirectory(wsA.path + "/")
test("a trailing slash names the same workspace", panel.openTabPaths == [a1.path, aSrc.path])

// --- the Close button closes every tab AND forgets every workspace ----------

panel.performCloseAction()
test("Close closes every tab", panel.openTabPaths.isEmpty)
test("Close leaves nothing selected", panel.selectedTabPath == nil)

panel.setProjectDirectory(wsB.path)
test("nothing is reopened in another workspace after Close", panel.openTabPaths.isEmpty)
panel.setProjectDirectory(wsA.path)
test("switching back after Close reopens nothing", panel.openTabPaths.isEmpty)

// A workspace visited after Close still remembers from scratch.
panel.open(path: a1.path)
panel.setProjectDirectory(wsB.path)
panel.setProjectDirectory(wsA.path)
test("remembering works again after Close", panel.openTabPaths == [a1.path])

// --- unsaved edits: with no window to confirm in, the switch is aborted ------
// (the save / discard / cancel sheet itself needs a window and is covered by the
// manual pass in .dsh/wiki/tasks.md; this pins the no-window guard, which is
// what keeps a headless / QA run from silently discarding the user's edits)

func firstEditableTextView(in view: NSView) -> NSTextView? {
    if let tv = view as? NSTextView, tv.isEditable { return tv }
    for sub in view.subviews {
        if let found = firstEditableTextView(in: sub) { return found }
    }
    return nil
}

panel.open(path: a1.path)
let editor = firstEditableTextView(in: panel.view)
test("the open tab's editable text view is reachable", editor != nil)

editor?.insertText("x", replacementRange: NSRange(location: 0, length: 0))
panel.setProjectDirectory(wsB.path)
test("an unsaved edit with no window to confirm in aborts the switch", panel.openTabPaths == [a1.path])

// Regression: an aborted (or user-cancelled) switch must only DEFER, never
// blacklist the target — a later request for the same workspace has to be
// attempted again. It used to be swallowed forever ("stays declined"), leaving
// the panel silently stuck on a workspace it had stopped following.
panel.saveActiveTab()
panel.setProjectDirectory(wsB.path)
test("a later switch to the same workspace is attempted again", panel.openTabPaths.isEmpty)

panel.setProjectDirectory(wsA.path)
test("that workspace is reachable once more afterwards", panel.openTabPaths == [a1.path])

panel.performCloseAction()
test("closing the panel still clears everything", panel.openTabPaths.isEmpty)

try? fm.removeItem(at: root)
print("done")
