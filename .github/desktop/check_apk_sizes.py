#!/usr/bin/env python3
"""Gate of Immuch360 Desktop: the phone APKs keep their size (design 8.4 point 4).

The desktop work must not change what the phones ship. Apart from the plugin lists, the size of each APK is the
plainest sign of it: a desktop package that slipped into the Android build, or an asset added for the computers,
shows as growth. This compares release APKs (and the bundle) with those of a published release, kind by kind (each
ABI, the universal APK, the Quest APK, the AAB), and fails when one differs by more than the threshold.

  check_apk_sizes.py --release v3.3.0-rc.0-20 APK ...            sizes of that release of freeKC/Immuch360 (GitHub API)
  check_apk_sizes.py --reference-json FILE APK ...               sizes from a file: {"arm64-v8a": 134198546, ...}
  check_apk_sizes.py --release TAG --reference-json FILE APK ... sizes of the release TAG, from a file (no API call)
  check_apk_sizes.py --release TAG --kind-threshold quest=7 APK ...   one kind with its own threshold

APK names as Flutter writes them (app-arm64-v8a-phone-release.apk) or as the release has them
(Immuch360-v3.3.0-rc.0-20-arm64-v8a-release.apk). A local release build signed with another key differs by a few
kilobytes, far under the default 1 %.

A release that adds a known weight to one kind gets a threshold of its own for that kind, once: in
ONE_TIME_KIND_THRESHOLDS below, keyed by the published release it is compared with (--release), or by hand with
--kind-threshold KIND=PERCENT (repeatable), which wins over the table. Every other kind keeps --threshold. The release
after it compares with that release and the ordinary threshold again.
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

# One-time thresholds in percent, by the published release the build is compared with: each entry is for the one
# release that adds a known weight, never for the release after it.
ONE_TIME_KIND_THRESHOLDS = {
    # 29 October 2026, for Android build 32, the release of the AI immersive features (phases 1 to 3), compared with
    # release 31, whose Quest APK is 144,411,843 bytes. The Quest APK of feat-ai-immersive at 8e50a3a1d measures
    # 155,878,518 bytes, +7.94 % (CI run 40783336966, same tree). Its steps: the AI relief and the 3D scenes,
    # 154,502,078 bytes, +6.99 %, of which LiteRT 2.3.0 is about 9.4 MB of native libraries in the Quest APK alone
    # (design-final 2026-10-26, section 3.10, the reason for the 7 % first planned); the panoramas, 65,720 bytes
    # more, a step of 64 KiB that phase23/lots/integration-vague-5.md puts down to an alignment boundary crossed by
    # the small changes of the Dart code shared by the phones and the Quest (not verified there), which left the APK
    # 47,126 bytes over 7 %; then the 257 texts of the features in 88 languages, compiled into the Dart code, 1,310,720
    # bytes more. 8.5 % stops at 156,686,849 bytes and leaves about 0.8 MB for the fixes of the headset tests. The
    # other kinds keep the ordinary threshold. Once build 32 is published, the next release compares with it and this
    # entry no longer applies.
    'v3.3.0-rc.0-31': {'quest': 8.5},
}


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
    parser.add_argument('--release', help='tag of the published release to compare with (its sizes come from '
                        '--reference-json when given)')
    parser.add_argument('--repository', default='freeKC/Immuch360')
    parser.add_argument('--reference-json', type=pathlib.Path, help='sizes by kind instead of a release')
    parser.add_argument('--threshold', type=float, default=1.0, help='percent, default 1')
    parser.add_argument('--kind-threshold', type=kind_threshold, action='append', default=[], metavar='KIND=PERCENT',
                        help='percent for one kind (quest, arm64-v8a, armeabi-v7a, x86_64, universal, aab)')
    args = parser.parse_args(argv)
    # The one-time thresholds of the release compared with, then those given by hand, which win
    one_time = ONE_TIME_KIND_THRESHOLDS.get(args.release, {})
    given = dict(args.kind_threshold)
    thresholds = {**one_time, **given}
    for what, threshold in sorted(one_time.items()):
        if what not in given:
            print(f'{what}: one-time threshold of {threshold:g} % against {args.release} (ONE_TIME_KIND_THRESHOLDS)')

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
