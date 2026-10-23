#!/usr/bin/env node
// A fake Immich server for the end to end test of the Samsung TV app (run.mjs), made from the fixtures of the webOS
// app (webos/test/fixtures/immich: one 360° photo of an Insta360 X4, one flat photo, one video), with more flat photos
// so that the timeline has pages. The pictures are drawn as PNG at start: a 2:1 panorama whose colour follows the
// longitude (the test reads the centre of the sphere), stripes for the flat photos. The video is the clip of the About
// page test (H.264, 256 x 128, 2 s), served with byte ranges as Immich does. Like Immich, it sends no CORS header: on
// a Samsung TV the access policy of config.xml stands in for it, in the test Chromium's --disable-web-security does.
//
//   node tizen/test/e2e/server.mjs [port]       prints its address; the test starts it by itself
//
// Sign in: e2e@immuch360.test with the password e2e-password, or the API key e2e-key.

import {createServer} from 'node:http';
import {readFileSync} from 'node:fs';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {encodePng} from './png.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const FIXTURES = join(ROOT, 'webos', 'test', 'fixtures', 'immich');
const CLIP = join(ROOT, 'webos', 'src', 'immuch360', 'diagnostics', 'probe.mp4');

export const E2E_EMAIL = 'e2e@immuch360.test';
export const E2E_PASSWORD = 'e2e-password';
export const E2E_API_KEY = 'e2e-key';
const SESSION = 'e2e-session';
const USER = {id: 'u1', email: E2E_EMAIL, name: 'E2E tester', isAdmin: false, profileImagePath: '', avatarColor: 'primary'};

const fixture = (name) => JSON.parse(readFileSync(join(FIXTURES, name), 'utf8'));

/** The timeline: the three assets of the fixture, then older flat photos up to count */
export function timeline(count = 60) {
	const bucket = fixture('timeline-bucket-2024-06-01.json');
	// Older than the three of the fixture (1 June, 01:00 to 06:00 local time), so that those come first
	for (let i = bucket.id.length; i < count; i++) {
		bucket.id.push(`f1a70000-0000-4000-8000-${String(i).padStart(12, '0')}`);
		bucket.ownerId.push('u1');
		bucket.ratio.push(i % 4 === 0 ? 0.75 : 1.3333333333333333);
		bucket.isFavorite.push(false);
		bucket.visibility.push('timeline');
		bucket.isTrashed.push(false);
		bucket.isImage.push(true);
		bucket.thumbhash.push(null);
		const at = new Date(Date.UTC(2024, 4, 31, 23 + Math.floor((count - i) / 12), (count - i) % 12 * 5)).toISOString();
		bucket.createdAt.push(at);
		bucket.fileCreatedAt.push(at);
		bucket.localOffsetHours.push(2);
		bucket.duration.push(null);
		bucket.stack.push(null);
		bucket.projectionType.push(null);
		bucket.livePhotoVideoId.push(null);
		bucket.city.push('Annecy');
		bucket.country.push('France');
		bucket.latitude.push(45.899);
		bucket.longitude.push(6.129);
	}
	return bucket;
}

/** An asset as GET /api/assets/:id answers, from the timeline */
function assetJson(bucket, index) {
	const id = bucket.id[index];
	if (index === 0) return fixture('asset-360.json');
	const video = !bucket.isImage[index];
	return {
		id,
		type: video ? 'VIDEO' : 'IMAGE',
		originalFileName: video ? 'VID_20240602_072000.mp4' : `IMG_${index}.jpg`,
		originalMimeType: video ? 'video/mp4' : 'image/jpeg',
		fileCreatedAt: bucket.fileCreatedAt[index],
		localDateTime: bucket.fileCreatedAt[index],
		duration: video ? '0:00:02.000000' : null,
		visibility: 'timeline',
		ownerId: 'u1',
		thumbhash: null,
		livePhotoVideoId: null,
		isTrashed: false,
		isEdited: false,
		width: video ? 256 : 4032,
		height: video ? 128 : 3024,
		exifInfo: {make: 'Immuch360', model: 'E2E', exifImageWidth: video ? 256 : 4032, exifImageHeight: video ? 128 : 3024, fileSizeInByte: 123456},
	};
}

const hue = (h) => {
	const f = (n) => {
		const k = (n + h * 6) % 6;
		return Math.round(255 * (1 - Math.max(0, Math.min(k, 4 - k, 1))));
	};
	return [f(5), f(3), f(1)];
};

/** The panorama: the colour follows the longitude, darker bands every 15° of latitude; the front (centre) is bright */
function panorama(width, height) {
	return encodePng(width, height, (x, y) => {
		const [r, g, b] = hue(x / width);
		const latitude = (y / height) * 180;
		const shade = Math.floor(latitude / 15) % 2 === 0 ? 1 : 0.7;
		const meridian = x % (width / 12) < 3 ? 0.4 : 1;
		return [r * shade * meridian, g * shade * meridian, b * shade * meridian].map((v) => Math.max(40, Math.round(v)));
	});
}

function flat(width, height, seed) {
	const [r, g, b] = hue((seed * 0.137) % 1);
	return encodePng(width, height, (x, y) => (Math.floor((x + y) / (width / 16)) % 2 === 0 ? [r, g, b] : [255 - r / 2, 255 - g / 2, 255 - b / 2]));
}

export function startFakeImmich(port = 0) {
	const bucket = timeline();
	const clip = readFileSync(CLIP);
	const pictures = new Map();
	const picture = (index, size) => {
		const key = `${index === 0 ? 'pano' : !bucket.isImage[index] ? 'video' : index % 7}:${size}`;
		if (!pictures.has(key)) {
			const small = size === 'thumbnail';
			if (index === 0) pictures.set(key, panorama(small ? 512 : 2048, small ? 256 : 1024));
			else if (!bucket.isImage[index]) pictures.set(key, flat(small ? 256 : 1024, small ? 128 : 512, 99));
			else pictures.set(key, flat(small ? 320 : 1440, small ? 240 : 1080, index % 7));
		}
		return pictures.get(key);
	};
	const requests = [];

	const server = createServer((request, response) => {
		const url = new URL(request.url, 'http://e2e');
		requests.push(`${request.method} ${url.pathname}`);
		const send = (status, body, type = 'application/json', headers = {}) => {
			const data = Buffer.isBuffer(body) ? body : Buffer.from(typeof body === 'string' ? body : JSON.stringify(body));
			response.writeHead(status, {'Content-Type': type, 'Content-Length': data.length, ...headers});
			response.end(request.method === 'HEAD' ? undefined : data);
		};
		const signedIn =
			request.headers.authorization === `Bearer ${SESSION}` ||
			request.headers['x-api-key'] === E2E_API_KEY ||
			url.searchParams.get('sessionKey') === SESSION ||
			url.searchParams.get('apiKey') === E2E_API_KEY;
		const path = url.pathname.replace(/\/+$/, '');

		if (request.method === 'POST' && path === '/api/auth/login') {
			let body = '';
			request.on('data', (part) => (body += part));
			request.on('end', () => {
				let login = {};
				try {
					login = JSON.parse(body);
				} catch {
					// an empty or broken body is a failed login
				}
				if (login.email === E2E_EMAIL && login.password === E2E_PASSWORD) {
					send(201, {accessToken: SESSION, userId: 'u1', userEmail: E2E_EMAIL, name: USER.name, isAdmin: false, isOnboarded: true, profileImagePath: '', shouldChangePassword: false});
				} else send(401, {message: 'Incorrect email or password', error: 'Unauthorized', statusCode: 401});
			});
			return;
		}
		if (path === '/api/server/about') return send(200, fixture('server-about.json'));
		if (path === '/api/server/version') return send(200, {major: 3, minor: 3, patch: 0});
		if (path === '/api/server/ping') return send(200, {res: 'pong'});
		if (!signedIn) return send(401, {message: 'Authentication required', error: 'Unauthorized', statusCode: 401});

		if (path === '/api/users/me') return send(200, USER);
		if (path === '/api/timeline/buckets') return send(200, [{timeBucket: '2024-06-01', count: bucket.id.length}]);
		if (path === '/api/timeline/bucket') {
			return url.searchParams.get('timeBucket')?.startsWith('2024-06-01') ? send(200, bucket) : send(200, {...timeline(0), id: []});
		}
		if (path === '/api/albums') return send(200, []);
		if (path === '/api/people') return send(200, {people: [], total: 0, hidden: 0, hasNextPage: false});
		if (path === '/api/search/cities') return send(200, []);
		if (path.startsWith('/api/search/')) return send(200, {assets: {items: [], total: 0, count: 0, nextPage: null}, albums: {items: [], total: 0, count: 0}});

		const asset = /^\/api\/assets\/([\w-]+)(\/.*)?$/.exec(path);
		const index = asset ? bucket.id.indexOf(asset[1]) : -1;
		if (asset && index >= 0) {
			const rest = asset[2] ?? '';
			if (rest === '') return send(200, assetJson(bucket, index));
			if (rest === '/edits') return send(200, {assetId: asset[1], edits: []});
			if (rest === '/thumbnail' || rest === '/original') return send(200, picture(index, url.searchParams.get('size') ?? 'preview'), 'image/png', {'Cache-Control': 'private, max-age=86400'});
			if (rest === '/video/playback' && !bucket.isImage[index]) {
				const range = /^bytes=(\d+)-(\d*)$/.exec(request.headers.range ?? '');
				if (!range) return send(200, clip, 'video/mp4', {'Accept-Ranges': 'bytes'});
				const start = Number(range[1]);
				const end = range[2] ? Math.min(Number(range[2]), clip.length - 1) : clip.length - 1;
				return send(206, clip.subarray(start, end + 1), 'video/mp4', {'Accept-Ranges': 'bytes', 'Content-Range': `bytes ${start}-${end}/${clip.length}`});
			}
		}
		send(404, {message: `Not found: ${request.method} ${path}`, statusCode: 404});
	});

	return new Promise((resolveStart) => {
		server.listen(port, '127.0.0.1', () => {
			const address = server.address();
			resolveStart({url: `http://127.0.0.1:${address.port}`, requests, ids: bucket.id, close: () => new Promise((done) => server.close(done))});
		});
	});
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
	const {url} = await startFakeImmich(Number(process.argv[2] ?? 2283));
	console.log(`[fake-immich] ${url}`);
}
