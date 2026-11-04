#!/usr/bin/env python3
"""The AV2 decoder of Immuch360 Desktop: the sources, the build, the licences, the checks and the archive of its jobs.

immuch360-av2 (mobile/native/av2, C on the library of dav2d by VideoLAN) decodes AV2 videos for the app and serves the
pictures to its player as a virtual y4m on 127.0.0.1 (plan of the 2nd of November 2026, sections 2 and 3). Its
binaries come from our CI only: the jobs av2-windows, av2-linux and av2-macos of immuch360-desktop.yml build it from
dav2d at the commit of av2.lock.json next to this script, check it, and upload Immuch360-av2-decoder-<id>-<system>.zip,
a name that no release of the app attaches.

  av2_build.py lock --system SYSTEM [--github-output]
      the id of the lock, the commit of dav2d, the tools and the name of the artifact of SYSTEM (windows-x64,
      linux-x64 or macos-universal)
  av2_build.py sources [--dir DIR]
      dav2d at the commit of the lock in DIR (by default mobile/native/av2/subprojects/dav2d, where Meson finds it),
      checked against the commit and the SHA-256 of its licence files in the lock
  av2_build.py build --system SYSTEM --build DIR [--source-commit COMMIT]
      Meson and Ninja with the options of the lock; on Windows with MSVC and its static runtime (Meson finds Visual
      Studio itself, --vsenv), on macOS twice (arm64, then x86_64 by a cross file) and joined by lipo, then signed ad
      hoc; the program in DIR/immuch360-av2[.exe], the tools that built it in DIR/tools.json (the C compiler as Meson
      found it, nasm, Meson, Ninja), and the seconds it took
  av2_build.py licences --source DIR
      the licences of the lock: every component under a permissive licence (ours apart, pinned here: the AGPL 3.0 of
      the program, the MIT licence of immuch360-run), and each text of licenses/av2 equal to the file of the sources it
      comes from and to the SHA-256 of the lock; a GPL entry fails here
  av2_build.py pack --system SYSTEM --source DIR --program FILE --out DIR [--launcher FILE] [--source-commit COMMIT]
      the archive: the program (and on Linux immuch360-run), licenses/, BUILD-INFO.txt (with the tools of tools.json
      next to the program) and SHA256SUMS.txt; sorted names and fixed dates, the same files give the same bytes
  av2_build.py check --system SYSTEM --archive FILE [--fixtures DIR] [--run] [--arch-x86-64]
      the archive: its files and their sums, its licences equal to those of the repository, no library or import
      outside the system's, no string of GPL code in the program; with --run, the program of the archive itself: its
      --version against the lock, its --help against the fixture, and av2_serve_check.py on the fixtures (the MD5 of
      the reference decoder avmdec v1.0.0, the requests of a player, the token, 127.0.0.1, the end of the input);
      --arch-x86-64 runs the x86_64 slice of the macOS program under Rosetta
  av2_build.py help --output FILE [--fixture FILE]
      the output of immuch360-av2 --help compared with mobile/test/fixtures/av2/immuch360_av2_help.txt, the text the
      app's launcher is frozen by
  av2_build.py program --system windows-x64 --archive FILE --out DIR [--github-output]
      the program of the archive, written in DIR for the release workflow to sign (lot AD11: av2-decoder-1)
  av2_build.py signed --system windows-x64 --archive FILE --program FILE --out DIR [--github-output]
      the archive again with the program signed: FILE must be the program of the archive with an Authenticode
      signature added and nothing else changed (the two equal once the checksum of the PE header, its certificate
      directory and the certificate table at its end are taken out); BUILD-INFO.txt says it is signed, SHA256SUMS.txt
      gives the new sums, names sorted and dates fixed as pack writes them, and SHA256SUMS next to it in DIR names
      the archive with its SHA-256

nasm is pinned on every system, at the version of the lock: on Windows the build of nasm.us, on Linux and macOS its
source of nasm.us built on the runner, each checked against the SHA-256 of the lock. BUILD-INFO.txt gives its version
with the compiler's, and a program that another nasm assembled is neither packed nor accepted by check.

Only the Python standard library is used, and it writes no cache next to the scripts (a __pycache__ folder is not
for the repository). Exit codes: 0 good, 1 a check failed, 2 bad arguments or missing inputs.
"""
from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
import pathlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zipfile

# windows_bundle and av2_serve_check are imported later, from here: their caches would land next to them
sys.dont_write_bytecode = True

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]
LOCK = HERE / 'av2.lock.json'
LICENCES = ROOT / 'licenses' / 'av2'
NATIVE = ROOT / 'mobile' / 'native' / 'av2'
FIXTURES = ROOT / 'mobile' / 'test' / 'fixtures' / 'av2'
HELP_FIXTURE = FIXTURES / 'immuch360_av2_help.txt'
SYSTEMS = ('windows-x64', 'linux-x64', 'macos-universal')
ARTIFACT_PREFIX = 'Immuch360-av2-decoder-'
PROGRAM = {'windows-x64': 'immuch360-av2.exe', 'linux-x64': 'immuch360-av2', 'macos-universal': 'immuch360-av2'}
REPOSITORY = 'https://github.com/freeKC/Immuch360'
# What a program of the archive may need from the system, and nothing else: the C library of any Linux of the packages
# (glibc 2.35 of Ubuntu 22.04), libSystem on macOS, and on Windows the DLLs of Windows itself (the C runtime is static)
LINUX_SYSTEM = {'libc.so.6', 'libm.so.6', 'libpthread.so.0', 'libdl.so.2', 'librt.so.1', 'ld-linux-x86-64.so.2'}
MACOS_SYSTEM = {'/usr/lib/libSystem.B.dylib'}
WINDOWS_SYSTEM = {'kernel32.dll', 'ws2_32.dll', 'shell32.dll', 'advapi32.dll', 'ntdll.dll', 'user32.dll',
                  'bcrypt.dll'}
# Strings of GPL code a program of the archive must not hold: the licence's own words, and the banners of the GPL
# video libraries a decoder could pull in by mistake (x264, x265, FFmpeg built with them, libvpx's GPL parts none)
GPL_STRINGS = (b'GNU General Public License', b'General Public License', b'GPL-2.0', b'GPL-3.0', b'GPLv2', b'GPLv3',
               b'x264 - core', b'x265 (build', b'--enable-gpl', b'libpostproc', b'GNU Lesser General Public')
# The licence words of the lock that are a GPL: such an entry fails whatever list it is in
GPL_LICENCE = re.compile(r'(?i)\b(A|L)?GPL\b|GPL-|General Public')
# Our own code and its licence, fixed here and not only in the lock: the LICENSE of this repository for the program,
# the SPDX line of .github/desktop/ai/immuch360_run.c for the launcher. No other component may say it is ours
OWN_LICENCES = {'immuch360-av2': 'AGPL-3.0-only', 'immuch360-run': 'MIT'}


class Failure(Exception):
    pass


def load_lock(path: pathlib.Path = LOCK) -> dict:
    lock = json.loads(path.read_text(encoding='utf-8'))
    for key in ('id', 'dav2d', 'components', 'permissive', 'own', 'tools', 'meson'):
        if key not in lock:
            raise Failure(f'{path.name}: no {key}')
    commit = lock['dav2d'].get('commit', '')
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise Failure(f'{path.name}: the commit of dav2d is not a full commit')
    if not re.fullmatch(r'[0-9a-f]{7}-\d+', lock['id']) or not commit.startswith(lock['id'].split('-')[0]):
        raise Failure(f'{path.name}: the id {lock["id"]!r} is not <short commit of dav2d>-<build>')
    for name, digest in lock['dav2d'].get('files', {}).items():
        if not re.fullmatch(r'[0-9a-f]{64}', digest):
            raise Failure(f'{path.name}: no SHA-256 for {name}')
    nasm = lock['tools'].get('nasm', {})
    for key, what in (('windows-x64', 'the nasm of Windows'),
                      ('source', 'the source of nasm, built on Linux and macOS,')):
        entry = nasm.get(key, {})
        url, digest = entry.get('url', ''), entry.get('sha256', '')
        if not re.fullmatch(r'[0-9a-f]{64}', digest) or not url.startswith('https://'):
            raise Failure(f'{path.name}: {what} has no https address or SHA-256')
    if not re.fullmatch(r'\d+\.\d+(\.\d+)*', nasm.get('version', '')):
        raise Failure(f'{path.name}: no version of nasm')
    return lock


def nasm_problem(text: str, lock: dict) -> str | None:
    """What is wrong with the nasm a build names (the first line of nasm -v): None when it is the version of the lock"""
    version = lock['tools']['nasm']['version']
    if re.match(rf'NASM version {re.escape(version)}(\s|$)', text):
        return None
    return f'nasm {text}, not the {version} of the lock'


def artifact_name(lock: dict, system: str) -> str:
    return f'{ARTIFACT_PREFIX}{lock["id"]}-{system}.zip'


def run(command: list, cwd: pathlib.Path | None = None, env: dict | None = None):
    print('$ ' + ' '.join(str(part) for part in command), flush=True)
    subprocess.run([str(part) for part in command], cwd=cwd, check=True, env=env)


def output(command: list, cwd: pathlib.Path | None = None) -> str:
    return subprocess.run([str(part) for part in command], cwd=cwd, check=True, capture_output=True,
                          text=True).stdout.strip()


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def text_bytes(data: bytes) -> bytes:
    """A text file as compared: LF line ends (a checkout on Windows may give CRLF)"""
    return data.replace(b'\r\n', b'\n')


# --- lock ------------------------------------------------------------------------------------------------------------

def command_lock(args) -> int:
    lock = load_lock(args.lock)
    # The build of nasm.us on Windows, its source elsewhere
    nasm = lock['tools']['nasm']['windows-x64' if args.system == 'windows-x64' else 'source']
    values = {
        'id': lock['id'],
        'artifact': artifact_name(lock, args.system),
        'commit': lock['dav2d']['commit'],
        'meson': lock['tools']['meson'],
        'ninja': lock['tools']['ninja'],
        'nasm_version': lock['tools']['nasm']['version'],
        'nasm_url': nasm['url'],
        'nasm_sha256': nasm['sha256'],
        'program': PROGRAM[args.system],
    }
    for key, value in values.items():
        print(f'{key}={value}')
    if args.github_output:
        with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as stream:
            for key, value in values.items():
                stream.write(f'{key}={value}\n')
    return 0


# --- sources ---------------------------------------------------------------------------------------------------------

def source_file(source: pathlib.Path, name: str, lines: list | None = None) -> bytes:
    data = text_bytes((source / name).read_bytes())
    if lines:
        data = b''.join(data.splitlines(keepends=True)[lines[0] - 1:lines[1]])
    return data


def command_sources(args) -> int:
    lock = load_lock(args.lock)
    folder = args.dir
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True)
    commit = lock['dav2d']['commit']
    run(['git', 'init', '-q', folder])
    # No line end conversion: the sums of the lock are those of the files as dav2d keeps them
    run(['git', '-C', folder, 'config', 'core.autocrlf', 'false'])
    run(['git', '-C', folder, 'fetch', '-q', '--depth', '1', lock['dav2d']['repository'], commit])
    run(['git', '-C', folder, 'checkout', '-q', '--detach', 'FETCH_HEAD'])
    found = output(['git', '-C', folder, 'rev-parse', 'HEAD'])
    if found != commit:
        raise Failure(f'dav2d: {found} checked out, the lock says {commit}')
    for name, digest in lock['dav2d']['files'].items():
        got = sha256((folder / name).read_bytes())
        if got != digest:
            raise Failure(f'dav2d {name}: SHA-256 {got}, the lock says {digest}')
    print(f'dav2d {commit} in {folder}, {len(lock["dav2d"]["files"])} files as the lock says')
    return 0


# --- build -----------------------------------------------------------------------------------------------------------

def meson_files(build: pathlib.Path, lock: dict) -> tuple:
    """The native file of arm64 and the cross file of x86_64 for macOS, with the minimum version of the app"""
    minimum = lock['tools']['macosMinimum']
    build.mkdir(parents=True, exist_ok=True)
    native = build / 'macos-arm64.ini'
    native.write_text('\n'.join([
        '[built-in options]',
        f"c_args = ['-arch', 'arm64', '-mmacosx-version-min={minimum}']",
        f"c_link_args = ['-arch', 'arm64', '-mmacosx-version-min={minimum}']",
        '',
    ]), encoding='utf-8')
    cross = build / 'macos-x86_64.ini'
    cross.write_text('\n'.join([
        '[binaries]',
        "c = ['clang', '-arch', 'x86_64']",
        "ar = 'ar'",
        "strip = 'strip'",
        "nasm = 'nasm'",
        '',
        '[built-in options]',
        f"c_args = ['-mmacosx-version-min={minimum}']",
        f"c_link_args = ['-arch', 'x86_64', '-mmacosx-version-min={minimum}']",
        '',
        '[host_machine]',
        "system = 'darwin'",
        "cpu_family = 'x86_64'",
        "cpu = 'x86_64'",
        "endian = 'little'",
        '',
    ]), encoding='utf-8')
    return native, cross


def tool_versions(build: pathlib.Path) -> dict:
    """The C compiler Meson found for the build in build, nasm, Meson and Ninja, for BUILD-INFO.txt"""
    compilers = json.loads(output(['meson', 'introspect', '--compilers', build]))
    c = compilers.get('host', {}).get('c', {})
    nasm = shutil.which('nasm')
    if not c or not nasm:
        raise Failure(f'the build in {build} names no C compiler, or no nasm on the PATH')
    full = (c.get('full_version') or '').splitlines()
    return {
        'compiler': f'{c.get("id")} {c.get("version")}' + (f' ({full[0]})' if full else ''),
        'nasm': output([nasm, '-v']).splitlines()[0],
        'meson': output(['meson', '--version']),
        'ninja': output(['ninja', '--version']),
    }


def command_build(args) -> int:
    lock = load_lock(args.lock)
    commit = args.source_commit or os.environ.get('GITHUB_SHA') or 'unknown'
    options = [*lock['meson']['common'], *lock['meson'][args.system], f'-Dsource_commit={commit}',
               f'-Ddav2d_commit={lock["dav2d"]["commit"]}']
    started = time.monotonic()
    build = args.build
    if args.system == 'macos-universal':
        native, cross = meson_files(build, lock)
        slices = []
        for arch, extra in (('arm64', ['--native-file', native]), ('x86_64', ['--cross-file', cross])):
            folder = build / arch
            if folder.exists():
                shutil.rmtree(folder)
            run(['meson', 'setup', folder, NATIVE, *options, *extra])
            run(['meson', 'compile', '-C', folder])
            slices.append(folder / 'immuch360-av2')
        program = build / 'immuch360-av2'
        run(['lipo', '-create', '-output', program, *slices])
        run(['lipo', '-info', program])
        # The linker signs arm64 ad hoc, lipo keeps it; one signature over the universal file, as the system asks
        run(['codesign', '--force', '--sign', '-', program])
        run(['codesign', '--verify', '--verbose', program])
    else:
        setup = ['meson', 'setup', build, NATIVE, *options]
        if args.system == 'windows-x64':
            setup.insert(2, '--vsenv')
        run(setup)
        run(['meson', 'compile', '-C', build])
        program = build / PROGRAM[args.system]
        if args.system == 'linux-x64':
            run(['strip', '--strip-unneeded', program])
    seconds = time.monotonic() - started
    tools = tool_versions(build / 'arm64' if args.system == 'macos-universal' else build)
    (build / 'tools.json').write_text(json.dumps(tools, indent=1) + '\n', encoding='utf-8')
    print(f'{program}: {program.stat().st_size} bytes, built in {seconds:.0f} s by {tools["compiler"]}, '
          f'{tools["nasm"]}')
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as stream:
            stream.write(f'program={program}\nseconds={seconds:.0f}\n')
    return 0


# --- licences --------------------------------------------------------------------------------------------------------

def licence_problems(lock: dict, source: pathlib.Path | None, licences: pathlib.Path = LICENCES,
                     system: str | None = None) -> list:
    """What is wrong with the licences of the lock: a licence that is not permissive (ours apart), a text of
    licenses/av2 that differs from the sources or from the SHA-256 of the lock"""
    problems = []
    permissive = set(lock['permissive'])
    for licence in permissive:
        if GPL_LICENCE.search(licence):
            problems.append(f'the permissive list of the lock holds {licence}')
    for component in lock['components']:
        name, licence = component['name'], component['licence']
        if 'own' in component:
            if name not in OWN_LICENCES:
                problems.append(f'{name}: marked as our own code, which only {" and ".join(OWN_LICENCES)} are')
            elif licence != OWN_LICENCES[name] or lock['own'].get(name) != licence:
                problems.append(f'{name}: {licence}, not {OWN_LICENCES[name]}, the licence of our own code')
            continue
        # A licence expression: every part of an AND must be permissive, an OR needs one permissive choice
        choices = [[part.strip() for part in re.split(r'\s+AND\s+', choice)]
                   for choice in re.split(r'\s+OR\s+', licence.strip('() '))]
        if not any(all(part in permissive and not GPL_LICENCE.search(part) for part in choice) for choice in choices):
            problems.append(f'{name}: {licence} is not a permissive licence of the lock (a GPL is never shipped)')
        text = licences / component['text']
        if not text.is_file():
            problems.append(f'{name}: no {text.relative_to(ROOT) if ROOT in text.parents else text}')
            continue
        if source is not None:
            theirs = source_file(source, component['source'], component.get('lines'))
            if text_bytes(text.read_bytes()) != theirs:
                problems.append(f'licenses/av2/{component["text"]} differs from {component["source"]} of the sources '
                                'built: copy it again')
            digest = lock['dav2d']['files'].get(component['source'])
            if digest and not component.get('lines') and sha256(text_bytes(text.read_bytes())) != digest:
                problems.append(f'licenses/av2/{component["text"]}: not the SHA-256 the lock gives '
                                f'{component["source"]}')
    return problems


def command_licences(args) -> int:
    lock = load_lock(args.lock)
    problems = licence_problems(lock, args.source, args.licences)
    for problem in problems:
        print(f'::error::{problem}')
    if problems:
        return 1
    names = ', '.join(f'{c["name"]} ({c["licence"]})' for c in lock['components'])
    print(f'licences: {names}; the texts are those of the sources')
    return 0


# --- pack ------------------------------------------------------------------------------------------------------------

def archive_licences(lock: dict, system: str, commit: str, licences: pathlib.Path = LICENCES) -> dict:
    files = {}
    for component in lock['components']:
        if system not in component.get('systems', SYSTEMS):
            continue
        if component.get('own') == 'LICENSE':
            files[f'licenses/{component["text"]}'] = text_bytes((ROOT / 'LICENSE').read_bytes())
        else:
            files[f'licenses/{component["text"]}'] = text_bytes((licences / component['text']).read_bytes())
    files['licenses/immuch360-av2-SOURCE.txt'] = '\n'.join([
        'immuch360-av2 is free software: you can redistribute it and/or modify it under the terms of the GNU Affero',
        'General Public License version 3 (immuch360-av2-AGPL-3.0.txt). Its source, at the commit this program was',
        'built from:',
        f'{REPOSITORY}/tree/{commit}/mobile/native/av2',
        f'and the build and checks of this archive: {REPOSITORY}/tree/{commit}/.github/desktop/av2',
        '',
    ]).encode()
    files['licenses/README.md'] = text_bytes((licences / 'README.md').read_bytes())
    return files


def build_info(lock: dict, system: str, commit: str, tools: dict) -> bytes:
    run_url = ''
    if os.environ.get('GITHUB_RUN_ID'):
        run_url = (f'{os.environ.get("GITHUB_SERVER_URL", "https://github.com")}/{os.environ.get("GITHUB_REPOSITORY")}'
                   f'/actions/runs/{os.environ["GITHUB_RUN_ID"]}')
    return '\n'.join([
        f'immuch360-av2, the AV2 decoder of Immuch360 Desktop, {system}, lock {lock["id"]}',
        f'immuch360-av2 {REPOSITORY}/tree/{commit}/mobile/native/av2 (protocol of serve 1)',
        f'dav2d {lock["dav2d"]["repository"]} {lock["dav2d"]["commit"]} ({lock["dav2d"]["describe"]}), static library',
        f'C compiler: {tools["compiler"]}',
        f'nasm: {tools["nasm"]}',
        f'Meson {tools["meson"]}, Ninja {tools["ninja"]}, options: ' +
        ' '.join([*lock['meson']['common'], *lock['meson'][system]]),
        *([f'Built by {run_url}'] if run_url else []),
        'Licences: licenses/ (dav2d BSD-2-Clause, x86inc.asm ISC, Alliance for Open Media Patent License 1.0, '
        'immuch360-av2 AGPL-3.0' + (', immuch360-run MIT' if system == 'linux-x64' else '') + ')',
        '',
    ]).encode()


def write_archive(target: pathlib.Path, files: dict, programs: set):
    target.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as bundle:
        for name in sorted(files):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = (0o100755 if name in programs else 0o100644) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            bundle.writestr(info, files[name], compresslevel=9)


def sums_text(files: dict) -> bytes:
    return ''.join(f'{sha256(files[name])}  {name}\n' for name in sorted(files) if name != 'SHA256SUMS.txt').encode()


def command_pack(args) -> int:
    lock = load_lock(args.lock)
    problems = licence_problems(lock, args.source, args.licences, args.system)
    commit = args.source_commit or os.environ.get('GITHUB_SHA') or 'unknown'
    program_name = PROGRAM[args.system]
    tools_file = args.program.parent / 'tools.json'
    if not tools_file.is_file():
        raise Failure(f'no tools.json next to the program in {args.program.parent}: av2_build.py build writes it')
    tools = json.loads(tools_file.read_text(encoding='utf-8'))
    problem = nasm_problem(tools.get('nasm', ''), lock)
    if problem:
        raise Failure(f'{tools_file}: {problem}')
    files = {program_name: args.program.read_bytes()}
    programs = {program_name}
    if args.system == 'linux-x64':
        if args.launcher is None:
            raise Failure('the Linux archive needs --launcher (immuch360-run)')
        files['immuch360-run'] = args.launcher.read_bytes()
        programs.add('immuch360-run')
    files.update(archive_licences(lock, args.system, commit, args.licences))
    files['BUILD-INFO.txt'] = build_info(lock, args.system, commit, tools)
    files['SHA256SUMS.txt'] = sums_text(files)
    problems += static_problems(args.system, files, programs)
    if problems:
        for problem in problems:
            print(f'::error::{problem}')
        return 1
    target = args.out / artifact_name(lock, args.system)
    write_archive(target, files, programs)
    for name in sorted(files):
        print(f'{len(files[name]):>10}  {sha256(files[name])}  {name}' + ('  (program)' if name in programs else ''))
    digest = sha256(target.read_bytes())
    print(f'{target.name}: {target.stat().st_size} bytes, SHA-256 {digest}')
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as stream:
            stream.write(f'archive={target}\nsha256={digest}\nsize={target.stat().st_size}\n')
    return 0


# --- the programs: libraries, imports, strings ------------------------------------------------------------------------

def elf_needed(data: bytes) -> list:
    """The DT_NEEDED names of a 64 bit little endian ELF file"""
    if data[:4] != b'\x7fELF' or data[4] != 2 or data[5] != 1:
        raise Failure('not a 64 bit little endian ELF file')
    shoff, = struct.unpack_from('<Q', data, 0x28)
    shentsize, shnum = struct.unpack_from('<HH', data, 0x3A)
    sections = [struct.unpack_from('<IIQQQQIIQQ', data, shoff + index * shentsize) for index in range(shnum)]
    needed = []
    for _, kind, _, _, offset, size, link, _, _, entsize in sections:
        if kind != 6:  # SHT_DYNAMIC
            continue
        strings = sections[link]
        for at in range(offset, offset + size, entsize or 16):
            tag, value = struct.unpack_from('<qQ', data, at)
            if tag == 0:
                break
            if tag == 1:  # DT_NEEDED
                start = strings[4] + value
                needed.append(data[start:data.index(b'\0', start)].decode())
    return needed


MACHO_CPUS = {0x01000007: 'x86_64', 0x0100000C: 'arm64'}
# LC_LOAD_DYLIB, LC_LAZY_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB
MACHO_DYLIB_COMMANDS = {0xC, 0x20, 0x80000018, 0x8000001F, 0x80000023}


def macho_dylibs(data: bytes) -> dict:
    """{architecture: [dylibs]} of a thin or universal 64 bit Mach-O file"""
    slices = []
    magic, = struct.unpack_from('>I', data, 0)
    if magic == 0xCAFEBABE:
        count, = struct.unpack_from('>I', data, 4)
        for index in range(count):
            cpu, _, offset, size, _ = struct.unpack_from('>iiIII', data, 8 + index * 20)
            slices.append((cpu & 0xFFFFFFFF, data[offset:offset + size]))
    else:
        slices.append((None, data))
    found = {}
    for cpu, thin in slices:
        magic, cputype, _, _, ncmds, _, _, _ = struct.unpack_from('<IiiIIIII', thin, 0)
        if magic != 0xFEEDFACF:
            raise Failure('not a 64 bit Mach-O file')
        arch = MACHO_CPUS.get(cputype & 0xFFFFFFFF, hex(cputype & 0xFFFFFFFF))
        at, dylibs = 32, []
        for _ in range(ncmds):
            command, size = struct.unpack_from('<II', thin, at)
            if command in MACHO_DYLIB_COMMANDS:
                name_offset, = struct.unpack_from('<I', thin, at + 8)
                start = at + name_offset
                dylibs.append(thin[start:thin.index(b'\0', start)].decode())
            at += size
        found[arch] = dylibs
    return found


def pe_imports(data: bytes) -> tuple:
    sys.path.insert(0, str(ROOT / '.github' / 'desktop'))
    import windows_bundle  # noqa: E402 (the PE reader of the Windows ZIP of the app)

    with tempfile.TemporaryDirectory(prefix='av2-') as temporary:
        path = pathlib.Path(temporary) / 'program.exe'
        path.write_bytes(data)
        info = windows_bundle.read_pe(path)
    return info['machine'], info['imports'] + info['delay_imports']


def static_problems(system: str, files: dict, programs: set) -> list:
    """The libraries and imports of the programs, and the strings of GPL code in them"""
    problems = []
    for name in sorted(programs):
        data = files[name]
        for marker in GPL_STRINGS:
            if marker in data:
                problems.append(f'{name} holds "{marker.decode()}": GPL code in the program')
        try:
            if system == 'linux-x64':
                for needed in elf_needed(data):
                    if needed not in LINUX_SYSTEM:
                        problems.append(f'{name} needs {needed}, not a library of the system')
            elif system == 'macos-universal':
                dylibs = macho_dylibs(data)
                if sorted(dylibs) != ['arm64', 'x86_64']:
                    problems.append(f'{name} holds {sorted(dylibs)}, not arm64 and x86_64')
                for arch, names in dylibs.items():
                    for dylib in names:
                        if dylib not in MACOS_SYSTEM:
                            problems.append(f'{name} ({arch}) loads {dylib}, not a library of the system')
            else:
                machine, imports = pe_imports(data)
                if machine != 'x64':
                    problems.append(f'{name} is built for {machine}, not x64')
                for dll in imports:
                    lower = dll.lower()
                    if not (lower in WINDOWS_SYSTEM or re.match(r'^(api|ext)-ms-win-(core|eventing|security)-', lower)):
                        problems.append(f'{name} imports {dll}: only DLLs of Windows itself (the C runtime is static)')
        except (Failure, struct.error, ValueError, IndexError) as error:
            problems.append(f'{name}: unreadable ({error})')
    return problems


# --- the signed program of Windows ---------------------------------------------------------------------------------

# What BUILD-INFO.txt of a signed archive says (signed by the sign-windows job of immuch360-desktop-release.yml)
SIGNED_LINE = ('Signed: immuch360-av2.exe by APROGSYS with Azure Artifact Signing (Authenticode, SHA-256, RFC 3161 '
               'timestamp of Microsoft)')


def pe_without_signature(data: bytes) -> bytes:
    """[data], a PE file, without what an Authenticode signature changes: the checksum of its optional header and its
    certificate directory set to 0, and the file cut where its certificate table starts"""
    if len(data) < 0x40 or data[:2] != b'MZ':
        raise Failure('not a PE file')
    pe, = struct.unpack_from('<I', data, 0x3C)
    if data[pe:pe + 4] != b'PE\0\0':
        raise Failure('no PE signature')
    optional = pe + 24
    magic, = struct.unpack_from('<H', data, optional)
    if magic not in (0x20B, 0x10B):
        raise Failure(f'unknown optional header {magic:#x}')
    directories = optional + (112 if magic == 0x20B else 96)
    count, = struct.unpack_from('<I', data, directories - 4)
    out = bytearray(data)
    struct.pack_into('<I', out, optional + 64, 0)
    if count > 4:
        table, size = struct.unpack_from('<II', data, directories + 4 * 8)
        struct.pack_into('<II', out, directories + 4 * 8, 0, 0)
        if table and size:
            if table + size > len(data):
                raise Failure('the certificate table goes beyond the end of the file')
            out = out[:table]
    return bytes(out)


def only_signature_added(unsigned: bytes, signed: bytes) -> bool:
    """Whether [signed] is [unsigned] with a signature added: the same bytes once both are without their signature,
    but for the zeros that align the certificate table on 8 bytes"""
    bare, bare_signed = pe_without_signature(unsigned), pe_without_signature(signed)
    return bare_signed[:len(bare)] == bare and not bare_signed[len(bare):].strip(b'\0') \
        and len(bare_signed) - len(bare) < 8


def windows_archive(args, lock: dict) -> dict:
    if args.system != 'windows-x64':
        raise Failure('only the Windows program is signed')
    if args.archive.name != artifact_name(lock, args.system):
        raise Failure(f'{args.archive.name}: not {artifact_name(lock, args.system)}')
    with zipfile.ZipFile(args.archive) as bundle:
        files = {info.filename: bundle.read(info) for info in bundle.infolist() if not info.is_dir()}
    if PROGRAM[args.system] not in files:
        raise Failure(f'no {PROGRAM[args.system]} in {args.archive.name}')
    return files


def command_program(args) -> int:
    lock = load_lock(args.lock)
    files = windows_archive(args, lock)
    name = PROGRAM[args.system]
    args.out.mkdir(parents=True, exist_ok=True)
    target = args.out / name
    target.write_bytes(files[name])
    print(f'{target}: {len(files[name])} bytes, SHA-256 {sha256(files[name])}, from {args.archive.name}')
    if args.github_output and os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as stream:
            stream.write(f'program={target}\n')
    return 0


def command_signed(args) -> int:
    lock = load_lock(args.lock)
    files = windows_archive(args, lock)
    name = PROGRAM[args.system]
    unsigned, signed = files[name], args.program.read_bytes()
    if signed == unsigned:
        raise Failure(f'{args.program.name} is the program of the archive as it is: not signed')
    if not only_signature_added(unsigned, signed):
        raise Failure(f'{args.program.name} is not the program of {args.archive.name} with a signature added')
    info = files.get('BUILD-INFO.txt', b'').decode('utf-8')
    if SIGNED_LINE in info:
        raise Failure(f'{args.archive.name} is signed already')
    files[name] = signed
    files['BUILD-INFO.txt'] = (info.rstrip('\n') + '\n' + SIGNED_LINE + '\n').encode('utf-8')
    files['SHA256SUMS.txt'] = sums_text(files)
    problems = static_problems(args.system, {name: signed}, {name})
    if problems:
        for problem in problems:
            print(f'::error::{problem}')
        return 1
    target = args.out / args.archive.name
    write_archive(target, files, {name})
    for entry in sorted(files):
        print(f'{len(files[entry]):>10}  {sha256(files[entry])}  {entry}' + ('  (program)' if entry == name else ''))
    digest = sha256(target.read_bytes())
    (args.out / 'SHA256SUMS').write_text(f'{digest}  {target.name}\n', encoding='utf-8', newline='\n')
    print(f'{target.name}: {target.stat().st_size} bytes, SHA-256 {digest}, {name} signed '
          f'({len(signed) - len(unsigned)} bytes of signature)')
    if args.github_output and os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as stream:
            stream.write(f'archive={target}\nsha256={digest}\nsize={target.stat().st_size}\nname={target.name}\n')
    return 0


# --- check -----------------------------------------------------------------------------------------------------------

def normalized_help(text: str) -> list:
    lines = text.replace('\r\n', '\n').split('\n')
    while lines and not lines[-1].strip():
        lines.pop()
    return lines


def help_problems(text: str, fixture: pathlib.Path) -> list:
    built, frozen = normalized_help(text), normalized_help(fixture.read_text(encoding='utf-8'))
    if built == frozen:
        return []
    diff = ''.join(line + '\n' for line in difflib.unified_diff(frozen, built, 'fixture', 'built', lineterm=''))
    return [f'immuch360-av2 --help differs from {fixture.name}, the text the app is frozen by:\n{diff}']


def version_problems(text: str, lock: dict) -> list:
    lines = text.replace('\r\n', '\n').strip().split('\n')
    problems = []
    if not lines or not lines[0].startswith('immuch360-av2 protocol 1, source '):
        problems.append(f'--version starts with {lines[0] if lines else ""!r}, not "immuch360-av2 protocol 1"')
    if len(lines) < 2 or not lines[1].startswith(f'dav2d {lock["dav2d"]["commit"]} '):
        problems.append(f'--version says {lines[1] if len(lines) > 1 else ""!r}, the lock says dav2d '
                        f'{lock["dav2d"]["commit"]}')
    if len(lines) < 3 or not lines[2].startswith('simd '):
        problems.append('--version has no simd line')
    return problems


def command_check(args) -> int:
    lock = load_lock(args.lock)
    problems = []
    with zipfile.ZipFile(args.archive) as bundle:
        files = {info.filename: bundle.read(info) for info in bundle.infolist() if not info.is_dir()}
    if args.archive.name != artifact_name(lock, args.system):
        problems.append(f'{args.archive.name}: not {artifact_name(lock, args.system)}')
    program_name = PROGRAM[args.system]
    programs = {program_name} | ({'immuch360-run'} if args.system == 'linux-x64' else set())
    for name in sorted(programs):
        if name not in files:
            problems.append(f'no {name} in the archive')
    sums = files.get('SHA256SUMS.txt', b'')
    if sums != sums_text(files):
        problems.append('SHA256SUMS.txt does not give the sums of the files of the archive')
    if 'BUILD-INFO.txt' not in files or lock['dav2d']['commit'].encode() not in files.get('BUILD-INFO.txt', b''):
        problems.append('BUILD-INFO.txt is missing or does not name the commit of dav2d')
    info_lines = files.get('BUILD-INFO.txt', b'').decode('utf-8', 'replace').splitlines()
    nasm_lines = [line[len('nasm: '):] for line in info_lines if line.startswith('nasm: ')]
    nasm_wrong = nasm_problem(nasm_lines[0], lock) if nasm_lines else None
    if not any(line.startswith('C compiler: ') for line in info_lines) or not nasm_lines:
        problems.append('BUILD-INFO.txt does not name the C compiler and the nasm of the build')
    elif nasm_wrong:
        problems.append(f'BUILD-INFO.txt: {nasm_wrong}')
    commit_match = re.search(rb'/tree/([0-9a-f]{40}|unknown)/mobile/native/av2', files.get('BUILD-INFO.txt', b''))
    commit = commit_match.group(1).decode() if commit_match else 'unknown'
    expected = archive_licences(lock, args.system, commit)
    for name, data in sorted(expected.items()):
        if text_bytes(files.get(name, b'')) != data:
            problems.append(f'{name} is missing from the archive or differs from the repository')
    for name in sorted(files):
        if name.startswith('licenses/') and name not in expected:
            problems.append(f'{name}: a licence file the lock does not name')
    extra = set(files) - programs - set(expected) - {'BUILD-INFO.txt', 'SHA256SUMS.txt'}
    for name in sorted(extra):
        problems.append(f'{name}: a file the archive should not hold')
    problems += licence_problems(lock, None, args.licences)
    present = {name: data for name, data in files.items() if name in programs}
    problems += static_problems(args.system, present, set(present))
    if not problems:
        print(f'{args.archive.name}: {len(files)} files, sums, licences, libraries and strings as they should be')

    if args.run and not problems:
        with tempfile.TemporaryDirectory(prefix='av2-check-') as temporary:
            folder = pathlib.Path(temporary)
            for name, data in files.items():
                target = folder / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
                if name in programs:
                    target.chmod(0o755)
            program = folder / program_name
            runs = [('', [str(program)])]
            if args.arch_x86_64:
                runs.append((' (x86_64 under Rosetta)', ['arch', '-x86_64', str(program)]))
            for label, command in runs:
                version = subprocess.run([*command, '--version'], capture_output=True, text=True, timeout=60)
                print(f'--version{label}:\n{version.stdout.strip()}')
                problems += [problem + label for problem in version_problems(version.stdout, lock)]
                shown = subprocess.run([*command, '--help'], capture_output=True, text=True, timeout=60)
                problems += [problem + label for problem in help_problems(shown.stdout, args.help_fixture)]
                sys.path.insert(0, str(HERE))
                import av2_serve_check  # noqa: E402

                launcher = folder / ('immuch360-av2-x86_64' if label else program_name)
                if label:
                    # The x86_64 slice alone, so that the checks start it as they start any program
                    subprocess.run(['lipo', str(program), '-thin', 'x86_64', '-output', str(launcher)], check=True)
                    launcher.chmod(0o755)
                code = av2_serve_check.main(['check', '--program', str(launcher), '--fixtures', str(args.fixtures),
                                             '--threads', str(args.threads)])
                if code != 0:
                    problems.append(f'the serve checks failed{label}')
    for problem in problems:
        print(f'::error::{problem}')
    return 1 if problems else 0


def command_help(args) -> int:
    problems = help_problems(args.output.read_text(encoding='utf-8', errors='replace'), args.fixture)
    for problem in problems:
        print(f'::error::{problem}')
    if not problems:
        print(f'immuch360-av2 --help: the same as {args.fixture.name}')
    return 1 if problems else 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--lock', type=pathlib.Path, default=LOCK)
    parser.add_argument('--licences', type=pathlib.Path, default=LICENCES)
    commands = parser.add_subparsers(dest='command', required=True)
    lock = commands.add_parser('lock')
    lock.add_argument('--system', choices=SYSTEMS, required=True)
    lock.add_argument('--github-output', action='store_true')
    sources = commands.add_parser('sources')
    sources.add_argument('--dir', type=pathlib.Path, default=NATIVE / 'subprojects' / 'dav2d')
    build = commands.add_parser('build')
    build.add_argument('--system', choices=SYSTEMS, required=True)
    build.add_argument('--build', type=pathlib.Path, required=True)
    build.add_argument('--source-commit')
    licences = commands.add_parser('licences')
    licences.add_argument('--source', type=pathlib.Path, default=NATIVE / 'subprojects' / 'dav2d')
    pack = commands.add_parser('pack')
    pack.add_argument('--system', choices=SYSTEMS, required=True)
    pack.add_argument('--source', type=pathlib.Path, default=NATIVE / 'subprojects' / 'dav2d')
    pack.add_argument('--program', type=pathlib.Path, required=True)
    pack.add_argument('--out', type=pathlib.Path, required=True)
    pack.add_argument('--launcher', type=pathlib.Path)
    pack.add_argument('--source-commit')
    check = commands.add_parser('check')
    check.add_argument('--system', choices=SYSTEMS, required=True)
    check.add_argument('--archive', type=pathlib.Path, required=True)
    check.add_argument('--fixtures', type=pathlib.Path, default=FIXTURES)
    check.add_argument('--help-fixture', type=pathlib.Path, default=HELP_FIXTURE)
    check.add_argument('--run', action='store_true')
    check.add_argument('--arch-x86-64', action='store_true')
    check.add_argument('--threads', type=int, default=0)
    shown = commands.add_parser('help')
    shown.add_argument('--output', type=pathlib.Path, required=True)
    shown.add_argument('--fixture', type=pathlib.Path, default=HELP_FIXTURE)
    extract = commands.add_parser('program')
    extract.add_argument('--system', choices=SYSTEMS, required=True)
    extract.add_argument('--archive', type=pathlib.Path, required=True)
    extract.add_argument('--out', type=pathlib.Path, required=True)
    extract.add_argument('--github-output', action='store_true')
    signed = commands.add_parser('signed')
    signed.add_argument('--system', choices=SYSTEMS, required=True)
    signed.add_argument('--archive', type=pathlib.Path, required=True)
    signed.add_argument('--program', type=pathlib.Path, required=True)
    signed.add_argument('--out', type=pathlib.Path, required=True)
    signed.add_argument('--github-output', action='store_true')
    args = parser.parse_args(argv)
    try:
        return {'lock': command_lock, 'sources': command_sources, 'build': command_build,
                'licences': command_licences, 'pack': command_pack, 'check': command_check,
                'help': command_help, 'program': command_program, 'signed': command_signed}[args.command](args)
    except (Failure, subprocess.CalledProcessError) as error:
        print(f'::error::{error}')
        return 1
    except (OSError, json.JSONDecodeError, KeyError) as error:
        print(f'::error::{error}')
        return 2


if __name__ == '__main__':
    sys.exit(main())
