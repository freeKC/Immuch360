// Immuch360: what this session knows of the TV's video, asked once and read by the viewer without asking again. The
// decoder record (decoders.ts) is asked at the start of the app (startVideoChecks in diagnostics/collect.ts) and read by
// the About page. The video frames verdict comes from the WebGL test of the About page, or on a Samsung TV from the same
// test run once a few seconds after the start (features.ts, probeVideoFramesAtStart). Nothing here runs on the play
// path: the viewer reads what is known and subscribes for what comes later.

import {askDecoders, browserDecoders, type DecoderRecord} from './decoders';

/** What the WebGL test said: frames drawn, frames black (a hardware video plane), or the clip did not play */
export type VideoFramesVerdict = 'yes' | 'black' | 'untested';

let decoders: Promise<DecoderRecord> | null = null;
let knownRecord: DecoderRecord | null = null;
let frames: VideoFramesVerdict | null = null;
let flatNoticeHolder: string | null = null;
const listeners = new Set<() => void>();
let version = 0;

const changed = () => {
	version += 1;
	listeners.forEach((listener) => listener());
};

/** The decoder record of this session: asked the first time, the same promise after */
export function sessionDecoders(ask: () => Promise<DecoderRecord> = () => askDecoders(browserDecoders())): Promise<DecoderRecord> {
	if (!decoders) {
		decoders = ask().then(
			(record) => {
				knownRecord = record;
				changed();
				return record;
			},
			// A failure leaves no record (no ceiling) and lets a later call ask again
			(error: unknown) => {
				decoders = null;
				throw error;
			}
		);
	}
	return decoders;
}

/** The decoder record once it is in, null before */
export const knownDecoders = (): DecoderRecord | null => knownRecord;

/**
 * Keeps the verdict of a WebGL video test, the latest one winning (Retry on the About page), but for a clip that did not
 * play, which tells nothing and leaves an earlier yes or black as it is
 */
export function recordVideoFrames(verdict: VideoFramesVerdict): void {
	if (frames === verdict || (verdict === 'untested' && frames !== null)) return;
	frames = verdict;
	changed();
}

/** The verdict of the last WebGL video test of this session, null before one ended */
export const knownVideoFrames = (): VideoFramesVerdict | null => frames;

/**
 * Whether the notice that 360° videos play flat on this TV goes with this video: the first 360° video opened in the
 * session holds it, and keeps it when opened again; the others play flat without it
 */
export function holdsFlatVideoNotice(assetId: string): boolean {
	if (flatNoticeHolder === null) flatNoticeHolder = assetId;
	return flatNoticeHolder === assetId;
}

/** For useSyncExternalStore: a call on every change, and a number that changes with it */
export function subscribeVideoSession(listener: () => void): () => void {
	listeners.add(listener);
	return () => {
		listeners.delete(listener);
	};
}

export const videoSessionVersion = (): number => version;

/** Forgets everything (tests) */
export function resetVideoSession(): void {
	decoders = null;
	knownRecord = null;
	frames = null;
	flatNoticeHolder = null;
	changed();
}

/** Sets the record as if it had been asked (tests) */
export function setKnownDecoders(record: DecoderRecord | null): void {
	knownRecord = record;
	decoders = record ? Promise.resolve(record) : null;
	changed();
}
