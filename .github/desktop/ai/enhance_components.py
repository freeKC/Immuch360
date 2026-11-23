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
      ai-components-3), with the Dart lines of its entry printed; SHA256SUMS. Nothing is downloaded.

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


class Failure(Exception):
    pass


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
        print(f'{asset}: {len(data)} bytes, SHA-256 {digest}; the entry {component} of ai_enhance_manifest.dart:')
        print(f'  size: {len(data)},\n  sha256: \'{digest}\',')
        print(pub.dart_archive_files(listed), end='')
    (out / 'SHA256SUMS').write_text(''.join(f'{digest}  {name}\n' for name, digest in sorted(sums.items())))
    print(f'{len(sums)} files and SHA256SUMS in {out}; nothing published')
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('check')
    maker = commands.add_parser('make')
    maker.add_argument('--cache', type=pathlib.Path, action='append', default=[])
    maker.add_argument('--artifact', type=pathlib.Path, action='append', default=[])
    maker.add_argument('--out', type=pathlib.Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == 'check':
            found = check()
            for line in found:
                print(f'::error::{line}')
            if not found:
                print(f'{len(MODELS)} models and {len(ENGINES)} archives of {TAG}, as ai_enhance_manifest.dart says')
            return 1 if found else 0
        return make(args.cache, args.artifact, args.out)
    except (Failure, pub.Failure) as error:
        print(f'::error::{error}')
        return 1


if __name__ == '__main__':
    sys.exit(main())
