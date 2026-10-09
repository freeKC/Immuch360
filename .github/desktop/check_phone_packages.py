#!/usr/bin/env python3
"""Gate of Immuch360 Desktop: the packages of the phone builds stay those of the phone branch.

check_plugin_baseline.py compares the names of the Android and iOS plugins only. A desktop package whose constraints
move a package the phones use to another version, or a `flutter pub upgrade` made for the desktop, keeps those names
and passes it, while the Android, Quest and iOS builds change. So mobile/pubspec.lock is compared, package by package,
with the one of the merge base with the phone branch: a package gained, lost or changed fails, except the packages
of desktop-packages.json, which the phone builds do not register and whose Dart code only lib/desktop imports. The
"dependency:" line of an entry (whether the app or another package asks for it) is not compared: it changes nothing
in what is built. A change of the SDK constraints is printed, not failed: the Flutter of every build is the one of
mobile/mise.toml.

The merge base follows the phone branch: after a phone release is merged into the desktop branch, the packages it
brought are the reference, so this gate never asks for an update after a phone release.

  check_phone_packages.py [--phone-ref origin/immuch360]   exit 1 when a package of the phone builds differs
  check_phone_packages.py --worktree                       the lock of the working tree instead of HEAD's
  check_phone_packages.py --base-lock FILE [--lock FILE]   compare two lock files instead (the tests use fixtures)

Only read-only git commands are run (merge-base, show).
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
LOCK = 'mobile/pubspec.lock'
PACKAGE = re.compile(r'^  ([^\s:]+):\s*$')


def read_lock(text: str) -> tuple:
    """The entries of a pubspec.lock by package, each as its lines without the "dependency:" one, and the sdks lines.

    The file is read line by line on purpose, as pub writes it: no YAML module is needed on the runners."""
    packages, sdks = {}, []
    section, current = None, None
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        if not line.startswith(' '):
            section, current = line.rstrip().rstrip(':'), None
            continue
        if section == 'sdks':
            sdks.append(line.strip())
            continue
        if section != 'packages':
            continue
        package = PACKAGE.match(line)
        if package:
            current = package.group(1)
            packages[current] = []
        elif current and not line.strip().startswith('dependency:'):
            packages[current].append(line.strip())
    return packages, sdks


def version(lines: list) -> str:
    return next((line.split(':', 1)[1].strip().strip('"') for line in lines if line.startswith('version:')), '?')


def differences(base: dict, now: dict, desktop_only) -> list:
    found = []
    for name in sorted(set(base) | set(now)):
        if name in desktop_only or base.get(name) == now.get(name):
            continue
        if name not in base:
            found.append(f'{name}: added ({version(now[name])})')
        elif name not in now:
            found.append(f'{name}: removed (was {version(base[name])})')
        else:
            before, after = version(base[name]), version(now[name])
            change = f'{before} to {after}' if before != after else 'same version, other source or checksum'
            found.append(f'{name}: changed, {change}')
    return found


def git(root: pathlib.Path, *args) -> str:
    return subprocess.run(['git', '-C', str(root), *args], check=True, capture_output=True, text=True).stdout


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--phone-ref', default='origin/immuch360', help='the phone branch as the clone knows it')
    parser.add_argument('--worktree', action='store_true', help='the lock of the working tree instead of HEAD')
    parser.add_argument('--base-lock', type=pathlib.Path, help='a lock file to compare with, instead of the merge base')
    parser.add_argument('--lock', type=pathlib.Path, help='the lock file to check, with --base-lock')
    parser.add_argument('--desktop-packages', type=pathlib.Path, default=HERE / 'desktop-packages.json')
    parser.add_argument('--root', type=pathlib.Path, default=ROOT, help='repository root')
    args = parser.parse_args(argv)

    desktop_only = json.loads(args.desktop_packages.read_text(encoding='utf-8'))
    try:
        if args.base_lock:
            base_text = args.base_lock.read_text(encoding='utf-8')
            now_text = (args.lock or args.root / LOCK).read_text(encoding='utf-8')
        else:
            base = git(args.root, 'merge-base', args.phone_ref, 'HEAD').strip()
            print(f'merge base with {args.phone_ref}: {base}')
            base_text = git(args.root, 'show', f'{base}:{LOCK}')
            if args.worktree:
                now_text = (args.root / LOCK).read_text(encoding='utf-8')
            else:
                now_text = git(args.root, 'show', f'HEAD:{LOCK}')
    except subprocess.CalledProcessError as error:
        print(f'git {" ".join(error.cmd[3:])} failed: {error.stderr.strip()}')
        print(f'{args.phone_ref} must be in the clone (fetch-depth 0 in the workflow)')
        return 2

    base_packages, base_sdks = read_lock(base_text)
    now_packages, now_sdks = read_lock(now_text)
    if not base_packages or not now_packages:
        print('a lock file without packages: not a pubspec.lock')
        return 2
    found = differences(base_packages, now_packages, desktop_only)
    for line in found:
        print(line)
    desktop = sorted(name for name in desktop_only if base_packages.get(name) != now_packages.get(name))
    if desktop:
        print('desktop only, not compared: ' + ', '.join(desktop))
    if base_sdks != now_sdks:
        print(f'for the record, SDK constraints {base_sdks} now {now_sdks}')
    if found:
        print('A package of the phone builds differs from the phone branch. The desktop work must not move them: pin '
              'the desktop package to a version that accepts them, or make the change on the phone branch first. A '
              'package only the computers build goes in desktop-packages.json, with the reason.')
        return 1
    print(f'{len(now_packages)} packages: those of the phone builds as on the phone branch')
    return 0


if __name__ == '__main__':
    sys.exit(main())
