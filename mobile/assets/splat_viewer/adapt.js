// The drawing quality follows the frame times (plan section 6): the pixel ratio at most the session's (1 at first),
// the drawing scale 1, then 0.75, then 0.5 when the median frame stays over 22 ms for 2 s, back up under 12 ms; one
// "heavy" line per opening when the median stays over 50 ms at the lowest scale. Pure, tested in Node.

export const SCALES = [1, 0.75, 0.5];
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
  constructor() {
    this.step = 0;
    this.frames = [];
    this.since = null;
    this.heavy = false;
  }

  get scale() {
    return SCALES[this.step];
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
    if (now - this.since < WINDOW_MS || this.frames.length < 10) {
      return null;
    }
    const middle = median(this.frames.map((frame) => frame.ms));
    if (middle > SLOW_MS && this.step < SCALES.length - 1) {
      this.step++;
      this.restart(now);
      return 'down';
    }
    if (middle < FAST_MS && this.step > 0) {
      this.step--;
      this.restart(now);
      return 'up';
    }
    if (middle > HEAVY_MS && this.step === SCALES.length - 1 && !this.heavy) {
      this.heavy = true;
      return 'heavy';
    }
    return null;
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
