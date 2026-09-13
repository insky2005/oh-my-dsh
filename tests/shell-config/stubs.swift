// Minimal stubs for the ShellConfig unit tests: the class logs through AppLog
// and delegates writes to the bundled core CLI (CoreBridge) — neither exists
// headless, and the tests only exercise the read/migrate path.

import Foundation

final class AppLog {
    static let shared = AppLog()
    private(set) var lines: [String] = []
    func log(_ msg: String) { lines.append(msg) }
}

enum CoreBridge {
    /// nil = core CLI unavailable → ShellConfig falls back to a direct atomic
    /// write (the path the migration itself uses).
    static func run(_ args: [String], timeout: TimeInterval = 15) -> String? { nil }
}
