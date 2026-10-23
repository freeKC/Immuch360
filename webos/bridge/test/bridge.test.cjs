'use strict';
const test = require('node:test');
const assert = require('node:assert');
const {createCache, createLimiter, createBridge} = require('../src/index');
const {normalizeSource} = require('../src/sources');
const {startServer, fetchJson, fetchRaw, startBridge} = require('./helpers');

test('sources are checked; refused ones are said', () => {
	assert.ok(normalizeSource({id: 'a', kind: 'webdav', url: 'ftp://x'}) instanceof Error);
	assert.ok(normalizeSource({id: 'a b', kind: 'webdav', url: 'http://x'}) instanceof Error);
	assert.strictEqual(normalizeSource({id: 'a', kind: 'smb', host: 'nas', share: '/media/', root: '\\Photos\\2026\\'}).root, 'Photos/2026');
	assert.strictEqual(normalizeSource({id: 'a', kind: 'smb', host: 'nas', share: '/media/'}).share, 'media');
	assert.strictEqual(normalizeSource({id: 'a', kind: 'tapo', host: 'cam'}).port, 554);
	assert.strictEqual(normalizeSource({id: 'p', kind: 'plex', address: '10.0.0.2', hash: 'nothex'}).hash, null);
	const bridge = createBridge({});
	const result = bridge.setSources([{id: 'ok', kind: 'dlna', location: 'http://10.0.0.5/d.xml'}, {id: 'bad', kind: 'gopher'}, null]);
	assert.strictEqual(result.count, 1);
	assert.strictEqual(result.refused.length, 2);
});

test('the cache keeps the most recent entries within its size', () => {
	const cache = createCache(10, 100);
	cache.set('a', 'A', 4);
	cache.set('b', 'B', 4);
	cache.get('a');
	cache.set('c', 'C', 4);
	assert.strictEqual(cache.get('b'), undefined);
	assert.strictEqual(cache.get('a'), 'A');
	assert.strictEqual(cache.get('c'), 'C');
});

test('the limiter runs at most n tasks at a time and passes failures on', async () => {
	const limit = createLimiter(2);
	let running = 0;
	let most = 0;
	const task = () =>
		new Promise((resolve) => {
			running++;
			most = Math.max(most, running);
			setTimeout(() => {
				running--;
				resolve();
			}, 10);
		});
	await Promise.all([1, 2, 3, 4, 5].map(() => limit(task)));
	assert.strictEqual(most, 2);
	await assert.rejects(limit(() => {
		throw new Error('sync');
	}));
});

test('control: a source is tested before it is saved, discovery answers even when nothing answers', async (t) => {
	const dav = await startServer((req, res) => {
		res.writeHead(207, {'Content-Type': 'application/xml'});
		res.end('<D:multistatus xmlns:D="DAV:"><D:response><D:href>/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response><D:response><D:href>/a.jpg</D:href><D:propstat><D:prop><D:getcontentlength>3</D:getcontentlength></D:prop></D:propstat></D:response></D:multistatus>');
	});
	const b = await startBridge([], {discoveryOptions: {addresses: [], sweep: false}});
	t.after(() => {
		b.stop();
		return dav.close();
	});
	const tested = await b.bridge.control('test', {source: {id: 'new', kind: 'webdav', url: dav.url}});
	assert.deepStrictEqual(tested, {ok: true, count: 1});
	await assert.rejects(b.bridge.control('test', {source: {id: 'new', kind: 'webdav', url: 'nope'}}));
	const found = await b.bridge.control('discover', {kind: 'plex', ms: 500});
	assert.ok(Array.isArray(found.servers));
	await assert.rejects(b.bridge.control('smbShares', {host: 'nas'}), /SMB/);
	await assert.rejects(b.bridge.control('nothing', {}), /unknown operation/);
	const status = await fetchJson(`${b.base}/status`);
	assert.strictEqual(status.json.running, true);
	assert.strictEqual(status.json.node, process.version);
	const preflight = await fetchRaw(`${b.base}/file`, {method: 'OPTIONS'});
	assert.strictEqual(preflight.status, 204);
	assert.match(preflight.headers['access-control-allow-headers'], /Range/);
});

// Immuch360: no requests to every address of the /24 unless the page asks for them (Scan again)
test('discovery sweeps the local /24 only when asked', async (t) => {
	const udp = require('../src/udp');
	const real = udp.search;
	const seen = [];
	udp.search = (message, port, ms, options) => {
		seen.push(!!(options && options.sweep));
		return Promise.resolve([]);
	};
	const b = await startBridge([], {});
	t.after(() => {
		udp.search = real;
		b.stop();
	});
	await b.bridge.control('discover', {kind: 'plex', ms: 500});
	await b.bridge.control('discover', {kind: 'dlna', ms: 500});
	assert.ok(seen.length >= 2);
	assert.ok(seen.every((sweep) => sweep === false), 'no sweep when the page opens');
	seen.length = 0;
	await b.bridge.control('discover', {kind: 'plex', ms: 500, sweep: true});
	await b.bridge.control('discover', {kind: 'dlna', ms: 500, sweep: true});
	assert.ok(seen.includes(true), 'the sweep on Scan again');
});

test('the bridge starts once, and a stopped bridge refuses the old token', async () => {
	const bridge = createBridge({});
	const first = await bridge.start();
	const again = await bridge.start();
	assert.strictEqual(first.token, again.token);
	bridge.stop();
	assert.strictEqual(bridge.isRunning(), false);
	const next = await bridge.start();
	assert.notStrictEqual(next.token, first.token);
	bridge.stop();
});
