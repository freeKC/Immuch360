import {fireEvent, renderHook} from '@testing-library/react';
import {FLOATING_LAYER_ID, HOME_APP_ID, backShowsHome, useRootBack, useWebOSKeys} from './useWebOSKeys';

// Immuch360: the Luna calls of the Home app on webOS 23 to 25, recorded (jsdom has no Luna bus)
interface MockLunaRequest {
	service: string;
	method: string;
	parameters: unknown;
	onSuccess?: () => void;
	onFailure?: () => void;
	onTimeout?: () => void;
}
const mockLunaCalls: MockLunaRequest[] = [];
jest.mock('@enact/webos/LS2Request', () => ({
	__esModule: true,
	default: class {
		send(request: MockLunaRequest) {
			mockLunaCalls.push(request);
			return this;
		}
	},
}));

// Fire a keydown while a single onBack is mounted, and report whether it was treated as Back.
function firesBack(init: KeyboardEventInit & {keyCode?: number}): boolean {
	const onBack = jest.fn();
	const {unmount} = renderHook(() => useWebOSKeys({onBack}));
	fireEvent.keyDown(window, init);
	unmount();
	return onBack.mock.calls.length > 0;
}

describe('useWebOSKeys Back detection', () => {
	test('real Back button (key "GoBack") triggers back on any paired keyCode', () => {
		expect(firesBack({key: 'GoBack', keyCode: 461})).toBe(true);
		expect(firesBack({key: 'GoBack', keyCode: 1536})).toBe(true);
	});

	test('legacy/cross-platform numeric Back codes still trigger back', () => {
		expect(firesBack({keyCode: 461})).toBe(true);
		expect(firesBack({keyCode: 1536})).toBe(true); // webOS 10.x Back, no key set
		expect(firesBack({keyCode: 10009})).toBe(true);
		expect(firesBack({keyCode: 27})).toBe(true);
	});

	// Regression: the LG magic-remote scroll wheel emits keyCode 1536 with key 'Unidentified'
	// while scrolling in 5-way mode. That must not be read as Back, or a scroll pops the view
	// (album/viewer exited mid-scroll on device).
	test('magic-remote wheel scroll (keyCode 1536 + key "Unidentified") does NOT trigger back', () => {
		expect(firesBack({keyCode: 1536, key: 'Unidentified'})).toBe(false);
	});

	test('the wheel filter is scoped to 1536 only — other Back codes still fire even if key is "Unidentified"', () => {
		expect(firesBack({keyCode: 461, key: 'Unidentified'})).toBe(true);
	});
});

// Immuch360: Back that no layer takes (LG's self checklist: the entry page hands Back to the platform, the other
// pages go to the previous screen; an open popup closes first)
describe('useWebOSKeys Back without a layer', () => {
	const platformBack = jest.fn();

	beforeEach(() => {
		platformBack.mockClear();
		(window as {PalmSystem?: unknown}).PalmSystem = {platformBack};
	});

	afterEach(() => {
		delete (window as {PalmSystem?: unknown}).PalmSystem;
		document.getElementById(FLOATING_LAYER_ID)?.remove();
	});

	// Dispatches a Back keydown and tells whether the app consumed it (preventDefault)
	function pressBack(): boolean {
		const event = new KeyboardEvent('keydown', {key: 'GoBack', keyCode: 461, bubbles: true, cancelable: true} as KeyboardEventInit);
		window.dispatchEvent(event);
		return event.defaultPrevented;
	}

	test('on an entry page (no layer, no page Back) Back calls platformBack and is consumed', () => {
		const {unmount} = renderHook(() => useRootBack());
		expect(pressBack()).toBe(true);
		expect(platformBack).toHaveBeenCalledTimes(1);
		unmount();
	});

	test('off a TV (no PalmSystem nor webOSSystem) the key is left alone', () => {
		delete (window as {PalmSystem?: unknown}).PalmSystem;
		const {unmount} = renderHook(() => useRootBack());
		expect(pressBack()).toBe(false);
		unmount();
	});

	test('webOSSystem is used when the TV has it', () => {
		delete (window as {PalmSystem?: unknown}).PalmSystem;
		const viaWebOSSystem = jest.fn();
		(window as {webOSSystem?: unknown}).webOSSystem = {platformBack: viaWebOSSystem};
		const {unmount} = renderHook(() => useRootBack());
		expect(pressBack()).toBe(true);
		expect(viaWebOSSystem).toHaveBeenCalledTimes(1);
		delete (window as {webOSSystem?: unknown}).webOSSystem;
		unmount();
	});

	test("a page's own Back (a rail page other than Photos) comes before the platform", () => {
		const toPhotos = jest.fn();
		const {unmount} = renderHook(() => useRootBack(toPhotos));
		expect(pressBack()).toBe(true);
		expect(toPhotos).toHaveBeenCalledTimes(1);
		expect(platformBack).not.toHaveBeenCalled();
		unmount();
		// Unmounted (back on Photos): the platform again
		const {unmount: unmountAgain} = renderHook(() => useRootBack());
		expect(pressBack()).toBe(true);
		expect(platformBack).toHaveBeenCalledTimes(1);
		unmountAgain();
	});

	test('a layer (viewer, album, overlay) comes before the page and the platform', () => {
		const toPhotos = jest.fn();
		const closeViewer = jest.fn();
		const {unmount: unmountPage} = renderHook(() => useRootBack(toPhotos));
		const {unmount: unmountViewer} = renderHook(() => useWebOSKeys({onBack: closeViewer}));
		expect(pressBack()).toBe(true);
		expect(closeViewer).toHaveBeenCalledTimes(1);
		expect(toPhotos).not.toHaveBeenCalled();
		expect(platformBack).not.toHaveBeenCalled();
		unmountViewer();
		unmountPage();
	});

	test('an open Sandstone popup takes the press: nothing else acts, and the TV does not see it', () => {
		const layer = document.createElement('div');
		layer.id = FLOATING_LAYER_ID;
		const item = document.createElement('button');
		layer.appendChild(item);
		document.body.appendChild(layer);
		// A popup holds the focus (the language list, an Input's text entry)
		item.focus();
		const toPhotos = jest.fn();
		const closeViewer = jest.fn();
		const {unmount: unmountPage} = renderHook(() => useRootBack(toPhotos));
		const {unmount: unmountViewer} = renderHook(() => useWebOSKeys({onBack: closeViewer}));
		expect(pressBack()).toBe(true);
		expect(closeViewer).not.toHaveBeenCalled();
		expect(toPhotos).not.toHaveBeenCalled();
		expect(platformBack).not.toHaveBeenCalled();
		// The popup closed (its node left the layer, the focus with it): Back acts again
		layer.innerHTML = '';
		(document.activeElement as HTMLElement | null)?.blur?.();
		expect(pressBack()).toBe(true);
		expect(closeViewer).toHaveBeenCalledTimes(1);
		unmountViewer();
		unmountPage();
	});
	// The Magic Remote pointer leaves the focus on the body while the language list is open (review R13)
	test('an open popup holds Back even when the pointer left the focus on the body', () => {
		const layer = document.createElement('div');
		layer.id = FLOATING_LAYER_ID;
		const popup = document.createElement('div');
		popup.setAttribute('data-spotlight-container', 'true');
		layer.appendChild(popup);
		document.body.appendChild(layer);
		(document.activeElement as HTMLElement | null)?.blur?.();
		expect(document.activeElement).toBe(document.body);
		const closeViewer = jest.fn();
		const {unmount} = renderHook(() => useWebOSKeys({onBack: closeViewer}));
		expect(pressBack()).toBe(true);
		expect(closeViewer).not.toHaveBeenCalled();
		expect(platformBack).not.toHaveBeenCalled();
		// A dialog in the layer counts too
		popup.removeAttribute('data-spotlight-container');
		popup.setAttribute('role', 'dialog');
		expect(pressBack()).toBe(true);
		expect(closeViewer).not.toHaveBeenCalled();
		// Closed: Back acts again
		layer.innerHTML = '';
		expect(pressBack()).toBe(true);
		expect(closeViewer).toHaveBeenCalledTimes(1);
		unmount();
	});

	// A tooltip of a focused button (the viewer's controls) sits in the same layer but leaves the focus on its button:
	// Back still closes the viewer (seen in the headless proof of 23 October 2026: Back stayed held)
	test('a tooltip in the floating layer does not hold Back', () => {
		const layer = document.createElement('div');
		layer.id = FLOATING_LAYER_ID;
		layer.appendChild(document.createElement('div'));
		document.body.appendChild(layer);
		const button = document.createElement('button');
		document.body.appendChild(button);
		button.focus();
		const closeViewer = jest.fn();
		const {unmount} = renderHook(() => useWebOSKeys({onBack: closeViewer}));
		expect(pressBack()).toBe(true);
		expect(closeViewer).toHaveBeenCalledTimes(1);
		unmount();
		button.remove();
	});
});

// Immuch360: LG's self checklist asks Back on the entry page to show the Home screen on webOS 23 to 25 only; the Back
// Button guide gives platformBack() (the exit popup) for webOS 6 and later (review R3)
describe('Back on an entry page per webOS version', () => {
	const platformBack = jest.fn();
	const onVersion = (platformVersion?: string) => {
		(window as {PalmSystem?: unknown}).PalmSystem = {platformBack, deviceInfo: platformVersion ? JSON.stringify({platformVersion}) : undefined};
	};
	function pressBack(): boolean {
		const event = new KeyboardEvent('keydown', {key: 'GoBack', keyCode: 461, bubbles: true, cancelable: true} as KeyboardEventInit);
		window.dispatchEvent(event);
		return event.defaultPrevented;
	}

	beforeEach(() => {
		platformBack.mockClear();
		mockLunaCalls.length = 0;
	});
	afterEach(() => {
		delete (window as {PalmSystem?: unknown}).PalmSystem;
		jest.restoreAllMocks();
	});

	test.each(['8.0.0', '9.2.1', '10.1.0'])('webOS %s (23 to 25): the Home app, and platformBack() only if it does not open', (version) => {
		onVersion(version);
		const {unmount} = renderHook(() => useRootBack());
		const warn = jest.spyOn(console, 'warn').mockImplementation(() => undefined);
		expect(pressBack()).toBe(true);
		expect(mockLunaCalls).toHaveLength(1);
		expect(mockLunaCalls[0]).toMatchObject({service: 'luna://com.webos.applicationManager', method: 'launch', parameters: {id: HOME_APP_ID}});
		expect(platformBack).not.toHaveBeenCalled();
		// The TV refused (no such app, or ACG): the platform's own Back
		mockLunaCalls[0]!.onFailure!();
		expect(platformBack).toHaveBeenCalledTimes(1);
		expect(warn).toHaveBeenCalled();
		// Opened: nothing else
		expect(pressBack()).toBe(true);
		mockLunaCalls[1]!.onSuccess!();
		expect(platformBack).toHaveBeenCalledTimes(1);
		unmount();
	});

	test.each(['5.2.0', '6.3.1', '7.3.0', '11.0.0'])('webOS %s: platformBack(), no Luna call', (version) => {
		onVersion(version);
		const {unmount} = renderHook(() => useRootBack());
		expect(pressBack()).toBe(true);
		expect(platformBack).toHaveBeenCalledTimes(1);
		expect(mockLunaCalls).toHaveLength(0);
		unmount();
	});

	test('without a platform version, the engine tells (Chromium 94 to 120 for webOS 23 to 25)', () => {
		onVersion();
		const agent = jest.spyOn(navigator, 'userAgent', 'get');
		const ua = (chrome: string) => `Mozilla/5.0 (Web0S; Linux/SmartTV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${chrome} Safari/537.36 WebAppManager`;
		agent.mockReturnValue(ua('87.0.4280.88'));
		expect(backShowsHome()).toBe(false);
		agent.mockReturnValue(ua('94.0.4606.128'));
		expect(backShowsHome()).toBe(true);
		agent.mockReturnValue(ua('108.0.5359.211'));
		expect(backShowsHome()).toBe(true);
		agent.mockReturnValue(ua('120.0.6099.270'));
		expect(backShowsHome()).toBe(true);
		agent.mockReturnValue(ua('132.0.6834.0'));
		expect(backShowsHome()).toBe(false);
	});
});

// Sandstone's floating layer, where its popups and tooltips go
function floatLayer(): HTMLElement {
	const layer = document.createElement('div');
	layer.id = 'floatLayer';
	document.body.appendChild(layer);
	return layer;
}

// Immuch360: on a Samsung TV, Back on the first screen closes the app, and Back with a popup open closes the popup only
// (src/platform/features.ts)
describe('Back on the first screen of a Samsung TV', () => {
	let exits: number;

	beforeEach(() => {
		exits = 0;
		(window as {tizen?: unknown}).tizen = {application: {getCurrentApplication: () => ({exit: () => exits++})}};
	});

	afterEach(() => {
		delete (window as {tizen?: unknown}).tizen;
		document.body.innerHTML = '';
	});

	test('closes the app when no screen takes Back', () => {
		const {unmount} = renderHook(() => useWebOSKeys({}));
		fireEvent.keyDown(window, {keyCode: 10009});
		unmount();
		expect(exits).toBe(1);
	});

	test('a screen that takes Back keeps the app open', () => {
		expect(firesBack({keyCode: 10009})).toBe(true);
		expect(exits).toBe(0);
	});

	test('not while a text is typed, nor while a popup is open, nor for another Back code', () => {
		const {unmount} = renderHook(() => useWebOSKeys({}));
		const input = document.createElement('input');
		document.body.appendChild(input);
		input.focus();
		fireEvent.keyDown(input, {keyCode: 10009});
		input.blur();
		const layer = floatLayer();
		const popup = document.createElement('div');
		popup.setAttribute('role', 'alert');
		layer.appendChild(popup);
		fireEvent.keyDown(window, {keyCode: 10009});
		layer.innerHTML = '';
		fireEvent.keyDown(window, {keyCode: 8});
		fireEvent.keyDown(window, {keyCode: 27});
		expect(exits).toBe(0);
		// The popup closed: Back closes the app again
		fireEvent.keyDown(window, {keyCode: 10009});
		unmount();
		expect(exits).toBe(1);
	});

	test('the tooltip of a focused button does not keep the app open', () => {
		const {unmount} = renderHook(() => useWebOSKeys({}));
		floatLayer().appendChild(document.createElement('div'));
		fireEvent.keyDown(window, {keyCode: 10009});
		unmount();
		expect(exits).toBe(1);
	});

	test('a popup holding the focus closes on its own: the screen under it does not get Back', () => {
		const onBack = jest.fn();
		const {unmount} = renderHook(() => useWebOSKeys({onBack}));
		const input = document.createElement('input');
		floatLayer().appendChild(input);
		input.focus();
		const pressed = fireEvent.keyDown(input, {keyCode: 10009});
		// Not prevented: Enact closes the popup on the key's release
		expect(pressed).toBe(true);
		expect(onBack).not.toHaveBeenCalled();
		input.remove();
		fireEvent.keyDown(window, {keyCode: 10009});
		unmount();
		expect(onBack).toHaveBeenCalledTimes(1);
		expect(exits).toBe(0);
	});

	// Merged with LG's lot for its store (23 October 2026): an LG TV holds Back for a popup as well, and the TV does not
	// see the press, where WAM would add its own exit popup over the list (the LG tests above)
	test('an LG TV holds Back for a popup too: the screen does not get it, the TV does not see it', () => {
		delete (window as {tizen?: unknown}).tizen;
		(window as {PalmSystem?: unknown}).PalmSystem = {platformBack: () => undefined};
		try {
			const onBack = jest.fn();
			const {unmount} = renderHook(() => useWebOSKeys({onBack}));
			const input = document.createElement('input');
			floatLayer().appendChild(input);
			input.focus();
			const pressed = fireEvent.keyDown(input, {keyCode: 461});
			expect(pressed).toBe(false);
			expect(onBack).not.toHaveBeenCalled();
			input.remove();
			fireEvent.keyDown(window, {keyCode: 461});
			unmount();
			expect(onBack).toHaveBeenCalledTimes(1);
		} finally {
			delete (window as {PalmSystem?: unknown}).PalmSystem;
		}
	});

	// LG's Back to Photos from the other pages of the rail is webOS only (features().railBackToPhotos)
	test('a page of the rail other than Photos does not keep the app open', () => {
		const toPhotos = jest.fn();
		const {unmount} = renderHook(() => useRootBack(toPhotos));
		fireEvent.keyDown(window, {keyCode: 10009});
		unmount();
		expect(toPhotos).not.toHaveBeenCalled();
		expect(exits).toBe(1);
	});

	test('an LG TV keeps its own dialog', () => {
		delete (window as {tizen?: unknown}).tizen;
		const {unmount} = renderHook(() => useWebOSKeys({}));
		fireEvent.keyDown(window, {keyCode: 10009});
		unmount();
		expect(exits).toBe(0);
	});
});
