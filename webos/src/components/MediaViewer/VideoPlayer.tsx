import React, {useCallback, useEffect, useRef} from 'react';
import {VideoPlayer as SandstoneVideoPlayer} from '@enact/sandstone/VideoPlayer';
import {features} from '../../platform/features';
import {platform} from '../../platform/detect';
import {
	fitMatters,
	noteVideoTurn,
	resolveVideoTurn,
	videoTurnTransform,
	type TurnDegrees,
	type VideoFit,
	type VideoOrientationInfo,
	type VideoTurnChoice,
} from '../../immuch360/video/orientation';
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
	// Immuch360: the orientation and stored size of the video (asset details), null while unknown: a video filmed upright
	// whose frames the player shows on their side is turned (src/immuch360/video/orientation.ts, issue 17)
	orientation?: VideoOrientationInfo | null;
	// Immuch360: the turn chosen with the viewer's "Turn the picture" and "Fit the picture" buttons, which replaces the
	// player's own; null for none
	manualTurn?: VideoTurnChoice | null;
	// Immuch360: what the picture is turned by now, and whether the fit changes anything, for the viewer's buttons
	onTurnShown?: (shown: VideoTurnShown) => void;
}

/** What the player turns the picture by, once it knows the frames (VideoPlayer's onTurnShown) */
export interface VideoTurnShown {
	degrees: TurnDegrees;
	fit: VideoFit;
	fitMatters: boolean;
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

// Immuch360: the player's Spotlight container (Sandstone's default id, kept), where the focus goes back from the buttons
// of the video's top bar; it enters at the handle that takes the keys while the transport bar is closed
export const PLAYER_SPOTLIGHT_ID = 'videoPlayer';

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
/** The video element of the viewer's player, null when none is open: its readyState tells whether it reached canplay */
export const viewerVideoElement = (): HTMLVideoElement | null => document.querySelector<HTMLVideoElement>(`video[${VIDEO_MARK}]`);
// The events after which a video no longer plays; 'waiting' (buffering) keeps the screen saver off
const STOPPED_EVENTS = ['pause', 'ended', 'emptied', 'error'];

// Hands the player's API to the ref of the viewer, a function or an object
function passApi(ref: React.Ref<VideoPlayerApi> | undefined, api: VideoPlayerApi | null): void {
	if (typeof ref === 'function') ref(api);
	else if (ref) (ref as React.MutableRefObject<VideoPlayerApi | null>).current = api;
}

export const VideoPlayer: React.FC<VideoPlayerProps> = ({src, onControlsAvailable, apiRef, orientation, manualTurn, onTurnShown}) => {
	// Immuch360: the player's API for this component too (the pause below), and for the viewer through apiRef
	const ownApi = useRef<VideoPlayerApi | null>(null);
	const setApi = useCallback(
		(api: VideoPlayerApi | null) => {
			ownApi.current = api;
			passApi(apiRef, api);
		},
		[apiRef]
	);

	// Immuch360: on a Samsung TV the video pauses when the app is hidden (Samsung: "your application must handle
	// multitasking"). webOS suspends a hidden app by itself and keeps its behaviour (features.ts).
	useEffect(() => {
		if (!features().pauseVideoWhenHidden) return undefined;
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

	// Immuch360: the video element is turned once the player knows the size of the frames (loadedmetadata), and again
	// when the asset's details come or a turn is chosen by hand; the player's controls are outside the element and stay
	// as they are. By itself on a Samsung TV only; a turn chosen by hand on every TV.
	const turnOrientation = orientation?.orientation ?? null;
	const turnWidth = orientation?.width ?? null;
	const turnHeight = orientation?.height ?? null;
	const manualDegrees = manualTurn?.degrees ?? null;
	const manualFit = manualTurn?.fit ?? null;
	const shownRef = useRef(onTurnShown);
	useEffect(() => {
		shownRef.current = onTurnShown;
	});
	useEffect(() => {
		// webOS only notes its own turn, for the diagnostics page, and leaves it to its player
		const {turnSidewaysVideo, reportedVideoSizeTellsTurn} = features();
		const rule = {reportedSizeTellsTurn: reportedVideoSizeTellsTurn};
		const manual: VideoTurnChoice | null = manualDegrees === null ? null : manualFit ? {degrees: manualDegrees, fit: manualFit} : {degrees: manualDegrees};
		// The element turned last: on closing it is already out of the page
		let turned: HTMLVideoElement | null = null;
		const apply = () => {
			const node = viewerVideoElement();
			if (!node) return;
			const input = {
				orientation: turnOrientation,
				width: turnWidth,
				height: turnHeight,
				frameWidth: node.videoWidth,
				frameHeight: node.videoHeight,
				boxWidth: node.clientWidth,
				boxHeight: node.clientHeight,
			};
			const resolved = resolveVideoTurn(input, manual, rule);
			const applies = resolved.source === 'manual' || turnSidewaysVideo;
			if (applies) {
				turned = node;
				node.style.transform = videoTurnTransform(resolved.turn);
			}
			const rect = typeof node.getBoundingClientRect === 'function' ? node.getBoundingClientRect() : null;
			noteVideoTurn(input, {platform: platform(), resolved, applied: applies, onScreen: rect ? {width: rect.width, height: rect.height} : null});
			// A turn by hand stands before the player knows its frames; its own turn only once it is set
			const degrees = resolved.source === 'manual' || (applies && resolved.turn) ? resolved.degrees : 0;
			shownRef.current?.({degrees, fit: resolved.fit, fitMatters: fitMatters(input)});
		};
		const onMetadata = (event: Event) => {
			if (fromThisPlayer(event.target)) apply();
		};
		apply();
		document.addEventListener('loadedmetadata', onMetadata, true);
		window.addEventListener('resize', apply);
		return () => {
			document.removeEventListener('loadedmetadata', onMetadata, true);
			window.removeEventListener('resize', apply);
			if (turned) turned.style.transform = '';
		};
	}, [src, turnOrientation, turnWidth, turnHeight, manualDegrees, manualFit]);

	const playerProps = {...PLAYER_PROPS, onControlsAvailable, ref: setApi, [VIDEO_MARK]: ''};
	return (
		<SandstoneVideoPlayer {...(playerProps as any)} className={css.viewerMedia}>
			<source src={src} type="video/mp4" />
		</SandstoneVideoPlayer>
	);
};

VideoPlayer.displayName = 'VideoPlayer';
