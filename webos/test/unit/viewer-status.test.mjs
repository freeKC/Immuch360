// The loading pill and the zoom level of the viewer (src/immuch360/viewerStatus.ts), asked on discussion 8: a dark photo
// told from one still on its way, and the level of the zoom of Up and Down.

import {test, describe} from 'node:test';
import assert from 'node:assert/strict';
import {
	LOADING_SHOWN_AFTER_MS,
	ZOOM_LEVEL_SHOWN_MS,
	photoLoadStart,
	photoLoadStep,
	showsLoading,
	zoomLevelText,
} from '../../src/immuch360/viewerStatus.ts';

const run = (state, ...events) => events.reduce(photoLoadStep, state);

describe('the picture of a photo, from the address to its paint', () => {
	test('the pill after 300 ms, the zoom level for 1.5 s', () => {
		assert.equal(LOADING_SHOWN_AFTER_MS, 300);
		assert.equal(ZOOM_LEVEL_SHOWN_MS, 1500);
	});

	test('no pill before the delay, the pill once it ran out, none once painted', () => {
		const start = photoLoadStart('/preview/a');
		assert.equal(start.phase, 'loading');
		assert.equal(showsLoading(start), false);
		const slow = run(start, {type: 'delay', src: '/preview/a'});
		assert.equal(showsLoading(slow), true);
		const shown = run(slow, {type: 'painted', src: '/preview/a'});
		assert.equal(shown.phase, 'shown');
		assert.equal(showsLoading(shown), false);
	});

	test('a picture painted before the delay never shows the pill', () => {
		const state = run(photoLoadStart('/preview/a'), {type: 'painted', src: '/preview/a'}, {type: 'delay', src: '/preview/a'});
		assert.equal(state.phase, 'shown');
		assert.equal(showsLoading(state), false);
	});

	test('an error ends the wait, with or without the pill', () => {
		assert.equal(run(photoLoadStart('/preview/a'), {type: 'error', src: '/preview/a'}).phase, 'failed');
		const failed = run(photoLoadStart('/preview/a'), {type: 'delay', src: '/preview/a'}, {type: 'error', src: '/preview/a'});
		assert.equal(failed.phase, 'failed');
		assert.equal(showsLoading(failed), false);
	});

	test('the events of an earlier picture are ignored', () => {
		const next = run(photoLoadStart('/preview/a'), {type: 'src', src: '/preview/b'});
		assert.deepEqual(next, {src: '/preview/b', phase: 'loading'});
		assert.equal(run(next, {type: 'painted', src: '/preview/a'}), next);
		assert.equal(run(next, {type: 'error', src: '/preview/a'}), next);
		assert.equal(run(next, {type: 'delay', src: '/preview/a'}), next);
	});

	test('another address starts a new wait, the full-size picture included; the same one changes nothing', () => {
		const shown = run(photoLoadStart('/preview/a'), {type: 'painted', src: '/preview/a'});
		assert.equal(run(shown, {type: 'src', src: '/preview/a'}), shown);
		const fullsize = run(shown, {type: 'src', src: '/fullsize/a'});
		assert.deepEqual(fullsize, {src: '/fullsize/a', phase: 'loading'});
		assert.equal(showsLoading(run(fullsize, {type: 'delay', src: '/fullsize/a'})), true);
	});

	test('no address (a video, a 360° photo): nothing to wait for', () => {
		assert.deepEqual(photoLoadStart(null), {src: null, phase: 'shown'});
		assert.deepEqual(run(photoLoadStart('/preview/a'), {type: 'src', src: null}), {src: null, phase: 'shown'});
	});

	test('a painted or failed picture stays so', () => {
		const shown = run(photoLoadStart('/preview/a'), {type: 'painted', src: '/preview/a'});
		assert.equal(run(shown, {type: 'delay', src: '/preview/a'}), shown);
		const failed = run(photoLoadStart('/preview/a'), {type: 'error', src: '/preview/a'});
		assert.equal(run(failed, {type: 'painted', src: '/preview/a'}), failed);
		assert.equal(run(failed, {type: 'delay', src: '/preview/a'}), failed);
	});
});

describe('the zoom level', () => {
	test('a percentage of the steps of 1.25', () => {
		assert.equal(zoomLevelText(1, 'en-US'), '100%');
		assert.equal(zoomLevelText(1.25, 'en-US'), '125%');
		assert.equal(zoomLevelText(1.5625, 'en-US'), '156%');
		assert.equal(zoomLevelText(1.953125, 'en-US'), '195%');
		assert.equal(zoomLevelText(4, 'en-US'), '400%');
	});

	test('written for the locale', () => {
		const french = zoomLevelText(1.25, 'fr-FR');
		assert.match(french, /^125\s%$/u);
	});

	test('plain digits where the engine cannot write the locale', () => {
		assert.equal(zoomLevelText(1.25, 'not a locale!'), '125%');
	});
});
