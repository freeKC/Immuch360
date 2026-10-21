#!/usr/bin/env python3
"""Gate of Immuch360 Desktop: the desktop workflow stays pinned and closed to secrets.

.github/workflows/immuch360-desktop.yml builds pull request code on three operating systems. It keeps:

  - runner labels pinned (windows-latest moved to Visual Studio 2026 and macos-latest to macOS 26 while the owner's PC
    builds with the Build Tools 2022; plan 20, 0.1 points 3 and 4);
  - every action pinned to a full commit, with its version in a comment;
  - the Flutter of the Windows job (the Flutter action, mise does not install Flutter on Windows hosts) equal to the one
    of mobile/mise.toml, which every other job uses;
  - an Xcode chosen by its version (XCODE_VERSION), never the newest one a pattern finds on the image, which may be a
    beta or a release candidate added by the weekly image update (design 6.6: pinned toolchains);
  - read-only permissions, no secret, no pull_request_target, and checkouts that do not keep the token, since the
    code it runs comes from pull requests (signing, when it comes, goes to a workflow that runs on tags only).

.github/workflows/immuch360-desktop-release.yml is such a workflow: it attaches the packages to the GitHub release of a
desktop pre-release tag, so its release job writes to the repository. With --release the same rules hold, except that
"contents: write" is its one write access (the top may also give no permission at all, "permissions: {}"), and it may
run on the push of desktop-v* tags and by hand (workflow_dispatch) only: no pull request, no branch.

.github/workflows/immuch360-webos.yml, the LG webOS app, is held to the same rules as a release workflow on its own tags:
--tag-prefix webos-v.

  check_workflow.py             exit 1 on any finding
  check_workflow.py --release   the release workflow
  check_workflow.py --release --workflow .github/workflows/immuch360-webos.yml --tag-prefix webos-v

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
RELEASE_EVENTS = ('push', 'workflow_dispatch')


def release_triggers(workflow: str, tag_prefix: str = 'desktop-v') -> list:
    """The release workflow runs on its tags (desktop-v*) and by hand only"""
    block = re.search(r'^on:[ \t]*\n((?:[ \t]+.*\n|[ \t]*\n)+)', workflow, re.MULTILINE)
    if not block:
        return ['the triggers ("on:") are not a block of events']
    found = []
    for event in re.findall(r'^  ([\w-]+):', block.group(1), re.MULTILINE):
        if event not in RELEASE_EVENTS:
            found.append(f'the release workflow runs on {event}: {tag_prefix}* tags and workflow_dispatch only')
    if re.search(r'^\s+(?:branches|branches-ignore|paths|paths-ignore|tags-ignore)\s*:', block.group(1), re.MULTILINE):
        found.append(f'the release workflow runs on branches or paths: {tag_prefix}* tags and workflow_dispatch only')
    tags = re.search(r'^\s+tags:[ \t]*(\[.*\])?[ \t]*\n((?:\s+-.*\n)*)', block.group(1), re.MULTILINE)
    patterns = []
    if tags:
        patterns = re.findall(r'[\w.*?/-]+', tags.group(1) or '') + re.findall(r'-\s*[\'"]?([^\'"\s]+)', tags.group(2))
    if re.search(r'^  push:', block.group(1), re.MULTILINE) and not patterns:
        found.append('the release workflow runs on push without a tag filter')
    for pattern in patterns:
        if not pattern.startswith(tag_prefix):
            found.append(f'the release workflow runs on the tags {pattern}: {tag_prefix}* only')
    return found


def findings(workflow: str, mise: str, release: bool = False, tag_prefix: str = 'desktop-v') -> list:
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

    for number, line in enumerate(lines, 1):
        if re.search(r'Xcode_[^/\s"\']*[*?\[]', line):
            found.append(f'line {number}: an Xcode found by a pattern, not named by XCODE_VERSION')
    if any(re.search(r'\bxcode-select\s+(?:-s|--switch)\b', line) for line in lines) and not any(
        re.match(r'^\s*XCODE_VERSION:\s*[\'"]?\d+(?:\.\d+)+[\'"]?\s*(?:#.*)?$', line) for line in lines
    ):
        found.append('xcode-select without an XCODE_VERSION: the Xcode of the job is not pinned')

    checkouts = sum(1 for line in lines if re.match(r'^\s*(?:-\s*)?uses:\s*actions/checkout@', line))
    kept = sum(1 for line in lines if re.match(r'^\s*persist-credentials:\s*false\s*$', line))
    if checkouts != kept:
        found.append(f'{checkouts} checkouts and {kept} "persist-credentials: false": every checkout drops the token')

    permissions = re.search(r'^permissions:\s*\n((?:[ \t]+.*\n)+)', workflow, re.MULTILINE)
    none = release and re.search(r'^permissions:\s*\{\s*\}\s*$', workflow, re.MULTILINE)
    if not none and (not permissions or not re.search(r'^\s+contents:\s*read\s*$', permissions.group(1), re.MULTILINE)):
        found.append('the workflow does not set "permissions: contents: read" at the top'
                     + (' (or "permissions: {}")' if release else ''))
    for number, line in enumerate(lines, 1):
        if re.match(r'^\s*(?:[\w-]+:\s*write|permissions:\s*write-all)\s*$', line):
            if release and re.match(r'^\s*contents:\s*write\s*$', line):
                continue
            found.append(f'line {number}: a write access ({line.strip()})')
    if release:
        found += release_triggers(workflow, tag_prefix)
    return found


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--workflow', type=pathlib.Path)
    parser.add_argument('--mise', type=pathlib.Path, default=ROOT / 'mobile' / 'mise.toml')
    parser.add_argument('--release', action='store_true', help='the release workflow, which may write the contents')
    parser.add_argument('--tag-prefix', default='desktop-v', help='the tags a release workflow runs on (desktop-v)')
    args = parser.parse_args(argv)
    workflow = args.workflow or ROOT / '.github' / 'workflows' / (
        'immuch360-desktop-release.yml' if args.release else 'immuch360-desktop.yml')

    found = findings(workflow.read_text(encoding='utf-8'), args.mise.read_text(encoding='utf-8'), args.release, args.tag_prefix)
    for line in found:
        print(f'{workflow.name}: {line}')
    if found:
        return 1
    if args.release:
        print(f'{workflow.name}: runners and actions pinned, no secret, {args.tag_prefix}* tags and workflow_dispatch only, '
              'contents its only write access')
    else:
        print(f'{workflow.name}: runners, actions and Xcode pinned, Flutter as in mise.toml, read-only, no secret')
    return 0


if __name__ == '__main__':
    sys.exit(main())
