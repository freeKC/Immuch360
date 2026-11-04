// The draw loop of the page: frames only while something moves (render on demand), and one chain of animation frames
// at most, whatever asks for a frame while one is drawn (Spark's sort that settled, a key, the gyroscope). On 2
// November 2026 the replay of the Windows build counted 19,404 frames in 10 s with a scene at rest, and WebView2 then
// found the page unresponsive: a request made during a frame started a second chain, every frame of each chain asked
// again, and the chains multiplied.

/**
 * The loop: [requestFrame] is requestAnimationFrame, [clock] performance.now, [settleMs] how long it keeps drawing
 * after the last request, [draw] draws one frame given its time and that of the frame before it (null after a pause).
 */
export class DrawLoop {
  constructor({ requestFrame, clock, settleMs, draw }) {
    this.requestFrame = requestFrame;
    this.clock = clock;
    this.settleMs = settleMs;
    this.draw = draw;
    this.scheduled = false;
    this.drawUntil = 0;
    this.last = null;
  }

  /** A frame soon, and frames for [settleMs] after it */
  request() {
    this.keep(this.clock());
    this.schedule();
  }

  /** Frames for [settleMs] after [now] (something still moves) */
  keep(now) {
    this.drawUntil = Math.max(this.drawUntil, now + this.settleMs);
  }

  schedule() {
    if (!this.scheduled) {
      this.scheduled = true;
      this.requestFrame((now) => this.tick(now));
    }
  }

  tick(now) {
    this.scheduled = false;
    const previous = this.last;
    this.last = now;
    this.draw(now, previous);
    if (now < this.drawUntil) {
      this.schedule();
    } else {
      this.last = null;
    }
  }
}
