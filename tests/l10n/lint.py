#!/usr/bin/env python3
"""L10n key lint for the macOS shell (platforms/macos/src).

`L10n.tr(key)` falls back to the KEY ITSELF when it is missing from
`L10n.table` (`table[key] ?? (key, key)`), so a stale key ships as literal
button text — e.g. a "preview.switchDiscard" button after that key was renamed.
This lint makes the class of bug impossible:

  * FAIL: a literal `L10n.tr("…")` key that is not in the table;
  * FAIL: a duplicate key in the table;
  * FAIL: an entry whose Chinese or English string is empty (the table is meant
    to be bilingual, see AGENTS.md);
  * WARN: a table key no source literal ever references (keys may be assembled
    at runtime, e.g. ChannelPanel's wizardL10n appends ".dingtalk", so this is
    informational only).

Usage: tests/l10n/lint.py [src_dir]   (default: platforms/macos/src)
"""
import pathlib
import re
import sys

SRC = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "platforms/macos/src")
MAIN = SRC / "main.swift"

STRING = r'"(?:[^"\\]|\\.)*"'
ENTRY = re.compile(r'("' + r'(?:[^"\\]|\\.)*' + r'")\s*:\s*\(\s*(' + STRING + r')\s*,\s*(' + STRING + r')\s*\)', re.S)
KEY = re.compile(r'(' + STRING + r')\s*:\s*\(', re.S)
TR_LITERAL = re.compile(r'L10n\.tr\(\s*(' + STRING + r')')
ANY_LITERAL = re.compile(STRING)


def unquote(text):
    return text[1:-1].replace('\\"', '"').replace("\\\\", "\\")


def table_region(text):
    """The `static let table` dictionary literal (bracket-balanced)."""
    start = text.index("static let table")
    # Skip the type annotation's "[" — the literal starts after the "=".
    open_at = text.index("[", text.index("=", start))
    depth = 0
    for i in range(open_at, len(text)):
        if text[i] == "[":
            depth += 1
        elif text[i] == "]":
            depth -= 1
            if depth == 0:
                return text[open_at:i + 1]
    raise SystemExit("l10n-lint: could not find the end of L10n.table")


def main():
    region = table_region(MAIN.read_text(encoding="utf-8"))
    entries = [(unquote(k), unquote(zh), unquote(en)) for k, zh, en in ENTRY.findall(region)]
    keys = {k for k, _, _ in entries}
    loose_keys = {unquote(m) for m in KEY.findall(region)}

    sources = sorted(SRC.glob("*.swift"))
    used, referenced = set(), set()
    for path in sources:
        text = path.read_text(encoding="utf-8")
        if path == MAIN:
            # The table itself defines the keys — it is not a usage site.
            text = text.replace(region, "")
        used |= {unquote(m) for m in TR_LITERAL.findall(text)}
        referenced |= {unquote(m) for m in ANY_LITERAL.findall(text)}

    # Entries whose strings are built by concatenation (e.g. "about.credits")
    # are only visible to the loose key scan — use both so they are never
    # reported as missing.
    known = keys | loose_keys

    failures = []
    missing = sorted(used - known)
    if missing:
        failures.append("L10n.tr keys missing from L10n.table: " + ", ".join(missing))

    seen = {}
    for k, _, _ in entries:
        seen[k] = seen.get(k, 0) + 1
    duplicates = sorted(k for k, n in seen.items() if n > 1)
    if duplicates:
        failures.append("duplicate keys in L10n.table: " + ", ".join(duplicates))

    empty = sorted(k for k, zh, en in entries if not zh or not en)
    if empty:
        failures.append("entries missing a Chinese or English string: " + ", ".join(empty))

    unparsed = sorted(loose_keys - keys)
    if unparsed:
        print("note: %d table key(s) build their strings by concatenation, so value "
              "checks skip them: %s" % (len(unparsed), ", ".join(unparsed)))

    unused = sorted(keys - referenced)
    if unused:
        print("warn: %d table key(s) no source literal references "
              "(may be built at runtime): %s" % (len(unused), ", ".join(unused)))

    if failures:
        for f in failures:
            print("FAIL - " + f)
        return 1
    print("ok - %d table key(s), %d referenced by L10n.tr() in %d source file(s)"
          % (len(keys), len(used), len(sources)))
    return 0


sys.exit(main())
