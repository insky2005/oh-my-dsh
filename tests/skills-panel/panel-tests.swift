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

// Available-list card interaction: the card body opens the detail page, and the
// Install button only appears while the pointer is over the card.
let hoverProbe = SkillCandidate(name: "hover-probe", description: "d", sourceLabel: "acme/skills",
                                installs: 3,
                                address: .github(owner: "acme", repo: "skills", ref: nil, subpath: nil, skill: "hover-probe"))
let probeCard = SkillCandidateRowView(candidate: hoverProbe)
test("install button starts hidden", !probeCard.isInstallButtonVisible)
probeCard.setHovered(true)
test("hovering reveals the install button", probeCard.isInstallButtonVisible)
probeCard.setHovered(false)
test("leaving the card hides it again", !probeCard.isInstallButtonVisible)

var detailOpened = false
probeCard.onDetail = { detailOpened = true }
if let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                  timestamp: 0, windowNumber: 0, context: nil,
                                  eventNumber: 1, clickCount: 1, pressure: 1) {
    probeCard.mouseDown(with: click)
}
test("clicking the card opens the detail page", detailOpened)

// Scrolling must not leave stale hover highlights: a card that slides out from
// under a stationary pointer never gets mouseExited, so the panel recomputes the
// hovered card from the pointer position (SkillHoverResolver).
let cardFrames = [NSRect(x: 0, y: 0, width: 300, height: 60),
                  NSRect(x: 0, y: 68, width: 300, height: 60),
                  NSRect(x: 0, y: 136, width: 300, height: 60)]
let clip = NSRect(x: 0, y: 0, width: 300, height: 140)
test("hover: pointer inside the second card",
     SkillHoverResolver.hoveredIndex(cardFrames: cardFrames, clipBounds: clip,
                                     mouse: NSPoint(x: 150, y: 100)) == 1)
test("hover: pointer between cards -> nothing hovered",
     SkillHoverResolver.hoveredIndex(cardFrames: cardFrames, clipBounds: clip,
                                     mouse: NSPoint(x: 150, y: 64)) == nil)
test("hover: a card scrolled out of view never hovers",
     SkillHoverResolver.hoveredIndex(cardFrames: cardFrames, clipBounds: clip,
                                     mouse: NSPoint(x: 150, y: 160)) == nil)
test("hover: pointer outside the list -> nothing hovered",
     SkillHoverResolver.hoveredIndex(cardFrames: cardFrames, clipBounds: clip,
                                     mouse: NSPoint(x: 400, y: 100)) == nil)

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
