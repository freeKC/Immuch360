// Immuch360: on a Samsung TV the screen saver stays off while the viewer's video plays and the video pauses when the
// app is hidden; an LG TV keeps its behaviour (VideoPlayer.tsx)
import React from 'react';
import {act, render} from '@testing-library/react';
import {VIDEO_MARK, VideoPlayer} from './VideoPlayer';
import {lastVideoTurnLine} from '../../immuch360/video/orientation';

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
	expect(lastVideoTurnLine()).toBe('tizen, orientation 6, stored 1920 x 1080, player 1920 x 1080, element 1920 x 1080, auto rotate(90deg) scale(0.5625)');
	unmount();
	expect(video.style.transform).toBe('');
});

// Issue 17, the line of the reporter's Samsung TV with 0.3.2: "orientation 6, stored 3840 x 2160, player 2160 x 3840,
// box 1920 x 1080, not turned", the picture on its side
const UPRIGHT_4K = {orientation: '6', width: 3840, height: 2160};

test('issue 17: a Samsung TV that reports the turned size of the original still gets the turn, unstretched', () => {
	samsung();
	const shown = jest.fn();
	const {container} = render(<VideoPlayer src="clip.mp4" orientation={UPRIGHT_4K} onTurnShown={shown} />);
	const video = playerVideo(container);
	reportSizes(video, [2160, 3840]);
	jest.spyOn(video, 'getBoundingClientRect').mockReturnValue({width: 607.5, height: 1080} as DOMRect);
	act(() => {
		video.dispatchEvent(new Event('loadedmetadata'));
	});
	expect(video.style.transform).toBe('rotate(90deg) scale(1.7778, 0.5625)');
	expect(lastVideoTurnLine()).toBe(
		'tizen, orientation 6, stored 3840 x 2160, player 2160 x 3840, element 1920 x 1080, auto rotate(90deg) scale(1.7778, 0.5625), on screen 608 x 1080'
	);
	expect(shown).toHaveBeenLastCalledWith({degrees: 90, fit: 'file', fitMatters: true});
});

test('a Samsung TV leaves a smaller stream of the other shape (a transcode that turned the frames), and turns once the details come', () => {
	samsung();
	const {container, rerender} = render(<VideoPlayer src="clip.mp4" orientation={null} />);
	const video = playerVideo(container);
	reportSizes(video, [720, 1280]);
	act(() => {
		video.dispatchEvent(new Event('loadedmetadata'));
	});
	rerender(<VideoPlayer src="clip.mp4" orientation={UPRIGHT} />);
	expect(video.style.transform).toBe('');
	expect(lastVideoTurnLine()).toBe('tizen, orientation 6, stored 1920 x 1080, player 720 x 1280, element 1920 x 1080, not turned');
	reportSizes(video, [1920, 1080]);
	rerender(<VideoPlayer src="clip.mp4" orientation={{...UPRIGHT, orientation: '8'}} />);
	expect(video.style.transform).toBe('rotate(270deg) scale(0.5625)');
});

test('an LG TV or a browser leaves the turn to its player, and notes the size it reported for the diagnostics page', () => {
	const {container} = render(<VideoPlayer src="clip.mp4" orientation={UPRIGHT_4K} />);
	const video = playerVideo(container);
	reportSizes(video, [2160, 3840]);
	act(() => {
		video.dispatchEvent(new Event('loadedmetadata'));
	});
	expect(video.style.transform).toBe('');
	expect(lastVideoTurnLine()).toBe('browser, orientation 6, stored 3840 x 2160, player 2160 x 3840, element 1920 x 1080, not turned');
	reportSizes(video, [3840, 2160]);
	act(() => {
		video.dispatchEvent(new Event('loadedmetadata'));
	});
	expect(video.style.transform).toBe('');
	expect(lastVideoTurnLine()).toBe('browser, orientation 6, stored 3840 x 2160, player 3840 x 2160, element 1920 x 1080, auto rotate(90deg) scale(0.5625) left to the player');
});

test('a turn chosen by hand replaces the turn of the player, on a Samsung TV as on an LG TV, and goes when it closes', () => {
	samsung();
	const shown = jest.fn();
	const {container, rerender, unmount} = render(<VideoPlayer src="clip.mp4" orientation={UPRIGHT_4K} manualTurn={{degrees: 0}} onTurnShown={shown} />);
	const video = playerVideo(container);
	reportSizes(video, [2160, 3840]);
	act(() => {
		video.dispatchEvent(new Event('loadedmetadata'));
	});
	expect(video.style.transform).toBe('');
	expect(shown).toHaveBeenLastCalledWith({degrees: 0, fit: 'player', fitMatters: true});
	rerender(<VideoPlayer src="clip.mp4" orientation={UPRIGHT_4K} manualTurn={{degrees: 270, fit: 'player'}} onTurnShown={shown} />);
	expect(video.style.transform).toBe('rotate(270deg) scale(1.7778)');
	expect(lastVideoTurnLine()).toBe('tizen, orientation 6, stored 3840 x 2160, player 2160 x 3840, element 1920 x 1080, by hand 270, fit player, rotate(270deg) scale(1.7778)');
	unmount();
	expect(video.style.transform).toBe('');
	delete (window as {tizen?: unknown}).tizen;
	// An LG TV: no turn by itself, the one chosen by hand, for a video without the flag too
	const {container: lgContainer} = render(<VideoPlayer src="clip.mp4" orientation={{orientation: '1', width: 1920, height: 1080}} manualTurn={{degrees: 90}} />);
	const lgVideo = playerVideo(lgContainer);
	reportSizes(lgVideo, [1920, 1080]);
	act(() => {
		lgVideo.dispatchEvent(new Event('loadedmetadata'));
	});
	expect(lgVideo.style.transform).toBe('rotate(90deg) scale(0.5625)');
	expect(lastVideoTurnLine()).toBe('browser, orientation 1, stored 1920 x 1080, player 1920 x 1080, element 1920 x 1080, by hand 90, fit player, rotate(90deg) scale(0.5625)');
});
