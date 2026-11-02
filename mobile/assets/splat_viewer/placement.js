// Where a splat goes when the viewer opens, at Reset and at Turn upright: a port of SplatPlacement.kt of the Quest
// viewer (android/app/src/main/kotlin/app/alextran/immich/immersive/splat/), on the positions Spark decoded, so that
// a file opens the same way on a computer, a phone and the headset. Pure functions, tested in Node
// (test/splat_viewer_js/placement.test.mjs) against viewer_expected.json, which the Kotlin test reads too.
//
// The frame is three.js's: x right, y up, the camera looking along -z. The headset's frame has z ahead and its splat
// module mirrors z (SplatModuleFrame.kt): a point p of the file on an entity (t, q) shows at N (t + q N p) with
// N = diag(1, 1, -1), that is N t + R p where R turns about x by minus the headset's pitch. So the headset's target
// (x, y, z ahead) is (x, y, -z) here and its pitch of Z up (+90 degrees) is -90 degrees here.
//
// Two changes for flat screens (plan section 5): an object is framed to fit, at the larger of the headset's distance
// and the one where the sphere around its box fits the narrower side of the screen with a margin (its size alone let
// the near end of a deep object, the axes, out of the screen); the narrower side of the screen spans 60 degrees.

export const OBJECT_LIMIT = 2.5;
export const OBJECT_GAP = 0.6;
export const OBJECT_DROP = 0.0;
export const SCENE_DROP = 0.3;
export const UNKNOWN_DISTANCE = 2.0;
export const LOW_PERCENTILE = 5;
export const HIGH_PERCENTILE = 95;
export const FLOOR_BAND = 0.1;
export const FLOOR_RATIO = 3.0;
export const FLOOR_SHARE = 0.15;
export const SAMPLE_LIMIT = 65536;

/** The height of the eyes above the floor of the headset's frame, in metres */
export const EYE_HEIGHT = 1.6;

/** The narrower side of the screen spans this many degrees */
export const NARROW_FOV_DEGREES = 60;

/** An object framed to fit is this much farther than where the sphere around it touches the narrower side */
export const FIT_MARGIN = 1.05;

/** The speed of walking: the larger side of the bounds over this, per second, within the limits below */
export const SPEED_DIVISOR = 8;
export const MIN_SPEED = 0.5;
export const MAX_SPEED = 4.0;

/** The room to move: the bounds plus this, or a fifth of their larger side when that is more */
export const ZONE_MARGIN = 2.0;

/** Turn upright cycles these, as on the headset */
export const UPRIGHTS = ['yUp', 'zUp', 'yDown'];

/** The default orientation: Y down, the axes of a 3D Gaussian Splatting training (those of COLMAP) */
export const DEFAULT_UPRIGHT = 'yDown';

/** The orientation after [upright]: Y up, Z up, Y down, then Y up again */
export function nextUpright(upright) {
  const at = UPRIGHTS.indexOf(upright);
  return UPRIGHTS[((at < 0 ? UPRIGHTS.indexOf(DEFAULT_UPRIGHT) : at) + 1) % UPRIGHTS.length];
}

/** The rotation about x of three.js that puts [upright] up: minus the headset's pitch */
export function pitchOf(upright) {
  switch (upright) {
    case 'yUp':
      return 0;
    case 'zUp':
      return -Math.PI / 2;
    default:
      return Math.PI;
  }
}

/** [v] turned about x by [angle] radians */
export function rotateX(angle, v) {
  const c = Math.cos(angle);
  const s = Math.sin(angle);
  return [v[0], v[1] * c - v[2] * s, v[1] * s + v[2] * c];
}

/** The positions sampled for the placement: every [stride]th gaussian from the first, [samples] of them */
export function sampleOf(count, limit = SAMPLE_LIMIT) {
  if (!(count > 0)) {
    return { stride: 1, samples: 0 };
  }
  const stride = Math.max(1, Math.floor((count + limit - 1) / limit));
  return { stride, samples: Math.floor((count + stride - 1) / stride) };
}

/** The value of rank max(1, (P * N + 99) / 100) of the [sorted] values, as SplatPlacement.percentile */
export function percentile(sorted, p) {
  const rank = Math.max(1, Math.floor((p * sorted.length + 99) / 100));
  return sorted[rank - 1];
}

/**
 * The robust bounds of [positions] (x, y, z of each sample, in the numbers of the file): the percentiles 5 and 95 of
 * each axis; null without a position, or with one that is not a finite number
 */
export function boundsOf(positions) {
  const count = Math.floor(positions.length / 3);
  if (count === 0) {
    return null;
  }
  const low = [0, 0, 0];
  const high = [0, 0, 0];
  for (let axis = 0; axis < 3; axis++) {
    const values = new Float64Array(count);
    for (let k = 0; k < count; k++) {
      const value = positions[3 * k + axis];
      if (!Number.isFinite(value)) {
        return null;
      }
      values[k] = value;
    }
    values.sort();
    low[axis] = percentile(values, LOW_PERCENTILE);
    high[axis] = percentile(values, HIGH_PERCENTILE);
  }
  return { low, high };
}

export function centerOf(bounds) {
  return [0, 1, 2].map((axis) => (bounds.low[axis] + bounds.high[axis]) / 2);
}

/** The largest of the three extents: the same whichever axis is up */
export function sizeOf(bounds) {
  return Math.max(...[0, 1, 2].map((axis) => bounds.high[axis] - bounds.low[axis]));
}

/** Whether the splat of [bounds] is an object to look at, rather than a place to stand in */
export function isObject(bounds) {
  return bounds != null && sizeOf(bounds) < OBJECT_LIMIT;
}

/**
 * The floor rule of SplatPlacement.uprightOf: a place whose bottom band of y holds at least FLOOR_SHARE of the
 * samples and FLOOR_RATIO times those of the top band opens with Y up; otherwise null (the default holds). Never for
 * an object.
 */
export function floorUprightOf(positions, bounds) {
  if (bounds == null || isObject(bounds)) {
    return null;
  }
  const low = bounds.low[1];
  const high = bounds.high[1];
  const band = (high - low) * FLOOR_BAND;
  if (!(band > 0)) {
    return null;
  }
  let total = 0;
  let bottom = 0;
  let top = 0;
  for (let k = 0; 3 * k + 1 < positions.length; k++) {
    const y = positions[3 * k + 1];
    if (!Number.isFinite(y)) {
      continue;
    }
    total++;
    if (y <= low + band) bottom++;
    if (y >= high - band) top++;
  }
  if (total === 0) {
    return null;
  }
  return bottom >= FLOOR_SHARE * total && bottom >= FLOOR_RATIO * top ? 'yUp' : null;
}

/** The orientation a splat opens in: the one the user chose for the file, else the floor rule, else Y down */
export function openingUpright(remembered, positions, bounds) {
  if (UPRIGHTS.includes(remembered)) {
    return remembered;
  }
  return floorUprightOf(positions, bounds) ?? DEFAULT_UPRIGHT;
}

/** The vertical field of view of a screen of [aspect] (width over height) whose narrower side spans 60 degrees */
export function verticalFov(aspect) {
  const half = (NARROW_FOV_DEGREES / 2) * (Math.PI / 180);
  if (!(aspect > 0) || aspect >= 1) {
    return NARROW_FOV_DEGREES;
  }
  return (2 * Math.atan(Math.tan(half) / aspect) * 180) / Math.PI;
}

/**
 * How far an object of [bounds] goes: the headset's distance (OBJECT_GAP plus half its size), or farther so that the
 * sphere around its box fits the narrower side of the screen, whatever way it is turned
 */
export function objectDistance(bounds) {
  const half = (NARROW_FOV_DEGREES / 2) * (Math.PI / 180);
  const extent = [0, 1, 2].map((axis) => bounds.high[axis] - bounds.low[axis]);
  const radius = Math.hypot(extent[0], extent[1], extent[2]) / 2;
  return Math.max(OBJECT_GAP + sizeOf(bounds) / 2, (radius / Math.sin(half)) * FIT_MARGIN);
}

/**
 * The first view of a splat whose sampled [positions] gave [bounds] (null without positions), turned [upright]:
 * where its mesh goes ([position], turned by [pitch] about x), where the eye is and what it looks at, and for an
 * object the centre it is turned around and the distance. Also the speed of walking and the room to move.
 */
export function firstView(bounds, upright) {
  const pitch = pitchOf(upright);
  const eye = [0, EYE_HEIGHT, 0];
  if (bounds == null) {
    const target = [0, EYE_HEIGHT - SCENE_DROP, -UNKNOWN_DISTANCE];
    return {
      object: false,
      upright,
      pitch,
      position: target,
      eye,
      look: [0, EYE_HEIGHT, -1],
      center: target,
      distance: UNKNOWN_DISTANCE,
      size: 0,
      speed: MIN_SPEED,
      zone: { low: [-UNKNOWN_DISTANCE - ZONE_MARGIN, -ZONE_MARGIN, -2 * UNKNOWN_DISTANCE - ZONE_MARGIN],
        high: [UNKNOWN_DISTANCE + ZONE_MARGIN, EYE_HEIGHT + ZONE_MARGIN, ZONE_MARGIN] },
    };
  }
  const size = sizeOf(bounds);
  const object = isObject(bounds);
  const distance = object ? objectDistance(bounds) : 0;
  const target = object ? [0, EYE_HEIGHT - OBJECT_DROP, -distance] : [0, EYE_HEIGHT - SCENE_DROP, 0];
  const rotated = rotateX(pitch, centerOf(bounds));
  const position = [0, 1, 2].map((axis) => target[axis] - rotated[axis]);
  const world = worldBounds(bounds, pitch, position);
  const margin = Math.max(ZONE_MARGIN, size / 5);
  return {
    object,
    upright,
    pitch,
    position,
    eye,
    look: object ? target : [0, EYE_HEIGHT, -1],
    center: target,
    distance,
    size,
    speed: Math.min(MAX_SPEED, Math.max(MIN_SPEED, size / SPEED_DIVISOR)),
    zone: { low: world.low.map((v) => v - margin), high: world.high.map((v) => v + margin) },
  };
}

/** The box of [bounds] once turned by [pitch] about x and moved by [position], in the frame of three.js */
export function worldBounds(bounds, pitch, position) {
  const low = [Infinity, Infinity, Infinity];
  const high = [-Infinity, -Infinity, -Infinity];
  for (let corner = 0; corner < 8; corner++) {
    const point = [0, 1, 2].map((axis) => ((corner >> axis) & 1 ? bounds.high[axis] : bounds.low[axis]));
    const turned = rotateX(pitch, point);
    for (let axis = 0; axis < 3; axis++) {
      const value = turned[axis] + position[axis];
      low[axis] = Math.min(low[axis], value);
      high[axis] = Math.max(high[axis], value);
    }
  }
  return { low, high };
}
