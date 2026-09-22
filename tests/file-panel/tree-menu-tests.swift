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

// A right click on a FOLDER that can be referenced in the conversation: the
// conversation group leads, then create, then the item group.
let onFolder = TreeMenuModel.entries(hasRoot: true, hasRow: true, isRoot: false, isFile: false,
                                     canReference: true)
test("a folder leads with Add to Conversation, then create + rename/delete/reveal",
     items(onFolder) == [.addToConversation, .newFolder, .newFile, .rename, .delete, .reveal])
test("Add to Conversation is enabled when the shell can take it",
     enabled(onFolder, .addToConversation) == true)
test("the create group is separated from Add to Conversation",
     onFolder.first { $0.item == .newFolder }?.separatorBefore == true)
test("the create group and the item group are separated",
     onFolder.first { $0.item == .rename }?.separatorBefore == true)
test("Show in Finder sits in a group of its own",
     onFolder.first { $0.item == .reveal }?.separatorBefore == true)
test("Delete stays with Rename", onFolder.first { $0.item == .delete }?.separatorBefore == false)
test("no separator above the first entry", onFolder.first?.separatorBefore == false)
test("every folder entry is enabled", onFolder.allSatisfy { $0.enabled })

// A right click on a FILE: the menu is about that file only — no creation at all.
let onFile = TreeMenuModel.entries(hasRoot: true, hasRow: true, isRoot: false, isFile: true,
                                   canReference: true)
test("a file offers the conversation entry, no creation",
     items(onFile) == [.addToConversation, .rename, .delete, .reveal])
test("a file can be added to the conversation", enabled(onFile, .addToConversation) == true)
test("a file gets its own group for Show in Finder",
     onFile.first { $0.item == .reveal }?.separatorBefore == true)
test("every file entry is enabled", onFile.allSatisfy { $0.enabled })

// No listener (or no representable path): the entry stays visible but disabled —
// the panel never pretends there is a conversation to add to.
let onFileNoSink = TreeMenuModel.entries(hasRoot: true, hasRow: true, isRoot: false, isFile: true)
test("without a reference the entry is still offered", items(onFileNoSink).first == .addToConversation)
test("without a reference the entry is disabled", enabled(onFileNoSink, .addToConversation) == false)

// The project root: visible but immutable — and it has no workspace-relative path.
let onRoot = TreeMenuModel.entries(hasRoot: true, hasRow: true, isRoot: true, isFile: false,
                                   canReference: true)
test("the root offers creation", enabled(onRoot, .newFolder) == true && enabled(onRoot, .newFile) == true)
test("the root cannot be renamed or deleted",
     enabled(onRoot, .rename) == false && enabled(onRoot, .delete) == false)
test("the root can still be revealed", enabled(onRoot, .reveal) == true)
test("the root cannot be added to the conversation (there is no relative path)",
     enabled(onRoot, .addToConversation) == false)

// A click on empty space: creation only (target = the tree root).
let onEmptySpace = TreeMenuModel.entries(hasRoot: true, hasRow: false, isRoot: false, isFile: false)
test("empty space offers creation only", items(onEmptySpace) == [.newFolder, .newFile])
test("empty space offers no conversation entry",
     onEmptySpace.allSatisfy { $0.item != .addToConversation })

// No project directory loaded: no menu at all.
let noRoot = TreeMenuModel.entries(hasRoot: false, hasRow: false, isRoot: false, isFile: false)
test("no project directory means no menu", noRoot.isEmpty)

test("every entry maps to a distinct menu item",
     Set(TreeMenuItem.allCases).count == TreeMenuItem.allCases.count)

print("done")
