#!/usr/bin/env python3
"""The Gaussian splat files of lot S5 (splats of other tools in the Meta Quest): the fixtures the Dart and the Kotlin
tests share, and the synthetic files of the owner's kit.

A splat file is read by our own code before the splat module of the Meta Spatial SDK gets it: the probe of the head
of the file (lib/domain/models/splat/splat_header.dart, SplatHeader.kt), the reduction to the strongest gaussians
(SplatReducer.kt) and the placement from the bounds of the positions (SplatPlacement.kt). Every file here is written
by this script from the public descriptions of the formats, never by the code under test:

* SPZ, Niantic Labs, MIT, https://github.com/nianticlabs/spz (README of the repository, read on 30 October 2026):
  versions 1 to 3 are one gzip stream of a 16 byte header (magic 0x5053474e "NGSP", version, number of points,
  degree of the spherical harmonics, fractional bits, flags, a reserved byte at 0) followed by the attributes one
  after the other for all points: positions (float16 in version 1, 24 bit fixed point after), alphas (1 byte),
  colours (3 bytes), scales (3 bytes, log encoded), rotations (3 bytes in versions 1 and 2, 4 bytes "smallest three"
  from version 3) and the spherical harmonics (3 bytes for each coefficient past the first). Version 4 has a 32 byte
  clear header, a table of contents (the compressed and the decompressed size of each stream, 8 bytes each) and one
  ZSTD stream per attribute that is not empty, in the same order (README and src/cc/load-spz.cc of the repository at
  affd0ec, read again on 1 November 2026: saveSpz writes no stream for an empty array, so degree 0 has 5 streams),
  holding the arrays of version 3; its degree of the harmonics goes up to 4 (24 coefficients, 72 bytes a point).
* PLY of 3D Gaussian Splatting (Kerbl et al. 2023): binary little endian, one element vertex with x y z, f_dc_0 to 2,
  f_rest_* for the higher degrees, opacity (a logit), scale_0 to 2 (natural logarithms) and rot_0 to 3 (w first).

  make_splat_fixtures.py               writes mobile/test/fixtures/splat/ and its expected.json
  make_splat_fixtures.py --check       exit 1 when a fixture differs from what this script writes (for the ZSTD
                                       files, their header and their decompressed streams: the compressed bytes depend
                                       on the version of the zstandard module)
  make_splat_fixtures.py --kit DIR     also writes the synthetic files of the owner's kit into DIR (larger: a room of
                                       60 000 gaussians in SPZ, one of 200 000 in PLY, the axes, the refusals)

The fixtures:

  axes_v1.spz, axes_v2.spz, axes_v3.spz, axes_v4.spz, axes.ply   the same axes in each format: from the origin, +X
      red over 1 m, +Y green over 1.5 m, +Z blue over 2 m (three lengths, so that a mirror or a swap shows), a white
      cube at the origin and a white letter F in the plane z = 0 (readable from +z, so that a mirror shows)
  sh3.ply                    eight gaussians with the 45 f_rest coefficients of degree 3 and normals
  ranked_v3.spz, ranked.ply  24 gaussians whose scores (opacity times volume) are set apart, with a tie of three at
                             the tenth place, for the reduction to the 10 strongest
  mesh_cube.ply              a cube of 8 vertices and 12 triangles (element face): no splat
  point_cloud.ply            x y z red green blue: no splat (no opacity)
  compressed.ply             the head of a compressed PLY (element chunk, packed_position): refused
  ascii.ply, big_endian.ply  a splat written in ASCII, and in big endian: refused
  long_header.ply            a splat whose header ends past 64 KiB: refused
  negative_count.ply         a splat whose header says element vertex -5: damaged, never a count
  bad_magic.spz, reserved.spz, newer.spz, truncated.spz   SPZ heads that are refused
  axes_v4_niantic.spz        the axes in version 4 as Niantic's writer gives them: 5 streams, none for the empty
                             harmonics (axes_v4.spz, the file of the owner's kit of 31 October, has an empty sixth)
  turns_v4.spz               turns_v3.spz in version 4, its 6 streams (degree 1)
  sh4_v4.spz, sh4_v2.spz     eight gaussians of degree 4 in version 4, and the same rewritten as version 2 by
                             [as_v2]: degree 3, the first 15 coefficients of each point kept (the coefficient is the
                             slow axis, the colour the fast one)
  turns_v3.spz, turns_v2.spz, axes_v1_v2.spz   the SPZ the splat module of the headset reads is version 2 only
      (measured on a Quest 3 on 31 October 2026: version 3 and 4 abort the process, version 1 loads but its points
      are not where they should be). turns_v3.spz holds 40 gaussians of degree 1 with rotations of every kind
      (each component the largest, a negative w, ties), turns_v2.spz is the same file rewritten as version 2 by
      [as_v2] below (rotations decoded from their smallest three, normalised, w made positive and stored as
      floor(q * 127.5 + 128)), axes_v1_v2.spz is axes_v1.spz rewritten as version 2 (its float16 positions as 24 bit
      fixed point with the fractional bits of its header, floor(v * 2^bits + 0.5)); every other array is copied
  cash_register_head.spz, measuring_tape_head.ply   the first 65 536 bytes of two CC0 files of InnerScene
      (https://www.innerscene.com/tools/gaussian-splat-viewer, "public domain (CC0)"): heads of files of another
      writer, read with the length of the whole file; --kit downloads the whole files

expected.json holds what the tests compare with: the header of each file, the kept indices of the reduction, and the
percentiles 5 and 95 of the positions of the axes (the value of rank max(1, (P * N + 99) // 100) of the N sorted
values, as relief-v1 takes its percentiles).

numpy is not needed; zstandard (BSD) writes the version 4 file. Tools only: nothing of them is shipped.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import math
import pathlib
import struct
import sys
import urllib.request

import zstandard

ROOT = pathlib.Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "mobile/test/fixtures/splat"

SPZ_MAGIC = 0x5053474E
SH_C0 = 0.28209479177387814
# SPZ: colours are the DC coefficient scaled by 0.15 around the middle of the byte (load-spz.cc of Niantic)
SPZ_COLOR_SCALE = 0.15
FRACTIONAL_BITS = 12
HEAD_BYTES = 65536

INNERSCENE = {
    "cash_register_head.spz": ("gsplat-cash-register.spz", 686150,
                               "9f01f4455453aba7e4db04ef60483b3ee53d5cd687b4548770f4e793f7cd9dd8"),
    "measuring_tape_head.ply": ("gsplat-measuring-tape.ply", 1324307,
                                "1f6323c7ac68c8a4076789fdf0d67d6a7459412de4971c2f1e6a4b7470feff10"),
}
INNERSCENE_URL = "https://www.innerscene.com/samples/"
INNERSCENE_CACTUS = ("gsplat-cactus.spz", 6824362, "ddf7b1f8a2e9b9f2edf5fdafc8d9fc77ddd96fde87cf5695f490076039e3d974")


class Gaussian:
    """One gaussian: position in metres, colour 0 to 1, opacity 0 to 1, scale in metres on each axis"""

    def __init__(self, x, y, z, r, g, b, alpha, sx, sy=None, sz=None):
        self.position = (x, y, z)
        self.color = (r, g, b)
        self.alpha = alpha
        self.scale = (sx, sx if sy is None else sy, sx if sz is None else sz)


def axes() -> list:
    """The axes, the cube at the origin and the letter F (see the top of this file)"""
    out = []
    step = 0.01
    for axis, length, color in ((0, 1.0, (1, 0.1, 0.1)), (1, 1.5, (0.1, 1, 0.1)), (2, 2.0, (0.2, 0.3, 1))):
        for k in range(1, int(round(length / step)) + 1):
            p = [0.0, 0.0, 0.0]
            p[axis] = k * step
            out.append(Gaussian(*p, *color, 0.95, 0.006))
    for i in range(-2, 3):
        for j in range(-2, 3):
            for k in range(-2, 3):
                out.append(Gaussian(i * 0.01, j * 0.01, k * 0.01, 1, 1, 1, 0.95, 0.006))
    # The letter F, 0.6 m high, in the plane z = 0 between x = 0.3 and 0.6
    for k in range(61):
        out.append(Gaussian(0.3, 0.3 + k * step, 0.0, 1, 1, 1, 0.95, 0.006))
    for k in range(1, 31):
        out.append(Gaussian(0.3 + k * step, 0.9, 0.0, 1, 1, 1, 0.95, 0.006))
    for k in range(1, 21):
        out.append(Gaussian(0.3 + k * step, 0.6, 0.0, 1, 1, 1, 0.95, 0.006))
    return out


def ranked() -> list:
    """24 gaussians, scores apart by design, three tied at the tenth place: their bytes are equal in every format"""
    out = []
    # (alpha, scale) of each, in an order that is not the order of the scores
    plan = [
        (0.9, 0.050), (0.2, 0.010), (0.8, 0.080), (0.5, 0.0565), (0.7, 0.040), (0.6, 0.020),
        (0.4, 0.060), (0.9, 0.012), (0.5, 0.0565), (0.3, 0.090), (0.95, 0.070), (0.1, 0.050),
        (0.5, 0.0565), (0.6, 0.100), (0.25, 0.015), (0.85, 0.025), (0.45, 0.045), (0.75, 0.065),
        (0.35, 0.008), (0.65, 0.035), (0.15, 0.120), (0.55, 0.055), (0.05, 0.200), (0.99, 0.004),
    ]
    for i, (alpha, scale) in enumerate(plan):
        out.append(Gaussian(i * 0.1 - 1.2, (i % 5) * 0.2, (i % 3) * 0.3, (i % 7) / 6, (i % 4) / 3, (i % 5) / 4,
                            alpha, scale, scale * 1.5, scale * 0.5))
    return out


def room(count: int, seed: int = 7) -> list:
    """A room of [count] gaussians: a 4 x 4 m checkered floor at y = 0, walls of 2.4 m on three sides, three boxes"""
    out = []
    # A linear congruential generator, so that the room is the same on every machine
    state = seed

    def rnd():
        nonlocal state
        state = (state * 1103515245 + 12345) % (1 << 31)
        return state / (1 << 31)

    floor = int(count * 0.5)
    walls = int(count * 0.4)
    boxes = count - floor - walls
    for _ in range(floor):
        x, z = rnd() * 4 - 2, rnd() * 4 - 2
        dark = (int((x + 2) * 2) + int((z + 2) * 2)) % 2 == 0
        c = 0.25 if dark else 0.85
        out.append(Gaussian(x, 0.0, z, c, c, c * 0.95, 0.9, 0.02, 0.004, 0.02))
    for k in range(walls):
        side = k % 3
        u, v = rnd() * 4 - 2, rnd() * 2.4
        if side == 0:
            out.append(Gaussian(u, v, -2.0, 0.8, 0.55, 0.4, 0.9, 0.02, 0.02, 0.004))
        elif side == 1:
            out.append(Gaussian(-2.0, v, u, 0.4, 0.6, 0.8, 0.9, 0.004, 0.02, 0.02))
        else:
            out.append(Gaussian(2.0, v, u, 0.5, 0.75, 0.45, 0.9, 0.004, 0.02, 0.02))
    centres = ((-1.0, -1.0, (0.9, 0.2, 0.2)), (0.5, -1.2, (0.2, 0.8, 0.3)), (1.0, 0.8, (0.95, 0.85, 0.2)))
    for k in range(boxes):
        cx, cz, color = centres[k % 3]
        out.append(Gaussian(cx + rnd() * 0.5 - 0.25, rnd() * 0.5, cz + rnd() * 0.5 - 0.25, *color, 0.95, 0.015))
    return out


# ---------------------------------------------------------------------------------------------------------------------
# PLY


def ply_header(count: int, sh_degree: int = 0, normals: bool = False, comments=(), fmt="binary_little_endian") -> str:
    lines = ["ply", f"format {fmt} 1.0"]
    lines += [f"comment {c}" for c in comments]
    lines.append(f"element vertex {count}")
    lines += [f"property float {n}" for n in ("x", "y", "z")]
    if normals:
        lines += [f"property float {n}" for n in ("nx", "ny", "nz")]
    lines += [f"property float f_dc_{k}" for k in range(3)]
    lines += [f"property float f_rest_{k}" for k in range(sh_rest(sh_degree))]
    lines.append("property float opacity")
    lines += [f"property float scale_{k}" for k in range(3)]
    lines += [f"property float rot_{k}" for k in range(4)]
    lines.append("end_header")
    return "\n".join(lines) + "\n"


def sh_rest(degree: int) -> int:
    """The f_rest coefficients of a degree: 3 colours for each coefficient past the first"""
    return 3 * ((degree + 1) ** 2 - 1)


def logit(p: float) -> float:
    p = min(max(p, 1e-6), 1 - 1e-6)
    return math.log(p / (1 - p))


def ply_row(g: Gaussian, sh_degree: int = 0, normals: bool = False, sh_seed: int = 0) -> list:
    row = list(g.position)
    if normals:
        row += [0.0, 0.0, 0.0]
    row += [(c - 0.5) / SH_C0 for c in g.color]
    row += [((sh_seed * 31 + k * 7) % 17 - 8) / 40 for k in range(sh_rest(sh_degree))]
    row.append(logit(g.alpha))
    row += [math.log(s) for s in g.scale]
    row += [1.0, 0.0, 0.0, 0.0]
    return row


def write_ply(gaussians, sh_degree=0, normals=False, comments=(), big_endian=False) -> bytes:
    fmt = "binary_big_endian" if big_endian else "binary_little_endian"
    out = bytearray(ply_header(len(gaussians), sh_degree, normals, comments, fmt).encode("ascii"))
    order = ">" if big_endian else "<"
    for i, g in enumerate(gaussians):
        row = ply_row(g, sh_degree, normals, i)
        out += struct.pack(f"{order}{len(row)}f", *row)
    return bytes(out)


def write_ply_ascii(gaussians) -> bytes:
    out = ply_header(len(gaussians), fmt="ascii")
    for g in gaussians:
        out += " ".join(f"{v:.6f}" for v in ply_row(g)) + "\n"
    return out.encode("ascii")


def mesh_cube() -> bytes:
    corners = [(x, y, z) for x in (-0.5, 0.5) for y in (-0.5, 0.5) for z in (-0.5, 0.5)]
    faces = [(0, 1, 3), (0, 3, 2), (4, 6, 7), (4, 7, 5), (0, 4, 5), (0, 5, 1), (2, 3, 7), (2, 7, 6), (0, 2, 6),
             (0, 6, 4), (1, 5, 7), (1, 7, 3)]
    head = ("ply\nformat binary_little_endian 1.0\ncomment a cube, no splat\nelement vertex 8\nproperty float x\n"
            "property float y\nproperty float z\nelement face 12\nproperty list uchar int vertex_indices\nend_header\n")
    out = bytearray(head.encode("ascii"))
    for c in corners:
        out += struct.pack("<3f", *c)
    for f in faces:
        out += struct.pack("<B3i", 3, *f)
    return bytes(out)


def point_cloud() -> bytes:
    head = ("ply\nformat binary_little_endian 1.0\nelement vertex 4\nproperty float x\nproperty float y\n"
            "property float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n")
    out = bytearray(head.encode("ascii"))
    for k in range(4):
        out += struct.pack("<3f3B", k * 0.1, 0.0, 0.0, 200, 100, 50)
    return bytes(out)


def negative_count_ply() -> bytes:
    """Four gaussians of the axes under a header that says -5 of them: no count, a damaged file"""
    data = write_ply(axes()[:4])
    assert data.count(b"element vertex 4\n") == 1
    return data.replace(b"element vertex 4\n", b"element vertex -5\n")


def compressed_ply() -> bytes:
    """The layout of the compressed PLY of SuperSplat and PlayCanvas: a chunk of bounds, then packed vertices"""
    chunk_props = ["min_x", "min_y", "min_z", "max_x", "max_y", "max_z", "min_scale_x", "min_scale_y", "min_scale_z",
                   "max_scale_x", "max_scale_y", "max_scale_z"]
    head = ["ply", "format binary_little_endian 1.0", "element chunk 1"]
    head += [f"property float {p}" for p in chunk_props]
    head += ["element vertex 4", "property uint packed_position", "property uint packed_rotation",
             "property uint packed_scale", "property uint packed_color", "end_header"]
    out = bytearray(("\n".join(head) + "\n").encode("ascii"))
    out += struct.pack("<12f", -1, -1, -1, 1, 1, 1, -5, -5, -5, -2, -2, -2)
    for k in range(4):
        out += struct.pack("<4I", 0x80080080 + k, 0xC0000000, 0x80808080, 0xFF808080)
    return bytes(out)


# ---------------------------------------------------------------------------------------------------------------------
# SPZ


def to_byte(value: float) -> int:
    return int(min(max(round(value), 0), 255))


def spz_header(version: int, count: int, sh_degree: int, fractional_bits: int = FRACTIONAL_BITS, flags: int = 0,
               reserved: int = 0, magic: int = SPZ_MAGIC) -> bytes:
    return struct.pack("<IIIBBBB", magic, version, count, sh_degree, fractional_bits, flags, reserved)


def spz_rotation(version: int) -> bytes:
    """The identity rotation (x, y, z, w) = (0, 0, 0, 1): w is the largest, stored in the 2 bits of its index from
    version 3 on (the three others at 0, positive), else x, y, z as bytes around 127.5"""
    if version >= 3:
        return struct.pack("<I", 3 << 30)
    return bytes([to_byte(127.5)] * 3)


def spz_arrays(gaussians, version: int, sh_degree: int = 0) -> list:
    """The six attribute arrays of an SPZ, in the order of the file"""
    positions = bytearray()
    for g in gaussians:
        for v in g.position:
            if version == 1:
                positions += struct.pack("<e", v)
            else:
                fixed = int(round(v * (1 << FRACTIONAL_BITS)))
                positions += struct.pack("<i", fixed)[:3]
    alphas = bytes(to_byte(g.alpha * 255) for g in gaussians)
    colors = bytes(to_byte((c - 0.5) / SH_C0 * SPZ_COLOR_SCALE * 255 + 127.5) for g in gaussians for c in g.color)
    scales = bytes(to_byte((math.log(s) + 10) * 16) for g in gaussians for s in g.scale)
    rotations = b"".join(spz_rotation(version) for _ in gaussians)
    sh = bytes([128] * (len(gaussians) * sh_rest(sh_degree)))
    return [bytes(positions), alphas, colors, scales, rotations, sh]


def write_spz(gaussians, version: int, sh_degree: int = 0) -> bytes:
    payload = spz_header(version, len(gaussians), sh_degree) + b"".join(spz_arrays(gaussians, version, sh_degree))
    return gzip.compress(payload, compresslevel=9, mtime=0)


def write_spz_v4_arrays(arrays, count: int, sh_degree: int, keep_empty: bool = False) -> bytes:
    """A version 4 file of the six [arrays] of version 3: one ZSTD stream for each, an empty one left out as Niantic's
    saveSpz leaves it out, unless [keep_empty] (the file of the owner's kit of 31 October 2026 has one)"""
    streams = [a for a in arrays if keep_empty or len(a) > 0]
    compressor = zstandard.ZstdCompressor(level=3, write_checksum=False, write_content_size=True)
    packed = [compressor.compress(s) for s in streams]
    header = struct.pack("<IIIBBBBI", SPZ_MAGIC, 4, count, sh_degree, FRACTIONAL_BITS, 0, len(streams), 32)
    header += bytes(12)
    toc = b"".join(struct.pack("<QQ", len(p), len(s)) for p, s in zip(packed, streams))
    return header + toc + b"".join(packed)


def write_spz_v4(gaussians, sh_degree: int = 0, keep_empty: bool = False) -> bytes:
    return write_spz_v4_arrays(spz_arrays(gaussians, 4, sh_degree), len(gaussians), sh_degree, keep_empty)


def arrays_of(raw: bytes) -> tuple:
    """The header fields and the six arrays of the data of an SPZ of version 1 to 3 (its gzip stream inflated)"""
    magic, version, count, sh_degree, fractional, flags, reserved = struct.unpack_from("<IIIBBBB", raw, 0)
    assert magic == SPZ_MAGIC and version in (1, 2, 3) and reserved == 0
    sizes = [count * (6 if version == 1 else 9), count, 3 * count, 3 * count, count * (4 if version >= 3 else 3),
             count * sh_rest(sh_degree)]
    parts = []
    at = 16
    for size in sizes:
        parts.append(raw[at:at + size])
        at += size
    return (version, count, sh_degree, fractional, flags), parts


def v4_from_v3(data: bytes) -> bytes:
    """An SPZ of version 3 written as version 4, as Niantic's writer would: its arrays, one ZSTD stream each"""
    (version, count, sh_degree, _, _), parts = arrays_of(gzip.decompress(data))
    assert version == 3
    return write_spz_v4_arrays(parts, count, sh_degree)


def v4_payload(data: bytes) -> bytes:
    """The data of a version 4 file as versions 1 to 3 hold it: a 16 byte header (version 4), then its arrays"""
    magic, version, count, sh_degree, fractional, flags, streams, toc_at = struct.unpack_from("<IIIBBBBI", data, 0)
    assert magic == SPZ_MAGIC and version == 4
    sizes = [struct.unpack_from("<QQ", data, toc_at + 16 * k) for k in range(streams)]
    at = toc_at + 16 * streams
    decompressor = zstandard.ZstdDecompressor()
    body = bytearray()
    for packed, plain in sizes:
        body += decompressor.decompress(data[at:at + packed], max_output_size=plain) if plain else b""
        at += packed
    assert at == len(data)
    return spz_header(4, count, sh_degree, fractional, flags) + bytes(body)


def sh4_v4(count: int = 8) -> bytes:
    """Eight gaussians of degree 4 in version 4: 24 coefficients a point, each byte its own"""
    gaussians = [Gaussian(k * 0.1, 0.05 * (k % 3), -0.02 * k, 0.5, 0.4, 0.3, 0.8, 0.01 + 0.002 * k) for k in range(count)]
    arrays = spz_arrays(gaussians, 4, 0)
    rest = sh_rest(4)
    arrays[5] = bytes((i * rest + k) * 13 % 256 for i in range(count) for k in range(rest))
    return write_spz_v4_arrays(arrays, count, 4)


# The files written with ZSTD, whose compressed bytes depend on the version of the zstandard module
V4_FILES = ("axes_v4.spz", "axes_v4_niantic.spz", "turns_v4.spz", "sh4_v4.spz")


def v4_content(data: bytes) -> bytes:
    """The header, the table of contents and the decompressed streams of a version 4 file, for --check"""
    count = data[15]
    toc_at = struct.unpack_from("<I", data, 16)[0]
    sizes = [struct.unpack_from("<QQ", data, toc_at + 16 * k) for k in range(count)]
    out = bytearray(data[:toc_at])
    at = toc_at + 16 * count
    decompressor = zstandard.ZstdDecompressor()
    for packed, plain in sizes:
        out += struct.pack("<Q", plain) + decompressor.decompress(data[at:at + packed], max_output_size=plain)
        at += packed
    return bytes(out)


def pack_smallest_three(q) -> bytes:
    """A unit quaternion (x, y, z, w) as version 3 stores it: the index of its largest component in the top 2 bits,
    then the three others (in the order x, y, z, w, the last in the low bits), each a sign bit and 9 bits of its
    magnitude over 1/sqrt(2), of the quaternion made positive on its largest component"""
    largest = max(range(4), key=lambda i: abs(q[i]))
    negate = q[largest] < 0
    comp = largest
    for i in range(4):
        if i != largest:
            negbit = (q[i] < 0) != negate
            mag = int(math.floor(511 * (abs(q[i]) / math.sqrt(0.5)) + 0.5))
            comp = (comp << 10) | (int(negbit) << 9) | min(mag, 511)
    return struct.pack("<I", comp)


def unpack_smallest_three(data: bytes) -> list:
    """The quaternion (x, y, z, w) of 4 bytes of version 3, read as load-spz.cc of Niantic reads it"""
    comp = struct.unpack("<I", data)[0]
    largest = comp >> 30
    q = [0.0] * 4
    squares = 0.0
    for i in (3, 2, 1, 0):
        if i != largest:
            mag = comp & 511
            negative = (comp >> 9) & 1
            comp >>= 10
            q[i] = math.sqrt(0.5) * mag / 511
            if negative:
                q[i] = -q[i]
            squares += q[i] * q[i]
    q[largest] = math.sqrt(max(0.0, 1.0 - squares))
    return q


def pack_first_three(q) -> bytes:
    """A quaternion (x, y, z, w) as versions 1 and 2 store it: normalised, w made positive, x, y, z as bytes"""
    norm = math.sqrt(sum(c * c for c in q))
    q = [c / norm for c in q]
    if q[3] < 0:
        q = [-c for c in q]
    return bytes(int(min(max(math.floor(c * 127.5 + 127.5 + 0.5), 0), 255)) for c in q[:3])


def turn_quaternions(count: int) -> list:
    """Rotations of every kind: the identity, each component the largest with either sign, ties, then a fixed
    pseudo random set"""
    h = math.sqrt(0.5)
    fixed = [(0, 0, 0, 1), (1, 0, 0, 0), (0, -1, 0, 0), (0, 0, 1, 0), (0, 0, 0, -1), (0.5, 0.5, 0.5, -0.5),
             (h, 0, 0, -h), (-0.1, 0.2, -0.9, 0.3), (0.6, -0.6, 0.3, 0.2), (0.01, 0.02, 0.03, -0.99)]
    out = []
    state = 3

    def rnd():
        nonlocal state
        state = (state * 1103515245 + 12345) % (1 << 31)
        return state / (1 << 31)

    while len(out) < count:
        q = fixed[len(out)] if len(out) < len(fixed) else (rnd() - 0.5, rnd() - 0.5, rnd() - 0.5, rnd() - 0.5)
        norm = math.sqrt(sum(c * c for c in q))
        out.append([c / norm for c in q])
    return out


def turns_v3(count: int = 40, sh_degree: int = 1) -> bytes:
    """40 gaussians of degree 1, version 3: rotations of every kind, positions on both sides of each axis, the
    other arrays bytes that differ from one gaussian to the next (so that a mix-up shows)"""
    positions = bytearray()
    for i in range(count):
        for v in ((i - 20) * 0.037, ((i * 7) % 11 - 5) * 0.051, ((i * 3) % 13 - 6) * -0.043):
            positions += struct.pack("<i", int(round(v * (1 << FRACTIONAL_BITS))))[:3]
    alphas = bytes((i * 37 + 11) % 256 for i in range(count))
    colors = bytes((i * 3 + k) * 29 % 256 for i in range(count) for k in range(3))
    scales = bytes((i * 13 + k * 5 + 60) % 256 for i in range(count) for k in range(3))
    rotations = b"".join(pack_smallest_three(q) for q in turn_quaternions(count))
    rest = sh_rest(sh_degree)
    sh = bytes((i * rest + k) * 11 % 256 for i in range(count) for k in range(rest))
    payload = spz_header(3, count, sh_degree) + bytes(positions) + alphas + colors + scales + rotations + sh
    return gzip.compress(payload, compresslevel=9, mtime=0)


def as_v2(data: bytes) -> bytes:
    """An SPZ of version 1, 3 or 4 rewritten as version 2, the one the splat module of the headset reads, from the
    public description of the format: the header with version 2 and the flag of extensions cleared, the positions of
    version 1 as 24 bit fixed point, the rotations of versions 3 and 4 as three bytes, the harmonics of degree 4 cut to
    degree 3 (the first 15 coefficients of each point), everything else copied"""
    if struct.unpack_from("<I", data, 0)[0] == SPZ_MAGIC:
        raw = v4_payload(data)
        _, _, count, sh_degree, fractional, flags = struct.unpack_from("<IIIBBB", raw, 0)
        sizes = [9 * count, count, 3 * count, 3 * count, 4 * count, count * sh_rest(sh_degree)]
        parts = []
        at = 16
        for size in sizes:
            parts.append(raw[at:at + size])
            at += size
        version = 4
    else:
        (version, count, sh_degree, fractional, flags), parts = arrays_of(gzip.decompress(data))
    positions, alphas, colors, scales, rotations, sh = parts
    if sh_degree == 4:
        rest3, rest4 = sh_rest(3), sh_rest(4)
        sh = b"".join(sh[k * rest4:k * rest4 + rest3] for k in range(count))
        sh_degree = 3
    if version == 1:
        fixed = bytearray()
        for k in range(3 * count):
            value = struct.unpack_from("<e", positions, 2 * k)[0]
            n = int(math.floor(value * (1 << fractional) + 0.5))
            n = min(max(n, -(1 << 23)), (1 << 23) - 1)
            fixed += struct.pack("<i", n)[:3]
        positions = bytes(fixed)
    if version >= 3:
        rotations = b"".join(pack_first_three(unpack_smallest_three(rotations[4 * k:4 * k + 4])) for k in range(count))
    header = spz_header(2, count, sh_degree, fractional, flags & ~0x2)
    return gzip.compress(header + positions + alphas + colors + scales + rotations + sh, compresslevel=9, mtime=0)


# ---------------------------------------------------------------------------------------------------------------------
# What the tests compare with


def quantized_positions(gaussians, version: int) -> list:
    """The positions as an SPZ of [version] gives them back"""
    out = []
    for g in gaussians:
        if version == 1:
            out.append(tuple(struct.unpack("<e", struct.pack("<e", v))[0] for v in g.position))
        else:
            out.append(tuple(round(v * (1 << FRACTIONAL_BITS)) / (1 << FRACTIONAL_BITS) for v in g.position))
    return out


def percentile(values, p: int) -> float:
    ordered = sorted(values)
    rank = max(1, (p * len(ordered) + 99) // 100)
    return ordered[rank - 1]


def spz_score(alpha_byte: int, scale_bytes) -> float:
    """ln(opacity) + the three log scales, the score SplatReducer ranks by (an opacity of 0 counts as 1e-6)"""
    alpha = alpha_byte / 255
    return math.log(max(alpha, 1e-6)) + sum(b / 16 - 10 for b in scale_bytes)


def ply_score(row) -> float:
    opacity = row[-8]
    scales = row[-7:-4]
    f32 = [struct.unpack("<f", struct.pack("<f", v))[0] for v in [opacity, *scales]]
    # ln(sigmoid(o)) = -ln(1 + e^-o)
    log_alpha = -math.log1p(math.exp(-f32[0])) if f32[0] > -30 else f32[0]
    return max(log_alpha, math.log(1e-6)) + sum(f32[1:])


def top(scores, keep: int) -> list:
    """The indices kept: the [keep] largest scores, a tie going to the lower index"""
    order = sorted(range(len(scores)), key=lambda i: (-scores[i], i))
    return sorted(order[:keep])


def expected(files: dict) -> dict:
    gaussians = axes()
    out = {"about": "What the splat tests compare with, written by .github/desktop/ai/make_splat_fixtures.py",
           "headers": {}, "reduction": {}, "percentiles": {}}
    for name, data in sorted(files.items()):
        out["headers"][name] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    out["headers"]["axes_v3.spz"].update(format="spz", version=3, gaussians=len(gaussians), shDegree=0)
    out["headers"]["axes_v2.spz"].update(format="spz", version=2, gaussians=len(gaussians), shDegree=0)
    out["headers"]["axes_v1.spz"].update(format="spz", version=1, gaussians=len(gaussians), shDegree=0)
    out["headers"]["axes_v4.spz"].update(format="spz", version=4, gaussians=len(gaussians), shDegree=0, streams=6)
    out["headers"]["axes_v4_niantic.spz"].update(format="spz", version=4, gaussians=len(gaussians), shDegree=0,
                                                 streams=5)
    out["headers"]["turns_v4.spz"].update(format="spz", version=4, gaussians=40, shDegree=1, streams=6)
    out["headers"]["sh4_v4.spz"].update(format="spz", version=4, gaussians=8, shDegree=4, streams=6)
    out["headers"]["sh4_v2.spz"].update(format="spz", version=2, gaussians=8, shDegree=3)
    out["headers"]["turns_v3.spz"].update(format="spz", version=3, gaussians=40, shDegree=1)
    out["headers"]["turns_v2.spz"].update(format="spz", version=2, gaussians=40, shDegree=1)
    out["headers"]["axes_v1_v2.spz"].update(format="spz", version=2, gaussians=len(gaussians), shDegree=0)
    out["headers"]["axes.ply"].update(format="ply", gaussians=len(gaussians), shDegree=0,
                                      tool="make_splat_fixtures.py", rowBytes=14 * 4)
    out["headers"]["sh3.ply"].update(format="ply", gaussians=8, shDegree=3, tool=None, rowBytes=(17 + 45) * 4)
    for name, (source, length, sha) in INNERSCENE.items():
        out["headers"][name].update(source=INNERSCENE_URL + source, fileBytes=length, fileSha256=sha)
    out["headers"]["cash_register_head.spz"].update(format="spz", version=3, gaussians=47819, shDegree=0)
    out["headers"]["measuring_tape_head.ply"].update(format="ply", gaussians=19469, shDegree=0, tool=None,
                                                     rowBytes=17 * 4)
    plan = ranked()
    spz_arr = spz_arrays(plan, 3)
    spz_scores = [spz_score(spz_arr[1][i], spz_arr[3][3 * i:3 * i + 3]) for i in range(len(plan))]
    ply_scores = [ply_score(ply_row(g)) for g in plan]
    out["reduction"] = {
        "keep": 10,
        "ranked_v3.spz": {"scores": spz_scores, "kept": top(spz_scores, 10)},
        "ranked.ply": {"scores": ply_scores, "kept": top(ply_scores, 10)},
    }
    # The rewrite as version 2: each rotation of turns_v3.spz and what it became, as 1 - |q3 . q2| (0 the same)
    v3 = gzip.decompress(files["turns_v3.spz"])
    v2 = gzip.decompress(files["turns_v2.spz"])
    rot3 = 16 + 40 * (9 + 1 + 3 + 3)
    worst = 0.0
    for k in range(40):
        a = unpack_smallest_three(v3[rot3 + 4 * k:rot3 + 4 * k + 4])
        xyz = [b / 127.5 - 1.0 for b in v2[rot3 + 3 * k:rot3 + 3 * k + 3]]
        b = xyz + [math.sqrt(max(0.0, 1.0 - sum(c * c for c in xyz)))]
        worst = max(worst, 1 - min(1.0, abs(sum(x * y for x, y in zip(a, b)))))
    out["moduleSpz"] = {"version": 2, "rewrites": {"turns_v3.spz": "turns_v2.spz", "axes_v1.spz": "axes_v1_v2.spz",
                                                   "axes_v4.spz": "axes_v2.spz", "axes_v4_niantic.spz": "axes_v2.spz",
                                                   "turns_v4.spz": "turns_v2.spz", "sh4_v4.spz": "sh4_v2.spz"},
                        "worstRotation": round(worst, 6)}
    for version in (3, 1):
        positions = quantized_positions(gaussians, version)
        out["percentiles"][f"axes_v{version}.spz"] = {
            axis: [percentile([p[k] for p in positions], 5), percentile([p[k] for p in positions], 95)]
            for k, axis in enumerate("xyz")
        }
    return out


def innerscene_head(name: str, cache: pathlib.Path) -> bytes:
    source, length, sha = INNERSCENE[name]
    data = download(source, length, sha, cache)
    return data[:HEAD_BYTES]


def download(source: str, length: int, sha: str, cache: pathlib.Path) -> bytes:
    path = cache / source
    if not path.is_file():
        cache.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(INNERSCENE_URL + source, timeout=60) as response:
            path.write_bytes(response.read())
    data = path.read_bytes()
    if len(data) != length or hashlib.sha256(data).hexdigest() != sha:
        raise SystemExit(f"{source}: not the file of 30 October 2026 ({len(data)} bytes)")
    return data


def fixtures(cache: pathlib.Path) -> dict:
    gaussians = axes()
    sh3 = [Gaussian(k * 0.1, 0.0, 0.0, 0.5, 0.5, 0.5, 0.8, 0.01) for k in range(8)]
    long_comments = [f"padding line {k:05d} " + "x" * 60 for k in range(1000)]
    valid = write_spz(gaussians[:20], 3)
    files = {
        "axes_v1.spz": write_spz(gaussians, 1),
        "axes_v2.spz": write_spz(gaussians, 2),
        "axes_v3.spz": write_spz(gaussians, 3),
        "axes_v4.spz": write_spz_v4(gaussians, keep_empty=True),
        "axes_v4_niantic.spz": write_spz_v4(gaussians),
        "axes.ply": write_ply(gaussians, comments=["Generated by make_splat_fixtures.py"]),
        "sh3.ply": write_ply(sh3, sh_degree=3, normals=True),
        "sh4_v4.spz": sh4_v4(),
        "ranked_v3.spz": write_spz(ranked(), 3),
        "ranked.ply": write_ply(ranked()),
        "mesh_cube.ply": mesh_cube(),
        "point_cloud.ply": point_cloud(),
        "compressed.ply": compressed_ply(),
        "ascii.ply": write_ply_ascii(gaussians[:4]),
        "big_endian.ply": write_ply(gaussians[:4], big_endian=True),
        "long_header.ply": write_ply(gaussians[:4], comments=long_comments),
        "negative_count.ply": negative_count_ply(),
        "bad_magic.spz": gzip.compress(spz_header(3, 1, 0, magic=0x12345678) + bytes(20), mtime=0),
        "reserved.spz": gzip.compress(spz_header(3, 1, 0, reserved=1) + bytes(20), mtime=0),
        "newer.spz": gzip.compress(spz_header(5, 1, 0) + bytes(20), mtime=0),
        "truncated.spz": valid[:12],
    }
    files["turns_v3.spz"] = turns_v3()
    files["turns_v2.spz"] = as_v2(files["turns_v3.spz"])
    files["turns_v4.spz"] = v4_from_v3(files["turns_v3.spz"])
    files["sh4_v2.spz"] = as_v2(files["sh4_v4.spz"])
    files["axes_v1_v2.spz"] = as_v2(files["axes_v1.spz"])
    for name in INNERSCENE:
        files[name] = innerscene_head(name, cache)
    return files


def kit(folder: pathlib.Path, cache: pathlib.Path) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    gaussians = axes()
    made = {
        "axes_v3.spz": write_spz(gaussians, 3),
        "axes_v2.spz": write_spz(gaussians, 2),
        "axes_v4.spz": write_spz_v4(gaussians, keep_empty=True),
        "axes.ply": write_ply(gaussians, comments=["Generated by make_splat_fixtures.py"]),
        "room_60k.spz": write_spz(room(60000), 3),
        "room_200k.ply": write_ply(room(200000, seed=11), comments=["Generated by make_splat_fixtures.py"]),
        "mesh_cube.ply": mesh_cube(),
        "compressed.ply": compressed_ply(),
    }
    for name, data in made.items():
        (folder / name).write_bytes(data)
    for source, length, sha in [v[:3] for v in INNERSCENE.values()] + [INNERSCENE_CACTUS]:
        (folder / source).write_bytes(download(source, length, sha, cache))
    lines = []
    for path in sorted(folder.iterdir()):
        if path.is_file() and path.suffix in (".spz", ".ply"):
            lines.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.stat().st_size:>10}  {path.name}")
    (folder / "SHA256SUMS.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true", help="compare with the fixtures instead of writing them")
    parser.add_argument("--kit", type=pathlib.Path, help="also write the owner's kit into this folder")
    parser.add_argument("--cache", type=pathlib.Path, default=pathlib.Path("/tmp/splat-innerscene"),
                        help="where the CC0 files of InnerScene are downloaded once")
    args = parser.parse_args()
    files = fixtures(args.cache)
    exp = json.dumps(expected(files), indent=2) + "\n"
    if args.check:
        bad = []
        for name, data in files.items():
            path = FIXTURES / name
            if not path.is_file():
                bad.append(name)
            elif name in V4_FILES:
                if v4_content(path.read_bytes()) != v4_content(data):
                    bad.append(name)
            elif path.read_bytes() != data:
                bad.append(name)
        current = (FIXTURES / "expected.json").read_text(encoding="utf-8") if (FIXTURES / "expected.json").is_file() else ""
        # The sha256 and size of the version 4 files follow the zstandard module: compared apart from them
        def without_v4(text):
            data = json.loads(text) if text else {}
            for name in V4_FILES:
                data.get("headers", {}).get(name, {}).pop("sha256", None)
                data.get("headers", {}).get(name, {}).pop("bytes", None)
            return data
        if without_v4(current) != without_v4(exp):
            bad.append("expected.json")
        for name in bad:
            print(f"differs: {name}")
        return 1 if bad else 0
    FIXTURES.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (FIXTURES / name).write_bytes(data)
    (FIXTURES / "expected.json").write_text(exp, encoding="utf-8")
    print(f"{len(files)} fixtures and expected.json in {FIXTURES.relative_to(ROOT)}")
    if args.kit:
        kit(args.kit, args.cache)
        print(f"owner's kit in {args.kit}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
