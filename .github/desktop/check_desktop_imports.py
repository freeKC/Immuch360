#!/usr/bin/env python3
"""Gate of Immuch360 Desktop: the desktop packages are imported under mobile/lib/desktop only.

The shared files of the app hold at most a guarded line that hands over to lib/desktop/; they never import a
desktop package themselves, so that the phones never compile against one and upstream merges stay small. This holds
for lib/main_desktop.dart too: it hands over to lib/desktop/desktop_start.dart. Besides the packages named below,
every package whose name ends in _windows, _linux or _macos counts: those are the desktop sides of federated plugins
(path_provider_windows, file_selector_linux, ...), which only the desktop code has a reason to call directly.

  check_desktop_imports.py           exit 1 when a shared file imports a desktop package

--root points at another tree (the tests use fixtures).
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
FORBIDDEN = (
    # Video and camera (phases 2 and 3)
    'media_kit',
    'media_kit_video',
    'media_kit_libs_windows_video',
    'media_kit_libs_linux',
    'media_kit_libs_macos_video',
    'camera_desktop',
    # The window
    'window_manager',
    'screen_retriever',
    'window_to_front',
    # Desktop only plugins and Windows APIs
    'desktop_webview_window',
    'flutter_secure_storage_windows',
    'win32',
    'win32_registry',
    # The fork's own desktop packages
    'immuch_head_tracker',
    'immuch_desktop_video',
)
# The desktop sides of federated plugins; _darwin is left out, it serves iOS too
DESKTOP_SIDE = re.compile(r'_(?:windows|linux|macos)$')
IMPORT = re.compile(r"""^\s*(?:import|export)\s+['"]package:([a-z0-9_]+)/""", re.MULTILINE)


def offending(root: pathlib.Path) -> list:
    lib = root / 'mobile' / 'lib'
    desktop = lib / 'desktop'
    bad = []
    for path in sorted(lib.rglob('*.dart')):
        if desktop in path.parents:
            continue
        for package in IMPORT.findall(path.read_text(encoding='utf-8', errors='replace')):
            if package in FORBIDDEN or DESKTOP_SIDE.search(package):
                bad.append(f'{path.relative_to(root).as_posix()}: imports package:{package}')
    return bad


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--root', type=pathlib.Path, default=ROOT, help='repository root')
    args = parser.parse_args(argv)

    bad = offending(args.root)
    for line in bad:
        print(line)
    if bad:
        print('Desktop packages are imported under mobile/lib/desktop only')
        return 1
    print('No desktop package imported outside mobile/lib/desktop')
    return 0


if __name__ == '__main__':
    sys.exit(main())
