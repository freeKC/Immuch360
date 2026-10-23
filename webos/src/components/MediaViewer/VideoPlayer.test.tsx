// Immuch360: on a Samsung TV the screen saver stays off while the viewer's video plays and the video pauses when the
// app is hidden; an LG TV keeps its behaviour (VideoPlayer.tsx)
import React from 'react';
import {act, render} from '@testing-library/react';
import {VIDEO_MARK, VideoPlayer} from './VideoPlayer';

let screenSaver: number[];

function samsung() {
	screenSaver = [];
	(window as {tizen?: unknown}).tizen = {application: {}};
	(window as {webapis?: unknown}).webapis = {
		appcommon: {AppCommonScreenSaverState: {SCREEN_SAVER_OFF: 0, SCREEN_SAVER_ON: 1}, setScreenSaver: (state: number) => screenSaver.push(state)},
	};
}

beforeEach(() => {
	jest.spyOn(HTMLMediaElement.prototype, 'play').mockImplementation(() => Promise.resolve());
	jest.spyOn(HTMLMediaElement.prototype, 'pause').mockImplementation(() => {});
	jest.spyOn(HTMLMediaElement.prototype, 'load').mockImplementation(() => {});
});

afterEach(() => {
	delete (window as {tizen?: unknown}).tizen;
	delete (window as {webapis?: unknown}).webapis;
	jest.restoreAllMocks();
});

const playerVideo = (container: HTMLElement): HTMLVideoElement => {
	const video = container.querySelector(`video[${VIDEO_MARK}]`);
	if (!video) throw new Error('no marked video element');
	return video as HTMLVideoElement;
};

test('the marked video element is the one Sandstone plays', () => {
	const {container} = render(<VideoPlayer src="http://nas/api/assets/a1/video/playback" />);
	expect(playerVideo(container).querySelector('source')?.getAttribute('src')).toBe('http://nas/api/assets/a1/video/playback');
});

test('a Samsung TV: the screen saver off while the video plays, on again when it stops or closes', () => {
	samsung();
	const {container, unmount} = render(<VideoPlayer src="clip.mp4" />);
	const video = playerVideo(container);
	act(() => {
		video.dispatchEvent(new Event('playing'));
	});
	expect(screenSaver).toEqual([0]);
	act(() => {
		video.dispatchEvent(new Event('playing'));
	});
	expect(screenSaver).toEqual([0]);
	act(() => {
		video.dispatchEvent(new Event('pause'));
	});
	expect(screenSaver).toEqual([0, 1]);
	act(() => {
		video.dispatchEvent(new Event('playing'));
	});
	unmount();
	expect(screenSaver).toEqual([0, 1, 0, 1]);
});

test('another video (the test clip of the About page) does not hold it', () => {
	samsung();
	render(<VideoPlayer src="clip.mp4" />);
	const other = document.createElement('video');
	document.body.appendChild(other);
	other.dispatchEvent(new Event('playing'));
	expect(screenSaver).toEqual([]);
	other.remove();
});

test('an LG TV keeps a playing video awake by itself: no call', () => {
	const setScreenSaver = jest.fn();
	(window as {webapis?: unknown}).webapis = {appcommon: {setScreenSaver}};
	const {container} = render(<VideoPlayer src="clip.mp4" />);
	act(() => {
		playerVideo(container).dispatchEvent(new Event('playing'));
	});
	expect(setScreenSaver).not.toHaveBeenCalled();
});

const hide = (hidden: boolean) => {
	Object.defineProperty(document, 'hidden', {configurable: true, get: () => hidden});
	act(() => {
		document.dispatchEvent(new Event('visibilitychange'));
	});
};

test('a Samsung TV: the video pauses when the app is hidden, and the viewer still gets the API', () => {
	samsung();
	const apiRef = React.createRef<{pause: () => void}>();
	render(<VideoPlayer src="clip.mp4" apiRef={apiRef as never} />);
	expect(typeof apiRef.current?.pause).toBe('function');
	const pause = jest.spyOn(apiRef.current!, 'pause');
	hide(true);
	expect(pause).toHaveBeenCalledTimes(1);
	hide(false);
	expect(pause).toHaveBeenCalledTimes(1);
});

test('an LG TV: hiding the app leaves the video to webOS, and the viewer gets the API', () => {
	const apiRef = React.createRef<{pause: () => void}>();
	render(<VideoPlayer src="clip.mp4" apiRef={apiRef as never} />);
	expect(typeof apiRef.current?.pause).toBe('function');
	const pause = jest.spyOn(apiRef.current!, 'pause');
	hide(true);
	hide(false);
	expect(pause).not.toHaveBeenCalled();
});
