import Foundation

// MARK: - Workspace tab memory for the file panel (pure Foundation, headless-testable)
//
// The Files panel (FilePanelController) follows the active dsh session's
// workspace: when the user switches to a session in another workspace, the
// project tree is re-rooted. Open preview tabs belong to the OLD workspace and
// must not stay mounted on the new one (they hold editors, syntax highlighters
// and preview views alive), so the panel closes them and remembers what was
// open, then reopens the same tabs when the user comes back.
//
// This file holds only the per-workspace bookkeeping: no AppKit, so it is unit
// testable headless (tests/file-panel/run.sh). The panel owns the UI side.
//
// Keying: the key is the panel's tree root — i.e. the workspace directory the
// tabs were browsed under (including a folder the user picked manually). Paths
// are normalized with `standardizingPath` plus a trailing-slash strip so
// "/repo" and "/repo/" name the same workspace; symbolic links are NOT resolved
// (matching how FilePanelController.open(path:) normalizes tab paths).

/// Remembers, per workspace directory, which preview tabs were open (in tab-bar
/// order) and which one was selected — so a workspace switch can close every tab
/// (releasing its content) and restore the same set later.
struct WorkspaceTabMemory {

    /// The remembered tab set of one workspace.
    struct Snapshot: Equatable {
        /// Tab paths in tab-bar order (directories included: folder tabs count).
        var paths: [String]
        /// The selected tab's path, when one was selected.
        var selectedPath: String?
    }

    /// workspace key -> snapshot. A workspace with no open tabs has NO entry
    /// (an empty list must never be restored as "nothing to reopen").
    private var snapshots: [String: Snapshot] = [:]

    /// Normalize a workspace directory path into its memory key.
    static func key(for workspacePath: String) -> String {
        var path = (workspacePath as NSString).standardizingPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    /// Record the open tabs of a workspace. An empty `paths` forgets the
    /// workspace (nothing to reopen); otherwise the snapshot replaces any
    /// previous one for that workspace.
    mutating func remember(paths: [String], selectedPath: String?, for workspacePath: String) {
        let k = Self.key(for: workspacePath)
        guard !paths.isEmpty else {
            snapshots.removeValue(forKey: k)
            return
        }
        snapshots[k] = Snapshot(paths: paths, selectedPath: selectedPath)
    }

    /// The tabs remembered for a workspace, or nil when nothing was remembered.
    func snapshot(for workspacePath: String) -> Snapshot? {
        snapshots[Self.key(for: workspacePath)]
    }

    /// Forget one workspace (unused today; the panel clears everything at once).
    mutating func forget(workspacePath: String) {
        snapshots.removeValue(forKey: Self.key(for: workspacePath))
    }

    /// Forget every workspace — the panel's Close button reclaims all resources.
    mutating func forgetAll() {
        snapshots.removeAll()
    }

    /// Whether anything is remembered (diagnostics / tests).
    var isEmpty: Bool { snapshots.isEmpty }
}
