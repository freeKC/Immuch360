import React, {useCallback, useEffect, useRef} from 'react';
import {VideoPlayer as SandstoneVideoPlayer} from '@enact/sandstone/VideoPlayer';
import {features} from '../../platform/features';
import {holdScreenSaver} from '../../utils/screenSaver';
import css from './MediaViewer.module.less';

// Subset of the imperative API exposed by Sandstone's ApiDecorator (available on a ref
// to the decorated component).
export interface VideoPlayerApi {
	areControlsVisible: () => boolean;
	showControls: () => void;
	hideControls: () => void;
	// Immuch360: the remote's 10 s steps and play and pause keys
	jump: (seconds: number) => void;
	play: () => void;
	pause: () => void;
	getMediaState: () => {paused?: boolean; currentTime?: number; duration?: number};
	// Immuch360: the media node, whose error tells a video the TV cannot play
	getVideoNode: () => {error?: unknown} | null;
}

interface VideoPlayerProps {
	src: string;
	// Fired by Sandstone when its media controls show/hide. Documented as ({available}),
	// but forwardCustom drops the payload — read `areControlsVisible()` instead.
	onControlsAvailable?: (ev: {available?: boolean}) => void;
	// Not Sandstone's `playerRef` prop (that one exposes the DOM node, not the API).
	apiRef?: React.Ref<VideoPlayerApi>;
}

// Sandstone exposes VideoPlayer with a Slottable-only typing — `autoCloseTimeout`,
// `jumpBy`, `noAutoPlay`, `spotlightDisabled` and friends live on VideoPlayerBaseProps
// and are forwarded at runtime through Sandstone's HOC chain. Spread with an `as any`
// cast is the established pattern in this project (see SearchPanel onComplete).
//
// HIDDEN_BACK_LABEL acts as a stable CSS hook: Sandstone renders its own back button
// at top-left when controls are visible (duplicate of our MediaControls close X).
// We set a sentinel aria-label and hide via [aria-label="..."] in the LESS module —
// targeting the CSS-Modules hash directly would break on every Sandstone rebuild.
const HIDDEN_BACK_LABEL = 'immich-tv-internal-back-hidden';

const PLAYER_PROPS = {
	autoCloseTimeout: 5000,
	jumpBy: 10,
	noAutoPlay: false,
	// Keep the transport bar closed on arrival: while hidden, left/right page between media
	// (intercepted by MediaViewer); OK/down opens it and left/right become seek again.
	noAutoShowMediaControls: true,
	spotlightDisabled: false,
	backButtonAriaLabel: HIDDEN_BACK_LABEL,
};

// Immuch360: marks the video element of the viewer (Sandstone hands the props it does not use to the <video>), so that
// the media events of this player are told from those of other videos (the test clip of the About page)
export const VIDEO_MARK = 'data-immuch360-video';
const fromThisPlayer = (target: EventTarget | null): boolean => target instanceof HTMLVideoElement && target.hasAttribute(VIDEO_MARK);
// The events after which a video no longer plays; 'waiting' (buffering) keeps the screen saver off
const STOPPED_EVENTS = ['pause', 'ended', 'emptied', 'error'];

// Hands the player's API to the ref of the viewer, a function or an object
function passApi(ref: React.Ref<VideoPlayerApi> | undefined, api: VideoPlayerApi | null): void {
	if (typeof ref === 'function') ref(api);
	else if (ref) (ref as React.MutableRefObject<VideoPlayerApi | null>).current = api;
}

export const VideoPlayer: React.FC<VideoPlayerProps> = ({src, onControlsAvailable, apiRef}) => {
	// Immuch360: the player's API for this component too (the pause below), and for the viewer through apiRef
	const ownApi = useRef<VideoPlayerApi | null>(null);
	const setApi = useCallback(
		(api: VideoPlayerApi | null) => {
			ownApi.current = api;
			passApi(apiRef, api);
		},
		[apiRef]
	);

	// Immuch360: the video pauses when the app is hidden. Samsung: "your application must handle multitasking"; webOS
	// suspends a hidden app anyway.
	useEffect(() => {
		const onVisibilityChange = () => {
			if (document.hidden) ownApi.current?.pause();
		};
		document.addEventListener('visibilitychange', onVisibilityChange);
		return () => document.removeEventListener('visibilitychange', onVisibilityChange);
	}, []);

	// Immuch360: on a Samsung TV the screen saver stays off while the video plays (Samsung's "Setting Screensaver"
	// guide); webOS keeps a playing video awake by itself. Media events do not bubble: they are caught on their way down.
	useEffect(() => {
		if (!features().holdScreenSaverForVideo) return undefined;
		let release: (() => void) | null = null;
		const onPlaying = (event: Event) => {
			if (fromThisPlayer(event.target) && !release) release = holdScreenSaver();
		};
		const onStopped = (event: Event) => {
			if (!fromThisPlayer(event.target) || !release) return;
			release();
			release = null;
		};
		document.addEventListener('playing', onPlaying, true);
		STOPPED_EVENTS.forEach((type) => document.addEventListener(type, onStopped, true));
		return () => {
			document.removeEventListener('playing', onPlaying, true);
			STOPPED_EVENTS.forEach((type) => document.removeEventListener(type, onStopped, true));
			if (release) release();
		};
	}, []);

	const playerProps = {...PLAYER_PROPS, onControlsAvailable, ref: setApi, [VIDEO_MARK]: ''};
	return (
		<SandstoneVideoPlayer {...(playerProps as any)} className={css.viewerMedia}>
			<source src={src} type="video/mp4" />
		</SandstoneVideoPlayer>
	);
};

VideoPlayer.displayName = 'VideoPlayer';
