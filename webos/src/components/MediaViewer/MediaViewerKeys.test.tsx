// Immuch360: the keys of the viewer on a photo, with the real key hooks (useWebOSKeys, useAutoHideControls), so the
// order of their listeners is tested too. Discussion 8 (gthrepwood, 26 October 2026): Up zooms a flat photo in at once,
// zoomed in the arrows move it, Back zooms out, OK alone brings the controls; a 360° photo keeps the arrows.
import React from 'react';
import {act, fireEvent, render, screen} from '@testing-library/react';
import Spotlight from '@enact/spotlight';
import {RepositoryProvider} from '../../domain/RepositoryContext';
import type {PhotoRepository} from '../../domain/PhotoRepository';
import type {TimelineAsset} from '../../domain/types';
import {useAssetRotation} from '../../hooks/useAssetRotation';
import {resetVideoSession} from '../../immuch360/video/session';
import {MediaViewer} from './MediaViewer';

jest.mock('../../hooks/useAssetRotation', () => ({useAssetRotation: jest.fn()}));
jest.mock('../../hooks/useAssetDetails', () => ({useAssetDetails: () => null, useAssetDetailsQuery: () => ({details: null, settled: false})}));
const mockForceFocus = jest.fn();
jest.mock('../../utils/spotlight', () => ({
	forceFocus: (id: string) => mockForceFocus(id),
	SpottableDiv: ({className, onClick, spotlightId}: {className?: string; onClick?: () => void; spotlightId?: string}) => (
		<div className={className} onClick={onClick} data-spotlight-id={spotlightId} />
	),
	createSpotlightContainer: () => ({className, children}: {className?: string; children?: React.ReactNode}) => <div className={className}>{children}</div>,
}));
// The controls: whether they show, the buttons of the action bar, and the focus entering the bar
const mockBar: {focusChange: ((focused: boolean) => void) | null} = {focusChange: null};
jest.mock('./MediaControls', () => ({
	ACTION_BAR_SPOTLIGHT_ID: 'media-viewer-actions',
	MediaControls: ({
		controlsVisible,
		actions,
		onActionBarFocusChange,
	}: {
		controlsVisible: boolean;
		actions: {key: string; label: string; onClick: () => void}[];
		onActionBarFocusChange: (focused: boolean) => void;
	}) => {
		mockBar.focusChange = onActionBarFocusChange;
		return (
			<div data-testid="controls" data-visible={String(controlsVisible)}>
				{actions.map((action) => (
					<button key={action.key} type="button" onClick={action.onClick}>
						{action.label}
					</button>
				))}
			</div>
		);
	},
}));
jest.mock('./VideoPlayer', () => ({viewerVideoElement: () => null, VideoPlayer: () => <div data-testid="player" />}));
// The sphere takes the arrows itself (its own listener): here it draws nothing and listens to nothing
jest.mock('../../immuch360/sphere/SphereView', () => ({SphereView: jest.requireActual('react').forwardRef(() => null)}));
jest.mock('../../immuch360/details/AssetDetailsPanel', () => ({AssetDetailsPanel: () => null}));

const photo = (id: string): TimelineAsset => ({id, type: 'IMAGE', ratio: 1.5, localDateTime: '2026-10-26', durationSeconds: null});
const photo360: TimelineAsset = {id: 'p360', type: 'IMAGE', ratio: 2, localDateTime: '2026-10-26', durationSeconds: null, projectionType: 'EQUIRECTANGULAR'};
const video: TimelineAsset = {id: 'v', type: 'VIDEO', ratio: 16 / 9, localDateTime: '2026-10-26', durationSeconds: 12};
const repository = {
	previewUrl: (id: string) => `/preview/${id}`,
	fullsizeUrl: (id: string) => `/fullsize/${id}`,
	videoPlaybackUrl: (id: string) => `/video/${id}`,
	playsOriginal: () => Promise.resolve(false),
	serverTranscodes: true,
} as unknown as PhotoRepository;

const ZOOM_IN = 'media-viewer-zoom-in';
const STAGE = 'media-viewer-stage';
const KEYS = {
	ArrowLeft: 37,
	ArrowUp: 38,
	ArrowRight: 39,
	ArrowDown: 40,
	Enter: 13,
	GoBack: 461,
	PageUp: 33,
	PageDown: 34,
};
let onClose: jest.Mock;
let onNavigate: jest.Mock;
// Whether the pointer of the Magic Remote shows (Spotlight's pointer mode); off: the 5-way keys
let pointerMode: jest.SpyInstance;

// A photo between two others, so that Left and Right have somewhere to go
const mount = (middle: TimelineAsset = photo('b')) => {
	(useAssetRotation as jest.Mock).mockReturnValue({rotation: 0, rotate: jest.fn(), notice: null, phase: 'idle'});
	const items = [photo('a'), middle, photo('c')];
	return render(
		<RepositoryProvider repository={repository}>
			<MediaViewer
				getAssetAt={(index) => items[index] ?? null}
				totalCount={3}
				currentIndex={1}
				position="2 / 3"
				onClose={onClose}
				onNavigate={onNavigate}
				onStartSlideshow={() => {}}
			/>
		</RepositoryProvider>
	);
};
const wait = (ms: number) =>
	act(() => {
		jest.advanceTimersByTime(ms);
	});
/** Presses a key of the remote; true when the viewer took it (its default prevented, Spotlight never sees it) */
const press = (key: keyof typeof KEYS): boolean => !fireEvent.keyDown(window, {key, keyCode: KEYS[key]});
/** The repeats of a key held down */
const hold = (key: keyof typeof KEYS, repeats: number) => {
	for (let i = 0; i < repeats; i++) fireEvent.keyDown(window, {key, keyCode: KEYS[key], repeat: true});
};
const image = () => screen.getByRole('presentation') as HTMLImageElement;
/** The photo on screen, as a load and two frames put it there (jsdom has no decode()) */
const paint = () => {
	fireEvent.load(image());
	wait(50);
};
const transform = () => (image().parentElement as HTMLElement).style.transform;
const controlsShown = () => screen.getByTestId('controls').dataset.visible === 'true';
/** The controls fade out 5 s after they showed */
const hideControls = () => {
	wait(5000);
	expect(controlsShown()).toBe(false);
};
const stage = () => document.querySelector(`[data-spotlight-id="${STAGE}"]`) as HTMLElement;

beforeEach(() => {
	jest.useFakeTimers();
	onClose = jest.fn();
	onNavigate = jest.fn();
	mockBar.focusChange = null;
	resetVideoSession();
	pointerMode = jest.spyOn(Spotlight, 'getPointerMode').mockReturnValue(false);
});
afterEach(() => {
	pointerMode.mockRestore();
	jest.useRealTimers();
});

describe('a flat photo', () => {
	test('Up zooms in at once, controls hidden or shown, and never brings them', () => {
		mount();
		paint();
		expect(controlsShown()).toBe(true);
		expect(press('ArrowUp')).toBe(true);
		expect(transform()).toBe('scale(1.25) translate(0%, 0%)');
		expect(press('GoBack')).toBe(true);
		expect(transform()).toBe('');
		hideControls();
		expect(press('ArrowUp')).toBe(true);
		expect(transform()).toBe('scale(1.25) translate(0%, 0%)');
		expect(controlsShown()).toBe(false);
		expect(onNavigate).not.toHaveBeenCalled();
		expect(screen.getByText('125%')).toBeTruthy();
	});

	test('Down at 1x has nothing to zoom out: the level says 100% for 1.5 s, nothing else moves', () => {
		mount();
		paint();
		hideControls();
		expect(press('ArrowDown')).toBe(true);
		expect(transform()).toBe('');
		expect(controlsShown()).toBe(false);
		expect(onNavigate).not.toHaveBeenCalled();
		expect(mockForceFocus).not.toHaveBeenCalledWith('media-viewer-actions');
		expect(screen.getByText('100%')).toBeTruthy();
		wait(1499);
		expect(screen.getByText('100%')).toBeTruthy();
		wait(1);
		expect(screen.queryByText('100%')).toBeNull();
	});

	test('each zoom key shows the level for 1.5 s from that press', () => {
		mount();
		paint();
		press('ArrowUp');
		// Zoomed in, the arrows move the photo; the channel keys zoom further
		press('PageUp');
		expect(transform()).toMatch(/^scale\(1\.5625\)/);
		expect(screen.getByText('156%')).toBeTruthy();
		wait(1000);
		press('PageDown');
		expect(transform()).toMatch(/^scale\(1\.25\)/);
		wait(1000);
		// 1.5 s from the last press, not from the first
		expect(screen.getByText('125%')).toBeTruthy();
		wait(500);
		expect(screen.queryByText('125%')).toBeNull();
	});

	test('zoomed in, the four arrows move the photo: never to a neighbour, never a zoom', () => {
		mount();
		paint();
		press('ArrowUp');
		const seen = [transform()];
		for (const key of ['ArrowRight', 'ArrowDown', 'ArrowLeft', 'ArrowUp'] as const) {
			expect(press(key)).toBe(true);
			const now = transform();
			expect(now).toMatch(/^scale\(1\.25\) translate\(/);
			expect(now).not.toBe(seen[seen.length - 1]);
			seen.push(now);
		}
		// Right then Left, Down then Up: back where it started
		expect(seen[seen.length - 1]).toBe(seen[0]);
		expect(onNavigate).not.toHaveBeenCalled();
	});

	test('Up held down zooms once: its repeats neither zoom further nor move the photo; a new press moves it', () => {
		mount();
		paint();
		expect(press('ArrowUp')).toBe(true);
		hold('ArrowUp', 5);
		expect(transform()).toBe('scale(1.25) translate(0%, 0%)');
		expect(onNavigate).not.toHaveBeenCalled();
		// Released, then pressed again: zoomed in, it moves the photo
		expect(press('ArrowUp')).toBe(true);
		expect(transform()).toMatch(/^scale\(1\.25\) translate\(0%, [1-9]/);
		// A held arrow that did not zoom still moves the photo at each repeat, up to its edge
		press('ArrowDown');
		const once = transform();
		hold('ArrowDown', 1);
		expect(transform()).not.toBe(once);
	});

	test('Down held down at 1x: the level only, never a neighbour', () => {
		mount();
		paint();
		expect(press('ArrowDown')).toBe(true);
		hold('ArrowDown', 5);
		expect(transform()).toBe('');
		expect(screen.getByText('100%')).toBeTruthy();
		expect(onNavigate).not.toHaveBeenCalled();
	});

	test('not zoomed, Left and Right still go to the previous and next item', () => {
		mount();
		paint();
		expect(press('ArrowLeft')).toBe(true);
		expect(press('ArrowRight')).toBe(true);
		expect(onNavigate.mock.calls).toEqual([['prev'], ['next']]);
		expect(transform()).toBe('');
	});

	test('Back leaves the zoom, a second Back closes the viewer', () => {
		mount();
		paint();
		press('ArrowUp');
		press('ArrowUp');
		expect(transform()).not.toBe('');
		press('GoBack');
		expect(transform()).toBe('');
		expect(onClose).not.toHaveBeenCalled();
		press('GoBack');
		expect(onClose).toHaveBeenCalledTimes(1);
	});

	test('OK alone brings the controls; OK on the photo shows them with Zoom in focused, and never hides them', () => {
		mount();
		paint();
		hideControls();
		press('ArrowDown');
		press('ArrowUp');
		expect(controlsShown()).toBe(false);
		mockForceFocus.mockClear();
		// Hidden: the first OK only brings them (useAutoHideControls takes it)
		expect(press('Enter')).toBe(true);
		expect(controlsShown()).toBe(true);
		expect(mockForceFocus).not.toHaveBeenCalled();
		// Shown: OK reaches the photo (Spotlight clicks it), the focus goes to Zoom in
		fireEvent.click(stage());
		expect(mockForceFocus).toHaveBeenCalledWith(ZOOM_IN);
		expect(controlsShown()).toBe(true);
		fireEvent.click(stage());
		expect(controlsShown()).toBe(true);
		// They still go 5 s after the last key
		hideControls();
	});

	test('a click of the Magic Remote on the photo shows or hides the controls and leaves the pointer alone', () => {
		mount();
		paint();
		pointerMode.mockReturnValue(true);
		mockForceFocus.mockClear();
		expect(controlsShown()).toBe(true);
		fireEvent.click(stage());
		expect(controlsShown()).toBe(false);
		fireEvent.click(stage());
		expect(controlsShown()).toBe(true);
		fireEvent.click(stage());
		expect(controlsShown()).toBe(false);
		// forceFocus would leave pointer mode and put the focus ring on Zoom in
		expect(mockForceFocus).not.toHaveBeenCalled();
	});

	test('the controls go 5 s after OK: the zoom keys pressed meanwhile do not keep them', () => {
		mount();
		paint();
		hideControls();
		press('Enter');
		expect(controlsShown()).toBe(true);
		wait(4000);
		press('ArrowUp');
		press('ArrowDown');
		expect(controlsShown()).toBe(true);
		wait(1000);
		expect(controlsShown()).toBe(false);
	});

	test('a photo that did not load has nothing to zoom: Left and Right go on, Back closes', () => {
		mount();
		// Up while the photo comes zooms it; then it fails
		press('ArrowUp');
		expect(transform()).toBe('scale(1.25) translate(0%, 0%)');
		fireEvent.error(image());
		expect(screen.getByRole('alert').textContent).toBe('Error loading image');
		// No level over the message, and the zoom keys and buttons zoom nothing
		expect(screen.queryByRole('status')).toBeNull();
		for (const key of ['ArrowUp', 'ArrowDown', 'PageUp', 'PageDown'] as const) expect(press(key)).toBe(true);
		fireEvent.click(screen.getByRole('button', {name: 'Zoom in'}));
		expect(screen.queryByRole('status')).toBeNull();
		expect(press('ArrowLeft')).toBe(true);
		expect(press('ArrowRight')).toBe(true);
		expect(onNavigate.mock.calls).toEqual([['prev'], ['next']]);
		expect(press('GoBack')).toBe(true);
		expect(onClose).toHaveBeenCalledTimes(1);
	});

	test('the channel keys and the zoom buttons still zoom, with the level', () => {
		mount();
		paint();
		press('PageUp');
		expect(transform()).toBe('scale(1.25) translate(0%, 0%)');
		expect(screen.getByText('125%')).toBeTruthy();
		press('PageDown');
		expect(transform()).toBe('');
		expect(screen.getByText('100%')).toBeTruthy();
		fireEvent.click(screen.getByRole('button', {name: 'Zoom in'}));
		expect(transform()).toBe('scale(1.25) translate(0%, 0%)');
		expect(screen.getByText('125%')).toBeTruthy();
		fireEvent.click(screen.getByRole('button', {name: 'Zoom out'}));
		expect(transform()).toBe('');
	});

	test('in the controls bar: Up goes back to the photo, Left and Right move along the bar, Down stays', () => {
		mount();
		paint();
		act(() => mockBar.focusChange?.(true));
		mockForceFocus.mockClear();
		expect(press('ArrowLeft')).toBe(false);
		expect(press('ArrowRight')).toBe(false);
		expect(onNavigate).not.toHaveBeenCalled();
		expect(press('ArrowDown')).toBe(true);
		expect(press('ArrowUp')).toBe(true);
		expect(mockForceFocus).toHaveBeenCalledWith(STAGE);
		expect(transform()).toBe('');
		expect(screen.queryByText('100%')).toBeNull();
	});

	test('a new photo opens at 1x, without the level of the last one', () => {
		const {rerender} = mount();
		paint();
		press('ArrowUp');
		expect(screen.getByText('125%')).toBeTruthy();
		const items = [photo('a'), photo('b'), photo('c'), photo('d')];
		rerender(
			<RepositoryProvider repository={repository}>
				<MediaViewer
					getAssetAt={(index) => items[index] ?? null}
					totalCount={4}
					currentIndex={2}
					position="3 / 4"
					onClose={onClose}
					onNavigate={onNavigate}
					onStartSlideshow={() => {}}
				/>
			</RepositoryProvider>
		);
		expect(image().getAttribute('src')).toBe('/preview/c');
		expect(transform()).toBe('');
		// No zoom level at all, not even 100%, until a zoom key is pressed on it
		expect(screen.queryByRole('status')).toBeNull();
		wait(299);
		expect(screen.queryByRole('status')).toBeNull();
	});
});

describe('other items keep their keys', () => {
	test('a 360° photo: the arrows stay with the sphere, OK brings the controls and focuses Zoom in', () => {
		mount(photo360);
		expect(screen.queryByRole('presentation')).toBeNull();
		hideControls();
		// Not taken by the viewer: SphereView turns the view with them
		expect(press('ArrowUp')).toBe(false);
		expect(press('ArrowDown')).toBe(false);
		expect(press('ArrowLeft')).toBe(false);
		expect(controlsShown()).toBe(false);
		expect(onNavigate).not.toHaveBeenCalled();
		expect(press('Enter')).toBe(true);
		expect(controlsShown()).toBe(true);
		fireEvent.click(stage());
		expect(mockForceFocus).toHaveBeenCalledWith(ZOOM_IN);
		// The pointer of the Magic Remote too, as before: the controls with Zoom in focused
		pointerMode.mockReturnValue(true);
		mockForceFocus.mockClear();
		fireEvent.click(stage());
		expect(controlsShown()).toBe(true);
		expect(mockForceFocus).toHaveBeenCalledWith(ZOOM_IN);
		expect(screen.queryByText('125%')).toBeNull();
	});

	test('a video: Up is still swallowed, nothing zooms', () => {
		mount(video);
		expect(screen.getByTestId('player')).toBeTruthy();
		expect(press('ArrowUp')).toBe(true);
		expect(press('PageUp')).toBe(false);
		expect(screen.queryByText('125%')).toBeNull();
		expect(screen.queryByRole('presentation')).toBeNull();
	});
});
