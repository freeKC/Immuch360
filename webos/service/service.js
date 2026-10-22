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
// Immuch360: one activity per user of the service, the phone sign in ('pairing') and the media bridge ('bridge')
var activities = {};

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

function teardown() {
	session = null;
	releaseActivity('pairing');
	if (httpServer !== null) {
		try {
			httpServer.close();
		} catch (e) {
			// Clear local state even if the server is already closed.
		}
		httpServer = null;
		httpPort = null;
	}
}

function ensureServer() {
	if (httpServer !== null) return Promise.resolve(httpPort);
	var server = serverLib.createPairingServer({
		getSession: function () {
			return session;
		}
	});
	return serverLib.listenOnFreePort(server, BASE_PORT, PORT_TRIES).then(function (port) {
		server.on('error', function (err) {
			console.error('[pairing] http server error', err);
		});
		httpServer = server;
		httpPort = port;
		return port;
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
		function (port) {
			var url = serverLib.buildPairingUrl(serverLib.lanIp(), port, session);
			if (!url) {
				teardown();
				message.respond({returnValue: false, errorText: 'TV has no network address'});
				return;
			}
			holdActivity('pairing');
			message.respond({
				returnValue: true,
				url: url,
				code: session.code,
				port: port,
				nodeVersion: process.version
			});
		},
		function (err) {
			teardown();
			message.respond({returnValue: false, errorText: 'Could not start pairing server: ' + err.message});
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
