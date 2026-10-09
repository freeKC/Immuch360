#!/usr/bin/env python3
"""The checklist of an upstream sync for Immuch360 Desktop (design 8.4 point 7, plan 20 section 9).

An upstream merge can change a contract the desktop classes re-implement in Dart (a pigeon API, the native HTTP
clients, the start of the app, the sync and hash services) or a shared file that holds a desktop wiring point. The
compile and the tests catch a changed signature; they do not catch a changed behaviour, such as a new header the
native clients now send. This report lists, for the files the sync changed, what to read against which desktop file:

  1. the contracts of design 8.4 point 7, with their desktop counterparts;
  2. the shared files with a desktop hand over (an import of lib/desktop, CurrentPlatform.isDesktop, PlatformApis,
     deviceFeaturesProvider);
  3. the files with Platform.isAndroid or Platform.isIOS lines (PLATFORM-AUDIT.md);
  4. the pubspec (the plugin baseline).

  upstream_sync_report.py [--base origin/desktop]   the files changed since the merge base with the desktop branch
  upstream_sync_report.py --changed-from FILE        a list of changed paths instead (one per line)
  --summary FILE                                     also append the report there ($GITHUB_STEP_SUMMARY in CI)

It is a checklist, not a gate: the exit code is 0 unless git fails. Only read-only git commands are run.
"""
from __future__ import annotations

import argparse
import fnmatch
import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
# No __pycache__ folder in the repository for the module below
sys.dont_write_bytecode = True
import check_pigeon_desktop  # noqa: E402  (same folder; the path is set just above)

# What upstream changes and what the desktop re-implements, from design 8.4 point 7. Patterns match the path from the
# repository root or, for the native clients, the file name wherever it moves.
CONTRACTS = (
    ('Pigeon definitions', ('mobile/pigeon/*.dart',), ('the desktop class of each host API (below)',)),
    ('Start of the app', ('mobile/lib/main.dart', 'mobile/lib/utils/bootstrap.dart'),
     ('mobile/lib/main_desktop.dart', 'mobile/lib/desktop/desktop_start.dart')),
    ('HTTP clients and headers',
     ('mobile/lib/infrastructure/repositories/network.repository.dart', 'HttpClientManager.kt',
      'URLSessionManager.swift'),
     ('mobile/lib/desktop/network/desktop_http_stack.dart', 'mobile/lib/desktop/platform/desktop_network_api.dart')),
    ('Video viewer', ('mobile/lib/presentation/widgets/asset_viewer/video_viewer.widget.dart',),
     ('mobile/lib/desktop/video/',)),
    ('Local sync and hashing',
     ('mobile/lib/domain/services/local_sync.service.dart', 'mobile/lib/domain/services/hash.service.dart'),
     ('mobile/lib/desktop/library/folder_library_sync_api.dart',)),
)
HAND_OVER = re.compile(r"package:immich_mobile/desktop/|CurrentPlatform\.isDesktop|PlatformApis\.|deviceFeaturesProvider")
PLATFORM_LINE = re.compile(r'Platform\.is(?:Android|IOS)\b')


def matches(path: str, pattern: str) -> bool:
    if '/' in pattern:
        return fnmatch.fnmatchcase(path, pattern)
    return path.rsplit('/', 1)[-1] == pattern


def report(root: pathlib.Path, changed: list) -> str:
    changed = sorted({p.strip() for p in changed if p.strip()})
    lines = ['## Upstream sync checklist for Immuch360 Desktop', '', f'{len(changed)} files changed.', '']

    lines += ['### 1. Contracts the desktop re-implements', '']
    contract_hits = 0
    implemented = check_pigeon_desktop.desktop_classes(root)
    for label, patterns, desktop in CONTRACTS:
        hits = [p for p in changed if any(matches(p, pattern) for pattern in patterns)]
        if not hits:
            continue
        contract_hits += len(hits)
        lines.append(f'- [ ] **{label}**: read the diff of ' + ', '.join(f'`{p}`' for p in hits)
                     + ' against ' + ', '.join(f'`{d}`' if '/' in d else d for d in desktop))
        if label == 'Pigeon definitions':
            for path in hits:
                file = root / path
                text = file.read_text(encoding='utf-8', errors='replace') if file.exists() else ''
                for api in check_pigeon_desktop.HOST_API.findall(text):
                    where = implemented.get(api, 'no desktop class: see pigeon-not-on-desktop.json')
                    lines.append(f'  - `{api}`: {where}')
    if not contract_hits:
        lines.append('None of them changed.')
    lines.append('')

    lines += ['### 2. Shared files with a desktop hand over', '']
    wired = []
    audited = []
    for path in changed:
        if not path.startswith('mobile/lib/') or path.startswith('mobile/lib/desktop/') or not path.endswith('.dart'):
            continue
        file = root / path
        if not file.exists():
            continue
        text = file.read_text(encoding='utf-8', errors='replace')
        if HAND_OVER.search(text):
            wired.append(path)
        if PLATFORM_LINE.search(text):
            audited.append(path)
    lines += [f'- [ ] `{p}`: the guarded hand over still runs only on the computers' for p in wired] or ['None.']
    lines.append('')

    lines += ['### 3. Files with Platform.isAndroid or Platform.isIOS lines', '']
    lines += ([f'- [ ] `{p}`: its rows in `mobile/lib/desktop/platform/PLATFORM-AUDIT.md`' for p in audited]
              or ['None.'])
    lines += ['', 'The gates job runs `check_platform_audit.py` and `check_platform_ternaries.py` on the result.', '']

    lines += ['### 4. Dependencies', '']
    if any(p in ('mobile/pubspec.yaml', 'mobile/pubspec.lock') for p in changed):
        lines.append('- [ ] The pubspec changed: the test job compares the Android and iOS plugin lists with '
                     '`.github/desktop/plugin-baseline.json`; a new plugin with a Windows, Linux or macOS side needs a '
                     'Windows build through the wrapper.')
    else:
        lines.append('The pubspec did not change.')
    lines.append('')
    return '\n'.join(lines)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--base', default='origin/desktop', help='the desktop branch as the clone knows it')
    parser.add_argument('--changed-from', type=pathlib.Path, help='a file listing changed paths, one per line')
    parser.add_argument('--summary', type=pathlib.Path, help='also append the report to this file')
    parser.add_argument('--root', type=pathlib.Path, default=ROOT, help='repository root')
    args = parser.parse_args(argv)

    if args.changed_from:
        changed = args.changed_from.read_text(encoding='utf-8').splitlines()
    else:
        def git(*command):
            return subprocess.run(['git', '-C', str(args.root), *command], check=True, capture_output=True,
                                  text=True).stdout
        try:
            base = git('merge-base', args.base, 'HEAD').strip()
            changed = git('diff', '--name-only', base, 'HEAD').splitlines()
        except subprocess.CalledProcessError as error:
            print(f'git failed: {error.stderr.strip()} ({args.base} must be in the clone, fetch-depth 0)')
            return 2
    text = report(args.root, changed)
    print(text)
    if args.summary:
        with open(args.summary, 'a', encoding='utf-8') as summary:
            summary.write(text + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
