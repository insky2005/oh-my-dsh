//
//  ProjectsCore.swift — pure model for the Projects panel (right-side slot #9).
//
//  The Projects panel treats "a workspace" as *a directory under a configurable
//  projects root*, so the whole feature is built on four model-level questions
//  that must not be spread across the UI:
//
//    1. which root is in effect?      -> resolvedRoot()   (env > config > default)
//    2. is this a legal folder name?  -> validateName()   (single path segment)
//    3. which workspaces are there?   -> listDirectories()
//    4. which of them does dsh know?  -> merge()          (registry match)
//
//  Only (4) touches dsh, and it does so through an *injected* canonicalizer, so
//  this file stays free of AppKit and of DshWebRPC and can be unit tested
//  headlessly (tests/projects-panel/run.sh). The panel (ProjectsPanel.swift) and
//  main.swift own everything else.
//
//  Design: docs/projects-panel-design.md (§2/§3).
//

import Foundation

/// One workspace = one directory under the projects root, decorated with what the
/// dsh workspace registry (if anything) says about it.
struct ProjectWorkspace: Equatable {
    /// Directory name — the card's title, and the only thing the user types when
    /// creating one.
    let name: String
    /// Absolute path (root + name).
    let path: String
    /// Directory mtime (best effort: nil when the file system cannot report it).
    let modifiedAt: Date?
    /// True when dsh has a workspace whose path canonicalizes to this directory.
    let registered: Bool
    /// dsh's workspaceId while registered — used to create sessions *inside* this
    /// workspace (so dsh web groups them under it instead of "Ungrouped").
    let workspaceId: String?
    /// Sessions dsh accounts to this workspace (0 while unregistered).
    let sessionCount: Int
}

enum ProjectsCore {

    // MARK: - Configuration

    /// Shell setting key ($DSH_HOME/shell/config.json); absent/empty = default.
    /// Deliberately NOT part of ShellConfig.legacyUserDefaultsKeys: it is a new
    /// key, there is no pre-1.14 UserDefaults value to migrate.
    static let configKey = "projectsRoot"

    /// QA-only override (higher priority than the setting). Lets the panel be
    /// pointed at a fixture root without touching the user's config.
    static let envRootKey = "DSH_PROJECTS_TEST_ROOT"

    /// Default root, relative to the dsh data home:
    /// <DSH_HOME>/oh-my-dsh/projects (dev builds isolate to ~/.dsh-dev).
    static let defaultSubpath = "oh-my-dsh/projects"

    /// Upper bound on a workspace name. Long enough for any realistic project,
    /// short enough that <root>/<name> stays far from any path length limit.
    static let maxNameLength = 64

    /// Where the effective root came from — the panel logs it, tests pin it.
    enum RootSource: String, Equatable {
        case environment      // DSH_PROJECTS_TEST_ROOT
        case config           // shell/config.json -> projectsRoot
        case fallback         // built-in default (no usable value configured)
        case invalidConfig    // configured, but not an absolute path -> fallback
    }

    struct RootResolution: Equatable {
        let path: String
        let source: RootSource
    }

    /// The built-in root for a given dsh data home.
    static func defaultRoot(dshHome: String) -> String {
        (dshHome as NSString).appendingPathComponent(defaultSubpath)
    }

    /// Effective projects root. Priority: QA env override > projectsRoot >
    /// built-in default. A configured value that is blank or not an absolute path
    /// is *rejected* (never silently turned into a path relative to the process'
    /// cwd) and reported as .invalidConfig.
    static func resolvedRoot(configValue: String?,
                             dshHome: String,
                             envOverride: String? = ProcessInfo.processInfo.environment[envRootKey]) -> RootResolution {
        if let env = envOverride?.trimmed, !env.isEmpty, let absolute = absolutePath(env) {
            return RootResolution(path: absolute, source: .environment)
        }
        if let raw = configValue, !raw.trimmed.isEmpty {
            if let absolute = absolutePath(raw) {
                return RootResolution(path: absolute, source: .config)
            }
            return RootResolution(path: defaultRoot(dshHome: dshHome), source: .invalidConfig)
        }
        return RootResolution(path: defaultRoot(dshHome: dshHome), source: .fallback)
    }

    /// Absolute, standardized form of a user-supplied path (~ expanded), or nil
    /// when it is not absolute.
    static func absolutePath(_ raw: String) -> String? {
        let expanded = (raw.trimmed as NSString).expandingTildeInPath
        guard (expanded as NSString).isAbsolutePath else { return nil }
        return (expanded as NSString).standardizingPath
    }

    // MARK: - Name rules

    /// Why a typed workspace name was rejected. The panel maps each case onto one
    /// bilingual message (docs/projects-panel-design.md §10).
    enum NameError: Error, Equatable {
        case empty
        case separator            // "/" or ":" — not a single path segment
        case illegalCharacter     // control characters
        case dot                  // "." / ".."
        case hidden               // leading "." — the panel never lists hidden dirs
        case tooLong
    }

    /// Validate a typed name and return the value to use (trimmed) on success.
    static func validateName(_ raw: String) -> Result<String, NameError> {
        let name = raw.trimmed
        guard !name.isEmpty else { return .failure(.empty) }
        if name.contains("/") || name.contains(":") { return .failure(.separator) }
        if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return .failure(.illegalCharacter)
        }
        if name == "." || name == ".." { return .failure(.dot) }
        if name.hasPrefix(".") { return .failure(.hidden) }
        if name.count > maxNameLength { return .failure(.tooLong) }
        return .success(name)
    }

    /// The path a workspace name maps to (the name is validated separately).
    static func workspacePath(root: String, name: String) -> String {
        (root as NSString).appendingPathComponent(name)
    }

    // MARK: - Listing

    /// One direct subdirectory of the root.
    struct DirectoryEntry: Equatable {
        let name: String
        let path: String
        let modifiedAt: Date?
    }

    /// The *direct* subdirectories of the root, i.e. the workspaces this panel
    /// manages. Rules (docs §3.4):
    ///   * directories only — plain files are not workspaces;
    ///   * symlinks that point at a directory ARE workspaces (linking an existing
    ///     repo into the root is a normal way to adopt it);
    ///   * hidden entries (leading ".") are skipped — the panel must not offer
    ///     what it refuses to create;
    ///   * sorted case-insensitively by name;
    ///   * a missing root is an empty list, never an error and never created here.
    static func listDirectories(root: String, fileManager: FileManager = .default) -> [DirectoryEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let urls = try? fileManager.contentsOfDirectory(at: URL(fileURLWithPath: root),
                                                             includingPropertiesForKeys: keys,
                                                             options: []) else { return [] }
        var out: [DirectoryEntry] = []
        for url in urls {
            let name = url.lastPathComponent
            if name.isEmpty || name.hasPrefix(".") { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            var isDir = values?.isDirectory ?? false
            if !isDir, values?.isSymbolicLink == true {
                // A symlink: follow it — only links onto directories count.
                var target: ObjCBool = false
                if fileManager.fileExists(atPath: url.path, isDirectory: &target), target.boolValue {
                    isDir = true
                }
            }
            guard isDir else { continue }
            out.append(DirectoryEntry(name: name, path: url.path, modifiedAt: values?.contentModificationDate))
        }
        return out.sorted {
            let l = $0.name.lowercased(), r = $1.name.lowercased()
            return l == r ? $0.name < $1.name : l < r
        }
    }

    /// Decorate the listing with the dsh workspace registry (items shaped like
    /// workspace/list: workspaceId / path / sessionIds).
    ///
    /// Paths on both sides are compared through the injected canonical (the panel
    /// passes DshWorkspaceStore.canonical, which standardizes and resolves
    /// symlinks), so "/r/abc", "/r/abc/" and a symlinked "/link/abc" all match the
    /// same workspace. An unreadable or empty registry simply leaves every entry
    /// unregistered — the panel still lists the folders.
    static func merge(entries: [DirectoryEntry],
                      registry: [[String: Any]],
                      canonical: (String) -> String) -> [ProjectWorkspace] {
        var byPath: [String: (id: String?, sessions: Int)] = [:]
        for item in registry {
            guard let path = item["path"] as? String, !path.isEmpty else { continue }
            let key = canonical(path)
            if byPath[key] != nil { continue }   // first match wins (dsh's own order)
            byPath[key] = (item["workspaceId"] as? String, (item["sessionIds"] as? [String])?.count ?? 0)
        }
        return entries.map { entry in
            let hit = byPath[canonical(entry.path)]
            return ProjectWorkspace(name: entry.name,
                                    path: entry.path,
                                    modifiedAt: entry.modifiedAt,
                                    registered: hit != nil,
                                    workspaceId: hit?.id,
                                    sessionCount: hit?.sessions ?? 0)
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
