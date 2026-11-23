#!/usr/bin/env python3
"""The files of the prerelease ai-components-7, the components of "Enhance (AI)" (release 51), NOT published by this
script.

store/m2/ai-enhance-2026-11-22 (study.md, probe-e0.md) chose the files; their entries are in
mobile/lib/domain/models/ai_immersive/ai_enhance_manifest.dart, kept out of the catalogue of
ai_components_manifest.dart until the release is made (publish_ai_components.py checks every entry of that catalogue
against a published release). Once ai-components-7 is out, they join that catalogue and the tables of
publish_ai_components.py, as the DirectML runtime of ai-components-6 will.

  enhance_components.py check
      offline: the entries of ai_enhance_manifest.dart are those of MODELS below (asset, size, SHA-256, the parts of
      1945 MiB of a file of 2 GiB or more and their sum), each under a licence this project allows
  enhance_components.py make --cache DIR [--cache DIR]... [--artifact FILE]... --out DIR
      the files of the release in DIR: each model found in a --cache folder by its name and checked by its SHA-256
      (the probe kept them in downloads/seedvr2 and downloads/vosr2-int8/<part>/model.onnx), copied under its asset
      name, or cut into its parts; each archive of stable-diffusion.cpp made from the artifact
      Immuch360-AI-sdcpp-0d71f96-1-<system>.zip of the jobs sdcpp-seedvr2-* (as publish_ai_components.py makes those of
      ai-components-3), with the Dart lines of its entry printed; SHA256SUMS; and LICENCE_SECTION, the section of
      ai-components-7 for MODEL-LICENSES.md (below). Nothing is downloaded.
  enhance_components.py licences --out FILE
      that section alone, with the sizes and sums of the archives as "pending" until their artifacts are given to make.

The section is a separate file on purpose: licenses/ai-components/MODEL-LICENSES.md is written by
publish_ai_components.py from its catalogue (--write), and --publish of any release refuses while the file of the
repository differs from what it writes, so a section of a release it does not know yet would block the publication of
ai-components-6. Once the entries of ai-components-7 move into the catalogue and the tables of publish_ai_components.py,
its --write writes the section of ai-components-7 into MODEL-LICENSES.md; this file is the text to check it against.

Only the Python standard library and publish_ai_components.py beside it. Exit codes: 0 good, 1 a check failed, 2 bad
arguments or missing inputs.
"""
from __future__ import annotations

import argparse
import hashlib
import pathlib
import re
import shutil
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import publish_ai_components as pub  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[3]
MANIFEST = ROOT / 'mobile' / 'lib' / 'domain' / 'models' / 'ai_immersive' / 'ai_enhance_manifest.dart'
TAG = 'ai-components-7'

# The models: component id, asset name, the name and folder the probe kept it under, size, SHA-256, licence, source
MODELS = (
    ('seedvr2-3b-int8-convrot', 'seedvr2_3b_int8_convrot.safetensors', 'seedvr2/seedvr2_3b_int8_convrot.safetensors',
     3458259704, 'c3dec8bcc5916843a8a858572970597462e1f2dc598d6dfd818f6cd40f53a157', 'Apache-2.0',
     'Comfy-Org/SeedVR2 df488797 diffusion_models/seedvr2_3b_int8_convrot.safetensors'),
    ('seedvr2-ema-vae-fp16', 'seedvr2_ema_vae_fp16.safetensors', 'seedvr2/seedvr2_ema_vae_fp16.safetensors',
     501324814, '20678548f420d98d26f11442d3528f8b8c94e57ee046ef93dbb7633da8612ca1', 'Apache-2.0',
     'Comfy-Org/SeedVR2 df488797 vae/seedvr2_ema_vae_fp16.safetensors'),
    ('vosr2-1.4b-int8-image-encoder', 'vosr2-int8-image_encoder.onnx', 'vosr2-int8/image_encoder/model.onnx',
     460494444, '991f96af4a0dedf5da19d5a69a8c77f106138cacffdc82fadeef2397dd3c37cd', 'Apache-2.0',
     'moonbox-dev/VOSR-ONNX 46811283 int8/image_encoder/model.onnx'),
    ('vosr2-1.4b-int8-vae-encoder', 'vosr2-int8-vae_encoder.onnx', 'vosr2-int8/vae_encoder/model.onnx',
     38701657, 'c3efac4d5f173692c45002aa90d79f155898697db73cfcef1fb90a56d07ea161', 'Apache-2.0',
     'moonbox-dev/VOSR-ONNX 46811283 int8/vae_encoder/model.onnx'),
    ('vosr2-1.4b-int8-transformer', 'vosr2-int8-transformer.onnx', 'vosr2-int8/transformer/model.onnx',
     1409190442, 'e38ab963051515bdc39fb1a096d8eb3ee895355cdc1b658bbd7ce9fa3af8bd62', 'Apache-2.0',
     'moonbox-dev/VOSR-ONNX 46811283 int8/transformer/model.onnx'),
    ('vosr2-1.4b-int8-vae-decoder', 'vosr2-int8-vae_decoder.onnx', 'vosr2-int8/vae_decoder/model.onnx',
     50689496, '3ca755f97a8d57ad5f793c757f0d3a65200067d98528f110d765b4b28ef989ba', 'Apache-2.0',
     'moonbox-dev/VOSR-ONNX 46811283 int8/vae_decoder/model.onnx'),
)

# The archives of stable-diffusion.cpp at 0d71f963: component id, platform, asset name
ENGINES = (
    ('sd-cpp-seedvr2-vulkan-win-x64', 'windows-x64', 'sd-cpp-seedvr2-vulkan-win-x64.zip'),
    ('sd-cpp-seedvr2-vulkan-linux-x64', 'linux-x64', 'sd-cpp-seedvr2-vulkan-linux-x64.zip'),
)
ARTIFACT = re.compile(r'^Immuch360-AI-sdcpp-0d71f96-\d+-(windows-x64|linux-x64)\.zip$')


LICENCE_SECTION = 'MODEL-LICENSES-ai-components-7.md'

# The licence texts the probe of 23 November 2026 read again before each download (its folder licences/), by SHA-256
LICENCE_TEXTS = (
    ('ByteDance-Seed/SeedVR LICENSE (sha 9b0726ca on GitHub)', 'Apache License, Version 2.0, January 2004',
     '5967a0c153e731109b76c5d83b5e0fae2382b6aaf7b898d08ff03702eea59430'),
    ('cswry/VOSR LICENSE, the same text in moonbox-dev/VOSR-ONNX at 46811283',
     'Apache License, Version 2.0, January 2004', '6cf63d87586c7c25c3ab8e62eef5c75bbaa982b0a6f9c00c59e2720255aac9ec'),
    ('leejet/stable-diffusion.cpp LICENSE', 'MIT License, Copyright (c) 2023 leejet',
     'b53fa08f515cb5a6fff7b9fd8fcd0961a4b80df29d74372d25e1f9171aa042ee'),
)


class Failure(Exception):
    pass


def licence_section(archives: dict | None = None) -> str:
    """The section of ai-components-7 for MODEL-LICENSES.md. [archives]: asset name -> (size, sha256) of the archives
    of stable-diffusion.cpp that make built, the others pending"""
    archives = archives or {}
    lines = [
        f'<!-- {TAG} -->',
        f'## {TAG}: Enhance (AI)',
        '',
        f'https://github.com/{pub.REPO}/releases/tag/{TAG}',
        '',
        '| File | Component | Size (bytes) | SHA-256 | Licence | Source, pinned revision |',
        '| --- | --- | --- | --- | --- | --- |',
    ]
    for component, asset, _, size, digest, licence, source in MODELS:
        repository, revision, path = source.split(' ', 2)
        lines.append(f'| `{asset}` | `{component}` | {size} | `{digest}` | {licence} | '
                     f'https://huggingface.co/{repository}, revision `{revision}`, `{path}` |')
    for component, _, asset in ENGINES:
        size, digest = archives.get(asset, ('pending', 'pending'))
        shown = digest if digest == 'pending' else f'`{digest}`'
        lines.append(f'| `{asset}` | `{component}` | {size} | {shown} | MIT | built and signed by our CI |')
    lines += [
        '',
        'The files of 2 GiB or more are in parts (GitHub refuses a larger asset), put end to end by the app, which',
        'checks the sum of each part and of the whole:',
        '',
        '| Part | Of | Size (bytes) | SHA-256 |',
        '| --- | --- | --- | --- |',
    ]
    for component, entry in sorted(entries().items()):
        parts = entry['parts']
        for index, (name, size, digest) in enumerate(parts, 1):
            lines.append(f'| `{name}` | {index} of {len(parts)} of `{entry["asset"]}` | {size} | `{digest}` |')
    lines += [
        '',
        'SeedVR2 3B: Apache-2.0. The card of ByteDance-Seed/SeedVR2-3B (revision `37255ff8`) says `license:',
        'apache-2.0` and "SeedVR and SeedVR2 are licensed under the Apache 2.0."; the files are the repack of',
        'Comfy-Org/SeedVR2 at `df48879708206a403d2a61acd55578c2e80fd233` (card `license: apache-2.0`, "Repackaged',
        'model files for ComfyUI"). SeedVR2 was trained from scratch (arXiv 2506.05301, section 4: a 7B model "from',
        'scratch", the 3B one "distilled from the original 7B one"), so it inherits no base model; the weights of',
        'SeedVR v1, initialised from SD3-Medium, are not used. Its VAE was trained from scratch too.',
        '',
        'VOSR 2.0 1.4B int8: the ONNX export of moonbox-dev/VOSR-ONNX at `46811283f2b767d9d634cdd3d8e465594712df61`,',
        'whose card says "Apache-2.0. These files are a derivative of the original model and carry its license", of',
        'the checkpoints of CSWRY/VOSR (card `license: apache-2.0`), whose table gives "VOSR checkpoints (`VOSR2/`,',
        '`VOSR_*/`) and project-authored decoder files" the terms "Apache-2.0 under the project license", and its',
        '`Qwen-Image-vae-2d/` VAE "the applicable upstream terms" of Wan2.1 (GitHub',
        '`Apache License 2.0`) and Qwen-Image (card `apache-2.0`), and DINOv2 (facebookresearch/dinov2, `Apache',
        'License 2.0`). Only the 1.4B models are used: the 0.5B ones take the VAE of Stable Diffusion 2.1, under',
        'OpenRAIL++, which this project does not ship.',
        '',
        'stable-diffusion.cpp and ggml: MIT',
        '(https://github.com/leejet/stable-diffusion.cpp/blob/0d71f963af9c94941f4a67e8ea145935651dd756/LICENSE,',
        'https://github.com/leejet/ggml/blob/eeda9ec48fc84a3df0bb9dcc19ae9053075a2539/LICENSE), built by our CI at the',
        'commits of `.github/desktop/ai/sd_cpp_seedvr2.lock.json` and signed for Windows, run by the app as a child',
        'process; the licences of the code built into them are in the `licenses/` folder of each archive. No CUDA.',
        '',
        'The licence texts, as read again on 23 November 2026:',
        '',
        '| Text | First line | SHA-256 |',
        '| --- | --- | --- |',
    ]
    for name, first, digest in LICENCE_TEXTS:
        lines.append(f'| {name} | {first} | `{digest}` |')
    lines.append('')
    return '\n'.join(lines)


def entries() -> dict:
    """The entries of ai_enhance_manifest.dart: the const AiComponent blocks and the calls of _vosr, by id"""
    text = MANIFEST.read_text(encoding='utf-8')
    found = {}
    for block in re.finditer(r'^const \w+ = AiComponent\(\n(.*?)^\);\n', text, re.MULTILINE | re.DOTALL):
        body = block.group(1)
        field = {key: value for key, value in re.findall(r"^  (\w+): '?([^',\n]*)'?,$", body, re.MULTILINE)}
        parts = re.findall(r"AiComponentPart\(\s*assetName: '([^']*)',\s*size: (\d+),\s*sha256: '([^']*)',?\s*\)",
                           body)
        found[field['id']] = {'asset': field.get('assetName'), 'size': field.get('size'),
                              'sha256': field.get('sha256'), 'licence': field.get('licence'),
                              'parts': [(name, int(size), digest) for name, size, digest in parts]}
    for call in re.finditer(r"_vosr\(\s*'(\w+)',\s*'[^']*',\s*(\d+),\s*'([0-9a-f]{64})',?\s*\)", text):
        part, size, digest = call.groups()
        found[f'vosr2-1.4b-int8-{part.replace("_", "-")}'] = {
            'asset': f'vosr2-int8-{part}.onnx', 'size': size, 'sha256': digest, 'licence': 'Apache-2.0', 'parts': []}
    return found


def check() -> list:
    found = []
    listed = entries()
    for component, asset, _, size, digest, licence, _ in MODELS:
        entry = listed.get(component)
        if entry is None:
            found.append(f'{component}: not in ai_enhance_manifest.dart')
            continue
        if (entry['asset'], entry['size'], entry['sha256']) != (asset, str(size), digest):
            found.append(f'{component}: the manifest has {entry["asset"]} {entry["size"]} {entry["sha256"]}')
        if licence not in pub.ALLOWED_LICENCES or entry['licence'] not in (licence, '_seedVr2Licence'):
            found.append(f'{component}: licence {licence} / {entry["licence"]}')
        parts = entry['parts']
        if size >= pub.ASSET_LIMIT:
            names = [f'{asset}.{index:03d}' for index in range(1, len(parts) + 1)]
            sizes = [part_size for _, part_size, _ in parts]
            if not parts or [name for name, _, _ in parts] != names or sum(sizes) != size \
                    or any(part_size != pub.PART_SIZE for part_size in sizes[:-1]):
                found.append(f'{component}: {size} bytes, parts of {pub.PART_SIZE} bytes expected, has {parts}')
        elif parts:
            found.append(f'{component}: under 2 GiB but in parts')
    for component, _, _ in ENGINES:
        if component not in listed:
            found.append(f'{component}: not in ai_enhance_manifest.dart')
    return found


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(8 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def find(caches: list, relative: str, size: int, digest: str) -> pathlib.Path | None:
    for cache in caches:
        for candidate in (cache / relative, cache / pathlib.Path(relative).name):
            if candidate.is_file() and candidate.stat().st_size == size and sha256_file(candidate) == digest:
                return candidate
    return None


def make(caches: list, artifacts: list, out: pathlib.Path) -> int:
    out.mkdir(parents=True, exist_ok=True)
    sums = {}
    for component, asset, relative, size, digest, _, _ in MODELS:
        source = find(caches, relative, size, digest)
        if source is None:
            print(f'::error::{component}: no file of {size} bytes with SHA-256 {digest} in the caches')
            return 1
        if size >= pub.ASSET_LIMIT:
            for name, part_size, part_digest in pub.split_parts(source, out, asset):
                sums[name] = part_digest
                print(f'{name}: {part_size} bytes, SHA-256 {part_digest}')
        else:
            shutil.copyfile(source, out / asset)
            sums[asset] = digest
            print(f'{asset}: {size} bytes, SHA-256 {digest}')
    built = {}
    for artifact in artifacts:
        match = ARTIFACT.match(artifact.name)
        if not match:
            print(f'::error::{artifact.name} is no artifact of the jobs sdcpp-seedvr2-*')
            return 2
        component, platform, asset = next(engine for engine in ENGINES if engine[1] == match.group(1))
        data, listed = pub.engine_archive(pub.engine_files(artifact), platform)
        (out / asset).write_bytes(data)
        digest = hashlib.sha256(data).hexdigest()
        sums[asset] = digest
        built[asset] = (len(data), digest)
        print(f'{asset}: {len(data)} bytes, SHA-256 {digest}; the entry {component} of ai_enhance_manifest.dart:')
        print(f'  size: {len(data)},\n  sha256: \'{digest}\',')
        print(pub.dart_archive_files(listed), end='')
    (out / 'SHA256SUMS').write_text(''.join(f'{digest}  {name}\n' for name, digest in sorted(sums.items())))
    (out / LICENCE_SECTION).write_text(licence_section(built), encoding='utf-8')
    print(f'{len(sums)} files, SHA256SUMS and {LICENCE_SECTION} in {out}; nothing published')
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('check')
    maker = commands.add_parser('make')
    maker.add_argument('--cache', type=pathlib.Path, action='append', default=[])
    maker.add_argument('--artifact', type=pathlib.Path, action='append', default=[])
    maker.add_argument('--out', type=pathlib.Path, required=True)
    licences = commands.add_parser('licences')
    licences.add_argument('--out', type=pathlib.Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == 'check':
            found = check()
            for line in found:
                print(f'::error::{line}')
            if not found:
                print(f'{len(MODELS)} models and {len(ENGINES)} archives of {TAG}, as ai_enhance_manifest.dart says')
            return 1 if found else 0
        if args.command == 'licences':
            args.out.write_text(licence_section(), encoding='utf-8')
            print(f'the section of {TAG} in {args.out}, its archives pending')
            return 0
        return make(args.cache, args.artifact, args.out)
    except (Failure, pub.Failure) as error:
        print(f'::error::{error}')
        return 1


if __name__ == '__main__':
    sys.exit(main())
