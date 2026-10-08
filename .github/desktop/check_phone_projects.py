#!/usr/bin/env python3
"""Gate of Immuch360 Desktop: nothing under mobile/android or mobile/ios changes on the desktop branch.

The desktop work never touches the phone projects; whatever they hold on the desktop branch comes from the phone
branch (immuch360), merged in after each phone release. So the difference between the checked out commit and its
merge base with the phone branch, restricted to mobile/android and mobile/ios, must be empty, whether the commit is
a push to the desktop branch, a pull request or a merge of a phone release. An upstream sync reaches the desktop
through the phone branch; an upstream-sync/* branch is not checked here (the workflow skips it).

  check_phone_projects.py [--phone-ref origin/immuch360]   exit 1 when a phone project file differs
  check_phone_projects.py --worktree                       the working tree instead of HEAD, untracked files
                                                           included (before a commit)
  check_phone_projects.py --changed-from FILE              check a list of changed paths instead (one per line)

Only read-only git commands are run (merge-base, diff).
"""
from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
PHONE_PROJECTS = ('mobile/android/', 'mobile/ios/')


def phone_project_changes(paths) -> list:
    return sorted({p.strip() for p in paths if p.strip().startswith(PHONE_PROJECTS)})


def changed_since_phone_branch(root: pathlib.Path, phone_ref: str, worktree: bool) -> list:
    def git(*args):
        return subprocess.run(['git', '-C', str(root), *args], check=True, capture_output=True, text=True).stdout

    folders = [p.rstrip('/') for p in PHONE_PROJECTS]
    base = git('merge-base', phone_ref, 'HEAD').strip()
    print(f'merge base with {phone_ref}: {base}')
    if not worktree:
        return git('diff', '--name-only', base, 'HEAD', '--', *folders).splitlines()
    return (git('diff', '--name-only', base, '--', *folders).splitlines()
            + git('ls-files', '--others', '--exclude-standard', '--', *folders).splitlines())


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--phone-ref', default='origin/immuch360', help='the phone branch as the clone knows it')
    parser.add_argument('--worktree', action='store_true', help='check the working tree instead of HEAD')
    parser.add_argument('--changed-from', type=pathlib.Path, help='a file listing changed paths, one per line')
    parser.add_argument('--root', type=pathlib.Path, default=ROOT, help='repository root')
    args = parser.parse_args(argv)

    if args.changed_from:
        paths = args.changed_from.read_text(encoding='utf-8').splitlines()
    else:
        try:
            paths = changed_since_phone_branch(args.root, args.phone_ref, args.worktree)
        except subprocess.CalledProcessError as error:
            print(f'git {" ".join(error.cmd[3:])} failed: {error.stderr.strip()}')
            print(f'{args.phone_ref} must be in the clone (fetch-depth 0 in the workflow)')
            return 2
    changed = phone_project_changes(paths)
    for path in changed:
        print(f'changed: {path}')
    if changed:
        print('The desktop work changed the phone projects: nothing under mobile/android or mobile/ios may differ '
              'from the phone branch')
        return 1
    print('mobile/android and mobile/ios as on the phone branch')
    return 0


if __name__ == '__main__':
    sys.exit(main())
