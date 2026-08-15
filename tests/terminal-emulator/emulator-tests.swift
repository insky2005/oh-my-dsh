import AppKit
import Foundation

// Headless unit tests for TerminalEmulator (no PTY — forkpty is blocked in
// this dev sandbox). Compile with stubs.swift + TerminalPanel.swift.

var failures = 0
func check(_ name: String, _ cond: Bool) {
    if cond { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}
func approx(_ c: NSColor?, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool {
    guard let c = c?.usingColorSpace(.sRGB) else { return false }
    return abs(c.redComponent - r) < 0.01 && abs(c.greenComponent - g) < 0.01 && abs(c.blueComponent - b) < 0.01
}

// --- plain text, cursor ---
let emu = TerminalEmulator(rows: 10, cols: 20)
emu.feed("Hello")
check("plain text", emu.screenCell(row: 0, col: 0).ch == "H" && emu.screenCell(row: 0, col: 4).ch == "o")
check("cursor col", emu.cursorCol == 5)
emu.feed("\r\nB")
check("crlf moves down", emu.screenCell(row: 1, col: 0).ch == "B" && emu.cursorRow == 1)
emu.feed("\u{08}\u{08}")
check("backspace", emu.cursorCol == 0)

// --- SGR colors ---
emu.feed("\u{1B}[H\u{1B}[2J")
emu.feed("\u{1B}[31mR")
check("sgr red fg", emu.screenCell(row: 0, col: 0).fg == TerminalEmulator.basePalette[1])
emu.feed("\u{1B}[0mG")
check("sgr reset fg", emu.screenCell(row: 0, col: 1).fg == nil)
emu.feed("\u{1B}[1m\u{1B}[44mB")
let boldBlue = emu.screenCell(row: 0, col: 2)
check("sgr bold+bg", boldBlue.bold && boldBlue.bg == TerminalEmulator.basePalette[4])
emu.feed("\u{1B}[7mI")
check("sgr inverse", emu.screenCell(row: 0, col: 3).inverse)

// --- 256 + truecolor ---
emu.feed("\u{1B}[H\u{1B}[2J")
emu.feed("\u{1B}[38;5;196mX")
check("sgr 256", emu.screenCell(row: 0, col: 0).fg == TerminalEmulator.palette256(196))
emu.feed("\u{1B}[H\u{1B}[2J")
emu.feed("\u{1B}[38;2;10;20;30mX")
check("sgr truecolor", approx(emu.screenCell(row: 0, col: 0).fg, 10/255, 20/255, 30/255))

// --- cursor addressing ---
emu.feed("\u{1B}[H\u{1B}[2J")
emu.feed("\u{1B}[3;5HX")
check("cup", emu.cursorRow == 2 && emu.cursorCol == 5 && emu.screenCell(row: 2, col: 4).ch == "X")
emu.feed("\u{1B}[G") // CHA default col 1
check("cha", emu.cursorCol == 0)
emu.feed("\u{1B}[B\u{1B}[C") // down + right
check("cud/cuf", emu.cursorRow == 3 && emu.cursorCol == 1)
emu.feed("\u{1B}[s\u{1B}[H\u{1B}[u")
check("save/restore cursor", emu.cursorRow == 3 && emu.cursorCol == 1)

// --- erase ---
emu.feed("\u{1B}[H\u{1B}[2J")
emu.feed("abcdef")
emu.feed("\u{1B}[H\u{1B}[K") // erase to end of line
check("erase line 0", emu.screenCell(row: 0, col: 0).ch == " ")
emu.feed("zz\u{1B}[H\u{1B}[2K")
check("erase whole line", emu.screenCell(row: 0, col: 1).ch == " ")
emu.feed("\u{1B}[H\u{1B}[2J")
emu.feed("top")
emu.feed("\u{1B}[5;1Hbottom\u{1B}[2J")
check("erase display", emu.screenCell(row: 0, col: 0).ch == " " && emu.screenCell(row: 4, col: 0).ch == " ")

// --- insert/delete chars ---
emu.feed("\u{1B}[H\u{1B}[2J")
emu.feed("ABCDE\u{1B}[D\u{1B}[D\u{1B}[P") // cursor on C, delete → ABDE
check("delete char", emu.screenCell(row: 0, col: 3).ch == "E" && emu.screenCell(row: 0, col: 4).ch == " ")
emu.feed("\u{1B}[H\u{1B}[2J")
emu.feed("ABC\u{1B}[D\u{1B}[@") // insert at col 2 → AB C? (blank at 2)
check("insert char", emu.screenCell(row: 0, col: 2).ch == " " && emu.screenCell(row: 0, col: 3).ch == "C")

// --- wide chars ---
emu.feed("\u{1B}[H\u{1B}[2J")
emu.feed("中")
check("wide char occupies 2", emu.screenCell(row: 0, col: 0).ch == "中" && emu.screenCell(row: 0, col: 1).continuation)
check("wide cursor advance", emu.cursorCol == 2)
emu.feed("\u{08}\u{08}") // bs to col 0
emu.feed("A")
check("overwrite wide start clears continuation", emu.screenCell(row: 0, col: 0).ch == "A" && !emu.screenCell(row: 0, col: 1).continuation)

// --- autowrap ---
emu.feed("\u{1B}[H\u{1B}[2J")
emu.feed(String(repeating: "A", count: 20))
check("wrap pending at last col", emu.cursorCol == 19)
emu.feed("B")
check("autowrap to next line", emu.screenCell(row: 1, col: 0).ch == "B" && emu.cursorRow == 1)

// --- tab ---
emu.feed("\u{1B}[H\u{1B}[2J")
emu.feed("\t")
check("tab to col 8", emu.cursorCol == 8)

// --- scrollback ---
emu.feed("\u{1B}[H\u{1B}[2J")
for _ in 0..<12 { emu.feed("X\n") }
check("scrollback grows", emu.totalLineCount == 13) // 3 pushed + 10 screen
check("scrollback content", emu.line(at: 0).contains { $0.ch == "X" })

// --- clearScreen (Cmd+K) ---
emu.feed("\u{1B}[H\u{1B}[2J")
emu.feed("garbage")
emu.clearScreen()
check("clearScreen", emu.screenCell(row: 0, col: 0).ch == " " && emu.cursorRow == 0 && emu.totalLineCount == emu.rows)

// --- selection text ---
emu.feed("\u{1B}[H\u{1B}[2J")
emu.feed("hello world")
emu.selectAll()
let all = emu.selectedText(emu.selection!)
check("select all text", all.trimmingCharacters(in: .whitespaces) == "hello world")
emu.selection = TerminalEmulator.Selection(startLine: 0, startCol: 0,
                                           endLine: 0, endCol: 4)
check("select subset", emu.selectedText(emu.selection!) == "hello")

// --- alt screen ---
emu.feed("\u{1B}[H\u{1B}[2J")
emu.feed("KEEP")
emu.feed("\u{1B}[?1049h")
check("alt screen blank", emu.screenCell(row: 0, col: 0).ch == " ")
emu.feed("ALT")
emu.feed("\u{1B}[?1049l")
check("alt screen restore", emu.screenCell(row: 0, col: 0).ch == "K")

// --- cursor visibility ---
emu.feed("\u{1B}[?25l")
check("cursor hidden", !emu.cursorVisible)
emu.feed("\u{1B}[?25h")
check("cursor shown", emu.cursorVisible)

// --- resize ---
emu.feed("\u{1B}[H\u{1B}[2J")
emu.feed("WIDE")
emu.resize(rows: 5, cols: 8)
check("resize keeps content", emu.line(at: 0).contains { $0.ch == "W" })
check("resize rows", emu.rows == 5 && emu.cols == 8)

// --- OSC title ---
var title = ""
let emu2 = TerminalEmulator(rows: 5, cols: 10)
emu2.onTitle = { title = $0 }
emu2.feed("\u{1B}]0;My Cool Title\u{07}")
check("osc title", title == "My Cool Title")
emu2.feed("\u{1B}]2;Second\u{1B}\\")
check("osc title ST", title == "Second")

// --- RIS reset ---
emu.feed("ABC\u{1B}c")
check("ris reset", emu.screenCell(row: 0, col: 0).ch == " " && emu.cursorRow == 0 && emu.cursorCol == 0)

// --- DCS ignored ---
emu.feed("\u{1B}P1234\u{1B}\\")
check("dcs ignored", emu.screenCell(row: 0, col: 0).ch == " ")



// --- realistic shell session ---
let s = TerminalEmulator(rows: 24, cols: 80)
s.feed("Last login: Tue Jul  1 12:00:00 on ttys000\r\n")
s.feed("user@mac ~ % ")
s.feed("\u{1B}[32mREADME.md\u{1B}[0m\u{1B}[0m\u{1B}[0m\r\n") // ls with green
s.feed("user@mac ~ % ")
let readmeLine = 1 // login(0), prompt+README(1), prompt(2)
check("session: README green", s.line(at: readmeLine).contains { $0.ch == "R" && $0.fg == TerminalEmulator.basePalette[2] })
check("session: prompt after", s.cursorRow == 2 && s.cursorCol == 13)

// --- clear (ESC[H ESC[2J ESC[3J) wipes scrollback too ---
s.feed("\u{1B}[H\u{1B}[2J\u{1B}[3J")
check("clear wipes scrollback", s.totalLineCount == s.rows && s.screenCell(row: 0, col: 0).ch == " ")

// --- vim-style alternate screen roundtrip ---
let v = TerminalEmulator(rows: 24, cols: 80)
v.feed("hello\r\nworld\r\n")
v.feed("\u{1B}[?1049h")
v.feed("\u{1B}[2J\u{1B}[H~ vim content ~")
check("vim: alt screen dirty", v.screenCell(row: 0, col: 2).ch == "v")
v.feed("\u{1B}[?1049l")
check("vim: restore original", v.screenCell(row: 0, col: 0).ch == "h" && v.screenCell(row: 1, col: 0).ch == "w")

// --- long output pushes scrollback; bottom viewport stays on the prompt ---
let l = TerminalEmulator(rows: 5, cols: 20)
for i in 0..<30 { l.feed("line\(i)\r\n") }
check("scrollback capped at 10000", l.totalLineCount <= 10_005)
check("scrollback has old lines", l.line(at: 0).contains { $0.ch == "l" })
check("screen bottom is recent", l.screenCell(row: 3, col: 0).ch == "l")
// --- DECCKM / bracketed paste mode tracking ---
let m = TerminalEmulator(rows: 5, cols: 20)
check("initial modes off", !m.applicationCursorKeys && !m.bracketedPaste)
m.feed("\u{1B}[?1h")
check("DECCKM on", m.applicationCursorKeys)
m.feed("\u{1B}[?2004h")
check("bracketed paste on", m.bracketedPaste)
m.feed("\u{1B}[?1l\u{1B}[?2004l")
check("modes off again", !m.applicationCursorKeys && !m.bracketedPaste)
m.feed("\u{1B}[?1h\u{1B}c")
check("RIS resets modes", !m.applicationCursorKeys && !m.bracketedPaste)

print(failures == 0 ? "\nALL TESTS PASSED" : "\n\(failures) TEST(S) FAILED")
exit(failures == 0 ? 0 : 1)
