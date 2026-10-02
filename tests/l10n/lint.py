#!/usr/bin/env python3
"""L10n key lint for the macOS shell (platforms/macos/src).

`L10n.tr(key)` falls back to the KEY ITSELF when it is missing from
`L10n.table` (`table[key] ?? (key, key)`), so a stale key ships as literal
button text — e.g. a "preview.switchDiscard" button after that key was renamed.
This lint makes the class of bug impossible:

  * FAIL: a literal `L10n.tr("…")` key that is not in the table;
  * FAIL: a key handed to the UI AS DATA — the view models carry keys in
    `primaryKey` / `stateKey` / `messageKey` / `headingKey` / `submitKey` /
    `infoKey` / `problemKey` / `problem` / `key` and the views call `L10n.tr`
    on them later, so the old check could not see a missing one. That is how
    `tasks.queue.add` shipped as a raw key on the card's primary button;
  * FAIL: a duplicate key in the table;
  * FAIL: an entry whose Chinese or English string is empty (the table is meant
    to be bilingual, see AGENTS.md);
  * FAIL: Chinese and English format arguments that disagree — a reordered `%@`
    / `%d` (or a wrong type) makes `String(format:)` read the wrong CVarArg and
    can crash the shell (see tasks.apiQueueAppended);
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

# 模型层里「值就是 L10n key」的槽位：视图只负责把模型里的 key 交给 L10n.tr()，
# 因此这些槽位里的字面量同样是「必须存在于表里」的 key。
NAMED_KEY_SLOTS = ("primaryKey", "stateKey", "messageKey", "headingKey", "submitKey",
                   "infoKey", "problemKey", "problem", "key")
NAMED_KEY = re.compile(r'\b(' + "|".join(NAMED_KEY_SLOTS) + r')\s*[:=]\s*(' + STRING + r')')
# L10n key 的形状：全小写、点分（UserDefaults 的 "channel.global.list" 也长这样，
# 但它不出现在上面这些槽位里；"terminal.autoCopy" 这类带大写的则直接排除）。
L10N_SHAPE = re.compile(r'^[a-z][a-z0-9]*(\.[a-z0-9]+)+$')


def unquote(text):
    return text[1:-1].replace('\\"', '"').replace("\\\\", "\\")


FORMAT_SPEC = re.compile(r'%(?:(\d+)\$)?([@dD])')


def format_slots(text):
    """Map each format argument (1-based) to its conversion letter.

    `%@` is an object and `%d` an integer. L10n.tr() forwards ONE shared
    `arguments:` list to whichever language string is active, so both
    languages must agree on the type of every argument slot. Reordering is
    safe only with explicit positions (`%1$@` / `%2$d`); mixing positional and
    implicit specifiers is undefined, so return None for that.
    """
    slots, next_slot = {}, 1
    positional = implicit = False
    for m in FORMAT_SPEC.finditer(text):
        explicit, conv = m.group(1), m.group(2)
        if explicit is not None:
            slot, positional = int(explicit), True
        else:
            slot, next_slot, implicit = next_slot, next_slot + 1, True
        slots[slot] = "?" if slots.get(slot, conv) != conv else conv
    if positional and implicit:
        return None
    return slots


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

    # A literal inside string interpolation (e.g. "\(L10n.tr(\"a.b\"))") can hide
    # from the plain string scan, so anything used through L10n.tr() also counts
    # as referenced — otherwise the "unused key" warning would mislead.
    referenced |= used

    failures = []
    missing = sorted(used - known)
    if missing:
        failures.append("L10n.tr keys missing from L10n.table: " + ", ".join(missing))

    # Keys the models hand to the views as data (see NAMED_KEY above).
    named_missing = {}
    for path in sources:
        text = path.read_text(encoding="utf-8")
        if path == MAIN:
            text = text.replace(region, "")
        for slot, literal in NAMED_KEY.findall(text):
            key = unquote(literal)
            if L10N_SHAPE.match(key) and key not in known:
                named_missing.setdefault(key, set()).add(path.name + ":" + slot)
    if named_missing:
        failures.append("keys carried by the view models but missing from L10n.table: "
                        + ", ".join("%s (%s)" % (k, "; ".join(sorted(v)))
                                    for k, v in sorted(named_missing.items())))

    seen = {}
    for k, _, _ in entries:
        seen[k] = seen.get(k, 0) + 1
    duplicates = sorted(k for k, n in seen.items() if n > 1)
    if duplicates:
        failures.append("duplicate keys in L10n.table: " + ", ".join(duplicates))

    empty = sorted(k for k, zh, en in entries if not zh or not en)
    if empty:
        failures.append("entries missing a Chinese or English string: " + ", ".join(empty))

    format_mismatch = []
    mixed_positions = []
    for k, zh, en in entries:
        zh_slots, en_slots = format_slots(zh), format_slots(en)
        if zh_slots is None or en_slots is None:
            mixed_positions.append(k)
        elif zh_slots != en_slots:
            format_mismatch.append(k)
    if mixed_positions:
        failures.append("entries mixing positional and implicit format specifiers: "
                        + ", ".join(sorted(mixed_positions)))
    if format_mismatch:
        failures.append("Chinese/English format arguments disagree (order or type) — "
                        "String(format:) reads the wrong CVarArg and can crash: "
                        + ", ".join(sorted(format_mismatch)))

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
