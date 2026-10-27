import React, {useCallback, useEffect, useMemo, useRef, useState} from 'react';
import Button from '@enact/sandstone/Button';
import {useWebOSKeys} from '../../hooks/useWebOSKeys';
import {useOnline} from '../../hooks/useOnline';
import {useAutoHideControls} from '../../hooks/useAutoHideControls';
import {useAssetRotation} from '../../hooks/useAssetRotation';
import {useAssetDetailsQuery} from '../../hooks/useAssetDetails';
import {usePhotoZoom} from '../../hooks/usePhotoZoom';
import {usePhotoLoading} from '../../hooks/usePhotoLoading';
import {useRepository} from '../../domain/RepositoryContext';
import {createSpotlightContainer, forceFocus, SpottableDiv} from '../../utils/spotlight';
import type {TimelineAsset} from '../../domain/types';
import {i18nKey, t} from '../../immuch360/i18n';
import {
	CONTROLS_HIDE_AFTER_MS,
	SEEK_STEP_SECONDS,
	VIDEO_STALL_MS,
	photoArrows,
	photoRotationStep,
	playPauseWantsPlay,
	remoteAction,
	videoArrows,
	type PhotoArrow,
} from '../../immuch360/keys';
import {isForced360, setForced360, setSphereChoice, sphereChoice, type SphereChoice} from '../../immuch360/forced360';
import {isEquirectangularProjection, isShownAs360, nextStereoLayout, type SphereView as ResolvedSphereView, type StereoLayout} from '../../immuch360/sphere/rules';
import {SphereView, type SphereViewHandle} from '../../immuch360/sphere/SphereView';
import {AssetDetailsPanel} from '../../immuch360/details/AssetDetailsPanel';
import {RotationIndicator} from '../../immuch360/rotation/RotationIndicator';
import {FULLSIZE_FROM_SCALE, wantsFullsize} from '../../immuch360/photoSize';
import {decoderCeiling, exceedsCeiling} from '../../immuch360/video/decoders';
import {
	flatVideoNotice,
	nextStallState,
	stallNotice,
	startAdvice,
	videoBitrateMbps,
	videoStart,
	type StallState,
	type VideoAdvice,
	type VideoGateInput,
} from '../../immuch360/video/limits';
import {holdsFlatVideoNotice} from '../../immuch360/video/session';
import {usePlaysOriginal, useVideoGate, useVideoSession} from '../../immuch360/video/useVideoGate';
import {MediaControls, type ViewerAction} from './MediaControls';
import {VideoPlayer, VideoPlayerApi, viewerVideoElement} from './VideoPlayer';
import {PhotoLoading, ZoomLevel} from './PhotoStatus';
import css from './MediaViewer.module.less';

interface MediaViewerProps {
	getAssetAt: (index: number) => TimelineAsset | null;
	totalCount: number;
	currentIndex: number;
	position: string;
	onClose: () => void;
	onNavigate: (direction: 'prev' | 'next') => void;
	onStartSlideshow: () => void;
}

const VIEWER_SPOTLIGHT_ID = 'media-viewer';
const STAGE_SPOTLIGHT_ID = 'media-viewer-stage';
// Immuch360: OK on a photo focuses this button, as the Flutter viewer does on Android TV for a 360° photo
const ZOOM_IN_SPOTLIGHT_ID = 'media-viewer-zoom-in';
// Immuch360: the Back button under the message of a video that does not play
const VIDEO_BACK_SPOTLIGHT_ID = 'media-viewer-video-back';
// readyState from which a video can play (HTMLMediaElement.HAVE_FUTURE_DATA, the canplay event)
const HAVE_FUTURE_DATA = 3;
// Immuch360: the duration the player found, once its metadata is in
const knownDuration = (duration: number | undefined): number | null => (duration !== undefined && Number.isFinite(duration) && duration > 0 ? duration : null);
// Immuch360: what lightens a heavy original, as a sentence
const adviceText = (advice: VideoAdvice): string => (advice === 'transcode' ? t('webos_video_advice_transcode') : t('webos_video_advice_wired'));
// Trap Spotlight inside the viewer so D-pad can't reach the underlying rail/grid (which would
// trigger NavigationRail's focus-based expand and other surprises).
const ViewerContainer = createSpotlightContainer({enterTo: 'last-focused'});

// Immuch360: the arrows turn a 360° photo and zoom or move a flat one, so only OK brings the controls back. A constant:
// a new list at each render would install the listener of useAutoHideControls again, after the arrows' one.
const PHOTO_REVEAL_KEYS: readonly string[] = ['Enter'];

// Immuch360: the name of each 3D layout on the 2D/3D button, held through i18nKey so that tools/build-i18n.mjs bundles
// the three texts (a key chosen by a ternary inside t() is not seen by it)
const STEREO_LAYOUT_NAMES: Record<StereoLayout, string> = {
	mono: i18nKey('panorama_stereo_mono'),
	topBottom: i18nKey('panorama_stereo_top_bottom'),
	leftRight: i18nKey('panorama_stereo_left_right'),
};

// Immuch360: a photo whose shape is 2:1 within 2% may be one a 360° camera stitched without GPano tags; its details
// (name, camera) tell, so they are fetched for it
const looksEquirect = (ratio: number) => Math.abs(ratio / 2 - 1) <= 0.02;

// useWebOSKeys preventDefaults + stops propagation before calling the handler, so a no-op
// is enough to fully swallow a key (Spotlight never sees it → focus can't leak).
const swallowKey = () => {};
const focusStage = () => forceFocus(STAGE_SPOTLIGHT_ID);

export const MediaViewer: React.FC<MediaViewerProps> = React.memo(({getAssetAt, totalCount, currentIndex, position, onClose, onNavigate, onStartSlideshow}) => {
	const repository = useRepository();
	// Immuch360: a video that fails while the TV is offline says so, not that the TV cannot play it
	const online = useOnline();
	const asset = getAssetAt(currentIndex);

	const handlePrev = useCallback(() => {
		if (currentIndex > 0) onNavigate('prev');
	}, [onNavigate, currentIndex]);

	const handleNext = useCallback(() => {
		if (currentIndex < totalCount - 1) onNavigate('next');
	}, [onNavigate, currentIndex, totalCount]);

	const isVideo = asset?.type === 'VIDEO';

	// Immuch360: is this photo shown on the 360° sphere? The server's flag, the user's "View as 360°", or a 360° camera
	// that stitched it (its details tell). Raw files of 360° cameras never are.
	const [forcedVersion, setForcedVersion] = useState(0);
	const forced = useMemo(() => (asset ? isForced360(asset.id) : false), [asset, forcedVersion]); // eslint-disable-line react-hooks/exhaustive-deps
	const flagged = isEquirectangularProjection(asset?.projectionType);
	// Immuch360: the details panel (Info, I, or its button) stays open from one item to the next until Info or Back
	const [detailsOpen, setDetailsOpen] = useState(false);
	const toggleDetails = useCallback(() => setDetailsOpen((open) => !open), []);
	// Immuch360: a flat photo zoomed in past 2x shows its full-size picture, once its size is known to fit a TV
	const [zoomedPast2x, setZoomedPast2x] = useState(false);
	// Immuch360: the video that did not play (a media error, or not started after 20 s): a message replaces the player.
	// mediaDuration: the duration the player had found, for the bitrate when the asset does not tell it.
	const [videoFailure, setVideoFailure] = useState<{assetId: string; kind: 'error' | 'notStarted'; mediaDuration: number | null} | null>(null);
	const videoFailed = isVideo && !!asset && videoFailure?.assetId === asset.id;
	// Immuch360: the video that stalled after it started (limits.ts, nextStallState): its notice stays with it, and the
	// controls show while it stalls (active)
	const [videoStall, setVideoStall] = useState<{assetId: string; active: boolean; mediaDuration: number | null} | null>(null);
	const stallSeen = isVideo && !!asset && videoStall?.assetId === asset.id;
	// Immuch360: what the session knows of the TV's video (src/immuch360/video/session.ts). Where its decoders refused a
	// size, a video's own size is read before it plays, and one past the ceiling does not start (limits.ts).
	const {decoders, frames} = useVideoSession();
	const ceiling = useMemo(() => decoderCeiling(decoders), [decoders]);
	const sizeBeforePlay = isVideo && !!ceiling;
	const {details, settled: detailsSettled} = useAssetDetailsQuery(
		asset?.id,
		!!asset &&
			(detailsOpen || zoomedPast2x || videoFailed || stallSeen || sizeBeforePlay || (!isVideo && (flagged || forced || looksEquirect(asset.ratio) || repository.detailsForEveryPhoto === true)))
	);
	let videoSize: VideoGateInput['size'] = null;
	if (sizeBeforePlay) videoSize = details ? {width: details.width, height: details.height} : detailsSettled ? null : undefined;
	// Immuch360: whether the server plays the original, asked for a video past the ceiling, one that did not start and one
	// that stalls (a HEAD request on Immich, src/api/ImmichRepository.ts)
	const pastCeiling = sizeBeforePlay && !!ceiling && !!details?.width && !!details.height && exceedsCeiling(details.width, details.height, ceiling);
	const playsOriginal = usePlaysOriginal(repository, isVideo ? asset?.id : undefined, details?.fileSize ?? null, pastCeiling || videoFailed || stallSeen);
	const gate = useVideoGate(isVideo ? asset?.id : undefined, ceiling, videoSize, playsOriginal);
	const playerShown = isVideo && gate.kind === 'play' && !videoFailed;
	// Immuch360: the bitrate of the file, from its size and the asset's duration (else the one the player found)
	const mediaDuration = (videoFailed ? videoFailure?.mediaDuration : null) ?? (stallSeen ? videoStall?.mediaDuration : null) ?? null;
	const heavy = {
		playsOriginal,
		bitrate: isVideo ? videoBitrateMbps(details?.fileSize, asset?.durationSeconds || mediaDuration) : null,
		serverTranscodes: repository.serverTranscodes === true,
	};
	// Immuch360: why a video does not play, in the middle of the screen with Back, where the player would be
	let videoMessage: string | null = null;
	if (isVideo && gate.kind === 'tooLarge') {
		videoMessage = t('webos_video_too_large', {size: gate.size, width: String(gate.width), height: String(gate.height)});
	} else if (videoFailed && !online) {
		videoMessage = t('webos_error_offline');
	} else if (videoFailed) {
		const size = details?.width && details.height ? `${details.width} × ${details.height}` : null;
		const format = [details?.originalMimeType, size].filter(Boolean).join(', ') || t('unknown');
		videoMessage = videoFailure?.kind === 'notStarted' ? t('webos_video_not_started', {format}) : t('webos_video_cannot_play', {format});
		// A heavy original can fail to start as it stalls: its bitrate and what lightens it
		const advice = videoFailure?.kind === 'notStarted' ? startAdvice(heavy) : null;
		if (advice && heavy.bitrate !== null) videoMessage += ` ${t('webos_video_file_bitrate', {bitrate: heavy.bitrate})} ${adviceText(advice)}`;
	}
	// Immuch360: the notice of a video that stalled, which goes on playing: the bitrate of the original and what lightens
	// it, or only that the link is too slow for a transcode
	let stallText: string | null = null;
	if (stallSeen && playerShown) {
		const stall = stallNotice(heavy);
		if (stall.kind === 'heavy') stallText = t('webos_video_stalls_heavy', {bitrate: heavy.bitrate ?? 0});
		else if (stall.kind === 'heavyUnknown') stallText = t('webos_video_stalls_heavy_unknown');
		else stallText = t('webos_video_stalls_slow_link');
		if (stall.advice) stallText += ` ${adviceText(stall.advice)}`;
	}
	const [sphereFailure, setSphereFailure] = useState<{assetId: string; reason: string} | null>(null);
	const sphereFailed = !!asset && sphereFailure?.assetId === asset.id;
	const wants360 =
		!!asset &&
		!isVideo &&
		isShownAs360({
			isVideo: false,
			projectionType: asset.projectionType ?? details?.projectionType,
			forced,
			name: details?.originalFileName,
			make: details?.make,
			model: details?.model,
			width: details?.width,
			height: details?.height,
		});
	const show360 = wants360 && !sphereFailed;
	const video360 = isVideo && flagged;
	const [choiceVersion, setChoiceVersion] = useState(0);
	const choice: SphereChoice = useMemo(() => (asset ? sphereChoice(asset.id) : {}), [asset, choiceVersion]); // eslint-disable-line react-hooks/exhaustive-deps
	const [resolved, setResolved] = useState<ResolvedSphereView | null>(null);
	const sphereRef = useRef<SphereViewHandle>(null);

	const [actionBarFocused, setActionBarFocused] = useState(false);
	const {rotation, rotate, notice: rotationNotice, phase: rotationPhase} = useAssetRotation(isVideo || show360 ? undefined : asset?.id);
	const {zoom, zoomed, pulse: zoomPulse, zoomIn: photoZoomIn, zoomOut: photoZoomOut, reset: resetZoom, pan, style: zoomStyle} = usePhotoZoom(isVideo || show360 ? undefined : asset?.id);
	if (zoomedPast2x !== zoom.scale > FULLSIZE_FROM_SCALE) setZoomedPast2x(zoom.scale > FULLSIZE_FROM_SCALE);
	// Immuch360: the photo whose full-size picture the TV could not load or decode (memory, a timeout): it stays on its
	// preview, without a message, until another photo is opened
	const [fullsizeFailed, setFullsizeFailed] = useState<string | null>(null);
	const sharp = !isVideo && !show360 && !!asset && fullsizeFailed !== asset.id && wantsFullsize(zoom.scale, details?.width, details?.height);
	// Immuch360: the picture of a flat photo, and whether it is on screen yet (the loading pill, an error)
	const photoSrc = !asset || isVideo || show360 ? null : sharp ? repository.fullsizeUrl(asset.id) : repository.previewUrl(asset.id);
	const photoLoad = usePhotoLoading(photoSrc);
	const controlsRef = useRef<HTMLDivElement>(null);

	// Auto-hide is for still images only. Video keeps its always-visible MediaControls and
	// relies on Sandstone VideoPlayer's own auto-hide (OK/Select is play/pause there).
	const {visible: controlsVisible, show: showControls} = useAutoHideControls({
		enabled: !isVideo,
		controlsRef,
		revealKeys: PHOTO_REVEAL_KEYS,
	});
	const inActionBar = !isVideo && controlsVisible && actionBarFocused;

	// The bar faded out under an idle focus: hand it back to the stage rather than leave it on
	// a hidden button.
	useEffect(() => {
		if (!controlsVisible && actionBarFocused) focusStage();
	}, [controlsVisible, actionBarFocused]);

	// Sandstone transport-bar visibility (video) drives arrow-key semantics: hidden →
	// left/right page between media; visible → Sandstone seeks.
	const playerApiRef = useRef<VideoPlayerApi | null>(null);
	const [videoControlsVisible, setVideoControlsVisible] = useState(false);
	// Sandstone bug: forwardCustom drops the documented {available} payload, so read the
	// current state through the imperative API instead (fires post-update, value is fresh).
	const handleVideoControlsAvailable = useCallback(({available}: {available?: boolean}) => {
		setVideoControlsVisible(available ?? playerApiRef.current?.areControlsVisible() ?? false);
	}, []);

	// Reset on media change: Sandstone doesn't notify when the player unmounts (video →
	// photo), which would leave the state stuck on "visible". State adjustment during
	// render, not in an effect (`react-hooks/set-state-in-effect`, Enact CI strict).
	// Immuch360: the top bar of a video (close, date, position) hides with Sandstone's transport bar instead of staying
	// over the film; it shows for 5 s when a video opens, as the controls do after a key. The video it shows for is set
	// with the asset (below), the timer only clears it.
	const [videoIntro, setVideoIntro] = useState<string | null>(isVideo && asset ? asset.id : null);
	const [prevAssetId, setPrevAssetId] = useState(asset?.id);
	if (asset?.id !== prevAssetId) {
		setPrevAssetId(asset?.id);
		setVideoControlsVisible(false);
		// The bar may unmount (photo → video) without a blur reaching us.
		setActionBarFocused(false);
		setResolved(null);
		setVideoIntro(isVideo && asset ? asset.id : null);
		// A video that failed is tried again, and checked again, when it is opened again
		setVideoFailure(null);
		setVideoStall(null);
		// And the full-size picture of a photo
		setFullsizeFailed(null);
	}
	const videoControlsOpen = isVideo && videoControlsVisible;

	const assetId = asset?.id;
	useEffect(() => {
		if (!isVideo || !assetId) return undefined;
		const timer = window.setTimeout(() => setVideoIntro(null), CONTROLS_HIDE_AFTER_MS);
		return () => window.clearTimeout(timer);
	}, [isVideo, assetId]);

	// Immuch360: once a second until the video starts, whether the TV gave up on it (a media error), or whether it did not
	// start within 20 s of the player opening: no canplay, or canplay and still no frame while nobody paused it (limits.ts,
	// videoStart). Either way the player closes, which ends its loading and frees the TV's decoder, and a message with
	// Back takes its place; the video is tried again when it is opened again. Once it started, whether it stalls: no
	// progress for 8 s while nobody paused it (nextStallState) shows a notice, and the video goes on.
	useEffect(() => {
		if (!playerShown || !assetId) return undefined;
		const opened = Date.now();
		let started = false;
		let stall: StallState | null = null;
		const timer = window.setInterval(() => {
			const api = playerApiRef.current;
			if (!api) return;
			const state = api.getMediaState();
			if (started) {
				const wasStalled = stall?.stalled ?? false;
				stall = nextStallState(stall, {at: Date.now(), currentTime: state.currentTime ?? 0, paused: state.paused});
				if (stall.stalled !== wasStalled) setVideoStall({assetId, active: stall.stalled, mediaDuration: knownDuration(state.duration)});
				return;
			}
			const node = viewerVideoElement();
			const verdict = videoStart(
				{
					elapsedMs: Date.now() - opened,
					currentTime: state.currentTime ?? 0,
					canPlay: !!node && node.readyState >= HAVE_FUTURE_DATA,
					paused: state.paused,
					error: !!api.getVideoNode()?.error,
				},
				VIDEO_STALL_MS
			);
			if (verdict === 'waiting') return;
			if (verdict === 'started') {
				started = true;
				return;
			}
			window.clearInterval(timer);
			try {
				api.pause();
			} catch {
				// The player closes anyway
			}
			setVideoControlsVisible(false);
			setVideoFailure({assetId, kind: verdict, mediaDuration: knownDuration(state.duration)});
		}, 1000);
		return () => window.clearInterval(timer);
	}, [playerShown, assetId]);

	// Immuch360: the message of a video that does not play takes the focus, on its Back button; the next video that
	// plays gives it back to the viewer, as when a video opens
	const hasVideoMessage = !!videoMessage;
	const hadVideoMessage = useRef(false);
	useEffect(() => {
		if (hasVideoMessage) forceFocus(VIDEO_BACK_SPOTLIGHT_ID);
		else if (hadVideoMessage.current && isVideo) forceFocus(VIEWER_SPOTLIGHT_ID);
		hadVideoMessage.current = hasVideoMessage;
	}, [hasVideoMessage, assetId, isVideo]);
	// Immuch360: a photo whose turn stays on the TV, or could not be saved, shows the controls with a message about it
	const chromeVisible = isVideo
		? videoControlsOpen || videoIntro === asset?.id || hasVideoMessage || (stallSeen && !!videoStall?.active)
		: controlsVisible || !!rotationNotice;

	// Immuch360: Left and Right go to the neighbours whatever the video does; a video alone in the viewer seeks 10 s
	const hasNeighbours = totalCount > 1;
	const seekVideo = useCallback((seconds: number) => playerApiRef.current?.jump(seconds), []);
	const videoLeft = useCallback(() => (videoArrows(hasNeighbours) === 'navigate' ? handlePrev() : seekVideo(-SEEK_STEP_SECONDS)), [hasNeighbours, handlePrev, seekVideo]);
	const videoRight = useCallback(() => (videoArrows(hasNeighbours) === 'navigate' ? handleNext() : seekVideo(SEEK_STEP_SECONDS)), [hasNeighbours, handleNext, seekVideo]);

	// Back closes the transport bar if open, the viewer otherwise. Our Back bridge
	// (capture + stopImmediatePropagation) preempts Sandstone's Cancelable, so the
	// two-step behavior has to be restored here. Immuch360: the details panel closes first, a zoomed photo zooms out
	// before the viewer closes.
	const handleBack = useCallback(() => {
		if (detailsOpen) {
			setDetailsOpen(false);
			return;
		}
		if (videoControlsOpen && playerApiRef.current) {
			playerApiRef.current.hideControls();
			return;
		}
		if (zoomed) {
			resetZoom();
			return;
		}
		onClose();
	}, [detailsOpen, videoControlsOpen, onClose, zoomed, resetZoom]);

	const panLeft = useCallback(() => pan(-1, 0), [pan]);
	const panRight = useCallback(() => pan(1, 0), [pan]);
	const panUp = useCallback(() => pan(0, -1), [pan]);
	const panDown = useCallback(() => pan(0, 1), [pan]);
	// Immuch360: what each arrow does on a flat photo (keys.ts, photoArrows); a pan moves the photo the arrow's way
	const photoArrow = (arrow: PhotoArrow, panThisWay: () => void): (() => void) | undefined => {
		if (arrow === 'previous') return handlePrev;
		if (arrow === 'next') return handleNext;
		if (arrow === 'zoomIn') return photoZoomIn;
		// Down at 1x has nothing to zoom out: the level shows 100%, so the key answers
		if (arrow === 'zoomOut') return photoZoomOut;
		if (arrow === 'pan') return panThisWay;
		if (arrow === 'toStage') return focusStage;
		if (arrow === 'swallow') return swallowKey;
		return undefined;
	};

	let arrowLeft: (() => void) | undefined;
	let arrowRight: (() => void) | undefined;
	let arrowUp: (() => void) | undefined;
	let arrowDown: (() => void) | undefined;
	if (isVideo) {
		// Left/right page between media, except while the video transport bar is open (Sandstone seeks there)
		arrowLeft = videoControlsOpen ? undefined : videoLeft;
		arrowRight = videoControlsOpen ? undefined : videoRight;
		// Up/down must never reach Spotlight unhandled, or it leaks focus to the grid behind the overlay
		arrowUp = videoControlsOpen ? undefined : swallowKey;
		arrowDown = undefined;
	} else if (show360) {
		// The sphere turns with the arrows (SphereView) unless the focus is in the action bar
		arrowUp = inActionBar ? focusStage : undefined;
		arrowDown = inActionBar ? swallowKey : undefined;
	} else {
		// Left/right page between media and Up/Down zoom, except inside the action bar (Spotlight moves between its
		// buttons, Up goes back to the photo); zoomed in, the four arrows move the photo
		const arrows = photoArrows({zoomed, inActionBar});
		arrowLeft = photoArrow(arrows.left, panLeft);
		arrowRight = photoArrow(arrows.right, panRight);
		arrowUp = photoArrow(arrows.up, panUp);
		arrowDown = photoArrow(arrows.down, panDown);
	}

	useWebOSKeys({onBack: handleBack, onArrowLeft: arrowLeft, onArrowRight: arrowRight, onArrowUp: arrowUp, onArrowDown: arrowDown});

	// Immuch360: the other keys of the remote in the viewer: yellow turns a flat photo 90° clockwise and blue
	// counterclockwise (R and Shift R on a keyboard), as on Android TV; the track keys go to the neighbours, Stop closes
	// a video, rewind and fast forward step 10 s, the play and pause keys do as their name says, the channel keys zoom a
	// photo as Up and Down do
	useEffect(() => {
		const onKeyDown = (event: KeyboardEvent) => {
			const action = remoteAction(event);
			const turn = !isVideo && !show360 ? photoRotationStep(action) : null;
			let handled = true;
			if (turn !== null) {
				// A key held down repeats: one press is one turn
				if (!event.repeat) {
					// The zoom and its position were for the photo as it stood
					if (zoomed) resetZoom();
					rotate(turn);
				}
			} else if (action === 'info') toggleDetails();
			else if (action === 'previousTrack') handlePrev();
			else if (action === 'nextTrack') handleNext();
			else if (isVideo && action === 'stop') onClose();
			else if (isVideo && (action === 'rewind' || action === 'fastForward')) seekVideo(action === 'rewind' ? -SEEK_STEP_SECONDS : SEEK_STEP_SECONDS);
			else if (isVideo && playerApiRef.current && (action === 'play' || action === 'pause' || action === 'playPause')) {
				const api = playerApiRef.current;
				const play = playPauseWantsPlay(action, !api.getMediaState().paused);
				if (play) api.play();
				else api.pause();
			} else if (!isVideo && !show360 && !inActionBar && (action === 'channelUp' || action === 'channelDown')) {
				if (action === 'channelUp') photoZoomIn();
				else photoZoomOut();
			} else handled = false;
			if (!handled) return;
			event.preventDefault();
			event.stopImmediatePropagation();
		};
		window.addEventListener('keydown', onKeyDown, {capture: true});
		return () => window.removeEventListener('keydown', onKeyDown, {capture: true});
	}, [handlePrev, handleNext, isVideo, show360, inActionBar, zoomed, onClose, seekVideo, photoZoomIn, photoZoomOut, resetZoom, rotate, toggleDetails]);

	// Photos rest focus on the stage; forcing it also pulls focus off the grid card behind the
	// overlay when the viewer was opened with the pointer.
	useEffect(() => {
		forceFocus(isVideo ? VIEWER_SPOTLIGHT_ID : STAGE_SPOTLIGHT_ID);
	}, [isVideo]);

	// Immuch360: OK on a photo shows the controls with the zoom button focused: the arrows turn a 360° photo and zoom or
	// move a flat one, so OK is the way into the controls. They hide 5 s after the last key, Up leaves them.
	const handleStageClick = useCallback(() => {
		showControls();
		forceFocus(ZOOM_IN_SPOTLIGHT_ID);
	}, [showControls]);

	// Immuch360: a full-size picture that fails gives way to the preview; a preview that fails says so
	const onPhotoError = photoLoad.onError;
	const assetIdForError = asset?.id;
	const handlePhotoError = useCallback(() => {
		if (sharp && assetIdForError) setFullsizeFailed(assetIdForError);
		else onPhotoError();
	}, [sharp, assetIdForError, onPhotoError]);

	useEffect(() => {
		const prefetch = (index: number) => {
			const neighbor = getAssetAt(index);
			if (!neighbor || neighbor.type === 'VIDEO') return;
			const img = new Image();
			img.src = repository.previewUrl(neighbor.id);
		};
		prefetch(currentIndex - 1);
		prefetch(currentIndex + 1);
	}, [currentIndex, getAssetAt, repository]);

	const handleSphereFailed = useCallback((reason: string) => {
		if (asset) setSphereFailure({assetId: asset.id, reason});
	}, [asset]);

	const toggleForced = useCallback(() => {
		if (!asset) return;
		setForced360(asset.id, !forced);
		setForcedVersion((n) => n + 1);
		setSphereFailure(null);
	}, [asset, forced]);

	const saveChoice = useCallback(
		(next: SphereChoice) => {
			if (!asset) return;
			setSphereChoice(asset.id, next);
			setChoiceVersion((n) => n + 1);
		},
		[asset]
	);

	// The zoom buttons of the sphere call it through its handle, only when pressed
	const sphereZoomIn = useCallback(() => sphereRef.current?.zoomIn(), []);
	const sphereZoomOut = useCallback(() => sphereRef.current?.zoomOut(), []);

	// The buttons of the action bar, in their order. Built from literals only: the zoom buttons of the sphere read a
	// ref when pressed, and the React lint rules forbid handing such a function to a call during render.
	const actions: ViewerAction[] = useMemo(() => {
		if (!asset || isVideo) return [];
		const sphereChoices: ViewerAction[] =
			show360 && resolved
				? [
						{
							key: 'coverage',
							text: resolved.coverage === 'full' ? '360°' : '180°',
							label: resolved.coverage === 'full' ? t('panorama_coverage_full') : t('panorama_coverage_half'),
							onClick: () => saveChoice({...choice, coverage: resolved.coverage === 'full' ? 'half' : 'full'}),
						},
						{
							key: 'layout',
							text: resolved.layout === 'mono' ? '2D' : '3D',
							label: `${t('panorama_stereo_layout')}: ${t(STEREO_LAYOUT_NAMES[resolved.layout])}`,
							onClick: () => saveChoice({...choice, layout: nextStereoLayout(resolved.layout)}),
						},
					]
				: [];
		const first: ViewerAction[] = show360
			? currentIndex > 0
				? [{key: 'prev', icon: 'arrowlargeleft', label: t('previous'), onClick: handlePrev}]
				: []
			: [{key: 'rotate', icon: 'rotate', label: t('editor_rotate_right'), onClick: rotate}];
		const view360: ViewerAction[] =
			!flagged && (forced || !show360)
				? [{key: 'view360', icon: 'view360', label: forced ? t('view_as_360_remove') : t('view_as_360'), onClick: toggleForced}]
				: [];
		const last: ViewerAction[] =
			show360 && currentIndex < totalCount - 1 ? [{key: 'next', icon: 'arrowlargeright', label: t('next'), onClick: handleNext}] : [];
		return [
			...first,
			{key: 'zoomOut', icon: 'zoomout', label: t('tv_zoom_out'), onClick: show360 ? sphereZoomOut : photoZoomOut},
			{key: 'zoomIn', icon: 'zoomin', label: t('tv_zoom_in'), onClick: show360 ? sphereZoomIn : photoZoomIn, spotlightId: ZOOM_IN_SPOTLIGHT_ID},
			...sphereChoices,
			...view360,
			{key: 'details', icon: 'info', label: t('details'), onClick: toggleDetails},
			{key: 'slideshow', icon: 'play', label: t('slideshow'), onClick: onStartSlideshow},
			{key: 'close', icon: 'closex', label: t('close'), onClick: onClose},
			...last,
		];
	}, [asset, isVideo, show360, resolved, flagged, forced, choice, currentIndex, totalCount, photoZoomIn, photoZoomOut, sphereZoomIn, sphereZoomOut, rotate, toggleDetails, handlePrev, handleNext, onStartSlideshow, onClose, saveChoice, toggleForced]);

	// The Magic Remote drags the sphere through the stage, which lies over it
	const stageMouse = useMemo(
		() =>
			show360
				? {
						onMouseDown: (event: React.MouseEvent) => sphereRef.current?.dragStart(event.clientX, event.clientY),
						onMouseMove: (event: React.MouseEvent) => sphereRef.current?.dragMove(event.clientX, event.clientY),
						onMouseUp: () => sphereRef.current?.dragEnd(),
						onMouseLeave: () => sphereRef.current?.dragEnd(),
						onWheel: (event: React.WheelEvent) => sphereRef.current?.wheel(event.deltaY),
					}
				: {},
		[show360]
	);

	if (!asset) return null;

	const mediaUrl = isVideo ? repository.videoPlaybackUrl(asset.id) : (photoSrc ?? repository.previewUrl(asset.id));
	let notice: string | undefined;
	if (show360) notice = t('tv_look_hint');
	else if (rotationNotice === 'failed') notice = t('rotate_failed');
	else if (rotationNotice === 'keptOnDevice') notice = t('rotate_kept_on_device');
	else if (wants360 && sphereFailure) notice = sphereFailure.reason;
	else if (stallText) notice = stallText;
	else if (video360 && playerShown) {
		// Immuch360: a 360° video plays flat; where the TV keeps video frames out of WebGL, the first one of the session
		// says why and the next ones say nothing (limits.ts, flatVideoNotice)
		const flat = flatVideoNotice(frames, () => holdsFlatVideoNotice(asset.id));
		if (flat === 'noFrames') notice = t('webos_360_video_flat_no_frames');
		else if (flat === 'flat') notice = t('webos_360_video_flat');
	}

	return (
		<ViewerContainer spotlightId={VIEWER_SPOTLIGHT_ID} spotlightRestrict="self-only" className={css.viewerOverlay}>
			<div className={css.viewerContent}>
				{isVideo ? (
					videoMessage ? (
						<div className={css.videoMessage} role="alert">
							<p className={css.videoMessageText}>{videoMessage}</p>
							<Button size="small" onClick={onClose} spotlightId={VIDEO_BACK_SPOTLIGHT_ID}>
								{t('back')}
							</Button>
						</div>
					) : playerShown ? (
						<VideoPlayer src={mediaUrl} onControlsAvailable={handleVideoControlsAvailable} apiRef={playerApiRef} />
					) : null
				) : show360 ? (
					<SphereView
						ref={sphereRef}
						assetId={asset.id}
						details={details}
						chosenLayout={choice.layout}
						chosenCoverage={choice.coverage}
						keysEnabled={!inActionBar}
						onFailed={handleSphereFailed}
						onResolved={setResolved}
					/>
				) : photoLoad.failed ? (
					// Immuch360: a preview that did not load: why, where the photo would be; Left, Right and Back go on
					<div className={css.videoMessage} role="alert">
						<p className={css.videoMessageText}>{online ? t('error_loading_image') : t('webos_error_offline')}</p>
					</div>
				) : (
					<div className={css.zoomBox} style={zoomStyle}>
						<img
							src={mediaUrl}
							alt=""
							className={rotation % 180 ? `${css.photo} ${css.quarterTurn}` : css.photo}
							style={rotation ? {transform: `rotate(${rotation}deg)`} : undefined}
							onLoad={photoLoad.onLoad}
							onError={handlePhotoError}
						/>
					</div>
				)}
			</div>
			{!isVideo && <SpottableDiv spotlightId={STAGE_SPOTLIGHT_ID} className={css.stage} onClick={handleStageClick} {...stageMouse} />}
			<MediaControls
				rootRef={controlsRef}
				asset={asset}
				position={position}
				isVideo={isVideo}
				controlsVisible={chromeVisible}
				canGoPrev={currentIndex > 0}
				canGoNext={currentIndex < totalCount - 1}
				onPrev={handlePrev}
				onNext={handleNext}
				onClose={onClose}
				actions={actions}
				notice={notice}
				onActionBarFocusChange={setActionBarFocused}
			/>
			{/* Immuch360: from a yellow or blue press until the turned picture is shown, over the photo, out of the way of the keys */}
			<RotationIndicator key={asset?.id} active={rotationPhase === 'turning'} />
			{/* Immuch360: while the picture of a flat photo is on its way past 300 ms, in the middle; the zoom level a moment
			    after each zoom key or button, at the top, where the pill of a turn would be */}
			<PhotoLoading active={photoLoad.loading} />
			<ZoomLevel key={`zoom-${asset.id}`} pulse={zoomPulse} scale={zoom.scale} hidden={rotationPhase === 'turning'} />
			{detailsOpen && <AssetDetailsPanel asset={asset} details={details} />}
		</ViewerContainer>
	);
});

MediaViewer.displayName = 'MediaViewer';
