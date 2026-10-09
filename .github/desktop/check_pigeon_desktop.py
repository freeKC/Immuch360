#!/usr/bin/env python3
"""Gate of Immuch360 Desktop: every pigeon host API has an answer on the computers.

The phone apps reach their native side through the pigeon host APIs of mobile/pigeon. The computers have no native
side behind those channels: each API is implemented in Dart under mobile/lib/desktop (a class that implements or
extends the generated one, handed out by PlatformApis), or is listed in pigeon-not-on-desktop.json with the reason
the computers never call it. An upstream merge that adds a host API fails here instead of failing at run time with
a channel error on the computers.

  check_pigeon_desktop.py   exit 1 when a host API has neither a desktop class nor a reason

--root and --not-on-desktop point at another tree and list (the tests use fixtures).
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
HOST_API = re.compile(r'@HostApi\([^)]*\)\s*(?:abstract\s+)?(?:interface\s+)?class\s+(\w+)')
# A class declaration that names a parent: `class X extends Y implements Z {`, comments removed first
DESKTOP_CLASS = re.compile(r'\bclass\s+(\w+)\b([^{;]*\b(?:extends|implements|with)\b[^{;]*)\{')
COMMENT = re.compile(r'//[^\n]*|/\*.*?\*/', re.DOTALL)


def host_apis(root: pathlib.Path) -> dict:
    found = {}
    for path in sorted((root / 'mobile' / 'pigeon').glob('*.dart')):
        for name in HOST_API.findall(path.read_text(encoding='utf-8', errors='replace')):
            found[name] = path.relative_to(root).as_posix()
    return found


def desktop_classes(root: pathlib.Path) -> dict:
    """The desktop class of each API name it implements or extends: {api: 'Class in path'}"""
    found = {}
    for path in sorted((root / 'mobile' / 'lib' / 'desktop').rglob('*.dart')):
        text = COMMENT.sub(' ', path.read_text(encoding='utf-8', errors='replace'))
        for name, header in DESKTOP_CLASS.findall(text):
            for parent in re.findall(r'\w+', re.sub(r'<[^>]*>', ' ', header)):
                if parent not in ('extends', 'implements', 'with', 'base', 'final', 'interface'):
                    found.setdefault(parent, f'{name} in {path.relative_to(root).as_posix()}')
    return found


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--root', type=pathlib.Path, default=ROOT, help='repository root')
    parser.add_argument('--not-on-desktop', type=pathlib.Path, default=HERE / 'pigeon-not-on-desktop.json')
    args = parser.parse_args(argv)

    apis = host_apis(args.root)
    implemented = desktop_classes(args.root)
    reasons = json.loads(args.not_on_desktop.read_text(encoding='utf-8'))
    missing = []
    for api, source in sorted(apis.items()):
        if api in implemented:
            print(f'{api}: {implemented[api]}')
        elif api in reasons:
            print(f'{api}: not on the computers, {reasons[api]}')
        else:
            missing.append(f'{api} ({source}): no desktop class under mobile/lib/desktop and no reason in '
                           f'{args.not_on_desktop.name}')
    for name in sorted(reasons):
        if name not in apis:
            print(f'{name} is no longer a pigeon host API: its line in {args.not_on_desktop.name} can go')
        elif name in implemented:
            print(f'{name} now has a desktop class: its line in {args.not_on_desktop.name} can go')
    for line in missing:
        print(line)
    if missing:
        print('A pigeon host API has no answer on the computers: implement it under mobile/lib/desktop and hand it '
              'out through PlatformApis, or say why the computers never call it')
        return 1
    print(f'{len(apis)} pigeon host APIs, each answered on the computers or never called there')
    return 0


if __name__ == '__main__':
    sys.exit(main())
