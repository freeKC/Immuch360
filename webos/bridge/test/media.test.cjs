'use strict';
const test = require('node:test');
const assert = require('node:assert');
const media = require('../src/media');

test('classify tells photos, videos and what the TV cannot decode', () => {
	assert.deepStrictEqual(media.classify('IMG_0001.JPG'), {kind: 'image', mime: 'image/jpeg'});
	assert.deepStrictEqual(media.classify('clip.mkv'), {kind: 'video', mime: 'video/x-matroska'});
	assert.strictEqual(media.classify('IMG_0002.HEIC').kind, 'unsupported');
	assert.strictEqual(media.classify('notes.txt').kind, null);
	assert.strictEqual(media.classify('noext', 'image/jpeg').kind, 'image');
	assert.strictEqual(media.classify('noext', 'video/mp4; charset=x').mime, 'video/mp4');
});

test('listings sort folders and files by name, numbers by value, and drop what is not media', () => {
	const shaped = media.shapeListing(
		[{name: 'b'}, {name: 'A'}],
		[{name: 'IMG_10.jpg', kind: 'image'}, {name: 'IMG_2.jpg', kind: 'image'}, {name: 'x.txt', kind: null}]
	);
	assert.deepStrictEqual(shaped.folders.map((f) => f.name), ['A', 'b']);
	assert.deepStrictEqual(shaped.files.map((f) => f.name), ['IMG_2.jpg', 'IMG_10.jpg']);
});

test('system folders and dot files are hidden', () => {
	for (const name of ['.DS_Store', '@eaDir', '#recycle', '$RECYCLE.BIN', 'Thumbs.db']) assert.ok(media.isHiddenName(name), name);
	assert.ok(!media.isHiddenName('Photos 2024'));
});
