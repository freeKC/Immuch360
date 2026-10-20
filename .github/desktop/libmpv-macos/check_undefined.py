#!/usr/bin/env python3
"""Fails when a framework of the macOS libmpv calls a function that no library defines.

mpv links with -undefined dynamic_lookup (b_lundef=false in its meson.build), so a function declared and never
defined links all the same and becomes a jump to address 0 when it is first called: mpv_create crashed so on
libmpv-macos-20261020-8, whose mpv called the Cocoa bridge of its Swift part (cocoa_set_input_context), which this
build does not make. Run by .github/workflows/immuch360-libmpv.yml on the zips of the xcframeworks, on macOS (nm).

  check_undefined.py ZIP...

Each framework binary of each zip, every architecture: the symbols nm lists as "dynamically looked up" must be
functions the process finds in a library it has loaded anyway (ALLOWED). Exit 1 otherwise, with the symbols.
"""
from __future__ import annotations

import pathlib
import re
import subprocess
import sys
import tempfile

# IOSurface comes with CoreVideo, which mpv links; libobjc is linked by mpv itself
ALLOWED = re.compile(r'^_(IOSurface\w+|objc_msgSend)$')
LOOKED_UP = re.compile(r'\(undefined\) external (\S+) \(dynamically looked up\)')


def looked_up(binary: pathlib.Path) -> set[str]:
    result = subprocess.run(['nm', '-m', '-u', '-arch', 'all', str(binary)], capture_output=True, text=True,
                            check=True)
    return {match[1] for match in LOOKED_UP.finditer(result.stdout)}


def framework_binaries(folder: pathlib.Path) -> list[pathlib.Path]:
    """The binary of each framework: Versions/A/<name> in a macOS framework, <name> in a flat one"""
    found = []
    for framework in sorted(folder.rglob('*.framework')):
        for binary in (framework / 'Versions' / 'A' / framework.stem, framework / framework.stem):
            if binary.is_file() and not binary.is_symlink():
                found.append(binary)
                break
    return found


def main(zips: list[str]) -> int:
    if not zips:
        print(__doc__)
        return 2
    failed = False
    for name in zips:
        with tempfile.TemporaryDirectory() as temp:
            # unzip keeps the symbolic links of the framework, which zipfile would write as small text files
            subprocess.run(['unzip', '-q', name, '-d', temp], check=True)
            binaries = framework_binaries(pathlib.Path(temp))
            if not binaries:
                print(f'{name}: no framework binary')
                failed = True
            for binary in binaries:
                symbols = looked_up(binary)
                unknown = sorted(symbol for symbol in symbols if not ALLOWED.match(symbol))
                print(f'{binary.name}: {len(symbols)} symbols looked up at run time, {len(unknown)} not allowed')
                for symbol in unknown:
                    print(f'  {symbol}: no library defines it, a call jumps to address 0')
                failed |= bool(unknown)
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
