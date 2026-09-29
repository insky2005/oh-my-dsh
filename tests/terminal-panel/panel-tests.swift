import AppKit
import Foundation

// Headless tests for the terminal panel's fixed header title. The controller is
// instantiated WITHOUT spawning a session: TerminalSession opens a PTY
// (openpty/fork), which the sandbox may deny, so the session-driving paths
// (select / OSC title / session ended) are covered by the manual pass in
// .dsh/wiki/tasks.md. What is pinned here is the invariant that survived a
// regression in the Files panel too: the header shows the PANEL NAME, never a
// path / session title. Usage: tests/terminal-panel/run.sh

func test(_ name: String, _ cond: Bool) {
    print((cond ? "ok" : "FAIL") + " - " + name)
    if !cond { exit(1) }
}

_ = NSApplication.shared

let panel = TerminalPanelController()

test("the header shows the panel's fixed title", panel.headerTitleText == "bar.terminal")
test("the header starts without a tooltip", panel.headerTooltipText == nil)

// A language switch re-resolves the title through refreshTooltips().
panel.refreshTooltips()
test("a language switch keeps the fixed title", panel.headerTitleText == "bar.terminal")

// Closing every session (no session was opened) must not blank the title.
panel.closeAllSessions()
test("closing sessions keeps the fixed title", panel.headerTitleText == "bar.terminal")

// MARK: - Per-workspace tabs (issue #5 in docs/ux-feedback.md)
//
// The panel hides the tabs of the workspace being left and brings them back on
// return; the sessions themselves keep running, so this is pure bookkeeping and
// testable without a PTY.

var ws = TerminalWorkspaceTabs()
ws.assign(tabId: 1, workspacePath: "/repo/alpha")
ws.assign(tabId: 2, workspacePath: "/repo/beta")
ws.assign(tabId: 3, workspacePath: "/repo/alpha")

test("tabs of the shown workspace are visible",
     ws.visibleIds([1, 2, 3], current: "/repo/alpha") == [1, 3])
test("a trailing slash names the same workspace",
     ws.visibleIds([1, 2, 3], current: "/repo/alpha/") == [1, 3])
test("switching workspace swaps the visible tabs",
     ws.visibleIds([1, 2, 3], current: "/repo/beta") == [2])
test("each tab keeps its own workspace key",
     ws.workspaceKey(of: 2) == TerminalWorkspaceTabs.key(for: "/repo/beta"))

// A tab spawned without a resolvable project directory (home fallback) must
// stay reachable from every workspace — the user got a usable shell out of it.
ws.assign(tabId: 4, workspacePath: nil, isGlobal: true)
test("a fallback tab is visible in every workspace",
     ws.visibleIds([1, 4], current: "/repo/alpha") == [1, 4] &&
     ws.visibleIds([1, 4], current: "/repo/beta") == [4] &&
     ws.visibleIds([1, 4], current: "/elsewhere") == [4])

// Returning to a workspace re-selects the tab the user left on.
ws.rememberSelection(tabId: 3, current: "/repo/alpha")
ws.rememberSelection(tabId: 2, current: "/repo/beta")
test("returning to a workspace restores its selected tab",
     ws.lastSelectedId(current: "/repo/alpha", among: [1, 2, 3]) == 3)
ws.forget(tabId: 3)
test("a closed tab is not restored",
     ws.lastSelectedId(current: "/repo/alpha", among: [1, 2, 3]) == nil)
test("a closed tab disappears from the visible set",
     ws.visibleIds([1, 3], current: "/repo/alpha") == [1])

ws.forgetAll()
test("closing the panel forgets every tab", ws.isEmpty)

// Auto-copy on selection (issue #4) defaults to ON and follows ShellConfig.
test("terminal auto-copy defaults to on", TerminalView.autoCopyEnabled)
ShellConfig.shared.set(false, forKey: TerminalView.autoCopyKey)
test("terminal auto-copy follows the setting", !TerminalView.autoCopyEnabled)

// MARK: - IME / input-method pre-edit (NSTextInputClient)
//
// The terminal IS the text buffer, so the only composer state the view keeps is
// the pending pre-edit. These tests pin the NSTextInputClient bookkeeping that
// lets macOS keep the input method engaged; none of them opens a PTY (session is
// nil, so a commit is a no-op write).

let term = TerminalView(emulator: TerminalEmulator(rows: 24, cols: 80), session: nil)

test("no composition initially",
     !term.hasMarkedText() && term.markedRange().location == NSNotFound)

term.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                   replacementRange: NSRange(location: NSNotFound, length: 0))
test("a pre-edit becomes marked text",
     term.hasMarkedText() && term.markedRange() == NSRange(location: 0, length: 2))
test("the insertion point sits after the pre-edit",
     term.selectedRange() == NSRange(location: 2, length: 0))
test("the pre-edit is addressable as the attributed substring",
     term.attributedSubstring(forProposedRange: NSRange(location: 0, length: 2),
                              actualRange: nil)?.string == "ni")
test("a range outside the pre-edit has no substring",
     term.attributedSubstring(forProposedRange: NSRange(location: 5, length: 2),
                              actualRange: nil) == nil)
test("marked-text attributes advertise the underline",
     term.validAttributesForMarkedText().contains(.underlineStyle))

term.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
test("committing clears the composition",
     !term.hasMarkedText() && term.markedRange().location == NSNotFound)

term.setMarkedText("hao", selectedRange: NSRange(location: 3, length: 0),
                   replacementRange: NSRange(location: NSNotFound, length: 0))
term.unmarkText()
test("cancelling clears the composition", !term.hasMarkedText())

// An empty marked string unmarks per the protocol docs.
term.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0),
                   replacementRange: NSRange(location: NSNotFound, length: 0))
term.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                   replacementRange: NSRange(location: NSNotFound, length: 0))
test("an empty marked string unmarks", !term.hasMarkedText())

// Without a window the candidate-window anchor degrades to the origin.
test("firstRect degrades to zero without a window",
     term.firstRect(forCharacterRange: NSRange(location: 0, length: 0),
                    actualRange: nil) == .zero)

print("done")
