'use strict';
/* global Buffer */
const test = require('node:test');
const assert = require('node:assert');
const exif = require('../src/exif');
const {makeJpeg} = require('./jpeg');

test('the head of a JPEG gives its thumbnail, size, camera and the GPano projection', () => {
	const thumbnail = Buffer.concat([Buffer.from([0xff, 0xd8]), Buffer.alloc(500, 7), Buffer.from([0xff, 0xd9])]);
	const file = makeJpeg({thumbnail, gpano: true, orientation: 6, width: 5376, height: 2688});
	const info = exif.readJpegHead(file.slice(0, exif.HEAD_BYTES));
	assert.strictEqual(info.make, 'RICOH');
	assert.strictEqual(info.model, 'RICOH THETA Z1');
	assert.strictEqual(info.orientation, 6);
	assert.strictEqual(info.width, 5376);
	assert.strictEqual(info.height, 2688);
	assert.strictEqual(info.projection, 'equirectangular');
	assert.strictEqual(info.panoCoverage, 1);
	assert.ok(info.thumbnail.equals(thumbnail));
});

test('a JPEG without EXIF still tells its size; anything else tells nothing', () => {
	const info = exif.readJpegHead(makeJpeg({exif: false, width: 800, height: 600}));
	assert.strictEqual(info.width, 800);
	assert.strictEqual(info.height, 600);
	assert.strictEqual(info.thumbnail, null);
	assert.strictEqual(info.projection, null);
	assert.deepStrictEqual(exif.readJpegHead(Buffer.from('not a jpeg')).width, null);
});

test('a truncated head does not throw', () => {
	const file = makeJpeg({});
	for (const size of [3, 10, 40, 120, 300]) exif.readJpegHead(file.slice(0, size));
});
