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
// A wide glyph occupies exactly two cells via the full-width font (see the
// "Wide-glyph font" section below), and the block cursor spans the pair.
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

// MARK: - Hover-to-focus
//
// Entering the terminal grabs the keyboard so the user can type without
// clicking first. The tracking area is what makes that possible; mouseEntered
// then calls makeFirstResponder.

let hoverView = TerminalView(emulator: TerminalEmulator(rows: 4, cols: 20), session: nil)
hoverView.updateTrackingAreas()
test("the terminal installs a hover-to-focus tracking area",
     hoverView.trackingAreas.contains {
         $0.owner === hoverView && $0.options.contains(.mouseEnteredAndExited)
     })

// MARK: - Keyboard input source (IME) on focus / blur
//
// On focus the terminal switches to an ASCII-capable source and remembers the
// user's; on blur it restores it. The remembered original is write-once: a
// repeated focus (hover-then-click both route through makeFirstResponder) must
// not overwrite it with the forced English.

final class FakeInputSources: InputSourceControlling {
    var current: String?
    var ascii: String?
    var selectCalls: [String] = []
    var selectSucceeds = true
    func currentInputSourceID() -> String? { current }
    func asciiInputSourceID() -> String? { ascii }
    @discardableResult
    func selectInputSource(id: String) -> Bool {
        selectCalls.append(id)
        if selectSucceeds { current = id }
        return selectSucceeds
    }
}

let fakeSources = FakeInputSources()
fakeSources.current = "com.baidu.inputmethod.BaiduIM.pinyin"
fakeSources.ascii = "com.apple.keylayout.ABC"
let inputGuard = TerminalInputSourceGuard(sources: fakeSources)

inputGuard.terminalDidFocus()
test("terminal focus switches to the ASCII input source",
     fakeSources.current == "com.apple.keylayout.ABC" &&
     fakeSources.selectCalls == ["com.apple.keylayout.ABC"])
test("the original input source is remembered", inputGuard.hasSavedSource)

// A second focus must not overwrite the remembered original with English.
inputGuard.terminalDidFocus()
test("a repeated focus does not overwrite the original",
     fakeSources.selectCalls == ["com.apple.keylayout.ABC"] && inputGuard.hasSavedSource)

inputGuard.terminalDidBlur()
test("terminal blur restores the original input source",
     fakeSources.current == "com.baidu.inputmethod.BaiduIM.pinyin" &&
     fakeSources.selectCalls == ["com.apple.keylayout.ABC",
                                 "com.baidu.inputmethod.BaiduIM.pinyin"])
test("the remembered original is cleared after restore", !inputGuard.hasSavedSource)

// Already on English: nothing to switch, and a manual mid-session switch to
// Chinese is left alone when focus leaves.
let alreadyEnglish = FakeInputSources()
alreadyEnglish.current = "com.apple.keylayout.ABC"
alreadyEnglish.ascii = "com.apple.keylayout.ABC"
let englishGuard = TerminalInputSourceGuard(sources: alreadyEnglish)
englishGuard.terminalDidFocus()
test("focusing from English does not select anything",
     alreadyEnglish.selectCalls.isEmpty && !englishGuard.hasSavedSource)
alreadyEnglish.current = "com.baidu.inputmethod.BaiduIM.pinyin"   // user switches
englishGuard.terminalDidBlur()
test("a manual switch is kept when the terminal never changed the source",
     alreadyEnglish.current == "com.baidu.inputmethod.BaiduIM.pinyin" &&
     alreadyEnglish.selectCalls.isEmpty)

// No ASCII-capable source: stay out of the user's way.
let noAscii = FakeInputSources()
noAscii.current = "com.baidu.inputmethod.BaiduIM.pinyin"
noAscii.ascii = nil
let noAsciiGuard = TerminalInputSourceGuard(sources: noAscii)
noAsciiGuard.terminalDidFocus()
noAsciiGuard.terminalDidBlur()
test("no ASCII source: nothing is changed or remembered",
     noAscii.current == "com.baidu.inputmethod.BaiduIM.pinyin" &&
     noAscii.selectCalls.isEmpty && !noAsciiGuard.hasSavedSource)

// If the system refuses the restore, the original must survive for the next
// attempt instead of being replaced by the forced English.
let failing = FakeInputSources()
failing.current = "com.baidu.inputmethod.BaiduIM.pinyin"
failing.ascii = "com.apple.keylayout.ABC"
let failingGuard = TerminalInputSourceGuard(sources: failing)
failingGuard.terminalDidFocus()
failing.selectSucceeds = false
failingGuard.terminalDidBlur()
test("a failed restore keeps the original remembered",
     failing.current == "com.apple.keylayout.ABC" && failingGuard.hasSavedSource)
failingGuard.terminalDidFocus()   // must not overwrite the original
test("focus after a failed restore does not overwrite the original",
     failing.selectCalls == ["com.apple.keylayout.ABC",
                             "com.baidu.inputmethod.BaiduIM.pinyin"])
failing.selectSucceeds = true
failingGuard.terminalDidBlur()
test("the original is restored once the system accepts it",
     failing.current == "com.baidu.inputmethod.BaiduIM.pinyin" && !failingGuard.hasSavedSource)

// MARK: - Focus cursor (solid when focused, hollow when not)
//
// The block cursor is filled while the terminal owns the keyboard and turns
// into an outline once it does not, so an inactive pane still shows where the
// caret is without looking active.

let cursorView = TerminalView(emulator: TerminalEmulator(rows: 4, cols: 20), session: nil)
test("the cursor starts hollow while unfocused", cursorView.cursorIsHollowForTesting)
cursorView.setFocusedForTesting(true)
test("a focused terminal shows the solid cursor", !cursorView.cursorIsHollowForTesting)
cursorView.setFocusedForTesting(false)
test("losing focus makes the cursor hollow again", cursorView.cursorIsHollowForTesting)

// MARK: - Wide-glyph font (no horizontal stretch distortion)
//
// The monospaced system font has no CJK glyphs; its default fallback renders
// full-width punctuation at only ~0.8 cell and Han at ~1.6 cells, and the old
// code stretched those to two cells (Chinese punctuation looked deformed). The
// wide path now sizes a real full-width face so its natural advance is exactly
// two cells — no horizontal stretch at all.

for ch in ["。" as Character, "，" as Character, "！" as Character,
           "（" as Character, "中" as Character, "国" as Character] {
    if let f = cjkView.wideGlyphFontForTesting(ch) {
        let advance = (String(ch) as NSString).size(withAttributes: [.font: f]).width
        test("wide glyph \(ch) advances exactly two cells",
             abs(advance - cjkView.cellWidthForTesting * 2) < 0.1)
    } else {
        test("wide glyph \(ch) resolves to a sized full-width font", false)
    }
}

// MARK: - First terminal open must spawn exactly one session
//
// Regression: setRightPanel(.terminal) adopts the current workspace and then
// calls ensureSession(). Both auto-spawned; because cwd resolution is
// asynchronous (visibleTabs is still empty when ensureSession runs) the panel
// opened with TWO shells. No PTY is opened here: the server is never marked
// ready, so each spawn is merely queued in deferredSpawns.
//
// The guard is the FIRST workspace adoption: it must not auto-spawn — the
// panel's own ensureSession() owns that first session. A LATER switch to a
// terminal-less workspace still auto-spawns (#5).

let firstOpen = TerminalPanelController()
let firstOpenWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                               styleMask: [.titled], backing: .buffered, defer: false)
firstOpenWindow.contentView?.addSubview(firstOpen.view)
firstOpen.setWorkspaceDirectory("/repo/alpha")   // panel-open: adopt workspace…
firstOpen.ensureSession()                        // …then ensure the first session
test("first terminal open queues exactly one session", firstOpen.queuedSpawnCount == 1)
firstOpen.closeAllSessions()

let switchWs = TerminalPanelController()
let switchWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                            styleMask: [.titled], backing: .buffered, defer: false)
switchWindow.contentView?.addSubview(switchWs.view)
switchWs.setWorkspaceDirectory("/repo/alpha")    // first adoption: no spawn
switchWs.ensureSession()                         // one queued
switchWs.setWorkspaceDirectory("/repo/beta")     // later switch to a tab-less ws
test("a later switch to a terminal-less workspace still auto-spawns",
     switchWs.queuedSpawnCount == 2)
switchWs.closeAllSessions()

print("done")
