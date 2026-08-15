"use strict";

// ANSI/VT terminal emulator — platform-independent port of the Swift
// `TerminalEmulator` from src/TerminalPanel.swift (oh-my-dsh M1 "shared core").
//
// Model: a scrollback buffer + a `rows`-line screen of cells, cursor
// addressing, SGR colors (16/256/truecolor), erase, insert/delete, alternate
// screen (?1049h/l), cursor visibility (?25), OSC titles. DECSTBM scroll
// regions are parsed but ignored (documented limitation, same as Swift).
//
// Self-contained: no dependencies. Feed iterates by Unicode code point
// (JS `for...of` over a string), which matches the Swift unicodeScalars
// iteration — code-point based, not grapheme-cluster based.

function clampInt(v, lo, hi) {
  return Math.min(Math.max(v, lo), hi);
}

class TerminalEmulator {
  constructor(rows, cols) {
    const r = clampInt(rows, 2, 200);
    const c = clampInt(cols, 2, 500);
    this._rows = r;
    this._cols = c;
    this.scrollback = [];
    this.screen = [];
    for (let i = 0; i < r; i++) {
      this.screen.push(TerminalEmulator.blankLine(c));
    }
    this.cursorRow = 0;
    this.cursorCol = 0;
    this.cursorVisible = true;
    // DECCKM (CSI ?1h/l): when set, cursor keys must be sent in application
    // mode (ESC O A… instead of ESC [ A…) — shells like zsh enable it.
    this.applicationCursorKeys = false;
    // Bracketed paste (CSI ?2004h/l): when set, pasted text must be wrapped
    // in ESC [ 200~ … ESC [ 201~ or the shell renders it garbled.
    this.bracketedPaste = false;
    this.selection = null;

    this.cur = TerminalEmulator.blankCell(); // current SGR attributes
    this.wrapPending = false;                // DECAWM pending wrap
    this.savedCursor = null;
    this.savedScreen = [];
    this.savedScrollback = [];
    this.altSavedCursor = null;
    this.inAltScreen = false;
    this.maxScrollback = 10000;

    this.parserState = "ground";
    this.csiParams = [];
    this.csiIntermediates = "";
    this.csiPrivate = false;
    this.oscPayload = "";

    this.onTitle = null;
  }

  // MARK: - Model access (for the view)

  get rows() {
    return this._rows;
  }

  get cols() {
    return this._cols;
  }

  get totalLineCount() {
    return this.scrollback.length + this.screen.length;
  }

  line(index) {
    if (index < this.scrollback.length) return this.scrollback[index];
    const s = index - this.scrollback.length;
    if (s >= 0 && s < this.screen.length) return this.screen[s];
    return [];
  }

  screenCell(row, col) {
    if (row < 0 || row >= this._rows || col < 0 || col >= this._cols) {
      return TerminalEmulator.blankCell();
    }
    return this.screen[row][col];
  }

  selectAll() {
    if (this.totalLineCount <= 0) return;
    this.selection = {
      startLine: 0,
      startCol: 0,
      endLine: this.totalLineCount - 1,
      endCol: this._cols - 1,
    };
  }

  clearSelection() {
    this.selection = null;
  }

  /// Copyable text for a selection: lines joined with "\n", trailing spaces
  /// trimmed per line, trailing empty lines dropped.
  selectedText(sel) {
    const out = [];
    if (
      sel.startLine > sel.endLine ||
      (sel.startLine === sel.endLine && sel.startCol > sel.endCol)
    ) {
      return "";
    }
    for (let line = sel.startLine; line <= sel.endLine; line++) {
      if (line < 0 || line >= this.totalLineCount) continue;
      const cells = this.line(line);
      if (cells.length === 0) continue;
      const c0 = line === sel.startLine ? sel.startCol : 0;
      const c1 =
        line === sel.endLine
          ? Math.min(sel.endCol, cells.length - 1)
          : cells.length - 1;
      if (c0 > c1) continue;
      let s = "";
      for (let c = c0; c <= c1; c++) {
        if (c < 0 || c >= cells.length) continue;
        const cell = cells[c];
        if (cell.continuation) continue;
        s += cell.ch;
      }
      out.push(s.trim());
    }
    while (out.length > 0 && out[out.length - 1] === "") out.pop();
    return out.join("\n");
  }

  /// Cmd+K: clear scrollback and the visible screen, keep the cursor home.
  clearScreen() {
    this.scrollback.length = 0;
    for (let r = 0; r < this._rows; r++) {
      this.screen[r] = TerminalEmulator.blankLine(this._cols);
    }
    this.cursorRow = 0;
    this.cursorCol = 0;
    this.wrapPending = false;
    this.selection = null;
  }

  // MARK: - Feeding

  feed(text) {
    // Iterate by code point (matches Swift unicodeScalars; terminals are
    // codepoint-based, so CR+LF stay separate scalars).
    for (const ch of text) {
      switch (this.parserState) {
        case "ground":
          if (ch === "\u001b") this.parserState = "escape";
          else this.handleGround(ch);
          break;
        case "escape":
          this.handleEscape(ch);
          break;
        case "swallow":
          this.parserState = "ground"; // charset designation: swallow one char
          break;
        case "csi":
          this.handleCSIChar(ch);
          break;
        case "osc":
          if (ch === "\u0007") {
            this.finishOSC();
            this.parserState = "ground";
          } else if (ch === "\u001b") {
            this.parserState = "oscST";
          } else {
            this.oscPayload += ch;
          }
          break;
        case "oscST":
          if (ch === "\\") this.finishOSC();
          this.parserState = "ground";
          break;
        case "dcs":
          if (ch === "\u001b") this.parserState = "dcsST";
          break;
        case "dcsST":
          this.parserState = ch === "\\" ? "ground" : "dcs";
          break;
      }
    }
  }

  handleGround(ch) {
    switch (ch) {
      case "\r":
        this.cursorCol = 0;
        this.wrapPending = false;
        break;
      case "\n":
      case "\u000b":
      case "\u000c":
        this.lineFeed();
        break;
      case "\u0008": // BS
        if (this.cursorCol > 0) this.cursorCol -= 1;
        this.wrapPending = false;
        break;
      case "\t": {
        const next = (Math.floor(this.cursorCol / 8) + 1) * 8;
        this.cursorCol = Math.min(next, this._cols - 1);
        this.wrapPending = false;
        break;
      }
      case "\u0007": // BEL: no audible bell in core
        break;
      default:
        this.putChar(ch);
    }
  }

  handleEscape(ch) {
    switch (ch) {
      case "[":
        this.csiParams = [];
        this.csiIntermediates = "";
        this.csiPrivate = false;
        this.parserState = "csi";
        break;
      case "]":
        this.oscPayload = "";
        this.parserState = "osc";
        break;
      case "P":
        this.parserState = "dcs";
        break;
      case "7": // DECSC
        this.savedCursor = { row: this.cursorRow, col: this.cursorCol };
        break;
      case "8": // DECRC
        if (this.savedCursor) {
          this.moveCursor(this.savedCursor.row, this.savedCursor.col);
        }
        break;
      case "c": // RIS
        this.reset();
        break;
      case "M": // RI
        this.reverseIndex();
        break;
      case "D": // IND
        this.lineFeed();
        break;
      case "E": // NEL
        this.cursorCol = 0;
        this.lineFeed();
        break;
      case "(":
      case ")":
      case "*":
      case "+": // charset select
        this.parserState = "swallow";
        break;
      default: // = > \ keypad/ST: ignore
        break;
    }
    if (
      this.parserState !== "csi" &&
      this.parserState !== "osc" &&
      this.parserState !== "dcs" &&
      this.parserState !== "swallow"
    ) {
      this.parserState = "ground";
    }
  }

  handleCSIChar(ch) {
    const a = ch.codePointAt(0);
    if (a >= 0x30 && a <= 0x39) {
      const v = a - 0x30;
      if (this.csiParams.length === 0) this.csiParams.push(0);
      this.csiParams[this.csiParams.length - 1] =
        this.csiParams[this.csiParams.length - 1] * 10 + v;
      return;
    }
    switch (ch) {
      case ";":
        this.csiParams.push(0);
        break;
      case "?":
      case ">":
      case "<":
        this.csiPrivate = true;
        break;
      case " ":
        this.csiIntermediates += " ";
        break;
      default:
        if (a >= 0x40 && a <= 0x7e) {
          this.handleCSI(ch);
          this.parserState = "ground";
        }
    }
  }

  // MARK: - CSI dispatch

  handleCSI(final) {
    const p = this.csiParams.length === 0 ? [0] : this.csiParams;
    const param = (i, dflt) =>
      i < p.length ? (p[i] === 0 ? dflt : p[i]) : dflt;
    if (this.csiPrivate) {
      this.handlePrivateCSI(final, p);
      this.csiParams = [];
      this.csiIntermediates = "";
      this.csiPrivate = false;
      return;
    }
    switch (final) {
      case "A":
        this.moveCursor(this.cursorRow - param(0, 1), this.cursorCol);
        break;
      case "B":
        this.moveCursor(this.cursorRow + param(0, 1), this.cursorCol);
        break;
      case "C":
        this.moveCursor(this.cursorRow, this.cursorCol + param(0, 1));
        break;
      case "D":
        this.moveCursor(this.cursorRow, this.cursorCol - param(0, 1));
        break;
      case "H":
      case "f":
        this.moveCursor(param(0, 1) - 1, param(1, 1) - 1);
        break;
      case "G":
        this.moveCursor(this.cursorRow, param(0, 1) - 1);
        break;
      case "d":
        this.moveCursor(param(0, 1) - 1, this.cursorCol);
        break;
      case "E":
        this.moveCursor(this.cursorRow + param(0, 1), 0);
        break;
      case "F":
        this.moveCursor(this.cursorRow - param(0, 1), 0);
        break;
      case "J":
        this.eraseDisplay(param(0, 0));
        break;
      case "K":
        this.eraseLine(param(0, 0));
        break;
      case "m":
        this.applySGR(p);
        break;
      case "s":
        this.savedCursor = { row: this.cursorRow, col: this.cursorCol };
        break;
      case "u":
        if (this.savedCursor) {
          this.moveCursor(this.savedCursor.row, this.savedCursor.col);
        }
        break;
      case "X":
        this.eraseChars(param(0, 1));
        break;
      case "P":
        this.deleteChars(param(0, 1));
        break;
      case "@":
        this.insertChars(param(0, 1));
        break;
      case "L":
        this.insertLines(param(0, 1));
        break;
      case "M":
        this.deleteLines(param(0, 1));
        break;
      case "S":
        this.scrollScreen(param(0, 1));
        break;
      case "T":
        this.scrollScreen(-param(0, 1));
        break;
      case "h":
      case "l": // SM/RM without '?' — ignore
        break;
      case "r": // DECSTBM scroll region — ignored (limitation)
        break;
      default:
        break;
    }
    this.csiParams = [];
    this.csiIntermediates = "";
    this.csiPrivate = false;
  }

  handlePrivateCSI(final, p) {
    switch (final) {
      case "h":
        for (const m of p) {
          if (m === 0) continue;
          switch (m) {
            case 25:
              this.cursorVisible = true;
              break;
            case 47:
            case 1049:
              this.enterAltScreen();
              break;
            case 1: // DECCKM: arrows → ESC O A…
              this.applicationCursorKeys = true;
              break;
            case 2004: // pasted text needs markers
              this.bracketedPaste = true;
              break;
            default:
              break;
          }
        }
        break;
      case "l":
        for (const m of p) {
          if (m === 0) continue;
          switch (m) {
            case 25:
              this.cursorVisible = false;
              break;
            case 47:
            case 1049:
              this.exitAltScreen();
              break;
            case 1:
              this.applicationCursorKeys = false;
              break;
            case 2004:
              this.bracketedPaste = false;
              break;
            default:
              break;
          }
        }
        break;
      default:
        break;
    }
  }

  moveCursor(row, col) {
    this.cursorRow = clampInt(row, 0, this._rows - 1);
    this.cursorCol = clampInt(col, 0, this._cols - 1);
    this.wrapPending = false;
  }

  lineFeed() {
    if (this.cursorRow === this._rows - 1) {
      const top = this.screen.shift();
      if (!this.inAltScreen) {
        this.scrollback.push(top);
        if (this.scrollback.length > this.maxScrollback) {
          this.scrollback.splice(0, this.scrollback.length - this.maxScrollback);
        }
      }
      this.screen.push(this.blankLine());
    } else {
      this.cursorRow += 1;
    }
  }

  reverseIndex() {
    if (this.cursorRow > 0) {
      this.cursorRow -= 1;
    } else {
      this.screen.pop();
      this.screen.unshift(this.blankLine());
    }
    this.wrapPending = false;
  }

  // MARK: - Character placement

  putChar(ch) {
    if (this.wrapPending) {
      this.cursorCol = 0;
      this.lineFeed();
      this.wrapPending = false;
    }
    const w = TerminalEmulator.displayWidth(ch);
    if (w === 2) {
      if (this.cursorCol >= this._cols - 1) {
        // wide char does not fit: wrap first
        this.cursorCol = 0;
        this.lineFeed();
      }
      if (this.cursorCol >= this._cols) return;
      const row = this.screen[this.cursorRow];
      const old = row[this.cursorCol];
      if (old.continuation && this.cursorCol > 0) {
        row[this.cursorCol - 1] = TerminalEmulator.blankCell();
      }
      if (
        !old.continuation &&
        this.cursorCol + 1 < this._cols &&
        row[this.cursorCol + 1].continuation
      ) {
        row[this.cursorCol + 1] = TerminalEmulator.blankCell();
      }
      row[this.cursorCol] = this.styledCell(ch);
      if (this.cursorCol + 1 < this._cols) {
        row[this.cursorCol + 1] = TerminalEmulator.continuationCell();
        this.cursorCol += 2;
      } else {
        this.cursorCol = this._cols - 1;
      }
    } else {
      if (this.cursorCol >= this._cols) return;
      const row = this.screen[this.cursorRow];
      const old = row[this.cursorCol];
      if (old.continuation && this.cursorCol > 0) {
        row[this.cursorCol - 1] = TerminalEmulator.blankCell();
      }
      if (
        !old.continuation &&
        this.cursorCol + 1 < this._cols &&
        row[this.cursorCol + 1].continuation
      ) {
        row[this.cursorCol + 1] = TerminalEmulator.blankCell();
      }
      row[this.cursorCol] = this.styledCell(ch);
      this.cursorCol += 1;
      this.wrapPending = this.cursorCol >= this._cols;
      if (this.cursorCol >= this._cols) this.cursorCol = this._cols - 1;
    }
  }

  // MARK: - Erase / insert / delete

  eraseDisplay(mode) {
    switch (mode) {
      case 0:
        this.eraseLine(0);
        for (let r = this.cursorRow + 1; r < this._rows; r++) {
          this.screen[r] = this.blankLine();
        }
        break;
      case 1:
        for (let r = 0; r < this.cursorRow; r++) {
          this.screen[r] = this.blankLine();
        }
        this.eraseLine(1);
        break;
      case 2:
        for (let r = 0; r < this._rows; r++) {
          this.screen[r] = this.blankLine();
        }
        break;
      case 3:
        this.scrollback.length = 0;
        break;
      default:
        break;
    }
  }

  eraseLine(mode) {
    if (mode === 0) {
      for (let c = this.cursorCol; c < this._cols; c++) {
        this.clearCell(this.cursorRow, c);
      }
    } else if (mode === 1) {
      for (let c = 0; c <= this.cursorCol; c++) {
        this.clearCell(this.cursorRow, c);
      }
    } else {
      for (let c = 0; c < this._cols; c++) {
        this.clearCell(this.cursorRow, c);
      }
    }
  }

  eraseChars(n) {
    const end = Math.min(this.cursorCol + n, this._cols);
    for (let c = this.cursorCol; c < end; c++) {
      this.clearCell(this.cursorRow, c);
    }
  }

  deleteChars(n) {
    const count = Math.min(n, this._cols - this.cursorCol);
    if (count <= 0) return;
    const row = this.screen[this.cursorRow];
    for (let c = this.cursorCol; c < this._cols - count; c++) {
      row[c] = row[c + count];
    }
    for (let c = this._cols - count; c < this._cols; c++) {
      row[c] = TerminalEmulator.blankCell();
    }
  }

  insertChars(n) {
    if (this.cursorCol + n >= this._cols) return;
    const row = this.screen[this.cursorRow];
    for (let c = this._cols - 1; c >= this.cursorCol + n; c--) {
      row[c] = row[c - n];
    }
    for (let c = this.cursorCol; c < this.cursorCol + n; c++) {
      row[c] = TerminalEmulator.blankCell();
    }
  }

  insertLines(n) {
    for (let i = 0; i < n; i++) {
      if (this.cursorRow === this._rows - 1) break;
      this.screen.pop();
      this.screen.splice(this.cursorRow, 0, this.blankLine());
    }
  }

  deleteLines(n) {
    for (let i = 0; i < n; i++) {
      if (this.cursorRow >= this._rows) break;
      this.screen.splice(this.cursorRow, 1);
      this.screen.push(this.blankLine());
    }
  }

  scrollScreen(up) {
    if (up === 0) return;
    if (up > 0) {
      for (let i = 0; i < up; i++) {
        this.screen.shift();
        this.screen.push(this.blankLine());
      }
    } else {
      for (let i = 0; i < -up; i++) {
        this.screen.pop();
        this.screen.unshift(this.blankLine());
      }
    }
  }

  clearCell(r, c) {
    if (r < 0 || r >= this._rows || c < 0 || c >= this._cols) return;
    const old = this.screen[r][c];
    this.screen[r][c] = TerminalEmulator.blankCell();
    if (old.continuation && c > 0 && !this.screen[r][c - 1].continuation) {
      this.screen[r][c - 1] = TerminalEmulator.blankCell();
    }
    if (
      !old.continuation &&
      c + 1 < this._cols &&
      this.screen[r][c + 1].continuation
    ) {
      this.screen[r][c + 1] = TerminalEmulator.blankCell();
    }
  }

  // MARK: - SGR

  applySGR(p) {
    const params = p.length === 0 ? [0] : p;
    let i = 0;
    while (i < params.length) {
      const code = params[i];
      switch (code) {
        case 0:
          this.cur = TerminalEmulator.blankCell();
          break;
        case 1:
          this.cur.bold = true;
          break;
        case 3:
          this.cur.italic = true;
          break;
        case 4:
          this.cur.underline = true;
          break;
        case 7:
          this.cur.inverse = true;
          break;
        case 22:
          this.cur.bold = false;
          break;
        case 23:
          this.cur.italic = false;
          break;
        case 24:
          this.cur.underline = false;
          break;
        case 27:
          this.cur.inverse = false;
          break;
        case 38:
          if (i + 1 < params.length) {
            if (params[i + 1] === 5 && i + 2 < params.length) {
              this.cur.fg = TerminalEmulator.palette256(params[i + 2]);
              i += 2;
            } else if (params[i + 1] === 2 && i + 4 < params.length) {
              this.cur.fg = TerminalEmulator.rgb(
                params[i + 2],
                params[i + 3],
                params[i + 4]
              );
              i += 4;
            }
          }
          break;
        case 39:
          this.cur.fg = null;
          break;
        case 48:
          if (i + 1 < params.length) {
            if (params[i + 1] === 5 && i + 2 < params.length) {
              this.cur.bg = TerminalEmulator.palette256(params[i + 2]);
              i += 2;
            } else if (params[i + 1] === 2 && i + 4 < params.length) {
              this.cur.bg = TerminalEmulator.rgb(
                params[i + 2],
                params[i + 3],
                params[i + 4]
              );
              i += 4;
            }
          }
          break;
        case 49:
          this.cur.bg = null;
          break;
        default:
          if (code >= 30 && code <= 37) {
            this.cur.fg = TerminalEmulator.basePalette[code - 30];
          } else if (code >= 40 && code <= 47) {
            this.cur.bg = TerminalEmulator.basePalette[code - 40];
          } else if (code >= 90 && code <= 97) {
            this.cur.fg = TerminalEmulator.basePalette[code - 90 + 8];
          } else if (code >= 100 && code <= 107) {
            this.cur.bg = TerminalEmulator.basePalette[code - 100 + 8];
          }
          break;
      }
      i += 1;
    }
  }

  // MARK: - Alternate screen / reset / resize

  enterAltScreen() {
    if (this.inAltScreen) return;
    this.savedScreen = this.screen;
    this.savedScrollback = this.scrollback;
    this.altSavedCursor = { row: this.cursorRow, col: this.cursorCol };
    this.inAltScreen = true;
    this.scrollback = [];
    this.screen = [];
    for (let i = 0; i < this._rows; i++) {
      this.screen.push(this.blankLine());
    }
    this.cursorRow = 0;
    this.cursorCol = 0;
    this.wrapPending = false;
    this.selection = null;
  }

  exitAltScreen() {
    if (!this.inAltScreen) return;
    this.inAltScreen = false;
    this.screen =
      this.savedScreen.length === 0
        ? this.makeBlankScreen()
        : this.savedScreen;
    this.scrollback = this.savedScrollback;
    const sc = this.altSavedCursor || { row: 0, col: 0 };
    this.moveCursor(sc.row, sc.col);
    this.savedScreen = [];
    this.savedScrollback = [];
    this.altSavedCursor = null;
  }

  makeBlankScreen() {
    const s = [];
    for (let i = 0; i < this._rows; i++) {
      s.push(this.blankLine());
    }
    return s;
  }

  reset() {
    this.scrollback = [];
    this.screen = this.makeBlankScreen();
    this.cursorRow = 0;
    this.cursorCol = 0;
    this.cur = TerminalEmulator.blankCell();
    this.wrapPending = false;
    this.cursorVisible = true;
    this.applicationCursorKeys = false;
    this.bracketedPaste = false;
    this.inAltScreen = false;
    this.savedScreen = [];
    this.savedScrollback = [];
    this.savedCursor = null;
    this.altSavedCursor = null;
    this.selection = null;
  }

  resize(newRows, newCols) {
    newRows = clampInt(newRows, 2, 200);
    newCols = clampInt(newCols, 2, 500);
    if (newRows === this._rows && newCols === this._cols) return;

    // Rebuild the screen from the bottom of (scrollback + screen) so
    // shrinking keeps the most recent content.
    const all = this.scrollback.concat(this.screen);
    const keep = Math.max(newRows, this._rows);
    const start = Math.max(0, all.length - keep);
    const kept = all.slice(start);
    let newScreen;
    if (kept.length >= newRows) {
      newScreen = kept.slice(kept.length - newRows);
      this.scrollback = kept.slice(0, Math.max(0, kept.length - newRows));
    } else {
      newScreen = kept.slice();
      while (newScreen.length < newRows) {
        newScreen.unshift(TerminalEmulator.blankLine(newCols));
      }
      this.scrollback = [];
    }
    for (let i = 0; i < newScreen.length; i++) {
      if (newScreen[i].length > newCols) {
        newScreen[i] = newScreen[i].slice(0, newCols);
      } else if (newScreen[i].length < newCols) {
        while (newScreen[i].length < newCols) {
          newScreen[i].push(TerminalEmulator.blankCell());
        }
      }
    }
    this.screen = newScreen;
    this._rows = newRows;
    this._cols = newCols;
    this.cursorRow = Math.min(this.cursorRow, this._rows - 1);
    this.cursorCol = Math.min(this.cursorCol, this._cols - 1);
    this.wrapPending = false;
    if (this.scrollback.length > this.maxScrollback) {
      this.scrollback.splice(0, this.scrollback.length - this.maxScrollback);
    }
  }

  // MARK: - Cells & palette

  styledCell(ch) {
    return {
      ch: ch,
      fg: this.cur.fg,
      bg: this.cur.bg,
      bold: this.cur.bold,
      italic: this.cur.italic,
      underline: this.cur.underline,
      inverse: this.cur.inverse,
      continuation: this.cur.continuation,
    };
  }

  blankLine() {
    return TerminalEmulator.blankLine(this._cols);
  }

  static blankCell() {
    return {
      ch: " ",
      fg: null,
      bg: null,
      bold: false,
      italic: false,
      underline: false,
      inverse: false,
      continuation: false,
    };
  }

  static continuationCell() {
    const c = TerminalEmulator.blankCell();
    c.continuation = true;
    return c;
  }

  static blankLine(cols) {
    const line = [];
    for (let i = 0; i < cols; i++) {
      line.push(TerminalEmulator.blankCell());
    }
    return line;
  }

  static rgb(r, g, b) {
    return {
      r: clampInt(r, 0, 255),
      g: clampInt(g, 0, 255),
      b: clampInt(b, 0, 255),
    };
  }

  static palette256(n) {
    if (n < 16) return TerminalEmulator.basePalette[n];
    if (n < 232) {
      const v = n - 16;
      const r = Math.floor(v / 36);
      const g = Math.floor(v / 6) % 6;
      const b = v % 6;
      const level = (x) => (x === 0 ? 0 : 95 + (x - 1) * 40);
      return TerminalEmulator.rgb(level(r), level(g), level(b));
    }
    const g = 8 + (n - 232) * 10;
    return TerminalEmulator.rgb(g, g, g);
  }

  /// Rough display width: CJK / wide emoji ranges are 2 columns, everything
  /// else 1 (combining/ZWJ sequences are approximated as 1 — documented).
  static displayWidth(ch) {
    const cp = ch.codePointAt(0);
    if (cp === undefined) return 1;
    if (
      (cp >= 0x1100 && cp <= 0x115f) ||
      (cp >= 0x2e80 && cp <= 0xa4cf) ||
      (cp >= 0xac00 && cp <= 0xd7a3) ||
      (cp >= 0xf900 && cp <= 0xfaff) ||
      (cp >= 0xfe30 && cp <= 0xfe4f) ||
      (cp >= 0xff00 && cp <= 0xff60) ||
      (cp >= 0xffe0 && cp <= 0xffe6) ||
      (cp >= 0x1f300 && cp <= 0x1f64f) ||
      (cp >= 0x1f900 && cp <= 0x1f9ff) ||
      (cp >= 0x20000 && cp <= 0x3fffd)
    ) {
      return 2;
    }
    return 1;
  }

  // MARK: - OSC

  finishOSC() {
    const payload = this.oscPayload;
    this.oscPayload = "";
    const idx = payload.indexOf(";");
    if (idx === -1) return;
    const cmd = payload.slice(0, idx);
    if (cmd === "0" || cmd === "2") {
      const title = payload.slice(idx + 1);
      if (title !== "" && typeof this.onTitle === "function") {
        this.onTitle(title);
      }
    }
    // Other OSC (clipboard, cwd, …) are ignored.
  }
}

/// Classic xterm 16-color palette.
TerminalEmulator.basePalette = [
  TerminalEmulator.rgb(0, 0, 0),
  TerminalEmulator.rgb(205, 0, 0),
  TerminalEmulator.rgb(0, 205, 0),
  TerminalEmulator.rgb(205, 205, 0),
  TerminalEmulator.rgb(0, 0, 238),
  TerminalEmulator.rgb(205, 0, 205),
  TerminalEmulator.rgb(0, 205, 205),
  TerminalEmulator.rgb(229, 229, 229),
  TerminalEmulator.rgb(127, 127, 127),
  TerminalEmulator.rgb(255, 0, 0),
  TerminalEmulator.rgb(0, 255, 0),
  TerminalEmulator.rgb(255, 255, 0),
  TerminalEmulator.rgb(92, 92, 255),
  TerminalEmulator.rgb(255, 0, 255),
  TerminalEmulator.rgb(0, 255, 255),
  TerminalEmulator.rgb(255, 255, 255),
];

module.exports = { TerminalEmulator };
