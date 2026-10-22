'use strict';
/* eslint-disable no-var -- runs on webOS 4.x's Node 0.12.2 (see lib/pairing.js) */

// Immuch360: the Luna side of the media bridge (bridge/src/index.js, bundled as bridge/base.js). The page starts it
// (bridgeStart: port and token of the loopback server), hands it the sources with their passwords and tokens
// (bridgeSetSources), polls bridgeStatus while it shows them (which keeps the service alive where ActivityManager
// does not), asks for discovery, tests and the Plex sign in (bridgeCall), and stops it (bridgeStop). An activity is
// held while the bridge runs; the bridge stops by itself after IDLE_MS without a call or a request, so that a closed app
// does not keep the service alive.
//
// This file is loaded on every webOS: it must stay plain ES5 for the Node 0.12 of webOS 4, where the bridge is refused.

var METHODS = ['bridgeStart', 'bridgeSetSources', 'bridgeStatus', 'bridgeCall', 'bridgeStop'];
var IDLE_MS = 120000;
var WATCH_EVERY_MS = 30000;

function nodeMajor(version) {
	return Number(String(version || '0').split('.')[0]) || 0;
}

function failure(message, code) {
	var error = new Error(message);
	error.code = code;
	return error;
}

/**
 * options: nodeVersion (process.versions.node), load () -> the bundle's module, hold () and release () of the activity,
 * log (text), idleMs and watchEveryMs (tests)
 */
function createHost(options) {
	var bridge = null;
	var loadError = null;
	var watchTimer = null;
	var idleMs = options.idleMs || IDLE_MS;

	function stop() {
		if (watchTimer !== null) {
			clearInterval(watchTimer);
			watchTimer = null;
		}
		if (bridge && bridge.isRunning()) bridge.stop();
		options.release();
	}

	function watch() {
		if (watchTimer !== null) return;
		watchTimer = setInterval(function () {
			if (bridge && bridge.isRunning() && bridge.idleMs() > idleMs) {
				if (options.log) options.log('idle, stopping');
				stop();
			}
		}, options.watchEveryMs || WATCH_EVERY_MS);
	}

	function ensureBridge() {
		if (bridge) return bridge;
		if (loadError) throw loadError;
		if (nodeMajor(options.nodeVersion) < 8) {
			loadError = failure('Shares, Plex and cameras need webOS 5 or later', 'needs_webos5');
			throw loadError;
		}
		try {
			bridge = options.load().createBridge({
				log: options.log
			});
		} catch (e) {
			loadError = failure('The media bridge could not load: ' + e.message, 'bridge_unavailable');
			throw loadError;
		}
		return bridge;
	}

	function handle(method, payload) {
		var params = payload || {};
		return new Promise(function (resolve) {
			resolve(ensureBridge());
		}).then(function (b) {
			if (method === 'bridgeStart') {
				if (params.clientId) b.setPlexClientId(params.clientId);
				return b.start(params.lan ? '0.0.0.0' : '127.0.0.1').then(function (info) {
					b.touch();
					options.hold();
					watch();
					return {returnValue: true, port: info.port, token: info.token, host: info.host, node: info.node, smb: info.smb};
				});
			}
			if (method === 'bridgeSetSources') {
				var result = b.setSources(params.sources || []);
				b.touch();
				return {returnValue: true, count: result.count, refused: result.refused};
			}
			if (method === 'bridgeStatus') {
				if (b.isRunning()) b.touch();
				var status = b.status();
				status.returnValue = true;
				return status;
			}
			if (method === 'bridgeCall') {
				return b.control(params.op, params.args || {}).then(function (answer) {
					var out = {returnValue: true};
					Object.keys(answer || {}).forEach(function (key) {
						out[key] = answer[key];
					});
					return out;
				});
			}
			if (method === 'bridgeStop') {
				stop();
				return {returnValue: true};
			}
			throw failure('Unknown method ' + method, 'unknown_method');
		});
	}

	return {handle: handle, stop: stop};
}

module.exports = {createHost: createHost, METHODS: METHODS, nodeMajor: nodeMajor};
