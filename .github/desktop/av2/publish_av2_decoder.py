#!/usr/bin/env python3
"""The prerelease av2-decoder-1: the AV2 decoder of Immuch360 Desktop, from the three archives of one run of our CI.

Plan of the AV2 videos (store/m2/av2-2026-11-02/plan-2026-11-02.md), section 3 and lot AD11. The app carries a catalogue
of its components with the size and the SHA-256 of each file (mobile/lib/domain/models/ai_immersive/
ai_components_manifest.dart): its three entries av2-decoder-windows-x64, -linux-x64 and -macos-universal name the
archives Immuch360-av2-decoder-<lock id>-<system>.zip of the release av2-decoder-1, a release of its own (AV2 is no AI,
plan 2.7). This script makes that release from a run of the desktop release workflow by hand with sign_test and
with_av2 (immuch360-desktop-release.yml), whose sign-windows job signed the Windows program with Azure Artifact Signing
and put the signed archive in place of the artifact; the Linux and macOS archives are those of the av2-linux and
av2-macos jobs of the same run, as they are. Modelled on .github/desktop/ai/publish_ai_components.py.

  publish_av2_decoder.py --from-run RUN --out DIR [--cache DIR] [--write] [--dry-run]
      downloads the three archives of the run RUN by the GitHub API (or takes them from a --cache folder or DIR when
      they are there), checks each one as its job did (av2_build.py check: its files, its sums, its licences, the
      libraries and imports of its program, no string of GPL code), checks that the Windows program is signed (the
      line of BUILD-INFO.txt the signing writes, and an Authenticode certificate in the PE file) and that the three were
      built from one commit of the repository and the lock of this checkout, then writes in DIR the three archives,
      AV2-DECODER-LICENSES.md (the licences of the decoder, the files of each archive with their sums, where the source
      is) and SHA256SUMS, and prints the entries of the catalogue with their sizes and sums. It then says whether the
      catalogue and the record of the release (.github/desktop/av2/av2-decoder-1.json) agree with these files. With
      --write, the entries are written into the catalogue (size, sha256 and archiveFiles of each archive) and the
      record is written: the step of the release of the app that ships the AV2 videos.
      With --dry-run, the release is also checked against GitHub without writing anything there: av2-decoder-1 must
      not exist yet, not even as a draft, and every request --publish would send is printed. Exit 1 when --publish
      would refuse (an unsigned Windows program, a catalogue or a record that differs from the files).
  publish_av2_decoder.py --from-run RUN --out DIR [...] --publish [--token-file FILE]
      the same, then the prerelease av2-decoder-1 on freeKC/Immuch360, its tag on the commit the archives were built
      from, only when the Windows program is signed and the catalogue and the record agree with the files: made as a
      draft, filled, then published as a prerelease that is never "Latest" (the app and its updaters read
      releases/latest). A release that exists already is never touched.

Without --publish nothing is written to GitHub; the network is used to read the run and download its artifacts. The
token comes from GH_TOKEN or GITHUB_TOKEN, or from --token-file, and is never printed; it is sent to the GitHub API
only, never to the storage an artifact is redirected to. --catalogue, --record, --licences, --date, --repo and --api
point at other files, dates and servers (the tests). Only the Python standard library is used, and no Python cache is
written next to the scripts. Exit codes: 0 done, 1 a check failed or GitHub refused, 2 bad arguments, files or token.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import io
import json
import os
import pathlib
import re
import struct
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile

sys.dont_write_bytecode = True

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / 'ai'))
import av2_build  # noqa: E402
import publish_ai_components as components  # noqa: E402

CATALOGUE = components.CATALOGUE
RECORD = HERE / 'av2-decoder-1.json'
LICENCES = ROOT / 'licenses' / 'av2'
API = 'https://api.github.com'
REPO = 'freeKC/Immuch360'
TAG = components.TAG_AV2
NOTICES = 'AV2-DECODER-LICENSES.md'
SUMS = 'SHA256SUMS'
USER_AGENT = 'immuch360-av2-decoder'
# The entry of the catalogue of each system, and the programs of its archive
COMPONENTS = {'windows-x64': 'av2-decoder-windows-x64', 'linux-x64': 'av2-decoder-linux-x64',
              'macos-universal': 'av2-decoder-macos-universal'}
PROGRAMS = {'windows-x64': {'immuch360-av2.exe'}, 'linux-x64': {'immuch360-av2', 'immuch360-run'},
            'macos-universal': {'immuch360-av2'}}
CONTENT_TYPES = {'.zip': 'application/zip', '.md': 'text/markdown'}
NOTES = (
    'The AV2 decoder of Immuch360 Desktop (experimental): immuch360-av2, our program on the library of dav2d by '
    'VideoLAN (BSD-2-Clause), for Windows x64, Linux x64 and macOS (Apple silicon and Intel), built and checked by our '
    'CI from pinned sources; the Windows program is signed by APROGSYS. It decodes AV2 videos with the processor and '
    'serves the pictures to the video player of the app on this computer only. This is not a release of the app: the '
    'app downloads the archive of its computer when an AV2 video plays without it, checks it by its SHA-256, and works '
    f'offline afterwards. Licences, files and sources: {NOTICES}. Sums: {SUMS}.\n'
)


class Failure(Exception):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# --- the archives -----------------------------------------------------------------------------------------------


def archive_names(lock: dict) -> dict:
    """The name of the archive of each system, from the lock of this checkout"""
    return {system: av2_build.artifact_name(lock, system) for system in COMPONENTS}


def files_of(data: bytes) -> dict:
    with zipfile.ZipFile(io.BytesIO(data)) as bundle:
        return {info.filename: bundle.read(info) for info in bundle.infolist() if not info.is_dir()}


def unwrapped(data: bytes, name: str) -> bytes:
    """The archive itself: an artifact uploaded without an archive of its own, or the one zip of an artifact that
    holds it"""
    names = list(files_of(data))
    if names == [name]:
        return files_of(data)[name]
    return data


def has_certificate(data: bytes) -> bool:
    """Whether the PE file [data] carries a certificate table (an Authenticode signature)"""
    if len(data) < 0x40 or data[:2] != b'MZ':
        return False
    pe, = struct.unpack_from('<I', data, 0x3C)
    if data[pe:pe + 4] != b'PE\0\0':
        return False
    optional = pe + 24
    magic, = struct.unpack_from('<H', data, optional)
    directories = optional + (112 if magic == 0x20B else 96)
    count, = struct.unpack_from('<I', data, directories - 4)
    if count <= 4:
        return False
    table, size = struct.unpack_from('<II', data, directories + 4 * 8)
    return bool(table and size) and table + size <= len(data)


def built_from(files: dict) -> str | None:
    """The commit of the repository an archive was built from, as its BUILD-INFO.txt says"""
    found = re.search(rb'/tree/([0-9a-f]{40})/mobile/native/av2', files.get('BUILD-INFO.txt', b''))
    return found.group(1).decode() if found else None


def catalogue_entry(system: str, data: bytes) -> tuple:
    """(size, sha256, [(path, size, sha256, executable)]) of an archive, as the catalogue writes it"""
    listed = [(path, len(content), sha256_bytes(content), path in PROGRAMS[system])
              for path, content in sorted(files_of(data).items())]
    return len(data), sha256_bytes(data), listed


def dart_entry(component_id: str, entry: tuple) -> str:
    size, digest, files = entry
    return (f'{component_id}:\n  size: {size},\n  sha256: \'{digest}\',\n'
            + components.dart_archive_files(files))


# --- the run of the CI ------------------------------------------------------------------------------------------


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def get_json(api: str, path: str, token: str):
    request = urllib.request.Request(f'{api.rstrip("/")}{path}', headers={
        'Authorization': f'Bearer {token}', 'Accept': 'application/vnd.github+json', 'User-Agent': USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise Failure(f'GET {path}: HTTP {error.code}') from None
    except urllib.error.URLError as error:
        raise Failure(f'GET {path}: {error.reason}') from None


def download_artifact(api: str, artifact: dict, token: str) -> bytes:
    """The bytes of an artifact; the token goes to the API only, never to the storage it redirects to"""
    url = f'{api.rstrip("/")}/repos/{artifact["repo"]}/actions/artifacts/{artifact["id"]}/zip'
    request = urllib.request.Request(url, headers={'Authorization': f'Bearer {token}', 'User-Agent': USER_AGENT,
                                                   'Accept': 'application/vnd.github+json'})
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        with opener.open(request, timeout=300) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        location = error.headers.get('Location') if error.code in (301, 302, 303, 307, 308) else None
        if location is None:
            raise Failure(f'GET {urllib.parse.urlsplit(url).path}: HTTP {error.code}') from None
        try:
            with urllib.request.urlopen(urllib.request.Request(location, headers={'User-Agent': USER_AGENT}),
                                        timeout=300) as response:
                return response.read()
        except (urllib.error.URLError, OSError) as failure:
            raise Failure(f'the artifact {artifact["name"]}: {failure}') from None


def run_archives(args, names: dict, token: str | None) -> tuple:
    """The three archives (system -> bytes) and what the run says of itself; from --cache or DIR first"""
    places = [*args.cache, args.out]
    archives, run = {}, None
    for system, name in names.items():
        for folder in places:
            if (folder / name).is_file():
                archives[system] = (folder / name).read_bytes()
                print(f'{name}: {len(archives[system])} bytes from {folder}')
                break
    missing = [system for system in names if system not in archives]
    if args.from_run:
        if not token:
            raise Failure('no token: set GH_TOKEN or GITHUB_TOKEN, or give --token-file')
        run = get_json(args.api, f'/repos/{args.repo}/actions/runs/{args.from_run}', token)
        if run is None:
            raise Failure(f'no run {args.from_run} on {args.repo}')
        print(f'run {args.from_run}: {run.get("name")} on {run.get("head_branch")} at {run.get("head_sha")}, '
              f'{run.get("event")}, {run.get("status")} {run.get("conclusion")}')
        if missing:
            listed = get_json(args.api, f'/repos/{args.repo}/actions/runs/{args.from_run}/artifacts?per_page=100',
                              token) or {}
            for system in missing:
                name = names[system]
                matches = [artifact for artifact in listed.get('artifacts', [])
                           if artifact.get('name') in (name, name.removesuffix('.zip'))]
                if len(matches) != 1:
                    raise Failure(f'the run {args.from_run} has {len(matches)} artifacts {name}')
                if matches[0].get('expired'):
                    raise Failure(f'the artifact {name} of the run {args.from_run} has expired')
                data = unwrapped(download_artifact(args.api, {**matches[0], 'repo': args.repo}, token), name)
                digest = (matches[0].get('digest') or '').removeprefix('sha256:')
                if digest and digest != sha256_bytes(data):
                    raise Failure(f'{name}: the API gives the SHA-256 {digest}, the download {sha256_bytes(data)}')
                archives[system] = data
                print(f'{name}: {len(data)} bytes from the run {args.from_run}')
    missing = [names[system] for system in names if system not in archives]
    if missing:
        raise Failure(f'missing {", ".join(missing)}: give --from-run RUN of the release workflow with with_av2')
    return archives, run


def check_archives(args, lock: dict, names: dict, archives: dict) -> tuple:
    """The problems of the three archives that stop everything, the reasons --publish would refuse, and the commit
    they were built from"""
    args.out.mkdir(parents=True, exist_ok=True)
    problems, refusals = [], []
    commits = set()
    for system, name in names.items():
        path = args.out / name
        if not path.is_file() or path.read_bytes() != archives[system]:
            path.write_bytes(archives[system])
        code = av2_build.main(['--lock', str(args.lock), 'check', '--system', system, '--archive', str(path)])
        if code != 0:
            problems.append(f'{name}: av2_build.py check failed')
        files = files_of(archives[system])
        commits.add(built_from(files))
        if system == 'windows-x64':
            program = files.get('immuch360-av2.exe', b'')
            signed_info = av2_build.SIGNED_LINE.encode() in files.get('BUILD-INFO.txt', b'')
            if not (signed_info and has_certificate(program)):
                refusals.append(f'{name}: its program is not signed (BUILD-INFO.txt says it is: {signed_info}; '
                                f'a certificate in immuch360-av2.exe: {has_certificate(program)}), the archive of '
                                f'the run of the release workflow with sign_test and with_av2 is the one to publish')
    if len(commits) != 1 or None in commits:
        problems.append(f'the three archives come from {sorted(str(commit) for commit in commits)}, not one commit')
    return problems, refusals, next(iter(commits)) if len(commits) == 1 else None


# --- the files of the release -----------------------------------------------------------------------------------


def notices_text(date: str, lock: dict, commit: str, names: dict, archives: dict) -> str:
    """AV2-DECODER-LICENSES.md: what the decoder is made of and under which licences, the archives and their files
    with their sums, where the source is; the licence texts the archives carry, from the Linux one, which has them all"""
    readme = (LICENCES / 'README.md').read_text(encoding='utf-8').strip().split('\n', 1)[1].strip()
    lines = [f'# {TAG}: the AV2 decoder of Immuch360 Desktop', '', f'Date: {date}.', '', readme, '',
             '## The archives', '',
             f'Built from {av2_build.REPOSITORY}/tree/{commit} (lock {lock["id"]}: dav2d '
             f'{lock["dav2d"]["commit"]}, {lock["dav2d"]["describe"]}).', '',
             '| Archive | Component of the app | Bytes | SHA-256 |', '|---|---|---:|---|']
    for system, name in names.items():
        data = archives[system]
        lines.append(f'| `{name}` | `{COMPONENTS[system]}` | {len(data)} | `{sha256_bytes(data)}` |')
    for system, name in names.items():
        lines += ['', f'### {name}', '', '| File | Bytes | SHA-256 |', '|---|---:|---|']
        for path, content in sorted(files_of(archives[system]).items()):
            lines.append(f'| `{path}` | {len(content)} | `{sha256_bytes(content)}` |')
    texts = {path: content for path, content in files_of(archives['linux-x64']).items()
             if path.startswith('licenses/') and path.endswith('.txt')}
    lines += ['', '## The licence texts', '']
    for path in sorted(texts):
        lines += [f'### {path.removeprefix("licenses/")}', '', '```', texts[path].decode('utf-8').rstrip('\n'), '```',
                  '']
    return '\n'.join(lines).rstrip('\n') + '\n'


def make_files(args, lock: dict, commit: str, names: dict, archives: dict) -> dict:
    """The files of the release in args.out, name -> (size, sha256)"""
    made = {name: (len(archives[system]), sha256_bytes(archives[system])) for system, name in names.items()}
    notices = notices_text(args.date, lock, commit, names, archives).encode('utf-8')
    (args.out / NOTICES).write_bytes(notices)
    made[NOTICES] = (len(notices), sha256_bytes(notices))
    sums = ''.join(f'{made[name][1]}  {name}\n' for name in sorted(made)).encode('utf-8')
    (args.out / SUMS).write_bytes(sums)
    made[SUMS] = (len(sums), sha256_bytes(sums))
    return made


def record_of(run: str | None, commit: str, names: dict, archives: dict, date: str) -> dict:
    return {'tag': TAG, 'run': run, 'commit': commit, 'date': date,
            'archives': {COMPONENTS[system]: {'assetName': name, 'size': len(archives[system]),
                                              'sha256': sha256_bytes(archives[system])}
                         for system, name in names.items()}}


def findings(catalogue: dict, record: dict | None, names: dict, archives: dict) -> list:
    found = []
    for system, name in names.items():
        component_id = COMPONENTS[system]
        entry = catalogue.get(component_id)
        if entry is None:
            found.append(f'the catalogue has no {component_id}')
            continue
        size, digest, files = catalogue_entry(system, archives[system])
        if entry.get('assetName') != name:
            found.append(f'{component_id}: the catalogue names {entry.get("assetName")}, the run made {name}')
        if (entry.get('size'), entry.get('sha256'), entry['archiveFiles']) != (size, digest, files):
            found.append(f'{component_id}: the catalogue says size {entry.get("size")}, sha256 {entry.get("sha256")}, '
                         f'{len(entry["archiveFiles"])} files; the archive gives {size}, {digest}, {len(files)} files')
        recorded = (record or {}).get('archives', {}).get(component_id)
        if recorded != {'assetName': name, 'size': size, 'sha256': digest}:
            found.append(f'{component_id}: the record of {TAG} says {recorded}; the archive gives {size}, {digest}')
    return found


# --- GitHub -----------------------------------------------------------------------------------------------------


def plan(made: dict, commit: str) -> list:
    """The requests --publish sends, in order"""
    body = {'tag_name': TAG, 'target_commitish': commit, 'name': 'AV2 decoder 1', 'body': NOTES, 'draft': True,
            'prerelease': True, 'make_latest': 'false'}
    steps = [f'POST /repos/{{repo}}/releases {json.dumps(body)}']
    steps += [f'POST <upload_url>?name={name} ({size} bytes, sha256 {digest})' for name, (size, digest)
              in sorted(made.items())]
    steps.append('PATCH <release> {"draft": false, "prerelease": true, "make_latest": "false"}')
    steps.append(f'GET /repos/{{repo}}/releases/latest: must not be {TAG}')
    return steps


def release_state(github: components.GitHub, repo: str) -> list:
    """Why av2-decoder-1 cannot be made now: it exists, or a draft of it does"""
    found = []
    if github.call('GET', f'/repos/{repo}/releases/tags/{TAG}') is not None:
        found.append(f'{TAG} exists already on {repo}: nothing is changed (delete it by hand to publish it again)')
    drafts = components.drafts_of(github, repo, TAG)
    if drafts:
        found.append(f'a draft of {TAG} exists already on {repo}: {drafts[0].get("html_url")}')
    return found


def publish(args, made: dict, commit: str, token: str) -> int:
    github = components.GitHub(args.api, token)
    refused = release_state(github, args.repo)
    if refused:
        for line in refused:
            print(line)
        return 1
    release = github.call('POST', f'/repos/{args.repo}/releases', {
        'tag_name': TAG, 'target_commitish': commit, 'name': 'AV2 decoder 1', 'body': NOTES, 'draft': True,
        'prerelease': True, 'make_latest': 'false'})
    print(f'draft made: {release["html_url"]}')
    try:
        upload = release['upload_url'].split('{', 1)[0]
        for name in sorted(made):
            size, digest = made[name]
            path = args.out / name
            data = path.read_bytes()
            if len(data) != size or sha256_bytes(data) != digest:
                raise Failure(f'{path} changed since it was made')
            content_type = CONTENT_TYPES.get(path.suffix.lower(), 'text/plain' if name == SUMS
                                             else 'application/octet-stream')
            asset = github.call('POST', f'{upload}?{urllib.parse.urlencode({"name": name})}', data=data,
                                content_type=content_type)
            held = asset.get('digest') or ''
            if asset.get('size') != size or (held.startswith('sha256:') and held[7:] != digest):
                raise Failure(f'{name}: GitHub holds {asset.get("size")} bytes, {held}; the file has {size} bytes, '
                              f'sha256:{digest}')
            print(f'uploaded: {name} ({size} bytes)')
        release = github.call('PATCH', release['url'], {'draft': False, 'prerelease': True, 'make_latest': 'false'})
    except (Failure, components.Failure, OSError) as error:
        raise Failure(f'{error}. A draft is left at {release["html_url"]}: delete it by hand before the next run.') \
            from None
    if not release.get('prerelease') or release.get('draft'):
        raise Failure(f'{TAG} is not a published prerelease: {release.get("html_url")}')
    latest = github.call('GET', f'/repos/{args.repo}/releases/latest')
    if latest is not None and latest.get('tag_name') == TAG:
        raise Failure(f'{TAG} became the latest release of {args.repo}: mark the app release as latest again')
    print(f'published as a prerelease: {release["html_url"]}')
    return 0


# --- command line -----------------------------------------------------------------------------------------------


def read_token(args) -> str | None:
    token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
    if args.token_file:
        token = args.token_file.read_text(encoding='utf-8').strip()
    return token or None


def main(argv=None) -> int:
    sys.stdout.reconfigure(line_buffering=True)
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--out', type=pathlib.Path, required=True, help='the folder of the files of the release')
    parser.add_argument('--from-run', help='the run of the release workflow (with sign_test and with_av2) whose '
                        'archives make the release')
    parser.add_argument('--cache', type=pathlib.Path, action='append', default=[],
                        help='a folder that holds some of the archives already')
    parser.add_argument('--write', action='store_true', help='write the entries into the catalogue, and the record')
    parser.add_argument('--dry-run', action='store_true', help='check the release against GitHub and print the '
                        'requests --publish would send, without sending any')
    parser.add_argument('--publish', action='store_true', help=f'create the prerelease {TAG} on GitHub')
    parser.add_argument('--token-file', type=pathlib.Path, help='a file holding the token')
    parser.add_argument('--catalogue', type=pathlib.Path, default=CATALOGUE, help=argparse.SUPPRESS)
    parser.add_argument('--record', type=pathlib.Path, default=RECORD, help=argparse.SUPPRESS)
    parser.add_argument('--lock', type=pathlib.Path, default=av2_build.LOCK, help=argparse.SUPPRESS)
    parser.add_argument('--date', default=datetime.date.today().isoformat(), help=argparse.SUPPRESS)
    parser.add_argument('--repo', default=REPO, help=argparse.SUPPRESS)
    parser.add_argument('--api', default=API, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.dry_run and args.publish:
        print('--dry-run or --publish, not both')
        return 2
    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}', args.date):
        print(f'--date {args.date!r} is not YYYY-MM-DD')
        return 2
    if not args.catalogue.is_file():
        print(f'no catalogue at {args.catalogue}')
        return 2
    token = read_token(args)
    if (args.publish or args.dry_run) and not token:
        print('no token: set GH_TOKEN or GITHUB_TOKEN, or give --token-file')
        return 2
    try:
        lock = av2_build.load_lock(args.lock)
        names = archive_names(lock)
        archives, run = run_archives(args, names, token)
        problems, refusals, commit = check_archives(args, lock, names, archives)
        if problems:
            for line in problems:
                print(f'publish_av2_decoder: {line}')
            return 1
        if run is not None and run.get('head_sha') != commit:
            raise Failure(f'the run {args.from_run} is at {run.get("head_sha")}, its archives were built from {commit}')
        made = make_files(args, lock, commit, names, archives)
        print()
        print(f'Files of {TAG} in {args.out}, built from {commit}:')
        for name in sorted(made):
            print(f'  {name}  {made[name][0]} bytes  {made[name][1]}')
        entries = {COMPONENTS[system]: catalogue_entry(system, archives[system]) for system in names}
        print()
        print('The entries of the catalogue (ai_components_manifest.dart):')
        for component_id in sorted(entries):
            print(dart_entry(component_id, entries[component_id]))
        record = record_of(args.from_run, commit, names, archives, args.date)
        text = args.catalogue.read_text(encoding='utf-8')
        if args.write:
            new = components.write_catalogue_family(text, {}, entries)
            if new != text:
                args.catalogue.write_text(new, encoding='utf-8', newline='\n')
                print(f'written: {args.catalogue}')
            args.record.write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8', newline='\n')
            print(f'written: {args.record}')
            text = new
        kept = json.loads(args.record.read_text(encoding='utf-8')) if args.record.is_file() else None
        found = findings(components.read_catalogue(text), kept, names, archives)
        for line in found:
            print(f'publish_av2_decoder: {line}')
        print('the catalogue or the record differs from these files: run with --write' if found
              else 'the catalogue and the record of the release agree with these files')
        refusals += ([f'{TAG} must carry the files the catalogue names'] if found else [])
        if args.dry_run:
            github = components.GitHub(args.api, token)
            refusals += release_state(github, args.repo)
            latest = github.call('GET', f'/repos/{args.repo}/releases/latest')
            print(f'the latest release of {args.repo} is {(latest or {}).get("tag_name")}, and stays it')
            print(f'dry run: --publish would send, on {args.repo}:')
            for step in plan(made, commit):
                print(f'  {step.replace("{repo}", args.repo)}')
        for line in refusals:
            print(f'not published: {line}')
        if not args.publish:
            if args.dry_run:
                print('dry run: nothing was written to GitHub' + ('; --publish would refuse' if refusals else ''))
                return 1 if refusals else 0
            print(f'not published: {TAG} is created only with --publish')
            return 0
        if refusals:
            return 1
        return publish(args, made, commit, token)
    except (Failure, components.Failure, av2_build.Failure, OSError, zipfile.BadZipFile, json.JSONDecodeError) as error:
        message = f'publish_av2_decoder: {error}'
        print(message.replace(token, '***') if token else message)
        return 1


if __name__ == '__main__':
    sys.exit(main())
