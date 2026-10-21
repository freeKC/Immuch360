// Immuch360: which picture of a flat photo the viewer shows. The preview (1440 px on its short side by default) is
// sharp at the size of the screen; zoomed in past 2x it gets soft, so the full-size picture is asked for, unless the
// photo is so large that a TV could run out of memory decoding it.

/** The zoom from which the full-size picture is asked for */
export const FULLSIZE_FROM_SCALE = 2;

/** The longest side a TV is asked to decode, in pixels */
export const FULLSIZE_MAX_SIDE = 8192;

/** Whether a photo zoomed to scale, of that size (null while its details load), shows its full-size picture */
export function wantsFullsize(scale: number, width: number | null | undefined, height: number | null | undefined): boolean {
	if (scale <= FULLSIZE_FROM_SCALE || !width || !height) return false;
	return Math.max(width, height) <= FULLSIZE_MAX_SIDE;
}
