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
    second and their decoding speed, no processor time while the player does not read (Linux and macOS), and the
    program gone within a second of the standard input closing, with exit code 0, whatever its queue of units holds
    (full with no request, with a paused player, after the player closed);
  - the program gone too when the app is gone without closing it: its standard output closed, or the --parent process
    ended;
  - a request that trickles in a byte at a time holds neither the player's requests nor its connection beyond 2 s;
  - --depth 8, and the probe of a file cut in its first picture, of the standard input, and of a first picture after
    5, 20 and 70 MiB (its steps of 1, 4, 16 and 64 MiB);
  - a damaged file stops the program with its error line and exit code 3, never a crash.

The app's side writes the standard input of serve as dart:io does: writes that never hold the writer, so that closing
it always closes the pipe (a pipe whose end does not block on Linux and macOS, a named pipe with overlapped writes on
Windows, the program reading its client end).

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
import select
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

RECORD = struct.Struct('<4sIII')
INDEX_UNIT = 0xFFFFFFFF
TEMPORAL_DELIMITER, CLOSED_LOOP_KEY, PADDING = 2, 4, 25


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


class Repeated:
    """The units of a stream played times times in a row: a long video made of a fixture (each copy starts with its
    key frame and its sequence header)"""

    def __init__(self, stream: Stream, times: int):
        self.base = stream
        self.path = stream.path
        self.fps = stream.fps
        self.units = stream.units * times
        self.raps = [copy * len(stream.units) + rap for copy in range(times) for rap in stream.raps]

    def unit(self, index: int) -> bytes:
        return self.base.unit(index % len(self.base.units))


def leb128_bytes(value: int) -> bytes:
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        out.append(byte | (0x80 if value else 0))
        if not value:
            return bytes(out)


def padded_ivf(data: bytes, padding: int) -> bytes:
    """An IVF with a padding OBU of padding bytes at the end of its first packet: its first picture whole, but past
    the first steps of the probe"""
    header, = struct.unpack_from('<H', data, 6)
    size, = struct.unpack_from('<I', data, header)
    packet = data[header + 12:header + 12 + size] + leb128_bytes(1 + padding) + bytes([PADDING << 2]) + bytes(padding)
    return (data[:header] + struct.pack('<I', len(packet)) + data[header + 4:header + 12] + packet +
            data[header + 12 + size:])


# --- the program ------------------------------------------------------------------------------------------------------

def probe(program: pathlib.Path, path: pathlib.Path, threads: int = 0) -> tuple:
    result = subprocess.run([str(program), 'probe', str(path), '--threads', str(threads)], capture_output=True,
                            timeout=60)
    text = result.stdout.decode('utf-8', 'replace').strip()
    try:
        return result.returncode, json.loads(text.splitlines()[-1] if text else '{}')
    except json.JSONDecodeError:
        raise Failure(f'probe {path.name}: not JSON: {text!r}')


class AppPipe:
    """The standard input of serve as the app holds it. dart:io never blocks on a write: it waits for room in the pipe
    without holding a thread, and closing its end always closes the pipe. A blocking write would not do here: on
    Linux, a pipe with a write still blocked in it keeps its writer after close(), and on Windows CloseHandle waits for
    that write. So: a pipe whose end of the app does not block (Linux, macOS), or a named pipe whose server end the app
    writes with overlapped writes, the program reading the client end, as dart:io makes it (Windows)"""

    def __init__(self):
        self.closed = threading.Event()
        self.waiting_since = None  # when the write under way started to wait for room, None when it is not waiting
        self._lock = threading.Lock()
        self._pending = None
        if os.name == 'nt':
            import _winapi
            import msvcrt

            self._winapi = _winapi
            name = rf'\\.\pipe\immuch360-av2-check-{os.getpid()}-{secrets.token_hex(8)}'
            # Outbound, overlapped, first instance; a byte pipe of 64 KiB
            self._server = _winapi.CreateNamedPipe(name, 0x2 | _winapi.FILE_FLAG_OVERLAPPED | 0x80000, 0, 1, 65536,
                                                   65536, 0, _winapi.NULL)
            client = _winapi.CreateFile(name, _winapi.GENERIC_READ, 0, _winapi.NULL, _winapi.OPEN_EXISTING,
                                        _winapi.FILE_FLAG_OVERLAPPED, _winapi.NULL)
            connected = _winapi.ConnectNamedPipe(self._server, overlapped=True)
            try:
                connected.GetOverlappedResult(True)
            except OSError:
                pass  # ERROR_PIPE_CONNECTED: the client end was opened first, as here
            self.child = msvcrt.open_osfhandle(client, os.O_RDONLY)
        else:
            self.child, self._writer = os.pipe()
            os.set_blocking(self._writer, False)

    def started(self):
        """The program holds its end: the app keeps only its own"""
        os.close(self.child)

    def write(self, data: bytes, timeout: float | None = None) -> bool:
        """data whole, waiting while the pipe is full; False once the pipe is closed or broken, or after timeout
        seconds"""
        view = memoryview(data)
        limit = None if timeout is None else time.monotonic() + timeout
        while view:
            if self.closed.is_set() or (limit is not None and time.monotonic() > limit):
                return False
            try:
                written = self._write_some(view)
            except OSError:
                return False
            if written:
                view = view[written:]
                self.waiting_since = None
            elif self.waiting_since is None:
                self.waiting_since = time.monotonic()
        return True

    def _write_some(self, view) -> int:
        """The bytes one write took, 0 when the pipe had no room for 0.1 s"""
        if os.name != 'nt':
            with self._lock:
                if self.closed.is_set():
                    raise OSError('closed')
                try:
                    return os.write(self._writer, view)
                except BlockingIOError:
                    writer = self._writer
            select.select([], [writer], [], 0.1)
            return 0
        winapi = self._winapi
        with self._lock:
            if self.closed.is_set():
                raise OSError('closed')
            overlapped, _ = winapi.WriteFile(self._server, bytes(view), overlapped=True)
            self._pending = overlapped
        try:
            while winapi.WaitForSingleObject(overlapped.event, 100) != 0:
                if self.waiting_since is None:
                    self.waiting_since = time.monotonic()
            written, _ = overlapped.GetOverlappedResult(True)
            return written
        finally:
            with self._lock:
                self._pending = None

    def waited(self, timeout: float, held: float = 0.5) -> bool:
        """Whether a write waited for room for held seconds within timeout seconds: the pipe is full"""
        limit = time.monotonic() + timeout
        while time.monotonic() < limit:
            since = self.waiting_since
            if since is not None and time.monotonic() - since >= held:
                return True
            time.sleep(0.05)
        return False

    def close(self):
        """Closes the end of the app, as the app does to stop the program; a write under way ends at once"""
        with self._lock:
            if self.closed.is_set():
                return
            self.closed.set()
            if os.name == 'nt':
                if self._pending is not None:
                    try:
                        self._pending.cancel()
                    except OSError:
                        pass
                self._winapi.CloseHandle(self._server)
            else:
                os.close(self._writer)


def serve_command(program: pathlib.Path, stream, info: dict, token: str, threads: int = 0, depth: int = 0) -> list:
    picture = info['picture']
    rate, scale = stream.fps
    command = [str(program), 'serve', '--token', token, '--width', str(picture['width']), '--height',
               str(picture['height']), '--bits', str(picture['bits']), '--fps', f'{rate}/{scale}', '--frames',
               str(len(stream.units)), '--threads', str(threads), '--range', info['color']['range']]
    if depth:
        command += ['--depth', str(depth)]
    return command


class Companion:
    """immuch360-av2 serve, fed as the app feeds it"""

    def __init__(self, program: pathlib.Path, stream, info: dict, threads: int = 0, depth: int = 0,
                 token: str | None = None, extra: list | None = None, hold_from: int | None = None,
                 feed: bool = True):
        self.stream = stream
        # The app's side can stop feeding the first generation at a unit, as a slow share would: the program then
        # waits for that unit, and the request it serves stays open
        self.hold_from = hold_from
        self.token = token or secrets.token_urlsafe(24)
        command = serve_command(program, stream, info, self.token, threads, depth) + (extra or [])
        self.pipe = AppPipe()
        self.units_written = 0
        self.process = subprocess.Popen(command, stdin=self.pipe.child, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, bufsize=0)
        self.pipe.started()
        self.lines = []
        self.lines_lock = threading.Condition()
        self.needs = queue.Queue()
        self.port = None
        self.length = None
        self.started = time.monotonic()
        self.reader = threading.Thread(target=self._read_lines, daemon=True)
        self.reader.start()
        threading.Thread(target=self._read_errors, daemon=True).start()
        # Without feed, the test writes the records itself (write_record)
        self.feeding = threading.Thread(target=self._feed if feed else self._index_only, daemon=True)
        self.feeding.start()
        line = self.wait_line(lambda text: text.startswith(('listening ', 'error ')), 20)
        if not line or not line.startswith('listening '):
            self.kill()
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

    def write_record(self, generation: int, unit: int, payload: bytes, timeout: float | None = None) -> bool:
        return self.pipe.write(RECORD.pack(b'AV2R', generation, unit, len(payload)) + payload, timeout)

    def _write(self, generation: int, unit: int, payload: bytes) -> bool:
        if not self.write_record(generation, unit, payload):
            return False
        if payload:
            self.units_written += 1
        return True

    def _index_only(self):
        self._write(0, INDEX_UNIT, b''.join(struct.pack('<I', rap) for rap in self.stream.raps))

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
        self.pipe.close()
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
        self.pipe.close()

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


def wait_exit(process: subprocess.Popen, timeout: float = 3.0) -> tuple:
    """The exit code of a program and the seconds it took to end, or None after timeout seconds (then killed)"""
    started = time.monotonic()
    try:
        code = process.wait(timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        return None, timeout
    return code, time.monotonic() - started


def paused_player(companion: Companion, header_length: int) -> socket.socket:
    """A player that asks for the whole video, reads its header and the start of the first picture, then stops reading
    (a pause): the program blocks on its write, then the app on its own once the queue of units is full"""
    player = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    player.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 65536)
    player.settimeout(10)
    player.connect(('127.0.0.1', companion.port))
    player.sendall(f'GET {companion.url_path} HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-\r\n\r\n'.encode())
    received = b''
    while b'\r\n\r\n' not in received or len(received.split(b'\r\n\r\n', 1)[1]) < header_length + 10:
        chunk = player.recv(65536)
        if not chunk:
            break
        received += chunk
    return player


def check_input_end(report: Report, program: pathlib.Path, fixtures: pathlib.Path, threads: int):
    """The program ends within a second of its standard input closing, whatever its queue of units holds: full (64
    units) with no request, full with a paused player, full after the player closed. The app writes as fast as the
    pipe takes its records, so that a real video always fills the queue"""
    path = fixtures / 'av2-256x144-8bit.ivf'
    _, info = probe(program, path, threads)
    # No request: 90 units of generation 0, 64 in the queue, one read, the rest in the pipe
    stream = Repeated(Stream(path), 10)
    companion = Companion(program, stream, info, threads, feed=False)
    try:
        sent = all(companion.write_record(0, unit, stream.unit(unit), 10) for unit in range(90))
        time.sleep(0.5)
        report.check(sent and companion.process.poll() is None,
                     'no request, 90 units sent: the program waits for room in its queue')
        code, seconds = companion.close(3)
        report.check(code == 0 and seconds < 1.0,
                     f'no request, the queue full: gone {seconds:.2f} s after its input closed, exit {code}')
        report.check(companion.texts()[-1:] == ['exit input-closed'],
                     f'no request, the queue full: last line "exit input-closed" ({companion.texts()[-1:]})')
    finally:
        companion.kill()

    # A paused player, then the input closed; the player closed, then the input closed
    path = fixtures / 'av2-256x144-10bit.ivf'
    _, info = probe(program, path, threads)
    stream = Repeated(Stream(path), 40)
    header_length = len(expected_header(info, stream))
    for label, close_player in (('a paused player', False), ('the player closed', True)):
        companion = Companion(program, stream, info, threads)
        player = None
        try:
            player = paused_player(companion, header_length)
            full = companion.pipe.waited(20)
            report.check(full, f'{label}: the app waits on a full pipe, the queue of the program full '
                               f'({companion.units_written} of {len(stream.units)} units written)')
            if close_player:
                player.close()
                time.sleep(0.3)
            code, seconds = companion.close(3)
            report.check(code == 0 and seconds < 1.0,
                         f'{label}: gone {seconds:.2f} s after its input closed, exit {code}')
            report.check(companion.texts()[-1:] == ['exit input-closed'],
                         f'{label}: last line "exit input-closed" ({companion.texts()[-1:]})')
        except (OSError, Failure) as error:
            report.check(False, f'{label}: {error}')
        finally:
            if player is not None:
                player.close()
            companion.kill()


def check_app_gone(report: Report, program: pathlib.Path, fixtures: pathlib.Path, threads: int):
    """The app gone without closing the input (another process may still hold its end): the program ends when its
    lines can no longer be written (at the next stat line), and when the process of --parent ends"""
    path = fixtures / 'av2-256x144-8bit.ivf'
    stream = Stream(path)
    _, info = probe(program, path, threads)

    pipe = AppPipe()
    lines, write_end = os.pipe()
    command = serve_command(program, stream, info, secrets.token_urlsafe(24), threads)
    process = subprocess.Popen(command, stdin=pipe.child, stdout=write_end, stderr=subprocess.DEVNULL)
    pipe.started()
    os.close(write_end)
    try:
        first = b''
        while not first.endswith(b'\n'):
            chunk = os.read(lines, 1)
            if not chunk:
                break
            first += chunk
        pipe.write(RECORD.pack(b'AV2R', 0, INDEX_UNIT, 8) + struct.pack('<II', 0, 6))
        os.close(lines)
        code, seconds = wait_exit(process)
        report.check(first.startswith(b'listening ') and code == 0 and seconds < 1.5,
                     f'its standard output closed: gone {seconds:.2f} s later, exit {code}')
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        pipe.close()

    parent = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
    companion = None
    try:
        try:
            companion = Companion(program, stream, info, threads, extra=['--parent', str(parent.pid)])
        except Failure as error:
            report.check(False, f'--parent {parent.pid}: {error}')
            return
        time.sleep(0.3)
        report.check(companion.process.poll() is None, '--parent: the program runs while that process lives')
        parent.kill()
        parent.wait()
        code, seconds = wait_exit(companion.process)
        report.check(code == 0 and seconds < 1.0 and companion.wait_line(lambda t: t == 'exit parent-gone', 1),
                     f'--parent: gone {seconds:.2f} s after that process ended, exit {code}, "exit parent-gone"')
    finally:
        if parent.poll() is None:
            parent.kill()
            parent.wait()
        if companion is not None:
            companion.kill()


def check_slow_request(report: Report, program: pathlib.Path, fixtures: pathlib.Path, threads: int):
    """A local program that sends its request a byte at a time, without the token, holds neither the requests of the
    player nor its own connection beyond 2 s"""
    path = fixtures / 'av2-256x144-8bit.ivf'
    stream = Stream(path)
    _, info = probe(program, path, threads)
    companion = Companion(program, stream, info, threads)
    stop = threading.Event()
    trickler = socket.create_connection(('127.0.0.1', companion.port), timeout=10)
    connected = time.monotonic()

    def trickle():
        for byte in b'GET /x HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Slow: ' + b'y' * 200:
            if stop.is_set():
                return
            try:
                trickler.send(bytes([byte]))
            except OSError:
                return
            time.sleep(0.3)

    threading.Thread(target=trickle, daemon=True).start()
    try:
        time.sleep(0.2)
        started = time.monotonic()
        try:
            status = get(companion.port, companion.url_path, method='HEAD', timeout=5)[0]
        except (OSError, http.client.HTTPException):
            status = None
        seconds = time.monotonic() - started
        report.check(status == 200 and seconds < 1.0,
                     f'a request trickling in a byte at a time: the player\'s HEAD answered in {seconds:.2f} s '
                     f'({status})')
        trickler.settimeout(6)
        try:
            while trickler.recv(4096):
                pass
        except OSError:
            pass
        held = time.monotonic() - connected
        report.check(held < 3.0, f'a request trickling in a byte at a time: its connection closed {held:.1f} s after '
                                 'it came')
    finally:
        stop.set()
        trickler.close()
        companion.close()


def check_depth8(report: Report, program: pathlib.Path, fixtures: pathlib.Path, threads: int):
    """--depth 8: the 10-bit pictures as 8-bit samples, (v + 2) >> 2, in a C420 y4m"""
    path = fixtures / 'av2-256x144-10bit.ivf'
    stream = Stream(path)
    _, info = probe(program, path, threads)
    served = {}
    for depth in (0, 8):
        companion = Companion(program, stream, info, threads, depth)
        try:
            served[depth] = (companion.listening, get(companion.port, companion.url_path, start=0)[2])
        finally:
            companion.close()
    (wide, body10), (narrow, body8) = served[0], served[8]
    header = expected_header(info, stream).replace(b' C420p10 ', b' C420 ')
    frame10, frame8 = int(wide['frame']), int(narrow['frame'])
    right = (body8[:len(header)] == header and frame10 == 2 * frame8 and
             len(body8) == len(header) + len(stream.units) * (6 + frame8))
    pictures10 = frames_of(body10, int(wide['header']), frame10)
    pictures8 = frames_of(body8, int(narrow['header']), frame8) if right else []
    rounded = [bytes(min(255, (value + 2) >> 2) for value in struct.unpack(f'<{len(p) // 2}H', p)) for p in pictures10]
    report.check(right and len(pictures8) == len(stream.units) and pictures8 == rounded,
                 f'--depth 8: a C420 y4m of {len(pictures8)} pictures, the 10-bit ones rounded to 8 bits')


def check_speed(report: Report, program: pathlib.Path, fixtures: pathlib.Path, entry: dict, threads: int):
    """The decoding speed of the stat lines on a video the player reads as fast as it can (600 pictures: the fixture
    50 times, each copy decoded as avmdec v1.0.0 decodes the fixture)"""
    path = fixtures / 'av2-256x144-8bit.ivf'
    _, info = probe(program, path, threads)
    stream = Repeated(Stream(path), 50)
    header_length = len(expected_header(info, stream))
    companion = Companion(program, stream, info, threads)
    try:
        started = time.monotonic()
        status, _, body = get(companion.port, companion.url_path, start=0, timeout=120)
        seconds = time.monotonic() - started
        pictures = frames_of(body, header_length, info['y4m']['frame_bytes'])
        count = len(entry['frame_md5'])
        report.check(status == 206 and len(pictures) == len(stream.units) and
                     all(hashlib.md5(p).hexdigest() == entry['frame_md5'][k % count] for k, p in enumerate(pictures)),
                     f'the fixture 50 times: {len(pictures)} pictures, each as avmdec v1.0.0 decodes the fixture')
        mark = companion.line_count()
        line = companion.wait_line(lambda text: text.startswith('stat '), 2, mark) or ''
        fields = dict(part.split('=', 1) for part in line.split()[1:])
        fps = float(fields.get('fps', 0))
        rate = len(pictures) / seconds if seconds > 0 else 0
        report.check(fps > 0 and fps >= 0.5 * rate,
                     f'the decoding speed of the stat lines: fps={fps:.0f}, {rate:.0f} pictures per second served')
    finally:
        companion.close()


def check_probe_starts(report: Report, program: pathlib.Path, fixtures: pathlib.Path, threads: int):
    """The probe of the start of a file: cut in its first picture, too short for a sequence header, read on the
    standard input, and a first picture after 5, 20 and 70 MiB (steps of 1, 4, 16 and 64 MiB)"""
    path = fixtures / 'av2-256x144-8bit.ivf'
    data = path.read_bytes()
    _, whole = probe(program, path, threads)
    with tempfile.TemporaryDirectory(prefix='av2-probe-') as folder:
        folder = pathlib.Path(folder)
        cut = folder / 'cut-in-first-picture.ivf'
        cut.write_bytes(data[:1000])
        code, info = probe(program, cut, threads)
        report.check(code == 0 and info.get('playable') is False and
                     info.get('refusal') == 'a stream without a picture in its start' and
                     info.get('sequence', {}).get('bits') == 8,
                     f'probe of the first 1000 bytes: the sequence header, not playable ({info.get("refusal")})')
        short = folder / 'short.ivf'
        short.write_bytes(data[:40])
        code, info = probe(program, short, threads)
        report.check(code == 3 and 'no AV2 sequence header' in info.get('error', ''),
                     f'probe of the first 40 bytes: exit 3, no sequence header ({info})')
        piped = subprocess.run([str(program), 'probe', '-', '--threads', str(threads)], input=data,
                               capture_output=True, timeout=60)
        text = piped.stdout.decode('utf-8', 'replace').strip()
        report.check(piped.returncode == 0 and text and json.loads(text.splitlines()[-1]) == whole,
                     'probe - on the standard input: the JSON of the file')
        for megabytes, playable in ((5, True), (20, True), (70, False)):
            padded = folder / f'first-picture-after-{megabytes}-mib.ivf'
            padded.write_bytes(padded_ivf(data, megabytes << 20))
            code, info = probe(program, padded, threads)
            if playable:
                good = code == 0 and info.get('playable') is True and info.get('picture', {}).get('width') == 256
            else:
                good = (code == 0 and info.get('playable') is False and
                        info.get('refusal') == 'a stream without a picture in its start')
            report.check(good, f'probe of a first picture after {megabytes} MiB: '
                               f'{"playable" if playable else "beyond 64 MiB, not playable"} ({info.get("refusal")})')
            if megabytes == 20:
                piped = subprocess.run([str(program), 'probe', '-', '--threads', str(threads)],
                                       input=padded.read_bytes(), capture_output=True, timeout=60)
                text = piped.stdout.decode('utf-8', 'replace').strip()
                info = json.loads(text.splitlines()[-1]) if text else {}
                report.check(piped.returncode == 0 and info.get('playable') is True,
                             'probe - of a first picture after 20 MiB on the standard input: playable')
            padded.unlink()


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
    check_probe_starts(report, args.program, fixtures, args.threads)
    check_depth8(report, args.program, fixtures, args.threads)
    check_speed(report, args.program, fixtures, entries['av2-256x144-8bit.ivf'], args.threads)
    check_slow_request(report, args.program, fixtures, args.threads)
    check_input_end(report, args.program, fixtures, args.threads)
    check_app_gone(report, args.program, fixtures, args.threads)
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
