'use strict';
const test = require('node:test');
const assert = require('node:assert');
const {createSmbDriver, toSmbPath, describeError} = require('../src/smb/driver');
const {fetchRaw, fetchJson, startBridge} = require('./helpers');
const {makeJpeg} = require('./jpeg');

const VIDEO = Buffer.alloc(3 * 1024 * 1024 + 123);
for (let i = 0; i < VIDEO.length; i++) VIDEO[i] = (i * 7) % 256;
const PHOTO = makeJpeg({});

/** A fake @winlinux/smb2: a share "media" with a few files; failOnce makes the first session drop */
function fakeLib(options) {
	const opts = options || {};
	const calls = {connect: 0, reads: [], lists: []};
	const files = {'photos\\a.jpg': PHOTO, 'photos\\clip.mp4': VIDEO, 'root\\photos\\clip.mp4': VIDEO};
	let failures = opts.failOnce ? 1 : 0;
	return {
		calls,
		createAuthProvider: (kind) => ({kind}),
		connect: (o) => {
			calls.connect++;
			if (o.credentials.password !== 'testpass') return Promise.reject(Object.assign(new Error('STATUS_LOGON_FAILURE'), {name: 'SmbAuthError'}));
			return Promise.resolve({
				list: (share, dir) => {
					calls.lists.push([share, dir]);
					if (failures > 0) {
						failures--;
						return Promise.reject(new Error('SmbConnectionError: socket closed'));
					}
					if (dir === 'missing') return Promise.reject(Object.assign(new Error('STATUS_OBJECT_NAME_NOT_FOUND'), {name: 'SmbNotFoundError'}));
					return Promise.resolve([
						{name: '.', isDirectory: true, sizeBytes: 0n},
						{name: 'été 2026', isDirectory: true, sizeBytes: 0n, mtime: new Date(0)},
						{name: 'clip.mp4', isDirectory: false, sizeBytes: BigInt(VIDEO.length), mtime: new Date(1000)},
						{name: 'a.jpg', isDirectory: false, sizeBytes: BigInt(PHOTO.length), mtime: new Date(1000)},
						{name: '@eaDir', isDirectory: true, sizeBytes: 0n},
						{name: 'notes.txt', isDirectory: false, sizeBytes: 3n}
					]);
				},
				stat: (share, path) => Promise.resolve({sizeBytes: BigInt(files[path].length)}),
				readRange: (share, path, offset, length) => {
					calls.reads.push([path, offset, length]);
					return Promise.resolve(files[path].slice(offset, offset + length));
				},
				listShares: () => Promise.resolve([{name: 'media', type: 'disk'}, {name: 'IPC$', type: 'ipc'}, {name: 'print$', type: 'disk'}]),
				close: () => Promise.resolve()
			});
		}
	};
}

const SOURCE = {id: 'nas', kind: 'smb', host: '10.0.0.2', share: 'media', user: 'tester', password: 'testpass'};

test('paths go to the server with backslashes, without dot segments', () => {
	assert.strictEqual(toSmbPath('a/b c/../d.jpg'), 'a\\b c\\d.jpg');
	assert.strictEqual(toSmbPath(''), '');
	assert.strictEqual(describeError(Object.assign(new Error('x'), {name: 'SmbAuthError'})).code, 'auth');
	assert.strictEqual(describeError(new Error('connect ECONNREFUSED')).code, 'unreachable');
});

test('the driver lists, reconnects once after a dropped session, and stops at a wrong password', async () => {
	const lib = fakeLib({failOnce: true});
	const driver = createSmbDriver(lib);
	const entries = await driver.list(Object.assign({}, SOURCE, {root: 'root'}), 'photos');
	assert.strictEqual(lib.calls.connect, 2);
	assert.deepStrictEqual(lib.calls.lists, [['media', 'root\\photos'], ['media', 'root\\photos']]);
	assert.strictEqual(entries.find((e) => e.name === 'clip.mp4').size, VIDEO.length);
	assert.deepStrictEqual(await driver.shares(SOURCE), ['media']);
	const bad = createSmbDriver(fakeLib());
	await assert.rejects(bad.list(Object.assign({}, SOURCE, {password: 'nope'}), ''), (e) => e.code === 'auth');
});

test('the bridge serves SMB files with ranges, a megabyte at a time', async (t) => {
	const lib = fakeLib();
	const b = await startBridge([SOURCE], {loadSmb: () => ({createSmbDriver: () => createSmbDriver(lib)})});
	t.after(() => b.stop());
	if (Number(process.versions.node.split('.')[0]) < 12) return;
	const listing = await fetchJson(`${b.base}/list?s=nas&r=photos`);
	assert.strictEqual(listing.status, 200);
	assert.deepStrictEqual(listing.json.folders, [{ref: 'photos/été 2026', name: 'été 2026'}]);
	assert.deepStrictEqual(listing.json.files.map((f) => f.name), ['a.jpg', 'clip.mp4']);
	const whole = await fetchRaw(`${b.base}/file?s=nas&r=photos/clip.mp4`);
	assert.strictEqual(whole.status, 200);
	assert.strictEqual(Number(whole.headers['content-length']), VIDEO.length);
	assert.ok(whole.body.equals(VIDEO));
	assert.ok(lib.calls.reads.every((r) => r[2] <= 1024 * 1024));
	const part = await fetchRaw(`${b.base}/file?s=nas&r=photos/clip.mp4`, {headers: {Range: 'bytes=1048570-1048590'}});
	assert.strictEqual(part.status, 206);
	assert.strictEqual(part.headers['content-range'], `bytes 1048570-1048590/${VIDEO.length}`);
	assert.ok(part.body.equals(VIDEO.slice(1048570, 1048591)));
	const past = await fetchRaw(`${b.base}/file?s=nas&r=photos/clip.mp4`, {headers: {Range: `bytes=${VIDEO.length}-`}});
	assert.strictEqual(past.status, 416);
	const thumb = await fetchRaw(`${b.base}/thumb?s=nas&r=photos/a.jpg`);
	assert.strictEqual(thumb.status, 200);
	const missing = await fetchJson(`${b.base}/list?s=nas&r=missing`);
	assert.strictEqual(missing.status, 404);
	assert.strictEqual(missing.json.code, 'not_found');
});

test('without Node 12 or without the SMB bundle, SMB is refused with a reason', async (t) => {
	const b = await startBridge([SOURCE]);
	t.after(() => b.stop());
	const answer = await fetchJson(`${b.base}/list?s=nas`);
	assert.strictEqual(answer.status, 501);
	assert.strictEqual(answer.json.code, 'smb_unavailable');
});
