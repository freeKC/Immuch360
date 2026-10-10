#!/usr/bin/env python3
"""Resolve the i18n/*.json conflicts of an upstream merge by a union of the keys (plan 23 section 3, step 2).

The fork adds its own keys to the translation files of Immich; each upstream sync adds, removes and changes keys of
its own next to them, and git reports a conflict for every file where the two additions touch. The content never
conflicts: the keys of the fork are not the keys of Immich. For each conflicted file under i18n/, this script reads
the three versions git keeps in the index (the merge base, ours, theirs), starts from theirs (their additions,
removals and changes are kept), puts back the keys the fork added or changed when upstream left them alone, drops the
keys the fork removed, sorts the keys the way upstream does (plain code point order, checked on their version) and
writes the file in their format (two spaces, no escaping of non ASCII characters, one final newline). The file is
then staged. A key changed on both sides keeps ours and is listed, for a look by hand.

  i18n_merge.py            resolve the conflicted files under i18n/ (run from anywhere in the repository)
  i18n_merge.py --check    only report what would be done, stage nothing
"""
from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys


def git(*args: str, cwd: pathlib.Path) -> str:
    return subprocess.run(['git', *args], cwd=cwd, check=True, capture_output=True, text=True).stdout


def stage(path: str, number: int, cwd: pathlib.Path) -> dict:
    return json.loads(git('show', f':{number}:{path}', cwd=cwd))


def merge(base: dict, ours: dict, theirs: dict, both: list[str], prefix: str = '') -> dict:
    result = dict(theirs)
    for key, value in ours.items():
        name = prefix + key
        if isinstance(value, dict) and isinstance(theirs.get(key), dict):
            result[key] = merge(base.get(key) if isinstance(base.get(key), dict) else {}, value, theirs[key], both,
                                name + '.')
        elif key not in base:
            result[key] = value
        elif value != base[key]:
            if theirs.get(key) == base[key]:
                result[key] = value
            elif key in theirs:
                both.append(name)
                result[key] = value
    for key in base:
        if key not in ours and key in theirs and theirs[key] == base[key]:
            del result[key]
    return {key: result[key] for key in sorted(result)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    root = pathlib.Path(git('rev-parse', '--show-toplevel', cwd=pathlib.Path.cwd()).strip())
    conflicted = [line for line in git('diff', '--name-only', '--diff-filter=U', cwd=root).splitlines()
                  if line.startswith('i18n/') and line.endswith('.json')]
    if not conflicted:
        print('no conflicted file under i18n/')
        return 0
    for path in conflicted:
        base, ours, theirs = (stage(path, n, root) for n in (1, 2, 3))
        if list(theirs) != sorted(theirs):
            print(f'{path}: their keys are not in code point order, look at the file by hand', file=sys.stderr)
            return 1
        both: list[str] = []
        merged = merge(base, ours, theirs, both)
        added = [k for k in merged if k not in theirs]
        print(f'{path}: {len(merged)} keys, {len(added)} of the fork put back, '
              f'{len(set(theirs) - set(base))} new upstream, {len(set(base) - set(theirs))} removed upstream'
              + (f', changed on both sides and kept ours: {", ".join(both)}' if both else ''))
        if args.check:
            continue
        (root / path).write_text(json.dumps(merged, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
        git('add', path, cwd=root)
    return 0


if __name__ == '__main__':
    sys.exit(main())
