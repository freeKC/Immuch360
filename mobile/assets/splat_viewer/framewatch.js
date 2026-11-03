// The frames of the first seconds of a viewing on a computer (lot SVC, 3 November 2026): a computer with a dedicated
// graphics card shows a splat whole, and only its frames say whether it is too much. When the frames drawn back to
// back stay under 30 per second for 3 s once the quality steps (adapt.js) are at their lowest, the page offers a
// reduced copy with one tap, of the count that would draw at about 45 per second; 30 or more over 3 s ends the watch,
// and so do 30 s of drawing. The app keeps the answer for the file. Measured in the app's page (Chrome 156, 2482 x
// 1170): an RTX 4060 Laptop draws 1 to 8 million gaussians at 78 to 120 fps and is never offered anything; an Intel UHD
// at its lowest step draws 2 million at 31 to 36 fps (no offer), 3 million at 25 to 27 and 4 million at 10 to 19
// (offered 1.78 and 1.33 million). Pure, tested in Node with those frames (framewatch.test.mjs).

/** Under this many frames per second over WINDOW_MS, at the lowest quality, the reduced copy is offered */
export const SLOW_FPS = 30;
export const WINDOW_MS = 3000;

/** The watch ends after this much drawing, whatever the frames */
export const WATCH_MS = 30000;

/** The reduced copy is of the count that would draw at this rate, the frame time taken as growing with the count */
export const TARGET_FPS = 45;

/** The count offered is rounded down to this */
export const KEEP_STEP = 10000;

/** The count offered for [gaussians] drawn at [fps]: TARGET_FPS by proportion, at least [floor], under [gaussians] */
export function keepFor(gaussians, fps, floor) {
  const keep = Math.floor((gaussians * Math.max(0, fps)) / TARGET_FPS / KEEP_STEP) * KEEP_STEP;
  return Math.min(gaussians - 1, Math.max(floor, keep));
}

/** The watch of one viewing: frame(ms, now, lowest) for each frame drawn right after another; restart, pause */
export class FrameWatch {
  constructor({ gaussians, floor }) {
    this.gaussians = gaussians;
    this.floor = floor;
    this.frames = [];
    this.windowMs = 0;
    this.drawnMs = 0;
    this.done = gaussians <= floor;
  }

  /**
   * A frame of [ms] at [now]; [lowest] when the quality steps are at their lowest. Returns once what was found,
   * { slow: true, fps, keep } or { slow: false, fps }, null until then and after
   */
  frame(ms, now, lowest) {
    if (this.done) {
      return null;
    }
    this.frames.push(ms);
    this.windowMs += ms;
    this.drawnMs += ms;
    while (this.frames.length > 1 && this.windowMs - this.frames[0] >= WINDOW_MS) {
      this.windowMs -= this.frames.shift();
    }
    if (this.windowMs >= WINDOW_MS) {
      const fps = Math.round((10000 * this.frames.length) / this.windowMs) / 10;
      if (fps >= SLOW_FPS) {
        this.done = true;
        return { slow: false, fps };
      }
      if (lowest) {
        this.done = true;
        return { slow: true, fps, keep: keepFor(this.gaussians, fps, this.floor) };
      }
    }
    if (this.drawnMs >= WATCH_MS) {
      this.done = true;
      return { slow: false, fps: this.windowMs > 0 ? Math.round((10000 * this.frames.length) / this.windowMs) / 10 : 0 };
    }
    return null;
  }

  /** The drawing changed scale: the frames before count no more */
  restart() {
    this.frames = [];
    this.windowMs = 0;
  }

  /** The frames were not drawn back to back (the scene settled): the next ones start a new window */
  pause() {
    this.restart();
  }
}
