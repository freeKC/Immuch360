#!/usr/bin/env python3
"""A small synthetic set posed by COLMAP in the colmap jobs: the archive just built places all its views, where they are.

The splat scenes of Immuch360 Desktop (lot SP1 of the splat maker, plan of 2026-11-01, section 3) place the photos with
COLMAP built by our CI without its GPL parts. Before an archive leaves the job, this script renders a closed room with
three boxes, every face covered by its own noise texture, as seen by 24 cameras on a circle turned towards the boxes,
with two focal lengths (two folders, so two cameras for --ImageReader.single_camera_per_folder), and keeps the true
poses. The job then runs the chain of the app on it with the archive's program (feature_extractor on the processor,
exhaustive_matcher, mapper) and compares: every view placed, two cameras, and after the similarity that best maps the
computed centres on the true ones, each rotation within 1 degree and each centre within 2 % of the spread of the
cameras.

  colmap_synthetic.py render --out DIR [--views N] [--width W] [--height H]
      DIR/images/a/*.png and DIR/images/b/*.png (8 bit grey, stored without compression: the same bytes on every
      system) and DIR/poses.json (per image: camera, focal length, rotation world to camera, translation)
  colmap_synthetic.py pose --colmap FILE --set DIR [--threads N]
      the chain of the app on DIR with the program FILE: DIR/work/database.db, DIR/work/sparse/<n>, then the largest
      model written as text in DIR/work/text
  colmap_synthetic.py compare --set DIR [--model DIR] [--max-rotation DEGREES] [--max-centre FRACTION]
      the poses of the text model (DIR/work/text by default) against DIR/poses.json

Only the Python standard library is used: no Pillow on the runners. Exit codes: 0 good, 1 a check failed, 2 bad
arguments or missing inputs.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import pathlib
import struct
import subprocess
import sys
import zlib

# The room, metres, y up: walls, floor and ceiling seen from the inside
ROOM = ((-4.0, 0.0, -4.0), (4.0, 3.0, 4.0))
BOXES = (
    ((-0.9, 0.0, -0.5), (-0.2, 0.9, 0.2)),
    ((0.1, 0.0, -0.2), (0.8, 1.3, 0.6)),
    ((-0.4, 0.0, 0.7), (0.3, 0.6, 1.3)),
)
# The two cameras: focal lengths in pixels of a 320 x 240 view, scaled with the width
FOCALS = {'a': 280.0, 'b': 320.0}
BASE_WIDTH = 320


class Failure(Exception):
    pass


# --- vectors ---------------------------------------------------------------------------------------------------------

def sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def norm(a):
    length = math.sqrt(dot(a, a))
    return (a[0] / length, a[1] / length, a[2] / length)


def matmul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(len(b))) for j in range(len(b[0]))] for i in range(len(a))]


def transpose(a):
    return [list(row) for row in zip(*a)]


def apply(m, v):
    return tuple(sum(m[i][k] * v[k] for k in range(3)) for i in range(3))


# --- the cameras -----------------------------------------------------------------------------------------------------

def cameras(views: int) -> list:
    """Name, folder, centre and rotation (world to camera, COLMAP's convention: x right, y down, z forward)"""
    found = []
    for index in range(views):
        angle = 2 * math.pi * index / views
        radius = 2.8 + 0.15 * math.sin(3 * angle)
        centre = (radius * math.cos(angle), 1.5 + 0.2 * math.cos(2 * angle), radius * math.sin(angle))
        target = (0.15 * math.sin(angle), 0.6, 0.15 * math.cos(angle))
        forward = norm(sub(target, centre))
        right = norm(cross((0.0, -1.0, 0.0), forward))
        down = cross(forward, right)
        folder = 'a' if index % 2 == 0 else 'b'
        found.append((f'{folder}/view_{index:02d}.png', folder, centre, [list(right), list(down), list(forward)]))
    return found


# --- the scene -------------------------------------------------------------------------------------------------------

def mix(value: int) -> float:
    """A hash of an integer lattice point into [0, 1), with integer arithmetic only (the same on every system)"""
    value &= 0xFFFFFFFF
    value ^= value >> 16
    value = (value * 0x7FEB352D) & 0xFFFFFFFF
    value ^= value >> 15
    value = (value * 0x846CA68B) & 0xFFFFFFFF
    value ^= value >> 16
    return value / 4294967296.0


def lattice(ix: int, iy: int, seed: int) -> float:
    return mix(ix * 0x8DA6B343 ^ iy * 0xD8163841 ^ seed * 0xCB1AB31F)


def value_noise(u: float, v: float, seed: int) -> float:
    x0, y0 = math.floor(u), math.floor(v)
    fx, fy = u - x0, v - y0
    sx, sy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    a, b = lattice(x0, y0, seed), lattice(x0 + 1, y0, seed)
    c, d = lattice(x0, y0 + 1, seed), lattice(x0 + 1, y0 + 1, seed)
    return (a + (b - a) * sx) + ((c + (d - c) * sx) - (a + (b - a) * sx)) * sy


def texture(face: int, u: float, v: float) -> int:
    """The grey level of a face at (u, v) metres: three octaves of value noise over a shade of its own"""
    shade = 0.35 + 0.3 * mix(face * 977 + 13)
    level = (0.55 * value_noise(u / 0.11, v / 0.11, face * 3 + 1) + 0.3 * value_noise(u / 0.047, v / 0.047, face * 3 + 2)
             + 0.15 * value_noise(u / 0.021, v / 0.021, face * 3 + 3))
    return max(0, min(255, int(255 * (shade * 0.6 + level * 0.7 - 0.15))))


def box_hit(origin, direction, low, high):
    """Distance and axis of the entry of a ray into a box, or None"""
    near, far, axis = -math.inf, math.inf, -1
    for k in range(3):
        if abs(direction[k]) < 1e-12:
            if origin[k] < low[k] or origin[k] > high[k]:
                return None
            continue
        t1, t2 = (low[k] - origin[k]) / direction[k], (high[k] - origin[k]) / direction[k]
        if t1 > t2:
            t1, t2 = t2, t1
        if t1 > near:
            near, axis = t1, k
        far = min(far, t2)
        if near > far:
            return None
    if near <= 1e-9:
        return None
    return near, axis


def room_hit(origin, direction):
    """Distance and axis of the wall, floor or ceiling a ray leaves the room through"""
    best, axis = math.inf, -1
    for k in range(3):
        if abs(direction[k]) < 1e-12:
            continue
        bound = ROOM[1][k] if direction[k] > 0 else ROOM[0][k]
        t = (bound - origin[k]) / direction[k]
        if 0 < t < best:
            best, axis = t, k
    return best, axis


def shade(origin, direction) -> int:
    distance, axis = room_hit(origin, direction)
    face = axis * 2 + (1 if direction[axis] > 0 else 0)
    for index, (low, high) in enumerate(BOXES):
        hit = box_hit(origin, direction, low, high)
        if hit is not None and hit[0] < distance:
            distance, axis = hit
            face = 6 + index * 6 + axis * 2 + (1 if direction[axis] > 0 else 0)
    point = tuple(origin[k] + distance * direction[k] for k in range(3))
    u, v = [point[k] for k in range(3) if k != axis]
    return texture(face, u, v)


# --- PNG -------------------------------------------------------------------------------------------------------------

def png_grey(width: int, height: int, rows: list) -> bytes:
    """An 8 bit grey PNG whose zlib stream is made of stored blocks, written here: no compressor, the same bytes on
    every system"""
    raw = b''.join(b'\0' + bytes(row) for row in rows)
    stream = bytearray(b'\x78\x01')
    for start in range(0, len(raw), 65535):
        block = raw[start:start + 65535]
        last = 1 if start + 65535 >= len(raw) else 0
        stream += struct.pack('<BHH', last, len(block), len(block) ^ 0xFFFF) + block
    stream += struct.pack('>I', zlib.adler32(raw) & 0xFFFFFFFF)

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xFFFFFFFF)

    header = struct.pack('>IIBBBBB', width, height, 8, 0, 0, 0, 0)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', bytes(stream)) + chunk(b'IEND', b'')


def command_render(args) -> int:
    if args.views < 6 or args.width < 64 or args.height < 48:
        raise SystemExit('at least 6 views of 64 x 48 pixels')
    poses = {}
    for name, folder, centre, rotation in cameras(args.views):
        focal = FOCALS[folder] * args.width / BASE_WIDTH
        cx, cy = args.width / 2, args.height / 2
        world = transpose(rotation)
        rows = []
        for y in range(args.height):
            row = []
            for x in range(args.width):
                ray = norm(apply(world, ((x + 0.5 - cx) / focal, (y + 0.5 - cy) / focal, 1.0)))
                row.append(shade(centre, ray))
            rows.append(row)
        target = args.out / 'images' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(png_grey(args.width, args.height, rows))
        translation = [-x for x in apply(rotation, centre)]
        poses[name] = {'camera': folder, 'focal': focal, 'rotation': rotation, 'translation': translation,
                       'centre': list(centre)}
    (args.out / 'poses.json').write_text(json.dumps({'width': args.width, 'height': args.height, 'images': poses},
                                                    indent=1, sort_keys=True) + '\n', encoding='utf-8', newline='\n')
    print(f'{len(poses)} views of {args.width} x {args.height} in {args.out / "images"}, true poses in poses.json')
    return 0


# --- pose ------------------------------------------------------------------------------------------------------------

def run(command: list):
    print('$ ' + ' '.join(str(part) for part in command), flush=True)
    subprocess.run([str(part) for part in command], check=True)


def command_pose(args) -> int:
    images, work = args.set / 'images', args.set / 'work'
    if not images.is_dir():
        raise Failure(f'no images in {args.set}: render first')
    (work / 'sparse').mkdir(parents=True, exist_ok=True)
    database = work / 'database.db'
    if database.exists():
        database.unlink()
    colmap = args.colmap
    threads = str(args.threads)
    run([colmap, 'feature_extractor', '--database_path', database, '--image_path', images,
         '--ImageReader.single_camera_per_folder', '1', '--FeatureExtraction.use_gpu', '0',
         '--FeatureExtraction.num_threads', threads])
    run([colmap, 'exhaustive_matcher', '--database_path', database, '--FeatureMatching.use_gpu', '0',
         '--FeatureMatching.num_threads', threads])
    run([colmap, 'mapper', '--database_path', database, '--image_path', images, '--output_path', work / 'sparse',
         '--Mapper.num_threads', threads])
    models = [path for path in (work / 'sparse').iterdir() if (path / 'images.bin').is_file()]
    if not models:
        raise Failure('the mapper wrote no model')
    # The largest model, by its number of images (the first one is not always it: measure of 2026-11-01, section 3)
    largest = max(models, key=lambda path: struct.unpack('<Q', (path / 'images.bin').read_bytes()[:8])[0])
    text = work / 'text'
    text.mkdir(exist_ok=True)
    run([colmap, 'model_converter', '--input_path', largest, '--output_path', text, '--output_type', 'TXT'])
    print(f'{len(models)} model(s), the largest is {largest.name}, as text in {text}')
    return 0


# --- compare ---------------------------------------------------------------------------------------------------------

def quaternion_matrix(w, x, y, z):
    return [[1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
            [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
            [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)]]


def read_model(folder: pathlib.Path) -> tuple:
    """The images ({name: (camera, rotation, translation)}) and the number of cameras of a text model"""
    images = {}
    lines = [line for line in (folder / 'images.txt').read_text(encoding='utf-8').splitlines()
             if line.strip() and not line.startswith('#')]
    # Two lines per image: the pose, then its 2D points (which may be empty, hence the lines kept above are pairs only
    # when no image has an empty second line: read the pose lines by their shape instead)
    for line in lines:
        parts = line.split()
        if len(parts) != 10:
            continue
        try:
            values = [float(part) for part in parts[1:8]]
            camera = int(parts[8])
        except ValueError:
            continue
        images[parts[9]] = (camera, quaternion_matrix(*values[:4]), values[4:7])
    cameras_lines = [line for line in (folder / 'cameras.txt').read_text(encoding='utf-8').splitlines()
                     if line.strip() and not line.startswith('#')]
    return images, len(cameras_lines)


def jacobi_eigen(matrix: list) -> tuple:
    """Eigenvalues and eigenvectors (columns) of a small symmetric matrix"""
    n = len(matrix)
    a = [row[:] for row in matrix]
    v = [[1.0 if i == j else 0.0 for j in range(n)] for i in range(n)]
    for _ in range(100):
        off = sum(a[i][j] ** 2 for i in range(n) for j in range(n) if i != j)
        if off < 1e-22:
            break
        for p in range(n):
            for q in range(p + 1, n):
                if abs(a[p][q]) < 1e-30:
                    continue
                theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                t = (1.0 if theta >= 0 else -1.0) / (abs(theta) + math.sqrt(theta * theta + 1))
                c = 1 / math.sqrt(t * t + 1)
                s = t * c
                for k in range(n):
                    akp, akq = a[k][p], a[k][q]
                    a[k][p], a[k][q] = c * akp - s * akq, s * akp + c * akq
                for k in range(n):
                    apk, aqk = a[p][k], a[q][k]
                    a[p][k], a[q][k] = c * apk - s * aqk, s * apk + c * aqk
                for k in range(n):
                    vkp, vkq = v[k][p], v[k][q]
                    v[k][p], v[k][q] = c * vkp - s * vkq, s * vkp + c * vkq
    return [a[i][i] for i in range(n)], v


def similarity(source: list, target: list) -> tuple:
    """Scale, rotation and translation with target ~ scale * rotation * source + translation (Horn's quaternions)"""
    count = len(source)
    mean_s = [sum(p[k] for p in source) / count for k in range(3)]
    mean_t = [sum(p[k] for p in target) / count for k in range(3)]
    s = [[p[k] - mean_s[k] for k in range(3)] for p in source]
    t = [[p[k] - mean_t[k] for k in range(3)] for p in target]
    m = [[sum(s[i][a] * t[i][b] for i in range(count)) for b in range(3)] for a in range(3)]
    sxx, sxy, sxz = m[0]
    syx, syy, syz = m[1]
    szx, szy, szz = m[2]
    n = [[sxx + syy + szz, syz - szy, szx - sxz, sxy - syx],
         [syz - szy, sxx - syy - szz, sxy + syx, szx + sxz],
         [szx - sxz, sxy + syx, -sxx + syy - szz, syz + szy],
         [sxy - syx, szx + sxz, syz + szy, -sxx - syy + szz]]
    values, vectors = jacobi_eigen(n)
    best = max(range(4), key=lambda index: values[index])
    rotation = quaternion_matrix(*[vectors[k][best] for k in range(4)])
    rotated = [apply(rotation, p) for p in s]
    scale = sum(dot(rotated[i], t[i]) for i in range(count)) / sum(dot(p, p) for p in s)
    shift = sub(mean_t, [scale * x for x in apply(rotation, mean_s)])
    return scale, rotation, shift


def rotation_angle(a: list, b: list) -> float:
    """The angle in degrees of the rotation from a to b"""
    relative = matmul(a, transpose(b))
    trace = relative[0][0] + relative[1][1] + relative[2][2]
    return math.degrees(math.acos(max(-1.0, min(1.0, (trace - 1) / 2))))


def command_compare(args) -> int:
    truth = json.loads((args.set / 'poses.json').read_text(encoding='utf-8'))['images']
    model = args.model or args.set / 'work' / 'text'
    images, camera_count = read_model(model)
    problems = []
    placed = sorted(name for name in images if name in truth)
    print(f'{len(placed)} of {len(truth)} views placed, {camera_count} camera(s)')
    if len(placed) != len(truth):
        problems.append(f'{len(truth) - len(placed)} of {len(truth)} views not placed: '
                        + ', '.join(sorted(set(truth) - set(placed))))
    expected_cameras = len({value['camera'] for value in truth.values()})
    if camera_count != expected_cameras:
        problems.append(f'{camera_count} camera(s) in the model, {expected_cameras} folders of views')
    if len(placed) >= 3:
        computed = [[-x for x in apply(transpose(images[name][1]), images[name][2])] for name in placed]
        true = [truth[name]['centre'] for name in placed]
        scale, rotation, shift = similarity(computed, true)
        spread = max(math.dist(p, q) for p in true for q in true)
        worst_centre = worst_angle = 0.0
        for name, centre, true_centre in zip(placed, computed, true):
            mapped = [scale * x + y for x, y in zip(apply(rotation, centre), shift)]
            error = math.dist(mapped, true_centre) / spread
            angle = rotation_angle(matmul(images[name][1], transpose(rotation)), truth[name]['rotation'])
            worst_centre, worst_angle = max(worst_centre, error), max(worst_angle, angle)
            if error > args.max_centre:
                problems.append(f'{name}: centre {100 * error:.2f} % of the spread away, at most '
                                f'{100 * args.max_centre:.2f} %')
            if angle > args.max_rotation:
                problems.append(f'{name}: rotation {angle:.3f} degrees away, at most {args.max_rotation}')
        print(f'after the similarity (scale {scale:.4f}): centres within {100 * worst_centre:.3f} % of the spread, '
              f'rotations within {worst_angle:.4f} degrees')
    for problem in problems:
        print(f'::error::{problem}')
    return 1 if problems else 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest='command', required=True)
    render = commands.add_parser('render')
    render.add_argument('--out', type=pathlib.Path, required=True)
    render.add_argument('--views', type=int, default=24)
    render.add_argument('--width', type=int, default=320)
    render.add_argument('--height', type=int, default=240)
    pose = commands.add_parser('pose')
    pose.add_argument('--colmap', type=pathlib.Path, required=True)
    pose.add_argument('--set', type=pathlib.Path, required=True)
    pose.add_argument('--threads', type=int, default=max(1, min(4, os.cpu_count() or 1)))
    compare = commands.add_parser('compare')
    compare.add_argument('--set', type=pathlib.Path, required=True)
    compare.add_argument('--model', type=pathlib.Path)
    compare.add_argument('--max-rotation', type=float, default=1.0)
    compare.add_argument('--max-centre', type=float, default=0.02)
    args = parser.parse_args(argv)
    try:
        return {'render': command_render, 'pose': command_pose, 'compare': command_compare}[args.command](args)
    except (Failure, subprocess.CalledProcessError) as error:
        print(f'::error::{error}')
        return 1
    except (OSError, KeyError, ValueError, json.JSONDecodeError) as error:
        print(f'::error::{error}')
        return 2


if __name__ == '__main__':
    sys.exit(main())
