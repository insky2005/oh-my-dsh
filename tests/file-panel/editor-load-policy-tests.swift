import Foundation

// Headless tests for EditorLoadPolicy: when a text file is large enough that
// syntax highlighting / reloading must back off, and when a written file counts
// as "quiet" (docs/ux-feedback.md — the 3000+ line reload freeze).
// Usage: tests/file-panel/run.sh

func test(_ name: String, _ cond: Bool) {
    print((cond ? "ok" : "FAIL") + " - " + name)
    if !cond { exit(1) }
}

// --- line counting ---------------------------------------------------------

test("an empty buffer is one line", EditorLoadPolicy.lineCount(of: "") == 1)
test("a single line has no newline", EditorLoadPolicy.lineCount(of: "abc") == 1)
test("a trailing newline does not add a line", EditorLoadPolicy.lineCount(of: "a\nb\n") == 2)
test("every newline separates two lines", EditorLoadPolicy.lineCount(of: "a\nb\nc") == 3)

// --- highlighting budget ---------------------------------------------------

test("a small file is highlighted",
     EditorLoadPolicy.shouldHighlight(text: "let x = 1\n", language: "swift"))
test("no language means no highlighting", !EditorLoadPolicy.shouldHighlight(text: "x", language: nil))

let manyLines = String(repeating: "let x = 1\n", count: EditorLoadPolicy.maxHighlightedLines + 1)
test("a file above the line limit is not highlighted",
     !EditorLoadPolicy.shouldHighlight(text: manyLines, language: "swift"))
let atLimit = String(repeating: "let x = 1\n", count: EditorLoadPolicy.maxHighlightedLines)
test("a file exactly at the line limit is still highlighted",
     EditorLoadPolicy.shouldHighlight(text: atLimit, language: "swift"))

let longLines = String(repeating: "x", count: EditorLoadPolicy.maxHighlightedBytes + 1)
test("a file above the byte limit is not highlighted",
     !EditorLoadPolicy.shouldHighlight(text: longLines, language: "swift"))
test("a large multi-byte file counts bytes, not characters",
     !EditorLoadPolicy.shouldHighlight(text: String(repeating: "中", count: EditorLoadPolicy.maxHighlightedBytes / 2),
                                       language: "swift"))

// --- write-burst coalescing ------------------------------------------------

let now = Date()
test("a file still being written is not stable yet",
     !EditorLoadPolicy.isStable(mtime: now.addingTimeInterval(-0.1), now: now))
test("a quiet file is stable",
     EditorLoadPolicy.isStable(mtime: now.addingTimeInterval(-5), now: now))
test("the window is the boundary",
     EditorLoadPolicy.isStable(mtime: now.addingTimeInterval(-EditorLoadPolicy.reloadStabilityWindow), now: now))
test("a future mtime (clock skew) counts as just written",
     !EditorLoadPolicy.isStable(mtime: now.addingTimeInterval(10), now: now))

print("done")
