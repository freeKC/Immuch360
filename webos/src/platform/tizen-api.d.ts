// Immuch360: the few members of Samsung's tizen and webapis objects the app uses, written by hand from Samsung's API
// references (read 23 October 2026) rather than taken from an npm package. Every member is optional: an older TV, a
// missing privilege or a plain browser lacks some of them, and src/platform/tizen.ts checks each one before a call.
//
// Named tizen-api.d.ts, not tizen.d.ts: TypeScript leaves out a .d.ts that has the name of a .ts file next to it.

export interface TizenKey {
	name: string;
	code: number;
}

export interface TizenInputDevice {
	getSupportedKeys?: () => TizenKey[];
	registerKey?: (keyName: string) => void;
	registerKeyBatch?: (keyNames: string[], onSuccess?: () => void, onError?: (error: unknown) => void) => void;
}

export interface TizenApplicationInformation {
	id?: string;
	name?: string;
	version?: string;
}

export interface TizenApplication {
	exit?: () => void;
	hide?: () => void;
}

export interface TizenApplicationManager {
	getCurrentApplication?: () => TizenApplication;
	getAppInfo?: (id?: string) => TizenApplicationInformation;
}

export interface TizenSystemInfo {
	getCapability?: (key: string) => unknown;
}

export interface Tizen {
	application?: TizenApplicationManager;
	tvinputdevice?: TizenInputDevice;
	systeminfo?: TizenSystemInfo;
}

export interface WebapisProductInfo {
	getModel?: () => string;
	getRealModel?: () => string;
	getFirmware?: () => string;
	isUdPanelSupported?: () => boolean;
	is8KPanelSupported?: () => boolean;
}

export interface WebapisAppCommon {
	AppCommonScreenSaverState?: {SCREEN_SAVER_OFF?: number; SCREEN_SAVER_ON?: number};
	setScreenSaver?: (state: number, onSuccess?: () => void, onError?: (error: unknown) => void) => void;
}

export interface WebapisAvInfo {
	isHdrTvSupport?: () => boolean;
}

export interface Webapis {
	productinfo?: WebapisProductInfo;
	appcommon?: WebapisAppCommon;
	avinfo?: WebapisAvInfo;
	avplay?: unknown;
}

/** The globals of a Samsung TV page: tizen from the web runtime, webapis from $WEBAPIS/webapis/webapis.js */
export interface TizenGlobals {
	tizen?: Tizen;
	webapis?: Webapis;
}
