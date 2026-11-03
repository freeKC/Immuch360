// The frames of the first seconds on a computer (framewatch.js, lot SVC): the reduced copy is offered when the frames
// stay under 30 per second for 3 s at the lowest quality, never when 30 or more come over 3 s; and on the frames the
// app's page drew on 3 November 2026 (test/fixtures/splat_viewer/computer_measures.json), what each computer is offered.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { Quality } from '../../assets/splat_viewer/adapt.js';
import { FrameWatch, keepFor, SLOW_FPS, WATCH_MS } from '../../assets/splat_viewer/framewatch.js';

const measures = JSON.parse(readFileSync(new URL('../fixtures/splat_viewer/computer_measures.json', import.meta.url)));

/** The frames of [ms] each for [seconds], at [lowest] or not; what the watch found, and when */
const steady = (watch, ms, seconds, lowest = true, from = 0) => {
  for (let now = from + ms; now <= from + seconds * 1000; now += ms) {
    const found = watch.frame(ms, now, lowest);
    if (found) {
      return { ...found, at: now };
    }
  }
  return null;
};

/** The page's own loop on the measured frames: the quality steps of adapt.js, and the watch beside them */
const replay = (kase) => {
  const quality = new Quality(2);
  const watch = new FrameWatch({ gaussians: kase.gaussians, floor: 150000 });
  let now = 0;
  for (const tenths of kase.frameTenths) {
    const ms = tenths / 10;
    now += ms;
    if (ms >= 250) {
      quality.pause();
      watch.pause();
      continue;
    }
    const change = quality.frame(ms, now);
    if (change === 'down' || change === 'up') {
      watch.restart();
    }
    const found = watch.frame(ms, now, quality.step === quality.scales.length - 1);
    if (found) {
      return { ...found, at: Math.round(now), scale: quality.scale };
    }
  }
  return { none: true, scale: quality.scale };
};

test('30 frames a second or more over 3 s ends the watch: nothing is offered', () => {
  const watch = new FrameWatch({ gaussians: 4000000, floor: 150000 });
  const found = steady(watch, 1000 / 31, 10, false);
  assert.equal(found.slow, false);
  assert.ok(found.fps >= SLOW_FPS);
  assert.ok(found.at >= 3000 && found.at < 3100);
  assert.equal(watch.frame(100, 20000, true), null, 'once found, the watch says nothing more');
});

test('under 30 at the lowest quality for 3 s offers the count that would draw at about 45', () => {
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

test('frames that are not back to back start the window again', () => {
  const watch = new FrameWatch({ gaussians: 2000000, floor: 150000 });
  assert.equal(steady(watch, 50, 2.9), null);
  watch.pause();
  assert.equal(steady(watch, 50, 2.9, true, 5000), null);
});

test('30 s of drawing end the watch without an offer', () => {
  const watch = new FrameWatch({ gaussians: 2000000, floor: 150000 });
  const found = steady(watch, 40, 40, false);
  assert.equal(found.slow, false);
  assert.ok(found.at >= WATCH_MS && found.at < WATCH_MS + 50);
});

test('a splat of the phones cap or fewer is never watched; the count offered stays between the floor and the file', () => {
  assert.equal(steady(new FrameWatch({ gaussians: 150000, floor: 150000 }), 100, 10), null);
  assert.equal(keepFor(4000000, 15, 150000), 1330000);
  assert.equal(keepFor(400000, 2, 150000), 150000);
  assert.equal(keepFor(160000, 44.9, 150000), 150000);
  assert.equal(keepFor(1000000, 29.9, 150000), 660000);
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
    assert.equal(offer.scale, 0.25, 'only once the drawing is at its lowest');
    assert.ok(offer.keep >= 150000 && offer.keep < 2000000, `${gaussians} offered ${offer.keep}`);
  }
});
