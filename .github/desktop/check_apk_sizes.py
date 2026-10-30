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
    # release 31. The packages of feat-ai-immersive at 8e50a3a1d (CI run 40783336966, same tree; the same to the byte at
    # 852935654, run 40788776138), against release 31:
    #   The Quest APK, 155,878,518 bytes against 144,411,843, +7.94 %: the AI relief and the 3D scenes first, +6.99 %,
    #   of which LiteRT 2.3.0 is about 9.4 MB of native libraries in the Quest APK alone (design-final 2026-10-26,
    #   section 3.10, the reason for the 7 % first planned); the panoramas next, 65,720 bytes more, a step of 64 KiB
    #   that phase23/lots/integration-vague-5.md puts down to an alignment boundary crossed by the small changes of the
    #   Dart code shared by the phones and the Quest (not verified there), 47,126 bytes over 7 %; then the texts below,
    #   1,310,720 bytes more.
    #   The phone packages, each under 1 % at 0c066ba38 (+0.32 to +0.61 %), then over it: the 257 AI texts in 88
    #   languages, compiled into libapp.so by CodegenLoader, add 1.25 MiB to the library of each ABI (1,310,720 bytes;
    #   1,605,632 for armeabi-v7a), so the AAB 231,967,368 bytes (+2.88 %), armeabi-v7a 86,562,924 (+2.49 %), x86_64
    #   92,618,497 (+1.95 %), the universal APK 291,538,887 (+1.93 %, its three libraries) and arm64-v8a 146,183,068
    #   (+1.23 %).
    # Each threshold leaves at least half a point for the fixes of the headset tests. Once build 32 is published, the
    # next release compares with it, this entry no longer applies, and every kind is back to the ordinary threshold.
    'v3.3.0-rc.0-31': {'quest': 8.5, 'aab': 3.5, 'armeabi-v7a': 3, 'universal': 2.5, 'x86_64': 2.5, 'arm64-v8a': 2},
    # 30 October 2026, for the release that brings the Gaussian splats (lot S5, branch feat-quest-splats), compared
    # with release 35. The Quest APK alone carries the splat module of the Meta Spatial SDK 0.14.0
    # (questImplementation: libMetaSpatialSDKSplat.so and its classes, about 1.1 MB). The packages of the branch at
    # 739dd6bb3 (CI job 124263073041), against release 35:
    #   The Quest APK, 157,873,379 bytes against 156,452,346, +0.908 %: 0.09 point under the ordinary threshold, about
    #   144 KB, so that one more step of 64 KiB of alignment, or a fix of the headset tests, would refuse it.
    #   The phone packages, which do not carry the module, +0.243 to +0.492 %: they keep the ordinary threshold.
    # 1.5 % leaves about half a point for the fixes of the headset tests. Should another release be published before
    # the one with the splats, this entry moves to the tag that release becomes.
    'v3.3.0-rc.0-35': {'quest': 1.5},
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
