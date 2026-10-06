//
//  model-tests.swift — headless tests for WorkstreamsCore (no AppKit, no window).
//  Built by tests/workstreams-panel/run.sh (top-level code must live in main.swift).
//

import Foundation

var checks = 0
var failures = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { failures += 1; print("  FAIL " + label) }
}

func eq<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("  FAIL " + label + ": got " + String(describing: actual) + ", want " + String(describing: expected))
    }
}

func section(_ name: String) { print("--- " + name + " ---") }

/// Assert a throwing call fails with exactly this WorkstreamError.
func expectError<T>(_ label: String, _ expected: WorkstreamError, _ body: () throws -> T) {
    checks += 1
    do {
        _ = try body()
        failures += 1
        print("  FAIL " + label + ": no error thrown")
    } catch let error as WorkstreamError {
        if error != expected { failures += 1; print("  FAIL " + label + ": got " + String(describing: error)) }
    } catch {
        failures += 1
        print("  FAIL " + label + ": unexpected error " + String(describing: error))
    }
}

func tempWorkspace(_ tag: String) -> String {
    let path = NSTemporaryDirectory() + "ws-panel-" + tag + "-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

func writeFile(_ path: String, _ text: String) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    try? text.write(toFile: path, atomically: true, encoding: .utf8)
}

func files(in dir: String) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
}

let fullCard = """
---
id: WS-000002
title: 事项 & 模型
requirement: REQ-000001
stage: design
covered:
  - docs/a.md
  - docs/b.md
  base: 46e83f791115699ed012498586a81ebd055646e6
  head: 5506c2441af5ed3e4ae9726e5191e78a48483be2
regression: REG-001
queues:
  - id: q-111
    stage: planning
  - id: q-222
    stage: task
delivery:
  pr: 78
  url: https://github.com/example/repo/pull/78
  outcome: merged
created: 2026-10-06
updated: 2026-10-06
---

# WS-000002 事项

## 规划

- 目标：验证模型层。
"""

// MARK: - Scalar parsing

section("scalar parsing")
eq(WorkstreamsCore.parseScalar("\"quoted\""), "quoted", "double quotes stripped")
eq(WorkstreamsCore.parseScalar("'single'"), "single", "single quotes stripped")
eq(WorkstreamsCore.parseInlineList("[a, b, c]"), ["a", "b", "c"], "inline list")
eq(WorkstreamsCore.parseInlineList("not a list"), nil, "non-list returns nil")

// MARK: - Stages

section("stages")
eq(WorkstreamStage.allCases.map { $0.rawValue }, ["planning", "design", "task", "acceptance", "delivery"],
   "five stages in order")
eq(WorkstreamStage.parse("design"), .design, "parse design")
eq(WorkstreamStage.parse(" acceptance "), .acceptance, "parse trims whitespace")
eq(WorkstreamStage.parse("shipping"), nil, "unknown stage -> nil")
eq(WorkstreamStage(rawValue: "task"), .task, "task is a valid raw value")

// MARK: - Full card

section("full card")
let card = try WorkstreamsCore.parseCard(fullCard, path: "/tmp/WS-000002.md")
eq(card.id, "WS-000002", "id parsed")
eq(card.title, "事项 & 模型", "title keeps full text")
eq(card.requirement, "REQ-000001", "requirement parsed")
eq(card.stage, .design, "stage parsed")
eq(card.covered?.paths, ["docs/a.md", "docs/b.md"], "covered paths (mixed list block)")
eq(card.covered?.base, "46e83f791115699ed012498586a81ebd055646e6", "covered base")
eq(card.covered?.head, "5506c2441af5ed3e4ae9726e5191e78a48483be2", "covered head")
eq(card.regression, "REG-001", "regression parsed")
eq(card.queues, ["q-111", "q-222"],
   "legacy [{id, stage}] queues read as ids (stage dropped), no id lost")
eq(card.delivery?.pr, 78, "delivery pr")
eq(card.delivery?.url, "https://github.com/example/repo/pull/78", "delivery url")
eq(card.delivery?.outcome, "merged", "delivery outcome derived cache")
check(card.body.contains("## 规划"), "body kept after frontmatter")

// Optional fields absent -> clean defaults.
let minimal = try WorkstreamsCore.parseCard("""
---
id: WS-000003
title: 最小卡
stage: planning
created: 2026-10-06
updated: 2026-10-06
---
""", path: "/tmp/WS-000003.md")
eq(minimal.requirement, nil, "missing requirement is nil")
eq(minimal.covered, nil, "missing covered is nil")
eq(minimal.regression, nil, "missing regression is nil")
eq(minimal.queues, [], "missing queues is empty")
eq(minimal.delivery, nil, "missing delivery is nil")

// Canonical [q-...] list reads as-is (design A9 / D16).
let canonicalQueues = try WorkstreamsCore.parseCard("""
---
id: WS-000004
title: 新队列形式
stage: planning
queues: [q-aaa]
---
""", path: "/tmp/WS-000004.md")
eq(canonicalQueues.queues, ["q-aaa"], "canonical [q-...] queue reads")

// Legacy bare queue list also reads.
let legacy = try WorkstreamsCore.parseCard("""
---
id: WS-000005
title: 旧队列形式
stage: planning
queues: [q-aaa, q-bbb]
---
""", path: "/tmp/WS-000005.md")
eq(legacy.queues, ["q-aaa", "q-bbb"], "legacy inline queues read")

// Real cards annotate the derived outcome with an inline comment; the parser
// must strip it so the value compares equal to "merged".
let commented = try WorkstreamsCore.parseCard("""
---
id: WS-000020
title: 注释
stage: delivery
covered:
  - docs/a.md
  base: b
  head: h
delivery:
  pr: 78
  outcome: merged   # 派生自 PR 状态，不手写
---
""", path: "/tmp/WS-000020.md")
eq(commented.delivery?.outcome, "merged", "inline YAML comment stripped from outcome")

// MARK: - Negative cases

section("negative: illegal stage")
expectError("illegal stage rejected", .invalidStage("shipping")) {
    try WorkstreamsCore.parseCard("""
    ---
    id: WS-000005
    title: 非法阶段
    stage: shipping
    ---
    """, path: "/tmp/bad-stage.md")
}

section("negative: bad YAML")
expectError("no frontmatter block", .malformedFrontmatter("missing --- frontmatter block")) {
    try WorkstreamsCore.parseCard("# 没有 frontmatter\n", path: "/tmp/no-fm.md")
}
expectError("garbage line in frontmatter",
            .malformedFrontmatter("expected 'key: value': this line has no colon")) {
    try WorkstreamsCore.parseCard("""
    ---
    id: WS-000006
    title: 坏 YAML
    stage: planning
    this line has no colon
    ---
    """, path: "/tmp/bad-yaml.md")
}
expectError("unterminated frontmatter", .malformedFrontmatter("missing --- frontmatter block")) {
    try WorkstreamsCore.parseCard("""
    ---
    id: WS-000007
    title: 未闭合
    stage: planning
    """, path: "/tmp/unterminated.md")
}
expectError("duplicate key rejected", .malformedFrontmatter("duplicate key: id")) {
    try WorkstreamsCore.parseCard("""
    ---
    id: WS-000008
    id: WS-000009
    title: 重复键
    stage: planning
    ---
    """, path: "/tmp/dup.md")
}

section("negative: missing required")
expectError("missing id", .missingId) {
    try WorkstreamsCore.parseCard("---\ntitle: 无 id\nstage: planning\n---\n", path: "/tmp/no-id.md")
}
expectError("missing title", .missingTitle) {
    try WorkstreamsCore.parseCard("---\nid: WS-000010\nstage: planning\n---\n", path: "/tmp/no-title.md")
}
expectError("missing stage", .missingStage) {
    try WorkstreamsCore.parseCard("---\nid: WS-000011\ntitle: 无阶段\n---\n", path: "/tmp/no-stage.md")
}
expectError("empty id", .missingId) {
    try WorkstreamsCore.parseCard("---\nid: \"\"\ntitle: 空 id\nstage: planning\n---\n", path: "/tmp/empty-id.md")
}

// MARK: - Serialization

section("serialization")
let serialized = WorkstreamsCore.serialize(card)
check(serialized.hasPrefix("---\nid: WS-000002\ntitle: 事项 & 模型\nrequirement: REQ-000001\nstage: design\n"),
      "canonical key order (id/title/requirement/stage)")
check(serialized.contains("covered:\n  - docs/a.md\n  - docs/b.md\n  base: 46e83"),
      "covered block order (paths then base/head)")
check(serialized.contains("queues: [q-111, q-222]\n"),
      "queues serialized as an inline id list")
check(serialized.contains("delivery:\n  pr: 78\n  url: https://github.com/example/repo/pull/78\n  outcome: merged\n"),
      "delivery block serialized")
let roundTrip = try WorkstreamsCore.parseCard(serialized, path: card.path)
eq(roundTrip, card, "serialize -> parse round-trips exactly")

let noQueues = WorkstreamCard(id: "WS-000012", title: "t", requirement: nil, stage: .planning,
                              covered: nil, regression: nil, queues: [], delivery: nil,
                              created: "2026-10-06", updated: "2026-10-06", path: "/tmp/x.md", body: "\n")
check(!WorkstreamsCore.serialize(noQueues).contains("queues:"), "empty queues omitted")
check(!WorkstreamsCore.serialize(noQueues).contains("requirement:"), "nil requirement omitted")

// MARK: - Validate

section("validate")
let acceptanceNoCovered = WorkstreamCard(id: "WS-000013", title: "验收无证据", requirement: nil,
                                         stage: .acceptance, covered: nil, regression: nil, queues: [],
                                         delivery: nil, created: nil, updated: nil, path: "", body: "\n")
eq(WorkstreamsCore.validate(acceptanceNoCovered),
   ["covered is required at stage acceptance"], "acceptance without covered is flagged")
var acceptanceWithCovered = acceptanceNoCovered
acceptanceWithCovered.covered = CoveredRecord(paths: ["docs/a.md"], base: "b", head: "h")
eq(WorkstreamsCore.validate(acceptanceWithCovered), [], "acceptance with covered is clean")
eq(WorkstreamsCore.validate(minimal), [], "planning needs no covered")
var twoQueues = minimal
twoQueues.queues = ["q-1", "q-2"]
eq(WorkstreamsCore.validate(twoQueues), ["at most one queue is allowed"],
   "more than one queue is flagged (0..1)")

// MARK: - Writes (atomic / six-digit ids)

section("writes")
let ws = tempWorkspace("writes")
let created = try WorkstreamsCore.create(workspace: ws, title: "新建事项", requirement: "REQ-000001",
                                         stage: .planning, today: "2026-10-06")
eq(created.id, "WS-000001", "first id is six-digit zero-padded")
check(FileManager.default.fileExists(atPath: WorkstreamsCore.workstreamPath(ws, id: "WS-000001")),
      "card file written")
check(!files(in: WorkstreamsCore.workstreamsDir(ws)).contains { $0.hasPrefix(".") },
      "atomic write leaves no temp file behind")

let second = try WorkstreamsCore.create(workspace: ws, title: "第二", today: "2026-10-06")
eq(second.id, "WS-000002", "second id increments")

// Legacy short ids still drive the next six-digit number.
let mixed = tempWorkspace("mixed")
writeFile(mixed + "/.dsh/workstreams/WS-001.md", "---\nid: WS-001\ntitle: a\nstage: planning\n---\n")
writeFile(mixed + "/.dsh/workstreams/WS-000009.md", "---\nid: WS-000009\ntitle: b\nstage: planning\n---\n")
eq(WorkstreamsCore.nextId(in: WorkstreamsCore.workstreamsDir(mixed)), "WS-000010",
   "nextId honors three-digit + six-digit cards")

section("writes: update / stage / queues / covered / delivery")
let staged = try WorkstreamsCore.setStage(workspace: ws, id: created.id, stage: .design, today: "2026-10-07")
eq(staged.stage, .design, "stage advanced")
eq(staged.updated, "2026-10-07", "updated stamp refreshed")

let withQueues = try WorkstreamsCore.setQueues(
    workspace: ws, id: created.id,
    queues: ["q-1"],
    today: "2026-10-07")
eq(withQueues.queues, ["q-1"], "queue id persisted")
expectError("second queue rejected (0..1)", .invalidQueue("at most one queue is allowed")) {
    try WorkstreamsCore.setQueues(workspace: ws, id: created.id,
                                  queues: ["q-1", "q-2"], today: "2026-10-07")
}

let withCovered = try WorkstreamsCore.setCovered(
    workspace: ws, id: created.id,
    covered: CoveredRecord(paths: ["docs/a.md"], base: "base1", head: "head1"),
    today: "2026-10-07")
eq(withCovered.covered, CoveredRecord(paths: ["docs/a.md"], base: "base1", head: "head1"),
   "covered persisted")

let withDelivery = try WorkstreamsCore.setDelivery(
    workspace: ws, id: created.id,
    delivery: DeliveryInfo(pr: 12, url: "https://example.com/pr/12", outcome: "open"),
    today: "2026-10-07")
eq(withDelivery.delivery, DeliveryInfo(pr: 12, url: "https://example.com/pr/12", outcome: "open"),
   "delivery persisted")

let renamed = try WorkstreamsCore.update(workspace: ws, id: created.id, title: "改名",
                                         requirement: "REQ-000042", today: "2026-10-08")
eq(renamed.title, "改名", "title updated")
eq(renamed.requirement, "REQ-000042", "requirement updated")
let cleared = try WorkstreamsCore.update(workspace: ws, id: created.id, requirement: "",
                                        today: "2026-10-08")
eq(cleared.requirement, nil, "empty requirement clears the pointer")

// Reload sees exactly what was written.
let reloaded = try WorkstreamsCore.loadCard(workspace: ws, id: created.id)
eq(reloaded.title, "改名", "reload title")
eq(reloaded.queues, ["q-1"], "reload queues")

expectError("unknown card", .unknownWorkstream("WS-999999")) {
    try WorkstreamsCore.loadCard(workspace: ws, id: "WS-999999")
}
expectError("no workspace", .noWorkspace) {
    try WorkstreamsCore.create(workspace: ws + "/does-not-exist", title: "x", today: "2026-10-06")
}
expectError("empty queue id rejected", .invalidQueue("id is required")) {
    try WorkstreamsCore.setQueues(workspace: ws, id: created.id,
                                  queues: ["  "],
                                  today: "2026-10-06")
}

// MARK: - Load snapshot

section("load snapshot")
let snapWs = tempWorkspace("snapshot")
writeFile(snapWs + "/.dsh/workstreams/WS-000002.md", fullCard)
writeFile(snapWs + "/.dsh/workstreams/WS-000001.md", """
---
id: WS-000001
title: 一
stage: planning
---
""")
writeFile(snapWs + "/.dsh/workstreams/WS-000003.md", """
---
id: WS-000003
title: 坏
stage: nowhere
---
""")
writeFile(snapWs + "/.dsh/workstreams/README.md", "not a card")
let snapshot = WorkstreamsCore.load(workspace: snapWs)
eq(snapshot.workspace, snapWs, "snapshot workspace")
eq(snapshot.dshExists, true, "dsh exists")
eq(snapshot.workstreams.map { $0.id }, ["WS-000001", "WS-000002"], "valid cards, id-sorted, README skipped")
eq(snapshot.unparsed.count, 1, "bad card collected in unparsed")
check(snapshot.unparsed.first?.hasSuffix("WS-000003.md") ?? false, "unparsed points at the bad card")

let missing = WorkstreamsCore.load(workspace: snapWs + "/nope")
eq(missing.dshExists, false, "non-directory yields empty snapshot")

// MARK: - Section helpers

section("sections")
eq(WorkstreamsCore.sectionText("## 规划\n\n目标\n\n## 设计\n\nx\n", heading: "## 规划"), "目标",
   "sectionText extracts a level-2 section")
let replaced = WorkstreamsCore.replaceSection("## 规划\n\n旧\n\n## 设计\n\nx\n",
                                              heading: "## 规划", with: "## 规划\n\n新\n")
check(replaced.contains("新") && !replaced.contains("旧") && replaced.contains("## 设计"),
      "replaceSection swaps one section only")

// MARK: - 事项 ↔ 会话绑定 (design §6)

section("session binding")
let bindings = ["WS-000002": "s-2", "WS-000001": "s-1"]
eq(WorkstreamsCore.boundSession(in: bindings, workstream: "WS-000001"), "s-1", "bound session lookup")
eq(WorkstreamsCore.boundSession(in: bindings, workstream: "WS-000999") == nil, true, "unbound workstream -> nil")
eq(WorkstreamsCore.boundSession(in: ["WS-1": "  "], workstream: "WS-1") == nil, true, "blank binding -> nil")
eq(WorkstreamsCore.boundWorkstream(in: bindings, session: "s-2"), "WS-000002", "reverse lookup finds the workstream")
eq(WorkstreamsCore.boundWorkstream(in: bindings, session: " nope "), nil, "unknown session -> nil")
// One session may have captured two workstreams: id order keeps it deterministic.
let multiBound = ["WS-000002": "s-1", "WS-000001": "s-1"]
eq(WorkstreamsCore.boundWorkstream(in: multiBound, session: "s-1"), "WS-000001",
   "reverse lookup is deterministic (id order)")

// 「拆分任务」的目标选择: reuse > created > fallback current.
eq(WorkstreamsCore.sessionTarget(bound: "s-9", boundAlive: true, created: "s-new", current: "s-cur"),
   .reuse("s-9"), "live bound session is reused")
eq(WorkstreamsCore.sessionTarget(bound: "s-9", boundAlive: false, created: "s-new", current: "s-cur"),
   .created("s-new"), "dead bound session -> new session")
eq(WorkstreamsCore.sessionTarget(bound: nil, boundAlive: false, created: "s-new", current: "s-cur"),
   .created("s-new"), "no binding -> new session")
eq(WorkstreamsCore.sessionTarget(bound: "s-9", boundAlive: false, created: nil, current: "s-cur"),
   .fallback("s-cur"), "dead bound session + failed create -> fall back to current")
eq(WorkstreamsCore.sessionTarget(bound: nil, boundAlive: false, created: nil, current: "s-cur"),
   .fallback("s-cur"), "no binding + failed create -> fall back to current")
eq(WorkstreamsCore.sessionTarget(bound: nil, boundAlive: false, created: nil, current: nil) == nil, true,
   "no candidate at all -> nil")
eq(WorkstreamsCore.sessionTarget(bound: "  ", boundAlive: true, created: nil, current: "s-cur"),
   .fallback("s-cur"), "blank bound session ignored")
let reuseTarget = WorkstreamsCore.sessionTarget(bound: "s-1", boundAlive: true, created: nil, current: nil)
eq(reuseTarget?.isReuse, true, "target exposes isReuse")
eq(reuseTarget?.isCreated, false, "reuse is not created")
eq(reuseTarget?.session, "s-1", "target exposes the chosen session")

// MARK: - Report

print("")
if failures == 0 {
    print("workstreams-core model tests passed (\(checks) checks)")
} else {
    print("workstreams-core model tests FAILED: \(failures)/\(checks)")
    exit(1)
}
