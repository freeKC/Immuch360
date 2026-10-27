#!/usr/bin/env python3
"""The reference of scene-v1, the 3D scene Immuch360 makes from one photo, and its golden fixture.

The computers build the scene in Dart (lib/desktop/ai/scene, lot S1) and the Meta Quest moves in it in Kotlin
(SceneNavigator.kt, lot S2). Both must give what this script gives on mobile/test/fixtures/ai_immersive/
scene_golden_v1.json: the masks exactly, every number within 1e-9 of it (relative to the larger of 1 and the value).
Everything is in double precision, in the order written below. Design: store/m2/ai-immersive-2026-10-26/phase23/
design-final-2026-10-27.md, sections 2.3, 2.4 and 3.4. The geometry of the model (MoGe-2) and its focal length and
shift are upstream: the input here is the metric depth z of a map of W x H values (z after the shift and the metric
scale, in metres), the mask of the model, and the focal length f of the map in pixels (see make_focal_shift_golden.py).

scene-v1, as far as both sides must agree:

1. Sky. A value whose mask is under 0.5 has no depth: it goes on a far plane at clamp(2 * p99, 20, 200) m, p99 the
   percentile 99 of the valid depths (the percentile by nearest rank of relief-v1: the value of rank
   max(1, (P * N + 99) // 100) of the N sorted values). The flag sky when more than 15 % of the values are such. A
   map without a valid value is all on the plane at 20 m.
2. Comfort. p2, the percentile 2 of every depth; scale = 0.45 / p2 when p2 < 0.45, else 1; every depth is multiplied
   by scale. A scaling around the eye does not change the view from the start: only the stereo, the parallax and the
   size of the zone.
3. Disparity. q = 1 / z (1/m); d = q normalised as relief-v1 does (its step 1, percentiles 2 and 98, d = 0.5
   everywhere when they are equal), and the flag lowRelief by its rule.
4. Breaks. Two neighbours of the map, side by side or one above the other, break when |d(a) - d(b)| > 0.04 (the rule
   of relief-v1). The jump is |d(a) - d(b)|; the near one has the larger d, the far one the smaller.
5. Grid, as ReliefMesh, at the step s of the map. columns = (W + s // 2) // s + 1 and rows = (H + s // 2) // s + 1
   (at least 2): 257 x 193 for a map of 1024 x 768 at 4. The step is 4, or the smallest integer step from 4 for which
   columns * rows is at most 50 000 (the decision of M2): 4 for the 4:3, 3:2, 16:9 and 3:1 maps of 1024, 5 for a square
   one (257 x 257 = 66 049 at 4, over the 65 535 vertices of a mesh), the same both ways round. It is written in
   Immuch360:GridStep and in the key of the settings. The small maps of the cases below never reach 50 000 vertices:
   gridSteps holds the rule on real sizes, and the case "square" is built at the step of a square photo. The vertex
   (i, j) shows the point (i / (columns - 1), j / (rows - 1)) of the photo from its top left corner (its uv); its map
   coordinates are x = i / (columns - 1) * W - 0.5 and y = j / (rows - 1) * H - 0.5 (the centres of the values), where
   q is read in bilinear, the edges repeated (the enlargement of relief-v1, step 3); its depth is z = 1 / q. Its
   position in the frame of the camera (glTF: x right, y up, looking towards -z):
   X = (u - W / 2) * z / f, Y = (H / 2 - v) * z / f, Z = -z, with u = i / (columns - 1) * W and v = j / (rows - 1) * H.
6. Cells. The cell (i, j) covers the values from column clamp(floor(x_i)) to clamp(ceil(x_(i+1))) and from row
   clamp(floor(y_j)) to clamp(ceil(y_(j+1))) (clamped to the map); it is cut when two neighbours both within it break.
   A kept cell gives the triangles (a, c, b) and (b, c, d) of the near layer, a = (i, j), b = (i + 1, j),
   c = (i, j + 1), d = (i + 1, j + 1): counter clockwise as the camera sees them.
7. Bands. Each break of jump J between its near value n and its far value g has a band of
   w = clamp(floor(160 * J + 0.5), 8, 48) values: the values p on the near side, nearer than the middle of the jump
   (d(p) > (d(n) + d(g)) / 2), whose distance to n, sqrt(dx * dx + dy * dy), is at most w. The mask of the filling is
   the same with 2 * w: LaMa fills the pixels the near side may hide, so that it continues the background (M2 chose
   LaMa for every band; MI-GAN only joins the seam of a panorama). The flag hiddenAreas when the band covers more than
   8 % of the map.
8. Depth behind a band. Each value of the band takes the depth z of the nearest far value of a break (the smallest
   squared distance, the first in the order of the rows then of the columns on a tie), then the mean of those depths
   over the values of the band within its 5 x 5 window.
9. Zone, in metres. For each break, the step aside that keeps it covered is w / (f * (q(n) - q(g))); lateral is the
   percentile 10 of these (one per break: a longer break counts more), clamped to [0.10, 0.50], 0.50 without a break;
   vertical = 0.6 * lateral; forward = 0.35 * p5 of the depths, clamped to [0.10, 1.00]; backward = 0.5 * lateral,
   clamped to [0.05, 0.25]. The flag smallZone when lateral < 0.12. Flags in the order lowRelief, hiddenAreas, sky,
   smallZone.
10. Edge, in the headset. With the eye at (x, y, z) from where it started (the frame of the camera), rho =
    sqrt((x / lateral)^2 + (y / vertical)^2 + (z / r)^2), r = forward when z < 0 (towards the scene), backward
    otherwise. The layers flatten by a = smooth((rho - 1) / 0.5) and darken by 0.95 * smooth((rho - 1.25) / 0.25),
    smooth(t) = t * t * (3 - 2 * t) with t clamped to [0, 1] (the curve of ReliefMesh, without plateaus). A vertex at
    depth z (its -Z) slides on its ray to the depth (1 - a) * z + a * plane, plane the median depth of the vertices of
    the kept cells (the lower middle one of an even count) for the near layer, plane + 0.01 for the background: the
    position times that depth over z. The meshes are made again when a moved by 0.02.

  make_scene_golden.py           writes the fixture
  make_scene_golden.py --check   exit 1 when the fixture differs from what this script writes (a CI step)

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

FIXTURE = pathlib.Path(__file__).resolve().parents[3] / "mobile/test/fixtures/ai_immersive/scene_golden_v1.json"

PIPELINE = "scene-v1"
GRID_STEP = 4
MAX_GRID_VERTICES = 50000
BREAK = 0.04
VALID_MASK = 0.5
SKY_PERCENTILE = 99
SKY_NEAREST = 20.0
SKY_FARTHEST = 200.0
SKY_RATIO = 0.15
COMFORT_DISTANCE = 0.45
COMFORT_PERCENTILE = 2
BAND_FACTOR = 160.0
BAND_MIN = 8
BAND_MAX = 48
BAND_SMOOTHING = 5
INPAINT_FACTOR = 2
HIDDEN_AREAS_RATIO = 0.08
ZONE_PERCENTILE = 10
LATERAL = (0.10, 0.50)
VERTICAL_SHARE = 0.6
FORWARD_PERCENTILE = 5
FORWARD_SHARE = 0.35
FORWARD = (0.10, 1.00)
BACKWARD_SHARE = 0.5
BACKWARD = (0.05, 0.25)
SMALL_ZONE = 0.12
FLATTEN = (1.0, 1.5)
DARKEN_FROM = 1.25
DARKEN_MAX = 0.95
FLAT_BACKGROUND = 0.01
FLATTEN_STEP = 0.02


def clamp(value: float, low: float, high: float) -> float:
    return min(high, max(low, value))


def sky(z: list, mask: list) -> tuple:
    valid = sorted(value for row, row_mask in zip(z, mask) for value, m in zip(row, row_mask) if m >= VALID_MASK)
    count = sum(1 for row in mask for m in row if m < VALID_MASK)
    far = clamp(2 * relief.percentile(valid, SKY_PERCENTILE), SKY_NEAREST, SKY_FARTHEST) if valid else SKY_NEAREST
    out = [[value if m >= VALID_MASK else far for value, m in zip(row, row_mask)] for row, row_mask in zip(z, mask)]
    return out, far, count > SKY_RATIO * len(z) * len(z[0])


def comfort(z: list) -> tuple:
    p2 = relief.percentile(sorted(value for row in z for value in row), COMFORT_PERCENTILE)
    scale = COMFORT_DISTANCE / p2 if p2 < COMFORT_DISTANCE else 1.0
    return [[value * scale for value in row] for row in z], scale


def breaks(d: list) -> list:
    """Every break: (near (x, y), far (x, y), jump), along the rows then down the columns, in the order of the map"""
    height, width = len(d), len(d[0])
    found = []
    for y in range(height):
        for x in range(width):
            for nx, ny in ((x + 1, y), (x, y + 1)):
                if nx < width and ny < height:
                    jump = abs(d[y][x] - d[ny][nx])
                    if jump > BREAK:
                        near, far = ((x, y), (nx, ny)) if d[y][x] > d[ny][nx] else ((nx, ny), (x, y))
                        found.append((near, far, jump))
    return found


def band_width(jump: float) -> int:
    return int(clamp(math.floor(BAND_FACTOR * jump + 0.5), BAND_MIN, BAND_MAX))


def bands(d: list, found: list, factor: int) -> list:
    """The values on the near side of a break within factor * w of its near value"""
    height, width = len(d), len(d[0])
    mask = [[False] * width for _ in range(height)]
    for (nx, ny), (gx, gy), jump in found:
        reach = factor * band_width(jump)
        middle = (d[ny][nx] + d[gy][gx]) / 2
        for y in range(max(0, ny - reach), min(height - 1, ny + reach) + 1):
            for x in range(max(0, nx - reach), min(width - 1, nx + reach) + 1):
                if (x - nx) ** 2 + (y - ny) ** 2 <= reach * reach and d[y][x] > middle:
                    mask[y][x] = True
    return mask


def depth_behind(z: list, band: list, found: list) -> list:
    """The depth behind each value of the band (None elsewhere): that of the nearest far value, then the 5 x 5 mean"""
    height, width = len(z), len(z[0])
    fars = sorted({far for _, far, _ in found}, key=lambda point: (point[1], point[0]))
    raw = [[None] * width for _ in range(height)]
    for y in range(height):
        for x in range(width):
            if band[y][x]:
                best = None
                for fx, fy in fars:
                    distance = (fx - x) ** 2 + (fy - y) ** 2
                    if best is None or distance < best[0]:
                        best = (distance, z[fy][fx])
                raw[y][x] = best[1]
    radius = BAND_SMOOTHING // 2
    smooth = [[None] * width for _ in range(height)]
    for y in range(height):
        for x in range(width):
            if band[y][x]:
                total, count = 0.0, 0
                for yy in range(max(0, y - radius), min(height - 1, y + radius) + 1):
                    for xx in range(max(0, x - radius), min(width - 1, x + radius) + 1):
                        if band[yy][xx]:
                            total += raw[yy][xx]
                            count += 1
                smooth[y][x] = total / count
    return smooth


def grid_lines(length: int, step: int) -> int:
    return max(2, (length + step // 2) // step + 1)


def grid_step(width: int, height: int) -> int:
    """The step of the grid of a map of width x height: 4, or the smallest step above whose grid fits the budget"""
    step = GRID_STEP
    while grid_lines(width, step) * grid_lines(height, step) > MAX_GRID_VERTICES:
        step += 1
    return step


def grid(q: list, f: float, step: int) -> tuple:
    height, width = len(q), len(q[0])
    columns = grid_lines(width, step)
    rows = grid_lines(height, step)
    xs = [i / (columns - 1) * width - 0.5 for i in range(columns)]
    ys = [j / (rows - 1) * height - 0.5 for j in range(rows)]
    vertices = []
    for j in range(rows):
        y0 = math.floor(ys[j])
        fy = ys[j] - y0
        top = q[relief.clamp_index(y0, height)]
        bottom = q[relief.clamp_index(y0 + 1, height)]
        for i in range(columns):
            x0 = math.floor(xs[i])
            fx = xs[i] - x0
            left, right = relief.clamp_index(x0, width), relief.clamp_index(x0 + 1, width)
            upper = top[left] + (top[right] - top[left]) * fx
            lower = bottom[left] + (bottom[right] - bottom[left]) * fx
            depth = 1.0 / (upper + (lower - upper) * fy)
            u, v = i / (columns - 1) * width, j / (rows - 1) * height
            vertices.append([(u - width / 2) * depth / f, (height / 2 - v) * depth / f, -depth])
    return columns, rows, xs, ys, vertices


def kept_cells(d: list, columns: int, rows: int, xs: list, ys: list) -> list:
    height, width = len(d), len(d[0])
    cut_pairs = [(near, far) for near, far, _ in breaks(d)]
    kept = []
    for j in range(rows - 1):
        top, bottom = relief.clamp_index(math.floor(ys[j]), height), relief.clamp_index(math.ceil(ys[j + 1]), height)
        row = []
        for i in range(columns - 1):
            left = relief.clamp_index(math.floor(xs[i]), width)
            right = relief.clamp_index(math.ceil(xs[i + 1]), width)
            inside = lambda p: left <= p[0] <= right and top <= p[1] <= bottom  # noqa: E731
            row.append(not any(inside(a) and inside(b) for a, b in cut_pairs))
        kept.append(row)
    return kept


def triangles(columns: int, kept: list) -> list:
    out = []
    for j, row in enumerate(kept):
        for i, keep in enumerate(row):
            if keep:
                a = j * columns + i
                b, c, d = a + 1, a + columns, a + columns + 1
                out += [a, c, b, b, c, d]
    return out


def zone(z: list, q: list, found: list, f: float) -> dict:
    steps = sorted(band_width(jump) / (f * (q[ny][nx] - q[gy][gx])) for (nx, ny), (gx, gy), jump in found)
    lateral = clamp(relief.percentile(steps, ZONE_PERCENTILE), *LATERAL) if steps else LATERAL[1]
    p5 = relief.percentile(sorted(value for row in z for value in row), FORWARD_PERCENTILE)
    return {
        "lateral": lateral,
        "vertical": VERTICAL_SHARE * lateral,
        "forward": clamp(FORWARD_SHARE * p5, *FORWARD),
        "backward": clamp(BACKWARD_SHARE * lateral, *BACKWARD),
    }


def smooth(t: float) -> float:
    t = clamp(t, 0.0, 1.0)
    return t * t * (3 - 2 * t)


def edge(rho: float) -> tuple:
    return (smooth((rho - FLATTEN[0]) / (FLATTEN[1] - FLATTEN[0])),
            DARKEN_MAX * smooth((rho - DARKEN_FROM) / (FLATTEN[1] - DARKEN_FROM)))


def rho_of(eye: list, safe: dict) -> float:
    x, y, z = eye
    reach = safe["forward"] if z < 0 else safe["backward"]
    return math.sqrt((x / safe["lateral"]) ** 2 + (y / safe["vertical"]) ** 2 + (z / reach) ** 2)


def flattened(vertex: list, a: float, plane: float) -> list:
    depth = -vertex[2]
    target = (1 - a) * depth + a * plane
    return [coordinate * target / depth for coordinate in vertex]


def scene_v1(z_in: list, mask: list, f: float, step: int) -> dict:
    height, width = len(z_in), len(z_in[0])
    z_sky, far, has_sky = sky(z_in, mask)
    z, scale = comfort(z_sky)
    q = [[1.0 / value for value in row] for row in z]
    d, _, _, low_relief = relief.normalise(q)
    found = breaks(d)
    band = bands(d, found, 1)
    inpaint = bands(d, found, INPAINT_FACTOR)
    behind = depth_behind(z, band, found)
    columns, rows, xs, ys, vertices = grid(q, f, step)
    kept = kept_cells(d, columns, rows, xs, ys)
    indices = triangles(columns, kept)
    safe = zone(z, q, found, f)
    used = sorted({index for index in indices})
    depths = sorted(-vertices[index][2] for index in used)
    plane = depths[(len(depths) - 1) // 2] if depths else None
    band_count = sum(1 for row in band for value in row if value)
    flags = []
    if low_relief:
        flags.append("lowRelief")
    if band_count > HIDDEN_AREAS_RATIO * width * height:
        flags.append("hiddenAreas")
    if has_sky:
        flags.append("sky")
    if safe["lateral"] < SMALL_ZONE:
        flags.append("smallZone")
    eyes = [[0.0, 0.0, 0.0], [safe["lateral"], 0.0, 0.0], [0.0, 0.0, -1.2 * safe["forward"]],
            [0.0, 0.0, 1.3 * safe["backward"]], [0.5 * safe["lateral"], 0.4 * safe["vertical"], -0.2 * safe["forward"]],
            [2.0 * safe["lateral"], 0.0, 0.0]]
    probe = vertices[used[len(used) // 2]] if used else vertices[0]
    return {
        "width": width,
        "height": height,
        "gridStep": step,
        "farPlane": far,
        "scale": scale,
        "depth": z,
        "normalized": d,
        "breaks": [[near[0], near[1], far_[0], far_[1], jump] for near, far_, jump in found],
        "bandWidths": [band_width(jump) for _, _, jump in found],
        "band": ["".join("1" if value else "0" for value in row) for row in band],
        "inpaintMask": ["".join("1" if value else "0" for value in row) for row in inpaint],
        "depthBehind": [[0.0 if value is None else value for value in row] for row in behind],
        "columns": columns,
        "rows": rows,
        "vertices": [coordinate for vertex in vertices for coordinate in vertex],
        "keptCells": ["".join("1" if value else "0" for value in row) for row in kept],
        "indices": indices,
        "safe": safe,
        "flags": flags,
        "photoPlane": plane,
        "edge": [
            {"eye": eye, "rho": rho_of(eye, safe), "flatten": edge(rho_of(eye, safe))[0],
             "darken": edge(rho_of(eye, safe))[1]} for eye in eyes
        ],
        "flattenedVertex": {
            "vertex": probe,
            "half": flattened(probe, 0.5, plane if plane is not None else -probe[2]),
            "full": flattened(probe, 1.0, plane if plane is not None else -probe[2]),
            "background": flattened(probe, 1.0, (plane if plane is not None else -probe[2]) + FLAT_BACKGROUND),
        },
    }


# --- The cases ----------------------------------------------------------------------------------------------------

MAP_WIDTH = 24
MAP_HEIGHT = 16
# A focal length of 240 values: on these small maps the zone then falls within its bounds, as on a real one
FOCAL = 240.0


def step_depth() -> list:
    """Three walls, at 1 m, 1.15 m and 3 m: a small break, then a large one"""
    return [[1.0 if x < 8 else 1.15 if x < 16 else 3.0 for x in range(MAP_WIDTH)] for _ in range(MAP_HEIGHT)]


def person_depth() -> list:
    """A person at 1.2 m in front of a wall at 4 m that leans back towards the top"""
    return [[1.2 if 9 <= x <= 14 and 4 <= y <= 15 else 4.0 + 0.05 * (MAP_HEIGHT - y) for x in range(MAP_WIDTH)]
            for y in range(MAP_HEIGHT)]


def close_depth() -> list:
    """A table seen from very close, 0.30 m at the bottom to 0.34 m at its far edge, under a wall at 2 m"""
    return [[0.30 + 0.005 * (MAP_HEIGHT - 1 - y) if y >= 8 else 2.0 for _ in range(MAP_WIDTH)]
            for y in range(MAP_HEIGHT)]


def ledge_depth() -> list:
    """A wall at 5 m, its right half 1 m nearer, and a lamp at 1 m in the top left corner that sets the range: the
    small step has a band of 10 values and a filling of 20"""
    return [[1.0 if x < 3 and y < 3 else 5.0 if x < 12 else 4.0 for x in range(MAP_WIDTH)] for y in range(MAP_HEIGHT)]


def flat_depth() -> list:
    return [[2.0] * MAP_WIDTH for _ in range(MAP_HEIGHT)]


def all_valid() -> list:
    return [[1.0] * MAP_WIDTH for _ in range(MAP_HEIGHT)]


def sky_mask() -> list:
    """The top five rows without depth: the sky, 31 % of the map"""
    return [[0.0 if y < 5 else 1.0 for _ in range(MAP_WIDTH)] for y in range(MAP_HEIGHT)]


def landscape_depth() -> list:
    """Hills from 8 m to 12 m under the sky, a rock at 2.5 m on the left"""
    return [[2.5 if x < 6 and y > 10 else 8.0 + 4.0 * (MAP_HEIGHT - y) / MAP_HEIGHT for x in range(MAP_WIDTH)]
            for y in range(MAP_HEIGHT)]


SQUARE = 20


def square_depth() -> list:
    """A square drone photo looking down: a field from 40 m to 44.75 m, the roof of a barn at 30 m in its middle"""
    return [[30.0 if 7 <= x <= 12 and 7 <= y <= 12 else 40.0 + 0.25 * (SQUARE - 1 - y) for x in range(SQUARE)]
            for y in range(SQUARE)]


def square_valid() -> list:
    return [[1.0] * SQUARE for _ in range(SQUARE)]


# The sizes of map whose step gridSteps gives: the frames M2 measured at 1024, the limits of step 4, a larger map
GRID_SIZES = [(1024, 768), (768, 1024), (1024, 683), (1024, 576), (1024, 341), (1024, 773), (1024, 774), (1024, 1024),
              (2048, 2048), (MAP_WIDTH, MAP_HEIGHT)]

# The cases, each with its step: None for the step of its map, always 4 on these small maps
CASES = [
    ("step", "three walls: a small break at the third of the width, a large one at two thirds", step_depth, all_valid,
     None),
    ("person", "a person in front of a wall: breaks on three sides, a depth behind them", person_depth, all_valid,
     None),
    ("close", "a table under the comfort distance and a wall: the scene grows", close_depth, all_valid, None),
    ("ledge", "a small step on a wall: a band narrower than the filling", ledge_depth, all_valid, None),
    ("flat", "a flat wall: no break, the whole zone, lowRelief", flat_depth, all_valid, None),
    ("sky", "a landscape with 31 % of sky on its far plane, a rock near the left edge", landscape_depth, sky_mask,
     None),
    ("square", "a square drone photo: its grid at the step of a square map of 1024, 5", square_depth, square_valid,
     grid_step(1024, 1024)),
]


def build() -> dict:
    cases = []
    for name, description, depth_of, mask_of, step in CASES:
        z = depth_of()
        mask = mask_of()
        cases.append({"name": name, "description": description, "focal": FOCAL, "input": z, "mask": mask,
                      **scene_v1(z, mask, FOCAL, step if step is not None else grid_step(len(z[0]), len(z)))})
    smooth_table = [[rho, *edge(rho)] for rho in (0.0, 0.5, 1.0, 1.1, 1.25, 1.3, 1.4, 1.5, 2.0)]
    return {
        "pipeline": PIPELINE,
        "about": "Made by .github/desktop/ai/make_scene_golden.py, whose header describes scene-v1. Maps are rows of "
        "the map; masks are rows of 0 and 1; breaks are [near x, near y, far x, far y, jump]; vertices are x, y, z "
        "one after the other, row after row; edgeCurve rows are [rho, flatten, darken]; gridSteps rows are [width, "
        "height, step, columns, rows] of a map. Numbers within 1e-9.",
        "tolerance": 1e-9,
        "gridStep": GRID_STEP,
        "maxGridVertices": MAX_GRID_VERTICES,
        "gridSteps": [[width, height, grid_step(width, height), grid_lines(width, grid_step(width, height)),
                       grid_lines(height, grid_step(width, height))] for width, height in GRID_SIZES],
        "breakThreshold": BREAK,
        "percentiles": [relief.LOW_PERCENTILE, relief.HIGH_PERCENTILE],
        "comfortDistance": COMFORT_DISTANCE,
        "band": [BAND_FACTOR, BAND_MIN, BAND_MAX, BAND_SMOOTHING],
        "inpaintFactor": INPAINT_FACTOR,
        "hiddenAreasRatio": HIDDEN_AREAS_RATIO,
        "sky": [VALID_MASK, SKY_PERCENTILE, SKY_NEAREST, SKY_FARTHEST, SKY_RATIO],
        "zone": {"percentile": ZONE_PERCENTILE, "lateral": list(LATERAL), "verticalShare": VERTICAL_SHARE,
                 "forwardPercentile": FORWARD_PERCENTILE, "forwardShare": FORWARD_SHARE, "forward": list(FORWARD),
                 "backwardShare": BACKWARD_SHARE, "backward": list(BACKWARD), "smallZone": SMALL_ZONE},
        "edgeCurve": smooth_table,
        "flatten": [FLATTEN[0], FLATTEN[1], DARKEN_FROM, DARKEN_MAX, FLAT_BACKGROUND, FLATTEN_STEP],
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
