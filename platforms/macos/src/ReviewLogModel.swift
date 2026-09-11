import Foundation

// MARK: - Review（变更审计）panel data model (pure Foundation, headless-testable)
//
// The audit itself lives in the shared core (`core/lib/review-log.js`), because
// dsh session logs are concatenated Zstandard frames and Swift cannot decode
// zstd (Apple's Compression framework has no zstd algorithm on this SDK; the
// bundled Node runtime does). This file only decodes the JSON the core CLI
// emits and folds it for display — no AppKit, so it is unit-testable headless.
//
// Contract (docs/review-panel-design.md):
//   core/bin/ohmy-core.js review sessions --workspace <dir>
//   core/bin/ohmy-core.js review audit <sessionId> --workspace <dir>
//
// Entry categories:
//   diff    — applied contextual hunks (top-level write/edit result meta)
//   args    — change reconstructed from the call arguments (nested run_code, or no meta)
//   content — full written content, old side unknown (create / nested write)
//   bash    — shell command; the file change is NOT structurally recorded

/// The session header dsh wrote for this log.
struct ReviewSessionInfo: Decodable, Equatable {
    var id: String
    var cwd: String?
    var createdAt: Double?
    var parentSession: String?
    var delegationDepth: Int?
}

/// One applied change hunk (three-line context, per dsh's diff projection).
struct ReviewHunk: Decodable, Equatable {
    var oldText: String?
    var newText: String
}

/// One audited tool call.
struct ReviewEntry: Decodable, Equatable {
    var seq: Int?
    /// Monotonic position in the audit (dsh's `seq` may repeat across record kinds).
    var order: Int?
    var turn: Int?
    var step: Int?
    var tool: String
    /// "top" (a direct tool call) or "nested" (dispatched inside run_code).
    var surface: String
    /// "ok" | "error" | "unknown" (no result recorded before the log ended).
    var status: String
    /// "diff" | "args" | "content" | "bash" | null (reads and unrecognised calls).
    var category: String?
    var path: String?
    var pathAbs: String?
    var command: String?
    /// "write-like" | "unknown" for bash calls.
    var suspicion: String?
    var hunks: [ReviewHunk]
    var added: Int
    var removed: Int
    var note: String?

    var isMutation: Bool { category == "diff" || category == "args" || category == "content" }
    var isBash: Bool { category == "bash" }
    var isNested: Bool { surface == "nested" }
    var isError: Bool { status == "error" }
}

/// Counters for the audit header.
struct ReviewStats: Decodable, Equatable {
    var entries: Int
    var mutations: Int
    var files: Int
    var added: Int
    var removed: Int
    var nested: Int
    var bashCalls: Int
    var bashSuspect: Int
    var failed: Int
}

/// A reader-facing diagnostic emitted by core (never a user-facing failure).
struct ReviewDiagnostic: Decodable, Equatable {
    var code: String
    var message: String
}

/// Result of `review audit`.
struct ReviewAudit: Decodable, Equatable {
    var session: ReviewSessionInfo?
    var entries: [ReviewEntry]
    var stats: ReviewStats?
    var diagnostics: [ReviewDiagnostic]?
}

/// One session log on disk, as reported by `review sessions`.
struct ReviewSessionSummary: Decodable, Equatable {
    var id: String
    var dir: String
    var file: String
    var cwd: String?
    var createdAt: Double?
    var parentSession: String?
    var delegationDepth: Int?
    var compressed: Bool
    var sizeBytes: Double
    var mtimeMs: Double

    var isSubagent: Bool { (delegationDepth ?? 0) > 0 }
}

/// Result of `review sessions`.
struct ReviewSessionsResult: Decodable, Equatable {
    var sessions: [ReviewSessionSummary]
    var total: Int?
    var diagnostics: [ReviewDiagnostic]?
}

// MARK: - Display folding

/// Files touched by one session, in first-seen order.
struct ReviewFileGroup: Equatable {
    var path: String
    var entries: [ReviewEntry]
    var added: Int
    var removed: Int
    /// True when any entry carried the full content of a file that did not exist before.
    var created: Bool
    /// True when at least one entry came from a nested run_code dispatch.
    var hasNested: Bool
    /// True when at least one entry is an applied-hunk record.
    var hasAppliedHunks: Bool
}

/// A rendered diff line (removed block first, then the added block per hunk).
struct ReviewDiffLine: Equatable {
    enum Kind: Equatable { case removed, added }
    var kind: Kind
    var text: String
}

enum ReviewLogModel {

    /// Decode the JSON emitted by `review sessions`.
    static func decodeSessions(_ json: String) -> ReviewSessionsResult? {
        decode(ReviewSessionsResult.self, from: json)
    }

    /// Decode the JSON emitted by `review audit`.
    static func decodeAudit(_ json: String) -> ReviewAudit? {
        decode(ReviewAudit.self, from: json)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        guard let data = json.data(using: .utf8), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Successful mutations of a session, in log order.
    static func mutations(_ entries: [ReviewEntry]) -> [ReviewEntry] {
        entries.filter { $0.isMutation && !$0.isError }
    }

    /// Failed mutations (recorded as attempted but not applied), in log order.
    static func failures(_ entries: [ReviewEntry]) -> [ReviewEntry] {
        entries.filter { $0.isMutation && $0.isError }
    }

    /// Shell calls, optionally only those whose command may write files.
    static func bashEntries(_ entries: [ReviewEntry], suspectOnly: Bool) -> [ReviewEntry] {
        entries.filter { $0.isBash && (!suspectOnly || $0.suspicion == "write-like") }
    }

    /// Group the successful mutations by file path with totals.
    ///
    /// Groups come back **most-recently-changed first** (git-log order): an audit
    /// opens on what the agent just did, instead of burying it under a first big
    /// file creation. Entries inside a group stay chronological.
    static func fileGroups(_ entries: [ReviewEntry]) -> [ReviewFileGroup] {
        var order: [String] = []
        var byPath: [String: ReviewFileGroup] = [:]
        for entry in mutations(entries) {
            let key = entry.path ?? entry.pathAbs ?? "?"
            if byPath[key] == nil {
                order.append(key)
                byPath[key] = ReviewFileGroup(path: key, entries: [], added: 0, removed: 0,
                                              created: false, hasNested: false, hasAppliedHunks: false)
            }
            var group = byPath[key]!
            group.entries.append(entry)
            group.added += entry.added
            group.removed += entry.removed
            group.created = group.created || entry.note == "created-content"
            group.hasNested = group.hasNested || entry.isNested
            group.hasAppliedHunks = group.hasAppliedHunks || entry.category == "diff"
            byPath[key] = group
        }
        return order.compactMap { byPath[$0] }.sorted { lhs, rhs in
            let l = lhs.entries.last?.order ?? 0
            let r = rhs.entries.last?.order ?? 0
            return l > r
        }
    }

    /// Flatten hunks into renderable lines: each hunk yields its removed block
    /// then its added block (the same two-block shape dsh's own diff card uses).
    static func diffLines(_ hunks: [ReviewHunk]) -> [ReviewDiffLine] {
        var out: [ReviewDiffLine] = []
        for hunk in hunks {
            if let old = hunk.oldText, !old.isEmpty {
                for line in old.split(separator: "\n", omittingEmptySubsequences: false) {
                    out.append(ReviewDiffLine(kind: .removed, text: String(line)))
                }
            }
            for line in hunk.newText.split(separator: "\n", omittingEmptySubsequences: false) {
                out.append(ReviewDiffLine(kind: .added, text: String(line)))
            }
        }
        return out
    }

    /// "session-74e368ee-21ee-4e99-8789-23b6c73143f9" → "74e368ee" (the short id
    /// dsh's own UI shows); anything unexpected is returned unchanged.
    static func shortId(_ id: String) -> String {
        let trimmed = id.hasPrefix("session-") ? String(id.dropFirst("session-".count)) : id
        return trimmed.count > 8 ? String(trimmed.prefix(8)) : trimmed
    }

    /// Human byte size ("1.2 MB"), used by the session picker.
    static func byteLabel(_ bytes: Double) -> String {
        if bytes >= 1024 * 1024 { return String(format: "%.1f MB", bytes / (1024 * 1024)) }
        if bytes >= 1024 { return String(format: "%.0f KB", bytes / 1024) }
        return "\(Int(bytes)) B"
    }

    /// The session picker title: short id + clock time + optional subagent mark.
    static func sessionLabel(_ session: ReviewSessionSummary) -> String {
        var label = shortId(session.id) + " · " + clockLabel(session.mtimeMs)
        if session.isSubagent { label += " · sub" }
        return label
    }

    /// "HH:mm" for a millisecond timestamp (local time).
    static func clockLabel(_ millis: Double) -> String {
        guard millis > 0 else { return "--:--" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: millis / 1000))
    }

    /// One-line audit summary, e.g. "3 files · +42 −7 · 2 nested · +5 in unrecorded bash".
    /// Numbers only — the panel supplies the localized wording.
    static func bashSummary(_ stats: ReviewStats) -> String {
        "\(stats.bashSuspect)/\(stats.bashCalls)"
    }
}
