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

// The valve is a SAFETY VALVE: an ordinary 3000-line source file keeps its
// colours (QA: "skipping highlighting above 2000 lines is not acceptable").
let sourceFile = String(repeating: "let x = 1\n", count: 3000)
test("a 3000-line source file is still highlighted",
     EditorLoadPolicy.shouldHighlight(text: sourceFile, language: "swift"))
test("a 20000-line source file is still highlighted",
     EditorLoadPolicy.shouldHighlight(text: String(repeating: "let x = 1\n", count: 20_000),
                                      language: "swift"))
let manyLines = String(repeating: "let x = 1\n", count: EditorLoadPolicy.maxHighlightedLines + 1)
test("only a file past the safety valve is left plain",
     !EditorLoadPolicy.shouldHighlight(text: manyLines, language: "swift"))

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

// --- chunked highlighting --------------------------------------------------
// The editor colours the buffer in whole-line chunks; a chunk must never split a
// line (the highlighter needs complete syntax on every call).

let tenLines = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n" as NSString
let firstChunk = EditorLoadPolicy.highlightChunk(in: tenLines, from: 0, maxLines: 3, maxBytes: 1_000_000)
test("a chunk covers whole lines", tenLines.substring(with: firstChunk) == "a\nb\nc\n")
let secondChunk = EditorLoadPolicy.highlightChunk(in: tenLines, from: firstChunk.location + firstChunk.length,
                                                  maxLines: 3, maxBytes: 1_000_000)
test("the next chunk continues where the last one ended",
     tenLines.substring(with: secondChunk) == "d\ne\nf\n")
var offset = 0
var chunks: [String] = []
while offset < tenLines.length {
    let chunk = EditorLoadPolicy.highlightChunk(in: tenLines, from: offset, maxLines: 4, maxBytes: 1_000_000)
    guard chunk.length > 0 else { break }
    chunks.append(tenLines.substring(with: chunk))
    offset = chunk.location + chunk.length
}
test("walking the chunks covers the text exactly once", chunks.joined() == (tenLines as String))
test("the walk terminates", offset == tenLines.length)

let overLongLine = (String(repeating: "x", count: 500) + "\ny\n") as NSString
let overLongChunk = EditorLoadPolicy.highlightChunk(in: overLongLine, from: 0, maxLines: 100, maxBytes: 16)
test("a single line over the byte budget is returned on its own",
     overLongChunk.length == 501)   // 500 chars + newline: never split, always progress

let unicodeText = "中文行\n中文行\n" as NSString
let unicodeChunk = EditorLoadPolicy.highlightChunk(in: unicodeText, from: 0, maxLines: 1, maxBytes: 1_000_000)
test("a chunk respects line boundaries with multi-byte text",
     unicodeText.substring(with: unicodeChunk) == "中文行\n")
test("an offset past the end yields an empty chunk",
     EditorLoadPolicy.highlightChunk(in: tenLines, from: tenLines.length).length == 0)
test("an empty buffer yields an empty chunk",
     EditorLoadPolicy.highlightChunk(in: "" as NSString, from: 0).length == 0)

print("done")
