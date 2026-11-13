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

// Immuch360: a phone video filmed upright, stored as 1920 x 1080 frames with a rotation flag (Immich orientation "6"),
// whose frames the player shows as stored, in a 1920 x 1080 screen (issue 17)
const UPRIGHT = {orientation: '6', width: 1920, height: 1080};

function reportSizes(video: HTMLVideoElement, frame: [number, number], box: [number, number] = [1920, 1080]) {
	Object.defineProperty(video, 'videoWidth', {configurable: true, value: frame[0]});
	Object.defineProperty(video, 'videoHeight', {configurable: true, value: frame[1]});
	Object.defineProperty(video, 'clientWidth', {configurable: true, value: box[0]});
	Object.defineProperty(video, 'clientHeight', {configurable: true, value: box[1]});
}

test('a Samsung TV turns a video filmed upright once the player knows its frames, and stops when it closes', () => {
	samsung();
	const {container, unmount} = render(<VideoPlayer src="clip.mp4" orientation={UPRIGHT} />);
	const video = playerVideo(container);
	expect(video.style.transform).toBe('');
	reportSizes(video, [1920, 1080]);
	act(() => {
		video.dispatchEvent(new Event('loadedmetadata'));
	});
	expect(video.style.transform).toBe('rotate(90deg) scale(0.5625)');
	unmount();
	expect(video.style.transform).toBe('');
});

test('a Samsung TV leaves a video whose frames come already turned, and turns once the details come', () => {
	samsung();
	const {container, rerender} = render(<VideoPlayer src="clip.mp4" orientation={null} />);
	const video = playerVideo(container);
	reportSizes(video, [1080, 1920]);
	act(() => {
		video.dispatchEvent(new Event('loadedmetadata'));
	});
	rerender(<VideoPlayer src="clip.mp4" orientation={UPRIGHT} />);
	expect(video.style.transform).toBe('');
	reportSizes(video, [1920, 1080]);
	rerender(<VideoPlayer src="clip.mp4" orientation={{...UPRIGHT, orientation: '8'}} />);
	expect(video.style.transform).toBe('rotate(270deg) scale(0.5625)');
});

test('an LG TV leaves the turn to its player', () => {
	const {container} = render(<VideoPlayer src="clip.mp4" orientation={UPRIGHT} />);
	const video = playerVideo(container);
	reportSizes(video, [1920, 1080]);
	act(() => {
		video.dispatchEvent(new Event('loadedmetadata'));
	});
	expect(video.style.transform).toBe('');
});
