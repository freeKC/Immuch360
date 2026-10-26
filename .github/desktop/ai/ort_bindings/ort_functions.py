#!/usr/bin/env python3
"""The entries of the ONNX Runtime table the app calls, with their place in it (ort_functions.json).

The table of functions (struct OrtApi) only grows: each release appends its new entries, and GetApi(n) gives the table
as it stood at API n, so an entry is reached by its place. The app asks for API 23, the API of ONNX Runtime 1.23.2,
the last release with a build for Intel Macs; 1.31.0 gives the same table for that request, with more entries after.
An entry the app calls must therefore sit below the size of the table of API 23, and have the same name there.

Reads the bindings ffigen wrote from the header of 1.31.0, the bindings of the header of 1.23.2 (generate.sh makes
them in a temporary folder), and the Dart files of mobile/lib/desktop/ai/ort, where every call goes through
`<pointer>.ref.<Entry>`. Writes the entries called, their place, and both table sizes. The test
test/desktop/ai/ort/ort_bindings_test.dart checks the file against the bindings and the code on every run.

  ort_functions.py --bindings <1.31.0.dart> --api23 <1.23.2.dart> --sources <dir> --out ort_functions.json
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

STRUCT = re.compile(r'^final class OrtApi extends ffi\.Struct \{\n(.*?)^\}', re.MULTILINE | re.DOTALL)
FIELD_NAME = re.compile(r'(\w+)\s*$')
CALL = re.compile(r'\.ref\.(\w+)')
API_VERSION = 23
HEADER_1_23_2 = ('https://github.com/microsoft/onnxruntime/blob/a83fc4d58cb48eb68890dd689f94f28288cf2278/'
                 'include/onnxruntime/core/session/onnxruntime_c_api.h')


def table(bindings: str) -> list:
    """The entries of struct OrtApi, in their order"""
    found = STRUCT.search(bindings)
    if not found:
        sys.exit('no "final class OrtApi extends ffi.Struct" in the bindings')
    names = []
    for chunk in found.group(1).split(';'):
        if 'external' in chunk:
            name = FIELD_NAME.search(chunk.strip())
            names.append(name.group(1))
    return names


def called(sources: pathlib.Path, entries: set, skip: str) -> list:
    names = set()
    for path in sorted(sources.glob('*.dart')):
        if path.name == skip:
            continue
        names.update(name for name in CALL.findall(path.read_text(encoding='utf-8')) if name in entries)
    return sorted(names)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--bindings', type=pathlib.Path, required=True)
    parser.add_argument('--api23', type=pathlib.Path, required=True)
    parser.add_argument('--sources', type=pathlib.Path, required=True)
    parser.add_argument('--out', type=pathlib.Path, required=True)
    args = parser.parse_args()

    current = table(args.bindings.read_text(encoding='utf-8'))
    older = table(args.api23.read_text(encoding='utf-8'))
    renamed = [f'{rank}: {old} became {new}' for rank, (old, new) in enumerate(zip(older, current)) if old != new]
    names = called(args.sources, set(current), args.bindings.name)
    problems = []
    entries = []
    for name in names:
        rank = current.index(name)
        if rank >= len(older):
            problems.append(f'{name} is entry {rank}, not in the table of API {API_VERSION} ({len(older)} entries)')
        elif older[rank] != name:
            problems.append(f'{name} is entry {rank}, which is {older[rank]} in the table of API {API_VERSION}')
        entries.append({'name': name, 'rank': rank})
    for line in renamed:
        print(f'note: entry renamed since API {API_VERSION}: {line}')
    if problems:
        for line in problems:
            print(f'error: {line}', file=sys.stderr)
        return 1
    document = {
        'about': 'The entries of struct OrtApi that mobile/lib/desktop/ai/ort calls, with their place in the table '
                 '(from 0). Written by .github/desktop/ai/ort_bindings/generate.sh; checked by '
                 'test/desktop/ai/ort/ort_bindings_test.dart.',
        'apiVersion': API_VERSION,
        'tableSize': {'api23': len(older), 'api31': len(current)},
        'api23Header': HEADER_1_23_2,
        'functions': entries,
    }
    args.out.write_text(json.dumps(document, indent=2) + '\n', encoding='utf-8')
    print(f'{len(entries)} entries called, table of API {API_VERSION}: {len(older)} entries, of API 31: {len(current)}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
