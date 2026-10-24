// Immuch360: what the video decoders of the TV take, asked once per session and kept as a record. The About page shows
// it line by line, and the viewer checks a video against it before playing (limits.ts): a Samsung S90C answered
// "supported" for every codec at 4K and "not supported" for H.264 and HEVC at 5.7K, then loaded an 8K video forever.
//
// canPlayType only reads the codec string; Media Source and mediaCapabilities.decodingInfo also take the size, and
// decodingInfo is the answer the ceiling is drawn from. A TV without decodingInfo has no ceiling: nothing is held back.

/** The sizes the probes ask about, the smallest first */
export const PROBE_SIZES = {
	'4K': {width: 3840, height: 2160},
	'5.7K': {width: 5760, height: 2880},
} as const;

export type ProbeSize = keyof typeof PROBE_SIZES;

export interface DecoderProbe {
	/** The name of the About line: "H.264 4K" */
	name: string;
	/** The codec, whose answers at two sizes tell a size limit from a codec the TV lacks */
	family: string;
	size: ProbeSize;
	contentType: string;
	bitrate: number;
}

export const DECODER_PROBES: DecoderProbe[] = [
	{name: 'H.264 4K', family: 'H.264', size: '4K', contentType: 'video/mp4; codecs="avc1.640033"', bitrate: 40000000},
	{name: 'H.264 5.7K', family: 'H.264', size: '5.7K', contentType: 'video/mp4; codecs="avc1.640034"', bitrate: 100000000},
	{name: 'HEVC 4K', family: 'HEVC', size: '4K', contentType: 'video/mp4; codecs="hvc1.1.6.L153.B0"', bitrate: 40000000},
	{name: 'HEVC 5.7K', family: 'HEVC', size: '5.7K', contentType: 'video/mp4; codecs="hvc1.1.6.L183.B0"', bitrate: 100000000},
	{name: 'HEVC 10 bit 4K', family: 'HEVC 10 bit', size: '4K', contentType: 'video/mp4; codecs="hvc1.2.4.L153.B0"', bitrate: 40000000},
	{name: 'AV1 4K', family: 'AV1', size: '4K', contentType: 'video/mp4; codecs="av01.0.12M.08"', bitrate: 40000000},
	{name: 'VP9 4K', family: 'VP9', size: '4K', contentType: 'video/webm; codecs="vp09.00.51.08"', bitrate: 40000000},
];

export interface DecodingInfo {
	supported: boolean;
	smooth: boolean;
	powerEfficient: boolean;
}

/** The TV's answers to one probe */
export interface DecoderAnswer {
	probe: DecoderProbe;
	/** "probably", "maybe" or "no" */
	canPlay: string;
	/** Whether Media Source takes the type, null without Media Source */
	mediaSource: 'yes' | 'no' | null;
	/** decodingInfo's answer, null without mediaCapabilities or when it threw */
	decoding: DecodingInfo | null;
	/** What decodingInfo threw */
	decodingError: string | null;
}

export type DecoderRecord = DecoderAnswer[];

/** The calls the probes make, given by the page (browserDecoders) or by a test */
export interface DecoderEnvironment {
	canPlayType: (contentType: string) => string;
	isTypeSupported?: (contentType: string) => boolean;
	decodingInfo?: (config: unknown) => Promise<DecodingInfo>;
}

/** Asks each probe of the TV, one after the other */
export async function askDecoders(env: DecoderEnvironment, probes: DecoderProbe[] = DECODER_PROBES): Promise<DecoderRecord> {
	const record: DecoderRecord = [];
	for (const probe of probes) {
		let canPlay = 'no';
		try {
			canPlay = env.canPlayType(probe.contentType) || 'no';
		} catch {
			// "no"
		}
		let mediaSource: DecoderAnswer['mediaSource'] = null;
		if (env.isTypeSupported) {
			try {
				mediaSource = env.isTypeSupported(probe.contentType) ? 'yes' : 'no';
			} catch {
				mediaSource = null;
			}
		}
		let decoding: DecodingInfo | null = null;
		let decodingError: string | null = null;
		if (env.decodingInfo) {
			const {width, height} = PROBE_SIZES[probe.size];
			try {
				const info = await env.decodingInfo({
					type: 'file',
					video: {contentType: probe.contentType, width, height, bitrate: probe.bitrate, framerate: 30},
				});
				decoding = {supported: !!info.supported, smooth: !!info.smooth, powerEfficient: !!info.powerEfficient};
			} catch (error) {
				decodingError = error instanceof Error ? error.message : String(error);
			}
		}
		record.push({probe, canPlay, mediaSource, decoding, decodingError});
	}
	return record;
}

/** The calls of this page: a video element's canPlayType, MediaSource and navigator.mediaCapabilities */
export function browserDecoders(): DecoderEnvironment {
	const video = document.createElement('video');
	const source = (window as {MediaSource?: {isTypeSupported?: (type: string) => boolean}}).MediaSource;
	const capabilities = (navigator as {mediaCapabilities?: {decodingInfo?: (config: unknown) => Promise<DecodingInfo>}}).mediaCapabilities;
	return {
		canPlayType: (type) => video.canPlayType(type),
		isTypeSupported: source && typeof source.isTypeSupported === 'function' ? (type) => source.isTypeSupported!(type) : undefined,
		decodingInfo: capabilities && typeof capabilities.decodingInfo === 'function' ? (config) => capabilities.decodingInfo!(config) : undefined,
	};
}

/** The About line of one answer: "canPlayType probably, Media Source yes, supported, smooth, hardware" */
export function decoderVerdict(answer: DecoderAnswer): string {
	let verdict = `canPlayType ${answer.canPlay}`;
	if (answer.mediaSource) verdict += `, Media Source ${answer.mediaSource}`;
	if (answer.decoding) {
		const {supported, smooth, powerEfficient} = answer.decoding;
		verdict += `, ${supported ? 'supported' : 'not supported'}${smooth ? ', smooth' : ''}${powerEfficient ? ', hardware' : ''}`;
	} else if (answer.decodingError) {
		verdict += `, decodingInfo: ${answer.decodingError}`;
	}
	return verdict;
}

/** The largest video the decoders of this TV take, when a larger one was refused */
export interface DecoderCeiling {
	size: ProbeSize;
	width: number;
	height: number;
}

const pixels = (size: ProbeSize) => PROBE_SIZES[size].width * PROBE_SIZES[size].height;

/** The largest size some decoder of the TV said it takes, null when none did (or the TV has no decodingInfo) */
export function largestDecoded(record: DecoderRecord | null): ProbeSize | null {
	let largest: ProbeSize | null = null;
	for (const answer of record ?? []) {
		if (answer.decoding?.supported && (!largest || pixels(answer.probe.size) > pixels(largest))) largest = answer.probe.size;
	}
	return largest;
}

/**
 * The ceiling of the TV's decoders, or null when the record does not show one. There is one when a codec the TV takes
 * at a size is refused at a larger size (a size limit, not a codec the TV lacks), and no codec takes that larger size:
 * the video's codec is not known before it plays, so a larger size any codec takes is no ceiling. A Samsung S90C:
 * every codec at 4K, H.264 and HEVC refused at 5.7K, a 4K ceiling. An LG 50NANO763QA, which takes 5.7K: none.
 */
export function decoderCeiling(record: DecoderRecord | null): DecoderCeiling | null {
	const largest = largestDecoded(record);
	if (!record || !largest) return null;
	const takenBy = (family: string, size: ProbeSize) =>
		record.some((answer) => answer.probe.family === family && answer.probe.size === size && answer.decoding?.supported === true);
	const sizeRefused = record.some(
		(answer) =>
			answer.decoding?.supported === false &&
			pixels(answer.probe.size) > pixels(largest) &&
			(Object.keys(PROBE_SIZES) as ProbeSize[]).some((smaller) => pixels(smaller) < pixels(answer.probe.size) && takenBy(answer.probe.family, smaller))
	);
	return sizeRefused ? {size: largest, ...PROBE_SIZES[largest]} : null;
}

/**
 * How far past the ceiling a video may go and still be tried: a decoder said to take 3840 x 2160 takes 4096 x 2160 and
 * 4096 x 2048 (DCI 4K and the 4K of several 360° cameras); 5120 x 2560 and 7680 x 3840 are well past it
 */
export const CEILING_MARGIN = 1.15;

/**
 * Whether a video of this size is past the ceiling: more pixels, or a longer side, than the ceiling by more than the
 * margin. Its orientation does not count (a portrait 2160 x 3840 is a 4K video).
 */
export function exceedsCeiling(width: number, height: number, ceiling: DecoderCeiling): boolean {
	if (!(width > 0) || !(height > 0)) return false;
	const longSide = Math.max(width, height);
	const ceilingLongSide = Math.max(ceiling.width, ceiling.height);
	return width * height > ceiling.width * ceiling.height * CEILING_MARGIN || longSide > ceilingLongSide * CEILING_MARGIN;
}
