// The drawing quality follows the frame times (plan section 6): the pixel ratio at most the session's (1 on phones and
// tablets, 2 on computers, whose panels at 200 % were drawn at a quarter of their pixels), the drawing scale 1, then
// 0.75, then 0.5 when the median frame stays over 22 ms for 2 s, and on down to a drawing at half a pixel per CSS
// pixel when the session starts at 2; back up under 12 ms; one "heavy" line per opening when the median stays over
// 50 ms at the lowest scale. A window decides with ten frames, or with fewer when they fill it (frames of 230 ms or
// more, which a computer's frame watch counts: review of 4 November 2026). Pure, tested in Node.

export const SCALES = [1, 0.75, 0.5, 0.375, 0.25];

/** The lowest pixel ratio the steps go down to, whatever the session starts at */
export const LOWEST_RATIO = 0.5;

/** The steps of a session whose pixel ratio is at most [ratioMax]: down to LOWEST_RATIO */
export function scalesFor(ratioMax = 1) {
  const base = Math.max(1, ratioMax);
  return SCALES.filter((scale) => base * scale >= LOWEST_RATIO - 1e-9);
}
export const SLOW_MS = 22;
export const FAST_MS = 12;
export const HEAVY_MS = 50;
export const WINDOW_MS = 2000;

export function median(values) {
  if (values.length === 0) {
    return 0;
  }
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)];
}

export function quantile(values, q) {
  if (values.length === 0) {
    return 0;
  }
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))];
}

/** The quality of one viewing: frame(ms, now) for each frame drawn right after another; scale, heavy */
export class Quality {
  constructor(ratioMax = 1) {
    this.scales = scalesFor(ratioMax);
    this.step = 0;
    this.frames = [];
    this.since = null;
    this.heavy = false;
  }

  get scale() {
    return this.scales[this.step];
  }

  /**
   * A frame of [ms] at [now]; returns 'down' or 'up' when the scale changed, 'heavy' once when the splat stays heavy,
   * null otherwise
   */
  frame(ms, now) {
    this.frames.push({ ms, now });
    while (this.frames.length && now - this.frames[0].now > WINDOW_MS) {
      this.frames.shift();
    }
    if (this.since == null) {
      this.since = now;
    }
    if (now - this.since < WINDOW_MS || (this.frames.length < 10 && this.drawnMs() < WINDOW_MS)) {
      return null;
    }
    const middle = median(this.frames.map((frame) => frame.ms));
    if (middle > SLOW_MS && this.step < this.scales.length - 1) {
      this.step++;
      this.restart(now);
      return 'down';
    }
    if (middle < FAST_MS && this.step > 0) {
      this.step--;
      this.restart(now);
      return 'up';
    }
    if (middle > HEAVY_MS && this.step === this.scales.length - 1 && !this.heavy) {
      this.heavy = true;
      return 'heavy';
    }
    return null;
  }

  /** The time the frames of the window took */
  drawnMs() {
    return this.frames.reduce((sum, frame) => sum + frame.ms, 0);
  }

  /** The frames were not drawn back to back (the scene settled): the next ones start a new window */
  pause() {
    this.frames = [];
    this.since = null;
  }

  restart(now) {
    this.frames = [];
    this.since = now;
  }
}
