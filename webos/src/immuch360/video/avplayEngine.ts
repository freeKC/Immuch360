// Immuch360: which player plays a video in the viewer (issue 17). On a Samsung TV the video element draws a video
// filmed upright on its side and ignores any turn the page gives it, so a video that needs a turn plays through
// Samsung's AVPlay player, which has a rotation setting of its own (src/platform/avplay.ts): one with the EXIF
// orientation 6 or 8, or one the user turned with "Turn the picture" (its choice is kept, turnChoice.ts). Every other
// video keeps the HTML element as before: it plays well there, the end to end test covers it, and AVPlay has its own
// network stack, which may refuse a server the browser reaches. LG webOS and browsers have no AVPlay and never get here.
//
// A video AVPlay failed (avplaySession.ts) plays in the HTML element with the CSS turn of 0.3.4 for the rest of the
// session; a failure every video would meet (the player refused to open, the server cannot be reached by it) stops
// AVPlay for the session.

import {avplayApi} from '../../platform/avplay';
import {features} from '../../platform/features';
import type {AvplayFailure} from './avplaySession';
import {quarterTurnOf, type VideoOrientationInfo, type VideoTurnChoice} from './orientation';

export type VideoEngine = 'html' | 'avplay';

const failedAssets: string[] = [];
let sessionFailure: AvplayFailure | null = null;

/** Whether AVPlay may play a video on this TV now: a Samsung TV whose AVPlay has what the viewer calls */
export const avplayUsable = (): boolean => features().avplayForTurn && sessionFailure === null && avplayApi() !== null;

/** Whether AVPlay failed this video in this session */
export const avplayFailedFor = (assetId: string): boolean => failedAssets.indexOf(assetId) >= 0;

/** Notes a failure: the video goes back to the HTML element, every video does after a session wide one */
export function noteAvplayFailure(assetId: string, failure: AvplayFailure): void {
	if (failedAssets.indexOf(assetId) < 0) failedAssets.push(assetId);
	if (failedAssets.length > 200) failedAssets.shift();
	if (failure.sessionWide) sessionFailure = failure;
}

export interface EngineInput {
	/** avplayUsable() */
	usable: boolean;
	/** A 360 video plays flat in the HTML element, as before */
	video360: boolean;
	failed: boolean;
	orientation: VideoOrientationInfo | null;
	manual: VideoTurnChoice | null;
}

/** The player of a video: AVPlay for one that needs a turn where it can, the HTML element otherwise */
export function chooseVideoEngine({usable, video360, failed, orientation, manual}: EngineInput): VideoEngine {
	if (!usable || video360 || failed) return 'html';
	return manual !== null || quarterTurnOf(orientation?.orientation) !== null ? 'avplay' : 'html';
}

/** Forgets the failures (tests) */
export function resetAvplayEngine(): void {
	failedAssets.length = 0;
	sessionFailure = null;
}
