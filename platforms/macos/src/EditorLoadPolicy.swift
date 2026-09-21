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
// Fixing THOSE is what makes large files fast again — NOT dropping their syntax
// highlighting (QA: turning colours off above a few thousand lines is not an
// acceptable trade). So highlighting stays on for every ordinary source file;
// the editor simply applies it in whole-line CHUNKS with a run-loop yield in
// between, and the reload does exactly one pass.
//
// The numbers live here (pure Foundation, no AppKit) so the behaviour is
// unit-tested headlessly — see tests/file-panel/run.sh.

enum EditorLoadPolicy {

    /// SAFETY VALVE, not a budget: only files no editor should tokenize (a
    /// multi-megabyte log, a minified bundle) skip highlighting, where one pass
    /// would be seconds of JavaScript and a pathological attribute count.
    static let maxHighlightedLines = 40_000
    static let maxHighlightedBytes = 4 * 1024 * 1024

    /// One highlight pass covers at most this much text; the editor feeds the
    /// highlighter whole-line chunks and yields to the run loop between them, so a
    /// large document is coloured progressively instead of blocking the UI in a
    /// single pass.
    static let highlightChunkLines = 300
    static let highlightChunkBytes = 32 * 1024

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

    /// Whether this buffer is small enough to be worth highlighting at all (see
    /// the safety valve above — ordinary files always return true).
    static func shouldHighlight(text: String, language: String?) -> Bool {
        guard language != nil else { return false }
        guard text.utf8.count <= maxHighlightedBytes else { return false }
        return lineCount(of: text) <= maxHighlightedLines
    }

    /// The next slice of text to highlight, starting at `location`: whole lines
    /// (the highlighter must see complete syntax, so a line is never split) and at
    /// most `maxLines` / `maxBytes` long. A single line over the byte budget is
    /// returned on its own, so the caller can always make progress.
    static func highlightChunk(in text: NSString, from location: Int,
                               maxLines: Int = highlightChunkLines,
                               maxBytes: Int = highlightChunkBytes) -> NSRange {
        let length = text.length
        guard location >= 0, location < length else { return NSRange(location: length, length: 0) }
        var lines = 0
        var index = location
        while index < length {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            if lines > 0,
               lines >= maxLines || (index + lineRange.length - location) > maxBytes {
                break
            }
            index += lineRange.length
            lines += 1
        }
        return NSRange(location: location, length: index - location)
    }

    /// Whether a change stamped `mtime` is old enough to act on (the writer has
    /// stopped for `window`).
    static func isStable(mtime: Date, now: Date,
                         window: TimeInterval = reloadStabilityWindow) -> Bool {
        now.timeIntervalSince(mtime) >= window
    }
}
