#!/usr/bin/env python3
"""Version numbers of an Immuch360 Desktop build.

The fork numbers its releases with tags v<version>-<build> (v3.3.0-rc.0-20 is build 20). The pubspec's build number
(3030018) does not fit a Windows version, whose four numbers have 16 bits each, so desktop builds pass
--build-number <fork build> (design 6.1): the newest fork build tag reachable from the commit, or the tag itself on a
tag build. Printed as key=value lines, appended to $GITHUB_OUTPUT with --github-output:

  build_name     the pubspec version without its build number (3.3.0-rc.0)
  build_number   the fork build, for flutter build --build-number (20)
  file_version   what Windows shows in the file properties (3.3.0.20)
  label          for file names: 3.3.0-rc.0-20 on a release tag, 3.3.0-rc.0-20-<commit> otherwise
  msix_version   major.minor.(patch x 1000 + build).0, the Store package version of phase 4 (3.3.20.0)

--pubspec-version, --tags, --exact-tag and --commit replace what is read from the repository (the tests use them).
Only read-only git commands are run.
"""
from __future__ import annotations

import argparse
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
FORK_TAG = re.compile(r'^v(\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)-(\d+)$')
PUBSPEC_VERSION = re.compile(r'^version:\s*([^\s#]+)', re.MULTILINE)
# Strict on purpose: the values end up in file names and in the commands of the workflow
BUILD_NAME = re.compile(r'^(\d+)\.(\d+)\.(\d+)(?:-[0-9A-Za-z.]+)?$')
COMMIT = re.compile(r'^[0-9a-z]{1,40}$')
LIMIT = 65535


def fork_build(tag: str):
    match = FORK_TAG.match(tag.strip())
    return int(match.group(2)) if match else None


def compute(pubspec_version: str, tags, exact_tag, commit: str) -> dict:
    build_name = pubspec_version.split('+', 1)[0]
    numbers = BUILD_NAME.match(build_name)
    if not numbers:
        raise ValueError(f'pubspec version {pubspec_version!r} is not major.minor.patch[-prerelease][+build]')
    if not COMMIT.match(commit):
        raise ValueError(f'unexpected commit id {commit!r}')
    major, minor, patch = (int(n) for n in numbers.groups())

    exact = fork_build(exact_tag) if exact_tag else None
    builds = [b for b in (fork_build(t) for t in tags) if b is not None]
    build = exact if exact is not None else max(builds, default=0)
    if build > LIMIT:
        raise ValueError(f'fork build {build} does not fit a Windows version number (at most {LIMIT})')

    label = f'{build_name}-{build}' if exact is not None else f'{build_name}-{build}-{commit}'
    msix_build = patch * 1000 + build
    return {
        'build_name': build_name,
        'build_number': str(build),
        'file_version': f'{major}.{minor}.{patch}.{build}',
        'label': label,
        # Empty when it cannot be a Store version; only phase 4 uses it
        'msix_version': f'{major}.{minor}.{msix_build}.0' if major > 0 and build < 1000 and msix_build <= LIMIT else '',
    }


def from_repository(root: pathlib.Path):
    def git(*args):
        return subprocess.run(['git', '-C', str(root), *args], check=True, capture_output=True, text=True).stdout

    pubspec = (root / 'mobile' / 'pubspec.yaml').read_text(encoding='utf-8')
    version = PUBSPEC_VERSION.search(pubspec)
    if not version:
        raise ValueError('no version line in mobile/pubspec.yaml')
    tags = git('tag', '--merged', 'HEAD', '--list', 'v*').split()
    on_head = [t for t in git('tag', '--points-at', 'HEAD', '--list', 'v*').split() if fork_build(t) is not None]
    exact = max(on_head, key=fork_build) if on_head else None
    return version.group(1), tags, exact, git('rev-parse', '--short=7', 'HEAD').strip()


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--root', type=pathlib.Path, default=ROOT, help='repository root')
    parser.add_argument('--pubspec-version')
    parser.add_argument('--tags', help='comma separated tags reachable from the commit')
    parser.add_argument('--exact-tag', help='the release tag of the commit, if any')
    parser.add_argument('--commit', help='short commit id')
    parser.add_argument('--github-output', action='store_true', help='also append the values to $GITHUB_OUTPUT')
    args = parser.parse_args(argv)

    try:
        if args.pubspec_version is not None:
            values = compute(args.pubspec_version, (args.tags or '').split(','), args.exact_tag, args.commit or 'local')
        else:
            values = compute(*from_repository(args.root))
    except (ValueError, subprocess.CalledProcessError) as error:
        print(f'desktop_version: {getattr(error, "stderr", None) or error}')
        return 1
    if values['build_number'] == '0':
        print('warning: no fork build tag reachable from this commit, build number 0 (fetch-depth 0 brings the tags)')
    lines = [f'{key}={value}' for key, value in values.items()]
    print('\n'.join(lines))
    if args.github_output:
        with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as output:
            output.write('\n'.join(lines) + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
