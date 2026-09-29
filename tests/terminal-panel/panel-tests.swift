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


// MARK: - DECSTBM scroll regions (vim/vi scroll their text area with one)
//
// Regression: vim sets a region that excludes the status line, then feeds LF
// at the region's bottom row. Ignoring the region made the cursor walk into
// the status line while the text never moved (arrow-key scrolling looked dead).

let reg = TerminalEmulator(rows: 6, cols: 10)
reg.feed("\u{1B}[1;4r")
reg.feed("\u{1B}[1;1HA\u{1B}[2;1HB\u{1B}[3;1HC\u{1B}[4;1HD\u{1B}[6;1HSTATUS")
reg.feed("\u{1B}[4;1H\n")
test("decstbm: LF at region bottom scrolls only the region",
     reg.screenCell(row: 0, col: 0).ch == "B" &&
     reg.screenCell(row: 1, col: 0).ch == "C" &&
     reg.screenCell(row: 2, col: 0).ch == "D" &&
     reg.screenCell(row: 3, col: 0).ch == " ")
test("decstbm: the status row is untouched", reg.screenCell(row: 5, col: 0).ch == "S")
test("decstbm: a partial region adds no scrollback", reg.totalLineCount == reg.rows)

let regRI = TerminalEmulator(rows: 6, cols: 10)
regRI.feed("\u{1B}[1;4r")
regRI.feed("\u{1B}[1;1HA\u{1B}[2;1HB\u{1B}[3;1HC\u{1B}[4;1HD\u{1B}[6;1HSTATUS")
regRI.feed("\u{1B}[1;1H\u{1B}M")
test("decstbm: RI at region top scrolls down inside the region",
     regRI.screenCell(row: 0, col: 0).ch == " " &&
     regRI.screenCell(row: 1, col: 0).ch == "A" &&
     regRI.screenCell(row: 2, col: 0).ch == "B" &&
     regRI.screenCell(row: 3, col: 0).ch == "C" &&
     regRI.screenCell(row: 5, col: 0).ch == "S")

let regIL = TerminalEmulator(rows: 6, cols: 10)
regIL.feed("\u{1B}[1;4r")
regIL.feed("\u{1B}[1;1HA\u{1B}[2;1HB\u{1B}[3;1HC\u{1B}[4;1HD\u{1B}[6;1HSTATUS")
regIL.feed("\u{1B}[2;1H\u{1B}[L")
test("decstbm: insert line stays inside the region",
     regIL.screenCell(row: 0, col: 0).ch == "A" &&
     regIL.screenCell(row: 1, col: 0).ch == " " &&
     regIL.screenCell(row: 2, col: 0).ch == "B" &&
     regIL.screenCell(row: 3, col: 0).ch == "C" &&
     regIL.screenCell(row: 5, col: 0).ch == "S")

let regDL = TerminalEmulator(rows: 6, cols: 10)
regDL.feed("\u{1B}[1;4r")
regDL.feed("\u{1B}[1;1HA\u{1B}[2;1HB\u{1B}[3;1HC\u{1B}[4;1HD\u{1B}[6;1HSTATUS")
regDL.feed("\u{1B}[2;1H\u{1B}[M")
test("decstbm: delete line stays inside the region",
     regDL.screenCell(row: 0, col: 0).ch == "A" &&
     regDL.screenCell(row: 1, col: 0).ch == "C" &&
     regDL.screenCell(row: 2, col: 0).ch == "D" &&
     regDL.screenCell(row: 3, col: 0).ch == " " &&
     regDL.screenCell(row: 5, col: 0).ch == "S")

let regSU = TerminalEmulator(rows: 6, cols: 10)
regSU.feed("\u{1B}[1;4r")
regSU.feed("\u{1B}[1;1HA\u{1B}[2;1HB\u{1B}[3;1HC\u{1B}[4;1HD\u{1B}[6;1HSTATUS")
regSU.feed("\u{1B}[1S")
test("decstbm: SU shifts only the region",
     regSU.screenCell(row: 0, col: 0).ch == "B" &&
     regSU.screenCell(row: 3, col: 0).ch == " " &&
     regSU.screenCell(row: 5, col: 0).ch == "S")
regSU.feed("\u{1B}[1T")
test("decstbm: SD shifts the region back",
     regSU.screenCell(row: 0, col: 0).ch == " " &&
     regSU.screenCell(row: 1, col: 0).ch == "B" &&
     regSU.screenCell(row: 2, col: 0).ch == "C" &&
     regSU.screenCell(row: 5, col: 0).ch == "S")

let regReset = TerminalEmulator(rows: 6, cols: 10)
regReset.feed("\u{1B}[1;4r")
regReset.feed("\u{1B}[1;1HTOP\u{1B}[6;1HBOT")
regReset.feed("\u{1B}[r")
regReset.feed("\u{1B}[6;1H\n")
test("decstbm: CSI r restores the full-screen region",
     regReset.screenCell(row: 4, col: 0).ch == "B" &&
     regReset.line(at: 0).contains { $0.ch == "T" })


// MARK: - Wide-glyph cursor span (CJK is two cells; the cursor must match)
//
// The monospaced system font's CJK fallback advances ~1.6 cells, not 2, so the
// glyph is now stretched to its two cells and the block cursor spans the pair.
// Pinned here is the span math drawCursor() uses for that block.

let cjkEmu = TerminalEmulator(rows: 4, cols: 20)
let cjkView = TerminalView(emulator: cjkEmu, session: nil)
cjkEmu.feed("\u{1B}[1;1H中")
test("wide cursor advance is two cells", cjkEmu.cursorCol == 2)
test("a cursor after a wide glyph stays one cell",
     cjkView.cursorGlyphSpan().col == 2 && cjkView.cursorGlyphSpan().width == 1)

cjkEmu.feed("\u{1B}[1;1H") // park the cursor on the wide glyph itself
test("a cursor on a wide glyph spans two cells",
     cjkView.cursorGlyphSpan().col == 0 && cjkView.cursorGlyphSpan().width == 2)

cjkEmu.feed("\u{1B}[1;2H") // park it on the continuation cell
test("a cursor on the continuation cell snaps back to the lead cell",
     cjkView.cursorGlyphSpan().col == 0 && cjkView.cursorGlyphSpan().width == 2)

cjkEmu.feed("\u{1B}[1;5H")
test("a cursor on a narrow/blank cell spans one cell",
     cjkView.cursorGlyphSpan().col == 4 && cjkView.cursorGlyphSpan().width == 1)

print("done")
