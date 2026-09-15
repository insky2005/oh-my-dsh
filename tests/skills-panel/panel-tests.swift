import AppKit
import Foundation

// Headless smoke test for the Skills panel controller: instantiate it against a
// fixture DSH_HOME (no window, no network) and exercise the render path so a
// construction/layout regression fails CI instead of only showing up in the app.
// Usage: tests/skills-panel/run.sh

/// Defined in ChannelPanel.swift for the app target; the headless test builds
/// only the skills sources, so provide the same shape here.
final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

func test(_ name: String, _ cond: Bool) {
    print((cond ? "ok" : "FAIL") + " - " + name)
    if !cond { exit(1) }
}

_ = NSApplication.shared

// NOTE: declared up front — top-level globals in main.swift are lazily
// initialised, so reading it before this line would silently yield "".
let home = ProcessInfo.processInfo.environment["DSH_HOME"] ?? ""

let panel = SkillsPanelController()
test("header shows the panel's fixed title key", panel.headerTitleKey() == "skills.title")

panel.refreshTooltips()
test("a language switch keeps the fixed title", panel.headerTitleKey() == "skills.title")

// Scans the fixture roots, renders the installed list and the registry tabs.
panel.ensureLoaded()
panel.refreshTooltips()

// Changing a skill's invocation flags must notify the shell so it can make
// dsh web drop its cached skill catalog (otherwise the composer's "/" menu is
// stale until the page is reloaded).
var catalogChanged = 0
panel.onCatalogChanged = { catalogChanged += 1 }
let toggled = panel.applyInvocationForQA(name: "my-tool", userInvocable: false, modelInvocable: nil)
test("invocation toggle reaches the skill on disk", toggled)
test("invocation toggle notifies the shell (catalog changed)", catalogChanged == 1)
let toolFile = (home as NSString).appendingPathComponent("skills/my-tool/SKILL.md")
if let text = try? String(contentsOfFile: toolFile, encoding: .utf8) {
    test("SKILL.md now carries user-invocable: false", text.contains("user-invocable: false"))
} else {
    test("SKILL.md now carries user-invocable: false", false)
}
// Toggling back must remove the key again (byte round-trip) and notify again.
_ = panel.applyInvocationForQA(name: "my-tool", userInvocable: true, modelInvocable: nil)
if let text = try? String(contentsOfFile: toolFile, encoding: .utf8) {
    test("toggling back removes the key", !text.contains("user-invocable"))
}
test("second toggle notifies again", catalogChanged == 2)

// The checkbox column in the available list selects candidates for a BULK
// install, so it must actually accumulate selection (and 全选 must toggle it).
let fakeA = SkillCandidate(name: "bulk-a", description: "a", sourceLabel: "acme/skills", installs: 10,
                           address: .github(owner: "acme", repo: "skills", ref: nil, subpath: nil, skill: "bulk-a"))
let fakeB = SkillCandidate(name: "bulk-b", description: "b", sourceLabel: "acme/skills", installs: 5,
                           address: .github(owner: "acme", repo: "skills", ref: nil, subpath: nil, skill: "bulk-b"))
panel.setCandidatesForQA([fakeA, fakeB])
test("selection starts empty", panel.selectedCountForQA == 0)
panel.selectAllForQA()
test("select-all ticks every visible candidate", panel.selectedCountForQA == 2)
panel.selectAllForQA()
test("select-all again clears the selection", panel.selectedCountForQA == 0)

// The registry-management page is rendered INSIDE the content area (the header's
// top-right button switches to it), so exercise all three pages.
panel.showPage(.registries)
panel.showPage(.available)
panel.showPage(.installed)

// Instantiating the panel seeds the default registry into the shell store.
let storeFile = (home as NSString).appendingPathComponent("shell/skills.json")
test("shell store seeded at $DSH_HOME/shell/skills.json", FileManager.default.fileExists(atPath: storeFile))
if let raw = try? String(contentsOfFile: storeFile, encoding: .utf8) {
    // NOTE: JSONEncoder escapes forward slashes ("api\/search"), so match on
    // markers without slashes.
    test("default skills.sh registry persisted", raw.contains("skills-sh") && raw.contains("{q}"))
} else {
    test("default skills.sh registry persisted", false)
}

print("done")
