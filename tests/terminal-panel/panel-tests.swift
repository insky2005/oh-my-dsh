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

print("done")
