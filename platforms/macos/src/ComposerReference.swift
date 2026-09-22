import Foundation

// MARK: - Files panel → dsh composer reference (@path)
//
// dsh web's composer resolves an `@` token against the SESSION's working
// directory, so a mention must be written WORKSPACE-RELATIVE. The grammar is
// dsh's own (mirrored in @deepseek-ai/dsh-file-reference/grammar and in the web
// client, so composer, terminal and file-reference discovery agree):
//
//   * `@src/foo.ts`            a file;
//   * `@src/`                  a DIRECTORY (a trailing slash marks it);
//   * `@"my dir/foo.txt"`      whitespace forces the quoted form;
//   * `@"my dir/`              a quoted directory keeps its quote OPEN — dsh
//                              never closes a quote that file completion would
//                              have left open for drilling deeper;
//   * a path the grammar cannot represent (an embedded quote, control
//     characters, or the workspace root itself — there is no relative path to
//     name) has NO mention at all rather than a broken token.
//
// Pure Foundation on purpose: the menu rules and this formatting are unit-tested
// headlessly (tests/file-panel), while FilePanelController only turns a
// Mention into a menu action and AppDelegate only injects it.

/// One path as the composer should receive it.
struct ComposerReference: Equatable {
    /// The prompt token, e.g. `@src/foo.ts` — what the model reads.
    let text: String
    /// Inline chip label, e.g. `foo.ts` (a directory keeps its bare name).
    let label: String
    /// Chip glyph kind: "file" or "folder" (dsh's own appearance vocabulary).
    let appearance: String
}

enum ComposerReferenceFormatter {

    /// The mention for `path` seen from the workspace root `root`.
    /// - Returns: nil when `path` is outside/equal to `root`, or the relative
    ///   path cannot be expressed in the `@` grammar.
    static func mention(path: String, root: String, isDirectory: Bool) -> ComposerReference? {
        guard let relative = relativePath(path: path, root: root) else { return nil }
        return mention(relativePath: relative, isDirectory: isDirectory)
    }

    /// The mention for an already-relative path ("" is the root itself → nil).
    static func mention(relativePath raw: String, isDirectory: Bool) -> ComposerReference? {
        var relative = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while relative.hasSuffix("/") { relative.removeLast() }
        relative = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty else { return nil }
        // Characters the `@"…"` grammar cannot carry, and the ones a stray
        // newline would break the surrounding draft with.
        guard !relative.unicodeScalars.contains(where: { unusable($0) }) else { return nil }

        let path = isDirectory ? relative + "/" : relative
        let needsQuote = path.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
        let text: String
        if !needsQuote {
            text = "@" + path
        } else if isDirectory {
            text = "@\"" + path           // open quote: more drilling may follow
        } else {
            text = "@\"" + path + "\""
        }
        let label = (relative as NSString).lastPathComponent
        guard !label.isEmpty else { return nil }
        return ComposerReference(text: text, label: label, appearance: isDirectory ? "folder" : "file")
    }

    /// `path` relative to `root`, or nil when it is not strictly inside it.
    /// Paths are standardized first (trailing slashes, `.`/`..`), never
    /// symlink-resolved: the tree hands us both ends of the same walk.
    static func relativePath(path: String, root: String) -> String? {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        let base = URL(fileURLWithPath: root).standardizedFileURL.path
        guard !base.isEmpty, base != "/" else { return nil }
        if target == base { return nil }                       // the root itself
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard target.hasPrefix(prefix) else { return nil }     // outside the root
        let relative = String(target.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
    }

    /// Whether one scalar makes a path unrepresentable in the `@` grammar.
    private static func unusable(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\"" { return true }
        if scalar.value < 0x20 { return true }                 // C0 controls, incl. \n
        if scalar.value >= 0x7F && scalar.value <= 0x9F { return true }
        return false
    }
}
