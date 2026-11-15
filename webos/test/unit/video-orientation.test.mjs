// The turn of a video filmed upright whose player shows its frames as stored (issue 17, a Samsung TV): the EXIF
// orientation Immich reads from the file's rotation flag, the stored size, the size the player reports, the TV's box.

import {describe, test} from 'node:test';
import assert from 'node:assert/strict';
import {features} from '../../src/platform/features.ts';
import {
	autoTurnDegrees,
	defaultFit,
	fitMatters,
	lastVideoTurnLine,
	nextTurn,
	noteVideoTurn,
	quarterTurnOf,
	resolveVideoTurn,
	turnGeometry,
	videoTurn,
	videoTurnTransform,
} from '../../src/immuch360/video/orientation.ts';

const TV = {boxWidth: 1920, boxHeight: 1080};
// A phone's upright 1080p video: stored 1920 x 1080, flag -90 (Immich orientation "6")
const upright = {orientation: '6', width: 1920, height: 1080};

describe('quarterTurnOf', () => {
	test('6 is a quarter turn clockwise, 8 counter clockwise, as strings (the API) or numbers', () => {
		assert.equal(quarterTurnOf('6'), 90);
		assert.equal(quarterTurnOf(6), 90);
		assert.equal(quarterTurnOf('8'), 270);
		assert.equal(quarterTurnOf(8), 270);
	});

	test('no turn for 1, the half turn 3, unknown values and none', () => {
		for (const value of ['1', 1, '3', 3, '0', 'x', '', null, undefined]) assert.equal(quarterTurnOf(value), null, String(value));
	});
});

// A Samsung TV does not trust the reported size; webOS and browsers do
const SAMSUNG = {reportedSizeTellsTurn: false};
const LG = {reportedSizeTellsTurn: true};
const RULES = [SAMSUNG, LG];

describe('videoTurn', () => {
	test('frames shown as stored on a 16:9 TV: turned clockwise, scaled to the height of the screen, on every TV', () => {
		for (const rule of RULES) {
			const turn = videoTurn({...upright, frameWidth: 1920, frameHeight: 1080, ...TV}, rule);
			assert.deepEqual(turn, {degrees: 90, scaleX: 0.5625, scaleY: 0.5625});
			assert.equal(videoTurnTransform(turn), 'rotate(90deg) scale(0.5625)');
		}
	});

	test('orientation 8 turns counter clockwise (270 degrees clockwise)', () => {
		assert.deepEqual(videoTurn({...upright, orientation: '8', frameWidth: 1920, frameHeight: 1080, ...TV}, SAMSUNG), {degrees: 270, scaleX: 0.5625, scaleY: 0.5625});
	});

	test('a transcode keeping the flag (720p of a 4K original) still turns', () => {
		const turn = videoTurn({orientation: '6', width: 3840, height: 2160, frameWidth: 1280, frameHeight: 720, ...TV}, SAMSUNG);
		assert.deepEqual(turn, {degrees: 90, scaleX: 0.5625, scaleY: 0.5625});
	});

	test('the turned picture fits a box of another shape (4:3 frames, a 16:9 box)', () => {
		// Unturned: 1440 x 1080 at fit 1.125 from 1280 x 960. Turned: 960 x 1280 must fit 1080 high, so 0.84375 / 1.125
		const turn = videoTurn({orientation: '6', width: 1280, height: 960, frameWidth: 1280, frameHeight: 960, ...TV}, SAMSUNG);
		assert.deepEqual(turn, {degrees: 90, scaleX: 0.75, scaleY: 0.75});
	});

	test('issue 17: a Samsung TV reports the turned size of the 4K original and draws it on its side: turned, unstretched', () => {
		// The engine lays out 607.5 x 1080 for 2160 x 3840; the plane stretches the 3840 x 2160 frames into it. Scaled by
		// 1080 / 607.5 across and 607.5 / 1080 down, then turned, they stand 607.5 x 1080 with their own proportions.
		const reported = {orientation: '6', width: 3840, height: 2160, frameWidth: 2160, frameHeight: 3840, boxWidth: 1920, boxHeight: 1080};
		const turn = videoTurn(reported, SAMSUNG);
		assert.deepEqual(turn, {degrees: 90, scaleX: 1.7778, scaleY: 0.5625});
		assert.equal(videoTurnTransform(turn), 'rotate(90deg) scale(1.7778, 0.5625)');
		assert.deepEqual(videoTurn({...reported, orientation: '8'}, SAMSUNG), {degrees: 270, scaleX: 1.7778, scaleY: 0.5625});
		// The same in a 1280 x 720 viewport
		assert.deepEqual(videoTurn({...reported, boxWidth: 1280, boxHeight: 720}, SAMSUNG), {degrees: 90, scaleX: 1.7778, scaleY: 0.5625});
	});

	test('webOS and browsers: the turned size means the player turned the frames, nothing is done', () => {
		assert.equal(videoTurn({...upright, frameWidth: 1080, frameHeight: 1920, ...TV}, LG), null);
		assert.equal(videoTurn({orientation: '6', width: 3840, height: 2160, frameWidth: 2160, frameHeight: 3840, ...TV}, LG), null);
	});

	test('a Samsung TV leaves a smaller stream of the other shape: a transcode, which software transcoding turned', () => {
		assert.equal(videoTurn({orientation: '6', width: 3840, height: 2160, frameWidth: 720, frameHeight: 1280, ...TV}, SAMSUNG), null);
		assert.equal(videoTurn({...upright, frameWidth: 720, frameHeight: 1280, ...TV}, SAMSUNG), null);
		// The original size within 2% (a codec's padding) counts as the original
		assert.equal(autoTurnDegrees({...upright, frameWidth: 1080, frameHeight: 1904, ...TV}, SAMSUNG), 90);
	});

	test('nothing for a landscape video, a half turn, a square video, or a missing size', () => {
		for (const rule of RULES) {
			assert.equal(videoTurn({orientation: '1', width: 1920, height: 1080, frameWidth: 1920, frameHeight: 1080, ...TV}, rule), null);
			assert.equal(videoTurn({orientation: null, width: 1920, height: 1080, frameWidth: 1920, frameHeight: 1080, ...TV}, rule), null);
			assert.equal(videoTurn({orientation: '3', width: 1920, height: 1080, frameWidth: 1920, frameHeight: 1080, ...TV}, rule), null);
			assert.equal(videoTurn({orientation: '6', width: 1080, height: 1080, frameWidth: 1080, frameHeight: 1080, ...TV}, rule), null);
			assert.equal(videoTurn({orientation: '6', width: null, height: 1080, frameWidth: 1920, frameHeight: 1080, ...TV}, rule), null);
			assert.equal(videoTurn({...upright, frameWidth: 0, frameHeight: 0, ...TV}, rule), null);
			assert.equal(videoTurn({...upright, frameWidth: 1920, frameHeight: 1080, boxWidth: 0, boxHeight: 1080}, rule), null);
		}
	});

	test('no transform without a turn, nor for a turn that changes nothing', () => {
		assert.equal(videoTurnTransform(null), '');
		assert.equal(videoTurnTransform({degrees: 0, scaleX: 1, scaleY: 1}), '');
		assert.equal(videoTurnTransform({degrees: 180, scaleX: 1, scaleY: 1}), 'rotate(180deg)');
		assert.equal(videoTurnTransform({degrees: 0, scaleX: 3.1605, scaleY: 1}), 'scale(3.1605, 1)');
	});
});

describe('the turn chosen by hand', () => {
	const samsung4k = {orientation: '6', width: 3840, height: 2160, frameWidth: 2160, frameHeight: 3840, ...TV};

	test('each press is a quarter turn clockwise, the blue key a quarter back', () => {
		assert.deepEqual([0, 90, 180, 270].map((d) => nextTurn(d)), [90, 180, 270, 0]);
		assert.deepEqual([0, 90, 180, 270].map((d) => nextTurn(d, -1)), [270, 0, 90, 180]);
	});

	test('it replaces the turn of the viewer, on every TV', () => {
		for (const rule of RULES) {
			const none = resolveVideoTurn(samsung4k, {degrees: 0}, rule);
			assert.equal(none.source, 'manual');
			assert.equal(videoTurnTransform(none.turn), '');
			const half = resolveVideoTurn(samsung4k, {degrees: 180}, rule);
			assert.equal(videoTurnTransform(half.turn), 'rotate(180deg)');
		}
		const auto = resolveVideoTurn(samsung4k, null, SAMSUNG);
		assert.equal(auto.source, 'auto');
		assert.equal(videoTurnTransform(auto.turn), 'rotate(90deg) scale(1.7778, 0.5625)');
		assert.equal(resolveVideoTurn(samsung4k, null, LG).source, 'none');
	});

	test('a quarter turn: the proportions of the file on a Samsung TV, those the player reports elsewhere, or the chosen fit', () => {
		assert.equal(videoTurnTransform(resolveVideoTurn(samsung4k, {degrees: 90}, SAMSUNG).turn), 'rotate(90deg) scale(1.7778, 0.5625)');
		assert.equal(videoTurnTransform(resolveVideoTurn(samsung4k, {degrees: 90}, LG).turn), 'rotate(90deg) scale(1.7778)');
		assert.equal(videoTurnTransform(resolveVideoTurn(samsung4k, {degrees: 270, fit: 'player'}, SAMSUNG).turn), 'rotate(270deg) scale(1.7778)');
		assert.equal(videoTurnTransform(resolveVideoTurn(samsung4k, {degrees: 0, fit: 'file'}, SAMSUNG).turn), 'scale(3.1605, 1)');
		// Without the stored size the file's proportions are not known: those the player reports
		assert.equal(videoTurnTransform(turnGeometry({...samsung4k, width: null, height: null}, 90, 'file')), 'rotate(90deg) scale(1.7778)');
	});

	test('the fit matters only where the reported and stored proportions differ', () => {
		assert.equal(fitMatters(samsung4k), true);
		assert.equal(fitMatters({...upright, frameWidth: 1280, frameHeight: 720, ...TV}), false);
		assert.equal(fitMatters({...upright, width: null, frameWidth: 1080, frameHeight: 1920, ...TV}), false);
		assert.equal(defaultFit(90, SAMSUNG), 'file');
		assert.equal(defaultFit(180, SAMSUNG), 'player');
		assert.equal(defaultFit(90, LG), 'player');
	});
});

describe('the diagnostics line of the last video with a quarter turn flag', () => {
	const note = (input, manual, rule, applied, onScreen = null) =>
		noteVideoTurn(input, {platform: rule === SAMSUNG ? 'tizen' : 'webos', resolved: resolveVideoTurn(input, manual, rule), applied, onScreen});

	test('none before one played; a video without the flag or before the player knows its frames changes nothing', () => {
		assert.equal(lastVideoTurnLine(), 'none');
		note({orientation: '1', width: 1920, height: 1080, frameWidth: 1920, frameHeight: 1080, ...TV}, null, SAMSUNG, true);
		note({...upright, frameWidth: 0, frameHeight: 0, ...TV}, null, SAMSUNG, true);
		assert.equal(lastVideoTurnLine(), 'none');
	});

	test('the platform, the sizes the player reported, what was done and the element on screen', () => {
		note({...upright, frameWidth: 1920, frameHeight: 1080, ...TV}, null, SAMSUNG, true, {width: 607.5, height: 1080});
		assert.equal(
			lastVideoTurnLine(),
			'tizen, orientation 6, stored 1920 x 1080, player 1920 x 1080, element 1920 x 1080, auto rotate(90deg) scale(0.5625), on screen 608 x 1080'
		);
		note({...upright, frameWidth: 1080, frameHeight: 1920, ...TV}, null, LG, false);
		assert.equal(lastVideoTurnLine(), 'webos, orientation 6, stored 1920 x 1080, player 1080 x 1920, element 1920 x 1080, not turned');
		note({...upright, frameWidth: 1920, frameHeight: 1080, ...TV}, null, LG, false);
		assert.equal(lastVideoTurnLine(), 'webos, orientation 6, stored 1920 x 1080, player 1920 x 1080, element 1920 x 1080, auto rotate(90deg) scale(0.5625) left to the player');
	});

	test('issue 17 as the Samsung TV reported it, now turned; then a turn by hand, noted for a video without the flag too', () => {
		note({orientation: '6', width: 3840, height: 2160, frameWidth: 2160, frameHeight: 3840, ...TV}, null, SAMSUNG, true);
		assert.equal(
			lastVideoTurnLine(),
			'tizen, orientation 6, stored 3840 x 2160, player 2160 x 3840, element 1920 x 1080, auto rotate(90deg) scale(1.7778, 0.5625)'
		);
		note({orientation: '1', width: 1920, height: 1080, frameWidth: 1920, frameHeight: 1080, ...TV}, {degrees: 270}, SAMSUNG, true);
		assert.equal(
			lastVideoTurnLine(),
			'tizen, orientation 1, stored 1920 x 1080, player 1920 x 1080, element 1920 x 1080, by hand 270, fit file, rotate(270deg) scale(0.5625)'
		);
	});
});

describe('the platforms that turn', () => {
	test('a Samsung TV turns the video element; webOS and the browser leave it to their player', () => {
		assert.equal(features('tizen').turnSidewaysVideo, true);
		assert.equal(features('webos').turnSidewaysVideo, false);
		assert.equal(features('browser').turnSidewaysVideo, false);
	});

	test('only a Samsung TV distrusts the size its player reports', () => {
		assert.equal(features('tizen').reportedVideoSizeTellsTurn, false);
		assert.equal(features('webos').reportedVideoSizeTellsTurn, true);
		assert.equal(features('browser').reportedVideoSizeTellsTurn, true);
	});
});
