// When the viewer swaps the preview of a flat photo for its full-size picture (src/immuch360/photoSize.ts)

import {test} from 'node:test';
import assert from 'node:assert/strict';
import {
	FULLSIZE_FROM_SCALE,
	FULLSIZE_MAX_PIXELS,
	FULLSIZE_MAX_PIXELS_BEFORE_WEBOS_6,
	chromiumMajor,
	fullsizePixelCap,
	wantsFullsize,
} from '../../src/immuch360/photoSize.ts';

test('the preview up to 2x, the full-size picture past it', () => {
	assert.equal(FULLSIZE_FROM_SCALE, 2);
	assert.equal(wantsFullsize(1, 6000, 4000, FULLSIZE_MAX_PIXELS), false);
	assert.equal(wantsFullsize(1.953125, 6000, 4000, FULLSIZE_MAX_PIXELS), false);
	assert.equal(wantsFullsize(2, 6000, 4000, FULLSIZE_MAX_PIXELS), false);
	assert.equal(wantsFullsize(2.44140625, 6000, 4000, FULLSIZE_MAX_PIXELS), true);
});

test('capped on the pixel count: a 48 MP phone photo never, a 12 MP one always', () => {
	assert.equal(wantsFullsize(3, 8064, 6048, FULLSIZE_MAX_PIXELS), false);
	assert.equal(wantsFullsize(3, 6048, 8064, FULLSIZE_MAX_PIXELS), false);
	assert.equal(wantsFullsize(3, 4032, 3024, FULLSIZE_MAX_PIXELS_BEFORE_WEBOS_6), true);
	// A long panorama of few pixels passes, where a cap on the longest side refused it
	assert.equal(wantsFullsize(3, 12000, 1500, FULLSIZE_MAX_PIXELS), true);
	// 24 MP on webOS 6 and later, 16 MP before
	assert.equal(wantsFullsize(3, 6000, 4000, FULLSIZE_MAX_PIXELS), true);
	assert.equal(wantsFullsize(3, 6000, 4000, FULLSIZE_MAX_PIXELS_BEFORE_WEBOS_6), false);
	assert.equal(wantsFullsize(3, 4928, 3264, FULLSIZE_MAX_PIXELS_BEFORE_WEBOS_6), true);
	assert.equal(wantsFullsize(3, 6048, 4024, FULLSIZE_MAX_PIXELS), true);
});

test('never before the size is known', () => {
	assert.equal(wantsFullsize(3, null, null, FULLSIZE_MAX_PIXELS), false);
	assert.equal(wantsFullsize(3, 6000, undefined, FULLSIZE_MAX_PIXELS), false);
});

test('the cap follows the Chromium of the TV', () => {
	const webos4 = 'Mozilla/5.0 (Web0S; Linux/SmartTV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/53.0.2785.34 Safari/537.36 WebAppManager';
	const webos6 = 'Mozilla/5.0 (Web0S; Linux/SmartTV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/79.0.3945.79 Safari/537.36 WebAppManager';
	assert.equal(chromiumMajor(webos4), 53);
	assert.equal(chromiumMajor(webos6), 79);
	assert.equal(chromiumMajor('Node.js/24'), null);
	assert.equal(chromiumMajor(undefined), null);
	assert.equal(fullsizePixelCap(53), FULLSIZE_MAX_PIXELS_BEFORE_WEBOS_6);
	assert.equal(fullsizePixelCap(68), FULLSIZE_MAX_PIXELS_BEFORE_WEBOS_6);
	assert.equal(fullsizePixelCap(79), FULLSIZE_MAX_PIXELS);
	assert.equal(fullsizePixelCap(120), FULLSIZE_MAX_PIXELS);
	assert.equal(fullsizePixelCap(null), FULLSIZE_MAX_PIXELS_BEFORE_WEBOS_6);
});
