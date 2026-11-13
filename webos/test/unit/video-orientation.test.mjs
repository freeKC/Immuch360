// The turn of a video filmed upright whose player shows its frames as stored (issue 17, a Samsung TV): the EXIF
// orientation Immich reads from the file's rotation flag, the stored size, the size the player reports, the TV's box.

import {describe, test} from 'node:test';
import assert from 'node:assert/strict';
import {features} from '../../src/platform/features.ts';
import {lastVideoTurnLine, noteVideoTurn, quarterTurnOf, videoTurn, videoTurnTransform} from '../../src/immuch360/video/orientation.ts';

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

describe('videoTurn', () => {
	test('frames shown as stored on a 16:9 TV: turned clockwise, scaled to the height of the screen', () => {
		const turn = videoTurn({...upright, frameWidth: 1920, frameHeight: 1080, ...TV});
		assert.deepEqual(turn, {degrees: 90, scale: 0.5625});
		assert.equal(videoTurnTransform(turn), 'rotate(90deg) scale(0.5625)');
	});

	test('orientation 8 turns counter clockwise (270 degrees clockwise)', () => {
		assert.deepEqual(videoTurn({...upright, orientation: '8', frameWidth: 1920, frameHeight: 1080, ...TV}), {degrees: 270, scale: 0.5625});
	});

	test('a transcode keeping the flag (720p of a 4K original) still turns', () => {
		const turn = videoTurn({orientation: '6', width: 3840, height: 2160, frameWidth: 1280, frameHeight: 720, ...TV});
		assert.deepEqual(turn, {degrees: 90, scale: 0.5625});
	});

	test('the turned picture fits a box of another shape (4:3 frames, a 16:9 box)', () => {
		// Unturned: 1440 x 1080 at fit 1.125 from 1280 x 960. Turned: 960 x 1280 must fit 1080 high, so 0.84375 / 1.125
		const turn = videoTurn({orientation: '6', width: 1280, height: 960, frameWidth: 1280, frameHeight: 960, ...TV});
		assert.deepEqual(turn, {degrees: 90, scale: 0.75});
	});

	test('nothing when the player or the server already turned the frames (portrait size reported)', () => {
		assert.equal(videoTurn({...upright, frameWidth: 1080, frameHeight: 1920, ...TV}), null);
		assert.equal(videoTurn({...upright, frameWidth: 720, frameHeight: 1280, ...TV}), null);
	});

	test('nothing for a landscape video, a half turn, a square video, or a missing size', () => {
		assert.equal(videoTurn({orientation: '1', width: 1920, height: 1080, frameWidth: 1920, frameHeight: 1080, ...TV}), null);
		assert.equal(videoTurn({orientation: null, width: 1920, height: 1080, frameWidth: 1920, frameHeight: 1080, ...TV}), null);
		assert.equal(videoTurn({orientation: '3', width: 1920, height: 1080, frameWidth: 1920, frameHeight: 1080, ...TV}), null);
		assert.equal(videoTurn({orientation: '6', width: 1080, height: 1080, frameWidth: 1080, frameHeight: 1080, ...TV}), null);
		assert.equal(videoTurn({orientation: '6', width: null, height: 1080, frameWidth: 1920, frameHeight: 1080, ...TV}), null);
		assert.equal(videoTurn({...upright, frameWidth: 0, frameHeight: 0, ...TV}), null);
		assert.equal(videoTurn({...upright, frameWidth: 1920, frameHeight: 1080, boxWidth: 0, boxHeight: 1080}), null);
	});

	test('no transform without a turn', () => {
		assert.equal(videoTurnTransform(null), '');
	});
});

describe('the diagnostics line of the last video with a quarter turn flag', () => {
	test('none before one played; a video without the flag or before the player knows its frames changes nothing', () => {
		assert.equal(lastVideoTurnLine(), 'none');
		noteVideoTurn({orientation: '1', width: 1920, height: 1080, frameWidth: 1920, frameHeight: 1080, ...TV}, null, true);
		noteVideoTurn({...upright, frameWidth: 0, frameHeight: 0, ...TV}, null, true);
		assert.equal(lastVideoTurnLine(), 'none');
	});

	test('the sizes the player reported and what was done', () => {
		const shown = {...upright, frameWidth: 1920, frameHeight: 1080, ...TV};
		noteVideoTurn(shown, videoTurn(shown), true);
		assert.equal(lastVideoTurnLine(), 'orientation 6, stored 1920 x 1080, player 1920 x 1080, box 1920 x 1080, rotate(90deg) scale(0.5625)');
		const honoured = {...upright, frameWidth: 1080, frameHeight: 1920, ...TV};
		noteVideoTurn(honoured, videoTurn(honoured), true);
		assert.equal(lastVideoTurnLine(), 'orientation 6, stored 1920 x 1080, player 1080 x 1920, box 1920 x 1080, not turned');
	});
});

describe('the platforms that turn', () => {
	test('a Samsung TV turns the video element; webOS and the browser leave it to their player', () => {
		assert.equal(features('tizen').turnSidewaysVideo, true);
		assert.equal(features('webos').turnSidewaysVideo, false);
		assert.equal(features('browser').turnSidewaysVideo, false);
	});
});
