// The session of a viewing as the page reads it (session.js): defaults for what is missing, texts filled.
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { fill, parseSession } from '../../assets/splat_viewer/session.js';

test('a full session', () => {
  const session = parseSession({
    scene: { url: '/t/s/scene.ply', type: 'ply', name: 'room.ply', bytes: 10, gaussians: 5, shown: 5, reduced: true },
    upright: 'zUp',
    device: 'phone',
    limits: { pixelRatioMax: 1, maxStdDev: 2.236 },
    gyroscope: true,
    locale: 'fr',
    texts: { reset: 'Recentrer' },
    theme: { dark: false, primary: '#123456' },
    events: 'events',
  });
  assert.equal(session.scene.type, 'ply');
  assert.equal(session.scene.reduced, true);
  assert.equal(session.upright, 'zUp');
  assert.equal(session.device, 'phone');
  assert.equal(session.limits.maxStdDev, 2.236);
  assert.equal(session.gyroscope, true);
  assert.equal(session.texts.reset, 'Recentrer');
  assert.equal(session.theme.dark, false);
  assert.equal(session.check, false);
});

test('defaults: a computer, no orientation, the limits of a computer', () => {
  const session = parseSession({ scene: { url: '/t/s/scene.spz' } });
  assert.equal(session.scene.type, 'spz');
  assert.equal(session.upright, null);
  assert.equal(session.device, 'computer');
  assert.equal(session.limits.pixelRatioMax, 1);
  assert.ok(Math.abs(session.limits.maxStdDev - Math.sqrt(8)) < 1e-12);
  assert.equal(session.gyroscope, false);
  assert.equal(parseSession({ scene: { url: 'x' }, upright: 'sideways' }).upright, null);
});

test('no scene, no session', () => {
  assert.throws(() => parseSession({}));
  assert.throws(() => parseSession(null));
});

test('the texts are filled by name, unknown names left as they are', () => {
  assert.equal(fill('Drawn at {fps} frames per second', { fps: 60 }), 'Drawn at 60 frames per second');
  assert.equal(fill('{a} and {b}', { a: 1 }), '1 and {b}');
  assert.equal(fill(undefined, {}), '');
});

test('the first frames are watched only when the app asks (a computer that shows the splat whole)', () => {
  assert.equal(parseSession({ scene: { url: 'x' } }).watch, null);
  assert.equal(parseSession({ scene: { url: 'x' }, watch: null }).watch, null);
  assert.deepEqual(parseSession({ scene: { url: 'x' }, watch: { floor: 150000 } }).watch, { floor: 150000 });
  assert.deepEqual(parseSession({ scene: { url: 'x' }, watch: {} }).watch, { floor: 150000 });
});
