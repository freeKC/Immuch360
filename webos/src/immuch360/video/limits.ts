// Immuch360: what the viewer does with a video the TV may not play, decided from what the session knows (session.ts)
// and never by probing at play time.
// 1. A video larger than the TV's decoders take (decoders.ts, decoderCeiling) does not start: a message says so, with
//    Back. Only where the record shows a ceiling (a Samsung S90C: 4K); a TV that takes more, or does not say, plays it
//    as before. The size is the asset's (Immich's metadata, a share's listing), and it counts only when the server
//    plays that file: Immich plays its transcode when it made one (by default for any codec but H.264, at 720p), and
//    Plex its HLS stream.
// 2. A video that never gets going stops within a bounded time with a message, instead of loading forever: the S90C
//    neither failed nor played an 8K video.
// 3. A 360° video plays flat. Where the WebGL video test found black frames (the video is on a hardware plane the page
//    cannot read), the first one of the session says why; elsewhere each says it plays flat, as before.

import {exceedsCeiling, type DecoderCeiling, type ProbeSize} from './decoders';
import type {VideoFramesVerdict} from './session';

/**
 * How long the viewer waits for the size of a video and for the server's word on the file it plays before it plays the
 * video anyway (a slow or silent server must not hold a video the TV may well play)
 */
export const VIDEO_CHECK_MAX_MS = 4000;

export type VideoGate = {kind: 'play'} | {kind: 'check'} | {kind: 'tooLarge'; size: ProbeSize; width: number; height: number};

const PLAY: VideoGate = {kind: 'play'};
const CHECK: VideoGate = {kind: 'check'};

export interface VideoGateInput {
	/** The ceiling of the TV's decoders, null when the record shows none or is not in yet */
	ceiling: DecoderCeiling | null;
	/** The size of the video: undefined while its details load, null when they did not come or do not tell */
	size: {width: number | null; height: number | null} | null | undefined;
	/** Whether the server plays the file of that size: undefined before it answered, null when it cannot tell */
	playsOriginal: boolean | null | undefined;
	/** VIDEO_CHECK_MAX_MS went by: what is still unknown no longer holds the video */
	timedOut: boolean;
}

/** Whether the viewer plays a video, waits a moment to know more, or says the TV cannot decode it */
export function videoGate({ceiling, size, playsOriginal, timedOut}: VideoGateInput): VideoGate {
	if (!ceiling) return PLAY;
	if (size === undefined) return timedOut ? PLAY : CHECK;
	if (!size || !size.width || !size.height || !exceedsCeiling(size.width, size.height, ceiling)) return PLAY;
	if (playsOriginal === undefined) return timedOut ? PLAY : CHECK;
	return playsOriginal === true ? {kind: 'tooLarge', size: ceiling.size, width: size.width, height: size.height} : PLAY;
}

/** Where a video stands since it opened: going, still getting there, failed with an error, or not started in time */
export type VideoStart = 'started' | 'waiting' | 'error' | 'notStarted';

export interface VideoStartInput {
	elapsedMs: number;
	currentTime: number;
	/** The video reached canplay (readyState HAVE_FUTURE_DATA or more) */
	canPlay: boolean;
	/** The paused flag of the video element, undefined when not known */
	paused: boolean | undefined;
	/** The video element holds a media error */
	error: boolean;
}

/**
 * A video that shows a frame has started. One with a media error has failed. One that did not reach canplay within the
 * time given, or reached it and still shows nothing while nobody paused it, has not started: the TV may never say more
 * (the S90C kept an 8K video "loading" without an error). The rule before this one waited for a playing element, which
 * a TV that never gets to canplay may not report.
 */
export function videoStart({elapsedMs, currentTime, canPlay, paused, error}: VideoStartInput, maxMs: number): VideoStart {
	if (currentTime > 0) return 'started';
	if (error) return 'error';
	if (elapsedMs < maxMs) return 'waiting';
	return !canPlay || paused === false ? 'notStarted' : 'waiting';
}

/** The notice of a 360° video, which plays flat: why (black frames), that it does (elsewhere), or none */
export type FlatVideoNotice = 'noFrames' | 'flat' | null;

/**
 * Where the WebGL test found black frames, the first 360° video of the session tells why and the others say nothing;
 * elsewhere, the test not run or the clip not played included, every 360° video says it plays flat, as before
 */
export function flatVideoNotice(frames: VideoFramesVerdict | null, holdsSessionNotice: () => boolean): FlatVideoNotice {
	if (frames === 'black') return holdsSessionNotice() ? 'noFrames' : null;
	return 'flat';
}
