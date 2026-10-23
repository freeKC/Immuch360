'use strict';
/* eslint-disable no-var -- runs on webOS 4.x's Node 0.12.2 (see lib/pairing.js) */

// Session control stays on the TV's Luna bus; the phone-facing server exposes
// only sign-in and approval. dev.js adds desktop-only control routes.

/* global __dirname */
var http = require('http');
var fs = require('fs');
var os = require('os');
var path = require('path');
var Buffer = require('buffer').Buffer;
var pairing = require('./pairing');
var immich = require('./immich');

var MAX_BODY_BYTES = 16 * 1024;

var pageCache = null;
function verifyPage() {
	if (pageCache === null) {
		pageCache = fs.readFileSync(path.join(__dirname, '..', 'verify.html'));
	}
	return pageCache;
}

function lanIp() {
	var interfaces = os.networkInterfaces();
	var names = Object.keys(interfaces);
	for (var i = 0; i < names.length; i++) {
		var addresses = interfaces[names[i]] || [];
		for (var j = 0; j < addresses.length; j++) {
			var addr = addresses[j];
			if (addr.family === 'IPv4' && !addr.internal) return addr.address;
		}
	}
	return null;
}

function buildPairingUrl(host, port, session) {
	if (!host) return null;
	var url = 'http://' + host + ':' + port + '/?c=' + session.code;
	if (session.suggestedUrl) url += '&u=' + encodeURIComponent(session.suggestedUrl);
	return url;
}

function readBody(req) {
	return new Promise(function (resolve, reject) {
		var size = 0;
		var chunks = [];
		req.on('data', function (chunk) {
			size += chunk.length;
			if (size > MAX_BODY_BYTES) {
				reject(new Error('body_too_large'));
				req.destroy();
				return;
			}
			chunks.push(chunk);
		});
		req.on('end', function () {
			resolve(Buffer.concat(chunks).toString('utf8'));
		});
		req.on('error', reject);
	});
}

function sendJson(res, status, body, extraHeaders) {
	var payload = JSON.stringify(body);
	var headers = {'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload, 'utf8')};
	var extra = extraHeaders || {};
	Object.keys(extra).forEach(function (key) {
		headers[key] = extra[key];
	});
	res.writeHead(status, headers);
	res.end(payload, 'utf8');
}

function createPairingServer(context) {
	var now = context.now || Date.now;

	function handleApprove(req, res) {
		readBody(req)
			.then(function (raw) {
				var body = null;
				try {
					body = JSON.parse(raw);
				} catch (e) {
					// Invalid JSON is handled by the request validation below.
				}
				if (!body || !body.serverUrl || !body.email || !body.password) {
					sendJson(res, 400, {ok: false, error: 'Fill in every field'});
					return;
				}
				var session = context.getSession();
				var codeStatus = pairing.checkCode(session, now(), body.code);
				if (codeStatus !== 'ok') {
					var message =
						codeStatus === 'bad_code'
							? "That code doesn't match the one on the TV"
							: 'This pairing session has expired. Start again on the TV.';
					sendJson(res, 400, {ok: false, error: message});
					return;
				}
				// Authenticate before approval so a bad password leaves the session retryable.
				immich.login(body.serverUrl, body.email, body.password).then(function (login) {
					if (!login.ok) {
						sendJson(res, 401, {ok: false, error: login.error});
						return;
					}
					pairing.markApproved(session, now(), {
						baseUrl: immich.normalizeBaseUrl(body.serverUrl),
						email: String(body.email),
						accessToken: login.accessToken
					});
					sendJson(res, 200, {ok: true});
				});
			})
			.catch(function () {
				sendJson(res, 400, {ok: false, error: 'Invalid request'});
			});
	}

	var server = http.createServer(function (req, res) {
		var pathname = String(req.url || '/').split('?')[0];
		if (context.extraRoutes && context.extraRoutes(req, res, pathname)) return;
		if (req.method === 'GET' && (pathname === '/' || pathname === '/index.html')) {
			res.writeHead(200, {'Content-Type': 'text/html; charset=utf-8'});
			res.end(verifyPage());
			return;
		}
		if (req.method === 'POST' && pathname === '/approve') {
			handleApprove(req, res);
			return;
		}
		sendJson(res, 404, {ok: false, error: 'Not found'});
	});

	return server;
}

// Immuch360: host is the address to listen on; the service gives the TV's address on the home network (lanIp), so the
// phone page answers there only (LG's vulnerability scan; PRIVACY.md); dev.js keeps every address of the computer.
function listenOnFreePort(server, basePort, tries, host) {
	var address = host || '0.0.0.0';
	return new Promise(function (resolve, reject) {
		var attempt = 0;
		// Immuch360: each attempt removes its own listeners: the callback of a listen() that failed used to stay
		// registered and resolve with the port that was taken when the next one succeeded
		function tryListen() {
			var port = basePort + attempt;
			function onError(err) {
				server.removeListener('listening', onListening);
				if (err && err.code === 'EADDRINUSE' && attempt + 1 < tries) {
					attempt += 1;
					tryListen();
					return;
				}
				reject(err);
			}
			function onListening() {
				server.removeListener('error', onError);
				resolve(port);
			}
			server.once('error', onError);
			server.once('listening', onListening);
			server.listen(port, address);
		}
		tryListen();
	});
}

module.exports = {
	createPairingServer: createPairingServer,
	listenOnFreePort: listenOnFreePort,
	sendJson: sendJson,
	readBody: readBody,
	lanIp: lanIp,
	buildPairingUrl: buildPairingUrl
};
