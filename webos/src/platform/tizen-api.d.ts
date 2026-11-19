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
	appInfo?: TizenApplicationInformation;
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

/**
 * What the app hands AVPlay's setListener (Samsung's AVPlay API reference, read 16 November 2026): times in milliseconds,
 * errors as the name of an AVPlayError (PLAYER_ERROR_CONNECTION_FAILED and so on)
 */
export interface WebapisAvplayListener {
	onbufferingstart?: () => void;
	onbufferingprogress?: (percent: number) => void;
	onbufferingcomplete?: () => void;
	oncurrentplaytime?: (milliseconds: number) => void;
	onstreamcompleted?: () => void;
	onevent?: (eventType: string, eventData: unknown) => void;
	onerror?: (error: unknown) => void;
	onresourceconflicted?: () => void;
}

/** One stream of getCurrentStreamInfo(): extra_info is JSON text, for a video {fourCC, Width, Height, Bit_rate} */
export interface WebapisAvplayStreamInfo {
	index?: number;
	type?: string;
	extra_info?: string;
}

/**
 * Samsung's AVPlay player (webapis.avplay), one per app. Every member optional, as above: src/platform/avplay.ts checks
 * the ones the app needs before it uses the player at all.
 */
export interface WebapisAvplay {
	open?: (url: string) => void;
	close?: () => void;
	setListener?: (listener: WebapisAvplayListener) => void;
	setDisplayRect?: (x: number, y: number, width: number, height: number) => void;
	setDisplayMethod?: (method: string) => void;
	/** Since 4.0: PLAYER_DISPLAY_ROTATION_NONE, _90, _180 or _270; setDisplayRect must be called again after it */
	setDisplayRotation?: (rotation: string) => void;
	setTimeoutForBuffering?: (seconds: number) => void;
	prepareAsync?: (onSuccess?: () => void, onError?: (error: unknown) => void) => void;
	play?: () => void;
	pause?: () => void;
	stop?: () => void;
	seekTo?: (milliseconds: number, onSuccess?: () => void, onError?: (error: unknown) => void) => void;
	getState?: () => string;
	getDuration?: () => number;
	getCurrentTime?: () => number;
	getCurrentStreamInfo?: () => WebapisAvplayStreamInfo[];
}

export interface Webapis {
	productinfo?: WebapisProductInfo;
	appcommon?: WebapisAppCommon;
	avinfo?: WebapisAvInfo;
	avplay?: WebapisAvplay;
}

/** The globals of a Samsung TV page: tizen from the web runtime, webapis from $WEBAPIS/webapis/webapis.js */
export interface TizenGlobals {
	tizen?: Tizen;
	webapis?: Webapis;
}
