'use strict';
/* eslint-disable no-var -- runs on webOS 4.x's Node 0.12.2 (see lib/pairing.js) */

// Luna services may be reclaimed between calls. Polling keeps this one alive
// while pairing is visible; ActivityManager covers gaps when available.
//
// Immuch360: the service is also the media bridge of the shares, Plex servers and cameras (bridge/src/index.js,
// bundled into bridge/base.js by tools/build-bridge.mjs). It runs on Node 8 and later (webOS 5 and later) and is loaded
// only there: on webOS 4 (Node 0.12) this file and the phone sign in stay as they were.

var Service = require('webos-service');
var pairing = require('./lib/pairing');
var serverLib = require('./lib/server');
var bridgeHost = require('./lib/bridge-host');

var SERVICE_ID = 'com.aprogsys.immuch360.service';
var BASE_PORT = 8788;
var PORT_TRIES = 5;

var service = new Service(SERVICE_ID);

var session = null;
var httpServer = null;
var httpPort = null;
// Immuch360: the address the phone page listens on, the TV's address on the home network
var httpHost = null;
// Immuch360: one activity per user of the service, the phone sign in ('pairing') and the media bridge ('bridge')
var activities = {};
// Immuch360: the end of the phone page, armed at each start: the page stops at the end of its session even when the app
// no longer asks for the status (closed, in the background, or polling given up)
var endTimer = null;
// Immuch360: how long an approved sign in waits for the app to take it before it is dropped from memory
var RESULT_GRACE_MS = 60 * 1000;

function holdActivity(name) {
	var key = name || 'pairing';
	if (activities[key]) return;
	activities[key] = 'pending';
	try {
		service.activityManager.create(key, function (a) {
			if (activities[key] === 'pending') activities[key] = a;
			else if (a) service.activityManager.complete(a);
		});
	} catch (e) {
		// Polling alone keeps the service alive on firmwares without ActivityManager.
		delete activities[key];
	}
}

function releaseActivity(name) {
	var key = name || 'pairing';
	var a = activities[key];
	delete activities[key];
	if (!a || a === 'pending') return;
	try {
		service.activityManager.complete(a);
	} catch (e) {
		// Local cleanup must continue if ActivityManager rejects completion.
	}
}

function clearEndTimer() {
	if (endTimer !== null) {
		clearTimeout(endTimer);
		endTimer = null;
	}
}

// Immuch360: the phone page only (the session stays, for the status the app asks next)
function closePage() {
	if (httpServer !== null) {
		try {
			httpServer.close();
		} catch (e) {
			// Clear local state even if the server is already closed.
		}
		httpServer = null;
		httpPort = null;
		httpHost = null;
	}
}

function teardown() {
	clearEndTimer();
	session = null;
	releaseActivity('pairing');
	closePage();
}

// Immuch360: everything stops at the time given (the end of the session, or the grace of an approved sign in)
function endAt(time) {
	clearEndTimer();
	endTimer = setTimeout(function () {
		endTimer = null;
		teardown();
	}, Math.max(0, time - Date.now()));
}

// Immuch360: what the phone page reports (lib/server.js): after an approved sign in the page stops and the session
// waits a minute for the app to take it; after the tenth wrong code everything stops
function onPageEnd(reason) {
	if (reason === 'approved') {
		closePage();
		endAt(Date.now() + RESULT_GRACE_MS);
		return;
	}
	teardown();
}

// Immuch360: the phone page listens on the TV's address on the home network only, not on every address of the TV; a
// new address (the TV changed networks) starts the server again there. Resolves with that address and the port.
function ensureServer() {
	var address = serverLib.lanIp();
	if (!address) return Promise.reject(new Error('TV has no network address'));
	if (httpServer !== null && httpHost === address) return Promise.resolve({host: address, port: httpPort});
	if (httpServer !== null) {
		try {
			httpServer.close();
		} catch (e) {
			// A server already closed is fine
		}
		httpServer = null;
		httpPort = null;
		httpHost = null;
	}
	var server = serverLib.createPairingServer({
		getSession: function () {
			return session;
		},
		onPageEnd: onPageEnd
	});
	return serverLib.listenOnFreePort(server, BASE_PORT, PORT_TRIES, address).then(function (port) {
		server.on('error', function (err) {
			console.error('[pairing] http server error', err);
		});
		httpServer = server;
		httpPort = port;
		httpHost = address;
		return {host: address, port: port};
	});
}

service.register('start', function (message) {
	var params = message.payload || {};
	var now = Date.now();
	// Reuse a pending session so remounting cannot invalidate a code being entered.
	if (pairing.statusOf(session, now) !== 'pending') {
		session = pairing.createSession(now, {suggestedUrl: params.suggestedUrl});
	}
	ensureServer().then(
		function (listening) {
			var url = serverLib.buildPairingUrl(listening.host, listening.port, session);
			holdActivity('pairing');
			endAt(session.expiresAt);
			message.respond({
				returnValue: true,
				url: url,
				code: session.code,
				port: listening.port,
				nodeVersion: process.version
			});
		},
		function (err) {
			teardown();
			// Immuch360: errorCode for the app, which shows its own text (no_address: the TV is offline); errorText for the log
			var noAddress = err && err.message === 'TV has no network address';
			var text = noAddress ? err.message : 'Could not start pairing server: ' + (err && err.message);
			message.respond({returnValue: false, errorCode: noAddress ? 'no_address' : 'listen_failed', errorText: text});
		}
	);
});

service.register('status', function (message) {
	var state = pairing.statusOf(session, Date.now());
	if (state === 'approved') {
		var result = pairing.consumeResult(session);
		message.respond({returnValue: true, state: 'approved', result: result});
		teardown();
		return;
	}
	if (state === 'expired') {
		teardown();
		message.respond({returnValue: true, state: 'expired'});
		return;
	}
	message.respond({returnValue: true, state: state});
});

service.register('cancel', function (message) {
	teardown();
	message.respond({returnValue: true});
});

/* ── Immuch360: the media bridge (lib/bridge-host.js) ── */

var host = bridgeHost.createHost({
	nodeVersion: process.versions.node,
	load: function () {
		return require('./bridge/base.js');
	},
	hold: function () {
		holdActivity('bridge');
	},
	release: function () {
		releaseActivity('bridge');
	},
	log: function (text) {
		console.log('[bridge] ' + text);
	}
});

function lunaMethod(name) {
	service.register(name, function (message) {
		host.handle(name, message.payload || {}).then(
			function (result) {
				message.respond(result);
			},
			function (err) {
				message.respond({returnValue: false, errorText: String((err && err.message) || err), errorCode: (err && err.code) || null});
			}
		);
	});
}

bridgeHost.METHODS.forEach(lunaMethod);
