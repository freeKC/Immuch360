// The navigator of the page (controls.js): looking, walking in the gaze's horizontal plane, the room to move, Turn
// around, the stick, the pinch and the gyroscope, without a browser.
import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  attachEscape,
  FAST,
  forwardOf,
  GYRO_NOISE,
  gyroTurn,
  inStickArea,
  isBrowserKey,
  keyInput,
  MAX_PITCH,
  Navigator,
  rightOf,
  stickSpeed,
} from '../../assets/splat_viewer/controls.js';
import { firstView } from '../../assets/splat_viewer/placement.js';

const near = (found, wanted, tolerance = 1e-9) =>
  assert.ok(Math.abs(found - wanted) <= tolerance, `${found} is not ${wanted}`);
const place = () => firstView({ low: [-10, -2, -10], high: [10, 2, 10] }, 'yUp');
const object = () => firstView({ low: [-0.3, -0.3, -0.3], high: [0.3, 0.3, 0.3] }, 'yUp');

test('a place opens in Walk, an object in Turn around, the eye where the first view puts it', () => {
  const walk = new Navigator(place());
  assert.equal(walk.mode, 'walk');
  assert.deepEqual(walk.camera().eye, [0, 1.6, 0]);
  const orbit = new Navigator(object());
  assert.equal(orbit.mode, 'orbit');
  orbit.camera().eye.forEach((value, axis) => near(value, [0, 1.6, 0][axis], 1e-9));
  const look = orbit.camera().look;
  near(look[2], -1, 1e-9);
});

test('drag: the content follows the finger, the horizon stays level, never past 85 degrees', () => {
  const nav = new Navigator(place());
  nav.look(0.5, 0);
  near(nav.yaw, 0.5);
  nav.look(0, 10);
  near(nav.pitch, MAX_PITCH);
  nav.look(0, -20);
  near(nav.pitch, -MAX_PITCH);
});

test('walking stays in the horizontal plane of the gaze, looking down does not sink', () => {
  const nav = new Navigator(place());
  nav.look(0, -1);
  for (let k = 0; k < 120; k++) {
    nav.step(1 / 60, { forward: 1 });
  }
  near(nav.eye[1], 1.6, 1e-12);
  assert.ok(nav.eye[2] < -1, 'went forward along -z');
  near(nav.eye[0], 0, 1e-9);
});

test('the speed follows the size of the place and eases in over about 0.2 s; Shift is three times faster', () => {
  const view = place();
  near(view.speed, 20 / 8);
  const nav = new Navigator(view);
  nav.step(0.2, { forward: 1 });
  const eased = Math.hypot(...nav.velocity);
  assert.ok(eased > 0.9 * view.speed && eased < view.speed, `${eased}`);
  const fast = new Navigator(view);
  for (let k = 0; k < 60; k++) {
    fast.step(1 / 60, { forward: 1 }, FAST);
  }
  near(Math.hypot(...fast.velocity), view.speed * FAST, 1e-3);
  const small = firstView({ low: [0, 0, 0], high: [3, 1, 3] }, 'yUp');
  assert.equal(small.speed, 0.5);
});

test('the room to move holds the eye, walking slows to nothing at its edge', () => {
  const nav = new Navigator(place());
  for (let k = 0; k < 6000; k++) {
    nav.step(1 / 60, { forward: 1 }, FAST);
  }
  assert.ok(nav.eye[2] >= nav.view.zone.low[2] - 1e-9);
  near(nav.eye[2], nav.view.zone.low[2], 0.05);
});

test('strafe and up and down, turning with the arrows', () => {
  const nav = new Navigator(place());
  for (let k = 0; k < 60; k++) {
    nav.step(1 / 60, { right: 1, up: 1 });
  }
  assert.ok(nav.eye[0] > 0.5 && nav.eye[1] > 2);
  nav.step(1, { turn: 1 });
  near(nav.yaw, Math.PI / 3);
  near(forwardOf(0)[2], -1);
  near(rightOf(0)[0], 1);
});

test('Turn around: drag goes around the object at its distance, the wheel comes closer, never through its middle', () => {
  const nav = new Navigator(object());
  const distance = nav.distance;
  nav.look(Math.PI / 2, 0);
  const offset = nav.eye.map((value, axis) => value - nav.center[axis]);
  near(Math.hypot(...offset), distance);
  near(offset[0], -distance, 1e-9);
  nav.zoom(1000);
  near(nav.distance, nav.minDistance);
  assert.ok(nav.minDistance > 0);
  nav.zoom(1 / 1e6);
  near(nav.distance, nav.maxDistance);
});

test('switching ways keeps the view where it is', () => {
  const nav = new Navigator(object());
  nav.look(0.4, 0.2);
  const before = nav.camera();
  nav.setMode('walk');
  const after = nav.camera();
  before.eye.forEach((value, axis) => near(value, after.eye[axis]));
  before.look.forEach((value, axis) => near(value, after.look[axis]));
  nav.setMode('orbit');
  const back = nav.camera();
  before.eye.forEach((value, axis) => near(value, back.eye[axis], 1e-9));
});

test('Reset puts back the first view and the way of the splat', () => {
  const nav = new Navigator(object());
  nav.setMode('walk');
  nav.step(1, { forward: 1 });
  nav.reset();
  assert.equal(nav.mode, 'orbit');
  near(nav.eye[2], 0, 1e-9);
});

test('the keys by position: W, A, S, D and the arrows in Walk; the arrows closer and farther in Turn around', () => {
  const walk = keyInput(new Set(['KeyW', 'KeyD', 'ShiftLeft']), 'walk');
  assert.equal(walk.forward, 1);
  assert.equal(walk.right, 1);
  assert.equal(walk.fast, true);
  assert.equal(keyInput(new Set(['ArrowUp']), 'walk').forward, 1);
  const orbit = keyInput(new Set(['ArrowUp']), 'orbit');
  assert.equal(orbit.forward, 0);
  assert.equal(orbit.orbitZoom, 1);
  assert.equal(keyInput(new Set(['KeyE']), 'walk').up, 1);
  assert.equal(keyInput(new Set(['PageDown']), 'walk').up, -1);
  assert.equal(keyInput(new Set(['ArrowLeft']), 'walk').turn, 1);
});

test('the browser keys do nothing: reload, print, find, the developer tools', () => {
  assert.ok(isBrowserKey({ code: 'F5' }));
  assert.ok(isBrowserKey({ code: 'KeyR', ctrlKey: true }));
  assert.ok(isBrowserKey({ code: 'KeyP', ctrlKey: true }));
  assert.ok(isBrowserKey({ code: 'KeyI', ctrlKey: true, shiftKey: true }));
  assert.ok(isBrowserKey({ code: 'F12' }));
  assert.ok(!isBrowserKey({ code: 'KeyR' }));
  assert.ok(!isBrowserKey({ code: 'KeyW', shiftKey: true }));
});

test('the stick sits in the lower left third, faster the further it is pushed, three times at the rim', () => {
  assert.ok(inStickArea(50, 900, 1080, 1000));
  assert.ok(!inStickArea(500, 900, 1080, 1000));
  assert.ok(!inStickArea(50, 300, 1080, 1000));
  assert.equal(stickSpeed(0), 0);
  near(stickSpeed(0.4), 0.5);
  assert.equal(stickSpeed(0.8), 1);
  near(stickSpeed(1), FAST);
  near(stickSpeed(2), FAST);
});

test('the gyroscope: the 360 viewer\'s rule, its noise threshold, and the screen turned', () => {
  // Turning the phone to the right (clockwise around its up axis, a negative rate) looks right: the yaw goes down
  assert.ok(gyroTurn(0, -1, 0.1, 0).yaw < 0);
  // Tilting its top towards the user (counterclockwise around its right axis) looks up
  assert.ok(gyroTurn(1, 0, 0.1, 0).pitch > 0);
  assert.deepEqual(gyroTurn(GYRO_NOISE / 2, -GYRO_NOISE / 2, 0.1, 0), { yaw: 0, pitch: 0 });
  // The top of the phone on the left: its x points up
  const left = gyroTurn(1, 0, 0.1, 90);
  near(left.yaw, 0.1);
  near(left.pitch, 0);
  const right = gyroTurn(1, 0, 0.1, 270);
  near(right.yaw, -0.1);
  const down = gyroTurn(1, 1, 0.1, 180);
  near(down.pitch, -0.1);
  near(down.yaw, -0.1);
});

/** A window that only takes key listeners, and a key event that records preventDefault */
function fakeWindow() {
  const listeners = new Set();
  return {
    addEventListener: (type, listener) => type === 'keydown' && listeners.add(listener),
    removeEventListener: (type, listener) => listeners.delete(listener),
    press(code, repeat = false) {
      const event = { code, key: code, repeat, prevented: false, preventDefault() { this.prevented = true; } };
      listeners.forEach((listener) => listener(event));
      return event;
    },
  };
}

test('Esc closes while the scene loads and on an error at once; once it shows, the sheet first', () => {
  // Review of 2 November 2026: two Esc on the error of a cut SPZ left the window of a computer open
  const target = fakeWindow();
  const state = { shown: false, failed: false, sheet: false, closes: 0 };
  const unbind = attachEscape(target, {
    shown: () => state.shown,
    failed: () => state.failed,
    hideSheet: () => {
      const was = state.sheet;
      state.sheet = false;
      return was;
    },
    close: () => state.closes++,
  });
  // Loading
  assert.equal(target.press('Escape').prevented, true);
  assert.equal(state.closes, 1);
  // The error sheet of a file that could not be read, before or after the scene showed
  state.failed = true;
  state.sheet = true;
  target.press('Escape');
  assert.equal(state.closes, 2);
  // Shown: the info sheet first, then the viewer
  state.failed = false;
  state.shown = true;
  state.sheet = true;
  target.press('Escape');
  assert.equal(state.closes, 2);
  assert.equal(state.sheet, false);
  target.press('Escape');
  assert.equal(state.closes, 3);
  // A held key repeats nothing; other keys are not its
  target.press('Escape', true);
  assert.equal(target.press('KeyW').prevented, false);
  assert.equal(state.closes, 3);
  unbind();
  target.press('Escape');
  assert.equal(state.closes, 3);
});
