import ri from '@enact/ui/resolution';
import {RAIL_WIDTH_PX} from './constants';

/**
 * Immuch360: the width of the pages, the window less the rail, in CSS px of the screen type in use: 1920 - 180 in the
 * 1920x1080 package, 1280 - 120 in the 1280x720 one (the rail is authored in 4K-space px like the rest of the LESS)
 */
export const contentWidthNow = (): number => window.innerWidth - ri.scale(RAIL_WIDTH_PX);
