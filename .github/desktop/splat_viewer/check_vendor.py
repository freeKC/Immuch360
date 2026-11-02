#!/usr/bin/env python3
"""The engine files of the splat viewer's page are those Spark's build gave (lot SV0 of the splat viewer).

licenses/splat-viewer/MANIFEST lists, with their SHA-256 and sizes, the files spark_build.py wrote: the page's engine
(spark.module.min.js, spark_rs_bg.wasm, three.module.min.js, three.core.min.js, Pass.js), committed under
mobile/assets/splat_viewer, and its licences (licenses/...), committed under mobile/assets/licenses/splat-viewer.

  check_vendor.py                 every file of MANIFEST in place with its bytes, and no other engine file in the
                                  page's folder than those and the page's own files (OWN_FILES)
  check_vendor.py --built DIR     the output of a build (the spark job) gives the same bytes as MANIFEST: the build
                                  is reproducible and the committed files are what it gives; passes with a note while
                                  nothing is committed yet
"""
from __future__ import annotations

import argparse
import hashlib
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
MANIFEST = ROOT / 'licenses' / 'splat-viewer' / 'MANIFEST'
PAGE = ROOT / 'mobile' / 'assets' / 'splat_viewer'
LICENCES = ROOT / 'mobile' / 'assets' / 'licenses' / 'splat-viewer'

# The page's own files, written in the repository (not built)
OWN_FILES = {
    'index.html', 'viewer.js', 'session.js', 'placement.js', 'controls.js', 'panel.js', 'events.js', 'adapt.js',
    'engine-spark.js', 'viewer.css',
}


def manifest_entries(text: str) -> list:
    """(sha256, size, path) of each line of a MANIFEST"""
    entries = []
    for line in text.splitlines():
        if not line.strip() or line.startswith('#'):
            continue
        digest, size, path = line.split()
        entries.append((digest, int(size), path))
    return entries


def committed_path(relative: str) -> pathlib.Path:
    if relative.startswith('licenses/'):
        return LICENCES / relative[len('licenses/'):]
    return PAGE / relative


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_committed() -> list:
    found = []
    if not MANIFEST.exists():
        engine = [path.name for path in sorted(PAGE.iterdir()) if path.name not in OWN_FILES] if PAGE.exists() else []
        if engine:
            return [f'{MANIFEST.relative_to(ROOT)} is missing for {", ".join(engine)}']
        print(f'no engine file yet and no {MANIFEST.relative_to(ROOT)}')
        return []
    entries = manifest_entries(MANIFEST.read_text(encoding='utf-8'))
    listed = set()
    for digest, size, relative in entries:
        path = committed_path(relative)
        listed.add(path.resolve())
        if not path.exists():
            found.append(f'{path.relative_to(ROOT)} is missing')
            continue
        if path.stat().st_size != size or sha256(path) != digest:
            found.append(f'{path.relative_to(ROOT)} is not the file of MANIFEST')
    for path in sorted(PAGE.iterdir()) if PAGE.exists() else []:
        if path.name not in OWN_FILES and path.resolve() not in listed:
            found.append(f'{path.relative_to(ROOT)} is neither a file of MANIFEST nor a file of the page')
    for path in sorted(LICENCES.iterdir()) if LICENCES.exists() else []:
        if path.resolve() not in listed:
            found.append(f'{path.relative_to(ROOT)} is not a file of MANIFEST')
    return found


def check_built(built: pathlib.Path) -> list:
    if not MANIFEST.exists():
        print(f'nothing committed yet ({MANIFEST.relative_to(ROOT)} is missing): the build is not compared')
        return []
    committed = manifest_entries(MANIFEST.read_text(encoding='utf-8'))
    made = manifest_entries((built / 'MANIFEST').read_text(encoding='utf-8'))
    found = []
    if committed != made:
        for entry in sorted(set(committed) ^ set(made), key=lambda item: item[2]):
            side = 'committed' if entry in committed else 'built'
            found.append(f'{entry[2]}: {side} {entry[0]} ({entry[1]} bytes)')
    for _, _, relative in made:
        if sha256(built / relative) != next((d for d, _, r in made if r == relative), None):
            found.append(f'{relative}: the built file is not the one its own MANIFEST lists')
    return found


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--built', type=pathlib.Path, help='the output folder of spark_build.py')
    arguments = parser.parse_args(argv)
    found = check_built(arguments.built) if arguments.built else check_committed()
    for line in found:
        print(line)
    if found:
        return 1
    if MANIFEST.exists():
        print('the engine files of the splat viewer are those of MANIFEST')
    return 0


if __name__ == '__main__':
    sys.exit(main())
