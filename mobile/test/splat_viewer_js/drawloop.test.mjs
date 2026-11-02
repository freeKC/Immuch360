// The draw loop of the page (drawloop.js): frames only while something moves, one chain of frames at most whatever
// asks for a frame during a frame (the Windows replay of 2 November 2026 counted 19,404 frames in 10 s at rest)
import assert from 'node:assert/strict';
import test from 'node:test';

import { DrawLoop } from '../../assets/splat_viewer/drawloop.js';

/** A fake requestAnimationFrame: the callbacks wait until [vsync] runs them, all at the same time */
function fakeFrames() {
  let pending = [];
  let time = 0;
  return {
    requestFrame: (callback) => pending.push(callback),
    clock: () => time,
    get waiting() {
      return pending.length;
    },
    vsync(ms = 16) {
      time += ms;
      const run = pending;
      pending = [];
      run.forEach((callback) => callback(time));
      return run.length;
    },
  };
}

test('a request during a frame never starts a second chain of frames', () => {
  const frames = fakeFrames();
  let drawn = 0;
  const loop = new DrawLoop({
    ...frames,
    settleMs: 1000,
    draw: () => {
      drawn++;
      // Spark's sort settled: it asks for another frame from inside the frame, every frame
      loop.request();
    },
  });
  loop.request();
  for (let i = 0; i < 100; i++) {
    assert.ok(frames.vsync() <= 1, `one frame per vsync at most (vsync ${i})`);
  }
  assert.equal(drawn, 100);
  assert.equal(frames.waiting, 1);
});

test('the loop stops a second after the last request, and starts again on the next one', () => {
  const frames = fakeFrames();
  const times = [];
  const loop = new DrawLoop({ ...frames, settleMs: 1000, draw: (now, last) => times.push([now, last]) });
  loop.request();
  let vsyncs = 0;
  while (frames.waiting && vsyncs < 1000) {
    frames.vsync();
    vsyncs++;
  }
  assert.equal(vsyncs, 63, 'about a second of frames at 60 Hz');
  assert.equal(times[0][1], null, 'the first frame has no frame before it');
  assert.equal(times[1][1], times[0][0]);
  frames.vsync(5000);
  assert.equal(times.length, 63, 'nothing drawn at rest');
  loop.request();
  frames.vsync();
  assert.equal(times.at(-1)[1], null, 'a frame after a pause does not count the pause');
});

test('something that keeps moving keeps the frames going', () => {
  const frames = fakeFrames();
  let moving = 200;
  const loop = new DrawLoop({
    ...frames,
    settleMs: 100,
    draw: (now) => {
      if (moving-- > 0) {
        loop.keep(now);
      }
    },
  });
  loop.request();
  let vsyncs = 0;
  while (frames.waiting && vsyncs < 1000) {
    frames.vsync();
    vsyncs++;
  }
  assert.ok(vsyncs >= 200 && vsyncs <= 210, `${vsyncs} frames`);
});
