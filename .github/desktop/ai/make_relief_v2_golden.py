#!/usr/bin/env python3
"""The reference of relief-v2 without MI-GAN, the right eye a computer makes since release 46, and its golden fixture.

relief-v2 is relief-v1 (make_relief_golden.py, whose steps 1 and 4 to 7 it keeps) with another way to read the depth at
each pixel of the eye: steps 2 and 3 of relief-v1 (dilation, bilinear enlargement) become a joint bilateral upsampling
guided by the photo. The Dart of the computers (lib/desktop/ai/relief/relief_v2.dart) must give what this script gives
on mobile/test/fixtures/ai_immersive/relief_golden_v2.json: d at each pixel within 1e-9, each channel of the right eye
within one unit, the mask of the holes exactly. The fill by MI-GAN, a model, is tested on synthetic images in Dart.

For a photo of L x H pixels and the normalised map d of w x h values (step 1 of relief-v1, not dilated):

a. The guide: the cell of the column x of the eye is min(w - 1, (x * w + w // 2) // L), that of the row y
   min(h - 1, (y * h + h // 2) // H); each sample of the map takes the mean colour of the eye pixels of its cell (each
   channel summed pixel after pixel, row after row, divided by their number, rounded as floor(v + 0.5)); a cell with no
   pixel takes the pixel (min(L - 1, floor((i + 0.5) * L / w)), min(H - 1, floor((j + 0.5) * H / h))).
b. The weights: the distance weight of a sample at the column k for the pixel x is g(u - k), u = (x + 0.5) * w / L - 0.5,
   g(t) = exp(-t * t / (2 * 1.0 * 1.0)), the same along the rows with v; the colour weight is
   exp(-(dr^2 + dg^2 + db^2) / (2 * 16.0 * 16.0)) + 0.0001, the differences between the pixel and the guide of the
   sample, the small constant keeping a mean by distance where no sample looks like the pixel.
c. The depth of the pixel: over the 4 x 4 samples of the columns floor(u) - 1 to floor(u) + 2 and the rows floor(v) - 1
   to floor(v) + 2 (each clamped to the map, weighted by its unclamped distance), rows then columns, the weight
   wy * wx * wc, d = sum(weight * d) / sum(weight).

  make_relief_v2_golden.py           writes the fixture
  make_relief_v2_golden.py --check   exit 1 when the fixture differs from what this script writes (a CI step)

Pure Python 3, no package.
"""
from __future__ import annotations

import argparse
import math
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import make_relief_golden as v1  # noqa: E402

FIXTURE = pathlib.Path(__file__).resolve().parents[3] / "mobile/test/fixtures/ai_immersive/relief_golden_v2.json"

PIPELINE = "relief-v2"
RANGE_SIGMA = 16.0
SPATIAL_SIGMA = 1.0
RANGE_FLOOR = 0.0001


def gauss(distance: float, sigma: float) -> float:
    return math.exp(-distance * distance / (2 * sigma * sigma))


def guide_of(image: list[list[list[int]]], w: int, h: int) -> list[list[list[int]]]:
    height = len(image)
    width = len(image[0])
    sums = [[[0.0, 0.0, 0.0] for _ in range(w)] for _ in range(h)]
    counts = [[0] * w for _ in range(h)]
    for y in range(height):
        j = min(h - 1, (y * h + h // 2) // height)
        for x in range(width):
            i = min(w - 1, (x * w + w // 2) // width)
            for c in range(3):
                sums[j][i][c] += image[y][x][c]
            counts[j][i] += 1
    guide = []
    for j in range(h):
        row = []
        for i in range(w):
            if counts[j][i] > 0:
                row.append([math.floor(sums[j][i][c] / counts[j][i] + 0.5) for c in range(3)])
            else:
                x = min(width - 1, math.floor((i + 0.5) * width / w))
                y = min(height - 1, math.floor((j + 0.5) * height / h))
                row.append(list(image[y][x]))
        guide.append(row)
    return guide


def guided(d: list[list[float]], image: list[list[list[int]]]) -> list[list[float]]:
    h = len(d)
    w = len(d[0])
    height = len(image)
    width = len(image[0])
    guide = guide_of(image, w, h)
    two_sigma2 = 2 * RANGE_SIGMA * RANGE_SIGMA
    out = []
    for y in range(height):
        v = (y + 0.5) * h / height - 0.5
        first_row = math.floor(v) - 1
        rows = [(v1.clamp_index(first_row + k, h), gauss(v - (first_row + k), SPATIAL_SIGMA)) for k in range(4)]
        row_out = []
        for x in range(width):
            u = (x + 0.5) * w / width - 0.5
            first_column = math.floor(u) - 1
            columns = [
                (v1.clamp_index(first_column + k, w), gauss(u - (first_column + k), SPATIAL_SIGMA)) for k in range(4)
            ]
            r, g, b = image[y][x]
            total = 0.0
            weight = 0.0
            for j, wy in rows:
                for i, wx in columns:
                    sample = guide[j][i]
                    dr = r - sample[0]
                    dg = g - sample[1]
                    db = b - sample[2]
                    wc = math.exp(-(dr * dr + dg * dg + db * db) / two_sigma2) + RANGE_FLOOR
                    wt = wy * wx * wc
                    total += wt * d[j][i]
                    weight += wt
            row_out.append(total / weight)
        out.append(row_out)
    return out


def relief_v2(image: list[list[list[int]]], depth: list[list[float]], parallax: float, convergence: float) -> dict:
    height = len(image)
    width = len(image[0])
    normalised, p2, p98, low_relief = v1.normalise(depth)
    eye_depth = guided(normalised, image)
    right_eye = []
    holes = []
    filled = 0
    for y in range(height):
        row, row_holes = v1.right_eye_row(image[y], eye_depth[y], parallax, convergence)
        right_eye.append([v1.to_byte(channel) for pixel in row for channel in pixel])
        holes.append("".join("1" if hole else "0" for hole in row_holes))
        filled += sum(row_holes)
    total = 0.0
    for row in image:
        for r, g, b in row:
            total += 0.2126 * r + 0.7152 * g + 0.0722 * b
    luma = total / (width * height)
    flags = []
    if low_relief:
        flags.append("lowRelief")
    if filled > v1.HIDDEN_AREAS_RATIO * width * height:
        flags.append("hiddenAreas")
    if luma < v1.DARK_LUMA:
        flags.append("dark")
    return {
        "p2": p2,
        "p98": p98,
        "normalized": normalised,
        "eyeDepth": eye_depth,
        "rightEye": right_eye,
        "holes": holes,
        "filledPixels": filled,
        "meanLuma": luma,
        "flags": flags,
    }


def edge_image() -> list[list[list[int]]]:
    """A dark object on the left of the column 13, a light background with a little texture on its right"""
    return [
        [[30, 30, 30] if x < 13 else [200 + (x * 7 + y * 3) % 20, 210, 220] for x in range(v1.EYE_WIDTH)]
        for y in range(v1.EYE_HEIGHT)
    ]


def edge_depth() -> list[list[float]]:
    """The soft ramp Depth Anything draws around the edge of the object"""
    ramp = [1.0, 1.0, 1.0, 1.0, 1.0, 0.95, 0.7, 0.35, 0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
    return [list(ramp) for _ in range(v1.MAP_HEIGHT)]


CASES = [
    *v1.CASES,
    ("edge", "a soft ramp of the model at a sharp edge of the photo: the jump falls on the edge", edge_image, edge_depth,
     0.25, 0.5),
]


def build() -> dict:
    cases = []
    for name, description, image_of, depth_of, parallax, convergence in CASES:
        image = image_of()
        depth = depth_of()
        cases.append(
            {
                "name": name,
                "description": description,
                "parallax": parallax,
                "convergence": convergence,
                "image": [[channel for pixel in row for channel in pixel] for row in image],
                "depth": depth,
                **relief_v2(image, depth, parallax, convergence),
            }
        )
    return {
        "pipeline": PIPELINE,
        "about": "Made by .github/desktop/ai/make_relief_v2_golden.py, whose header describes relief-v2 without MI-GAN. "
        "Images are rows of R, G, B bytes; depth and normalized are rows of the map; eyeDepth is d at each pixel of "
        "the eye; holes are rows where 1 marks a filled pixel.",
        "eyeWidth": v1.EYE_WIDTH,
        "eyeHeight": v1.EYE_HEIGHT,
        "mapWidth": v1.MAP_WIDTH,
        "mapHeight": v1.MAP_HEIGHT,
        "rangeSigma": RANGE_SIGMA,
        "spatialSigma": SPATIAL_SIGMA,
        "cases": cases,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="compare with the fixture instead of writing it")
    args = parser.parse_args()
    text = v1.render(build()) + "\n"
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
