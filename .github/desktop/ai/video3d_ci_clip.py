#!/usr/bin/env python3
"""The CI check of the 3D videos with the real FFmpeg program and tiny_vda.onnx (video3d-plan.md, section 5).

  video3d_ci_clip.py make FFMPEG OUT.mkv   writes a 4 s clip, 160 x 90 at 25 fps, a moving pattern with a cut at 2 s
                                           and a stereo tone, encoded by the program itself (SVT-AV1 and AAC)
  video3d_ci_clip.py check LOG             reads the events of video3d_probe in the log of the test: one done event,
                                           100 frames, st3d left right, one cut; prints the encoder chosen

Pure Python 3, no package.
"""
import json
import math
import os
import pathlib
import struct
import subprocess
import sys
import tempfile

WIDTH, HEIGHT, RATE, FRAMES, CUT = 160, 90, 25, 100, 50


def frame(index: int) -> bytes:
    out = bytearray()
    for y in range(HEIGHT):
        for x in range(WIDTH):
            if index < CUT:
                out += bytes(((3 * x + 2 * index) % 120, (2 * y + index) % 100 + 20, (x * y // 8 + index) % 90))
            else:
                out += bytes((140 + (5 * y + 3 * index) % 110, 120 + (2 * x + index) % 130, 200 + (x + y) % 55))
    return bytes(out)


def make(ffmpeg: str, target: str) -> None:
    with tempfile.TemporaryDirectory() as work:
        video = pathlib.Path(work, 'video.rgb')
        audio = pathlib.Path(work, 'audio.raw')
        video.write_bytes(b''.join(frame(i) for i in range(FRAMES)))
        samples = 48000 * FRAMES // RATE
        audio.write_bytes(b''.join(struct.pack('<hh', int(8000 * math.sin(i / 20)), int(8000 * math.sin(i / 31)))
                                   for i in range(samples)))
        subprocess.run([ffmpeg, '-nostdin', '-hide_banner', '-v', 'error', '-y',
                        '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{WIDTH}x{HEIGHT}', '-framerate', str(RATE),
                        '-i', str(video), '-f', 's16le', '-ar', '48000', '-ac', '2', '-i', str(audio),
                        '-vf', 'scale=out_color_matrix=bt709:out_range=tv,format=yuv420p',
                        '-c:v', 'libsvtav1', '-preset', '12', '-crf', '20', '-c:a', 'aac', target], check=True)
    print(f'{target}: {os.path.getsize(target)} bytes')


def check(log: str) -> int:
    done = []
    for line in pathlib.Path(log).read_text(encoding='utf-8', errors='replace').splitlines():
        start = line.find('{"event"')
        if start >= 0:
            event = json.loads(line[start:])
            if event['event'] == 'failed':
                print(f'::error::the 3D video failed: {event["error"]}')
                return 1
            if event['event'] == 'done':
                done.append(event)
    if len(done) != 1:
        print(f'::error::{len(done)} 3D videos made, 1 expected')
        return 1
    event = done[0]
    problems = []
    if event['frames'] != FRAMES:
        problems.append(f'{event["frames"]} frames, {FRAMES} expected')
    if not event['st3d_left_right']:
        problems.append('no st3d left right read back by the app')
    if event['cuts'] != [CUT]:
        problems.append(f'cuts {event["cuts"]}, [{CUT}] expected')
    for problem in problems:
        print(f'::error::{problem}')
    print(f'3D video: {event["frames"]} frames, encoder {event["encoder"]}, cuts {event["cuts"]}, '
          f'st3d {event["st3d"]}, {event["bytes"]} bytes, holes {event["holes_mean"]:.4f}')
    return 1 if problems else 0


if __name__ == '__main__':
    if sys.argv[1] == 'make':
        make(sys.argv[2], sys.argv[3])
    else:
        sys.exit(check(sys.argv[2]))
