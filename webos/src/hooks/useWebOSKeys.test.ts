import {fireEvent, renderHook} from '@testing-library/react';
import {FLOATING_LAYER_ID, useRootBack, useWebOSKeys} from './useWebOSKeys';

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
		const again = renderHook(() => useRootBack());
		expect(pressBack()).toBe(true);
		expect(platformBack).toHaveBeenCalledTimes(1);
		again.unmount();
	});

	test('a layer (viewer, album, overlay) comes before the page and the platform', () => {
		const toPhotos = jest.fn();
		const closeViewer = jest.fn();
		const page = renderHook(() => useRootBack(toPhotos));
		const viewer = renderHook(() => useWebOSKeys({onBack: closeViewer}));
		expect(pressBack()).toBe(true);
		expect(closeViewer).toHaveBeenCalledTimes(1);
		expect(toPhotos).not.toHaveBeenCalled();
		expect(platformBack).not.toHaveBeenCalled();
		viewer.unmount();
		page.unmount();
	});

	test('an open Sandstone popup takes the press: nothing else acts, and the TV does not see it', () => {
		const layer = document.createElement('div');
		layer.id = FLOATING_LAYER_ID;
		layer.appendChild(document.createElement('div'));
		document.body.appendChild(layer);
		const toPhotos = jest.fn();
		const closeViewer = jest.fn();
		const page = renderHook(() => useRootBack(toPhotos));
		const viewer = renderHook(() => useWebOSKeys({onBack: closeViewer}));
		expect(pressBack()).toBe(true);
		expect(closeViewer).not.toHaveBeenCalled();
		expect(toPhotos).not.toHaveBeenCalled();
		expect(platformBack).not.toHaveBeenCalled();
		// The popup closed (its node left the layer): Back acts again
		layer.innerHTML = '';
		expect(pressBack()).toBe(true);
		expect(closeViewer).toHaveBeenCalledTimes(1);
		viewer.unmount();
		page.unmount();
	});
});
