#!/usr/bin/env python3
"""What the self check of the app found on the macOS runner, as Markdown for the run summary.

The macOS job of .github/workflows/immuch360-desktop.yml starts the app twice with IMMUCH360_SELF_CHECK set
(mobile/lib/desktop/window/self_check.dart): "folder", the folder of a photo and a video on the command line, with
the video played by libmpv for five seconds; "video", that video alone. Each start leaves <name>.json (the report),
<name>.log, <name>.state and <name>.png in the folder given; a start without arguments or self check before them
leaves plain.state, and the crash reports of macOS (Immuch360*.ips) are copied there too.

  self_check_summary.py FOLDER [--strict]

Prints the table of the checks. With --strict, exits 1 when one of them failed: the app ran 30 s without arguments,
no crash was reported, it started and wrote its report both times, the secure storage gave back the secret it was
given, libmpv was loaded and played the video, the folder opened as a page of its own and the video in the viewer.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

# The names of the pages (auto_route) that the files of the command line open
OPENED_FILES_PAGE = 'OpenedFilesRoute'
VIEWER_PAGE = 'AssetViewerRoute'
# The video is played for five seconds from its first frame: some of it may go to the start of the decoder
MIN_PLAYED_SECONDS = 3.0


def read_report(folder: pathlib.Path, name: str) -> dict | None:
    path = folder / f'{name}.json'
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return None


def state_of(folder: pathlib.Path, name: str) -> str:
    try:
        return (folder / f'{name}.state').read_text(encoding='utf-8').strip()
    except OSError:
        return f'{name}: not started'


def checks(folder: pathlib.Path) -> list[tuple[str, bool, str]]:
    """Each check as (what, passed, detail)"""
    results: list[tuple[str, bool, str]] = []
    plain = state_of(folder, 'plain')
    results.append(('Start without arguments or self check, as a user would, for 30 s', 'still running' in plain,
                    plain))
    crashes = sorted(path.name for path in folder.glob('Immuch360*'))
    if crashes:
        results.append(('Crash reports of macOS', False, ', '.join(crashes)))
    folder_report = read_report(folder, 'folder')
    video_report = read_report(folder, 'video')

    for name, report in (('folder', folder_report), ('video', video_report)):
        detail = state_of(folder, name)
        if report is not None:
            detail += f"; first page {report.get('firstPage')}, session {report.get('session')}"
            if report.get('error'):
                detail += f"; stopped: {report['error']}"
        results.append((f'Start with the {name} on the command line, report written', report is not None, detail))

    storage = (folder_report or {}).get('secureStorage') or {}
    app = storage.get('app') or {}
    results.append(('Secure storage as the app uses it (login keychain): write, read back, delete',
                    app.get('ok') is True, json.dumps(app)))
    if 'dataProtectionKeychain' in storage:
        protected = storage['dataProtectionKeychain'] or {}
        # For the record: what the plugin's default would do in a build signed for the computer only
        results.append(('For the record, not a check: the plugin default (data protection keychain)', True,
                        json.dumps(protected)))

    video = (folder_report or {}).get('video') or {}
    played = video.get('playedSeconds')
    results.append(('libmpv loaded at start', video.get('loaded') is True,
                     f"bundled {video.get('bundled')}, {video.get('mpvVersion', 'no mpv version')}, "
                     f"{video.get('ffmpegVersion', 'no FFmpeg version')}"))
    results.append((f'The test video played by libmpv for five seconds (at least {MIN_PLAYED_SECONDS:g} s of it)',
                    isinstance(played, (int, float)) and played >= MIN_PLAYED_SECONDS,
                    ', '.join(f'{key} {video.get(key)}' for key in
                              ('playedSeconds', 'firstFrameMs', 'size', 'hwdec-current', 'video-codec',
                               'frame-drop-count', 'error') if key in video)))

    folder_pages = (folder_report or {}).get('pages') or []
    results.append(('The folder of the command line opened as a page of its own', OPENED_FILES_PAGE in folder_pages,
                    ' > '.join(folder_pages) or 'no page'))
    video_pages = (video_report or {}).get('pages') or []
    results.append(('The video of the command line opened in the viewer', VIEWER_PAGE in video_pages,
                    ' > '.join(video_pages) or 'no page'))
    return results


def markdown(results: list[tuple[str, bool, str]]) -> str:
    lines = ['### Self check of the app on the macOS runner', '', '| Check | Result | Detail |', '|---|---|---|']
    for what, passed, detail in results:
        cell = detail.replace('|', '\\|').replace('\n', ' ')
        lines.append(f"| {what} | {'passed' if passed else 'FAILED'} | {cell} |")
    lines += ['', 'Screen captures: `plain.png`, `folder.png`, `video.png` and `video-2s-later.png` in the '
              '`macos-first-start` artifact.']
    return '\n'.join(lines) + '\n'


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('folder', type=pathlib.Path, help='the folder of the reports')
    parser.add_argument('--strict', action='store_true', help='exit 1 when a check failed')
    args = parser.parse_args()
    results = checks(args.folder)
    sys.stdout.write(markdown(results))
    if args.strict and not all(passed for _, passed, _ in results):
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
