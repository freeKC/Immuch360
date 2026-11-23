#!/usr/bin/env python3
"""The runtime of the graphics card of the 3D videos on Windows (lot ai-360-3d-51, 23 Nov 2026): the files of the
prerelease ai-components-6, made from the official NuGet package Microsoft.ML.OnnxRuntime.DirectML 1.24.4 (MIT).

The package is fetched from api.nuget.org and checked by its size and SHA-256 (PACKAGE below). Its LICENSE must be the
MIT licence of Microsoft. Out of it come, in OUT:
  onnxruntime-directml-1.24.4-win-x64.dll.gz      runtimes/win-x64/native/onnxruntime.dll as it is (its Authenticode
                                                  signature kept), gzip compressed without name or date, as the
                                                  libraries of ai-components-1
  onnxruntime-directml-1.24.4-LICENSE.txt         LICENSE of the package
  onnxruntime-directml-1.24.4-ThirdPartyNotices.txt
  SHA256SUMS
and with --plain DIR the DLL unpacked (DIR/onnxruntime.dll), for the tests and the test ZIP of the CI. DirectML.dll
of the package Microsoft.AI.DirectML is NOT taken: its licence (Microsoft software licence terms) is not one this
project allows; the library calls the DirectML.dll of Windows (System32) instead.

The entry of the app (mobile/lib/domain/models/ai_immersive/ai_gpu_runtime_manifest.dart) must give the same size, sum
and download size, and the same size and sum of the notices: checked, exit 1 when they differ. Nothing is published:
the prerelease is made by hand once it is decided (the command printed at the end).

  gpu_runtime.py --out DIR [--plain DIR] [--cache DIR]
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import pathlib
import re
import sys
import urllib.request
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
MANIFEST = ROOT / 'mobile' / 'lib' / 'domain' / 'models' / 'ai_immersive' / 'ai_gpu_runtime_manifest.dart'
TAG = 'ai-components-6'
VERSION = '1.24.4'
PACKAGE = ('microsoft.ml.onnxruntime.directml.1.24.4.nupkg',
           'https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime.directml/1.24.4/'
           'microsoft.ml.onnxruntime.directml.1.24.4.nupkg',
           12458649, '57e9f11b73437bef7a309496135d4c1f96b1a8e9ddba60013fa27bfc1d788681')
LIBRARY = 'runtimes/win-x64/native/onnxruntime.dll'
ASSET = f'onnxruntime-directml-{VERSION}-win-x64.dll.gz'
LICENSE_ASSET = f'onnxruntime-directml-{VERSION}-LICENSE.txt'
NOTICES_ASSET = f'onnxruntime-directml-{VERSION}-ThirdPartyNotices.txt'
MIT_START = b'MIT License'


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def packed(data: bytes) -> bytes:
    """[data] gzip compressed, without name nor date (publish_ai_components.py packed)"""
    buffer = io.BytesIO()
    with gzip.GzipFile(filename='', mode='wb', fileobj=buffer, compresslevel=9, mtime=0) as stream:
        stream.write(data)
    return buffer.getvalue()


def fetch(caches: list) -> bytes:
    name, url, size, digest = PACKAGE
    for cache in caches:
        path = pathlib.Path(cache) / name
        if path.is_file():
            data = path.read_bytes()
            if len(data) == size and sha256(data) == digest:
                print(f'{name}: from {cache}')
                return data
    request = urllib.request.Request(url, headers={'User-Agent': 'immuch360-ai-components'})
    with urllib.request.urlopen(request, timeout=120) as response:
        data = response.read()
    if len(data) != size or sha256(data) != digest:
        sys.exit(f'{name}: {len(data)} bytes, SHA-256 {sha256(data)}; expected {size} and {digest}')
    if caches:
        pathlib.Path(caches[0]).mkdir(parents=True, exist_ok=True)
        (pathlib.Path(caches[0]) / name).write_bytes(data)
    print(f'{name}: downloaded, {size} bytes, SHA-256 {digest}')
    return data


def manifest_values(text: str) -> dict:
    """The size, sum and download size of the component, and the size and sum of its notices, as the app has them"""
    consts = dict(re.findall(r"^const (\w+) = '([^']*)';$", text, re.MULTILINE))

    def field(block: str, key: str) -> str:
        found = re.search(rf'^  {key}: (.+),$', block, re.MULTILINE)
        if not found:
            sys.exit(f'{MANIFEST.name}: no {key}')
        value = found.group(1).strip()
        return value.strip("'") if value.startswith("'") else consts.get(value, value)

    component = re.search(r'^const onnxRuntimeDirectMlComponent = AiComponent\(\n(.*?)^\);', text,
                          re.MULTILINE | re.DOTALL)
    notices = re.search(r'^const _directMlNotices = AiNoticesFile\(\n(.*?)^\);', text, re.MULTILINE | re.DOTALL)
    if not component or not notices:
        sys.exit(f'{MANIFEST.name}: the component or its notices are not found')
    body, notes = component.group(1), notices.group(1)
    return {
        'assetName': field(body, 'assetName'), 'size': int(field(body, 'size')), 'sha256': field(body, 'sha256'),
        'downloadSize': int(field(body, 'downloadSize')), 'releaseTag': field(body, 'releaseTag'),
        'licence': field(body, 'licence'), 'notices': (field(notes, 'assetName'), int(field(notes, 'size')),
                                                         field(notes, 'sha256')),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--out', type=pathlib.Path, required=True)
    parser.add_argument('--plain', type=pathlib.Path)
    parser.add_argument('--cache', action='append', default=[])
    args = parser.parse_args()

    package = zipfile.ZipFile(io.BytesIO(fetch(args.cache)))
    library = package.read(LIBRARY)
    licence = package.read('LICENSE')
    notices = package.read('ThirdPartyNotices.txt')
    if not licence.lstrip(b'\xef\xbb\xbf').startswith(MIT_START) or b'Microsoft Corporation' not in licence:
        sys.exit('LICENSE of the package is not the MIT licence of Microsoft')
    if any(name.lower().endswith('directml.dll') for name in package.namelist()):
        sys.exit('the package holds a DirectML.dll: it must not be taken')
    compressed = packed(library)
    files = {ASSET: compressed, LICENSE_ASSET: licence, NOTICES_ASSET: notices}
    args.out.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (args.out / name).write_bytes(data)
    sums = ''.join(f'{sha256(data)}  {name}\n' for name, data in sorted(files.items()))
    # LF on every system: write_text would give CRLF on the Windows runner
    (args.out / 'SHA256SUMS').write_bytes(sums.encode('ascii'))
    if args.plain:
        args.plain.mkdir(parents=True, exist_ok=True)
        (args.plain / 'onnxruntime.dll').write_bytes(library)
        (args.plain / 'LICENSE.txt').write_bytes(licence)
        (args.plain / 'ThirdPartyNotices.txt').write_bytes(notices)

    print(f'{LIBRARY}: {len(library)} bytes, SHA-256 {sha256(library)}')
    for name, data in sorted(files.items()):
        print(f'{name}: {len(data)} bytes, SHA-256 {sha256(data)}')

    app = manifest_values(MANIFEST.read_text(encoding='utf-8'))
    wanted = {
        'assetName': ASSET, 'size': len(library), 'sha256': sha256(library), 'downloadSize': len(compressed),
        'releaseTag': TAG, 'licence': 'MIT', 'notices': (NOTICES_ASSET, len(notices), sha256(notices)),
    }
    wrong = [f'{key}: the app has {app[key]!r}, the package gives {value!r}' for key, value in wanted.items()
             if app[key] != value]
    if wrong:
        print('\n'.join(wrong), file=sys.stderr)
        return 1
    print(f'{MANIFEST.name} agrees with the files')
    total = sum(len(data) for data in files.values()) + len(sums)
    print(f'to publish (not done here): the prerelease {TAG} of freeKC/Immuch360, never Latest, {len(files) + 1} '
          f'files, {total} bytes:')
    print(f'  gh release create {TAG} --repo freeKC/Immuch360 --prerelease --latest=false --title "{TAG}" '
          f'--notes-file <notes> {" ".join(sorted([*files, "SHA256SUMS"]))}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
