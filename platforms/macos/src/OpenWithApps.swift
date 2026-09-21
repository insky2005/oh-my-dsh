import Foundation

// MARK: - "Open the project directory with…" catalog (pure Foundation)
//
// The Files panel's project button used to have exactly one behaviour: open the
// active project directory inside the panel. Developers usually want it in their
// editor / IDE / terminal instead (issue #2 in docs/ux-feedback.md), so the
// button now offers a menu and remembers the chosen app.
//
// This file holds ONLY the catalog and the selection rules — no AppKit — so the
// "which entries appear, which one is remembered, what happens when the app is
// gone" decisions are unit-tested headlessly (tests/file-panel/run.sh). The
// panel probes installed applications through NSWorkspace and drives the menu.

/// One selectable target for "open the project directory".
struct OpenWithEntry: Equatable {
    /// Persistence key: "panel", "finder", a bundle identifier, or "path:<…>".
    let id: String
    /// Menu title. Brand names (VS Code, iTerm2 …) are never translated; the two
    /// shell-owned entries carry an `l10nKey` instead.
    let title: String
    /// Bundle identifier, used to locate the app and to detect if it is installed.
    let bundleIdentifier: String?
    /// L10n key for shell-owned entries (panel / finder); nil for real apps.
    let l10nKey: String?
    let group: Group

    enum Group: String {
        case panel, finder, editor, terminal
    }
}

enum OpenWithCatalog {

    /// Open the directory inside the panel itself — the historical behaviour and
    /// the fallback whenever nothing is remembered.
    static let panel = OpenWithEntry(id: "panel", title: "Files Panel",
                                     bundleIdentifier: nil,
                                     l10nKey: "files.openInPanel", group: .panel)

    /// Hand the directory to Finder.
    static let finder = OpenWithEntry(id: "finder", title: "Finder",
                                      bundleIdentifier: nil,
                                      l10nKey: "files.openInFinder", group: .finder)

    /// Editors / IDEs, in menu order.
    static let editors: [OpenWithEntry] = [
        OpenWithEntry(id: "com.microsoft.VSCode", title: "VS Code",
                      bundleIdentifier: "com.microsoft.VSCode", l10nKey: nil, group: .editor),
        OpenWithEntry(id: "com.microsoft.VSCodeInsiders", title: "VS Code Insiders",
                      bundleIdentifier: "com.microsoft.VSCodeInsiders", l10nKey: nil, group: .editor),
        OpenWithEntry(id: "com.todesktop.230313mzl4w4u92", title: "Cursor",
                      bundleIdentifier: "com.todesktop.230313mzl4w4u92", l10nKey: nil, group: .editor),
        OpenWithEntry(id: "com.exafunction.windsurf", title: "Windsurf",
                      bundleIdentifier: "com.exafunction.windsurf", l10nKey: nil, group: .editor),
        OpenWithEntry(id: "dev.zed.Zed", title: "Zed",
                      bundleIdentifier: "dev.zed.Zed", l10nKey: nil, group: .editor),
        OpenWithEntry(id: "com.sublimetext.4", title: "Sublime Text",
                      bundleIdentifier: "com.sublimetext.4", l10nKey: nil, group: .editor),
        OpenWithEntry(id: "com.panic.Nova", title: "Nova",
                      bundleIdentifier: "com.panic.Nova", l10nKey: nil, group: .editor),
        OpenWithEntry(id: "com.apple.dt.Xcode", title: "Xcode",
                      bundleIdentifier: "com.apple.dt.Xcode", l10nKey: nil, group: .editor),
        OpenWithEntry(id: "com.jetbrains.intellij", title: "IntelliJ IDEA",
                      bundleIdentifier: "com.jetbrains.intellij", l10nKey: nil, group: .editor),
        OpenWithEntry(id: "com.jetbrains.WebStorm", title: "WebStorm",
                      bundleIdentifier: "com.jetbrains.WebStorm", l10nKey: nil, group: .editor),
        OpenWithEntry(id: "com.jetbrains.pycharm", title: "PyCharm",
                      bundleIdentifier: "com.jetbrains.pycharm", l10nKey: nil, group: .editor),
        OpenWithEntry(id: "com.jetbrains.goland", title: "GoLand",
                      bundleIdentifier: "com.jetbrains.goland", l10nKey: nil, group: .editor),
        OpenWithEntry(id: "com.google.android.studio", title: "Android Studio",
                      bundleIdentifier: "com.google.android.studio", l10nKey: nil, group: .editor),
    ]

    /// External terminals, in menu order.
    static let terminals: [OpenWithEntry] = [
        OpenWithEntry(id: "com.googlecode.iterm2", title: "iTerm2",
                      bundleIdentifier: "com.googlecode.iterm2", l10nKey: nil, group: .terminal),
        OpenWithEntry(id: "com.apple.Terminal", title: "Terminal",
                      bundleIdentifier: "com.apple.Terminal", l10nKey: nil, group: .terminal),
        OpenWithEntry(id: "dev.warp.Warp-Stable", title: "Warp",
                      bundleIdentifier: "dev.warp.Warp-Stable", l10nKey: nil, group: .terminal),
        OpenWithEntry(id: "com.mitchellh.ghostty", title: "Ghostty",
                      bundleIdentifier: "com.mitchellh.ghostty", l10nKey: nil, group: .terminal),
        OpenWithEntry(id: "net.kovidgoyal.kitty", title: "kitty",
                      bundleIdentifier: "net.kovidgoyal.kitty", l10nKey: nil, group: .terminal),
        OpenWithEntry(id: "org.alacritty", title: "Alacritty",
                      bundleIdentifier: "org.alacritty", l10nKey: nil, group: .terminal),
        OpenWithEntry(id: "com.github.wez.wezterm", title: "WezTerm",
                      bundleIdentifier: "com.github.wez.wezterm", l10nKey: nil, group: .terminal),
        OpenWithEntry(id: "co.zeit.hyper", title: "Hyper",
                      bundleIdentifier: "co.zeit.hyper", l10nKey: nil, group: .terminal),
    ]

    /// Everything the menu can offer, in order (installed apps are filtered by
    /// the caller — this is the catalog, not the menu).
    static var all: [OpenWithEntry] { [panel, finder] + editors + terminals }

    /// Look an entry up by its persisted id.
    static func entry(id: String) -> OpenWithEntry? {
        all.first { $0.id == id }
    }

    /// The entry a button click should use without asking, or nil when the panel
    /// must show the menu: nothing remembered yet, an unknown id, or a
    /// remembered application that is no longer installed.
    ///
    /// - Parameters:
    ///   - remembered: the persisted id ("panel", "finder", bundle id, "path:…").
    ///   - isInstalled: probe injected by the caller (NSWorkspace in the panel,
    ///     a stub in tests).
    static func rememberedEntry(_ remembered: String?, isInstalled: (OpenWithEntry) -> Bool) -> OpenWithEntry? {
        guard let remembered = remembered else { return nil }
        guard let entry = entry(id: remembered) else { return nil }
        switch entry.group {
        case .panel, .finder: return entry
        case .editor, .terminal: return isInstalled(entry) ? entry : nil
        }
    }

    /// Id for an application chosen through the file picker (an app that is not
    /// in the catalog): stored by path, so it keeps working across launches.
    static func pathEntryId(_ appPath: String) -> String { "path:" + appPath }
}
