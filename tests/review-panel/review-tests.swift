import Foundation

// Headless unit tests for the Review (change audit) panel data model:
// decoding the core CLI JSON and folding it for display. Pure Foundation, no
// AppKit and no Node — the audit itself is covered by node --test
// core/tests/review-log.test.js.

func test(_ name: String, _ cond: Bool) {
    print((cond ? "ok" : "FAIL") + " - " + name)
    if !cond { exit(1) }
}

// --- fixture: the exact shape core/bin/ohmy-core.js review audit emits ---

let auditJSON = """
{
  "session": {"id": "session-abc12345-0000-0000-0000-000000000000", "cwd": "/work/proj", "createdAt": 1000, "parentSession": null, "delegationDepth": 0},
  "entries": [
    {"seq": 10, "order": 0, "turn": 1, "step": 1, "tool": "edit", "surface": "top", "status": "ok", "category": "diff",
     "path": "src/a.js", "pathAbs": "/work/proj/src/a.js", "command": null, "suspicion": null,
     "hunks": [{"oldText": "let x = 1;", "newText": "let x = 1;\\nlet z = 2;"}], "added": 2, "removed": 1, "note": "applied-hunks"},
    {"seq": 20, "order": 1, "turn": 1, "step": 2, "tool": "write", "surface": "nested", "status": "ok", "category": "content",
     "path": "core/new.js", "pathAbs": "/work/proj/core/new.js", "command": null, "suspicion": null,
     "hunks": [{"oldText": null, "newText": "a\\nb"}], "added": 2, "removed": 0, "note": "created-content"},
    {"seq": 21, "order": 2, "turn": 1, "step": 2, "tool": "edit", "surface": "top", "status": "error", "category": "args",
     "path": "src/b.js", "pathAbs": "/work/proj/src/b.js", "command": null, "suspicion": null,
     "hunks": [], "added": 0, "removed": 0, "note": "args"},
    {"seq": 30, "order": 3, "turn": 1, "step": 3, "tool": "bash", "surface": "top", "status": "ok", "category": "bash",
     "path": null, "pathAbs": null, "command": "ls -la", "suspicion": "unknown",
     "hunks": [], "added": 0, "removed": 0, "note": null},
    {"seq": 31, "order": 4, "turn": 1, "step": 3, "tool": "bash", "surface": "top", "status": "ok", "category": "bash",
     "path": null, "pathAbs": null, "command": "sed -i '' -e s/a/b/ src/a.js", "suspicion": "write-like",
     "hunks": [], "added": 0, "removed": 0, "note": null}
  ],
  "stats": {"entries": 5, "mutations": 3, "files": 2, "added": 4, "removed": 1,
            "nested": 1, "bashCalls": 2, "bashSuspect": 1, "failed": 1},
  "diagnostics": [{"code": "zstd-torn-frame", "message": "[review] 日志末尾存在未完成帧"}]
}
"""

guard let audit = ReviewLogModel.decodeAudit(auditJSON) else {
    print("FAIL - audit fixture did not decode")
    exit(1)
}
let entries = audit.entries

test("audit decodes session", audit.session?.id == "session-abc12345-0000-0000-0000-000000000000")
test("audit decodes stats", audit.stats?.files == 2 && audit.stats?.bashSuspect == 1)
test("audit decodes diagnostics", audit.diagnostics?.first?.code == "zstd-torn-frame")
test("entry carries nested surface", entries[1].isNested)
test("entry category null is neither mutation nor bash", !entries[1].isBash)
test("error entry is flagged", entries[2].isError)

test("mutations exclude failures", ReviewLogModel.mutations(entries).count == 2)
test("failures are separated", ReviewLogModel.failures(entries).count == 1)
test("failures carry their path", ReviewLogModel.failures(entries).first?.path == "src/b.js")

let groups = ReviewLogModel.fileGroups(entries)
test("file groups group by path", groups.count == 2)
test("file groups list the most recently changed file first", groups.first?.path == "core/new.js")
test("file group totals add up", groups[1].added == 2 && groups[1].removed == 1)
test("file group flags created file", groups[0].created)
test("file group flags nested origin", groups[0].hasNested && !groups[1].hasNested)
test("file group flags applied hunks", groups[1].hasAppliedHunks && !groups[0].hasAppliedHunks)
test("failed entries are not grouped", !groups.contains { $0.path == "src/b.js" })

test("bash filter includes all by default", ReviewLogModel.bashEntries(entries, suspectOnly: false).count == 2)
let suspect = ReviewLogModel.bashEntries(entries, suspectOnly: true)
test("bash filter narrows to suspects", suspect.count == 1)
test("suspect bash keeps its command", suspect.first?.command == "sed -i '' -e s/a/b/ src/a.js")

let lines = ReviewLogModel.diffLines(groups[1].entries[0].hunks)
test("diff lines render removed then added", lines.map(\.kind) == [.removed, .added, .added])
test("diff lines keep text", lines[0].text == "let x = 1;" && lines[2].text == "let z = 2;")
test("pure insertion renders only added lines", ReviewLogModel.diffLines(groups[0].entries[0].hunks).allSatisfy { $0.kind == .added })
test("empty hunks render nothing", ReviewLogModel.diffLines([]).isEmpty)

test("short id strips the session prefix", ReviewLogModel.shortId("session-abc12345-0000") == "abc12345")
test("short id tolerates other shapes", ReviewLogModel.shortId("xyz") == "xyz")
test("byte label formats MB", ReviewLogModel.byteLabel(3 * 1024 * 1024) == "3.0 MB")
test("byte label formats KB", ReviewLogModel.byteLabel(2048) == "2 KB")
test("byte label formats bytes", ReviewLogModel.byteLabel(512) == "512 B")

// --- session list fixture ---

let sessionsJSON = """
{"sessions": [
  {"id": "session-74e368ee-1111", "dir": "/s/a", "file": "/s/a/session.jsonl.zstd", "cwd": "/work/proj",
   "createdAt": 1, "parentSession": null, "delegationDepth": 0, "compressed": true, "sizeBytes": 867668, "mtimeMs": 1789103703793},
  {"id": "138bf1a6-2222", "dir": "/s/b", "file": "/s/b/session.jsonl.zstd", "cwd": "/work/proj",
   "createdAt": 2, "parentSession": "session-74e368ee-1111", "delegationDepth": 1, "compressed": true, "sizeBytes": 1024, "mtimeMs": 1789103600000}
], "total": 2, "diagnostics": []}
"""

guard let listed = ReviewLogModel.decodeSessions(sessionsJSON) else {
    print("FAIL - sessions fixture did not decode")
    exit(1)
}
test("sessions decode", listed.sessions.count == 2 && listed.total == 2)
test("subagent session detected", listed.sessions[1].isSubagent && !listed.sessions[0].isSubagent)
test("session label marks subagents", ReviewLogModel.sessionLabel(listed.sessions[1]).hasSuffix("· sub"))
test("session label uses the short id", ReviewLogModel.sessionLabel(listed.sessions[0]).hasPrefix("74e368ee · "))

test("garbage json decodes to nil", ReviewLogModel.decodeAudit("not json") == nil)
test("empty json decodes to nil", ReviewLogModel.decodeAudit("") == nil)

print("done")
