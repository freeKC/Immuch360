#!/usr/bin/env python3
"""Gate of Immuch360 Desktop: no new "iOS else Android" branch in the app.

A ternary on Platform.isIOS or Platform.isAndroid (or CurrentPlatform.isIOS, isAndroid) sends a computer down one of
the two phone paths without anyone deciding it. Each existing one has a verdict in
mobile/lib/desktop/platform/PLATFORM-AUDIT.md; this check counts them per file under mobile/lib and fails when a
file has more than ternary-allowlist.json allows, so that a new one is looked at (desktop gate or allow list).
Counts are per file because line numbers move with every upstream merge; a ternary removed and another added in the
same file is not seen, the audit check (check_platform_audit.py) covers the lines themselves.

  check_platform_ternaries.py           compare (exit 1 when a count went up)
  check_platform_ternaries.py --update  rewrite the allow list on purpose, after the audit table was updated

--root and --allowlist point at another tree and list (the tests use fixtures).
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
GENERATED = ('.g.dart', '.freezed.dart', '.drift.dart', '.gr.dart', '.steps.dart', '.mocks.dart')
# The test, then the question mark of a conditional expression (not ?. nor ??), possibly on the next line
TERNARY = re.compile(r'\b(?:Platform|CurrentPlatform)\.is(?:IOS|Android)\s*\?(?![?.])')


def counts(root: pathlib.Path) -> dict:
    found = {}
    for path in sorted((root / 'mobile' / 'lib').rglob('*.dart')):
        if path.name.endswith(GENERATED):
            continue
        n = len(TERNARY.findall(path.read_text(encoding='utf-8', errors='replace')))
        if n:
            found[path.relative_to(root).as_posix()] = n
    return found


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--root', type=pathlib.Path, default=ROOT, help='repository root')
    parser.add_argument('--allowlist', type=pathlib.Path, default=HERE / 'ternary-allowlist.json')
    parser.add_argument('--update', action='store_true', help='rewrite the allow list from the current counts')
    args = parser.parse_args(argv)

    now = counts(args.root)
    if args.update:
        args.allowlist.write_text(json.dumps(now, indent=2, sort_keys=True) + '\n', encoding='utf-8')
        print(f'allow list written: {sum(now.values())} ternaries in {len(now)} files')
        return 0

    allowed = json.loads(args.allowlist.read_text(encoding='utf-8'))
    over = {path: (n, allowed.get(path, 0)) for path, n in now.items() if n > allowed.get(path, 0)}
    for path, (n, limit) in sorted(over.items()):
        print(f'{path}: {n} iOS or Android ternaries, {limit} allowed')
    if over:
        print('A new "iOS else Android" branch: gate it for the computers, or give it a verdict in PLATFORM-AUDIT.md '
              'and run check_platform_ternaries.py --update')
        return 1
    # Fewer than allowed is fine (an upstream merge or a desktop gate removed one); the list can shrink at the next
    # --update, so it is only said
    fewer = sorted(path for path, limit in allowed.items() if now.get(path, 0) < limit)
    if fewer:
        print('fewer ternaries than allowed in: ' + ', '.join(fewer))
    print(f'{sum(now.values())} iOS or Android ternaries in {len(now)} files, none new')
    return 0


if __name__ == '__main__':
    sys.exit(main())
