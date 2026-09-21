import Foundation

// MARK: - When the Files panel may spend main-thread time on a text file
//
// Reloading an open file used to freeze the app on large files (3000+ lines,
// QA report). Two costs stacked up on the main thread:
//
//   1. Highlightr re-highlights the WHOLE document in JavaScript and then applies
//      every attribute run through the text storage — and a reload did it TWICE
//      (the string replacement highlights the replaced paragraph range, and
//      re-assigning `language` highlights everything again);
//   2. the watcher reloaded on every tick while a file was still being written
//      (an agent saving repeatedly), so that cost ran over and over.
//
// The thresholds live here (pure Foundation, no AppKit) so the behaviour is
// unit-tested headlessly — see tests/file-panel/run.sh.

enum EditorLoadPolicy {

    /// Above these a text file is shown WITHOUT syntax highlighting: the file
    /// stays readable and editable, it just does not pay the JS + attribute cost
    /// on every open/reload.
    static let maxHighlightedLines = 2000
    static let maxHighlightedBytes = 256 * 1024

    /// A changed file must have been quiet for this long before the panel reloads
    /// it, so a burst of writes costs exactly ONE reload instead of one per
    /// watcher tick.
    static let reloadStabilityWindow: TimeInterval = 0.6

    /// Number of lines in a buffer (a trailing newline does not add an empty
    /// line beyond what the editor shows).
    static func lineCount(of text: String) -> Int {
        guard !text.isEmpty else { return 1 }
        var lines = 1
        for character in text where character == "\n" { lines += 1 }
        if text.hasSuffix("\n") { lines -= 1 }
        return max(1, lines)
    }

    /// Whether syntax highlighting is worth its cost for this buffer.
    static func shouldHighlight(text: String, language: String?) -> Bool {
        guard language != nil else { return false }
        guard text.utf8.count <= maxHighlightedBytes else { return false }
        return lineCount(of: text) <= maxHighlightedLines
    }

    /// Whether a change stamped `mtime` is old enough to act on (the writer has
    /// stopped for `window`).
    static func isStable(mtime: Date, now: Date,
                         window: TimeInterval = reloadStabilityWindow) -> Bool {
        now.timeIntervalSince(mtime) >= window
    }
}
