#!/usr/bin/env python3
"""The CI check of the 3D videos with the real FFmpeg program and tiny_vda.onnx (video3d-plan.md, section 5).

  video3d_ci_clip.py make FFMPEG OUT.mkv   writes a 4 s clip, 160 x 90 at 25 fps, a moving pattern with a cut at 2 s,
                                           encoded by the program itself (SVT-AV1). No sound: the program has no raw
                                           audio or WAV demuxer to take one from (the mux of the sound is checked by the
                                           integration on ai1 and by the CI of the program)
  video3d_ci_clip.py check LOG             reads the events of video3d_probe in the log of the test: one done event,
                                           100 frames, st3d left right, one cut; prints the encoder chosen
  video3d_ci_clip.py drift FFMPEG DIR      12 Matroska segments of 899 frames at 30000/1001 made by the program as the
                                           engine makes them, joined into an MP4 by its concat demuxer with the list
                                           the engine writes (each file followed by its exact duration,
                                           videoConcatList): the last frame within 1 ms of 12 x 899 - 1 frames, so the
                                           picture keeps to the source's sound over a long film; the same list without
                                           the durations is shown drifting
  video3d_ci_clip.py make360 FFMPEG OUT.mkv  writes a 3 s equirectangular clip, 256 x 128 at 25 fps, stripes that
                                           wrap across the seam, a bright band moving along the equator, a textured
                                           sky and ground at the poles (lot ai-360-3d-51)
  video3d_ci_clip.py check360 LOG          reads the events of video3d_probe --sphere 256: one done event of 75
                                           frames, a square top and bottom frame of 256 x 256, st3d top and bottom
                                           and sv3d of a whole sphere read back by the app, the eyes of frame 50 alike
                                           at the poles and apart at the equator, no jump across the seam of the right
                                           eye beyond that of the left one
  video3d_ci_clip.py decoders FFMPEG DART  the audio decoders the program prints (-decoders) are those the app counts on
                                           (VideoAudioTrack.decodable of video_source.dart, by ffprobe's codec names:
                                           the dca decoder reads "dts"), so no track is accepted that only the final
                                           mux would find unreadable

Pure Python 3, no package.
"""
import json
import os
import pathlib
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
        video.write_bytes(b''.join(frame(i) for i in range(FRAMES)))
        subprocess.run([ffmpeg, '-nostdin', '-hide_banner', '-v', 'error', '-y',
                        '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{WIDTH}x{HEIGHT}', '-framerate', str(RATE),
                        '-i', str(video), '-vf', 'scale=out_color_matrix=bt709:out_range=tv,format=yuv420p',
                        '-c:v', 'libsvtav1', '-preset', '12', '-crf', '20', target], check=True)
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


SPHERE_WIDTH, SPHERE_HEIGHT, SPHERE_FRAMES = 256, 128, 75


def sphere_frame(index: int) -> bytes:
    import math
    out = bytearray()
    for y in range(SPHERE_HEIGHT):
        for x in range(SPHERE_WIDTH):
            # Stripes of 16 columns: whole periods around the 256 columns, so the seam is no edge
            stripe = 0.5 + 0.5 * math.sin(2 * math.pi * x / 16 + 0.15 * index)
            if y < 16 or y >= SPHERE_HEIGHT - 16:
                # Sky and ground: a texture of their own
                value = int(60 + 120 * stripe * (0.5 + 0.5 * math.cos(2 * math.pi * y / 8)))
                out += bytes((value, value // 2 + 40, 200 - value // 2))
            else:
                # A bright band (near, for tiny_vda) that moves along the equator, darker around it
                centre = (index * 3) % SPHERE_WIDTH
                distance = min(abs(x - centre), SPHERE_WIDTH - abs(x - centre))
                near = 1.0 if distance < 24 and abs(y - SPHERE_HEIGHT // 2) < 20 else 0.3
                value = int(255 * near * (0.4 + 0.6 * stripe))
                out += bytes((value, int(value * 0.8), int(value * 0.6)))
    return bytes(out)


def make360(ffmpeg: str, target: str) -> None:
    with tempfile.TemporaryDirectory() as work:
        video = pathlib.Path(work, 'sphere.rgb')
        video.write_bytes(b''.join(sphere_frame(i) for i in range(SPHERE_FRAMES)))
        subprocess.run([ffmpeg, '-nostdin', '-hide_banner', '-v', 'error', '-y',
                        '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{SPHERE_WIDTH}x{SPHERE_HEIGHT}',
                        '-framerate', str(RATE), '-i', str(video),
                        '-vf', 'scale=out_color_matrix=bt709:out_range=tv,format=yuv420p',
                        '-c:v', 'libsvtav1', '-preset', '12', '-crf', '20', target], check=True)
    print(f'{target}: {os.path.getsize(target)} bytes')


def check360(log: str) -> int:
    done = []
    spheres = []
    for line in pathlib.Path(log).read_text(encoding='utf-8', errors='replace').splitlines():
        start = line.find('{"event"')
        if start >= 0:
            event = json.loads(line[start:])
            if event['event'] == 'failed':
                print(f'::error::the 360° 3D video failed: {event["error"]}')
                return 1
            if event['event'] == 'done':
                done.append(event)
            if event['event'] == 'sphere':
                spheres.append(event)
    if len(done) != 1 or len(spheres) != 1:
        print(f'::error::{len(done)} 360° 3D videos made and {len(spheres)} read back, 1 expected')
        return 1
    event, sphere = done[0], spheres[0]
    problems = []
    if event['frames'] != SPHERE_FRAMES:
        problems.append(f'{event["frames"]} frames, {SPHERE_FRAMES} expected')
    if (sphere['width'], sphere['height']) != (SPHERE_WIDTH, 2 * SPHERE_HEIGHT):
        problems.append(f'a frame of {sphere["width"]} x {sphere["height"]}, {SPHERE_WIDTH} x {2 * SPHERE_HEIGHT} expected')
    if not sphere['st3d_top_bottom']:
        problems.append('no st3d top and bottom read back by the app')
    if not sphere['sv3d'] or sphere['half_sphere'] is not False:
        problems.append(f'sv3d {sphere["sv3d"]}, half sphere {sphere["half_sphere"]}: a whole sphere expected')
    if not sphere['equator_diff'] > 1.0:
        problems.append(f'the eyes alike at the equator ({sphere["equator_diff"]:.2f}): no relief')
    if not sphere['pole_diff'] < sphere['equator_diff'] / 2:
        problems.append(f'the eyes apart at the poles ({sphere["pole_diff"]:.2f} against {sphere["equator_diff"]:.2f} '
                        'at the equator)')
    if not sphere['seam_right'] <= sphere['seam_left'] * 1.5 + 6:
        problems.append(f'a jump across the seam of the right eye ({sphere["seam_right"]:.2f} against '
                        f'{sphere["seam_left"]:.2f} in the left eye)')
    for problem in problems:
        print(f'::error::{problem}')
    print(f'360° 3D video: {event["frames"]} frames, encoder {event["encoder"]}, {sphere["width"]} x '
          f'{sphere["height"]}, st3d top and bottom {sphere["st3d_top_bottom"]}, sv3d {sphere["sv3d"]}, '
          f'eyes apart {sphere["pole_diff"]:.2f} at the poles and {sphere["equator_diff"]:.2f} at the equator, '
          f'seam {sphere["seam_left"]:.2f} left and {sphere["seam_right"]:.2f} right, {event["bytes"]} bytes, '
          f'holes {event["holes_mean"]:.4f}')
    return 1 if problems else 0


SEGMENTS, SEGMENT_FRAMES, NUM, DEN = 12, 899, 30000, 1001


def concat_list(names: list, durations: bool) -> str:
    """The list of videoConcatList (ffmpeg_commands.dart): each file, then its slots at the grid's rate"""
    lines = ['ffconcat version 1.0']
    for name in names:
        lines.append(f"file '{name}'")
        if durations:
            lines.append(f'duration {SEGMENT_FRAMES * DEN / NUM:.9f}')
    return '\n'.join(lines)


def last_pts(ffmpeg: str, path: pathlib.Path) -> float:
    probe = pathlib.Path(ffmpeg).with_name('ffprobe' + pathlib.Path(ffmpeg).suffix)
    out = subprocess.run([str(probe), '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'packet=pts_time',
                          '-of', 'csv=p=0', str(path)], check=True, capture_output=True, text=True).stdout
    return max(float(value) for value in out.split())


def drift(ffmpeg: str, folder: str) -> int:
    work = pathlib.Path(folder)
    work.mkdir(parents=True, exist_ok=True)
    names = []
    for index in range(SEGMENTS):
        name = f'seg-{index + 1:04d}.seg'
        subprocess.run([ffmpeg, '-nostdin', '-hide_banner', '-v', 'error', '-y', '-f', 'lavfi', '-i',
                        f'color=c=gray:s=64x64:r={NUM}/{DEN}', '-frames:v', str(SEGMENT_FRAMES), '-vf',
                        'format=yuv420p', '-c:v', 'libsvtav1', '-preset', '12', '-svtav1-params', 'lp=2',
                        '-metadata:s:v:0', 'stereo_mode=left_right', '-f', 'matroska', str(work / name)],
                       check=True, capture_output=True)
        names.append(name)
    expected = (SEGMENTS * SEGMENT_FRAMES - 1) * DEN / NUM
    found = {}
    for durations in (False, True):
        listing = work / f'segments-{"durations" if durations else "plain"}.txt'
        listing.write_text(concat_list(names, durations), encoding='utf-8')
        output = work / f'joined-{"durations" if durations else "plain"}.mp4'
        subprocess.run([ffmpeg, '-nostdin', '-hide_banner', '-v', 'error', '-y', '-f', 'concat', '-safe', '0', '-i',
                        str(listing), '-map', '0:v', '-c:v', 'copy', '-f', 'mp4', str(output)], check=True)
        found[durations] = last_pts(ffmpeg, output)
        print(f'{"with" if durations else "without"} the durations: last frame at {found[durations]:.6f} s, '
              f'{1000 * (found[durations] - expected):+.3f} ms')
    if abs(found[True] - expected) > 0.001:
        print(f'::error::the joined segments end at {found[True]:.6f} s, {expected:.6f} s expected')
        return 1
    return 0


# The decoders whose name is not the codec name ffprobe gives
DECODER_CODECS = {'dca': 'dts'}


def decoders(ffmpeg: str, dart: str) -> int:
    import re
    printed = subprocess.run([ffmpeg, '-hide_banner', '-decoders'], check=True, capture_output=True,
                             text=True).stdout
    program = set()
    for line in printed.splitlines():
        found = re.match(r'^ (A)[A-Z.]{5} (\w+) ', line)
        if found:
            program.add(DECODER_CODECS.get(found.group(2), found.group(2)))
    text = pathlib.Path(dart).read_text(encoding='utf-8')
    block = re.search(r'static const decodable = \{(.*?)\};', text, re.DOTALL)
    if not block:
        print(f'::error::no VideoAudioTrack.decodable in {dart}')
        return 1
    app = set(re.findall(r"'([^']+)'", block.group(1)))
    problems = []
    if app - program:
        problems.append(f'the app counts on audio decoders the program lacks: {sorted(app - program)}')
    if program - app:
        problems.append(f'the program has audio decoders the app does not count on: {sorted(program - app)}')
    for problem in problems:
        print(f'::error::{problem}')
    print(f'audio decoders: {len(program)} in the program, {len(app)} in the app')
    return 1 if problems else 0


if __name__ == '__main__':
    if sys.argv[1] == 'make':
        make(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == 'make360':
        make360(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == 'check360':
        sys.exit(check360(sys.argv[2]))
    elif sys.argv[1] == 'drift':
        sys.exit(drift(sys.argv[2], sys.argv[3]))
    elif sys.argv[1] == 'decoders':
        sys.exit(decoders(sys.argv[2], sys.argv[3]))
    else:
        sys.exit(check(sys.argv[2]))
