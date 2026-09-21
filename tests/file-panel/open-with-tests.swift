import Foundation

// Headless tests for the "open the project directory with…" catalog
// (OpenWithApps.swift) — the model behind the Files panel project button
// (docs/ux-feedback.md #2). No AppKit here: installation probing is injected.
// Usage: tests/file-panel/run.sh

func test(_ name: String, _ cond: Bool) {
    print((cond ? "ok" : "FAIL") + " - " + name)
    if !cond { exit(1) }
}

let always = { (_: OpenWithEntry) -> Bool in true }
let never = { (_: OpenWithEntry) -> Bool in false }

test("the shell-owned targets come first", OpenWithCatalog.all.prefix(2).map(\.id) == ["panel", "finder"])
test("the catalog lists editors and terminals",
     !OpenWithCatalog.editors.isEmpty && !OpenWithCatalog.terminals.isEmpty)
test("the catalog contains VS Code", OpenWithCatalog.entry(id: "com.microsoft.VSCode")?.title == "VS Code")
test("catalog ids are unique", Set(OpenWithCatalog.all.map(\.id)).count == OpenWithCatalog.all.count)
test("only shell-owned entries carry an L10n key",
     OpenWithCatalog.panel.l10nKey != nil && OpenWithCatalog.finder.l10nKey != nil
     && OpenWithCatalog.all.allSatisfy { $0.l10nKey != nil || $0.group == .editor || $0.group == .terminal })

// First use: nothing remembered → the panel must show the menu.
test("no remembered target pops the menu", OpenWithCatalog.rememberedEntry(nil, isInstalled: always) == nil)
// The panel itself needs no installation.
test("the panel target is always usable",
     OpenWithCatalog.rememberedEntry("panel", isInstalled: never)?.id == "panel")
test("the finder target is always usable",
     OpenWithCatalog.rememberedEntry("finder", isInstalled: never)?.id == "finder")
// A remembered app that is still installed is reused directly.
test("an installed editor is reused",
     OpenWithCatalog.rememberedEntry("com.microsoft.VSCode", isInstalled: always)?.id == "com.microsoft.VSCode")
// …and one that was uninstalled falls back to the menu instead of failing.
test("an uninstalled editor falls back to the menu",
     OpenWithCatalog.rememberedEntry("dev.zed.Zed", isInstalled: never) == nil)
test("an unknown remembered id falls back to the menu",
     OpenWithCatalog.rememberedEntry("com.example.uninstalled", isInstalled: always) == nil)
// Apps picked through the file panel are remembered by path.
test("a picked app is stored by path",
     OpenWithCatalog.pathEntryId("/Applications/Foo.app") == "path:/Applications/Foo.app")
test("every catalog entry has an id", OpenWithCatalog.all.allSatisfy { !$0.id.isEmpty })

print("done")
