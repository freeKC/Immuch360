#!/usr/bin/env python3
"""The reference of the focal length and the shift of a MoGe-2 point map, and its golden fixture.

MoGe-2 gives its points up to a shift of their depth and without the focal length; its PyTorch code finds both with
recover_focal_shift, which does not export to ONNX ("The .infer() method in our PyTorch code includes some
post-processing logic (e.g., recovering focal and shift and reprojection) that cannot be exported to ONNX",
https://github.com/microsoft/MoGe/blob/main/docs/onnx.md). The computers do it in Dart (focal_shift.dart, lot S1) and
must give what this script gives on mobile/test/fixtures/ai_immersive/focal_shift_golden_v1.json, within the
tolerance it states. The measure M2 checks this script once against recover_focal_shift of MoGe on real outputs.
Design: store/m2/ai-immersive-2026-10-26/phase23/design-final-2026-10-27.md, sections 2.2 and 2.3.

As far as both sides must agree, for a map of W x H points (x, y, z) and its mask (valid when over 0.5), already on
the grid the fit uses (MoGe resizes to 64 x 64 first, keeping the valid points; that resizing is not part of this
reference):

1. The view plane of MoGe, normalised so that the half diagonal is 1: aspect a = W / H,
   span_x = a / sqrt(1 + a * a), span_y = 1 / sqrt(1 + a * a); the point (i, j) looks through
   u = span_x * (2 * (i + 0.5) / W - 1), v = span_y * (2 * (j + 0.5) / H - 1).
2. For a shift s, every valid point projects to (x, y) / (z + s); the focal length that fits best is
   focal(s) = sum(p . uv) / sum(p . p) over the valid points, p the projection; the error is
   E(s) = sum |focal(s) * p - uv|^2.
3. The shift is the s that makes E the smallest over s > -min(z): golden section on [lo, hi], lo = -min(z) + 1e-6 *
   max(1, |min(z)|), hi = lo + 100 * (max(z) - min(z) + 1), until hi - lo < 1e-12 * max(1, |lo|): the middle of the
   last interval. With a focal length known (the EXIF), the same search on E_f(s) = sum |f * p - uv|^2.
4. The depth is then z + s (times the metric scale of MoGe-2, outside this reference); the horizontal field of view
   2 * atan(span_x / focal) in degrees; the focal length in pixels of a map W wide, focal * W / (2 * span_x).
5. From the EXIF: a focal length F35 equivalent to 35 mm (a diagonal of 43.27 mm) gives focal = F35 / 21.635. The flag
   fovGuessed when |focal of the model - focal of the EXIF| > 0.25 * focal of the EXIF, or without EXIF: focal
   lengths, not fields of view, and measured against the EXIF (the cases exifNear and exifFar sit on each side of the
   threshold, where comparing fields of view, or dividing by the focal of the model, gives the other answer).

  make_focal_shift_golden.py           writes the fixture
  make_focal_shift_golden.py --check   exit 1 when the fixture differs from what this script writes (a CI step)

Pure Python 3, no package.
"""
from __future__ import annotations

import argparse
import math
import pathlib
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import make_relief_golden as relief  # noqa: E402

FIXTURE = pathlib.Path(__file__).resolve().parents[3] / "mobile/test/fixtures/ai_immersive/focal_shift_golden_v1.json"
VALID_MASK = 0.5
HALF_DIAGONAL_35MM = 21.635
FOV_MISMATCH = 0.25
GOLDEN = (math.sqrt(5) - 1) / 2


def view_plane(width: int, height: int) -> tuple:
    aspect = width / height
    span_x = aspect / math.sqrt(1 + aspect * aspect)
    span_y = 1 / math.sqrt(1 + aspect * aspect)
    uv = [[(span_x * (2 * (i + 0.5) / width - 1), span_y * (2 * (j + 0.5) / height - 1)) for i in range(width)]
          for j in range(height)]
    return uv, span_x, span_y


def valid_points(points: list, mask: list, uv: list) -> list:
    return [(p, q) for row_p, row_m, row_uv in zip(points, mask, uv) for p, m, q in zip(row_p, row_m, row_uv)
            if m > VALID_MASK]


def best_focal(pairs: list, shift: float) -> float:
    top = bottom = 0.0
    for (x, y, z), (u, v) in pairs:
        px, py = x / (z + shift), y / (z + shift)
        top += px * u + py * v
        bottom += px * px + py * py
    return top / bottom


def error(pairs: list, shift: float, focal: float | None) -> float:
    f = best_focal(pairs, shift) if focal is None else focal
    total = 0.0
    for (x, y, z), (u, v) in pairs:
        ex, ey = f * x / (z + shift) - u, f * y / (z + shift) - v
        total += ex * ex + ey * ey
    return total


def search(pairs: list, focal: float | None) -> float:
    depths = [z for (_, _, z), _ in pairs]
    lo = -min(depths) + 1e-6 * max(1.0, abs(min(depths)))
    hi = lo + 100 * (max(depths) - min(depths) + 1)
    a, b = hi - GOLDEN * (hi - lo), lo + GOLDEN * (hi - lo)
    ea, eb = error(pairs, a, focal), error(pairs, b, focal)
    while hi - lo >= 1e-12 * max(1.0, abs(lo)):
        if ea < eb:
            hi, b, eb = b, a, ea
            a = hi - GOLDEN * (hi - lo)
            ea = error(pairs, a, focal)
        else:
            lo, a, ea = a, b, eb
            b = lo + GOLDEN * (hi - lo)
            eb = error(pairs, b, focal)
    return (lo + hi) / 2


def case(name: str, description: str, width: int, height: int, focal: float, shift: float, depth, noise: float,
         mask=None, exif35: float | None = None) -> dict:
    """Points whose true depth is depth(i, j), seen with [focal], given with z = true depth - [shift], plus a fixed
    pseudo random noise of [noise] on every coordinate"""
    uv, span_x, _ = view_plane(width, height)
    seed = 12345
    points = []
    for j in range(height):
        row = []
        for i in range(width):
            true_z = depth(i, j)
            u, v = uv[j][i]
            values = [u * true_z / focal, v * true_z / focal, true_z - shift]
            for k in range(3):
                seed = (seed * 1103515245 + 12345) % 2147483648
                values[k] += noise * (seed / 2147483648 - 0.5)
            row.append(values)
        points.append(row)
    mask_values = [[1.0 if mask is None else mask(i, j) for i in range(width)] for j in range(height)]
    pairs = valid_points(points, mask_values, uv)
    found_shift = search(pairs, None)
    found_focal = best_focal(pairs, found_shift)
    exif_focal = None if exif35 is None else exif35 / HALF_DIAGONAL_35MM
    shift_for_exif = None if exif_focal is None else search(pairs, exif_focal)
    guessed = exif_focal is None or abs(found_focal - exif_focal) > FOV_MISMATCH * exif_focal
    return {
        "name": name,
        "description": description,
        "width": width,
        "height": height,
        "points": [coordinate for row in points for p in row for coordinate in p],
        "mask": [value for row in mask_values for value in row],
        "uv": [coordinate for row in uv for pair in row for coordinate in pair],
        "spanX": span_x,
        "trueFocal": focal,
        "trueShift": shift,
        "focal": found_focal,
        "shift": found_shift,
        "error": error(pairs, found_shift, None),
        "fovDegrees": math.degrees(2 * math.atan(span_x / found_focal)),
        "focalPixels": found_focal * width / (2 * span_x),
        "exifFocal35": exif35,
        "exifFocal": exif_focal,
        "shiftForExif": shift_for_exif,
        "fovGuessed": guessed,
    }


def build() -> dict:
    cases = [
        case("exact", "a wall leaning back, exact points: the shift and the focal length of the camera come back",
             16, 12, 1.2, 0.7, lambda i, j: 2.0 + 0.1 * j + 0.05 * i, 0.0),
        case("noisy", "the same wall with noise on every coordinate", 16, 12, 1.2, 0.7,
             lambda i, j: 2.0 + 0.1 * j + 0.05 * i, 0.002),
        case("masked", "a room with its top third without depth: only the valid points count", 16, 12, 0.9, -0.4,
             lambda i, j: 3.0 - 0.15 * j + (0.6 if 5 <= i <= 9 else 0.0), 0.001,
             mask=lambda i, j: 0.0 if j < 4 else 1.0),
        case("exif", "a portrait frame with the EXIF of a 28 mm lens: the shift for the focal of the EXIF", 9, 12,
             28 / HALF_DIAGONAL_35MM, 1.5, lambda i, j: 4.0 + 0.2 * math.sin(i) + 0.1 * j, 0.0005, exif35=28.0),
        case("exifMismatch", "a 4:3 frame whose EXIF says 50 mm while the points say a wide lens: fovGuessed", 16, 12,
             0.8, 0.2, lambda i, j: 1.5 + 0.08 * i, 0.0005, exif35=50.0),
        case("exifNear", "an EXIF of 26 mm, the points a focal length 22 % shorter: within 25 %, not fovGuessed", 16,
             12, 0.78 * 26 / HALF_DIAGONAL_35MM, 0.3, lambda i, j: 2.5 + 0.06 * i + 0.04 * j, 0.0005, exif35=26.0),
        case("exifFar", "an EXIF of 26 mm, the points a focal length 28 % longer: fovGuessed, though the fields of "
             "view differ by less than 25 %", 16, 12, 1.28 * 26 / HALF_DIAGONAL_35MM, 0.3,
             lambda i, j: 2.5 + 0.06 * i + 0.04 * j, 0.0005, exif35=26.0),
    ]
    return {
        "about": "Made by .github/desktop/ai/make_focal_shift_golden.py, whose header describes the fit. points are x, "
        "y, z one after the other, row after row; uv the same in pairs; the mask one value per point.",
        "tolerance": 1e-6,
        "validMask": VALID_MASK,
        "halfDiagonal35mm": HALF_DIAGONAL_35MM,
        "fovMismatch": FOV_MISMATCH,
        "cases": cases,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="compare with the fixture instead of writing it")
    args = parser.parse_args()
    text = relief.render(build()) + "\n"
    if args.check:
        current = FIXTURE.read_text(encoding="utf-8") if FIXTURE.exists() else ""
        if current != text:
            print(f"{FIXTURE} differs from what {pathlib.Path(__file__).name} writes: run it and commit the result",
                  file=sys.stderr)
            return 1
        print(f"{FIXTURE.name} is what the script writes")
        return 0
    FIXTURE.write_text(text, encoding="utf-8")
    print(f"wrote {FIXTURE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
