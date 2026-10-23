export const TARGET_ROW_HEIGHT_PX = 400;
export const GRID_GAP_PX = 8;
export const GRID_INSET_LEFT_PX = 72;
export const GRID_INSET_RIGHT_PX = 72;
export const GRID_HORIZONTAL_PADDING_PX = GRID_INSET_LEFT_PX + GRID_INSET_RIGHT_PX;
// Must match .dateHeader height in DateHeader.module.less.
export const BUCKET_HEADER_HEIGHT_PX = 128;
export const BUCKET_HEADER_MARGIN_PX = 40;
// Authored 4K-space px, as .rail width in NavigationRail.module.less (360px there = 180 CSS px at FHD, 120 at HD).
// Immuch360: it was a runtime 180, which no longer matched the rail of the 1280x720 package; ri.scale() it.
export const RAIL_WIDTH_PX = 360;
// The rail of the 1280x720 package (Enact's hd screen type): 432 authored px, 144 CSS px, so that the labels of the
// rail are not all cut at 16 px per rem. Must match the .enact-res-hd .rail width of NavigationRail.module.less.
export const RAIL_WIDTH_HD_PX = 432;
export const NAVIGATION_RAIL_ID = 'navigation-rail';
// Authored 4K-space px (ri.scale(240) renders a 120 CSS px rail at FHD). Must match
// .scrubberHost width in DateScrubber.module.less — TimelineGrid subtracts it from gridWidth.
export const DATE_SCRUBBER_WIDTH_PX = 240;
export const DATE_SCRUBBER_SPOTLIGHT_ID = 'date-scrubber';
