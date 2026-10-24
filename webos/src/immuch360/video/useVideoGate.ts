// Immuch360: the viewer's side of limits.ts: what the session knows of the TV's video, kept up to date, whether the
// server plays the original of a video, and the decision on a video before its player starts
import {useEffect, useState, useSyncExternalStore} from 'react';
import type {PhotoRepository} from '../../domain/PhotoRepository';
import type {DecoderCeiling, DecoderRecord} from './decoders';
import {VIDEO_CHECK_MAX_MS, videoGate, type VideoGate, type VideoGateInput} from './limits';
import {knownDecoders, knownVideoFrames, subscribeVideoSession, videoSessionVersion, type VideoFramesVerdict} from './session';

/** The decoder record and the video frames verdict of this session, a new render when either comes in */
export function useVideoSession(): {decoders: DecoderRecord | null; frames: VideoFramesVerdict | null} {
	useSyncExternalStore(subscribeVideoSession, videoSessionVersion);
	return {decoders: knownDecoders(), frames: knownVideoFrames()};
}

/**
 * Whether the server plays the original of the video assetId, asked of the repository once wanted turns true (a video
 * past the decoders, one that did not start, one that stalls), and again only when the original's size comes in:
 * undefined before the answer, null when the server cannot tell
 */
export function usePlaysOriginal(repository: PhotoRepository, assetId: string | undefined, originalSize: number | null, wanted: boolean): boolean | null | undefined {
	const [answer, setAnswer] = useState<{assetId: string; originalSize: number | null; playsOriginal: boolean | null} | null>(null);

	useEffect(() => {
		if (!wanted || !assetId) return undefined;
		let live = true;
		const asked = repository.playsOriginal ? repository.playsOriginal(assetId, originalSize) : Promise.resolve(null);
		asked.then(
			(playsOriginal) => {
				if (live) setAnswer({assetId, originalSize, playsOriginal});
			},
			() => {
				if (live) setAnswer({assetId, originalSize, playsOriginal: null});
			}
		);
		return () => {
			live = false;
		};
	}, [wanted, assetId, originalSize, repository]);

	return answer && answer.assetId === assetId && answer.originalSize === originalSize ? answer.playsOriginal : undefined;
}

/**
 * The decision on the video assetId (undefined for a photo): play it, wait a moment (at most VIDEO_CHECK_MAX_MS), or
 * say the TV cannot decode it. size is the asset's (undefined while its details load); playsOriginal, usePlaysOriginal's
 * answer, which the viewer asks for when the size is past the ceiling.
 */
export function useVideoGate(
	assetId: string | undefined,
	ceiling: DecoderCeiling | null,
	size: VideoGateInput['size'],
	playsOriginal: boolean | null | undefined
): VideoGate {
	const active = !!assetId && !!ceiling;
	const [timedOutFor, setTimedOutFor] = useState<string | null>(null);

	useEffect(() => {
		if (!active || !assetId) return undefined;
		const timer = window.setTimeout(() => setTimedOutFor(assetId), VIDEO_CHECK_MAX_MS);
		return () => window.clearTimeout(timer);
	}, [active, assetId]);

	return videoGate({ceiling: active ? ceiling : null, size, playsOriginal, timedOut: timedOutFor === assetId});
}
