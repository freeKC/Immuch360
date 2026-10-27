// Immuch360: what the viewer of a flat photo says over it while it waits, and the zoom level it shows a moment.
//
// A photo is fetched, then decoded, then painted; on a low end TV and a busy server that takes a while, and a dark
// photo (a lens cap left on) looked like a screen that stayed blank (discussion 8). So a "Loading…" pill shows over the
// screen when the picture is not painted 300 ms after it was asked for, and goes at its first paint: a photo that comes
// at once shows no pill at all. The same for the full-size picture that replaces the preview past 2x (photoSize.ts):
// the preview stays on screen under the pill until the full-size picture is painted.

/** A picture not painted this long after it was asked for shows the loading pill */
export const LOADING_SHOWN_AFTER_MS = 300;

/** How long the zoom level stays on screen after a zoom key or button */
export const ZOOM_LEVEL_SHOWN_MS = 1500;

/**
 * Where the picture of a photo stands: loading (not painted yet, the pill not due), slow (not painted after
 * LOADING_SHOWN_AFTER_MS, the pill shows), shown (painted), failed (the engine could not load or decode it)
 */
export type PhotoLoadPhase = 'loading' | 'slow' | 'shown' | 'failed';

export interface PhotoLoadState {
	/** The address asked for; null when the viewer shows no flat photo (a video, a 360° photo) */
	src: string | null;
	phase: PhotoLoadPhase;
}

/**
 * What happens to it: another address is asked for (src), the delay of the pill ran out (delay), the picture was
 * painted (painted), or it failed (error). The last three name their address: one for another address is ignored, as
 * the engine may finish an earlier picture after the next one was asked for.
 */
export type PhotoLoadEvent = {type: 'src'; src: string | null} | {type: 'delay' | 'painted' | 'error'; src: string};

/** The state of the picture of a photo after an event */
export function photoLoadStep(state: PhotoLoadState, event: PhotoLoadEvent): PhotoLoadState {
	if (event.type === 'src') {
		if (event.src === state.src) return state;
		return {src: event.src, phase: event.src === null ? 'shown' : 'loading'};
	}
	if (event.src !== state.src) return state;
	if (event.type === 'delay') return state.phase === 'loading' ? {...state, phase: 'slow'} : state;
	if (event.type === 'painted') return state.phase === 'loading' || state.phase === 'slow' ? {...state, phase: 'shown'} : state;
	return state.phase === 'failed' ? state : {...state, phase: 'failed'};
}

/** The state of a picture just asked for */
export const photoLoadStart = (src: string | null): PhotoLoadState => ({src, phase: src === null ? 'shown' : 'loading'});

/** Whether the loading pill shows */
export const showsLoading = (state: PhotoLoadState): boolean => state.phase === 'slow';

/**
 * The zoom level as the viewer shows it, a percentage written for the locale ("125%", in French "125 %"); plain
 * digits and a percent sign where the engine cannot write it
 */
export function zoomLevelText(scale: number, localeTag: string): string {
	const percent = Math.round(scale * 100);
	try {
		return (percent / 100).toLocaleString(localeTag, {style: 'percent', maximumFractionDigits: 0});
	} catch {
		return `${percent}%`;
	}
}
