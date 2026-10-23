// Immuch360: which TV the app runs on, found at run time. The same bundle (npm run pack-p) runs on LG webOS TVs and,
// packaged by tizen/tools/build-wgt.mjs, on Samsung Tizen TVs; the few differences go through src/platform/.

export type Platform = 'webos' | 'tizen' | 'browser';

/** The globals that tell the TVs apart */
export interface PlatformGlobals {
	tizen?: {application?: unknown} | null;
	WebOSServiceBridge?: unknown;
	PalmSystem?: unknown;
	webOSSystem?: unknown;
}

const pageGlobals = (): PlatformGlobals | undefined => (typeof window === 'undefined' ? undefined : (window as unknown as PlatformGlobals));

/**
 * The TV the page runs on: Samsung's tizen object (the web runtime gives it to every Tizen app), else one of LG's
 * bridges, else a plain browser (development with enact serve, the tests).
 */
export function platform(globals: PlatformGlobals | undefined = pageGlobals()): Platform {
	if (!globals) return 'browser';
	if (globals.tizen && typeof globals.tizen === 'object' && globals.tizen.application) return 'tizen';
	if (typeof globals.WebOSServiceBridge === 'function' || globals.PalmSystem || globals.webOSSystem) return 'webos';
	return 'browser';
}

/** Whether the page runs on a Samsung TV */
export const isTizen = (): boolean => platform() === 'tizen';
