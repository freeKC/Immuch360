import {isTizen} from '../platform/detect';
import {holdTizenScreenSaver} from '../platform/tizen';

const ignore = () => {};

/**
 * Holds off the TV screen saver until the returned release function is called: the slideshow, and a video on Samsung
 * TVs (features().holdScreenSaverForVideo).
 * Immuch360: a Samsung TV turns it off through AppCommon, holds counted (src/platform/tizen.ts). On webOS nothing:
 * appinfo.json asks for the Type 3 screen saver of gallery apps (screenSaverProperties, useGalleryMode), and the app
 * no longer calls the undocumented power service of webOS, which LG's store refuses (tools/store-rules.mjs).
 */
export function holdScreenSaver(): () => void {
	return isTizen() ? holdTizenScreenSaver() : ignore;
}
