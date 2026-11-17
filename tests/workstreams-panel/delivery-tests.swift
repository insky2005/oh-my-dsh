//
//  delivery-tests.swift — headless tests for WorkstreamsDelivery (git pipeline /
//  GitHub PR / token file reading, design A10), adapted to workstream / stage
//  semantics. Built by tests/workstreams-panel/run.sh with WorkstreamsCore.swift.
//
//  Covered:
//    - the delivery path: accepted(ws) -> git repo -> branch -> remote -> GitHub ->
//      token -> plan (owner/repo/base/commits/covered/existing PR) + home-session
//      prompt (no delivery task / session; the API write is the completion signal);
//    - every failure path has a clear reason: notAccepted / notGitRepo / noBranch /
//      noRemote / noGitHubRemote / noToken;
//    - the home-session run verdict: facts (delivered) / report failure / timeout;
//    - the pure parsers copied from the tasks panel (remotes / github / base /
//      PR URL) and the token file layout (per-repo -> generic -> legacy);
//    - a real temp git repo driven through WSGitProbe.live.
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

func tempDir(_ tag: String) -> String {
    let path = NSTemporaryDirectory() + "ws-delivery-" + tag + "-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

func deliveryCard(stage: WorkstreamStage = .acceptance,
                  delivery: DeliveryInfo? = nil,
                  covered: CoveredRecord? = nil,
                  accepted: Bool = true) -> WorkstreamCard {
    // accepted(ws) is read from the "## 阶段确认" audit trail, not from `stage`.
    let body = accepted
        ? "## 阶段确认\n\n- 2026-10-07 · confirm · acceptance · source:panel"
        : ""
    return WorkstreamCard(id: "WS-000009", title: "事项面板交付", requirement: "REQ-000008",
                          stage: stage, covered: covered, regression: nil, queues: [],
                          delivery: delivery, created: "2026-10-06", updated: "2026-10-06",
                          path: "/tmp/WS-000009.md", body: body)
}

// MARK: - injected probes

/// A scripted git: the same answer shape as a real repo, no Process.
func fakeProbe(isGit: Bool = true,
               remoteNames: [String] = ["origin"],
               remoteURL: String = "https://github.com/example/example.git",
               current: String = "feature/workstream-panel",
               hasMain: Bool = true,
               commitsOut: String = "abc1234 feat: 交付") -> WSGitProbe {
    WSGitProbe(run: { _, args in
        switch args {
        case ["rev-parse", "--is-inside-work-tree"]: return isGit ? "true" : nil
        case ["remote"]: return remoteNames.joined(separator: "\n")
        case ["remote", "-v"]:
            return remoteNames.map { $0 + "\t" + remoteURL + " (fetch)" }.joined(separator: "\n")
        case ["rev-parse", "--abbrev-ref", "HEAD"]: return current
        case ["rev-parse", "--verify", "--quiet", "main"]: return hasMain ? "aaa" : nil
        case ["rev-parse", "--verify", "--quiet", "master"]: return nil
        case ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]: return nil
        case ["symbolic-ref", "--short", "refs/remotes/github/HEAD"]: return nil
        default:
            if args.count == 4, args[0] == "log" { return commitsOut }
            return nil
        }
    })
}

/// A scripted token store: a path -> string dictionary, capturing writes / removes.
final class FakeTokens {
    var files: [String: String] = [:]
    private(set) var wrote: [(path: String, contents: String)] = []
    private(set) var removed: [String] = []
    func store(home: String = "/home/test") -> WSTokenStore {
        let self_ = self
        return WSTokenStore(home: home,
                            read: { self_.files[$0] },
                            write: { self_.wrote.append((path: $0, contents: $1)) },
                            remove: { self_.removed.append($0) })
    }
}

// MARK: - parsers copied from the tasks panel

section("git remote parsing")
let remoteOutput = """
origin\thttps://github.com/example/example.git (fetch)
origin\thttps://github.com/example/example.git (push)
github\tgit@github.com:example/example.git (fetch)
github\tgit@github.com:example/example.git (push)
"""
let parsed = WSGitProbe.parseGitRemotes(remoteOutput)
eq(parsed.count, 2, "same-name duplicate lines collapse to one remote each")
eq(parsed.first?.name, "origin", "first remote keeps git order")
eq(parsed.first?.url, "https://github.com/example/example.git", "url keeps the first line")
eq(parsed.last?.name, "github", "second remote name")

eq(WSGitProbe.githubRepo(fromRemotes: parsed)?.slug, "example/example", "github remote parses owner/repo")
eq(WSGitProbe.githubRepo(fromRemotes: [(name: "origin", url: "git@github.com:acme/widget.git")])?.slug,
   "acme/widget", "scp-style github url parses")
eq(WSGitProbe.githubRepo(fromRemotes: [(name: "origin", url: "git@gitlab.com:acme/widget.git")]), nil,
   "non-github remote is not a GitHub repo")
eq(WSGitProbe.githubRepo(fromRemotes: [])?.slug, nil, "no remote -> no github repo")
eq(WSGitProbe.githubRepo(fromRemotes: [
    (name: "origin", url: "https://github.com/wrong/one.git"),
    (name: "github", url: "https://github.com/right/one.git"),
])?.slug, "right/one", "the remote literally named github wins")

eq(WSGitProbe.pushRemoteName(["origin", "github"]), "github", "push prefers github")
eq(WSGitProbe.pushRemoteName(["upstream", "origin"]), "origin", "push falls back to origin")
eq(WSGitProbe.pushRemoteName(["upstream", "fork"]), "upstream", "push falls back to the first")
eq(WSGitProbe.pushRemoteName([]), nil, "no remote -> nil")

section("default base branch chain")
eq(WSGitProbe.defaultBaseBranch(symbolicRef: "origin/develop", current: "feature/x", hasMain: true, hasMaster: false),
   "develop", "remote HEAD wins")
eq(WSGitProbe.defaultBaseBranch(symbolicRef: "origin/HEAD", current: "feature/x", hasMain: true, hasMaster: false),
   "main", "unresolved origin/HEAD is skipped")
eq(WSGitProbe.defaultBaseBranch(symbolicRef: nil, current: "feature/x", hasMain: false, hasMaster: true),
   "master", "master when there is no main")
eq(WSGitProbe.defaultBaseBranch(symbolicRef: nil, current: "develop", hasMain: false, hasMaster: false),
   "develop", "current branch when nothing else is known")
eq(WSGitProbe.defaultBaseBranch(symbolicRef: nil, current: "HEAD", hasMain: false, hasMaster: false),
   "main", "detached HEAD falls back to main")

// MARK: - token file layout

section("token file layout")
let tok = FakeTokens()
let store = tok.store(home: "/h")
eq(store.candidatePaths(owner: "o", repo: "r"),
   ["/h/oh-my-dsh/tokens/o-r", "/h/tokens/o-r", "/h/oh-my-dsh/gh-token", "/h/gh-token"],
   "search order: per-repo new -> per-repo legacy -> generic new -> generic legacy")
eq(store.candidatePaths(owner: nil, repo: nil), ["/h/oh-my-dsh/gh-token", "/h/gh-token"],
   "no repo -> generic files only")

tok.files["/h/oh-my-dsh/tokens/o-r"] = "  scoped-token\n"
eq(store.load(owner: "o", repo: "r"), "scoped-token", "per-repo token wins and is trimmed")
eq(store.source(owner: "o", repo: "r"), "/h/oh-my-dsh/tokens/o-r", "source reports the file, not the token")

tok.files["/h/oh-my-dsh/tokens/o-r"] = "   "
tok.files["/h/tokens/o-r"] = "legacy-scoped"
eq(store.load(owner: "o", repo: "r"), "legacy-scoped", "blank file is skipped, legacy per-repo is next")

tok.files["/h/tokens/o-r"] = ""
tok.files["/h/oh-my-dsh/gh-token"] = "generic"
eq(store.load(owner: "o", repo: "r"), "generic", "generic token is the fallback")
tok.files["/h/oh-my-dsh/gh-token"] = ""
tok.files["/h/gh-token"] = "legacy-generic"
eq(store.load(owner: "o", repo: "r"), "legacy-generic", "legacy generic is the last fallback")
tok.files.removeAll()
eq(store.load(owner: "o", repo: "r"), nil, "no file -> nil (the no-token reason)")

// save() writes / deletes through the injected writer.
store.save("new-token", owner: "o", repo: "r")
eq(tok.wrote.last?.path, "/h/oh-my-dsh/tokens/o-r", "save writes the per-repo path")
eq(tok.wrote.last?.contents, "new-token", "save trims the token")
store.save("  ", owner: "o", repo: "r")
eq(tok.removed.last, "/h/oh-my-dsh/tokens/o-r", "saving an empty token removes the file")

// Real file round-trip + 0600.
section("token file round-trip (real filesystem)")
let home = tempDir("home")
let real = WSTokenStore(home: home)
check(real.load(owner: "example", repo: "example") == nil, "missing token file reads nil")
real.save("roundtrip-token", owner: "example", repo: "example")
eq(real.load(owner: "example", repo: "example"), "roundtrip-token", "saved token loads back")
let perms = (try? FileManager.default.attributesOfItem(atPath:
    WSTokenStore.perRepoPath(home: home, owner: "example", repo: "example")))?[.posixPermissions] as? NSNumber
eq(perms?.intValue, 0o600, "token file is chmod 600")
real.save("", owner: "example", repo: "example")
check(real.load(owner: "example", repo: "example") == nil, "clearing the token deletes the file")

// MARK: - PR text / outcome

section("PR text and outcome")
eq(WSPRText.url(in: "done\nhttps://github.com/example/example/pull/78\n"), "https://github.com/example/example/pull/78",
   "PR url is found anywhere in the report")
eq(WSPRText.url(in: "no link here"), nil, "no PR link -> nil")
eq(WSPRText.number(in: "https://github.com/example/example/pull/78"), 78, "PR number parses")
eq(WSPRText.number(in: nil), nil, "no url -> no number")

eq(WSDeliveryOutcome.derive(merged: true, state: "closed"), .merged, "merged PR -> merged")
eq(WSDeliveryOutcome.derive(merged: false, state: "open"), .open, "open PR -> open")
eq(WSDeliveryOutcome.derive(merged: false, state: "closed"), .closed, "closed unmerged -> closed")
eq(WSDeliveryOutcome.derive(merged: false, state: nil), .unknown, "unknown state -> unknown")
eq(WSDeliveryOutcome.derive(merged: false, state: "closed", abandoned: true), .abandoned, "explicit abandon wins")
check(WSDeliveryOutcome.merged.isTerminal, "merged is terminal")
check(WSDeliveryOutcome.closed.isTerminal, "closed is terminal")
check(WSDeliveryOutcome.abandoned.isTerminal, "abandoned is terminal")
check(!WSDeliveryOutcome.open.isTerminal, "open is not terminal")
check(!WSDeliveryOutcome.unknown.isTerminal, "unknown is not terminal")

section("outcome derivation and the delivery write-back")
eq(WSDeliveryOutcome.parse("merged"), .merged, "parse merged")
eq(WSDeliveryOutcome.parse(" MERGED "), .merged, "parse is trimmed + case-insensitive")
eq(WSDeliveryOutcome.parse("open"), .open, "parse open")
eq(WSDeliveryOutcome.parse("nonsense"), nil, "unknown outcome string -> nil")
eq(WSDeliveryOutcome.parse(nil), nil, "nil outcome string -> nil")

// record() is the ONLY place the derived cache is produced: facts in, cache out.
let cached = WorkstreamsDelivery.record(pr: 42, url: " https://github.com/o/r/pull/42 ",
                                        state: "open")
eq(cached?.pr, 42, "record keeps the pr fact")
eq(cached?.url, "https://github.com/o/r/pull/42", "record trims the url fact")
eq(cached?.outcome, "open", "record derives the outcome cache from the observation")
eq(WorkstreamsDelivery.record(pr: 42, url: nil, merged: true)?.outcome, "merged", "record derives merged")
eq(WorkstreamsDelivery.record(pr: 42, url: nil, abandoned: true)?.outcome, "abandoned", "record derives abandoned")
eq(WorkstreamsDelivery.record(pr: 42, url: nil)?.outcome, "unknown", "no observation -> unknown cache")
eq(WorkstreamsDelivery.record(pr: nil, url: "   "), nil, "no facts -> nil (clears the block)")

// writeBack lands the facts + derived cache on a real card.
let writeWS = tempDir("write-ws")
let created = try? WorkstreamsCore.create(workspace: writeWS, title: "交付写回",
                                          stage: .acceptance, today: "2026-10-07")
if let created = created {
    let written = try? WorkstreamsDelivery.writeBack(workspace: writeWS, id: created.id,
                                                     pr: 78,
                                                     url: "https://github.com/o/r/pull/78",
                                                     state: "closed", merged: false,
                                                     today: "2026-10-08")
    eq(written?.delivery?.pr, 78, "writeBack lands the pr fact")
    eq(written?.delivery?.outcome, "closed", "writeBack derives the outcome cache (no hand-writing)")
    let reloaded = try? WorkstreamsCore.loadCard(workspace: writeWS, id: created.id)
    eq(reloaded?.delivery?.outcome, "closed", "writeBack round-trips through disk")
    let cleared = try? WorkstreamsDelivery.writeBack(workspace: writeWS, id: created.id,
                                                     pr: nil, url: nil, today: "2026-10-09")
    eq(cleared?.delivery == nil, true, "writeBack with no facts clears the delivery block")
}
try? FileManager.default.removeItem(atPath: writeWS)

// MARK: - failure paths (clear reasons)

section("failure paths")
var fake = FakeTokens()
fake.files["/h/oh-my-dsh/tokens/example-example"] = "ghp_secret_value_123"

// notAccepted: 交付是操作（design A17），前置是 accepted(ws)——验收已确认。
eq(WorkstreamsDelivery.resolve(card: deliveryCard(stage: .task, accepted: false), branch: "b",
                               repoRoot: "/repo", git: fakeProbe(), tokens: fake.store(home: "/h"))
      .blocker, .notAccepted(.task), "a stage before acceptance is refused")
eq(WorkstreamsDelivery.resolve(card: deliveryCard(accepted: false), branch: "b",
                               repoRoot: "/repo", git: fakeProbe(), tokens: fake.store(home: "/h"))
      .blocker, .notAccepted(.acceptance),
   "acceptance without a human sign-off is refused (accepted(ws), not stage)")
// notGitRepo
eq(WorkstreamsDelivery.resolve(card: deliveryCard(), branch: "b",
                               repoRoot: "/repo", git: fakeProbe(isGit: false), tokens: fake.store(home: "/h"))
      .blocker, .notGitRepo, "a non-git directory is refused")
// noBranch
eq(WorkstreamsDelivery.resolve(card: deliveryCard(), branch: nil,
                               repoRoot: "/repo", git: fakeProbe(), tokens: fake.store(home: "/h"))
      .blocker, .noBranch, "no branch is refused")
eq(WorkstreamsDelivery.resolve(card: deliveryCard(), branch: "   ",
                               repoRoot: "/repo", git: fakeProbe(), tokens: fake.store(home: "/h"))
      .blocker, .noBranch, "a blank branch is refused")
// noRemote
eq(WorkstreamsDelivery.resolve(card: deliveryCard(), branch: "b",
                               repoRoot: "/repo", git: fakeProbe(remoteNames: []), tokens: fake.store(home: "/h"))
      .blocker, .noRemote, "no remote is refused")
// noGitHubRemote
eq(WorkstreamsDelivery.resolve(card: deliveryCard(), branch: "b", repoRoot: "/repo",
                               git: fakeProbe(remoteURL: "https://gitlab.com/o/r.git"), tokens: fake.store(home: "/h"))
      .blocker, .noGitHubRemote, "a non-GitHub remote is refused")
// noToken
let emptyTokens = FakeTokens().store(home: "/h")
eq(WorkstreamsDelivery.resolve(card: deliveryCard(), branch: "b", repoRoot: "/repo",
                               git: fakeProbe(), tokens: emptyTokens)
      .blocker, .noToken, "a missing token is refused")

// Every blocker carries a stable code + a non-empty reason.
let blockers: [WSDeliveryBlocker] = [.notAccepted(.planning), .notGitRepo, .noBranch,
                                     .noRemote, .noGitHubRemote, .noToken]
let expectedCodes = ["not-accepted", "not-git-repo", "no-branch", "no-remote",
                     "no-github-remote", "no-token"]
for (i, blocker) in blockers.enumerated() {
    eq(blocker.code, expectedCodes[i], "blocker code " + expectedCodes[i])
    check(!blocker.message.isEmpty, "blocker message is not empty: " + blocker.code)
    eq(blocker.messageKey, "workstreams.deliver." + blocker.code, "blocker message key: " + blocker.code)
}
check(WSDeliveryBlocker.notAccepted(.planning).message.contains("验收"),
      "notAccepted reason names the acceptance sign-off")
check(WSDeliveryBlocker.noBranch.message.contains("分支"), "noBranch reason names the branch")
check(WSDeliveryBlocker.noRemote.message.contains("远端"), "noRemote reason names the remote")
check(WSDeliveryBlocker.noToken.message.contains("token"), "noToken reason names the token")

// MARK: - the delivery path

section("delivery path (injected probe)")
let card = deliveryCard(covered: CoveredRecord(paths: ["platforms/macos/src/WorkstreamsDelivery.swift"],
                                               base: "baseblob", head: "headblob"))
let resolution = WorkstreamsDelivery.resolve(
    card: card, branch: "feature/workstream-panel", repoRoot: "/repo", repoID: ".",
    base: "main", git: fakeProbe(), tokens: fake.store(home: "/h"),
    findExistingPR: { _, _, _, _ in "https://github.com/example/example/pull/99" })
check(resolution.isReady, "a complete delivery is ready")
if let plan = resolution.plan {
    eq(plan.workstreamID, "WS-000009", "plan carries the workstream id")
    eq(plan.stage, .acceptance, "plan carries the last stage (delivery is an operation)")
    eq(plan.slug, "example/example", "plan carries owner/repo")
    eq(plan.remote, "origin", "plan carries the push remote")
    eq(plan.branch, "feature/workstream-panel", "plan carries the branch")
    eq(plan.base, "main", "explicit base wins")
    eq(plan.token, "ghp_secret_value_123", "plan carries the token for API calls")
    eq(plan.existingPR, "https://github.com/example/example/pull/99", "existing PR is looked up")
    eq(plan.commits, ["abc1234 feat: 交付"], "commits come from base..branch")
    eq(plan.covered?.paths, ["platforms/macos/src/WorkstreamsDelivery.swift"], "covered paths travel with the plan")

    let prompt = WorkstreamsDelivery.prompt(plan: plan)
    check(prompt.contains("WS-000009"), "prompt names the workstream")
    check(prompt.contains("事项面板交付"), "prompt names the title")
    check(prompt.contains("feature/workstream-panel"), "prompt names the branch")
    check(prompt.contains("example/example"), "prompt names the repo")
    check(prompt.contains("WorkstreamsDelivery.swift"), "prompt lists covered paths")
    check(prompt.contains("headblob"), "prompt shows the covered head anchor")
    check(prompt.contains("pull/99"), "prompt points at the existing PR")
    check(prompt.contains("$DSH_HOME/oh-my-dsh/gh-token"), "prompt tells where the token file is")
    check(!prompt.contains("ghp_secret_value_123"), "prompt never contains the token value")
    check(prompt.contains("delivery.outcome"), "prompt tells the session outcome is derived")
    check(prompt.contains("最后一行"), "prompt requires the PR link on the last line")
}

// Default base: the repo's own default when no explicit base is passed.
let defaultBase = WorkstreamsDelivery.resolve(card: card, branch: "b", repoRoot: "/repo",
                                              git: fakeProbe(current: "develop", hasMain: false),
                                              tokens: fake.store(home: "/h"),
                                              findExistingPR: { _, _, _, _ in nil })
eq(defaultBase.plan?.base, "develop", "no explicit base -> the repo default branch")

// Card facts are a fallback when GitHub knows no open PR yet.
let cardWithDelivery = deliveryCard(delivery: DeliveryInfo(pr: 12, url: "https://github.com/example/example/pull/12",
                                                           outcome: nil))
let fallback = WorkstreamsDelivery.resolve(card: cardWithDelivery, branch: "b", repoRoot: "/repo",
                                           git: fakeProbe(), tokens: fake.store(home: "/h"),
                                           findExistingPR: { _, _, _, _ in nil })
eq(fallback.plan?.existingPR, "https://github.com/example/example/pull/12",
   "the recorded delivery url is the fallback")

eq(WorkstreamsDelivery.summary(fromReport: "anything\nhttps://github.com/example/example/pull/7"),
   "https://github.com/example/example/pull/7", "summary prefers the PR url")
eq(WorkstreamsDelivery.summary(fromReport: "已合并到 main"), "已合并到 main", "summary falls back to the first line")
eq(WorkstreamsDelivery.summary(fromReport: "   "), nil, "blank report -> no summary")

// The prompt explicitly says it runs in the home session (no delivery task /
// session) and names the API write as the completion signal.
let homePrompt = WorkstreamsDelivery.prompt(plan: resolution.plan!)
check(homePrompt.contains("主场会话"), "prompt runs in the home session")
check(homePrompt.contains("不要新建交付任务"), "prompt forbids a delivery task")
check(homePrompt.contains("完成信号"), "prompt names the completion signal")
check(homePrompt.contains("/api/workstreams/delivery"), "prompt names the facts write route")

// MARK: - the home-session delivery run (completion / report / timeout)

section("home-session delivery run")
let t0 = Date(timeIntervalSince1970: 1_000_000)
let run = WSDeliveryRun(workspace: "/repo", workstreamID: "WS-000009", sessionID: "s-home",
                        startedAt: t0, timeout: 120, reportGrace: 10)
eq(run.evaluate(now: t0.addingTimeInterval(5), delivered: false,
                sessionRunning: true, report: nil), .pending,
   "a running session with no facts yet is pending")
eq(run.evaluate(now: t0.addingTimeInterval(5), delivered: true,
                sessionRunning: true, report: nil), .delivered,
   "the API write (delivery facts on the card) is the completion signal")
// The report only decides after the grace window: a just-sent prompt must not be
// judged by the previous turn's report.
eq(run.evaluate(now: t0.addingTimeInterval(5), delivered: false,
                sessionRunning: false, report: "权限不足"), .pending,
   "a stopped session inside the report grace is still pending")
eq(run.evaluate(now: t0.addingTimeInterval(11), delivered: false,
                sessionRunning: false, report: "没有权限推送"), .failed(.report("没有权限推送")),
   "a stopped session without facts fails with its own report")
eq(run.evaluate(now: t0.addingTimeInterval(11), delivered: true,
                sessionRunning: false, report: "没有权限推送"), .delivered,
   "facts win over the report")
eq(run.evaluate(now: t0.addingTimeInterval(121), delivered: false,
                sessionRunning: true, report: nil), .failed(.timeout),
   "a session that never records the facts times out")
eq(run.evaluate(now: t0.addingTimeInterval(121), delivered: true,
                sessionRunning: true, report: nil), .delivered,
   "facts win over the timeout")
eq(WSDeliveryFailure.report("x").code, "report-failed", "report failure code")
eq(WSDeliveryFailure.timeout.code, "delivery-timeout", "timeout failure code")
eq(WSDeliveryFailure.report("x").messageKey, "workstreams.deliver.report-failed", "report failure key")
eq(WSDeliveryFailure.timeout.messageKey, "workstreams.deliver.delivery-timeout", "timeout failure key")
check(!WSDeliveryFailure.report("   ").message.isEmpty, "empty report still explains the failure")
check(WSDeliveryFailure.report("没有权限推送").message.contains("没有权限推送"),
      "report failure carries the session's own explanation")
check(WSDeliveryFailure.timeout.message.contains("超时"), "timeout failure names the timeout")

// MARK: - real git pipeline

section("real git repo through WSGitProbe.live")
let repo = tempDir("repo")
_ = WSGitProbe.runGit(repo, ["-c", "init.defaultBranch=main", "init"])
_ = WSGitProbe.runGit(repo, ["config", "user.email", "test@example.com"])
_ = WSGitProbe.runGit(repo, ["config", "user.name", "Test"])
try? "hello".write(toFile: repo + "/file.txt", atomically: true, encoding: .utf8)
_ = WSGitProbe.runGit(repo, ["add", "file.txt"])
_ = WSGitProbe.runGit(repo, ["commit", "-m", "chore: init"])
_ = WSGitProbe.runGit(repo, ["remote", "add", "origin", "https://github.com/example/example.git"])
_ = WSGitProbe.runGit(repo, ["checkout", "-b", "feature/workstream-panel"])
try? "world".write(toFile: repo + "/file2.txt", atomically: true, encoding: .utf8)
_ = WSGitProbe.runGit(repo, ["add", "file2.txt"])
_ = WSGitProbe.runGit(repo, ["commit", "-m", "feat: deliver"])

let liveHome = tempDir("live-home")
let liveStore = WSTokenStore(home: liveHome)
liveStore.save("live-token", owner: "example", repo: "example")
let live = WorkstreamsDelivery.resolve(card: deliveryCard(), branch: "feature/workstream-panel",
                                       repoRoot: repo, git: .live, tokens: liveStore,
                                       findExistingPR: { owner, repoName, branch, token in
                                           // The probe gives the pipeline the token; assert here too.
                                           owner == "example" && repoName == "example"
                                               && branch == "feature/workstream-panel" && token == "live-token"
                                               ? "https://github.com/example/example/pull/101" : nil
                                       })
check(live.isReady, "a real repo delivers: " + String(describing: live.blocker))
if let plan = live.plan {
    eq(plan.slug, "example/example", "live: owner/repo from git remote -v")
    eq(plan.base, "main", "live: default base from the local main")
    eq(plan.branch, "feature/workstream-panel", "live: branch as passed")
    eq(plan.existingPR, "https://github.com/example/example/pull/101", "live: existing PR from the lookup")
    check(plan.commits.contains { $0.contains("feat: deliver") }, "live: commits include the delivery commit")
    eq(plan.covered, nil, "live: card had no covered point")
    check(!WorkstreamsDelivery.prompt(plan: plan).contains("live-token"), "live: prompt hides the token")
}

// A local-only real repo (no remote) is the noRemote reason, even with a token.
let localRepo = tempDir("local-repo")
_ = WSGitProbe.runGit(localRepo, ["-c", "init.defaultBranch=main", "init"])
_ = WSGitProbe.runGit(localRepo, ["config", "user.email", "test@example.com"])
_ = WSGitProbe.runGit(localRepo, ["config", "user.name", "Test"])
_ = WSGitProbe.runGit(localRepo, ["commit", "--allow-empty", "-m", "init"])
eq(WorkstreamsDelivery.resolve(card: deliveryCard(), branch: "main", repoRoot: localRepo, git: .live,
                               tokens: liveStore, findExistingPR: { _, _, _, _ in nil }).blocker,
   .noRemote, "live: local-only repo -> noRemote")

// Cleanup the temp trees.
try? FileManager.default.removeItem(atPath: repo)
try? FileManager.default.removeItem(atPath: localRepo)
try? FileManager.default.removeItem(atPath: home)
try? FileManager.default.removeItem(atPath: liveHome)

print("delivery: " + String(checks) + " checks, " + String(failures) + " failure(s)")
if failures > 0 { exit(1) }
