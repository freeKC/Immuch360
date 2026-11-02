#!/usr/bin/env python3
"""The splat viewer's page, end to end in a headless browser (lot SV3 of the splat viewer).

Serves mobile/assets/splat_viewer as the app's media bridge does (one session per case under a token, the page, its
session.json, the scene from disk with single ranges, the Content-Security-Policy and nosniff headers, the events
posted back), opens each case in a headless Chromium on SwiftShader and waits for the page's ready event:

  * ready within the time limit, no error event, no CSP violation;
  * the share of non blank pixels over a floor;
  * the placement as viewer_expected.json says (object or place and the orientation exactly, the bounds within the
    relative tolerance of Spark's float16 centres: 2^-10 of the coordinate plus 1 mm);
  * a PNG of the first view written to --out.

  page_check.py --browser chromium --out DIR            every case of CASES
  page_check.py --serve PORT                             serves the cases for a browser opened by hand, printing
                                                         their URLs, until interrupted

The browser is started with a profile of its own and stopped by its PID.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import http.server
import json
import os
import pathlib
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parents[3]
PAGE = ROOT / 'mobile' / 'assets' / 'splat_viewer'
FIXTURES = ROOT / 'mobile' / 'test' / 'fixtures' / 'splat'
VIEWER_FIXTURES = ROOT / 'mobile' / 'test' / 'fixtures' / 'splat_viewer'
EXPECTED = VIEWER_FIXTURES / 'viewer_expected.json'

# The headers of the app's session (splat_viewer_session.dart), made the same way here: the import map of index.html is
# the one inline script, allowed by its hash
def csp() -> str:
    page = (PAGE / 'index.html').read_text(encoding='utf-8')
    found = re.search(r'<script type="importmap">(.*?)</script>', page, re.DOTALL)
    digest = base64.b64encode(hashlib.sha256(found.group(1).encode('utf-8')).digest()).decode() if found else ''
    return (f"default-src 'none'; script-src 'self' 'wasm-unsafe-eval' blob: 'sha256-{digest}'; "
            "worker-src 'self' blob: data:; connect-src 'self'; img-src 'self' blob: data:; "
            "style-src 'self' 'unsafe-inline'; font-src 'self'")

TYPES = {'.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
         '.wasm': 'application/wasm', '.json': 'application/json; charset=utf-8'}

# The texts of the page in English, as the app sends them (the app's en.json)
TEXTS = {
    'back': 'Back', 'reset': 'Reset', 'upright': 'Turn upright', 'modeWalk': 'Walk', 'modeOrbit': 'Turn around',
    'gyroscope': 'Gyroscope', 'noGyroscope': 'No gyroscope on this device', 'info': 'Info', 'helpLabel': 'Controls',
    'loading': 'Loading the splat', 'countLine': '{count} gaussians',
    'hintKeys': 'Drag to look around. {keys} or the arrows: walk. Wheel: forward and back. {updown}: up and down. '
                'R: reset. Esc: back.',
    'hintKeysOrbit': 'Drag to turn around. Right drag: shift the view. Wheel or the arrows: closer or farther. '
                     '{keys}: walk. R: reset. Esc: back.',
    'hintTouch': 'Left thumb: walk. Drag: look around. Pinch: forward and back. Two fingers: slide. Double tap: reset.',
    'hintTouchOrbit': 'Drag: turn around. Pinch: closer or farther. Two fingers: shift the view. Left thumb: walk. '
                      'Double tap: reset.',
    'focusHint': 'Click the scene to walk with the keys', 'kindPlace': 'A place', 'kindObject': 'An object of {size}',
    'fpsLine': 'Drawn at {fps} frames per second', 'gpuLine': 'Graphics: {name}', 'turnedLine': 'Turned: {axis}',
    'axisYUp': 'Y up', 'axisZUp': 'Z up', 'axisYDown': 'Y down',
    'heavy': 'This splat is heavy for this device: it may stutter',
    'needsWebgl2': 'This device cannot show splats: its web view has no WebGL 2',
    'needsSimd': 'This device cannot show splats: its web view is too old',
    'graphicsLost': 'The graphics of this device stopped drawing the splat', 'failed': 'The splat could not be shown: {reason}',
    'keysFallback': 'W, A, S, D (Z, Q, S, D on AZERTY)', 'upDownFallback': 'E, Q (E, A on AZERTY)',
}

# (fixture, type, folder): the axes in every SPZ version and in PLY, the turns of version 4, a PLY of degree 3, a PLY in
# Brush's order of properties, the places with their floor at either end of y and the small object of
# make_viewer_fixtures.py. Not sh4_v4.spz: Spark refuses degree 4 harmonics, and the app's gate refuses such a file
# before any page opens
CASES = [
    ('axes_v1.spz', 'spz', FIXTURES), ('axes_v2.spz', 'spz', FIXTURES), ('axes_v3.spz', 'spz', FIXTURES),
    ('axes_v4.spz', 'spz', FIXTURES), ('axes_v4_niantic.spz', 'spz', FIXTURES), ('axes.ply', 'ply', FIXTURES),
    ('turns_v4.spz', 'spz', FIXTURES), ('sh3.ply', 'ply', FIXTURES), ('axes_brush_order.ply', 'ply', VIEWER_FIXTURES),
    ('room_floor.spz', 'spz', VIEWER_FIXTURES), ('room_colmap.spz', 'spz', VIEWER_FIXTURES),
    ('small_object.ply', 'ply', VIEWER_FIXTURES),
]

NON_BLANK_FLOOR = 0.002


class Sessions:
    def __init__(self, width: int, height: int, device: str):
        self.token = secrets.token_hex(16)
        self.sessions = {}
        self.events = {}
        self.captures = {}
        self.lock = threading.Condition()
        self.width, self.height, self.device = width, height, device

    def add(self, name: str, kind: str, folder: pathlib.Path) -> str:
        sid = secrets.token_hex(16)
        path = folder / name
        session = {
            'v': 1,
            'scene': {'url': f'/{self.token}/{sid}/scene.{kind}', 'type': kind, 'name': name,
                      'bytes': path.stat().st_size, 'gaussians': 0, 'shown': 0, 'reduced': False},
            'upright': None, 'device': self.device,
            'limits': {'pixelRatioMax': 1, 'maxStdDev': 2.236 if self.device == 'phone' else 2.828},
            'gyroscope': False, 'locale': 'en', 'texts': TEXTS, 'theme': {'dark': True, 'primary': '#4250af'},
            'events': 'events', 'check': True, 'capture': 'capture',
        }
        self.sessions[sid] = (session, path)
        self.events[sid] = []
        return sid

    def url(self, port: int, sid: str) -> str:
        return f'http://127.0.0.1:{port}/{self.token}/{sid}/index.html'


def handler_for(state: Sessions):
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def target(self):
            parts = urllib.parse.urlparse(self.path).path.split('/')
            if len(parts) != 4 or parts[1] != state.token or parts[2] not in state.sessions:
                return None
            return parts[2], parts[3]

        def send_bytes(self, status: int, body: bytes, kind: str, extra=None):
            self.send_response(status)
            self.send_header('Content-Type', kind)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('X-Content-Type-Options', 'nosniff')
            for key, value in (extra or {}).items():
                self.send_header(key, value)
            self.end_headers()
            if self.command != 'HEAD':
                self.wfile.write(body)

        def do_GET(self):
            found = self.target()
            if not found:
                return self.send_bytes(404, b'Not found', 'text/plain')
            sid, name = found
            session, path = state.sessions[sid]
            if name == 'session.json':
                return self.send_bytes(200, json.dumps(session).encode(), TYPES['.json'], {'Cache-Control': 'no-store'})
            if name == f'scene.{session["scene"]["type"]}':
                data = path.read_bytes()
                ranged = re.match(r'bytes=(\d*)-(\d*)$', self.headers.get('Range', ''))
                if ranged:
                    start = int(ranged.group(1) or 0)
                    end = int(ranged.group(2)) + 1 if ranged.group(2) else len(data)
                    self.send_response(206)
                    self.send_header('Content-Range', f'bytes {start}-{end - 1}/{len(data)}')
                    self.send_header('Content-Length', str(end - start))
                    self.send_header('Content-Type', 'application/octet-stream')
                    self.end_headers()
                    self.wfile.write(data[start:end])
                    return None
                return self.send_bytes(200, data, 'application/octet-stream', {'Cache-Control': 'no-store'})
            file = PAGE / name
            if '/' in name or not file.is_file():
                return self.send_bytes(404, b'Not found', 'text/plain')
            extra = {'Content-Security-Policy': csp()} if name == 'index.html' else {}
            return self.send_bytes(200, file.read_bytes(), TYPES.get(file.suffix, 'application/octet-stream'), extra)

        do_HEAD = do_GET

        def do_POST(self):
            found = self.target()
            length = int(self.headers.get('Content-Length') or 0)
            body = self.rfile.read(length)
            if not found:
                return self.send_bytes(404, b'Not found', 'text/plain')
            sid, name = found
            with state.lock:
                if name == 'events':
                    state.events[sid].append(json.loads(body or b'{}'))
                elif name == 'capture':
                    state.captures[sid] = body
                else:
                    return self.send_bytes(404, b'Not found', 'text/plain')
                state.lock.notify_all()
            self.send_response(204)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return None

    return Handler


def close_enough(found: float, wanted: float) -> bool:
    return abs(found - wanted) <= abs(wanted) / 1024 + 0.001


def compare(case: str, placement: dict, expected: dict) -> list:
    problems = []
    if placement.get('object') != expected['object']:
        problems.append(f'object {placement.get("object")}, expected {expected["object"]}')
    if placement.get('upright') != expected['upright']:
        problems.append(f'upright {placement.get("upright")}, expected {expected["upright"]}')
    bounds = placement.get('bounds') or {}
    for side in ('low', 'high'):
        for axis, (found, wanted) in enumerate(zip(bounds.get(side, []), expected['bounds'][side])):
            if not close_enough(found, wanted):
                problems.append(f'bounds {side}[{axis}] {found}, expected {wanted}')
    return problems


def browser_command(browser: str, profile: str, width: int, height: int, url: str) -> list:
    return [browser, '--headless=new', f'--user-data-dir={profile}', '--no-first-run', '--no-default-browser-check',
            '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist',
            f'--window-size={width},{height}', '--force-device-scale-factor=1', '--disable-extensions',
            '--autoplay-policy=no-user-gesture-required', url]


def run_cases(browser: str, out: pathlib.Path, width: int, height: int, timeout: float, device: str) -> int:
    expected = json.loads(EXPECTED.read_text()) if EXPECTED.exists() else {}
    state = Sessions(width, height, device)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler_for(state))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_address[1]
    out.mkdir(parents=True, exist_ok=True)
    failures = 0
    results = []
    for name, kind, folder in CASES:
        if not (folder / name).exists():
            print(f'{name}: missing fixture')
            failures += 1
            continue
        sid = state.add(name, kind, folder)
        profile = tempfile.mkdtemp(prefix='splat-page-check-')
        started = time.monotonic()
        process = subprocess.Popen(browser_command(browser, profile, width, height, state.url(port, sid)),
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        ready = None
        with state.lock:
            while time.monotonic() - started < timeout:
                ready = next((e for e in state.events[sid] if e.get('type') in ('ready', 'error', 'unsupported')),
                             None)
                if ready and (ready.get('type') != 'ready' or sid in state.captures):
                    break
                state.lock.wait(0.5)
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
        shutil.rmtree(profile, ignore_errors=True)
        problems = []
        if not ready:
            problems.append(f'no ready within {timeout:.0f} s')
        elif ready.get('type') != 'ready':
            problems.append(f'{ready.get("type")}: {ready.get("message") or ready.get("reason")}')
        else:
            if ready.get('nonBlank', 0) < NON_BLANK_FLOOR:
                problems.append(f'blank: {ready.get("nonBlank")}')
            if name in expected:
                problems += compare(name, ready.get('placement') or {}, expected[name])
            if sid in state.captures:
                (out / f'{name}.png').write_bytes(state.captures[sid])
        errors = [e for e in state.events[sid] if e.get('type') == 'error']
        problems += [f'error: {e.get("message")}' for e in errors]
        verdict = 'ok' if not problems else 'FAILED ' + '; '.join(problems)
        results.append({'case': name, 'ready': ready, 'problems': problems})
        print(f'{name}: {verdict} ({time.monotonic() - started:.1f} s, nonBlank {ready and ready.get("nonBlank")}, '
              f'{ready and ready.get("renderer")})', flush=True)
        failures += bool(problems)
    (out / 'results.json').write_text(json.dumps(results, indent=1))
    server.shutdown()
    return 1 if failures else 0


def serve(port: int, width: int, height: int, device: str) -> int:
    state = Sessions(width, height, device)
    for name, kind, folder in CASES:
        if (folder / name).exists():
            state.add(name, kind, folder)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', port), handler_for(state))
    for sid, (session, _) in state.sessions.items():
        print(session['scene']['name'], state.url(port, sid))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--browser', default=shutil.which('google-chrome') or shutil.which('chromium') or 'chromium')
    parser.add_argument('--out', type=pathlib.Path, default=pathlib.Path('splat-page-check'))
    parser.add_argument('--size', default='640x480')
    parser.add_argument('--device', default='computer', choices=['computer', 'phone'])
    parser.add_argument('--timeout', type=float, default=90)
    parser.add_argument('--serve', type=int, metavar='PORT')
    arguments = parser.parse_args()
    width, height = (int(v) for v in arguments.size.split('x'))
    if arguments.serve:
        return serve(arguments.serve, width, height, arguments.device)
    return run_cases(arguments.browser, arguments.out, width, height, arguments.timeout, arguments.device)


if __name__ == '__main__':
    sys.exit(main())
