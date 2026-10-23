// Immuch360: the video test of the diagnostics page. A clip that does not play tests nothing, and the line says so with
// the reason; one that plays is drawn into WebGL (here a fake) and its colour read back.
import {collectDiagnostics, diagnosticsText, heapLine, probeVideoTexture, tizenDeviceLines, videoErrorReason} from './collect';
import {clearErrorLog, recordError} from './errorLog';

let mockPixel: [number, number, number] = [255, 0, 255];
jest.mock('@enact/webos/LS2Request', () => jest.fn());
// Immuch360: no network in the tests; the Smart View port of a Samsung TV does not answer here
jest.mock('../../platform/tizen', () => ({...jest.requireActual('../../platform/tizen'), probeSmartView: () => Promise.resolve(false)}));
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

// Immuch360: the lines of a Samsung TV (Tizen design notes, section 7)
describe('on a Samsung TV', () => {
	beforeEach(() => jest.useRealTimers());

	afterEach(() => {
		delete (window as {tizen?: unknown}).tizen;
		delete (window as {webapis?: unknown}).webapis;
		clearErrorLog();
	});

	test('model, Tizen version, firmware, panel and HDR, AVPlay, secure context, Smart View', () => {
		const lines = tizenDeviceLines(
			{model: 'QE55Q80C', tizenVersion: '7.0', firmware: 'T-PTMDEUC-1440.5', uhdPanel: true, panel8k: false, hdr: true, avplay: true},
			false
		);
		expect(lines.map((line) => `${line.label}: ${line.value}`)).toEqual([
			'TV: QE55Q80C',
			'Tizen: 7.0',
			'Firmware: T-PTMDEUC-1440.5',
			'Panel: UHD, HDR yes',
			'AVPlay: yes',
			expect.stringMatching(/^Secure context: (yes|no), crypto\.subtle (yes|no)$/),
			'Smart View: no answer on port 8001',
		]);
		const unknown = tizenDeviceLines({model: null, tizenVersion: null, firmware: null, uhdPanel: null, panel8k: null, hdr: null, avplay: false}, null);
		expect(unknown.map((line) => line.value).slice(0, 5)).toEqual(['?', '?', '?', '?, HDR ?', 'no']);
		expect(tizenDeviceLines({model: 'QE65QN900C', tizenVersion: '7.0', firmware: null, uhdPanel: true, panel8k: true, hdr: true, avplay: true}, true)[3]!.value).toBe('8K, HDR yes');
	});

	test('the JS memory where the engine tells it', () => {
		expect(heapLine({usedJSHeapSize: 52428800, jsHeapSizeLimit: 2197815296})).toBe('50 MB used of 2096 MB');
		expect(heapLine(undefined)).toBe('?');
		expect(heapLine({})).toBe('?');
	});

	test('the page: the package of config.xml, the Tizen lines, the last errors and what Samsung TVs lack; no DUID', async () => {
		(window as {tizen?: unknown}).tizen = {
			application: {getAppInfo: () => ({id: 'Immuch360T.Immuch360', version: '0.1.0'})},
			systeminfo: {getCapability: () => '6.0'},
		};
		(window as {webapis?: unknown}).webapis = {productinfo: {getModel: () => 'UE43AU7100', getFirmware: () => 'T-KSU2EDEUC-1300.1', getDuid: () => 'DUIDSECRET'}};
		recordError('policy: img-src blocked http://nas/api/assets/a1/thumbnail');
		const lines = await collectDiagnostics(null);
		const text = diagnosticsText(lines);
		expect(text).toContain('Immuch360: 0.1.0 (Immuch360T.Immuch360)');
		expect(text).toContain('TV: UE43AU7100');
		expect(text).toContain('Tizen: 6.0');
		expect(text).toContain('Smart View: no answer on port 8001');
		expect(text).toContain('JS memory: ');
		expect(text).toContain('Last errors: policy: img-src blocked http://nas/api/assets/a1/thumbnail');
		expect(text).toContain('Not yet on Samsung TVs: Sign in with a phone, network shares, Plex and Tapo cameras. On LG TVs these run');
		expect(text).toContain('which the Samsung version does not have yet.');
		expect(text).not.toContain('webOS:');
		expect(text).not.toContain('DUIDSECRET');
	});

	test('an LG TV keeps its lines, and has no line about Samsung TVs', async () => {
		const text = diagnosticsText(await collectDiagnostics(null));
		expect(text).toContain('webOS: ?');
		expect(text).toContain('Last errors: none');
		expect(text).not.toContain('on Samsung TVs');
		expect(text).not.toContain('Tizen:');
	});
});
