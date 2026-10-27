// The key map of src/immuch360/keys.ts: the codes an LG remote sends, and the video policy of the Flutter TV app
// (remote_keys.dart on branch fix-tv-video-nav, 043225dde).

import {test, describe} from 'node:test';
import assert from 'node:assert/strict';
import {
	CONTROLS_HIDE_AFTER_MS,
	SEEK_STEP_SECONDS,
	keyShowsVideoControls,
	photoArrows,
	photoRotationStep,
	playPauseWantsPlay,
	remoteAction,
	videoArrows,
} from '../../src/immuch360/keys.ts';

describe('remoteAction', () => {
	test('maps the codes of an LG remote', () => {
		const table = [
			[37, 'left'], [38, 'up'], [39, 'right'], [40, 'down'], [13, 'ok'],
			[461, 'back'], [10009, 'back'], [27, 'back'],
			[33, 'channelUp'], [34, 'channelDown'],
			[415, 'play'], [19, 'pause'], [179, 'playPause'], [412, 'rewind'], [417, 'fastForward'], [413, 'stop'],
			[177, 'previousTrack'], [176, 'nextTrack'], [457, 'info'],
			[403, 'red'], [404, 'green'], [405, 'yellow'], [406, 'blue'],
		];
		for (const [keyCode, action] of table) assert.equal(remoteAction({keyCode}), action, String(keyCode));
	});

	test('falls back to the key name for codes it does not know', () => {
		assert.equal(remoteAction({keyCode: 0, key: 'GoBack'}), 'back');
		assert.equal(remoteAction({keyCode: 0, key: 'MediaPlayPause'}), 'playPause');
		assert.equal(remoteAction({keyCode: 0, key: 'ChannelUp'}), 'channelUp');
		assert.equal(remoteAction({keyCode: 73, key: 'i'}), 'info');
		assert.equal(remoteAction({keyCode: 65, key: 'a'}), null);
		assert.equal(remoteAction({keyCode: 0}), null);
	});

	test('1536 is Back, except the wheel of the Magic Remote', () => {
		assert.equal(remoteAction({keyCode: 1536, key: 'GoBack'}), 'back');
		assert.equal(remoteAction({keyCode: 1536}), 'back');
		assert.equal(remoteAction({keyCode: 1536, key: 'Unidentified'}), null);
	});

	test('8 is Back, except in a text field', () => {
		assert.equal(remoteAction({keyCode: 8, key: 'Backspace'}), 'back');
		assert.equal(remoteAction({keyCode: 8, key: 'Backspace'}, true), null);
	});
});

describe('the video policy of a TV', () => {
	test('Left and Right go to the neighbours whatever the video does, a video alone seeks', () => {
		assert.equal(videoArrows(true), 'navigate');
		assert.equal(videoArrows(false), 'seek');
	});

	test('the keys that bring back the controls, and those that do not', () => {
		for (const action of ['ok', 'up', 'down', 'play', 'pause', 'playPause', 'rewind', 'fastForward', 'channelUp', 'channelDown', 'red', 'stop']) {
			assert.equal(keyShowsVideoControls(action), true, action);
		}
		for (const action of ['left', 'right', 'previousTrack', 'nextTrack', 'back', 'info', null]) {
			assert.equal(keyShowsVideoControls(action), false, String(action));
		}
	});

	test('play always plays, pause always pauses, the toggle toggles', () => {
		assert.equal(playPauseWantsPlay('play', true), true);
		assert.equal(playPauseWantsPlay('play', false), true);
		assert.equal(playPauseWantsPlay('pause', true), false);
		assert.equal(playPauseWantsPlay('pause', false), false);
		assert.equal(playPauseWantsPlay('playPause', true), false);
		assert.equal(playPauseWantsPlay('playPause', false), true);
		assert.equal(playPauseWantsPlay('ok', false), null);
	});

	test('10 s steps, controls gone 5 s after the last key', () => {
		assert.equal(SEEK_STEP_SECONDS, 10);
		assert.equal(CONTROLS_HIDE_AFTER_MS, 5000);
	});
});

describe('one key turns a flat photo by 90°, as on Android TV', () => {
	test('yellow turns it clockwise, blue counterclockwise', () => {
		assert.equal(photoRotationStep(remoteAction({keyCode: 405})), 1);
		assert.equal(photoRotationStep(remoteAction({keyCode: 406})), -1);
	});

	test('R of a keyboard turns it clockwise, Shift R counterclockwise', () => {
		assert.equal(remoteAction({keyCode: 82, key: 'r'}), 'rotateRight');
		assert.equal(remoteAction({keyCode: 82, key: 'R', shiftKey: true}), 'rotateLeft');
		// Caps Lock without Shift
		assert.equal(remoteAction({keyCode: 82, key: 'R'}), 'rotateRight');
		assert.equal(photoRotationStep('rotateRight'), 1);
		assert.equal(photoRotationStep('rotateLeft'), -1);
	});

	test('R with Control, Alt or Meta, or typed in a text field, is not a turn', () => {
		assert.equal(remoteAction({keyCode: 82, key: 'r', ctrlKey: true}), null);
		assert.equal(remoteAction({keyCode: 82, key: 'r', altKey: true}), null);
		assert.equal(remoteAction({keyCode: 82, key: 'r', metaKey: true}), null);
		assert.equal(remoteAction({keyCode: 82, key: 'r'}, true), null);
	});

	test('the arrows never turn it, Up included (Up and Down zoom it, and a turn is saved on the server)', () => {
		assert.equal(photoRotationStep(remoteAction({keyCode: 38, key: 'ArrowUp'})), null);
		for (const action of ['up', 'down', 'left', 'right', 'ok', 'back', 'channelUp', 'info', 'red', 'green', null]) {
			assert.equal(photoRotationStep(action), null, String(action));
		}
	});

	test('the brackets of the web editor are no turn keys on the TV', () => {
		assert.equal(remoteAction({keyCode: 219, key: '['}), null);
		assert.equal(remoteAction({keyCode: 221, key: ']'}), null);
	});
});

// Discussion 8 (gthrepwood, 26 October 2026): Up and Down zoom a photo at once; OK, not an arrow, brings the controls
describe('the arrows on a flat photo', () => {
	test('on the photo: Left and Right go to the neighbours, Up zooms in, Down zooms out', () => {
		assert.deepEqual(photoArrows({zoomed: false, inActionBar: false}), {left: 'previous', right: 'next', up: 'zoomIn', down: 'zoomOut'});
	});

	test('zoomed in: the four arrows move the photo, none goes to a neighbour or zooms', () => {
		assert.deepEqual(photoArrows({zoomed: true, inActionBar: false}), {left: 'pan', right: 'pan', up: 'pan', down: 'pan'});
	});

	test('in the controls bar, zoomed or not: Left and Right move along it, Up goes back to the photo, Down does nothing', () => {
		for (const zoomed of [false, true]) {
			assert.deepEqual(photoArrows({zoomed, inActionBar: true}), {left: null, right: null, up: 'toStage', down: 'swallow'}, String(zoomed));
		}
	});
});
