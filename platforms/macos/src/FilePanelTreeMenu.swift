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
    case addToConversation
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
    ///   - isRoot: that row IS the project root (it cannot be renamed/deleted, and
    ///     it has no workspace-relative path to reference in the composer).
    ///   - isFile: that row is a file (creating a folder is offered for folders).
    ///   - canReference: the row has a usable `@` mention AND someone is listening
    ///     (the shell injects it into dsh web's composer).
    static func entries(hasRoot: Bool, hasRow: Bool, isRoot: Bool, isFile: Bool,
                        canReference: Bool = false) -> [TreeMenuEntry] {
        guard hasRoot else { return [] }
        var entries: [TreeMenuEntry] = []

        // Group 0: hand the entry to the conversation. It leads the menu (it is
        // the one entry that only ever ADDS something, to a place the user is
        // already looking at) and it is the only group offered for every row kind.
        if hasRow {
            entries.append(TreeMenuEntry(item: .addToConversation, separatorBefore: false,
                                         enabled: !isRoot && canReference))
        }

        // Group 1: create inside the clicked directory. A FILE's menu is about that
        // file, so it offers no creation at all (QA feedback: neither "New Folder"
        // nor "New File" — you rename it, delete it, or reveal it).
        if !isFile {
            entries.append(TreeMenuEntry(item: .newFolder, separatorBefore: !entries.isEmpty, enabled: true))
            entries.append(TreeMenuEntry(item: .newFile, separatorBefore: false, enabled: true))
        }

        // Group 2: operations on the clicked entry (root excluded).
        if hasRow {
            let mutable = !isRoot
            entries.append(TreeMenuEntry(item: .rename, separatorBefore: true, enabled: mutable))
            entries.append(TreeMenuEntry(item: .delete, separatorBefore: false, enabled: mutable))
            // Group 3: revealing does not mutate the entry, so it gets its own
            // group (QA feedback).
            entries.append(TreeMenuEntry(item: .reveal, separatorBefore: true, enabled: true))
        }
        return entries
    }
}
