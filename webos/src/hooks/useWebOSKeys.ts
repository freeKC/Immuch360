import {useEffect} from 'react';
import {platformBack} from '@enact/webos/application';

interface UseWebOSKeysOptions {
	onBack?: () => void;
	onArrowLeft?: () => void;
	onArrowRight?: () => void;
	onArrowUp?: () => void;
	onArrowDown?: () => void;
}

// LG remote Back fires a different keyCode depending on the webOS / WAM version. We support
// all the ones we've observed plus Escape for dev mode in a desktop browser:
//   - 461   : VK_BACK on older webOS (matches Enact's ThemeDecorator default of cancel: 461)
//   - 1536  : observed on webOS 10.x via Chrome/120 WAM (ares-inspect capture on Quentin's TV)
//   - 8     : Backspace fallback (some firmwares re-map Back to it) — gated on text-editing focus, see below
//   - 10009 : Tizen-style back (Tizen TVs and a handful of LG firmwares)
//   - 27    : Escape, for dev browsers
// key === 'GoBack' is also accepted directly: it's the semantic webOS Back regardless of code.
const BACK_KEYCODES = new Set([461, 1536, 8, 10009, 27]);
const BACKSPACE_KEYCODE = 8;
const WHEEL_KEYCODE = 1536;

// The LG magic-remote scroll WHEEL emits keyCode 1536 with key 'Unidentified' while scrolling in
// 5-way mode — the same numeric code webOS 10.x uses for Back. That exact pair is the wheel, not a
// Back press: treating it as Back makes a scroll spuriously pop the current view (the album/viewer
// exits mid-scroll — reproduced on device). The real Back button always carries a meaningful key
// ('GoBack'), so we filter out only the 1536 + 'Unidentified' signature and honor everything else.
function isBackKey(event: KeyboardEvent): boolean {
	if (event.keyCode === WHEEL_KEYCODE && event.key === 'Unidentified') return false;
	return BACK_KEYCODES.has(event.keyCode) || event.key === 'GoBack';
}

// Backspace is overloaded: it's the on-remote Back on a few firmwares AND the
// delete-previous-character key on any input (USB keyboard or webOS virtual keyboard).
// When the user is editing text we let the native editor handle it; everywhere else we
// keep the Back fallback behavior.
function isEditableElement(el: EventTarget | null): boolean {
	if (!(el instanceof HTMLElement)) return false;
	if (el.isContentEditable) return true;
	const tag = el.tagName;
	return tag === 'INPUT' || tag === 'TEXTAREA';
}

// Check the focused element as well as the event target. On webOS the virtual keyboard's
// Backspace arrives as a keyCode-8 keydown whose target is the document body, not the
// <input> being edited (Sandstone Input types into an <input> inside a FloatingLayer popup).
// Looking only at event.target would miss that case, so the capture handler below would
// swallow the keystroke as a Back press and the character would never be deleted.
// document.activeElement still points at the popup's <input> while typing.
function isEditingText(target: EventTarget | null): boolean {
	return isEditableElement(target) || isEditableElement(document.activeElement);
}

// Back handlers are tracked in a stack so the most recently mounted hook wins. This lets
// nested screens (e.g. AlbumView → MediaViewer) coexist: opening the viewer pushes its
// onClose to the top, closing it pops it, then the album-level back becomes active again.
const backStack: Array<() => void> = [];

function fireTopBack(): boolean {
	const top = backStack[backStack.length - 1];
	if (!top) return false;
	top();
	return true;
}

// Immuch360: the Back of a page itself, used when no layer of it took the key: a rail page other than Photos goes
// back to Photos (LG's self checklist, item 37: Back moves to the previous screen). One at a time, the last set wins.
let rootBack: (() => void) | null = null;

// Immuch360: an open Sandstone popup (the language list, the text entry of an Input, a dialog) lives in the floating
// layer of the ThemeDecorator and closes itself on the keyup of Back. Its keydown must not close the page under it nor
// reach the TV, where WAM would add its own exit popup over the list.
export const FLOATING_LAYER_ID = 'floatLayer';

function popupOpen(): boolean {
	const layer = typeof document !== 'undefined' ? document.getElementById(FLOATING_LAYER_ID) : null;
	return !!layer && layer.childElementCount > 0;
}

// Immuch360: Back on an entry page (the welcome page, Photos, the account page of a failed start): with
// disableBackHistoryAPI the app handles Back itself, and webOS.platformBack() asks the TV for its own default, which
// LG's Back Button guide gives as the exit popup on webOS 6 and later and the Home screen on webOS 5 and earlier.
// False when the page does not run on a TV (no webOSSystem or PalmSystem): the key is then left alone.
export function exitToPlatform(): boolean {
	const system = (window as {webOSSystem?: {platformBack?: () => void}; PalmSystem?: {platformBack?: () => void}}).webOSSystem ??
		(window as {PalmSystem?: {platformBack?: () => void}}).PalmSystem;
	if (!system || typeof system.platformBack !== 'function') return false;
	platformBack();
	return true;
}

let bridgeInstalled = false;

// Installs the global Back key listener once per app. On webOS, WAM dispatches the remote
// Back as a DOM keydown event on window (we verified this via ares-inspect on a real TV).
// The app consumes every Back: an open popup closes on keyup, else the top layer closes, else the page goes back to
// Photos, else (an entry page) the app hands the key to the platform with platformBack().
function ensureBridgeInstalled(): void {
	if (bridgeInstalled || typeof window === 'undefined') return;
	bridgeInstalled = true;

	window.addEventListener(
		'keydown',
		(event: KeyboardEvent) => {
			if (!isBackKey(event)) return;
			if (event.keyCode === BACKSPACE_KEYCODE && isEditingText(event.target)) return;
			if (popupOpen()) {
				// Sandstone closes the popup on keyup; nothing else may act on this press
				event.preventDefault();
				return;
			}
			// stopImmediatePropagation (not stopPropagation) so sibling window-level listeners
			// don't all fire the same back action — otherwise an album-and-viewer combo would
			// pop both layers on a single press.
			if (fireTopBack()) {
				event.preventDefault();
				event.stopImmediatePropagation();
				return;
			}
			if (rootBack) {
				rootBack();
				event.preventDefault();
				event.stopImmediatePropagation();
				return;
			}
			if (exitToPlatform()) {
				event.preventDefault();
				event.stopImmediatePropagation();
			}
		},
		{capture: true}
	);
}

/** Immuch360: the Back of a page when none of its layers takes it (see rootBack); undefined on an entry page */
export const useRootBack = (handler?: () => void): void => {
	useEffect(() => {
		ensureBridgeInstalled();
		if (!handler) return undefined;
		rootBack = handler;
		return () => {
			if (rootBack === handler) rootBack = null;
		};
	}, [handler]);
};

export const useWebOSKeys = ({onBack, onArrowLeft, onArrowRight, onArrowUp, onArrowDown}: UseWebOSKeysOptions = {}) => {
	useEffect(() => {
		ensureBridgeInstalled();

		if (onBack) backStack.push(onBack);

		const handleArrowKeys = (event: KeyboardEvent) => {
			let handler: (() => void) | undefined;
			if (event.key === 'ArrowLeft') handler = onArrowLeft;
			else if (event.key === 'ArrowRight') handler = onArrowRight;
			else if (event.key === 'ArrowUp') handler = onArrowUp;
			else if (event.key === 'ArrowDown') handler = onArrowDown;
			if (!handler) return;
			event.preventDefault();
			// A handler must be the sole consumer of the key: Spotlight (bubble) and Sandstone
			// (e.g. VideoPlayer seek) listen to the same keydown.
			event.stopImmediatePropagation();
			handler();
		};
		const needsArrowListener = !!(onArrowLeft || onArrowRight || onArrowUp || onArrowDown);
		if (needsArrowListener) {
			window.addEventListener('keydown', handleArrowKeys, {capture: true});
		}

		return () => {
			if (onBack) {
				const idx = backStack.lastIndexOf(onBack);
				if (idx >= 0) backStack.splice(idx, 1);
			}
			if (needsArrowListener) {
				window.removeEventListener('keydown', handleArrowKeys, {capture: true});
			}
		};
	}, [onBack, onArrowLeft, onArrowRight, onArrowUp, onArrowDown]);
};
