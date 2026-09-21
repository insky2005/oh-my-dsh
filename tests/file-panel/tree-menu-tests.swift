import Foundation

// Headless tests for the Files panel tree context menu (FilePanelTreeMenu.swift):
// order, which entries appear, and which are enabled — the rules the panel turns
// into NSMenuItems (docs/ux-feedback.md #1). Usage: tests/file-panel/run.sh

func test(_ name: String, _ cond: Bool) {
    print((cond ? "ok" : "FAIL") + " - " + name)
    if !cond { exit(1) }
}

/// Convenience: the menu items for a click, without the separators.
func items(_ entries: [TreeMenuEntry]) -> [TreeMenuItem] { entries.map(\.item) }
func enabled(_ entries: [TreeMenuEntry], _ item: TreeMenuItem) -> Bool? {
    entries.first { $0.item == item }?.enabled
}

// A right click on a FOLDER: create group, then the item group.
let onFolder = TreeMenuModel.entries(hasRoot: true, hasRow: true, isRoot: false, isFile: false)
test("a folder offers create + rename/delete/reveal in that order",
     items(onFolder) == [.newFolder, .newFile, .rename, .delete, .reveal])
test("the create group and the item group are separated",
     onFolder.first { $0.item == .rename }?.separatorBefore == true)
test("Show in Finder sits in a group of its own",
     onFolder.first { $0.item == .reveal }?.separatorBefore == true)
test("Delete stays with Rename", onFolder.first { $0.item == .delete }?.separatorBefore == false)
test("no separator above New Folder", onFolder.first?.separatorBefore == false)
test("every folder entry is enabled", onFolder.allSatisfy { $0.enabled })

// A right click on a FILE: no "New Folder" (the menu is about that file), and the
// ordering/separator stay the same.
let onFile = TreeMenuModel.entries(hasRoot: true, hasRow: true, isRoot: false, isFile: true)
test("a file has no New Folder", items(onFile) == [.newFile, .rename, .delete, .reveal])
test("a file can still create a sibling file", enabled(onFile, .newFile) == true)
test("the separator stays above Rename for a file",
     onFile.first { $0.item == .rename }?.separatorBefore == true)
test("a file gets its own group for Show in Finder too",
     onFile.first { $0.item == .reveal }?.separatorBefore == true)

// The project root: visible but immutable.
let onRoot = TreeMenuModel.entries(hasRoot: true, hasRow: true, isRoot: true, isFile: false)
test("the root offers creation", enabled(onRoot, .newFolder) == true && enabled(onRoot, .newFile) == true)
test("the root cannot be renamed or deleted",
     enabled(onRoot, .rename) == false && enabled(onRoot, .delete) == false)
test("the root can still be revealed", enabled(onRoot, .reveal) == true)

// A click on empty space: creation only (target = the tree root).
let onEmptySpace = TreeMenuModel.entries(hasRoot: true, hasRow: false, isRoot: false, isFile: false)
test("empty space offers creation only", items(onEmptySpace) == [.newFolder, .newFile])

// No project directory loaded: no menu at all.
let noRoot = TreeMenuModel.entries(hasRoot: false, hasRow: false, isRoot: false, isFile: false)
test("no project directory means no menu", noRoot.isEmpty)

test("every entry maps to a distinct menu item",
     Set(TreeMenuItem.allCases).count == TreeMenuItem.allCases.count)

print("done")
