import AppKit
import Foundation

// Headless tests for the wiki panel's fixed header title (see the sibling
// wiki-tests.swift for the model layer). No wiki directory is scanned and no
// session is created: the controller is instantiated and only its header state
// is asserted. Usage: tests/wiki-panel/run.sh

func test(_ name: String, _ cond: Bool) {
    print((cond ? "ok" : "FAIL") + " - " + name)
    if !cond { exit(1) }
}

_ = NSApplication.shared

let panel = WikiPanelController()

test("the header shows the panel's fixed title", panel.headerTitleText == "bar.wiki")
test("the header starts without a tooltip", panel.headerTooltipText == nil)

// A language switch re-resolves the title through refreshTooltips().
panel.refreshTooltips()
test("a language switch keeps the fixed title", panel.headerTitleText == "bar.wiki")

print("done")
