import React, {useCallback, useEffect, useMemo, useRef, useState} from 'react';
import {useWebOSKeys} from '../../hooks/useWebOSKeys';
import {useAutoHideControls} from '../../hooks/useAutoHideControls';
import {useAssetRotation} from '../../hooks/useAssetRotation';
import {useAssetDetails} from '../../hooks/useAssetDetails';
import {usePhotoZoom} from '../../hooks/usePhotoZoom';
import {useRepository} from '../../domain/RepositoryContext';
import {createSpotlightContainer, forceFocus, SpottableDiv} from '../../utils/spotlight';
import type {TimelineAsset} from '../../domain/types';
import {i18nKey, t} from '../../immuch360/i18n';
import {CONTROLS_HIDE_AFTER_MS, SEEK_STEP_SECONDS, VIDEO_STALL_MS, photoRotationStep, playPauseWantsPlay, remoteAction, videoArrows} from '../../immuch360/keys';
import {isForced360, setForced360, setSphereChoice, sphereChoice, type SphereChoice} from '../../immuch360/forced360';
import {isEquirectangularProjection, isShownAs360, nextStereoLayout, type SphereView as ResolvedSphereView, type StereoLayout} from '../../immuch360/sphere/rules';
import {SphereView, type SphereViewHandle} from '../../immuch360/sphere/SphereView';
import {AssetDetailsPanel} from '../../immuch360/details/AssetDetailsPanel';
import {FULLSIZE_FROM_SCALE, wantsFullsize} from '../../immuch360/photoSize';
import {MediaControls, ACTION_BAR_SPOTLIGHT_ID, type ViewerAction} from './MediaControls';
import {VideoPlayer, VideoPlayerApi} from './VideoPlayer';
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
// Immuch360: OK on a 360° photo focuses this button, as the Flutter viewer does on Android TV
const ZOOM_IN_SPOTLIGHT_ID = 'media-viewer-zoom-in';
// Trap Spotlight inside the viewer so D-pad can't reach the underlying rail/grid (which would
// trigger NavigationRail's focus-based expand and other surprises).
const ViewerContainer = createSpotlightContainer({enterTo: 'last-focused'});

// Immuch360: on a 360° photo the arrows turn the view, so only OK brings the controls back
const SPHERE_REVEAL_KEYS: readonly string[] = ['Enter'];
// Immuch360: on a flat photo Up turns it by 90° (photoRotationStep), so OK and Down bring the controls back
const FLAT_PHOTO_REVEAL_KEYS: readonly string[] = ['Enter', 'ArrowDown'];

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
const focusActionBar = () => forceFocus(ACTION_BAR_SPOTLIGHT_ID);

export const MediaViewer: React.FC<MediaViewerProps> = React.memo(({getAssetAt, totalCount, currentIndex, position, onClose, onNavigate, onStartSlideshow}) => {
	const repository = useRepository();
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
	// Immuch360: the video that did not play (an error, or nothing after 20 s): a message replaces the endless spinner
	const [videoFailure, setVideoFailure] = useState<string | null>(null);
	const videoFailed = isVideo && !!asset && videoFailure === asset.id;
	const details = useAssetDetails(asset?.id, !!asset && (detailsOpen || zoomedPast2x || videoFailed || (!isVideo && (flagged || forced || looksEquirect(asset.ratio)))));
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
	const [rotation, rotate] = useAssetRotation(isVideo || show360 ? undefined : asset?.id);
	const {zoom, zoomed, zoomIn: photoZoomIn, zoomOut: photoZoomOut, reset: resetZoom, pan, style: zoomStyle} = usePhotoZoom(isVideo || show360 ? undefined : asset?.id);
	if (zoomedPast2x !== zoom.scale > FULLSIZE_FROM_SCALE) setZoomedPast2x(zoom.scale > FULLSIZE_FROM_SCALE);
	const sharp = !isVideo && !show360 && wantsFullsize(zoom.scale, details?.width, details?.height);
	const controlsRef = useRef<HTMLDivElement>(null);

	// Auto-hide is for still images only. Video keeps its always-visible MediaControls and
	// relies on Sandstone VideoPlayer's own auto-hide (OK/Select is play/pause there).
	const {visible: controlsVisible, show: showControls, hide: hideControls} = useAutoHideControls({
		enabled: !isVideo,
		controlsRef,
		revealKeys: show360 ? SPHERE_REVEAL_KEYS : FLAT_PHOTO_REVEAL_KEYS,
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
	}
	const videoControlsOpen = isVideo && videoControlsVisible;

	const assetId = asset?.id;
	useEffect(() => {
		if (!isVideo || !assetId) return undefined;
		const timer = window.setTimeout(() => setVideoIntro(null), CONTROLS_HIDE_AFTER_MS);
		return () => window.clearTimeout(timer);
	}, [isVideo, assetId]);

	// Immuch360: once a second until the video starts, whether the TV gave up on it (a media error), or whether it still
	// shows nothing 20 s after it opened while nobody paused it
	useEffect(() => {
		if (!isVideo || !assetId) return undefined;
		const opened = Date.now();
		const timer = window.setInterval(() => {
			const api = playerApiRef.current;
			if (!api) return;
			const state = api.getMediaState();
			if ((state.currentTime ?? 0) > 0) {
				window.clearInterval(timer);
				return;
			}
			const stalled = Date.now() - opened >= VIDEO_STALL_MS && state.paused === false;
			if (api.getVideoNode()?.error || stalled) {
				window.clearInterval(timer);
				setVideoFailure(assetId);
			}
		}, 1000);
		return () => window.clearInterval(timer);
	}, [isVideo, assetId]);
	const chromeVisible = isVideo ? videoControlsOpen || videoIntro === asset?.id || videoFailed : controlsVisible;

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
	const panning = zoomed && !inActionBar;

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
	} else if (panning) {
		arrowLeft = panLeft;
		arrowRight = panRight;
		arrowUp = panUp;
		arrowDown = panDown;
	} else {
		// Left/right page between media, except inside the action bar (Spotlight moves between its buttons)
		arrowLeft = inActionBar ? undefined : handlePrev;
		arrowRight = inActionBar ? undefined : handleNext;
		// Immuch360: Up on the photo turns it by 90° (the key handler below); from the action bar it goes back to the photo.
		// Unassigned, Down is a reveal key (useAutoHideControls).
		arrowUp = inActionBar ? focusStage : undefined;
		arrowDown = inActionBar ? swallowKey : controlsVisible ? focusActionBar : undefined;
	}

	useWebOSKeys({onBack: handleBack, onArrowLeft: arrowLeft, onArrowRight: arrowRight, onArrowUp: arrowUp, onArrowDown: arrowDown});

	// Immuch360: the other keys of the remote in the viewer: Up (and R, ] or [ of a keyboard) turns a flat photo by 90°,
	// the track keys go to the neighbours, Stop closes a video, rewind and fast forward step 10 s, the play and pause
	// keys do as their name says, the channel keys zoom a photo
	useEffect(() => {
		const onKeyDown = (event: KeyboardEvent) => {
			const action = remoteAction(event);
			const turn = !isVideo && !show360 ? photoRotationStep(action, {zoomed, inActionBar}) : null;
			let handled = true;
			if (turn !== null) {
				// The zoom and its position were for the photo as it stood
				if (zoomed) resetZoom();
				rotate(turn);
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

	// Immuch360: OK on a 360° photo shows the controls with the zoom button focused (the arrows turn the view)
	const handleStageClick = useCallback(() => {
		if (show360) {
			showControls();
			forceFocus(ZOOM_IN_SPOTLIGHT_ID);
			return;
		}
		if (controlsVisible) hideControls();
		else showControls();
	}, [show360, controlsVisible, hideControls, showControls]);

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

	const mediaUrl = isVideo ? repository.videoPlaybackUrl(asset.id) : sharp ? repository.fullsizeUrl(asset.id) : repository.previewUrl(asset.id);
	let notice: string | undefined;
	if (show360) notice = t('tv_look_hint');
	else if (wants360 && sphereFailure) notice = sphereFailure.reason;
	else if (videoFailed) {
		const size = details?.width && details.height ? `${details.width} × ${details.height}` : null;
		const format = [details?.originalMimeType, size].filter(Boolean).join(', ');
		notice = t('webos_video_cannot_play', {format: format || t('unknown')});
	} else if (video360) notice = t('webos_360_video_flat');

	return (
		<ViewerContainer spotlightId={VIEWER_SPOTLIGHT_ID} spotlightRestrict="self-only" className={css.viewerOverlay}>
			<div className={css.viewerContent}>
				{isVideo ? (
					<VideoPlayer src={mediaUrl} onControlsAvailable={handleVideoControlsAvailable} apiRef={playerApiRef} />
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
				) : (
					<div className={css.zoomBox} style={zoomStyle}>
						<img
							src={mediaUrl}
							alt=""
							className={rotation % 180 ? `${css.photo} ${css.quarterTurn}` : css.photo}
							style={rotation ? {transform: `rotate(${rotation}deg)`} : undefined}
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
			{detailsOpen && <AssetDetailsPanel asset={asset} details={details} />}
		</ViewerContainer>
	);
});

MediaViewer.displayName = 'MediaViewer';
