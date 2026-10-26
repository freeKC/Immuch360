#!/usr/bin/env python3
"""The reference of relief-v1, the right eye Immuch360 makes from a photo and its estimated depth, and its golden fixture.

The computers build the right eye in Dart (lib/desktop/ai, lot A2a) and the Meta Quest in Kotlin (relief/, lot A8b).
Both must give what this script gives on mobile/test/fixtures/ai_immersive/relief_golden_v1.json: each channel of the
right eye within one unit, the mask of the filled holes exactly. Everything is in double precision, in the order
written below: the three languages then round the same way, which keeps the comparisons that decide a hole or an
occlusion identical. Design: store/m2/ai-immersive-2026-10-26/design-final-2026-10-26.md, section 2.4.

relief-v1, for a photo of L x H pixels (the left eye, never changed) and a depth map D of w x h values at the
resolution of the model (relative disparity: larger is nearer), with the parallax B and the convergence c:

1. Normalisation. The values of D sorted in increasing order; the percentile P by nearest rank is the value of rank
   max(1, (P * N + 99) // 100) (integer arithmetic, N = w * h, ranks from 1). range = p98 - p2. When range <= 0,
   d = 0.5 everywhere; otherwise d = (D - p2) / range, clamped to [0, 1]. The flag lowRelief is set when
   range <= 0 or range < 0.1 * |p98|.
2. Dilation of the foreground: each value becomes the largest d of the 5 x 5 window around it, the window cut at the
   edges of the map.
3. Enlargement to the eye: for the pixel (x, y) of the eye, u = (x + 0.5) * w / L - 0.5 and
   v = (y + 0.5) * h / H - 0.5, evaluated left to right; x0 = floor(u), fx = u - x0, the columns x0 and x0 + 1 clamped
   to [0, w - 1], the same for the rows; top = a + (b - a) * fx, bottom = e + (f - e) * fx,
   d = top + (bottom - top) * fy (a, b on the upper row, e, f on the lower one): equal neighbours give their value
   exactly.
4. Shift of the right eye: s = (B * L) * (c - d) pixels. The nearest (d = 1) moves left by B * L / 2 when c = 0.5.
5. Forward projection, row by row: the pixel x goes to t = x + s(x). For x from 0 to L - 1: first the pixel alone at
   X = floor(t + 0.5); then, when x + 1 < L and |d(x) - d(x + 1)| <= 0.04, the segment to x + 1 over the columns
   X = ceil(min(t0, t1)) to floor(max(t0, t1)), with a = (X - t0) / (t1 - t0) (0 when t1 == t0), the depth
   d0 + (d1 - d0) * a and each channel c0 + (c1 - c0) * a. A column outside [0, L - 1] is skipped. A write takes the
   column only when its depth is strictly larger than the one already there (the nearest wins, the first written on a
   tie); a column never written is a hole.
6. Filling: each run of holes of a row takes the colour of the one of its two written neighbours with the smaller
   depth (the background), the left one on a tie, the only one when there is one, black when the row has none. Then
   each filled pixel becomes (f[x - 1] + f[x] + f[x + 1]) / 3 per channel, read on the filled row f, the neighbours
   clamped to the row. Every channel is finally rounded as floor(v + 0.5), clamped to [0, 255].
7. Flags: hiddenAreas when more than 5 % of the pixels were filled; dark when the mean of
   0.2126 R + 0.7152 G + 0.0722 B over the photo is under 20. In the order lowRelief, hiddenAreas, dark.

  make_relief_golden.py           writes the fixture
  make_relief_golden.py --check   exit 1 when the fixture differs from what this script writes (a CI step)

Pure Python 3, no package.
"""
from __future__ import annotations

import argparse
import json
import math
import pathlib
import sys

FIXTURE = pathlib.Path(__file__).resolve().parents[3] / "mobile/test/fixtures/ai_immersive/relief_golden_v1.json"

PIPELINE = "relief-v1"
LINK_THRESHOLD = 0.04
DILATION_RADIUS = 2
LOW_PERCENTILE = 2
HIGH_PERCENTILE = 98
LOW_RELIEF_RATIO = 0.1
HIDDEN_AREAS_RATIO = 0.05
DARK_LUMA = 20.0


def percentile(sorted_values: list[float], p: int) -> float:
    rank = max(1, (p * len(sorted_values) + 99) // 100)
    return sorted_values[rank - 1]


def normalise(depth: list[list[float]]) -> tuple[list[list[float]], float, float, bool]:
    ordered = sorted(value for row in depth for value in row)
    p2 = percentile(ordered, LOW_PERCENTILE)
    p98 = percentile(ordered, HIGH_PERCENTILE)
    spread = p98 - p2
    low_relief = spread <= 0 or spread < LOW_RELIEF_RATIO * abs(p98)
    if spread <= 0:
        return [[0.5 for _ in row] for row in depth], p2, p98, low_relief
    normalised = [[min(1.0, max(0.0, (value - p2) / spread)) for value in row] for row in depth]
    return normalised, p2, p98, low_relief


def dilate(d: list[list[float]]) -> list[list[float]]:
    h = len(d)
    w = len(d[0])
    out = []
    for y in range(h):
        row = []
        for x in range(w):
            best = d[y][x]
            for yy in range(max(0, y - DILATION_RADIUS), min(h - 1, y + DILATION_RADIUS) + 1):
                for xx in range(max(0, x - DILATION_RADIUS), min(w - 1, x + DILATION_RADIUS) + 1):
                    if d[yy][xx] > best:
                        best = d[yy][xx]
            row.append(best)
        out.append(row)
    return out


def clamp_index(i: int, size: int) -> int:
    return min(size - 1, max(0, i))


def enlarge(d: list[list[float]], width: int, height: int) -> list[list[float]]:
    h = len(d)
    w = len(d[0])
    out = []
    for y in range(height):
        v = (y + 0.5) * h / height - 0.5
        y0 = math.floor(v)
        fy = v - y0
        top_row = d[clamp_index(y0, h)]
        bottom_row = d[clamp_index(y0 + 1, h)]
        row = []
        for x in range(width):
            u = (x + 0.5) * w / width - 0.5
            x0 = math.floor(u)
            fx = u - x0
            left = clamp_index(x0, w)
            right = clamp_index(x0 + 1, w)
            top = top_row[left] + (top_row[right] - top_row[left]) * fx
            bottom = bottom_row[left] + (bottom_row[right] - bottom_row[left]) * fx
            row.append(top + (bottom - top) * fy)
        out.append(row)
    return out


def right_eye_row(
    pixels: list[list[int]], d: list[float], parallax: float, convergence: float
) -> tuple[list[list[float]], list[bool]]:
    """One row: the colours of the right eye before rounding, and which columns were holes"""
    width = len(pixels)
    t = [x + (parallax * width) * (convergence - d[x]) for x in range(width)]
    depth = [-math.inf] * width
    colour: list[list[float] | None] = [None] * width

    def put(column: int, dd: float, rgb: list[float]) -> None:
        if 0 <= column < width and dd > depth[column]:
            depth[column] = dd
            colour[column] = rgb

    for x in range(width):
        put(math.floor(t[x] + 0.5), d[x], [float(channel) for channel in pixels[x]])
        if x + 1 < width and abs(d[x] - d[x + 1]) <= LINK_THRESHOLD:
            t0 = t[x]
            t1 = t[x + 1]
            for column in range(math.ceil(min(t0, t1)), math.floor(max(t0, t1)) + 1):
                a = (column - t0) / (t1 - t0) if t1 != t0 else 0.0
                put(
                    column,
                    d[x] + (d[x + 1] - d[x]) * a,
                    [pixels[x][k] + (pixels[x + 1][k] - pixels[x][k]) * a for k in range(3)],
                )

    holes = [colour[x] is None for x in range(width)]
    filled: list[list[float]] = [list(c) if c is not None else [0.0, 0.0, 0.0] for c in colour]
    x = 0
    while x < width:
        if not holes[x]:
            x += 1
            continue
        start = x
        while x < width and holes[x]:
            x += 1
        end = x - 1
        left = start - 1 if start > 0 else None
        right = end + 1 if end + 1 < width else None
        if left is not None and right is not None:
            source = left if depth[left] <= depth[right] else right
        else:
            source = left if left is not None else right
        fill = filled[source] if source is not None else [0.0, 0.0, 0.0]
        for column in range(start, end + 1):
            filled[column] = list(fill)
    out = [list(c) for c in filled]
    for x in range(width):
        if holes[x]:
            before = filled[max(0, x - 1)]
            after = filled[min(width - 1, x + 1)]
            out[x] = [(before[k] + filled[x][k] + after[k]) / 3 for k in range(3)]
    return out, holes


def to_byte(value: float) -> int:
    return min(255, max(0, math.floor(value + 0.5)))


def relief_v1(image: list[list[list[int]]], depth: list[list[float]], parallax: float, convergence: float) -> dict:
    height = len(image)
    width = len(image[0])
    normalised, p2, p98, low_relief = normalise(depth)
    dilated = dilate(normalised)
    eye_depth = enlarge(dilated, width, height)
    right_eye = []
    holes = []
    filled = 0
    for y in range(height):
        row, row_holes = right_eye_row(image[y], eye_depth[y], parallax, convergence)
        right_eye.append([to_byte(channel) for pixel in row for channel in pixel])
        holes.append("".join("1" if hole else "0" for hole in row_holes))
        filled += sum(row_holes)
    luma = sum(0.2126 * r + 0.7152 * g + 0.0722 * b for row in image for (r, g, b) in row) / (width * height)
    flags = []
    if low_relief:
        flags.append("lowRelief")
    if filled > HIDDEN_AREAS_RATIO * width * height:
        flags.append("hiddenAreas")
    if luma < DARK_LUMA:
        flags.append("dark")
    return {
        "p2": p2,
        "p98": p98,
        "normalized": normalised,
        "dilated": dilated,
        "eyeDepth": eye_depth,
        "rightEye": right_eye,
        "holes": holes,
        "filledPixels": filled,
        "meanLuma": luma,
        "flags": flags,
    }


# --- The cases ----------------------------------------------------------------------------------------------------

EYE_WIDTH = 32
EYE_HEIGHT = 8
MAP_WIDTH = 16
MAP_HEIGHT = 4


def pattern_image() -> list[list[list[int]]]:
    return [
        [[(17 * x + 3 * y * y) % 256, (5 * x * y + 40) % 256, (255 - 7 * x - 11 * y) % 256] for x in range(EYE_WIDTH)]
        for y in range(EYE_HEIGHT)
    ]


def dark_image() -> list[list[list[int]]]:
    return [[[(x + y) % 24, (2 * x + y) % 20, (x * y) % 16] for x in range(EYE_WIDTH)] for y in range(EYE_HEIGHT)]


def scene_depth() -> list[list[float]]:
    """A ground that comes nearer towards the bottom, a near object in the middle, and one outlier at each end that the
    percentiles leave out"""
    rows = []
    for y in range(MAP_HEIGHT):
        row = []
        for x in range(MAP_WIDTH):
            value = 1.0 + 0.75 * y + 0.05 * x
            if 6 <= x <= 9 and 1 <= y <= 3:
                value = 9.0
            row.append(value)
        rows.append(row)
    rows[0][0] = -2.0
    rows[0][MAP_WIDTH - 1] = 30.0
    return rows


def constant_depth() -> list[list[float]]:
    return [[3.0] * MAP_WIDTH for _ in range(MAP_HEIGHT)]


def shallow_depth() -> list[list[float]]:
    return [[10.0 + 0.01 * x + 0.02 * y for x in range(MAP_WIDTH)] for y in range(MAP_HEIGHT)]


CASES = [
    ("production", "the settings of the app: 2 % of parallax, convergence in the middle", pattern_image, scene_depth,
     0.02, 0.5),
    ("strong", "a parallax of 25 % that opens holes beside the near object and at the left edge", pattern_image,
     scene_depth, 0.25, 0.5),
    ("flat", "a constant map: d = 0.5 everywhere, the whole eye moved left, a hole column at the right edge",
     pattern_image, constant_depth, 0.25, 0.4),
    ("dark", "a dark photo and a map with little relief", dark_image, shallow_depth, 0.02, 0.5),
]


def build() -> dict:
    cases = []
    for name, description, image_of, depth_of, parallax, convergence in CASES:
        image = image_of()
        depth = depth_of()
        expected = relief_v1(image, depth, parallax, convergence)
        cases.append(
            {
                "name": name,
                "description": description,
                "parallax": parallax,
                "convergence": convergence,
                "image": [[channel for pixel in row for channel in pixel] for row in image],
                "depth": depth,
                **expected,
            }
        )
    return {
        "pipeline": PIPELINE,
        "about": "Made by .github/desktop/ai/make_relief_golden.py, whose header describes relief-v1. Images are rows of "
        "R, G, B bytes; depth, normalized and dilated are rows of the map; eyeDepth is d at each pixel of the eye; "
        "holes are rows where 1 marks a filled pixel.",
        "eyeWidth": EYE_WIDTH,
        "eyeHeight": EYE_HEIGHT,
        "mapWidth": MAP_WIDTH,
        "mapHeight": MAP_HEIGHT,
        "linkThreshold": LINK_THRESHOLD,
        "dilationWindow": 2 * DILATION_RADIUS + 1,
        "percentiles": [LOW_PERCENTILE, HIGH_PERCENTILE],
        "lowReliefRatio": LOW_RELIEF_RATIO,
        "hiddenAreasRatio": HIDDEN_AREAS_RATIO,
        "darkLuma": DARK_LUMA,
        "cases": cases,
    }


def render(value, indent: int = 0) -> str:
    """JSON with two spaces of indentation, a list of numbers or strings on one line, floats in their shortest exact
    form (repr), so that every reader gets the same doubles"""
    pad = "  " * indent
    inner = "  " * (indent + 1)
    if isinstance(value, dict):
        items = [f"{inner}{json.dumps(key)}: {render(item, indent + 1)}" for key, item in value.items()]
        return "{\n" + ",\n".join(items) + "\n" + pad + "}"
    if isinstance(value, list):
        if all(not isinstance(item, (dict, list)) for item in value):
            return "[" + ", ".join(render(item) for item in value) + "]"
        return "[\n" + ",\n".join(inner + render(item, indent + 1) for item in value) + "\n" + pad + "]"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ValueError("no infinity in the fixture")
        return repr(value)
    return json.dumps(value)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="compare with the fixture instead of writing it")
    args = parser.parse_args()
    text = render(build()) + "\n"
    if args.check:
        current = FIXTURE.read_text(encoding="utf-8") if FIXTURE.exists() else ""
        if current != text:
            print(f"{FIXTURE} differs from what {pathlib.Path(__file__).name} writes: run it and commit the result",
                  file=sys.stderr)
            return 1
        print(f"{FIXTURE.name} is what the script writes")
        return 0
    FIXTURE.parent.mkdir(parents=True, exist_ok=True)
    FIXTURE.write_text(text, encoding="utf-8")
    print(f"wrote {FIXTURE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
