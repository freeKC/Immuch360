// The drawing quality of the page (adapt.js): the scale steps down when frames stay slow, back up when fast, and one
// heavy line at the lowest scale.
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { median, quantile, Quality, scalesFor } from '../../assets/splat_viewer/adapt.js';

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
  assert.equal(quality.scale, 0.5);
});

test('a computer starts at two pixels per CSS pixel and steps down to half a pixel, as a phone does', () => {
  // Review of 2 November 2026: a 200 % panel was drawn at a quarter of its pixels, stretched
  assert.deepEqual(scalesFor(1), [1, 0.75, 0.5]);
  assert.deepEqual(scalesFor(2), [1, 0.75, 0.5, 0.375, 0.25]);
  assert.deepEqual(scalesFor(1.5), [1, 0.75, 0.5, 0.375]);
  const quality = new Quality(2);
  assert.equal(quality.scale, 1);
  const changes = run(quality, 60, 30);
  assert.deepEqual(changes.map((c) => c.change), ['down', 'down', 'down', 'down', 'heavy']);
  assert.equal(2 * quality.scale, 0.5);
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

test('frames too long for ten in 2 s step it down once they fill the window (4 fps, review of 4 November 2026)', () => {
  const quality = new Quality(2);
  const changes = run(quality, 230, 12, 230);
  assert.deepEqual(changes.map((c) => c.change), ['down', 'down', 'down', 'down', 'heavy']);
  assert.ok(changes[0].now <= 2300, `the first step after one window: ${changes[0].now}`);
  // A single frame of 9.5 s fills it alone
  const crawl = new Quality(2);
  assert.equal(crawl.frame(16, 0), null);
  assert.equal(crawl.frame(9500, 9500), 'down');
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
