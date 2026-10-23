import {fireEvent, renderHook} from '@testing-library/react';
import {useWebOSKeys} from './useWebOSKeys';

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

// Immuch360: on a Samsung TV, Back on the first screen closes the app (src/platform/features.ts)
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
		const layer = document.createElement('div');
		layer.id = 'floatLayer';
		layer.appendChild(document.createElement('div'));
		document.body.appendChild(layer);
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

	test('an LG TV keeps its own dialog', () => {
		delete (window as {tizen?: unknown}).tizen;
		const {unmount} = renderHook(() => useWebOSKeys({}));
		fireEvent.keyDown(window, {keyCode: 10009});
		unmount();
		expect(exits).toBe(0);
	});
});
