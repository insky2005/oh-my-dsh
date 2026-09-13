import Foundation
import WebKit
import CryptoKit

// MARK: - dsh web browser-cookie janitor
//
// dsh >= 0.1.2 authenticates the browser session with a cookie minted from the
// per-instance launch token (`GET /?token=<token>` -> 303 + `Set-Cookie`). The
// cookie NAME is derived from the request authority
// (@deepseek-ai/dsh-client-connection, `cookieName()`):
//
//     cookieName(authority) = "dsh-auth-" + base64url(sha256(authority))
//     authority             = "127.0.0.1:<port>"        // the Host of that instance
//
// Cookies are keyed by (domain, path) and IGNORE the port, so every instance
// this app talks to lands in the SAME cookie list of the SAME WKWebView data
// store — and because the name carries the authority, a new port mints a NEW
// cookie instead of overwriting the previous one. The shell spawns a fresh dsh
// web on a new random port on every launch, so the list only ever grows: one
// ~226-byte cookie per launch, each with a 30-day TTL (measured: 68 of them).
//
// That is fatal for exactly one request. The client-modules "application" batch
// the browser loads at startup is a single ~2.1 KB combo URL (45 plugin ids in
// one path), while node's default HTTP header cap is 16 KiB. Once the
// accumulated `Cookie:` header passes ~14.1 KB — 63 cookies — request line +
// cookie header exceed the cap and node answers `431 Request Header Fields Too
// Large` with an empty body. The `<script src>` of the plugin bundle then fires
// its `error` event (not a JS exception), client-modules reports
//
//     client-modules: bundle script /plugins/??…&rev=… failed to load
//
// and the UI shows "Failed to load plugins" — while the short bootstrap URL
// (~80 B) right next to it still returns 200, so the app shell renders and only
// the plugins are missing. Reproduced end to end: 62 cookies -> 200,
// 63 cookies -> 431; a fresh data store (1 cookie) -> 200.
//
// The fix is to stop accumulating: keep the current instance's cookie and drop
// the ones whose authority this app can never talk to again (startup, before
// the page load), then drop our own on the way out. Both purges only ever touch
// `dsh-auth-*`: UI state lives in localStorage, dsh's sessions/workspaces live
// in $DSH_HOME, the shell's own settings in $DSH_HOME/shell/config.json, and the
// CEF browser panel has a cookie store of its own — none of it is affected.
//
// Docs: docs/dsh-version-impact.md (R6).

enum DshWebCookieJanitor {

    /// dsh's `COOKIE_PREFIX` — every browser-session cookie it mints.
    static let prefix = "dsh-auth-"

    /// The shell only ever loads `http://127.0.0.1:<port>/`, so the Host (and
    /// therefore dsh's authority) is exactly this. Switching the WebView to
    /// `localhost` would mint a different cookie family — keep them in sync.
    static func authority(port: Int) -> String { "127.0.0.1:\(port)" }

    /// dsh's derivation, reproduced: `"dsh-auth-" + base64url(sha256(authority))`.
    static func cookieName(forAuthority authority: String) -> String {
        prefix + base64URL(Data(SHA256.hash(data: Data(authority.utf8))))
    }

    /// Cookie-safe, unpadded base64url — `=`/`+`/`/` are not valid in a cookie name.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The cookies to delete. Only `dsh-auth-*` names are ever candidates;
    /// everything else in the store belongs to the page or the user.
    ///
    /// - `keeping: "127.0.0.1:<port>"` (startup) — every foreign authority goes,
    ///   the one we are about to load stays (a mid-session reload of the
    ///   tokenless `webView.url` must not lose its credential).
    /// - `keeping: nil` (exit) — all of ours go.
    static func namesToPurge(_ names: [String], keeping authority: String?) -> [String] {
        let keep = authority.map(cookieName(forAuthority:))
        return names.filter { $0.hasPrefix(prefix) && $0 != keep }
    }

    // MARK: - WKWebView glue

    /// Startup: drop the stale cookies before the entry URL is loaded. Async —
    /// the page load mints the fresh cookie for the current authority, and the
    /// purge only ever targets OTHER names, so the two cannot race.
    static func purgeStale(keeping authority: String,
                           store: WKWebsiteDataStore = .default(),
                           log: @escaping (String) -> Void) {
        purge(keeping: authority, store: store) { removed, total in
            if removed == 0 {
                log("dsh cookies: nothing stale (\(total) total, kept \(authority))")
            } else {
                log("dsh cookies: purged \(removed) stale of \(total) (kept \(authority))")
            }
        }
    }

    /// Exit: drop every `dsh-auth-*` cookie this app minted, then wait (pumping
    /// the run loop, so WebKit's main-queue callbacks can land) for up to
    /// `timeout`. Best effort by design — the startup purge is the guarantee.
    @discardableResult
    static func purgeAll(timeout: TimeInterval = 1.5,
                         store: WKWebsiteDataStore = .default(),
                         log: @escaping (String) -> Void) -> Int {
        var removed = -1
        var total = 0
        purge(keeping: nil, store: store) { count, seen in removed = count; total = seen }
        let deadline = Date().addingTimeInterval(timeout)
        while removed < 0 && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        log(removed < 0
            ? "dsh cookies: exit purge timed out after \(timeout)s"
            : "dsh cookies: purged \(removed) on exit (\(total) total)")
        return max(removed, 0)
    }

    private static func purge(keeping authority: String?,
                              store: WKWebsiteDataStore,
                              completion: @escaping (Int, Int) -> Void) {
        let cookieStore = store.httpCookieStore
        cookieStore.getAllCookies { cookies in
            let doomed = Set(namesToPurge(cookies.map(\.name), keeping: authority))
            let targets = cookies.filter { doomed.contains($0.name) }
            guard !targets.isEmpty else { completion(0, cookies.count); return }
            let group = DispatchGroup()
            for cookie in targets {
                group.enter()
                cookieStore.delete(cookie) { group.leave() }
            }
            group.notify(queue: .main) { completion(targets.count, cookies.count) }
        }
    }
}

/// The server-side half of the same header budget: node's 16 KiB default HTTP
/// header cap is what turns a stale cookie pile into "Failed to load plugins"
/// (the plugin-batch URL alone is 2.1 KB). The janitor above is the actual fix;
/// this is the seatbelt for every other way the header could grow.
enum DshWebServerOptions {

    static let maxHeaderSizeFlag = "--max-http-header-size=65536"

    /// Add `--max-http-header-size` unless NODE_OPTIONS already sets one (the
    /// user's environment wins — we never fight or duplicate an explicit value,
    /// which node would parse in an order-dependent way).
    static func appendingHeaderLimit(to options: String?) -> String {
        let existing = (options ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if existing.contains("--max-http-header-size") { return existing }
        return existing.isEmpty ? maxHeaderSizeFlag : existing + " " + maxHeaderSizeFlag
    }
}
