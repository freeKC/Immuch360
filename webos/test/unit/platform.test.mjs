// The platform layer of src/platform/: which TV the page runs on, what it offers, and every Tizen call against stand
// ins of Samsung's tizen and webapis objects. Also the Samsung codes of the key map, the full-size cap of a Samsung TV
// and the error log of the About page.

import {afterEach, describe, test} from 'node:test';
import assert from 'node:assert/strict';
import {platform, isTizen} from '../../src/platform/detect.ts';
import {features, TIZEN_FULLSIZE_MAX_PIXELS} from '../../src/platform/features.ts';
import {
	TIZEN_KEYS,
	exitTizenApp,
	holdTizenScreenSaver,
	registerTizenKeys,
	setTizenScreenSaver,
	tizenAppInfo,
	tizenInfo,
	tizenScreenSaverHolds,
} from '../../src/platform/tizen.ts';
import {remoteAction} from '../../src/immuch360/keys.ts';
import {FULLSIZE_MAX_PIXELS, wantsFullsize} from '../../src/immuch360/photoSize.ts';
import {clearErrorLog, errorLine, lastErrors, policyLine, recordError, withoutKeys, withoutQuery} from '../../src/immuch360/diagnostics/errorLog.ts';

/** A Samsung TV as far as the app sees it, recording what the app asks of it */
function fakeSamsung({supported = TIZEN_KEYS, batchThrows = false, keyThrows = [], product = {}, hdr = true, avplay = true} = {}) {
	const calls = {batch: [], keys: [], screenSaver: [], exits: 0};
	const tv = {
		calls,
		tizen: {
			application: {
				getCurrentApplication: () => ({exit: () => calls.exits++}),
				getAppInfo: () => ({id: 'Immuch360T.Immuch360', name: 'Immuch360', version: '0.1.0'}),
			},
			tvinputdevice: {
				getSupportedKeys: () => supported.map((name, index) => ({name, code: 400 + index})),
				registerKey: (name) => {
					if (keyThrows.indexOf(name) >= 0) throw new Error(`unknown key ${name}`);
					calls.keys.push(name);
				},
				registerKeyBatch: (names) => {
					if (batchThrows) throw new Error('batch refused');
					calls.batch.push(...names);
				},
			},
			systeminfo: {getCapability: (key) => (key === 'http://tizen.org/feature/platform.version' ? '7.0' : undefined)},
		},
		webapis: {
			productinfo: {
				getRealModel: () => 'QE55Q80C',
				getModel: () => '23_PONTUSM_QTV',
				getFirmware: () => 'T-PTMDEUC-1440.5',
				isUdPanelSupported: () => true,
				is8KPanelSupported: () => false,
				...product,
			},
			appcommon: {
				AppCommonScreenSaverState: {SCREEN_SAVER_OFF: 0, SCREEN_SAVER_ON: 1},
				setScreenSaver: (state) => calls.screenSaver.push(state),
			},
			avinfo: {isHdrTvSupport: () => hdr},
			avplay: avplay ? {} : undefined,
		},
	};
	globalThis.window = {tizen: tv.tizen, webapis: tv.webapis};
	return tv;
}

afterEach(() => {
	delete globalThis.window;
});

describe('the platform', () => {
	test('Samsung, LG and a plain browser told apart', () => {
		assert.equal(platform({tizen: {application: {}}}), 'tizen');
		assert.equal(platform({WebOSServiceBridge: function bridge() {}}), 'webos');
		assert.equal(platform({PalmSystem: {}}), 'webos');
		assert.equal(platform({webOSSystem: {}}), 'webos');
		assert.equal(platform({}), 'browser');
		assert.equal(platform(undefined), 'browser');
		// A page that defines a tizen object of its own is no Samsung TV
		assert.equal(platform({tizen: {}}), 'browser');
		assert.equal(platform(), 'browser');
		fakeSamsung();
		assert.equal(platform(), 'tizen');
		assert.equal(isTizen(), true);
	});

	test('what each TV offers', () => {
		assert.deepEqual(features('tizen'), {
			phonePairing: false,
			sources: false,
			holdScreenSaverForVideo: true,
			exitOnRootBack: true,
			backClosesPopupFirst: true,
			pauseVideoWhenHidden: true,
			fullsizePixelCap: TIZEN_FULLSIZE_MAX_PIXELS,
		});
		// webOS keeps its behaviour: every Samsung only answer is off there
		for (const on of ['webos', 'browser']) {
			assert.deepEqual(
				features(on),
				{
					phonePairing: true,
					sources: true,
					holdScreenSaverForVideo: false,
					exitOnRootBack: false,
					backClosesPopupFirst: false,
					pauseVideoWhenHidden: false,
					fullsizePixelCap: null,
				},
				on
			);
		}
		assert.equal(TIZEN_FULLSIZE_MAX_PIXELS, 4032 * 3024);
	});
});

describe('the remote keys of a Samsung TV', () => {
	test('asked for in one batch, only those the TV has', () => {
		const tv = fakeSamsung({supported: ['ChannelUp', 'ChannelDown', 'MediaPlayPause', 'ColorF2Yellow', 'ColorF3Blue', 'Exit', '0', 'VolumeUp']});
		assert.deepEqual(registerTizenKeys(), ['ChannelUp', 'ChannelDown', 'MediaPlayPause', 'ColorF2Yellow', 'ColorF3Blue']);
		assert.deepEqual(tv.calls.batch, ['ChannelUp', 'ChannelDown', 'MediaPlayPause', 'ColorF2Yellow', 'ColorF3Blue']);
		assert.deepEqual(tv.calls.keys, []);
	});

	test('the numbers, the volume and Exit stay with the TV', () => {
		for (const name of ['0', '1', 'VolumeUp', 'VolumeDown', 'VolumeMute', 'Exit', 'Return', 'Enter']) {
			assert.equal(TIZEN_KEYS.indexOf(name), -1, name);
		}
	});

	test('key by key when the batch throws, a key the TV refuses left out', () => {
		const tv = fakeSamsung({batchThrows: true, keyThrows: ['MediaTrackNext']});
		const asked = registerTizenKeys();
		assert.equal(asked.indexOf('MediaTrackNext'), -1);
		assert.equal(asked.length, TIZEN_KEYS.length - 1);
		assert.deepEqual(tv.calls.keys, asked);
	});

	test('every key asked for when the TV does not list them, nothing off a Samsung TV', () => {
		const tv = fakeSamsung();
		tv.tizen.tvinputdevice.getSupportedKeys = () => {
			throw new Error('not supported');
		};
		assert.deepEqual(registerTizenKeys(), TIZEN_KEYS);
		delete globalThis.window;
		assert.deepEqual(registerTizenKeys(), []);
		globalThis.window = {tizen: {application: {}}};
		assert.deepEqual(registerTizenKeys(), []);
	});

	test('the Samsung codes in the shared key map', () => {
		const table = [
			[427, 'channelUp'],
			[428, 'channelDown'],
			[10252, 'playPause'],
			[10232, 'previousTrack'],
			[10233, 'nextTrack'],
			[10009, 'back'],
			[415, 'play'],
			[19, 'pause'],
			[412, 'rewind'],
			[417, 'fastForward'],
			[413, 'stop'],
			[457, 'info'],
			[405, 'yellow'],
			[406, 'blue'],
		];
		for (const [keyCode, action] of table) assert.equal(remoteAction({keyCode}), action, String(keyCode));
		// The keys of the Samsung keyboard are Enact's (src/platform/keymap.ts), not actions of the app
		assert.equal(remoteAction({keyCode: 65376}), null);
		assert.equal(remoteAction({keyCode: 65385}), null);
		assert.equal(remoteAction({keyCode: 10182}), null);
	});
});

describe('the screen saver of a Samsung TV', () => {
	test('off at the first hold, back on when the last one lets go', () => {
		const tv = fakeSamsung();
		const slideshow = holdTizenScreenSaver();
		const video = holdTizenScreenSaver();
		assert.deepEqual(tv.calls.screenSaver, [0]);
		assert.equal(tizenScreenSaverHolds(), 2);
		video();
		assert.deepEqual(tv.calls.screenSaver, [0]);
		// A release called twice counts once
		video();
		assert.equal(tizenScreenSaverHolds(), 1);
		slideshow();
		assert.deepEqual(tv.calls.screenSaver, [0, 1]);
		assert.equal(tizenScreenSaverHolds(), 0);
	});

	test('a TV without AppCommon, or one that throws, costs nothing', () => {
		const tv = fakeSamsung();
		tv.webapis.appcommon.setScreenSaver = () => {
			throw new Error('SecurityError');
		};
		assert.equal(setTizenScreenSaver(false), false);
		delete tv.webapis.appcommon;
		assert.equal(setTizenScreenSaver(false), false);
		const release = holdTizenScreenSaver();
		release();
		assert.equal(tizenScreenSaverHolds(), 0);
	});
});

describe('the app and the TV', () => {
	test('exit closes the app; false off a Samsung TV', () => {
		const tv = fakeSamsung();
		assert.equal(exitTizenApp(), true);
		assert.equal(tv.calls.exits, 1);
		delete globalThis.window;
		assert.equal(exitTizenApp(), false);
	});

	test('the id and version of the package', () => {
		fakeSamsung();
		assert.deepEqual(tizenAppInfo(), {id: 'Immuch360T.Immuch360', version: '0.1.0'});
		delete globalThis.window;
		assert.equal(tizenAppInfo(), null);
	});

	test('model, Tizen version, firmware, panel, HDR and AVPlay', () => {
		fakeSamsung();
		assert.deepEqual(tizenInfo(), {
			model: 'QE55Q80C',
			tizenVersion: '7.0',
			firmware: 'T-PTMDEUC-1440.5',
			uhdPanel: true,
			panel8k: false,
			hdr: true,
			avplay: true,
		});
	});

	test('an older TV: the model name when there is no real model, unknown for what throws', () => {
		fakeSamsung({
			product: {
				getRealModel: undefined,
				is8KPanelSupported: () => {
					throw new Error('NotSupportedError');
				},
			},
			hdr: null,
			avplay: false,
		});
		const info = tizenInfo();
		assert.equal(info.model, '23_PONTUSM_QTV');
		assert.equal(info.panel8k, null);
		assert.equal(info.hdr, null);
		assert.equal(info.avplay, false);
	});

	test('the DUID is never read', () => {
		const tv = fakeSamsung();
		let read = false;
		tv.webapis.productinfo.getDuid = () => {
			read = true;
			return 'SECRET';
		};
		assert.equal(JSON.stringify(tizenInfo()).indexOf('SECRET'), -1);
		assert.equal(read, false);
	});
});

describe('the full-size picture on a Samsung TV', () => {
	test('up to 12 MP, where an LG TV with the same engine takes 24 MP', () => {
		fakeSamsung();
		assert.equal(wantsFullsize(3, 4032, 3024), true);
		assert.equal(wantsFullsize(3, 4033, 3024), false);
		assert.equal(wantsFullsize(3, 6000, 4000), false);
		delete globalThis.window;
		assert.equal(wantsFullsize(3, 6000, 4000, FULLSIZE_MAX_PIXELS), true);
	});
});

describe('the last errors of the About page', () => {
	test('the last five kept, the oldest dropped', () => {
		clearErrorLog();
		for (let i = 1; i <= 7; i++) recordError(`error: ${i}`);
		assert.deepEqual(lastErrors(), ['error: 3', 'error: 4', 'error: 5', 'error: 6', 'error: 7']);
		clearErrorLog();
	});

	test('no sign in in what is kept: queries and keys hidden', () => {
		assert.equal(withoutQuery('http://nas:2283/api/assets/a1/video/playback?sessionKey=abc#t=1'), 'http://nas:2283/api/assets/a1/video/playback');
		assert.equal(withoutKeys('GET http://nas/api/x?apiKey=abc123&size=preview failed'), 'GET http://nas/api/x?apiKey=…&size=preview failed');
		assert.equal(withoutKeys('sessionKey=s3cr3t token=t0k'), 'sessionKey=… token=…');
		assert.equal(
			policyLine({effectiveDirective: 'img-src', blockedURI: 'http://nas:2283/api/assets/a1/thumbnail?size=preview&apiKey=abc'}),
			'policy: img-src blocked http://nas:2283/api/assets/a1/thumbnail'
		);
		assert.equal(policyLine({violatedDirective: 'script-src'}), 'policy: script-src blocked ?');
		assert.equal(errorLine('x is not a function', 'file:///opt/usr/apps/Immuch360T/res/wgt/main.js?v=1', 12), 'error: x is not a function (main.js:12)');
		clearErrorLog();
		recordError('error: http://nas/api/x?apiKey=abc');
		assert.deepEqual(lastErrors(), ['error: http://nas/api/x?apiKey=…']);
		clearErrorLog();
	});
});
