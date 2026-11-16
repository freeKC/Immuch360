// Immuch360: the viewer's player on a Samsung TV for a video that needs a turn: Sandstone's VideoPlayer plays through
// Samsung's AVPlay player (AvplayMedia.tsx) against a stand in of it (fakeAvplay.ts). Its controls, the screen saver,
// the page over the video plane, the app hidden, a failure, and closing (issue 17).
import React from 'react';
import {act, render} from '@testing-library/react';
import {VIDEO_MARK, VideoPlayer, type VideoPlayerApi} from './VideoPlayer';
import {fakeAvplay, type FakeAvplay, type FakeAvplayOptions} from '../../immuch360/video/fakeAvplay';
import {lastVideoTurnLine, resetVideoTurnNotes} from '../../immuch360/video/orientation';
import {AVPLAY_PAGE_CLASS, VIEWER_MARK} from '../../immuch360/video/avplayPage';
import {AVPLAYER_OBJECT_TYPE} from './AvplayMedia';

const SRC = 'http://nas:2283/api/assets/v1/video/playback?apiKey=SECRET-KEY';
const UPRIGHT_4K = {orientation: '6', width: 3840, height: 2160};
let tv: FakeAvplay;
let screenSaver: number[];

function samsung(options: FakeAvplayOptions = {}) {
	screenSaver = [];
	tv = fakeAvplay(options);
	(window as {tizen?: unknown}).tizen = {application: {}};
	(window as {webapis?: unknown}).webapis = {
		appcommon: {AppCommonScreenSaverState: {SCREEN_SAVER_OFF: 0, SCREEN_SAVER_ON: 1}, setScreenSaver: (state: number) => screenSaver.push(state)},
		avplay: tv.api,
	};
}

beforeEach(() => {
	jest.useFakeTimers();
	resetVideoTurnNotes();
	jest.spyOn(HTMLMediaElement.prototype, 'play').mockImplementation(() => Promise.resolve());
	jest.spyOn(HTMLMediaElement.prototype, 'pause').mockImplementation(() => {});
	jest.spyOn(HTMLMediaElement.prototype, 'load').mockImplementation(() => {});
});

afterEach(() => {
	jest.useRealTimers();
	delete (window as {tizen?: unknown}).tizen;
	delete (window as {webapis?: unknown}).webapis;
	jest.restoreAllMocks();
	document.body.innerHTML = '';
});

// The viewer as the page has it: its overlay (marked), the grid beside it, the player inside
function mountPage(props: Partial<React.ComponentProps<typeof VideoPlayer>> = {}) {
	const grid = document.createElement('div');
	grid.id = 'grid';
	grid.style.background = 'rgb(1, 2, 3)';
	const viewer = document.createElement('div');
	viewer.setAttribute(VIEWER_MARK, '');
	viewer.style.background = 'black';
	document.body.append(grid, viewer);
	const apiRef = React.createRef<VideoPlayerApi>();
	const shown = jest.fn();
	const failed = jest.fn();
	const view = render(
		<VideoPlayer src={SRC} engine="avplay" orientation={UPRIGHT_4K} apiRef={apiRef} onTurnShown={shown} onAvplayFailed={failed} avplayOpenDelayMs={0} {...props} />,
		{container: viewer}
	);
	const node = viewer.querySelector(`[${VIDEO_MARK}]`) as HTMLElement;
	// AVPlay opens on a timer (AvplayMedia.tsx), after the delay given
	act(() => {
		jest.advanceTimersByTime(0);
	});
	return {...view, grid, viewer, apiRef, shown, failed, node};
}

// The <object type="application/avplayer"> of Samsung's guide, where the page has it
const playerObjects = () => Array.from(document.querySelectorAll(`object[type="${AVPLAYER_OBJECT_TYPE}"]`)) as HTMLObjectElement[];

const run = (step: () => void) =>
	act(() => {
		step();
	});

test('a Samsung TV plays a turned video through AVPlay: no video element, the URL as the HTML player has it, the turn sent once prepared', () => {
	samsung();
	const {node, viewer, shown} = mountPage();
	expect(viewer.querySelector('video')).toBeNull();
	expect(node.tagName).toBe('DIV');
	expect(tv.calls[0]).toEqual(['open', SRC]);
	run(() => tv.prepareOk());
	expect(tv.calls.filter((call) => call[0] === 'setDisplayRotation')).toEqual([['setDisplayRotation', 'PLAYER_DISPLAY_ROTATION_90']]);
	expect(tv.state).toBe('PLAYING');
	expect(shown).toHaveBeenLastCalledWith({degrees: 90, fit: 'player', fitMatters: true});
	expect(node.getAttribute('data-immuch360-avplay')).toBe('playing');
	expect(lastVideoTurnLine()).toContain('tizen AVPlay');
	expect(lastVideoTurnLine()).not.toContain('SECRET');
});

test("Samsung's guide: the player's object is on the page before AVPlay opens, fills the player, and goes when it closes", () => {
	samsung();
	let objectAtOpen: HTMLObjectElement[] = [];
	const open = tv.api.open;
	tv.api.open = (url) => {
		objectAtOpen = playerObjects();
		open.call(tv.api, url);
	};
	const {node, unmount} = mountPage();
	expect(objectAtOpen).toHaveLength(1);
	const object = playerObjects()[0]!;
	expect(object).toBe(objectAtOpen[0]);
	expect(object.parentElement).toBe(node);
	expect(object.style.width).toBe('100%');
	expect(object.style.height).toBe('100%');
	expect(object.style.pointerEvents).toBe('none');
	expect(object.tabIndex).toBe(-1);
	run(() => tv.prepareOk());
	expect(lastVideoTurnLine()).toContain('stream 3840 x 2160 HEVC, object yes, auto 90');
	unmount();
	expect(playerObjects()).toEqual([]);
});

test('the page is cleared over the video plane while AVPlay plays, and put back as it was when it closes', () => {
	samsung();
	const {grid, viewer, unmount} = mountPage();
	expect(document.documentElement.classList.contains(AVPLAY_PAGE_CLASS)).toBe(true);
	expect(viewer.style.getPropertyValue('background')).toBe('transparent');
	expect(document.body.style.getPropertyValue('background')).toBe('transparent');
	expect(grid.style.visibility).toBe('hidden');
	run(() => tv.prepareOk());
	unmount();
	expect(tv.names().slice(-2)).toEqual(['stop', 'close']);
	expect(tv.state).toBe('NONE');
	expect(document.documentElement.classList.contains(AVPLAY_PAGE_CLASS)).toBe(false);
	expect(viewer.style.background).toBe('black');
	expect(grid.style.visibility).toBe('');
	expect(grid.style.background).toBe('rgb(1, 2, 3)');
	expect(document.body.style.getPropertyValue('background')).toBe('');
});

test("Sandstone's controls drive AVPlay: pause, play, a 10 s jump, the time it reads", () => {
	samsung();
	const {apiRef} = mountPage();
	run(() => tv.prepareOk());
	run(() => tv.tick(4000));
	const api = apiRef.current!;
	expect(api.getMediaState().currentTime).toBe(4);
	expect(api.getMediaState().paused).toBe(false);
	expect(api.getVideoNode()?.readyState).toBe(4);
	expect(api.getVideoNode()?.error).toBe(false);
	run(() => api.pause());
	expect(tv.state).toBe('PAUSED');
	expect(api.getMediaState().paused).toBe(true);
	run(() => api.play());
	expect(tv.state).toBe('PLAYING');
	run(() => api.jump(10));
	expect(tv.calls[tv.calls.length - 1]).toEqual(['seekTo', 14000]);
	expect(api.getMediaState().currentTime).toBe(14);
	// Pause while the jump is on its way: sent once it lands (Samsung refuses it meanwhile)
	run(() => api.pause());
	expect(api.getMediaState().paused).toBe(true);
	expect(tv.state).toBe('PLAYING');
	run(() => tv.seekOk());
	expect(tv.state).toBe('PAUSED');
	expect(api.getMediaState().paused).toBe(true);
	run(() => api.play());
	expect(tv.state).toBe('PLAYING');
	run(() => tv.complete());
	expect(tv.names().slice(-1)).toEqual(['stop']);
	expect(api.getMediaState().paused).toBe(true);
});

test('a Samsung TV: the screen saver off while AVPlay plays, on again when it pauses, ends or closes', () => {
	samsung();
	const {apiRef, unmount} = mountPage();
	run(() => tv.prepareOk());
	expect(screenSaver).toEqual([0]);
	run(() => apiRef.current!.pause());
	expect(screenSaver).toEqual([0, 1]);
	run(() => apiRef.current!.play());
	expect(screenSaver).toEqual([0, 1, 0]);
	run(() => tv.complete());
	expect(screenSaver).toEqual([0, 1, 0, 1]);
	run(() => apiRef.current!.play());
	run(() => tv.prepareOk());
	expect(screenSaver).toEqual([0, 1, 0, 1, 0]);
	unmount();
	expect(screenSaver).toEqual([0, 1, 0, 1, 0, 1]);
});

test('the app hidden: AVPlay stops and closes; shown again it opens at the same time, paused', () => {
	samsung();
	const {apiRef} = mountPage();
	run(() => tv.prepareOk());
	run(() => tv.tick(9000));
	const hide = (hidden: boolean) => {
		Object.defineProperty(document, 'hidden', {configurable: true, get: () => hidden});
		run(() => document.dispatchEvent(new Event('visibilitychange')));
	};
	hide(true);
	expect(tv.state).toBe('NONE');
	expect(tv.names().slice(-2)).toEqual(['stop', 'close']);
	hide(false);
	expect(tv.calls.filter((call) => call[0] === 'open')).toHaveLength(2);
	run(() => tv.prepareOk());
	expect(tv.calls[tv.calls.length - 1]).toEqual(['seekTo', 9000]);
	run(() => tv.seekOk());
	expect(apiRef.current!.getMediaState().paused).toBe(true);
	expect(tv.state).toBe('READY');
});

test('a failure closes AVPlay, puts the page back and tells the viewer where it was', () => {
	samsung();
	const {failed, grid} = mountPage();
	run(() => tv.prepareOk());
	run(() => tv.tick(3000));
	run(() => tv.error('PLAYER_ERROR_CONNECTION_FAILED'));
	expect(failed).toHaveBeenCalledWith({stage: 'playback', error: 'PLAYER_ERROR_CONNECTION_FAILED', at: 3, sessionWide: true});
	expect(tv.state).toBe('NONE');
	expect(grid.style.visibility).toBe('');
	expect(document.documentElement.classList.contains(AVPLAY_PAGE_CLASS)).toBe(false);
	expect(playerObjects()).toEqual([]);
});

test('a turn chosen by hand reaches AVPlay while it plays, no reopening', () => {
	samsung();
	const {rerender, shown} = mountPage();
	run(() => tv.prepareOk());
	rerender(<VideoPlayer src={SRC} engine="avplay" orientation={UPRIGHT_4K} manualTurn={{degrees: 270, fit: 'file'}} onTurnShown={shown} avplayOpenDelayMs={0} />);
	expect(tv.calls.slice(-3)).toEqual([
		['setDisplayRotation', 'PLAYER_DISPLAY_ROTATION_270'],
		['setDisplayMethod', 'PLAYER_DISPLAY_MODE_FULL_SCREEN'],
		['setDisplayRect', 656, 0, 608, 1080],
	]);
	expect(tv.calls.filter((call) => call[0] === 'open')).toHaveLength(1);
	expect(shown).toHaveBeenLastCalledWith({degrees: 270, fit: 'file', fitMatters: true});
});

test('AVPlay opens after the delay given, so that a video element closed just before frees the decoder', () => {
	samsung();
	const {unmount} = mountPage({avplayOpenDelayMs: 300});
	expect(tv.calls).toEqual([]);
	run(() => jest.advanceTimersByTime(300));
	expect(tv.names()[0]).toBe('open');
	unmount();
	// Closed before it opened: nothing opens later
	samsung();
	const second = mountPage({avplayOpenDelayMs: 300});
	second.unmount();
	run(() => jest.advanceTimersByTime(1000));
	expect(tv.names().indexOf('open')).toBe(-1);
	expect(playerObjects()).toEqual([]);
});

// The viewer's video element in a rendered player
const videoIn = (root: HTMLElement): HTMLVideoElement => {
	const video = root.querySelector(`video[${VIDEO_MARK}]`);
	if (!video) throw new Error('no marked video element');
	return video as HTMLVideoElement;
};

test('on a Samsung TV the HTML element frees its decoder when it goes; an LG TV keeps its behaviour', () => {
	samsung();
	const load = HTMLMediaElement.prototype.load as jest.Mock;
	const utils = render(<VideoPlayer src="clip.mp4" />);
	const video = videoIn(utils.container);
	load.mockClear();
	utils.unmount();
	expect(video.querySelector('source')?.hasAttribute('src')).toBe(false);
	expect(load).toHaveBeenCalledTimes(1);
	delete (window as {tizen?: unknown}).tizen;
	const view = render(<VideoPlayer src="clip.mp4" />);
	const lgVideo = videoIn(view.container);
	load.mockClear();
	view.unmount();
	expect(lgVideo.querySelector('source')?.getAttribute('src')).toBe('clip.mp4');
	expect(load).not.toHaveBeenCalled();
});

test('the HTML element after AVPlay goes on from where AVPlay was', () => {
	samsung();
	const view = render(<VideoPlayer src="clip.mp4" startAt={21.5} />);
	const video = videoIn(view.container);
	Object.defineProperty(video, 'readyState', {configurable: true, value: 1});
	act(() => {
		video.dispatchEvent(new Event('loadedmetadata'));
	});
	expect(video.currentTime).toBe(21.5);
});
