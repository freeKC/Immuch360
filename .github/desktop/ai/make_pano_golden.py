#!/usr/bin/env python3
"""The reference of the panoramas of Immuch360 (pano-v1 and relief-360-v1), and their golden fixture.

The computers make the 360° panorama around a photo (lot P3) and the 3D version of a 360° panorama (lot P1) in Dart;
both must give what this script gives on mobile/test/fixtures/ai_immersive/pano_golden_v1.json: every byte of an
image exactly but for one unit of rounding, the masks exactly, every number within 1e-9. Everything is in double
precision, in the order written below. Design: store/m2/ai-immersive-2026-10-26/phase23/design-final-2026-10-27.md,
sections 4.3 and 4.4.

An equirectangular frame of W x H: the pixel (x, y) looks towards the longitude lon = 2 * pi * ((x + 0.5) / W - 0.5)
(0 at the centre column, positive to the right) and the latitude lat = pi * (0.5 - (y + 0.5) / H) (positive upwards),
the direction (cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon)) in a frame x right, y up, z ahead.

pano-v1:
1. Projection of a photo of w x h with the horizontal field of view hfov, looking at the centre (yaw 0, pitch 0, the
   horizon level): t = tan(hfov / 2), s = t * h / w (tan of half the vertical field). A direction with z > 0 meets
   the plane of the photo at (a, b) = (x / z, y / z), the point u = (a / t + 1) * w / 2, v = (1 - b / s) * h / 2 of
   the photo (pixel edges, 0 at its top left). Inside when 0 <= u <= w and 0 <= v <= h: the colour read in bilinear
   at (u - 0.5, v - 0.5), the edges repeated, each channel rounded as floor(c + 0.5) clamped to [0, 255]. Elsewhere
   pure green (0, 255, 0): the control frame of the LoRA. The vertical field of view is 2 * atan(s).
2. Coverage: the sum of cos(lat) over the pixels inside, over the sum of cos(lat) over every pixel.
3. Roll of half a turn: the pixel x of the rolled frame is the pixel (x + W / 2) mod W of the frame; the seam, at the
   edges, comes to the centre, where it is joined, then the frame rolls back.
4. Pasting back on the output of Wo x Ho: each pixel inside the photo (step 1 at that size) takes
   alpha * photo + (1 - alpha) * generated, alpha = clamp(e / 0.02, 0, 1), e = min(u / w, 1 - u / w, v / h,
   1 - v / h), rounded as in step 1; outside, the generated pixel as it is.

relief-360-v1, the right eye of a 360° panorama (the left eye is the panorama itself):
5. d is the disparity map of the panorama (larger is nearer) normalised as relief-v1 does (its step 1, percentiles 2
   and 98), with its lowRelief flag.
6. Each row y shifts by s(x) = -(W / 360) * m * d(x) * cos(lat(y)) pixels, m the largest shift in degrees (1 for the
   app): the nearest moves left by m degrees at the equator, nothing moves at the poles, and the far stays put
   (convergence at infinity).
7. Forward projection of relief-v1 (its step 5), around the row: t(x) = x + s(x); the pixel alone at
   floor(t + 0.5) mod W; then, when |d(x) - d(x')| <= 0.04 with x' = (x + 1) mod W, the segment to x' over the columns
   ceil(min(t0, t1)) to floor(max(t0, t1)), t1 = t(x') + W when x' = 0, each written at its column mod W. A write
   takes the column only when its d is strictly larger than the one there.
8. Filling around the row: each run of holes, read cyclically, takes the colour of the one of its two written
   neighbours with the smaller d (the left one on a tie); a row with nothing written is black. Then each filled pixel
   becomes the mean of the filled row at x - 1, x, x + 1 (mod W). Rounded as in step 1.
9. hiddenAreas when more than 5 % was filled; refused ("Not enough relief for a comfortable 3D panorama") when the map
   is lowRelief or more than 8 % was filled.

  make_pano_golden.py           writes the fixture
  make_pano_golden.py --check   exit 1 when the fixture differs from what this script writes (a CI step)

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

FIXTURE = pathlib.Path(__file__).resolve().parents[3] / "mobile/test/fixtures/ai_immersive/pano_golden_v1.json"
GREEN = (0, 255, 0)
FEATHER = 0.02
MAX_SHIFT_DEGREES = 1.0
LINK = 0.04
HIDDEN_AREAS_RATIO = 0.05
MAX_FILLED = 0.08


def direction(x: int, y: int, width: int, height: int) -> tuple:
    lon = 2 * math.pi * ((x + 0.5) / width - 0.5)
    lat = math.pi * (0.5 - (y + 0.5) / height)
    return math.cos(lat) * math.sin(lon), math.sin(lat), math.cos(lat) * math.cos(lon), lat


def photo_point(x: int, y: int, width: int, height: int, w: int, h: int, hfov: float):
    """Where the pixel (x, y) of the frame meets the photo: (u, v), or None outside it"""
    dx, dy, dz, _ = direction(x, y, width, height)
    if dz <= 0:
        return None
    t = math.tan(math.radians(hfov) / 2)
    s = t * h / w
    u = (dx / dz / t + 1) * w / 2
    v = (1 - dy / dz / s) * h / 2
    if 0 <= u <= w and 0 <= v <= h:
        return u, v
    return None


def bilinear(photo: list, u: float, v: float) -> list:
    h, w = len(photo), len(photo[0])
    px, py = u - 0.5, v - 0.5
    x0, y0 = math.floor(px), math.floor(py)
    fx, fy = px - x0, py - y0
    left, right = relief.clamp_index(x0, w), relief.clamp_index(x0 + 1, w)
    top, bottom = relief.clamp_index(y0, h), relief.clamp_index(y0 + 1, h)
    out = []
    for k in range(3):
        upper = photo[top][left][k] + (photo[top][right][k] - photo[top][left][k]) * fx
        lower = photo[bottom][left][k] + (photo[bottom][right][k] - photo[bottom][left][k]) * fx
        out.append(upper + (lower - upper) * fy)
    return out


def project(photo: list, hfov: float, width: int, height: int) -> tuple:
    h, w = len(photo), len(photo[0])
    frame, inside_mask = [], []
    covered = total = 0.0
    for y in range(height):
        row, mask = [], []
        for x in range(width):
            lat = direction(x, y, width, height)[3]
            total += math.cos(lat)
            point = photo_point(x, y, width, height, w, h, hfov)
            if point is None:
                row.append(list(GREEN))
                mask.append(False)
            else:
                covered += math.cos(lat)
                row.append([relief.to_byte(c) for c in bilinear(photo, *point)])
                mask.append(True)
        frame.append(row)
        inside_mask.append(mask)
    return frame, inside_mask, covered / total


def roll(frame: list) -> list:
    width = len(frame[0])
    return [[row[(x + width // 2) % width] for x in range(width)] for row in frame]


def paste_back(generated: list, photo: list, hfov: float) -> list:
    height, width = len(generated), len(generated[0])
    h, w = len(photo), len(photo[0])
    out = []
    for y in range(height):
        row = []
        for x in range(width):
            point = photo_point(x, y, width, height, w, h, hfov)
            if point is None:
                row.append(list(generated[y][x]))
                continue
            u, v = point
            edge = min(u / w, 1 - u / w, v / h, 1 - v / h)
            alpha = min(1.0, max(0.0, edge / FEATHER))
            sample = bilinear(photo, u, v)
            row.append([relief.to_byte(alpha * sample[k] + (1 - alpha) * generated[y][x][k]) for k in range(3)])
        out.append(row)
    return out


def right_eye_row(pixels: list, d: list, shifts: list) -> tuple:
    width = len(pixels)
    t = [x + shifts[x] for x in range(width)]
    depth = [-math.inf] * width
    colour = [None] * width

    def put(column: int, dd: float, rgb: list) -> None:
        column %= width
        if dd > depth[column]:
            depth[column] = dd
            colour[column] = rgb

    for x in range(width):
        put(math.floor(t[x] + 0.5), d[x], [float(c) for c in pixels[x]])
        nxt = (x + 1) % width
        if abs(d[x] - d[nxt]) <= LINK:
            t0 = t[x]
            t1 = t[nxt] + (width if nxt == 0 else 0)
            for column in range(math.ceil(min(t0, t1)), math.floor(max(t0, t1)) + 1):
                a = (column - t0) / (t1 - t0) if t1 != t0 else 0.0
                put(column, d[x] + (d[nxt] - d[x]) * a,
                    [pixels[x][k] + (pixels[nxt][k] - pixels[x][k]) * a for k in range(3)])
    holes = [c is None for c in colour]
    filled = [list(c) if c is not None else [0.0, 0.0, 0.0] for c in colour]
    if all(holes):
        return [[0.0, 0.0, 0.0] for _ in range(width)], holes
    start = next(x for x in range(width) if not holes[x])
    x = 0
    while x < width:
        column = (start + x) % width
        if not holes[column]:
            x += 1
            continue
        run_start = x
        while x < width and holes[(start + x) % width]:
            x += 1
        left = (start + run_start - 1) % width
        right = (start + x) % width
        source = left if depth[left] <= depth[right] else right
        for k in range(run_start, x):
            filled[(start + k) % width] = list(filled[source])
    out = [list(c) for c in filled]
    for x in range(width):
        if holes[x]:
            before, after = filled[(x - 1) % width], filled[(x + 1) % width]
            out[x] = [(before[k] + filled[x][k] + after[k]) / 3 for k in range(3)]
    return out, holes


def relief_360(image: list, disparity: list, max_shift: float) -> dict:
    height, width = len(image), len(image[0])
    d, p2, p98, low_relief = relief.normalise(disparity)
    right_eye, holes, filled = [], [], 0
    for y in range(height):
        lat = math.pi * (0.5 - (y + 0.5) / height)
        shifts = [-(width / 360) * max_shift * d[y][x] * math.cos(lat) for x in range(width)]
        row, row_holes = right_eye_row(image[y], d[y], shifts)
        right_eye.append([relief.to_byte(c) for pixel in row for c in pixel])
        holes.append("".join("1" if hole else "0" for hole in row_holes))
        filled += sum(row_holes)
    fraction = filled / (width * height)
    flags = []
    if low_relief:
        flags.append("lowRelief")
    if fraction > HIDDEN_AREAS_RATIO:
        flags.append("hiddenAreas")
    return {"p2": p2, "p98": p98, "normalized": d, "rightEye": right_eye, "holes": holes, "filledPixels": filled,
            "filledFraction": fraction, "refused": low_relief or fraction > MAX_FILLED, "flags": flags}


# --- The cases ----------------------------------------------------------------------------------------------------

FRAME_WIDTH = 48
FRAME_HEIGHT = 24


def photo(width: int, height: int) -> list:
    return [[[(23 * x + 7 * y) % 256, (11 * x * y + 60) % 256, (200 - 9 * x - 13 * y) % 256] for x in range(width)]
            for y in range(height)]


def generated(width: int, height: int) -> list:
    return [[[(5 * x + 90) % 256, (3 * y + 30) % 256, (x * y) % 256] for x in range(width)] for y in range(height)]


def panorama_image() -> list:
    return [[[(13 * x + 5 * y) % 256, (7 * x + 40) % 256, (255 - 11 * y) % 256] for x in range(FRAME_WIDTH)]
            for y in range(FRAME_HEIGHT)]


def object_across_seam() -> list:
    """A far room (1) with a near object (9) that crosses the seam, columns 44 to 3, rows 8 to 16"""
    return [[9.0 if (x >= 44 or x <= 3) and 8 <= y <= 16 else 1.0 + 0.02 * y for x in range(FRAME_WIDTH)]
            for y in range(FRAME_HEIGHT)]


def object_and_pillar() -> list:
    """The same room and object, with a near pillar too, columns 22 to 27, rows 4 to 19"""
    return [[9.0 if 22 <= x <= 27 and 4 <= y <= 19 else value for x, value in enumerate(row)]
            for y, row in enumerate(object_across_seam())]


def flat_disparity() -> list:
    return [[4.0] * FRAME_WIDTH for _ in range(FRAME_HEIGHT)]


def projection_case(name: str, description: str, w: int, h: int, hfov: float, out_width: int) -> dict:
    image = photo(w, h)
    frame, inside, coverage = project(image, hfov, FRAME_WIDTH, FRAME_HEIGHT)
    output = generated(out_width, out_width // 2)
    pasted = paste_back(output, image, hfov)
    t = math.tan(math.radians(hfov) / 2)
    return {
        "name": name,
        "description": description,
        "photoWidth": w,
        "photoHeight": h,
        "hfov": hfov,
        "vfov": math.degrees(2 * math.atan(t * h / w)),
        "photo": [[c for pixel in row for c in pixel] for row in image],
        "control": [[c for pixel in row for c in pixel] for row in frame],
        "inside": ["".join("1" if value else "0" for value in row) for row in inside],
        "coverage": coverage,
        "rolled": [[c for pixel in row for c in pixel] for row in roll(frame)],
        "outputWidth": out_width,
        "outputHeight": out_width // 2,
        "generated": [[c for pixel in row for c in pixel] for row in output],
        "pasted": [[c for pixel in row for c in pixel] for row in pasted],
    }


def relief_case(name: str, description: str, disparity_of, max_shift: float) -> dict:
    image = panorama_image()
    disparity = disparity_of()
    return {"name": name, "description": description, "maxShiftDegrees": max_shift,
            "image": [[c for pixel in row for c in pixel] for row in image], "disparity": disparity,
            **relief_360(image, disparity, max_shift)}


def build() -> dict:
    return {
        "about": "Made by .github/desktop/ai/make_pano_golden.py, whose header describes pano-v1 and relief-360-v1. "
        "Images are rows of R, G, B bytes; masks are rows of 0 and 1 (inside: the photo; holes: a filled pixel).",
        "tolerance": 1e-9,
        "frameWidth": FRAME_WIDTH,
        "frameHeight": FRAME_HEIGHT,
        "green": list(GREEN),
        "pasteFeather": FEATHER,
        "maxShiftDegrees": MAX_SHIFT_DEGREES,
        "linkThreshold": LINK,
        "hiddenAreasRatio": HIDDEN_AREAS_RATIO,
        "maxFilled": MAX_FILLED,
        "projections": [
            projection_case("landscape", "a 4:3 photo of 60° across, pasted back at a larger size", 16, 12, 60.0, 64),
            projection_case("portrait", "a 3:4 photo of 40° across, pasted back at the size of the frame", 9, 12, 40.0,
                            48),
        ],
        "reliefs": [
            relief_case("production", "the shift of the app, 1° at the equator: no hole on such a small frame",
                        object_across_seam, MAX_SHIFT_DEGREES),
            relief_case("strong", "a shift of 30° that opens holes beside the object, across the seam",
                        object_across_seam, 30.0),
            relief_case("hidden", "a shift of 60°: between 5 % and 8 % filled, hiddenAreas, still made",
                        object_across_seam, 60.0),
            relief_case("tooMuch", "a shift of 40° with a pillar too: more than 8 % filled, refused",
                        object_and_pillar, 40.0),
            relief_case("flat", "a constant map: lowRelief, refused", flat_disparity, MAX_SHIFT_DEGREES),
        ],
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
