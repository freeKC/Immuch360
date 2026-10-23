// Immuch360: what the TV offers beyond a web page. On webOS the app's JS service listens on the network (the phone
// sign in) and reads shares, Plex and cameras (the media bridge). The Samsung version has no such service yet, so those
// features are not offered there in this version: a Samsung app could reach some of them otherwise (Plex and WebDAV
// over HTTP, sockets through Samsung's WebAssembly extension, a web service with a partner certificate), which is left
// for later (design notes of 23 October 2026, section 6).

import {platform, type Platform} from './detect';

export interface Features {
	/** The phone sign in and the sign in page for the phone's browser: the TV listens for the phone */
	phonePairing: boolean;
	/** The "Network shares" page: SMB, WebDAV and DLNA shares, Plex and Tapo cameras through the media bridge */
	sources: boolean;
	/** The app holds the screen saver while a video plays (webOS keeps a playing video awake by itself) */
	holdScreenSaverForVideo: boolean;
	/** Back on the first screen closes the app, as Samsung's apps do (webOS asks with its own dialog) */
	exitOnRootBack: boolean;
	/** The most pixels a full-size picture may have on this TV, null to follow the engine (photoSize.ts) */
	fullsizePixelCap: number | null;
}

/**
 * 4032 x 3024, a 12 MP phone photo: 49 MB once decoded. Samsung gives an app installed for tests at most 120 MB
 * ("Applications installed through the Tizen Studio for testing can use a maximum 120 MB of memory").
 */
export const TIZEN_FULLSIZE_MAX_PIXELS = 12192768;

export function features(on: Platform = platform()): Features {
	if (on === 'tizen') {
		return {phonePairing: false, sources: false, holdScreenSaverForVideo: true, exitOnRootBack: true, fullsizePixelCap: TIZEN_FULLSIZE_MAX_PIXELS};
	}
	// webOS, and a browser in development, where service/dev.js stands in for the service
	return {phonePairing: true, sources: true, holdScreenSaverForVideo: false, exitOnRootBack: false, fullsizePixelCap: null};
}
