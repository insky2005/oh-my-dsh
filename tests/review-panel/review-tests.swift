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
    {"seq": 20, "order": 1, "turn": 2, "step": 2, "tool": "write", "surface": "nested", "status": "ok", "category": "content",
     "path": "core/new.js", "pathAbs": "/work/proj/core/new.js", "command": null, "suspicion": null,
     "hunks": [{"oldText": null, "newText": "a\\nb"}], "added": 2, "removed": 0, "note": "created-content"},
    {"seq": 21, "order": 2, "turn": 2, "step": 2, "tool": "edit", "surface": "top", "status": "error", "category": "args",
     "path": "src/b.js", "pathAbs": "/work/proj/src/b.js", "command": null, "suspicion": null,
     "hunks": [], "added": 0, "removed": 0, "note": "args"},
    {"seq": 30, "order": 3, "turn": 1, "step": 3, "tool": "bash", "surface": "top", "status": "ok", "category": "bash",
     "path": null, "pathAbs": null, "command": "ls -la", "suspicion": "unknown",
     "hunks": [], "added": 0, "removed": 0, "note": null},
    {"seq": 31, "order": 4, "turn": 1, "step": 3, "tool": "bash", "surface": "top", "status": "ok", "category": "bash",
     "path": null, "pathAbs": null, "command": "sed -i '' -e s/a/b/ src/a.js", "suspicion": "write-like",
     "hunks": [], "added": 0, "removed": 0, "note": null}
  ],
  "turns": [{"turn": 1, "prompt": "first ask", "startedAt": 900},
              {"turn": 2, "prompt": "second ask", "startedAt": 1900}],
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
test("file groups keep the order files were first touched", groups.first?.path == "src/a.js")
test("file group totals add up", groups[0].added == 2 && groups[0].removed == 1)
test("file group flags created file", groups[1].created)
test("file group flags nested origin", groups[1].hasNested && !groups[0].hasNested)
test("file group flags applied hunks", groups[0].hasAppliedHunks && !groups[1].hasAppliedHunks)
test("failed entries are not grouped", !groups.contains { $0.path == "src/b.js" })

test("bash filter includes all by default", ReviewLogModel.bashEntries(entries, suspectOnly: false).count == 2)
let suspect = ReviewLogModel.bashEntries(entries, suspectOnly: true)
test("bash filter narrows to suspects", suspect.count == 1)
test("suspect bash keeps its command", suspect.first?.command == "sed -i '' -e s/a/b/ src/a.js")

let lines = ReviewLogModel.diffLines(groups[0].entries[0].hunks)
test("diff lines render removed then added", lines.map(\.kind) == [.removed, .added, .added])
test("diff lines keep text", lines[0].text == "let x = 1;" && lines[2].text == "let z = 2;")
test("pure insertion renders only added lines", ReviewLogModel.diffLines(groups[1].entries[0].hunks).allSatisfy { $0.kind == .added })
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

// --- turn hierarchy (会话 → 对话 → 文件 → 变更内容) ---

test("audit decodes turns", audit.turns?.count == 2 && audit.turns?.first?.prompt == "first ask")

let turnGroups = ReviewLogModel.turnGroups(audit, suspectShellsOnly: false)
test("turn groups split by 对话", turnGroups.count == 2)
test("turn groups list the newest turn first", turnGroups.first?.turn == 2)
test("turn group carries its prompt", turnGroups.first?.prompt == "second ask")
test("turn group keeps only its own files", turnGroups.first?.files.map(\.path) == ["core/new.js"])
test("turn group totals add up", turnGroups.first?.added == 2 && turnGroups.first?.removed == 0)
test("turn group separates failures", turnGroups.first?.failures.count == 1)
test("turn group carries shell calls", turnGroups[1].shells.count == 2)
test("turn group narrows shell calls when asked", ReviewLogModel.turnGroups(audit, suspectShellsOnly: true)[1].shells.count == 1)
test("oldest turn is last", turnGroups.last?.turn == 1)
test("turn group files stay chronological", turnGroups[1].files.count == 1 && turnGroups[1].files[0].path == "src/a.js")

// --- workspace scoping (cross-workspace switch must not leak sessions) ---

func summary(_ id: String, cwd: String, mtime: Double) -> ReviewSessionSummary {
    ReviewSessionSummary(id: id, dir: "/s/\(id)", file: "/s/\(id)/session.jsonl.zstd", cwd: cwd,
                         createdAt: 0, parentSession: nil, delegationDepth: 0,
                         compressed: true, sizeBytes: 10, mtimeMs: mtime)
}
let workspaceSessions = [summary("session-a1", cwd: "/ws/A", mtime: 900),
              summary("session-a2", cwd: "/ws/A", mtime: 800),
              summary("session-b1", cwd: "/ws/B", mtime: 700),
              summary("session-b2", cwd: "/ws/B", mtime: 600),
              summary("session-b3", cwd: "/ws/B", mtime: 500)]
let scopedB = ReviewLogModel.sessionsForWorkspace(workspaceSessions, workspace: "/ws/B", limit: 60)
test("only the workspace's sessions are kept", scopedB.sessions.map { $0.id } == ["session-b1", "session-b2", "session-b3"])
test("the other workspace's session is never pinned on top", !scopedB.sessions.contains { $0.id == "session-a1" })
test("order is preserved (newest first)", scopedB.sessions.first?.id == "session-b1")
test("no truncation when under the cap", scopedB.beyondLimit == false)
let cappedA = ReviewLogModel.sessionsForWorkspace(workspaceSessions, workspace: "/ws/A", limit: 1)
test("the cap applies to the scoped list only", cappedA.sessions.map { $0.id } == ["session-a1"] && cappedA.beyondLimit)
test("an unknown workspace yields no sessions", ReviewLogModel.sessionsForWorkspace(workspaceSessions, workspace: "/ws/C", limit: 60).sessions.isEmpty)
test("a session without a resolved cwd is excluded", ReviewLogModel.sessionsForWorkspace(
    [summary("session-x", cwd: "", mtime: 1)], workspace: "", limit: 60).sessions.count == 1)

// --- session titles (how a session is recognised in dsh web) ---

let listPayload: [String: Any] = ["items": [
    ["sessionId": "session-a", "projections": ["values": ["title": "修复登录超时"]]],
    ["sessionId": "session-b", "projections": ["values": ["title": "   "]]],
    ["sessionId": "session-c", "projections": ["values": [:]]],
    ["sessionId": "session-d"],
    ["projections": ["values": ["title": "无 id"]]],
    ["sessionId": "session-e", "projections": ["values": ["title": "带空格 "]]],
]]
let titles = ReviewLogModel.sessionTitles(fromSessionList: listPayload)
test("session titles map id → dsh web title", titles["session-a"] == "修复登录超时")
test("blank titles are dropped (caller falls back to the short id)", titles["session-b"] == nil && titles["session-c"] == nil)
test("items without a title are skipped", titles["session-d"] == nil)
test("items without a sessionId are skipped", titles.count == 2)
test("titles are trimmed", titles["session-e"] == "带空格")
test("a malformed payload yields an empty map", ReviewLogModel.sessionTitles(fromSessionList: [:]).isEmpty)

// --- session display name (untitled sessions read like dsh web) ---

test("a titled session shows its title",
     ReviewLogModel.sessionDisplayName(id: "session-a", titles: ["session-a": "修复登录超时"],
                                       untitledPlaceholder: "新会话") == "修复登录超时")
test("a titleless session shows the dsh web placeholder",
     ReviewLogModel.sessionDisplayName(id: "session-b", titles: ["session-a": "x"],
                                       untitledPlaceholder: "新会话") == "新会话")
test("placeholder follows the language",
     ReviewLogModel.sessionDisplayName(id: "session-b", titles: ["session-a": "x"],
                                       untitledPlaceholder: "New Session") == "New Session")
test("an empty title map falls back to the short id (fetch failed)",
     ReviewLogModel.sessionDisplayName(id: "session-74e368ee-1111", titles: [:],
                                       untitledPlaceholder: "新会话") == "74e368ee")
test("an empty title string is treated as untitled",
     ReviewLogModel.sessionDisplayName(id: "session-c", titles: ["session-c": ""],
                                       untitledPlaceholder: "新会话") == "新会话")

test("garbage json decodes to nil", ReviewLogModel.decodeAudit("not json") == nil)
test("empty json decodes to nil", ReviewLogModel.decodeAudit("") == nil)

print("done")
