import {useEffect} from 'react';
import {platformBack} from '@enact/webos/application';
import LS2Request from '@enact/webos/LS2Request';
import {recordError} from '../immuch360/diagnostics/errorLog';
import {features} from '../platform/features';
import {exitTizenApp} from '../platform/tizen';

// Immuch360: an arrow's handler gets its keydown, a repeat of a held key included (event.repeat)
export type ArrowHandler = (event: KeyboardEvent) => void;

interface UseWebOSKeysOptions {
	onBack?: () => void;
	onArrowLeft?: ArrowHandler;
	onArrowRight?: ArrowHandler;
	onArrowUp?: ArrowHandler;
	onArrowDown?: ArrowHandler;
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
// webOS only (features().railBackToPhotos): a Samsung TV closes the app from any page of the rail.
let rootBack: (() => void) | null = null;

// Immuch360: an open Sandstone popup (the language list, the text entry of an Input, a dialog) lives in the floating
// layer of the ThemeDecorator, holds the focus, and closes itself on the keyup of Back. Its keydown must not close the
// page under it (the sign in form, and what was typed) nor, on webOS, reach the TV, where WAM would add its own exit
// popup over the list. The tooltips of the focused buttons live in the same layer but leave the focus on their button:
// they must not hold Back. Both TVs: LG's lot for its store, the Samsung lot for the keyboard popup of the sign in form.
export const FLOATING_LAYER_ID = 'floatLayer';

// The Magic Remote pointer can leave the focus on the body while a popup is open: a popup is then a Spotlight container
// in the layer (Sandstone's Popup, which also holds the Dropdown list and the Input's text entry), an alert or a dialog;
// a tooltip is none of them (its text only, aria-hidden)
const POPUP_IN_LAYER = '[data-spotlight-container], [role="alert"], [role="dialog"], [aria-modal="true"]';

function popupOpen(): boolean {
	if (typeof document === 'undefined') return false;
	const layer = document.getElementById(FLOATING_LAYER_ID);
	if (!layer) return false;
	const focused = document.activeElement;
	if (focused && focused !== document.body && layer.contains(focused)) return true;
	return !!layer.querySelector(POPUP_IN_LAYER);
}

interface WebOSSystemLike {
	platformBack?: () => void;
	deviceInfo?: string;
}

const webOSSystem = (): WebOSSystemLike | undefined =>
	(window as {webOSSystem?: WebOSSystemLike}).webOSSystem ?? (window as {PalmSystem?: WebOSSystemLike}).PalmSystem;

/** The Home app of webOS TV, which the Back of an entry page shows on webOS 23 to 25 (to confirm on those TVs) */
export const HOME_APP_ID = 'com.webos.app.home';

/** What the page knows of the TV: the platform version webOS gives it and the major version of its engine */
function platformClues(): {platformVersion: string | null; chromium: number | null} {
	let platformVersion: string | null = null;
	const raw = typeof window === 'undefined' ? undefined : webOSSystem()?.deviceInfo;
	if (raw) {
		try {
			const value = (JSON.parse(raw) as {platformVersion?: unknown}).platformVersion;
			if (value !== undefined && value !== null && value !== '') platformVersion = String(value);
		} catch {
			// none
		}
	}
	const engine = typeof navigator === 'undefined' ? null : /Chrome\/(\d+)/.exec(navigator.userAgent);
	return {platformVersion, chromium: engine ? Number(engine[1]) : null};
}

/**
 * Immuch360: whether the TV runs webOS 23, 24 or 25, where LG's self checklist asks Back on the entry page to show the
 * Home screen. From the engine first (Chromium 94, 108 and 120 there, 87 on webOS 22, 132 on webOS 26: the Web Engine
 * page), as webOS 25 TVs of LG's Cloud Test Lab did not take the Home path from the platform version of the page;
 * else from that version (8, 9 and 10 for webOS 23, 24 and 25: the SDK table of LG's FAQ).
 */
export function backShowsHome(): boolean {
	const {platformVersion, chromium} = platformClues();
	if (chromium !== null) return chromium >= 94 && chromium < 132;
	const major = platformVersion === null ? NaN : parseInt(platformVersion, 10);
	return !isNaN(major) && major >= 8 && major <= 10;
}

/** The clues of backShowsHome, for the line About keeps when the Home app did not open */
function cluesText(): string {
	const {platformVersion, chromium} = platformClues();
	return `platform ${platformVersion ?? '?'}, Chromium ${chromium ?? '?'}`;
}

// The Home app through the application manager (ACG group application.launcher, in requiredACG); platformBack() when
// the TV refuses or does not answer. Why it did not open goes to the last errors of About (a TV has no console at hand);
// an opened Home writes nothing there (seen on webOS 25 TVs of LG's Cloud Test Lab, 24 October 2026)
function launchHome(): void {
	let settled = false;
	const fallBack = (reason: string) => {
		if (settled) return;
		settled = true;
		console.warn('[back] the Home app did not open: platformBack()', reason);
		recordError(`back: the Home app did not open (${reason}; ${cluesText()}), platformBack()`);
		platformBack();
	};
	new LS2Request().send({
		service: 'luna://com.webos.applicationManager',
		method: 'launch',
		parameters: {id: HOME_APP_ID},
		timeout: 3000,
		onSuccess: () => {
			settled = true;
		},
		onFailure: (response?: {errorCode?: unknown; errorText?: unknown}) =>
			fallBack([response?.errorCode, response?.errorText].filter((part) => part !== undefined && part !== '').join(' ') || 'refused'),
		onTimeout: () => fallBack('no answer within 3 s'),
	});
}

// Immuch360: Back on an entry page (the welcome page, Photos, the account page of a failed start): with
// disableBackHistoryAPI the app handles Back itself. LG's two texts differ: the Back Button guide gives
// webOS.platformBack() as the exit popup on webOS 6 and later (Home on webOS 5 and earlier), the mandatory item of the
// self checklist asks for the Home screen on webOS 23 to 25 only. So: the Home app on webOS 23 to 25 (backShowsHome),
// platformBack() elsewhere. False when the page does not run on a TV (no webOSSystem or PalmSystem): the key is then
// left alone.
export function exitToPlatform(): boolean {
	const system = webOSSystem();
	if (!system) return false;
	if (backShowsHome()) {
		launchHome();
		return true;
	}
	if (typeof system.platformBack !== 'function') {
		// Left to the TV, which then does its own default; About says so (seen nowhere yet, kept to be told)
		recordError('back: this TV has no platformBack()');
		return false;
	}
	platformBack();
	return true;
}

// Immuch360: Samsung's Back. On a Samsung TV, Back on the first screen closes the app, as Samsung's own apps do; webOS
// asks with its own dialog instead (exitToPlatform). Not while a text is typed (the Samsung keyboard closes itself);
// an open popup holds Back before this is reached (popupOpen).
const SAMSUNG_BACK_KEYCODE = 10009;

function exitsTheApp(event: KeyboardEvent): boolean {
	return event.keyCode === SAMSUNG_BACK_KEYCODE && features().exitOnRootBack && !isEditingText(event.target);
}

let bridgeInstalled = false;

// Installs the global Back key listener once per app. On webOS, WAM dispatches the remote
// Back as a DOM keydown event on window (we verified this via ares-inspect on a real TV).
// The app consumes every Back: an open popup closes on keyup, else the top layer closes, else the page goes back to
// Photos (webOS), else (an entry page) the app hands the key to the platform with platformBack().
// Immuch360: a Samsung TV does nothing by itself there, so the app closes itself (exitsTheApp).
function ensureBridgeInstalled(): void {
	if (bridgeInstalled || typeof window === 'undefined') return;
	bridgeInstalled = true;

	window.addEventListener(
		'keydown',
		(event: KeyboardEvent) => {
			if (!isBackKey(event)) return;
			if (event.keyCode === BACKSPACE_KEYCODE && isEditingText(event.target)) return;
			if (popupOpen()) {
				// Sandstone closes the popup on keyup; nothing else may act on this press. On webOS the TV must not
				// see it either; a Samsung TV does nothing with Back by itself, and the press is left as it is there.
				if (webOSSystem()) event.preventDefault();
				return;
			}
			// stopImmediatePropagation (not stopPropagation) so sibling window-level listeners
			// don't all fire the same back action; otherwise an album-and-viewer combo would
			// pop both layers on a single press.
			if (fireTopBack()) {
				event.preventDefault();
				event.stopImmediatePropagation();
				return;
			}
			if (rootBack && features().railBackToPhotos) {
				rootBack();
				event.preventDefault();
				event.stopImmediatePropagation();
				return;
			}
			if (exitToPlatform()) {
				event.preventDefault();
				event.stopImmediatePropagation();
			} else if (exitsTheApp(event)) {
				event.preventDefault();
				exitTizenApp();
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
			let handler: ArrowHandler | undefined;
			if (event.key === 'ArrowLeft') handler = onArrowLeft;
			else if (event.key === 'ArrowRight') handler = onArrowRight;
			else if (event.key === 'ArrowUp') handler = onArrowUp;
			else if (event.key === 'ArrowDown') handler = onArrowDown;
			if (!handler) return;
			event.preventDefault();
			// A handler must be the sole consumer of the key: Spotlight (bubble) and Sandstone
			// (e.g. VideoPlayer seek) listen to the same keydown.
			event.stopImmediatePropagation();
			handler(event);
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
