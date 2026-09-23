#!/usr/bin/env python3
"""Guard the JavaScript the shell injects into dsh web (WKUserScript / evaluateJavaScript).

Why this exists: every bridge is a Swift multi-line string literal holding JS that
only ever runs inside dsh web. A syntax error — most famously a lone backslash
Swift eats before the page ever sees it — makes the bridge silently never install,
and the only symptom is a panel button that does nothing.

Three checks:
  1. every injected script parses as JavaScript (node --check);
  2. every window.__dshX the Swift side names is assigned by some script, so a
     renamed or forgotten bridge fails here instead of in the UI;
  3. no injected script contains a backslash escape sequence (Swift eats a lone
     one, and the page then gets a broken string literal — the convention is to
     match characters by code, e.g. String.fromCharCode(10) for a newline).

Usage: python3 tests/injected-scripts/check.py platforms/macos/src
"""
import re, subprocess, sys, tempfile, pathlib

SCRIPT_RE = re.compile(r'private static let (\w+Script)\s*=\s*"""\n(.*?)\n    """', re.S)
BRIDGE_DEF_RE = re.compile(r'window\.(__dsh\w+)\s*=')
BRIDGE_REF_RE = re.compile(r'window\.(__dsh\w+)')
ESCAPE_RE = re.compile(r"\\[A-Za-z0-9]")

def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "platforms/macos/src"
    files = sorted(pathlib.Path(root).glob("*.swift"))
    if not files:
        print("FAIL no Swift sources under " + root)
        return 1

    failures = []
    scripts = {}
    for path in files:
        for name, body in SCRIPT_RE.findall(path.read_text()):
            scripts.setdefault(name, (path, body))
    if not scripts:
        print("FAIL no injected scripts found under " + root)
        return 1

    # A bridge may be installed by an injected script OR by an inline JS snippet
    # the shim evaluates (the QA probes do the latter) — both are assignments in
    # the Swift text, so the whole source is the definition set.
    installed = set()
    for path in files:
        installed.update(BRIDGE_DEF_RE.findall(path.read_text()))

    for name, (path, body) in sorted(scripts.items()):
        with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as fh:
            fh.write(body)
            tmp = fh.name
        checked = subprocess.run(["node", "--check", tmp], capture_output=True, text=True)
        pathlib.Path(tmp).unlink()
        if checked.returncode != 0:
            failures.append("%s: %s does not parse:\n%s" % (path.name, name, checked.stderr.strip()))
        else:
            print("ok   %s: %s parses (%d bytes)" % (path.name, name, len(body)))
        for escape in sorted(set(ESCAPE_RE.findall(body))):
            failures.append("%s: %s contains %r — Swift strips the backslash (use charCodeAt/fromCharCode)"
                            % (path.name, name, escape))

    referenced = set()
    for path in files:
        referenced.update(BRIDGE_REF_RE.findall(path.read_text()))
    for bridge in sorted(referenced):
        if bridge in installed:
            print("ok   window.%s is installed by a script or snippet" % bridge)
        else:
            failures.append("window.%s is named by the shim but no injected script assigns it" % bridge)

    for line in failures:
        print("FAIL " + line)
    print("injected-script checks %s (%d script(s), %d bridge(s))"
          % ("passed" if not failures else "FAILED", len(scripts), len(referenced)))
    return 1 if failures else 0

if __name__ == "__main__":
    sys.exit(main())
