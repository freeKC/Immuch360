// Immuch360: the viewer's side of limits.ts: what the session knows of the TV's video, kept up to date, and the decision
// on a video before its player starts
import {useEffect, useState, useSyncExternalStore} from 'react';
import type {PhotoRepository} from '../../domain/PhotoRepository';
import {exceedsCeiling, type DecoderCeiling, type DecoderRecord} from './decoders';
import {VIDEO_CHECK_MAX_MS, videoGate, type VideoGate, type VideoGateInput} from './limits';
import {knownDecoders, knownVideoFrames, subscribeVideoSession, videoSessionVersion, type VideoFramesVerdict} from './session';

/** The decoder record and the video frames verdict of this session, a new render when either comes in */
export function useVideoSession(): {decoders: DecoderRecord | null; frames: VideoFramesVerdict | null} {
	useSyncExternalStore(subscribeVideoSession, videoSessionVersion);
	return {decoders: knownDecoders(), frames: knownVideoFrames()};
}

/**
 * The decision on the video assetId (undefined for a photo): play it, wait a moment (at most VIDEO_CHECK_MAX_MS), or
 * say the TV cannot decode it. size is the asset's (undefined while its details load); originalSize, the length of its
 * original file, against which the repository tells whether the server plays that file.
 */
export function useVideoGate(
	repository: PhotoRepository,
	assetId: string | undefined,
	ceiling: DecoderCeiling | null,
	size: VideoGateInput['size'],
	originalSize: number | null
): VideoGate {
	const active = !!assetId && !!ceiling;
	const [timedOutFor, setTimedOutFor] = useState<string | null>(null);
	const [answer, setAnswer] = useState<{assetId: string; playsOriginal: boolean | null} | null>(null);
	// Only a video past the ceiling needs the server's word on the file it plays
	const pastCeiling = active && !!size && !!size.width && !!size.height && exceedsCeiling(size.width, size.height, ceiling);

	useEffect(() => {
		if (!active || !assetId) return undefined;
		const timer = window.setTimeout(() => setTimedOutFor(assetId), VIDEO_CHECK_MAX_MS);
		return () => window.clearTimeout(timer);
	}, [active, assetId]);

	useEffect(() => {
		if (!pastCeiling || !assetId) return undefined;
		let live = true;
		const asked = repository.playsOriginal ? repository.playsOriginal(assetId, originalSize) : Promise.resolve(null);
		asked.then(
			(playsOriginal) => {
				if (live) setAnswer({assetId, playsOriginal});
			},
			() => {
				if (live) setAnswer({assetId, playsOriginal: null});
			}
		);
		return () => {
			live = false;
		};
	}, [pastCeiling, assetId, originalSize, repository]);

	return videoGate({
		ceiling: active ? ceiling : null,
		size,
		playsOriginal: answer && answer.assetId === assetId ? answer.playsOriginal : undefined,
		timedOut: timedOutFor === assetId,
	});
}
