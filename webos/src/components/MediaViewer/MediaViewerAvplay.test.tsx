// Immuch360: which player the viewer gives a video (issue 17). On a Samsung TV with AVPlay, a video that needs a turn
// (orientation 6 or 8, or a turn chosen by hand) plays through AVPlay; "Turn the picture" on a video in the HTML element
// moves it to AVPlay at the time it reached; a failure of AVPlay moves it back. An LG TV and a browser never use it.
import React from 'react';
import {act, fireEvent, render, screen} from '@testing-library/react';
import {RepositoryProvider} from '../../domain/RepositoryContext';
import type {PhotoRepository} from '../../domain/PhotoRepository';
import type {TimelineAsset} from '../../domain/types';
import {useAssetRotation} from '../../hooks/useAssetRotation';
import {MediaViewer} from './MediaViewer';
import {resetVideoSession} from '../../immuch360/video/session';
import {avplayUsable, chooseVideoEngine, noteAvplayFailure, resetAvplayEngine} from '../../immuch360/video/avplayEngine';
import {fakeAvplay} from '../../immuch360/video/fakeAvplay';

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
	MediaControls: ({notice, actions}: {notice?: string; actions: {key: string; label: string; onClick: () => void}[]}) => (
		<div>
			{notice ? <p data-testid="notice">{notice}</p> : null}
			{actions.map((action) => (
				<button key={action.key} type="button" onClick={action.onClick}>
					{action.label}
				</button>
			))}
		</div>
	),
}));
// The player: what the viewer gives it, and an API whose video is at 7 s
type PlayerProps = {engine: string; startAt: number; onAvplayFailed: (failure: unknown) => void; manualTurn: unknown; apiRef: {current: unknown}};
const mockPlayer: {props: PlayerProps | null; mounts: number} = {props: null, mounts: 0};
jest.mock('./VideoPlayer', () => {
	const {useEffect} = jest.requireActual('react');
	return {
		PLAYER_SPOTLIGHT_ID: 'videoPlayer',
		viewerVideoElement: () => null,
		VideoPlayer: (props: PlayerProps) => {
			mockPlayer.props = props;
			useEffect(() => {
				mockPlayer.mounts += 1;
				props.apiRef.current = {
					getMediaState: () => ({currentTime: 7, paused: false}),
					getVideoNode: () => ({error: false, readyState: 4}),
					pause: () => {},
					areControlsVisible: () => false,
				};
				return () => {
					props.apiRef.current = null;
				};
			}, []); // eslint-disable-line react-hooks/exhaustive-deps
			return <div data-testid="player" data-engine={props.engine} />;
		},
	};
});
jest.mock('../../immuch360/sphere/SphereView', () => ({SphereView: () => null}));
jest.mock('../../immuch360/details/AssetDetailsPanel', () => ({AssetDetailsPanel: () => null}));

const video: TimelineAsset = {id: 'v', type: 'VIDEO', ratio: 16 / 9, localDateTime: '2026-11-16', durationSeconds: 30};
const repository = {
	previewUrl: (id: string) => `/preview/${id}`,
	fullsizeUrl: (id: string) => `/fullsize/${id}`,
	videoPlaybackUrl: (id: string) => `/video/${id}`,
	playsOriginal: () => Promise.resolve(true),
	serverTranscodes: true,
} as unknown as PhotoRepository;

const upright = (orientation: string) => ({details: {id: 'v', orientation, width: 3840, height: 2160}, settled: true});

function samsung(withAvplay = true) {
	(window as {tizen?: unknown}).tizen = {application: {}};
	(window as {webapis?: unknown}).webapis = withAvplay ? {avplay: fakeAvplay().api} : {};
}

const mount = (asset: TimelineAsset = video) => {
	(useAssetRotation as jest.Mock).mockReturnValue({rotation: 0, rotate: jest.fn(), notice: null, phase: 'idle'});
	return render(
		<RepositoryProvider repository={repository}>
			<MediaViewer getAssetAt={() => asset} totalCount={1} currentIndex={0} position="1 / 1" onClose={() => {}} onNavigate={() => {}} onStartSlideshow={() => {}} />
		</RepositoryProvider>
	);
};
const engine = () => screen.queryByTestId('player')?.dataset.engine ?? null;

beforeEach(() => {
	jest.useFakeTimers();
	localStorage.clear();
	mockDetails = {details: null, settled: false};
	mockPlayer.props = null;
	mockPlayer.mounts = 0;
	resetAvplayEngine();
	resetVideoSession();
});

afterEach(() => {
	jest.useRealTimers();
	delete (window as {tizen?: unknown}).tizen;
	delete (window as {webapis?: unknown}).webapis;
});

test('a Samsung TV with AVPlay: a video filmed upright (6 or 8) plays through AVPlay, any other one in the HTML element', () => {
	samsung();
	mockDetails = upright('6');
	const {unmount} = mount();
	expect(engine()).toBe('avplay');
	expect(mockPlayer.props?.startAt).toBe(0);
	unmount();
	mockDetails = upright('8');
	mount().unmount();
	expect(mockPlayer.props?.engine).toBe('avplay');
	mockDetails = upright('1');
	mount();
	expect(engine()).toBe('html');
});

test('the player waits for the details where AVPlay may play, so that a video does not start twice; not on an LG TV', () => {
	samsung();
	const {rerender} = mount();
	expect(engine()).toBeNull();
	mockDetails = upright('6');
	rerender(
		<RepositoryProvider repository={repository}>
			<MediaViewer getAssetAt={() => video} totalCount={1} currentIndex={0} position="1 / 1" onClose={() => {}} onNavigate={() => {}} onStartSlideshow={() => {}} />
		</RepositoryProvider>
	);
	expect(engine()).toBe('avplay');
	expect(mockPlayer.mounts).toBe(1);
});

test('details that could not be fetched: the HTML element', () => {
	samsung();
	mockDetails = {details: null, settled: true};
	mount();
	expect(engine()).toBe('html');
});

test('an LG TV or a browser: the HTML element at once, for a video filmed upright too, even with an object called webapis.avplay', () => {
	(window as {webapis?: unknown}).webapis = {avplay: fakeAvplay().api};
	mount();
	expect(engine()).toBe('html');
	mockDetails = upright('6');
	mount();
	expect(screen.getAllByTestId('player').map((node) => node.dataset.engine)).toEqual(['html', 'html']);
	expect(avplayUsable()).toBe(false);
});

test('a Samsung TV without AVPlay keeps the HTML element and its CSS turn, without waiting', () => {
	samsung(false);
	mount();
	expect(engine()).toBe('html');
});

test('"Turn the picture" on a video in the HTML element moves it to AVPlay at the time it reached', () => {
	samsung();
	mockDetails = upright('1');
	mount();
	expect(engine()).toBe('html');
	fireEvent.click(screen.getByText('Turn the picture'));
	expect(engine()).toBe('avplay');
	expect(mockPlayer.props?.startAt).toBe(7);
	expect(mockPlayer.props?.manualTurn).toEqual({degrees: 90});
	// Back to no turn: it stays in AVPlay
	fireEvent.click(screen.getByText('Turn the picture'));
	fireEvent.click(screen.getByText('Turn the picture'));
	fireEvent.click(screen.getByText('Turn the picture'));
	expect(mockPlayer.props?.manualTurn).toEqual({degrees: 0});
	expect(engine()).toBe('avplay');
	expect(mockPlayer.mounts).toBe(2);
});

test('the turn kept for a video opens it in AVPlay the next time', () => {
	samsung();
	localStorage.setItem('immuch360_video_turns', JSON.stringify({v: {degrees: 270}}));
	mount();
	expect(engine()).toBe('avplay');
	expect(mockPlayer.props?.manualTurn).toEqual({degrees: 270});
});

test('AVPlay failed: the video goes on in the HTML element where AVPlay was, a notice says so for a few seconds', () => {
	samsung();
	mockDetails = upright('6');
	mount();
	expect(engine()).toBe('avplay');
	act(() => {
		mockPlayer.props?.onAvplayFailed({stage: 'prepare', error: 'PLAYER_ERROR_NOT_SUPPORTED_FILE', at: 4.5, sessionWide: false});
	});
	expect(engine()).toBe('html');
	expect(mockPlayer.props?.startAt).toBe(4.5);
	expect(screen.getByTestId('notice').textContent).toBe("Samsung's video player could not play this video: the standard player plays it.");
	act(() => {
		jest.advanceTimersByTime(5000);
	});
	expect(screen.queryByTestId('notice')).toBeNull();
	// A press of the button no longer moves this video to AVPlay: the CSS turn of 0.3.4
	fireEvent.click(screen.getByText('Turn the picture'));
	expect(engine()).toBe('html');
	expect(avplayUsable()).toBe(true);
});

test('a failure every video would meet stops AVPlay for the session; the engine rule', () => {
	samsung();
	expect(avplayUsable()).toBe(true);
	noteAvplayFailure('x', {stage: 'prepare', error: 'PLAYER_ERROR_CONNECTION_FAILED', at: 0, sessionWide: true});
	expect(avplayUsable()).toBe(false);
	const base = {usable: true, video360: false, failed: false, orientation: {orientation: '6', width: 1920, height: 1080}, manual: null};
	expect(chooseVideoEngine(base)).toBe('avplay');
	expect(chooseVideoEngine({...base, orientation: {orientation: 8, width: 1920, height: 1080}})).toBe('avplay');
	expect(chooseVideoEngine({...base, orientation: {orientation: '3', width: 1920, height: 1080}})).toBe('html');
	expect(chooseVideoEngine({...base, orientation: null, manual: {degrees: 0}})).toBe('avplay');
	expect(chooseVideoEngine({...base, video360: true})).toBe('html');
	expect(chooseVideoEngine({...base, failed: true})).toBe('html');
	expect(chooseVideoEngine({...base, usable: false})).toBe('html');
});

test('a 360 video plays flat in the HTML element, as before', () => {
	samsung();
	mockDetails = upright('6');
	mount({...video, projectionType: 'EQUIRECTANGULAR'});
	expect(engine()).toBe('html');
});
