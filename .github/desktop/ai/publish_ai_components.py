#!/usr/bin/env python3
"""The files of the prerelease ai-components-1: the AI components Immuch360 downloads when the user asks for them.

Design: store/m2/ai-immersive-2026-10-26/design-final-2026-10-26.md, sections 2.2 and 4.6 (lot A3b). The app carries a
catalogue of these files with the size and the SHA-256 of each (mobile/lib/domain/models/ai_immersive/
ai_components_manifest.dart) and takes them from the release, never from a remote manifest. This script makes the files
of the release from their official sources, and the entries of the catalogue from those files:

  1. the official archives of ONNX Runtime (MIT): 1.31.0 for Windows x64, Linux x64 and macOS arm64, and 1.23.2 for
     macOS x86_64, the last release with an archive for the Intel Macs; each checked by the SHA-256 GitHub gives for it
     (ARCHIVES below, read from the GitHub API on 27 October 2026);
  2. the library of each archive, as it is (the Authenticode signature of the DLL kept), gzip compressed without name
     or date: onnxruntime-<version>-<platform>.<ext>.gz, which the app unpacks while it downloads;
  3. the LICENSE and the ThirdPartyNotices.txt of each version of ONNX Runtime (the same text in every archive of a
     version, the Windows one with CRLF line ends: the LF copy is kept, the others are compared to it);
  4. the two depth models, Depth Anything V2 Small (Apache-2.0), fp32 ONNX for the computers and fp32 LiteRT for the
     Quest, from their official source pinned to a commit, checked by the sums of the catalogue;
  5. MODEL-LICENSES.md (the copy of licenses/ai-components/MODEL-LICENSES.md, dated) and SHA256SUMS.

  publish_ai_components.py --out DIR [--cache DIR]... [--write]
      makes the files in DIR and prints their sizes and sums, then says whether the catalogue and MODEL-LICENSES.md of
      the repository agree with them. A file found in a --cache folder (or in DIR) with the right SHA-256 is not
      downloaded again; a download goes to the first --cache folder, else to a temporary one. With --write, the
      entries of ONNX Runtime in the catalogue (size, sha256, downloadSize, and the size and SHA-256 of its notices)
      and MODEL-LICENSES.md are written.
  publish_ai_components.py --out DIR [--cache DIR]... --publish [--token-file FILE]
      the same, then the prerelease ai-components-1 on freeKC/Immuch360 with the files of DIR, only when the catalogue
      and MODEL-LICENSES.md of the repository agree with them. Made as a draft, filled, then published as a
      prerelease that is never "Latest" (the app reads releases/latest); its tag starts with no "v", so no release
      workflow runs on it (the upstream workflows that run on a published release are disabled in the fork). A
      release that exists already is never touched.
  publish_ai_components.py --check
      offline: every component of the catalogue is complete, its file and sums are those of the table below, and
      MODEL-LICENSES.md names each file with its size and SHA-256 (test/desktop/ci/publish_ai_components_test.dart)

Without --publish nothing leaves this computer; the only network use is the download of the official files. --sources
FILE replaces the addresses and upstream sums of the tables below (the tests serve small archives at file://
addresses); --catalogue, --licences, --date, --repo and --api point at other files, dates and servers (the tests). The
token comes from GH_TOKEN or GITHUB_TOKEN, or from --token-file, and is never printed. Only the Python standard
library is used. Exit codes: 0 done, 1 a check failed or GitHub refused, 2 bad arguments, files or token.
"""
from __future__ import annotations

import argparse
import dataclasses
import datetime
import gzip
import hashlib
import io
import json
import os
import pathlib
import re
import shutil
import sys
import tarfile
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
CATALOGUE = ROOT / 'mobile' / 'lib' / 'domain' / 'models' / 'ai_immersive' / 'ai_components_manifest.dart'
LICENCES = ROOT / 'licenses' / 'ai-components' / 'MODEL-LICENSES.md'
API = 'https://api.github.com'
REPO = 'freeKC/Immuch360'
TAG = 'ai-components-1'
SUMS = 'SHA256SUMS'
LICENCES_NAME = 'MODEL-LICENSES.md'
ORT_RELEASES = 'https://github.com/microsoft/onnxruntime/releases/download'
USER_AGENT = 'immuch360-ai-components'


@dataclasses.dataclass(frozen=True)
class Archive:
    """An official archive of ONNX Runtime and the library the app installs from it"""
    component: str
    name: str
    version: str
    size: int
    sha256: str
    library: str

    @property
    def url(self) -> str:
        return f'{ORT_RELEASES}/v{self.version}/{self.name}'

    @property
    def folder(self) -> str:
        return self.name.removesuffix('.zip').removesuffix('.tgz')


@dataclasses.dataclass(frozen=True)
class Model:
    """A depth model, as its official source gives it"""
    component: str
    url: str
    size: int
    sha256: str
    source: str
    revision: str
    use: str


ARCHIVES = (
    Archive('onnxruntime-1.31.0-win-x64', 'onnxruntime-win-x64-1.31.0.zip', '1.31.0', 82887349,
            '3958d8a44984160692c1b4ffd0de3cb48f8c39f9d34bb31e433db06e30b82195', 'lib/onnxruntime.dll'),
    Archive('onnxruntime-1.31.0-linux-x64', 'onnxruntime-linux-x64-1.31.0.tgz', '1.31.0', 11408003,
            'cc5c72baf5ae5c8238a6841f0897227be2d02826b9cf98eaf02fdefaeeb03a57', 'lib/libonnxruntime.so.1.31.0'),
    Archive('onnxruntime-1.31.0-osx-arm64', 'onnxruntime-osx-arm64-1.31.0.tgz', '1.31.0', 36549009,
            '1031b36dd3bdaa8d976a6130d9cf2a05e9be320b93ae804f8427b91dc3432afc', 'lib/libonnxruntime.1.31.0.dylib'),
    Archive('onnxruntime-1.23.2-osx-x86_64', 'onnxruntime-osx-x86_64-1.23.2.tgz', '1.23.2', 11676322,
            'd10359e16347b57d9959f7e80a225a5b4a66ed7d7e007274a15cae86836485a6', 'lib/libonnxruntime.1.23.2.dylib'),
)

# The archive whose LICENSE and ThirdPartyNotices.txt go into the release, per version: one with LF line ends
TEXTS_FROM = {'1.31.0': 'onnxruntime-1.31.0-linux-x64', '1.23.2': 'onnxruntime-1.23.2-osx-x86_64'}

HF_ONNX = 'https://huggingface.co/onnx-community/depth-anything-v2-small'
HF_LITERT = 'https://huggingface.co/litert-community/depth-anything-v2-small'
MODELS = (
    Model('depth-anything-v2-small-onnx',
          f'{HF_ONNX}/resolve/4472b7362082ad9968fee890ca0f1e5aca36b93d/onnx/model.onnx', 99060839,
          'afb6a5c28f3b6bf1618c6e43f02073ef9dfdc70e937502d51603e57b0a1df10c', HF_ONNX, '4472b736',
          'the computers (Windows, Linux, macOS), fp32 ONNX'),
    Model('depth-anything-v2-small-tflite',
          f'{HF_LITERT}/resolve/178427e448dbf4da93b1e7b1b2abc103ad329bd6/tflite/depth_anything_v2_small.tflite',
          99530468, '651415f1774e02d06de946eccf2e6dbbc5f499a9e932d9de7ada3d59637d2e8e', HF_LITERT, '178427e4',
          'the Meta Quest, fp32 LiteRT'),
)

CONTENT_TYPES = {'.gz': 'application/gzip', '.txt': 'text/plain', '.md': 'text/markdown', '.onnx':
                 'application/octet-stream', '.tflite': 'application/octet-stream'}


class Failure(Exception):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


# --- the catalogue of the app -------------------------------------------------------------------------------------

COMPONENT_BLOCK = re.compile(r'^const (\w+) = AiComponent\(\n(.*?)^\);\n', re.MULTILINE | re.DOTALL)
NOTICES_BLOCK = re.compile(r'^const (\w+) = AiNoticesFile\(\n(.*?)^\);\n', re.MULTILINE | re.DOTALL)
STRING_CONST = re.compile(r"^const (_?\w+) = '([^']*)';$", re.MULTILINE)
FIELD = re.compile(r"^  (\w+): (.+),$", re.MULTILINE)


def dart_value(text: str, consts: dict):
    """The value of a field of the catalogue: a string, an int, null, or a name (a const string resolved)"""
    text = text.strip()
    if text == 'null':
        return None
    if re.fullmatch(r"'[^']*'", text):
        return text[1:-1]
    if re.fullmatch(r'\d+', text):
        return int(text)
    return consts.get(text, text)


def read_catalogue(text: str) -> dict:
    """The components of the catalogue by id, each a dict of its fields, the notices resolved"""
    consts = dict(STRING_CONST.findall(text))
    notices = {}
    for name, body in NOTICES_BLOCK.findall(text):
        notices[name] = {key: dart_value(value, consts) for key, value in FIELD.findall(body)}
    components = {}
    for name, body in COMPONENT_BLOCK.findall(text):
        fields = {key: dart_value(value, consts) for key, value in FIELD.findall(body)}
        fields['const'] = name
        if isinstance(fields.get('notices'), str):
            fields['notices'] = notices.get(fields['notices'])
        components[fields['id']] = fields
    return components


def set_field(body: str, key: str, value: str, after: str) -> str:
    """[body] with the field [key] set to [value], added after the field [after] when missing"""
    line = re.compile(rf'^  {key}: .+,$', re.MULTILINE)
    if line.search(body):
        return line.sub(lambda _: f'  {key}: {value},', body, count=1)
    anchor = re.compile(rf'^  {after}: .+,$', re.MULTILINE)
    match = anchor.search(body)
    if match is None:
        raise Failure(f'the catalogue has no field {after} to put {key} after')
    return body[:match.end()] + f'\n  {key}: {value},' + body[match.end():]


def write_catalogue(text: str, libraries: dict, notices: dict) -> str:
    """The catalogue with the size, sum and download size of each library, and the size and sum of each notices file.
    [libraries]: component id -> (size, sha256, download size); [notices]: asset name -> (size, sha256)"""
    def component(match: re.Match) -> str:
        name, body = match.group(1), match.group(2)
        found = re.search(r"^  id: '([^']+)',$", body, re.MULTILINE)
        entry = libraries.get(found.group(1)) if found else None
        if entry is None:
            return match.group(0)
        size, digest, download = entry
        body = set_field(body, 'size', str(size), 'installPath')
        body = set_field(body, 'sha256', f"'{digest}'", 'size')
        body = set_field(body, 'downloadSize', str(download), 'compression')
        return f'const {name} = AiComponent(\n{body});\n'

    def notice(match: re.Match) -> str:
        name, body = match.group(1), match.group(2)
        found = re.search(r"^  assetName: '([^']+)',$", body, re.MULTILINE)
        entry = notices.get(found.group(1)) if found else None
        if entry is None:
            return match.group(0)
        size, digest = entry
        body = set_field(body, 'size', str(size), 'assetName')
        body = set_field(body, 'sha256', f"'{digest}'", 'size')
        return f'const {name} = AiNoticesFile(\n{body});\n'

    return NOTICES_BLOCK.sub(notice, COMPONENT_BLOCK.sub(component, text))


# --- the official files -------------------------------------------------------------------------------------------


def load_sources(path: pathlib.Path | None) -> tuple:
    """The tables, with the addresses and sums of [path] when given: {"archives": {name: {url, size, sha256}},
    "models": {component: {url, size, sha256}}}"""
    urls = {archive.name: archive.url for archive in ARCHIVES}
    archives, models = list(ARCHIVES), list(MODELS)
    if path is None:
        return archives, models, urls
    data = json.loads(path.read_text(encoding='utf-8'))
    for name, change in data.get('archives', {}).items():
        index = next(i for i, archive in enumerate(archives) if archive.name == name)
        archives[index] = dataclasses.replace(archives[index], size=change['size'], sha256=change['sha256'])
        urls[name] = change['url']
    for component, change in data.get('models', {}).items():
        index = next(i for i, model in enumerate(models) if model.component == component)
        models[index] = dataclasses.replace(models[index], url=change['url'], size=change['size'],
                                            sha256=change['sha256'])
    return archives, models, urls


def fetch(name: str, url: str, size: int, digest: str, places: list, downloads: pathlib.Path) -> pathlib.Path:
    """The file [name] with [size] bytes and the SHA-256 [digest]: found in [places], else downloaded from [url] into
    [downloads]. A file with another sum is never used; a download with another sum is deleted."""
    for folder in places:
        candidate = folder / name
        if candidate.is_file() and candidate.stat().st_size == size and sha256_file(candidate) == digest:
            print(f'{name}: found in {folder}, SHA-256 checked')
            return candidate
    downloads.mkdir(parents=True, exist_ok=True)
    target = downloads / name
    part = downloads / f'{name}.part'
    print(f'{name}: downloading {url}')
    request = urllib.request.Request(url, headers={'User-Agent': USER_AGENT})
    hasher = hashlib.sha256()
    try:
        with urllib.request.urlopen(request, timeout=300) as response, open(part, 'wb') as stream:
            for block in iter(lambda: response.read(1 << 20), b''):
                hasher.update(block)
                stream.write(block)
    except (urllib.error.URLError, OSError) as error:
        part.unlink(missing_ok=True)
        raise Failure(f'{name}: download failed from {url}: {error}') from None
    received = part.stat().st_size
    if received != size or hasher.hexdigest() != digest:
        part.unlink()
        raise Failure(f'{name}: {received} bytes, SHA-256 {hasher.hexdigest()}; expected {size} bytes, SHA-256 '
                      f'{digest}. Deleted.')
    os.replace(part, target)
    print(f'{name}: {size} bytes, SHA-256 checked')
    return target


def read_member(archive: pathlib.Path, member: str) -> bytes:
    """The regular file [member] of a .zip or .tgz archive, its name with or without a leading ./"""
    if archive.name.endswith('.zip'):
        with zipfile.ZipFile(archive) as bundle:
            try:
                return bundle.read(member)
            except KeyError:
                raise Failure(f'{archive.name} has no {member}') from None
    with tarfile.open(archive, 'r:gz') as bundle:
        for info in bundle.getmembers():
            if info.name.removeprefix('./') == member:
                if not info.isfile():
                    raise Failure(f'{archive.name}: {member} is not a regular file')
                return bundle.extractfile(info).read()
    raise Failure(f'{archive.name} has no {member}')


def packed(data: bytes) -> bytes:
    """[data] gzip compressed, without name nor date: the same bytes on every run of the same zlib"""
    buffer = io.BytesIO()
    with gzip.GzipFile(filename='', mode='wb', fileobj=buffer, compresslevel=9, mtime=0) as stream:
        stream.write(data)
    return buffer.getvalue()


def write_file(path: pathlib.Path, data: bytes) -> None:
    """[data] in [path], written beside then renamed; a file that already holds those bytes stays as it is"""
    if path.is_file() and path.stat().st_size == len(data) and sha256_file(path) == sha256_bytes(data):
        return
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_bytes(data)
    os.replace(temporary, path)


def text_asset(version: str, kind: str) -> str:
    return f'onnxruntime-{version}-{kind}.txt'


# --- MODEL-LICENSES.md --------------------------------------------------------------------------------------------

EXCLUDED = (
    ('Depth Anything V2 Base, Large and Giant', 'CC-BY-NC-4.0',
     'https://github.com/DepthAnything/Depth-Anything-V2#license'),
    ('DirectML.dll', 'Microsoft proprietary licence',
     'https://www.nuget.org/packages/Microsoft.AI.DirectML/1.15.4/License'),
    ('dxil.dll of the DirectX Shader Compiler', 'LICENSE-MS.txt, Microsoft software licence terms',
     'https://github.com/microsoft/DirectXShaderCompiler/releases/tag/v1.9.2609'),
    ('Qualcomm QNN', 'Qualcomm licence',
     'https://softwarecenter.qualcomm.com/api/download/software/licenses/ai_model_hub/v1/LICENSE.pdf'),
)


def licences_text(date: str, models: list, libraries: list, texts: dict) -> str:
    """MODEL-LICENSES.md. [models]: (component, model, asset); [libraries]: (component, archive, asset, size, sha256,
    download size); [texts]: asset name -> (size, sha256)"""
    lines = [
        '# Licences of the AI components of Immuch360',
        '',
        f'Date: {date}. Written by `.github/desktop/ai/publish_ai_components.py` from the files of the prerelease',
        f'`{TAG}`: https://github.com/{REPO}/releases/tag/{TAG}',
        '',
        'The app downloads a component only when the user asks for it, checks its SHA-256 against the catalogue built',
        'into the app, and copies its licence next to it (`ai-components/licenses/`). The depth model is Apache-2.0,',
        'ONNX Runtime is MIT. ONNX Runtime has other libraries built in, each under its own licence, listed in',
        'its notices (below): mostly BSD, Apache-2.0, MIT, Boost, zlib or public domain, and Eigen under MPL-2.0,',
        'a weak copyleft licence. The notices cover the whole ONNX Runtime project, not only what these builds',
        'hold. The libraries are redistributed as Microsoft built them, unmodified, with those notices. When two',
        'pages disagree on a licence, the more restrictive one applies.',
        '',
        '## Depth model: Depth Anything V2 Small, Apache-2.0',
        '',
        '| File | For | Size (bytes) | SHA-256 | Official source, pinned revision |',
        '| --- | --- | --- | --- | --- |',
    ]
    for component, model, asset in models:
        lines.append(f'| `{asset}` | {model.use} | {model.size} | `{model.sha256}` | {model.source}, revision '
                     f'`{model.revision}` |')
    lines += [
        '',
        'The weights: Apache-2.0 for the Small model (https://github.com/DepthAnything/Depth-Anything-V2#license,',
        'https://huggingface.co/depth-anything/Depth-Anything-V2-Small). The ONNX export of onnx-community and the',
        'LiteRT export of litert-community: Apache-2.0',
        '(https://huggingface.co/onnx-community/depth-anything-v2-small,',
        'https://huggingface.co/litert-community/depth-anything-v2-small/blob/main/LICENSE). The files are those of the',
        'official sources, byte for byte. Licence text: https://www.apache.org/licenses/LICENSE-2.0',
        '',
        '## ONNX Runtime, MIT',
        '',
        '| File | Component | Installed file | Size (bytes) | SHA-256 | Download (bytes) | Official archive | '
        'Archive SHA-256 |',
        '| --- | --- | --- | --- | --- | --- | --- | --- |',
    ]
    for component, archive, asset, size, digest, download in libraries:
        lines.append(f'| `{asset}` | `{component["id"]}` | `{archive.library.rsplit("/", 1)[-1]}` | {size} | '
                     f'`{digest}` | {download} | {archive.url} | `{archive.sha256}` |')
    lines += [
        '',
        'Each library is the one of the official archive of ONNX Runtime, as it is (the Authenticode signature of',
        '`onnxruntime.dll` kept), gzip compressed for the download; the app unpacks it and checks the SHA-256 of the',
        'installed file. Licence: MIT (https://github.com/microsoft/onnxruntime/blob/v1.31.0/LICENSE, the same text in',
        '1.23.2). The licence and the notices of the libraries built into ONNX Runtime, as each version gives them: the',
        'app holds the text of the licence, and downloads the notices with the library.',
        '',
        '| File | Size (bytes) | SHA-256 |',
        '| --- | --- | --- |',
    ]
    for asset in sorted(texts):
        size, digest = texts[asset]
        lines.append(f'| `{asset}` | {size} | `{digest}` |')
    lines += [
        '',
        '## Telemetry of ONNX Runtime, turned off',
        '',
        'The official builds of ONNX Runtime 1.31.0 send telemetry to Microsoft by default',
        '(https://github.com/microsoft/onnxruntime/blob/v1.31.0/docs/Privacy.md). The libraries for Linux and',
        'macOS carry the 1DS SDK: at their first session they write a device id and queue events for',
        'https://mobile.events.data.microsoft.com/OneCollector/1.0/. The Windows DLL reports through ETW',
        '(provider `Microsoft.ML.ONNXRuntime`). Immuch360 turns both off: it sets `ORT_DISABLE_TELEMETRY=1` in its',
        'process before it opens the library, so that 1DS never starts, and calls `DisableTelemetryEvents` on each',
        'environment it makes, which stops the ETW events. On Windows, ONNX Runtime may write one start event to',
        'ETW before that call; ETW events leave the computer only through the diagnostic data of Windows, under its',
        'own setting. 1.23.2 for the Intel Macs has no telemetry.',
        '',
        '## Not used',
        '',
        'These were looked at and left out, because of their licence:',
        '',
    ]
    for name, licence, url in EXCLUDED:
        lines.append(f'* {name}: {licence}, {url}')
    lines.append('')
    return '\n'.join(lines)


def without_date(text: str) -> str:
    return re.sub(r'^Date: \d{4}-\d{2}-\d{2}\.', 'Date:', text, count=1, flags=re.MULTILINE)


# --- making the files ---------------------------------------------------------------------------------------------


def prepare(args, catalogue: dict) -> dict:
    """Makes the files of the release in args.out; returns what the catalogue and MODEL-LICENSES.md should say"""
    archives, models, urls = load_sources(args.sources)
    out = args.out
    out.mkdir(parents=True, exist_ok=True)
    temporary = None
    if args.cache:
        downloads = args.cache[0]
    else:
        temporary = tempfile.TemporaryDirectory(prefix='ai-components-')
        downloads = pathlib.Path(temporary.name)
    places = [*args.cache, out, downloads]
    try:
        files = {}
        libraries = []
        texts = {}
        notices = {}
        sources = {archive.component: fetch(archive.name, urls[archive.name], archive.size, archive.sha256, places,
                                            downloads) for archive in archives}
        by_component = {archive.component: archive for archive in archives}
        for archive in archives:
            component = catalogue.get(archive.component)
            if component is None:
                raise Failure(f'the catalogue has no component {archive.component}')
            source = sources[archive.component]
            library = read_member(source, f'{archive.folder}/{archive.library}')
            installed = component['installPath'].rsplit('/', 1)[-1]
            if installed != archive.library.rsplit('/', 1)[-1]:
                raise Failure(f'{archive.component}: the catalogue installs {installed}, the archive holds '
                              f'{archive.library}')
            data = packed(library)
            write_file(out / component['assetName'], data)
            files[component['assetName']] = (len(data), sha256_bytes(data))
            libraries.append((component, archive, component['assetName'], len(library), sha256_bytes(library),
                              len(data)))
            reference = by_component[TEXTS_FROM[archive.version]]
            for kind, member in (('LICENSE', 'LICENSE'), ('ThirdPartyNotices', 'ThirdPartyNotices.txt')):
                text = read_member(source, f'{archive.folder}/{member}')
                asset = text_asset(archive.version, kind)
                if reference is archive:
                    write_file(out / asset, text)
                    texts[asset] = (len(text), sha256_bytes(text))
                    files[asset] = texts[asset]
                    continue
                # The same text in every archive of a version, line ends apart
                kept = read_member(sources[reference.component], f'{reference.folder}/{member}')
                if text.replace(b'\r\n', b'\n') != kept.replace(b'\r\n', b'\n'):
                    raise Failure(f'{archive.name}: its {member} differs from the one of {reference.name}')
            notice = component.get('notices') or {}
            if notice.get('assetName') != text_asset(archive.version, 'ThirdPartyNotices'):
                raise Failure(f'{archive.component}: the catalogue must name '
                              f'{text_asset(archive.version, "ThirdPartyNotices")} as its notices')
        for asset in texts:
            if asset.endswith('-ThirdPartyNotices.txt'):
                notices[asset] = texts[asset]
        model_rows = []
        for model in models:
            component = catalogue.get(model.component)
            if component is None:
                raise Failure(f'the catalogue has no component {model.component}')
            if (component.get('size'), component.get('sha256')) != (model.size, model.sha256):
                raise Failure(f'{model.component}: the catalogue says {component.get("size")} bytes, SHA-256 '
                              f'{component.get("sha256")}; the official file has {model.size} bytes, SHA-256 '
                              f'{model.sha256}')
            asset = component['assetName']
            source = fetch(asset, model.url, model.size, model.sha256, places, downloads)
            if source.resolve() != (out / asset).resolve():
                shutil.copyfile(source, out / f'{asset}.tmp')
                os.replace(out / f'{asset}.tmp', out / asset)
            files[asset] = (model.size, model.sha256)
            model_rows.append((component, model, asset))
        text = licences_text(args.date, model_rows, libraries, texts).encode('utf-8')
        write_file(out / LICENCES_NAME, text)
        files[LICENCES_NAME] = (len(text), sha256_bytes(text))
        sums = ''.join(f'{files[name][1]}  {name}\n' for name in sorted(files)).encode('utf-8')
        write_file(out / SUMS, sums)
        files[SUMS] = (len(sums), sha256_bytes(sums))
    finally:
        if temporary is not None:
            temporary.cleanup()

    print()
    print(f'Files of {TAG} in {out}:')
    for name in sorted(files):
        size, digest = files[name]
        print(f'  {name}  {size} bytes  {digest}')
    print()
    print('ONNX Runtime, the installed libraries:')
    for component, archive, asset, size, digest, download in libraries:
        print(f'  {component["id"]}: {archive.library.rsplit("/", 1)[-1]}, {size} bytes, SHA-256 {digest}; '
              f'{asset}, {download} bytes')
    return {
        'files': files,
        'libraries': {component['id']: (size, digest, download)
                      for component, _, _, size, digest, download in libraries},
        'notices': notices,
        'licences': text.decode('utf-8'),
    }


def catalogue_findings(catalogue: dict, made: dict) -> list:
    found = []
    for component, (size, digest, download) in made['libraries'].items():
        entry = catalogue[component]
        if (entry.get('size'), entry.get('sha256'), entry.get('downloadSize')) != (size, digest, download):
            found.append(f'{component}: the catalogue says size {entry.get("size")}, sha256 {entry.get("sha256")}, '
                         f'downloadSize {entry.get("downloadSize")}; the files give {size}, {digest}, {download}')
        notice = entry.get('notices') or {}
        expected = made['notices'].get(notice.get('assetName'))
        if expected is None or (notice.get('size'), notice.get('sha256')) != expected:
            found.append(f'{component}: its notices in the catalogue are {notice}; the files give {expected}')
    return found


# --- the offline check --------------------------------------------------------------------------------------------


def check(catalogue: dict, licences: str, sources: pathlib.Path | None = None) -> list:
    """What is wrong in the catalogue and MODEL-LICENSES.md, without the network"""
    found = []
    tables = load_sources(sources)
    archives = {archive.component: archive for archive in tables[0]}
    models = {model.component: model for model in tables[1]}
    if set(catalogue) != set(archives) | set(models):
        found.append(f'the catalogue has {sorted(catalogue)}; this script knows {sorted(set(archives) | set(models))}')
    for component_id, component in sorted(catalogue.items()):
        size, digest = component.get('size'), component.get('sha256')
        if not isinstance(size, int) or not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest):
            found.append(f'{component_id}: incomplete in the catalogue (size {size}, sha256 {digest})')
            continue
        if component.get('licence') not in ('Apache-2.0', 'MIT'):
            found.append(f'{component_id}: licence {component.get("licence")} is not one this project allows')
        asset = component.get('assetName')
        if component_id in models:
            model = models[component_id]
            if (size, digest) != (model.size, model.sha256):
                found.append(f'{component_id}: the catalogue and the official file differ')
            row = f'| `{asset}` | {model.use} | {size} | `{digest}` |'
        else:
            archive = archives.get(component_id)
            download = component.get('downloadSize')
            if not isinstance(download, int):
                found.append(f'{component_id}: no downloadSize in the catalogue')
            if archive and component.get('installPath', '').rsplit('/', 1)[-1] != archive.library.rsplit('/', 1)[-1]:
                found.append(f'{component_id}: the catalogue installs {component.get("installPath")}, the archive '
                             f'holds {archive.library}')
            notice = component.get('notices') or {}
            if archive and notice.get('assetName') != text_asset(archive.version, 'ThirdPartyNotices'):
                found.append(f'{component_id}: its notices must be {text_asset(archive.version, "ThirdPartyNotices")}')
            elif archive:
                notice_row = f'| `{notice.get("assetName")}` | {notice.get("size")} | `{notice.get("sha256")}` |'
                if notice_row not in licences:
                    found.append(f'{LICENCES_NAME} lacks the row {notice_row}')
            row = (f'| `{asset}` | `{component_id}` | `{component.get("installPath", "").rsplit("/", 1)[-1]}` | '
                   f'{size} | `{digest}` | {download} |')
        if row not in licences:
            found.append(f'{LICENCES_NAME} lacks the row {row}')
    if not re.search(r'^Date: \d{4}-\d{2}-\d{2}\.', licences, re.MULTILINE):
        found.append(f'{LICENCES_NAME} has no date')
    return found


# --- the release --------------------------------------------------------------------------------------------------

NOTES = (
    'The AI components of Immuch360: the depth model Depth Anything V2 Small (Apache-2.0) for the computers and the '
    'Meta Quest, and ONNX Runtime (MIT) for the computers. This is not a release of the app: the app downloads these '
    'files only when you ask it to, checks each one by its SHA-256, and works offline afterwards. Licences and sources: '
    f'{LICENCES_NAME}. Sums: {SUMS}.\n'
)


class GitHub:
    def __init__(self, base: str, token: str):
        self.base = base.rstrip('/')
        self.token = token

    def call(self, method: str, url: str, body=None, data: bytes | None = None, content_type='application/json'):
        if not url.startswith('http'):
            url = self.base + url
        headers = {'Authorization': f'Bearer {self.token}', 'Accept': 'application/vnd.github+json',
                   'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': USER_AGENT}
        if body is not None:
            data = json.dumps(body).encode('utf-8')
        if data is not None:
            headers['Content-Type'] = content_type
        request = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=900) as response:
                raw = response.read()
        except urllib.error.HTTPError as error:
            if error.code == 404 and method == 'GET':
                return None
            detail = error.read().decode('utf-8', 'replace')[:300]
            raise Failure(f'{method} {urllib.parse.urlsplit(url).path}: HTTP {error.code} {detail}') from None
        return json.loads(raw) if raw else None


def drafts_of(github: GitHub, repo: str) -> list:
    """The drafts of [repo] with the tag of the release, which GET /releases/tags does not see"""
    found = []
    page = 1
    while True:
        releases = github.call('GET', f'/repos/{repo}/releases?per_page=100&page={page}') or []
        found += [release for release in releases if release.get('draft') and release.get('tag_name') == TAG]
        if len(releases) < 100:
            return found
        page += 1


def publish(args, made: dict, token: str) -> int:
    github = GitHub(args.api, token)
    if github.call('GET', f'/repos/{args.repo}/releases/tags/{TAG}') is not None:
        print(f'{TAG} exists already on {args.repo}: nothing is changed. Delete it by hand to publish it again.')
        return 1
    drafts = drafts_of(github, args.repo)
    if drafts:
        print(f'a draft of {TAG} exists already on {args.repo}: {drafts[0].get("html_url")}. Nothing is changed. '
              f'Delete it by hand to publish again.')
        return 1
    release = github.call('POST', f'/repos/{args.repo}/releases', {
        'tag_name': TAG, 'name': 'AI components 1', 'body': NOTES, 'draft': True, 'prerelease': True,
        'make_latest': 'false',
    })
    print(f'draft made: {release["html_url"]}')
    try:
        upload = release['upload_url'].split('{', 1)[0]
        for name in sorted(made['files']):
            size, digest = made['files'][name]
            path = args.out / name
            if path.stat().st_size != size or sha256_file(path) != digest:
                raise Failure(f'{path} changed since it was made')
            content_type = CONTENT_TYPES.get(path.suffix.lower(), 'application/octet-stream')
            asset = github.call('POST', f'{upload}?{urllib.parse.urlencode({"name": name})}', data=path.read_bytes(),
                                content_type=content_type)
            held = asset.get('digest') or ''
            if asset.get('size') != size or (held.startswith('sha256:') and held[7:] != digest):
                raise Failure(f'{name}: GitHub holds {asset.get("size")} bytes, {held}; the file has {size} bytes, '
                              f'sha256:{digest}')
            print(f'uploaded: {name} ({size} bytes)')
        release = github.call('PATCH', release['url'], {'draft': False, 'prerelease': True, 'make_latest': 'false'})
    except (Failure, OSError) as error:
        raise Failure(f'{error}. A draft is left at {release["html_url"]}: delete it by hand before the next run.') \
            from None
    if not release.get('prerelease') or release.get('draft'):
        raise Failure(f'{TAG} is not a published prerelease: {release.get("html_url")}')
    latest = github.call('GET', f'/repos/{args.repo}/releases/latest')
    if latest is not None and latest.get('tag_name') == TAG:
        raise Failure(f'{TAG} became the latest release of {args.repo}: mark the app release as latest again')
    print(f'published as a prerelease: {release["html_url"]}')
    return 0


# --- command line -------------------------------------------------------------------------------------------------


def main(argv=None) -> int:
    sys.stdout.reconfigure(line_buffering=True)
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--out', type=pathlib.Path, help='the folder of the files of the release')
    parser.add_argument('--cache', type=pathlib.Path, action='append', default=[],
                        help='a folder of official files already downloaded; downloads go to the first one')
    parser.add_argument('--write', action='store_true', help='write the catalogue and MODEL-LICENSES.md')
    parser.add_argument('--publish', action='store_true', help=f'create the prerelease {TAG} on GitHub')
    parser.add_argument('--check', action='store_true', help='check the catalogue and MODEL-LICENSES.md, offline')
    parser.add_argument('--token-file', type=pathlib.Path, help='a file holding the token')
    parser.add_argument('--sources', type=pathlib.Path, help=argparse.SUPPRESS)
    parser.add_argument('--catalogue', type=pathlib.Path, default=CATALOGUE, help=argparse.SUPPRESS)
    parser.add_argument('--licences', type=pathlib.Path, default=LICENCES, help=argparse.SUPPRESS)
    parser.add_argument('--date', default=datetime.date.today().isoformat(), help=argparse.SUPPRESS)
    parser.add_argument('--repo', default=REPO, help=argparse.SUPPRESS)
    parser.add_argument('--api', default=API, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    if not args.catalogue.is_file():
        print(f'no catalogue at {args.catalogue}')
        return 2
    catalogue_text = args.catalogue.read_text(encoding='utf-8')
    catalogue = read_catalogue(catalogue_text)
    if args.check:
        licences = args.licences.read_text(encoding='utf-8') if args.licences.is_file() else ''
        found = check(catalogue, licences, args.sources)
        for line in found:
            print(f'publish_ai_components: {line}')
        if found:
            return 1
        print(f'{len(catalogue)} components, each complete and named with its size and SHA-256 in {LICENCES_NAME}')
        return 0
    if args.out is None:
        print('--out DIR is needed (or --check)')
        return 2
    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}', args.date):
        print(f'--date {args.date!r} is not YYYY-MM-DD')
        return 2
    token = None
    if args.publish:
        token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
        if args.token_file:
            token = args.token_file.read_text(encoding='utf-8').strip()
        if not token:
            print('no token: set GH_TOKEN or GITHUB_TOKEN, or give --token-file')
            return 2
    try:
        made = prepare(args, catalogue)
        if args.write:
            new = write_catalogue(catalogue_text, made['libraries'], made['notices'])
            if new != catalogue_text:
                args.catalogue.write_text(new, encoding='utf-8', newline='\n')
                print(f'written: {args.catalogue}')
            args.licences.parent.mkdir(parents=True, exist_ok=True)
            args.licences.write_text(made['licences'], encoding='utf-8', newline='\n')
            print(f'written: {args.licences}')
            catalogue = read_catalogue(new)
        found = catalogue_findings(catalogue, made)
        licences = args.licences.read_text(encoding='utf-8') if args.licences.is_file() else ''
        if without_date(licences) != without_date(made['licences']):
            found.append(f'{args.licences} differs from the one of these files')
        print()
        if found:
            for line in found:
                print(f'publish_ai_components: {line}')
            print('the catalogue or MODEL-LICENSES.md differs from these files: run with --write')
        else:
            print('the catalogue and MODEL-LICENSES.md of the repository agree with these files')
        if not args.publish:
            print(f'not published: {TAG} is created only with --publish')
            return 0
        if found:
            print(f'not published: {TAG} must carry the files the catalogue names')
            return 1
        return publish(args, made, token)
    except (Failure, OSError, zipfile.BadZipFile, tarfile.TarError) as error:
        message = f'publish_ai_components: {error}'
        print(message.replace(token, '***') if token else message)
        return 1


if __name__ == '__main__':
    sys.exit(main())
