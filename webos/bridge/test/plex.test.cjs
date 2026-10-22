'use strict';
/* global Buffer */
const test = require('node:test');
const assert = require('node:assert');
const https = require('node:https');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const childProcess = require('node:child_process');
const plex = require('../src/plex');
const plextv = require('../src/plextv');
const {startServer, fetchRaw, fetchJson, startBridge, listen} = require('./helpers');

const HASH = '0123456789abcdef0123456789abcdef';
const OTHER = 'fedcba9876543210fedcba9876543210';
const PART = Buffer.alloc(200000, 9);

function json(res, value) {
	res.writeHead(200, {'Content-Type': 'application/json'});
	res.end(JSON.stringify(value));
}

function plexHandler(seen) {
	return (req, res) => {
		seen.push({url: req.url, token: req.headers['x-plex-token'] || null, start: req.headers['x-plex-container-start'], client: req.headers['x-plex-client-identifier'], host: req.headers.host});
		const url = req.url;
		if (url === '/identity') return json(res, {MediaContainer: {machineIdentifier: 'abcdef0123', version: '1.43.5', claimed: false}});
		if (url === '/') return json(res, {MediaContainer: {friendlyName: 'Salon'}});
		if (url === '/library/sections') {
			return json(res, {
				MediaContainer: {
					Directory: [
						{key: '1', title: 'Films', type: 'movie'},
						{key: '2', title: 'Photos', type: 'photo'},
						{key: '3', title: 'Music', type: 'artist'}
					]
				}
			});
		}
		if (url === '/library/sections/1/folder') {
			const start = Number(req.headers['x-plex-container-start'] || 0);
			const metadata = [];
			if (start === 0) metadata.push({key: '/library/sections/1/folder?parent=7', title: 'Kids'});
			// Plex counts the folder among the elements of the listing
			const count = start === 0 ? 299 : 1;
			const first = start === 0 ? 0 : start - 1;
			for (let i = 0; i < count; i++) {
				const n = first + i;
				metadata.push({
					ratingKey: String(100 + n),
					type: 'movie',
					title: 'Film ' + n,
					thumb: `/library/metadata/${100 + n}/thumb/1`,
					addedAt: 1700000000,
					Media: [{container: 'mkv', videoCodec: n === 0 ? 'mpeg2video' : 'h264', audioCodec: 'aac', width: 1920, height: 1080, Part: [{key: `/library/parts/${n}/1/file.mkv`, file: `/data/films/Film ${n}.mkv`, size: 1000, duration: 60000}]}]
				});
			}
			return json(res, {MediaContainer: {offset: start, totalSize: 301, Metadata: metadata}});
		}
		if (url === '/library/sections/2/folder') {
			res.writeHead(404);
			res.end();
			return;
		}
		if (url === '/library/sections/2/all') {
			return json(res, {
				MediaContainer: {
					Metadata: [
						{key: '/library/metadata/50/children', title: 'Album', type: 'photoalbum'},
						{ratingKey: '51', type: 'photo', title: 'IMG', thumb: '/library/metadata/51/thumb/2', Media: [{width: 4000, height: 3000, Part: [{key: '/library/parts/51/2/file.jpg', file: 'C:\\Photos\\IMG_51.JPG'}]}]}
					]
				}
			});
		}
		if (url.indexOf('/library/parts/') === 0 || url.indexOf('/photo/:/transcode') === 0) {
			const range = /bytes=(\d+)-(\d+)/.exec(req.headers.range || '');
			if (range) {
				const s = Number(range[1]);
				const e = Number(range[2]);
				res.writeHead(206, {'Content-Type': 'video/x-matroska', 'Content-Range': `bytes ${s}-${e}/${PART.length}`, 'Content-Length': e - s + 1});
				res.end(PART.slice(s, e + 1));
			} else {
				res.writeHead(200, {'Content-Type': url.indexOf('/photo') === 0 ? 'image/jpeg' : 'video/x-matroska', 'Content-Length': PART.length});
				res.end(PART);
			}
			return;
		}
		if (url.indexOf('/video/:/transcode/universal/decision') === 0) {
			seen.decided = (seen.decided || []).concat([/session=([0-9a-f]+)/.exec(url)[1]]);
			assert.strictEqual(req.headers['x-plex-platform'], 'Chrome');
			return json(res, {MediaContainer: {generalDecisionCode: 1001}});
		}
		if (url.indexOf('/video/:/transcode/universal/stop') === 0) {
			seen.stopped = (seen.stopped || []).concat([/session=([0-9a-f]+)/.exec(url)[1]]);
			res.writeHead(200);
			res.end();
			return;
		}
		if (url.indexOf('/video/:/transcode/universal/start.m3u8') === 0) {
			if (!(seen.decided || []).includes(/session=([0-9a-f]+)/.exec(url)[1])) {
				res.writeHead(400);
				res.end();
				return;
			}
			res.writeHead(200, {'Content-Type': 'application/vnd.apple.mpegurl'});
			res.end('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2000000\nsession/abc/base/index.m3u8\n');
			return;
		}
		if (url === '/video/:/transcode/universal/session/abc/base/index.m3u8') {
			res.writeHead(200, {'Content-Type': 'application/vnd.apple.mpegurl'});
			res.end('#EXTM3U\n#EXTINF:4,\n00000.ts\n');
			return;
		}
		res.writeHead(404);
		res.end();
	};
}

test('plex.direct names, certificate subjects and GDM answers are read strictly', () => {
	assert.deepStrictEqual(plex.parseDirectHost(`192-168-1-20.${HASH}.plex.direct`), {address: '192.168.1.20', hash: HASH});
	assert.strictEqual(plex.parseDirectHost(`192-168-1-020.${HASH}.plex.direct`), null);
	assert.strictEqual(plex.parseDirectHost(`300-1-1-1.${HASH}.plex.direct`), null);
	assert.strictEqual(plex.parseDirectHost(`nas.${HASH}.plex.direct`), null);
	assert.strictEqual(plex.directHost('10.0.0.2', HASH), `10-0-0-2.${HASH}.plex.direct`);
	assert.strictEqual(plex.hashOfSubject(`*.${HASH}.plex.direct`), HASH);
	assert.strictEqual(plex.hashOfSubject(`192-168-1-20.${HASH}.plex.direct`), null);
	const answer = plex.parseGdmAnswer(`HTTP/1.0 200 OK\r\nContent-Type: plex/media-server\nResource-Identifier: abcdef0123456789\nName: Salon\nPort: 32400\nHost: ${HASH}.plex.direct\nVersion: 1.43.5\n\n`, '192.168.1.20');
	assert.deepStrictEqual(answer, {kind: 'plex', name: 'Salon', address: '192.168.1.20', port: 32400, machineId: 'abcdef0123456789', hash: HASH, version: '1.43.5'});
	assert.strictEqual(plex.parseGdmAnswer('HTTP/1.0 200 OK\r\nContent-Type: plex/media-player\r\nResource-Identifier: abcdef01\r\nPort: 32500\r\n\r\n', 'x'), null);
	assert.strictEqual(plex.parseGdmAnswer('HTTP/1.0 200 OK\r\nContent-Type: plex/media-server\r\nResource-Identifier: abcdef01\r\nPort: 32400\r\n\r\n', '10.0.0.3').hash, null);
});

test('what the bridge forwards and how it decides to transcode', () => {
	assert.ok(plex.isForwardable('/library/parts/1/2/file.mkv'));
	assert.ok(plex.isForwardable('/photo/:/transcode?width=1&url=x'));
	assert.ok(plex.isForwardable('/video/:/transcode/universal/session/abc/base/00001.ts'));
	assert.ok(!plex.isForwardable('/:/prefs'));
	assert.ok(!plex.isForwardable('/library/sections'));
	assert.ok(!plex.isForwardable('/library/parts/../../:/prefs'));
	assert.ok(plex.playsDirectly({name: 'a.mkv', container: 'mkv', videoCodec: 'h264', audioCodec: 'aac'}));
	assert.ok(!plex.playsDirectly({name: 'a.avi', container: 'avi', videoCodec: 'mpeg4', audioCodec: 'mp3'}));
	assert.ok(!plex.playsDirectly({name: 'a.mkv', container: 'mkv', videoCodec: 'h264', audioCodec: 'dts'}));
	assert.match(plex.hlsPath('123', 'sess', 'client12345'), /^\/video\/:\/transcode\/universal\/start\.m3u8\?hasMDE=1&path=%2Flibrary%2Fmetadata%2F123&.*session=sess/);
	assert.strictEqual(plex.photoPath('/library/metadata/1/thumb/2', 360, 360), '/photo/:/transcode?width=360&height=360&minSize=1&upscale=0&url=%2Flibrary%2Fmetadata%2F1%2Fthumb%2F2');
});

test('the bridge lists a Plex server without a certificate, without a token', async (t) => {
	const seen = [];
	const server = await startServer(plexHandler(seen));
	const b = await startBridge([{id: 'px', kind: 'plex', address: '127.0.0.1', port: server.port}]);
	b.bridge.setPlexClientId('client-1234567890');
	t.after(() => {
		b.stop();
		return server.close();
	});
	const root = await fetchJson(`${b.base}/list?s=px`);
	assert.deepStrictEqual(root.json.folders.map((f) => [f.name, f.ref]), [
		['Films', '/library/sections/1/folder'],
		['Photos', '/library/sections/2/folder']
	]);
	const films = await fetchJson(`${b.base}/list?s=px&r=${encodeURIComponent('/library/sections/1/folder')}`);
	assert.strictEqual(films.json.files.length, 300);
	assert.deepStrictEqual(films.json.folders, [{ref: '/library/sections/1/folder?parent=7', name: 'Kids'}]);
	assert.strictEqual(films.json.files[0].name, 'Film 0.mkv');
	assert.strictEqual(films.json.files[0].direct, false);
	assert.strictEqual(films.json.files[1].direct, true);
	assert.strictEqual(films.json.files[1].kind, 'video');
	assert.deepStrictEqual(seen.filter((s) => s.url === '/library/sections/1/folder').map((s) => s.start), ['0', '300']);
	assert.ok(seen.every((s) => s.token === null));
	assert.ok(seen.every((s) => s.client === 'client-1234567890'));

	const photos = await fetchJson(`${b.base}/list?s=px&r=${encodeURIComponent('/library/sections/2/folder')}`);
	assert.deepStrictEqual(photos.json.folders, [{ref: '/library/metadata/50/children', name: 'Album'}]);
	assert.deepStrictEqual(photos.json.files.map((f) => [f.name, f.kind, f.width]), [['IMG_51.JPG', 'image', 4000]]);

	const range = await fetchRaw(`${b.base}/file?s=px&r=${encodeURIComponent('/library/parts/1/1/file.mkv')}`, {headers: {Range: 'bytes=10-19'}});
	assert.strictEqual(range.status, 206);
	assert.ok(range.body.equals(PART.slice(10, 20)));
	const thumb = await fetchRaw(`${b.base}/thumb?s=px&r=x&t=${encodeURIComponent('/library/metadata/51/thumb/2')}`);
	assert.strictEqual(thumb.status, 200);
	assert.ok(seen.some((s) => s.url.indexOf('/photo/:/transcode?width=360&height=360') === 0));
	const photo = await fetchRaw(`${b.base}/photo?s=px&r=${encodeURIComponent('/library/parts/51/2/file.jpg')}&w=1920&h=1080`);
	assert.strictEqual(photo.status, 200);
	assert.ok(seen.some((s) => /^\/photo\/:\/transcode\?width=1920&height=1080&.*url=%2Flibrary%2Fparts%2F51/.test(s.url)));

	// The HLS transcode: a redirect to the forwarded path, whose relative playlists resolve through the bridge
	const hls = await fetchRaw(`${b.base}/hls?s=px&k=101`);
	assert.strictEqual(hls.status, 302);
	const master = await fetchRaw(`http://127.0.0.1:${b.info.port}${hls.headers.location}`);
	assert.strictEqual(master.status, 200);
	const next = new URL('session/abc/base/index.m3u8', `http://127.0.0.1:${b.info.port}${hls.headers.location}`);
	const media = await fetchRaw(next.href);
	assert.strictEqual(media.status, 200);
	assert.match(media.body.toString(), /00000\.ts/);
	// A second transcode of the same server stops the first one
	const second = await fetchRaw(`${b.base}/hls?s=px&k=102`);
	assert.strictEqual(second.status, 302);
	assert.strictEqual(seen.stopped.length, 1);
	assert.strictEqual(seen.stopped[0], seen.decided[0]);
	const refused = await fetchJson(`${b.base}/px/px/:/prefs`);
	assert.strictEqual(refused.status, 403);
});

function makeCert(dir, hash) {
	const key = path.join(dir, 'key.pem');
	const cert = path.join(dir, 'cert.pem');
	childProcess.execFileSync(
		'openssl',
		['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', '-keyout', key, '-out', cert, '-subj', `/CN=*.${hash}.plex.direct`, '-addext', `subjectAltName=DNS:*.${hash}.plex.direct`],
		{stdio: 'ignore'}
	);
	return {key: fs.readFileSync(key), cert: fs.readFileSync(cert)};
}

let haveOpenssl = true;
try {
	childProcess.execFileSync('openssl', ['version'], {stdio: 'ignore'});
} catch (e) {
	haveOpenssl = false;
}

test('a token only goes to the server holding the plex.direct certificate of its hash', {skip: !haveOpenssl && 'openssl is not installed'}, async (t) => {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'plexcert-'));
	const pair = makeCert(dir, HASH);
	plex.setTestCa(pair.cert);
	const seen = [];
	const server = https.createServer({key: pair.key, cert: pair.cert}, plexHandler(seen));
	const port = await listen(server);
	const b = await startBridge([
		{id: 'good', kind: 'plex', address: '127.0.0.1', port, hash: HASH, token: 'secret-token'},
		{id: 'other', kind: 'plex', address: '127.0.0.1', port, hash: OTHER, token: 'secret-token'}
	]);
	t.after(() => {
		b.stop();
		plex.setTestCa(null);
		fs.rmSync(dir, {recursive: true, force: true});
		return new Promise((r) => server.close(r));
	});
	const good = await fetchJson(`${b.base}/list?s=good`);
	assert.strictEqual(good.status, 200);
	assert.strictEqual(good.json.folders.length, 2);
	assert.strictEqual(seen[0].token, 'secret-token');
	assert.strictEqual(seen[0].host, `127-0-0-1.${HASH}.plex.direct:${port}`);
	const count = seen.length;
	const other = await fetchJson(`${b.base}/list?s=other`);
	assert.strictEqual(other.status, 502);
	assert.strictEqual(seen.length, count, 'no request reached the server');
	// The probe reads the hash of the certificate without sending anything
	assert.strictEqual(await plex.probeHash('127.0.0.1', port), HASH);
	assert.strictEqual(seen.length, count);
	// A token without a hash is refused: it would go in clear
	assert.strictEqual(b.bridge.setSources([{id: 'clear', kind: 'plex', address: '127.0.0.1', token: 'secret-token'}]).refused.length, 1);
});

test('the plex.tv sign in: a PIN, its token once linked, the servers of the account', async (t) => {
	let linked = false;
	const seen = [];
	const fake = await startServer((req, res) => {
		seen.push({method: req.method, url: req.url, client: req.headers['x-plex-client-identifier'], token: req.headers['x-plex-token']});
		if (req.method === 'POST' && req.url === '/api/v2/pins?strong=false') return json(res, {id: 4242, code: 'AB12', expiresAt: '2026-10-22T12:00:00Z'});
		if (req.url === '/api/v2/pins/4242') return json(res, {id: 4242, code: 'AB12', authToken: linked ? 'account-token' : null});
		if (req.url.indexOf('/api/v2/resources') === 0) {
			return json(res, [
				{name: 'Player', provides: 'player', clientIdentifier: 'p1', connections: []},
				{
					name: 'Salon',
					provides: 'server',
					clientIdentifier: 'srv1',
					accessToken: 'server-token',
					owned: true,
					connections: [
						{protocol: 'https', address: '81.1.1.1', port: 32400, uri: `https://81-1-1-1.${HASH}.plex.direct:32400`, local: false, relay: false},
						{protocol: 'https', address: '192.168.1.20', port: 32400, uri: `https://192-168-1-20.${HASH}.plex.direct:32400`, local: true, relay: false},
						{protocol: 'https', address: 'relay', port: 8443, uri: `https://1-2-3-4.${OTHER}.plex.direct:8443`, local: false, relay: true}
					]
				},
				{name: 'Relay only', provides: 'server', clientIdentifier: 'srv2', connections: [{protocol: 'https', uri: 'https://x', relay: true}]}
			]);
		}
		res.writeHead(404);
		res.end();
	});
	t.after(() => fake.close());
	const bases = {plexTv: fake.url, clients: fake.url};
	const pin = await plextv.createPin('client-1234567890', bases);
	assert.deepStrictEqual(pin, {id: 4242, code: 'AB12', expiresAt: '2026-10-22T12:00:00Z'});
	assert.strictEqual(await plextv.checkPin('client-1234567890', 4242, bases), null);
	linked = true;
	assert.strictEqual(await plextv.checkPin('client-1234567890', 4242, bases), 'account-token');
	const servers = await plextv.servers('client-1234567890', 'account-token', bases);
	assert.deepStrictEqual(servers, [{name: 'Salon', machineId: 'srv1', token: 'server-token', address: '192.168.1.20', port: 32400, hash: HASH, local: true, owned: true}]);
	assert.ok(seen.every((s) => s.client === 'client-1234567890'));
	assert.strictEqual(seen[seen.length - 1].token, 'account-token');
	await assert.rejects(plextv.createPin('bad id!', bases));
});
