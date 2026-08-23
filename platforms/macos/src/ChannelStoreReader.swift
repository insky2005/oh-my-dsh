import Foundation

// MARK: - Channel project-view data model (pure Foundation, headless-testable)
//
// Reads the GLOBAL channel-scoped store written by core/lib/channel-sessions.js
// (docs/channel-storage.md, implemented for D):
//   ~/.dsh/channels/<channelId>.sessions.json
//   ~/.dsh/channels/<channelId>.<workspaceKey>.<sessionId>.messages.json
//   ~/.dsh/channels/<channelId>.<workspaceKey>.system.messages.json
// No AppKit — safe to unit-test headless.

/// A message record as persisted by the channel store (dir: "in" | "out").
struct ChannelMessageVM {
    var dir: String
    var text: String
    var ts: TimeInterval
    var projectRoot: String
}

/// A session belonging to the current project, with its message history.
struct ChannelSessionVM {
    var sessionId: String
    var conversationId: String
    var projectRoot: String
    var workspaceKey: String
    var name: String
    var updatedAt: TimeInterval
    var messages: [ChannelMessageVM]
}

enum ChannelStoreReader {

    /// The global channels dir: DSH_HOME (default ~/.dsh)/channels.
    static func channelsDir(dshHome: String? = nil) -> String {
        let env = ProcessInfo.processInfo.environment["DSH_HOME"]
        let home = dshHome ?? env ?? (NSHomeDirectory() + "/.dsh")
        return (home as NSString).appendingPathComponent("channels")
    }

    /// Workspace key derivation mirroring core/lib/channel-sessions.js workspaceKey().
    /// Used only as a fallback; session records normally carry their stored workspaceKey.
    static func workspaceKey(for projectRoot: String) -> String {
        let base = (projectRoot as NSString).lastPathComponent
        guard !base.isEmpty else { return "ws" }
        var out = ""
        for scalar in base.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "." || scalar == "-"
                || (scalar.value >= 0x4E00 && scalar.value <= 0x9FA5) {
                out.append(Character(scalar))
            } else {
                out.append("-")
            }
        }
        if out.isEmpty { out = "ws" }
        if out.count > 48 { out = String(out.prefix(48)) }
        return out
    }

    /// Load the session records for a channel that belong to `projectRoot`,
    /// each hydrated with its per-session message bucket. Sorted by updatedAt desc.
    static func loadSessions(channelId: String, projectRoot: String, dshHome: String? = nil) -> [ChannelSessionVM] {
        let dir = channelsDir(dshHome: dshHome)
        let sessionsFile = (dir as NSString).appendingPathComponent(channelId + ".sessions.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: sessionsFile)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = obj["sessions"] as? [[String: Any]] else { return [] }
        var result: [ChannelSessionVM] = []
        for s in sessions {
            guard let sessionId = s["sessionId"] as? String,
                  let proj = s["projectRoot"] as? String, proj == projectRoot else { continue }
            let conversationId = s["conversationId"] as? String ?? ""
            let name = s["name"] as? String ?? conversationId
            let key = (s["workspaceKey"] as? String) ?? workspaceKey(for: projectRoot)
            let updatedAt = s["updatedAt"] as? TimeInterval ?? 0
            let messages = loadMessages(channelId: channelId, workspaceKey: key, sessionId: sessionId, dshHome: dshHome)
            result.append(ChannelSessionVM(sessionId: sessionId, conversationId: conversationId, projectRoot: proj,
                                           workspaceKey: key, name: name, updatedAt: updatedAt, messages: messages))
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Read a session's message bucket (oldest first).
    static func loadMessages(channelId: String, workspaceKey: String, sessionId: String, dshHome: String? = nil) -> [ChannelMessageVM] {
        let dir = channelsDir(dshHome: dshHome)
        let fileName = channelId + "." + workspaceKey + "." + sessionId + ".messages.json"
        let file = (dir as NSString).appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = obj["messages"] as? [[String: Any]] else { return [] }
        return messages.compactMap { m in
            guard let text = m["text"] as? String else { return nil }
            return ChannelMessageVM(dir: m["dir"] as? String ?? "", text: text,
                                    ts: m["ts"] as? TimeInterval ?? 0,
                                    projectRoot: m["projectRoot"] as? String ?? "")
        }.sorted { $0.ts < $1.ts }
    }
}
