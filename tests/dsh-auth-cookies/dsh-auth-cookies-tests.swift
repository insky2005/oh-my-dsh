import Foundation

// Headless tests for DshWebCookieJanitor / DshWebServerOptions — dsh's cookie
// naming, stale-cookie selection (startup / exit) and the node header-cap
// seatbelt. Pure logic only: no AppKit, no WKWebsiteDataStore, no running dsh.

var failures = 0
func check(_ ok: Bool, _ label: String) {
    if ok { print("ok  - \(label)") } else { failures += 1; print("FAIL- \(label)") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ label: String) {
    check(a == b, "\(label) (got \(a), want \(b))")
}

// MARK: - dsh's derivation, pinned to cookies that really exist

// These names were read out of
// ~/Library/HTTPStorages/com.ohmydsh.app.dev.binarycookies (68 cookies) and
// .../com.ohmydsh.app.binarycookies (2 cookies) after real launches — the
// authority in each name is the one dsh signed into the matching cookie value.
eq(DshWebCookieJanitor.cookieName(forAuthority: "127.0.0.1:54728"),
   "dsh-auth-ti0qeqg2eUkrh_KqvYum53uG3E_xoqw9qnlGM49dd4g",
   "name matches a real dev-instance cookie")
eq(DshWebCookieJanitor.cookieName(forAuthority: "127.0.0.1:3080"),
   "dsh-auth-VPhEEcLKeqRDBoBalzN2Nm7CnfxKhLE00pKIDWxt1sw",
   "name matches the release app's 3080 cookie")
eq(DshWebCookieJanitor.cookieName(forAuthority: DshWebCookieJanitor.authority(port: 64690)),
   "dsh-auth-sa_sbeM50lcoQa-doJt0ZxwPcJhk8581AtmVseTse3k",
   "authority(port:) is 127.0.0.1:<port> and feeds the same derivation")
eq(DshWebCookieJanitor.authority(port: 3080), "127.0.0.1:3080", "authority(port:) shape")

let sample = DshWebCookieJanitor.cookieName(forAuthority: "127.0.0.1:1")
eq(sample.count, DshWebCookieJanitor.prefix.count + 43, "sha256 -> 43 base64url chars")
check(!sample.contains("=") && !sample.contains("+") && !sample.contains("/"),
      "cookie name stays cookie-safe (unpadded base64url)")
check(sample.hasPrefix("dsh-auth-"), "cookie name keeps dsh's prefix")

// MARK: - selection: what the purges delete

let current = DshWebCookieJanitor.cookieName(forAuthority: "127.0.0.1:64690")
let older = DshWebCookieJanitor.cookieName(forAuthority: "127.0.0.1:54728")

eq(DshWebCookieJanitor.namesToPurge([older, current], keeping: "127.0.0.1:64690"),
   [older], "startup drops a foreign authority, keeps the one we load")
eq(DshWebCookieJanitor.namesToPurge([older, current], keeping: nil),
   [older, current], "exit drops our cookies (current one included)")
eq(DshWebCookieJanitor.namesToPurge(["session", "sid", "dsh-auth-not-ours"], keeping: "127.0.0.1:64690"),
   ["dsh-auth-not-ours"], "non-dsh cookies are never touched")
eq(DshWebCookieJanitor.namesToPurge(["dsh-auth-"], keeping: nil),
   ["dsh-auth-"], "prefix-only name still counts as ours")
eq(DshWebCookieJanitor.namesToPurge([], keeping: "127.0.0.1:64690"), [], "empty store stays empty")
eq(DshWebCookieJanitor.namesToPurge([current], keeping: "127.0.0.1:64690"), [],
   "the current instance's cookie survives a mid-session reload")

// The exact pile that broke the app (68 launches -> HTTP 431 for the plugin batch).
let pile = (50000...50067).map { DshWebCookieJanitor.cookieName(forAuthority: "127.0.0.1:\($0)") }
eq(DshWebCookieJanitor.namesToPurge(pile, keeping: nil).count, 68,
   "a 68-launch pile purges completely on exit")
let startupPurge = DshWebCookieJanitor.namesToPurge(pile, keeping: "127.0.0.1:50000")
eq(startupPurge.count, 67, "startup purges every instance but the one about to be loaded")
check(!startupPurge.contains(pile[0]) && startupPurge.contains(pile[67]),
      "the kept name is the current authority's, everything else goes")
check(Set(pile).count == 68, "every authority mints a distinct name (never overwrites)")

// MARK: - node header-cap seatbelt

eq(DshWebServerOptions.appendingHeaderLimit(to: nil),
   "--max-http-header-size=65536", "adds the flag when NODE_OPTIONS is unset")
eq(DshWebServerOptions.appendingHeaderLimit(to: "   "),
   "--max-http-header-size=65536", "blank NODE_OPTIONS counts as unset")
eq(DshWebServerOptions.appendingHeaderLimit(to: "--enable-source-maps"),
   "--enable-source-maps --max-http-header-size=65536", "appends to the user's NODE_OPTIONS")
eq(DshWebServerOptions.appendingHeaderLimit(to: "--max-http-header-size=8192"),
   "--max-http-header-size=8192", "an explicit limit is left alone (never duplicated)")
eq(DshWebServerOptions.appendingHeaderLimit(to: "--max-http-header-size 8192"),
   "--max-http-header-size 8192", "space-separated form is recognised too")

if failures > 0 {
    print("\n\(failures) failure(s)")
    exit(1)
}
print("\nall dsh auth-cookie janitor tests passed")
