#!/usr/bin/env python3
"""The reference of the frame work of the 3D videos of the computers, and its golden fixture.

A 3D video (store/m2/release-49/lots/video3d-plan.md, sections 2.2 and 4.6) is relief-v1 frame after frame, with four
steps of its own that the Rust of mobile/packages/immuch_sbs_codec (rust/src/video.rs) and the pure Dart references of
mobile/lib/desktop/ai/video3d must give exactly as this script does on
mobile/test/fixtures/ai_immersive/relief_video_golden_v1.json:

1. relief-v1 with external percentiles. The depth of a frame is normalised between p2 and p98 given from outside (the
   job smooths them over time, decay 0.9, reset at each cut), not read on the frame: d = (D - p2) / (p98 - p2) clamped
   to [0, 1], 0.5 everywhere when p98 - p2 <= 0. Then steps 2 to 6 of make_relief_golden.py, imported from it: the
   5 x 5 dilation, the enlargement to the eye, the shift, the forward projection, the filling. The left eye is the
   frame; the right eye goes into the right half of a 2L x H frame of RGB bytes. With p2 and p98 read on the frame
   itself, the right eye is that of a 3D photo of the same picture at relief-v1 (checked below on the production case
   of relief_golden_v1.json).
2. The soft floating window. A band of B = ceil(parallax * L * max(c, 1 - c)) + 2 columns at both edges of each eye
   fades to black: the column k from the edge (k = 0 at the edge) keeps (v * k * 2 + B) // (2 * B) of each channel v,
   so the edge column is black and the column B is untouched. B is fixed for a whole job, and is at most L // 2.
3. Half side by side. Each pair of columns of the 2L x H frame becomes one, (a + b + 1) >> 1 per channel: each eye
   squeezed to half its width (L even).
4. The input of Video Depth Anything. The frame (RGB bytes, w x h) taken to W x H by the cubic of OpenCV's
   INTER_CUBIC (a = -0.75): for an output column X, u = (X + 0.5) * w / W - 0.5, x0 = floor(u), f = u - x0, the four
   columns x0 - 1 to x0 + 2 clamped to the frame (edges repeated), weights
     c0 = ((a (f + 1) - 5 a)(f + 1) + 8 a)(f + 1) - 4 a,  c1 = ((a + 2) f - (a + 3)) f f + 1,
     c2 = ((a + 2)(1 - f) - (a + 3))(1 - f)(1 - f) + 1,    c3 = 1 - c0 - c1 - c2;
   the rows first (each output column of each source row, summed in that order), then the columns, in double
   precision, then floor(v + 0.5) clamped to [0, 255]; then (v / 255 - mean) / std with the ImageNet mean
   (0.485, 0.456, 0.406) and std (0.229, 0.224, 0.225), rounded once to float32, channels first (C, H, W).
5. The histogram of the cut detector. The frame taken to 320 x 180 by area: an output pixel is the mean of the source
   area it covers, each source pixel weighted by the part of it inside (rows first, then columns), floor(v + 0.5);
   then the luma of OpenCV's RGB2GRAY, (R * 4899 + G * 9617 + B * 1868 + 8192) >> 14; then 64 bins of 4 levels, each
   count over 57 600. A cut is a half L1 distance between two frames over 0.15 and over 4 times the median of the last
   15 distances (0.01 at least), the median of an even count being the mean of its two middle values.

  make_relief_video_golden.py           writes the fixture
  make_relief_video_golden.py --check   exit 1 when the fixture differs from what this script writes (a CI step)

Pure Python 3, no package.
"""
from __future__ import annotations

import argparse
import math
import pathlib
import struct
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import make_relief_golden as photo  # noqa: E402

FIXTURE = pathlib.Path(__file__).resolve().parents[3] / "mobile/test/fixtures/ai_immersive/relief_video_golden_v1.json"
PHOTO_FIXTURE = photo.FIXTURE

PIPELINE = "relief-v1-video"
MEAN = (0.485, 0.456, 0.406)
STD = (0.229, 0.224, 0.225)
CUBIC_A = -0.75
HIST_WIDTH = 320
HIST_HEIGHT = 180
HIST_BINS = 64
CUT_FLOOR = 0.15
CUT_RATIO = 4.0
CUT_HISTORY = 15
CUT_MEDIAN_FLOOR = 0.01


def f32(value: float) -> float:
    return struct.unpack("<f", struct.pack("<f", value))[0]


# --- 1 to 3: the side by side frame -------------------------------------------------------------------------------


def normalise_with(depth: list[list[float]], p2: float, p98: float) -> list[list[float]]:
    spread = p98 - p2
    if spread <= 0:
        return [[0.5 for _ in row] for row in depth]
    return [[min(1.0, max(0.0, (value - p2) / spread)) for value in row] for row in depth]


def edge_band(parallax: float, width: int, convergence: float) -> int:
    return min(width // 2, math.ceil(parallax * width * max(convergence, 1 - convergence)) + 2)


def fade(value: int, k: int, band: int) -> int:
    return (value * k * 2 + band) // (2 * band)


def sbs_frame(image, depth, p2, p98, parallax, convergence, band):
    """The 2L x H frame (rows of R, G, B bytes), the mask of the holes of the right eye, its count"""
    height = len(image)
    width = len(image[0])
    eye_depth = photo.enlarge(photo.dilate(normalise_with(depth, p2, p98)), width, height)
    rows = []
    holes = []
    filled = 0
    for y in range(height):
        right, row_holes = photo.right_eye_row(image[y], eye_depth[y], parallax, convergence)
        left = [list(pixel) for pixel in image[y]]
        right = [[photo.to_byte(channel) for channel in pixel] for pixel in right]
        for eye in (left, right):
            for k in range(band):
                for column in (k, width - 1 - k):
                    eye[column] = [fade(v, k, band) for v in eye[column]]
        rows.append([channel for pixel in left + right for channel in pixel])
        holes.append("".join("1" if hole else "0" for hole in row_holes))
        filled += sum(row_holes)
    return rows, holes, filled


def half(rows: list[list[int]]) -> list[list[int]]:
    out = []
    for row in rows:
        pixels = len(row) // 3
        out.append([(row[6 * x + k] + row[6 * x + 3 + k] + 1) >> 1 for x in range(pixels // 2) for k in range(3)])
    return out


# --- 4: the input of the model ------------------------------------------------------------------------------------


def cubic_weights(f: float) -> tuple[float, float, float, float]:
    a = CUBIC_A
    c0 = ((a * (f + 1) - 5 * a) * (f + 1) + 8 * a) * (f + 1) - 4 * a
    c1 = ((a + 2) * f - (a + 3)) * f * f + 1
    c2 = ((a + 2) * (1 - f) - (a + 3)) * (1 - f) * (1 - f) + 1
    return c0, c1, c2, 1 - c0 - c1 - c2


def taps(size_in: int, size_out: int) -> list[tuple[list[int], tuple[float, float, float, float]]]:
    out = []
    for x in range(size_out):
        u = (x + 0.5) * size_in / size_out - 0.5
        x0 = math.floor(u)
        weights = cubic_weights(u - x0)
        out.append(([min(size_in - 1, max(0, x0 - 1 + i)) for i in range(4)], weights))
    return out


def vda_input(image: list[list[list[int]]], width: int, height: int) -> list[float]:
    h = len(image)
    w = len(image[0])
    across = taps(w, width)
    down = taps(h, height)
    rows = []
    for y in range(h):
        row = []
        for columns, weights in across:
            rgb = []
            for k in range(3):
                # Added one after the other, never with sum(): from Python 3.12 it compensates the rounding of floats
                value = 0.0
                for i in range(4):
                    value += image[y][columns[i]][k] * weights[i]
                rgb.append(value)
            row.append(rgb)
        rows.append(row)
    out = [0.0] * (3 * width * height)
    for y, (sources, weights) in enumerate(down):
        for x in range(width):
            for k in range(3):
                value = 0.0
                for i in range(4):
                    value += rows[sources[i]][x][k] * weights[i]
                byte = min(255, max(0, math.floor(value + 0.5)))
                out[k * width * height + y * width + x] = f32((byte / 255.0 - MEAN[k]) / STD[k])
    return out


# --- 5: the cut detector --------------------------------------------------------------------------------------------


def area_spans(size_in: int, size_out: int) -> list[list[tuple[int, float]]]:
    scale = size_in / size_out
    spans = []
    for x in range(size_out):
        start = x * scale
        end = (x + 1) * scale
        span = []
        i = math.floor(start)
        while i < end and i < size_in:
            weight = min(end, i + 1) - max(start, i)
            if weight > 0:
                span.append((i, weight))
            i += 1
        spans.append(span)
    return spans


def luma_hist(image: list[list[list[int]]]) -> list[float]:
    h = len(image)
    w = len(image[0])
    across = area_spans(w, HIST_WIDTH)
    down = area_spans(h, HIST_HEIGHT)
    rows = []
    for y in range(h):
        row = []
        for span in across:
            rgb = []
            for k in range(3):
                value = 0.0
                for i, weight in span:
                    value += image[y][i][k] * weight
                rgb.append(value)
            row.append(rgb)
        rows.append(row)
    counts = [0] * HIST_BINS
    area = (w / HIST_WIDTH) * (h / HIST_HEIGHT)
    for span in down:
        for x in range(HIST_WIDTH):
            rgb = []
            for k in range(3):
                value = 0.0
                for i, weight in span:
                    value += rows[i][x][k] * weight
                rgb.append(min(255, max(0, math.floor(value / area + 0.5))))
            luma = (rgb[0] * 4899 + rgb[1] * 9617 + rgb[2] * 1868 + 8192) >> 14
            counts[luma >> 2] += 1
    return [count / (HIST_WIDTH * HIST_HEIGHT) for count in counts]


def median(values: list[float]) -> float:
    ordered = sorted(values)
    n = len(ordered)
    return ordered[n // 2] if n % 2 else (ordered[n // 2 - 1] + ordered[n // 2]) / 2


def cuts(distances: list[float]) -> list[int]:
    """The indices of the distances flagged as cuts, each distance going into the history after its test"""
    history: list[float] = []
    flagged = []
    for index, distance in enumerate(distances):
        recent = history[-CUT_HISTORY:] or [0.0]
        if distance > CUT_FLOOR and distance > CUT_RATIO * max(median(recent), CUT_MEDIAN_FLOOR):
            flagged.append(index)
        history.append(distance)
    return flagged


# --- The cases ----------------------------------------------------------------------------------------------------


def pattern(width: int, height: int, seed: int) -> list[list[list[int]]]:
    """A picture of integers only, the same in every language: (17 x + 3 y y + seed) and two others, modulo 256"""
    return [
        [[(17 * x + 3 * y * y + seed) % 256, (5 * x * y + 40 + seed) % 256, (255 - 7 * x - 11 * y + 3 * seed) % 256]
         for x in range(width)]
        for y in range(height)
    ]


RELIEF_CASES = [
    # name, description, depth, p2, p98, parallax, convergence, fade
    ("normal", "Normal (2 %), percentiles of the job inside the map's own, no fade", photo.scene_depth, 1.5, 5.0,
     0.02, 0.5, False),
    ("subtleFaded", "Subtle (1.5 %), the job's percentiles, the floating window of the job", photo.scene_depth, 1.0,
     9.0, 0.015, 0.5, True),
    ("strongWide", "Strong (3 %) with a parallax of 25 %, percentiles wider than the map, the floating window",
     photo.scene_depth, -4.0, 12.0, 0.25, 0.5, True),
    ("flat", "p98 - p2 = 0: d = 0.5 everywhere", photo.constant_depth, 3.0, 3.0, 0.25, 0.4, True),
]


def build() -> dict:
    image = photo.pattern_image()
    relief = []
    for name, description, depth_of, p2, p98, parallax, convergence, faded in RELIEF_CASES:
        depth = depth_of()
        band = edge_band(parallax, photo.EYE_WIDTH, convergence) if faded else 0
        rows, holes, filled = sbs_frame(image, depth, p2, p98, parallax, convergence, band)
        relief.append({
            "name": name,
            "description": description,
            "parallax": parallax,
            "convergence": convergence,
            "p2": p2,
            "p98": p98,
            "edgeBand": band,
            "depth": depth,
            "sbs": rows,
            "halfSbs": half(rows),
            "holes": holes,
            "filledPixels": filled,
        })

    # A frame of a 3D video, its percentiles read on itself and no fade, is the 3D photo of the same picture
    photo_case = photo.relief_v1(image, photo.scene_depth(), 0.02, 0.5)
    rows, _, _ = sbs_frame(image, photo.scene_depth(), photo_case["p2"], photo_case["p98"], 0.02, 0.5, 0)
    assert [row[3 * photo.EYE_WIDTH:] for row in rows] == photo_case["rightEye"], "the video frame left relief-v1"

    vda = []
    for name, (w, h, seed), (width, height) in [
        ("down", (64, 36, 0), (28, 14)),
        ("up", (20, 12, 7), (42, 28)),
        ("odd", (37, 23, 3), (14, 28)),
    ]:
        vda.append({"name": name, "source": [w, h, seed], "size": [width, height],
                    "values": vda_input(pattern(w, h, seed), width, height)})

    hist = []
    for name, (w, h, seed) in [("half", (640, 360, 0)), ("odd", (500, 300, 11)), ("same", (320, 180, 5))]:
        hist.append({"name": name, "source": [w, h, seed], "histogram": luma_hist(pattern(w, h, seed))})

    # The distances of the study's detect.log: ped then lake (the cut at 0.33), the three clips without a cut at most
    # 0.048, and a rhythm of flashes
    distances = [0.01, 0.02, 0.015, 0.012, 0.018, 0.33, 0.02, 0.025, 0.048, 0.03, 0.2, 0.21, 0.19, 0.22, 0.2]
    detector = {"distances": distances, "cuts": cuts(distances)}

    bands = [{"parallax": parallax, "width": width, "convergence": c, "band": edge_band(parallax, width, c)}
             for parallax, width, c in [(0.015, 1920, 0.5), (0.02, 1920, 0.5), (0.03, 1920, 0.5), (0.02, 1080, 0.5),
                                        (0.25, 32, 0.4), (0.9, 8, 0.5)]]

    return {
        "pipeline": PIPELINE,
        "about": "Made by .github/desktop/ai/make_relief_video_golden.py, whose header describes each step. The image "
        "of the relief cases is the pattern of relief_golden_v1.json (32 x 8); sbs and halfSbs are rows of R, G, B "
        "bytes of the whole frame; holes are rows of the right eye where 1 marks a filled pixel. The vdaInput and "
        "lumaHistogram cases name their source picture by width, height and seed (pattern() of the script) and give "
        "float32 values, channels first.",
        "mean": list(MEAN),
        "std": list(STD),
        "cubicA": CUBIC_A,
        "histogramSize": [HIST_WIDTH, HIST_HEIGHT],
        "cutFloor": CUT_FLOOR,
        "cutRatio": CUT_RATIO,
        "cutHistory": CUT_HISTORY,
        "relief": relief,
        "vdaInput": vda,
        "lumaHistogram": hist,
        "detector": detector,
        "edgeBands": bands,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="compare with the fixture instead of writing it")
    args = parser.parse_args()
    text = photo.render(build()) + "\n"
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
