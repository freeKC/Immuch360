#!/usr/bin/env python3
"""Makes the Windows folder and ZIP of Immuch360 Desktop from a `flutter build windows` output, and checks it.

`flutter build windows --release` leaves the executable, the engine, the plugin DLLs and data/ in
build/windows/<arch>/runner/Release. That folder runs on the build machine but not always on another PC: the Visual C++
runtime is not part of Windows (the Flutter documentation asks for msvcp140.dll, vcruntime140.dll and
vcruntime140_1.dll next to the executable), and jni builds dartjni.dll whenever a JDK is found, which needs jvm.dll.
This script copies the output to <out>/<name>/, leaves out dartjni.dll and the debug symbols (kept apart with
--symbols), adds the runtime DLLs from the Visual C++ redistributable folder, writes BUILD-INFO.txt, and then reads
the import table of every DLL and EXE of the folder: each imported DLL must be in the folder, be an API set, or be a
DLL of Windows itself (present in System32 and not a Visual C++ runtime, which a clean Windows does not have). A
debug runtime, an unresolved import or a DLL of another architecture fails the run, so that a ZIP which would not
start on a clean PC is never handed out. With --file-version, the executable must also carry that version in its
version resource: the fork's build number reaches it through flutter build --build-number, and a build made without
it would show the pubspec's numbers in the file properties.

  windows_bundle.py --release DIR --out DIR [--name "Immuch360 Desktop"] [--arch x64] [--crt-dir DIR]
                    [--system-dir DIR] [--zip FILE] [--symbols DIR] [--info KEY=VALUE ...]
                    [--file-version A.B.C.D]
  windows_bundle.py --imports FILE ...      print the imports of PE files as JSON

--crt-dir defaults to the newest Microsoft.VC*.CRT folder of the Visual Studio found by vswhere (Windows only);
--system-dir defaults to %SystemRoot%\\System32. Both can point at copies elsewhere (the tests use fixtures).
Exit codes: 0 good, 1 the folder would not run on a clean Windows, 2 bad arguments or missing inputs.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import struct
import subprocess
import sys
import zipfile

MACHINES = {0x8664: 'x64', 0xAA64: 'arm64', 0x014C: 'x86'}
# The runtime the Flutter documentation asks to ship next to the executable
ALWAYS_SHIPPED = ('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
# Never in the folder: dartjni.dll needs a Java runtime (jvm.dll) and only serves Android; .pdb, .ilk, .exp and .lib
# files are for developers
LEFT_OUT = re.compile(r'(?i)^(dartjni\.dll|.*\.(pdb|ilk|exp|lib))$')
SYMBOLS = re.compile(r'(?i)\.pdb$')
# Visual C++ runtime DLLs: present in System32 wherever Visual Studio or some other program installed them, absent
# from a clean Windows, so they must come from the folder
VC_RUNTIME = re.compile(r'(?i)^(msvcp|vcruntime|concrt|vccorlib|vcomp|vcamp|mfc\w*?)\d{3}.*\.dll$')
DEBUG_RUNTIME = re.compile(r'(?i)^((msvcp|vcruntime|concrt|vccorlib)\d{3}(_\w+?)?d|ucrtbased)\.dll$')
API_SET = re.compile(r'(?i)^(api|ext)-ms-')
# VS_FIXEDFILEINFO of the version resource: its signature, then the structure version 1.0
FIXED_FILE_INFO = struct.pack('<II', 0xFEEF04BD, 0x00010000)


class NotPe(Exception):
    pass


def read_pe(path: pathlib.Path) -> dict:
    """The machine and the imported DLL names (plain and delay loaded) of a PE file, read from its tables."""
    data = path.read_bytes()
    if len(data) < 0x40 or data[:2] != b'MZ':
        raise NotPe(f'{path.name}: not a PE file')
    pe = struct.unpack_from('<I', data, 0x3C)[0]
    if data[pe:pe + 4] != b'PE\0\0':
        raise NotPe(f'{path.name}: no PE signature')
    machine, sections, _, _, _, optional_size, _ = struct.unpack_from('<HHIIIHH', data, pe + 4)
    optional = pe + 24
    magic = struct.unpack_from('<H', data, optional)[0]
    if magic == 0x20B:
        image_base = struct.unpack_from('<Q', data, optional + 24)[0]
        count = struct.unpack_from('<I', data, optional + 108)[0]
        directories = optional + 112
    elif magic == 0x10B:
        image_base = struct.unpack_from('<I', data, optional + 28)[0]
        count = struct.unpack_from('<I', data, optional + 92)[0]
        directories = optional + 96
    else:
        raise NotPe(f'{path.name}: unknown optional header {magic:#x}')

    table = optional + optional_size
    spans = []
    for i in range(sections):
        virtual_size, virtual_address, raw_size, raw_pointer = struct.unpack_from('<IIII', data, table + i * 40 + 8)
        spans.append((virtual_address, max(virtual_size, raw_size), raw_pointer))

    def offset(rva):
        for start, size, raw in spans:
            if start <= rva < start + size:
                return rva - start + raw
        raise NotPe(f'{path.name}: address {rva:#x} outside the sections')

    def name_at(rva):
        start = offset(rva)
        end = data.index(b'\0', start)
        return data[start:end].decode('ascii', 'replace')

    def directory(index):
        if index >= count:
            return 0, 0
        return struct.unpack_from('<II', data, directories + index * 8)

    imports = []
    rva, size = directory(1)
    if rva and size:
        at = offset(rva)
        while True:
            name_rva = struct.unpack_from('<I', data, at + 12)[0]
            if not any(data[at:at + 20]):
                break
            imports.append(name_at(name_rva))
            at += 20

    delay = []
    rva, size = directory(13)
    if rva and size:
        at = offset(rva)
        while True:
            attributes, name_rva = struct.unpack_from('<II', data, at)
            if not name_rva:
                break
            # Old linkers wrote virtual addresses instead of relative ones (attribute bit 0 clear)
            delay.append(name_at(name_rva if attributes & 1 else name_rva - image_base))
            at += 32

    return {'machine': MACHINES.get(machine, hex(machine)), 'imports': imports, 'delay_imports': delay}


def file_version(path: pathlib.Path) -> str | None:
    """The binary file version of the version resource (what the file properties show), or None without one."""
    data = path.read_bytes()
    at = data.find(FIXED_FILE_INFO)
    if at < 0 or len(data) < at + 16:
        return None
    high, low = struct.unpack_from('<II', data, at + 8)
    return f'{high >> 16}.{high & 0xFFFF}.{low >> 16}.{low & 0xFFFF}'


def find_crt_dir(arch: str) -> pathlib.Path | None:
    """The Microsoft.VC*.CRT folder of the newest Visual C++ redistributable of the newest Visual Studio."""
    roots = []
    if os.environ.get('VCToolsRedistDir'):
        roots.append(pathlib.Path(os.environ['VCToolsRedistDir']))
    vswhere = pathlib.Path(os.environ.get('ProgramFiles(x86)', r'C:\Program Files (x86)'),
                           'Microsoft Visual Studio', 'Installer', 'vswhere.exe')
    if vswhere.exists():
        found = subprocess.run([str(vswhere), '-latest', '-products', '*', '-requires',
                                'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath'],
                               capture_output=True, text=True).stdout.strip()
        if found:
            redist = pathlib.Path(found, 'VC', 'Redist', 'MSVC')
            versions = [d for d in redist.glob('*') if re.match(r'^\d+(\.\d+)+$', d.name)]
            roots += sorted(versions, key=lambda d: tuple(int(n) for n in d.name.split('.')), reverse=True)
    for root in roots:
        crt = sorted(root.glob(f'{arch}/Microsoft.VC*.CRT'))
        if crt:
            return crt[-1]
    return None


def pe_files(folder: pathlib.Path):
    return sorted(p for p in folder.rglob('*') if p.is_file() and p.suffix.lower() in ('.dll', '.exe'))


def check(folder: pathlib.Path, arch: str, crt: dict, system: set, copied: list) -> list:
    """Problems of the folder; copies the runtime DLLs it needs from crt ({lower name: path}) on the way."""
    problems = []
    present = {p.name.lower() for p in folder.iterdir() if p.is_file()}
    pending = pe_files(folder)
    seen = set()
    while pending:
        path = pending.pop(0)
        if path in seen:
            continue
        seen.add(path)
        relative = path.relative_to(folder).as_posix()
        try:
            info = read_pe(path)
        except (NotPe, struct.error, ValueError) as error:
            problems.append(f'{relative}: unreadable ({error})')
            continue
        if info['machine'] != arch:
            problems.append(f'{relative}: built for {info["machine"]}, the folder is {arch}')
        for name, how in [(n, '') for n in info['imports']] + [(n, ' (delay loaded)') for n in info['delay_imports']]:
            lower = name.lower()
            if DEBUG_RUNTIME.match(lower):
                problems.append(f'{relative}: imports {name}{how}, a debug runtime that cannot be shipped (debug build?)')
            elif lower in present or API_SET.match(lower):
                continue
            elif lower in crt:
                target = folder / crt[lower].name
                shutil.copy2(crt[lower], target)
                present.add(lower)
                copied.append(crt[lower].name)
                pending.append(target)
            elif lower in system and not VC_RUNTIME.match(lower):
                continue
            else:
                problems.append(f'{relative}: imports {name}{how}, found neither in the folder nor in Windows')
    return problems


def write_zip(folder: pathlib.Path, zip_path: pathlib.Path) -> str:
    zip_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in sorted(p for p in folder.rglob('*') if p.is_file()):
            archive.write(path, f'{folder.name}/{path.relative_to(folder).as_posix()}')
    digest = hashlib.sha256()
    with open(zip_path, 'rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def bundle(args) -> int:
    if not (args.release / 'data').is_dir():
        print(f'{args.release} is not a Flutter Windows build output (no data folder)')
        return 2
    crt_dir = args.crt_dir or find_crt_dir(args.arch)
    if crt_dir is None or not crt_dir.is_dir():
        print('no Visual C++ redistributable folder: give --crt-dir (VC\\Redist\\MSVC\\<version>\\'
              f'{args.arch}\\Microsoft.VC143.CRT of Visual Studio)')
        return 2
    system_dir = args.system_dir or pathlib.Path(os.environ.get('SystemRoot', r'C:\Windows'), 'System32')
    if not system_dir.is_dir():
        print(f'no {system_dir}: give --system-dir, the System32 folder of a Windows the folder is checked against')
        return 2

    folder = args.out / args.name
    if folder.exists():
        shutil.rmtree(folder)
    folder.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(args.release, folder)

    for path in sorted(p for p in folder.rglob('*') if p.is_file() and LEFT_OUT.match(p.name)):
        if args.symbols and SYMBOLS.search(path.name):
            args.symbols.mkdir(parents=True, exist_ok=True)
            shutil.move(str(path), str(args.symbols / path.name))
            print(f'symbols kept apart: {path.name}')
        else:
            path.unlink()
            print(f'left out: {path.relative_to(folder).as_posix()}')

    crt = {p.name.lower(): p for p in crt_dir.glob('*.dll')}
    copied = []
    for name in ALWAYS_SHIPPED:
        if name not in crt:
            print(f'{crt_dir} has no {name}')
            return 2
        shutil.copy2(crt[name], folder / crt[name].name)
        copied.append(crt[name].name)
    system = {name.lower() for name in os.listdir(system_dir)}
    problems = check(folder, args.arch, crt, system, copied)
    if args.file_version:
        for exe in sorted(p for p in folder.iterdir() if p.is_file() and p.suffix.lower() == '.exe'):
            found = file_version(exe)
            if found is None:
                problems.append(f'{exe.name}: no version resource, expected file version {args.file_version}')
            elif found != args.file_version:
                problems.append(f'{exe.name}: file version {found}, expected {args.file_version}')
            else:
                print(f'{exe.name}: file version {found}')

    info = ['Immuch360 Desktop'] + [line.replace('=', ': ', 1) for line in args.info] + [
        '',
        'Start immuch360.exe from this folder and keep the folder whole: the program needs the files next to it.',
        'This build is not signed: Windows SmartScreen may ask for a confirmation at the first start, and Smart App',
        'Control, where it is on, blocks it.',
    ]
    (folder / 'BUILD-INFO.txt').write_text('\r\n'.join(info) + '\r\n', encoding='utf-8')

    files = [p for p in folder.rglob('*') if p.is_file()]
    print(f'runtime copied from {crt_dir}: {", ".join(sorted(set(copied)))}')
    print(f'{len(files)} files, {sum(p.stat().st_size for p in files) / 1e6:.1f} MB in {folder}')
    for line in problems:
        print(f'problem: {line}')
    if problems:
        print('This folder would not start on a clean Windows; no ZIP made')
        return 1
    print(f'every import of the {len(pe_files(folder))} DLL and EXE files resolves in the folder or in Windows')
    if args.zip:
        digest = write_zip(folder, args.zip)
        print(f'zip: {args.zip} ({args.zip.stat().st_size / 1e6:.1f} MB), SHA-256 {digest}')
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--imports', nargs='+', type=pathlib.Path, help='print the imports of these PE files')
    parser.add_argument('--release', type=pathlib.Path, help='the Release folder of flutter build windows')
    parser.add_argument('--out', type=pathlib.Path, help='where the folder <name> is made')
    parser.add_argument('--name', default='Immuch360 Desktop', help='name of the folder, also its name in the ZIP')
    parser.add_argument('--arch', default='x64', choices=('x64', 'arm64'))
    parser.add_argument('--crt-dir', type=pathlib.Path, help='the Microsoft.VC*.CRT folder to take the runtime from')
    parser.add_argument('--system-dir', type=pathlib.Path, help='System32 of the Windows to check against')
    parser.add_argument('--zip', type=pathlib.Path, help='also write this ZIP of the folder')
    parser.add_argument('--symbols', type=pathlib.Path, help='move the .pdb files here instead of dropping them')
    parser.add_argument('--info', action='append', default=[], metavar='KEY=VALUE', help='a line of BUILD-INFO.txt')
    parser.add_argument('--file-version', help='the version each executable must carry, A.B.C.D (3.3.0.20)')
    args = parser.parse_args(argv)

    if args.imports:
        result, failed = {}, False
        for path in args.imports:
            try:
                result[path.name] = read_pe(path)
            except (NotPe, OSError, struct.error, ValueError) as error:
                result[path.name] = {'error': str(error)}
                failed = True
        print(json.dumps(result, indent=2, sort_keys=True))
        return 1 if failed else 0
    if not args.release or not args.out:
        parser.error('--release and --out are needed (or --imports)')
    if args.file_version and not re.match(r'^\d+\.\d+\.\d+\.\d+$', args.file_version):
        parser.error(f'--file-version {args.file_version!r} is not A.B.C.D')
    return bundle(args)


if __name__ == '__main__':
    sys.exit(main())
