// Immuch360: which picture of a flat photo the viewer shows. The preview (1440 px on its short side by default) is
// sharp at the size of the screen; zoomed in past 2x it gets soft, so the full-size picture is asked for, unless the
// photo has so many pixels that a TV could run out of memory decoding it (4 bytes a pixel once decoded: a 48 MP phone
// photo would take about 195 MB, and a TV closes an app that asks too much without a word).

/** The zoom from which the full-size picture is asked for */
export const FULLSIZE_FROM_SCALE = 2;

/** The most pixels a TV with webOS 6 or later (Chromium 79 and later) is asked to decode: a 24 MP camera fits */
export const FULLSIZE_MAX_PIXELS = 25000000;

/** The most pixels an older TV (webOS 4 and 5, Chromium 53 and 68) is asked to decode: a 16 MP camera fits */
export const FULLSIZE_MAX_PIXELS_BEFORE_WEBOS_6 = 16777216;

const WEBOS_6_CHROMIUM = 79;

/** The major version of Chromium in a user agent, null when it names none */
export function chromiumMajor(userAgent: string | null | undefined): number | null {
	const match = /Chrome\/(\d+)/.exec(userAgent ?? '');
	return match ? Number(match[1]) : null;
}

/** The most pixels the TV running this engine is asked to decode; the lower cap when the engine is not known */
export function fullsizePixelCap(chromium: number | null): number {
	return chromium !== null && chromium >= WEBOS_6_CHROMIUM ? FULLSIZE_MAX_PIXELS : FULLSIZE_MAX_PIXELS_BEFORE_WEBOS_6;
}

const thisTvCap = (): number => fullsizePixelCap(chromiumMajor(typeof navigator === 'undefined' ? null : navigator.userAgent));

/** Whether a photo zoomed to scale, of that size (null while its details load), shows its full-size picture */
export function wantsFullsize(scale: number, width: number | null | undefined, height: number | null | undefined, maxPixels: number = thisTvCap()): boolean {
	if (scale <= FULLSIZE_FROM_SCALE || !width || !height) return false;
	return width * height <= maxPixels;
}
