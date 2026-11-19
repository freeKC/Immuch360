// Immuch360: what Samsung's AVPlay player is told for a video that needs a turn (issue 17, src/platform/avplay.ts). The
// turn and the place of the picture, as plain functions; avplaySession.ts makes the calls.
//
// What Samsung documents (AVPlay API reference, read 16 November 2026): setDisplayRotation takes NONE, 90, 180 or 270
// and "will change the origin of coordinates", so setDisplayRect is called again after it; the display rect is given on
// a 1920 x 1080 screen; setDisplayMethod keeps the picture whole in the rect (LETTER_BOX) or stretches it to the rect
// (FULL_SCREEN). What it does not say, and nobody here can measure without a Samsung TV:
// - which way PLAYER_DISPLAY_ROTATION_90 turns. The viewer reads it as clockwise, as CSS and the EXIF orientation do
//   (orientation 6 asks for 90 clockwise). Were it the other way on a TV, "Turn the picture" pressed twice gives the
//   right way up, and the choice is kept for the video (turnChoice.ts);
// - whether the letterbox follows the turned picture or the stored frames. "Fit the picture" switches between the
//   letterbox on the whole player (fit 'player', the default: the player shapes the picture) and a rect with the
//   proportions of the turned file, the picture stretched to it (fit 'file');
// - in which space the rect is read once turned. The whole player (the default) is the same either way.
// - whether AVPlay applies the file's rotation flag itself. Samsung's multimedia FAQ says it plays the content "as
//   delivered"; were it to turn it, the picture would come out turned twice, and the button sets it right.

import {AVPLAY_FULL_SCREEN, AVPLAY_LETTER_BOX, AVPLAY_SCREEN_HEIGHT, AVPLAY_SCREEN_WIDTH} from '../../platform/avplay';
import type {WebapisAvplayStreamInfo} from '../../platform/tizen-api';
import {quarterTurnOf, type TurnDegrees, type VideoFit, type VideoOrientationInfo, type VideoTurnChoice} from './orientation';

/** The size of the video stream AVPlay decodes (getCurrentStreamInfo), and its codec when it says */
export interface AvplayStream {
	width: number;
	height: number;
	codec: string | null;
}

/** What the viewer asks AVPlay for: its own turn, the one chosen by hand, or none */
export interface AvplayTurn {
	source: 'auto' | 'manual' | 'none';
	degrees: TurnDegrees;
	fit: VideoFit;
}

/** The fit of a turn nobody chose one for: the letterbox on the whole player */
export const AVPLAY_DEFAULT_FIT: VideoFit = 'player';

const positive = (value: number | null | undefined): value is number => typeof value === 'number' && Number.isFinite(value) && value > 0;
const toNumber = (value: unknown): number | null => {
	const number = typeof value === 'number' ? value : typeof value === 'string' ? Number.parseFloat(value) : NaN;
	return Number.isFinite(number) ? number : null;
};
const shapeOf = (width: number, height: number): 'landscape' | 'portrait' | 'square' => (width > height ? 'landscape' : width < height ? 'portrait' : 'square');

/** The video stream of getCurrentStreamInfo(), null when it gives none or no size */
export function videoStreamOf(streams: WebapisAvplayStreamInfo[] | null | undefined): AvplayStream | null {
	if (!Array.isArray(streams)) return null;
	for (const stream of streams) {
		if (!stream || String(stream.type).toUpperCase() !== 'VIDEO' || typeof stream.extra_info !== 'string') continue;
		try {
			const extra = JSON.parse(stream.extra_info) as Record<string, unknown>;
			const width = toNumber(extra.Width);
			const height = toNumber(extra.Height);
			if (!positive(width) || !positive(height)) continue;
			const codec = typeof extra.fourCC === 'string' && /^[A-Za-z0-9_.-]{1,16}$/.test(extra.fourCC) ? extra.fourCC : null;
			return {width, height, codec};
		} catch {
			// a stream whose details are not JSON is skipped
		}
	}
	return null;
}

/**
 * The turn AVPlay is asked for. A turn chosen by hand stands. Else the quarter turn of the EXIF orientation (6: 90, 8:
 * 270), unless the stream has the other shape than the stored frames: a transcode that Immich's software transcoding
 * already turned. AVPlay reports the stream it decodes, not a turned size as the video element does, so its shape is
 * trusted; an unknown stream counts as the original.
 */
export function resolveAvplayTurn(info: VideoOrientationInfo | null, stream: AvplayStream | null, manual: VideoTurnChoice | null): AvplayTurn {
	if (manual) return {source: 'manual', degrees: manual.degrees, fit: manual.fit ?? AVPLAY_DEFAULT_FIT};
	const degrees = quarterTurnOf(info?.orientation);
	if (degrees === null) return {source: 'none', degrees: 0, fit: AVPLAY_DEFAULT_FIT};
	const {width, height} = info ?? {width: null, height: null};
	if (stream && positive(width) && positive(height)) {
		const stored = shapeOf(width, height);
		if (stored === 'square' || shapeOf(stream.width, stream.height) !== stored) return {source: 'none', degrees: 0, fit: AVPLAY_DEFAULT_FIT};
	}
	return {source: 'auto', degrees, fit: AVPLAY_DEFAULT_FIT};
}

/** A rect on AVPlay's 1920 x 1080 screen, in whole pixels (setDisplayRect takes unsigned longs) */
export interface AvplayRect {
	x: number;
	y: number;
	width: number;
	height: number;
}

/** The display method and rect of a turn */
export interface AvplayDisplay {
	method: string;
	rect: AvplayRect;
}

/** Where the player is on the page, in CSS pixels (getBoundingClientRect) */
export interface PageArea {
	left: number;
	top: number;
	width: number;
	height: number;
}

const FULL: AvplayRect = {x: 0, y: 0, width: AVPLAY_SCREEN_WIDTH, height: AVPLAY_SCREEN_HEIGHT};

/** The player's area on AVPlay's screen: the page's pixels scaled to its 1920 wide screen; the whole screen when unknown */
export function playerRect(area: PageArea | null, viewportWidth: number): AvplayRect {
	if (!area || !positive(area.width) || !positive(area.height) || !positive(viewportWidth)) return {...FULL};
	const scale = AVPLAY_SCREEN_WIDTH / viewportWidth;
	const x = Math.max(0, Math.round(area.left * scale));
	const y = Math.max(0, Math.round(area.top * scale));
	const width = Math.min(AVPLAY_SCREEN_WIDTH - x, Math.round(area.width * scale));
	const height = Math.min(AVPLAY_SCREEN_HEIGHT - y, Math.round(area.height * scale));
	return width > 0 && height > 0 ? {x, y, width, height} : {...FULL};
}

/**
 * The method and rect for a turn. Fit 'player': the letterbox on the whole player. Fit 'file': the picture stretched to
 * the largest rect of the proportions of the file turned (the stored size, else the stream's) in the player, centred.
 */
export function avplayDisplay(player: AvplayRect, turn: AvplayTurn, picture: {width: number; height: number} | null): AvplayDisplay {
	if (turn.fit !== 'file' || !picture || !positive(picture.width) || !positive(picture.height)) return {method: AVPLAY_LETTER_BOX, rect: {...player}};
	const quarter = turn.degrees % 180 !== 0;
	const pictureWidth = quarter ? picture.height : picture.width;
	const pictureHeight = quarter ? picture.width : picture.height;
	const scale = Math.min(player.width / pictureWidth, player.height / pictureHeight);
	const width = Math.max(1, Math.round(pictureWidth * scale));
	const height = Math.max(1, Math.round(pictureHeight * scale));
	return {
		method: AVPLAY_FULL_SCREEN,
		rect: {x: player.x + Math.round((player.width - width) / 2), y: player.y + Math.round((player.height - height) / 2), width, height},
	};
}
