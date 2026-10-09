#!/usr/bin/env python3
"""Gate of Immuch360 Desktop: every Platform.isAndroid and Platform.isIOS line of the app has a verdict.

mobile/lib/desktop/platform/PLATFORM-AUDIT.md gives one row per line of mobile/lib that tests Platform.isAndroid or
Platform.isIOS (CurrentPlatform's getters included), saying what the computers do there. This check counts those
lines per file, as the audit's own `git grep` does, and fails when a file has more of them than the table has rows
for it: a line added by an upstream merge or by the desktop work has not been read for the computers yet. Counts are
per file because line numbers move; lib/desktop and generated files are left out, as in the table.

  check_platform_audit.py   exit 1 when a file has a platform line without a row in the table

--root and --audit point at another tree and table (the tests use fixtures).
"""
from __future__ import annotations

import argparse
import collections
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
AUDIT = pathlib.PurePosixPath('mobile/lib/desktop/platform/PLATFORM-AUDIT.md')
GENERATED = ('.g.dart', '.freezed.dart', '.drift.dart', '.gr.dart', '.steps.dart')
PLATFORM_LINE = re.compile(r'Platform\.is(?:Android|IOS)\b')
# A row of the table: its first cell is the file and line of build 20, `lib/...dart:123`
ROW = re.compile(r'^\|\s*`(lib/[^`:]+\.dart):\d+`', re.MULTILINE)


def platform_lines(root: pathlib.Path) -> collections.Counter:
    lib = root / 'mobile' / 'lib'
    desktop = lib / 'desktop'
    found = collections.Counter()
    for path in sorted(lib.rglob('*.dart')):
        if desktop in path.parents or path.name.endswith(GENERATED):
            continue
        n = sum(1 for line in path.read_text(encoding='utf-8', errors='replace').splitlines()
                if PLATFORM_LINE.search(line))
        if n:
            found[path.relative_to(root / 'mobile').as_posix()] = n
    return found


def audit_rows(audit: pathlib.Path) -> collections.Counter:
    return collections.Counter(ROW.findall(audit.read_text(encoding='utf-8')))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--root', type=pathlib.Path, default=ROOT, help='repository root')
    parser.add_argument('--audit', type=pathlib.Path, help='the audit table (default: the one of --root)')
    args = parser.parse_args(argv)

    audit = args.audit or args.root / AUDIT
    if not audit.exists():
        print(f'{audit} is missing')
        return 2
    lines = platform_lines(args.root)
    rows = audit_rows(audit)
    missing = sorted((path, n, rows[path]) for path, n in lines.items() if n > rows[path])
    for path, n, r in missing:
        print(f'mobile/{path}: {n} platform lines, {r} rows in PLATFORM-AUDIT.md')
    if missing:
        print('A Platform.isAndroid or Platform.isIOS line has no verdict for the computers: read it, gate it if '
              'needed, and add its row to mobile/lib/desktop/platform/PLATFORM-AUDIT.md')
        return 1
    stale = sorted(path for path, r in rows.items() if lines[path] < r)
    if stale:
        print('rows without their line any more (the table can drop them): ' + ', '.join(stale))
    print(f'{sum(lines.values())} platform lines in {len(lines)} files, each with a row in PLATFORM-AUDIT.md')
    return 0


if __name__ == '__main__':
    sys.exit(main())
