#!/usr/bin/env python3
"""COLMAP for Immuch360 Desktop, on the processor and without its GPL parts: the sources, the build and the archive of
the colmap jobs.

The splat scenes of Immuch360 Desktop place the photos with COLMAP (lot SP1 of the splat maker, plan of 2026-11-01,
sections 2.3 and 3; research of the same day, section 1.2). The official binaries of COLMAP are never shipped: they
carry SiftGPU (educational, research and non-profit use only), LSD (AGPL 3), CGAL, Qt and CHOLMOD with its GPL modules,
and no notice. The jobs colmap-windows and colmap-linux of immuch360-desktop.yml build it from the commit of
colmap.lock.json next to this script, with the patches of licenses/colmap/patches (no CHOLMOD at all: the sparse
Cholesky of COLMAP goes through Eigen's SimplicialLDLT, and Ceres through Eigen's sparse solvers instead of
SuiteSparse), the libraries of vcpkg at the commit of the lock (LAPACK by CLAPACK, our overlay port of
.github/desktop/ai/colmap/vcpkg-ports, never the Fortran of lapack-reference and its libgfortran), and upload the
archive Immuch360-AI-colmap-<id>-<system>.zip, which no release of the app attaches.

  colmap_build.py lock --system SYSTEM [--github-output]
      the id of the lock, the commits, the triplet of SYSTEM (windows-x64 or linux-x64), the name of the artifact and
      the key of the binary cache of vcpkg
  colmap_build.py sources --dir DIR
      COLMAP at the commit of the lock, line ends as committed (no autocrlf), with the patches of the lock applied
  colmap_build.py vcpkg --system SYSTEM --source DIR --vcpkg DIR --installed DIR --cache DIR [--github-output]
      vcpkg at the commit of the lock, bootstrapped, then the libraries of the patched manifest of COLMAP (no default
      feature: no GUI, no download) built or taken from the binary cache DIR; cache_grew=true when it gained archives
  colmap_build.py licences --system SYSTEM --installed DIR [--ports-json FILE] [--table FILE]
      the licence of every port installed for the triplet, read in its vcpkg.spdx.json, against our list (MIT, BSD,
      Apache 2.0, BSL 1.0, MPL 2.0, zlib, IJG, libpng, libtiff, public domain); a GPL, LGPL, AGPL, unknown or missing
      licence fails, but for the ports reviewed by hand (metapackages, CLAPACK); then the ports against the table of
      licenses/colmap/THIRD-PARTY.md, so that a new library shows in a review
  colmap_build.py table --ports-json FILE [--ports-json FILE] [--table FILE]
      writes that table from the port lists of the jobs (their artifacts)
  colmap_build.py build --system SYSTEM --source DIR --build DIR --vcpkg DIR --installed DIR
      cmake with the options of the lock (each part we leave out must say so in the configure output), then the
      program; on Windows inside the environment of Visual Studio 2022 with the C++ tools
  colmap_build.py pack --system SYSTEM --source DIR --build DIR --installed DIR --out DIR [--launcher FILE]
                       [--crt-dir DIR] [--system-dir DIR]
      the archive: the program, on Windows the Visual C++ and OpenMP runtime DLLs it imports (a clean Windows has none)
      and every import checked as windows_bundle.py does, on Linux the launcher immuch360-run and every library they
      need found in the base of a distribution; licenses/ (licenses/colmap, the texts of the code built in compared
      with the sources, the copyright file of every port), BUILD-INFO.txt and SHA256SUMS.txt. Sorted names, fixed dates.
      Nothing forbidden may be in it (see check)
  colmap_build.py check --archive FILE | --dir DIR
      no file, import or needed library named after Qt, GMP, MPFR, CHOLMOD, SPQR, SuiteSparse, GLEW, gfortran, CGAL,
      ONNX Runtime, curl or OpenGL, and none of the strings that only SiftGPU, LSD, CHOLMOD, SPQR, GMP, MPFR, GLEW,
      gfortran, CGAL or Qt put in a program
  colmap_build.py help --colmap FILE [--fixtures DIR] [--save DIR] [--write]
      the output of colmap help and of the -h of the commands of the lock compared with mobile/test/fixtures/
      ai_immersive/colmap_help/, the texts the arguments of the runner of the app are frozen by (log lines apart); the
      first line of colmap help must name the commit of the lock

Only the Python standard library is used. Exit codes: 0 good, 1 a check failed, 2 bad arguments or missing inputs.
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
import zipfile

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]
LOCK = HERE / 'colmap.lock.json'
OVERLAY_PORTS = HERE / 'colmap' / 'vcpkg-ports'
LICENCES = ROOT / 'licenses' / 'colmap'
TABLE = LICENCES / 'THIRD-PARTY.md'
FIXTURES = ROOT / 'mobile' / 'test' / 'fixtures' / 'ai_immersive' / 'colmap_help'
SYSTEMS = ('windows-x64', 'linux-x64')
ARTIFACT_PREFIX = 'Immuch360-AI-colmap-'

sys.path.insert(0, str(HERE))
import sdcpp_build  # noqa: E402 (ELF reading, the archive writer and Visual Studio, shared with the sdcpp jobs)

# The licences a library of the archive may have (SPDX identifiers): the permissive list of the project (research of
# 2026-11-01, section 4), with libtiff (a permission notice of the same kind, for OpenImageIO's TIFF reader) and the
# public domain of SQLite (blessing)
ALLOWED_LICENCES = {
    'MIT', 'MIT-0', 'BSD-2-Clause', 'BSD-3-Clause', 'Apache-2.0', 'BSL-1.0', 'MPL-2.0', 'Zlib', 'IJG', 'libpng-2.0',
    'Libpng', 'libtiff', 'ISC', 'blessing', 'Unlicense', 'CC0-1.0',
}
ALLOWED_EXCEPTIONS = {'LLVM-exception'}
# The ports whose vcpkg.json gives no licence, read by hand (LicenseRef-vcpkg-null, or NOASSERTION, in their
# vcpkg.spdx.json)
REVIEWED = {
    'blas': 'a metapackage without code: it selects OpenBLAS (BSD-3-Clause)',
    'lapack': 'a metapackage without code (our overlay port): it selects CLAPACK',
    'clapack': 'LAPACK 3.2.1 translated to C, BSD-3-Clause (its COPYING), with libf2c under the permission notice of '
               'AT&T, Lucent and Bellcore (F2CLIBS/libf2c/Notice, in licenses/libf2c-Notice.txt): both read on '
               '2026-11-01',
}
# The licences vcpkg writes for a port whose vcpkg.json gives none
NO_LICENCE = ('LicenseRef-vcpkg-null', 'NOASSERTION', 'NONE', '')
# The ports that install no copyright file: two metapackages without code, and a build script of vcpkg
WITHOUT_COPYRIGHT = {
    'blas': 'none, a metapackage without code',
    'lapack': 'none, a metapackage without code',
    'boost-uninstall': 'none, a build script of vcpkg (MIT)',
}
# Never installed: what the official binaries carry and our build leaves out
FORBIDDEN_PORTS = re.compile(r'^(suitesparse.*|cholmod|qt.*|cgal|gmp|mpfr|glew|lapack-reference|gfortran|curl|openssl|'
                             r'onnxruntime.*|cuda|freeglut|opengl)$')
# Names of files, imports and needed libraries, and strings that only the code we leave out puts in a program
FORBIDDEN_NAMES = re.compile(r'(?i)(qt[56]|^gmp|libgmp|mpfr|cholmod|spqr|suitesparse|glew|gfortran|quadmath|cgal|'
                             r'onnxruntime|curl|opengl|^libgl\.|^libglx)')
FORBIDDEN_STRINGS = {
    b'SiftGPU Usage:': 'SiftGPU', b'[SiftGPU Language]': 'SiftGPU', b'SiftPyramid': 'SiftGPU',
    b'LineSegmentDetection': 'LSD (AGPL 3)', b'new_ntuple_list': 'LSD (AGPL 3)',
    b'cholmod_': 'CHOLMOD', b'SuiteSparseQR': 'SPQR', b'spqr_': 'SPQR',
    b'__gmp': 'GMP', b'mpfr_': 'MPFR', b'glewInit': 'GLEW', b'_gfortran': 'libgfortran',
    b'CGAL::': 'CGAL', b'@CGAL@@': 'CGAL', b'QApplication': 'Qt', b'qt_plugin_': 'Qt',
}
# The libraries a Linux program may need from the system: the base of any distribution of the desktop (glibc 2.35 and
# the GCC runtime of Ubuntu 22.04), as for sd-cli, and GCC's OpenMP runtime, which COLMAP links (OpenMP is not optional
# in its CMake); the Linux packages of the app depend on it when the feature is offered there
LINUX_SYSTEM = sdcpp_build.LINUX_SYSTEM | {'libgomp.so.1'}
# The licence texts of the code built into COLMAP but not by vcpkg, compared with the sources at packing time: the file
# of licenses/colmap, and where it is in the sources (source:) or in the build tree (build:)
LICENCE_SOURCES = {
    'COPYING.txt': 'source:COPYING.txt',
    'VLFeat-LICENSE.txt': 'source:src/thirdparty/VLFeat/LICENSE',
    'PoissonRecon-LICENSE.txt': 'source:src/thirdparty/PoissonRecon/LICENSE',
    'PoseLib-LICENSE.txt': 'build:_deps/poselib-src/LICENSE',
    'faiss-LICENSE.txt': 'build:_deps/faiss-src/LICENSE',
}
# What the configure step must say: each part we leave out, and nothing that would bring it back
CONFIGURE_SAYS = ('Disabling LSD support', 'Disabling CHOLMOD support', 'Disabling GUI support',
                  'Disabling CGAL support', 'Disabling CUDA support', 'Disabling ONNX support',
                  'Disabling download support', 'Disabling MVS support', 'Disabling OpenGL support')
CONFIGURE_NEVER = ('Enabling GPU support', 'Enabling LSD support', 'Enabling CHOLMOD support', 'Found CGAL',
                   'Enabling download support', 'Enabling ONNX support')
TABLE_START = '<!-- vcpkg ports: written by colmap_build.py table, checked by the colmap jobs -->'
TABLE_END = '<!-- end of the vcpkg ports -->'
# Log lines of glog (I20261101 15:23:53.425428 29732 option_manager.cc:1319] ...): time and thread, never the same
GLOG_LINE = re.compile(r'^[IWEF]\d{8} ')


class Failure(Exception):
    pass


def load_lock(path: pathlib.Path = LOCK) -> dict:
    lock = json.loads(path.read_text(encoding='utf-8'))
    for key in ('id', 'colmap', 'patches', 'vcpkg', 'cmake', 'help'):
        if key not in lock:
            raise Failure(f'{path.name}: no {key}')
    match = re.fullmatch(r'(\d+\.\d+\.\d+)-imm\d+', lock['id'])
    if not match:
        raise Failure(f'{path.name}: the id {lock["id"]!r} is not <version of COLMAP>-imm<build>')
    if lock['colmap'].get('tag') != match.group(1):
        raise Failure(f'{path.name}: the id {lock["id"]} is not of the tag {lock["colmap"].get("tag")}')
    for name in ('colmap', 'vcpkg'):
        if not re.fullmatch(r'[0-9a-f]{40}', lock[name].get('commit', '')):
            raise Failure(f'{path.name}: the commit of {name} is not a full commit')
        if not lock[name].get('repository', '').startswith('https://'):
            raise Failure(f'{path.name}: {name} has no https repository')
    if not re.fullmatch(r'\d{4}-\d\d-\d\d', lock['colmap'].get('date', '')):
        raise Failure(f'{path.name}: the date of the commit of COLMAP is not YYYY-MM-DD')
    for system in SYSTEMS:
        if not lock['vcpkg'].get('triplets', {}).get(system):
            raise Failure(f'{path.name}: no triplet for {system}')
        if not isinstance(lock['cmake'].get(system), list):
            raise Failure(f'{path.name}: no CMake options for {system}')
    for patch in lock['patches']:
        if not (LICENCES / 'patches' / patch).is_file():
            raise Failure(f'{path.name}: the patch {patch} is not in licenses/colmap/patches')
    if not lock['help'] or any(not re.fullmatch(r'[a-z_]+', command) for command in lock['help']):
        raise Failure(f'{path.name}: the help commands are not a list of command names')
    return lock


def artifact_name(lock: dict, system: str) -> str:
    return f'{ARTIFACT_PREFIX}{lock["id"]}-{system}.zip'


def write_outputs(values: dict):
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as stream:
            for key, value in values.items():
                stream.write(f'{key}={value}\n')


def run(command: list, cwd: pathlib.Path | None = None):
    print('$ ' + ' '.join(str(part) for part in command), flush=True)
    subprocess.run([str(part) for part in command], cwd=cwd, check=True)


def output(command: list, cwd: pathlib.Path | None = None) -> str:
    return subprocess.run([str(part) for part in command], cwd=cwd, check=True, capture_output=True,
                          text=True).stdout.strip()


# --- lock ------------------------------------------------------------------------------------------------------------

def command_lock(args) -> int:
    lock = load_lock(args.lock)
    values = {
        'id': lock['id'],
        'artifact': artifact_name(lock, args.system),
        'commit': lock['colmap']['commit'],
        'vcpkg_commit': lock['vcpkg']['commit'],
        'triplet': lock['vcpkg']['triplets'][args.system],
        # The binary cache of vcpkg holds archives by their ABI hash: any older cache of the same vcpkg is worth
        # restoring, whatever changed in our patches since
        'cache_key': f'{args.system}-{lock["vcpkg"]["commit"][:12]}',
    }
    for key, value in values.items():
        print(f'{key}={value}')
    if args.github_output:
        write_outputs(values)
    return 0


# --- sources ---------------------------------------------------------------------------------------------------------

def fetch_commit(folder: pathlib.Path, repository: str, commit: str):
    """The commit in folder, its files as committed: no autocrlf (on by default on the Windows runners), or the patches
    would not apply"""
    folder.mkdir(parents=True, exist_ok=True)
    git = ['git', '-c', 'core.autocrlf=false', '-C', folder]
    run(['git', 'init', '-q', folder])
    run(git + ['fetch', '-q', '--depth', '1', repository, commit])
    run(git + ['checkout', '-q', '--detach', 'FETCH_HEAD'])
    found = output(['git', '-C', folder, 'rev-parse', 'HEAD'])
    if found != commit:
        raise Failure(f'{repository}: {found} checked out, the lock says {commit}')


def command_sources(args) -> int:
    lock = load_lock(args.lock)
    if args.dir.exists():
        shutil.rmtree(args.dir)
    fetch_commit(args.dir, lock['colmap']['repository'], lock['colmap']['commit'])
    for patch in lock['patches']:
        path = LICENCES / 'patches' / patch
        run(['git', '-c', 'core.autocrlf=false', '-C', args.dir, 'apply', '--check', path])
        run(['git', '-c', 'core.autocrlf=false', '-C', args.dir, 'apply', path])
    print(f'COLMAP {lock["colmap"]["tag"]} ({lock["colmap"]["commit"]}) in {args.dir}, patched by '
          + ', '.join(lock['patches']))
    return 0


# --- vcpkg -----------------------------------------------------------------------------------------------------------

def archives(cache: pathlib.Path) -> int:
    return sum(1 for path in cache.rglob('*.zip')) if cache.is_dir() else 0


def command_vcpkg(args) -> int:
    lock = load_lock(args.lock)
    triplet = lock['vcpkg']['triplets'][args.system]
    tool = args.vcpkg / ('vcpkg.exe' if args.system == 'windows-x64' else 'vcpkg')
    if not tool.is_file():
        if args.vcpkg.exists():
            shutil.rmtree(args.vcpkg)
        fetch_commit(args.vcpkg, lock['vcpkg']['repository'], lock['vcpkg']['commit'])
        # The bootstrap downloads the vcpkg program its scripts name, checked by its SHA-512
        if args.system == 'windows-x64':
            run(['cmd.exe', '/d', '/c', str(args.vcpkg / 'bootstrap-vcpkg.bat'), '-disableMetrics'])
        else:
            run(['sh', str(args.vcpkg / 'bootstrap-vcpkg.sh'), '-disableMetrics'])
    args.cache.mkdir(parents=True, exist_ok=True)
    before = archives(args.cache)
    command = [tool, 'install', f'--triplet={triplet}', f'--host-triplet={triplet}',
               f'--x-manifest-root={args.source}', f'--x-install-root={args.installed}',
               f'--overlay-ports={OVERLAY_PORTS}', '--x-no-default-features', '--clean-after-build',
               f'--binarysource=clear;files,{args.cache},readwrite']
    try:
        run(command)
    finally:
        after = archives(args.cache)
        print(f'binary cache of vcpkg: {before} archives before, {after} after')
        if args.github_output:
            write_outputs({'cache_grew': 'true' if after > before else 'false'})
    return 0


# --- licences --------------------------------------------------------------------------------------------------------

def tokens(expression: str) -> list:
    return re.findall(r'\(|\)|[A-Za-z0-9.+:-]+', expression)


def licence_allowed(expression: str) -> bool:
    """An SPDX expression whose every AND part is allowed and whose OR offers an allowed choice; WITH only with an
    allowed exception"""
    parts = tokens(expression)
    position = 0

    def primary() -> bool:
        nonlocal position
        if position >= len(parts):
            raise ValueError('incomplete')
        part = parts[position]
        position += 1
        if part == '(':
            value = disjunction()
            if position >= len(parts) or parts[position] != ')':
                raise ValueError('no closing parenthesis')
            position += 1
            return value
        if part in (')', 'AND', 'OR', 'WITH'):
            raise ValueError(f'{part} out of place')
        allowed = part in ALLOWED_LICENCES
        if position < len(parts) and parts[position] == 'WITH':
            position += 1
            if position >= len(parts):
                raise ValueError('WITH without an exception')
            allowed = allowed and parts[position] in ALLOWED_EXCEPTIONS
            position += 1
        return allowed

    def conjunction() -> bool:
        nonlocal position
        value = primary()
        while position < len(parts) and parts[position] == 'AND':
            position += 1
            value = primary() and value
        return value

    def disjunction() -> bool:
        nonlocal position
        value = conjunction()
        while position < len(parts) and parts[position] == 'OR':
            position += 1
            value = conjunction() or value
        return value

    try:
        value = disjunction()
    except ValueError:
        return False
    return value and position == len(parts)


def installed_ports(installed: pathlib.Path, triplet: str) -> dict:
    """{port: (version, licence)} from the vcpkg.spdx.json of every port installed for the triplet"""
    share = installed / triplet / 'share'
    if not share.is_dir():
        raise Failure(f'nothing installed for {triplet} in {installed}')
    ports = {}
    for path in sorted(share.glob('*/vcpkg.spdx.json')):
        document = json.loads(path.read_text(encoding='utf-8'))
        package = next((item for item in document.get('packages', []) if item.get('SPDXID') == 'SPDXRef-port'),
                       (document.get('packages') or [{}])[0])
        name = package.get('name') or path.parent.name
        licence = package.get('licenseConcluded') or package.get('licenseDeclared') or 'NOASSERTION'
        ports[name] = (package.get('versionInfo', '?'), licence)
    if not ports:
        raise Failure(f'no vcpkg.spdx.json under {share}')
    return ports


def licence_problems(ports: dict) -> list:
    problems = []
    for name, (version, licence) in sorted(ports.items()):
        if FORBIDDEN_PORTS.match(name):
            problems.append(f'{name} {version} is installed: it is left out of our build ({licence})')
        elif licence in NO_LICENCE:
            if name not in REVIEWED:
                problems.append(f'{name} {version} gives no licence and was not reviewed: read its copyright file')
        elif not licence_allowed(licence):
            problems.append(f'{name} {version} is under {licence}, not in our list')
    return problems


def read_table(path: pathlib.Path) -> dict:
    """{port: (version, licence, set of systems)} of the table of the vcpkg ports"""
    text = path.read_text(encoding='utf-8')
    if TABLE_START not in text or TABLE_END not in text:
        raise Failure(f'{path}: no table of the vcpkg ports between its markers')
    rows = {}
    for line in text.split(TABLE_START, 1)[1].split(TABLE_END, 1)[0].splitlines():
        cells = [cell.strip() for cell in line.strip().strip('|').split('|')]
        if len(cells) < 4 or cells[0] in ('Port', '') or set(cells[0]) <= {'-'}:
            continue
        rows[cells[0].strip('`')] = (cells[1].strip('`'), cells[2].strip('`'),
                                     {system.strip() for system in cells[3].split(',') if system.strip()})
    return rows


def table_problems(ports: dict, rows: dict, system: str) -> list:
    problems = []
    listed = {name for name, row in rows.items() if system in row[2]}
    for name in sorted(set(ports) - listed):
        problems.append(f'{name} {ports[name][0]} ({ports[name][1]}) is installed for {system} but not in the table')
    for name in sorted(listed - set(ports)):
        problems.append(f'{name} is in the table for {system} but not installed')
    for name in sorted(listed & set(ports)):
        if (rows[name][0], rows[name][1]) != ports[name]:
            problems.append(f'{name}: the table says {rows[name][0]} under {rows[name][1]}, installed {ports[name][0]} '
                            f'under {ports[name][1]}')
    return problems


def command_licences(args) -> int:
    lock = load_lock(args.lock)
    triplet = lock['vcpkg']['triplets'][args.system]
    ports = installed_ports(args.installed, triplet)
    for name, (version, licence) in sorted(ports.items()):
        note = f'  (reviewed: {REVIEWED[name]})' if name in REVIEWED and licence in NO_LICENCE else ''
        print(f'{name:<34} {version:<20} {licence}{note}')
    if args.ports_json:
        args.ports_json.parent.mkdir(parents=True, exist_ok=True)
        args.ports_json.write_text(json.dumps({'system': args.system, 'triplet': triplet, 'ports': {
            name: {'version': version, 'licence': licence} for name, (version, licence) in sorted(ports.items())}},
            indent=1) + '\n', encoding='utf-8', newline='\n')
    problems = licence_problems(ports)
    problems += table_problems(ports, read_table(args.table), args.system)
    for problem in problems:
        print(f'::error::{problem}')
    if problems:
        return 1
    print(f'{len(ports)} ports for {triplet}, every licence in our list or reviewed, as the table says')
    return 0


def command_table(args) -> int:
    merged = {}
    for path in args.ports_json:
        data = json.loads(path.read_text(encoding='utf-8'))
        for name, port in data['ports'].items():
            row = merged.setdefault(name, [port['version'], port['licence'], set()])
            if (row[0], row[1]) != (port['version'], port['licence']):
                raise Failure(f'{name}: {row[0]} under {row[1]} on one system, {port["version"]} under '
                              f'{port["licence"]} on {data["system"]}')
            row[2].add(data['system'])
    lines = [TABLE_START, '', '| Port | Version | Licence (SPDX of vcpkg) | Systems | Text in the archive |',
             '|---|---|---|---|---|']
    for name, (version, licence, systems) in sorted(merged.items()):
        text = WITHOUT_COPYRIGHT.get(name, f'`licenses/vcpkg/{name}.txt`')
        lines.append(f'| `{name}` | {version} | {licence} | {", ".join(sorted(systems))} | {text} |')
    lines += ['', TABLE_END]
    text = args.table.read_text(encoding='utf-8')
    start, end = text.index(TABLE_START), text.index(TABLE_END) + len(TABLE_END)
    args.table.write_text(text[:start] + '\n'.join(lines) + text[end:], encoding='utf-8', newline='\n')
    print(f'{len(merged)} ports written in {args.table}')
    return 0


# --- build -----------------------------------------------------------------------------------------------------------

def cmake_options(lock: dict, system: str, vcpkg: pathlib.Path, installed: pathlib.Path) -> list:
    triplet = lock['vcpkg']['triplets'][system]
    return [*lock['cmake']['common'], *lock['cmake'][system],
            f'-DCMAKE_TOOLCHAIN_FILE={vcpkg / "scripts" / "buildsystems" / "vcpkg.cmake"}',
            f'-DVCPKG_TARGET_TRIPLET={triplet}', f'-DVCPKG_HOST_TRIPLET={triplet}', f'-DVCPKG_INSTALLED_DIR={installed}',
            f'-DGIT_COMMIT_ID={lock["colmap"]["commit"][:7]}', f'-DGIT_COMMIT_DATE={lock["colmap"]["date"]}']


def configure_problems(log: str, options: list = (), cache: str = '') -> list:
    problems = [f'the configure step does not say "{line}"' for line in CONFIGURE_SAYS if line not in log]
    problems += [f'the configure step says "{line}"' for line in CONFIGURE_NEVER if line in log]
    # The AVX2 build of faiss, when asked (Windows), must be the one COLMAP links
    if '-DFAISS_AVX2_ENABLED=ON' in options and 'Enabling the AVX2 build of faiss' not in log:
        problems.append('the configure step does not say "Enabling the AVX2 build of faiss"')
    # A flag given to start the flags of a language must be in the flags CMake kept
    for option in options:
        match = re.fullmatch(r'-DCMAKE_(C|CXX)_FLAGS_INIT=(.+)', option)
        if not match:
            continue
        kept = re.search(rf'^CMAKE_{match.group(1)}_FLAGS:STRING=(.*)$', cache, re.MULTILINE)
        if not kept or match.group(2) not in kept.group(1).split():
            problems.append(f'CMAKE_{match.group(1)}_FLAGS of the build does not hold {match.group(2)}')
    return problems


def command_build(args) -> int:
    lock = load_lock(args.lock)
    configure = ['cmake', '-S', str(args.source), '-B', str(args.build),
                 *cmake_options(lock, args.system, args.vcpkg, args.installed)]
    # Four jobs, the processors of the hosted runners
    build = ['cmake', '--build', str(args.build), '--config', 'Release', '--target', 'colmap_main', '--parallel', '4']
    log = args.build / 'configure.log'
    args.build.mkdir(parents=True, exist_ok=True)
    if args.system == 'linux-x64':
        print('$ ' + ' '.join(configure), flush=True)
        result = subprocess.run(configure, capture_output=True, text=True)
        log.write_text(result.stdout + result.stderr, encoding='utf-8')
        print(result.stdout + result.stderr, flush=True)
        if result.returncode != 0:
            raise Failure(f'cmake configure failed ({result.returncode})')
        run(build)
    else:
        studio = sdcpp_build.visual_studio()
        script = pathlib.Path(tempfile.mkdtemp(prefix='colmap-')) / 'build.bat'
        quote = sdcpp_build.batch_quote
        script.write_text('\r\n'.join([
            '@echo off',
            f'call "{studio}\\Common7\\Tools\\VsDevCmd.bat" -arch=x64 -host_arch=x64 -no_logo || exit /b 1',
            'where cl ninja cmake',
            ' '.join(quote(part) for part in configure) + f' > "{log}" 2>&1',
            'set CONFIGURED=%ERRORLEVEL%',
            f'type "{log}"',
            'if not "%CONFIGURED%"=="0" exit /b 1',
            ' '.join(quote(part) for part in build) + ' || exit /b 1',
            '',
        ]), encoding='utf-8', newline='')
        print(f'Visual Studio: {studio}')
        run(['cmd.exe', '/d', '/c', str(script)])
    cache = args.build / 'CMakeCache.txt'
    problems = configure_problems(log.read_text(encoding='utf-8', errors='replace'), configure,
                                  cache.read_text(encoding='utf-8', errors='replace') if cache.is_file() else '')
    for line in re.findall(r'^CMAKE_(?:C|CXX)_FLAGS:STRING=.*$', cache.read_text(encoding='utf-8', errors='replace')
                           if cache.is_file() else '', re.MULTILINE):
        print(line)
    for problem in problems:
        print(f'::error::{problem}')
    if problems:
        return 1
    program = program_path(args.build, args.system)
    if not program.is_file():
        raise Failure(f'no {program.name} in {program.parent}')
    print(f'{program}: {program.stat().st_size} bytes; the configure step left out each part it must')
    return 0


def program_path(build: pathlib.Path, system: str) -> pathlib.Path:
    return build / 'src' / 'colmap' / 'exe' / ('colmap.exe' if system == 'windows-x64' else 'colmap')


# --- check -----------------------------------------------------------------------------------------------------------

def is_program(name: str, data: bytes) -> bool:
    return data[:2] == b'MZ' or data[:4] == b'\x7fELF' or name.lower().endswith(('.exe', '.dll', '.so')) or '.so.' in name


def imported_names(data: bytes) -> list:
    """The DLLs a PE file imports, or the libraries an ELF file needs"""
    if data[:4] == b'\x7fELF':
        return sdcpp_build.elf_needed(data)
    if data[:2] == b'MZ':
        sys.path.insert(0, str(ROOT / '.github' / 'desktop'))
        import windows_bundle  # noqa: E402 (the import tables of the Windows ZIP of the app)

        with tempfile.TemporaryDirectory(prefix='colmap-pe-') as temporary:
            path = pathlib.Path(temporary) / 'file.bin'
            path.write_bytes(data)
            try:
                info = windows_bundle.read_pe(path)
            except (windows_bundle.NotPe, struct.error, ValueError, IndexError):
                return ['<unreadable PE file>']
            return info['imports'] + info['delay_imports']
    return []


def forbidden(files: dict) -> list:
    """What is forbidden in the files of an archive ({name: bytes}): names, imports, needed libraries, strings"""
    problems = []
    for name, data in sorted(files.items()):
        base = name.rsplit('/', 1)[-1]
        if name.startswith('licenses/'):
            continue
        if FORBIDDEN_NAMES.search(base):
            problems.append(f'{name}: a forbidden name')
        if not is_program(name, data):
            continue
        for imported in imported_names(data):
            if FORBIDDEN_NAMES.search(imported):
                problems.append(f'{name}: imports or needs {imported}')
        for marker, what in FORBIDDEN_STRINGS.items():
            if marker in data:
                problems.append(f'{name}: holds "{marker.decode()}", a string of {what}')
    return problems


def command_check(args) -> int:
    if args.archive:
        with zipfile.ZipFile(args.archive) as bundle:
            files = {info.filename: bundle.read(info) for info in bundle.infolist() if not info.is_dir()}
    else:
        files = {path.relative_to(args.dir).as_posix(): path.read_bytes() for path in sorted(args.dir.rglob('*'))
                 if path.is_file()}
    problems = forbidden(files)
    for problem in problems:
        print(f'::error::{problem}')
    if problems:
        return 1
    print(f'{len(files)} files: no forbidden name, import, library or string')
    return 0


# --- pack ------------------------------------------------------------------------------------------------------------

def windows_files(program: pathlib.Path, crt_dir: pathlib.Path | None, system_dir: pathlib.Path | None) -> tuple:
    """colmap.exe with the Visual C++ and OpenMP runtime DLLs it imports, and the problems"""
    sys.path.insert(0, str(ROOT / '.github' / 'desktop'))
    import windows_bundle  # noqa: E402 (the import checks of the Windows ZIP of the app)

    crt_dir = crt_dir or windows_bundle.find_crt_dir('x64')
    if crt_dir is None or not crt_dir.is_dir():
        raise Failure('no Visual C++ redistributable folder: give --crt-dir')
    system_dir = system_dir or pathlib.Path(os.environ.get('SystemRoot', r'C:\Windows'), 'System32')
    # vcomp140.dll, the OpenMP runtime of Visual C++, is in the Microsoft.VC*.OpenMP folder next to the CRT one
    crt = {}
    for folder in [crt_dir, *sorted(crt_dir.parent.glob('Microsoft.VC*.OpenMP'))]:
        crt.update({path.name.lower(): path for path in folder.glob('*.dll')})
    system = {name.lower() for name in os.listdir(system_dir)}
    with tempfile.TemporaryDirectory(prefix='colmap-') as temporary:
        folder = pathlib.Path(temporary)
        shutil.copy2(program, folder / 'colmap.exe')
        copied = []
        problems = windows_bundle.check(folder, 'x64', crt, system, copied)
        for name in copied:
            print(f'Visual C++ runtime: {name}')
        return {path.name: path.read_bytes() for path in sorted(folder.iterdir())}, problems


def linux_files(program: pathlib.Path, launcher: pathlib.Path) -> tuple:
    files = {'colmap': program.read_bytes(), 'immuch360-run': launcher.read_bytes()}
    problems = []
    for name, data in files.items():
        for needed in sdcpp_build.elf_needed(data):
            if needed not in LINUX_SYSTEM:
                problems.append(f'{name} needs {needed}, which is not in the base of a distribution')
    return files, problems


def licence_files(lock: dict, system: str, source: pathlib.Path, build: pathlib.Path, installed: pathlib.Path) -> tuple:
    files, problems = {}, []
    for name, where in LICENCE_SOURCES.items():
        kind, relative = where.split(':', 1)
        theirs_path = (source if kind == 'source' else build) / relative
        ours = (LICENCES / name).read_bytes().replace(b'\r\n', b'\n').strip()
        if not theirs_path.is_file():
            problems.append(f'no {relative} in the {kind} tree: its licence cannot be checked')
            continue
        if ours != theirs_path.read_bytes().replace(b'\r\n', b'\n').strip():
            problems.append(f'licenses/colmap/{name} differs from {relative} of the {kind} tree: copy it again')
    for path in sorted(LICENCES.rglob('*')):
        if path.is_file():
            files[f'licenses/{path.relative_to(LICENCES).as_posix()}'] = path.read_bytes()
    triplet = lock['vcpkg']['triplets'][system]
    for spdx in sorted((installed / triplet / 'share').glob('*/vcpkg.spdx.json')):
        copyright = spdx.parent / 'copyright'
        if copyright.is_file():
            files[f'licenses/vcpkg/{spdx.parent.name}.txt'] = copyright.read_bytes()
        elif spdx.parent.name not in WITHOUT_COPYRIGHT:
            problems.append(f'the port {spdx.parent.name} has no copyright file')
    return files, problems


def build_info(lock: dict, system: str, ports: int) -> bytes:
    run_url = ''
    if os.environ.get('GITHUB_RUN_ID'):
        run_url = (f'{os.environ.get("GITHUB_SERVER_URL", "https://github.com")}/{os.environ.get("GITHUB_REPOSITORY")}'
                   f'/actions/runs/{os.environ["GITHUB_RUN_ID"]}')
    return '\n'.join([
        f'COLMAP {lock["colmap"]["tag"]} for Immuch360 Desktop, on the processor, without its GPL parts: {system}, '
        f'lock {lock["id"]}',
        f'COLMAP {lock["colmap"]["repository"]} {lock["colmap"]["commit"]} (tag {lock["colmap"]["tag"]}), with the '
        'patches of licenses/patches: ' + ', '.join(lock['patches']),
        f'vcpkg {lock["vcpkg"]["repository"]} {lock["vcpkg"]["commit"]}, triplet {lock["vcpkg"]["triplets"][system]}, '
        f'{ports} ports (licenses/THIRD-PARTY.md, their texts in licenses/vcpkg/), LAPACK by CLAPACK',
        'CMake options: ' + ' '.join([*lock['cmake']['common'], *lock['cmake'][system]]),
        'Left out: the graphical interface (Qt), OpenGL and SiftGPU, CUDA, LSD, CGAL, CHOLMOD and SuiteSparse, ONNX '
        'Runtime, the dense reconstruction (MVS), the downloads (curl, OpenSSL), the tests',
        *(['Processor: x86-64 with AVX2 (faiss built for AVX2, its own distances instead of BLAS: '
           'licenses/patches/0003-faiss-avx2-without-blas.patch)'] if '-DFAISS_AVX2_ENABLED=ON' in lock['cmake'][system]
          else ['Processor: x86-64 (faiss chooses its SIMD code at run time)']),
        *([f'Built by {run_url}'] if run_url else []),
        '',
    ]).encode()


def command_pack(args) -> int:
    lock = load_lock(args.lock)
    program = program_path(args.build, args.system)
    if not program.is_file():
        raise Failure(f'no {program}')
    if args.system == 'windows-x64':
        files, problems = windows_files(program, args.crt_dir, args.system_dir)
        programs = {'colmap.exe'}
    else:
        if args.launcher is None:
            raise Failure('the Linux archive needs --launcher (immuch360-run)')
        files, problems = linux_files(program, args.launcher)
        programs = {'colmap', 'immuch360-run'}
    licences, found = licence_files(lock, args.system, args.source, args.build, args.installed)
    problems += found
    files.update(licences)
    ports = sum(1 for name in licences if name.startswith('licenses/vcpkg/'))
    files['BUILD-INFO.txt'] = build_info(lock, args.system, ports)
    problems += forbidden(files)
    if problems:
        for problem in problems:
            print(f'::error::{problem}')
        return 1
    files['SHA256SUMS.txt'] = ''.join(f'{hashlib.sha256(files[name]).hexdigest()}  {name}\n'
                                      for name in sorted(files)).encode()
    target = args.out / artifact_name(lock, args.system)
    sdcpp_build.write_archive(target, files, programs)
    for name in sorted(files):
        if not name.startswith('licenses/vcpkg/'):
            print(f'{len(files[name]):>10}  {hashlib.sha256(files[name]).hexdigest()}  {name}'
                  + ('  (program)' if name in programs else ''))
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    (args.out / f'{target.name}.sha256').write_text(f'{digest}  {target.name}\n', encoding='utf-8', newline='\n')
    print(f'{target.name}: {target.stat().st_size} bytes, SHA-256 {digest}, {len(files)} files ({ports} licences of '
          'vcpkg ports)')
    write_outputs({'archive': target, 'sha256': digest})
    return 0


# --- help ------------------------------------------------------------------------------------------------------------

def normalized_help(text: str) -> list:
    """The lines of a help without the log lines of glog, line ends of Unix, no trailing blank lines"""
    lines = [line.rstrip() for line in text.replace('\r\n', '\n').split('\n') if not GLOG_LINE.match(line)]
    while lines and not lines[-1]:
        lines.pop()
    return lines


def help_texts(colmap: pathlib.Path, commands: list) -> dict:
    texts = {}
    # A program in Python (the fake COLMAP of the tests) runs with this Python, on every system
    program = [sys.executable, str(colmap)] if colmap.suffix == '.py' else [str(colmap)]
    for command in ['help', *commands]:
        arguments = [*program, 'help'] if command == 'help' else [*program, command, '-h']
        result = subprocess.run(arguments, capture_output=True, text=True, errors='replace', timeout=120)
        texts[command] = normalized_help(result.stdout + result.stderr)
    return texts


def command_help(args) -> int:
    lock = load_lock(args.lock)
    texts = help_texts(args.colmap, lock['help'])
    short = lock['colmap']['commit'][:7]
    first = texts['help'][0] if texts['help'] else ''
    problems = []
    if not first.startswith(f'COLMAP {lock["colmap"]["tag"]} (Commit {short} ') or 'without GPU support' not in first:
        problems.append(f'colmap help says {first!r}: COLMAP {lock["colmap"]["tag"]}, commit {short}, without GPU '
                        'support expected')
    if args.save:
        args.save.mkdir(parents=True, exist_ok=True)
        for command, lines in texts.items():
            (args.save / f'{command}.txt').write_text('\n'.join(lines) + '\n', encoding='utf-8', newline='\n')
    for command, lines in texts.items():
        fixture = args.fixtures / f'{command}.txt'
        if args.write:
            args.fixtures.mkdir(parents=True, exist_ok=True)
            fixture.write_text('\n'.join(lines) + '\n', encoding='utf-8', newline='\n')
            continue
        frozen = normalized_help(fixture.read_text(encoding='utf-8')) if fixture.is_file() else []
        if lines != frozen:
            problems.append(f'{command}: the help differs from {fixture.name}')
            sys.stdout.writelines(line + '\n' for line in difflib.unified_diff(frozen, lines, 'fixture', 'built',
                                                                               lineterm=''))
    for problem in problems:
        print(f'::error::{problem}')
    if problems:
        return 1
    print(f'{first}; ' + ('fixtures written: ' if args.write else 'the same as the fixtures: ')
          + ', '.join(f'{command} ({len(lines)} lines)' for command, lines in texts.items()))
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--lock', type=pathlib.Path, default=LOCK)
    commands = parser.add_subparsers(dest='command', required=True)
    lock = commands.add_parser('lock')
    lock.add_argument('--system', choices=SYSTEMS, required=True)
    lock.add_argument('--github-output', action='store_true')
    sources = commands.add_parser('sources')
    sources.add_argument('--dir', type=pathlib.Path, required=True)
    vcpkg = commands.add_parser('vcpkg')
    vcpkg.add_argument('--system', choices=SYSTEMS, required=True)
    vcpkg.add_argument('--source', type=pathlib.Path, required=True)
    vcpkg.add_argument('--vcpkg', type=pathlib.Path, required=True)
    vcpkg.add_argument('--installed', type=pathlib.Path, required=True)
    vcpkg.add_argument('--cache', type=pathlib.Path, required=True)
    vcpkg.add_argument('--github-output', action='store_true')
    licences = commands.add_parser('licences')
    licences.add_argument('--system', choices=SYSTEMS, required=True)
    licences.add_argument('--installed', type=pathlib.Path, required=True)
    licences.add_argument('--ports-json', type=pathlib.Path)
    licences.add_argument('--table', type=pathlib.Path, default=TABLE)
    table = commands.add_parser('table')
    table.add_argument('--ports-json', type=pathlib.Path, action='append', required=True)
    table.add_argument('--table', type=pathlib.Path, default=TABLE)
    build = commands.add_parser('build')
    build.add_argument('--system', choices=SYSTEMS, required=True)
    build.add_argument('--source', type=pathlib.Path, required=True)
    build.add_argument('--build', type=pathlib.Path, required=True)
    build.add_argument('--vcpkg', type=pathlib.Path, required=True)
    build.add_argument('--installed', type=pathlib.Path, required=True)
    pack = commands.add_parser('pack')
    pack.add_argument('--system', choices=SYSTEMS, required=True)
    pack.add_argument('--source', type=pathlib.Path, required=True)
    pack.add_argument('--build', type=pathlib.Path, required=True)
    pack.add_argument('--installed', type=pathlib.Path, required=True)
    pack.add_argument('--out', type=pathlib.Path, required=True)
    pack.add_argument('--launcher', type=pathlib.Path)
    pack.add_argument('--crt-dir', type=pathlib.Path)
    pack.add_argument('--system-dir', type=pathlib.Path)
    check = commands.add_parser('check')
    target = check.add_mutually_exclusive_group(required=True)
    target.add_argument('--archive', type=pathlib.Path)
    target.add_argument('--dir', type=pathlib.Path)
    helps = commands.add_parser('help')
    helps.add_argument('--colmap', type=pathlib.Path, required=True)
    helps.add_argument('--fixtures', type=pathlib.Path, default=FIXTURES)
    helps.add_argument('--save', type=pathlib.Path)
    helps.add_argument('--write', action='store_true')
    args = parser.parse_args(argv)
    try:
        return {'lock': command_lock, 'sources': command_sources, 'vcpkg': command_vcpkg, 'licences': command_licences,
                'table': command_table, 'build': command_build, 'pack': command_pack, 'check': command_check,
                'help': command_help}[args.command](args)
    except (Failure, subprocess.CalledProcessError) as error:
        print(f'::error::{error}')
        return 1
    except (OSError, json.JSONDecodeError, KeyError, ValueError, subprocess.TimeoutExpired) as error:
        print(f'::error::{error}')
        return 2


if __name__ == '__main__':
    sys.exit(main())
