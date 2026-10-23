'use strict';
/* eslint-disable no-var -- runs on webOS 4.x's Node 0.12.2 (see lib/pairing.js) */

// Plain-node test suite for the pairing service (no Jest: this code targets
// the TV's Node, down to 0.12.2 on webOS 4.x, and must stay runnable there).
// Run: node service/test.js

var assert = require('assert');
var http = require('http');
var pairing = require('./lib/pairing');
var immich = require('./lib/immich');
var serverLib = require('./lib/server');
var bridgeHost = require('./lib/bridge-host');

var tests = [];
function test(name, fn) {
	tests.push({name: name, fn: fn});
}

function postJson(port, path, body) {
	return immich.postJson('http://127.0.0.1:' + port + path, body);
}

/* ── pairing.js ── */

test('session lifecycle: pending → approved → consumed', function () {
	var t0 = 1000;
	var session = pairing.createSession(t0);
	assert.strictEqual(pairing.statusOf(session, t0), 'pending');
	assert.strictEqual(session.code.length, pairing.CODE_LENGTH);

	assert.strictEqual(pairing.checkCode(session, t0, 'WRONGCOD'), 'bad_code');
	assert.strictEqual(pairing.checkCode(session, t0, session.code), 'ok');
	assert.strictEqual(pairing.checkCode(session, t0, session.code.toLowerCase()), 'ok');

	assert.ok(pairing.markApproved(session, t0, {email: 'a@b.c'}));
	assert.strictEqual(pairing.statusOf(session, t0), 'approved');
	assert.strictEqual(pairing.checkCode(session, t0, session.code), 'not_pending');

	var result = pairing.consumeResult(session);
	assert.strictEqual(result.email, 'a@b.c');
	assert.strictEqual(pairing.consumeResult(session), null, 'result is single-delivery');
	assert.strictEqual(pairing.statusOf(session, t0), 'consumed');
});

test('session expires by time', function () {
	var t0 = 1000;
	var session = pairing.createSession(t0);
	var later = t0 + pairing.SESSION_TTL_MS;
	assert.strictEqual(pairing.statusOf(session, later), 'expired');
	assert.strictEqual(pairing.checkCode(session, later, session.code), 'expired');
	assert.strictEqual(pairing.markApproved(session, later, {}), false);
});

test('repeated bad codes burn the session', function () {
	var t0 = 1000;
	var session = pairing.createSession(t0);
	for (var i = 0; i < pairing.MAX_CODE_FAILURES; i++) {
		pairing.checkCode(session, t0, 'XXXXXXXX');
	}
	assert.strictEqual(pairing.statusOf(session, t0), 'expired');
});

test('no session behaves as expired', function () {
	assert.strictEqual(pairing.statusOf(null, 0), 'none');
	assert.strictEqual(pairing.checkCode(null, 0, 'ANYTHING'), 'expired');
});

test('codes avoid ambiguous characters', function () {
	assert.ok(!/[0O1IL]/.test(pairing.CODE_ALPHABET));
});

/* ── immich.js ── */

test('apiUrl mirrors APIClient normalization', function () {
	assert.strictEqual(immich.apiUrl('https://x.com'), 'https://x.com/api');
	assert.strictEqual(immich.apiUrl('https://x.com/'), 'https://x.com/api');
	assert.strictEqual(immich.apiUrl('https://x.com/api'), 'https://x.com/api');
	assert.strictEqual(immich.apiUrl('  https://x.com//  '), 'https://x.com/api');
});

test('login rejects non-http URLs without a network call', function () {
	return immich.login('ftp://x', 'a', 'b').then(function (res) {
		assert.strictEqual(res.ok, false);
		assert.ok(/http/.test(res.error));
	});
});

/* ── end-to-end against a stub Immich ── */

function withServers(stubHandler, body) {
	var session = null;
	var stub = http.createServer(stubHandler);
	var pairingServer = serverLib.createPairingServer({
		getSession: function () {
			return session;
		}
	});
	return new Promise(function (resolve) {
		stub.listen(0, '127.0.0.1', function () {
			pairingServer.listen(0, '127.0.0.1', function () {
				resolve({
					stubPort: stub.address().port,
					pairingPort: pairingServer.address().port,
					setSession: function (s) {
						session = s;
					}
				});
			});
		});
	}).then(function (ctx) {
		return Promise.resolve(body(ctx)).then(
			function () {
				stub.close();
				pairingServer.close();
			},
			function (err) {
				stub.close();
				pairingServer.close();
				throw err;
			}
		);
	});
}

test('approve: full happy path stores token and pending→approved', function () {
	return withServers(
		function (req, res) {
			assert.strictEqual(req.url, '/api/auth/login');
			res.writeHead(201, {'Content-Type': 'application/json'});
			res.end(JSON.stringify({accessToken: 'tok123'}));
		},
		function (ctx) {
			var session = pairing.createSession(Date.now());
			ctx.setSession(session);
			return postJson(ctx.pairingPort, '/approve', {
				code: session.code,
				serverUrl: 'http://127.0.0.1:' + ctx.stubPort,
				email: 'q@e.fr',
				password: 'secret'
			}).then(function (res) {
				assert.strictEqual(res.status, 200);
				assert.strictEqual(res.json.ok, true);
				var result = pairing.consumeResult(session);
				assert.strictEqual(result.accessToken, 'tok123');
				assert.strictEqual(result.email, 'q@e.fr');
				assert.strictEqual(result.baseUrl, 'http://127.0.0.1:' + ctx.stubPort);
			});
		}
	);
});

test('approve: wrong password leaves the session pending for a retry', function () {
	return withServers(
		function (req, res) {
			res.writeHead(401);
			res.end('{}');
		},
		function (ctx) {
			var session = pairing.createSession(Date.now());
			ctx.setSession(session);
			return postJson(ctx.pairingPort, '/approve', {
				code: session.code,
				serverUrl: 'http://127.0.0.1:' + ctx.stubPort,
				email: 'q@e.fr',
				password: 'nope'
			}).then(function (res) {
				assert.strictEqual(res.status, 401);
				assert.ok(/Invalid email or password/.test(res.json.error));
				assert.strictEqual(pairing.statusOf(session, Date.now()), 'pending');
			});
		}
	);
});

test('approve: wrong code never reaches Immich', function () {
	return withServers(
		function () {
			throw new Error('stub must not be called');
		},
		function (ctx) {
			var session = pairing.createSession(Date.now());
			ctx.setSession(session);
			return postJson(ctx.pairingPort, '/approve', {
				code: 'WRONGCOD',
				serverUrl: 'http://127.0.0.1:' + ctx.stubPort,
				email: 'q@e.fr',
				password: 'x'
			}).then(function (res) {
				assert.strictEqual(res.status, 400);
				assert.ok(/doesn't match/.test(res.json.error));
			});
		}
	);
});

test('approve: missing fields → 400', function () {
	return withServers(
		function () {},
		function (ctx) {
			return postJson(ctx.pairingPort, '/approve', {code: 'X'}).then(function (res) {
				assert.strictEqual(res.status, 400);
			});
		}
	);
});

test('GET / serves the sign-in page', function () {
	return withServers(
		function () {},
		function (ctx) {
			return new Promise(function (resolve, reject) {
				http.get('http://127.0.0.1:' + ctx.pairingPort + '/?c=ABCD2345', function (res) {
					var data = '';
					res.on('data', function (c) {
						data += c;
					});
					res.on('end', function () {
						try {
							assert.strictEqual(res.statusCode, 200);
							assert.ok(/Sign in to your TV/.test(data));
							resolve();
						} catch (e) {
							reject(e);
						}
					});
				});
			});
		}
	);
});

// Immuch360: the phone page listens on the address it is given (the service gives the TV's address on the home
// network), on the first free port from the base one
test('pairing server listens on the given address only, on the first free port', function () {
	var first = serverLib.createPairingServer({getSession: function () { return null; }});
	var second = serverLib.createPairingServer({getSession: function () { return null; }});
	var base = 18788 + Math.floor(Math.random() * 500);
	return serverLib
		.listenOnFreePort(first, base, 5, '127.0.0.1')
		.then(function (port) {
			assert.strictEqual(port, base);
			assert.strictEqual(first.address().address, '127.0.0.1');
			return serverLib.listenOnFreePort(second, base, 5, '127.0.0.1');
		})
		.then(function (port) {
			assert.strictEqual(port, base + 1, 'the next port when the first is taken');
			assert.strictEqual(second.address().address, '127.0.0.1');
			first.close();
			second.close();
		});
});

test('pairing server: without an address, every address (the computer of dev.js)', function () {
	var server = serverLib.createPairingServer({getSession: function () { return null; }});
	return serverLib.listenOnFreePort(server, 19400 + Math.floor(Math.random() * 500), 5).then(function () {
		assert.strictEqual(server.address().address, '0.0.0.0');
		server.close();
	});
});

test('the service binds the phone page to the TV address of the home network (lanIp)', function () {
	var source = require('fs').readFileSync(require('path').join(__dirname, 'service.js'), 'utf8');
	assert.ok(/listenOnFreePort\(server, BASE_PORT, PORT_TRIES, address\)/.test(source));
	assert.ok(/var address = serverLib\.lanIp\(\);/.test(source));
	assert.ok(!/0\.0\.0\.0/.test(source));
});

/* ── bridge-host.js (Immuch360: the Luna side of the media bridge) ── */

function fakeBridgeModule(log) {
	return {
		createBridge: function () {
			var running = false;
			var idle = 0;
			return {
				start: function (host) {
					running = true;
					log.push('start ' + host);
					return Promise.resolve({port: 1234, token: 'tok', host: host, node: 'v12.21.0', smb: true});
				},
				stop: function () {
					running = false;
					log.push('stop');
				},
				isRunning: function () {
					return running;
				},
				setSources: function (list) {
					log.push('sources ' + list.length);
					return {count: list.length, refused: []};
				},
				status: function () {
					return {running: running, sources: 1};
				},
				control: function (op, args) {
					if (op === 'fail') {
						var error = new Error('nope');
						error.code = 'x';
						return Promise.reject(error);
					}
					return Promise.resolve({echo: op, args: args});
				},
				setPlexClientId: function (id) {
					log.push('client ' + id);
				},
				touch: function () {
					idle = 0;
				},
				idleMs: function () {
					return idle;
				},
				setIdle: function (ms) {
					idle = ms;
				}
			};
		}
	};
}

test('bridge host: methods, activity held while it runs, released at stop', function () {
	var log = [];
	var host = bridgeHost.createHost({
		nodeVersion: '12.21.0',
		load: function () {
			return fakeBridgeModule(log);
		},
		hold: function () {
			log.push('hold');
		},
		release: function () {
			log.push('release');
		}
	});
	return host
		.handle('bridgeStart', {clientId: 'client-1234567890'})
		.then(function (res) {
			assert.strictEqual(res.returnValue, true);
			assert.strictEqual(res.port, 1234);
			assert.strictEqual(res.token, 'tok');
			return host.handle('bridgeSetSources', {sources: [{id: 'a'}, {id: 'b'}]});
		})
		.then(function (res) {
			assert.strictEqual(res.count, 2);
			return host.handle('bridgeCall', {op: 'discover', args: {kind: 'dlna'}});
		})
		.then(function (res) {
			assert.strictEqual(res.returnValue, true);
			assert.strictEqual(res.echo, 'discover');
			return host.handle('bridgeCall', {op: 'fail'}).then(
				function () {
					throw new Error('should fail');
				},
				function (err) {
					assert.strictEqual(err.code, 'x');
				}
			);
		})
		.then(function () {
			return host.handle('bridgeStop', {});
		})
		.then(function () {
			assert.deepEqual(log, ['client client-1234567890', 'start 127.0.0.1', 'hold', 'sources 2', 'stop', 'release']);
			host.stop();
		});
});

test('bridge host: refused on the Node of webOS 4, which keeps the phone sign in only', function () {
	var loaded = false;
	var host = bridgeHost.createHost({
		nodeVersion: '0.12.2',
		load: function () {
			loaded = true;
		},
		hold: function () {},
		release: function () {}
	});
	return host.handle('bridgeStart', {}).then(
		function () {
			throw new Error('should be refused');
		},
		function (err) {
			assert.strictEqual(err.code, 'needs_webos5');
			assert.strictEqual(loaded, false);
		}
	);
});

test('bridge host: a bridge left idle stops and releases its activity', function () {
	var log = [];
	var module_ = fakeBridgeModule(log);
	var made = null;
	var host = bridgeHost.createHost({
		nodeVersion: '8.12.0',
		load: function () {
			return {
				createBridge: function () {
					made = module_.createBridge();
					return made;
				}
			};
		},
		hold: function () {
			log.push('hold');
		},
		release: function () {
			log.push('release');
		},
		idleMs: 50,
		watchEveryMs: 20
	});
	return host
		.handle('bridgeStart', {lan: true})
		.then(function () {
			made.setIdle(1000);
			return new Promise(function (resolve) {
				setTimeout(resolve, 80);
			});
		})
		.then(function () {
			assert.deepEqual(log, ['start 0.0.0.0', 'hold', 'stop', 'release']);
			host.stop();
		});
});

/* ── runner ── */

var failed = 0;
function run(index) {
	if (index >= tests.length) {
		console.log(failed === 0 ? '\nAll ' + tests.length + ' tests passed' : '\n' + failed + ' test(s) FAILED');
		process.exit(failed === 0 ? 0 : 1);
	}
	var t = tests[index];
	Promise.resolve()
		.then(function () {
			return t.fn();
		})
		.then(
			function () {
				console.log('  ok  ' + t.name);
				run(index + 1);
			},
			function (err) {
				failed += 1;
				console.error('FAIL  ' + t.name);
				console.error('      ' + (err && err.message));
				run(index + 1);
			}
		);
}
run(0);
