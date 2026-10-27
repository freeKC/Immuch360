// Immuch360: the loading pill of the flat photo of the viewer (src/immuch360/viewerStatus.ts): the state of its picture,
// the 300 ms before the pill shows, and the load and error handlers of its <img>.
import {useCallback, useEffect, useState} from 'react';
import type {SyntheticEvent} from 'react';
import {LOADING_SHOWN_AFTER_MS, photoLoadStart, photoLoadStep, showsLoading, type PhotoLoadState} from '../immuch360/viewerStatus';

// The load event says the bytes are in; the engine may decode them only when it paints. decode() (Chromium 64, webOS 5
// and later) resolves once the picture can be painted, then one frame puts it on screen; without it (webOS 4, Chromium
// 53) two frames after the load. A decode that rejects (another picture was asked for meanwhile) counts as painted: the
// reducer ignores it when the address changed.
function whenPainted(img: HTMLImageElement, painted: () => void): void {
	const frame = () => {
		window.requestAnimationFrame(painted);
	};
	if (typeof img.decode === 'function') {
		img.decode().then(frame, frame);
		return;
	}
	window.requestAnimationFrame(frame);
}

export interface PhotoLoading {
	/** The pill shows: the picture is not painted LOADING_SHOWN_AFTER_MS after it was asked for */
	loading: boolean;
	/** The engine could not load or decode the picture */
	failed: boolean;
	onLoad: (event: SyntheticEvent<HTMLImageElement>) => void;
	onError: () => void;
}

/** The wait of the picture at src; null when the viewer shows no flat photo */
export const usePhotoLoading = (src: string | null): PhotoLoading => {
	const [state, setState] = useState<PhotoLoadState>(() => photoLoadStart(src));
	// Another picture: its own wait (state adjusted during render, as the inherited hooks do)
	if (state.src !== src) setState(photoLoadStart(src));
	const current = state.src === src ? state : photoLoadStart(src);

	useEffect(() => {
		if (src === null) return undefined;
		const timer = window.setTimeout(() => setState((s) => photoLoadStep(s, {type: 'delay', src})), LOADING_SHOWN_AFTER_MS);
		return () => window.clearTimeout(timer);
	}, [src]);

	const onLoad = useCallback(
		(event: SyntheticEvent<HTMLImageElement>) => {
			if (src === null) return;
			whenPainted(event.currentTarget, () => setState((s) => photoLoadStep(s, {type: 'painted', src})));
		},
		[src]
	);
	const onError = useCallback(() => {
		if (src !== null) setState((s) => photoLoadStep(s, {type: 'error', src}));
	}, [src]);

	return {loading: showsLoading(current), failed: current.phase === 'failed', onLoad, onError};
};
