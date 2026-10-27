#!/usr/bin/env python3
"""Gate of Immuch360 Desktop: the phone APKs keep their size (design 8.4 point 4).

The desktop work must not change what the phones ship. Apart from the plugin lists, the size of each APK is the
plainest sign of it: a desktop package that slipped into the Android build, or an asset added for the computers,
shows as growth. This compares release APKs (and the bundle) with those of a published release, kind by kind (each
ABI, the universal APK, the Quest APK, the AAB), and fails when one differs by more than the threshold.

  check_apk_sizes.py --release v3.3.0-rc.0-20 APK ...            sizes of that release of freeKC/Immuch360 (GitHub API)
  check_apk_sizes.py --reference-json FILE APK ...               sizes from a file: {"arm64-v8a": 134198546, ...}
  check_apk_sizes.py --release TAG --kind-threshold quest=7 APK ...   one kind with its own threshold

APK names as Flutter writes them (app-arm64-v8a-phone-release.apk) or as the release has them
(Immuch360-v3.3.0-rc.0-20-arm64-v8a-release.apk). A local release build signed with another key differs by a few
kilobytes, far under the default 1 %.

--kind-threshold KIND=PERCENT (repeatable) is for the one release that adds a known weight to one kind, every other
kind keeping --threshold. The release that brings the AI relief of the Quest passes quest=7: LiteRT 2.3.0 adds about
9.4 MB of native libraries to the Quest APK alone, about +6.5 % of its 144.4 MB (design-final 2026-10-26, section
3.10). The release after it compares with that release and the ordinary threshold again.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys
import urllib.request

# The Quest first: its APK is arm64 too
KINDS = ('quest', 'arm64-v8a', 'armeabi-v7a', 'x86_64')
ALL_KINDS = KINDS + ('universal', 'aab')


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


def kind_threshold(value: str) -> tuple:
    """('quest', 7.0) from 'quest=7'"""
    name, separator, percent = value.partition('=')
    if not separator or name not in ALL_KINDS:
        raise argparse.ArgumentTypeError(f'{value}: KIND=PERCENT with KIND one of {", ".join(ALL_KINDS)}')
    try:
        threshold = float(percent)
    except ValueError:
        raise argparse.ArgumentTypeError(f'{value}: {percent} is not a number') from None
    if threshold < 0:
        raise argparse.ArgumentTypeError(f'{value}: a threshold is not negative')
    return name, threshold


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('apks', nargs='+', type=pathlib.Path)
    parser.add_argument('--release', help='tag of the published release to compare with')
    parser.add_argument('--repository', default='freeKC/Immuch360')
    parser.add_argument('--reference-json', type=pathlib.Path, help='sizes by kind instead of a release')
    parser.add_argument('--threshold', type=float, default=1.0, help='percent, default 1')
    parser.add_argument('--kind-threshold', type=kind_threshold, action='append', default=[], metavar='KIND=PERCENT',
                        help='percent for one kind (quest, arm64-v8a, armeabi-v7a, x86_64, universal, aab)')
    args = parser.parse_args(argv)
    thresholds = dict(args.kind_threshold)

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
        threshold = thresholds.get(what, args.threshold)
        verdict = 'ok' if abs(change) <= threshold else f'more than {threshold:g} %'
        if what in thresholds:
            verdict += f' (threshold of the {what} kind: {threshold:g} %)'
        print(f'{apk.name}: {what}, {size} bytes against {reference[what]} ({change:+.3f} %), {verdict}')
        failed = failed or abs(change) > threshold
    if failed:
        print('A phone package changed size: find what the desktop work added to it')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
