import React, {useCallback, useEffect, useRef, useState} from 'react';
import Spotlight from '@enact/spotlight';
import {useRepository} from '../../domain/RepositoryContext';
import {useAutoHideControls} from '../../hooks/useAutoHideControls';
import {SLIDESHOW_INTERVALS_S, useSlideshowSettings} from '../../hooks/useSlideshowSettings';
import {useWebOSKeys} from '../../hooks/useWebOSKeys';
import {getRotation} from '../../utils/rotationStore';
import {holdScreenSaver} from '../../utils/screenSaver';
import {remoteAction, type RemoteAction} from '../../immuch360/keys';
import {MediaInfo} from '../MediaInfo/MediaInfo';
import {RoundButton} from '../RoundButton';
import {createSpotlightContainer, forceFocus} from '../../utils/spotlight';
import {createSlideshowPlaylist, type SlideshowOrder, type SlideshowSource} from '../../domain/slideshow';
import type {TimelineAsset} from '../../domain/types';
import chrome from '../MediaChrome.module.less';
import css from './Slideshow.module.less';
import {t} from '../../immuch360/i18n';

interface SlideshowProps {
	start: TimelineAsset | null;
	source: SlideshowSource;
	onExit: (last: TimelineAsset | null) => void;
}

// Two stacked layers crossfade on opacity only (compositor work, cheap on TV GPUs).
interface Stage {
	slots: [TimelineAsset | null, TimelineAsset | null];
	front: 0 | 1;
	// Slot whose image is loading and becomes front once loaded.
	incoming: 0 | 1 | null;
}

const SLIDESHOW_SPOTLIGHT_ID = 'slideshow';
const PLAY_BUTTON_SPOTLIGHT_ID = 'slideshow-play';
const MAX_BROKEN_SKIPS = 5;
// Immuch360: Play, Pause and Play/Pause each pause or resume the slideshow, read through the key map of src/immuch360/
// keys.ts: LG's 415, 19 and 179 as before, and Samsung's 10252, the one Play/Pause key of its Smart Remote
const TOGGLES_SLIDESHOW: RemoteAction[] = ['play', 'pause', 'playPause'];

const Container = createSpotlightContainer({enterTo: 'default-element'});
const swallowKey = () => {};

// Decoding ahead of the swap keeps the crossfade from stuttering on the first frame.
function preload(url: string): Promise<void> {
	return new Promise((resolve, reject) => {
		const img = new Image();
		img.onload = () => (img.decode ? img.decode().then(resolve, resolve) : resolve());
		img.onerror = reject;
		img.src = url;
	});
}

interface SlideLayerProps {
	asset: TimelineAsset;
	slot: 0 | 1;
	isFront: boolean;
	onLoad: (slot: 0 | 1) => void;
}

const SlideLayer: React.FC<SlideLayerProps> = ({asset, slot, isFront, onLoad}) => {
	const repository = useRepository();
	const handleLoad = useCallback(() => onLoad(slot), [onLoad, slot]);
	const rotation = getRotation(asset.id);
	const className = [css.layer, isFront && css.front, rotation % 180 && css.quarterTurn].filter(Boolean).join(' ');
	return (
		<img
			src={repository.previewUrl(asset.id)}
			alt=""
			className={className}
			style={rotation ? {transform: `rotate(${rotation}deg)`} : undefined}
			onLoad={handleLoad}
		/>
	);
};

const formatInterval = (seconds: number) => (seconds < 60 ? `${seconds} s` : `${seconds / 60} min`);

export const Slideshow: React.FC<SlideshowProps> = ({start, source, onExit}) => {
	const repository = useRepository();
	const [settings, updateSettings] = useSlideshowSettings();
	const createPlaylist = useCallback(
		(order: SlideshowOrder, from: TimelineAsset | null) => createSlideshowPlaylist({order, start: from, repository, ...source}),
		[repository, source]
	);
	const [playlist, setPlaylist] = useState(() => createPlaylist(settings.order, start));
	const [stage, setStage] = useState<Stage>({slots: [null, null], front: 0, incoming: null});
	const [paused, setPaused] = useState(false);
	const [isEmpty, setIsEmpty] = useState(false);
	// Bumped after a failed advance so the dwell timer re-arms and retries.
	const [retryTick, setRetryTick] = useState(0);
	const generationRef = useRef(0);
	const hasShownRef = useRef(false);
	const current = stage.slots[stage.front];

	const osdRef = useRef<HTMLDivElement>(null);
	const {visible: osdVisible} = useAutoHideControls({enabled: true, controlsRef: osdRef});

	// Latest request wins: a slow load can't overwrite a newer one (e.g. rapid Right presses).
	const advance = useCallback(
		(pick: () => Promise<TimelineAsset | null> | TimelineAsset | null) => {
			const generation = ++generationRef.current;
			const loadNext = async () => {
				for (let skips = 0; skips <= MAX_BROKEN_SKIPS; skips++) {
					const asset = await (skips === 0 ? pick() : playlist.next());
					if (generation !== generationRef.current) return undefined;
					if (!asset) return null;
					try {
						await preload(repository.previewUrl(asset.id));
					} catch {
						continue;
					}
					return asset;
				}
				return undefined;
			};
			// Publish state from the load completion, including synchronous pick failures.
			return loadNext().then(
				(asset) => {
					if (generation !== generationRef.current || asset === undefined) return;
					if (!asset) {
						if (!hasShownRef.current) setIsEmpty(true);
						return;
					}
					hasShownRef.current = true;
					setStage((prev) => {
						if (prev.slots[prev.front]?.id === asset.id) return prev;
						const back = prev.front === 0 ? 1 : 0;
						// Same image already in the back slot: no load event will fire, flip now.
						if (prev.slots[back]?.id === asset.id) return {...prev, front: back, incoming: null};
						const slots: Stage['slots'] = [...prev.slots];
						slots[back] = asset;
						return {slots, front: prev.front, incoming: back};
					});
				},
				() => {
					if (generation === generationRef.current) setRetryTick((tick) => tick + 1);
				}
			);
		},
		[playlist, repository]
	);

	const handleLayerLoad = useCallback((slot: 0 | 1) => {
		setStage((prev) => (prev.incoming === slot ? {...prev, front: slot, incoming: null} : prev));
	}, []);

	useEffect(() => {
		void advance(() => playlist.next());
	}, [playlist, advance]);

	useEffect(() => {
		if (paused || stage.incoming !== null || (!current && !retryTick)) return undefined;
		playlist
			.peek()
			.then((next) => next && preload(repository.previewUrl(next.id)))
			.catch(() => {});
		const timer = window.setTimeout(() => void advance(() => playlist.next()), settings.intervalSeconds * 1000);
		return () => window.clearTimeout(timer);
	}, [current, paused, stage.incoming, settings.intervalSeconds, playlist, repository, advance, retryTick]);

	// Immuch360: on webOS no veto of the screen saver any more: appinfo.json asks for the Type 3 screen saver of gallery
	// apps (screenSaverProperties, useGalleryMode), which dims the screen after 30 minutes instead. A Samsung TV turns
	// its screen saver off through AppCommon while the slideshow plays (holdScreenSaver does nothing on webOS)
	useEffect(() => holdScreenSaver(), []);

	const handleExit = useCallback(() => onExit(current), [onExit, current]);
	const handleNext = useCallback(() => void advance(() => playlist.next()), [advance, playlist]);
	const handlePrevious = useCallback(() => void advance(() => playlist.previous()), [advance, playlist]);
	const togglePaused = useCallback(() => setPaused((value) => !value), []);

	const toggleOrder = useCallback(() => {
		const order = settings.order === 'shuffle' ? 'sequential' : 'shuffle';
		updateSettings({order});
		setPlaylist(createPlaylist(order, current));
	}, [settings.order, updateSettings, createPlaylist, current]);

	const cycleInterval = useCallback(() => {
		const index = SLIDESHOW_INTERVALS_S.indexOf(settings.intervalSeconds);
		updateSettings({intervalSeconds: SLIDESHOW_INTERVALS_S[(index + 1) % SLIDESHOW_INTERVALS_S.length]});
	}, [settings.intervalSeconds, updateSettings]);

	useWebOSKeys({
		onBack: handleExit,
		// Hidden OSD: left/right page photos. Visible: Spotlight moves between the OSD buttons.
		onArrowLeft: osdVisible ? undefined : handlePrevious,
		onArrowRight: osdVisible ? undefined : handleNext,
		onArrowUp: osdVisible ? swallowKey : undefined,
		onArrowDown: osdVisible ? swallowKey : undefined,
	});

	useEffect(() => {
		const handleKeyDown = (event: KeyboardEvent) => {
			const action = remoteAction(event);
			if (!action || TOGGLES_SLIDESHOW.indexOf(action) < 0) return;
			event.preventDefault();
			togglePaused();
		};
		window.addEventListener('keydown', handleKeyDown);
		return () => window.removeEventListener('keydown', handleKeyDown);
	}, [togglePaused]);

	useEffect(() => {
		if (osdVisible) forceFocus(PLAY_BUTTON_SPOTLIGHT_ID);
	}, [osdVisible]);

	useEffect(() => {
		Spotlight.focus(SLIDESHOW_SPOTLIGHT_ID);
	}, []);

	return (
		<Container spotlightId={SLIDESHOW_SPOTLIGHT_ID} spotlightRestrict="self-only" className={css.slideshow}>
			{stage.slots.map((asset, slot) =>
				asset ? <SlideLayer key={slot} asset={asset} slot={slot as 0 | 1} isFront={slot === stage.front} onLoad={handleLayerLoad} /> : null
			)}
			{isEmpty && <div className={css.message}>{t('webos_slideshow_empty')}</div>}
			<div ref={osdRef} className={osdVisible ? chrome.chrome : `${chrome.chrome} ${chrome.hidden}`}>
				<div className={chrome.topBar}>{current && <MediaInfo asset={current} />}</div>
				<div className={chrome.bottomBar}>
					<div className={chrome.actionBar}>
						<RoundButton
							icon={paused ? 'play' : 'pause'}
							tooltipText={paused ? t('play') : t('pause')}
							spotlightId={PLAY_BUTTON_SPOTLIGHT_ID}
							data-spotlight-default-element
							onClick={togglePaused}
						/>
						<RoundButton
							icon={settings.order === 'shuffle' ? 'shuffleon' : 'shuffle'}
							tooltipText={settings.order === 'shuffle' ? t('webos_shuffle_on') : t('webos_shuffle_off')}
							onClick={toggleOrder}
						/>
						<RoundButton tooltipText={t('webos_interval')} onClick={cycleInterval}>
							{formatInterval(settings.intervalSeconds)}
						</RoundButton>
						<RoundButton icon="closex" tooltipText={t('exit_slideshow')} onClick={handleExit} />
					</div>
				</div>
			</div>
		</Container>
	);
};

Slideshow.displayName = 'Slideshow';
