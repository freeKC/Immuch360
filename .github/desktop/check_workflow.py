#!/usr/bin/env python3
"""Gate of Immuch360 Desktop: the desktop workflow stays pinned and closed to secrets.

.github/workflows/immuch360-desktop.yml builds pull request code on three operating systems. It keeps:

  - runner labels pinned (windows-latest moved to Visual Studio 2026 and macos-latest to macOS 26 while the owner's PC
    builds with the Build Tools 2022; plan 20, 0.1 points 3 and 4);
  - every action pinned to a full commit, with its version in a comment;
  - the Flutter of the Windows job (the Flutter action, mise does not install Flutter on Windows hosts) equal to the one
    of mobile/mise.toml, which every other job uses;
  - read-only permissions, no secret, no pull_request_target, and checkouts that do not keep the token, since the
    code it runs comes from pull requests (signing, when it comes, goes to a workflow that runs on tags only).

  check_workflow.py   exit 1 on any finding

--workflow and --mise point at other files (the tests use fixtures). The YAML is read line by line on purpose: no
third party module is needed on the runners.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
PINNED_RUNNER = re.compile(r'^(ubuntu-\d\d\.\d\d|windows-20\d\d|windows-11-arm|macos-\d+)$')
USES = re.compile(r'^\s*(?:-\s*)?uses:\s*([^\s#]+)\s*(?:#\s*(\S+))?')
PINNED_ACTION = re.compile(r'^[\w.-]+/[\w./-]+@[0-9a-f]{40}$')
MISE_FLUTTER = re.compile(r'^\[tools\."aqua:flutter/flutter"\]\s*\n\s*version\s*=\s*"([^"]+)"', re.MULTILINE)


def findings(workflow: str, mise: str) -> list:
    found = []
    lines = workflow.splitlines()
    for number, line in enumerate(lines, 1):
        runner = re.match(r'^\s*runs-on:\s*(.+?)\s*$', line)
        if runner and not PINNED_RUNNER.match(runner.group(1).strip('\'"')):
            found.append(f'line {number}: runner {runner.group(1)} is not a pinned label')
        uses = USES.match(line)
        if uses and not uses.group(1).startswith('./'):
            if not PINNED_ACTION.match(uses.group(1)):
                found.append(f'line {number}: {uses.group(1)} is not pinned to a full commit')
            elif not uses.group(2):
                found.append(f'line {number}: {uses.group(1)} has no version comment')
        if re.search(r'\$\{\{[^}]*\bsecrets\.', line) or re.match(r'^\s*secrets:\s*inherit', line):
            found.append(f'line {number}: a secret in the workflow that builds pull request code')
        if re.match(r'^\s*pull_request_target\s*:', line):
            found.append(f'line {number}: pull_request_target runs pull request code with the repository token')

    flutter = MISE_FLUTTER.search(mise)
    if not flutter:
        found.append('mobile/mise.toml: no aqua:flutter/flutter version')
    for number, line in enumerate(lines, 1):
        version = re.match(r'^\s*flutter-version:\s*[\'"]?([^\'"\s#]+)', line)
        if version and flutter and version.group(1) != flutter.group(1):
            found.append(f'line {number}: Flutter {version.group(1)}, mobile/mise.toml has {flutter.group(1)}')

    checkouts = sum(1 for line in lines if re.match(r'^\s*(?:-\s*)?uses:\s*actions/checkout@', line))
    kept = sum(1 for line in lines if re.match(r'^\s*persist-credentials:\s*false\s*$', line))
    if checkouts != kept:
        found.append(f'{checkouts} checkouts and {kept} "persist-credentials: false": every checkout drops the token')

    permissions = re.search(r'^permissions:\s*\n((?:[ \t]+.*\n)+)', workflow, re.MULTILINE)
    if not permissions or not re.search(r'^\s+contents:\s*read\s*$', permissions.group(1), re.MULTILINE):
        found.append('the workflow does not set "permissions: contents: read" at the top')
    for number, line in enumerate(lines, 1):
        if re.match(r'^\s*(?:[\w-]+:\s*write|permissions:\s*write-all)\s*$', line):
            found.append(f'line {number}: a write access ({line.strip()})')
    return found


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--workflow', type=pathlib.Path, default=ROOT / '.github' / 'workflows' / 'immuch360-desktop.yml')
    parser.add_argument('--mise', type=pathlib.Path, default=ROOT / 'mobile' / 'mise.toml')
    args = parser.parse_args(argv)

    found = findings(args.workflow.read_text(encoding='utf-8'), args.mise.read_text(encoding='utf-8'))
    for line in found:
        print(f'{args.workflow.name}: {line}')
    if found:
        return 1
    print(f'{args.workflow.name}: runners and actions pinned, Flutter as in mise.toml, read-only, no secret')
    return 0


if __name__ == '__main__':
    sys.exit(main())
