#!/usr/bin/env python3
"""Checks that a libmpv reads a y4m, 8 and 10 bit, from a file and over HTTP with seeks, as the AV2 path needs.

The AV2 decoder of Immuch360 Desktop (immuch360-av2) serves libmpv the decoded frames as a y4m over HTTP on 127.0.0.1;
mpv reads it with FFmpeg's yuv4mpegpipe demuxer and rawvideo decoder and seeks in it by range requests. The macOS
libmpv had neither until the overlay added them (mk-pkg-ffmpeg-meson.build). This script writes two y4m fixtures,
builds y4m_probe.c against the libmpv given, serves the fixtures on 127.0.0.1 with ranges, and runs the probe on each
fixture twice: from the file (mpv finds the format by itself) and over HTTP with the format forced, as the app opens
the AV2 decoder's stream. Every check must pass:

  - the demuxer is yuv4mpegpipe, the codec rawvideo, the pixel format yuv420p or yuv420p10, the size, the frame rate
    and the duration those of the fixture;
  - the first frame, then the frames of an exact seek forward and of an exact seek back, have the grey of their frame
    number (each frame of a fixture is one grey, a step brighter than the one before), so the samples were read as
    written, 10 bit included;
  - the playback reached the end, at the time of the last frame, without a dropped frame;
  - over HTTP, the seek back asked the server for a range that starts on a frame of the stream (a seek forward within
    the TCP window is read through by FFmpeg, without a request).

  check_y4m.py run (--zips ZIP... | --frameworks DIR | --system) [--headers DIR] [--search-headers DIR...]
                   [--summary FILE] [--work DIR]
      --zips        the xcframework zips of a build of immuch360-libmpv.yml (Mpv and the libraries it loads)
      --frameworks  a folder of .framework, such as Contents/Frameworks of the app
      --system      the libmpv of the system, by pkg-config (Linux)
      --headers     the folder of mpv's client.h when the frameworks have no headers (the app's are stripped);
      --search-headers  folders to look for Mpv.framework/Headers/client.h in instead
      On macOS every architecture of Mpv.framework that this Mac runs is checked (x86_64 under Rosetta when it is
      installed). --summary writes one line saying what passed, for BUILDINFO-macos.txt. Exit 1 when a check failed.
  check_y4m.py fixture OUT --depth 8|10
      writes a fixture
  check_y4m.py serve --seconds S --port-file FILE
      serves the two fixtures, S seconds long, on 127.0.0.1 with ranges until stopped, and writes its port to FILE: the
      self check of the app (immuch360-desktop.yml) plays the 10 bit one over HTTP, as the app opens the stream of the
      AV2 decoder
  check_y4m.py evaluate REPORT --depth 8|10 [--http --ranges START...]
      judges the JSON a probe printed (the tests give it reports of their own); exit 1 when a check failed
  check_y4m.py companion (--zips ZIP... | --frameworks DIR | --system) [--headers DIR] [--search-headers DIR...]
                         --program FILE --stream FILE[:TIMES]... [--summary FILE] [--work DIR]
      the AV2 path itself (review of lot AD4, m8): the serve of immuch360-av2 (the program of an av2-* archive), fed
      by the app's side in Python (.github/desktop/av2/av2_serve_check.py), on each stream given (played TIMES times
      in a row), read by the probe over its HTTP/1.1 connection with the options the app opens an AV2 video with
      (the y4m demuxer forced, the cache of a streamed video and av2CacheBytes, the wait after a stall): the demuxer
      and decoder, the size, rate and length of the stream, a first frame, exact seeks forward and back, the end
      without a dropped frame, and the frames a second of the untimed playback, written in the table and the summary
  check_y4m.py evaluate-companion REPORT --width W --height H --depth 8|10 --frames N --fps F --forward K --back K
      judges a probe's report of the AV2 path (the tests)
"""
from __future__ import annotations

import argparse
import http.server
import json
import pathlib
import platform
import shutil
import subprocess
import sys
import tempfile
import threading

HERE = pathlib.Path(__file__).resolve().parent
PROBE_SOURCE = HERE / 'y4m_probe.c'
# The app's side of the AV2 decoder, for the companion check
AV2_SCRIPTS = HERE.parent / 'av2'

# The fixtures: big enough frames that a seek goes back to the server, few enough that both stay small
WIDTH = 320
HEIGHT = 180
FRAMES = 32
FPS = 16
# The seek forward, then the seek back
FORWARD_FRAME = 24
BACK_FRAME = 8
# Frame k is one grey: luma 16 + 6k (limited range) on 8 bits, four times that on 10 bits; chroma at the middle
LUMA_STEP = 6
# How far the grey of a frame on screen may be from the expected one (the conversion to RGB may dither)
GREY_TOLERANCE = 2.5
PROBE_TIMEOUT = 90


def header(depth: int) -> bytes:
    """The y4m header, as immuch360-av2 writes it (C420 on 8 bits, C420p10 on 10, the range said)"""
    colour = 'C420' if depth == 8 else 'C420p10'
    return f'YUV4MPEG2 W{WIDTH} H{HEIGHT} F{FPS}:1 Ip A1:1 {colour} XCOLORRANGE=LIMITED\n'.encode('ascii')


def frame_size(depth: int) -> int:
    return WIDTH * HEIGHT * 3 // 2 * (1 if depth == 8 else 2)


def frame_offset(depth: int, frame: int) -> int:
    """Where the FRAME line of [frame] starts in the stream"""
    return len(header(depth)) + frame * (len(b'FRAME\n') + frame_size(depth))


def luma(frame: int) -> int:
    return 16 + LUMA_STEP * frame


def expected_grey(frame: int) -> float:
    """The grey of [frame] on screen: limited range luma to full range RGB"""
    return (luma(frame) - 16) * 255 / 219


def fixture(depth: int, frames: int = FRAMES) -> bytes:
    parts = [header(depth)]
    for frame in range(frames):
        if depth == 8:
            y, c = bytes([luma(frame % FRAMES)]), bytes([128])
        else:
            y, c = (luma(frame % FRAMES) * 4).to_bytes(2, 'little'), (512).to_bytes(2, 'little')
        parts += [b'FRAME\n', y * (WIDTH * HEIGHT), c * (WIDTH * HEIGHT // 2)]
    return b''.join(parts)


def near(value, expected: float, tolerance: float) -> bool:
    return isinstance(value, (int, float)) and abs(value - expected) <= tolerance


def grey_of(frame) -> float | None:
    """The grey of a frame of the report: blue, green and red alike, or None"""
    if not isinstance(frame, dict) or not isinstance(frame.get('bgr'), list) or len(frame['bgr']) != 3:
        return None
    blue, green, red = frame['bgr']
    if max(blue, green, red) - min(blue, green, red) > GREY_TOLERANCE:
        return None
    return (blue + green + red) / 3


def evaluate(report: dict, depth: int, http: bool, ranges: list[int]) -> list[tuple[str, bool, str]]:
    """Each check of a probe's report as (what, passed, detail)"""
    results = []

    def check(what: str, passed: bool, detail) -> None:
        results.append((what, bool(passed), str(detail)))

    error = report.get('error')
    check('opened and played', error is None and 'file-format' in report, error or 'no error')
    check('demuxer yuv4mpegpipe', report.get('file-format') == 'yuv4mpegpipe', report.get('file-format'))
    check('decoder rawvideo', report.get('current-tracks/video/codec') == 'rawvideo',
          report.get('current-tracks/video/codec'))
    formats = ('yuv420p',) if depth == 8 else ('yuv420p10', 'yuv420p10le')
    check(f'pixel format {formats[0]}', report.get('video-params/pixelformat') in formats,
          report.get('video-params/pixelformat'))
    size = f"{report.get('video-params/w')}x{report.get('video-params/h')}"
    check(f'size {WIDTH}x{HEIGHT}', size == f'{WIDTH}x{HEIGHT}', size)
    check(f'{FPS} frames per second', near(report.get('container-fps'), FPS, 0.01), report.get('container-fps'))
    check(f'duration {FRAMES / FPS:g} s', near(report.get('duration'), FRAMES / FPS, 0.5 / FPS), report.get('duration'))

    first = grey_of(report.get('firstFrame'))
    check('first frame: frame 0', near(report.get('firstTime'), 0, 0.5 / FPS) and
          first is not None and near(first, expected_grey(0), GREY_TOLERANCE),
          f"time {report.get('firstTime')}, grey {first} for {expected_grey(0):.1f}")
    for name, frame in (('forward', FORWARD_FRAME), ('back', BACK_FRAME)):
        time, grey = report.get(f'{name}Time'), grey_of(report.get(f'{name}Frame'))
        check(f'exact seek {name}: frame {frame}', near(time, frame / FPS, 0.5 / FPS) and
              grey is not None and near(grey, expected_grey(frame), GREY_TOLERANCE),
              f'time {time} for {frame / FPS:g}, grey {grey} for {expected_grey(frame):.1f}')
    drops = (report.get('frame-drop-count'), report.get('decoder-frame-drop-count'))
    check('played to the last frame, none dropped',
          near(report.get('endTime'), (FRAMES - 1) / FPS, 0.5 / FPS) and drops == ('0', '0'),
          f"time {report.get('endTime')} for {(FRAMES - 1) / FPS:g}, dropped {drops[0]} and {drops[1]} (decoder)")
    if http:
        frames = [frame for frame in range(1, BACK_FRAME + 1) if frame_offset(depth, frame) in ranges]
        check('over HTTP, the seek back asked for a range from a frame', bool(frames),
              f"ranges from {sorted(set(ranges))}, frames {frames}")
    return results


# The options the app opens the y4m of an AV2 companion with, beyond the probe's (desktop_player.dart, forOpen of a
# streamed video, and av2MpvOptions of av2_playback.dart); demuxer-max-bytes comes from av2_cache_bytes
APP_AV2_OPTIONS = {'cache': 'yes', 'cache-secs': '60', 'demuxer-max-back-bytes': str(32 * 1024 * 1024),
                   'cache-pause-wait': '1', 'cache-on-disk': 'no'}
# Where the companion check seeks, in seconds of the stream: forward past the cache filled at the start, then back
# beyond what mpv keeps behind, so that both reach the companion as ranges
COMPANION_FORWARD = 0.7
COMPANION_BACK = 0.2


def av2_cache_bytes(frame_bytes: int, fps: float) -> int:
    """av2CacheBytes of av2_playback.dart: 256 MiB, raised up to 512 MiB while that holds less than a second"""
    floor, ceiling = 256 * 1024 * 1024, 512 * 1024 * 1024
    second = int(-(-((frame_bytes + 6) * fps) // 1))
    return floor if second <= floor else min(ceiling, second)


def evaluate_companion(report: dict, width: int, height: int, depth: int, frames: int, fps: float, forward: int,
                       back: int) -> list[tuple[str, bool, str]]:
    """Each check of a probe's report of the AV2 path as (what, passed, detail); the last row is the speed"""
    results = []

    def check(what: str, passed: bool, detail) -> None:
        results.append((what, bool(passed), str(detail)))

    error = report.get('error')
    check('opened and played', error is None and 'file-format' in report, error or 'no error')
    check('demuxer yuv4mpegpipe', report.get('file-format') == 'yuv4mpegpipe', report.get('file-format'))
    check('decoder rawvideo', report.get('current-tracks/video/codec') == 'rawvideo',
          report.get('current-tracks/video/codec'))
    formats = ('yuv420p',) if depth == 8 else ('yuv420p10', 'yuv420p10le')
    check(f'pixel format {formats[0]}', report.get('video-params/pixelformat') in formats,
          report.get('video-params/pixelformat'))
    size = f"{report.get('video-params/w')}x{report.get('video-params/h')}"
    check(f'size {width}x{height}', size == f'{width}x{height}', size)
    check(f'{fps:g} frames per second', near(report.get('container-fps'), fps, 0.01), report.get('container-fps'))
    check(f'duration {frames / fps:g} s', near(report.get('duration'), frames / fps, 0.5 / fps), report.get('duration'))
    picture = report.get('firstFrame')
    check('a first frame', near(report.get('firstTime'), 0, 0.5 / fps) and isinstance(picture, dict),
          f"time {report.get('firstTime')}, after {report.get('openSeconds')} s")
    for name, frame in (('forward', forward), ('back', back)):
        time, shown = report.get(f'{name}Time'), report.get(f'{name}Frame')
        check(f'exact seek {name}: frame {frame}', near(time, frame / fps, 0.5 / fps) and isinstance(shown, dict),
              f'time {time} for {frame / fps:g}')
    drops = (report.get('frame-drop-count'), report.get('decoder-frame-drop-count'))
    check('played to the last frame, none dropped',
          near(report.get('endTime'), (frames - 1) / fps, 0.5 / fps) and drops == ('0', '0'),
          f"time {report.get('endTime')} for {(frames - 1) / fps:g}, dropped {drops[0]} and {drops[1]} (decoder)")
    start, seconds, end = report.get('playFrom'), report.get('playSeconds'), report.get('endTime')
    speed = None
    if all(isinstance(value, (int, float)) for value in (start, seconds, end)) and seconds > 0:
        speed = ((end - start) * fps + 1) / seconds
    check('frames a second of the untimed playback', speed is not None,
          f'{speed:.1f} for {fps:g} needed' if speed is not None else 'not measured')
    return results


def companion(args) -> int:
    sys.path.insert(0, str(AV2_SCRIPTS))
    import av2_serve_check as serve_check  # noqa: E402

    program = pathlib.Path(args.program).resolve()
    with tempfile.TemporaryDirectory() as temp:
        work = pathlib.Path(args.work) if args.work else pathlib.Path(temp)
        work.mkdir(parents=True, exist_ok=True)
        probes, origin = build_probes(args, work)
        if not probes:
            print('no architecture of the library runs here')
            return 1
        rows, speeds, failed = [], [], False
        for given in args.stream:
            path_text, _, times_text = given.rpartition(':') if given.rpartition(':')[2].isdigit() else (given, '', '')
            path, times = pathlib.Path(path_text), int(times_text or 1)
            stream = serve_check.Stream(path)
            code, info = serve_check.probe(program, path)
            if code != 0 or not info.get('playable'):
                rows.append((path.name, 'the probe of the companion', False, f'exit {code}, {info}'))
                failed = True
                continue
            served = serve_check.Repeated(stream, times) if times > 1 else stream
            picture = info['picture']
            width, height, depth = picture['width'], picture['height'], picture['bits']
            rate, scale = stream.fps
            fps = rate / scale
            frames = len(served.units)
            frame_bytes = width * height * 3 // 2 * (1 if depth == 8 else 2)
            forward = min(frames - 1, round(frames * COMPANION_FORWARD))
            back = round(frames * COMPANION_BACK)
            options = {**APP_AV2_OPTIONS, 'demuxer-max-bytes': str(av2_cache_bytes(frame_bytes, fps))}
            for arch, command in probes:
                where = f'{arch}, {path.name} x{times}, {width}x{height} {depth} bit'
                runner = serve_check.Companion(program, served, info)
                try:
                    probe = command + [runner.url, f'{forward / fps:.6f}', f'{back / fps:.6f}', 'yuv4mpegpipe',
                                       *(f'{key}={value}' for key, value in options.items())]
                    try:
                        done = _run(probe, timeout=PROBE_TIMEOUT)
                        report = json.loads(done.stdout)
                    except subprocess.TimeoutExpired:
                        report = {'error': f'no answer from the probe within {PROBE_TIMEOUT} s'}
                    except ValueError:
                        report = {'error': f'no report (exit {done.returncode}): {done.stderr.strip()[-400:]}'}
                    requests = [text for text in runner.texts() if text.startswith('request ')]
                    stat = runner.last_stat()
                finally:
                    exit_code, gone = runner.close()
                results = evaluate_companion(report, width, height, depth, frames, fps, forward, back)
                measured = stat.get('fps', 'not measured yet')
                results.append(('the companion served the player', bool(requests) and exit_code == 0,
                                f'{len(requests)} requests on its HTTP/1.1 connection, its speed {measured} '
                                f'frames a second, gone in {gone:.2f} s with code {exit_code}'))
                for what, passed, detail in results:
                    rows.append((where, what, passed, detail))
                    failed |= not passed
                    if what.startswith('frames a second') and passed:
                        speeds.append(f'{where}: {detail}')
                if report.get('log'):
                    print(f'{where}: mpv said: {report["log"].strip()}')
        print(f'### libmpv reads the AV2 decoder\n\nLibrary: {origin}; companion: {program.name}\n')
        print('| Run | Check | Result | Detail |\n|---|---|---|---|')
        for where, what, passed, detail in rows:
            cell = detail.replace('|', '\\|').replace('\n', ' ')
            print(f"| {where} | {what} | {'passed' if passed else 'FAILED'} | {cell} |")
        verdict = 'FAILED' if failed else 'passed'
        line = (f'AV2 path check (check_y4m.py companion): {verdict}, {len(rows)} checks; the serve of {program.name} '
                f'read by this libmpv with the options of the app; ' + '; '.join(speeds))
        print(f'\n{line}')
        if args.summary:
            pathlib.Path(args.summary).write_text(line + '\n', encoding='utf-8')
        return 1 if failed else 0


class _Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, files: dict[str, bytes]):
        self.files = files
        self.ranges: dict[str, list[int]] = {name: [] for name in files}
        super().__init__(('127.0.0.1', 0), _Handler)


class _Handler(http.server.BaseHTTPRequestHandler):
    """GET and HEAD with one range (bytes=start- or start-end), as the AV2 decoder answers mpv"""
    server: _Server

    def log_message(self, *args) -> None:
        pass

    def _send(self, body: bool) -> None:
        name = self.path.lstrip('/')
        data = self.server.files.get(name)
        if data is None:
            self.send_error(404)
            return
        start, end = 0, len(data) - 1
        wanted = self.headers.get('Range')
        if wanted:
            first, _, last = wanted.removeprefix('bytes=').partition('-')
            start = int(first)
            end = min(int(last), end) if last else end
            if start > end:
                self.send_response(416)
                self.send_header('Content-Range', f'bytes */{len(data)}')
                self.end_headers()
                return
            self.server.ranges[name].append(start)
            self.send_response(206)
            self.send_header('Content-Range', f'bytes {start}-{end}/{len(data)}')
        else:
            self.send_response(200)
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Type', 'video/x-yuv4mpeg')
        self.send_header('Content-Length', str(end - start + 1))
        self.end_headers()
        if body:
            try:
                self.wfile.write(memoryview(data)[start:end + 1])
            except (BrokenPipeError, ConnectionResetError):
                pass  # mpv closes a stream it seeks away from

    def do_GET(self) -> None:
        self._send(True)

    def do_HEAD(self) -> None:
        self._send(False)


def _run(command: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(command, capture_output=True, text=True, **kwargs)


def frameworks_from_zips(zips: list[str], work: pathlib.Path) -> pathlib.Path:
    """The macOS slice of each xcframework of the zips, side by side in one folder"""
    folder = work / 'frameworks'
    folder.mkdir(exist_ok=True)
    for name in zips:
        unpacked = work / 'unzip'
        # unzip keeps the symbolic links of a framework
        subprocess.run(['unzip', '-q', name, '-d', str(unpacked)], check=True)
        for framework in unpacked.glob('*.xcframework/macos-*/*.framework'):
            shutil.move(str(framework), str(folder / framework.name))
        shutil.rmtree(unpacked)
    # Signed for this computer, as the build of the app signs them when it copies them into the app: Apple silicon
    # loads no code without a valid signature, and the zips' may not be one after the build changed install names
    for framework in sorted(folder.glob('*.framework')):
        signed = _run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(framework)])
        if signed.returncode != 0:
            raise SystemExit(f'codesign {framework.name}: {signed.stderr.strip()}')
    return folder


def find_client_header(roots: list[pathlib.Path]) -> pathlib.Path | None:
    for root in roots:
        if not root.is_dir():
            continue
        for header_file in sorted(root.rglob('client.h')):
            if 'Mpv.framework' in header_file.parts and header_file.parent.name == 'Headers':
                return header_file
    return None


def build_probes(args, work: pathlib.Path) -> tuple[list[tuple[str, list[str]]], str]:
    """The probe built for each architecture this machine runs, as (architecture, command), and what was built from"""
    include = work / 'include' / 'mpv'
    include.mkdir(parents=True, exist_ok=True)
    if args.system:
        flags = _run(['pkg-config', '--cflags', '--libs', 'mpv'])
        if flags.returncode != 0:
            raise SystemExit(f'pkg-config found no libmpv: {flags.stderr.strip()}')
        probe = work / 'y4m_probe'
        built = _run(['cc', '-std=c11', '-O1', '-o', str(probe), str(PROBE_SOURCE), *flags.stdout.split()])
        if built.returncode != 0:
            raise SystemExit(f'the probe did not build:\n{built.stderr}')
        version = _run(['pkg-config', '--modversion', 'mpv']).stdout.strip()
        return [(platform.machine(), [str(probe)])], f'the libmpv of the system (client API {version})'

    folder = frameworks_from_zips(args.zips, work) if args.zips else pathlib.Path(args.frameworks).resolve()
    mpv = folder / 'Mpv.framework' / 'Mpv'
    if not mpv.exists():
        raise SystemExit(f'no Mpv.framework in {folder}')
    if args.headers:
        client = pathlib.Path(args.headers) / 'client.h'
    else:
        client = find_client_header([folder] + [pathlib.Path(root) for root in args.search_headers or []])
    if client is None or not client.is_file():
        raise SystemExit('no client.h of Mpv.framework: give --headers or --search-headers')
    shutil.copy(client, include / 'client.h')
    archs = _run(['lipo', '-archs', str(mpv)]).stdout.split()
    probes = []
    for arch in archs:
        probe = work / f'y4m_probe-{arch}'
        built = _run(['cc', '-arch', arch, '-std=c11', '-O1', '-o', str(probe), str(PROBE_SOURCE),
                      '-I', str(work / 'include'), '-F', str(folder), '-framework', 'Mpv',
                      '-Wl,-rpath,' + str(folder)])
        if built.returncode != 0:
            raise SystemExit(f'the probe did not build for {arch}:\n{built.stderr}')
        command = ['arch', f'-{arch}', str(probe)]
        if _run(['arch', f'-{arch}', '/usr/bin/true']).returncode != 0:
            print(f'{arch}: this Mac does not run it (no Rosetta), not checked')
            continue
        probes.append((arch, command))
    return probes, f'{mpv} ({", ".join(archs)})'


def run(args) -> int:
    with tempfile.TemporaryDirectory() as temp:
        work = pathlib.Path(args.work) if args.work else pathlib.Path(temp)
        work.mkdir(parents=True, exist_ok=True)
        probes, origin = build_probes(args, work)
        if not probes:
            print('no architecture of the library runs here')
            return 1
        files = {f'fixture-{depth}bit.y4m': fixture(depth) for depth in (8, 10)}
        for name, data in files.items():
            (work / name).write_bytes(data)
        server = _Server(files)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        port = server.server_address[1]
        rows, failed = [], False
        try:
            for arch, command in probes:
                for depth in (8, 10):
                    name = f'fixture-{depth}bit.y4m'
                    for http in (False, True):
                        source = f'http://127.0.0.1:{port}/{name}' if http else str(work / name)
                        server.ranges[name].clear()
                        seeks = [f'{FORWARD_FRAME / FPS:.6f}', f'{BACK_FRAME / FPS:.6f}']
                        probe = command + [source, *seeks] + (['yuv4mpegpipe'] if http else [])
                        done = _run(probe, timeout=PROBE_TIMEOUT)
                        try:
                            report = json.loads(done.stdout)
                        except ValueError:
                            report = {'error': f'no report (exit {done.returncode}): {done.stderr.strip()[-400:]}'}
                        where = f"{arch}, {depth} bit, {'HTTP, format forced' if http else 'file'}"
                        for what, passed, detail in evaluate(report, depth, http, list(server.ranges[name])):
                            rows.append((where, what, passed, detail))
                            failed |= not passed
                        if report.get('log'):
                            print(f'{where}: mpv said: {report["log"].strip()}')
        finally:
            server.shutdown()
        print(f'### libmpv reads a y4m\n\nLibrary: {origin}\n')
        print('| Run | Check | Result | Detail |\n|---|---|---|---|')
        for where, what, passed, detail in rows:
            cell = detail.replace('|', '\\|').replace('\n', ' ')
            print(f"| {where} | {what} | {'passed' if passed else 'FAILED'} | {cell} |")
        archs = ', '.join(arch for arch, _ in probes)
        verdict = 'FAILED' if failed else 'passed'
        line = (f'y4m check (check_y4m.py): {verdict}, {len(rows)} checks; yuv4mpegpipe demuxer and rawvideo decoder, '
                f'8 and 10 bit, from a file and over HTTP with exact seeks; {archs}')
        print(f'\n{line}')
        if args.summary:
            pathlib.Path(args.summary).write_text(line + '\n', encoding='utf-8')
        return 1 if failed else 0


def serve(seconds: int, port_file: str) -> int:
    server = _Server({f'fixture-{depth}bit.y4m': fixture(depth, seconds * FPS) for depth in (8, 10)})
    written = pathlib.Path(port_file + '.partial')
    written.write_text(f'{server.server_address[1]}\n', encoding='ascii')
    written.replace(port_file)
    server.serve_forever()
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest='command', required=True)
    run_parser = commands.add_parser('run', help='the whole check')
    source = run_parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--zips', nargs='+')
    source.add_argument('--frameworks')
    source.add_argument('--system', action='store_true')
    run_parser.add_argument('--headers')
    run_parser.add_argument('--search-headers', nargs='+')
    run_parser.add_argument('--summary')
    run_parser.add_argument('--work')
    fixture_parser = commands.add_parser('fixture', help='writes a fixture')
    fixture_parser.add_argument('out')
    fixture_parser.add_argument('--depth', type=int, choices=(8, 10), required=True)
    serve_parser = commands.add_parser('serve', help='serves the fixtures over HTTP')
    serve_parser.add_argument('--seconds', type=int, default=10)
    serve_parser.add_argument('--port-file', required=True)
    companion_parser = commands.add_parser('companion', help='the serve of the AV2 decoder read by this libmpv')
    companion_source = companion_parser.add_mutually_exclusive_group(required=True)
    companion_source.add_argument('--zips', nargs='+')
    companion_source.add_argument('--frameworks')
    companion_source.add_argument('--system', action='store_true')
    companion_parser.add_argument('--headers')
    companion_parser.add_argument('--search-headers', nargs='+')
    companion_parser.add_argument('--program', required=True)
    companion_parser.add_argument('--stream', nargs='+', required=True)
    companion_parser.add_argument('--summary')
    companion_parser.add_argument('--work')
    judge_parser = commands.add_parser('evaluate-companion', help="judges a probe's report of the AV2 path")
    judge_parser.add_argument('report')
    for name in ('width', 'height', 'frames', 'forward', 'back'):
        judge_parser.add_argument(f'--{name}', type=int, required=True)
    judge_parser.add_argument('--depth', type=int, choices=(8, 10), required=True)
    judge_parser.add_argument('--fps', type=float, required=True)
    evaluate_parser = commands.add_parser('evaluate', help="judges a probe's report")
    evaluate_parser.add_argument('report')
    evaluate_parser.add_argument('--depth', type=int, choices=(8, 10), required=True)
    evaluate_parser.add_argument('--http', action='store_true')
    evaluate_parser.add_argument('--ranges', type=int, nargs='*', default=[])
    args = parser.parse_args(argv)

    if args.command == 'run':
        return run(args)
    if args.command == 'companion':
        return companion(args)
    if args.command == 'evaluate-companion':
        report = json.loads(pathlib.Path(args.report).read_text(encoding='utf-8'))
        results = evaluate_companion(report, args.width, args.height, args.depth, args.frames, args.fps, args.forward,
                                     args.back)
        for what, passed, detail in results:
            print(f"{'passed' if passed else 'FAILED'}: {what} ({detail})")
        return 0 if all(passed for _, passed, _ in results) else 1
    if args.command == 'serve':
        return serve(args.seconds, args.port_file)
    if args.command == 'fixture':
        data = fixture(args.depth)
        pathlib.Path(args.out).write_bytes(data)
        print(f'{args.out}: {len(data)} bytes, {FRAMES} frames of {frame_size(args.depth)} bytes')
        return 0
    report = json.loads(pathlib.Path(args.report).read_text(encoding='utf-8'))
    results = evaluate(report, args.depth, args.http, args.ranges)
    for what, passed, detail in results:
        print(f"{'passed' if passed else 'FAILED'}: {what} ({detail})")
    return 0 if all(passed for _, passed, _ in results) else 1


if __name__ == '__main__':
    sys.exit(main())
