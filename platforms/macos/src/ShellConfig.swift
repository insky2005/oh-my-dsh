import Foundation

/// Language-agnostic shell settings, persisted as plain JSON at
/// `$DSH_HOME/shell/config.json` (canonical implementation + CLI live in the
/// shared core: core/lib/settings.js / `ohmy-core settings …`).
///
/// Any language can read that file. To keep a single implementation of the
/// write/merge/atomic semantics, mutations are delegated to the core CLI, but
/// **coalesced + off the main thread** (a 0.3s debounce) so high-frequency
/// updates (e.g. panel resizing) never spawn a subprocess per event nor block
/// the UI. A direct atomic write is the fallback if the core is unavailable.
/// Reads go straight to the JSON file (fast, no subprocess).
///
/// Same surface as UserDefaults for a drop-in swap on owned keys:
/// object/string/bool/double/array/data(forKey:), set(_:forKey:),
/// removeObject(forKey:).
final class ShellConfig {
    static let shared = ShellConfig()

    private let lock = NSLock()
    private var cache: [String: Any] = [:]
    /// The file path the cache was loaded from. Tracked (not a plain bool) so a
    /// later DSH_HOME change (dev isolation is injected at launch) triggers a
    /// reload instead of permanently serving an empty cache loaded from the
    /// wrong home.
    private var loadedPath: String?
    private var dirty = Set<String>()
    private var pending: DispatchWorkItem?
    private let persistQueue = DispatchQueue(label: "com.ohmydsh.shellconfig.persist")

    /// Resolved dsh home ($DSH_HOME or ~/.dsh) — dev builds use ~/.dsh-dev.
    private var home: String {
        if let h = ProcessInfo.processInfo.environment["DSH_HOME"],
           !h.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return h.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".dsh")
    }

    var filePath: String {
        ((home as NSString).appendingPathComponent("shell") as NSString).appendingPathComponent("config.json")
    }

    private func loadIfNeeded() {
        let path = filePath
        if loadedPath == path { return }
        loadedPath = path
        cache = [:]
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        cache = obj
    }

    private func stored(_ key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return cache[key]
    }

    // MARK: reads (UserDefaults-compatible)

    func object(forKey key: String) -> Any? { stored(key) }
    func string(forKey key: String) -> String? { stored(key) as? String }
    func bool(forKey key: String) -> Bool { (stored(key) as? Bool) ?? false }
    func double(forKey key: String) -> Double {
        if let d = stored(key) as? Double { return d }
        if let n = stored(key) as? NSNumber { return n.doubleValue }
        return 0
    }
    func array(forKey key: String) -> [Any]? { stored(key) as? [Any] }

    /// JSON-encoded bytes of the stored value (compat with the legacy
    /// data-based `channel.global.list` read path).
    func data(forKey key: String) -> Data? {
        guard let v = stored(key) else { return nil }
        return try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed])
    }

    // MARK: writes (delegated to the shared core CLI, coalesced)

    func set(_ value: Any, forKey key: String) {
        var v = value
        if let d = value as? Data, let decoded = try? JSONSerialization.jsonObject(with: d) { v = decoded }
        lock.lock(); loadIfNeeded(); cache[key] = v; dirty.insert(key); lock.unlock()
        schedulePersist()
    }

    func removeObject(forKey key: String) {
        lock.lock(); loadIfNeeded(); cache.removeValue(forKey: key); dirty.insert(key); lock.unlock()
        schedulePersist()
    }

    /// Persist immediately (e.g. on app termination). Safe to call anytime.
    func flushNow() {
        lock.lock(); pending?.cancel(); pending = nil; lock.unlock()
        flush()
    }

    private func schedulePersist() {
        lock.lock(); pending?.cancel(); lock.unlock()
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        lock.lock(); pending = item; lock.unlock()
        persistQueue.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func flush() {
        lock.lock()
        let keys = dirty
        dirty.removeAll()
        let snapshot = cache
        lock.unlock()
        guard !keys.isEmpty else { return }

        // Delegate to the canonical core writer, one call per changed key.
        var coreOK = true
        for key in keys {
            guard let v = snapshot[key], let js = Self.jsonString(v) else { continue }
            if CoreBridge.run(["settings", "set", key, js]) == nil { coreOK = false; break }
        }
        if !coreOK {
            AppLog.shared.log("shellconfig: core persist failed; direct write fallback (\(keys.count) keys)")
            writeFileFallback(snapshot)
        }
    }

    private func writeFileFallback(_ snapshot: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) else { return }
        let dir = (filePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
    }

    private static func jsonString(_ v: Any) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]) else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
