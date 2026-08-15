//
//  TerminalPanel.swift — Right-side integrated terminal for oh-my-dsh.
//
//  Mounted as the right pane of the main NSSplitView (the same slot as the
//  preview panel; the activity bar toggles between the two). Each tab owns a
//  real PTY shell session (forkpty) whose output is rendered by a minimal
//  ANSI/VT emulator (a pragmatic subset: cursor addressing, SGR colors incl.
//  256/truecolor, erase, alternate screen for vim/top/less, OSC titles).
//
//  Localization strings live in AppDelegate's L10n table (see main.swift).
//

import AppKit
import Darwin
import Foundation

// MARK: - PTY session

/// One interactive shell process attached to a pseudo-terminal. Reads run on
/// a background queue (select + read, UTF-8 aware); writes are serialized;
/// resizes are forwarded via TIOCSWINSZ; termination kills the child's whole
/// process group and reaps it.
final class TerminalSession {

    var onOutput: ((String) -> Void)?
    var onExit: ((_ code: Int32, _ clean: Bool) -> Void)?

    private(set) var pid: pid_t = 0
    private var masterFD: Int32 = -1
    private let readQueue = DispatchQueue(label: "dsh.terminal.read")
    private let writeQueue = DispatchQueue(label: "dsh.terminal.write")
    /// Set by terminate()/natural exit; the read loop checks it after each
    /// select timeout, so a cross-thread close is never needed.
    private var stopReading = false
    private var reaped = false

    enum State { case running, exited(Int32), terminated }
    private var state: State = .running

    /// Resolve a usable interactive shell: $SHELL when it exists, else /bin/zsh.
    static func resolveShell() -> String {
        let env = ProcessInfo.processInfo.environment
        if let s = env["SHELL"], !s.isEmpty, FileManager.default.isExecutableFile(atPath: s) { return s }
        return "/bin/zsh"
    }

    /// Child environment: the app's environment plus terminal capabilities.
    static func buildEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        // Force UTF-8 in the PTY. GUI-launched processes usually lack a proper
        // LANG/LC_ALL; with a non-UTF-8 locale zsh can't decode input and
        // renders pasted text as <ffffffff>/<hex> garbage (and can misbehave
        // its keybindings, e.g. beeping on arrow keys).
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        env["LC_CTYPE"] = "en_US.UTF-8"
        return env
    }

    /// Spawn the shell on a fresh PTY. All C strings are built in the parent
    /// BEFORE forkpty so the child only runs chdir + execve (no allocation,
    /// avoiding fork-in-a-multithreaded-app hazards).
    init?(shell: String, args: [String], env: [String: String], cwd: String?, rows: Int, cols: Int) {
        let cols = min(max(cols, 2), 500)
        let rows = min(max(rows, 2), 200)
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)

        // Pre-fork: build argv/envp/cwd/shell as C strings.
        var argv: [UnsafeMutablePointer<CChar>?] = ([shell] + args).map { $0.withCString { strdup($0) } }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = env.map { "\($0.key)=\($0.value)".withCString { strdup($0) } }
        envp.append(nil)
        let shellCopy = shell.withCString { strdup($0) }
        let cwdCopy = cwd.flatMap { $0.withCString { strdup($0) } }

        var master: Int32 = 0
        let pid = forkpty(&master, nil, nil, &ws)
        if pid == 0 {
            // Child: only async-signal-safe-ish work, then exec.
            if let cd = cwdCopy { _ = chdir(cd) }
            execve(shellCopy, argv, envp)
            _exit(127)
        }
        // Parent: free pre-fork buffers.
        for p in argv { free(p) }
        for p in envp { free(p) }
        if let p = shellCopy { free(p) }
        if let p = cwdCopy { free(p) }

        guard pid > 0, master >= 0 else {
            if master >= 0 { close(master) }
            return nil
        }
        self.pid = pid
        self.masterFD = master
        readQueue.async { [weak self] in self?.readLoop() }
    }

    deinit {
        terminate()
    }

    // MARK: I/O

    private func readLoop() {
        var pending = Data()
        while !stopReading {
            var pfd = pollfd(fd: masterFD, events: Int16(POLLIN), revents: 0)
            let rc = poll(&pfd, 1, 200) // 200ms timeout so stopReading is honored
            if stopReading { break }
            if rc < 0 {
                if errno == EINTR { continue }
                break
            }
            if rc == 0 { continue }
            if (pfd.revents & Int16(POLLIN)) == 0 { continue }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(masterFD, &buf, buf.count)
            if n <= 0 { break } // EIO once the slave side is gone
            let text = decodeChunk(Data(buf[0..<n]), pending: &pending)
            if !text.isEmpty {
                let out = text
                DispatchQueue.main.async { [weak self] in self?.onOutput?(out) }
            }
        }
        close(masterFD)
        masterFD = -1
        reap()
        if !stopReading {
            // Natural exit (shell exited or exec failed).
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if case .running = self.state {
                    let info = self.exitInfo() ?? (0, true)
                    self.state = .exited(info.code)
                    self.onExit?(info.code, info.clean)
                }
            }
        }
    }

    /// Decode a chunk of bytes as UTF-8, keeping a partial multi-byte tail in
    /// `pending` for the next chunk; genuinely invalid bytes become U+FFFD.
    private func decodeChunk(_ data: Data, pending: inout Data) -> String {
        var combined = pending
        combined.append(data)
        if let s = String(data: combined, encoding: .utf8) {
            pending.removeAll(keepingCapacity: true)
            return s
        }
        let maxDrop = min(3, combined.count)
        if maxDrop > 0 {
            for drop in 1...maxDrop {
                let cut = combined.count - drop
                if let s = String(data: combined.prefix(cut), encoding: .utf8) {
                    pending = Data(combined.suffix(drop))
                    return s
                }
            }
        }
        pending.removeAll(keepingCapacity: true)
        return String(decoding: combined, as: UTF8.self)
    }

    func write(_ data: Data) {
        guard masterFD >= 0, !data.isEmpty else { return }
        let fd = masterFD
        writeQueue.async {
            // Write via withUnsafeBytes — `&array[index]` on a Swift [UInt8]
            // writes the array's OBJECT HEADER instead of the element bytes
            // (verified: only the first byte came through; multi-byte input
            // like arrow keys and pastes reached the shell as garbage).
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var off = 0
                while off < raw.count {
                    let n = Darwin.write(fd, base.advanced(by: off), raw.count - off)
                    if n > 0 { off += n; continue }
                    if n < 0 && errno == EINTR { continue }
                    break
                }
            }
        }
    }

    func write(_ text: String) {
        write(Data(text.utf8))
    }

    func resize(rows: Int, cols: Int) {
        guard masterFD >= 0 else { return }
        var ws = winsize(ws_row: UInt16(min(max(rows, 2), 200)),
                         ws_col: UInt16(min(max(cols, 2), 500)),
                         ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, UInt(TIOCSWINSZ), &ws)
    }

    /// Best-effort exit info via waitpid(WNOHANG); nil while still running.
    /// clean = the process exited normally (not killed by a signal). Code 127
    /// (the child's exec-failure fallback) is treated as abnormal so a shell
    /// that never started doesn't auto-close its tab. (WIFEXITED/WEXITSTATUS
    /// etc. are C macros — decode the status manually: low 7 bits = signal,
    /// next byte = exit code.)
    private func exitInfo() -> (code: Int32, clean: Bool)? {
        guard pid > 0 else { return nil }
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        if r == pid {
            let sig = status & 0x7f
            if sig == 0 {
                let code = (status >> 8) & 0xff
                return (code, code != 127)
            }
            if sig != 0x7f { return (128 + sig, false) }   // signaled
            return (0, true)
        }
        return nil
    }

    private func reap() {
        guard !reaped, pid > 0 else { return }
        reaped = true
        let p = pid
        pid = 0
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(p, &status, 0)
        }
    }

    /// Kill the child's process group and let the read loop wind down.
    func terminate() {
        guard pid > 0 || masterFD >= 0 else { return }
        stopReading = true
        if pid > 0 {
            kill(-pid, SIGHUP) // whole foreground process group
            kill(pid, SIGHUP)  // fallback if the group id differs
        }
        if case .running = state { state = .terminated }
    }
}

// MARK: - Terminal emulator (grid model + ANSI subset)

/// Minimal ANSI/VT terminal: a scrollback + a `rows`-line screen of cells,
/// cursor addressing, SGR colors (16/256/truecolor), erase, insert/delete,
/// alternate screen (?1049h/l), cursor visibility (?25), OSC titles.
/// DECSTBM scroll regions are parsed but ignored (documented limitation).
final class TerminalEmulator {

    struct Cell {
        var ch: Character = " "
        var fg: NSColor?
        var bg: NSColor?
        var bold = false
        var italic = false
        var underline = false
        var inverse = false
        /// True for the second column a wide (CJK/emoji) character occupies.
        var continuation = false
    }
    typealias Line = [Cell]

    /// Absolute-buffer selection (line indices into scrollback+screen).
    struct Selection {
        var startLine: Int
        var startCol: Int
        var endLine: Int
        var endCol: Int
    }

    var onTitle: ((String) -> Void)?

    private(set) var rows: Int
    private(set) var cols: Int
    private var scrollback: [Line] = []
    private var screen: [Line]
    private(set) var cursorRow = 0
    private(set) var cursorCol = 0
    var cursorVisible = true
    /// DECCKM (CSI ?1h/l): when set, cursor keys must be sent in application
    /// mode (ESC O A… instead of ESC [ A…) — shells like zsh enable it.
    private(set) var applicationCursorKeys = false
    /// Bracketed paste (CSI ?2004h/l): when set, pasted text must be wrapped
    /// in ESC [ 200~ … ESC [ 201~ or the shell renders it garbled.
    private(set) var bracketedPaste = false
    var selection: Selection?

    private var cur = Cell()                       // current SGR attributes
    private var wrapPending = false                // DECAWM pending wrap
    private var savedCursor: (row: Int, col: Int)?
    private var savedScreen: [Line] = []
    private var savedScrollback: [Line] = []
    private var altSavedCursor: (row: Int, col: Int)?
    private var inAltScreen = false
    private let maxScrollback = 10_000

    private enum ParserState { case ground, escape, swallow, csi, osc, oscST, dcs, dcsST }
    private var parserState: ParserState = .ground
    private var swallowNext = false
    private var csiParams: [Int] = []
    private var csiIntermediates = ""
    private var csiPrivate = false
    private var oscPayload = ""

    init(rows: Int, cols: Int) {
        let r = min(max(rows, 2), 200)
        let c = min(max(cols, 2), 500)
        self.rows = r
        self.cols = c
        self.screen = (0..<r).map { _ in Self.blankLine(cols: c) }
    }

    // MARK: - Model access (for the view)

    var totalLineCount: Int { scrollback.count + screen.count }

    func line(at index: Int) -> [Cell] {
        if index < scrollback.count { return scrollback[index] }
        let s = index - scrollback.count
        if s >= 0 && s < screen.count { return screen[s] }
        return []
    }

    func screenCell(row: Int, col: Int) -> Cell {
        guard row >= 0, row < rows, col >= 0, col < cols else { return Cell() }
        return screen[row][col]
    }

    func selectAll() {
        guard totalLineCount > 0 else { return }
        selection = Selection(startLine: 0, startCol: 0,
                              endLine: totalLineCount - 1, endCol: cols - 1)
    }

    func clearSelection() { selection = nil }

    /// Copyable text for a selection: lines joined with "\n", trailing spaces
    /// trimmed per line, trailing empty lines dropped.
    func selectedText(_ sel: Selection) -> String {
        var out: [String] = []
        if sel.startLine > sel.endLine || (sel.startLine == sel.endLine && sel.startCol > sel.endCol) { return "" }
        for line in sel.startLine...sel.endLine {
            guard line >= 0, line < totalLineCount else { continue }
            let cells = self.line(at: line)
            guard !cells.isEmpty else { continue }
            let c0 = line == sel.startLine ? sel.startCol : 0
            let c1 = line == sel.endLine ? min(sel.endCol, cells.count - 1) : cells.count - 1
            guard c0 <= c1 else { continue }
            var s = ""
            for c in c0...c1 where c >= 0 && c < cells.count {
                let cell = cells[c]
                if cell.continuation { continue }
                s.append(cell.ch)
            }
            out.append(s.trimmingCharacters(in: .whitespaces))
        }
        while let last = out.last, last.isEmpty { out.removeLast() }
        return out.joined(separator: "\n")
    }

    /// Cmd+K: clear scrollback and the visible screen, keep the cursor home.
    func clearScreen() {
        scrollback.removeAll(keepingCapacity: true)
        for r in 0..<rows { screen[r] = Self.blankLine(cols: cols) }
        cursorRow = 0
        cursorCol = 0
        wrapPending = false
        selection = nil
    }

    // MARK: - Feeding

    func feed(_ text: String) {
        // Iterate UNICODE SCALARS, not grapheme clusters: UAX#29 merges CR+LF
        // into a single Character ("\r\n"), which would never match the "\r"
        // / "\n" cases below and would land in putChar as one cell. Terminals
        // are codepoint-based, so per-scalar processing is the correct model
        // (combining marks render as separate cells — documented limitation).
        for scalar in text.unicodeScalars {
            let ch = Character(scalar)
            switch parserState {
            case .ground:
                if ch == "\u{1B}" { parserState = .escape }
                else { handleGround(ch) }
            case .escape:
                handleEscape(ch)
            case .swallow:
                parserState = .ground // charset designation: swallow one char
            case .csi:
                handleCSIChar(ch)
            case .osc:
                if ch == "\u{07}" { finishOSC(); parserState = .ground }
                else if ch == "\u{1B}" { parserState = .oscST }
                else { oscPayload.append(ch) }
            case .oscST:
                if ch == "\\" { finishOSC() }
                parserState = .ground
            case .dcs:
                if ch == "\u{1B}" { parserState = .dcsST }
            case .dcsST:
                parserState = ch == "\\" ? .ground : .dcs
            }
        }
    }

    private func handleGround(_ ch: Character) {
        switch ch {
        case "\r": cursorCol = 0; wrapPending = false
        case "\n", "\u{0B}", "\u{0C}": lineFeed()
        case "\u{08}": // BS
            if cursorCol > 0 { cursorCol -= 1 }
            wrapPending = false
        case "\t":
            let next = (cursorCol / 8 + 1) * 8
            cursorCol = min(next, cols - 1)
            wrapPending = false
        case "\u{07}": NSSound.beep()
        default: putChar(ch)
        }
    }

    private func handleEscape(_ ch: Character) {
        switch ch {
        case "[": csiParams = []; csiIntermediates = ""; csiPrivate = false; parserState = .csi
        case "]": oscPayload = ""; parserState = .osc
        case "P": parserState = .dcs
        case "7": savedCursor = (cursorRow, cursorCol)          // DECSC
        case "8": if let sc = savedCursor { moveCursor(row: sc.row, col: sc.col) } // DECRC
        case "c": reset()                                       // RIS
        case "M": reverseIndex()                                // RI
        case "D": lineFeed()                                    // IND
        case "E": cursorCol = 0; lineFeed()                     // NEL
        case "(", ")", "*", "+": parserState = .swallow         // charset select
        default: break                                          // = > \ keypad/ST: ignore
        }
        if parserState != .csi && parserState != .osc && parserState != .dcs && parserState != .swallow {
            parserState = .ground
        }
    }

    private func handleCSIChar(_ ch: Character) {
        if let a = ch.asciiValue, a >= 0x30, a <= 0x39 {
            let v = Int(a - 0x30)
            if csiParams.isEmpty { csiParams.append(0) }
            csiParams[csiParams.count - 1] = csiParams[csiParams.count - 1] * 10 + v
            return
        }
        switch ch {
        case ";":
            csiParams.append(0)
        case "?", ">", "<":
            csiPrivate = true
        case " ":
            csiIntermediates.append(" ")
        default:
            if let a = ch.asciiValue, a >= 0x40, a <= 0x7E {
                handleCSI(final: ch)
                parserState = .ground
            }
        }
    }

    // MARK: - CSI dispatch

    private func handleCSI(final: Character) {
        let p = csiParams.isEmpty ? [0] : csiParams
        func param(_ i: Int, _ dflt: Int) -> Int {
            i < p.count ? (p[i] == 0 ? dflt : p[i]) : dflt
        }
        defer { csiParams = []; csiIntermediates = ""; csiPrivate = false }
        if csiPrivate {
            handlePrivateCSI(final: final, p: p)
            return
        }
        switch final {
        case "A": moveCursor(row: cursorRow - param(0, 1), col: cursorCol)
        case "B": moveCursor(row: cursorRow + param(0, 1), col: cursorCol)
        case "C": moveCursor(row: cursorRow, col: cursorCol + param(0, 1))
        case "D": moveCursor(row: cursorRow, col: cursorCol - param(0, 1))
        case "H", "f": moveCursor(row: param(0, 1) - 1, col: param(1, 1) - 1)
        case "G": moveCursor(row: cursorRow, col: param(0, 1) - 1)
        case "d": moveCursor(row: param(0, 1) - 1, col: cursorCol)
        case "E": moveCursor(row: cursorRow + param(0, 1), col: 0)
        case "F": moveCursor(row: cursorRow - param(0, 1), col: 0)
        case "J": eraseDisplay(mode: param(0, 0))
        case "K": eraseLine(mode: param(0, 0))
        case "m": applySGR(p)
        case "s": savedCursor = (cursorRow, cursorCol)
        case "u": if let sc = savedCursor { moveCursor(row: sc.row, col: sc.col) }
        case "X": eraseChars(n: param(0, 1))
        case "P": deleteChars(n: param(0, 1))
        case "@": insertChars(n: param(0, 1))
        case "L": insertLines(n: param(0, 1))
        case "M": deleteLines(n: param(0, 1))
        case "S": scrollScreen(up: param(0, 1))
        case "T": scrollScreen(up: -param(0, 1))
        case "h", "l": break // SM/RM without '?' — ignore
        case "r": break      // DECSTBM scroll region — ignored (limitation)
        default: break
        }
    }

    private func handlePrivateCSI(final: Character, p: [Int]) {
        switch final {
        case "h":
            for m in p where m != 0 {
                switch m {
                case 25: cursorVisible = true
                case 47, 1049: enterAltScreen()
                case 1: applicationCursorKeys = true   // DECCKM: arrows → ESC O A…
                case 2004: bracketedPaste = true       // pasted text needs markers
                default: break
                }
            }
        case "l":
            for m in p where m != 0 {
                switch m {
                case 25: cursorVisible = false
                case 47, 1049: exitAltScreen()
                case 1: applicationCursorKeys = false
                case 2004: bracketedPaste = false
                default: break
                }
            }
        default: break
        }
    }

    private func moveCursor(row: Int, col: Int) {
        cursorRow = min(max(row, 0), rows - 1)
        cursorCol = min(max(col, 0), cols - 1)
        wrapPending = false
    }

    private func lineFeed() {
        if cursorRow == rows - 1 {
            let top = screen.removeFirst()
            if !inAltScreen {
                scrollback.append(top)
                if scrollback.count > maxScrollback {
                    scrollback.removeFirst(scrollback.count - maxScrollback)
                }
            }
            screen.append(blankLine())
        } else {
            cursorRow += 1
        }
    }

    private func reverseIndex() {
        if cursorRow > 0 {
            cursorRow -= 1
        } else {
            screen.removeLast()
            screen.insert(blankLine(), at: 0)
        }
        wrapPending = false
    }

    // MARK: - Character placement

    private func putChar(_ ch: Character) {
        if wrapPending {
            cursorCol = 0
            lineFeed()
            wrapPending = false
        }
        let w = Self.displayWidth(ch)
        if w == 2 {
            if cursorCol >= cols - 1 { // wide char does not fit: wrap first
                cursorCol = 0
                lineFeed()
            }
            guard cursorCol < cols else { return }
            let old = screen[cursorRow][cursorCol]
            if old.continuation && cursorCol > 0 { screen[cursorRow][cursorCol - 1] = blankCell() }
            if !old.continuation && cursorCol + 1 < cols && screen[cursorRow][cursorCol + 1].continuation {
                screen[cursorRow][cursorCol + 1] = blankCell()
            }
            screen[cursorRow][cursorCol] = styledCell(ch)
            if cursorCol + 1 < cols {
                screen[cursorRow][cursorCol + 1] = continuationCell()
                cursorCol += 2
            } else {
                cursorCol = cols - 1
            }
        } else {
            guard cursorCol < cols else { return }
            let old = screen[cursorRow][cursorCol]
            if old.continuation && cursorCol > 0 { screen[cursorRow][cursorCol - 1] = blankCell() }
            if !old.continuation && cursorCol + 1 < cols && screen[cursorRow][cursorCol + 1].continuation {
                screen[cursorRow][cursorCol + 1] = blankCell()
            }
            screen[cursorRow][cursorCol] = styledCell(ch)
            cursorCol += 1
            wrapPending = cursorCol >= cols
            if cursorCol >= cols { cursorCol = cols - 1 }
        }
    }

    // MARK: - Erase / insert / delete

    private func eraseDisplay(mode: Int) {
        switch mode {
        case 0:
            eraseLine(mode: 0)
            for r in (cursorRow + 1)..<rows { screen[r] = blankLine() }
        case 1:
            for r in 0..<cursorRow { screen[r] = blankLine() }
            eraseLine(mode: 1)
        case 2:
            for r in 0..<rows { screen[r] = blankLine() }
        case 3:
            scrollback.removeAll(keepingCapacity: true)
        default: break
        }
    }

    private func eraseLine(mode: Int) {
        switch mode {
        case 0:
            for c in cursorCol..<cols { clearCell(cursorRow, c) }
        case 1:
            for c in 0...cursorCol { clearCell(cursorRow, c) }
        default:
            for c in 0..<cols { clearCell(cursorRow, c) }
        }
    }

    private func eraseChars(n: Int) {
        let end = min(cursorCol + n, cols)
        for c in cursorCol..<end { clearCell(cursorRow, c) }
    }

    private func deleteChars(n: Int) {
        let count = min(n, cols - cursorCol)
        guard count > 0 else { return }
        for c in cursorCol..<(cols - count) {
            screen[cursorRow][c] = screen[cursorRow][c + count]
        }
        for c in (cols - count)..<cols {
            screen[cursorRow][c] = blankCell()
        }
    }

    private func insertChars(n: Int) {
        guard cursorCol + n < cols else { return }
        for c in stride(from: cols - 1, through: cursorCol + n, by: -1) {
            screen[cursorRow][c] = screen[cursorRow][c - n]
        }
        for c in cursorCol..<(cursorCol + n) { screen[cursorRow][c] = blankCell() }
    }

    private func insertLines(n: Int) {
        for _ in 0..<n {
            guard cursorRow < rows - 1 || rows > 0 else { break }
            if cursorRow == rows - 1 { break }
            screen.removeLast()
            screen.insert(blankLine(), at: cursorRow)
        }
    }

    private func deleteLines(n: Int) {
        for _ in 0..<n {
            guard cursorRow < rows else { break }
            screen.remove(at: cursorRow)
            screen.append(blankLine())
        }
    }

    private func scrollScreen(up: Int) {
        guard up != 0 else { return }
        if up > 0 {
            for _ in 0..<up {
                screen.removeFirst()
                screen.append(blankLine())
            }
        } else {
            for _ in 0..<(-up) {
                screen.removeLast()
                screen.insert(blankLine(), at: 0)
            }
        }
    }

    private func clearCell(_ r: Int, _ c: Int) {
        guard r >= 0, r < rows, c >= 0, c < cols else { return }
        let old = screen[r][c]
        screen[r][c] = blankCell()
        if old.continuation && c > 0 && !screen[r][c - 1].continuation {
            screen[r][c - 1] = blankCell()
        }
        if !old.continuation && c + 1 < cols && screen[r][c + 1].continuation {
            screen[r][c + 1] = blankCell()
        }
    }

    // MARK: - SGR

    private func applySGR(_ p: [Int]) {
        let params = p.isEmpty ? [0] : p
        var i = 0
        while i < params.count {
            let code = params[i]
            switch code {
            case 0: cur = Cell()
            case 1: cur.bold = true
            case 3: cur.italic = true
            case 4: cur.underline = true
            case 7: cur.inverse = true
            case 22: cur.bold = false
            case 23: cur.italic = false
            case 24: cur.underline = false
            case 27: cur.inverse = false
            case 30...37: cur.fg = Self.basePalette[code - 30]
            case 38:
                if i + 1 < params.count {
                    if params[i + 1] == 5, i + 2 < params.count {
                        cur.fg = Self.palette256(params[i + 2]); i += 2
                    } else if params[i + 1] == 2, i + 4 < params.count {
                        cur.fg = Self.rgb(params[i + 2], params[i + 3], params[i + 4]); i += 4
                    }
                }
            case 39: cur.fg = nil
            case 40...47: cur.bg = Self.basePalette[code - 40]
            case 48:
                if i + 1 < params.count {
                    if params[i + 1] == 5, i + 2 < params.count {
                        cur.bg = Self.palette256(params[i + 2]); i += 2
                    } else if params[i + 1] == 2, i + 4 < params.count {
                        cur.bg = Self.rgb(params[i + 2], params[i + 3], params[i + 4]); i += 4
                    }
                }
            case 49: cur.bg = nil
            case 90...97: cur.fg = Self.basePalette[code - 90 + 8]
            case 100...107: cur.bg = Self.basePalette[code - 100 + 8]
            default: break
            }
            i += 1
        }
    }

    // MARK: - Alternate screen / reset / resize

    private func enterAltScreen() {
        guard !inAltScreen else { return }
        savedScreen = screen
        savedScrollback = scrollback
        altSavedCursor = (cursorRow, cursorCol)
        inAltScreen = true
        scrollback = []
        screen = (0..<rows).map { _ in blankLine() }
        cursorRow = 0
        cursorCol = 0
        wrapPending = false
        selection = nil
    }

    private func exitAltScreen() {
        guard inAltScreen else { return }
        inAltScreen = false
        screen = savedScreen.isEmpty ? (0..<rows).map { _ in blankLine() } : savedScreen
        scrollback = savedScrollback
        let sc = altSavedCursor ?? (0, 0)
        moveCursor(row: sc.row, col: sc.col)
        savedScreen = []
        savedScrollback = []
        altSavedCursor = nil
    }

    private func reset() {
        scrollback = []
        screen = (0..<rows).map { _ in blankLine() }
        cursorRow = 0
        cursorCol = 0
        cur = Cell()
        wrapPending = false
        cursorVisible = true
        applicationCursorKeys = false
        bracketedPaste = false
        inAltScreen = false
        savedScreen = []
        savedScrollback = []
        savedCursor = nil
        altSavedCursor = nil
        selection = nil
    }

    func resize(rows newRows: Int, cols newCols: Int) {
        let newRows = min(max(newRows, 2), 200)
        let newCols = min(max(newCols, 2), 500)
        guard newRows != rows || newCols != cols else { return }

        // Rebuild the screen from the bottom of (scrollback + screen) so
        // shrinking keeps the most recent content.
        let all = scrollback + screen
        let keep = max(newRows, rows)
        let start = max(0, all.count - keep)
        let kept = Array(all[start...])
        var newScreen: [Line]
        if kept.count >= newRows {
            newScreen = Array(kept.suffix(newRows))
            scrollback = Array(kept.prefix(max(0, kept.count - newRows)))
        } else {
            newScreen = kept
            while newScreen.count < newRows { newScreen.insert(Self.blankLine(cols: newCols), at: 0) }
            scrollback = []
        }
        for i in newScreen.indices {
            if newScreen[i].count > newCols {
                newScreen[i] = Array(newScreen[i].prefix(newCols))
            } else if newScreen[i].count < newCols {
                newScreen[i] += (0..<(newCols - newScreen[i].count)).map { _ in blankCell() }
            }
        }
        screen = newScreen
        rows = newRows
        cols = newCols
        cursorRow = min(cursorRow, rows - 1)
        cursorCol = min(cursorCol, cols - 1)
        wrapPending = false
        if scrollback.count > maxScrollback {
            scrollback.removeFirst(scrollback.count - maxScrollback)
        }
    }

    // MARK: - Cells & palette

    private func styledCell(_ ch: Character) -> Cell {
        var c = cur
        c.ch = ch
        return c
    }

    private func blankCell() -> Cell { Cell() }

    private func continuationCell() -> Cell {
        var c = Cell()
        c.continuation = true
        return c
    }

    private func blankLine() -> Line { Self.blankLine(cols: cols) }

    private static func blankLine(cols: Int) -> Line {
        Line(repeating: Cell(), count: cols)
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(min(max(r, 0), 255)) / 255.0,
                green: CGFloat(min(max(g, 0), 255)) / 255.0,
                blue: CGFloat(min(max(b, 0), 255)) / 255.0,
                alpha: 1)
    }

    /// Classic xterm 16-color palette.
    static let basePalette: [NSColor] = [
        rgb(0, 0, 0), rgb(205, 0, 0), rgb(0, 205, 0), rgb(205, 205, 0),
        rgb(0, 0, 238), rgb(205, 0, 205), rgb(0, 205, 205), rgb(229, 229, 229),
        rgb(127, 127, 127), rgb(255, 0, 0), rgb(0, 255, 0), rgb(255, 255, 0),
        rgb(92, 92, 255), rgb(255, 0, 255), rgb(0, 255, 255), rgb(255, 255, 255),
    ]

    static func palette256(_ n: Int) -> NSColor {
        if n < 16 { return basePalette[n] }
        if n < 232 {
            let v = n - 16
            let r = v / 36, g = (v / 6) % 6, b = v % 6
            func level(_ x: Int) -> CGFloat { x == 0 ? 0 : CGFloat(95 + (x - 1) * 40) / 255 }
            return rgb(Int(level(r) * 255), Int(level(g) * 255), Int(level(b) * 255))
        }
        let g = CGFloat(8 + (n - 232) * 10) / 255
        return rgb(Int(g * 255), Int(g * 255), Int(g * 255))
    }

    /// Rough display width: CJK / wide emoji ranges are 2 columns, everything
    /// else 1 (combining/ZWJ sequences are approximated as 1 — documented).
    static func displayWidth(_ ch: Character) -> Int {
        guard let scalar = ch.unicodeScalars.first?.value else { return 1 }
        if (0x1100...0x115F).contains(scalar)
            || (0x2E80...0xA4CF).contains(scalar)
            || (0xAC00...0xD7A3).contains(scalar)
            || (0xF900...0xFAFF).contains(scalar)
            || (0xFE30...0xFE4F).contains(scalar)
            || (0xFF00...0xFF60).contains(scalar)
            || (0xFFE0...0xFFE6).contains(scalar)
            || (0x1F300...0x1F64F).contains(scalar)
            || (0x1F900...0x1F9FF).contains(scalar)
            || (0x20000...0x3FFFD).contains(scalar) {
            return 2
        }
        return 1
    }

    // MARK: - OSC

    private func finishOSC() {
        let parts = oscPayload.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        oscPayload = ""
        guard parts.count == 2 else { return }
        let cmd = String(parts[0])
        if cmd == "0" || cmd == "2" {
            let title = String(parts[1])
            if !title.isEmpty { onTitle?(title) }
        }
        // Other OSC (clipboard, cwd, …) are ignored.
    }
}

// MARK: - Terminal view (rendering + input)

/// Renders a TerminalEmulator grid and forwards keyboard/mouse input to the
/// session. Cmd+C/V/A are served through the responder chain (Edit menu);
/// Cmd+K clears the screen.
final class TerminalView: NSView {

    let emulator: TerminalEmulator
    weak var session: TerminalSession?

    private let font: NSFont
    private let cellWidth: CGFloat
    private let lineHeight: CGFloat

    /// Viewport state: `followOutput` tracks the screen bottom; otherwise
    /// `topLine` is the absolute buffer line shown at the top.
    private var followOutput = true
    private var topLine = 0

    // Mouse selection state (absolute buffer coordinates).
    private var mouseAnchorLine = 0
    private var mouseAnchorCol = 0
    private var mouseCurrentLine = 0
    private var mouseCurrentCol = 0
    private var isSelecting = false

    /// Tab shortcuts: Cmd+1…9 selects a tab by index; Cmd+Shift+[ / ] cycles.
    var onCmdDigit: ((Int) -> Void)?
    var onCycleTabs: ((Int) -> Void)?

    init(emulator: TerminalEmulator, session: TerminalSession?) {
        self.emulator = emulator
        self.session = session
        self.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        self.cellWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        self.lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Grid sizing

    override func layout() {
        super.layout()
        updateGridSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGridSize()
    }

    private func updateGridSize() {
        // While the right panel is collapsed (divider pushed to the edge) or
        // hidden, this view gets squeezed to near-zero width. Resizing the
        // emulator AND the PTY (TIOCSWINSZ) at that size would make the shell
        // redraw its whole screen wrapped at 2 columns; after re-expanding,
        // those 2-column fragments stay garbled in the scrollback. So only
        // resize when the view is actually visible with a usable size — the
        // real size is applied on the next layout once the panel shows again.
        let w = bounds.width
        let h = bounds.height
        guard !isHiddenOrHasHiddenAncestor, w >= 48, h >= 32 else { return }
        let cols = max(2, Int(w / cellWidth))
        let rows = max(2, Int(h / lineHeight))
        if cols != emulator.cols || rows != emulator.rows {
            emulator.resize(rows: rows, cols: cols)
            session?.resize(rows: rows, cols: cols)
        }
    }

    // MARK: - Rendering

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSColor.textBackgroundColor
        bg.setFill()
        dirtyRect.fill()

        let total = emulator.totalLineCount
        guard total > 0, emulator.rows > 0, emulator.cols > 0 else { return }
        let maxTop = max(0, total - emulator.rows)
        let start = followOutput ? maxTop : min(topLine, maxTop)
        let selection = emulator.selection
        for r in 0..<emulator.rows {
            let idx = start + r
            guard idx < total else { break }
            drawLine(idx, row: r, selection: selection)
        }
        if emulator.cursorVisible && followOutput {
            drawCursor()
        }
    }

    private func effectiveCell(_ cell: TerminalEmulator.Cell) -> (fg: NSColor?, bg: NSColor?) {
        if cell.inverse {
            let fg = cell.bg ?? NSColor.textBackgroundColor
            let bg = cell.fg ?? NSColor.textColor
            return (fg, bg)
        }
        return (cell.fg, cell.bg)
    }

    private func drawLine(_ lineIndex: Int, row: Int, selection: TerminalEmulator.Selection?) {
        let cells = emulator.line(at: lineIndex)
        guard !cells.isEmpty else { return }
        let y = bounds.height - CGFloat(row + 1) * lineHeight

        // 1) background fills (explicit bg + selection overlay)
        for c in 0..<cells.count {
            let cell = cells[c]
            let rect = NSRect(x: CGFloat(c) * cellWidth, y: y, width: cellWidth, height: lineHeight)
            let (_, bg) = effectiveCell(cell)
            if let bg = bg {
                bg.setFill()
                rect.fill()
            }
            if let sel = selection, isSelected(sel, line: lineIndex, col: c) {
                NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
                rect.fill()
            }
        }

        // 2) text runs (wide chars span two cells; continuation cells skipped)
        var runs: [(text: String, x: CGFloat, attrs: [NSAttributedString.Key: Any])] = []
        var runStart = -1
        var runText = ""
        var runFg: NSColor?
        var runBold = false
        var runItalic = false
        var runUnderline = false
        func flushRun() {
            if runStart >= 0 {
                var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
                if let f = runFg { attrs[.foregroundColor] = f }
                var f = font
                if runBold { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
                if runItalic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
                if f != font { attrs[.font] = f }
                if runUnderline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                runs.append((runText, CGFloat(runStart) * cellWidth, attrs))
                runText = ""
                runStart = -1
            }
        }
        for c in 0..<cells.count {
            let cell = cells[c]
            if cell.continuation { continue }
            let (fg, _) = effectiveCell(cell)
            if runStart < 0 || fg != runFg || cell.bold != runBold
                || cell.italic != runItalic || cell.underline != runUnderline {
                flushRun()
                runFg = fg
                runBold = cell.bold
                runItalic = cell.italic
                runUnderline = cell.underline
                runStart = c
            }
            runText.append(cell.ch)
        }
        flushRun()
        for run in runs {
            (run.text as NSString).draw(at: NSPoint(x: run.x, y: y), withAttributes: run.attrs)
        }
    }

    private func isSelected(_ sel: TerminalEmulator.Selection, line: Int, col: Int) -> Bool {
        if line < sel.startLine || line > sel.endLine { return false }
        if line == sel.startLine && line == sel.endLine {
            return col >= sel.startCol && col <= sel.endCol
        }
        if line == sel.startLine { return col >= sel.startCol }
        if line == sel.endLine { return col <= sel.endCol }
        return true
    }

    private func drawCursor() {
        let r = emulator.cursorRow
        let c = emulator.cursorCol
        guard r >= 0, r < emulator.rows, c >= 0, c < emulator.cols else { return }
        let rect = NSRect(x: CGFloat(c) * cellWidth,
                          y: bounds.height - CGFloat(r + 1) * lineHeight,
                          width: cellWidth, height: lineHeight)
        NSColor.controlAccentColor.setFill()
        rect.fill()
        let cell = emulator.screenCell(row: r, col: c)
        if !cell.continuation, cell.ch != " " {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            (String(cell.ch) as NSString).draw(at: NSPoint(x: rect.minX, y: rect.minY), withAttributes: attrs)
        }
    }

    // MARK: - Scrolling & selection

    private func visibleTopLine() -> Int {
        let total = emulator.totalLineCount
        let maxTop = max(0, total - emulator.rows)
        return followOutput ? maxTop : min(topLine, maxTop)
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY
        guard dy != 0 else { return }
        // Positive deltaY = two-finger-up = scroll back into history (natural
        // scrolling). If QA finds the direction inverted, flip this sign.
        let step: Int
        if abs(dy) < 1 {
            step = dy > 0 ? 1 : -1
        } else {
            step = Int(dy / 4)
        }
        let total = emulator.totalLineCount
        let maxTop = max(0, total - emulator.rows)
        topLine = min(max(visibleTopLine() + step, 0), maxTop)
        followOutput = topLine >= maxTop
        needsDisplay = true
    }

    private func cell(at point: NSPoint) -> (line: Int, col: Int) {
        let row = Int((bounds.height - point.y) / lineHeight)
        let col = Int(point.x / cellWidth)
        let line = min(max(visibleTopLine() + row, 0), max(0, emulator.totalLineCount - 1))
        let clampedCol = min(max(col, 0), max(0, emulator.cols - 1))
        return (line, clampedCol)
    }

    private func normalizeSelection() -> TerminalEmulator.Selection? {
        let a = (mouseAnchorLine, mouseAnchorCol)
        let b = (mouseCurrentLine, mouseCurrentCol)
        let start: (Int, Int), end: (Int, Int)
        if a.0 < b.0 || (a.0 == b.0 && a.1 <= b.1) {
            start = a; end = b
        } else {
            start = b; end = a
        }
        return TerminalEmulator.Selection(startLine: start.0, startCol: start.1,
                                          endLine: end.0, endCol: end.1)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let pt = cell(at: convert(event.locationInWindow, from: nil))
        mouseAnchorLine = pt.line
        mouseAnchorCol = pt.col
        mouseCurrentLine = pt.line
        mouseCurrentCol = pt.col
        isSelecting = true
        emulator.selection = normalizeSelection()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isSelecting else { return }
        let pt = cell(at: convert(event.locationInWindow, from: nil))
        mouseCurrentLine = pt.line
        mouseCurrentCol = pt.col
        emulator.selection = normalizeSelection()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isSelecting = false
        if mouseAnchorLine == mouseCurrentLine && mouseAnchorCol == mouseCurrentCol {
            emulator.clearSelection() // plain click: clear selection
            needsDisplay = true
        }
    }

    // MARK: - Responder actions (Edit menu: Cmd+C/V/A)
    // copy:/paste: are not declared on NSResponder (they come from NSText);
    // the plain methods still work through the responder chain — but they
    // MUST be @objc-exposed, otherwise the Edit menu's ObjC dispatch can't
    // find them (validation would disable Cmd+C/V while the terminal is
    // first responder).

    @objc func copy(_ sender: Any?) {
        guard let sel = emulator.selection else {
            session?.write(Data([0x03])) // no selection: send ^C (SIGINT)
            return
        }
        let text = emulator.selectedText(sel)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session?.write(Data([0x03]))
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        var payload = text
        // When the shell has enabled bracketed paste (CSI ?2004h — zsh and
        // bash do), the pasted text MUST be wrapped in ESC [ 200~…ESC [ 201~;
        // otherwise the shell renders the characters garbled. When disabled,
        // write the text verbatim.
        if emulator.bracketedPaste {
            payload = "\u{1B}[200~" + payload + "\u{1B}[201~"
        }
        if ProcessInfo.processInfo.environment["DSH_TERMINAL_DEBUG"] == "1" {
            let prefix = payload.prefix(40).utf8.map { String(format: "%02x", $0) }.joined(separator: " ")
            AppLog.shared.log("term input: paste \(text.count) chars bracketed=\(emulator.bracketedPaste) bytes(\(payload.utf8.count)) [\(prefix)…]")
        }
        session?.write(payload)
    }

    override func selectAll(_ sender: Any?) {
        emulator.selectAll()
        needsDisplay = true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let base = (event.charactersIgnoringModifiers ?? "").lowercased()

        // Command combos: Cmd+C/V/A are normally handled by the Edit menu
        // (responder chain); handle them here as a fallback for when the menu
        // item is disabled, plus Cmd+K = clear and Cmd+1…9 / Cmd+Shift+[/] =
        // tab shortcuts.
        if mods.contains(.command) {
            if base == "k" {
                emulator.clearScreen()
                needsDisplay = true
                return
            }
            if base == "v" { paste(nil); return }
            if base == "c" { copy(nil); return }
            if base == "a" { selectAll(nil); return }
            if let n = Int(base), (1...9).contains(n) {
                onCmdDigit?(n)
                return
            }
            if mods.contains(.shift) {
                switch event.keyCode {
                case 33: onCycleTabs?(-1); return   // Cmd+Shift+[
                case 30: onCycleTabs?(1); return    // Cmd+Shift+]
                default: break
                }
            }
            return
        }

        // Special keys (arrows, home/end, function keys…) FIRST — their
        // `characters` is empty, so the characters guard below would swallow
        // them (e.g. ↑/↓ history recall would never reach the shell). Arrows
        // honor DECCKM application mode (zsh enables it: ESC O A…).
        if let special = specialKey(for: event.keyCode) {
            if ProcessInfo.processInfo.environment["DSH_TERMINAL_DEBUG"] == "1" {
                AppLog.shared.log("term input: special keyCode=\(event.keyCode) -> \(special.debugDescription)")
            }
            session?.write(special)
            return
        }

        guard let chars = event.characters, !chars.isEmpty else { return }
        let unmod = (event.charactersIgnoringModifiers ?? chars).lowercased()

        if mods.contains(.control), let c = unmod.unicodeScalars.first, c.isASCII {
            if ProcessInfo.processInfo.environment["DSH_TERMINAL_DEBUG"] == "1" {
                AppLog.shared.log("term input: ctrl \(String(format: "0x%02X", c.value & 0x1F))")
            }
            session?.write(Data([UInt8(c.value & 0x1F)]))
            return
        }
        if mods.contains(.option) {
            // Meta: ESC + the unmodified key character (e.g. Option+→ = ESC+f).
            session?.write("\u{1B}" + (event.charactersIgnoringModifiers ?? chars))
            return
        }
        if ProcessInfo.processInfo.environment["DSH_TERMINAL_DEBUG"] == "1" {
            AppLog.shared.log("term input: chars=\(chars.debugDescription)")
        }
        session?.write(chars)
    }

    private func specialKey(for keyCode: UInt16) -> String? {
        // DECCKM application cursor mode: ESC O <letter>; normal mode: ESC [ <letter>.
        func arrow(_ letter: String) -> String {
            emulator.applicationCursorKeys ? "\u{1B}O\(letter)" : "\u{1B}[\(letter)"
        }
        switch keyCode {
        case 36: return "\r"
        case 48: return "\t"
        case 51: return "\u{7F}"              // backspace (DEL)
        case 53: return "\u{1B}"              // escape
        case 123: return arrow("D")           // left
        case 124: return arrow("C")           // right
        case 125: return arrow("B")           // down
        case 126: return arrow("A")           // up
        case 115: return "\u{1B}[H"           // home
        case 119: return "\u{1B}[F"           // end
        case 116: return "\u{1B}[5~"          // page up
        case 121: return "\u{1B}[6~"          // page down
        case 117: return "\u{1B}[3~"          // forward delete
        case 122: return "\u{1B}OP"           // F1
        case 120: return "\u{1B}OQ"           // F2
        case 99: return "\u{1B}OR"            // F3
        case 118: return "\u{1B}OS"           // F4
        case 96: return "\u{1B}[15~"          // F5
        case 97: return "\u{1B}[17~"          // F6
        case 98: return "\u{1B}[18~"          // F7
        case 100: return "\u{1B}[19~"         // F8
        case 101: return "\u{1B}[20~"         // F9
        case 109: return "\u{1B}[21~"         // F10
        case 103: return "\u{1B}[23~"         // F11
        case 111: return "\u{1B}[24~"         // F12
        default: return nil
        }
    }
}


/// Root view for the terminal panel. Draws the same gray background as
/// DynamicFillView(kind=.window) but with isOpaque=false so Core Animation
/// properly composites all subviews (especially the header) in the
/// layer-backed window.
final class TerminalRootView: NSView {
    var kind: DynamicFillView.Kind = .window {
        didSet { needsDisplay = true }
    }
    override var isOpaque: Bool { false }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color: NSColor
        switch kind {
        case .window:
            color = dark ? NSColor(calibratedWhite: 0.28, alpha: 1) : NSColor(calibratedWhite: 0.94, alpha: 1)
        case .control:
            color = dark ? NSColor(calibratedWhite: 0.20, alpha: 1) : NSColor(calibratedWhite: 0.86, alpha: 1)
        case .custom(let c):
            color = c
        }
        color.setFill()
        dirtyRect.fill()
    }
}


/// The terminal panel: header (session title + new/close), a tab bar with one
/// tab per PTY session, and the active TerminalView. Mirrors the preview
/// panel's structure; both share the split view's right slot.
final class TerminalPanelController: NSObject {

    /// Root view mounted directly as the right pane of the main split view.
    /// TerminalRootView = DynamicFillView with isOpaque=false so the header
    /// is properly composited in the layer-backed window.
    let view = TerminalRootView()

    /// Invoked when the user hits the panel's "Close" button.
    var onRequestHide: (() -> Void)?

    /// Supplies the dsh web server port (used to resolve the project
    /// directory as the new session's starting directory).
    var serverPortProvider: (() -> Int)?

    static let minWidth: CGFloat = 300

    private final class Tab {
        let id: Int
        let container: NSView
        let titleButton: NSButton
        let closeButton: NSButton
        var session: TerminalSession
        var emulator: TerminalEmulator
        var termView: TerminalView
        init(id: Int, title: String, session: TerminalSession, emulator: TerminalEmulator, termView: TerminalView) {
            self.id = id
            self.session = session
            self.emulator = emulator
            self.termView = termView
            let titleButton = NSButton(title: title, target: nil, action: nil)
            titleButton.bezelStyle = .texturedRounded
            titleButton.setButtonType(.pushOnPushOff)
            titleButton.state = .off
            titleButton.tag = id
            titleButton.cell?.lineBreakMode = .byTruncatingTail
            titleButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titleButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
            titleButton.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
            self.titleButton = titleButton
            let closeButton = NSButton(title: "✕", target: nil, action: nil)
            closeButton.bezelStyle = .inline
            closeButton.tag = id
            closeButton.toolTip = L10n.tr("terminal.closeTab")
            self.closeButton = closeButton
            let container = NSStackView(views: [titleButton, closeButton])
            container.orientation = .horizontal
            container.spacing = 2
            container.alignment = .centerY
            container.translatesAutoresizingMaskIntoConstraints = false
            container.setHuggingPriority(.defaultHigh, for: .horizontal)
            self.container = container
        }
    }

    private var tabs: [Tab] = []
    private var selectedId: Int?
    private var nextId = 1
    private var startedOnce = false
    private var shuttingDown = false

    /// dsh web server state for the session-start directory. The server may
    /// still be booting when the panel first opens (fresh spawn on app
    /// launch), so spawns are deferred until it is reachable — otherwise the
    /// cwd RPC fails and sessions start in ~ instead of the project dir.
    private var serverReadyPort: Int?
    private var deferredSpawns = 0
    private var spawnFallbackTimer: Timer?

    // Subviews
    private let headerTitle = HeaderLabel()
    private var newButton: CustomIconButton!
    private var closeButton: CustomIconButton!
    private let tabScroll = NSScrollView()
    private let tabStack = NSStackView()
    private let contentContainer = NSView()

    override init() {
        super.init()
        buildUI()
        showEmptyState()
        // The click-to-focus monitor is registered lazily (see
        // ensureSession): registering a local event monitor during launch can
        // stall the startup path before the event system is ready.
    }

    private var clickMonitor: Any?

    // MARK: - UI

    private func buildUI() {
        // --- header: title label (left) + icon action buttons (right) ---
        // All header content is custom-drawn (HeaderLabel / CustomIconButton):
        // NSTextField/NSButton cells were observed not rendering in some
        // environments, while Core Graphics text and bezier paths render.
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        headerTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Icon buttons with tooltips (hover shows what each does).
        let newButton = CustomIconButton(glyph: .plus, tooltip: L10n.tr("terminal.new"))
        newButton.onAction = { [weak self] in self?.newSessionTapped(nil) }
        let closeButton = CustomIconButton(glyph: .close, tooltip: L10n.tr("terminal.closePanel"))
        closeButton.onAction = { [weak self] in self?.hidePanel(nil) }
        self.newButton = newButton
        self.closeButton = closeButton

        let actions = NSStackView(views: [newButton, closeButton])
        actions.orientation = .horizontal
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false

        // Header strip: explicit dynamic background so the top bar is a
        // defined block (consistent with the preview panel) in both modes.
        let header = DynamicFillView()
        header.kind = .window
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerTitle)
        header.addSubview(actions)
        NSLayoutConstraint.activate([
            headerTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            headerTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerTitle.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),
            actions.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            actions.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),
        ])

        // --- tab bar (horizontally scrollable) ---
        tabStack.orientation = .horizontal
        tabStack.spacing = 6
        tabStack.alignment = .centerY
        tabStack.distribution = .gravityAreas
        tabStack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        tabStack.translatesAutoresizingMaskIntoConstraints = false

        tabScroll.documentView = tabStack
        tabScroll.hasHorizontalScroller = true
        tabScroll.hasVerticalScroller = false
        tabScroll.drawsBackground = false
        tabScroll.scrollerStyle = .overlay
        tabScroll.autohidesScrollers = true
        tabScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tabStack.leadingAnchor.constraint(equalTo: tabScroll.contentView.leadingAnchor),
            tabStack.topAnchor.constraint(equalTo: tabScroll.contentView.topAnchor),
            tabStack.bottomAnchor.constraint(equalTo: tabScroll.contentView.bottomAnchor),
            tabStack.widthAnchor.constraint(greaterThanOrEqualTo: tabScroll.contentView.widthAnchor),
        ])

        let tabBarUnderline = NSBox()
        tabBarUnderline.boxType = .separator
        tabBarUnderline.translatesAutoresizingMaskIntoConstraints = false

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true
        contentContainer.layer?.masksToBounds = true

        // Add all subviews together, then activate all constraints together
        // (same pattern as PreviewPanel).
        view.addSubview(header)
        view.addSubview(tabScroll)
        view.addSubview(tabBarUnderline)
        view.addSubview(contentContainer)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            tabScroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            tabScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // header (40) + tab bar (33) + separator (1) = 74pt, matching the
            // height of dsh web's workspace top so the two panes line up.
            tabScroll.heightAnchor.constraint(equalToConstant: 33),

            tabBarUnderline.topAnchor.constraint(equalTo: tabScroll.bottomAnchor),
            tabBarUnderline.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBarUnderline.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            contentContainer.topAnchor.constraint(equalTo: tabBarUnderline.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Diagnostics (DSH_UI_DEBUG=1): record the panel's effective
        // appearance so a dark-mode rendering problem can be traced from the
        // app log.
        if ProcessInfo.processInfo.environment["DSH_UI_DEBUG"] == "1" {
            AppLog.shared.log("terminal ui: panel.effective=\(String(describing: view.effectiveAppearance.name)) header=\(type(of: header))")
        }
    }

    // MARK: - Session lifecycle

    /// Spawn the first session lazily the first time the panel is shown.
    func ensureSession() {
        installClickMonitor()
        guard !startedOnce, !shuttingDown else { return }
        startedOnce = true
        newSession()
    }

    /// Clicking ANYWHERE in the panel chrome (header/tab bar/content) focuses
    /// the active terminal, so keyboard input (typing, arrows, ⌘C/V) always
    /// reaches the shell after a click. Registered lazily on first show.
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self, let win = self.view.window, win.isKeyWindow,
                  self.selectedId != nil, !self.tabs.isEmpty else { return event }
            let p = self.view.convert(event.locationInWindow, from: nil)
            if self.view.bounds.contains(p) {
                self.focusActiveTerminal()
            }
            return event
        }
    }

    /// The dsh web server is reachable on `port` (AppDelegate calls this once
    /// server.start() succeeds). Drain any spawns that were deferred while
    /// the server was still booting.
    func serverReady(port: Int) {
        serverReadyPort = port
        spawnFallbackTimer?.invalidate()
        spawnFallbackTimer = nil
        let n = deferredSpawns
        deferredSpawns = 0
        if n > 0 {
            AppLog.shared.log("terminal: server ready on :\(port), spawning \(n) deferred session(s)")
            for _ in 0..<n { newSession() }
        }
    }

    func newSession() {
        guard !shuttingDown else { return }
        guard let port = serverReadyPort else {
            // Server still booting: queue the spawn; a fallback timer ensures
            // the terminal still works even if the server never comes up.
            deferredSpawns += 1
            armSpawnFallbackTimer()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Resolve the project directory; fall back to home when there is
            // no usable dsh session yet.
            let cwd = DSHSessionRPC.fetchActiveSessionCwd(port: port, timeout: 5)
                ?? NSHomeDirectory()
            DispatchQueue.main.async {
                self?.spawnTab(cwd: cwd)
            }
        }
    }

    /// If the server never becomes ready (start failed, offline), spawn the
    /// deferred sessions in home after a grace period so the terminal is
    /// still usable.
    private func armSpawnFallbackTimer() {
        guard spawnFallbackTimer == nil else { return }
        let t = Timer(timeInterval: 10, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.spawnFallbackTimer = nil
            let n = self.deferredSpawns
            self.deferredSpawns = 0
            if n > 0 {
                let port = self.serverReadyPort ?? self.serverPortProvider?() ?? 3080
                AppLog.shared.log("terminal: server not ready in time; spawning \(n) session(s) on :\(port) (home cwd fallback)")
                for _ in 0..<n { self.spawnWithCwd(port: port) }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        spawnFallbackTimer = t
    }

    private func spawnWithCwd(port: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let cwd = DSHSessionRPC.fetchActiveSessionCwd(port: port, timeout: 5)
                ?? NSHomeDirectory()
            DispatchQueue.main.async {
                self?.spawnTab(cwd: cwd)
            }
        }
    }

    private func spawnTab(cwd: String) {
        guard !shuttingDown else { return }
        let shell = TerminalSession.resolveShell()
        let env = TerminalSession.buildEnv()
        let (rows, cols) = currentGridSize()
        guard let session = TerminalSession(shell: shell, args: ["-l"], env: env,
                                            cwd: cwd, rows: rows, cols: cols) else {
            AppLog.shared.log("terminal: failed to spawn session (shell=\(shell))")
            return
        }
        let id = nextId
        nextId += 1
        let emulator = TerminalEmulator(rows: rows, cols: cols)
        let termView = TerminalView(emulator: emulator, session: session)
        // Numbered default titles so multiple tabs are distinguishable;
        // a shell that sets an OSC title (e.g. zsh) replaces it.
        let tab = Tab(id: id, title: "\(L10n.tr("terminal.title")) \(id)",
                      session: session, emulator: emulator, termView: termView)
        tab.titleButton.target = self
        tab.titleButton.action = #selector(selectTab(_:))
        tab.closeButton.target = self
        tab.closeButton.action = #selector(closeTab(_:))
        termView.onCmdDigit = { [weak self] n in self?.selectTabIndex(n) }
        termView.onCycleTabs = { [weak self] delta in self?.cycleTab(delta: delta) }
        emulator.onTitle = { [weak self, weak tab] title in
            guard let self = self, let tab = tab else { return }
            tab.titleButton.title = title
            if self.selectedId == tab.id { self.headerTitle.text = title }
        }
        session.onOutput = { [weak termView] text in
            if ProcessInfo.processInfo.environment["DSH_TERMINAL_DEBUG"] == "1" {
                AppLog.shared.log("term output: \(text.prefix(120).debugDescription)")
            }
            termView?.emulator.feed(text)
            termView?.needsDisplay = true
        }
        session.onExit = { [weak self, weak tab] code, clean in
            guard let self = self, let tab = tab else { return }
            self.sessionEnded(tab, code: code, clean: clean)
        }
        tabs.append(tab)
        tabStack.addArrangedSubview(tab.container)
        select(id)
        AppLog.shared.log("terminal: session \(id) spawned pid=\(session.pid) shell=\(shell) cwd=\(cwd)")
    }

    /// A session ended. Clean exits (the user typed `exit` / Ctrl+D at the
    /// prompt) auto-close the tab — and the whole panel if it was the last
    /// one. Abnormal exits (killed by a signal, or exec failure) keep the tab
    /// with the ended state + restart button so the error stays visible.
    private func sessionEnded(_ tab: Tab, code: Int32, clean: Bool) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        AppLog.shared.log("terminal: session \(tab.id) ended (exit \(code)\(clean ? "" : ", signaled")")
        if clean {
            close(tab.id)
            if tabs.isEmpty { onRequestHide?() }
            return
        }
        markEnded(tab, code: code)
    }

    private func markEnded(_ tab: Tab, code: Int32) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        AppLog.shared.log("terminal: session \(tab.id) ended (exit \(code))")
        tab.container.subviews.forEach { $0.removeFromSuperview() }
        let icon = BakedIconView(symbol: "terminal")
        let label = NSTextField(wrappingLabelWithString: L10n.tr("terminal.sessionEnded", code))
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        let restart = NSButton(title: L10n.tr("terminal.restart"), target: self, action: #selector(restartTapped(_:)))
        restart.bezelStyle = .rounded
        restart.tag = tab.id
        let stack = NSStackView(views: [icon, label, restart])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        tab.container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: tab.container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: tab.container.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),
        ])
        if selectedId == tab.id {
            headerTitle.text = L10n.tr("terminal.sessionEnded", code)
        }
    }

    /// Terminate every session (app quit).
    func shutdownAll() {
        shuttingDown = true
        spawnFallbackTimer?.invalidate()
        spawnFallbackTimer = nil
        if let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
        for tab in tabs {
            tab.session.terminate()
        }
        tabs.removeAll()
        selectedId = nil
    }

    func focusActiveTerminal() {
        guard let tab = tabs.first(where: { $0.id == selectedId }), view.window != nil else { return }
        view.window?.makeFirstResponder(tab.termView)
    }

    private func currentGridSize() -> (rows: Int, cols: Int) {
        let w = contentContainer.bounds.width
        let h = contentContainer.bounds.height
        guard w > 10, h > 10 else { return (24, 80) }
        return (max(2, Int(h / 18)), max(2, Int(w / 9)))
    }

    // MARK: - Tabs

    private func select(_ id: Int) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        selectedId = id
        for t in tabs {
            t.titleButton.state = (t.id == id) ? .on : .off
        }
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        let v = tab.termView
        v.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            v.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            v.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        headerTitle.text = tab.titleButton.title
        v.needsDisplay = true
        DispatchQueue.main.async { [weak self] in self?.focusActiveTerminal() }
    }

    private func close(_ id: Int) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[idx]
        tab.session.terminate()
        tab.container.removeFromSuperview()
        tabs.remove(at: idx)
        guard selectedId == id else { return }
        selectedId = nil
        if let next = tabs.indices.contains(idx) ? tabs[idx] : tabs.last {
            select(next.id)
        } else {
            contentContainer.subviews.forEach { $0.removeFromSuperview() }
            headerTitle.text = ""
            showEmptyState()
        }
    }

    @objc private func selectTab(_ sender: NSButton) {
        select(sender.tag)
    }

    @objc private func closeTab(_ sender: NSButton) {
        close(sender.tag)
    }

    /// Cmd+1…9: select the nth tab (clamped).
    private func selectTabIndex(_ index: Int) {
        guard !tabs.isEmpty else { return }
        let i = min(max(index - 1, 0), tabs.count - 1)
        select(tabs[i].id)
    }

    /// Cmd+Shift+[ / ]: cycle to the previous/next tab.
    private func cycleTab(delta: Int) {
        guard !tabs.isEmpty else { return }
        guard let idx = tabs.firstIndex(where: { $0.id == selectedId }) else {
            select(tabs[0].id)
            return
        }
        let next = (idx + delta + tabs.count) % tabs.count
        select(tabs[next].id)
    }

    @objc private func restartTapped(_ sender: NSButton) {
        close(sender.tag)   // drop the ended session
        newSession()        // …and start a fresh one
    }

    @objc private func newSessionTapped(_ sender: Any?) {
        newSession()
    }

    @objc private func hidePanel(_ sender: Any?) {
        onRequestHide?()
    }

    private func showEmptyState() {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        let icon = BakedIconView(symbol: "terminal")
        let label = NSTextField(wrappingLabelWithString: L10n.tr("terminal.empty"))
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        let button = NSButton(title: L10n.tr("terminal.new"), target: self, action: #selector(newSessionTapped(_:)))
        button.bezelStyle = .rounded
        let stack = NSStackView(views: [icon, label, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentContainer.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentContainer.trailingAnchor, constant: -20),
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),
        ])
    }
}
