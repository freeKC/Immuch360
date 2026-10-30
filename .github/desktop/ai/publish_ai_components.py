#!/usr/bin/env python3
"""The files of the prereleases ai-components-1, 2 and 3: the AI components Immuch360 downloads when the user asks.

Design: store/m2/ai-immersive-2026-10-26/design-final-2026-10-26.md, sections 2.2 and 4.6 (lot A3b), and
phase23/design-final-2026-10-27.md, sections 7.1 to 7.4 (lot C2). The app carries a catalogue of these files with the
size and the SHA-256 of each (mobile/lib/domain/models/ai_immersive/ai_components_manifest.dart) and takes them from the
release of their family, never from a remote manifest. This script makes the files of a release from their sources, and
the entries of the catalogue from those files.

ai-components-1, the 3D photos:
  1. the official archives of ONNX Runtime (MIT): 1.31.0 for Windows x64, Linux x64 and macOS arm64, and 1.23.2 for
     macOS x86_64, the last release with an archive for the Intel Macs; each checked by the SHA-256 GitHub gives for it
     (ARCHIVES below, read from the GitHub API on 27 October 2026);
  2. the library of each archive, as it is (the Authenticode signature of the DLL kept), gzip compressed without name
     or date: onnxruntime-<version>-<platform>.<ext>.gz, which the app unpacks while it downloads;
  3. the LICENSE and the ThirdPartyNotices.txt of each version of ONNX Runtime (the same text in every archive of a
     version, the Windows one with CRLF line ends: the LF copy is kept, the others are compared to it);
  4. the two depth models, Depth Anything V2 Small (Apache-2.0), fp32 ONNX for the computers and fp32 LiteRT for the
     Quest, from their official source pinned to a commit, checked by the sums of the catalogue.
ai-components-2, the 3D scenes, and ai-components-3, the 360° panoramas (UPSTREAM and ENGINES below):
  5. each model from its source pinned to a revision (Hugging Face, or the GitHub release of Real-ESRGAN), checked by
     the sum of the catalogue; the card of each source is read again by the API of Hugging Face (or of GitHub): its
     licence, and the size and LFS sum of the file at the revision. MoGe-2 ViT-S is our export
     (export_moge_onnx.py): it is taken from a --cache folder only, its weights and their licence are read again, and
     so is the published file it equals byte for byte;
  6. a file of 2 GiB or more is cut into parts of PART_SIZE bytes, <asset>.001, <asset>.002, ..., each an asset of
     the release (GitHub refuses a file of 2 GiB or more); the app puts them end to end;
  7. the engines of ai-components-3, stable-diffusion.cpp on Vulkan (lot P2): the artifact
     Immuch360-AI-sdcpp-<lock>-<platform>.zip of a run of our CI, signed by the release workflow for Windows, read by
     the GitHub API (--from-run RUN) or found in a --cache folder; its files go into our own archive
     sd-cpp-vulkan-<platform>.zip (sorted names, fixed dates, deflate), each with its size, sum and executable bit (the
     artifacts keep no file mode: a .exe, or an ELF program that is not a .so, is executable).
Every release also holds MODEL-LICENSES.md (the copy of licenses/ai-components/MODEL-LICENSES.md, dated, one section
per release, the other sections kept as they are) and SHA256SUMS.

  publish_ai_components.py --out DIR [--release TAG] [--cache DIR]... [--from-run RUN] [--write]
      makes the files of the release TAG (ai-components-1 when not given) in DIR and prints their sizes and sums, then
      says whether the catalogue and MODEL-LICENSES.md of the repository agree with them. A file found in a --cache
      folder (or in DIR) with the right SHA-256 is not downloaded again; a download goes to the first --cache folder,
      else to a temporary one. With --write, what the files give is written into the catalogue (the libraries of ONNX
      Runtime and their notices, the parts, the archives) and the section of TAG into MODEL-LICENSES.md. An engine
      without its artifact stays pending: said, and the release is not published.
  publish_ai_components.py --out DIR [--release TAG] [...] --publish [--token-file FILE]
      the same, then the prerelease TAG on freeKC/Immuch360 with the files of DIR, only when the catalogue and
      MODEL-LICENSES.md of the repository agree with them and nothing is pending. Made as a draft, filled, then
      published as a prerelease that is never "Latest" (the app reads releases/latest); its tag starts with no "v", so
      no release workflow runs on it (the upstream workflows that run on a published release are disabled in the
      fork). A release that exists already is never touched.
  publish_ai_components.py --check [--release TAG]
      offline, for the three releases (or TAG): every component of the catalogue is complete (an engine of P2 may still
      be pending, said), in the release of its family, its file, parts and sums are those of the tables below, and
      MODEL-LICENSES.md names each file with its size and SHA-256 (test/desktop/ci/publish_ai_components_test.dart)

Without --publish nothing leaves this computer; the network is used only to download the files and to read the cards
and the artifacts. --sources FILE replaces the addresses and upstream sums of the tables below (the tests serve small
files at file:// addresses); --catalogue, --licences, --date, --repo, --api and --hf-api point at other files, dates
and servers (the tests). The token comes from GH_TOKEN or GITHUB_TOKEN, or from --token-file, and is never printed; it
is sent to the GitHub API only, never to the storage an artifact is redirected to. Only the Python standard library is
used. Exit codes: 0 done, 1 a check failed or GitHub refused, 2 bad arguments, files or token.
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
HF_API = 'https://huggingface.co'
REPO = 'freeKC/Immuch360'
TAG = 'ai-components-1'
TAG_SCENES = 'ai-components-2'
TAG_PANORAMAS = 'ai-components-3'
RELEASES = (TAG, TAG_SCENES, TAG_PANORAMAS)
FAMILIES = {TAG: '3D photos', TAG_SCENES: '3D scenes', TAG_PANORAMAS: '360° panoramas'}
SUMS = 'SHA256SUMS'
# GitHub refuses an asset of 2 GiB or more; a larger file goes in parts of the largest whole number of MiB under 1.9 GiB
ASSET_LIMIT = 2 * 1024 ** 3
PART_SIZE = 1945 * 1024 * 1024
ALLOWED_LICENCES = ('Apache-2.0', 'MIT', 'BSD-3-Clause')
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



@dataclasses.dataclass(frozen=True)
class Upstream:
    """A model of ai-components-2 or 3 as its source gives it, and what the card of that source says"""
    component: str
    release: str
    # Where the script downloads it; None for our own export, taken from a --cache folder only
    url: str | None
    size: int
    sha256: str
    # The Hugging Face repository, or github:owner/repo for a GitHub release; its revision (a commit, or the tag)
    repo: str
    revision: str
    # The file in the repository: the model itself, or the weights of our export
    path: str
    # The licence the card gives (Hugging Face: cardData.license; GitHub: the SPDX id of the repository)
    card: str
    use: str
    # Our export only: the size and SHA-256 of the weights at repo, revision and path, and the published file (repo,
    # revision, path) whose bytes ours equal
    weights: tuple | None = None
    same_as: tuple | None = None

    @property
    def source(self) -> str:
        if self.repo.startswith('github:'):
            return f'https://github.com/{self.repo[7:]}/releases/tag/{self.revision}'
        return f'https://huggingface.co/{self.repo}'


@dataclasses.dataclass(frozen=True)
class Engine:
    """An engine of ai-components-3: the artifact of our CI its files come from (lot P2)"""
    component: str
    platform: str

    @property
    def artifact_suffix(self) -> str:
        return f'-{self.platform}.zip'


HF = 'https://huggingface.co'
UPSTREAM = (
    Upstream('moge-2-vits-normal-onnx-immuch360', TAG_SCENES, None, 140852051,
             '24eacb5dc7a2c54c7bc98f7de085ffbed79ad006ea5b664c2c2cdc02ff3a52f0', 'Ruicheng/moge-2-vits-normal',
             '26b477f41595707c5db6770294c0d1721e8ed4ed', 'model.pt', 'mit',
             'the geometry of a scene and of the photo inside a panorama; our ONNX export (opset 14) of the MIT '
             'weights, by export_moge_onnx.py',
             weights=(140550416, '79a16621928c2bf0ed04659218c55c01075e950507f40bb3332fb4c873d3e1dc'),
             same_as=('Ruicheng/moge-2-vits-normal-onnx', 'e50ffda41565591092adea54c6ac83d6212e1e23', 'model.onnx')),
    Upstream('lama-onnx', TAG_SCENES,
             f'{HF}/Carve/LaMa-ONNX/resolve/c3c0c9e468934d62e79c329e35d82dd09ff8c444/lama_fp32.onnx', 208044816,
             '1faef5301d78db7dda502fe59966957ec4b79dd64e16f03ed96913c7a4eb68d6', 'Carve/LaMa-ONNX',
             'c3c0c9e468934d62e79c329e35d82dd09ff8c444', 'lama_fp32.onnx', 'apache-2.0',
             'the filling of the hidden bands of a scene'),
    Upstream('migan-512-places2-onnx', TAG_PANORAMAS,
             f'{HF}/andraniksargsyan/migan/resolve/406830d0fa60666da0071c342ad2fbc8f30c5c64/migan_pipeline_v2.onnx',
             28079181, '6f1f3530a1a2324b19752018ce756088b07973cda8d7d890034ace5c8a48c40b', 'andraniksargsyan/migan',
             '406830d0fa60666da0071c342ad2fbc8f30c5c64', 'migan_pipeline_v2.onnx', 'mit',
             'the filling of the seam of a panorama'),
    Upstream('flux2-klein-base-4b-q4_0', TAG_PANORAMAS,
             f'{HF}/leejet/FLUX.2-klein-base-4B-GGUF/resolve/d12671125306ca6b5f6db1b33ed4c80c8511a53f/'
             'flux-2-klein-base-4b-Q4_0.gguf', 2460378560,
             'c3a2854510677b7aa37dd7547d908c54889a76c6d6aa3ffe902fcaa092d1328b', 'leejet/FLUX.2-klein-base-4B-GGUF',
             'd12671125306ca6b5f6db1b33ed4c80c8511a53f', 'flux-2-klein-base-4b-Q4_0.gguf', 'apache-2.0',
             'the generator of a panorama: FLUX.2 klein base 4B (black-forest-labs, Apache-2.0), Q4_0 GGUF'),
    Upstream('qwen3-4b-q4_k_m', TAG_PANORAMAS,
             f'{HF}/unsloth/Qwen3-4B-GGUF/resolve/22c9fc8a8c7700b76a1789366280a6a5a1ad1120/Qwen3-4B-Q4_K_M.gguf',
             2497281312, 'f6f851777709861056efcdad3af01da38b31223a3ba26e61a4f8bf3a2195813a', 'unsloth/Qwen3-4B-GGUF',
             '22c9fc8a8c7700b76a1789366280a6a5a1ad1120', 'Qwen3-4B-Q4_K_M.gguf', 'apache-2.0',
             'the text encoder of FLUX.2 klein: Qwen3 4B (Qwen, Apache-2.0), Q4_K_M GGUF'),
    Upstream('flux2-vae', TAG_PANORAMAS,
             f'{HF}/black-forest-labs/FLUX.2-klein-base-4B/resolve/a3b4f4849157f664bdbc776fd7453c2783562f4d/vae/'
             'diffusion_pytorch_model.safetensors', 168120878,
             'ca70d2202afe6415bdbcb8793ba8cd99fd159cfe6192381504d6c4d3036e0f04', 'black-forest-labs/FLUX.2-klein-base-4B',
             'a3b4f4849157f664bdbc776fd7453c2783562f4d', 'vae/diffusion_pytorch_model.safetensors', 'apache-2.0',
             'the VAE of FLUX.2 klein base 4B'),
    Upstream('flux2-klein-4b-360-erp-lora-v1', TAG_PANORAMAS,
             f'{HF}/nomadoor/flux-2-klein-4B-360-erp-outpaint-lora/resolve/124129f3ebce357c007ffca177d19567246f8bff/'
             'flux-2-klein-4B-360-erp-outpaint-lora_V1.safetensors', 46224184,
             '567cc22de03800d2c9d4309e0cf6f971cc00da6b39fb26b0311031f2563de166',
             'nomadoor/flux-2-klein-4B-360-erp-outpaint-lora', '124129f3ebce357c007ffca177d19567246f8bff',
             'flux-2-klein-4B-360-erp-outpaint-lora_V1.safetensors', 'apache-2.0',
             'the 360 ERP Outpaint LoRA of klein 4B; trained on CC0 and public domain images, with a part under CC BY'),
    Upstream('realesrgan-x4plus', TAG_PANORAMAS,
             'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth', 67040989,
             '4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1', 'github:xinntao/Real-ESRGAN', 'v0.1.0',
             'RealESRGAN_x4plus.pth', 'BSD-3-Clause', 'the upscaler of a panorama (x4)'),
)

ENGINES = (
    Engine('sd-cpp-vulkan-win-x64', 'windows-x64'),
    Engine('sd-cpp-vulkan-linux-x64', 'linux-x64'),
)
ENGINE_ARTIFACT_PREFIX = 'Immuch360-AI-sdcpp-'

CONTENT_TYPES = {'.gz': 'application/gzip', '.txt': 'text/plain', '.md': 'text/markdown', '.onnx':
                 'application/octet-stream', '.tflite': 'application/octet-stream', '.zip': 'application/zip'}


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


PART = re.compile(r"AiComponentPart\(\s*assetName: '([^']*)',\s*size: (\d+),\s*sha256: '([^']*)',?\s*\)")
ARCHIVE_FILE = re.compile(r"AiArchiveFile\(\s*path: '([^']*)',\s*size: (\d+),\s*sha256: '([^']*)'"
                          r"(?:,\s*executable: (true|false))?,?\s*\)")
LIST_FIELD = r'^  {key}: \[\n?(.*?)^  \],\n'


def list_field(body: str, key: str) -> str | None:
    """The text of the list field [key] of a component, None when it has none"""
    match = re.search(LIST_FIELD.format(key=key), body, re.MULTILINE | re.DOTALL)
    return match.group(1) if match else None


def read_catalogue(text: str) -> dict:
    """The components of the catalogue by id, each a dict of its fields, the notices resolved, its release (the one of
    phase 1 when not named), its parts and the files of an archive"""
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
        fields.setdefault('releaseTag', TAG)
        fields['parts'] = [(asset, int(size), digest) for asset, size, digest in PART.findall(
            list_field(body, 'parts') or '')]
        fields['archiveFiles'] = [(path, int(size), digest, executable == 'true') for path, size, digest, executable
                                  in ARCHIVE_FILE.findall(list_field(body, 'archiveFiles') or '')]
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


def dart_parts(parts: list) -> str:
    """The parts field of the catalogue, as dart format writes it"""
    lines = ['  parts: [']
    for asset, size, digest in parts:
        lines += ['    AiComponentPart(', f"      assetName: '{asset}',", f'      size: {size},', f"      sha256: '{digest}',",
                  '    ),']
    lines.append('  ],')
    return '\n'.join(lines) + '\n'


def dart_archive_files(files: list) -> str:
    """The archiveFiles field of the catalogue, as dart format writes it"""
    lines = ['  archiveFiles: [']
    for path, size, digest, executable in files:
        lines += ['    AiArchiveFile(', f"      path: '{path}',", f'      size: {size},', f"      sha256: '{digest}',"]
        if executable:
            lines.append('      executable: true,')
        lines.append('    ),')
    lines.append('  ],')
    return '\n'.join(lines) + '\n'


def set_list_field(body: str, key: str, value: str, after: str) -> str:
    """[body] with the list field [key] replaced by [value] (a whole field, from dart_parts or dart_archive_files),
    added after the field [after] when missing"""
    pattern = re.compile(LIST_FIELD.format(key=key), re.MULTILINE | re.DOTALL)
    if pattern.search(body):
        return pattern.sub(lambda _: value, body, count=1)
    anchor = re.compile(rf'^  {after}: .+,\n', re.MULTILINE)
    match = anchor.search(body)
    if match is None:
        raise Failure(f'the catalogue has no field {after} to put {key} after')
    return body[:match.end()] + value + body[match.end():]


def write_catalogue_family(text: str, parts: dict, archives: dict) -> str:
    """The catalogue with the parts of each model of 2 GiB or more and the size, sum and files of each archive.
    [parts]: component id -> [(asset, size, sha256)]; [archives]: component id -> (size, sha256, [(path, size, sha256,
    executable)])"""
    def component(match: re.Match) -> str:
        name, body = match.group(1), match.group(2)
        found = re.search(r"^  id: '([^']+)',$", body, re.MULTILINE)
        identifier = found.group(1) if found else None
        if identifier in parts:
            body = set_list_field(body, 'parts', dart_parts(parts[identifier]), 'releaseTag')
        if identifier in archives:
            size, digest, files = archives[identifier]
            body = set_field(body, 'size', str(size), 'installPath')
            body = set_field(body, 'sha256', f"'{digest}'", 'size')
            body = set_list_field(body, 'archiveFiles', dart_archive_files(files), 'releaseTag')
        return f'const {name} = AiComponent(\n{body});\n'

    return COMPONENT_BLOCK.sub(component, text)


# --- the official files -------------------------------------------------------------------------------------------


def load_sources(path: pathlib.Path | None) -> tuple:
    """The tables, with the addresses and sums of [path] when given: {"archives": {name: {url, size, sha256}},
    "models": {component: {url, size, sha256}}, "upstream": {component: {url, size, sha256, weights?}}}"""
    urls = {archive.name: archive.url for archive in ARCHIVES}
    archives, models, upstream = list(ARCHIVES), list(MODELS), list(UPSTREAM)
    if path is None:
        return archives, models, urls, upstream
    data = json.loads(path.read_text(encoding='utf-8'))
    for name, change in data.get('archives', {}).items():
        index = next(i for i, archive in enumerate(archives) if archive.name == name)
        archives[index] = dataclasses.replace(archives[index], size=change['size'], sha256=change['sha256'])
        urls[name] = change['url']
    for component, change in data.get('models', {}).items():
        index = next(i for i, model in enumerate(models) if model.component == component)
        models[index] = dataclasses.replace(models[index], url=change['url'], size=change['size'],
                                            sha256=change['sha256'])
    for component, change in data.get('upstream', {}).items():
        index = next(i for i, model in enumerate(upstream) if model.component == component)
        weights = change.get('weights')
        upstream[index] = dataclasses.replace(upstream[index], url=change.get('url'), size=change['size'],
                                              sha256=change['sha256'],
                                              weights=tuple(weights) if weights else upstream[index].weights)
    return archives, models, urls, upstream


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

# THIRD_PARTY_NOTICE.txt of the LiteRT 2.3.0 packages (the same in litert, litert-api and litert-gpu), shipped in
# the quest APK as mobile/assets/licenses/litert/THIRD_PARTY_NOTICE.txt; test/utils/litert_licenses_test.dart checks
# that copy against this sum
LITERT_NOTICES_SHA256 = 'db6e1ff4b16c11eb01c45f135928527a50a05282739054686793ec70f442f119'

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


# The LICENSE and ThirdPartyNotices.txt of ONNX Runtime, as the official archives pinned in ARCHIVES hold them: the
# section of ai-components-1 when it is written by a run of another release and MODEL-LICENSES.md has none
ORT_TEXTS = {
    'onnxruntime-1.23.2-LICENSE.txt': (1073, '2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c'),
    'onnxruntime-1.23.2-ThirdPartyNotices.txt': (326866,
                                                 'e9e90971a8e75a9a8ac0c6412e29c1202d079998389915aa485f46c816c3b4cc'),
    'onnxruntime-1.31.0-LICENSE.txt': (1073, '2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c'),
    'onnxruntime-1.31.0-ThirdPartyNotices.txt': (338088,
                                                 '143764b952fdb1a7c69ce653bfba74a7744d6a8a573bfb73e235fba356c83de3'),
}

# Design-final 2026-10-27, section 7.6: what the scenes and panoramas left out, and why
EXCLUDED_LATER = (
    ('SHARP of Apple, the weights', 'apple-amlr, research only', 'https://github.com/apple/ml-sharp/blob/main/LICENSE_MODEL'),
    ('FlashWorld, the weights', 'CC-BY-NC-SA-4.0', 'https://huggingface.co/imlixinyang/FlashWorld'),
    ('Lyra 1 and 2 of NVIDIA', 'NVIDIA Open Model License, internal research licence',
     'https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license'),
    ('HY World 2.0, WorldMirror, HunyuanWorld', 'does not apply in the European Union',
     'https://github.com/Tencent-Hunyuan/HY-World-2.0/blob/main/License.txt'),
    ('VGGT, Depth Anything 3 Giant and Nested', 'CC-BY-NC', 'https://github.com/facebookresearch/vggt/blob/main/LICENSE.txt'),
    ('EdgeConnect, MAT, 3D Ken Burns', 'CC-BY-NC (SA)', 'https://github.com/knazeri/edge-connect/blob/master/LICENSE.md'),
    ('FLUX.1 dev, Fill, Kontext and Krea; FLUX.2 klein 9B and its 360 LoRA; FLUX.2 dev',
     'non commercial licences of Black Forest Labs', 'https://huggingface.co/black-forest-labs/FLUX.1-Fill-dev'),
    ('FLUX.3 Image Klein', 'FLUX Kommunity License: a revenue cap and imposed filters', 'https://bfl.ai/blog/flux-3-image-klein'),
    ('Stable Diffusion 3.5; SDXL and its 360 LoRA', 'Stability community licence; OpenRAIL++',
     'https://huggingface.co/stabilityai/stable-diffusion-3.5-medium'),
    ('Qwen Image 2.1', 'qwen-research', 'https://huggingface.co/Qwen/Qwen-Image-2.1'),
    ('HiDream, Lumina Image 2.0, Sana', 'their Llama 3.1 or Gemma 2 encoders',
     'https://huggingface.co/meta-llama/Llama-3.1-8B-Instruct'),
    ('CUDA, cuDNN and the nvidia-* wheels', 'NVIDIA EULA', 'https://docs.nvidia.com/cuda/eula/index.html'),
    ('ComfyUI', 'GPL-3.0: never shipped, only called when the user installed it',
     'https://github.com/Comfy-Org/ComfyUI'),
)

RELEASE_MARK = '<!-- {tag} -->'
END_MARK = '<!-- end of the releases -->'


def licences_header(date: str) -> list:
    return [
        '# Licences of the AI components of Immuch360',
        '',
        f'Date: {date}. Written by `.github/desktop/ai/publish_ai_components.py` from the files of the prereleases',
        f'`{TAG}` (3D photos), `{TAG_SCENES}` (3D scenes) and `{TAG_PANORAMAS}` (360° panoramas):',
        f'https://github.com/{REPO}/releases',
        '',
        'The app downloads a component only when the user asks for it, checks its SHA-256 against the catalogue built',
        'into the app, and copies its licence next to it (`ai-components/licenses/`). When two pages disagree on a',
        'licence, the more restrictive one applies.',
        '',
    ]


def photos_section(models: list, libraries: list, texts: dict) -> str:
    """The section of ai-components-1. [models]: (component, model, asset); [libraries]: (component, archive, asset,
    size, sha256, download size); [texts]: asset name -> (size, sha256)"""
    lines = [
        RELEASE_MARK.format(tag=TAG),
        f'## {TAG}: 3D photos',
        '',
        f'https://github.com/{REPO}/releases/tag/{TAG}. The depth model is Apache-2.0, ONNX Runtime is MIT. ONNX',
        'Runtime has other libraries built in, each under its own licence, listed in its notices (below): mostly BSD,',
        'Apache-2.0, MIT, Boost, zlib or public domain, and Eigen under MPL-2.0, a weak copyleft licence. The notices',
        'cover the whole ONNX Runtime project, not only what these builds hold. The libraries are redistributed as',
        'Microsoft built them, unmodified, with those notices.',
        '',
        '### Depth model: Depth Anything V2 Small, Apache-2.0',
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
        '### ONNX Runtime, MIT',
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
        '### Telemetry of ONNX Runtime, turned off',
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
        '### LiteRT 2.3.0, Apache-2.0 (in the quest APK, not downloaded)',
        '',
        '`com.google.ai.edge.litert:litert`, `litert-api` and `litert-gpu` 2.3.0 run the depth model on the Meta',
        'Quest. They are built into the APK of the quest flavour only; the phone APKs and the computers do not have',
        'them. Licence: Apache-2.0, https://github.com/google-ai-edge/LiteRT/blob/main/LICENSE. The notices of the',
        'libraries LiteRT is built from (`THIRD_PARTY_NOTICE.txt` of its packages, 1960672 bytes, SHA-256',
        f'`{LITERT_NOTICES_SHA256}`) ship in the quest APK and are shown on',
        'its licence page. Its native libraries carry XNNPACK, pthreadpool and cpuinfo (BSD), and FP16 and FXdiv',
        '(MIT); the notices also list Eigen 3 under MPL-2.0, a weak copyleft licence, which its CPU code may hold.',
        'The notices cover the whole LiteRT build, not only what these libraries hold. Left out of the APK:',
        '`com.google.android.play:ai-delivery` 0.1.1-alpha01 (Play Core Software Development Kit Terms of Service),',
        'which `litert-api` brings for Play for On-device AI and which the app never calls. Brought in by',
        '`litert-api`, quest flavour only, all Apache-2.0: `androidx.lifecycle:lifecycle-runtime` 2.10.0,',
        '`com.google.guava:guava` 33.5.0-android and `org.jetbrains.kotlinx:kotlinx-coroutines-guava` 1.8.0.',
        '',
    ]
    return '\n'.join(lines)


def photos_section_of_catalogue(catalogue: dict) -> str:
    """The section of ai-components-1 from the catalogue and the pinned tables, for a run of another release"""
    models = [(catalogue[model.component], model, catalogue[model.component]['assetName']) for model in MODELS
              if model.component in catalogue]
    libraries = []
    for archive in ARCHIVES:
        component = catalogue.get(archive.component)
        if component is not None:
            libraries.append((component, archive, component['assetName'], component.get('size'),
                              component.get('sha256'), component.get('downloadSize')))
    return photos_section(models, libraries, ORT_TEXTS)


FAMILY_NOTES = {
    TAG_SCENES: [
        'Our export of MoGe-2 ViT-S: the MIT weights of https://huggingface.co/Ruicheng/moge-2-vits-normal at revision',
        '`26b477f41595707c5db6770294c0d1721e8ed4ed` (`model.pt`, 140550416 bytes, SHA-256',
        '`79a16621928c2bf0ed04659218c55c01075e950507f40bb3332fb4c873d3e1dc`) through the export method of',
        'https://github.com/microsoft/MoGe at `74fbce054ebed49800de42d0ad0e83495065719a` (`docs/onnx.md`), opset 14, by',
        '`.github/desktop/ai/export_moge_onnx.py` with PyTorch 2.7.0 for the processor. The result is byte for byte',
        '`model.onnx` of https://huggingface.co/Ruicheng/moge-2-vits-normal-onnx at revision',
        '`e50ffda41565591092adea54c6ac83d6212e1e23`, a repository without a card nor a licence, which is therefore',
        'not used as a source. MoGe: MIT, Copyright (c) Microsoft Corporation; its DINOv2 backbone: Apache-2.0',
        '(https://github.com/facebookresearch/dinov2/blob/main/LICENSE).',
        '',
        'LaMa: Apache-2.0 (https://github.com/advimman/lama), trained by its authors on Places2, a research dataset;',
        'the ONNX export of Carve (`lama_fp32.onnx`, Apache-2.0 on its card), not `lama.onnx` of the same revision,',
        'which ONNX Runtime 1.31.0 refuses to load.',
    ],
    TAG_PANORAMAS: [
        'FLUX.2 klein base 4B: Apache-2.0 (https://huggingface.co/black-forest-labs/FLUX.2-klein-base-4B), as GGUF by',
        'leejet (Apache-2.0); the Q4_0 file, the one that holds in a graphics card of 8 GB (measure M3). Its VAE: the',
        '`vae/` folder of the same model. Qwen3 4B: Apache-2.0 (https://huggingface.co/Qwen/Qwen3-4B), as GGUF by',
        'unsloth (Apache-2.0). The 360 ERP Outpaint LoRA of nomadoor: Apache-2.0 on its card, trained on images',
        'under CC0 and in the public domain, with a part under CC BY (its card and `TRAINING_NOTES.md`); the',
        'attribution of that part comes with a later version of this file. MI-GAN: MIT, code and weights, Copyright (c)',
        '2024 Picsart AI Research (PAIR), trained on Places2, a research dataset. Real-ESRGAN x4plus: BSD-3-Clause,',
        'Copyright (c) 2021, Xintao Wang. stable-diffusion.cpp and ggml: MIT',
        '(https://github.com/leejet/stable-diffusion.cpp/blob/be486498eadc29dc3cd234d944c2180ed42b1415/LICENSE,',
        'https://github.com/leejet/ggml/blob/a5915eb0e47adef21c3f25b889a008925ea838c2/LICENSE), built by our CI at the',
        'commits of `.github/desktop/ai/sd_cpp.lock.json` and signed for Windows, run by the app as a child process;',
        'their licences and those of the code built into them (Oniguruma, utf8proc, Darts-clone, JSON for Modern C++,',
        'miniz, stb, llamafile sgemm) are in the `licenses/` folder of each archive, from `licenses/sdcpp/` of the',
        'repository. No CUDA: the graphics card is reached through Vulkan only.',
    ],
}


def upstream_source(model: Upstream) -> str:
    if model.weights is not None:
        return f'our export of {model.source}, revision `{model.revision[:8]}`, `{model.path}`'
    return f'{model.source}, revision `{model.revision[:8]}`, `{model.path}`'


def part_row(asset: str, index: int, count: int, whole: str, size: int, digest: str) -> str:
    return f'| `{asset}` | {index} of {count} of `{whole}` | {size} | `{digest}` |'


def family_section(tag: str, catalogue: dict, upstream: tuple = UPSTREAM) -> str:
    """The section of ai-components-2 or 3, from the catalogue and the pinned tables"""
    lines = [
        RELEASE_MARK.format(tag=tag),
        f'## {tag}: {FAMILIES[tag]}',
        '',
        f'https://github.com/{REPO}/releases/tag/{tag}',
        '',
        '| File | Component | Size (bytes) | SHA-256 | Licence | Source, pinned revision |',
        '| --- | --- | --- | --- | --- | --- |',
    ]
    parts = []
    for model in upstream:
        if model.release != tag or model.component not in catalogue:
            continue
        component = catalogue[model.component]
        lines.append(f'| `{component["assetName"]}` | `{model.component}` | {component.get("size")} | '
                     f'`{component.get("sha256")}` | {component.get("licence")} | {upstream_source(model)} |')
        for index, (asset, size, digest) in enumerate(component['parts'], start=1):
            parts.append(part_row(asset, index, len(component['parts']), component['assetName'], size, digest))
    engines = [catalogue[engine.component] for engine in ENGINES if engine.component in catalogue
               and catalogue[engine.component].get('releaseTag') == tag]
    for component in engines:
        if component.get('sha256') is not None:
            lines.append(f'| `{component["assetName"]}` | `{component["id"]}` | {component.get("size")} | '
                         f'`{component.get("sha256")}` | {component.get("licence")} | built and signed by our CI |')
    lines.append('')
    if parts:
        lines += [
            'The files of 2 GiB or more are in parts (GitHub refuses a larger asset), put end to end by the app, which',
            'checks the sum of each part and of the whole:',
            '',
            '| Part | Of | Size (bytes) | SHA-256 |',
            '| --- | --- | --- | --- |',
            *parts,
            '',
        ]
    for component in engines:
        if not component['archiveFiles']:
            lines += [f'`{component["id"]}`: pending, written by lot P2 from the signed artifacts of our CI.', '']
            continue
        lines += [
            f'`{component["assetName"]}` holds, unpacked into `{component.get("installPath")}`:',
            '',
            '| File | Size (bytes) | SHA-256 | Program |',
            '| --- | --- | --- | --- |',
            *[f'| `{path}` | {size} | `{digest}` | {"yes" if executable else "no"} |'
              for path, size, digest, executable in component['archiveFiles']],
            '',
        ]
    lines += FAMILY_NOTES[tag]
    lines.append('')
    return '\n'.join(lines)


# The splat module of the Meta Spatial SDK, which shows the Gaussian splats of other tools on a Quest 3 or 3S (lot S5):
# no download, no model, but a licence whose article 1.6 on Experimental Features, which the splat API is, FreeKC
# decided about on 30 October 2026 (licenses/meta-spatial-sdk/README.md)
SPLAT_MODULE = [
    '## The splat module of the Meta Spatial SDK 0.14.0 (in the quest APK, not downloaded)',
    '',
    '`com.meta.spatial:meta-spatial-sdk-splat` 0.14.0 shows on a Meta Quest 3 or 3S the Gaussian splat files that',
    'other tools make (`.spz`, `.ply`): no AI of ours, no model downloaded. It is built into the APK of the quest',
    'flavour only (about 1.1 MB). Licence: the Meta Platform Technologies SDK License Agreement, the very text of the',
    'Meta Spatial SDK the APK already ships (its `LICENSE`, SHA-256',
    '`bb9b12db3b92c024458df625acd6f2d8140ea805cc6814bac74613a466731368`, and its `notices.html` are byte for byte those',
    'of `meta-spatial-sdk`, `-toolkit` and `-vr`). Both are in `licenses/meta-spatial-sdk/` and on the licence page of',
    'the app. The same text, but one of its clauses applies here for the first time: the splat API is an Experimental',
    'Feature of the SDK (opt in `SpatialSDKExperimentalSplatAPI`), and article 1.6 keeps an Experimental Feature out of',
    'a production build unless Meta released it in its own production builds or permits it in writing. On 30 October',
    '2026 FreeKC, the maintainer, decided to ship it in the GitHub builds of this free hobby app, labelled experimental,',
    'with the words that Meta neither supports nor warrants its API and that any defect is Immuch360\'s own; the build',
    'of the Meta Horizon Store never starts it. The decision, its reading of the clause and what goes with it are in',
    '`licenses/meta-spatial-sdk/README.md`.',
    '',
]


def tail_section() -> str:
    lines = [END_MARK, *SPLAT_MODULE, '## Not used', '', 'These were looked at and left out, because of their licence:',
             '']
    for name, licence, url in EXCLUDED + EXCLUDED_LATER:
        lines.append(f'* {name}: {licence}, {url}')
    lines.append('')
    return '\n'.join(lines)


def sections_of(text: str) -> dict:
    """The section of each release in [text], by tag, as written (an empty dict for a file without them)"""
    found = {}
    for tag in RELEASES:
        mark = RELEASE_MARK.format(tag=tag)
        start = text.find(mark)
        if start < 0:
            continue
        ends = [text.find(other, start + len(mark)) for other in [*(RELEASE_MARK.format(tag=t) for t in RELEASES),
                                                                   END_MARK]]
        ends = [end for end in ends if end > start]
        found[tag] = text[start:min(ends) if ends else len(text)].rstrip('\n') + '\n'
    return found


def licences_text(date: str, sections: dict) -> str:
    """MODEL-LICENSES.md: the header, the section of each release ([sections], by tag), then what was left out"""
    return '\n'.join([*licences_header(date), *[sections[tag] for tag in RELEASES], tail_section()])


def licences_for(date: str, catalogue: dict, kept: str, made: dict | None = None, release: str | None = None,
                 upstream: tuple = UPSTREAM) -> str:
    """MODEL-LICENSES.md: the section of [release] from [made] (the photos) or from the catalogue (a family), the
    other families from the catalogue, the photos kept from [kept] when [release] is another one"""
    sections = {tag: family_section(tag, catalogue, upstream) for tag in (TAG_SCENES, TAG_PANORAMAS)}
    if release == TAG and made is not None:
        sections[TAG] = made['photos']
    else:
        sections[TAG] = sections_of(kept).get(TAG) or photos_section_of_catalogue(catalogue)
    return licences_text(date, sections)


def without_date(text: str) -> str:
    return re.sub(r'^Date: \d{4}-\d{2}-\d{2}\.', 'Date:', text, count=1, flags=re.MULTILINE)


# --- making the files ---------------------------------------------------------------------------------------------


def prepare(args, catalogue: dict) -> dict:
    """Makes the files of the release in args.out; returns what the catalogue and MODEL-LICENSES.md should say"""
    archives, models, urls, _ = load_sources(args.sources)
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
        kept = args.licences.read_text(encoding='utf-8') if args.licences.is_file() else ''
        upstream = load_sources(args.sources)[3]
        photos = photos_section(model_rows, libraries, texts)
        text = licences_for(args.date, catalogue, kept, {'photos': photos}, TAG, upstream).encode('utf-8')
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
        'photos': photos,
        'licences': text.decode('utf-8'),
        'pending': [],
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


# --- ai-components-2 and 3 -----------------------------------------------------------------------------------------


def get_json(url: str, token: str | None = None):
    """The JSON at [url] (a GET), with the token only when given (the GitHub API); None for a 404"""
    headers = {'User-Agent': USER_AGENT, 'Accept': 'application/json'}
    if token:
        headers['Authorization'] = f'Bearer {token}'
        headers['Accept'] = 'application/vnd.github+json'
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise Failure(f'GET {urllib.parse.urlsplit(url).path}: HTTP {error.code}') from None
    except (urllib.error.URLError, OSError, ValueError) as error:
        raise Failure(f'GET {url}: {error}') from None


def hf_entry(hf_api: str, repo: str, revision: str, path: str) -> dict | None:
    """The entry of [path] in the repository [repo] of Hugging Face at [revision]: its size and its LFS sum"""
    folder = path.rsplit('/', 1)[0] if '/' in path else ''
    url = f'{hf_api.rstrip("/")}/api/models/{repo}/tree/{revision}' + (f'/{folder}' if folder else '')
    entries = get_json(url) or []
    return next((entry for entry in entries if entry.get('path') == path), None)


def read_cards(models: list, hf_api: str, github_api: str, token: str | None) -> list:
    """What the sources say against the tables: the licence of each card, the size and LFS sum of each file at its
    revision, the weights of our export and the published file it equals. Needs the network."""
    found = []
    for model in models:
        if model.repo.startswith('github:'):
            repo = model.repo[7:]
            licence = ((get_json(f'{github_api.rstrip("/")}/repos/{repo}/license', token) or {}).get('license')
                       or {}).get('spdx_id')
            if licence != model.card:
                found.append(f'{model.component}: GitHub gives the licence {licence} for {repo}, the table '
                             f'{model.card}')
            release = get_json(f'{github_api.rstrip("/")}/repos/{repo}/releases/tags/{model.revision}', token) or {}
            asset = next((asset for asset in release.get('assets', []) if asset.get('name') == model.path), None)
            held = (asset or {}).get('digest') or ''
            if asset is None or asset.get('size') != model.size or (held.startswith('sha256:') and
                                                                   held[7:] != model.sha256):
                found.append(f'{model.component}: the release {model.revision} of {repo} holds {asset and asset.get("size")} '
                             f'bytes for {model.path}, the table {model.size}')
            print(f'{model.component}: {repo} {model.revision}, licence {licence}, {model.path} checked')
            continue
        card = get_json(f'{hf_api.rstrip("/")}/api/models/{model.repo}/revision/{model.revision}') or {}
        licence = (card.get('cardData') or {}).get('license')
        if licence != model.card:
            found.append(f'{model.component}: the card of {model.repo} at {model.revision[:8]} gives the licence '
                         f'{licence}, the table {model.card}')
        entry = hf_entry(hf_api, model.repo, model.revision, model.path) or {}
        expected = model.weights or (model.size, model.sha256)
        held = (entry.get('size'), (entry.get('lfs') or {}).get('oid'))
        if held != expected:
            found.append(f'{model.component}: {model.repo} at {model.revision[:8]} holds {model.path} with {held[0]} '
                         f'bytes, LFS sum {held[1]}; the table says {expected[0]}, {expected[1]}')
        if model.same_as:
            repo, revision, path = model.same_as
            twin = hf_entry(hf_api, repo, revision, path) or {}
            twin_held = (twin.get('size'), (twin.get('lfs') or {}).get('oid'))
            if twin_held != (model.size, model.sha256):
                found.append(f'{model.component}: {repo} at {revision[:8]} holds {path} with {twin_held[0]} bytes, '
                             f'LFS sum {twin_held[1]}: no longer the bytes of our export')
        print(f'{model.component}: {model.repo} {model.revision[:8]}, licence {licence}, {model.path} checked')
    return found


def find_in(places: list, name: str, size: int, digest: str) -> pathlib.Path | None:
    for folder in places:
        candidate = folder / name
        if candidate.is_file() and candidate.stat().st_size == size and sha256_file(candidate) == digest:
            print(f'{name}: found in {folder}, SHA-256 checked')
            return candidate
    return None


def split_parts(source: pathlib.Path, out: pathlib.Path, asset: str) -> list:
    """[source] cut into parts of PART_SIZE bytes in [out], <asset>.001, <asset>.002, ...; a part that already holds
    its bytes stays. Returns [(name, size, sha256)]."""
    parts = []
    with open(source, 'rb') as stream:
        index = 0
        while True:
            data = stream.read(PART_SIZE)
            if not data:
                break
            index += 1
            name = f'{asset}.{index:03d}'
            write_file(out / name, data)
            parts.append((name, len(data), sha256_bytes(data)))
    return parts


def is_program(path: str, data: bytes, platform: str) -> bool:
    """Whether a file of an engine runs: a .exe on Windows, an ELF file that is not a library elsewhere"""
    name = path.rsplit('/', 1)[-1]
    if platform.startswith('windows'):
        return name.lower().endswith('.exe')
    return data[:4] == b'\x7fELF' and '.so' not in name


def safe_path(path: str) -> bool:
    """A relative path with "/" between folders, never absolute nor going up"""
    return bool(path) and not path.startswith('/') and '\\' not in path and not re.match(r'^[A-Za-z]:', path) \
        and all(part not in ('', '.', '..') for part in path.split('/'))


def engine_files(artifact: pathlib.Path) -> dict:
    """The files of the engine in the artifact of the CI, by path: as uploaded, or inside the one zip it holds"""
    with zipfile.ZipFile(artifact) as bundle:
        names = [info for info in bundle.infolist() if not info.is_dir()]
        if len(names) == 1 and names[0].filename.lower().endswith('.zip'):
            with zipfile.ZipFile(io.BytesIO(bundle.read(names[0]))) as inner:
                return {info.filename: inner.read(info) for info in inner.infolist() if not info.is_dir()}
        return {info.filename: bundle.read(info) for info in names}


def engine_archive(files: dict, platform: str) -> tuple:
    """Our archive of an engine: the files sorted by path, dated 1980-01-01, deflated, executable or not; the same
    bytes on every run of the same zlib. Returns (bytes, [(path, size, sha256, executable)])."""
    listed = []
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as bundle:
        for path in sorted(files):
            if not safe_path(path):
                raise Failure(f'the engine holds {path!r}: not a relative path inside it')
            data = files[path]
            program = is_program(path, data, platform)
            info = zipfile.ZipInfo(path, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = (0o100755 if program else 0o100644) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            bundle.writestr(info, data, compresslevel=9)
            listed.append((path, len(data), sha256_bytes(data), program))
    if not any(program for *_, program in listed):
        raise Failure('the engine holds no program')
    return buffer.getvalue(), listed


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def download_artifact(api: str, repo: str, run: str, engine: Engine, token: str, downloads: pathlib.Path) \
        -> pathlib.Path | None:
    """The artifact of [engine] made by the run [run] of our CI, downloaded by the GitHub API; the token goes to the
    API only, never to the storage the API redirects to. None when the run has no such artifact."""
    listed = get_json(f'{api.rstrip("/")}/repos/{repo}/actions/runs/{run}/artifacts?per_page=100', token) or {}
    matches = [artifact for artifact in listed.get('artifacts', [])
               if artifact.get('name', '').startswith(ENGINE_ARTIFACT_PREFIX)
               and (artifact['name'].endswith(engine.artifact_suffix)
                    or artifact['name'].endswith(engine.artifact_suffix.removesuffix('.zip')))]
    if not matches:
        return None
    if len(matches) > 1:
        raise Failure(f'the run {run} has {len(matches)} artifacts for {engine.platform}')
    artifact = matches[0]
    if artifact.get('expired'):
        raise Failure(f'the artifact {artifact["name"]} of the run {run} has expired')
    url = f'{api.rstrip("/")}/repos/{repo}/actions/artifacts/{artifact["id"]}/zip'
    request = urllib.request.Request(url, headers={'Authorization': f'Bearer {token}', 'User-Agent': USER_AGENT,
                                                   'Accept': 'application/vnd.github+json'})
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        with opener.open(request, timeout=300) as response:
            data = response.read()
    except urllib.error.HTTPError as error:
        location = error.headers.get('Location') if error.code in (301, 302, 303, 307, 308) else None
        if location is None:
            raise Failure(f'GET {urllib.parse.urlsplit(url).path}: HTTP {error.code}') from None
        try:
            with urllib.request.urlopen(urllib.request.Request(location, headers={'User-Agent': USER_AGENT}),
                                        timeout=300) as response:
                data = response.read()
        except (urllib.error.URLError, OSError) as failure:
            raise Failure(f'the artifact {artifact["name"]}: {failure}') from None
    downloads.mkdir(parents=True, exist_ok=True)
    name = artifact['name'] if artifact['name'].endswith('.zip') else f'{artifact["name"]}.zip'
    target = downloads / name
    write_file(target, data)
    print(f'{name}: {len(data)} bytes from the run {run}')
    return target


def artifact_in(places: list, engine: Engine) -> pathlib.Path | None:
    """The artifact of [engine] already in a --cache folder"""
    found = sorted({path.resolve() for folder in places if folder.is_dir()
                    for path in folder.glob(f'{ENGINE_ARTIFACT_PREFIX}*{engine.artifact_suffix}')})
    if len(found) > 1:
        raise Failure(f'{len(found)} artifacts for {engine.platform} in the cache: {", ".join(map(str, found))}')
    return found[0] if found else None


def prepare_family(args, catalogue: dict, release: str, token: str | None) -> dict:
    """Makes the models, parts and archives of ai-components-2 or 3 in args.out; returns what the catalogue should say.
    MODEL-LICENSES.md and SHA256SUMS come after (finish_family), from the catalogue once written."""
    upstream = load_sources(args.sources)[3]
    models = [model for model in upstream if model.release == release]
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
        cards = read_cards(models, args.hf_api, args.api, token)
        if cards:
            raise Failure('the sources disagree with the tables: ' + '; '.join(cards))
        files, parts, archives, pending = {}, {}, {}, []
        for model in models:
            component = catalogue.get(model.component)
            if component is None:
                raise Failure(f'the catalogue has no component {model.component}')
            if (component.get('size'), component.get('sha256')) != (model.size, model.sha256):
                raise Failure(f'{model.component}: the catalogue says {component.get("size")} bytes, SHA-256 '
                              f'{component.get("sha256")}; the source has {model.size} bytes, SHA-256 {model.sha256}')
            asset = component['assetName']
            if model.url is None:
                source = find_in(places, asset, model.size, model.sha256)
                if source is None:
                    raise Failure(f'{asset}: our export is in no --cache folder; make it with export_moge_onnx.py')
            else:
                source = fetch(asset, model.url, model.size, model.sha256, places, downloads)
            if model.size >= ASSET_LIMIT:
                made = split_parts(source, out, asset)
                parts[model.component] = made
                for name, size, digest in made:
                    files[name] = (size, digest)
                print(f'{asset}: {len(made)} parts')
                continue
            if source.resolve() != (out / asset).resolve():
                shutil.copyfile(source, out / f'{asset}.tmp')
                os.replace(out / f'{asset}.tmp', out / asset)
            files[asset] = (model.size, model.sha256)
        for engine in ENGINES:
            component = catalogue.get(engine.component)
            if component is None or component.get('releaseTag') != release:
                continue
            artifact = artifact_in(places, engine)
            if artifact is None and args.from_run:
                artifact = download_artifact(args.api, args.repo, args.from_run, engine, token, downloads)
            if artifact is None:
                pending.append(engine.component)
                print(f'{engine.component}: pending, no artifact of the CI (give --from-run RUN of its sdcpp job)')
                continue
            data, listed = engine_archive(engine_files(artifact), engine.platform)
            write_file(out / component['assetName'], data)
            files[component['assetName']] = (len(data), sha256_bytes(data))
            archives[engine.component] = (len(data), sha256_bytes(data), listed)
            print(f'{component["assetName"]}: {len(listed)} files, {len(data)} bytes')
    finally:
        if temporary is not None:
            temporary.cleanup()
    return {'files': files, 'parts': parts, 'archives': archives, 'pending': pending, 'upstream': upstream}


def finish_family(args, made: dict, catalogue: dict, release: str) -> None:
    """MODEL-LICENSES.md and SHA256SUMS of a family in args.out, from [catalogue]"""
    kept = args.licences.read_text(encoding='utf-8') if args.licences.is_file() else ''
    text = licences_for(args.date, catalogue, kept, None, release, made['upstream'])
    made['licences'] = text
    data = text.encode('utf-8')
    files = made['files']
    write_file(args.out / LICENCES_NAME, data)
    files[LICENCES_NAME] = (len(data), sha256_bytes(data))
    sums = ''.join(f'{files[name][1]}  {name}\n' for name in sorted(files) if name != SUMS).encode('utf-8')
    write_file(args.out / SUMS, sums)
    files[SUMS] = (len(sums), sha256_bytes(sums))
    print()
    print(f'Files of {release} in {args.out}:')
    for name in sorted(files):
        size, digest = files[name]
        print(f'  {name}  {size} bytes  {digest}')


def family_findings(catalogue: dict, made: dict) -> list:
    found = []
    for component, parts in made['parts'].items():
        if catalogue[component]['parts'] != parts:
            found.append(f'{component}: the catalogue has the parts {catalogue[component]["parts"]}; the files give '
                         f'{parts}')
    for component, (size, digest, files) in made['archives'].items():
        entry = catalogue[component]
        if (entry.get('size'), entry.get('sha256'), entry['archiveFiles']) != (size, digest, files):
            found.append(f'{component}: the catalogue says size {entry.get("size")}, sha256 {entry.get("sha256")}, '
                         f'{len(entry["archiveFiles"])} files; the archive gives {size}, {digest}, {len(files)} files')
    return found


# --- the offline check --------------------------------------------------------------------------------------------


def hexadecimal(digest) -> bool:
    return isinstance(digest, str) and re.fullmatch(r'[0-9a-f]{64}', digest) is not None


def check(catalogue: dict, licences: str, sources: pathlib.Path | None = None, releases: tuple = RELEASES) -> tuple:
    """What is wrong in the catalogue and MODEL-LICENSES.md for [releases], without the network, and the engines that
    still wait for lot P2"""
    found, pending = [], []
    archives_table, models_table, _, upstream_table = load_sources(sources)
    archives = {archive.component: archive for archive in archives_table}
    models = {model.component: model for model in models_table}
    upstream = {model.component: model for model in upstream_table}
    engines = {engine.component: engine for engine in ENGINES}
    family = {**{component: TAG for component in [*archives, *models]},
              **{component: model.release for component, model in upstream.items()},
              **{component: TAG_PANORAMAS for component in engines}}
    if set(catalogue) != set(family):
        found.append(f'the catalogue has {sorted(catalogue)}; this script knows {sorted(family)}')
    for component_id, component in sorted(catalogue.items()):
        release = family.get(component_id, component.get('releaseTag'))
        if release not in releases:
            continue
        if component.get('releaseTag') != release:
            found.append(f'{component_id}: in {component.get("releaseTag")}, its family is in {release}')
        size, digest = component.get('size'), component.get('sha256')
        if component.get('licence') not in ALLOWED_LICENCES:
            found.append(f'{component_id}: licence {component.get("licence")} is not one this project allows')
        if component_id in engines:
            files = component['archiveFiles']
            if size is None and digest is None and not files:
                pending.append(component_id)
                continue
            if not isinstance(size, int) or not hexadecimal(digest) or not files:
                found.append(f'{component_id}: incomplete in the catalogue (size {size}, sha256 {digest}, '
                             f'{len(files)} files)')
                continue
            for path, file_size, file_digest, _ in files:
                if not safe_path(path) or not hexadecimal(file_digest):
                    found.append(f'{component_id}: the file {path!r} of its archive is not a safe path with a sum')
                row = f'| `{path}` | {file_size} | `{file_digest}` |'
                if row not in licences:
                    found.append(f'{LICENCES_NAME} lacks the row {row}')
            if not any(executable for *_, executable in files):
                found.append(f'{component_id}: its archive holds no program')
            row = f'| `{component.get("assetName")}` | `{component_id}` | {size} | `{digest}` |'
            if row not in licences:
                found.append(f'{LICENCES_NAME} lacks the row {row}')
            continue
        if not isinstance(size, int) or not hexadecimal(digest):
            found.append(f'{component_id}: incomplete in the catalogue (size {size}, sha256 {digest})')
            continue
        asset = component.get('assetName')
        if component_id in models:
            model = models[component_id]
            if (size, digest) != (model.size, model.sha256):
                found.append(f'{component_id}: the catalogue and the official file differ')
            row = f'| `{asset}` | {model.use} | {size} | `{digest}` |'
        elif component_id in upstream:
            model = upstream[component_id]
            if (size, digest) != (model.size, model.sha256):
                found.append(f'{component_id}: the catalogue and the source differ')
            row = f'| `{asset}` | `{component_id}` | {size} | `{digest}` |'
            parts = component['parts']
            if size >= ASSET_LIMIT:
                names = [f'{asset}.{index:03d}' for index in range(1, len(parts) + 1)]
                sizes = [part_size for _, part_size, _ in parts]
                if not parts or [name for name, _, _ in parts] != names or sum(sizes) != size \
                        or any(part_size != PART_SIZE for part_size in sizes[:-1]) or not 0 < sizes[-1] <= PART_SIZE \
                        or not all(hexadecimal(part_digest) for _, _, part_digest in parts):
                    found.append(f'{component_id}: {size} bytes, so parts of {PART_SIZE} bytes named {asset}.001 and '
                                 f'on, with their sums; the catalogue has {parts}')
                for index, (name, part_size, part_digest) in enumerate(parts, start=1):
                    part = part_row(name, index, len(parts), asset, part_size, part_digest)
                    if part not in licences:
                        found.append(f'{LICENCES_NAME} lacks the row {part}')
            elif parts:
                found.append(f'{component_id}: under 2 GiB, in one asset, but the catalogue has parts')
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
    sections = sections_of(licences)
    for tag in (TAG_SCENES, TAG_PANORAMAS):
        if tag in releases and sections.get(tag) != family_section(tag, catalogue, tuple(upstream_table)):
            found.append(f'the section of {tag} in {LICENCES_NAME} is not what the catalogue gives: run with '
                         f'--write-licences')
    if not re.search(r'^Date: \d{4}-\d{2}-\d{2}\.', licences, re.MULTILINE):
        found.append(f'{LICENCES_NAME} has no date')
    return found, pending


# --- the release --------------------------------------------------------------------------------------------------

NOTES = {
    TAG: 'The AI components of Immuch360: the depth model Depth Anything V2 Small (Apache-2.0) for the computers and the '
         'Meta Quest, and ONNX Runtime (MIT) for the computers.',
    TAG_SCENES: 'The AI components of the 3D scenes of Immuch360: MoGe-2 ViT-S, our ONNX export of its MIT weights, and '
                'LaMa (Apache-2.0).',
    TAG_PANORAMAS: 'The AI components of the 360° panoramas of Immuch360: FLUX.2 klein base 4B, Qwen3 4B, the VAE of '
                   'klein and the 360 ERP Outpaint LoRA (Apache-2.0), MI-GAN (MIT), Real-ESRGAN x4plus (BSD-3-Clause) '
                   'and stable-diffusion.cpp on Vulkan (MIT), built and signed by our CI. The files of 2 GiB or more '
                   'are in parts, which the app puts end to end.',
}
NOTES_END = (
    ' This is not a release of the app: the app downloads these files only when you ask it to, checks each one by its '
    f'SHA-256, and works offline afterwards. Licences and sources: {LICENCES_NAME}. Sums: {SUMS}.\n'
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


def drafts_of(github: GitHub, repo: str, tag: str) -> list:
    """The drafts of [repo] with the tag [tag], which GET /releases/tags does not see"""
    found = []
    page = 1
    while True:
        releases = github.call('GET', f'/repos/{repo}/releases?per_page=100&page={page}') or []
        found += [release for release in releases if release.get('draft') and release.get('tag_name') == tag]
        if len(releases) < 100:
            return found
        page += 1


def publish(args, made: dict, token: str) -> int:
    tag = args.release
    github = GitHub(args.api, token)
    if github.call('GET', f'/repos/{args.repo}/releases/tags/{tag}') is not None:
        print(f'{tag} exists already on {args.repo}: nothing is changed. Delete it by hand to publish it again.')
        return 1
    drafts = drafts_of(github, args.repo, tag)
    if drafts:
        print(f'a draft of {tag} exists already on {args.repo}: {drafts[0].get("html_url")}. Nothing is changed. '
              f'Delete it by hand to publish again.')
        return 1
    release = github.call('POST', f'/repos/{args.repo}/releases', {
        'tag_name': tag, 'name': f'AI components {tag.rsplit("-", 1)[-1]}', 'body': NOTES[tag] + NOTES_END,
        'draft': True, 'prerelease': True, 'make_latest': 'false',
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
        raise Failure(f'{tag} is not a published prerelease: {release.get("html_url")}')
    latest = github.call('GET', f'/repos/{args.repo}/releases/latest')
    if latest is not None and latest.get('tag_name') == tag:
        raise Failure(f'{tag} became the latest release of {args.repo}: mark the app release as latest again')
    print(f'published as a prerelease: {release["html_url"]}')
    return 0


# --- command line -------------------------------------------------------------------------------------------------


def read_token(args) -> str | None:
    token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
    if args.token_file:
        token = args.token_file.read_text(encoding='utf-8').strip()
    return token or None


def main(argv=None) -> int:
    sys.stdout.reconfigure(line_buffering=True)
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--out', type=pathlib.Path, help='the folder of the files of the release')
    parser.add_argument('--release', choices=RELEASES, help=f'the release to make or check ({TAG} by default when '
                        'making, all three when checking)')
    parser.add_argument('--cache', type=pathlib.Path, action='append', default=[],
                        help='a folder of files already downloaded or made; downloads go to the first one')
    parser.add_argument('--from-run', help='the run of our CI whose sdcpp artifacts give the engines of '
                        f'{TAG_PANORAMAS}')
    parser.add_argument('--write', action='store_true', help='write the catalogue and MODEL-LICENSES.md')
    parser.add_argument('--write-licences', action='store_true',
                        help='write the sections of the scenes and panoramas of MODEL-LICENSES.md from the catalogue, '
                        'offline')
    parser.add_argument('--publish', action='store_true', help='create the prerelease on GitHub')
    parser.add_argument('--check', action='store_true', help='check the catalogue and MODEL-LICENSES.md, offline')
    parser.add_argument('--token-file', type=pathlib.Path, help='a file holding the token')
    parser.add_argument('--sources', type=pathlib.Path, help=argparse.SUPPRESS)
    parser.add_argument('--catalogue', type=pathlib.Path, default=CATALOGUE, help=argparse.SUPPRESS)
    parser.add_argument('--licences', type=pathlib.Path, default=LICENCES, help=argparse.SUPPRESS)
    parser.add_argument('--date', default=datetime.date.today().isoformat(), help=argparse.SUPPRESS)
    parser.add_argument('--repo', default=REPO, help=argparse.SUPPRESS)
    parser.add_argument('--api', default=API, help=argparse.SUPPRESS)
    parser.add_argument('--hf-api', default=HF_API, help=argparse.SUPPRESS)
    parser.add_argument('--part-size', type=int, help=argparse.SUPPRESS)
    parser.add_argument('--asset-limit', type=int, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    global PART_SIZE, ASSET_LIMIT
    # The tests cut small files
    PART_SIZE = args.part_size or PART_SIZE
    ASSET_LIMIT = args.asset_limit or ASSET_LIMIT

    if not args.catalogue.is_file():
        print(f'no catalogue at {args.catalogue}')
        return 2
    catalogue_text = args.catalogue.read_text(encoding='utf-8')
    catalogue = read_catalogue(catalogue_text)
    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}', args.date):
        print(f'--date {args.date!r} is not YYYY-MM-DD')
        return 2
    if args.write_licences:
        kept = args.licences.read_text(encoding='utf-8') if args.licences.is_file() else ''
        upstream = load_sources(args.sources)[3]
        args.licences.parent.mkdir(parents=True, exist_ok=True)
        args.licences.write_text(licences_for(args.date, catalogue, kept, None, None, upstream), encoding='utf-8',
                                 newline='\n')
        print(f'written: {args.licences}')
        if not args.check:
            return 0
    if args.check:
        licences = args.licences.read_text(encoding='utf-8') if args.licences.is_file() else ''
        releases = (args.release,) if args.release else RELEASES
        found, pending = check(catalogue, licences, args.sources, releases)
        for line in found:
            print(f'publish_ai_components: {line}')
        if found:
            return 1
        counted = [component for component in catalogue.values() if component.get('releaseTag') in releases]
        print(f'{len(counted)} components in {", ".join(releases)}, each complete and named with its size and SHA-256 '
              f'in {LICENCES_NAME}' + (f'; pending for lot P2: {", ".join(sorted(pending))}' if pending else ''))
        return 0
    if args.out is None:
        print('--out DIR is needed (or --check)')
        return 2
    args.release = args.release or TAG
    token = read_token(args)
    if (args.publish or args.from_run) and not token:
        print('no token: set GH_TOKEN or GITHUB_TOKEN, or give --token-file')
        return 2
    try:
        if args.release == TAG:
            made = prepare(args, catalogue)
            if args.write:
                new = write_catalogue(catalogue_text, made['libraries'], made['notices'])
        else:
            made = prepare_family(args, catalogue, args.release, token)
            new = write_catalogue_family(catalogue_text, made['parts'], made['archives'])
        if args.write:
            if new != catalogue_text:
                args.catalogue.write_text(new, encoding='utf-8', newline='\n')
                print(f'written: {args.catalogue}')
            catalogue = read_catalogue(new)
        if args.release != TAG:
            finish_family(args, made, catalogue, args.release)
        if args.write:
            args.licences.parent.mkdir(parents=True, exist_ok=True)
            args.licences.write_text(made['licences'], encoding='utf-8', newline='\n')
            print(f'written: {args.licences}')
        found = catalogue_findings(catalogue, made) if args.release == TAG else family_findings(catalogue, made)
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
        if made['pending']:
            print(f'pending: {", ".join(made["pending"])}')
        if not args.publish:
            print(f'not published: {args.release} is created only with --publish')
            return 0
        if found:
            print(f'not published: {args.release} must carry the files the catalogue names')
            return 1
        if made['pending']:
            print(f'not published: {args.release} waits for {", ".join(made["pending"])}')
            return 1
        return publish(args, made, token)
    except (Failure, OSError, zipfile.BadZipFile, tarfile.TarError) as error:
        message = f'publish_ai_components: {error}'
        print(message.replace(token, '***') if token else message)
        return 1


if __name__ == '__main__':
    sys.exit(main())
