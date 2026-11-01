#!/usr/bin/env python3
"""Brush for Immuch360 Desktop: the sources, the build, the checks and the archive of the brush jobs.

The splat scenes (plan of 01/11/2026, lot SP2) are trained by brush_app of Brush (Apache-2.0), run as a child process.
Its binaries come from our CI only: the jobs brush-windows and brush-linux of immuch360-desktop.yml build the tag of
brush.lock.json next to this script, at its commit, with the toolchain of Brush's own CI at that tag, `cargo build
--locked` (the Cargo.lock of the tag, untouched), after the patches of licenses/brush/patches. The patch makes brush_app
a trainer without window, network client, rerun or the LPIPS weights, whose provenance is not written; these checks
hold it to that, and fail the job otherwise. The archive is Immuch360-AI-brush-<id>-<system>.zip: its name does not
start with Immuch360-Desktop-, so no release of the app ever attaches it.

  brush_build.py lock --system SYSTEM [--github-output]
      the id of the lock, the artifact, the target, the toolchain and the licence tools of SYSTEM (windows-x64 or
      linux-x64)
  brush_build.py sources --dir DIR [--patches DIR] [--weights-out FILE]
      Brush at the commit of the lock, the tag checked to be still there; its LICENSE, Cargo.lock and LPIPS weights
      checked by their SHA-256 (the probes of the lock read in the weights); the weights moved out of the tree (to FILE,
      or deleted), so that a build that would still compile them fails; then the patches, which must leave Cargo.lock
      as it is
  brush_build.py tools --system SYSTEM --dir DIR [--github-output]
      cargo-deny and cargo-about of the lock, their archives checked by SHA-256
  brush_build.py build --system SYSTEM --source DIR
      cargo fetch --locked of every crate of Cargo.lock (cargo about reads the metadata of the whole workspace, offline),
      then cargo build --locked of brush_app with the profile and arguments of the lock, under its toolchain
  brush_build.py graph --system SYSTEM (--source DIR | --tree FILE)
      the crates compiled into brush_app (cargo tree, normal dependencies, for the target of SYSTEM): none may be the
      LPIPS crate, rerun, a network client or server, TLS, a window or a file dialog
  brush_build.py deny --system SYSTEM --source DIR --cargo-deny FILE
      cargo deny check licenses bans sources with licenses/brush/deny.toml, our list (not Brush's)
  brush_build.py about --system SYSTEM --source DIR --cargo-about FILE --out FILE
      THIRD-PARTY.md by cargo about (licenses/brush/about.toml and about.hbs, offline), with the NOTICE files of the
      code compiled in: next to each crate, at the root of each git repository a crate comes from (cargo checks those
      out whole), at the root of Brush
  brush_build.py lpips --binary FILE
      none of the probes of the LPIPS weights (64 bytes each, the first 64 bytes of the file among them) in FILE
  brush_build.py help --output FILE --version-output FILE [--fixture FILE]
      brush_app --help compared with mobile/test/fixtures/ai_immersive/brush_help.txt, the text the arguments of the
      runner are frozen by (the name of the program apart), and brush_app --version with the version line of the lock
  brush_build.py pack --system SYSTEM --source DIR --bin FILE --third-party FILE --out DIR [--launcher FILE]
                      [--crt-dir DIR] [--system-dir DIR]
      the archive in DIR: brush_app (checked again for the LPIPS weights), on Windows the Visual C++ runtime DLLs it
      imports (every import checked as windows_bundle.py does), on Linux the launcher immuch360-run and the libraries
      every distribution has; licenses/ (README.md, Brush's LICENSE compared with the sources built, THIRD-PARTY.md,
      the patches) and BUILD-INFO.txt. Sorted names, fixed dates: the same files give the same bytes.

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
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]
LOCK = HERE / 'brush.lock.json'
LICENCES = ROOT / 'licenses' / 'brush'
FIXTURE = ROOT / 'mobile' / 'test' / 'fixtures' / 'ai_immersive' / 'brush_help.txt'
SYSTEMS = ('windows-x64', 'linux-x64')
TARGETS = {'windows-x64': 'x86_64-pc-windows-msvc', 'linux-x64': 'x86_64-unknown-linux-gnu'}
ARTIFACT_PREFIX = 'Immuch360-AI-brush-'
TOOLS = ('cargo-deny', 'cargo-about')
PROBE_SIZE = 64
# The files of licenses/brush that go into the archive; the configurations of cargo deny and cargo about stay here
SHIPPED_LICENCES = ('README.md', 'brush-LICENSE.txt')
# Crates brush_app must not hold, by name (and every crate of rerun, re_*): the LPIPS weights, rerun, a network client
# or server, TLS, a window or a file dialog. licenses/brush/deny.toml bans the same.
BANNED = {
    'lpips': 'the LPIPS weights',
    'rerun': 'rerun',
    'reqwest': 'an HTTP client',
    'hyper': 'HTTP',
    'h2': 'HTTP/2',
    'ureq': 'an HTTP client',
    'isahc': 'an HTTP client',
    'curl': 'an HTTP client',
    'tonic': 'gRPC',
    'rustls': 'TLS',
    'native-tls': 'TLS',
    'openssl': 'TLS',
    'openssl-sys': 'TLS',
    'egui': 'the viewer',
    'eframe': 'the viewer',
    'epaint_default_fonts': 'the fonts of egui (OFL, Ubuntu Font Licence)',
    'winit': 'a window',
    'rfd': 'a file dialog',
    'rrfd': 'a file dialog',
}


class Failure(Exception):
    pass


def is_sha256(value) -> bool:
    return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value) is not None


def load_lock(path: pathlib.Path = LOCK) -> dict:
    lock = json.loads(path.read_text(encoding='utf-8'))
    for key in ('id', 'version', 'brush', 'rust', 'cargo', 'patches', 'lpips', 'tools'):
        if key not in lock:
            raise Failure(f'{path.name}: no {key}')
    brush = lock['brush']
    if not re.fullmatch(r'[0-9a-f]{40}', brush.get('commit', '')):
        raise Failure(f'{path.name}: the commit of Brush is not a full commit')
    if not re.fullmatch(r'[0-9a-f]{7}-\d+', lock['id']):
        raise Failure(f'{path.name}: the id {lock["id"]!r} is not <short commit>-<build>')
    if not brush['commit'].startswith(lock['id'].split('-')[0]):
        raise Failure(f'{path.name}: the id {lock["id"]} does not start with the commit of Brush')
    for key in ('licenceSha256', 'cargoLockSha256'):
        if not is_sha256(brush.get(key)):
            raise Failure(f'{path.name}: no {key} of Brush')
    if not brush.get('tag') or not brush.get('versionLine') or not lock['rust'].get('toolchain'):
        raise Failure(f'{path.name}: no tag, version line or toolchain')
    lpips = lock['lpips']
    if not is_sha256(lpips.get('sha256')) or not isinstance(lpips.get('size'), int) or not lpips.get('path'):
        raise Failure(f'{path.name}: the LPIPS weights have no path, size or SHA-256')
    probes = lpips.get('probes') or {}
    if '0' not in probes:
        raise Failure(f'{path.name}: no probe of the first {PROBE_SIZE} bytes of the LPIPS weights')
    for at, hexa in probes.items():
        if not re.fullmatch(r'\d+', at) or not re.fullmatch(f'[0-9a-f]{{{2 * PROBE_SIZE}}}', hexa or ''):
            raise Failure(f'{path.name}: the probe {at!r} of the LPIPS weights is not {PROBE_SIZE} bytes in hex')
    for name in TOOLS:
        tool = lock['tools'].get(name) or {}
        for system in SYSTEMS:
            entry = tool.get(system) or {}
            if not entry.get('url', '').startswith('https://') or not is_sha256(entry.get('sha256')):
                raise Failure(f'{path.name}: {name} for {system} has no https address or SHA-256')
    return lock


def artifact_name(lock: dict, system: str) -> str:
    return f'{ARTIFACT_PREFIX}{lock["id"]}-{system}.zip'


def probes_of(lock: dict) -> dict:
    """The probes of the LPIPS weights, {offset: bytes}"""
    return {int(at): bytes.fromhex(hexa) for at, hexa in lock['lpips']['probes'].items()}


def run(command: list, cwd: pathlib.Path | None = None, env: dict | None = None):
    print('$ ' + ' '.join(str(part) for part in command), flush=True)
    subprocess.run([str(part) for part in command], cwd=cwd, check=True, env=env)


def output(command: list, cwd: pathlib.Path | None = None, env: dict | None = None) -> str:
    """The standard output of a command, read as UTF-8 whatever the code page of the system (cargo writes UTF-8)"""
    return subprocess.run([str(part) for part in command], cwd=cwd, check=True, capture_output=True,
                          encoding='utf-8', errors='replace', env=env).stdout.strip()


def cargo() -> str:
    """cargo as the PATH gives it (the proxy of rustup, cargo.exe on Windows)"""
    return shutil.which('cargo') or 'cargo'


def cargo_env(lock: dict) -> dict:
    """The environment of the cargo commands: the toolchain of the lock (rustup reads RUSTUP_TOOLCHAIN)"""
    return {**os.environ, 'RUSTUP_TOOLCHAIN': lock['rust']['toolchain']}


def write_outputs(values: dict):
    for key, value in values.items():
        print(f'{key}={value}')
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as stream:
            for key, value in values.items():
                stream.write(f'{key}={value}\n')


# --- lock ------------------------------------------------------------------------------------------------------------

def command_lock(args) -> int:
    lock = load_lock(args.lock)
    values = {
        'id': lock['id'],
        'version': lock['version'],
        'artifact': artifact_name(lock, args.system),
        'target': TARGETS[args.system],
        'commit': lock['brush']['commit'],
        'tag': lock['brush']['tag'],
        'toolchain': lock['rust']['toolchain'],
    }
    if args.github_output:
        write_outputs(values)
    else:
        for key, value in values.items():
            print(f'{key}={value}')
    return 0


# --- sources ---------------------------------------------------------------------------------------------------------

def sha256_of(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def remove_tree(path: pathlib.Path):
    """shutil.rmtree, which also removes the read-only files git leaves on Windows (.git/objects)"""
    def writable(function, name, _):
        os.chmod(name, stat.S_IWRITE)
        function(name)

    if sys.version_info >= (3, 12):
        shutil.rmtree(path, onexc=writable)
    else:
        shutil.rmtree(path, onerror=writable)


def tag_commit(repository: str, tag: str) -> str | None:
    """The commit the tag names in the repository (peeled when the tag is annotated), None without such a tag"""
    lines = output(['git', 'ls-remote', repository, f'refs/tags/{tag}']).splitlines()
    found = dict(reversed(line.split('\t', 1)) for line in lines if '\t' in line)
    return found.get(f'refs/tags/{tag}^{{}}') or found.get(f'refs/tags/{tag}')


def command_sources(args) -> int:
    lock = load_lock(args.lock)
    brush = lock['brush']
    source = args.dir
    if source.exists():
        remove_tree(source)
    named = tag_commit(brush['repository'], brush['tag'])
    if named != brush['commit']:
        raise Failure(f'{brush["repository"]}: the tag {brush["tag"]} names {named or "nothing"}, the lock says '
                      f'{brush["commit"]}')
    source.mkdir(parents=True)
    # The files as the repository holds them, whatever core.autocrlf the runner has (Windows images set it): the
    # checksums of the lock and the patches are those of the LF files
    git = ['git', '-c', 'core.autocrlf=false', '-c', 'core.eol=lf', '-C', source]
    run(['git', 'init', '-q', source])
    run([*git, 'fetch', '-q', '--depth', '1', brush['repository'], brush['commit']])
    run([*git, 'checkout', '-q', '--detach', 'FETCH_HEAD'])
    found = output([*git, 'rev-parse', 'HEAD'])
    if found != brush['commit']:
        raise Failure(f'{brush["repository"]}: {found} checked out, the lock says {brush["commit"]}')
    if sha256_of(source / 'LICENSE') != brush['licenceSha256']:
        raise Failure(f'the LICENSE of Brush {brush["tag"]} is not the one of the lock (licenceSha256)')
    if sha256_of(source / 'Cargo.lock') != brush['cargoLockSha256']:
        raise Failure(f'the Cargo.lock of Brush {brush["tag"]} is not the one of the lock (cargoLockSha256)')

    lpips = lock['lpips']
    weights_path = source / lpips['path']
    weights = weights_path.read_bytes()
    if len(weights) != lpips['size'] or hashlib.sha256(weights).hexdigest() != lpips['sha256']:
        raise Failure(f'the LPIPS weights {lpips["path"]} are not those of the lock ({len(weights)} bytes)')
    for at, probe in probes_of(lock).items():
        if weights[at:at + PROBE_SIZE] != probe:
            raise Failure(f'the probe at {at} is not in the LPIPS weights {lpips["path"]}')
    if args.weights_out:
        args.weights_out.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(weights_path), args.weights_out)
    else:
        weights_path.unlink()
    print(f'LPIPS weights {lpips["path"]} ({len(weights)} bytes, SHA-256 {lpips["sha256"]}) moved out of the sources')

    for name in lock['patches']:
        patch = args.patches / name
        if not patch.is_file():
            raise Failure(f'no patch {patch}')
        # The patch with LF line ends, as written, even when the checkout of this repository made them CRLF
        text = patch.read_bytes().replace(b'\r\n', b'\n')
        applied = source.parent / f'{source.name}-{name}'
        applied.write_bytes(text)
        run([*git, 'apply', '--check', applied])
        run([*git, 'apply', applied])
        applied.unlink()
        print(f'patch {name}: SHA-256 {hashlib.sha256(text).hexdigest()} (LF)')
    if sha256_of(source / 'Cargo.lock') != brush['cargoLockSha256']:
        raise Failure('the patches changed Cargo.lock: cargo build --locked would not build the locked graph')
    print(f'Brush {brush["tag"]} ({brush["commit"]}) patched in {source}')
    return 0


# --- tools -----------------------------------------------------------------------------------------------------------

def command_tools(args) -> int:
    lock = load_lock(args.lock)
    args.dir.mkdir(parents=True, exist_ok=True)
    values = {}
    for name in TOOLS:
        entry = lock['tools'][name][args.system]
        archive = args.dir / entry['url'].rsplit('/', 1)[1]
        print(f'{name} {lock["tools"][name].get("version", "")}: {entry["url"]}', flush=True)
        with urllib.request.urlopen(entry['url'], timeout=120) as response, open(archive, 'wb') as stream:
            shutil.copyfileobj(response, stream)
        digest = sha256_of(archive)
        if digest != entry['sha256']:
            raise Failure(f'{archive.name}: SHA-256 {digest}, the lock says {entry["sha256"]}')
        program = name + ('.exe' if args.system == 'windows-x64' else '')
        with tarfile.open(archive) as bundle:
            member = next((m for m in bundle.getmembers() if m.isfile() and pathlib.PurePosixPath(m.name).name == program),
                          None)
            if member is None:
                raise Failure(f'{archive.name} holds no {program}')
            target = args.dir / program
            with bundle.extractfile(member) as source, open(target, 'wb') as stream:
                shutil.copyfileobj(source, stream)
        target.chmod(0o755)
        values[name.replace('-', '_')] = str(target)
    write_outputs(values)
    return 0


# --- build -----------------------------------------------------------------------------------------------------------

def cargo_selection(lock: dict) -> list:
    return ['-p', lock['cargo']['package'], *lock['cargo']['arguments']]


def command_build(args) -> int:
    lock = load_lock(args.lock)
    env = cargo_env(lock)
    run(['rustc', '--version'], env=env)
    run([cargo(), '--version'], env=env)
    run([cargo(), 'fetch', '--locked'], cwd=args.source, env=env)
    run([cargo(), 'build', '--locked', '--profile', lock['cargo']['profile'], *cargo_selection(lock), '--bin',
         lock['cargo']['bin'], '--target', TARGETS[args.system]], cwd=args.source, env=env)
    program = (args.source / 'target' / TARGETS[args.system] / lock['cargo']['profile']
               / (lock['cargo']['bin'] + ('.exe' if args.system == 'windows-x64' else '')))
    if not program.is_file():
        raise Failure(f'no {program}')
    write_outputs({'program': str(program)})
    return 0


# --- graph -----------------------------------------------------------------------------------------------------------

def crates_of(tree: str) -> list:
    """The crates of a cargo tree --prefix none listing, each once: [(name, rest of the line)]"""
    crates = {}
    for line in tree.splitlines():
        line = line.replace(' (*)', '').strip()
        if not line or line.startswith('['):
            continue
        name, _, rest = line.partition(' ')
        crates.setdefault((name, rest), None)
    return list(crates)


def banned_in(crates: list) -> list:
    found = []
    for name, rest in crates:
        reason = BANNED.get(name) or ('rerun' if name.startswith('re_') else None)
        if reason:
            found.append(f'{name} {rest}: {reason}')
    return found


def command_graph(args) -> int:
    lock = load_lock(args.lock)
    if args.tree:
        tree = args.tree.read_text(encoding='utf-8')
    else:
        tree = output([cargo(), 'tree', '--locked', *cargo_selection(lock), '--target', TARGETS[args.system], '-e',
                       'normal', '--prefix', 'none'], cwd=args.source, env=cargo_env(lock))
    crates = crates_of(tree)
    found = banned_in(crates)
    if found:
        for line in found:
            print(f'::error::brush_app holds {line}')
        return 1
    print(f'brush_app for {TARGETS[args.system]}: {len(crates)} crates, none of '
          f'{", ".join(sorted(BANNED))} nor re_*')
    return 0


# --- deny ------------------------------------------------------------------------------------------------------------

def command_deny(args) -> int:
    lock = load_lock(args.lock)
    manifest = args.source / 'crates' / lock['cargo']['package'] / 'Cargo.toml'
    command = [args.cargo_deny, '--color', 'never', '--manifest-path', manifest, *lock['cargo']['arguments'],
               '--exclude-dev', '--target', TARGETS[args.system], '--locked', '--config', LICENCES / 'deny.toml',
               'check', '--show-stats', 'licenses', 'bans', 'sources']
    print('$ ' + ' '.join(str(part) for part in command), flush=True)
    result = subprocess.run([str(part) for part in command], env=cargo_env(lock))
    if result.returncode != 0:
        print(f'::error::cargo deny refused the graph of brush_app for {TARGETS[args.system]}')
        return 1
    return 0


# --- about -----------------------------------------------------------------------------------------------------------

def tree_source(rest: str) -> tuple:
    """The version and the source of a line of cargo tree after the name of the crate: None for crates.io, the address
    and short commit of a git dependency (https://github.com/tracel-ai/burn#dd2a0290), the folder of a path one"""
    version, _, tail = rest.partition(' ')
    sources = [group for group in re.findall(r'\(([^()]*)\)', tail) if group not in ('proc-macro', '*')]
    return version.lstrip('v'), (sources[0] if sources else None)


def same_folder(one, other) -> bool:
    return os.path.normcase(os.path.normpath(str(one))) == os.path.normcase(os.path.normpath(str(other)))


def named_by(package: dict, source: str | None) -> bool:
    """Whether a package of cargo metadata is the one cargo tree names with this source"""
    origin = package.get('source')
    if source is None:
        return bool(origin) and origin.startswith('registry+')
    if origin is None:
        return same_folder(pathlib.Path(package['manifest_path']).parent, source)
    if origin.startswith('git+'):
        address, _, commit = origin[len('git+'):].partition('#')
        named, _, short = source.partition('#')
        return address == named and bool(short) and commit.startswith(short)
    return False


def compiled_packages(tree: str, metadata: dict) -> list:
    """The packages of cargo metadata that a cargo tree listing names, each once, by their id: two sources may give a
    crate of the same name and version (cubecl-quant 0.7.0 of the two copies of cubecl that Cargo.lock of Brush pins)"""
    by_id = {package['id']: package for package in metadata['packages']}
    by_name = {}
    for package in metadata['packages']:
        by_name.setdefault((package['name'], package['version']), []).append(package['id'])
    found = {}
    for name, rest in crates_of(tree):
        version, source = tree_source(rest)
        ids = by_name.get((name, version), [])
        if len(ids) > 1:
            ids = [package_id for package_id in ids if named_by(by_id[package_id], source)]
        if len(ids) != 1:
            raise Failure(f'{name} {rest}: {len(ids)} packages of cargo metadata are this crate')
        found.setdefault(ids[0], by_id[ids[0]])
    return list(found.values())


def copy_root(package: dict) -> pathlib.Path:
    """The root of the copy of the repository a git dependency comes from: cargo checks the whole repository out under
    CARGO_HOME/git/checkouts/<name>-<hash>/<short commit>/, marked by .cargo-ok, and the crate is a folder of it"""
    folder = pathlib.Path(package['manifest_path']).parent
    for candidate in (folder, *folder.parents):
        if candidate.name == 'checkouts':
            break
        if (candidate / '.cargo-ok').exists() or (candidate / '.git').exists():
            return candidate
    raise Failure(f'{package["name"]} {package["version"]} ({package["source"]}): no root of its git copy (.cargo-ok '
                  f'or .git) above {folder}')


def notice_files(folder: pathlib.Path) -> list:
    """The NOTICE files of a folder (NOTICE, NOTICE.md, NOTICES.md...)"""
    if not folder.is_dir():
        return []
    return sorted(path for path in folder.iterdir() if path.is_file() and path.name.upper().startswith('NOTICE'))


def notices_of(packages: list, metadata: dict, brush: dict) -> list:
    """The NOTICE files of the code compiled into brush_app (Apache-2.0, section 4 d), each once: those next to the
    manifest of each crate, those at the root of each git repository a crate comes from (one copy per repository and
    commit, whose crates are folders of it), and those at the root of Brush"""
    places = {}

    def add(folder: pathlib.Path, title: str, crate: str):
        key = os.path.normcase(os.path.normpath(str(folder)))
        places.setdefault(key, (folder, title, set()))[2].add(crate)

    workspace = pathlib.Path(metadata['workspace_root'])
    for package in packages:
        crate = f'{package["name"]} {package["version"]}'
        folder = pathlib.Path(package['manifest_path']).parent
        origin = package.get('source') or ''
        if origin.startswith('git+'):
            address, _, commit = origin[len('git+'):].partition('#')
            root = copy_root(package)
            add(root, f'{address} at {commit}', crate)
            if not same_folder(root, folder):
                add(folder, crate, crate)
        elif not origin:
            add(workspace, f'Brush {brush["tag"]} ({brush["repository"]} at {brush["commit"]})', crate)
            if not same_folder(workspace, folder):
                add(folder, crate, crate)
        else:
            add(folder, crate, crate)
    sections = []
    for folder, title, crates in sorted(places.values(), key=lambda place: place[1]):
        for path in notice_files(folder):
            text = path.read_text(encoding='utf-8', errors='replace').replace('\r\n', '\n').strip()
            sections.append(f'### {title}, {path.name}\n\nFor {", ".join(sorted(crates))}.\n\n````text\n{text}\n````\n')
    return sections


def command_about(args) -> int:
    lock = load_lock(args.lock)
    env = cargo_env(lock)
    manifest = args.source / 'crates' / lock['cargo']['package'] / 'Cargo.toml'
    generated = args.out.with_suffix('.generated.md')
    args.out.parent.mkdir(parents=True, exist_ok=True)
    run([args.cargo_about, 'generate', '--manifest-path', manifest, *lock['cargo']['arguments'], '--target',
         TARGETS[args.system], '--frozen', '--fail', '-c', LICENCES / 'about.toml', '-o', generated,
         LICENCES / 'about.hbs'], env=env)
    # The crates compiled in, matched with their packages in cargo metadata, and their NOTICE files
    tree = output([cargo(), 'tree', '--frozen', *cargo_selection(lock), '--target', TARGETS[args.system], '-e',
                   'normal', '--prefix', 'none'], cwd=args.source, env=env)
    metadata = json.loads(output([cargo(), 'metadata', '--frozen', '--format-version', '1'], cwd=args.source,
                                 env=env))
    brush = lock['brush']
    notices = notices_of(compiled_packages(tree, metadata), metadata, brush)
    head = (f'Brush {brush["tag"]} ({brush["commit"]}), {brush["repository"]}, lock {lock["id"]}, '
            f'{TARGETS[args.system]}, toolchain {lock["rust"]["toolchain"]}\n\n')
    text = generated.read_text(encoding='utf-8').replace('\r\n', '\n')
    text = text.replace('\n\n', '\n\n' + head, 1)
    text += '\n## Notices\n\n' + ('\n'.join(notices) if notices else 'No crate compiled into brush_app carries a '
                                  'NOTICE file.\n')
    args.out.write_bytes(text.encode('utf-8'))
    generated.unlink()
    print(f'{args.out}: {len(text.encode())} bytes, {len(notices)} notices')
    return 0


# --- lpips -----------------------------------------------------------------------------------------------------------

def lpips_findings(lock: dict, data: bytes) -> list:
    found = []
    for at, probe in sorted(probes_of(lock).items()):
        where = data.find(probe)
        if where >= 0:
            what = (f'the first {PROBE_SIZE} bytes of the LPIPS weights' if at == 0
                    else f'the {PROBE_SIZE} bytes at {at} of the LPIPS weights')
            found.append(f'{what}, at {where}')
    return found


def command_lpips(args) -> int:
    lock = load_lock(args.lock)
    data = args.binary.read_bytes()
    found = lpips_findings(lock, data)
    if found:
        for line in found:
            print(f'::error::{args.binary.name} holds {line}')
        return 1
    print(f'{args.binary.name} ({len(data)} bytes): none of the {len(probes_of(lock))} probes of the LPIPS weights '
          f'({lock["lpips"]["path"]}, SHA-256 {lock["lpips"]["sha256"]})')
    return 0


# --- help ------------------------------------------------------------------------------------------------------------

def read_text(path: pathlib.Path) -> str:
    """The text of a file as written, its line ends untouched (read_text would turn a lone CR into a line end)"""
    return path.read_bytes().decode('utf-8', errors='replace')


def normalized_help(text: str) -> list:
    """The lines of brush_app --help without trailing blanks (CR included), with the program named brush_app on every
    system"""
    lines = [line.rstrip() for line in text.replace('\r\n', '\n').split('\n')]
    while lines and not lines[-1]:
        lines.pop()
    return [re.sub(r'^Usage: \S*brush_app(\.exe)?', 'Usage: brush_app', line) for line in lines]


def command_help(args) -> int:
    lock = load_lock(args.lock)
    version = read_text(args.version_output).strip()
    problems = 0
    if version != lock['brush']['versionLine']:
        print(f'::error::brush_app --version says {version!r}, the lock says {lock["brush"]["versionLine"]!r}')
        problems += 1
    built = normalized_help(read_text(args.output))
    frozen = normalized_help(read_text(args.fixture))
    if built != frozen:
        print('::error::brush_app --help differs from the fixture the arguments of the runner are frozen by:')
        sys.stdout.writelines(line + '\n' for line in difflib.unified_diff(frozen, built, 'fixture', 'built', lineterm=''))
        problems += 1
    if problems:
        return 1
    print(f'brush_app --help: {len(built)} lines, the same as {args.fixture.name}; {version}')
    return 0


# --- pack ------------------------------------------------------------------------------------------------------------

def windows_files(program: pathlib.Path, crt_dir: pathlib.Path | None, system_dir: pathlib.Path | None) -> tuple:
    """The files of the Windows archive by name, the program and the Visual C++ runtime DLLs it imports, the imports
    of the program, and the problems"""
    sys.path.insert(0, str(ROOT / '.github' / 'desktop'))
    import windows_bundle  # noqa: E402 (the import checks of the Windows ZIP of the app)

    crt_dir = crt_dir or windows_bundle.find_crt_dir('x64')
    if crt_dir is None or not crt_dir.is_dir():
        raise Failure('no Visual C++ redistributable folder: give --crt-dir')
    system_dir = system_dir or pathlib.Path(os.environ.get('SystemRoot', r'C:\Windows'), 'System32')
    imports = windows_bundle.read_pe(program)['imports']
    with tempfile.TemporaryDirectory(prefix='brush-') as temporary:
        folder = pathlib.Path(temporary)
        shutil.copy2(program, folder / 'brush_app.exe')
        crt = {path.name.lower(): path for path in crt_dir.glob('*.dll')}
        system = {name.lower() for name in os.listdir(system_dir)}
        copied = []
        problems = windows_bundle.check(folder, 'x64', crt, system, copied)
        for name in copied:
            print(f'Visual C++ runtime: {name}')
        return {path.name: path.read_bytes() for path in sorted(folder.iterdir())}, imports, problems


def linux_files(program: pathlib.Path, launcher: pathlib.Path) -> tuple:
    import sdcpp_build  # noqa: E402 (the ELF reader and the libraries every distribution has)

    files = {'brush_app': program.read_bytes(), 'immuch360-run': launcher.read_bytes()}
    problems, needed = [], {}
    for name, data in files.items():
        try:
            needed[name] = sdcpp_build.elf_needed(data)
        except (sdcpp_build.Failure, IndexError, ValueError) as error:
            raise Failure(f'{name}: {error}') from error
        for library in needed[name]:
            if library not in sdcpp_build.LINUX_SYSTEM:
                problems.append(f'{name} needs {library}, which the base of a distribution does not have')
    return files, needed['brush_app'], problems


def command_pack(args) -> int:
    lock = load_lock(args.lock)
    brush = lock['brush']
    problems = []
    program = args.bin.read_bytes()
    problems += [f'{args.bin.name} holds {line}' for line in lpips_findings(lock, program)]
    ours = (LICENCES / 'brush-LICENSE.txt').read_bytes().replace(b'\r\n', b'\n').strip()
    theirs = (args.source / 'LICENSE').read_bytes().replace(b'\r\n', b'\n').strip()
    if ours != theirs:
        problems.append('licenses/brush/brush-LICENSE.txt differs from LICENSE of the sources built: copy it again')
    if problems:
        for problem in problems:
            print(f'::error::{problem}')
        return 1
    if args.system == 'windows-x64':
        files, imports, found = windows_files(args.bin, args.crt_dir, args.system_dir)
        programs = {'brush_app.exe'}
    else:
        files, imports, found = linux_files(args.bin, args.launcher)
        programs = {'brush_app', 'immuch360-run'}
    problems += found
    print(f'brush_app imports: {", ".join(imports) or "nothing"}')

    # The texts with LF line ends, as in the repository, whatever the checkout of the runner made of them: the two
    # archives carry the same licences, the patch byte for byte the one of the repository
    def text(path: pathlib.Path) -> bytes:
        return path.read_bytes().replace(b'\r\n', b'\n')

    for name in SHIPPED_LICENCES:
        files[f'licenses/{name}'] = text(LICENCES / name)
    files['licenses/THIRD-PARTY.md'] = text(args.third_party)
    for name in lock['patches']:
        files[f'licenses/patches/{name}'] = text(LICENCES / 'patches' / name)
    run_url = ''
    if os.environ.get('GITHUB_RUN_ID'):
        run_url = (f'{os.environ.get("GITHUB_SERVER_URL", "https://github.com")}/{os.environ.get("GITHUB_REPOSITORY")}'
                   f'/actions/runs/{os.environ["GITHUB_RUN_ID"]}')
    files['BUILD-INFO.txt'] = '\n'.join([
        f'Brush for Immuch360 Desktop, {args.system}, lock {lock["id"]}, version {lock["version"]}',
        f'Brush {brush["repository"]} {brush["tag"]} {brush["commit"]} (Apache-2.0)',
        f'Rust {lock["rust"]["toolchain"]}, target {TARGETS[args.system]}',
        f'cargo build --locked --profile {lock["cargo"]["profile"]} ' + ' '.join(cargo_selection(lock))
        + f' --bin {lock["cargo"]["bin"]}',
        'Patches: ' + ', '.join(f'licenses/patches/{name}' for name in lock['patches'])
        + ' (no window, no network client, no rerun, no LPIPS weights)',
        f'LPIPS weights {lock["lpips"]["path"]} ({lock["lpips"]["size"]} bytes, SHA-256 {lock["lpips"]["sha256"]}) '
        'removed from the sources before the build; none of their probes in the program',
        f'Imports of brush_app: {", ".join(imports) or "none"}',
        *([f'Built by {run_url}'] if run_url else []),
        'Licences: licenses/ (Brush under the Apache License 2.0, the code built into it in licenses/THIRD-PARTY.md)',
        '',
    ]).encode()
    if problems:
        for problem in problems:
            print(f'::error::{problem}')
        return 1
    sys.path.insert(0, str(HERE))
    import sdcpp_build  # noqa: E402 (the same archive writer: sorted names, fixed dates)

    target = args.out / artifact_name(lock, args.system)
    sdcpp_build.write_archive(target, files, programs)
    for name in sorted(files):
        print(f'{len(files[name]):>10}  {hashlib.sha256(files[name]).hexdigest()}  {name}'
              + ('  (program)' if name in programs else ''))
    digest = sha256_of(target)
    print(f'{target.name}: {target.stat().st_size} bytes, SHA-256 {digest}')
    write_outputs({'archive': str(target), 'archive_sha256': digest})
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
    sources.add_argument('--patches', type=pathlib.Path, default=LICENCES / 'patches')
    sources.add_argument('--weights-out', type=pathlib.Path)
    tools = commands.add_parser('tools')
    tools.add_argument('--system', choices=SYSTEMS, required=True)
    tools.add_argument('--dir', type=pathlib.Path, required=True)
    tools.add_argument('--github-output', action='store_true')
    build = commands.add_parser('build')
    build.add_argument('--system', choices=SYSTEMS, required=True)
    build.add_argument('--source', type=pathlib.Path, required=True)
    graph = commands.add_parser('graph')
    graph.add_argument('--system', choices=SYSTEMS, required=True)
    given = graph.add_mutually_exclusive_group(required=True)
    given.add_argument('--source', type=pathlib.Path)
    given.add_argument('--tree', type=pathlib.Path)
    deny = commands.add_parser('deny')
    deny.add_argument('--system', choices=SYSTEMS, required=True)
    deny.add_argument('--source', type=pathlib.Path, required=True)
    deny.add_argument('--cargo-deny', type=pathlib.Path, required=True)
    about = commands.add_parser('about')
    about.add_argument('--system', choices=SYSTEMS, required=True)
    about.add_argument('--source', type=pathlib.Path, required=True)
    about.add_argument('--cargo-about', type=pathlib.Path, required=True)
    about.add_argument('--out', type=pathlib.Path, required=True)
    lpips = commands.add_parser('lpips')
    lpips.add_argument('--binary', type=pathlib.Path, required=True)
    check = commands.add_parser('help')
    check.add_argument('--output', type=pathlib.Path, required=True)
    check.add_argument('--version-output', type=pathlib.Path, required=True)
    check.add_argument('--fixture', type=pathlib.Path, default=FIXTURE)
    pack = commands.add_parser('pack')
    pack.add_argument('--system', choices=SYSTEMS, required=True)
    pack.add_argument('--source', type=pathlib.Path, required=True)
    pack.add_argument('--bin', type=pathlib.Path, required=True)
    pack.add_argument('--third-party', type=pathlib.Path, required=True)
    pack.add_argument('--out', type=pathlib.Path, required=True)
    pack.add_argument('--launcher', type=pathlib.Path)
    pack.add_argument('--crt-dir', type=pathlib.Path)
    pack.add_argument('--system-dir', type=pathlib.Path)
    args = parser.parse_args(argv)
    if args.command == 'pack' and args.system == 'linux-x64' and args.launcher is None:
        parser.error('the Linux archive needs --launcher (immuch360-run)')
    sys.path.insert(0, str(HERE))
    try:
        return {'lock': command_lock, 'sources': command_sources, 'tools': command_tools, 'build': command_build,
                'graph': command_graph, 'deny': command_deny, 'about': command_about, 'lpips': command_lpips,
                'help': command_help, 'pack': command_pack}[args.command](args)
    except (Failure, OSError, subprocess.CalledProcessError, json.JSONDecodeError, KeyError) as error:
        print(f'::error::{error}')
        return 1 if isinstance(error, (Failure, subprocess.CalledProcessError, KeyError)) else 2


if __name__ == '__main__':
    sys.exit(main())
