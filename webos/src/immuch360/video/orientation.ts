// Immuch360: a phone video filmed upright is often stored as landscape frames with a rotation flag (the display matrix
// of the MP4 or MOV file). Immich's server keeps that flag: it serves the original when the phone's H.264 needs no
// transcoding, and a hardware decoded transcode (-noautorotate) keeps the flag too. Chrome and the Flutter app turn
// the frames; the video element of a Samsung TV shows them as stored, so the picture lies on its side in an upright
// frame (issue 17). Immich reads the flag into the asset's EXIF orientation ("6" a quarter turn clockwise, "8" a
// quarter turn counter clockwise) and keeps the stored size in exifImageWidth and exifImageHeight.
//
// What the size the player reports (videoWidth, videoHeight) tells:
// - the shape of the stored frames: nobody turned them, the element is turned (every TV);
// - the other shape: on webOS and in browsers the player turned them, nothing is done. A Samsung TV reports the turned
//   size too while it still draws the frames as stored (issue 17: "player 2160 x 3840" for a 3840 x 2160 file, the
//   picture on its side). Its engine lays the element out for the upright size, and its video plane draws the stored
//   landscape frames stretched into that upright area. There the element is turned when the stream has the stored
//   resolution (the original); a smaller stream is a transcode, which Immich's default software transcoding already
//   turned (portrait frames, no flag), and is left alone.
// Neither can be checked on a real TV here: the viewer's "Turn the picture" and "Fit the picture" buttons choose by hand,
// and their choice is kept for the video (turnChoice.ts).

/** What the viewer knows of a video before it plays: its EXIF orientation and its stored size (asset details) */
export interface VideoOrientationInfo {
	orientation: string | number | null | undefined;
	width: number | null | undefined;
	height: number | null | undefined;
}

/** The size of the frames the player reports (videoWidth, videoHeight) and of the box it draws them in */
export interface VideoTurnInput extends VideoOrientationInfo {
	frameWidth: number;
	frameHeight: number;
	boxWidth: number;
	boxHeight: number;
}

/** A clockwise turn, as CSS rotate() reads it */
export type TurnDegrees = 0 | 90 | 180 | 270;

/**
 * Which proportions the picture is given once turned. 'file': those of the stored frames, for a player that stretches
 * them into the area laid out for the size it reports (a Samsung TV). 'player': those of the size it reports, for a
 * player that draws what it reports (a browser). The same when both sizes have the same proportions.
 */
export type VideoFit = 'file' | 'player';

export interface VideoTurn {
	degrees: TurnDegrees;
	/** What the element is scaled by before it is turned, so that the turned picture fits the box (object-fit: contain) */
	scaleX: number;
	scaleY: number;
}

/**
 * The clockwise quarter turn an EXIF orientation asks for, null for none. Immich gives videos 1, 3, 6 or 8 only. A
 * half turn (3) is left alone: the reported size cannot tell whether the player or the server already turned it.
 */
export function quarterTurnOf(orientation: VideoOrientationInfo['orientation']): 90 | 270 | null {
	const value = typeof orientation === 'string' ? Number.parseInt(orientation, 10) : orientation;
	if (value === 6) return 90;
	if (value === 8) return 270;
	return null;
}

const shapeOf = (width: number, height: number): 'landscape' | 'portrait' | 'square' =>
	width > height ? 'landscape' : width < height ? 'portrait' : 'square';

const positive = (value: number | null | undefined): value is number => typeof value === 'number' && Number.isFinite(value) && value > 0;

const round = (value: number): number => Math.round(value * 10000) / 10000;

// The size of w x h drawn at the largest scale that fits the box (object-fit: contain)
function contain(width: number, height: number, boxWidth: number, boxHeight: number): [number, number] {
	const scale = Math.min(boxWidth / width, boxHeight / height);
	return [width * scale, height * scale];
}

/** Whether the size the player reports tells the turn: false on a Samsung TV, which reports it turned or not */
export interface TurnRule {
	reportedSizeTellsTurn: boolean;
}

/**
 * The quarter turn the flag asks for that the player left undone, null when it did it, when nothing tells or for no
 * flag. rule.reportedSizeTellsTurn: see the head of this file.
 */
export function autoTurnDegrees(input: VideoTurnInput, rule: TurnRule): 90 | 270 | null {
	const degrees = quarterTurnOf(input.orientation);
	if (degrees === null) return null;
	const {width, height, frameWidth, frameHeight, boxWidth, boxHeight} = input;
	if (!positive(width) || !positive(height) || !positive(frameWidth) || !positive(frameHeight)) return null;
	if (!positive(boxWidth) || !positive(boxHeight)) return null;
	const stored = shapeOf(width, height);
	// A square video looks the same either way
	if (stored === 'square') return null;
	if (shapeOf(frameWidth, frameHeight) === stored) return degrees;
	if (rule.reportedSizeTellsTurn) return null;
	// The other shape on a Samsung TV: the original (the stored resolution) is drawn as stored; a smaller stream is a
	// transcode, turned by Immich's software transcoding (a hardware one keeps the flag: the button is there for it)
	const storedLong = Math.max(width, height);
	return Math.abs(Math.max(frameWidth, frameHeight) - storedLong) <= storedLong * 0.02 ? degrees : null;
}

/** The fit a turn gets when nobody chose one: a Samsung TV stretches the stored frames, a browser draws what it reports */
export const defaultFit = (degrees: TurnDegrees, rule: TurnRule): VideoFit => (!rule.reportedSizeTellsTurn && degrees % 180 !== 0 ? 'file' : 'player');

/** Whether the fit changes anything: the reported size and the stored size (or its turn) have other proportions */
export function fitMatters(input: VideoTurnInput): boolean {
	const {width, height, frameWidth, frameHeight} = input;
	if (!positive(width) || !positive(height) || !positive(frameWidth) || !positive(frameHeight)) return false;
	return Math.abs(frameWidth / frameHeight / (width / height) - 1) > 0.01;
}

/**
 * The scale of a turn by degrees with the given fit, null while the player does not know its frames. The element's
 * picture is drawn in the area the reported size takes in the box (contain); the scale maps that area onto the area
 * the turned picture takes in the box, with the proportions of the fit. For a 'player' fit the scale is uniform.
 */
export function turnGeometry(input: VideoTurnInput, degrees: TurnDegrees, fit: VideoFit): VideoTurn | null {
	const {width, height, frameWidth, frameHeight, boxWidth, boxHeight} = input;
	if (!positive(frameWidth) || !positive(frameHeight) || !positive(boxWidth) || !positive(boxHeight)) return null;
	const [drawnWidth, drawnHeight] = contain(frameWidth, frameHeight, boxWidth, boxHeight);
	const fromFile = fit === 'file' && positive(width) && positive(height);
	const pictureWidth = fromFile ? width : frameWidth;
	const pictureHeight = fromFile ? height : frameHeight;
	const quarter = degrees % 180 !== 0;
	const [shownWidth, shownHeight] = quarter ? contain(pictureHeight, pictureWidth, boxWidth, boxHeight) : contain(pictureWidth, pictureHeight, boxWidth, boxHeight);
	// The scale applies before the turn: once turned by a quarter, the element's width stands on screen as its height
	return quarter
		? {degrees, scaleX: round(shownHeight / drawnWidth), scaleY: round(shownWidth / drawnHeight)}
		: {degrees, scaleX: round(shownWidth / drawnWidth), scaleY: round(shownHeight / drawnHeight)};
}

/** The turn the viewer gives a video by itself, null for none (see autoTurnDegrees) */
export function videoTurn(input: VideoTurnInput, rule: TurnRule): VideoTurn | null {
	const degrees = autoTurnDegrees(input, rule);
	return degrees === null ? null : turnGeometry(input, degrees, defaultFit(degrees, rule));
}

/** The turn chosen with the viewer's buttons, kept for the video (turnChoice.ts); fit absent: the default one */
export interface VideoTurnChoice {
	degrees: TurnDegrees;
	fit?: VideoFit;
}

/** What the viewer does with a video: its own turn, the one chosen by hand (which replaces it), or none */
export interface ResolvedVideoTurn {
	source: 'auto' | 'manual' | 'none';
	degrees: TurnDegrees;
	fit: VideoFit;
	/** The scale and turn, null while the player does not know its frames or when the picture is left as it is */
	turn: VideoTurn | null;
}

export function resolveVideoTurn(input: VideoTurnInput, manual: VideoTurnChoice | null, rule: TurnRule): ResolvedVideoTurn {
	if (manual) {
		const fit = manual.fit ?? defaultFit(manual.degrees, rule);
		return {source: 'manual', degrees: manual.degrees, fit, turn: turnGeometry(input, manual.degrees, fit)};
	}
	const degrees = autoTurnDegrees(input, rule);
	if (degrees === null) return {source: 'none', degrees: 0, fit: defaultFit(0, rule), turn: null};
	const fit = defaultFit(degrees, rule);
	return {source: 'auto', degrees, fit, turn: turnGeometry(input, degrees, fit)};
}

/** The next turn of the "Turn the picture" button (step 1, the yellow key) or of the blue key (step -1) */
export const nextTurn = (degrees: TurnDegrees, step: 1 | -1 = 1): TurnDegrees => ((((degrees + step * 90) % 360) + 360) % 360) as TurnDegrees;

/** The CSS transform of a turn, '' for none */
export function videoTurnTransform(turn: VideoTurn | null): string {
	if (!turn) return '';
	const parts: string[] = [];
	if (turn.degrees) parts.push(`rotate(${turn.degrees}deg)`);
	if (turn.scaleX !== turn.scaleY) parts.push(`scale(${turn.scaleX}, ${turn.scaleY})`);
	else if (turn.scaleX !== 1) parts.push(`scale(${turn.scaleX})`);
	return parts.join(' ');
}

// What the viewer saw of the last video with a quarter turn flag or a turn chosen by hand, for the diagnostics page: on
// a TV nobody here can test, it tells which size the player reported, what was done and where the element ended up
let lastSeen: string | null = null;

/** What the viewer did, for the diagnostics line */
export interface VideoTurnNote {
	platform: string;
	resolved: ResolvedVideoTurn;
	/** Whether the transform was set on the element (webOS leaves its own turn to its player) */
	applied: boolean;
	/** The element's size on screen once transformed (getBoundingClientRect), null when unknown */
	onScreen: {width: number; height: number} | null;
}

/** Notes a video with a quarter turn flag or a turn chosen by hand, once the player reported its frames */
export function noteVideoTurn(input: VideoTurnInput, note: VideoTurnNote): void {
	const {resolved} = note;
	if ((quarterTurnOf(input.orientation) === null && resolved.source !== 'manual') || !positive(input.frameWidth) || !positive(input.frameHeight)) return;
	const transform = videoTurnTransform(resolved.turn) || 'none';
	let done: string;
	if (resolved.source === 'none') done = 'not turned';
	else if (resolved.source === 'manual') done = `by hand ${resolved.degrees}, fit ${resolved.fit}, ${transform}`;
	else done = note.applied ? `auto ${transform}` : `auto ${transform} left to the player`;
	const screen = note.onScreen && (note.onScreen.width > 0 || note.onScreen.height > 0) ? `, on screen ${Math.round(note.onScreen.width)} x ${Math.round(note.onScreen.height)}` : '';
	lastSeen =
		`${note.platform}, orientation ${String(input.orientation ?? '?')}, stored ${input.width ?? '?'} x ${input.height ?? '?'}, ` +
		`player ${input.frameWidth} x ${input.frameHeight}, element ${input.boxWidth} x ${input.boxHeight}, ${done}${screen}`;
}

/** The diagnostics line of the last video with a quarter turn flag or a turn by hand, 'none' before one played */
export const lastVideoTurnLine = (): string => lastSeen ?? 'none';
