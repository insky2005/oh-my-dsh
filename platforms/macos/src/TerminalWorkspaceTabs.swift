import Foundation

// MARK: - Per-workspace terminal tabs (pure Foundation, headless-testable)
//
// The terminal panel keeps one PTY session per tab, and tabs belong to the
// workspace (dsh session working directory) they were started in. Switching
// workspaces in dsh web must therefore HIDE the other workspace's tabs without
// killing their shells — a terminal is a running process, unlike a Files-panel
// preview tab (which is closed to release its editor, see WorkspaceTabMemory).
// Switching back shows the same tabs again, still running, with the previously
// selected one re-selected.
//
// Keying matches the Files panel: the key is the workspace directory
// (standardized, trailing slash stripped) so "/repo" and "/repo/" are one
// workspace.
//
// A tab spawned without a resolvable project directory (server booting, RPC
// failure → home fallback) is marked GLOBAL and stays visible in every
// workspace: the user did get a usable shell out of it and must not lose the
// tab by switching away.
//
// No AppKit here: the panel owns the UI, tests/terminal-panel/run.sh the model.

struct TerminalWorkspaceTabs {

    /// workspace key (or nil for a global tab) per tab id.
    private var workspaceByTab: [Int: String] = [:]
    /// Tab ids that belong to no particular workspace (home fallback spawns).
    private var globalTabs: Set<Int> = []
    /// Tab ids explicitly dropped by forget() (closed tabs).
    private var forgottenTabs: Set<Int> = []
    /// Last tab the user had selected in each workspace, so coming back
    /// re-selects the tab they left on.
    private var lastSelectedByWorkspace: [String: Int] = [:]

    /// Normalize a workspace directory path into its key (same normalization as
    /// the Files panel's tab memory).
    static func key(for path: String) -> String { WorkspaceTabMemory.key(for: path) }

    /// Record which workspace a tab belongs to. `workspacePath == nil` — or
    /// `isGlobal` — makes the tab visible in every workspace.
    mutating func assign(tabId: Int, workspacePath: String?, isGlobal: Bool = false) {
        forgottenTabs.remove(tabId)
        guard !isGlobal, let path = workspacePath else {
            globalTabs.insert(tabId)
            workspaceByTab.removeValue(forKey: tabId)
            return
        }
        globalTabs.remove(tabId)
        workspaceByTab[tabId] = Self.key(for: path)
    }

    /// Drop a closed tab from the model (its workspace memory of "last
    /// selected" is dropped too when it pointed at this tab).
    mutating func forget(tabId: Int) {
        workspaceByTab.removeValue(forKey: tabId)
        globalTabs.remove(tabId)
        // Remember that this id was explicitly dropped: an id we merely never
        // saw (defensive) stays visible, a forgotten one must not.
        forgottenTabs.insert(tabId)
        for (key, id) in lastSelectedByWorkspace where id == tabId {
            lastSelectedByWorkspace.removeValue(forKey: key)
        }
    }

    /// Forget everything (the panel's Close button terminates every session).
    mutating func forgetAll() {
        workspaceByTab.removeAll()
        globalTabs.removeAll()
        forgottenTabs.removeAll()
        lastSelectedByWorkspace.removeAll()
    }

    /// The workspace key of one tab (nil for a global tab or an unknown id).
    func workspaceKey(of tabId: Int) -> String? { workspaceByTab[tabId] }

    /// Whether a tab belongs to the workspace currently being viewed.
    func isVisible(tabId: Int, current: String) -> Bool {
        if forgottenTabs.contains(tabId) { return false }
        if globalTabs.contains(tabId) { return true }
        guard let key = workspaceByTab[tabId] else { return true }  // unassigned: never hide
        return key == Self.key(for: current)
    }

    /// The visible subset of `allIds`, keeping the caller's order.
    func visibleIds(_ allIds: [Int], current: String) -> [Int] {
        allIds.filter { isVisible(tabId: $0, current: current) }
    }

    /// Remember the user's selection inside a workspace.
    mutating func rememberSelection(tabId: Int, current: String) {
        lastSelectedByWorkspace[Self.key(for: current)] = tabId
    }

    /// The tab to re-select when returning to a workspace, when it is still
    /// open and visible there.
    func lastSelectedId(current: String, among allIds: [Int]) -> Int? {
        guard let remembered = lastSelectedByWorkspace[Self.key(for: current)],
              allIds.contains(remembered),
              isVisible(tabId: remembered, current: current) else { return nil }
        return remembered
    }

    /// Diagnostics / tests.
    var isEmpty: Bool { workspaceByTab.isEmpty && globalTabs.isEmpty }
}
