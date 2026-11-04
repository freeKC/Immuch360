// The frames of the first seconds on a computer (framewatch.js, lot SVC): the watch runs 30 s by the clock from ready
// and counts every frame while it runs, a long one too; the reduced copy is offered when the frames stay under 27 per
// second for 3 s at the lowest quality, or under 10 at any quality, never when 27 or more come over 3 s; and on the
// frames the app's page drew on 3 November 2026 (test/fixtures/splat_viewer/computer_measures.json), replayed from
// ready, what each computer is offered.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { Quality } from '../../assets/splat_viewer/adapt.js';
import {
  FLOOR_FPS,
  FrameWatch,
  followsOn,
  fpsShown,
  keepFor,
  paceFrame,
  PAUSE_MS,
  SLOW_FPS,
  WATCH_MS,
} from '../../assets/splat_viewer/framewatch.js';

const measures = JSON.parse(readFileSync(new URL('../fixtures/splat_viewer/computer_measures.json', import.meta.url)));

/** A watch started at [from]: the frames of [ms] each for [seconds], at [lowest] or not; what it found, and when */
const steady = (watch, ms, seconds, lowest = true, from = 0) => {
  watch.start(from);
  for (let now = from + ms; now <= from + seconds * 1000; now += ms) {
    const found = watch.frame(ms, now, lowest);
    if (found) {
      return { ...found, at: now };
    }
  }
  return null;
};

/**
 * The page's own loop (viewer.js) on frames of [frameMs] ms one after the other, the watch started at frame [ready]:
 * the quality steps of adapt.js and the watch beside them, with the page's rule of what follows on. What the watch
 * found, when, at which drawing scale, and how many frames the page drew meanwhile; or that it found nothing
 */
const loop = (frameMs, { gaussians, ready = 0, seconds = Infinity }) => {
  const quality = new Quality(2);
  const watch = new FrameWatch({ gaussians, floor: 150000 });
  let now = 0;
  let readyAt = 0;
  let drawn = 0;
  for (let index = 0; index < frameMs.length && now < seconds * 1000; index++) {
    const ms = frameMs[index];
    now += ms;
    if (index === ready) {
      watch.start(now);
      readyAt = now;
      continue;
    }
    if (index < ready) {
      continue;
    }
    drawn++;
    if (!followsOn(ms, watch.watching)) {
      quality.pause();
      watch.pause();
      continue;
    }
    const { found } = paceFrame(quality, watch, ms, now);
    if (found) {
      return { ...found, at: Math.round(now - readyAt), scale: quality.scale, drawn };
    }
  }
  return { none: true, done: watch.done, scale: quality.scale, drawn };
};

/** [count] frames of [ms] each, or of what [ms] gives for each index */
const frames = (count, ms) => Array.from({ length: count }, (_, index) => (typeof ms === 'function' ? ms(index) : ms));

/** A measured case replayed from its ready */
const replay = (kase) =>
  loop(
    kase.frameTenths.map((tenths) => tenths / 10),
    { gaussians: kase.gaussians, ready: kase.readyFrame },
  );

test('27 frames a second or more over 3 s ends the watch: nothing is offered', () => {
  const watch = new FrameWatch({ gaussians: 4000000, floor: 150000 });
  const found = steady(watch, 1000 / 28, 10, false);
  assert.equal(found.slow, false);
  assert.ok(found.fps >= SLOW_FPS);
  assert.ok(found.at >= 3000 && found.at < 3100);
  assert.equal(watch.frame(100, 20000, true), null, 'once found, the watch says nothing more');
  assert.equal(watch.watching, false);
});

test('under 27 at the lowest quality for 3 s offers the count that would draw at about 45', () => {
  const watch = new FrameWatch({ gaussians: 3000000, floor: 150000 });
  const found = steady(watch, 40, 10);
  assert.deepEqual({ slow: found.slow, fps: found.fps, keep: found.keep }, { slow: true, fps: 25, keep: 1660000 });
});

test('slow frames above the lowest quality wait for the steps; a step starts the 3 s again', () => {
  const watch = new FrameWatch({ gaussians: 2000000, floor: 150000 });
  assert.equal(steady(watch, 50, 8, false), null);
  watch.restart();
  const found = steady(watch, 50, 10, true, 8000);
  assert.equal(found.slow, true);
  assert.ok(found.at >= 11000, `3 s after the step, not before: ${found.at}`);
});

test('under 10 frames a second over 3 s offers at once, whatever the quality', () => {
  const watch = new FrameWatch({ gaussians: 4000000, floor: 150000 });
  const found = steady(watch, 125, 10, false);
  assert.equal(found.slow, true);
  assert.ok(found.fps < FLOOR_FPS);
  assert.equal(found.at, 3000);
  assert.equal(found.keep, 710000);
});

test('frames that are not back to back start the window again', () => {
  const watch = new FrameWatch({ gaussians: 2000000, floor: 150000 });
  assert.equal(steady(watch, 50, 2.9), null);
  watch.pause();
  assert.equal(steady(watch, 50, 2.9, true, 5000), null);
});

test('nothing counts before the scene shows; then 30 s by the clock end the watch without an offer', () => {
  const watch = new FrameWatch({ gaussians: 2000000, floor: 150000 });
  assert.equal(watch.watching, false);
  assert.equal(watch.frame(500, 1000, true), null, 'not started: the frames of the loading do not count');
  assert.equal(watch.frames.length, 0);
  const found = steady(watch, 40, 40, false, 2000);
  assert.equal(found.slow, false);
  assert.ok(found.at >= 2000 + WATCH_MS && found.at < 2000 + WATCH_MS + 50, `${found.at}`);
  // A page hidden for longer than the watch: the first frame after it ends the watch
  const hidden = new FrameWatch({ gaussians: 2000000, floor: 150000 });
  hidden.start(0);
  assert.equal(hidden.frame(16, 16, false), null);
  hidden.pause();
  assert.equal(hidden.frame(16, 45000, false).slow, false);
  assert.equal(hidden.watching, false);
});

test('a splat of the phones cap or fewer is never watched; the count offered stays between the floor and the file', () => {
  assert.equal(steady(new FrameWatch({ gaussians: 150000, floor: 150000 }), 100, 10), null);
  assert.equal(keepFor(4000000, 15, 150000), 1330000);
  assert.equal(keepFor(400000, 2, 150000), 150000);
  assert.equal(keepFor(160000, 44.9, 150000), 150000);
  assert.equal(keepFor(1000000, 29.9, 150000), 660000);
});

test('while the watch runs every frame follows on, a long one too; else 250 ms or more is a pause', () => {
  assert.equal(followsOn(null, true), false, 'the first frame after a pause or a hidden page');
  assert.equal(followsOn(9500, true), true);
  assert.equal(followsOn(PAUSE_MS - 1, false), true);
  assert.equal(followsOn(PAUSE_MS, false), false);
});

test('the rate the offer says is never above the one measured', () => {
  assert.equal(fpsShown(26.9), 26);
  assert.equal(fpsShown(10), 10);
  assert.equal(fpsShown(9.9), 9.9);
  assert.equal(fpsShown(3.3), 3.3);
  assert.equal(fpsShown(0.1), 0.1);
  assert.equal(fpsShown(0), 0.1, 'a frame longer than 20 s still reads as a rate');
});

test('a real collapse is offered: frames of 300 ms (3.3 fps), the page then stops drawing', () => {
  // Review of 4 November 2026: these frames counted as pauses, the page drew at full scale for as long as it stayed
  // open and never offered anything
  const found = loop(frames(400, 300), { gaussians: 8000000 });
  assert.equal(found.slow, true, JSON.stringify(found));
  assert.ok(found.fps < FLOOR_FPS);
  assert.ok(found.at <= 15000, `offered within 15 s: ${found.at}`);
  assert.ok(found.keep >= 150000 && found.keep < 1000000, `${found.keep}`);
  assert.ok(found.drawn < 60, `the watch ends, and with it the drawing kept for it: ${found.drawn} frames`);
});

test('frames of 230 ms (4.3 fps), which the steps never gathered ten of in 2 s, are offered too', () => {
  const found = loop(frames(400, 230), { gaussians: 8000000 });
  assert.equal(found.slow, true, JSON.stringify(found));
  assert.ok(found.at <= 15000, `${found.at}`);
  assert.equal(found.scale, 0.25, 'the steps went down on these frames meanwhile');
});

test('frames of 200 ms, and of 9.5 s (SwiftShader on ai1), are offered; the slowest at their first frame', () => {
  assert.equal(loop(frames(400, 200), { gaussians: 8000000 }).slow, true);
  const crawl = loop(frames(20, 9500), { gaussians: 1000000 });
  assert.deepEqual(
    { slow: crawl.slow, fps: crawl.fps, keep: crawl.keep, at: crawl.at },
    { slow: true, fps: 0.1, keep: 150000, at: 9500 },
  );
});

test('vsync at 30 frames a second, steady or with a missed frame now and then, is offered nothing', () => {
  // ai1, 3 November 2026: the same scene at a 33.3 ms median read 30.3 fps (no offer) and 29.5 (offered)
  for (const ms of [frames(2000, 1000 / 30), frames(2000, (index) => (index % 40 === 39 ? 2000 / 30 : 1000 / 30))]) {
    const found = loop(ms, { gaussians: 1000000 });
    assert.equal(found.slow, false, JSON.stringify(found));
    assert.ok(found.fps >= 29 && found.fps < 30.1, `${found.fps}`);
  }
});

test('the RTX 4060 is offered nothing, 637,401 to 12 million gaussians (measured 50 to 120 fps)', () => {
  const cases = measures.cases.filter((kase) => kase.gpu === 'rtx' && kase.page === 'app');
  assert.equal(cases.length, 8);
  for (const kase of cases) {
    const found = replay(kase);
    assert.equal(found.slow, false, `${kase.file}: ${JSON.stringify(found)}`);
    assert.equal(found.scale, 1, `${kase.file} keeps its full drawing`);
    assert.ok(found.at < 15000, `${kase.file} decided in the first seconds: ${found.at} ms`);
  }
});

test('the Intel UHD at its lowest quality: nothing up to 2 million, the reduced copy at 3 and 4 million', () => {
  const found = Object.fromEntries(
    measures.cases
      .filter((kase) => kase.gpu === 'intel' && kase.page === 'app')
      .map((kase) => [kase.gaussians, replay(kase)]),
  );
  for (const gaussians of [637401, 1000000, 2000000]) {
    assert.equal(found[gaussians].slow, false, `${gaussians}: ${JSON.stringify(found[gaussians])}`);
  }
  for (const gaussians of [3000000, 4000000]) {
    const offer = found[gaussians];
    assert.equal(offer.slow, true, `${gaussians}: ${JSON.stringify(offer)}`);
    assert.ok(offer.fps < SLOW_FPS);
    assert.ok(offer.at < 25000, `${gaussians} offered with time to spare: ${offer.at} ms`);
    assert.ok(offer.keep >= 150000 && offer.keep < 2000000, `${gaussians} offered ${offer.keep}`);
  }
});
