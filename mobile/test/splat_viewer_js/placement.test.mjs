// placement.js against viewer_expected.json (make_viewer_fixtures.py), which SplatPlacementViewerTest.kt checks the
// Quest's SplatPlacement against too: the same bounds, object or place, floor rule and first view.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import {
  boundsOf,
  DEFAULT_UPRIGHT,
  firstView,
  floorUprightOf,
  isObject,
  nextUpright,
  openingUpright,
  percentile,
  pitchOf,
  rotateX,
  sampleOf,
  verticalFov,
  worldBounds,
} from '../../assets/splat_viewer/placement.js';

const expected = JSON.parse(readFileSync(new URL('../fixtures/splat_viewer/viewer_expected.json', import.meta.url)));
const cases = Object.entries(expected).filter(([name]) => name !== 'about');

const near = (found, wanted, tolerance = 1e-9) =>
  assert.ok(Math.abs(found - wanted) <= tolerance, `${found} is not ${wanted}`);

test('every case of viewer_expected.json: bounds, object or place, floor rule, first view', () => {
  assert.ok(cases.length >= 8);
  for (const [name, wanted] of cases) {
    const positions = Float64Array.from(wanted.positions);
    assert.deepEqual(sampleOf(wanted.count), { stride: wanted.stride, samples: positions.length / 3 }, name);
    const bounds = boundsOf(positions);
    for (const side of ['low', 'high']) {
      bounds[side].forEach((value, axis) => near(value, wanted.bounds[side][axis], 1e-12));
    }
    assert.equal(isObject(bounds), wanted.object, name);
    assert.equal(floorUprightOf(positions, bounds), wanted.floorUpright, name);
    const upright = openingUpright(null, positions, bounds);
    assert.equal(upright, wanted.upright, name);
    const view = firstView(bounds, upright);
    near(view.size, wanted.size, 1e-12);
    near(view.pitch, wanted.view.pitch, 1e-12);
    near(view.distance, wanted.view.distance, 1e-9);
    near(view.speed, wanted.view.speed, 1e-12);
    view.position.forEach((value, axis) => near(value, wanted.view.position[axis], 1e-9));
    view.center.forEach((value, axis) => near(value, wanted.view.target[axis], 1e-9));
  }
});

test('a choice the user made for the file wins over the floor rule', () => {
  const [, room] = cases.find(([name]) => name === 'room_floor.spz');
  const positions = Float64Array.from(room.positions);
  const bounds = boundsOf(positions);
  assert.equal(openingUpright(null, positions, bounds), 'yUp');
  assert.equal(openingUpright('zUp', positions, bounds), 'zUp');
  assert.equal(openingUpright('nonsense', positions, bounds), 'yUp');
});

test('Turn upright cycles Y up, Z up, Y down as on the headset, from Y down by default', () => {
  assert.equal(DEFAULT_UPRIGHT, 'yDown');
  assert.equal(nextUpright('yDown'), 'yUp');
  assert.equal(nextUpright('yUp'), 'zUp');
  assert.equal(nextUpright('zUp'), 'yDown');
  assert.equal(nextUpright(undefined), 'yUp');
});

test('the pitches are the headset\'s with the z mirror: Z up turns z to y', () => {
  const z = rotateX(pitchOf('zUp'), [0, 0, 1]);
  near(z[1], 1, 1e-12);
  near(z[2], 0, 1e-12);
  const y = rotateX(pitchOf('yDown'), [0, 1, 0]);
  near(y[1], -1, 1e-12);
  assert.equal(pitchOf('yUp'), 0);
});

test('percentiles as relief-v1 takes them', () => {
  const sorted = Float64Array.from([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]);
  assert.equal(percentile(sorted, 5), 1);
  assert.equal(percentile(sorted, 95), 19);
  assert.equal(percentile(Float64Array.from([7]), 5), 7);
});

test('no positions, or one that is not a number: no bounds, the origin 2 m ahead', () => {
  assert.equal(boundsOf(new Float32Array(0)), null);
  assert.equal(boundsOf(Float32Array.from([0, 0, 0, NaN, 1, 1])), null);
  const view = firstView(null, 'yDown');
  assert.equal(view.object, false);
  assert.deepEqual(view.position, [0, 1.3, -2]);
});

test('the narrower side of the screen spans 60 degrees, in landscape and in portrait', () => {
  assert.equal(verticalFov(16 / 9), 60);
  const portrait = verticalFov(1080 / 2340);
  const horizontal = (2 * Math.atan(Math.tan((portrait * Math.PI) / 360) * (1080 / 2340)) * 180) / Math.PI;
  near(horizontal, 60, 1e-9);
  assert.ok(portrait > 100 && portrait < 120);
});

test('an object fits the narrower side whatever way it is turned; a place has its centre under the eye', () => {
  const [, axes] = cases.find(([name]) => name === 'axes_v2.spz');
  const bounds = boundsOf(Float64Array.from(axes.positions));
  for (const upright of ['yUp', 'zUp', 'yDown']) {
    const view = firstView(bounds, upright);
    const world = worldBounds(bounds, view.pitch, view.position);
    const half = Math.PI / 6;
    for (let corner = 0; corner < 8; corner++) {
      const point = [0, 1, 2].map((axis) => ((corner >> axis) & 1 ? world.high[axis] : world.low[axis]));
      const depth = view.eye[2] - point[2];
      assert.ok(depth > 0, 'in front of the eye');
      assert.ok(Math.abs(point[0] - view.eye[0]) / depth < Math.tan(half) * 1.0001, `${upright} x`);
      assert.ok(Math.abs(point[1] - view.eye[1]) / depth < Math.tan(half) * 1.0001, `${upright} y`);
    }
  }
  const [, room] = cases.find(([name]) => name === 'room_colmap.spz');
  const roomBounds = boundsOf(Float64Array.from(room.positions));
  const view = firstView(roomBounds, 'yDown');
  const world = worldBounds(roomBounds, view.pitch, view.position);
  near((world.low[1] + world.high[1]) / 2, 1.6 - 0.3, 1e-9);
  near((world.low[0] + world.high[0]) / 2, 0, 1e-9);
  assert.ok(view.zone.low[0] <= world.low[0] - 2 && view.zone.high[2] >= world.high[2] + 2);
});
