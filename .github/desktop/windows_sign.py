#!/usr/bin/env python3
"""Signs the Windows files of Immuch360 Desktop with Azure Artifact Signing, on the runner of the release workflow.

Azure Artifact Signing (formerly Trusted Signing) keeps the certificate of the publisher, APROGSYS, issued by
Microsoft (Microsoft ID Verified CS EOC CA 03), and its private key: signtool of the Windows SDK signs through the
client library of the service (the dlib), which sends the digest of each file to the signing account and gets the
signature back. The job sign-windows of .github/workflows/immuch360-desktop-release.yml runs this script. It is the
one desktop job that holds secrets, the three credentials of the signing account (AZURE_TENANT_ID, AZURE_CLIENT_ID,
AZURE_CLIENT_SECRET), which the client reads from the environment; this script never reads them.

  windows_sign.py tools --dir DIR [--packages DIR]
      signtool (Microsoft.Windows.SDK.BuildTools) and the client (Microsoft.ArtifactSigning.Client) from nuget.org,
      at the versions the official azure/artifact-signing-action v2.0.0 installs, each checked by its SHA-256 and
      unpacked in DIR, with metadata.json (endpoint, account, certificate profile) and signing.json, which the
      commands below read. --packages takes the two .nupkg files from a folder instead of nuget.org.
  windows_sign.py bundle --tools DIR --zip FILE --work DIR --out DIR [--github-output]
      unzips the ZIP of windows_bundle.py into the work folder, signs every .exe and .dll there that has no valid
      signature yet (the Visual C++ runtime keeps the signature of Microsoft), checks each of them, writes in
      BUILD-INFO.txt that the build is signed, and writes the ZIP again in <out>, under its name, with the same entries
      in the same order. The signed folder stays in the work folder: desktop_installers.py windows --sign-with DIR
      makes the installer from it, and Inno Setup signs the uninstaller and the installer through the command below.
  windows_sign.py sign --tools DIR FILE ...
      signs the files (SHA-256 digest, RFC 3161 timestamp of Microsoft, SHA-256 too), and tries a file that is not
      signed afterwards twice more; the log of signtool also goes to sign.log in the tools folder, since Inno Setup
      does not show it
  windows_sign.py verify --tools DIR FILE ...
      signtool verify /pa /v of each file: a valid signature of APROGSYS, with a timestamp
  windows_sign.py check --tools DIR --zip FILE --setup FILE [--install-dir DIR] [--github-output]
      the files of a release: every .exe and .dll of the ZIP with a valid signature, immuch360.exe and the installer
      signed by APROGSYS; with --install-dir, a silent installation there for the current user, whose uninstaller
      must be signed by APROGSYS and whose files must be those of the ZIP, byte for byte

--github-output writes the results for the next steps (bundle: folder, file_version; check: zip_sha256,
setup_sha256), and check writes a table in the run summary. signing.json names the signtool command; the tests point
it at a fake signtool. Only the Python standard library is used, as on every runner.
Exit codes: 0 good, 1 a file is not signed as it must be, 2 bad arguments or missing files.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from windows_bundle import UNSIGNED_NOTE, file_version  # noqa: E402

# The signing account: none of these is a secret
PUBLISHER = 'APROGSYS'
ENDPOINT = 'https://weu.codesigning.azure.net/'
ACCOUNT = 'APROGSYS'
PROFILE = 'APROGSYS-PublicTrust'
TIMESTAMP = 'http://timestamp.acs.microsoft.com'
DESCRIPTION = 'Immuch360 Desktop'
DESCRIPTION_URL = 'https://github.com/freeKC/Immuch360'

NUGET = 'https://api.nuget.org/v3-flatcontainer'
# The packages of azure/artifact-signing-action v2.0.0 (its "Set variables" step), with the SHA-256 of each package
# as nuget.org served it on 22 October 2026, when its SHA-512 matched the one of the nuget.org catalog, and the folder
# of the package that is unpacked
PACKAGES = {
    'buildtools': ('Microsoft.Windows.SDK.BuildTools', '10.0.26100.4188',
                   '180deb372659029864c10a0c04787833234d64aacd1d2c0661d2c00295d8e022', 'bin/10.0.26100.0/x64/'),
    'client': ('Microsoft.ArtifactSigning.Client', '1.0.128',
               '74bd7d27e6ce1051409c38d9b46bc8df0400ecd643d51ffbf2ac00869061e40b', 'bin/x64/'),
}
# Every credential of DefaultAzureCredential but the environment's: the client signs with the variables of the job or
# not at all, instead of trying the Azure CLI or a managed identity of the runner
EXCLUDED_CREDENTIALS = [
    'WorkloadIdentityCredential', 'ManagedIdentityCredential', 'SharedTokenCacheCredential', 'VisualStudioCredential',
    'VisualStudioCodeCredential', 'AzureCliCredential', 'AzurePowerShellCredential', 'AzureDeveloperCliCredential',
    'InteractiveBrowserCredential',
]
# What BUILD-INFO.txt says in place of UNSIGNED_NOTE once the folder is signed
SIGNED_NOTE = (
    f'This build is signed: immuch360.exe, the DLLs of the app and the installer show {PUBLISHER} as their publisher',
    '(file properties, Digital Signatures); the Visual C++ runtime DLLs keep the signature of Microsoft.',
)
PE_SUFFIXES = ('.exe', '.dll')
EXE = 'immuch360.exe'
UNINSTALLER = 'unins000.exe'
# The summed length of the paths given to one signtool call, well under the 32767 characters of a command line
BATCH = 16000


class Problem(Exception):
    pass


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def pe_files(folder: pathlib.Path) -> list:
    return sorted(path for path in folder.rglob('*') if path.is_file() and path.suffix.lower() in PE_SUFFIXES)


def github_output(values: dict) -> None:
    target = os.environ.get('GITHUB_OUTPUT')
    if not target:
        raise Problem('--github-output without GITHUB_OUTPUT')
    with open(target, 'a', encoding='utf-8') as stream:
        for key, value in values.items():
            stream.write(f'{key}={value}\n')


# --- the tools ---------------------------------------------------------------------------------------------------


def download(url: str) -> bytes:
    for attempt in range(1, 4):
        try:
            request = urllib.request.Request(url, headers={'User-Agent': 'immuch360-windows-sign'})
            with urllib.request.urlopen(request, timeout=300) as response:
                return response.read()
        except OSError as error:
            if attempt == 3:
                raise Problem(f'{url}: {error}') from None
            print(f'{url}: {error}, trying again')
            time.sleep(10 * attempt)
    raise AssertionError


def tools(args) -> int:
    folder = args.dir.resolve()
    folder.mkdir(parents=True, exist_ok=True)
    for key, (name, version, digest, prefix) in PACKAGES.items():
        file = f'{name.lower()}.{version}.nupkg'
        if args.packages:
            path = args.packages / file
            if not path.is_file():
                raise Problem(f'no {file} in {args.packages}')
            data = path.read_bytes()
        else:
            data = download(f'{NUGET}/{name.lower()}/{version}/{file}')
        found = hashlib.sha256(data).hexdigest()
        if found != digest:
            raise Problem(f'{file}: SHA-256 {found}, {digest} expected')
        target = folder / key
        if target.exists():
            shutil.rmtree(target)
        count = 0
        with zipfile.ZipFile(io.BytesIO(data)) as package:
            for entry in package.infolist():
                if not entry.filename.startswith(prefix) or entry.is_dir():
                    continue
                relative = pathlib.PurePosixPath(entry.filename[len(prefix):])
                if relative.is_absolute() or '..' in relative.parts:
                    raise Problem(f'{file}: unsafe path {entry.filename}')
                out = target.joinpath(*relative.parts)
                out.parent.mkdir(parents=True, exist_ok=True)
                out.write_bytes(package.read(entry))
                count += 1
        print(f'{name} {version}: SHA-256 checked, {count} files in {target}')

    signtool = folder / 'buildtools' / 'signtool.exe'
    dlib = folder / 'client' / 'Azure.CodeSigning.Dlib.dll'
    for path in (signtool, dlib):
        if not path.is_file():
            raise Problem(f'{path.name} is not in its package')
    metadata = {'Endpoint': ENDPOINT, 'CodeSigningAccountName': ACCOUNT, 'CertificateProfileName': PROFILE,
                'ExcludeCredentials': EXCLUDED_CREDENTIALS}
    if os.environ.get('GITHUB_RUN_ID'):
        # Found again in the logs of the signing account
        metadata['CorrelationId'] = (f'{os.environ.get("GITHUB_REPOSITORY", "")} run {os.environ["GITHUB_RUN_ID"]} '
                                     f'attempt {os.environ.get("GITHUB_RUN_ATTEMPT", "1")}')
    (folder / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
    settings = {'signtool': [str(signtool)], 'dlib': str(dlib), 'metadata': str(folder / 'metadata.json'),
                'log': str(folder / 'sign.log')}
    (folder / 'signing.json').write_text(json.dumps(settings, indent=2) + '\n', encoding='utf-8')
    print(f'endpoint {ENDPOINT}, account {ACCOUNT}, certificate profile {PROFILE}: {folder / "signing.json"}')
    return 0


def load_tools(folder: pathlib.Path) -> dict:
    path = folder / 'signing.json'
    if not path.is_file():
        raise Problem(f'no {path}: run windows_sign.py tools --dir {folder} first')
    return json.loads(path.read_text(encoding='utf-8'))


def signtool(settings: dict, arguments: list) -> subprocess.CompletedProcess:
    return subprocess.run(settings['signtool'] + arguments, capture_output=True, text=True, encoding='utf-8',
                          errors='replace')


# --- signing and checking ----------------------------------------------------------------------------------------


def read_signature(output: str) -> dict:
    """The signer, its issuer and the timestamp in the output of signtool verify /pa /v for one file"""
    signer = issuer = None
    chain = output.split('Signing Certificate Chain:', 1)
    if len(chain) == 2:
        section = re.split(r'^\s*(?:The signature is timestamped|File is not timestamped|Timestamp Verified by)',
                           chain[1], maxsplit=1, flags=re.MULTILINE)[0]
        # The chain goes from the root down to the certificate of the signer, the last one
        subjects = re.findall(r'^\s*Issued to:\s*(.+?)\s*$', section, re.MULTILINE)
        issuers = re.findall(r'^\s*Issued by:\s*(.+?)\s*$', section, re.MULTILINE)
        signer = subjects[-1] if subjects else None
        issuer = issuers[-1] if issuers else None
    stamp = re.search(r'^\s*The signature is timestamped:\s*(.+?)\s*$', output, re.MULTILINE)
    return {'signer': signer, 'issuer': issuer, 'timestamp': stamp.group(1) if stamp else None,
            'verified': bool(re.search(r'^\s*Successfully verified:', output, re.MULTILINE))}


def verify_file(settings: dict, path: pathlib.Path) -> dict:
    result = signtool(settings, ['verify', '/pa', '/v', str(path)])
    found = read_signature(result.stdout + result.stderr)
    found['valid'] = result.returncode == 0 and found['verified']
    found['output'] = result.stdout + result.stderr
    return found


def ours(signature: dict) -> bool:
    return bool(signature['valid'] and signature['signer'] == PUBLISHER and signature['timestamp'])


def describe(signature: dict) -> str:
    if not signature['valid']:
        return 'no valid signature'
    stamp = f'timestamped {signature["timestamp"]}' if signature['timestamp'] else 'not timestamped'
    return f'signed by {signature["signer"]} (issuer {signature["issuer"]}), {stamp}'


def batches(files: list) -> list:
    groups, group, size = [], [], 0
    for path in files:
        if group and size + len(str(path)) + 3 > BATCH:
            groups.append(group)
            group, size = [], 0
        group.append(path)
        size += len(str(path)) + 3
    return groups + ([group] if group else [])


def sign_files(settings: dict, files: list, attempts: int = 3) -> None:
    arguments = ['sign', '/v', '/debug', '/fd', 'SHA256', '/tr', TIMESTAMP, '/td', 'SHA256', '/dlib', settings['dlib'],
                 '/dmdf', settings['metadata'], '/d', DESCRIPTION, '/du', DESCRIPTION_URL]
    pending = list(files)
    for attempt in range(1, attempts + 1):
        for group in batches(pending):
            result = signtool(settings, arguments + [str(path) for path in group])
            text = result.stdout + result.stderr
            print(text, end='' if text.endswith('\n') else '\n')
            with open(settings['log'], 'a', encoding='utf-8') as log:
                log.write(text)
            # 0 signed, 2 signed with warnings: each file is checked below whatever signtool answered
            if result.returncode not in (0, 2):
                print(f'signtool exit {result.returncode} for {len(group)} files')
        pending = [path for path in pending if not ours(verify_file(settings, path))]
        if not pending:
            return
        if attempt < attempts:
            print(f'not signed yet: {", ".join(path.name for path in pending)}; trying again')
            time.sleep(15 * attempt)
    raise Problem(f'not signed by {PUBLISHER} with a timestamp: ' + ', '.join(str(path) for path in pending))


def sign(args) -> int:
    settings = load_tools(args.tools)
    files = [pathlib.Path(path).resolve() for path in args.files]
    missing = [str(path) for path in files if not path.is_file()]
    if missing:
        raise FileNotFoundError(', '.join(missing))
    sign_files(settings, files)
    for path in files:
        print(f'{path.name}: {describe(verify_file(settings, path))}')
    return 0


def verify(args) -> int:
    settings = load_tools(args.tools)
    failed = 0
    for name in args.files:
        signature = verify_file(settings, pathlib.Path(name))
        print(f'{name}: {describe(signature)}')
        if not ours(signature):
            print(signature['output'])
            failed += 1
    return 1 if failed else 0


# --- the ZIP -----------------------------------------------------------------------------------------------------


def safe_entries(archive: zipfile.ZipFile) -> list:
    entries = archive.infolist()
    for entry in entries:
        path = pathlib.PurePosixPath(entry.filename)
        if path.is_absolute() or '..' in path.parts or '\\' in entry.filename or ':' in entry.filename:
            raise Problem(f'unsafe path in the ZIP: {entry.filename}')
    tops = {entry.filename.split('/', 1)[0] for entry in entries}
    if len(tops) != 1 or not all('/' in entry.filename for entry in entries):
        raise Problem('the ZIP does not hold one folder, as windows_bundle.py makes it')
    return entries


def signed_info(text: str, name: str) -> str:
    """The text of BUILD-INFO.txt saying the build is signed, whatever its line ends (a Windows run writes \\r\\r\\n)"""
    first, *rest = (re.escape(line) for line in UNSIGNED_NOTE)
    # The end of the first line is kept for every line written
    match = re.search(first + ''.join((r'(\r*\n)' if index == 0 else r'\r*\n') + line
                                      for index, line in enumerate(rest)), text)
    if not match:
        raise Problem(f'{name} does not say that the build is not signed: windows_bundle.py and this script differ')
    separator = match.group(1) if rest else '\r\n'
    return text[:match.start()] + separator.join(SIGNED_NOTE) + text[match.end():]


def repack(entries: list, root: pathlib.Path, out: pathlib.Path) -> None:
    """The ZIP again from the folder: the same entries, in the same order, with their dates and attributes"""
    out.parent.mkdir(parents=True, exist_ok=True)
    partial = out.with_name(out.name + '.partial')
    with zipfile.ZipFile(partial, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for entry in entries:
            info = zipfile.ZipInfo(entry.filename, entry.date_time)
            info.compress_type = entry.compress_type
            info.external_attr = entry.external_attr
            info.create_system = entry.create_system
            data = b'' if entry.is_dir() else root.joinpath(*entry.filename.split('/')).read_bytes()
            archive.writestr(info, data, compresslevel=6)
    partial.replace(out)


def bundle(args) -> int:
    settings = load_tools(args.tools)
    if not args.zip.is_file():
        raise FileNotFoundError(str(args.zip))
    work = args.work.resolve()
    if work.exists():
        shutil.rmtree(work)
    with zipfile.ZipFile(args.zip) as archive:
        entries = safe_entries(archive)
        archive.extractall(work)
    folder = work / entries[0].filename.split('/', 1)[0]
    if not (folder / EXE).is_file():
        raise Problem(f'the ZIP has no {folder.name}/{EXE}')
    # Before anything is signed
    info = folder / 'BUILD-INFO.txt'
    if not info.is_file():
        raise Problem(f'the ZIP has no {folder.name}/{info.name}')
    text = signed_info(info.read_bytes().decode('utf-8'), info.name)

    files = pe_files(folder)
    keep, unsigned = {}, []
    for path in files:
        signature = verify_file(settings, path)
        if signature['valid'] and path.name.lower() != EXE:
            keep[path] = signature
        else:
            unsigned.append(path)
    print(f'{len(files)} .exe and .dll files: {len(unsigned)} to sign, {len(keep)} signed already')
    for path, signature in keep.items():
        print(f'  kept: {path.relative_to(folder).as_posix()}, {describe(signature)}')
    sign_files(settings, unsigned)
    for path in unsigned:
        print(f'  {path.relative_to(folder).as_posix()}: {describe(verify_file(settings, path))}')

    info.write_bytes(text.encode('utf-8'))
    out = args.out.resolve() / args.zip.name
    repack(entries, work, out)
    version = file_version(folder / EXE)
    print(f'{out}: {len(unsigned)} files signed by {PUBLISHER}, {len(entries)} entries as in the build, '
          f'SHA-256 {sha256(out)}; {EXE} file version {version}')
    if args.github_output:
        github_output({'folder': folder, 'file_version': version or ''})
    return 0


# --- the files of a release --------------------------------------------------------------------------------------


def install(setup: pathlib.Path, folder: pathlib.Path) -> None:
    if folder.exists():
        shutil.rmtree(folder)
    log = folder.parent / f'{folder.name}-install.log'
    command = [str(setup), '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER', f'/DIR={folder}',
               f'/LOG={log}']
    print(' '.join(command))
    result = subprocess.run(command, timeout=900)
    if result.returncode != 0:
        if log.is_file():
            print(log.read_text(encoding='utf-8', errors='replace')[-4000:])
        raise Problem(f'the silent installation failed (exit {result.returncode})')


def check(args) -> int:
    settings = load_tools(args.tools)
    for path in (args.zip, args.setup):
        if not path.is_file():
            raise FileNotFoundError(str(path))
    problems, rows = [], []

    def expect_ours(name: str, signature: dict) -> None:
        rows.append((name, signature))
        if not ours(signature):
            problems.append(f'{name}: {describe(signature)}, {PUBLISHER} with a timestamp expected')
            print(signature['output'])

    with tempfile.TemporaryDirectory() as temp:
        unpacked = pathlib.Path(temp)
        with zipfile.ZipFile(args.zip) as archive:
            entries = safe_entries(archive)
            archive.extractall(unpacked)
        folder = unpacked / entries[0].filename.split('/', 1)[0]
        others = {}
        for path in pe_files(folder):
            name = path.relative_to(folder).as_posix()
            signature = verify_file(settings, path)
            if name.lower() == EXE:
                expect_ours(f'ZIP: {name}', signature)
            elif not signature['valid']:
                problems.append(f'ZIP: {name}: {describe(signature)}')
                print(signature['output'])
            elif signature['signer'] == PUBLISHER and not signature['timestamp']:
                problems.append(f'ZIP: {name}: signed by {PUBLISHER} without a timestamp')
            else:
                others.setdefault(signature['signer'], []).append(name)
        expect_ours(f'installer: {args.setup.name}', verify_file(settings, args.setup))

        if args.install_dir:
            installed = args.install_dir.resolve()
            install(args.setup.resolve(), installed)
            expect_ours(f'installed: {UNINSTALLER}', verify_file(settings, installed / UNINSTALLER))
            zipped = {path.relative_to(folder).as_posix() for path in folder.rglob('*') if path.is_file()}
            present = {path.relative_to(installed).as_posix() for path in installed.rglob('*') if path.is_file()}
            for name in sorted(zipped - present):
                problems.append(f'installed: {name} of the ZIP is missing')
            for name in sorted(present - zipped):
                if not re.match(r'^unins\d{3}\.(exe|dat)$', name, re.IGNORECASE):
                    problems.append(f'installed: {name} is not in the ZIP')
            for name in sorted(zipped & present):
                if sha256(folder / name) != sha256(installed / name):
                    problems.append(f'installed: {name} differs from the one of the ZIP')
            print(f'installed in {installed}: {len(zipped & present)} files of the ZIP, byte for byte')

    for signer, names in sorted(others.items()):
        print(f'ZIP: signed by {signer}: {", ".join(names)}')
    for name, signature in rows:
        print(f'{name}: {describe(signature)}')
    sums = {'zip_sha256': sha256(args.zip), 'setup_sha256': sha256(args.setup)}
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a', encoding='utf-8') as stream:
            stream.write('### Signed Windows files\n\n| File | Signature |\n|---|---|\n')
            for name, signature in rows:
                stream.write(f'| `{name}` | {describe(signature)} |\n')
            for signer, names in sorted(others.items()):
                stream.write(f'| ZIP: {len(names)} other .exe and .dll | signed by {signer} |\n')
            stream.write(f'\n`{args.zip.name}`: SHA-256 `{sums["zip_sha256"]}`\n\n'
                         f'`{args.setup.name}`: SHA-256 `{sums["setup_sha256"]}`\n\n')
            stream.write(('Problems: ' + '; '.join(problems)) if problems else 'Every file is signed as it must be.')
            stream.write('\n')
    if problems:
        for line in problems:
            print(f'windows_sign: {line}')
        return 1
    if args.github_output:
        github_output(sums)
    return 0


# --- command line ------------------------------------------------------------------------------------------------


def main(argv=None) -> int:
    sys.stdout.reconfigure(line_buffering=True)
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest='command', required=True)
    get = commands.add_parser('tools', help='signtool and the Artifact Signing client, checked')
    get.add_argument('--dir', type=pathlib.Path, required=True)
    get.add_argument('--packages', type=pathlib.Path, help='a folder holding the two .nupkg files')
    pack = commands.add_parser('bundle', help='sign the folder of the ZIP and write the ZIP again')
    pack.add_argument('--tools', type=pathlib.Path, required=True)
    pack.add_argument('--zip', type=pathlib.Path, required=True)
    pack.add_argument('--work', type=pathlib.Path, required=True)
    pack.add_argument('--out', type=pathlib.Path, required=True)
    pack.add_argument('--github-output', action='store_true')
    one = commands.add_parser('sign', help='sign files')
    one.add_argument('--tools', type=pathlib.Path, required=True)
    one.add_argument('files', nargs='+')
    see = commands.add_parser('verify', help='check the signature of files')
    see.add_argument('--tools', type=pathlib.Path, required=True)
    see.add_argument('files', nargs='+')
    final = commands.add_parser('check', help='check the ZIP and the installer of a release')
    final.add_argument('--tools', type=pathlib.Path, required=True)
    final.add_argument('--zip', type=pathlib.Path, required=True)
    final.add_argument('--setup', type=pathlib.Path, required=True)
    final.add_argument('--install-dir', type=pathlib.Path, help='install the setup there, silently, and check it')
    final.add_argument('--github-output', action='store_true')
    args = parser.parse_args(argv)
    try:
        return {'tools': tools, 'bundle': bundle, 'sign': sign, 'verify': verify, 'check': check}[args.command](args)
    except Problem as error:
        print(f'windows_sign: {error}')
        return 1
    except (OSError, ValueError, zipfile.BadZipFile, json.JSONDecodeError) as error:
        print(f'windows_sign: {error}')
        return 2


if __name__ == '__main__':
    sys.exit(main())
