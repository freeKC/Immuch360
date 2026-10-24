// Immuch360: the decisions of the viewer on a video, from the decoder record of the session and the WebGL verdict:
// a video past the TV's decoders does not start (Samsung S90C), an LG TV that takes 5.7K plays what it played, a video
// that never gets going stops in a bounded time, and 360° videos say why they play flat where the TV gives black frames.
import {DECODER_PROBES, askDecoders, decoderCeiling, type DecoderRecord} from './decoders';
import {
	HEAVY_VIDEO_MBPS,
	VIDEO_CHECK_MAX_MS,
	VIDEO_STALL_NOTICE_MS,
	flatVideoNotice,
	nextStallState,
	stallNotice,
	startAdvice,
	videoBitrateMbps,
	videoGate,
	videoStart,
	type StallState,
} from './limits';
import {VIDEO_STALL_MS} from '../keys';

const WIDTHS: Record<number, string> = {3840: '4K', 5760: '5.7K'};

function record(takes: (family: string, size: string) => boolean): Promise<DecoderRecord> {
	const family = (type: string) => DECODER_PROBES.find((probe) => probe.contentType === type)!.family;
	return askDecoders({
		canPlayType: () => 'probably',
		isTypeSupported: () => true,
		decodingInfo: async (config) => {
			const {video} = config as {video: {contentType: string; width: number}};
			const ok = takes(family(video.contentType), WIDTHS[video.width]!);
			return {supported: ok, smooth: ok, powerEfficient: ok};
		},
	});
}

const samsungS90C = () => record((_family, size) => size === '4K');
const lg50Nano = () => record(() => true);
const EIGHT_K = {width: 7680, height: 3840};

describe('a video against the decoder record', () => {
	test('Samsung S90C: an 8K original past its 4K decoders does not start, and says its size', async () => {
		const ceiling = decoderCeiling(await samsungS90C());
		expect(videoGate({ceiling, size: EIGHT_K, playsOriginal: true, timedOut: false})).toEqual({kind: 'tooLarge', size: '4K', width: 7680, height: 3840});
		// Waiting for the size, then for the server's word on the file it plays
		expect(videoGate({ceiling, size: undefined, playsOriginal: undefined, timedOut: false})).toEqual({kind: 'check'});
		expect(videoGate({ceiling, size: EIGHT_K, playsOriginal: undefined, timedOut: false})).toEqual({kind: 'check'});
	});

	test('Samsung S90C: 4K and the 4K of 360° cameras play; a transcode or a server that cannot tell plays', async () => {
		const ceiling = decoderCeiling(await samsungS90C());
		for (const size of [{width: 3840, height: 2160}, {width: 3840, height: 1920}, {width: 4096, height: 2048}, {width: 1920, height: 1080}]) {
			expect(videoGate({ceiling, size, playsOriginal: undefined, timedOut: false})).toEqual({kind: 'play'});
		}
		// Immich made a 720p transcode of the 8K HEVC original: the TV plays that
		expect(videoGate({ceiling, size: EIGHT_K, playsOriginal: false, timedOut: false})).toEqual({kind: 'play'});
		expect(videoGate({ceiling, size: EIGHT_K, playsOriginal: null, timedOut: false})).toEqual({kind: 'play'});
		// No size in the details, or no details
		expect(videoGate({ceiling, size: {width: null, height: null}, playsOriginal: undefined, timedOut: false})).toEqual({kind: 'play'});
		expect(videoGate({ceiling, size: null, playsOriginal: undefined, timedOut: false})).toEqual({kind: 'play'});
	});

	test('a check that takes longer than VIDEO_CHECK_MAX_MS no longer holds the video', async () => {
		const ceiling = decoderCeiling(await samsungS90C());
		expect(VIDEO_CHECK_MAX_MS).toBe(4000);
		expect(videoGate({ceiling, size: undefined, playsOriginal: undefined, timedOut: true})).toEqual({kind: 'play'});
		expect(videoGate({ceiling, size: EIGHT_K, playsOriginal: undefined, timedOut: true})).toEqual({kind: 'play'});
		// A late word of the server still stops a video it plays as the 8K original
		expect(videoGate({ceiling, size: EIGHT_K, playsOriginal: true, timedOut: true}).kind).toBe('tooLarge');
	});

	test('LG 50NANO763QA takes 5.7K: every video plays as before, 8K included, without waiting', async () => {
		const ceiling = decoderCeiling(await lg50Nano());
		expect(ceiling).toBeNull();
		expect(videoGate({ceiling, size: EIGHT_K, playsOriginal: true, timedOut: false})).toEqual({kind: 'play'});
		expect(videoGate({ceiling, size: undefined, playsOriginal: undefined, timedOut: false})).toEqual({kind: 'play'});
	});

	test('a record not in yet holds nothing back', () => {
		expect(videoGate({ceiling: decoderCeiling(null), size: EIGHT_K, playsOriginal: true, timedOut: false})).toEqual({kind: 'play'});
	});
});

describe('a video that never gets going', () => {
	const base = {currentTime: 0, canPlay: false, paused: true, error: false};

	test('stops 20 s after the player opened when it never reached canplay, paused or not', () => {
		expect(VIDEO_STALL_MS).toBe(20000);
		expect(videoStart({...base, elapsedMs: 19000}, VIDEO_STALL_MS)).toBe('waiting');
		// The S90C and its 8K video: no error, never canplay
		expect(videoStart({...base, elapsedMs: 20000}, VIDEO_STALL_MS)).toBe('notStarted');
		expect(videoStart({...base, paused: false, elapsedMs: 20000}, VIDEO_STALL_MS)).toBe('notStarted');
	});

	test('reached canplay: stops only when it should play and shows nothing; one paused by the user waits', () => {
		expect(videoStart({...base, canPlay: true, paused: false, elapsedMs: 20000}, VIDEO_STALL_MS)).toBe('notStarted');
		expect(videoStart({...base, canPlay: true, paused: true, elapsedMs: 60000}, VIDEO_STALL_MS)).toBe('waiting');
	});

	test('a frame shown is a start, a media error a failure at once', () => {
		expect(videoStart({...base, currentTime: 0.04, elapsedMs: 30000}, VIDEO_STALL_MS)).toBe('started');
		expect(videoStart({...base, error: true, elapsedMs: 1000}, VIDEO_STALL_MS)).toBe('error');
	});
});

describe('the notice of a 360° video, which plays flat', () => {
	test('black frames: the first 360° video of the session says why, the next ones nothing', () => {
		let holder: string | null = null;
		const holds = (id: string) => () => {
			if (holder === null) holder = id;
			return holder === id;
		};
		expect(flatVideoNotice('black', holds('v1'))).toBe('noFrames');
		expect(flatVideoNotice('black', holds('v2'))).toBeNull();
		expect(flatVideoNotice('black', holds('v1'))).toBe('noFrames');
	});

	test('frames drawn, the test not run, or its clip not played: each says it plays flat, as before (LG)', () => {
		const never = jest.fn(() => true);
		expect(flatVideoNotice('yes', never)).toBe('flat');
		expect(flatVideoNotice(null, never)).toBe('flat');
		expect(flatVideoNotice('untested', never)).toBe('flat');
		// The session notice is taken only where it is shown
		expect(never).not.toHaveBeenCalled();
	});
});

// DeltaTango69's second report: a DJI clip, 3840 x 2160 at 59.94 fps, H.264, 377 MiB for 24 s, starts and stalls about
// 10 s in on the S90C; a Gear 360 clip, 3840 x 1920 at 31 Mb/s, plays
const DJI = {fileSize: 377 * 1048576, duration: 24};
const GEAR_360 = {fileSize: (31000000 * 24) / 8, duration: 24};

describe('a video that started and stalls', () => {
	const watch = (samples: [number, number, boolean | undefined][]) => {
		let state: StallState | null = null;
		return samples.map(([at, currentTime, paused]) => {
			state = nextStallState(state, {at, currentTime, paused});
			return state.stalled;
		});
	};

	test('no progress for 8 s while it should play: a stall, until the position moves again', () => {
		expect(VIDEO_STALL_NOTICE_MS).toBe(8000);
		const stalled = watch([
			[0, 9, false],
			[1000, 10, false],
			[5000, 10, false],
			[8999, 10, false],
			[9000, 10, false],
			[15000, 10, false],
			[16000, 10.5, false],
			[17000, 11, false],
		]);
		expect(stalled).toEqual([false, false, false, false, true, true, false, false]);
	});

	test('a paused video is no stall, and its 8 s count again from the last look while paused', () => {
		const stalled = watch([
			[0, 10, false],
			[1000, 10, true],
			[30000, 10, true],
			[31000, 10, false],
			[37000, 10, false],
			[38000, 10, false],
		]);
		expect(stalled).toEqual([false, false, false, false, false, true]);
	});

	test('a seek moves the position: the count starts again', () => {
		expect(watch([[0, 10, false], [7000, 10, false], [7500, 60, false], [14000, 60, false], [15500, 60, false]])).toEqual([false, false, false, false, true]);
	});
});

describe('the bitrate of a file', () => {
	test('from its size and duration: the DJI clip, the Gear 360 clip, a light file', () => {
		expect(videoBitrateMbps(DJI.fileSize, DJI.duration)).toBe(132);
		expect(videoBitrateMbps(GEAR_360.fileSize, GEAR_360.duration)).toBe(31);
		expect(videoBitrateMbps(12000000, 20)).toBe(4.8);
		expect(videoBitrateMbps(1000, 3600)).toBe(0.1);
	});

	test('not known without a size or a duration', () => {
		expect(videoBitrateMbps(null, 24)).toBeNull();
		expect(videoBitrateMbps(DJI.fileSize, null)).toBeNull();
		expect(videoBitrateMbps(DJI.fileSize, 0)).toBeNull();
		expect(videoBitrateMbps(0, 24)).toBeNull();
		expect(videoBitrateMbps(DJI.fileSize, Number.NaN)).toBeNull();
	});
});

describe('what the notices say of a heavy file', () => {
	const dji = videoBitrateMbps(DJI.fileSize, DJI.duration);
	const gear = videoBitrateMbps(GEAR_360.fileSize, GEAR_360.duration);

	test('a stall of the original: its bitrate and Immich transcoding; of a share: a faster link', () => {
		expect(stallNotice({playsOriginal: true, bitrate: dji, serverTranscodes: true})).toEqual({kind: 'heavy', advice: 'transcode'});
		expect(stallNotice({playsOriginal: true, bitrate: null, serverTranscodes: true})).toEqual({kind: 'heavyUnknown', advice: 'transcode'});
		expect(stallNotice({playsOriginal: true, bitrate: dji, serverTranscodes: false})).toEqual({kind: 'heavy', advice: 'wired'});
	});

	test('a stall of a transcode, or before the server said which file it plays: the link only, no advice', () => {
		expect(stallNotice({playsOriginal: false, bitrate: dji, serverTranscodes: true})).toEqual({kind: 'slowLink', advice: null});
		expect(stallNotice({playsOriginal: null, bitrate: dji, serverTranscodes: true})).toEqual({kind: 'slowLink', advice: null});
		expect(stallNotice({playsOriginal: undefined, bitrate: dji, serverTranscodes: true})).toEqual({kind: 'slowLink', advice: null});
	});

	test('could not start: the advice for an original above 60 Mb/s only', () => {
		expect(HEAVY_VIDEO_MBPS).toBe(60);
		expect(startAdvice({playsOriginal: true, bitrate: dji, serverTranscodes: true})).toBe('transcode');
		expect(startAdvice({playsOriginal: true, bitrate: dji, serverTranscodes: false})).toBe('wired');
		expect(startAdvice({playsOriginal: true, bitrate: gear, serverTranscodes: true})).toBeNull();
		expect(startAdvice({playsOriginal: true, bitrate: null, serverTranscodes: true})).toBeNull();
		expect(startAdvice({playsOriginal: false, bitrate: dji, serverTranscodes: true})).toBeNull();
	});
});
