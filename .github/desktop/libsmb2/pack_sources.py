#!/usr/bin/env python3
"""Packs the corresponding source of libsmb2 (GNU LGPL 2.1 or later), the library of the SMB shares, into one archive.

Every build of Immuch360 carries libsmb2: the binaries of dart_smb2's release libsmb2-r8 on Android, iOS, macOS and
Windows, a library built again from the same sources on Linux (build_linux.sh, next to this script). Their sources are
libsmb2-scripts at the commit of that release (its patches, configuration header, wrapper and build scripts), which pins
the libsmb2 commit and the SHA-256 of its archive. This script writes them into one .tar.gz:

  immuch360-libsmb2-sources/
    README.txt                       what the archive holds and how to build libsmb2 from it
    build_linux.sh                   the Linux build of Immuch360, which builds lib/libsmb2.so from this archive
    libsmb2-scripts-<commit>/        libsmb2-scripts at SCRIPTS_COMMIT, each file as git stores it
      sources/cache/libsmb2-<commit>.tar.gz
                                     libsmb2 as GitHub serves it, checked by the SHA-256 the scripts pin, where the
                                     scripts look for it before they download it (so their build runs offline)

The archive is made the same way each time (names in order, owner 0, the commit date of the scripts for every file,
gzip without a name or a date), so the same commits give the same file. It is an asset of the app in every build
(mobile/packages/dart_smb2/libsmb2/, written by `mise //mobile:codegen`, whose task runs this script) and a file of
every release (immuch360-release.yml, immuch360-desktop.yml).

Both inputs come from third parties: the scripts from ales-drnz/libsmb2-scripts, the archive of libsmb2 from GitHub's
archive endpoint. When either fails (the repository removed or rewritten, or GitHub serving the archive with other
bytes, as it did in January 2023), the same input is taken from a release of the fork made for that commit of the
scripts, libsmb2-inputs-<first 7 characters of the commit>: a git bundle of the scripts,
libsmb2-scripts-<commit>.bundle, and the archive of libsmb2, libsmb2-<libsmb2 commit>.tar.gz. The fallback goes
through the same checks: the commit id of the scripts, which git verifies every fetched object against, and the
SHA-256 the scripts pin for libsmb2. So the archive written is the same whichever source gave each input.

  pack_sources.py OUT [--libsmb2-archive FILE] [--scripts-repository URL] [--scripts-commit SHA]
                  [--libsmb2-url TEMPLATE] [--fallback LOCATION]

--libsmb2-archive takes the archive of libsmb2 from a file instead of downloading it (still checked by its SHA-256,
no fallback); --scripts-repository and --scripts-commit name other scripts (the tests use a local repository);
--libsmb2-url is the upstream address of the archive of libsmb2, {commit} standing for its commit; --fallback is the
release (or a local folder) holding the two fallback files, an empty value for none. Needs git and, without
--libsmb2-archive, the network. Exit codes: 0 written, 1 a check failed (commit, SHA-256, tree), 2 bad arguments.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import os
import pathlib
import re
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
SCRIPTS_REPOSITORY = 'https://github.com/ales-drnz/libsmb2-scripts.git'
# libsmb2-scripts 0.1.3 (2026-09-19), the scripts of dart_smb2's release libsmb2-r8
SCRIPTS_COMMIT = 'f0688e739ec56842981e455cf8eba4a34e7682e7'
LIBSMB2_URL = 'https://github.com/sahlberg/libsmb2/archive/{commit}.tar.gz'
# The two inputs again, under the fork's control, tried after the upstream source of each fails: a release of
# freeKC/Immuch360 per commit of the scripts, which only the owner changes
FALLBACK = 'https://github.com/freeKC/Immuch360/releases/download/libsmb2-inputs-{short}'
FALLBACK_SCRIPTS = 'libsmb2-scripts-{commit}.bundle'
FALLBACK_LIBSMB2 = 'libsmb2-{commit}.tar.gz'
TOP = 'immuch360-libsmb2-sources'


class Problem(Exception):
    pass


def git(cwd: pathlib.Path, *arguments: str, data: bytes | None = None) -> bytes:
    # A repository that is gone makes GitHub ask for a login: a failure here, never a prompt
    environment = dict(os.environ, GIT_TERMINAL_PROMPT='0')
    result = subprocess.run(['git', *arguments], cwd=cwd, input=data, capture_output=True, env=environment)
    if result.returncode != 0:
        raise Problem(f'git {" ".join(arguments)}: {result.stderr.decode(errors="replace").strip()}')
    return result.stdout


def fetch_commit(work: pathlib.Path, source: str, commit: str, shallow: bool) -> None:
    git(work, 'fetch', '-q', *(['--depth', '1'] if shallow else []), source, commit)
    fetched = git(work, 'rev-parse', 'FETCH_HEAD').decode().strip()
    if fetched != commit:
        raise Problem(f'{source} gave {fetched}, not the pinned commit {commit}')


def fetch_scripts(work: pathlib.Path, repository: str, commit: str, fallback: str) -> None:
    """Fetches [commit] of the scripts into a new repository, work/scripts, from [repository], else from the bundle of
    [fallback] (none when empty)"""
    repo = work / 'scripts'
    repo.mkdir()
    git(repo, 'init', '-q')
    try:
        fetch_commit(repo, repository, commit, shallow=True)
        return
    except Problem as problem:
        if not fallback:
            raise
        print(f'  {problem}', file=sys.stderr)
    location = f'{fallback}/{FALLBACK_SCRIPTS.format(commit=commit)}'
    print(f'  the scripts from the fallback {location}')
    bundle = work / 'scripts.bundle'
    bundle.write_bytes(fetch(location))
    # A bundle has no shallow fetch; git still checks every object it takes against the commit id
    fetch_commit(repo, str(bundle), commit, shallow=False)


def scripts_tree(repository: str, commit: str, work: pathlib.Path,
                 fallback: str = '') -> tuple[dict[str, tuple[int, bytes]], int]:
    """The files of the scripts at [commit] (path: (mode, content)), read from git's objects so that no checkout
    setting (line ends) changes them, and the commit date"""
    fetch_scripts(work, repository, commit, fallback)
    work = work / 'scripts'
    entries = []
    for line in git(work, 'ls-tree', '-r', '-z', '--full-tree', commit).split(b'\0'):
        if not line:
            continue
        meta, path = line.split(b'\t', 1)
        mode, kind, sha = meta.decode().split()
        if kind != 'blob' or mode not in ('100644', '100755'):
            raise Problem(f'{path.decode()}: a {kind} of mode {mode}, not a plain file')
        entries.append((path.decode(), int(mode, 8) & 0o111, sha))
    batch = git(work, 'cat-file', '--batch', data=''.join(f'{sha}\n' for _, _, sha in entries).encode())
    files: dict[str, tuple[int, bytes]] = {}
    offset = 0
    for path, executable, sha in entries:
        end = batch.index(b'\n', offset)
        header = batch[offset:end].decode().split()
        if header[0] != sha or header[1] != 'blob':
            raise Problem(f'git cat-file: {header} for {path}')
        size = int(header[2])
        files[path] = (0o755 if executable else 0o644, batch[end + 1:end + 1 + size])
        offset = end + 1 + size + 1
    date = int(git(work, 'show', '-s', '--format=%ct', commit).decode().strip())
    return files, date


def pinned(versions: str, name: str) -> str:
    match = re.search(rf'^export {name}="\$\{{{name}:-([^}}]*)\}}"$', versions, re.MULTILINE)
    if not match:
        raise Problem(f'no {name} in scripts/shared/_versions.sh')
    return match.group(1)


def fetch(location: str) -> bytes:
    """The bytes at [location], an address (downloaded) or a path on this machine"""
    if re.match(r'^[a-z][a-z0-9+.-]*://', location):
        return download(location)
    try:
        return pathlib.Path(location).read_bytes()
    except OSError as error:
        raise Problem(f'{location}: {error.strerror or error}') from error


def libsmb2_input(upstream: str, fallback: str, commit: str, sha256: str) -> bytes:
    """The archive of libsmb2 at [commit] with the SHA-256 the scripts pin: from [upstream], else from [fallback]
    (none when empty)"""
    locations = [upstream.format(commit=commit)]
    if fallback:
        locations.append(f'{fallback}/{FALLBACK_LIBSMB2.format(commit=commit)}')
    for index, location in enumerate(locations):
        if index:
            print(f'  the archive of libsmb2 from the fallback {location}')
        try:
            data = fetch(location)
        except Problem as problem:
            print(f'  {problem}', file=sys.stderr)
            continue
        digest = hashlib.sha256(data).hexdigest()
        if digest == sha256:
            return data
        print(f'  {location}: SHA-256 {digest}, not the one the scripts pin', file=sys.stderr)
    raise Problem(f'no archive of libsmb2 with the SHA-256 the scripts pin, {sha256}, at {" or ".join(locations)}')


def download(url: str) -> bytes:
    for attempt in range(1, 4):
        try:
            request = urllib.request.Request(url, headers={'User-Agent': 'Immuch360 pack_sources.py'})
            with urllib.request.urlopen(request, timeout=120) as response:
                return response.read()
        except OSError as error:
            if attempt == 3:
                raise Problem(f'{url}: {error}') from error
            print(f'  {url}: {error}, again in {5 * attempt} s', file=sys.stderr)
            time.sleep(5 * attempt)
    raise AssertionError


def readme(scripts: str, scripts_commit: str, libsmb2_commit: str, libsmb2_sha256: str) -> str:
    return f"""The corresponding source of libsmb2 in Immuch360

libsmb2 (https://github.com/sahlberg/libsmb2, GNU Lesser General Public License version 2.1 or later) is the library
of the SMB shares of Immuch360, loaded by the dart_smb2 package. Every libsmb2 binary of Immuch360 is built from the
sources in this archive:

{scripts}/
    libsmb2-scripts (https://github.com/ales-drnz/libsmb2-scripts, BSD 3-Clause) at commit {scripts_commit}:
    the patches it applies to libsmb2 (patches/libsmb2), its configuration header (scripts/shared/config/config.h),
    the wrapper built into the library (src/smb2_wrapper.c) and the build script of each system (scripts/). They
    built the binaries of release libsmb2-r8 of https://github.com/ales-drnz/dart_smb2, which Immuch360 carries on
    Android, iOS, macOS and Windows.

{scripts}/sources/cache/libsmb2-{libsmb2_commit}.tar.gz
    libsmb2 at commit {libsmb2_commit}, as GitHub serves it, where the scripts look for it before they
    download it. Its SHA-256, which the scripts check: {libsmb2_sha256}

build_linux.sh
    the script of Immuch360 (.github/desktop/libsmb2/build_linux.sh) that builds lib/libsmb2.so of the Linux packages
    from this archive, on Ubuntu 22.04 so that the library runs with glibc 2.25 or later.

To build libsmb2 again without the network, run in {scripts}:

    ARCHS=x86_64 bash scripts/build_libsmb2_linux.sh

which writes release_builds/libsmb2_linux-x86_64.so (needs gcc and python3). The scripts of the other systems are
next to it (Android with the NDK, Windows with llvm-mingw, iOS and macOS on a Mac); the README.md of the scripts says
what each one needs.

This archive is made by .github/desktop/libsmb2/pack_sources.py of https://github.com/freeKC/Immuch360, the same way
each time, so the same commits give the same file.
"""


def entries_of(files: dict[str, tuple[int, bytes]]) -> list[tuple[str, int, bytes | None]]:
    """Every file and folder of the archive under TOP, a folder before what it holds, names in order"""
    folders = {TOP}
    for path in files:
        parts = path.split('/')
        for depth in range(1, len(parts)):
            folders.add('/'.join(parts[:depth]))
    items: list[tuple[str, int, bytes | None]] = [(folder, 0o755, None) for folder in folders]
    items += [(path, mode, content) for path, (mode, content) in files.items()]
    return sorted(items, key=lambda item: item[0].split('/'))


def archive(files: dict[str, tuple[int, bytes]], date: int) -> bytes:
    tar_bytes = io.BytesIO()
    with tarfile.open(fileobj=tar_bytes, mode='w', format=tarfile.GNU_FORMAT) as tar:
        for name, mode, content in entries_of(files):
            info = tarfile.TarInfo(name)
            info.mode = mode
            info.mtime = date
            info.uid = info.gid = 0
            info.uname = info.gname = ''
            if content is None:
                info.type = tarfile.DIRTYPE
                tar.addfile(info)
            else:
                info.size = len(content)
                tar.addfile(info, io.BytesIO(content))
    packed = io.BytesIO()
    # Through GzipFile, which writes the header itself: no name, date 0 and the same "unknown" system on every host
    with gzip.GzipFile(filename='', mode='wb', compresslevel=9, fileobj=packed, mtime=0) as out:
        out.write(tar_bytes.getvalue())
    return packed.getvalue()


def pack(out: pathlib.Path, repository: str, commit: str, libsmb2_archive: pathlib.Path | None,
         libsmb2_url: str = LIBSMB2_URL, fallback: str | None = None) -> str:
    if fallback is None:
        fallback = FALLBACK.format(short=commit[:7])
    fallback = fallback.rstrip('/')
    with tempfile.TemporaryDirectory(prefix='immuch360-libsmb2-') as temporary:
        print(f'== libsmb2-scripts at {commit}')
        tree, date = scripts_tree(repository, commit, pathlib.Path(temporary), fallback)
    if 'scripts/shared/_versions.sh' not in tree:
        raise Problem('no scripts/shared/_versions.sh in the scripts')
    versions = tree['scripts/shared/_versions.sh'][1].decode()
    libsmb2_commit = pinned(versions, 'LIBSMB2_COMMIT')
    libsmb2_sha256 = pinned(versions, 'LIBSMB2_TARBALL_SHA256')
    if not re.fullmatch(r'[0-9a-f]{40}', libsmb2_commit) or not re.fullmatch(r'[0-9a-f]{64}', libsmb2_sha256):
        raise Problem(f'the scripts pin no libsmb2 commit and SHA-256: {libsmb2_commit} {libsmb2_sha256}')
    print(f'== libsmb2 at {libsmb2_commit}')
    if libsmb2_archive is not None:
        libsmb2 = libsmb2_archive.read_bytes()
        digest = hashlib.sha256(libsmb2).hexdigest()
        if digest != libsmb2_sha256:
            raise Problem(f'the archive of libsmb2 has the SHA-256 {digest}, the scripts pin {libsmb2_sha256}')
    else:
        libsmb2 = libsmb2_input(libsmb2_url, fallback, libsmb2_commit, libsmb2_sha256)
    print(f'  SHA-256 {libsmb2_sha256}, as the scripts pin it')

    scripts = f'libsmb2-scripts-{commit}'
    files = {f'{TOP}/{scripts}/{path}': entry for path, entry in tree.items()}
    files[f'{TOP}/{scripts}/sources/cache/libsmb2-{libsmb2_commit}.tar.gz'] = (0o644, libsmb2)
    files[f'{TOP}/build_linux.sh'] = (0o755, (HERE / 'build_linux.sh').read_bytes())
    files[f'{TOP}/README.txt'] = (0o644, readme(scripts, commit, libsmb2_commit, libsmb2_sha256).encode())
    data = archive(files, date)

    out.parent.mkdir(parents=True, exist_ok=True)
    partial = out.with_name(out.name + '.partial')
    partial.write_bytes(data)
    os.replace(partial, out)
    digest = hashlib.sha256(data).hexdigest()
    print(f'== {out} ({len(data)} bytes, {len(files)} files, SHA-256 {digest})')
    return digest


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('out', type=pathlib.Path)
    parser.add_argument('--libsmb2-archive', type=pathlib.Path)
    parser.add_argument('--scripts-repository', default=SCRIPTS_REPOSITORY)
    parser.add_argument('--scripts-commit', default=SCRIPTS_COMMIT)
    parser.add_argument('--libsmb2-url', default=LIBSMB2_URL)
    parser.add_argument('--fallback', help='default: ' + FALLBACK)
    arguments = parser.parse_args(argv)
    if not re.fullmatch(r'[0-9a-f]{40}', arguments.scripts_commit):
        print(f'--scripts-commit: not a full commit id: {arguments.scripts_commit}', file=sys.stderr)
        return 2
    if arguments.libsmb2_archive is not None and not arguments.libsmb2_archive.is_file():
        print(f'--libsmb2-archive: no file {arguments.libsmb2_archive}', file=sys.stderr)
        return 2
    try:
        pack(arguments.out, arguments.scripts_repository, arguments.scripts_commit, arguments.libsmb2_archive,
             arguments.libsmb2_url, arguments.fallback)
    except Problem as problem:
        print(f'pack_sources.py: {problem}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
