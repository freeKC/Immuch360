'use strict';
const test = require('node:test');
const assert = require('node:assert');
const httpx = require('../src/httpx');

test('parseRange reads the ranges players send', () => {
	assert.deepStrictEqual(httpx.parseRange('bytes=0-', 1000), {start: 0, end: 999});
	assert.deepStrictEqual(httpx.parseRange('bytes=100-199', 1000), {start: 100, end: 199});
	assert.deepStrictEqual(httpx.parseRange('bytes=900-5000', 1000), {start: 900, end: 999});
	assert.deepStrictEqual(httpx.parseRange('bytes=-100', 1000), {start: 900, end: 999});
	assert.deepStrictEqual(httpx.parseRange('bytes=-5000', 1000), {start: 0, end: 999});
	assert.deepStrictEqual(httpx.parseRange('bytes=0-9, 20-29', 1000), {start: 0, end: 9});
	assert.strictEqual(httpx.parseRange('bytes=1000-', 1000), 'unsatisfiable');
	assert.strictEqual(httpx.parseRange('bytes=-0', 1000), 'unsatisfiable');
	assert.strictEqual(httpx.parseRange(undefined, 1000), null);
	assert.strictEqual(httpx.parseRange('items=0-1', 1000), null);
	assert.strictEqual(httpx.parseRange('bytes=5-2', 1000), null);
});
