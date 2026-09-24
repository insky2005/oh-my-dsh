import Foundation

// Minimal stand-ins for the shell types the task logic leans on, so the model
// and runner can be compiled and driven headlessly. Everything the panel must
// get right (task/queue rules, branch naming, persistence, the run pipeline) is
// the real code; only the shell globals are faked.

enum L10n {
    /// Returns the key itself (plus its arguments), so assertions read like the
    /// label semantics ("tasks.card.queuedAt(2)") instead of localized prose.
    static func tr(_ key: String, _ args: CVarArg...) -> String {
        guard !args.isEmpty else { return key }
        return key + "(" + args.map { "\($0)" }.joined(separator: ",") + ")"
    }
}
