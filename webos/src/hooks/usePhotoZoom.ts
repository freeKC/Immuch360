// Immuch360: the zoom of a flat photo in the viewer. Up and Down, the channel keys and the zoom buttons zoom by 1.25 (up
// to 4 times); once zoomed in, the arrows move the photo instead of going to the next one, and Back zooms out first.
// Each zoom key or button counts a pulse, which shows the zoom level a moment (src/components/MediaViewer/PhotoStatus.tsx).
import {useCallback, useState} from 'react';
import {ZOOM_STEP} from '../immuch360/sphere/rules';

export const MAX_PHOTO_ZOOM = 4;
// One arrow press moves the photo by a tenth of the screen
const PAN_STEP = 0.1;

export interface PhotoZoom {
	scale: number;
	x: number;
	y: number;
}

const NO_ZOOM: PhotoZoom = {scale: 1, x: 0, y: 0};

// How far the photo may move at a scale, in fractions of the screen: its edges never pass the edges of the screen
const panLimit = (scale: number) => (scale - 1) / (2 * scale);
const clampPan = (value: number, scale: number) => Math.max(-panLimit(scale), Math.min(panLimit(scale), value));

/** The zoom after one step in or out, the position kept within the new limits */
export function stepZoom(zoom: PhotoZoom, zoomIn: boolean): PhotoZoom {
	const scale = Math.max(1, Math.min(MAX_PHOTO_ZOOM, zoomIn ? zoom.scale * ZOOM_STEP : zoom.scale / ZOOM_STEP));
	if (scale < 1.001) return NO_ZOOM;
	return {scale, x: clampPan(zoom.x, scale), y: clampPan(zoom.y, scale)};
}

/** The zoom after one arrow press: Right shows more of the right of the photo, so the photo moves left */
export function panZoom(zoom: PhotoZoom, dx: number, dy: number): PhotoZoom {
	const step = PAN_STEP / zoom.scale;
	return {scale: zoom.scale, x: clampPan(zoom.x - dx * step, zoom.scale), y: clampPan(zoom.y - dy * step, zoom.scale)};
}

export const usePhotoZoom = (assetId: string | undefined) => {
	// pulse: the zoom keys and buttons pressed on this photo, out at 1x or in at 4x included (the level shows each time)
	const [state, setState] = useState<{assetId: string | undefined; zoom: PhotoZoom; pulse: number}>({assetId, zoom: NO_ZOOM, pulse: 0});
	// A new photo opens unzoomed (state adjusted during render, as the inherited hooks do)
	if (state.assetId !== assetId) setState({assetId, zoom: NO_ZOOM, pulse: 0});
	const zoom = state.assetId === assetId ? state.zoom : NO_ZOOM;
	const pulse = state.assetId === assetId ? state.pulse : 0;
	const zoomIn = useCallback(() => setState((s) => ({...s, zoom: stepZoom(s.zoom, true), pulse: s.pulse + 1})), []);
	const zoomOut = useCallback(() => setState((s) => ({...s, zoom: stepZoom(s.zoom, false), pulse: s.pulse + 1})), []);
	const reset = useCallback(() => setState((s) => ({...s, zoom: NO_ZOOM})), []);
	const pan = useCallback((dx: number, dy: number) => setState((s) => ({...s, zoom: panZoom(s.zoom, dx, dy)})), []);
	const style = zoom.scale > 1 ? {transform: `scale(${zoom.scale}) translate(${zoom.x * 100}%, ${zoom.y * 100}%)`} : undefined;
	return {zoom, zoomed: zoom.scale > 1, pulse, zoomIn, zoomOut, reset, pan, style};
};
