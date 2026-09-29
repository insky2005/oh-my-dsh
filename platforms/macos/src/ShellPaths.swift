import Foundation

/// ShellPaths — the single source of truth for where oh-my-dsh SHELL work data
/// lives, plus the one-time layout migration (docs/storage-layout-refactor.md).
///
///   $DSH_HOME/oh-my-dsh/
///     projects/         projects panel workspaces (ProjectsCore.defaultSubpath)
///     shell/            shell settings + snapshot state/snapshots
///     browser/          CEF/Chromium profile (release + dev unified)
///     repo-wiki/        wiki panel DSH_HOME-private root
///     channel-runtime/  channel runner runtime
///     channels/         channel credentials/sessions/messages/state
///     tokens/           per-repo GitHub tokens
///     gh-token          generic GitHub token
///     browser-api.port  browser panel localhost API port
///     shell-api.port    tasks panel localhost API port
///
/// dsh's own data (sessions/ storages/ settings.yaml ...) and the upstream
/// contract path $DSH_HOME/skills/ are NOT touched.
enum ShellPaths {
    static let rootName = "oh-my-dsh"

    /// Resolved dsh data home: $DSH_HOME (trimmed) or ~/.dsh.
    static func home() -> String {
        if let h = ProcessInfo.processInfo.environment["DSH_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty {
            return h
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".dsh")
    }

    private static func join(_ base: String, _ name: String) -> String {
        (base as NSString).appendingPathComponent(name)
    }

    static func root(home explicit: String? = nil) -> String {
        join(explicit ?? home(), rootName)
    }
    static func shellDir(home explicit: String? = nil) -> String { join(root(home: explicit), "shell") }
    static func browserDir(home explicit: String? = nil) -> String { join(root(home: explicit), "browser") }
    static func repoWikiDir(home explicit: String? = nil) -> String { join(root(home: explicit), "repo-wiki") }
    static func channelRuntimeDir(home explicit: String? = nil) -> String { join(root(home: explicit), "channel-runtime") }
    static func channelsDir(home explicit: String? = nil) -> String { join(root(home: explicit), "channels") }
    static func tokensDir(home explicit: String? = nil) -> String { join(root(home: explicit), "tokens") }
    static func ghTokenPath(home explicit: String? = nil) -> String { join(root(home: explicit), "gh-token") }
    static func browserPortPath(home explicit: String? = nil) -> String { join(root(home: explicit), "browser-api.port") }
    static func shellPortPath(home explicit: String? = nil) -> String { join(root(home: explicit), "shell-api.port") }

    /// Legacy $DSH_HOME-root entries -> new shell-root entries. Same order and
    /// semantics as core/lib/shell-paths.js: browser before browser-dev so a home
    /// with both keeps the canonical profile, and a target is never overwritten.
    private static let legacyMoves: [(String, String)] = [
        ("shell", "shell"),
        ("browser", "browser"),
        ("browser-dev", "browser"),
        ("repo-wiki", "repo-wiki"),
        ("channel-runtime", "channel-runtime"),
        ("channels", "channels"),
        ("tokens", "tokens"),
        ("gh-token", "gh-token"),
        ("browser-api.port", "browser-api.port"),
        ("shell-api.port", "shell-api.port"),
    ]

    /// One-time, idempotent move of legacy $DSH_HOME-root shell data into
    /// $DSH_HOME/oh-my-dsh/. Never overwrites an existing target; a failed move
    /// leaves the source in place. Returns "old -> new" names moved (for logging).
    @discardableResult
    static func migrateLegacyLayout(home explicit: String? = nil) -> [String] {
        let h = explicit ?? home()
        let fm = FileManager.default
        var moved: [String] = []
        for (oldName, newName) in legacyMoves {
            let from = join(h, oldName)
            guard fm.fileExists(atPath: from) else { continue }
            let to = join(root(home: h), newName)
            if fm.fileExists(atPath: to) { continue }   // never overwrite
            do {
                try fm.createDirectory(atPath: (to as NSString).deletingLastPathComponent,
                                       withIntermediateDirectories: true)
                try fm.moveItem(atPath: from, toPath: to)
                moved.append(oldName + " -> " + newName)
            } catch {
                // cross-device or permissions: keep the source, retry next launch
            }
        }
        return moved
    }

    /// Dev-only: the pre-isolation shared CEF profile (~/.dsh/browser-dev) moved
    /// into the isolated dev home's unified browser dir. Idempotent; skips when a
    /// target already exists so it never clobbers the dev home's own data.
    @discardableResult
    static func migrateLegacyDevBrowserProfile(sharedHome: String, devHome: String) -> Bool {
        let fm = FileManager.default
        let legacy = join(sharedHome, "browser-dev")
        guard fm.fileExists(atPath: legacy) else { return false }
        let dest = browserDir(home: devHome)
        guard !fm.fileExists(atPath: dest) else { return false }
        do {
            try fm.createDirectory(atPath: root(home: devHome), withIntermediateDirectories: true)
            try fm.moveItem(atPath: legacy, toPath: dest)
            return true
        } catch { return false }
    }
}
