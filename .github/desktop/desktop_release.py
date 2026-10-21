#!/usr/bin/env python3
"""Attaches the files of an Immuch360 Desktop build to its GitHub pre-release, with SHA256SUMS.txt.

A desktop pre-release has the tag desktop-v<version>-<n>, for desktop build n (desktop-v3.3.0-rc.0-4 is desktop
build 4). Two ways lead to it, and both run this script, so that they give the same release:
  - the workflow immuch360-desktop-release.yml, on the push of such a tag: the Windows ZIP and installer, the Linux
    .deb and .rpm, the macOS ZIP and DMG that immuch360-desktop.yml built from the tag, and the archive of the
    corresponding source of libsmb2 (LGPL), which every package carries as an asset of the app and which
    .github/desktop/libsmb2/pack_sources.py makes for every build, with the token of the run;
  - the owner, from a computer, with a token of their own: the release notes, or a file built elsewhere.

  desktop_release.py --repo OWNER/NAME --tag TAG [--commit SHA] [--name NAME] [--notes FILE] [FILE ...]
  desktop_release.py --dry-run [--label LABEL] [--sums FILE] FILE ...

The release is created, as a pre-release, when the tag has none (on the commit given, or the tag's own). Its name and
notes are set only when they are given, so that the workflow never replaces notes written by hand. A file replaces
the asset of the same name. SHA256SUMS.txt is then written again for every asset of the release, whichever way it
came: from the digest GitHub keeps for each asset, from the file itself, or by reading the asset.

The token comes from GH_TOKEN or GITHUB_TOKEN, or from --token-file, and is never printed. --api points at another
server (the tests use a fake one). --dry-run reads the files only: with --label it checks that the seven files of a
build are all there and nothing else, and it prints SHA256SUMS.txt (or writes it with --sums), without the network.
Exit codes: 0 done, 1 a check failed or GitHub refused, 2 bad arguments, files or token.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

API = 'https://api.github.com'
DESKTOP_TAG = re.compile(r'^desktop-v(\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)-(\d+)$')
REPO = re.compile(r'^[\w.-]+/[\w.-]+$')
SUMS = 'SHA256SUMS.txt'
CONTENT_TYPES = {
    '.zip': 'application/zip',
    '.exe': 'application/vnd.microsoft.portable-executable',
    '.deb': 'application/vnd.debian.binary-package',
    '.rpm': 'application/x-rpm',
    '.dmg': 'application/x-apple-diskimage',
    '.gz': 'application/gzip',
    '.txt': 'text/plain',
}


class Failure(Exception):
    pass


def build_files(label: str) -> list:
    """The files of a build of immuch360-desktop.yml for a label of desktop_version.py"""
    stem = f'Immuch360-Desktop-{label}'
    return [f'{stem}-windows-x64.zip', f'{stem}-windows-x64-setup.exe', f'{stem}-linux-amd64.deb',
            f'{stem}-linux-x86_64.rpm', f'{stem}-macos.zip', f'{stem}-macos.dmg', f'{stem}-libsmb2-sources.tar.gz']


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def sums_text(sums: dict) -> str:
    """The lines of SHA256SUMS.txt, as sha256sum writes them and sha256sum -c reads them"""
    return ''.join(f'{sums[name]}  {name}\n' for name in sorted(sums))


def default_name(tag: str) -> str:
    version, build = DESKTOP_TAG.match(tag).groups()
    return f'Immuch360 Desktop {version}, desktop build {build} (preview)'


def default_notes(tag: str) -> str:
    _, build = DESKTOP_TAG.match(tag).groups()
    return (f'Immuch360 Desktop, desktop build {build}: the Windows installer and ZIP, the Linux .deb and .rpm and the '
            f'macOS app are below, with the sources of libsmb2 (LGPL) and {SUMS} to check them. The release notes '
            f'follow.\n')


class GitHub:
    def __init__(self, base: str, token: str):
        self.base = base.rstrip('/')
        self.token = token

    def call(self, method: str, url: str, body=None, data: bytes | None = None, content_type='application/json'):
        if not url.startswith('http'):
            url = self.base + url
        headers = {'Authorization': f'Bearer {self.token}', 'Accept': 'application/vnd.github+json',
                   'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'immuch360-desktop-release'}
        if body is not None:
            data = json.dumps(body).encode('utf-8')
        if data is not None:
            headers['Content-Type'] = content_type
        request = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=900) as response:
                raw = response.read()
        except urllib.error.HTTPError as error:
            if error.code == 404 and method == 'GET':
                return None
            detail = error.read().decode('utf-8', 'replace')[:300]
            raise Failure(f'{method} {urllib.parse.urlsplit(url).path}: HTTP {error.code} {detail}') from None
        return json.loads(raw) if raw else None


def read_asset(url: str) -> str:
    """The SHA-256 of an asset that has no digest on GitHub, read through its public download address"""
    digest = hashlib.sha256()
    request = urllib.request.Request(url, headers={'User-Agent': 'immuch360-desktop-release'})
    with urllib.request.urlopen(request, timeout=900) as response:
        for block in iter(lambda: response.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def publish(args, files: list, token: str) -> int:
    github = GitHub(args.api, token)
    tag = urllib.parse.quote(args.tag, safe='')
    notes = args.notes.read_text(encoding='utf-8') if args.notes else None
    release = github.call('GET', f'/repos/{args.repo}/releases/tags/{tag}')
    if release is None:
        body = {'tag_name': args.tag, 'name': args.name or default_name(args.tag),
                'body': notes if notes is not None else default_notes(args.tag), 'prerelease': True, 'draft': False}
        if args.commit:
            body['target_commitish'] = args.commit
        release = github.call('POST', f'/repos/{args.repo}/releases', body)
        print(f'release created: {release["html_url"]}')
    else:
        changes = {key: value for key, value in (('name', args.name), ('body', notes)) if value is not None}
        if changes:
            release = github.call('PATCH', release['url'], changes)
        print(f'release found: {release["html_url"]}' + (f' ({", ".join(sorted(changes))} updated)' if changes else ''))

    upload = release['upload_url'].split('{', 1)[0]
    existing = {asset['name']: asset for asset in release.get('assets', [])}
    local = {}
    for path in files:
        if path.name in existing:
            github.call('DELETE', existing[path.name]['url'])
            print(f'replaced: {path.name}')
        content_type = CONTENT_TYPES.get(path.suffix.lower(), 'application/octet-stream')
        asset = github.call('POST', f'{upload}?{urllib.parse.urlencode({"name": path.name})}', data=path.read_bytes(),
                            content_type=content_type)
        local[path.name] = sha256(path)
        print(f'uploaded: {path.name} ({asset["size"]} bytes)')

    release = github.call('GET', release['url'])
    sums = {}
    for asset in release.get('assets', []):
        if asset['name'] == SUMS:
            continue
        digest = asset.get('digest') or ''
        if asset['name'] in local:
            sums[asset['name']] = local[asset['name']]
            if digest.startswith('sha256:') and digest[7:] != local[asset['name']]:
                raise Failure(f'{asset["name"]}: GitHub holds {digest}, the file is sha256:{local[asset["name"]]}')
        elif digest.startswith('sha256:'):
            sums[asset['name']] = digest[7:]
        else:
            sums[asset['name']] = read_asset(asset['browser_download_url'])
    text = sums_text(sums)
    for asset in release.get('assets', []):
        if asset['name'] == SUMS:
            github.call('DELETE', asset['url'])
    github.call('POST', f'{upload}?{urllib.parse.urlencode({"name": SUMS})}', data=text.encode('utf-8'),
                content_type='text/plain')
    print(f'{SUMS}: {len(sums)} files')
    print(text, end='')
    return 0


def dry_run(args, files: list) -> int:
    names = [path.name for path in files]
    problems = []
    if args.label:
        wanted = build_files(args.label)
        problems += [f'missing: {name}' for name in wanted if name not in names]
        problems += [f'not a file of the build: {name}' for name in names if name not in wanted]
    sums = {path.name: sha256(path) for path in files}
    text = sums_text(sums)
    if args.sums:
        args.sums.write_text(text, encoding='utf-8', newline='\n')
    for path in files:
        print(f'{path.name}: {path.stat().st_size / 1e6:.1f} MB')
    print(text, end='')
    for line in problems:
        print(line)
    return 1 if problems else 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('files', nargs='*', type=pathlib.Path, metavar='FILE')
    parser.add_argument('--repo', help='OWNER/NAME of the repository')
    parser.add_argument('--tag', help='desktop-v<version>-<n>')
    parser.add_argument('--commit', help='the commit of a release made here; the tag\'s own commit otherwise')
    parser.add_argument('--name', help='the name of the release (kept as it is when not given)')
    parser.add_argument('--notes', type=pathlib.Path, help='a Markdown file, the notes of the release')
    parser.add_argument('--token-file', type=pathlib.Path, help='a file holding the token')
    parser.add_argument('--api', default=API, help=argparse.SUPPRESS)
    parser.add_argument('--dry-run', action='store_true', help='check and sum the files, no network')
    parser.add_argument('--label', help='with --dry-run: the label of the build, whose seven files must be there')
    parser.add_argument('--sums', type=pathlib.Path, help=f'with --dry-run: write {SUMS} there')
    args = parser.parse_args(argv)

    missing = [str(path) for path in args.files if not path.is_file()]
    if missing:
        print('no such file: ' + ', '.join(missing))
        return 2
    files = [path for path in args.files if path.name != SUMS]
    if len({path.name for path in files}) != len(files):
        print('two files with the same name')
        return 2
    if args.dry_run:
        return dry_run(args, files)
    if not args.repo or not REPO.match(args.repo):
        print('--repo OWNER/NAME is needed')
        return 2
    if not args.tag or not DESKTOP_TAG.match(args.tag):
        print(f'--tag {args.tag!r} is not a desktop pre-release tag (desktop-v<version>-<n>)')
        return 2
    if args.notes and not args.notes.is_file():
        print(f'no notes file at {args.notes}')
        return 2
    token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
    if args.token_file:
        token = args.token_file.read_text(encoding='utf-8').strip()
    if not token:
        print('no token: set GH_TOKEN or GITHUB_TOKEN, or give --token-file')
        return 2
    try:
        return publish(args, files, token)
    except (Failure, urllib.error.URLError, OSError) as error:
        print(f'desktop_release: {error}'.replace(token, '***'))
        return 1


if __name__ == '__main__':
    sys.exit(main())
