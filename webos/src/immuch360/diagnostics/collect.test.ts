// Immuch360: the video test of the diagnostics page. A clip that does not play tests nothing, and the line says so with
// the reason; one that plays is drawn into WebGL (here a fake) and its colour read back.
import {probeVideoTexture, videoErrorReason} from './collect';

let mockPixel: [number, number, number] = [255, 0, 255];
jest.mock('@enact/webos/LS2Request', () => jest.fn());
jest.mock('../sphere/SphereRenderer', () => ({
	getWebGL: () => ({}),
	webglInfo: () => ({}),
	// A class, not a jest.fn: the mocks are reset before each test
	SphereRenderer: class {
		setFrame() {}
		setSetup() {}
		draw() {}
		centrePixel() {
			return mockPixel;
		}
		dispose() {}
	},
}));

let video: HTMLVideoElement | null;

beforeEach(() => {
	jest.useFakeTimers();
	video = null;
	jest.spyOn(HTMLMediaElement.prototype, 'play').mockImplementation(function (this: HTMLMediaElement) {
		video = this as HTMLVideoElement;
		return Promise.resolve();
	});
	jest.spyOn(HTMLMediaElement.prototype, 'pause').mockImplementation(() => {});
	jest.spyOn(HTMLMediaElement.prototype, 'load').mockImplementation(() => {});
});

afterEach(() => {
	jest.useRealTimers();
	jest.restoreAllMocks();
});

test('a clip the TV refuses: not tested, with the code, its name and the message of the video element', async () => {
	const result = probeVideoTexture();
	Object.defineProperty(video!, 'error', {value: {code: 4, message: 'MEDIA_ELEMENT_ERROR: Format error'}});
	video!.dispatchEvent(new Event('error'));
	await expect(result).resolves.toBe('not tested: the test clip did not play (video error 4 MEDIA_ERR_SRC_NOT_SUPPORTED: MEDIA_ELEMENT_ERROR: Format error)');
	expect(video!.parentNode).toBeNull();
});

test('a clip that does not start in time: not tested', async () => {
	const result = probeVideoTexture(8000);
	jest.advanceTimersByTime(8000);
	await expect(result).resolves.toBe('not tested: the test clip did not play (timeout, readyState 0)');
});

test('a clip that plays: the colour of its frame in WebGL', async () => {
	mockPixel = [255, 0, 255];
	let result = probeVideoTexture();
	video!.dispatchEvent(new Event('playing'));
	jest.advanceTimersByTime(500);
	await expect(result).resolves.toBe('yes (255, 0, 255)');

	mockPixel = [0, 0, 0];
	result = probeVideoTexture();
	video!.dispatchEvent(new Event('playing'));
	jest.advanceTimersByTime(500);
	await expect(result).resolves.toBe('black (360° videos would play flat)');
});

test('the reason of a video error', () => {
	expect(videoErrorReason({code: 3, message: ''})).toBe('video error 3 MEDIA_ERR_DECODE');
	expect(videoErrorReason({code: 7})).toBe('video error 7');
	expect(videoErrorReason(null)).toBe('video error ?');
});
