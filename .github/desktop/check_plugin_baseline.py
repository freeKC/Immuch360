#!/usr/bin/env python3
"""Gate of Immuch360 Desktop: the Android and iOS plugin lists stay those of the baseline.

The desktop work adds packages for Windows, macOS and Linux only. A package that also declares android or ios would
join the phone builds unnoticed; this check reads mobile/.flutter-plugins-dependencies, which `flutter pub get`
writes with one plugin list per platform, and compares the android and ios lists with plugin-baseline.json. The
desktop lists are printed for the record, never compared: they are expected to grow. The versions of the packages
the phones are built with are checked by check_phone_packages.py, against the phone branch rather than a baseline,
so that a phone release merged into the desktop branch needs no update here.

  check_plugin_baseline.py           compare (exit 1 on any difference, 2 when the plugin file is missing)
  check_plugin_baseline.py --update  rewrite the baseline on purpose, after a change reviewed for the phones

--plugins and --baseline point at other files (the tests use fixtures).
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PHONES = ('android', 'ios')
DESKTOPS = ('windows', 'linux', 'macos')


def plugin_lists(plugins_file: pathlib.Path) -> dict:
    data = json.loads(plugins_file.read_text(encoding='utf-8'))
    plugins = data['plugins']
    return {platform: sorted(plugin['name'] for plugin in plugins.get(platform, [])) for platform in PHONES + DESKTOPS}


def differences(now: dict, baseline: dict) -> list:
    found = []
    for platform in PHONES:
        added = sorted(set(now[platform]) - set(baseline.get(platform, [])))
        removed = sorted(set(baseline.get(platform, [])) - set(now[platform]))
        if added or removed:
            found.append(f'{platform}: plugins added {added}, removed {removed}')
    return found


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--plugins', type=pathlib.Path, default=ROOT / 'mobile' / '.flutter-plugins-dependencies')
    parser.add_argument('--baseline', type=pathlib.Path, default=HERE / 'plugin-baseline.json')
    parser.add_argument('--update', action='store_true', help='rewrite the baseline from the current lists')
    args = parser.parse_args(argv)

    if not args.plugins.exists():
        print(f'{args.plugins} is missing: run flutter pub get in mobile first')
        return 2
    now = plugin_lists(args.plugins)
    if args.update:
        args.baseline.write_text(json.dumps({p: now[p] for p in PHONES}, indent=2) + '\n', encoding='utf-8')
        print('baseline written: ' + ', '.join(f'{p} {len(now[p])}' for p in PHONES))
        return 0

    baseline = json.loads(args.baseline.read_text(encoding='utf-8'))
    found = differences(now, baseline)
    for line in found:
        print(line)
    for platform in PHONES:
        if not any(line.startswith(f'{platform}:') for line in found):
            print(f'{platform}: {len(now[platform])} plugins, as the baseline')
    print('for the record: ' + ', '.join(f'{p} {len(now[p])}' for p in DESKTOPS))
    if found:
        print('The phone plugin lists changed. If that is wanted, run check_plugin_baseline.py --update and say why.')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
