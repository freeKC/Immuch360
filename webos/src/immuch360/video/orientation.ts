// Immuch360: a phone video filmed upright is often stored as landscape frames with a rotation flag (the display matrix
// of the MP4 or MOV file). Immich's server keeps that flag: it serves the original when the phone's H.264 needs no
// transcoding, and a hardware decoded transcode (-noautorotate) keeps the flag too. Chrome and the Flutter app turn
// the frames; the video element of a Samsung TV shows them as stored, so the picture lies on its side in an upright
// frame (issue 17). Immich reads the flag into the asset's EXIF orientation ("6" a quarter turn clockwise, "8" a
// quarter turn counter clockwise) and keeps the stored size in exifImageWidth and exifImageHeight. The viewer turns
// the video element itself when the player shows the frames as stored: the size the player reports has the shape of
// the stored frames. When the player or the server already turned them (a software transcode bakes the turn into the
// frames), the reported size has the other shape and nothing is done.

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

export interface VideoTurn {
	/** Clockwise, as CSS rotate() reads it */
	degrees: 90 | 270;
	/** What the turned picture is scaled by to fit the box as the unturned one did (object-fit: contain) */
	scale: number;
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

/** The turn the video element needs, null when the picture already shows the right way up or nothing tells */
export function videoTurn(input: VideoTurnInput): VideoTurn | null {
	const degrees = quarterTurnOf(input.orientation);
	if (degrees === null) return null;
	const {width, height, frameWidth, frameHeight, boxWidth, boxHeight} = input;
	if (!positive(width) || !positive(height) || !positive(frameWidth) || !positive(frameHeight)) return null;
	if (!positive(boxWidth) || !positive(boxHeight)) return null;
	const stored = shapeOf(width, height);
	// A square video looks the same either way; frames of the other shape were turned by the player or the server
	if (stored === 'square' || shapeOf(frameWidth, frameHeight) !== stored) return null;
	// object-fit: contain draws the frames at fit; once turned they take frameHeight x frameWidth, drawn at turned
	const fit = Math.min(boxWidth / frameWidth, boxHeight / frameHeight);
	const turned = Math.min(boxWidth / frameHeight, boxHeight / frameWidth);
	return {degrees, scale: Math.round((turned / fit) * 10000) / 10000};
}

/** The CSS transform of a turn, '' for none */
export const videoTurnTransform = (turn: VideoTurn | null): string => (turn ? `rotate(${turn.degrees}deg) scale(${turn.scale})` : '');
