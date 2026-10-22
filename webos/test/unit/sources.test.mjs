// The network sources of the TV app (src/immuch360/sources/): the store kept on the TV, the client of the media
// bridge (start, sources, restart after the service went away), the repository that feeds the Immich screens with the
// files of a share, the texts of the errors and the rules of the live view. The Luna transport and fetch are fakes.

import {test, describe} from 'node:test';
import assert from 'node:assert/strict';
import {createSourceStore, parseSources} from '../../src/immuch360/sources/store.ts';
import {BridgeClient, bridgeUrl} from '../../src/immuch360/sources/bridgeClient.ts';
import {SourceRepository, assetIdOf} from '../../src/immuch360/sources/repository.ts';
import {bridgeErrorText, sourceErrorText} from '../../src/immuch360/sources/messages.ts';
import {catchUpTo, concat, mseType, trimRange} from '../../src/immuch360/sources/liveMse.ts';
import {webdavUrl} from '../../src/immuch360/sources/addresses.ts';
import {BridgeError} from '../../src/immuch360/sources/types.ts';

function memoryStorage() {
	const map = new Map();
	return {getItem: (k) => (map.has(k) ? map.get(k) : null), setItem: (k, v) => map.set(k, String(v)), map};
}

const settle = async () => {
	for (let i = 0; i < 20; i++) await new Promise((resolve) => setImmediate(resolve));
};

describe('the store of the sources', () => {
	test('keeps, replaces and removes sources, and tells its listeners', () => {
		const storage = memoryStorage();
		const store = createSourceStore(storage);
		let told = 0;
		store.subscribe(() => told++);
		store.save({id: 'a', kind: 'smb', name: 'NAS', host: 'nas', share: 'photos', password: 'p'});
		store.save({id: 'b', kind: 'dlna', name: 'TV box', location: 'http://10.0.0.5/d.xml'});
		store.save({id: 'a', kind: 'smb', name: 'NAS 2', host: 'nas', share: 'photos'});
		assert.deepEqual(store.list().map((s) => s.name), ['NAS 2', 'TV box']);
		store.remove('b');
		assert.equal(store.list().length, 1);
		assert.equal(told, 4);
		assert.deepEqual(createSourceStore(storage).list().map((s) => s.id), ['a']);
	});

	test('drops what is not a source, and keeps one Plex client id', () => {
		assert.deepEqual(parseSources('[{"id":"x","kind":"ftp","name":"x"},{"id":"y","kind":"tapo","name":"Cam"},3]').map((s) => s.id), ['y']);
		assert.deepEqual(parseSources('not json'), []);
		const storage = memoryStorage();
		const id = createSourceStore(storage).plexClientId();
		assert.match(id, /^[0-9a-f]{32}$/);
		assert.equal(createSourceStore(storage).plexClientId(), id);
	});
});

function fakeTransport(options = {}) {
	const calls = [];
	let port = 4000;
	let running = false;
	return {
		calls,
		stopService() {
			running = false;
		},
		async call(method, params) {
			calls.push([method, params]);
			if (options.refuse) return {returnValue: false, errorText: 'Shares, Plex and cameras need webOS 5 or later', errorCode: 'needs_webos5'};
			if (method === 'bridgeStart') {
				running = true;
				port++;
				return {returnValue: true, port, token: `tok${port}`, host: '127.0.0.1', node: 'v12.21.0', smb: true};
			}
			if (method === 'bridgeStatus') return {returnValue: true, running, port};
			if (method === 'bridgeCall' && params.op === 'fail') return {returnValue: false, errorText: 'nope', errorCode: 'auth'};
			return {returnValue: true, count: 0, echo: params};
		},
	};
}

describe('the client of the bridge', () => {
	test('starts the bridge once, hands it the sources, and builds its URLs', async () => {
		const store = createSourceStore(memoryStorage());
		store.save({id: 'a', kind: 'webdav', name: 'Cloud', url: 'https://x/dav', password: 'secret'});
		const transport = fakeTransport();
		const client = new BridgeClient(transport, store, {pollMs: 1000000});
		const [one, two] = await Promise.all([client.ensure(), client.ensure()]);
		assert.equal(one, two);
		assert.deepEqual(transport.calls.map((c) => c[0]), ['bridgeStart', 'bridgeSetSources']);
		assert.equal(transport.calls[1][1].sources[0].password, 'secret');
		assert.match(transport.calls[0][1].clientId, /^[0-9a-f]{32}$/);
		assert.equal(client.url('file', {s: 'a', r: 'été/1.jpg', t: null}), 'http://127.0.0.1:4001/tok4001/file?s=a&r=%C3%A9t%C3%A9%2F1.jpg');
		assert.equal(client.smbAvailable(), true);
		// A change of the sources goes to the running bridge
		store.save({id: 'b', kind: 'dlna', name: 'Box', location: 'http://10.0.0.5/d.xml'});
		await settle();
		assert.equal(transport.calls[2][0], 'bridgeSetSources');
		assert.equal(transport.calls[2][1].sources.length, 2);
	});

	test('a stopped service is started again, with a new token, and the screens are told', async () => {
		const store = createSourceStore(memoryStorage());
		const transport = fakeTransport();
		const client = new BridgeClient(transport, store, {pollMs: 5});
		let told = 0;
		client.subscribe(() => told++);
		const release = client.hold();
		await settle();
		const first = client.current();
		const version = client.version();
		transport.stopService();
		await new Promise((resolve) => setTimeout(resolve, 30));
		await settle();
		release();
		assert.notEqual(client.current().token, first.token);
		assert.ok(client.version() > version);
		assert.ok(told >= 2);
	});

	test('listings come from the bridge, its errors keep their code', async () => {
		const store = createSourceStore(memoryStorage());
		const answers = [
			{ok: true, status: 200, json: async () => ({folders: [{ref: 'a', name: 'a'}], files: []})},
			{ok: false, status: 401, json: async () => ({error: 'The server refused the user name or the password', code: 'auth'})},
		];
		const urls = [];
		const client = new BridgeClient(fakeTransport(), store, {pollMs: 1000000, fetch: async (url) => (urls.push(url), answers.shift())});
		const listing = await client.list('x', '');
		assert.deepEqual(listing, {folders: [{ref: 'a', name: 'a'}], files: []});
		assert.match(urls[0], /\/list\?s=x&r=$/);
		await assert.rejects(client.list('x', 'b'), (e) => e instanceof BridgeError && e.code === 'auth' && e.status === 401);
		await assert.rejects(client.control('fail', {}), (e) => e.code === 'auth');
	});

	test('an old TV is told why, not a bare error', async () => {
		const client = new BridgeClient(fakeTransport({refuse: true}), createSourceStore(memoryStorage()), {pollMs: 1000000});
		await assert.rejects(client.ensure(), (e) => e.code === 'needs_webos5');
		assert.equal(bridgeErrorText(client.error()), 'Network shares, Plex and cameras need webOS 5 (2020 TVs) or later.');
	});
});

describe('the repository of a folder', () => {
	const info = {port: 9000, token: 'tok', host: '127.0.0.1', node: 'v12', smb: true};
	const files = [
		{ref: 'Photos/a.jpg', name: 'a.jpg', kind: 'image', mime: 'image/jpeg', size: 10, modified: 1700000000000},
		{ref: 'Photos/b.mp4', name: 'b.mp4', kind: 'video', mime: 'video/mp4', size: 10, duration: 12},
		{ref: 'Photos/c.heic', name: 'c.heic', kind: 'unsupported', mime: 'image/heic', size: 10},
	];

	test('SMB and WebDAV: EXIF thumbnails, originals, a tile for what the TV cannot show', () => {
		const repo = new SourceRepository(info, {id: 's', kind: 'smb', name: 'NAS'}, files, {unsupportedCaption: 'Not shown on this TV'});
		const [a, b, c] = repo.assets;
		assert.equal(a.id, assetIdOf('s', 'Photos/a.jpg'));
		assert.equal(a.type, 'IMAGE');
		assert.equal(a.fileName, 'a.jpg');
		assert.equal(b.type, 'VIDEO');
		assert.equal(b.durationSeconds, 12);
		assert.equal(repo.thumbnailUrl(a.id), 'http://127.0.0.1:9000/tok/thumb?s=s&r=Photos%2Fa.jpg');
		assert.equal(repo.previewUrl(a.id), 'http://127.0.0.1:9000/tok/file?s=s&r=Photos%2Fa.jpg');
		assert.equal(repo.videoPlaybackUrl(b.id), 'http://127.0.0.1:9000/tok/file?s=s&r=Photos%2Fb.mp4');
		assert.match(repo.thumbnailUrl(b.id), /^data:image\/svg\+xml/);
		assert.match(decodeURIComponent(repo.thumbnailUrl(c.id)), /Not shown on this TV/);
		assert.equal(repo.previewUrl(c.id), repo.thumbnailUrl(c.id));
	});

	test('Plex: pictures at the TV size, the HLS transcode for a video the TV does not play; DLNA videos straight', () => {
		const plexFiles = [
			{ref: '/library/parts/1/1/file.jpg', name: 'p.jpg', kind: 'image', mime: 'image/jpeg', size: 1, thumb: '/library/metadata/1/thumb/1'},
			{ref: '/library/parts/2/1/file.avi', name: 'v.avi', kind: 'video', mime: null, size: 1, ratingKey: '2', direct: false},
		];
		const plex = new SourceRepository(info, {id: 'p', kind: 'plex', name: 'Plex'}, plexFiles, {unsupportedCaption: '', screen: {width: 3840, height: 2160}});
		assert.equal(plex.thumbnailUrl(plex.assets[0].id), 'http://127.0.0.1:9000/tok/thumb?s=p&r=%2Flibrary%2Fparts%2F1%2F1%2Ffile.jpg&t=%2Flibrary%2Fmetadata%2F1%2Fthumb%2F1');
		assert.equal(plex.previewUrl(plex.assets[0].id), 'http://127.0.0.1:9000/tok/photo?s=p&r=%2Flibrary%2Fparts%2F1%2F1%2Ffile.jpg&w=3840&h=2160');
		assert.equal(plex.videoPlaybackUrl(plex.assets[1].id), 'http://127.0.0.1:9000/tok/hls?s=p&k=2');
		const dlna = new SourceRepository(info, {id: 'd', kind: 'dlna', name: 'Box'}, [{ref: 'http://10.0.0.5:8200/MediaItems/9.mp4', name: 'v', kind: 'video', mime: 'video/mp4', size: 1}], {unsupportedCaption: ''});
		assert.equal(dlna.videoPlaybackUrl(dlna.assets[0].id), 'http://10.0.0.5:8200/MediaItems/9.mp4');
	});

	test('the details of a JPEG come from its head: a GPano photo is a 360° photo; turns stay on the TV', async () => {
		const fetchFake = async (url) => ({ok: true, status: 200, json: async () => ({width: 6080, height: 3040, make: 'RICOH', model: 'RICOH THETA Z1', projection: 'equirectangular'}), arrayBuffer: async () => new ArrayBuffer(4), url});
		const repo = new SourceRepository(info, {id: 's', kind: 'webdav', name: 'Cloud'}, files, {unsupportedCaption: '', fetch: fetchFake});
		const details = await repo.getAssetDetails(repo.assets[0].id);
		assert.equal(details.projectionType, 'EQUIRECTANGULAR');
		assert.equal(details.width, 6080);
		assert.equal(details.model, 'RICOH THETA Z1');
		assert.deepEqual(await repo.getRotationContext(), {userId: null, serverVersion: null});
		assert.equal(repo.detailsForEveryPhoto, true);
		assert.equal((await repo.fetchPreviewBytes(repo.assets[0].id)).byteLength, 4);
		const shuffled = await repo.searchRandomImages({}, 10);
		assert.deepEqual(shuffled.map((a) => a.id), [repo.assets[0].id]);
	});
});

describe('texts and rules', () => {
	test('errors are said in the words of their kind', () => {
		assert.equal(sourceErrorText({message: 'x', code: 'smb_needs_node12'}, 'smb'), 'SMB shares need webOS 22 (2022 TVs) or later. WebDAV and DLNA shares work on this TV.');
		assert.equal(sourceErrorText({message: 'x', code: 'auth'}, 'tapo'), 'The camera refused the password. Each wrong try counts, and after a few the camera locks for a while.');
		assert.equal(sourceErrorText({message: 'x', code: 'h265'}, 'tapo'), 'This camera sends H.265, which the live view of TVs does not play yet.');
		assert.equal(sourceErrorText({message: 'x', code: 'token_refused'}, 'plex'), 'The Plex server refused this token.');
		assert.equal(sourceErrorText({message: 'boom'}, 'webdav'), 'Connection failed: boom');
		assert.equal(bridgeErrorText({message: 'no', code: 'bridge_unavailable'}), "The app's service did not start: no");
	});

	test('the live view asks MSE for the codec of the camera, catches up with the live edge and trims its buffer', () => {
		assert.equal(mseType('avc1.640032'), 'video/mp4; codecs="avc1.640032"');
		assert.equal(mseType(null), 'video/mp4; codecs="avc1.640028"');
		assert.equal(mseType('hvc1.1.6'), 'video/mp4; codecs="avc1.640028"');
		assert.equal(catchUpTo(10, 9), null);
		assert.equal(catchUpTo(10, 2), 9.5);
		assert.equal(trimRange(0, 20), null);
		assert.deepEqual(trimRange(0, 40), [0, 20]);
		assert.deepEqual(Array.from(concat([new Uint8Array([1]), new Uint8Array([2, 3])])), [1, 2, 3]);
	});

	test('the WebDAV address of the fields', () => {
		assert.equal(webdavUrl(' nas.local/ ', '', '/remote.php/dav/files/me', true), 'https://nas.local/remote.php/dav/files/me');
		assert.equal(webdavUrl('http://10.0.0.2', '5005', '', false), 'http://10.0.0.2:5005/');
	});

	test('bridge URLs leave out empty parameters', () => {
		assert.equal(bridgeUrl({port: 1, token: 't'}, 'list', {s: 'a', r: '', t: undefined}), 'http://127.0.0.1:1/t/list?s=a&r=');
	});
});
