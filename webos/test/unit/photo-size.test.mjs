// When the viewer swaps the preview of a flat photo for its full-size picture (src/immuch360/photoSize.ts)

import {test} from 'node:test';
import assert from 'node:assert/strict';
import {FULLSIZE_FROM_SCALE, FULLSIZE_MAX_SIDE, wantsFullsize} from '../../src/immuch360/photoSize.ts';

test('the preview up to 2x, the full-size picture past it', () => {
	assert.equal(FULLSIZE_FROM_SCALE, 2);
	assert.equal(wantsFullsize(1, 6000, 4000), false);
	assert.equal(wantsFullsize(1.953125, 6000, 4000), false);
	assert.equal(wantsFullsize(2, 6000, 4000), false);
	assert.equal(wantsFullsize(2.44140625, 6000, 4000), true);
});

test('never for a photo too large for a TV, nor before its size is known', () => {
	assert.equal(FULLSIZE_MAX_SIDE, 8192);
	assert.equal(wantsFullsize(3, 8192, 5464), true);
	assert.equal(wantsFullsize(3, 12000, 8000), false);
	assert.equal(wantsFullsize(3, null, null), false);
	assert.equal(wantsFullsize(3, 6000, undefined), false);
});
