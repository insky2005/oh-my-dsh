"use strict";

// Port of tests/terminal-emulator/emulator-tests.swift — headless unit tests
// for the TerminalEmulator shared-core port (no PTY involved). Every check()
// case from the Swift spec is preserved, in the same order.

const { test } = require("node:test");
const assert = require("node:assert/strict");
const { TerminalEmulator } = require("../lib/ansi.js");

function check(name, cond) {
  assert.ok(cond, name);
}

// Colors are {r,g,b} ints 0-255; mirror the Swift approx(r/255, g/255, b/255).
function approx(c, r, g, b) {
  return (
    c !== null &&
    c !== undefined &&
    Math.abs(c.r - r) < 0.01 &&
    Math.abs(c.g - g) < 0.01 &&
    Math.abs(c.b - b) < 0.01
  );
}

// --- plain text, cursor ---
const emu = new TerminalEmulator(10, 20);

test("plain text", () => {
  emu.feed("Hello");
  check(
    "plain text",
    emu.screenCell(0, 0).ch === "H" && emu.screenCell(0, 4).ch === "o"
  );
  check("cursor col", emu.cursorCol === 5);
});

test("crlf moves down", () => {
  emu.feed("\r\nB");
  check("crlf moves down", emu.screenCell(1, 0).ch === "B" && emu.cursorRow === 1);
});

test("backspace", () => {
  emu.feed("\u0008\u0008");
  check("backspace", emu.cursorCol === 0);
});

// --- SGR colors ---
test("sgr red fg", () => {
  emu.feed("\u001b[H\u001b[2J");
  emu.feed("\u001b[31mR");
  check("sgr red fg", emu.screenCell(0, 0).fg === TerminalEmulator.basePalette[1]);
});

test("sgr reset fg", () => {
  emu.feed("\u001b[0mG");
  check("sgr reset fg", emu.screenCell(0, 1).fg === null);
});

test("sgr bold+bg", () => {
  emu.feed("\u001b[1m\u001b[44mB");
  const boldBlue = emu.screenCell(0, 2);
  check("sgr bold+bg", boldBlue.bold && boldBlue.bg === TerminalEmulator.basePalette[4]);
});

test("sgr inverse", () => {
  emu.feed("\u001b[7mI");
  check("sgr inverse", emu.screenCell(0, 3).inverse);
});

// --- 256 + truecolor ---
test("sgr 256", () => {
  emu.feed("\u001b[H\u001b[2J");
  emu.feed("\u001b[38;5;196mX");
  check("sgr 256", approx(emu.screenCell(0, 0).fg, 255, 0, 0));
});

test("sgr truecolor", () => {
  emu.feed("\u001b[H\u001b[2J");
  emu.feed("\u001b[38;2;10;20;30mX");
  check("sgr truecolor", approx(emu.screenCell(0, 0).fg, 10, 20, 30));
});

// --- cursor addressing ---
test("cup", () => {
  emu.feed("\u001b[H\u001b[2J");
  emu.feed("\u001b[3;5HX");
  check(
    "cup",
    emu.cursorRow === 2 && emu.cursorCol === 5 && emu.screenCell(2, 4).ch === "X"
  );
});

test("cha", () => {
  emu.feed("\u001b[G"); // CHA default col 1
  check("cha", emu.cursorCol === 0);
});

test("cud/cuf", () => {
  emu.feed("\u001b[B\u001b[C"); // down + right
  check("cud/cuf", emu.cursorRow === 3 && emu.cursorCol === 1);
});

test("save/restore cursor", () => {
  emu.feed("\u001b[s\u001b[H\u001b[u");
  check("save/restore cursor", emu.cursorRow === 3 && emu.cursorCol === 1);
});

// --- erase ---
test("erase line 0", () => {
  emu.feed("\u001b[H\u001b[2J");
  emu.feed("abcdef");
  emu.feed("\u001b[H\u001b[K"); // erase to end of line
  check("erase line 0", emu.screenCell(0, 0).ch === " ");
});

test("erase whole line", () => {
  emu.feed("zz\u001b[H\u001b[2K");
  check("erase whole line", emu.screenCell(0, 1).ch === " ");
});

test("erase display", () => {
  emu.feed("\u001b[H\u001b[2J");
  emu.feed("top");
  emu.feed("\u001b[5;1Hbottom\u001b[2J");
  check(
    "erase display",
    emu.screenCell(0, 0).ch === " " && emu.screenCell(4, 0).ch === " "
  );
});

// --- insert/delete chars ---
test("delete char", () => {
  emu.feed("\u001b[H\u001b[2J");
  emu.feed("ABCDE\u001b[D\u001b[D\u001b[P"); // cursor on C, delete → ABDE
  check(
    "delete char",
    emu.screenCell(0, 3).ch === "E" && emu.screenCell(0, 4).ch === " "
  );
});

test("insert char", () => {
  emu.feed("\u001b[H\u001b[2J");
  emu.feed("ABC\u001b[D\u001b[@"); // insert at col 2 → AB C? (blank at 2)
  check(
    "insert char",
    emu.screenCell(0, 2).ch === " " && emu.screenCell(0, 3).ch === "C"
  );
});

// --- wide chars ---
test("wide char occupies 2", () => {
  emu.feed("\u001b[H\u001b[2J");
  emu.feed("\u4e2d"); // 中
  check(
    "wide char occupies 2",
    emu.screenCell(0, 0).ch === "\u4e2d" && emu.screenCell(0, 1).continuation
  );
  check("wide cursor advance", emu.cursorCol === 2);
});

test("overwrite wide start clears continuation", () => {
  emu.feed("\u0008\u0008"); // bs to col 0
  emu.feed("A");
  check(
    "overwrite wide start clears continuation",
    emu.screenCell(0, 0).ch === "A" && !emu.screenCell(0, 1).continuation
  );
});

// --- autowrap ---
test("wrap pending at last col", () => {
  emu.feed("\u001b[H\u001b[2J");
  emu.feed("A".repeat(20));
  check("wrap pending at last col", emu.cursorCol === 19);
});

test("autowrap to next line", () => {
  emu.feed("B");
  check(
    "autowrap to next line",
    emu.screenCell(1, 0).ch === "B" && emu.cursorRow === 1
  );
});

// --- tab ---
test("tab to col 8", () => {
  emu.feed("\u001b[H\u001b[2J");
  emu.feed("\t");
  check("tab to col 8", emu.cursorCol === 8);
});

// --- scrollback ---
test("scrollback grows", () => {
  emu.feed("\u001b[H\u001b[2J");
  for (let i = 0; i < 12; i++) emu.feed("X\n");
  check("scrollback grows", emu.totalLineCount === 13); // 3 pushed + 10 screen
});

test("scrollback content", () => {
  check("scrollback content", emu.line(0).some((cell) => cell.ch === "X"));
});

// --- clearScreen (Cmd+K) ---
test("clearScreen", () => {
  emu.feed("\u001b[H\u001b[2J");
  emu.feed("garbage");
  emu.clearScreen();
  check(
    "clearScreen",
    emu.screenCell(0, 0).ch === " " &&
      emu.cursorRow === 0 &&
      emu.totalLineCount === emu.rows
  );
});

// --- selection text ---
test("select all text", () => {
  emu.feed("\u001b[H\u001b[2J");
  emu.feed("hello world");
  emu.selectAll();
  const all = emu.selectedText(emu.selection);
  check("select all text", all.trim() === "hello world");
});

test("select subset", () => {
  emu.selection = { startLine: 0, startCol: 0, endLine: 0, endCol: 4 };
  check("select subset", emu.selectedText(emu.selection) === "hello");
});

// --- alt screen ---
test("alt screen blank", () => {
  emu.feed("\u001b[H\u001b[2J");
  emu.feed("KEEP");
  emu.feed("\u001b[?1049h");
  check("alt screen blank", emu.screenCell(0, 0).ch === " ");
});

test("alt screen restore", () => {
  emu.feed("ALT");
  emu.feed("\u001b[?1049l");
  check("alt screen restore", emu.screenCell(0, 0).ch === "K");
});

// --- cursor visibility ---
test("cursor hidden", () => {
  emu.feed("\u001b[?25l");
  check("cursor hidden", !emu.cursorVisible);
});

test("cursor shown", () => {
  emu.feed("\u001b[?25h");
  check("cursor shown", emu.cursorVisible);
});

// --- resize ---
test("resize keeps content", () => {
  emu.feed("\u001b[H\u001b[2J");
  emu.feed("WIDE");
  emu.resize(5, 8);
  check("resize keeps content", emu.line(0).some((cell) => cell.ch === "W"));
});

test("resize rows", () => {
  check("resize rows", emu.rows === 5 && emu.cols === 8);
});

// --- OSC title ---
test("osc title", () => {
  let title = "";
  const emu2 = new TerminalEmulator(5, 10);
  emu2.onTitle = (t) => {
    title = t;
  };
  emu2.feed("\u001b]0;My Cool Title\u0007");
  check("osc title", title === "My Cool Title");
  emu2.feed("\u001b]2;Second\u001b\\");
  check("osc title ST", title === "Second");
});

// --- RIS reset ---
test("ris reset", () => {
  emu.feed("ABC\u001bc");
  check(
    "ris reset",
    emu.screenCell(0, 0).ch === " " && emu.cursorRow === 0 && emu.cursorCol === 0
  );
});

// --- DCS ignored ---
test("dcs ignored", () => {
  emu.feed("\u001bP1234\u001b\\");
  check("dcs ignored", emu.screenCell(0, 0).ch === " ");
});

// --- DECSTBM scroll regions (vim/vi scroll their text area with one) ---
//
// The regression this pins: vim sets a region that excludes the status line
// and then feeds LF at the region's bottom row. An emulator that ignores the
// region just moves the cursor down one screen row, so the text stops moving
// (arrow-key scrolling appears dead) while the cursor walks into the status
// line.

test("decstbm: LF at region bottom scrolls only the region", () => {
  const v = new TerminalEmulator(6, 10);
  v.feed("\u001b[1;4r"); // region = screen rows 1..4 (0-based 0..3)
  v.feed("\u001b[1;1HA\u001b[2;1HB\u001b[3;1HC\u001b[4;1HD\u001b[6;1HSTATUS");
  v.feed("\u001b[4;1H\n"); // cursor on the region bottom, line feed
  check(
    "decstbm: region shifts up",
    v.screenCell(0, 0).ch === "B" &&
      v.screenCell(1, 0).ch === "C" &&
      v.screenCell(2, 0).ch === "D" &&
      v.screenCell(3, 0).ch === " "
  );
  check("decstbm: status row untouched", v.screenCell(5, 0).ch === "S");
  check("decstbm: partial region adds no scrollback", v.totalLineCount === v.rows);
});

test("decstbm: RI at region top scrolls down inside the region", () => {
  const v = new TerminalEmulator(6, 10);
  v.feed("\u001b[1;4r");
  v.feed("\u001b[1;1HA\u001b[2;1HB\u001b[3;1HC\u001b[4;1HD\u001b[6;1HSTATUS");
  v.feed("\u001b[1;1H\u001bM"); // reverse index at the region top
  check(
    "decstbm: region shifts down",
    v.screenCell(0, 0).ch === " " &&
      v.screenCell(1, 0).ch === "A" &&
      v.screenCell(2, 0).ch === "B" &&
      v.screenCell(3, 0).ch === "C"
  );
  check("decstbm: RI keeps the status row", v.screenCell(5, 0).ch === "S");
});

test("decstbm: insert line stays inside the region", () => {
  const v = new TerminalEmulator(6, 10);
  v.feed("\u001b[1;4r");
  v.feed("\u001b[1;1HA\u001b[2;1HB\u001b[3;1HC\u001b[4;1HD\u001b[6;1HSTATUS");
  v.feed("\u001b[2;1H\u001b[L"); // insert one line at region row 2
  check(
    "decstbm: IL pushes region lines down",
    v.screenCell(0, 0).ch === "A" &&
      v.screenCell(1, 0).ch === " " &&
      v.screenCell(2, 0).ch === "B" &&
      v.screenCell(3, 0).ch === "C"
  );
  check("decstbm: IL keeps the status row", v.screenCell(5, 0).ch === "S");
});

test("decstbm: delete line stays inside the region", () => {
  const v = new TerminalEmulator(6, 10);
  v.feed("\u001b[1;4r");
  v.feed("\u001b[1;1HA\u001b[2;1HB\u001b[3;1HC\u001b[4;1HD\u001b[6;1HSTATUS");
  v.feed("\u001b[2;1H\u001b[M"); // delete one line at region row 2
  check(
    "decstbm: DL pulls region lines up",
    v.screenCell(0, 0).ch === "A" &&
      v.screenCell(1, 0).ch === "C" &&
      v.screenCell(2, 0).ch === "D" &&
      v.screenCell(3, 0).ch === " "
  );
  check("decstbm: DL keeps the status row", v.screenCell(5, 0).ch === "S");
});

test("decstbm: SU/SD scroll only the region", () => {
  const v = new TerminalEmulator(6, 10);
  v.feed("\u001b[1;4r");
  v.feed("\u001b[1;1HA\u001b[2;1HB\u001b[3;1HC\u001b[4;1HD\u001b[6;1HSTATUS");
  v.feed("\u001b[1S"); // scroll up 1
  check(
    "decstbm: SU shifts the region",
    v.screenCell(0, 0).ch === "B" && v.screenCell(3, 0).ch === " "
  );
  v.feed("\u001b[1T"); // scroll down 1
  check(
    "decstbm: SD shifts the region back",
    v.screenCell(0, 0).ch === " " &&
      v.screenCell(1, 0).ch === "B" &&
      v.screenCell(2, 0).ch === "C"
  );
  check("decstbm: SU/SD keep the status row", v.screenCell(5, 0).ch === "S");
});

test("decstbm: CSI r restores the full-screen region", () => {
  const v = new TerminalEmulator(6, 10);
  v.feed("\u001b[1;4r");
  v.feed("\u001b[1;1HTOP\u001b[6;1HBOT");
  v.feed("\u001b[r"); // all-default DECSTBM = full screen
  v.feed("\u001b[6;1H\n"); // LF at the real bottom scrolls everything
  check(
    "decstbm: reset region scrolls the whole screen",
    v.screenCell(4, 0).ch === "B" && v.line(0).some((cell) => cell.ch === "T")
  );
});

// --- realistic shell session ---
test("session: README green", () => {
  const s = new TerminalEmulator(24, 80);
  s.feed("Last login: Tue Jul  1 12:00:00 on ttys000\r\n");
  s.feed("user@mac ~ % ");
  s.feed("\u001b[32mREADME.md\u001b[0m\u001b[0m\u001b[0m\r\n"); // ls with green
  s.feed("user@mac ~ % ");
  const readmeLine = 1; // login(0), prompt+README(1), prompt(2)
  check(
    "session: README green",
    s
      .line(readmeLine)
      .some((cell) => cell.ch === "R" && cell.fg === TerminalEmulator.basePalette[2])
  );
  check("session: prompt after", s.cursorRow === 2 && s.cursorCol === 13);
});

// --- clear (ESC[H ESC[2J ESC[3J) wipes scrollback too ---
test("clear wipes scrollback", () => {
  const s = new TerminalEmulator(24, 80);
  s.feed("Last login: Tue Jul  1 12:00:00 on ttys000\r\n");
  s.feed("user@mac ~ % ");
  s.feed("\u001b[32mREADME.md\u001b[0m\u001b[0m\u001b[0m\r\n");
  s.feed("user@mac ~ % ");
  s.feed("\u001b[H\u001b[2J\u001b[3J");
  check(
    "clear wipes scrollback",
    s.totalLineCount === s.rows && s.screenCell(0, 0).ch === " "
  );
});

// --- vim-style alternate screen roundtrip ---
test("vim: alt screen dirty", () => {
  const v = new TerminalEmulator(24, 80);
  v.feed("hello\r\nworld\r\n");
  v.feed("\u001b[?1049h");
  v.feed("\u001b[2J\u001b[H~ vim content ~");
  check("vim: alt screen dirty", v.screenCell(0, 2).ch === "v");
  v.feed("\u001b[?1049l");
  check(
    "vim: restore original",
    v.screenCell(0, 0).ch === "h" && v.screenCell(1, 0).ch === "w"
  );
});

// --- long output pushes scrollback; bottom viewport stays on the prompt ---
test("scrollback capped at 10000", () => {
  const l = new TerminalEmulator(5, 20);
  for (let i = 0; i < 30; i++) l.feed(`line${i}\r\n`);
  check("scrollback capped at 10000", l.totalLineCount <= 10005);
  check("scrollback has old lines", l.line(0).some((cell) => cell.ch === "l"));
  check("screen bottom is recent", l.screenCell(3, 0).ch === "l");
});

// --- DECCKM / bracketed paste mode tracking ---
test("initial modes off", () => {
  const m = new TerminalEmulator(5, 20);
  check("initial modes off", !m.applicationCursorKeys && !m.bracketedPaste);
  m.feed("\u001b[?1h");
  check("DECCKM on", m.applicationCursorKeys);
  m.feed("\u001b[?2004h");
  check("bracketed paste on", m.bracketedPaste);
  m.feed("\u001b[?1l\u001b[?2004l");
  check("modes off again", !m.applicationCursorKeys && !m.bracketedPaste);
  m.feed("\u001b[?1h\u001bc");
  check("RIS resets modes", !m.applicationCursorKeys && !m.bracketedPaste);
});
