#!/usr/bin/env python3
"""The small pictures of the tests of the JPEG codec of the AI features on a computer (lot A2b).

The codec decodes an original without any colour conversion, keeps its ICC profile, turns it upright, then writes
the side by side pair with a minimal EXIF, our XMP and the profile (design-final 2026-10-26, section 2.3). These
fixtures are made by another encoder than the one under test (Pillow on libjpeg), so that the tests do not only read
what they wrote themselves:

  orientation_1.jpg ... orientation_8.jpg   an upright 32 x 16 picture of four coloured quarters, stored turned or
                                            mirrored so that its EXIF orientation (1 to 8) shows it upright again;
                                            quality 100, 4:4:4
  quality_75.jpg, quality_90.jpg, quality_95.jpg   64 x 48, the IJG tables of these qualities, 4:2:0
  subsampling_444.jpg, subsampling_422.jpg, subsampling_420.jpg   64 x 48, quality 90
  display_p3.jpg       64 x 32, a Display P3 profile of ours (about 2.6 KB, one APP2 chunk)
  icc_two_chunks.jpg   the same picture with a Display P3 profile of about 73 KB, written by Pillow in two APP2
                       chunks, so that joining the chunks is tested on a file of another writer
  exif_camera.jpg      64 x 32 (2:1) with the EXIF of a DJI drone: make, model, software, orientation 6, the date
                       taken and its offset, GPS (south and west, so that the references matter) and a thumbnail in
                       IFD1; none of make, model or thumbnail may reach a 3D photo
  transparent.png      32 x 16 RGBA without a profile: opaque, half transparent and transparent areas, for the pixels
                       the engine decodes (transparency put on black)
  display_p3.png       the patches of display_p3.jpg with the Display P3 profile in iCCP: no profile may follow the
                       pixels the engine decoded
  display_p3.heic      (with --heic) 64 x 32, Display P3 in its colr box: a grey patch and two colours stored as
                       their Display P3 values, to tell whether a decoder of the system gives them in sRGB. Encoded
                       with the BT.709 matrix, the one the HEIF decoder of Windows applies to a file without an nclx
                       colour box (measured on 26 October 2026: with the BT.601 matrix that libheif uses by default,
                       it shifts saturated colours by about 10), so that only colour management makes a difference
  expected.json        what the tests compare to: colours, profile sizes and SHA-256, qualities, EXIF fields

Pillow (HPND licence, https://github.com/python-pillow/Pillow/blob/main/LICENSE) is a tool only: nothing of it is
shipped. The HEIC needs pillow-heif (BSD 3-Clause, https://github.com/bigcat88/pillow_heif), whose wheels carry
libheif and the x265 encoder; also a tool only, the picture is ours. The JPEG bytes depend on the libjpeg of Pillow,
so there is no --check: the tests read the pictures, never compare their bytes to a fresh run. Made with Pillow
10.2.0 and pillow-heif 0.18.0 (libheif 1.18.1).

The Display P3 profile is written here, not copied from a system: ICC v2.1 display profile, D50 white point with
the Bradford adapted P3 primaries (the colorants of the common Display P3 profiles), and the sRGB tone curve sampled
in a 'curv' tag.

  make_codec_fixtures.py          writes the JPEG and PNG fixtures and expected.json
  make_codec_fixtures.py --heic   also display_p3.heic
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
import pathlib
import struct
import sys

from PIL import Image, ImageOps

FIXTURES = pathlib.Path(__file__).resolve().parents[3] / "mobile/test/fixtures/ai_immersive/codec"

# The upright picture of the orientation fixtures: four quarters, each its own colour, so that each of the eight
# turns and mirrors gives a different layout, and wider than high, so that a quarter turn shows in the size
UPRIGHT_SIZE = (32, 16)
QUARTERS = {
    "topLeft": (220, 40, 40),
    "topRight": (40, 200, 60),
    "bottomLeft": (40, 60, 220),
    "bottomRight": (230, 220, 40),
}

# What makes the stored picture of each orientation from the upright one: the inverse of what a viewer does to show
# it (ImageOps.exif_transpose), checked below
STORED_FROM_UPRIGHT = {
    1: None,
    2: Image.Transpose.FLIP_LEFT_RIGHT,
    3: Image.Transpose.ROTATE_180,
    4: Image.Transpose.FLIP_TOP_BOTTOM,
    5: Image.Transpose.TRANSPOSE,
    6: Image.Transpose.ROTATE_90,
    7: Image.Transpose.TRANSVERSE,
    8: Image.Transpose.ROTATE_270,
}

# sRGB colours the P3 patches stand for, inside both gamuts, chosen so that their Display P3 values differ clearly
P3_PATCHES = {
    "grey": (128, 128, 128),
    "red": (200, 60, 60),
    "green": (70, 170, 90),
}

# The PNG on black: an opaque red half, a green quarter at alpha 128, a transparent blue quarter
PNG_AREAS = {
    "opaque": ((0, 0, 16, 16), (200, 30, 30, 255)),
    "half": ((16, 0, 32, 8), (0, 200, 0, 128)),
    "clear": ((16, 8, 32, 16), (0, 0, 255, 0)),
}

EXIF_CAMERA = {
    "make": "DJI",
    "model": "FC3582",
    "software": "10.01.02.07",
    "orientation": 6,
    "dateTimeOriginal": "2025:05:03 09:20:00",
    "offsetTimeOriginal": "+02:00",
    # degrees, minutes, seconds as rationals; south and west
    "latitude": -33.8568,
    "longitude": -70.6483,
    "altitude": 512.5,
}


# --- colours ---


def srgb_to_linear(v: float) -> float:
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def linear_to_srgb(v: float) -> float:
    v = min(max(v, 0.0), 1.0)
    return v * 12.92 if v <= 0.0031308 else 1.055 * v ** (1 / 2.4) - 0.055


def rgb_to_xyz_matrix(primaries: list[tuple[float, float]], white: tuple[float, float]) -> list[list[float]]:
    """The matrix from linear RGB to XYZ of these chromaticities"""
    columns = [[x / y, 1.0, (1 - x - y) / y] for x, y in primaries]
    wx, wy = white
    w = [wx / wy, 1.0, (1 - wx - wy) / wy]
    m = [[columns[c][r] for c in range(3)] for r in range(3)]
    s = solve3(m, w)
    return [[m[r][c] * s[c] for c in range(3)] for r in range(3)]


def solve3(m: list[list[float]], v: list[float]) -> list[float]:
    det = (
        m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
        - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
        + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
    )
    out = []
    for c in range(3):
        mc = [row[:] for row in m]
        for r in range(3):
            mc[r][c] = v[r]
        d = (
            mc[0][0] * (mc[1][1] * mc[2][2] - mc[1][2] * mc[2][1])
            - mc[0][1] * (mc[1][0] * mc[2][2] - mc[1][2] * mc[2][0])
            + mc[0][2] * (mc[1][0] * mc[2][1] - mc[1][1] * mc[2][0])
        )
        out.append(d / det)
    return out


def invert3(m: list[list[float]]) -> list[list[float]]:
    columns = [solve3(m, [1.0 if r == c else 0.0 for r in range(3)]) for c in range(3)]
    return [[columns[c][r] for c in range(3)] for r in range(3)]


def mul3(a: list[list[float]], b: list[list[float]]) -> list[list[float]]:
    return [[sum(a[r][k] * b[k][c] for k in range(3)) for c in range(3)] for r in range(3)]


D65 = (0.3127, 0.3290)
SRGB_TO_XYZ = rgb_to_xyz_matrix([(0.64, 0.33), (0.30, 0.60), (0.15, 0.06)], D65)
P3_TO_XYZ = rgb_to_xyz_matrix([(0.680, 0.320), (0.265, 0.690), (0.150, 0.060)], D65)
SRGB_TO_P3 = mul3(invert3(P3_TO_XYZ), SRGB_TO_XYZ)


def srgb_to_p3(rgb: tuple[int, int, int]) -> tuple[int, int, int]:
    """The Display P3 values of an sRGB colour: same tone curve, other primaries, same white"""
    linear = [srgb_to_linear(c / 255) for c in rgb]
    p3 = [sum(SRGB_TO_P3[r][c] * linear[c] for c in range(3)) for r in range(3)]
    return tuple(int(math.floor(linear_to_srgb(v) * 255 + 0.5)) for v in p3)


# --- the ICC profile ---


def s15f16(value: float) -> bytes:
    return struct.pack(">i", int(round(value * 65536)))


def xyz_tag(x: float, y: float, z: float) -> bytes:
    return b"XYZ " + b"\0" * 4 + s15f16(x) + s15f16(y) + s15f16(z)


def curve_tag(entries: int, offset: float = 0.0) -> bytes:
    """The sRGB tone curve in [entries] samples; [offset] shifts the samples by a tiny amount so that three curves of
    the large profile are not identical (a reader may not share them)"""
    values = []
    for i in range(entries):
        v = srgb_to_linear(i / (entries - 1)) + offset * (i / (entries - 1)) * (1 - i / (entries - 1))
        values.append(min(65535, max(0, int(round(v * 65535)))))
    return b"curv" + b"\0" * 4 + struct.pack(">I", entries) + struct.pack(f">{entries}H", *values)


def text_description_tag(text: str) -> bytes:
    data = text.encode("ascii") + b"\0"
    return (
        b"desc"
        + b"\0" * 4
        + struct.pack(">I", len(data))
        + data
        + struct.pack(">II", 0, 0)  # no Unicode description
        + struct.pack(">HB", 0, 0)  # no ScriptCode description
        + b"\0" * 67
    )


def text_tag(text: str) -> bytes:
    return b"text" + b"\0" * 4 + text.encode("ascii") + b"\0"


def display_p3_profile(curve_entries: int, separate_curves: bool, description: str) -> bytes:
    """An ICC v2.1 display profile of Display P3"""
    # The P3 primaries adapted to D50 by Bradford, as the common Display P3 profiles write them
    tags: list[tuple[bytes, bytes]] = [
        (b"desc", text_description_tag(description)),
        (b"cprt", text_tag("No copyright, use freely")),
        (b"wtpt", xyz_tag(0.96420, 1.00000, 0.82491)),
        (b"rXYZ", xyz_tag(0.515121, 0.241196, -0.001053)),
        (b"gXYZ", xyz_tag(0.291977, 0.692245, 0.041885)),
        (b"bXYZ", xyz_tag(0.157104, 0.066574, 0.784073)),
    ]
    if separate_curves:
        tags += [
            (b"rTRC", curve_tag(curve_entries, 0.0)),
            (b"gTRC", curve_tag(curve_entries, 1e-4)),
            (b"bTRC", curve_tag(curve_entries, 2e-4)),
        ]
    else:
        shared = curve_tag(curve_entries)
        tags += [(b"rTRC", shared), (b"gTRC", shared), (b"bTRC", shared)]

    table_size = 4 + 12 * len(tags)
    offset = 128 + table_size
    table = struct.pack(">I", len(tags))
    body = b""
    placed: dict[bytes, int] = {}
    for signature, data in tags:
        if data in placed:
            table += signature + struct.pack(">II", placed[data], len(data))
            continue
        while (offset + len(body)) % 4:
            body += b"\0"
        at = offset + len(body)
        placed[data] = at
        table += signature + struct.pack(">II", at, len(data))
        body += data
    size = 128 + len(table) + len(body)
    header = (
        struct.pack(">I", size)
        + b"\0\0\0\0"  # no preferred CMM
        + bytes([2, 0x10, 0, 0])  # version 2.1
        + b"mntr"
        + b"RGB "
        + b"XYZ "
        + struct.pack(">6H", 2026, 10, 26, 0, 0, 0)
        + b"acsp"
        + b"\0\0\0\0"  # no primary platform
        + struct.pack(">I", 0)  # flags
        + b"\0\0\0\0"  # device manufacturer
        + b"\0\0\0\0"  # device model
        + struct.pack(">Q", 0)  # device attributes
        + struct.pack(">I", 0)  # perceptual intent
        + s15f16(0.9642)
        + s15f16(1.0)
        + s15f16(0.8249)  # D50 illuminant of the PCS
        + b"\0\0\0\0"  # creator
        + b"\0" * 44
    )
    assert len(header) == 128, len(header)
    return header + table + body


# --- EXIF ---


def tiff_ifd(entries: list[tuple[int, int, int, bytes]], data_at: int, next_ifd: int) -> tuple[bytes, bytes]:
    """An IFD of little endian TIFF: (tag, type, count, value bytes). Values longer than 4 bytes go after the IFD,
    from [data_at]. Gives the IFD and its data."""
    entries = sorted(entries)
    ifd = struct.pack("<H", len(entries))
    data = b""
    for tag, kind, count, value in entries:
        if len(value) <= 4:
            ifd += struct.pack("<HHI", tag, kind, count) + value.ljust(4, b"\0")
        else:
            if len(data) % 2:
                data += b"\0"
            ifd += struct.pack("<HHII", tag, kind, count, data_at + len(data))
            data += value
    ifd += struct.pack("<I", next_ifd)
    return ifd, data


def ascii_value(text: str) -> tuple[int, int, bytes]:
    data = text.encode("ascii") + b"\0"
    return 2, len(data), data


def rationals(values: list[tuple[int, int]]) -> tuple[int, int, bytes]:
    return 5, len(values), b"".join(struct.pack("<II", n, d) for n, d in values)


def dms(value: float) -> list[tuple[int, int]]:
    value = abs(value)
    degrees = int(value)
    minutes_float = (value - degrees) * 60
    minutes = int(minutes_float)
    seconds = round((minutes_float - minutes) * 60 * 10000)
    return [(degrees, 1), (minutes, 1), (seconds, 10000)]


def camera_exif(thumbnail: bytes) -> bytes:
    """The APP1 payload of a drone photo: "Exif\\0\\0" then little endian TIFF with IFD0, the EXIF IFD, the GPS IFD
    and IFD1 with its JPEG thumbnail, one after the other"""
    e = EXIF_CAMERA
    lat, lon = e["latitude"], e["longitude"]

    def entry(tag: int, value: tuple[int, int, bytes]) -> tuple[int, int, int, bytes]:
        return (tag, value[0], value[1], value[2])

    def sections(exif_at: int, gps_at: int, ifd1_at: int, thumb_at: int) -> list[list[tuple[int, int, int, bytes]]]:
        return [
            [
                entry(0x010F, ascii_value(e["make"])),
                entry(0x0110, ascii_value(e["model"])),
                (0x0112, 3, 1, struct.pack("<H", e["orientation"])),
                entry(0x0131, ascii_value(e["software"])),
                (0x8769, 4, 1, struct.pack("<I", exif_at)),
                (0x8825, 4, 1, struct.pack("<I", gps_at)),
            ],
            [
                (0x9000, 7, 4, b"0232"),
                entry(0x9003, ascii_value(e["dateTimeOriginal"])),
                entry(0x9011, ascii_value(e["offsetTimeOriginal"])),
            ],
            [
                (0x0000, 1, 4, bytes([2, 3, 0, 0])),
                entry(0x0001, ascii_value("S" if lat < 0 else "N")),
                entry(0x0002, rationals(dms(lat))),
                entry(0x0003, ascii_value("W" if lon < 0 else "E")),
                entry(0x0004, rationals(dms(lon))),
                (0x0005, 1, 1, bytes([0])),
                entry(0x0006, rationals([(int(round(e["altitude"] * 10)), 10)])),
            ],
            [
                (0x0103, 3, 1, struct.pack("<H", 6)),
                (0x0201, 4, 1, struct.pack("<I", thumb_at)),
                (0x0202, 4, 1, struct.pack("<I", len(thumbnail))),
            ],
        ]

    def lay_out(offsets: list[int]) -> tuple[bytes, list[int]]:
        """The TIFF with each IFD at the offset given, and where each IFD and the thumbnail go when they follow each
        other (the sizes never depend on the offsets, so a first pass at zero finds them)"""
        exif_at, gps_at, ifd1_at, thumb_at = offsets
        tiff = b"II*\0" + struct.pack("<I", 8)
        starts = [8, exif_at, gps_at, ifd1_at]
        nexts = [ifd1_at, 0, 0, 0]
        packed = []
        at = 8
        followers = []
        for index, entries in enumerate(sections(exif_at, gps_at, ifd1_at, thumb_at)):
            start = starts[index]
            ifd, data = tiff_ifd(entries, start + 2 + 12 * len(entries) + 4, nexts[index])
            packed.append((start, ifd + data))
            followers.append(at)
            at += len(ifd) + len(data)
            at += at % 2
        followers.append(at)
        if thumb_at:
            for start, part in packed + [(thumb_at, thumbnail)]:
                assert len(tiff) <= start, (len(tiff), start)
                tiff = tiff.ljust(start, b"\0") + part
        return tiff, followers[1:]

    _, offsets = lay_out([0, 0, 0, 0])
    tiff, check = lay_out(offsets)
    assert check == offsets
    return b"Exif\0\0" + tiff


# --- pictures ---


def upright_quarters() -> Image.Image:
    width, height = UPRIGHT_SIZE
    image = Image.new("RGB", UPRIGHT_SIZE)
    for name, colour in QUARTERS.items():
        left = 0 if name.endswith("Left") else width // 2
        top = 0 if name.startswith("top") else height // 2
        image.paste(colour, (left, top, left + width // 2, top + height // 2))
    return image


def photo_like(width: int, height: int) -> Image.Image:
    """Gradients and a fixed texture: enough detail for the quantisation tables to matter, no randomness"""
    image = Image.new("RGB", (width, height))
    pixels = image.load()
    for y in range(height):
        for x in range(width):
            texture = (x * 37 + y * 91 + (x * y) % 13 * 7) % 23
            pixels[x, y] = (
                (x * 255 // max(1, width - 1) + texture) % 256,
                (y * 255 // max(1, height - 1) + 2 * texture) % 256,
                ((x + y) * 255 // max(1, width + height - 2) + 3 * texture) % 256,
            )
    return image


def p3_patches(width: int, height: int) -> Image.Image:
    """Three vertical bands, each the Display P3 value of its sRGB colour"""
    image = Image.new("RGB", (width, height))
    band = width // len(P3_PATCHES)
    for index, colour in enumerate(P3_PATCHES.values()):
        image.paste(srgb_to_p3(colour), (index * band, 0, (index + 1) * band if index < 2 else width, height))
    return image


def exif_with_orientation(orientation: int) -> bytes:
    exif = Image.Exif()
    exif[0x0112] = orientation
    return exif.tobytes()


def save_jpeg(path: pathlib.Path, image: Image.Image, **options) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, "JPEG", **options)
    data = buffer.getvalue()
    path.write_bytes(data)
    return data


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def app2_chunks(jpeg: bytes) -> int:
    """How many ICC_PROFILE APP2 segments a JPEG has"""
    count = 0
    at = 2
    while at + 4 <= len(jpeg) and jpeg[at] == 0xFF:
        marker = jpeg[at + 1]
        if marker == 0xDA:
            break
        length = jpeg[at + 2] << 8 | jpeg[at + 3]
        if marker == 0xE2 and jpeg[at + 4 : at + 16] == b"ICC_PROFILE\0":
            count += 1
        at += 2 + length
    return count


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--heic", action="store_true", help="also write display_p3.heic (needs pillow-heif)")
    args = parser.parse_args()

    FIXTURES.mkdir(parents=True, exist_ok=True)
    expected: dict = {"tool": f"Pillow {Image.__version__}"}

    # Orientations
    upright = upright_quarters()
    for orientation, transpose in STORED_FROM_UPRIGHT.items():
        stored = upright if transpose is None else upright.transpose(transpose)
        shown = ImageOps.exif_transpose(_with_orientation(stored, orientation))
        assert list(shown.getdata()) == list(upright.getdata()), f"orientation {orientation}"
        save_jpeg(
            FIXTURES / f"orientation_{orientation}.jpg",
            stored,
            quality=100,
            subsampling=0,
            exif=exif_with_orientation(orientation),
        )
    expected["orientation"] = {
        "uprightWidth": UPRIGHT_SIZE[0],
        "uprightHeight": UPRIGHT_SIZE[1],
        "quarters": {name: list(colour) for name, colour in QUARTERS.items()},
    }

    # Qualities and subsampling
    photo = photo_like(64, 48)
    for quality in (75, 90, 95):
        save_jpeg(FIXTURES / f"quality_{quality}.jpg", photo, quality=quality, subsampling=2)
    expected["qualities"] = [75, 90, 95]
    for name, subsampling in (("444", 0), ("422", 1), ("420", 2)):
        save_jpeg(FIXTURES / f"subsampling_{name}.jpg", photo, quality=90, subsampling=subsampling)
    expected["subsampling"] = ["444", "422", "420"]

    # Display P3 profiles
    patches = p3_patches(64, 32)
    small = display_p3_profile(1024, separate_curves=False, description="Display P3 (Immuch360 test)")
    large = display_p3_profile(12000, separate_curves=True, description="Display P3 large (Immuch360 test)")
    small_jpeg = save_jpeg(FIXTURES / "display_p3.jpg", patches, quality=95, subsampling=0, icc_profile=small)
    large_jpeg = save_jpeg(FIXTURES / "icc_two_chunks.jpg", patches, quality=95, subsampling=0, icc_profile=large)
    assert app2_chunks(small_jpeg) == 1 and app2_chunks(large_jpeg) == 2
    (FIXTURES / "display_p3.icc").write_bytes(small)
    expected["iccProfiles"] = {
        "display_p3.jpg": {"length": len(small), "sha256": sha256(small), "chunks": 1},
        "icc_two_chunks.jpg": {"length": len(large), "sha256": sha256(large), "chunks": 2},
    }
    expected["p3Patches"] = {
        name: {"srgb": list(colour), "p3": list(srgb_to_p3(colour))} for name, colour in P3_PATCHES.items()
    }

    # A drone photo with all the EXIF a 3D photo must not keep
    thumbnail_buffer = io.BytesIO()
    photo_like(16, 8).save(thumbnail_buffer, "JPEG", quality=70)
    camera = photo_like(64, 32)
    save_jpeg(FIXTURES / "exif_camera.jpg", camera, quality=90, exif=camera_exif(thumbnail_buffer.getvalue()))
    expected["exifCamera"] = EXIF_CAMERA

    # A PNG with transparency and a profile
    png = Image.new("RGBA", (32, 16))
    for box, colour in PNG_AREAS.values():
        png.paste(colour, box)
    png.save(FIXTURES / "transparent.png", "PNG")
    patches.save(FIXTURES / "display_p3.png", "PNG", icc_profile=small)
    expected["png"] = {
        name: {
            "x": (box[0] + box[2]) // 2,
            "y": (box[1] + box[3]) // 2,
            "rgba": list(colour),
            "onBlack": [int(math.floor(c * colour[3] / 255 + 0.5)) for c in colour[:3]],
        }
        for name, (box, colour) in PNG_AREAS.items()
    }

    if args.heic:
        import pillow_heif

        pillow_heif.register_heif_opener()
        heic = io.BytesIO()
        patches.save(heic, "HEIF", quality=95, chroma=444, icc_profile=small, matrix_coefficients=1, full_range_flag=1)
        (FIXTURES / "display_p3.heic").write_bytes(heic.getvalue())
        expected["heic"] = {"tool": f"pillow-heif {pillow_heif.__version__}", "width": 64, "height": 32}

    (FIXTURES / "expected.json").write_text(json.dumps(expected, indent=1, sort_keys=True) + "\n")
    print(f"written to {FIXTURES}")
    return 0


def _with_orientation(image: Image.Image, orientation: int) -> Image.Image:
    copy = image.copy()
    copy.getexif()[0x0112] = orientation
    return copy


if __name__ == "__main__":
    sys.exit(main())
