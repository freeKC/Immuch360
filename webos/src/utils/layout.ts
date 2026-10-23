import ri from '@enact/ui/resolution';
import {RAIL_WIDTH_HD_PX, RAIL_WIDTH_PX} from './constants';

// The screen type in use ("hd" for the 1280x720 package): the typings ask for an argument that the function does not
// need, as without one it reads the window bounds given at init
const screenType = (): string => (ri.getScreenType as unknown as () => string)();

/** Immuch360: the width of the rail in CSS px of the screen type in use: 180 at 1920x1080, 144 at 1280x720 */
export const railWidthNow = (): number => ri.scale(screenType() === 'hd' ? RAIL_WIDTH_HD_PX : RAIL_WIDTH_PX);

/**
 * Immuch360: the width of the pages, the window less the rail, in CSS px of the screen type in use (the rail is
 * authored in 4K-space px like the rest of the LESS)
 */
export const contentWidthNow = (): number => window.innerWidth - railWidthNow();
