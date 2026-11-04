// The frames of the first seconds of a viewing on a computer (lot SVC, 3 November 2026): a computer with a dedicated
// graphics card shows a splat whole, and only its frames say whether it is too much. The watch starts when the page
// says the scene shows (ready) and runs 30 s by the clock; meanwhile the page draws whatever moves, and every frame
// counts, a long one too: a frame of 300 ms is the slowness the watch looks for, not a pause (review of 4 November
// 2026: under 4 fps the page drew at full scale for as long as it stayed open, and never offered anything). Over 3 s
// of frames at one quality step (adapt.js), 27 per second or more ends the watch; under 27 at the lowest step, or
// under 10 at any step, the page offers a reduced copy with one tap, of the count that would draw at about 45 per
// second. 27 and not 30: a chip that needs 17 to 33 ms a frame reads 30 give or take its jitter under the vsync of a
// 60 Hz panel (30.3 and 29.5 for the same scene on ai1). The app keeps the answer for the file.
//
// Measured in the app's page (Chrome 156, 2482 x 1170) and replayed from ready in framewatch.test.mjs: an RTX 4060
// Laptop draws 637,401 to 12 million gaussians at 50 to 120 fps and is never offered anything; an Intel UHD at its
// lowest step draws 2 million at 28 to 36 fps (no offer), 3 million at 20 to 27 and 4 million at 9 to 19 (offered
// 1.32 million and 830,000, 11 s after ready). Pure, tested in Node.

/** Under this many frames per second over WINDOW_MS, at the lowest quality, the reduced copy is offered */
export const SLOW_FPS = 27;

/** Under this many over WINDOW_MS, at any quality, it is offered at once */
export const FLOOR_FPS = 10;

export const WINDOW_MS = 3000;

/** The watch ends this long after the scene showed, whatever the frames */
export const WATCH_MS = 30000;

/** Outside the watch, a frame this long after the one before follows no other: the scene had settled */
export const PAUSE_MS = 250;

/** The reduced copy is of the count that would draw at this rate, the frame time taken as growing with the count */
export const TARGET_FPS = 45;

/** The count offered is rounded down to this */
export const KEEP_STEP = 10000;

/** The count offered for [gaussians] drawn at [fps]: TARGET_FPS by proportion, at least [floor], under [gaussians] */
export function keepFor(gaussians, fps, floor) {
  const keep = Math.floor((gaussians * Math.max(0, fps)) / TARGET_FPS / KEEP_STEP) * KEEP_STEP;
  return Math.min(gaussians - 1, Math.max(floor, keep));
}

/** Frames per second of [count] frames over [ms], rounded down to a tenth: never above what was measured */
function rateOf(count, ms) {
  return ms > 0 ? Math.floor((10000 * count) / ms + 1e-6) / 10 : 0;
}

/** The rate the offer says: whole frames from 10 a second, tenths under, 0.1 at least; never above [fps] */
export function fpsShown(fps) {
  return fps >= 10 ? Math.floor(fps) : Math.max(0.1, Math.floor(fps * 10 + 1e-6) / 10);
}

/**
 * Whether a frame drawn [gap] ms after the one before (null: none before, or the page was hidden meanwhile) follows
 * on from it: always while the watch runs ([watching]), else under PAUSE_MS
 */
export function followsOn(gap, watching) {
  return gap != null && (watching || gap < PAUSE_MS);
}

/**
 * One frame of [ms] at [now] that follows on from the one before: the quality steps of [quality] (adapt.js) first, a
 * step starting the window of [watch] again, then [watch]. Returns { change, found }: the quality's change, what the
 * watch found
 */
export function paceFrame(quality, watch, ms, now) {
  const change = quality.frame(ms, now);
  if (change === 'down' || change === 'up') {
    watch?.restart();
  }
  const found = watch?.frame(ms, now, quality.step === quality.scales.length - 1) ?? null;
  return { change, found };
}

/** The watch of one viewing: start(now) at ready, then frame(ms, now, lowest) for each frame that follows on */
export class FrameWatch {
  constructor({ gaussians, floor }) {
    this.gaussians = gaussians;
    this.floor = floor;
    this.frames = [];
    this.windowMs = 0;
    this.startedAt = null;
    this.done = gaussians <= floor;
  }

  /** The scene shows at [now]: the watch runs from there */
  start(now) {
    if (this.startedAt == null) {
      this.startedAt = now;
    }
  }

  /** Started, and nothing found yet: every frame counts, and the page keeps drawing */
  get watching() {
    return this.startedAt != null && !this.done;
  }

  /**
   * A frame of [ms] at [now]; [lowest] when the quality steps are at their lowest. Returns once what was found,
   * { slow: true, fps, keep } or { slow: false, fps }, null until then and after
   */
  frame(ms, now, lowest) {
    if (!this.watching) {
      return null;
    }
    this.frames.push(ms);
    this.windowMs += ms;
    while (this.frames.length > 1 && this.windowMs - this.frames[0] >= WINDOW_MS) {
      this.windowMs -= this.frames.shift();
    }
    if (this.windowMs >= WINDOW_MS) {
      const fps = rateOf(this.frames.length, this.windowMs);
      if (fps >= SLOW_FPS) {
        return this.end({ slow: false, fps });
      }
      if (lowest || fps < FLOOR_FPS) {
        return this.end({ slow: true, fps, keep: keepFor(this.gaussians, fps, this.floor) });
      }
    }
    if (now - this.startedAt >= WATCH_MS) {
      return this.end({ slow: false, fps: rateOf(this.frames.length, this.windowMs) });
    }
    return null;
  }

  end(found) {
    this.done = true;
    return found;
  }

  /** The drawing changed scale: the frames before count no more */
  restart() {
    this.frames = [];
    this.windowMs = 0;
  }

  /** The frames did not follow on (the page was hidden): the next ones start a new window */
  pause() {
    this.restart();
  }
}
