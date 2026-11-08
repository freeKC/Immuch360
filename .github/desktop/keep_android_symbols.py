#!/usr/bin/env python3
"""Keeps what the stores and the project need to read the crash traces of an Android release build.

Every crash trace of the Android builds names obfuscated Java classes (R8) and native frames by offset only: the
R8 mapping and the symbol tables of the native libraries turn them back into names. What each build has:

- The App Bundle of the phones carries both itself, in BUNDLE-METADATA: the R8 mapping
  (com.android.tools.build.obfuscation/proguard.map) and the symbol table of each native library of each ABI
  (com.android.tools.build.debugsymbols/<abi>/libX.so.sym), which Google Play reads by itself. The Dart code is
  libapp.so: without its .sym, Play would show the Dart frames as offsets. That path regressed upstream once
  (flutter/flutter#188119), so this script fails when the bundle lacks the mapping or the libapp.so.sym of an ABI.
- The Quest APK carries neither, and the Meta Horizon Store reads only what is uploaded with the build
  (ovr-platform-util --debug-symbols-dir). This script keeps its mapping and the symbol tables of its native libraries,
  renamed to the names of the libraries (quest/arm64-v8a/libapp.so), from AGP's native-debug-symbols.zip, or from the
  unstripped libraries of AGP's intermediates when the build made no zip. Each kept file must have the GNU build ID of
  the library in the APK: a store matches symbols by it. libapp.so must match and hold a symbol table, or the script
  fails; another library that does not match, or holds no symbol table, is left out with a note.

What it writes in --out: phone/mapping.txt (or one mapping per phone build with a warning, when the three phone builds
of the workflow did not give the same file), quest/mapping.txt, quest/arm64-v8a/*.so, manifest.json (the label, the
commit, the version code, for each library its flavour, ABI, name, GNU build ID, Breakpad ID as Meta's traces show
it, whether it has a symbol table, size and SHA-256, and for each mapping its SHA-256 and the R8 version) and
README.txt (what each file is and how to use it).

  keep_android_symbols.py keep --out DIR --mappings DIR --bundle AAB --quest-apk APK
                               [--quest-symbols ZIP] [--intermediates DIR] [--label TEXT] [--commit SHA]
      --mappings holds the mapping.txt of each build as the release workflow copies them: phone-universal.txt,
      phone-split.txt, phone-bundle.txt (the build of the bundle) and quest.txt.
  keep_android_symbols.py verify --manifest FILE [--apk QUEST_APK] [--bundle AAB]
      Checks a downloaded build against the manifest of its symbols: the native libraries of the Quest APK (a
      re-signed copy too: signing leaves the libraries as they are) have the build IDs of the kept files, and the
      bundle carries its R8 mapping and the libapp.so.sym of each ABI. Before an upload to a store.
  keep_android_symbols.py build-id FILE...
      Prints the GNU build ID and the Breakpad ID of ELF files.

Standard library only; the ELF reader reads the 32 and 64 bit files of every Android ABI, no binutils needed.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import pathlib
import re
import shutil
import struct
import sys
import zipfile

SYMBOLS_PREFIX = 'BUNDLE-METADATA/com.android.tools.build.debugsymbols/'
PROGUARD_MAP = 'BUNDLE-METADATA/com.android.tools.build.obfuscation/proguard.map'
BUNDLE_MANIFEST = 'base/manifest/AndroidManifest.xml'
QUEST_ABI = 'arm64-v8a'
DART_LIBRARY = 'libapp.so'
PHONE_BUNDLE_MAPPING = 'phone-bundle.txt'
QUEST_MAPPING = 'quest.txt'

SHT_SYMTAB = 2
SHT_NOTE = 7
PT_NOTE = 4
NT_GNU_BUILD_ID = 3

README = """\
Symbols and mappings of the Android build {label} (commit {commit}, version code {version_code}).

phone/mapping.txt         R8 mapping of the phone builds (the universal and per ABI APKs and the App Bundle).
                          The App Bundle carries the same file and the symbol tables of its native libraries in
                          BUNDLE-METADATA, which Google Play reads by itself: the phone native symbols are there, in
                          the .aab of the release (unzip it), not here.
quest/mapping.txt         R8 mapping of the Quest APK (another build: never retrace a Quest trace with the phone file).
quest/arm64-v8a/*.so      Symbol tables of the native libraries of the Quest APK, named as the libraries, to upload to
                          the Meta Horizon Store with the build (ovr-platform-util upload-quest-build
                          --debug-symbols-dir quest/arm64-v8a --debug-symbols-pattern '*.so', or upload-debug-symbols
                          --parent <build id> for a build already uploaded). libapp.so is the Dart code.
manifest.json             For each library its GNU build ID (the BuildId of an Android trace) and its Breakpad ID (the
                          BreakpadBuildId of a Meta trace), its size and SHA-256; for each mapping its SHA-256 and R8
                          version. A trace line names the build ID: the manifest says which build and file it is.

Retrace a Java stack: retrace (R8 8.11 or later, or cmdline-tools/latest/bin/retrace) with the mapping of the flavour:
    retrace quest/mapping.txt trace.txt
Symbolise a native frame "#04 pc 000000000190041c base.apk (offset 0x3988000) (BuildId: 3f3463a7...)": find the build
ID in manifest.json, then
    llvm-symbolizer --obj=quest/arm64-v8a/libapp.so 0x190041c
(the pc of the frame is relative to the library). For a phone frame, take the libX.so.sym of the ABI from the bundle.
"""


# ELF


def elf_info(data: bytes) -> dict | None:
    """The GNU build ID (hexadecimal, None when there is none) and whether a symbol table is present, of the ELF file
    [data]; None when it is not an ELF file. Notes are read from the note sections, or from the PT_NOTE segments of a
    file without section headers."""
    if len(data) < 52 or data[:4] != b'\x7fELF':
        return None
    is64 = data[4] == 2
    endian = '<' if data[5] == 1 else '>'
    try:
        if is64:
            phoff, shoff = struct.unpack_from(endian + 'QQ', data, 0x20)
            phentsize, phnum, shentsize, shnum = struct.unpack_from(endian + 'HHHH', data, 0x36)
        else:
            phoff, shoff = struct.unpack_from(endian + 'II', data, 0x1C)
            phentsize, phnum, shentsize, shnum = struct.unpack_from(endian + 'HHHH', data, 0x2A)
        note_ranges = []
        symtab = False
        for i in range(shnum if shoff else 0):
            at = shoff + i * shentsize
            if is64:
                _, kind, _, _, offset, size = struct.unpack_from(endian + 'IIQQQQ', data, at)
            else:
                _, kind, _, _, offset, size = struct.unpack_from(endian + 'IIIIII', data, at)
            if kind == SHT_NOTE:
                note_ranges.append((offset, size))
            elif kind == SHT_SYMTAB and size > 0:
                symtab = True
        if not note_ranges:
            for i in range(phnum if phoff else 0):
                at = phoff + i * phentsize
                if is64:
                    kind, _, offset, _, _, size = struct.unpack_from(endian + 'IIQQQQ', data, at)
                else:
                    kind, offset, _, _, size = struct.unpack_from(endian + 'IIIII', data, at)
                if kind == PT_NOTE:
                    note_ranges.append((offset, size))
    except struct.error:
        return None
    build_id = None
    for offset, size in note_ranges:
        build_id = build_id or _gnu_build_id(data[offset:offset + size], endian)
    return {'build_id': build_id, 'symtab': symtab}


def _gnu_build_id(notes: bytes, endian: str) -> str | None:
    at = 0
    while at + 12 <= len(notes):
        namesz, descsz, kind = struct.unpack_from(endian + 'III', notes, at)
        name_at = at + 12
        desc_at = name_at + (namesz + 3) // 4 * 4
        end = desc_at + (descsz + 3) // 4 * 4
        if desc_at + descsz > len(notes):
            return None
        if kind == NT_GNU_BUILD_ID and notes[name_at:name_at + namesz].rstrip(b'\0') == b'GNU':
            return notes[desc_at:desc_at + descsz].hex()
        at = end
    return None


def breakpad_id(build_id: str | None) -> str | None:
    """The Breakpad ID of a GNU build ID, as Meta's crash traces show it (BreakpadBuildId): the first 16 bytes as a
    GUID, its first three fields byte swapped, then the age 0. fdf0a0a6f673cdcf... gives a6a0f0fd73f6cfcd..."""
    if not build_id:
        return None
    raw = bytes.fromhex(build_id)[:16].ljust(16, b'\0')
    guid = raw[3::-1] + raw[5:3:-1] + raw[7:5:-1] + raw[8:]
    return guid.hex() + '0'


# Files


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def sha256_entry(archive: zipfile.ZipFile, name: str) -> str:
    digest = hashlib.sha256()
    with archive.open(name) as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def r8_header(path: pathlib.Path) -> dict:
    """compiler_version and pg_map_id of the header of an R8 mapping, when it has them"""
    found = {}
    with path.open('r', encoding='utf-8', errors='replace') as stream:
        for line in stream:
            if not line.startswith('#'):
                break
            match = re.match(r'#\s*(compiler_version|pg_map_id):\s*(\S+)', line)
            if match:
                found[match.group(1)] = match.group(2)
    return found


def bundle_version_code(archive: zipfile.ZipFile) -> str | None:
    """The versionCode of the proto manifest of a bundle, from its raw value (the attribute name, then the string)"""
    try:
        data = archive.read(BUNDLE_MANIFEST)
    except KeyError:
        return None
    match = re.search(rb'\x12\x0bversionCode\x1a[\x01-\x7f](\d+)', data)
    return match.group(1).decode() if match else None


def apk_libraries(apk: pathlib.Path, abi: str) -> dict[str, dict]:
    """The ELF information of each native library of [abi] in [apk], by name"""
    found = {}
    with zipfile.ZipFile(apk) as archive:
        for name in archive.namelist():
            match = re.fullmatch(rf'lib/{re.escape(abi)}/([^/]+\.so)', name)
            if match:
                found[match.group(1)] = elf_info(archive.read(name)) or {'build_id': None, 'symtab': False}
    return found


def bundle_checks(archive: zipfile.ZipFile) -> tuple[list[str], list[str]]:
    """The ABIs of a bundle (those with a libapp.so) and what it lacks for Google Play to read its traces"""
    names = set(archive.namelist())
    abis = sorted({m.group(1) for n in names if (m := re.fullmatch(r'base/lib/([^/]+)/libapp\.so', n))})
    problems = []
    if not abis:
        problems.append('the bundle holds no base/lib/<abi>/libapp.so')
    if PROGUARD_MAP not in names:
        problems.append(f'the bundle holds no R8 mapping ({PROGUARD_MAP}): Google Play could not retrace Java frames')
    for abi in abis:
        if f'{SYMBOLS_PREFIX}{abi}/{DART_LIBRARY}.sym' not in names:
            problems.append(
                f'the bundle holds no {SYMBOLS_PREFIX}{abi}/{DART_LIBRARY}.sym: Google Play would show the Dart frames '
                'of that ABI as offsets (a regression of the Flutter tool such as flutter/flutter#188119)'
            )
    return abis, problems


# keep


def quest_candidates(symbols_zip: pathlib.Path | None, intermediates: pathlib.Path | None) -> tuple[str, dict]:
    """The symbol files of the Quest libraries, by library name, with their source: AGP's native-debug-symbols.zip
    first (arm64-v8a/libX.so.sym, or .dbg at the FULL level), else the unstripped libraries AGP merged"""
    if symbols_zip and symbols_zip.is_file():
        found = {}
        with zipfile.ZipFile(symbols_zip) as archive:
            for name in archive.namelist():
                match = re.fullmatch(rf'(?:.*/)?{re.escape(QUEST_ABI)}/([^/]+\.so)\.(?:sym|dbg)', name)
                if match:
                    found[match.group(1)] = archive.read(name)
        if found:
            return f'AGP native-debug-symbols.zip ({symbols_zip})', found
    if intermediates and intermediates.is_dir():
        merged = intermediates / 'merged_native_libs' / 'questRelease'
        found = {path.name: path.read_bytes() for path in sorted(merged.glob(f'**/lib/{QUEST_ABI}/*.so'))}
        if found:
            return f'AGP intermediates, unstripped libraries ({merged})', found
    return 'none', {}


def keep(args: argparse.Namespace) -> int:
    out = pathlib.Path(args.out)
    mappings = pathlib.Path(args.mappings)
    errors: list[str] = []
    notes: list[str] = []
    manifest: dict = {
        'label': args.label,
        'commit': args.commit,
        'made': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'libraries': [],
        'mappings': [],
    }

    # The phone bundle and its mapping
    bundle = pathlib.Path(args.bundle)
    with zipfile.ZipFile(bundle) as archive:
        manifest['version_code'] = bundle_version_code(archive)
        abis, problems = bundle_checks(archive)
        errors += problems
        print(f'{bundle.name}: ABIs {", ".join(abis) or "none"}, version code {manifest["version_code"] or "unknown"}')
        proguard_sha = sha256_entry(archive, PROGUARD_MAP) if PROGUARD_MAP in archive.namelist() else None
        for name in sorted(archive.namelist()):
            match = re.fullmatch(rf'{re.escape(SYMBOLS_PREFIX)}([^/]+)/([^/]+\.so)\.sym', name)
            if not match:
                continue
            info = elf_info(archive.read(name)) or {'build_id': None, 'symtab': False}
            manifest['libraries'].append({
                'flavour': 'phone',
                'abi': match.group(1),
                'name': match.group(2),
                'file': f'{bundle.name}!{name}',
                'gnu_build_id': info['build_id'],
                'breakpad_id': breakpad_id(info['build_id']),
                'symtab': info['symtab'],
                'size': archive.getinfo(name).file_size,
            })

    phone = sorted(mappings.glob('phone-*.txt'))
    if not phone:
        errors.append(f'no phone mapping in {mappings} (phone-*.txt)')
    else:
        digests = {path.name: sha256_file(path) for path in phone}
        (out / 'phone').mkdir(parents=True, exist_ok=True)
        if len(set(digests.values())) == 1:
            kept = {phone[0].name: out / 'phone' / 'mapping.txt'}
            print(f'phone mapping: the {len(phone)} phone builds gave the same file, kept once')
        else:
            kept = {path.name: out / 'phone' / f'mapping-{path.stem[len("phone-"):]}.txt' for path in phone}
            print(
                '::warning::the phone builds gave different R8 mappings, each one is kept: '
                + ', '.join(f'{name} {digest[:12]}' for name, digest in digests.items())
            )
        for name, target in kept.items():
            shutil.copyfile(mappings / name, target)
            manifest['mappings'].append({
                'flavour': 'phone',
                'build': name[len('phone-'):-len('.txt')],
                'file': target.relative_to(out).as_posix(),
                'sha256': digests[name],
                **r8_header(target),
            })
        bundle_mapping = digests.get(PHONE_BUNDLE_MAPPING)
        if bundle_mapping is None:
            errors.append(f'no mapping of the bundle build in {mappings} ({PHONE_BUNDLE_MAPPING})')
        elif proguard_sha is not None and bundle_mapping != proguard_sha:
            errors.append(
                f'the mapping of the bundle build ({bundle_mapping[:12]}) is not the proguard.map of the bundle '
                f'({proguard_sha[:12]}): the file kept would not retrace what Google Play shows'
            )
        elif proguard_sha is not None:
            print(f'phone mapping: equal to the proguard.map of {bundle.name} (SHA-256 {bundle_mapping})')

    quest_mapping = mappings / QUEST_MAPPING
    if quest_mapping.is_file():
        target = out / 'quest' / 'mapping.txt'
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(quest_mapping, target)
        manifest['mappings'].append({
            'flavour': 'quest',
            'build': 'quest',
            'file': 'quest/mapping.txt',
            'sha256': sha256_file(target),
            **r8_header(target),
        })
    else:
        errors.append(f'no mapping of the Quest build in {mappings} ({QUEST_MAPPING})')

    # The Quest native symbols, checked against the APK
    apk = pathlib.Path(args.quest_apk)
    in_apk = apk_libraries(apk, QUEST_ABI)
    source, candidates = quest_candidates(
        pathlib.Path(args.quest_symbols) if args.quest_symbols else None,
        pathlib.Path(args.intermediates) if args.intermediates else None,
    )
    manifest['quest_symbols_source'] = source
    print(f'Quest symbols from: {source}')
    if not candidates:
        errors.append('no symbol files of the Quest build (no native-debug-symbols.zip, no merged native libraries)')
    if DART_LIBRARY not in in_apk:
        errors.append(f'{apk.name} holds no lib/{QUEST_ABI}/{DART_LIBRARY}')
    elif candidates and DART_LIBRARY not in candidates:
        errors.append(f'no symbol file of {DART_LIBRARY} for the Quest build ({source})')
    folder = out / 'quest' / QUEST_ABI
    for name, data in sorted(candidates.items()):
        info = elf_info(data) or {'build_id': None, 'symtab': False}
        shipped = in_apk.get(name)
        dart = name == DART_LIBRARY
        if shipped is None:
            notes.append(f'{name}: not in {apk.name}, left out')
            continue
        if not info['build_id'] or info['build_id'] != shipped['build_id']:
            message = (
                f'{name}: build ID {info["build_id"]} of the symbol file, {shipped["build_id"]} in {apk.name}: '
                'a store would not match them'
            )
            if dart:
                errors.append(message)
            else:
                notes.append(message + ', left out')
            continue
        if not info['symtab']:
            if dart:
                errors.append(f'{name}: the symbol file has no symbol table (.symtab)')
            else:
                notes.append(f'{name}: no symbol table in the symbol file (shipped stripped), left out')
            continue
        folder.mkdir(parents=True, exist_ok=True)
        (folder / name).write_bytes(data)
        manifest['libraries'].append({
            'flavour': 'quest',
            'abi': QUEST_ABI,
            'name': name,
            'file': f'quest/{QUEST_ABI}/{name}',
            'gnu_build_id': info['build_id'],
            'breakpad_id': breakpad_id(info['build_id']),
            'symtab': True,
            'size': len(data),
            'sha256': hashlib.sha256(data).hexdigest(),
        })
        print(f'kept quest/{QUEST_ABI}/{name}: build ID {info["build_id"]}, Breakpad {breakpad_id(info["build_id"])}')
    for note in notes:
        print(note)

    out.mkdir(parents=True, exist_ok=True)
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    (out / 'README.txt').write_text(
        README.format(
            label=args.label or 'unknown',
            commit=args.commit or 'unknown',
            version_code=manifest['version_code'] or 'unknown',
        ),
        encoding='utf-8',
    )
    for error in errors:
        print(f'::error::{error}')
    if errors:
        return 1
    print(f'{out}: manifest.json, README.txt, {len(manifest["mappings"])} mappings, '
          f'{sum(1 for x in manifest["libraries"] if x["flavour"] == "quest")} Quest symbol files')
    return 0


# verify


def verify(args: argparse.Namespace) -> int:
    manifest = json.loads(pathlib.Path(args.manifest).read_text(encoding='utf-8'))
    errors = []
    if args.apk:
        apk = pathlib.Path(args.apk)
        in_apk = apk_libraries(apk, QUEST_ABI)
        kept = [x for x in manifest.get('libraries', []) if x.get('flavour') == 'quest']
        if not any(x['name'] == DART_LIBRARY for x in kept):
            errors.append(f'the manifest keeps no Quest {DART_LIBRARY}')
        for library in kept:
            shipped = (in_apk.get(library['name']) or {}).get('build_id')
            if shipped != library['gnu_build_id']:
                errors.append(
                    f'{apk.name}: {library["name"]} has build ID {shipped}, the symbols {library["gnu_build_id"]}'
                )
            else:
                print(f'{apk.name}: {library["name"]} build ID {shipped} as the symbols')
    if args.bundle:
        bundle = pathlib.Path(args.bundle)
        with zipfile.ZipFile(bundle) as archive:
            abis, problems = bundle_checks(archive)
            errors += [f'{bundle.name}: {problem}' for problem in problems]
            code = bundle_version_code(archive)
            if manifest.get('version_code') and code != manifest['version_code']:
                errors.append(f'{bundle.name}: version code {code}, the symbols are of {manifest["version_code"]}')
            if not problems:
                print(f'{bundle.name}: R8 mapping and libapp.so.sym of {", ".join(abis)} present, version code {code}')
    for error in errors:
        print(f'error: {error}')
    return 1 if errors else 0


def build_ids(args: argparse.Namespace) -> int:
    status = 0
    for name in args.files:
        info = elf_info(pathlib.Path(name).read_bytes())
        if not info or not info['build_id']:
            print(f'{name}: no GNU build ID')
            status = 1
        else:
            print(f'{name}: GNU {info["build_id"]} Breakpad {breakpad_id(info["build_id"])} symtab {info["symtab"]}')
    return status


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    commands = parser.add_subparsers(dest='command', required=True)
    keep_parser = commands.add_parser('keep', help='keep the mappings and Quest symbols of a release build')
    keep_parser.add_argument('--out', required=True)
    keep_parser.add_argument('--mappings', required=True)
    keep_parser.add_argument('--bundle', required=True)
    keep_parser.add_argument('--quest-apk', required=True)
    keep_parser.add_argument('--quest-symbols')
    keep_parser.add_argument('--intermediates')
    keep_parser.add_argument('--label', default='')
    keep_parser.add_argument('--commit', default='')
    verify_parser = commands.add_parser('verify', help='check a build against the manifest of its symbols')
    verify_parser.add_argument('--manifest', required=True)
    verify_parser.add_argument('--apk')
    verify_parser.add_argument('--bundle')
    ids_parser = commands.add_parser('build-id', help='print the build IDs of ELF files')
    ids_parser.add_argument('files', nargs='+')
    args = parser.parse_args(argv)
    try:
        return {'keep': keep, 'verify': verify, 'build-id': build_ids}[args.command](args)
    except (OSError, zipfile.BadZipFile) as error:
        print(f'::error::{error}')
        return 1


if __name__ == '__main__':
    sys.exit(main())
