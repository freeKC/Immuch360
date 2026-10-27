// Immuch360: the loading pill of the viewer (viewerStatus.ts, usePhotoLoading.ts). Discussion 8 (gthrepwood, 26 October
// 2026): a dark photo looked like a blank screen; "Loading…" shows when the picture is not on screen 300 ms after it was
// asked for, and goes at its first paint. jsdom decodes no image: the load event stands for the bytes, decode() is
// mocked where it is tested, and the frames are those of the fake timers.
import React from 'react';
import {act, fireEvent, render, screen} from '@testing-library/react';
import {RepositoryProvider} from '../../domain/RepositoryContext';
import type {PhotoRepository} from '../../domain/PhotoRepository';
import type {TimelineAsset} from '../../domain/types';
import {useAssetRotation} from '../../hooks/useAssetRotation';
import {MediaViewer} from './MediaViewer';

jest.mock('../../hooks/useAssetRotation', () => ({useAssetRotation: jest.fn()}));
let mockDetails: {details: Record<string, unknown> | null; settled: boolean} = {details: null, settled: false};
jest.mock('../../hooks/useAssetDetails', () => ({useAssetDetails: () => mockDetails.details, useAssetDetailsQuery: () => mockDetails}));
let mockOnline = true;
jest.mock('../../hooks/useOnline', () => ({useOnline: () => mockOnline}));
jest.mock('../../utils/spotlight', () => ({
	forceFocus: () => {},
	SpottableDiv: ({className}: {className?: string}) => <div className={className} />,
	createSpotlightContainer: () => ({className, children}: {className?: string; children?: React.ReactNode}) => <div className={className}>{children}</div>,
}));
jest.mock('./MediaControls', () => ({ACTION_BAR_SPOTLIGHT_ID: 'media-viewer-actions', MediaControls: () => null}));
jest.mock('./VideoPlayer', () => ({viewerVideoElement: () => null, VideoPlayer: () => null}));
jest.mock('../../immuch360/sphere/SphereView', () => ({SphereView: jest.requireActual('react').forwardRef(() => null)}));
jest.mock('../../immuch360/details/AssetDetailsPanel', () => ({AssetDetailsPanel: () => null}));

const photo = (id: string): TimelineAsset => ({id, type: 'IMAGE', ratio: 1.5, localDateTime: '2026-10-26', durationSeconds: null});
const items = [photo('a'), photo('b'), photo('c')];
const repository = {
	previewUrl: (id: string) => `/preview/${id}`,
	fullsizeUrl: (id: string) => `/fullsize/${id}`,
	videoPlaybackUrl: (id: string) => `/video/${id}`,
} as unknown as PhotoRepository;
let onNavigate: jest.Mock;

const viewer = (currentIndex: number) => (
	<RepositoryProvider repository={repository}>
		<MediaViewer
			getAssetAt={(index) => items[index] ?? null}
			totalCount={items.length}
			currentIndex={currentIndex}
			position={`${currentIndex + 1} / ${items.length}`}
			onClose={() => {}}
			onNavigate={onNavigate}
			onStartSlideshow={() => {}}
		/>
	</RepositoryProvider>
);
const mount = (currentIndex = 0) => {
	(useAssetRotation as jest.Mock).mockReturnValue({rotation: 0, rotate: jest.fn(), notice: null, phase: 'idle'});
	return render(viewer(currentIndex));
};
const wait = (ms: number) =>
	act(() => {
		jest.advanceTimersByTime(ms);
	});
const image = () => screen.getByRole('presentation') as HTMLImageElement;
const pill = () => screen.queryByText('Loading…');
// Two frames of the fake timers: enough for the paint that follows a load
const FRAMES_MS = 50;

beforeEach(() => {
	jest.useFakeTimers();
	mockDetails = {details: null, settled: false};
	mockOnline = true;
	onNavigate = jest.fn();
});
afterEach(() => {
	jest.useRealTimers();
});

test('nothing for 299 ms, then "Loading…" in the middle of the screen until the photo is painted', () => {
	mount();
	wait(299);
	expect(pill()).toBeNull();
	wait(1);
	const status = screen.getByRole('status');
	expect(status.textContent).toBe('Loading…');
	expect(status.getAttribute('aria-live')).toBe('polite');
	// The bytes are in: the pill stays until the frame that paints them (jsdom has no decode(), as webOS 4)
	fireEvent.load(image());
	expect(pill()).not.toBeNull();
	wait(FRAMES_MS);
	expect(pill()).toBeNull();
	expect(screen.queryByRole('alert')).toBeNull();
});

test('a photo painted within 300 ms never shows the pill', () => {
	mount();
	wait(100);
	fireEvent.load(image());
	wait(FRAMES_MS);
	wait(300 - 100 - FRAMES_MS);
	expect(pill()).toBeNull();
	wait(1000);
	expect(pill()).toBeNull();
});

describe('where the engine has decode() (Chromium 64, webOS 5 and later)', () => {
	const original = Object.getOwnPropertyDescriptor(HTMLImageElement.prototype, 'decode');
	const withDecode = (decode: () => Promise<void>) => Object.defineProperty(HTMLImageElement.prototype, 'decode', {value: decode, configurable: true});
	const flush = () =>
		act(async () => {
			await Promise.resolve();
			await Promise.resolve();
		});
	afterEach(() => {
		if (original) Object.defineProperty(HTMLImageElement.prototype, 'decode', original);
		else delete (HTMLImageElement.prototype as {decode?: unknown}).decode;
	});

	test('the pill goes once the picture is decoded and a frame painted it', async () => {
		let decoded: () => void = () => {};
		const decode = jest.fn(() => new Promise<void>((resolve) => (decoded = resolve)));
		withDecode(decode);
		mount();
		wait(300);
		fireEvent.load(image());
		expect(decode).toHaveBeenCalledTimes(1);
		wait(FRAMES_MS);
		// Still decoding
		expect(pill()).not.toBeNull();
		decoded();
		await flush();
		expect(pill()).not.toBeNull();
		wait(FRAMES_MS);
		expect(pill()).toBeNull();
	});

	test('a decode that fails still ends the wait (the picture is what the engine shows)', async () => {
		withDecode(jest.fn(() => Promise.reject(new Error('EncodingError'))));
		mount();
		wait(300);
		fireEvent.load(image());
		await flush();
		wait(FRAMES_MS);
		expect(pill()).toBeNull();
	});
});

test('a preview that fails: the pill goes, "Error loading image" in its place; Left and Right still go on', () => {
	mount(1);
	wait(300);
	expect(pill()).not.toBeNull();
	fireEvent.error(image());
	expect(pill()).toBeNull();
	expect(screen.getByRole('alert').textContent).toBe('Error loading image');
	expect(screen.queryByRole('presentation')).toBeNull();
	wait(1000);
	expect(pill()).toBeNull();
	fireEvent.keyDown(window, {key: 'ArrowRight', keyCode: 39});
	fireEvent.keyDown(window, {key: 'ArrowLeft', keyCode: 37});
	expect(onNavigate.mock.calls).toEqual([['next'], ['prev']]);
});

test('offline, the failed preview says the TV has no network', () => {
	mockOnline = false;
	mount();
	fireEvent.error(image());
	expect(screen.getByRole('alert').textContent).toBe('This TV has no network connection. Check the network settings of the TV, then try again.');
	expect(pill()).toBeNull();
});

describe('past 2x, the full-size picture', () => {
	beforeEach(() => {
		// 12 MP: within what a TV is asked to decode (photoSize.ts)
		mockDetails = {details: {id: 'a', type: 'IMAGE', width: 4000, height: 3000}, settled: true};
	});
	const zoomPast2x = () => {
		for (let i = 0; i < 4; i++) fireEvent.keyDown(window, {key: 'PageUp', keyCode: 33});
	};

	test('the preview stays on screen under the pill until the full-size picture is painted', () => {
		mount();
		const img = image();
		fireEvent.load(img);
		wait(FRAMES_MS);
		zoomPast2x();
		// The same element, its address changed: the engine keeps painting the preview meanwhile
		expect(image()).toBe(img);
		expect(img.getAttribute('src')).toBe('/fullsize/a');
		wait(299);
		expect(pill()).toBeNull();
		wait(1);
		expect(pill()).not.toBeNull();
		fireEvent.load(img);
		wait(FRAMES_MS);
		expect(pill()).toBeNull();
	});

	test('a full-size picture that fails gives way to the preview, without a message, and is not asked again', () => {
		mount();
		fireEvent.load(image());
		wait(FRAMES_MS);
		zoomPast2x();
		wait(300);
		expect(pill()).not.toBeNull();
		fireEvent.error(image());
		expect(image().getAttribute('src')).toBe('/preview/a');
		expect(screen.queryByRole('alert')).toBeNull();
		// The preview is in the cache of the engine: it comes at once
		fireEvent.load(image());
		wait(FRAMES_MS);
		expect(pill()).toBeNull();
		wait(1000);
		expect(pill()).toBeNull();
		fireEvent.keyDown(window, {key: 'PageUp', keyCode: 33});
		expect(image().getAttribute('src')).toBe('/preview/a');
	});
});

test('another photo: a wait of its own, its pill after 300 ms', () => {
	const {rerender} = mount(0);
	fireEvent.load(image());
	wait(FRAMES_MS);
	expect(pill()).toBeNull();
	rerender(viewer(1));
	expect(image().getAttribute('src')).toBe('/preview/b');
	wait(299);
	expect(pill()).toBeNull();
	wait(1);
	expect(pill()).not.toBeNull();
	// On to the next one before this one came: a new wait, no pill for its first 300 ms
	rerender(viewer(2));
	expect(image().getAttribute('src')).toBe('/preview/c');
	expect(pill()).toBeNull();
	wait(300);
	expect(pill()).not.toBeNull();
	fireEvent.load(image());
	wait(FRAMES_MS);
	expect(pill()).toBeNull();
});

test('a video and a 360° photo show no pill', () => {
	(useAssetRotation as jest.Mock).mockReturnValue({rotation: 0, rotate: jest.fn(), notice: null, phase: 'idle'});
	const others: TimelineAsset[] = [
		{id: 'v', type: 'VIDEO', ratio: 16 / 9, localDateTime: '2026-10-26', durationSeconds: 12},
		{id: 'p', type: 'IMAGE', ratio: 2, localDateTime: '2026-10-26', durationSeconds: null, projectionType: 'EQUIRECTANGULAR'},
	];
	for (const asset of others) {
		const {unmount} = render(
			<RepositoryProvider repository={{...repository, playsOriginal: () => Promise.resolve(false)} as unknown as PhotoRepository}>
				<MediaViewer getAssetAt={() => asset} totalCount={1} currentIndex={0} position="1 / 1" onClose={() => {}} onNavigate={() => {}} onStartSlideshow={() => {}} />
			</RepositoryProvider>
		);
		wait(1000);
		expect(pill()).toBeNull();
		unmount();
	}
});
