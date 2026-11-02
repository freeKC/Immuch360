#!/usr/bin/env python3
"""The small synthetic set of photos a splat scene is made from in the CI: 24 views of a closed room with three boxes,
whose true poses are known (store/m2/splat-maker-2026-11-01/plan-2026-11-01.md, lots SP0 and SP1; the engineering
design of the same day, section 8.4).

COLMAP has no graphics card to wait for: the job that builds it (lot SP1), and later the end to end job of the engine,
place these views with the real program and compare the poses it finds with poses.json. Nothing heavy is kept in the
repository: the views are drawn again by this script, the same pixels on every machine, and only their sums and poses
are kept, in mobile/test/fixtures/splat/dataset.json.

The room is the box [-2, 2] x [0, 2.4] x [-2, 2] in metres, y up: a floor, a ceiling and four walls, and three boxes on
the floor, each face with a texture of its own made of discs and rectangles of many sizes drawn by a fixed linear
congruential generator (the features of SIFT). 24 pinhole cameras stand on a circle of 1.3 m around the centre at
1.25 m high, 15 degrees apart, each turned towards a point of the far side slightly below the horizon. Two lenses: the
even views have a focal length of 260 pixels, the odd ones 210, in two folders (images/cam0, images/cam1), as the app
groups the photos of one camera. Each view is 320 x 240, drawn by casting one ray per pixel, the nearest texel of the
face hit. Only additions, products, divisions and square roots of IEEE 754 doubles are used (the angles come from the
square roots of 2 and 6), so the pixels do not depend on the mathematical library of the system.

  make_splat_dataset.py --out DIR                 draws the views into DIR/images/cam0 and cam1 (PNG) and writes
                                                  DIR/poses.json
  make_splat_dataset.py --out DIR --noise-view K  the same, view K (1 to 24) replaced by noise: COLMAP must then place
                                                  23 of 24
  make_splat_dataset.py --write                   writes mobile/test/fixtures/splat/dataset.json (sums and poses)
  make_splat_dataset.py --check                   draws the views in memory and exits 1 when their sums or poses differ
                                                  from dataset.json

poses.json and dataset.json hold, for each view, its file, its camera (the folder), its size and its focal length, the
centre of the camera in the world, and its rotation and translation as COLMAP writes them in images.bin: the
quaternion (w, x, y, z) and the translation of the world to the camera, x right, y down, z forward. The sums are those of
the RGB pixels, row after row, not of the PNG files, whose compression may change with zlib.

Python standard library only (zlib for the PNG). Tools only: nothing of it is shipped.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import pathlib
import struct
import sys
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[3]
MANIFEST = ROOT / "mobile/test/fixtures/splat/dataset.json"

WIDTH, HEIGHT = 320, 240
VIEWS = 24
FOCALS = (260.0, 210.0)
RADIUS, CAMERA_HEIGHT = 1.3, 1.25
ROOM_MIN, ROOM_MAX = (-2.0, 0.0, -2.0), (2.0, 2.4, 2.0)
BOXES = (
    ((-0.9, 0.0, -0.5), (-0.3, 0.7, 0.2)),
    ((0.25, 0.0, -0.95), (0.85, 0.45, -0.35)),
    ((-0.15, 0.0, 0.45), (0.35, 1.0, 0.95)),
)
TEXELS = 160
SEED = 20261101


class Random:
    """A linear congruential generator, the same numbers on every machine"""

    def __init__(self, seed: int):
        self.state = seed % (1 << 31)

    def next(self) -> float:
        self.state = (self.state * 1103515245 + 12345) % (1 << 31)
        return self.state / (1 << 31)

    def below(self, n: int) -> int:
        return int(self.next() * n)


def texture(random: Random, base: tuple) -> list:
    """A square texture of TEXELS x TEXELS colours: a base colour, then discs and rectangles of many sizes and colours"""
    pixels = [list(base) * TEXELS for _ in range(TEXELS)]

    def colour():
        return (random.below(256), random.below(256), random.below(256))

    for size, count in ((40, 6), (20, 18), (10, 40), (5, 70)):
        for _ in range(count):
            cx, cy = random.below(TEXELS), random.below(TEXELS)
            r = size // 2 + random.below(size // 2 + 1)
            c = colour()
            disc = random.next() < 0.5
            for y in range(max(0, cy - r), min(TEXELS, cy + r + 1)):
                row = pixels[y]
                for x in range(max(0, cx - r), min(TEXELS, cx + r + 1)):
                    if not disc or (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r:
                        row[3 * x:3 * x + 3] = c
    return pixels


def unit(v: tuple) -> tuple:
    n = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
    return (v[0] / n, v[1] / n, v[2] / n)


def cross(a: tuple, b: tuple) -> tuple:
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def circle() -> list:
    """The 24 directions 15 degrees apart, turned from (1, 0) by the rotation of 15 degrees (cos and sin from the
    square roots of 6 and 2)"""
    c = (math.sqrt(6.0) + math.sqrt(2.0)) / 4.0
    s = (math.sqrt(6.0) - math.sqrt(2.0)) / 4.0
    out, x, z = [], 1.0, 0.0
    for _ in range(VIEWS):
        out.append((x, z))
        x, z = x * c - z * s, x * s + z * c
    return out


def quaternion(r: list) -> tuple:
    """The quaternion (w, x, y, z) of the rotation matrix [r] (rows), its w positive, without trigonometry"""
    trace = r[0][0] + r[1][1] + r[2][2]
    if trace > 0:
        s = math.sqrt(trace + 1.0) * 2.0
        q = (0.25 * s, (r[2][1] - r[1][2]) / s, (r[0][2] - r[2][0]) / s, (r[1][0] - r[0][1]) / s)
    elif r[0][0] > r[1][1] and r[0][0] > r[2][2]:
        s = math.sqrt(1.0 + r[0][0] - r[1][1] - r[2][2]) * 2.0
        q = ((r[2][1] - r[1][2]) / s, 0.25 * s, (r[0][1] + r[1][0]) / s, (r[0][2] + r[2][0]) / s)
    elif r[1][1] > r[2][2]:
        s = math.sqrt(1.0 + r[1][1] - r[0][0] - r[2][2]) * 2.0
        q = ((r[0][2] - r[2][0]) / s, (r[0][1] + r[1][0]) / s, 0.25 * s, (r[1][2] + r[2][1]) / s)
    else:
        s = math.sqrt(1.0 + r[2][2] - r[0][0] - r[1][1]) * 2.0
        q = ((r[1][0] - r[0][1]) / s, (r[0][2] + r[2][0]) / s, (r[1][2] + r[2][1]) / s, 0.25 * s)
    return q if q[0] >= 0 else tuple(-v for v in q)


def cameras() -> list:
    """Each view: its index from 1, its folder, its focal length, its centre and the rows of its rotation (the world to
    the camera: x right, y down, z forward)"""
    out = []
    for k, (cx, cz) in enumerate(circle()):
        centre = (RADIUS * cx, CAMERA_HEIGHT, RADIUS * cz)
        target = (-0.8 * cx, 0.9, -0.8 * cz)
        forward = unit((target[0] - centre[0], target[1] - centre[1], target[2] - centre[2]))
        right = unit(cross(forward, (0.0, 1.0, 0.0)))
        down = cross(forward, right)
        out.append((k + 1, k % 2, FOCALS[k % 2], centre, [right, down, forward]))
    return out


def faces(random: Random) -> list:
    """The faces of the room and of the boxes: (axis, value, the two other axes, their bounds, the side seen, texture)"""
    out = []
    lo, hi = ROOM_MIN, ROOM_MAX
    bases = [(200, 190, 170), (170, 185, 200), (190, 200, 175), (205, 175, 165), (175, 165, 200), (160, 200, 190)]
    for axis in range(3):
        u, v = [a for a in range(3) if a != axis]
        for side, value in ((1, lo[axis]), (-1, hi[axis])):
            out.append((axis, value, u, v, (lo[u], hi[u], lo[v], hi[v]), side, texture(random, bases[len(out)])))
    return out


def box_faces(random: Random) -> list:
    out = []
    for index, (lo, hi) in enumerate(BOXES):
        for axis in range(3):
            u, v = [a for a in range(3) if a != axis]
            for side, value in ((-1, lo[axis]), (1, hi[axis])):
                base = ((90 + 50 * index) % 256, (140 + 30 * axis) % 256, (60 + 70 * index + 20 * side) % 256)
                out.append((axis, value, u, v, (lo[u], hi[u], lo[v], hi[v]), side, texture(random, base)))
    return out


def draw(view: tuple, room: list, boxes: list) -> bytes:
    """The RGB pixels of [view], row after row"""
    _, _, focal, centre, rows = view
    ox, oy, oz = centre
    right, down, forward = rows
    out = bytearray(WIDTH * HEIGHT * 3)
    at = 0
    half_w, half_h = WIDTH / 2.0, HEIGHT / 2.0
    for py in range(HEIGHT):
        b = (py + 0.5 - half_h) / focal
        for px in range(WIDTH):
            a = (px + 0.5 - half_w) / focal
            d = (forward[0] + a * right[0] + b * down[0], forward[1] + a * right[1] + b * down[1],
                 forward[2] + a * right[2] + b * down[2])
            o = (ox, oy, oz)
            best, hit = math.inf, None
            for face in boxes:
                axis, value, u, v, bounds, side, _ = face
                if d[axis] == 0.0 or (d[axis] > 0.0) == (side > 0):
                    continue
                t = (value - o[axis]) / d[axis]
                if t <= 0.0 or t >= best:
                    continue
                pu, pv = o[u] + t * d[u], o[v] + t * d[v]
                if bounds[0] <= pu <= bounds[1] and bounds[2] <= pv <= bounds[3]:
                    best, hit = t, (face, pu, pv)
            if hit is None:
                for face in room:
                    axis, value, u, v, bounds, side, _ = face
                    if d[axis] == 0.0 or (d[axis] > 0.0) == (side > 0):
                        continue
                    t = (value - o[axis]) / d[axis]
                    if t <= 0.0 or t >= best:
                        continue
                    pu, pv = o[u] + t * d[u], o[v] + t * d[v]
                    if bounds[0] <= pu <= bounds[1] and bounds[2] <= pv <= bounds[3]:
                        best, hit = t, (face, pu, pv)
            if hit is not None:
                (_, _, _, _, bounds, _, pixels), pu, pv = hit
                tu = int((pu - bounds[0]) / (bounds[1] - bounds[0]) * TEXELS)
                tv = int((pv - bounds[2]) / (bounds[3] - bounds[2]) * TEXELS)
                tu = TEXELS - 1 if tu >= TEXELS else tu
                tv = TEXELS - 1 if tv >= TEXELS else tv
                row = pixels[tv]
                out[at:at + 3] = bytes(row[3 * tu:3 * tu + 3])
            at += 3
    return bytes(out)


def noise(seed: int) -> bytes:
    random = Random(seed)
    return bytes(random.below(256) for _ in range(WIDTH * HEIGHT * 3))


def png(pixels: bytes) -> bytes:
    """An RGB PNG of WIDTH x HEIGHT, no filter"""
    raw = b"".join(b"\x00" + pixels[y * WIDTH * 3:(y + 1) * WIDTH * 3] for y in range(HEIGHT))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    head = struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", head) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def dataset(noise_view: int | None = None) -> tuple:
    """The views drawn and what dataset.json and poses.json hold"""
    random = Random(SEED)
    room = faces(random)
    boxes = box_faces(random)
    views, images = [], {}
    for view in cameras():
        index, group, focal, centre, rows = view
        name = f"images/cam{group}/{index:04d}.png"
        pixels = noise(index) if index == noise_view else draw(view, room, boxes)
        images[name] = pixels
        translation = tuple(-(rows[k][0] * centre[0] + rows[k][1] * centre[1] + rows[k][2] * centre[2])
                            for k in range(3))
        views.append({
            "file": name,
            "camera": f"cam{group}",
            "width": WIDTH,
            "height": HEIGHT,
            "focal": focal,
            "centre": list(centre),
            "qvec": list(quaternion(rows)),
            "tvec": list(translation),
            "rgbSha256": hashlib.sha256(pixels).hexdigest(),
        })
    about = {
        "about": "The views of make_splat_dataset.py: the world to each camera as COLMAP writes it (x right, y down, "
                 "z forward), the SHA-256 of their RGB pixels; the room [-2, 2] x [0, 2.4] x [-2, 2] m, y up",
        "seed": SEED,
        "views": views,
    }
    return about, images


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=pathlib.Path, help="the folder the views and poses.json are written to")
    parser.add_argument("--noise-view", type=int, help="the view (1 to 24) replaced by noise")
    parser.add_argument("--write", action="store_true", help="write the sums and poses into dataset.json")
    parser.add_argument("--check", action="store_true", help="compare the views drawn with dataset.json")
    args = parser.parse_args()
    if not (args.out or args.write or args.check):
        parser.error("--out DIR, --write or --check")
    if args.noise_view is not None and not 1 <= args.noise_view <= VIEWS:
        parser.error(f"--noise-view is a view from 1 to {VIEWS}")
    if args.noise_view is not None and (args.write or args.check):
        parser.error("--noise-view goes with --out only")
    about, images = dataset(args.noise_view)
    text = json.dumps(about, indent=2) + "\n"
    if args.check:
        current = MANIFEST.read_text(encoding="utf-8") if MANIFEST.is_file() else ""
        if current != text:
            kept = json.loads(current)["views"] if current else []
            made = about["views"]
            for k, view in enumerate(made):
                if k >= len(kept) or kept[k] != view:
                    print(f"differs: {view['file']}")
            print(f"differs: {MANIFEST.relative_to(ROOT)}")
            return 1
        print(f"{len(images)} views, the same as {MANIFEST.relative_to(ROOT)}")
    if args.write:
        MANIFEST.write_text(text, encoding="utf-8")
        print(f"written: {MANIFEST.relative_to(ROOT)}")
    if args.out:
        for name, pixels in images.items():
            path = args.out / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(png(pixels))
        (args.out / "poses.json").write_text(text, encoding="utf-8")
        print(f"{len(images)} views and poses.json in {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
