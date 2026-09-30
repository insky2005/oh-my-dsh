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
    /// Human-readable migration/rollback note written into the shell root.
    static let rollbackFileName = "ROLLBACK.md"

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
    static func migrateLegacyLayout(home explicit: String? = nil, appVersion: String? = nil) -> [String] {
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
        writeRollbackGuide(root: root(home: h), moved: moved, appVersion: appVersion)
        return moved
    }

    static func rollbackGuidePath(home explicit: String? = nil) -> String {
        join(root(home: explicit), rollbackFileName)
    }

    /// Plain-text (bilingual) rollback note for a human.
    static func renderRollbackGuide(moved: [String], at: Date = Date(), appVersion: String? = nil) -> String {
        let iso = ISO8601DateFormatter().string(from: at)
        let ver = appVersion.map { "`\($0)`" } ?? "（未知）"
        let movedList = moved.isEmpty
            ? "  - （无：本机此前已完成迁移）"
            : moved.map { "  - `\($0)`" }.joined(separator: "\n")
        return [
            "# oh-my-dsh 壳层数据目录迁移 / 回退说明",
            "",
            "生成时间：`\(iso)`　App 版本：\(ver)",
            "",
            "oh-my-dsh 已把**壳层自己的工作数据**从 `$DSH_HOME` 根目录收敛到 `$DSH_HOME/oh-my-dsh/` 下",
            "（与 `projects/` 并列）。dsh 自有的 `sessions/`、`storages/`、`settings.yaml` 以及",
            "上游契约路径 `$DSH_HOME/skills/` **未改动**。迁移是同卷 `rename`：数据未复制、未丢失。",
            "",
            "本次实际迁移：",
            movedList,
            "",
            "## 回退到只认旧根目录的旧版 App",
            "",
            "1. 退出 oh-my-dsh；",
            "2. 在终端执行（默认 `$DSH_HOME=~/.dsh`）：",
            "",
            "```bash",
            "H=\"${DSH_HOME:-$HOME/.dsh}\"",
            "for n in shell browser repo-wiki channel-runtime channels tokens gh-token browser-api.port shell-api.port; do",
            "  [ -e \"$H/$n\" ] && continue            # 目标已存在，跳过（不覆盖）",
            "  [ -e \"$H/oh-my-dsh/$n\" ] && mv \"$H/oh-my-dsh/$n\" \"$H/$n\"",
            "done",
            "# 开发版（DSH_DEV_BUILD）旧路径是 browser-dev 而非 browser：",
            "# [ -e \"$H/browser-dev\" ] || { [ -e \"$H/browser\" ] && mv \"$H/browser\" \"$H/browser-dev\"; }",
            "```",
            "",
            "3. 重新打开旧版 App。",
            "",
            "说明：反向移动前请先退出 App；重新升级到新版会再次自动归位。此文件由壳层迁移时生成，可安全删除。",
            "",
            "---",
            "",
            "# oh-my-dsh shell data directory migration / rollback",
            "",
            "The shell moved its own work data from the `$DSH_HOME` root into `$DSH_HOME/oh-my-dsh/`",
            "(next to `projects/`). dsh's own `sessions/`, `storages/`, `settings.yaml` and the upstream",
            "contract path `$DSH_HOME/skills/` are untouched. It was a same-volume rename: nothing was",
            "copied or lost.",
            "",
            "To roll back to an older app that only reads the root paths: quit oh-my-dsh, run the bash",
            "loop above, then relaunch the older app. Re-upgrading to a newer version moves the data back",
            "automatically. This file is generated by the shell and can be deleted safely.",
            "",
        ].joined(separator: "\n")
    }

    /// Write the rollback note; keep the first record when nothing new was moved.
    @discardableResult
    static func writeRollbackGuide(root: String, moved: [String], appVersion: String? = nil) -> String {
        let file = join(root, rollbackFileName)
        if moved.isEmpty && FileManager.default.fileExists(atPath: file) { return file }
        do {
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            try renderRollbackGuide(moved: moved, appVersion: appVersion)
                .write(toFile: file, atomically: true, encoding: .utf8)
        } catch { /* best effort */ }
        return file
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
