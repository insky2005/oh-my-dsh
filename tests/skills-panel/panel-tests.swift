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

let panel = SkillsPanelController()
test("header shows the panel's fixed title key", panel.headerTitleKey() == "skills.title")

panel.refreshTooltips()
test("a language switch keeps the fixed title", panel.headerTitleKey() == "skills.title")

// Scans the fixture roots, renders the installed list and the registry popup.
panel.ensureLoaded()
panel.refreshTooltips()

print("done")
