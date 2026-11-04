// Save to Immich of the page (save.js, mark.js): the crop of the view to 3:2 or 2:3, the size of the poster, the check
// of a black capture, the final states, and the square of the mark.
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { MARK, MARK_PATH, markBox } from '../../assets/splat_viewer/mark.js';
import {
  cropRect,
  FINAL_STATES,
  isBlankCapture,
  isFinal,
  POSTER_LONG,
  posterSize,
  saveLines,
} from '../../assets/splat_viewer/save.js';

test('a landscape view is cropped to 3:2 in its middle, a portrait one to 2:3', () => {
  assert.deepEqual(cropRect(1920, 1080), { x: 150, y: 0, w: 1620, h: 1080 });
  assert.deepEqual(cropRect(1500, 1000), { x: 0, y: 0, w: 1500, h: 1000 });
  assert.deepEqual(cropRect(1200, 1000), { x: 0, y: 100, w: 1200, h: 800 });
  assert.deepEqual(cropRect(1080, 2340), { x: 0, y: 360, w: 1080, h: 1620 });
  assert.deepEqual(cropRect(1000, 1000), { x: 0, y: 166, w: 1000, h: 667 });
  for (const [width, height] of [[2560, 1440], [3840, 2160], [800, 600], [412, 915], [1, 1]]) {
    const crop = cropRect(width, height);
    assert.ok(crop.x >= 0 && crop.y >= 0 && crop.x + crop.w <= width && crop.y + crop.h <= height);
  }
});

test('the poster keeps the crop below 1,600 px and scales a larger one down to it, within the writer\'s shapes', () => {
  assert.deepEqual(posterSize(1620, 1080), { width: POSTER_LONG, height: 1067 });
  assert.deepEqual(posterSize(1080, 1620), { width: 1067, height: POSTER_LONG });
  assert.deepEqual(posterSize(1200, 800), { width: 1200, height: 800 });
  for (const [width, height] of [[1920, 1080], [3840, 2160], [1080, 2340], [1366, 768]]) {
    const crop = cropRect(width, height);
    const size = posterSize(crop.w, crop.h);
    const ratio = Math.max(size.width, size.height) / Math.min(size.width, size.height);
    assert.ok(ratio >= 1.25 && ratio <= 1.85, `${width}x${height}: ${ratio}`);
    assert.ok(Math.max(size.width, size.height) <= 2048);
  }
});

test('a black capture, or one of a flat colour, shows nothing; a scene does', () => {
  const width = 160;
  const height = 100;
  const black = new Uint8ClampedArray(4 * width * height);
  assert.equal(isBlankCapture(black, width, height), true);
  const grey = new Uint8ClampedArray(4 * width * height).fill(128);
  assert.equal(isBlankCapture(grey, width, height), true);
  const scene = new Uint8ClampedArray(4 * width * height);
  for (let i = 0; i < width * height; i++) {
    const x = i % width;
    scene[4 * i] = (x * 7) % 256;
    scene[4 * i + 1] = (i * 13) % 200;
    scene[4 * i + 2] = 60;
    scene[4 * i + 3] = 255;
  }
  assert.equal(isBlankCapture(scene, width, height), false);
  // A few lit points on black: something shows
  const sparse = new Uint8ClampedArray(4 * width * height);
  for (let y = 0; y < height; y += 4) {
    for (let x = 0; x < width; x += 4) {
      sparse.fill(255, 4 * (y * width + x), 4 * (y * width + x) + 3);
    }
  }
  assert.equal(isBlankCapture(sparse, width, height), false);
});

test('the states that end a save are those of the app', () => {
  for (const state of ['done', 'duplicate', 'alreadyThere', 'inTrash', 'failed', 'cancelled']) {
    assert.equal(isFinal(state), true, state);
  }
  for (const state of ['idle', 'converting', 'checking', 'drawing', 'writing', 'uploading']) {
    assert.equal(isFinal(state), false, state);
  }
  assert.equal(FINAL_STATES.length, 6);
});

test('the panel says the line of mobile data the app gives, after the warning; none on Wi-Fi', () => {
  const texts = { explain: 'It becomes a photo.' };
  const save = { name: 'room.spz', details: '150k', date: 'Nov 3', warning: null };
  assert.deepEqual(saveLines({ ...save, mobileData: 'You are on mobile data: 3.4 MiB to send' }, texts), [
    'room.spz',
    '150k',
    'Nov 3',
    null,
    'You are on mobile data: 3.4 MiB to send',
    'It becomes a photo.',
  ]);
  assert.deepEqual(saveLines(save, texts).filter(Boolean), ['room.spz', '150k', 'Nov 3', 'It becomes a photo.']);
});

test('the mark: 7 % of the short side at the bottom right, 3 % from the edges, the glyph of the tiles', () => {
  assert.deepEqual(markBox(1600, 1067), { left: 1600 - 32 - 75, top: 1067 - 32 - 75, side: 75, radius: 75 * 0.22 });
  assert.deepEqual(markBox(1067, 1600), { left: 1067 - 32 - 75, top: 1600 - 32 - 75, side: 75, radius: 75 * 0.22 });
  assert.equal(MARK.size, 0.07);
  assert.ok(MARK_PATH.startsWith('M2.02 6C'));
  assert.equal((MARK_PATH.match(/Z/g) ?? []).length, 8);
});
