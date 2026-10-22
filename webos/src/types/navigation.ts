// Immuch360: 'about', the diagnostics page; 'sources', the network shares, Plex servers and cameras
export type View = 'photos' | 'albums' | 'places' | 'search' | 'sources' | 'about';

/** Shared props for every route-level panel mounted by AppLayout. */
export interface RoutePanelProps {
	contentWidth: number;
}
