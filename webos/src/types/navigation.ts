// Immuch360: 'about', the diagnostics page
export type View = 'photos' | 'albums' | 'places' | 'search' | 'about';

/** Shared props for every route-level panel mounted by AppLayout. */
export interface RoutePanelProps {
	contentWidth: number;
}
