// Immuch360: Samsung's AVPlay player (webapis.avplay), which the viewer uses on a Samsung TV for a video that needs a
// turn: the TV's video element draws its frames on their side whatever the page does with it (issue 17), and AVPlay
// has a rotation setting of its own (setDisplayRotation, since Tizen 4.0, the app needs 5.5). The player comes from
// the TV's own webapis.js, which the Samsung package loads before main.js (tizen/tools/build-wgt.mjs); nothing of
// Samsung's is in this repository. Off a Samsung TV, or on one without AVPlay, avplayApi() is null and nothing here
// touches webapis.
//
// Samsung's AVPlay API reference and "Using AVPlay" guide, read 16 November 2026: no privilege is needed for plain
// playback since the 2015 models; the display rect is given on a 1920 x 1080 screen whatever the page's size; a
// <video> element and AVPlay must not play at the same time.

import {platform} from './detect';
import type {TizenGlobals, WebapisAvplay} from './tizen-api';

/** The members the viewer calls; the others (setDisplayRotation, getCurrentStreamInfo) are checked where used */
const REQUIRED = [
	'open',
	'close',
	'setListener',
	'setDisplayRect',
	'setDisplayMethod',
	'prepareAsync',
	'play',
	'pause',
	'stop',
	'seekTo',
	'getState',
	'getDuration',
	'getCurrentTime',
] as const;

type RequiredMember = (typeof REQUIRED)[number];

/** The player with the members the viewer needs */
export type AvplayApi = WebapisAvplay & {[K in RequiredMember]-?: NonNullable<WebapisAvplay[K]>};

/** Samsung's player on a Samsung TV that has it with every member the viewer calls, else null */
export function avplayApi(): AvplayApi | null {
	if (typeof window === 'undefined' || platform() !== 'tizen') return null;
	try {
		const avplay = (window as unknown as TizenGlobals).webapis?.avplay;
		if (!avplay) return null;
		return REQUIRED.every((name) => typeof avplay[name] === 'function') ? (avplay as AvplayApi) : null;
	} catch {
		return null;
	}
}

/** The four values of setDisplayRotation, by the clockwise turn the viewer asks for (see avplaySession.ts) */
export const AVPLAY_ROTATION: Record<0 | 90 | 180 | 270, string> = {
	0: 'PLAYER_DISPLAY_ROTATION_NONE',
	90: 'PLAYER_DISPLAY_ROTATION_90',
	180: 'PLAYER_DISPLAY_ROTATION_180',
	270: 'PLAYER_DISPLAY_ROTATION_270',
};

/** The display methods the viewer uses: the picture kept whole in the rect, or stretched to the rect */
export const AVPLAY_LETTER_BOX = 'PLAYER_DISPLAY_MODE_LETTER_BOX';
export const AVPLAY_FULL_SCREEN = 'PLAYER_DISPLAY_MODE_FULL_SCREEN';

/** The width of the screen AVPlay's display rect is given on (Samsung: always 1920 x 1080) */
export const AVPLAY_SCREEN_WIDTH = 1920;
export const AVPLAY_SCREEN_HEIGHT = 1080;

/**
 * The name of what a call threw or an error callback gave, for the diagnostics line: a WebAPIException's name
 * (NotSupportedError, InvalidStateError), or an AVPlayError such as PLAYER_ERROR_CONNECTION_FAILED. Never its message,
 * which may hold the URL and its key.
 */
export function avplayErrorName(error: unknown): string {
	if (typeof error === 'string') return /^[A-Za-z][A-Za-z0-9_]{2,63}$/.test(error) ? error : 'error';
	if (error && typeof error === 'object') {
		const {name, type, code} = error as {name?: unknown; type?: unknown; code?: unknown};
		for (const value of [name, type]) {
			if (typeof value === 'string' && /^[A-Za-z][A-Za-z0-9_]{1,63}$/.test(value) && value !== 'Error' && value !== 'Object') return value;
		}
		if (typeof code === 'number') return `code ${code}`;
		if (typeof name === 'string' && /^[A-Za-z]+$/.test(name)) return name;
	}
	return 'error';
}
