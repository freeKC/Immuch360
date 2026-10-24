// Immuch360: the viewer while a turn of the yellow or blue key is saved: it shows that it works, over the photo
// already turned, and the keys go on as before (more presses, Back). And the videos a TV may not play: past its
// decoders, never started, 360° on a TV that keeps video frames out of WebGL.
import React from 'react';
import {act, fireEvent, render, screen} from '@testing-library/react';
import {RepositoryProvider} from '../../domain/RepositoryContext';
import type {PhotoRepository} from '../../domain/PhotoRepository';
import type {TimelineAsset} from '../../domain/types';
import {useAssetRotation, type AssetRotation} from '../../hooks/useAssetRotation';
import {useWebOSKeys} from '../../hooks/useWebOSKeys';
import {MediaViewer} from './MediaViewer';
import {DECODER_PROBES, askDecoders, type DecoderRecord} from '../../immuch360/video/decoders';
import {recordVideoFrames, resetVideoSession, setKnownDecoders} from '../../immuch360/video/session';

jest.mock('../../hooks/useAssetRotation', () => ({useAssetRotation: jest.fn()}));
jest.mock('../../hooks/useWebOSKeys', () => ({useWebOSKeys: jest.fn()}));
jest.mock('../../hooks/useAutoHideControls', () => ({useAutoHideControls: () => ({visible: false, show: () => {}, hide: () => {}})}));
let mockDetails: {details: Record<string, unknown> | null; settled: boolean} = {details: null, settled: false};
jest.mock('../../hooks/useAssetDetails', () => ({useAssetDetails: () => mockDetails.details, useAssetDetailsQuery: () => mockDetails}));
jest.mock('../../utils/spotlight', () => ({
	forceFocus: () => {},
	SpottableDiv: ({className}: {className?: string}) => <div className={className} />,
	createSpotlightContainer: () => ({className, children}: {className?: string; children?: React.ReactNode}) => <div className={className}>{children}</div>,
}));
jest.mock('./MediaControls', () => ({
	ACTION_BAR_SPOTLIGHT_ID: 'media-viewer-actions',
	MediaControls: ({notice}: {notice?: string}) => (notice ? <p data-testid="notice">{notice}</p> : null),
}));
// The player hands the viewer an API whose video never gets going, as the S90C did with an 8K video
const mockPlayerApi = {getMediaState: () => ({currentTime: 0, paused: true}), getVideoNode: () => ({error: null}), pause: jest.fn(), areControlsVisible: () => false};
jest.mock('./VideoPlayer', () => {
	const {useEffect} = jest.requireActual('react');
	return {
		viewerVideoElement: () => null,
		VideoPlayer: ({apiRef}: {apiRef: {current: unknown}}) => {
			useEffect(() => {
				apiRef.current = mockPlayerApi;
				return () => {
					apiRef.current = null;
				};
			}, [apiRef]);
			return <div data-testid="player" />;
		},
	};
});
jest.mock('../../immuch360/sphere/SphereView', () => ({SphereView: () => null}));
jest.mock('../../immuch360/details/AssetDetailsPanel', () => ({AssetDetailsPanel: () => null}));

const photo: TimelineAsset = {id: 'a', type: 'IMAGE', ratio: 1.5, localDateTime: '2026-10-22', durationSeconds: null};
let playsOriginal: jest.Mock;
const repository = {
	previewUrl: (id: string) => `/preview/${id}`,
	fullsizeUrl: (id: string) => `/fullsize/${id}`,
	videoPlaybackUrl: (id: string) => `/video/${id}`,
	playsOriginal: (...args: unknown[]) => playsOriginal(...args),
} as unknown as PhotoRepository;
let rotate: jest.Mock;
let onClose: jest.Mock;

const mount = (state: Partial<AssetRotation>, asset: TimelineAsset = photo) => {
	(useAssetRotation as jest.Mock).mockReturnValue({rotation: 0, rotate, notice: null, phase: 'idle', ...state});
	return render(
		<RepositoryProvider repository={repository}>
			<MediaViewer
				getAssetAt={() => asset}
				totalCount={1}
				currentIndex={0}
				position="1 / 1"
				onClose={onClose}
				onNavigate={() => {}}
				onStartSlideshow={() => {}}
			/>
		</RepositoryProvider>
	);
};
const lastKeys = () => (useWebOSKeys as jest.Mock).mock.calls[(useWebOSKeys as jest.Mock).mock.calls.length - 1][0];

beforeEach(() => {
	localStorage.clear();
	rotate = jest.fn();
	onClose = jest.fn();
	playsOriginal = jest.fn(() => Promise.resolve(true));
	mockDetails = {details: null, settled: false};
	mockPlayerApi.pause.mockClear();
	resetVideoSession();
	(useWebOSKeys as jest.Mock).mockReset();
});

test('while a turn is saved, the photo already turned shows that it works, and more presses still turn it', () => {
	mount({rotation: 90, phase: 'turning'});
	expect(screen.getByRole('status').textContent).toBe('Saving the rotation');
	// The photo, an image without a text (alt=""), turned at once
	expect(screen.getByRole('presentation').style.transform).toBe('rotate(90deg)');
	fireEvent.keyDown(window, {keyCode: 405});
	fireEvent.keyDown(window, {keyCode: 406});
	expect(rotate.mock.calls).toEqual([[1], [-1]]);
});

test('Back still leaves the viewer while a turn is saved', () => {
	mount({phase: 'turning'});
	lastKeys().onBack();
	expect(onClose).toHaveBeenCalled();
});

test('no indicator once the turned picture is shown', () => {
	mount({phase: 'shown'});
	expect(screen.queryByRole('status')).toBeNull();
});

test('the notice replaces the indicator when the turn stays on the TV or was not saved', () => {
	mount({phase: 'notice', notice: 'keptOnDevice', rotation: 90});
	expect(screen.queryByRole('status')).toBeNull();
	expect(screen.getByTestId('notice').textContent).toBe('The rotation is kept on this device only');
});

// Immuch360: the videos a TV may not play
const WIDTHS: Record<number, string> = {3840: '4K', 5760: '5.7K'};
function decoderRecord(takes: (size: string) => boolean): Promise<DecoderRecord> {
	return askDecoders({
		canPlayType: () => 'probably',
		isTypeSupported: () => true,
		decodingInfo: async (config) => {
			const ok = takes(WIDTHS[(config as {video: {width: number}}).video.width]!);
			return {supported: ok, smooth: ok, powerEfficient: ok};
		},
	});
}
const samsungS90C = () => decoderRecord((size) => size === '4K');
const lg50Nano = () => decoderRecord(() => true);
const video8k: TimelineAsset = {id: 'v8', type: 'VIDEO', ratio: 2, localDateTime: '2026-10-24', durationSeconds: 30, projectionType: 'EQUIRECTANGULAR'};
const details8k = {details: {id: 'v8', type: 'VIDEO', originalMimeType: 'video/mp4', width: 7680, height: 3840, fileSize: 734003200}, settled: true};

describe('a video past the decoders of the TV', () => {
	test('Samsung S90C: the 8K original does not start; the message says the limit and the size, Back closes', async () => {
		expect(DECODER_PROBES).toHaveLength(7);
		setKnownDecoders(await samsungS90C());
		mockDetails = details8k;
		mount({}, video8k);
		const message = await screen.findByRole('alert');
		expect(message.textContent).toContain('This TV cannot decode videos above 4K (this one is 7680 x 3840).');
		expect(screen.queryByTestId('player')).toBeNull();
		expect(playsOriginal).toHaveBeenCalledWith('v8', 734003200);
		// No notice about flat 360° videos over a video that does not play
		expect(screen.queryByTestId('notice')).toBeNull();
		fireEvent.click(screen.getByRole('button', {name: 'Back'}));
		expect(onClose).toHaveBeenCalled();
		lastKeys().onBack();
		expect(onClose).toHaveBeenCalledTimes(2);
	});

	test('Samsung S90C: the server plays its transcode of the 8K original, so the video plays', async () => {
		setKnownDecoders(await samsungS90C());
		mockDetails = details8k;
		playsOriginal = jest.fn(() => Promise.resolve(false));
		mount({}, video8k);
		expect(await screen.findByTestId('player')).toBeTruthy();
		expect(screen.queryByRole('alert')).toBeNull();
	});

	test('Samsung S90C: nothing plays while the size is not known, for at most 4 s', async () => {
		jest.useFakeTimers();
		try {
			setKnownDecoders(await samsungS90C());
			mount({}, video8k);
			expect(screen.queryByTestId('player')).toBeNull();
			act(() => {
				jest.advanceTimersByTime(4000);
			});
			expect(screen.getByTestId('player')).toBeTruthy();
		} finally {
			jest.useRealTimers();
		}
	});

	test('LG 50NANO763QA, which takes 5.7K: the 8K video plays at once, the server is not asked', async () => {
		setKnownDecoders(await lg50Nano());
		mockDetails = details8k;
		mount({}, video8k);
		expect(screen.getByTestId('player')).toBeTruthy();
		expect(playsOriginal).not.toHaveBeenCalled();
	});
});

describe('a video that never gets going', () => {
	test('20 s without canplay: the player closes and the message says the TV could not start it', () => {
		jest.useFakeTimers();
		try {
			mockDetails = details8k;
			mount({}, video8k);
			expect(screen.getByTestId('player')).toBeTruthy();
			act(() => {
				jest.advanceTimersByTime(19000);
			});
			expect(screen.queryByRole('alert')).toBeNull();
			act(() => {
				jest.advanceTimersByTime(1000);
			});
			expect(screen.getByRole('alert').textContent).toContain('The TV could not start this video (video/mp4, 7680 × 3840).');
			expect(screen.queryByTestId('player')).toBeNull();
			expect(mockPlayerApi.pause).toHaveBeenCalled();
		} finally {
			jest.useRealTimers();
		}
	});
});

describe('360° videos, which play flat', () => {
	const other: TimelineAsset = {...video8k, id: 'v2'};

	test('where the TV gives black frames to WebGL, the first one of the session says why, the next one nothing', () => {
		recordVideoFrames('black');
		const {unmount} = mount({}, video8k);
		expect(screen.getByTestId('notice').textContent).toBe('360° videos play flat on this TV: its browser does not hand video frames to the 3D view.');
		expect(screen.getByTestId('player')).toBeTruthy();
		unmount();
		mount({}, other);
		expect(screen.queryByTestId('notice')).toBeNull();
		expect(screen.getByTestId('player')).toBeTruthy();
	});

	test('where the frames reach WebGL, or the test did not run (LG), each one says it plays flat, as before', () => {
		const {unmount} = mount({}, video8k);
		expect(screen.getByTestId('notice').textContent).toBe('This TV cannot show the 360° view of this video yet: it plays flat.');
		unmount();
		recordVideoFrames('yes');
		mount({}, other);
		expect(screen.getByTestId('notice').textContent).toBe('This TV cannot show the 360° view of this video yet: it plays flat.');
	});
});
