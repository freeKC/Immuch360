// The key map of src/immuch360/keys.ts: the codes an LG remote sends, and the video policy of the Flutter TV app
// (remote_keys.dart on branch fix-tv-video-nav, 043225dde).

import {test, describe} from 'node:test';
import assert from 'node:assert/strict';
import {
	CONTROLS_HIDE_AFTER_MS,
	SEEK_STEP_SECONDS,
	keyShowsVideoControls,
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
