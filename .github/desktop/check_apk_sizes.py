#!/usr/bin/env python3
"""Gate of Immuch360 Desktop: the phone APKs keep their size (design 8.4 point 4).

The desktop work must not change what the phones ship. Apart from the plugin lists, the size of each APK is the
plainest sign of it: a desktop package that slipped into the Android build, or an asset added for the computers,
shows as growth. This compares release APKs (and the bundle) with those of a published release, kind by kind (each
ABI, the universal APK, the Quest APK, the AAB), and fails when one differs by more than the threshold.

  check_apk_sizes.py --release v3.3.0-rc.0-20 APK ...            sizes of that release of freeKC/Immuch360 (GitHub API)
  check_apk_sizes.py --reference-json FILE APK ...               sizes from a file: {"arm64-v8a": 134198546, ...}

APK names as Flutter writes them (app-arm64-v8a-phone-release.apk) or as the release has them
(Immuch360-v3.3.0-rc.0-20-arm64-v8a-release.apk). A local release build signed with another key differs by a few
kilobytes, far under the default 1 %.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys
import urllib.request

# The Quest first: its APK is arm64 too
KINDS = ('quest', 'arm64-v8a', 'armeabi-v7a', 'x86_64')


def kind(name: str) -> str:
    lower = name.lower()
    if lower.endswith('.aab'):
        return 'aab'
    for candidate in KINDS:
        if candidate in lower:
            return candidate
    return 'universal'


def release_sizes(repository: str, tag: str) -> dict:
    url = f'https://api.github.com/repos/{repository}/releases/tags/{tag}'
    request = urllib.request.Request(url, headers={'Accept': 'application/vnd.github+json'})
    with urllib.request.urlopen(request, timeout=30) as response:
        assets = json.load(response)['assets']
    return {kind(a['name']): a['size'] for a in assets if a['name'].lower().endswith(('.apk', '.aab'))}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('apks', nargs='+', type=pathlib.Path)
    parser.add_argument('--release', help='tag of the published release to compare with')
    parser.add_argument('--repository', default='freeKC/Immuch360')
    parser.add_argument('--reference-json', type=pathlib.Path, help='sizes by kind instead of a release')
    parser.add_argument('--threshold', type=float, default=1.0, help='percent, default 1')
    args = parser.parse_args(argv)

    if args.reference_json:
        reference = json.loads(args.reference_json.read_text(encoding='utf-8'))
    elif args.release:
        try:
            reference = release_sizes(args.repository, args.release)
        except OSError as error:
            print(f'cannot read the release {args.release} of {args.repository}: {error}')
            return 2
    else:
        parser.error('--release or --reference-json is needed')

    failed = False
    for apk in args.apks:
        if not apk.is_file():
            print(f'{apk}: missing')
            failed = True
            continue
        what = kind(apk.name)
        size = apk.stat().st_size
        if what not in reference:
            print(f'{apk.name}: {what}, {size} bytes, nothing to compare with')
            continue
        change = (size - reference[what]) * 100.0 / reference[what]
        verdict = 'ok' if abs(change) <= args.threshold else f'more than {args.threshold:g} %'
        print(f'{apk.name}: {what}, {size} bytes against {reference[what]} ({change:+.3f} %), {verdict}')
        failed = failed or abs(change) > args.threshold
    if failed:
        print('A phone package changed size: find what the desktop work added to it')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
