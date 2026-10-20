#!/usr/bin/env python3
"""What the self check of the app found on the macOS runner, as Markdown for the run summary.

The macOS job of .github/workflows/immuch360-desktop.yml starts the app three times with IMMUCH360_SELF_CHECK set
(mobile/lib/desktop/window/self_check.dart): "folder", the folder of a photo and a video on the command line, with
the video played by libmpv for five seconds; "video", that video alone; "finder", the photo handed over by Launch
Services as the Finder does (open -a), then the video handed to the copy that runs (finder.json.later, what the app
showed after the report, and finder-then-video.png). Each start leaves <name>.json (the report;
<name>.json.partial instead when the app ended before the last step, with the results of the steps before),
<name>.log, <name>.state and <name>.png in the folder given; a start without arguments or self check before them
leaves plain.state, and the crash reports of macOS (Immuch360*.ips) are copied there too.

  self_check_summary.py FOLDER [--strict]

Prints the table of the checks. With --strict, exits 1 when one of them failed: the app ran 30 s without arguments,
no crash was reported, it started and wrote its report both times, the secure storage gave back the secret it was
given, libmpv was loaded and played the video, the folder opened as a page of its own, the video in the viewer, and
the photo of the Finder's way in the viewer too, then the video handed to the copy that runs.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

# The names of the pages (auto_route) that the files of the command line open
OPENED_FILES_PAGE = 'OpenedFilesRoute'
VIEWER_PAGE = 'AssetViewerRoute'
# The video that make_test_media.swift makes
TEST_VIDEO = 'test-video.mp4'
# The video is played for five seconds from its first frame: some of it may go to the start of the decoder
MIN_PLAYED_SECONDS = 3.0


def read_report(folder: pathlib.Path, name: str) -> tuple[dict | None, bool]:
    """The report of a start and whether it is complete: <name>.json, or what <name>.json.partial holds when the app
    ended before the self check did"""
    for path, complete in ((folder / f'{name}.json', True), (folder / f'{name}.json.partial', False)):
        try:
            return json.loads(path.read_text(encoding='utf-8')), complete
        except (OSError, ValueError):
            continue
    return None, False


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
    folder_report, folder_complete = read_report(folder, 'folder')
    video_report, video_complete = read_report(folder, 'video')
    finder_report, finder_complete = read_report(folder, 'finder')

    for name, report, complete, what in (
            ('folder', folder_report, folder_complete, 'Start with the folder on the command line'),
            ('video', video_report, video_complete, 'Start with the video on the command line'),
            ('finder', finder_report, finder_complete, 'Start by Launch Services with the photo, as from the Finder')):
        detail = state_of(folder, name)
        if report is not None:
            if not complete:
                detail += '; partial report only, the app ended before the last step'
            detail += f"; first page {report.get('firstPage')}, session {report.get('session')}"
            if report.get('error'):
                detail += f"; stopped: {report['error']}"
        results.append((f'{what}, report written', complete, detail))

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
                              ('playedSeconds', 'firstFrameMs', 'size', 'hwdec-current', 'current-tracks/video/codec',
                               'frame-drop-count', 'error') if key in video)))

    folder_pages = (folder_report or {}).get('pages') or []
    results.append(('The folder of the command line opened as a page of its own', OPENED_FILES_PAGE in folder_pages,
                    ' > '.join(folder_pages) or 'no page'))
    video_pages = (video_report or {}).get('pages') or []
    results.append(('The video of the command line opened in the viewer', VIEWER_PAGE in video_pages,
                    ' > '.join(video_pages) or 'no page'))
    finder_pages = (finder_report or {}).get('pages') or []
    results.append(('The photo handed over by Launch Services opened in the viewer', VIEWER_PAGE in finder_pages,
                    ' > '.join(finder_pages) or 'no page'))
    try:
        later = json.loads((folder / 'finder.json.later').read_text(encoding='utf-8'))
    except (OSError, ValueError):
        later = {}
    later_pages = later.get('pages') or []
    results.append(('Then the video handed to the copy that runs opened in the viewer',
                    VIEWER_PAGE in later_pages and later.get('asset') == TEST_VIDEO,
                    f"{' > '.join(later_pages) or 'no change of page seen'}, asset {later.get('asset')}"))
    return results


def markdown(results: list[tuple[str, bool, str]]) -> str:
    lines = ['### Self check of the app on the macOS runner', '', '| Check | Result | Detail |', '|---|---|---|']
    for what, passed, detail in results:
        cell = detail.replace('|', '\\|').replace('\n', ' ')
        lines.append(f"| {what} | {'passed' if passed else 'FAILED'} | {cell} |")
    lines += ['', 'Screen captures: `plain.png`, `folder.png`, `video.png`, `video-2s-later.png`, `finder.png` and '
              '`finder-then-video.png` in the `macos-first-start` artifact.']
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
