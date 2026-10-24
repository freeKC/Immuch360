// What the TV app knows of a TV's video (src/immuch360/video): the decoder record asked once per session, its ceiling,
// the size check of a video against it, and the verdict of the WebGL video test kept for the session. The records are
// those of the first real TVs: a Samsung S90C (Tizen 9.0, 24 October 2026) and an LG 50NANO763QA (webOS 7.6).

import {beforeEach, describe, test} from 'node:test';
import assert from 'node:assert/strict';
import {
	CEILING_MARGIN,
	DECODER_PROBES,
	askDecoders,
	decoderCeiling,
	decoderVerdict,
	exceedsCeiling,
	largestDecoded,
} from '../../src/immuch360/video/decoders.ts';
import {
	holdsFlatVideoNotice,
	knownDecoders,
	knownVideoFrames,
	recordVideoFrames,
	resetVideoSession,
	sessionDecoders,
	subscribeVideoSession,
	videoSessionVersion,
} from '../../src/immuch360/video/session.ts';

const WIDTHS = {3840: '4K', 5760: '5.7K'};

/**
 * A TV that answers decodingInfo with takes(codec family, size); canPlayType and Media Source say yes to every probe,
 * as on both TVs. The families are read back from the codec string.
 */
function fakeTv(takes, {canPlay = 'probably', mse = true, decodingInfo = true} = {}) {
	const family = (type) => DECODER_PROBES.find((probe) => probe.contentType === type).family;
	const asked = [];
	return {
		asked,
		env: {
			canPlayType: () => canPlay,
			isTypeSupported: mse ? () => true : undefined,
			decodingInfo: decodingInfo
				? async (config) => {
						asked.push(config);
						const ok = takes(family(config.video.contentType), WIDTHS[config.video.width]);
						return {supported: ok, smooth: ok, powerEfficient: ok};
					}
				: undefined,
		},
	};
}

// Samsung S90C: every codec at 4K, H.264 and HEVC refused at 5.7K
const samsung = () => fakeTv((family, size) => size === '4K');
// LG 50NANO763QA: every codec at 4K and 5.7K
const lg = () => fakeTv(() => true);
// A Chromium without H.264 nor HEVC (the end to end engines): AV1 and VP9 only
const chromiumWithoutH264 = () => fakeTv((family) => family === 'AV1' || family === 'VP9', {canPlay: ''});

describe('the decoder record', () => {
	test('asks each probe once, with its size, and keeps the About lines as before', async () => {
		const tv = samsung();
		const record = await askDecoders(tv.env);
		assert.equal(record.length, 7);
		assert.deepEqual(tv.asked[1], {
			type: 'file',
			video: {contentType: 'video/mp4; codecs="avc1.640034"', width: 5760, height: 2880, bitrate: 100000000, framerate: 30},
		});
		// The lines of the tester's QR code, word for word
		const lines = record.map((answer) => `${answer.probe.name}: ${decoderVerdict(answer)}`);
		assert.deepEqual(lines, [
			'H.264 4K: canPlayType probably, Media Source yes, supported, smooth, hardware',
			'H.264 5.7K: canPlayType probably, Media Source yes, not supported',
			'HEVC 4K: canPlayType probably, Media Source yes, supported, smooth, hardware',
			'HEVC 5.7K: canPlayType probably, Media Source yes, not supported',
			'HEVC 10 bit 4K: canPlayType probably, Media Source yes, supported, smooth, hardware',
			'AV1 4K: canPlayType probably, Media Source yes, supported, smooth, hardware',
			'VP9 4K: canPlayType probably, Media Source yes, supported, smooth, hardware',
		]);
	});

	test('without decodingInfo, Media Source, or with a decodingInfo that throws', async () => {
		const bare = await askDecoders(fakeTv(() => true, {canPlay: '', mse: false, decodingInfo: false}).env);
		assert.equal(decoderVerdict(bare[0]), 'canPlayType no');
		const throwing = await askDecoders({canPlayType: () => 'maybe', decodingInfo: async () => Promise.reject(new Error('not allowed'))});
		assert.equal(decoderVerdict(throwing[0]), 'canPlayType maybe, decodingInfo: not allowed');
		assert.equal(throwing[0].decoding, null);
	});
});

describe('the ceiling of the decoders', () => {
	test('Samsung S90C: 4K, as H.264 and HEVC take 4K and refuse 5.7K', async () => {
		const record = await askDecoders(samsung().env);
		assert.equal(largestDecoded(record), '4K');
		assert.deepEqual(decoderCeiling(record), {size: '4K', width: 3840, height: 2160});
	});

	test('LG 50NANO763QA: none, as it takes 5.7K (the LG behaviour stays)', async () => {
		const record = await askDecoders(lg().env);
		assert.equal(largestDecoded(record), '5.7K');
		assert.equal(decoderCeiling(record), null);
	});

	test('one codec taking 5.7K is enough to hold no video back: the codec of a video is not known before it plays', async () => {
		const record = await askDecoders(fakeTv((family, size) => size === '4K' || family === 'HEVC').env);
		assert.equal(decoderCeiling(record), null);
	});

	test('a codec the TV lacks at every size is no size limit (a Chromium without H.264)', async () => {
		const record = await askDecoders(chromiumWithoutH264().env);
		assert.equal(largestDecoded(record), '4K');
		assert.equal(decoderCeiling(record), null);
	});

	test('no record, or no decodingInfo: none', async () => {
		assert.equal(decoderCeiling(null), null);
		assert.equal(decoderCeiling(await askDecoders(fakeTv(() => true, {decodingInfo: false}).env)), null);
		// Every size refused: nothing tells what the TV takes, nothing is held back
		assert.equal(decoderCeiling(await askDecoders(fakeTv(() => false).env)), null);
	});

	test('the sizes past a 4K ceiling', () => {
		const ceiling = {size: '4K', width: 3840, height: 2160};
		assert.equal(CEILING_MARGIN, 1.15);
		// Tried: 4K, DCI 4K, the 4K of 360° cameras, a portrait 4K, HD
		for (const [w, h] of [[3840, 2160], [4096, 2160], [3840, 1920], [4096, 2048], [2160, 3840], [1920, 1080], [2880, 2880]]) {
			assert.equal(exceedsCeiling(w, h, ceiling), false, `${w} x ${h}`);
		}
		// Held back: 5K, 5.6K, 5.7K, 8K 360°, 4K stereo top and bottom
		for (const [w, h] of [[5120, 2560], [5376, 2688], [5760, 2880], [7680, 3840], [3840, 3840]]) {
			assert.equal(exceedsCeiling(w, h, ceiling), true, `${w} x ${h}`);
		}
		assert.equal(exceedsCeiling(0, 0, ceiling), false);
		assert.equal(exceedsCeiling(Number.NaN, 3840, ceiling), false);
	});
});

describe('the session', () => {
	beforeEach(() => resetVideoSession());

	test('the record is asked once, and told to the listeners when it comes', async () => {
		let asks = 0;
		let told = 0;
		const stop = subscribeVideoSession(() => told++);
		const ask = () => {
			asks += 1;
			return askDecoders(samsung().env);
		};
		assert.equal(knownDecoders(), null);
		const before = videoSessionVersion();
		const [first, second] = await Promise.all([sessionDecoders(ask), sessionDecoders(ask)]);
		assert.equal(asks, 1);
		assert.equal(first, second);
		assert.equal(knownDecoders(), first);
		assert.equal(told, 1);
		assert.notEqual(videoSessionVersion(), before);
		stop();
	});

	test('a record that could not be asked is asked again the next time', async () => {
		await assert.rejects(sessionDecoders(() => Promise.reject(new Error('no video element'))));
		assert.equal(knownDecoders(), null);
		const record = await sessionDecoders(() => askDecoders(lg().env));
		assert.equal(knownDecoders(), record);
	});

	test('the WebGL verdict: the latest test wins, but a clip that did not play leaves a yes or black as it is', () => {
		assert.equal(knownVideoFrames(), null);
		recordVideoFrames('untested');
		assert.equal(knownVideoFrames(), 'untested');
		recordVideoFrames('black');
		recordVideoFrames('untested');
		assert.equal(knownVideoFrames(), 'black');
		recordVideoFrames('yes');
		assert.equal(knownVideoFrames(), 'yes');
	});

	test('the notice of flat 360° videos goes with the first one opened, and with it only', () => {
		assert.equal(holdsFlatVideoNotice('v1'), true);
		assert.equal(holdsFlatVideoNotice('v1'), true);
		assert.equal(holdsFlatVideoNotice('v2'), false);
		resetVideoSession();
		assert.equal(holdsFlatVideoNotice('v2'), true);
	});
});
