#!/usr/bin/env python3
"""The app's side of immuch360-av2 serve, in Python: the client the av2 jobs test the program of each archive with.

It does what av2_playback.dart will do in the app (plan of the 2nd of November 2026, section 2.1): read the container
(IVF or Section 5 OBUs), cut it into temporal units at each temporal delimiter (a unit cut by the end of a truncated
file is left out), mark the random access units (a CLOSED_LOOP_KEY OBU), start serve with the probe's numbers, send
the index record, answer each "need G U" line with the units from U on, then a record of length 0, and read the lines
of the program. Then, as a player would, it reads the virtual y4m over HTTP and checks it:

  - the length (the header and one "FRAME\\n" and picture per unit) and our own header (frame rate of the container);
  - the MD5 of the pictures, all of them, against the MD5 the reference decoder avmdec v1.0.0 gave (fixtures.json of
    the fixtures, lot AD0);
  - a range that starts in the middle of a picture, a seek to a picture after a random access point (the program asks
    for that unit again, "need"), a seek back, a new request that replaces the one being served;
  - another token (403) and another path (404) refused, the socket on 127.0.0.1 only, the "stat" lines every half
    second, no processor time while the player does not read (Linux and macOS), and the program gone within a second
    of the standard input closing, with exit code 0;
  - a damaged file stops the program with its error line and exit code 3, never a crash.

  av2_serve_check.py check --program FILE --fixtures DIR [--threads N]
      every check above on the fixtures of DIR (mobile/test/fixtures/av2); exit 1 on a failure
  av2_serve_check.py index --file FILE
      the temporal units, random access units and frame rate of FILE as this client reads them, as JSON
  av2_serve_check.py feed --program FILE --file FILE [--threads N] [--depth 8]
      serves FILE and prints its URL on the first line, then the lines of the program, until killed (the benchmark
      of the measurement plays the URL with mpv)

Only the Python standard library is used.
"""
from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
import pathlib
import queue
import re
import secrets
import socket
import struct
import subprocess
import sys
import threading
import time

RECORD = struct.Struct('<4sIII')
INDEX_UNIT = 0xFFFFFFFF
TEMPORAL_DELIMITER, CLOSED_LOOP_KEY = 2, 4


class Failure(Exception):
    pass


# --- the container ----------------------------------------------------------------------------------------------------

def leb128(data: bytes, at: int):
    value = 0
    for i in range(8):
        if at + i >= len(data):
            return None
        byte = data[at + i]
        value |= (byte & 0x7F) << (7 * i)
        if not byte & 0x80:
            return value, i + 1
    return None


def obus(data: bytes, start: int, end: int):
    """(offset, length, type) of each whole OBU between start and end; stops at a cut one"""
    at = start
    while at < end:
        size = leb128(data, at)
        if size is None or size[0] < 1 or at + size[1] + size[0] > end:
            return
        yield at, size[1] + size[0], (data[at + size[1]] >> 2) & 0x1F
        at += size[1] + size[0]


class Stream:
    """The temporal units of an AV2 IVF or Section 5 file, as the app indexes them"""

    def __init__(self, path: pathlib.Path):
        data = path.read_bytes()
        self.path = path
        self.data = data
        self.units = []  # (offset, length)
        self.raps = []
        self.fps = (30, 1)
        self.ivf = data[:4] == b'DKIF'
        if self.ivf:
            if data[8:12] != b'AV02':
                raise Failure(f'{path.name}: an IVF of {data[8:12]!r}, not AV2')
            header, = struct.unpack_from('<H', data, 6)
            rate, scale = struct.unpack_from('<II', data, 16)
            if rate and scale:
                self.fps = (rate, scale)
            at = header
            while at + 12 <= len(data):
                size, = struct.unpack_from('<I', data, at)
                start, end = at + 12, min(at + 12 + size, len(data))
                self._units(start, end, whole=at + 12 + size <= len(data))
                at += 12 + size
        else:
            self._units(0, len(data), whole=True)
        if not self.units:
            raise Failure(f'{path.name}: no whole temporal unit')

    def _units(self, start: int, end: int, whole: bool):
        """The units of a packet; in a cut packet, a unit is whole when another delimiter follows it"""
        found = []
        for offset, length, kind in obus(self.data, start, end):
            if kind == TEMPORAL_DELIMITER or not found:
                found.append([offset, offset + length, False])
            else:
                found[-1][1] = offset + length
            if kind == CLOSED_LOOP_KEY:
                found[-1][2] = True
        if not whole and found:
            found.pop()
        elif found and found[-1][1] != end:
            found.pop()  # the packet ends inside an OBU
        for offset, stop, key in found:
            if key:
                self.raps.append(len(self.units))
            self.units.append((offset, stop - offset))

    def unit(self, index: int) -> bytes:
        offset, length = self.units[index]
        return self.data[offset:offset + length]


# --- the program ------------------------------------------------------------------------------------------------------

def probe(program: pathlib.Path, path: pathlib.Path, threads: int = 0) -> tuple:
    result = subprocess.run([str(program), 'probe', str(path), '--threads', str(threads)], capture_output=True,
                            timeout=60)
    text = result.stdout.decode('utf-8', 'replace').strip()
    try:
        return result.returncode, json.loads(text.splitlines()[-1] if text else '{}')
    except json.JSONDecodeError:
        raise Failure(f'probe {path.name}: not JSON: {text!r}')


class Companion:
    """immuch360-av2 serve, fed as the app feeds it"""

    def __init__(self, program: pathlib.Path, stream: Stream, info: dict, threads: int = 0, depth: int = 0,
                 token: str | None = None, extra: list | None = None, hold_from: int | None = None):
        self.stream = stream
        # The app's side can stop feeding the first generation at a unit, as a slow share would: the program then
        # waits for that unit, and the request it serves stays open
        self.hold_from = hold_from
        self.token = token or secrets.token_urlsafe(24)
        picture = info['picture']
        rate, scale = stream.fps
        command = [str(program), 'serve', '--token', self.token, '--width', str(picture['width']), '--height',
                   str(picture['height']), '--bits', str(picture['bits']), '--fps', f'{rate}/{scale}', '--frames',
                   str(len(stream.units)), '--threads', str(threads), '--range', info['color']['range']]
        if depth:
            command += ['--depth', str(depth)]
        command += extra or []
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, bufsize=0)
        self.lines = []
        self.lines_lock = threading.Condition()
        self.needs = queue.Queue()
        self.port = None
        self.length = None
        self.started = time.monotonic()
        self.reader = threading.Thread(target=self._read_lines, daemon=True)
        self.reader.start()
        threading.Thread(target=self._read_errors, daemon=True).start()
        self.feeding = threading.Thread(target=self._feed, daemon=True)
        self.feeding.start()
        line = self.wait_line(lambda text: text.startswith(('listening ', 'error ')), 20)
        if not line or not line.startswith('listening '):
            raise Failure(f'serve did not listen: {line!r}, stderr {self.errors()!r}')
        self.port = int(line.split()[1])
        fields = dict(part.split('=', 1) for part in line.split()[2:])
        self.listening = fields
        self.length = int(fields['length'])

    @property
    def url_path(self) -> str:
        return f'/{self.token}/video.y4m'

    @property
    def url(self) -> str:
        return f'http://127.0.0.1:{self.port}{self.url_path}'

    def _read_lines(self):
        for raw in self.process.stdout:
            text = raw.decode('utf-8', 'replace').rstrip('\r\n')
            with self.lines_lock:
                self.lines.append((time.monotonic(), text))
                self.lines_lock.notify_all()
            match = re.match(r'^need (\d+) (\d+)$', text)
            if match:
                self.needs.put((int(match.group(1)), int(match.group(2))))
        self.needs.put(None)

    def _read_errors(self):
        self.stderr = self.process.stderr.read()

    def errors(self) -> str:
        return getattr(self, 'stderr', b'').decode('utf-8', 'replace')

    def _write(self, generation: int, unit: int, payload: bytes) -> bool:
        try:
            self.process.stdin.write(RECORD.pack(b'AV2R', generation, unit, len(payload)) + payload)
            return True
        except (BrokenPipeError, OSError, ValueError):
            return False

    def _feed(self):
        """The index first, then for each need the units from its unit on, until the next need"""
        index = b''.join(struct.pack('<I', rap) for rap in self.stream.raps)
        if not self._write(0, INDEX_UNIT, index):
            return
        need = self.needs.get()
        first = True
        while need is not None:
            generation, unit = need
            need = None
            for at in range(unit, len(self.stream.units)):
                try:
                    need = self.needs.get_nowait()
                    break
                except queue.Empty:
                    pass
                if first and self.hold_from is not None and at >= self.hold_from:
                    need = self.needs.get()  # held until the program asks for another generation
                    break
                if not self._write(generation, at, self.stream.unit(at)):
                    return
            else:
                if not self._write(generation, len(self.stream.units), b''):
                    return
            first = False
            if need is None:
                need = self.needs.get()

    def wait_line(self, test, timeout: float, after: int = 0):
        """The first line from the index after on that passes test, or None after timeout seconds"""
        limit = time.monotonic() + timeout
        with self.lines_lock:
            while True:
                for _, text in self.lines[after:]:
                    if test(text):
                        return text
                left = limit - time.monotonic()
                if left <= 0 or not self.reader.is_alive():
                    return None
                self.lines_lock.wait(min(left, 0.1))

    def line_count(self) -> int:
        with self.lines_lock:
            return len(self.lines)

    def texts(self) -> list:
        with self.lines_lock:
            return [text for _, text in self.lines]

    def close(self, timeout: float = 5.0) -> tuple:
        """Closes the standard input; the exit code and the seconds the program took to go"""
        started = time.monotonic()
        try:
            self.process.stdin.close()
        except OSError:
            pass
        try:
            code = self.process.wait(timeout)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            return None, timeout
        return code, time.monotonic() - started

    def kill(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait()

    def cpu_seconds(self) -> float | None:
        """Processor time of the program so far (Linux and macOS), None elsewhere"""
        pid = self.process.pid
        if sys.platform.startswith('linux'):
            fields = pathlib.Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
            return (int(fields[11]) + int(fields[12])) / os.sysconf('SC_CLK_TCK')
        if sys.platform == 'darwin':
            text = subprocess.run(['ps', '-o', 'time=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()
            match = re.match(r'(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)', text)
            if match:
                return int(match.group(1) or 0) * 3600 + int(match.group(2)) * 60 + float(match.group(3))
        return None


def get(port: int, path: str, start: int | None = None, end: int | None = None, limit: int | None = None,
        method: str = 'GET', timeout: float = 60) -> tuple:
    """The status, headers and body of one request (the first limit bytes of the body when limit is given)"""
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=timeout)
    headers = {}
    if start is not None:
        headers['Range'] = f'bytes={start}-' + ('' if end is None else str(end))
    connection.request(method, path, headers=headers)
    response = connection.getresponse()
    body = b''
    if method == 'GET':
        if limit is None:
            body = response.read()
        else:
            while len(body) < limit:
                chunk = response.read(min(1 << 20, limit - len(body)))
                if not chunk:
                    break
                body += chunk
    connection.close()
    return response.status, {key.lower(): value for key, value in response.getheaders()}, body


def frames_of(body: bytes, header_length: int, frame_bytes: int) -> list:
    pictures = []
    at = header_length
    while at < len(body):
        if body[at:at + 6] != b'FRAME\n':
            raise Failure(f'no FRAME marker at byte {at}')
        pictures.append(body[at + 6:at + 6 + frame_bytes])
        at += 6 + frame_bytes
    return pictures


# --- the checks -------------------------------------------------------------------------------------------------------

class Report:
    def __init__(self):
        self.failures = []

    def check(self, condition: bool, what: str):
        print(('ok    ' if condition else 'FAIL  ') + what, flush=True)
        if not condition:
            self.failures.append(what)


def expected_header(info: dict, stream: Stream) -> bytes:
    picture = info['picture']
    rate, scale = stream.fps
    space = '420' if picture['bits'] == 8 else '420p10'
    colour = 'FULL' if info['color']['range'] == 'full' else 'LIMITED'
    return f'YUV4MPEG2 W{picture["width"]} H{picture["height"]} F{rate}:{scale} Ip A1:1 C{space} ' \
           f'XCOLORRANGE={colour}\n'.encode()


def check_file(report: Report, program: pathlib.Path, path: pathlib.Path, entry: dict, threads: int):
    name = path.name
    stream = Stream(path)
    code, info = probe(program, path, threads)
    report.check(code == 0 and info.get('playable') is True, f'{name}: probe says playable ({info.get("format")})')
    if code != 0:
        return
    report.check(info['picture']['bits'] == entry['bits'] and info['picture']['width'] == entry['width'],
                 f'{name}: probe gives {entry["width"]}x{entry["height"]} in {entry["bits"]} bits')
    report.check(len(stream.units) == entry['frames'], f'{name}: {len(stream.units)} temporal units, '
                                                       f'{entry["frames"]} pictures in fixtures.json')
    report.check(stream.raps == [0, 6], f'{name}: random access units {stream.raps}, [0, 6] expected')
    header = expected_header(info, stream)
    frame_bytes = info['y4m']['frame_bytes']
    record = 6 + frame_bytes
    total = len(header) + len(stream.units) * record
    companion = Companion(program, stream, info, threads)
    try:
        report.check(companion.length == total, f'{name}: listening says length {companion.length}, {total} expected')
        report.check(companion.listening.get('address') == '127.0.0.1', f'{name}: listening on 127.0.0.1')
        status, headers, _ = get(companion.port, companion.url_path, method='HEAD')
        report.check(status == 200 and int(headers.get('content-length', -1)) == total,
                     f'{name}: HEAD 200 with Content-Length {total}')
        status, headers, body = get(companion.port, companion.url_path, start=0)
        report.check(status == 206 and headers.get('content-range') == f'bytes 0-{total - 1}/{total}' and
                     len(body) == total, f'{name}: GET bytes=0- 206, Content-Range and {total} bytes')
        report.check(body[:len(header)] == header, f'{name}: our y4m header {header!r}')
        pictures = frames_of(body, len(header), frame_bytes) if len(body) == total else []
        whole = hashlib.md5(b''.join(pictures)).hexdigest()
        expected = entry['md5_all_frames']['avmdec --md5']
        report.check(whole == expected,
                     f'{name}: MD5 of the {len(pictures)} pictures {whole}, avmdec v1.0.0 {expected}')
        report.check([hashlib.md5(p).hexdigest() for p in pictures] == entry['frame_md5'],
                     f'{name}: MD5 of each picture as avmdec v1.0.0')

        # A range in the middle of picture 3, read to the end of picture 4
        start = len(header) + 3 * record + 1000
        status, headers, part = get(companion.port, companion.url_path, start=start, end=len(header) + 5 * record - 1)
        report.check(status == 206 and part == body[start:len(header) + 5 * record],
                     f'{name}: a range from the middle of picture 3 gives the same bytes')

        # A seek to picture 8, two after the random access unit 6: the decoder ended, it starts again at 6
        mark = companion.line_count()
        start = len(header) + 8 * record
        status, _, part = get(companion.port, companion.url_path, start=start)
        need = companion.wait_line(lambda text: text.startswith('need '), 5, mark)
        report.check(need is not None and need.split()[2] == '6', f'{name}: a seek to picture 8 asks for unit 6 '
                                                                  f'({need})')
        report.check(status == 206 and part == body[start:], f'{name}: the seek to picture 8 gives the same bytes')

        # Back to picture 2, before the decoder: it starts again at 0
        mark = companion.line_count()
        start = len(header) + 2 * record
        status, _, part = get(companion.port, companion.url_path, start=start, end=start + record - 1)
        need = companion.wait_line(lambda text: text.startswith('need '), 5, mark)
        report.check(need is not None and need.split()[2] == '0' and part == body[start:start + record],
                     f'{name}: a seek back to picture 2 asks for unit 0 and gives the same bytes ({need})')

        # Another token, another path, a range beyond the end
        status, _, _ = get(companion.port, f'/{secrets.token_urlsafe(24)}/video.y4m')
        report.check(status == 403 and companion.wait_line(lambda t: t == 'refused token', 5) is not None,
                     f'{name}: another token is refused (403, "refused token")')
        status, _, _ = get(companion.port, f'/{companion.token}/other.y4m')
        report.check(status == 404, f'{name}: another path under the token is refused (404)')
        status, _, _ = get(companion.port, companion.url_path, start=total)
        report.check(status == 416, f'{name}: a range beyond the end is refused (416)')

        # Status lines
        stats = [text for text in companion.texts() if text.startswith('stat ')]
        time.sleep(1.2 if len(stats) < 2 else 0)
        stats = [text for text in companion.texts() if text.startswith('stat ')]
        fields = dict(part.split('=', 1) for part in stats[-1].split()[1:]) if stats else {}
        report.check(len(stats) >= 2 and {'decoded', 'served', 'fps', 'simd'} <= set(fields),
                     f'{name}: stat lines with decoded, served, fps and simd ({stats[-1] if stats else None})')
    finally:
        code, seconds = companion.close()
    report.check(code == 0 and seconds < 1.0, f'{name}: gone {seconds:.2f} s after its input closed, exit {code}')
    report.check(companion.texts()[-1:] == ['exit input-closed'], f'{name}: last line "exit input-closed"')


def check_pause(report: Report, program: pathlib.Path, path: pathlib.Path, threads: int):
    """A player that stops reading costs no processor time (Linux and macOS, where it can be read)"""
    name = path.name
    stream = Stream(path)
    _, info = probe(program, path, threads)
    header = expected_header(info, stream)
    companion = Companion(program, stream, info, threads)
    try:
        player = socket.create_connection(('127.0.0.1', companion.port), timeout=10)
        player.sendall(f'GET {companion.url_path} HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-\r\n\r\n'.encode())
        received = b''
        while b'\r\n\r\n' not in received or len(received.split(b'\r\n\r\n', 1)[1]) < len(header) + 10:
            chunk = player.recv(65536)
            if not chunk:
                break
            received += chunk
        time.sleep(0.5)
        before = companion.cpu_seconds()
        time.sleep(1.5)
        after = companion.cpu_seconds()
        if before is not None and after is not None:
            report.check(after - before < 0.05, f'{name}: {after - before:.3f} s of processor while the player waits')
        else:
            print(f'skip  {name}: processor time while the player waits (no /proc or ps here)')
        player.close()
    finally:
        companion.close()


def check_replace(report: Report, program: pathlib.Path, path: pathlib.Path, threads: int):
    """A new request ends the one being served, which waits for a unit the app has not sent yet"""
    name = path.name
    stream = Stream(path)
    _, info = probe(program, path, threads)
    header = expected_header(info, stream)
    record = 6 + info['y4m']['frame_bytes']
    total = len(header) + len(stream.units) * record
    companion = Companion(program, stream, info, threads, hold_from=3)
    try:
        first = socket.create_connection(('127.0.0.1', companion.port), timeout=10)
        first.sendall(f'GET {companion.url_path} HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-\r\n\r\n'.encode())
        received = b''
        while b'\r\n\r\n' not in received or len(received.split(b'\r\n\r\n', 1)[1]) < len(header):
            chunk = first.recv(65536)
            if not chunk:
                break
            received += chunk
        start = len(header) + 7 * record
        status, _, part = get(companion.port, companion.url_path, start=start, end=start + record - 1)
        report.check(status == 206 and len(part) == record,
                     f'{name}: a second request is served while the first waits for the app')
        first.settimeout(5)
        try:
            while True:
                chunk = first.recv(1 << 20)
                if not chunk:
                    break
                received += chunk
        except OSError:
            pass
        first.close()
        body = received.split(b'\r\n\r\n', 1)[1] if b'\r\n\r\n' in received else b''
        report.check(len(body) < total, f'{name}: the first request ended when the second came ({len(body)} of '
                                        f'{total} bytes)')
    finally:
        companion.close()


def check_loopback_only(report: Report, companion_port: int):
    """No address but 127.0.0.1 reaches the socket"""
    addresses = {'127.0.0.2'} if sys.platform != 'darwin' else set()
    try:
        for family, _, _, _, address in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            if not address[0].startswith('127.0.0.1'):
                addresses.add(address[0])
    except OSError:
        pass
    reached = []
    for address in sorted(addresses):
        try:
            with socket.create_connection((address, companion_port), timeout=1):
                reached.append(address)
        except OSError:
            pass
    report.check(not reached, f'only 127.0.0.1 reaches the socket (tried {", ".join(sorted(addresses)) or "none"})')
    if sys.platform.startswith('linux'):
        listening = [line.split() for line in pathlib.Path('/proc/net/tcp').read_text().splitlines()[1:]]
        bound = [fields[1] for fields in listening
                 if fields[3] == '0A' and int(fields[1].split(':')[1], 16) == companion_port]
        report.check(bound == ['0100007F:' + f'{companion_port:04X}'], f'/proc/net/tcp: bound to {bound}')


def check_damaged(report: Report, program: pathlib.Path, path: pathlib.Path, intact: pathlib.Path, threads: int):
    """A damaged unit stops the program with its error line and code 3: never a crash, never a hang"""
    name = path.name
    stream = Stream(path)
    _, info = probe(program, intact, threads)
    companion = Companion(program, stream, info, threads)
    try:
        try:
            get(companion.port, companion.url_path, start=0, timeout=10)
        except (OSError, http.client.HTTPException):
            pass
        try:
            code = companion.process.wait(10)
        except subprocess.TimeoutExpired:
            code = None
        error = companion.wait_line(lambda text: text.startswith('error '), 1)
        report.check(code == 3 and error is not None and error.startswith('error decode'),
                     f'{name}: the program stops with "error decode" and exit code 3 ({error}, exit {code})')
    finally:
        companion.kill()


def check_cut(report: Report, program: pathlib.Path, path: pathlib.Path, entry: dict, threads: int):
    """A file cut in a unit: its whole units, decoded as the reference decoder decodes them"""
    name = path.name
    stream = Stream(path)
    report.check(len(stream.units) == entry['whole_units'], f'{name}: {len(stream.units)} whole units, '
                                                           f'{entry["whole_units"]} in fixtures.json')
    code, info = probe(program, path, threads)
    if code != 0:
        report.check(False, f'{name}: probe ({info})')
        return
    companion = Companion(program, stream, info, threads)
    try:
        header = expected_header(info, stream)
        status, _, body = get(companion.port, companion.url_path, start=0)
        pictures = frames_of(body, len(header), info['y4m']['frame_bytes'])
        expected = entry['decoders_on_whole_units_as_obu']['avmdec']['frame_md5']
        report.check([hashlib.md5(p).hexdigest() for p in pictures] == expected,
                     f'{name}: the {len(pictures)} pictures of its whole units as avmdec v1.0.0 decodes them')
    finally:
        companion.close()


def check_refusals(report: Report, program: pathlib.Path, fixtures: pathlib.Path):
    code, info = probe(program, fixtures / 'av1-256x144-8bit.ivf')
    report.check(code == 3 and 'AV1' in info.get('error', ''), f'av1-256x144-8bit.ivf: refused by probe ({info})')
    garbage = bytes((i * 151 + 7) % 256 for i in range(4096))
    result = subprocess.run([str(program), 'probe', '-'], input=garbage, capture_output=True, timeout=30)
    report.check(result.returncode == 3, f'random bytes: refused by probe ({result.stdout.decode().strip()})')
    result = subprocess.run([str(program), 'serve', '--token', 'short'], capture_output=True, timeout=30)
    report.check(result.returncode == 2, 'serve with a short token: exit code 2')


def command_check(args) -> int:
    fixtures = args.fixtures
    entries = json.loads((fixtures / 'fixtures.json').read_text(encoding='utf-8'))['files']
    report = Report()
    for name in ('av2-256x144-8bit.ivf', 'av2-256x144-10bit.ivf', 'av2-256x144-8bit.obu', 'av2-256x144-10bit.obu'):
        check_file(report, args.program, fixtures / name, entries[name], args.threads)
    check_pause(report, args.program, fixtures / 'av2-256x144-10bit.ivf', args.threads)
    check_replace(report, args.program, fixtures / 'av2-256x144-8bit.ivf', args.threads)
    stream = Stream(fixtures / 'av2-256x144-8bit.ivf')
    _, info = probe(args.program, fixtures / 'av2-256x144-8bit.ivf')
    companion = Companion(args.program, stream, info, args.threads)
    try:
        check_loopback_only(report, companion.port)
    finally:
        companion.close()
    check_cut(report, args.program, fixtures / 'av2-256x144-8bit-cut.ivf', entries['av2-256x144-8bit-cut.ivf'],
              args.threads)
    check_damaged(report, args.program, fixtures / 'av2-256x144-8bit-damaged.ivf', fixtures / 'av2-256x144-8bit.ivf',
                  args.threads)
    check_refusals(report, args.program, fixtures)
    if report.failures:
        for failure in report.failures:
            print(f'::error::{failure}')
        return 1
    print('serve: every check passed')
    return 0


def command_index(args) -> int:
    stream = Stream(args.file)
    print(json.dumps({'container': 'ivf' if stream.ivf else 'obu', 'units': len(stream.units), 'raps': stream.raps,
                      'fps': list(stream.fps), 'sizes': [length for _, length in stream.units]}))
    return 0


def command_feed(args) -> int:
    stream = Stream(args.file)
    code, info = probe(args.program, args.file, args.threads)
    if code != 0:
        print(f'probe: {info}', file=sys.stderr)
        return 1
    companion = Companion(args.program, stream, info, args.threads, args.depth)
    print(companion.url, flush=True)
    print(f'pid {companion.process.pid}', flush=True)
    shown = 0
    try:
        while companion.process.poll() is None:
            texts = companion.texts()
            for text in texts[shown:]:
                print(text, flush=True)
            shown = len(texts)
            time.sleep(0.2)
    except KeyboardInterrupt:
        pass
    finally:
        companion.close()
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest='command', required=True)
    check = commands.add_parser('check')
    check.add_argument('--program', type=pathlib.Path, required=True)
    check.add_argument('--fixtures', type=pathlib.Path, required=True)
    check.add_argument('--threads', type=int, default=0)
    index = commands.add_parser('index')
    index.add_argument('--file', type=pathlib.Path, required=True)
    feed = commands.add_parser('feed')
    feed.add_argument('--program', type=pathlib.Path, required=True)
    feed.add_argument('--file', type=pathlib.Path, required=True)
    feed.add_argument('--threads', type=int, default=0)
    feed.add_argument('--depth', type=int, default=0)
    args = parser.parse_args(argv)
    try:
        return {'check': command_check, 'index': command_index, 'feed': command_feed}[args.command](args)
    except Failure as error:
        print(f'::error::{error}')
        return 1


if __name__ == '__main__':
    sys.exit(main())
