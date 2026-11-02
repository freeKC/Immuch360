// The drawing quality of the page (adapt.js): the scale steps down when frames stay slow, back up when fast, and one
// heavy line at the lowest scale.
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { median, quantile, Quality, SCALES } from '../../assets/splat_viewer/adapt.js';

const run = (quality, ms, seconds, from = 0) => {
  const changes = [];
  for (let now = from; now < from + seconds * 1000; now += ms) {
    const change = quality.frame(ms, now);
    if (change) changes.push({ change, now });
  }
  return changes;
};

test('slow frames for 2 s step the scale down, to 0.5 at most, then say heavy once', () => {
  const quality = new Quality();
  assert.equal(quality.scale, 1);
  const changes = run(quality, 60, 20);
  assert.deepEqual(changes.map((c) => c.change), ['down', 'down', 'heavy']);
  assert.equal(quality.scale, SCALES[SCALES.length - 1]);
});

test('fast frames step it back up; frames in between leave it', () => {
  const quality = new Quality();
  run(quality, 30, 3);
  assert.equal(quality.scale, 0.75);
  run(quality, 16, 10, 3000);
  assert.equal(quality.scale, 0.75);
  run(quality, 8, 3, 13000);
  assert.equal(quality.scale, 1);
});

test('a pause starts a new window', () => {
  const quality = new Quality();
  run(quality, 30, 1.5);
  quality.pause();
  assert.deepEqual(run(quality, 30, 1.5, 10000), []);
  assert.equal(quality.scale, 1);
});

test('median and quantile', () => {
  assert.equal(median([3, 1, 2]), 2);
  assert.equal(median([]), 0);
  assert.equal(quantile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.95), 10);
});
