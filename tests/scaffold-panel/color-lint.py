#!/usr/bin/env python3
"""配色 lint for the Scaffold panel (platforms/macos/src/ScaffoldPanel.swift).

docs/ui-color-scheme.md makes PanelSurface.swift the single source of truth for
every surface color: the panel surface (one step) and the interactive controls
(two steps). A panel that hardcodes its own grays drifts away silently — the
scaffold panel did exactly that (calibratedWhite 0.22/0.28/0.33/0.94/0.97 …).

This lint keeps the rule enforceable:

  * FAIL: a hardcoded grayscale outside ScaffoldColorScheme (every NSColor(white:)
    literal must live in that one table);
  * FAIL: calibratedWhite anywhere (new steps must come from PanelSurface);
  * FAIL: the table no longer resolves its fills through PanelSurface / PanelControl.

Usage: tests/scaffold-panel/color-lint.py [source_file]
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]   # 仓库根（本文件在 tests/scaffold-panel/）
SRC = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "platforms/macos/src/ScaffoldPanel.swift"
TABLE = "enum ScaffoldColorScheme {"

def table_span(lines):
    start = next((i for i, l in enumerate(lines) if l.startswith(TABLE)), None)
    if start is None:
        return None
    end = next((i for i in range(start + 1, len(lines)) if lines[i] == "}"), None)
    return None if end is None else (start, end)

def main():
    lines = SRC.read_text(encoding="utf-8").splitlines()
    span = table_span(lines)
    failures = []
    if span is None:
        failures.append("找不到 ScaffoldColorScheme 取色表（%s）" % SRC)
        span = (0, -1)
    start, end = span

    outside = [i + 1 for i, l in enumerate(lines)
               if "NSColor(white:" in l and not (start <= i <= end)]
    if outside:
        failures.append("写死的灰度在 ScaffoldColorScheme 之外（行 %s）——"
                        "表面色请用 PanelSurface / PanelControl，ink 档位加进取色表"
                        % ", ".join(str(n) for n in outside))

    calibrated = [i + 1 for i, l in enumerate(lines) if "calibratedWhite" in l]
    if calibrated:
        failures.append("出现 calibratedWhite（行 %s）——需要新档位请从 "
                        "docs/ui-color-scheme.md §2.2 的灰阶里挑，或加进 PanelSurface.swift"
                        % ", ".join(str(n) for n in calibrated))

    body = "\n".join(lines[start:end + 1])
    for token in ("PanelSurface.", "PanelControl."):
        if token not in body:
            failures.append("取色表没有走 %s（表面色必须来自共享令牌）" % token)

    if failures:
        for f in failures:
            print("FAIL - " + f)
        return 1
    print("ok - 脚手架面板取色表：%d-%d 行，表面色走 PanelSurface / PanelControl，无写死灰度"
          % (start + 1, end + 1))
    return 0

sys.exit(main())
