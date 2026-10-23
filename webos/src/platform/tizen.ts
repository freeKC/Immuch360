// Immuch360: every call the app makes to Samsung's tizen and webapis objects. Each one checks that the member exists
// and catches what it throws (an older TV, a privilege missing from config.xml), so that a failure costs a feature,
// never the app. Off a Samsung TV every function does nothing.
//
// Samsung's guides used (read 23 October 2026): Remote Control (tvinputdevice), Setting Screensaver (AppCommon),
// Product Info, AVInfo, Application (exit, app info), System Info.

import type {TizenGlobals, TizenInputDevice} from './tizen-api';

const globals = (): TizenGlobals => (typeof window === 'undefined' ? {} : (window as unknown as TizenGlobals));

/** The value of a call, null when the member is missing or the call throws */
function attempt<T>(call: () => T | undefined | null): T | null {
	try {
		const value = call();
		return value === undefined || value === null ? null : value;
	} catch {
		return null;
	}
}

/**
 * The keys of a Samsung remote the app asks for. Arrows, OK (13) and Back (10009) reach the page without asking; the
 * number and volume keys stay with the TV; Exit (10182) closes the app. The codes are in src/immuch360/keys.ts.
 */
export const TIZEN_KEYS = [
	'ChannelUp',
	'ChannelDown',
	'MediaPlay',
	'MediaPause',
	'MediaPlayPause',
	'MediaRewind',
	'MediaFastForward',
	'MediaStop',
	'MediaTrackPrevious',
	'MediaTrackNext',
	'Info',
	'ColorF0Red',
	'ColorF1Green',
	'ColorF2Yellow',
	'ColorF3Blue',
];

function registerOneByOne(input: TizenInputDevice, names: string[]): string[] {
	return names.filter((name) => {
		try {
			input.registerKey!(name);
			return true;
		} catch {
			return false;
		}
	});
}

/** Asks the TV for the remote keys of TIZEN_KEYS that this TV has; returns the names asked for */
export function registerTizenKeys(): string[] {
	const input = globals().tizen?.tvinputdevice;
	if (!input || typeof input.registerKey !== 'function') return [];
	const supported = attempt(() => input.getSupportedKeys!().map((key) => key.name));
	const wanted = supported ? TIZEN_KEYS.filter((name) => supported.indexOf(name) >= 0) : TIZEN_KEYS.slice();
	if (wanted.length === 0) return [];
	if (typeof input.registerKeyBatch === 'function') {
		try {
			// A batch that fails (one name unknown to this TV) is asked again key by key
			input.registerKeyBatch(wanted, undefined, () => registerOneByOne(input, wanted));
			return wanted;
		} catch {
			// key by key below
		}
	}
	return registerOneByOne(input, wanted);
}

/** Turns the screen saver of the TV on or off through AppCommon; false when the TV has no such call */
export function setTizenScreenSaver(on: boolean): boolean {
	const appcommon = globals().webapis?.appcommon;
	if (!appcommon || typeof appcommon.setScreenSaver !== 'function') return false;
	const states = appcommon.AppCommonScreenSaverState;
	const state = on ? states?.SCREEN_SAVER_ON ?? 1 : states?.SCREEN_SAVER_OFF ?? 0;
	try {
		appcommon.setScreenSaver(state, undefined, () => {});
		return true;
	} catch {
		return false;
	}
}

let screenSaverHolds = 0;

/**
 * Keeps the screen saver off until the returned function is called. Holds are counted: the slideshow and a video may
 * hold it at once, and it comes back when the last one lets go (Samsung: off during videos and slideshows, back on
 * when they stop).
 */
export function holdTizenScreenSaver(): () => void {
	screenSaverHolds += 1;
	if (screenSaverHolds === 1) setTizenScreenSaver(false);
	let released = false;
	return () => {
		if (released) return;
		released = true;
		screenSaverHolds -= 1;
		if (screenSaverHolds === 0) setTizenScreenSaver(true);
	};
}

/** How many holds keep the screen saver off now (tests, diagnostics) */
export const tizenScreenSaverHolds = (): number => screenSaverHolds;

/** Closes the app, as Back on the first screen does on Samsung TVs; false when it could not */
export function exitTizenApp(): boolean {
	const app = attempt(() => globals().tizen?.application?.getCurrentApplication?.());
	if (!app || typeof app.exit !== 'function') return false;
	try {
		app.exit();
		return true;
	} catch {
		return false;
	}
}

/** The id and version of the installed package (config.xml), null off a Samsung TV */
export function tizenAppInfo(): {id: string; version: string} | null {
	const info = attempt(() => globals().tizen?.application?.getAppInfo?.());
	if (!info) return null;
	return {id: String(info.id ?? '?'), version: String(info.version ?? '?')};
}

/** What the About page shows of a Samsung TV; null for what this TV does not say */
export interface TizenInfo {
	model: string | null;
	tizenVersion: string | null;
	firmware: string | null;
	uhdPanel: boolean | null;
	panel8k: boolean | null;
	hdr: boolean | null;
	avplay: boolean;
}

const asText = (value: unknown): string | null => (value === null || value === undefined || value === '' ? null : String(value));
const asFlag = (value: unknown): boolean | null => (typeof value === 'boolean' ? value : null);

/** The model, Tizen version, firmware and panel of the TV. The DUID is never read: the page goes into bug reports. */
export function tizenInfo(): TizenInfo {
	const {tizen, webapis} = globals();
	const product = webapis?.productinfo;
	return {
		model: asText(attempt(() => product?.getRealModel?.())) ?? asText(attempt(() => product?.getModel?.())),
		tizenVersion: asText(attempt(() => tizen?.systeminfo?.getCapability?.('http://tizen.org/feature/platform.version'))),
		firmware: asText(attempt(() => product?.getFirmware?.())),
		uhdPanel: asFlag(attempt(() => product?.isUdPanelSupported?.())),
		panel8k: asFlag(attempt(() => product?.is8KPanelSupported?.())),
		hdr: asFlag(attempt(() => webapis?.avinfo?.isHdrTvSupport?.())),
		avplay: !!webapis?.avplay,
	};
}

/** The address of Samsung's Smart View service on the TV itself (multiscreen, port 8001) */
export const SMART_VIEW_URL = 'http://127.0.0.1:8001/api/v2/';

/**
 * Whether the TV's own Smart View service answers within the time given: a later pairing with the phone could go
 * through it (design notes, section 4). Any answer counts; an error or no answer is false.
 */
export function probeSmartView(timeoutMs = 2000, url = SMART_VIEW_URL): Promise<boolean> {
	return new Promise((resolve) => {
		try {
			const request = new XMLHttpRequest();
			request.open('GET', url, true);
			request.timeout = timeoutMs;
			request.onload = () => resolve(request.status > 0);
			request.onerror = () => resolve(false);
			request.ontimeout = () => resolve(false);
			request.send();
		} catch {
			resolve(false);
		}
	});
}
