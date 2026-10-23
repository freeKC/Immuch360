// Stand ins of the tizen and webapis objects of a Samsung TV, injected before the page by the end to end test
// (run.mjs, through the DevTools protocol). They answer as a 2021 TV would and record what the app asks of them in
// window.__tizenCalls, which the test reads: the remote keys asked for, the screen saver calls, exit().
// Members as in Samsung's API references (read 23 October 2026). Plain ES5: it runs on Chromium 69.
(function () {
	'use strict';
	var calls = {registered: [], batches: 0, screenSaver: [], exits: 0};
	window.__tizenCalls = calls;
	var KEYS = {
		ChannelUp: 427, ChannelDown: 428, MediaPlay: 415, MediaPause: 19, MediaPlayPause: 10252, MediaRewind: 412,
		MediaFastForward: 417, MediaStop: 413, MediaTrackPrevious: 10232, MediaTrackNext: 10233, Info: 457,
		ColorF0Red: 403, ColorF1Green: 404, ColorF2Yellow: 405, ColorF3Blue: 406, Exit: 10182,
		'0': 48, '1': 49, VolumeUp: 447, VolumeDown: 448, VolumeMute: 449
	};
	window.tizen = {
		application: {
			getCurrentApplication: function () {
				return {
					appInfo: {id: 'Immuch360T.Immuch360', name: 'Immuch360', version: window.__e2eVersion || '0.1.0'},
					exit: function () {
						calls.exits += 1;
					},
					hide: function () {}
				};
			},
			getAppInfo: function () {
				return {id: 'Immuch360T.Immuch360', name: 'Immuch360', version: window.__e2eVersion || '0.1.0'};
			}
		},
		tvinputdevice: {
			getSupportedKeys: function () {
				return Object.keys(KEYS).map(function (name) {
					return {name: name, code: KEYS[name]};
				});
			},
			getKey: function (name) {
				return KEYS[name] ? {name: name, code: KEYS[name]} : null;
			},
			registerKey: function (name) {
				if (!KEYS[name]) throw new Error('InvalidValuesError: ' + name);
				calls.registered.push(name);
			},
			registerKeyBatch: function (names, onSuccess) {
				calls.batches += 1;
				names.forEach(function (name) {
					calls.registered.push(name);
				});
				if (onSuccess) setTimeout(onSuccess, 0);
			},
			unregisterKey: function () {}
		},
		systeminfo: {
			getCapability: function (key) {
				return key === 'http://tizen.org/feature/platform.version' ? '6.0' : undefined;
			}
		}
	};
	window.webapis = {
		productinfo: {
			getModel: function () {
				return '21_E2E_HEADLESS';
			},
			getRealModel: function () {
				return 'E2E-HEADLESS';
			},
			getFirmware: function () {
				return 'T-E2E-0000.0';
			},
			getDuid: function () {
				return 'E2EDUIDNEVERSHOWN';
			},
			isUdPanelSupported: function () {
				return true;
			},
			is8KPanelSupported: function () {
				return false;
			}
		},
		appcommon: {
			AppCommonScreenSaverState: {SCREEN_SAVER_OFF: 0, SCREEN_SAVER_ON: 1},
			setScreenSaver: function (state, onSuccess) {
				calls.screenSaver.push(state);
				if (onSuccess) setTimeout(onSuccess, 0);
			}
		},
		avinfo: {
			isHdrTvSupport: function () {
				return false;
			}
		}
	};
})();
