import Foundation

// MARK: - Files panel tree context-menu model (pure Foundation, headless-testable)
//
// What the directory tree's right-click menu offers depends on WHAT was clicked:
// a folder can host a new folder, a file cannot; the project root itself can be
// neither renamed nor deleted; a click on empty space can only create.
//
// Keeping that decision here (no AppKit) makes the ordering and the visibility
// rules testable — see tests/file-panel/run.sh. FilePanelController only turns the
// entries into NSMenuItems.

/// One entry of the tree's context menu.
enum TreeMenuItem: String, Equatable, CaseIterable {
    case newFolder
    case newFile
    case rename
    case delete
    case reveal
}

/// A menu entry plus how it is presented.
struct TreeMenuEntry: Equatable {
    let item: TreeMenuItem
    /// Draw a separator above this entry (the create group / the item group).
    let separatorBefore: Bool
    let enabled: Bool
}

enum TreeMenuModel {

    /// The menu for a right click on the tree.
    ///
    /// - Parameters:
    ///   - hasRoot: the panel has a project directory loaded (no root → no menu).
    ///   - hasRow: the click landed on a row (empty space → create-only).
    ///   - isRoot: that row IS the project root (it cannot be renamed/deleted).
    ///   - isFile: that row is a file (creating a folder is offered for folders).
    static func entries(hasRoot: Bool, hasRow: Bool, isRoot: Bool, isFile: Bool) -> [TreeMenuEntry] {
        guard hasRoot else { return [] }
        var entries: [TreeMenuEntry] = []

        // Group 1: create inside the clicked directory.
        // A file's menu is about that file, so "New Folder" is not offered for it
        // (QA feedback) — "New File" still is: it lands next to the file.
        if !isFile {
            entries.append(TreeMenuEntry(item: .newFolder, separatorBefore: false, enabled: true))
        }
        entries.append(TreeMenuEntry(item: .newFile, separatorBefore: false, enabled: true))

        // Group 2: operations on the clicked entry (root excluded).
        if hasRow {
            let mutable = !isRoot
            entries.append(TreeMenuEntry(item: .rename, separatorBefore: true, enabled: mutable))
            entries.append(TreeMenuEntry(item: .delete, separatorBefore: false, enabled: mutable))
            entries.append(TreeMenuEntry(item: .reveal, separatorBefore: false, enabled: true))
        }
        return entries
    }
}
