#!/usr/bin/env python3
"""Spark, the Gaussian splat renderer of the splat viewer, built from its tag (lot SV0 of the splat viewer plan).

The splat viewer of the computers, phones and tablets is one web page in the app's assets (mobile/assets/splat_viewer)
that draws with Spark 2.4.0 (MIT, World Labs) on three.js 0.180.0 (MIT). The npm file of Spark holds a WebAssembly
module built with flate2 on zlib-rs, the one crate of its build under the Zlib licence, which is not among the licences
the app takes (MIT, BSD, Apache 2.0, MPL 2.0). This script builds the same tag with flate2 and zip on miniz_oxide
(MIT, Zlib or Apache 2.0, taken under MIT) and the WebAssembly as a file of its own:

  1. sparkjsdev/spark cloned at the tag of spark.lock.json, its commit checked;
  2. the patches of patches/ applied (Cargo.toml: two features; src/wasm.ts: the WebAssembly fetched next to the
     module instead of inlined as base64);
  3. the crates of the WebAssembly listed from Cargo.lock as cargo resolves them for wasm32 (procedural macros left
     out: they run at build time only), each licence expression checked against the licences the app takes, and the
     crates of refused_crates refused outright. A crate of the tree under another licence passes only when none of its
     code is in the linked module: no function of the name section of the module cargo links (before wasm-bindgen and
     wasm-opt strip the names) mentions it (unicode-ident, under Unicode 3.0 next to MIT or Apache 2.0, which
     wasm-bindgen-shared uses for the identifiers of its build tools only);
  4. the WebAssembly built as Spark's own script does (wasm-pack, simd128 and bulk-memory), with the toolchain of the
     lock and CONST_RANDOM_SEED fixed (ahash takes its keys from const-random at build time: without the seed two
     builds differ), and the paths of the sources remapped to /cargo and /spark (the panic messages hold them);
  5. npm ci on Spark's package-lock.json (no install scripts) and its vite build;
  6. the files of the page copied to the output folder: spark.module.min.js, spark_rs_bg.wasm, three.module.min.js,
     three.core.min.js and Pass.js of three.js; the licences to <out>/licenses: Spark's, three.js's, fflate's (the one
     npm package bundled into Spark, read from the source map) and THIRD_PARTY_NOTICES.txt for the crates; MANIFEST
     with the SHA-256 and the size of each file, and CRATES.txt.

  spark_build.py --work DIR --out DIR      build (needs git, rustup, wasm-pack, node and npm of the lock)
  spark_build.py --check-licence EXPR      exit 0 when the app takes a crate under the SPDX expression EXPR

The desktop workflow runs it in its spark job, on demand (the spark input) or when spark.lock.json or the patches
changed, and uploads the output as an artifact; its files are committed under mobile/assets/splat_viewer and
mobile/assets/licenses/splat-viewer, and check_vendor.py holds them to MANIFEST.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
LOCK = HERE / 'spark.lock.json'

# The licences the app takes (FreeKC's rule: permissive only, MIT, BSD, Apache 2.0, MPL 2.0 unmodified)
ALLOWED = {
    'MIT', 'MIT-0', 'Apache-2.0', 'Apache-2.0 WITH LLVM-exception', 'BSD-2-Clause', 'BSD-3-Clause', '0BSD', 'MPL-2.0',
}
# The licence a crate is listed under when its expression offers several, the first one it offers
PREFERRED = ['MIT', 'Apache-2.0', 'BSD-3-Clause', 'BSD-2-Clause', '0BSD', 'MIT-0', 'Apache-2.0 WITH LLVM-exception',
             'MPL-2.0']

# The files of the page, from the build, the npm packages and the WebAssembly, in the order of MANIFEST
PAGE_FILES = {
    'spark.module.min.js': 'dist/spark.module.min.js',
    'spark_rs_bg.wasm': 'rust/spark-rs/pkg/spark_rs_bg.wasm',
    'three.module.min.js': 'node_modules/three/build/three.module.min.js',
    'three.core.min.js': 'node_modules/three/build/three.core.min.js',
    'Pass.js': 'node_modules/three/examples/jsm/postprocessing/Pass.js',
}


def _tokens(expression: str) -> list:
    expression = expression.replace('/', ' OR ')
    return re.findall(r'\(|\)|[A-Za-z0-9.+-]+(?:\s+WITH\s+[A-Za-z0-9.+-]+)?', expression)


def licence_choices(expression: str) -> list:
    """The licences of the SPDX expression the app takes, one per way it can be taken: [] when none (an AND is taken
    only when each of its sides is). "MIT/Apache-2.0", the old form of cargo, is an OR."""
    tokens = _tokens(expression)
    position = 0

    def parse_or() -> list:
        nonlocal position
        choices = parse_and()
        while position < len(tokens) and tokens[position] == 'OR':
            position += 1
            choices = choices + parse_and()
        return choices

    def parse_and() -> list:
        nonlocal position
        choices = parse_atom()
        while position < len(tokens) and tokens[position] == 'AND':
            position += 1
            right = parse_atom()
            choices = [f'{left} AND {other}' for left in choices for other in right]
        return choices

    def parse_atom() -> list:
        nonlocal position
        if position >= len(tokens):
            raise ValueError(f'licence expression ends early: {expression!r}')
        token = tokens[position]
        position += 1
        if token == '(':
            choices = parse_or()
            if position >= len(tokens) or tokens[position] != ')':
                raise ValueError(f'unbalanced licence expression: {expression!r}')
            position += 1
            return choices
        normal = re.sub(r'\s+', ' ', token)
        return [normal] if normal in ALLOWED else []

    choices = parse_or()
    if position != len(tokens):
        raise ValueError(f'unreadable licence expression: {expression!r}')
    return choices


def chosen_licence(expression: str) -> str | None:
    """The licence a crate is taken under, MIT first when it is offered; None when the app cannot take it"""
    choices = licence_choices(expression)
    for preferred in PREFERRED:
        if preferred in choices:
            return preferred
    return choices[0] if choices else None


def run(command: list, cwd: pathlib.Path | None = None, env: dict | None = None, capture: bool = False) -> str:
    print('+ ' + ' '.join(command), flush=True)
    result = subprocess.run(command, cwd=cwd, env=env, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout if capture else ''


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def check_toolchain(lock: dict) -> None:
    wanted = lock['toolchain']
    rust = run(['rustc', '--version'], capture=True).split()[1]
    pack = run(['wasm-pack', '--version'], capture=True).split()[1]
    node = run(['node', '--version'], capture=True).strip().lstrip('v')
    found = {'rust': rust, 'wasm_pack': pack, 'node': node}
    wrong = [f'{name} {found[name]} instead of {wanted[name]}' for name in found if found[name] != wanted[name]]
    if wrong:
        sys.exit('the toolchain is not the one of spark.lock.json: ' + ', '.join(wrong))


def wasm_crates(source: pathlib.Path) -> list:
    """The crates compiled into the WebAssembly, as (name, version, licence expression, folder), sorted"""
    tree = run(['cargo', 'tree', '--locked', '-p', 'spark-rs', '--target', 'wasm32-unknown-unknown',
                '-e', 'normal,no-proc-macro', '--prefix', 'none', '--format', '{p}'],
               cwd=source / 'rust', capture=True)
    wanted = set()
    for line in tree.splitlines():
        match = re.match(r'^(\S+) v(\S+)', line.strip())
        if match:
            wanted.add((match.group(1), match.group(2)))
    metadata = json.loads(run(['cargo', 'metadata', '--locked', '--format-version', '1',
                               '--filter-platform', 'wasm32-unknown-unknown'], cwd=source / 'rust', capture=True))
    crates = []
    for package in metadata['packages']:
        key = (package['name'], package['version'])
        if key in wanted:
            licence = package.get('license') or ''
            crates.append((package['name'], package['version'], licence,
                           pathlib.Path(package['manifest_path']).parent, package.get('authors') or []))
            wanted.discard(key)
    if wanted:
        sys.exit(f'crates of cargo tree missing from cargo metadata: {sorted(wanted)}')
    return sorted(crates, key=lambda crate: (crate[0], crate[1]))


LICENCE_FILE = re.compile(r'^(LICEN[CS]E|COPYING|COPYRIGHT|NOTICE|UNLICENSE)', re.IGNORECASE)


def licence_files(folder: pathlib.Path, licence: str) -> list:
    """The licence files of a crate for the licence it is taken under: LICENSE-MIT for MIT, LICENSE-APACHE and NOTICE
    for Apache 2.0, a lone LICENSE or COPYRIGHT otherwise"""
    files = sorted(path for path in folder.iterdir() if path.is_file() and LICENCE_FILE.match(path.name))
    markers = {'MIT': 'MIT', 'MIT-0': 'MIT', 'Apache-2.0': 'APACHE', 'Apache-2.0 WITH LLVM-exception': 'APACHE',
               'BSD-3-Clause': 'BSD', 'BSD-2-Clause': 'BSD', '0BSD': 'BSD', 'MPL-2.0': 'MPL'}
    wanted = [markers[part] for part in licence.split(' AND ')]
    picked = [path for path in files if any(marker in path.name.upper() for marker in wanted)]
    picked += [path for path in files if path.name.upper().startswith(('NOTICE', 'COPYRIGHT'))]
    if not picked:
        picked = [path for path in files if path.name.upper() in ('LICENSE', 'LICENCE', 'LICENSE.TXT', 'LICENSE.MD',
                                                                     'COPYING')]
    return picked


def _leb128(data: bytes, at: int) -> tuple:
    value, shift = 0, 0
    while True:
        byte = data[at]
        at += 1
        value |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            return value, at


def function_names(wasm: pathlib.Path) -> list:
    """The function names of the name section of a WebAssembly module (subsection 1), [] without one"""
    data = wasm.read_bytes()
    names, at = [], 8
    while at < len(data):
        section = data[at]
        size, at = _leb128(data, at + 1)
        end = at + size
        if section == 0:
            length, inner = _leb128(data, at)
            if data[inner:inner + length] == b'name':
                inner += length
                while inner < end:
                    kind = data[inner]
                    sub_size, inner = _leb128(data, inner + 1)
                    sub_end = inner + sub_size
                    if kind == 1:
                        count, inner = _leb128(data, inner)
                        for _ in range(count):
                            _, inner = _leb128(data, inner)
                            length, inner = _leb128(data, inner)
                            names.append(data[inner:inner + length].decode('utf-8', 'replace'))
                            inner += length
                    inner = sub_end
        at = end
    return names


def functions_of(crate: str, names: list) -> int:
    """How many of the (v0 mangled) function names mention the crate: its own functions and those instantiated on
    its types"""
    ident = crate.replace('-', '_')
    pattern = re.compile(rf'C(?:s[0-9A-Za-z]*_)?{len(ident)}{re.escape(ident)}')
    return sum(1 for name in names if pattern.search(name))


def write_notices(crates: list, names: list, out: pathlib.Path) -> list:
    """THIRD_PARTY_NOTICES.txt of the crates, and the lines of CRATES.txt; exits on a crate the app cannot take"""
    lock = json.loads(LOCK.read_text())
    refused, lines, sections = [], [], []
    for name, version, expression, folder, authors in crates:
        licence = chosen_licence(expression) if expression else None
        functions = functions_of(name, names)
        if name in lock['refused_crates'] or (licence is None and functions):
            refused.append(f'{name} {version} ({expression or "no licence"}, {functions} functions)')
            continue
        if licence is None:
            lines.append(f'{name} {version} | {expression} | not in the WebAssembly: no function of the linked module '
                         'mentions it')
            continue
        lines.append(f'{name} {version} | {expression} | taken under {licence} | {functions} functions')
        texts = []
        for path in licence_files(folder, licence):
            texts.append(f'--- {path.name} ---\n' + path.read_text(encoding='utf-8', errors='replace').strip())
        if not texts:
            texts.append(f'(no licence file in the crate; its manifest says {expression}, authors: '
                         f'{", ".join(authors) or "not given"})')
        sections.append(f'{name} {version}\nLicence: {expression}, taken under {licence}\n\n' + '\n\n'.join(texts))
    if refused:
        sys.exit('crates the app cannot take: ' + ', '.join(refused))
    header = ('The Rust crates compiled into spark_rs_bg.wasm, the WebAssembly of Spark 2.4.0 as Immuch360 builds it '
              '(.github/desktop/splat_viewer/spark_build.py), with the licence each is taken under and its texts.')
    (out / 'THIRD_PARTY_NOTICES.txt').write_text(header + '\n\n' + '\n\n\n'.join(sections) + '\n', encoding='utf-8')
    return lines


def bundled_npm_packages(source: pathlib.Path) -> list:
    """The npm packages the vite build put into spark.module.min.js and its worker, read from their source maps"""
    names = set()
    for path in [source / 'dist/spark.module.min.js.map', *sorted((source / 'dist/assets').glob('*.map'))]:
        for entry in json.loads(path.read_text())['sources']:
            if 'node_modules/' in entry:
                parts = entry.split('node_modules/')[-1].split('/')
                names.add('/'.join(parts[:2]) if parts[0].startswith('@') else parts[0])
    return sorted(names)


def build(work: pathlib.Path, out: pathlib.Path) -> None:
    lock = json.loads(LOCK.read_text())
    check_toolchain(lock)
    spark = lock['spark']
    source = work / 'spark'
    if source.exists():
        shutil.rmtree(source)
    work.mkdir(parents=True, exist_ok=True)
    run(['git', 'clone', '--quiet', '--depth', '1', '--branch', spark['tag'], spark['repository'], str(source)])
    commit = run(['git', 'rev-parse', 'HEAD'], cwd=source, capture=True).strip()
    if commit != spark['commit']:
        sys.exit(f'{spark["tag"]} is at {commit}, not at the commit of the lock {spark["commit"]}')
    for patch in lock['patches']:
        run(['git', 'apply', '--verbose', str(HERE / 'patches' / patch)], cwd=source)

    crates = wasm_crates(source)
    # The paths of the sources in the panic messages of the module do not depend on the machine: the registry of cargo
    # and the clone written as /cargo and /spark (the home folders of ai1 and of the runner gave 72 bytes apart)
    cargo_home = os.environ.get('CARGO_HOME') or os.path.join(os.path.expanduser('~'), '.cargo')
    remaps = f'--remap-path-prefix={cargo_home}=/cargo --remap-path-prefix={source}=/spark'
    env = dict(os.environ, RUSTFLAGS=f'-C target-feature=+simd128,+bulk-memory {remaps}',
               CONST_RANDOM_SEED=lock['toolchain']['const_random_seed'], SOURCE_DATE_EPOCH='0')
    run(['wasm-pack', 'build', '--target', 'web', '--release'], cwd=source / 'rust/spark-rs', env=env)
    run(['npm', 'ci', '--no-audit', '--no-fund', '--ignore-scripts'], cwd=source, env=env)
    three = json.loads((source / 'node_modules/three/package.json').read_text())['version']
    if three != lock['three']['version']:
        sys.exit(f'three {three} in the package-lock of Spark, not {lock["three"]["version"]}')
    run(['npx', '--no-install', 'vite', 'build', '--mode', 'production'], cwd=source, env=env)

    if out.exists():
        shutil.rmtree(out)
    licences = out / 'licenses'
    licences.mkdir(parents=True)
    for name, relative in PAGE_FILES.items():
        shutil.copyfile(source / relative, out / name)
    shutil.copyfile(source / 'LICENSE', licences / 'LICENSE-spark')
    shutil.copyfile(source / 'node_modules/three/LICENSE', licences / 'LICENSE-three')
    npm = bundled_npm_packages(source)
    for package in npm:
        shutil.copyfile(source / 'node_modules' / package / 'LICENSE', licences / f'LICENSE-{package.replace("/", "-")}')
    names = function_names(source / 'rust/target/wasm32-unknown-unknown/release/spark_rs.wasm')
    if not names:
        sys.exit('the module cargo linked has no name section: the crates of the WebAssembly cannot be told')
    crate_lines = write_notices(crates, names, licences)

    (out / 'CRATES.txt').write_text('\n'.join(crate_lines) + '\n', encoding='utf-8')
    manifest = [f'# Spark {spark["tag"]} ({spark["commit"]}) built by spark_build.py, three.js {three}',
                f'# npm packages bundled into spark.module.min.js: {", ".join(npm) or "none"}',
                f'# {len(crate_lines)} crates in spark_rs_bg.wasm (CRATES.txt)']
    for path in sorted([*(out / name for name in PAGE_FILES), *sorted(licences.iterdir())],
                       key=lambda p: p.relative_to(out).as_posix()):
        manifest.append(f'{sha256(path)}  {path.stat().st_size:>9}  {path.relative_to(out).as_posix()}')
    (out / 'MANIFEST').write_text('\n'.join(manifest) + '\n', encoding='utf-8')
    print((out / 'MANIFEST').read_text())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--work', type=pathlib.Path)
    parser.add_argument('--out', type=pathlib.Path)
    parser.add_argument('--check-licence', metavar='EXPR')
    arguments = parser.parse_args()
    if arguments.check_licence is not None:
        licence = chosen_licence(arguments.check_licence)
        print(licence or 'refused')
        return 0 if licence else 1
    if not arguments.work or not arguments.out:
        parser.error('--work and --out, or --check-licence')
    build(arguments.work.resolve(), arguments.out.resolve())
    return 0


if __name__ == '__main__':
    sys.exit(main())
