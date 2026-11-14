// Immuch360: the turn and fit chosen with the viewer's "Turn the picture" and "Fit the picture" buttons, per video, so
// that it opens the right way up next time (issue 17). Kept on the TV only (localStorage), the latest 1000 choices, as
// the 360° choices are (forced360.ts).

import type {TurnDegrees, VideoFit, VideoTurnChoice} from './orientation';

const CHOICES_KEY = 'immuch360_video_turns';
const MAX_ENTRIES = 1000;
const DEGREES: readonly number[] = [0, 90, 180, 270];

function readAll(): Record<string, VideoTurnChoice> {
	try {
		const raw = window.localStorage.getItem(CHOICES_KEY);
		const all = raw ? (JSON.parse(raw) as unknown) : null;
		return all && typeof all === 'object' && !Array.isArray(all) ? (all as Record<string, VideoTurnChoice>) : {};
	} catch {
		return {};
	}
}

// A value written by another version, or by hand, that is not a turn counts as none
function valid(choice: unknown): VideoTurnChoice | null {
	if (!choice || typeof choice !== 'object') return null;
	const {degrees, fit} = choice as {degrees?: unknown; fit?: unknown};
	if (typeof degrees !== 'number' || DEGREES.indexOf(degrees) < 0) return null;
	if (fit !== undefined && fit !== 'file' && fit !== 'player') return null;
	return fit === undefined ? {degrees: degrees as TurnDegrees} : {degrees: degrees as TurnDegrees, fit: fit as VideoFit};
}

/** The turn chosen by hand for this video, null when none was */
export const videoTurnChoice = (assetId: string): VideoTurnChoice | null => valid(readAll()[assetId]);

/** Keeps the turn chosen by hand for this video */
export function setVideoTurnChoice(assetId: string, choice: VideoTurnChoice): void {
	const all = readAll();
	delete all[assetId];
	all[assetId] = choice.fit ? {degrees: choice.degrees, fit: choice.fit} : {degrees: choice.degrees};
	const keys = Object.keys(all);
	for (const key of keys.slice(0, Math.max(0, keys.length - MAX_ENTRIES))) delete all[key];
	try {
		window.localStorage.setItem(CHOICES_KEY, JSON.stringify(all));
	} catch {
		// a full or missing storage only loses the choice
	}
}
