'use strict';
const test = require('node:test');
const assert = require('node:assert');
const webdav = require('../src/webdav');
const {startServer, fetchRaw, fetchJson, startBridge} = require('./helpers');
const {makeJpeg} = require('./jpeg');

const PHOTO = makeJpeg({gpano: true, thumbnail: Buffer.concat([Buffer.from([0xff, 0xd8]), Buffer.alloc(300, 1), Buffer.from([0xff, 0xd9])])});
const VIDEO = Buffer.alloc(300000);
for (let i = 0; i < VIDEO.length; i++) VIDEO[i] = i % 251;

function multistatus(base, entries) {
	return (
		'<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">' +
		entries
			.map(
				(e) =>
					`<D:response><D:href>${e.href}</D:href><D:propstat><D:prop>` +
					(e.dir ? '<D:resourcetype><D:collection/></D:resourcetype>' : `<D:resourcetype/><D:getcontentlength>${e.size}</D:getcontentlength>`) +
					`<D:getlastmodified>Wed, 21 Oct 2026 10:00:00 GMT</D:getlastmodified></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>`
			)
			.join('') +
		'</D:multistatus>'
	);
}

const FILES = {'/dav/photos/%C3%A9t%C3%A9%20360.jpg': PHOTO, '/dav/photos/clip.mp4': VIDEO};

function davServer() {
	return startServer((req, res) => {
		if (req.headers.authorization !== 'Basic ' + Buffer.from('tester:pässword').toString('base64')) {
			res.writeHead(401, {'WWW-Authenticate': 'Basic realm="x"'});
			res.end();
			return;
		}
		if (req.method === 'PROPFIND' && req.url === '/dav/photos/') {
			res.writeHead(207, {'Content-Type': 'application/xml'});
			res.end(
				multistatus('/dav/photos/', [
					{href: '/dav/photos/', dir: true},
					{href: '/dav/photos/%C3%A9t%C3%A9%20360.jpg', size: PHOTO.length},
					{href: 'http://127.0.0.1/dav/photos/clip.mp4', size: VIDEO.length},
					{href: '/dav/photos/notes.txt', size: 3},
					{href: '/dav/photos/.DS_Store', size: 3},
					{href: '/dav/photos/Vacances%202026/', dir: true}
				])
			);
			return;
		}
		if (req.method === 'PROPFIND' && req.url === '/dav/moved/') {
			res.writeHead(301, {Location: '/dav/photos/'});
			res.end();
			return;
		}
		if (req.method === 'PROPFIND' && req.url === '/dav/away/') {
			res.writeHead(302, {Location: 'http://example.invalid/dav/'});
			res.end();
			return;
		}
		const body = FILES[req.url];
		if (req.method === 'GET' && body) {
			const range = /bytes=(\d+)-(\d*)/.exec(req.headers.range || '');
			if (range) {
				const start = Number(range[1]);
				const end = range[2] ? Math.min(Number(range[2]), body.length - 1) : body.length - 1;
				res.writeHead(206, {'Content-Type': 'application/octet-stream', 'Content-Length': end - start + 1, 'Content-Range': `bytes ${start}-${end}/${body.length}`, 'Accept-Ranges': 'bytes'});
				res.end(body.slice(start, end + 1));
			} else {
				res.writeHead(200, {'Content-Length': body.length, 'Accept-Ranges': 'bytes'});
				res.end(body);
			}
			return;
		}
		res.writeHead(404);
		res.end();
	});
}

test('hrefs are decoded and made absolute', () => {
	assert.strictEqual(webdav.hrefPath('/dav/a%20b/', '/dav'), '/dav/a b');
	assert.strictEqual(webdav.hrefPath('https://nas:5006/dav/x.jpg', '/dav'), '/dav/x.jpg');
	assert.strictEqual(webdav.hrefPath('x.jpg', '/dav/f/'), '/dav/f/x.jpg');
	assert.strictEqual(webdav.hrefPath('/dav/%E9t%E9', '/'), '/dav/%E9t%E9');
	assert.strictEqual(webdav.davUrl({url: 'https://h/dav/'}, 'été/a b.jpg'), 'https://h/dav/%C3%A9t%C3%A9/a%20b.jpg');
});

test('the bridge lists a WebDAV folder and serves its files with ranges, CORS and the token', async (t) => {
	const dav = await davServer();
	const b = await startBridge([{id: 'nas', kind: 'webdav', name: 'NAS', url: dav.url + '/dav', user: 'tester', password: 'pässword'}]);
	t.after(() => {
		b.stop();
		return dav.close();
	});

	const listing = await fetchJson(`${b.base}/list?s=nas&r=photos`);
	assert.strictEqual(listing.status, 200);
	assert.strictEqual(listing.headers['access-control-allow-origin'], '*');
	assert.deepStrictEqual(listing.json.folders, [{ref: 'photos/Vacances 2026', name: 'Vacances 2026'}]);
	assert.deepStrictEqual(
		listing.json.files.map((f) => [f.ref, f.kind, f.size]),
		[
			['photos/clip.mp4', 'video', VIDEO.length],
			['photos/été 360.jpg', 'image', PHOTO.length]
		]
	);

	const range = await fetchRaw(`${b.base}/file?s=nas&r=${encodeURIComponent('photos/clip.mp4')}`, {headers: {Range: 'bytes=1000-1999'}});
	assert.strictEqual(range.status, 206);
	assert.strictEqual(range.headers['content-range'], `bytes 1000-1999/${VIDEO.length}`);
	assert.ok(range.body.equals(VIDEO.slice(1000, 2000)));
	assert.strictEqual(range.headers['access-control-allow-origin'], '*');

	const thumb = await fetchRaw(`${b.base}/thumb?s=nas&r=${encodeURIComponent('photos/été 360.jpg')}`);
	assert.strictEqual(thumb.status, 200);
	assert.strictEqual(thumb.headers['content-type'], 'image/jpeg');
	assert.strictEqual(thumb.body.length, 304);
	const meta = await fetchJson(`${b.base}/meta?s=nas&r=${encodeURIComponent('photos/été 360.jpg')}`);
	assert.strictEqual(meta.json.projection, 'equirectangular');
	assert.strictEqual(meta.json.width, 6720);
	// The head was read once: the thumbnail and the details come from the same ranged read
	assert.strictEqual(dav.requests.filter((r) => r.method === 'GET' && r.url.indexOf('360') >= 0).length, 1);

	const noToken = await fetchRaw(`http://127.0.0.1:${b.info.port}/list?s=nas&r=photos`);
	assert.strictEqual(noToken.status, 404);
	const wrongToken = await fetchRaw(`http://127.0.0.1:${b.info.port}/${'0'.repeat(32)}/list?s=nas&r=photos`);
	assert.strictEqual(wrongToken.status, 404);
	const post = await fetchRaw(`${b.base}/list?s=nas`, {method: 'POST'});
	assert.strictEqual(post.status, 405);
	// The password is never in what the page gets
	assert.ok(!JSON.stringify(listing.json).includes('pässword'));
});

test('redirects are followed on the same host only, and a wrong password says so', async (t) => {
	const dav = await davServer();
	const b = await startBridge([
		{id: 'moved', kind: 'webdav', url: dav.url + '/dav', user: 'tester', password: 'pässword'},
		{id: 'bad', kind: 'webdav', url: dav.url + '/dav', user: 'tester', password: 'nope'}
	]);
	t.after(() => {
		b.stop();
		return dav.close();
	});
	const moved = await fetchJson(`${b.base}/list?s=moved&r=moved`);
	assert.strictEqual(moved.status, 200);
	assert.strictEqual(moved.json.files.length, 2);
	const away = await fetchJson(`${b.base}/list?s=moved&r=away`);
	assert.strictEqual(away.status, 502);
	assert.match(away.json.error, /another host/);
	const bad = await fetchJson(`${b.base}/list?s=bad&r=photos`);
	assert.strictEqual(bad.status, 401);
	assert.strictEqual(bad.json.code, 'auth');
	const unknown = await fetchJson(`${b.base}/list?s=nothere`);
	assert.strictEqual(unknown.status, 404);
});
