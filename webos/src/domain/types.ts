type AssetType = 'IMAGE' | 'VIDEO';

export interface TimelineAsset {
	id: string;
	type: AssetType;
	ratio: number;
	// Local wall-clock time; day grouping must use it to match the server's month buckets,
	// which are cut on localDateTime, not UTC.
	localDateTime: string;
	durationSeconds: number | null;
	city?: string | null;
	country?: string | null;
	// Immuch360: the server's 360° flag ("EQUIRECTANGULAR"), see src/immuch360/sphere/rules.ts
	projectionType?: string | null;
	// Immuch360: the name of a file of a network share, shown by the viewer above its date
	fileName?: string | null;
}

// Immuch360: what the 360° viewer needs to know of an asset beyond the timeline (GET /api/assets/{id})
export interface AssetDetails {
	id: string;
	type: AssetType;
	originalFileName: string;
	originalMimeType: string | null;
	width: number | null;
	height: number | null;
	make: string | null;
	model: string | null;
	projectionType: string | null;
	fileSize: number | null;
	// Immuch360: what the one-key rotation reads (src/immuch360/rotation/mode.ts), and the thumbhash that changes once the
	// server made a turned picture
	ownerId: string | null;
	livePhotoVideoId: string | null;
	isTrashed: boolean;
	thumbhash: string | null;
}

export interface TimelineBucket {
	timeBucket: string;
	count: number;
}

export interface DayGroup {
	timeBucket: string;
	assets: TimelineAsset[];
	count: number;
	// Immuch360: the heading of a group that is no day (a folder of a network share)
	label?: string;
}

export interface Album {
	id: string;
	albumName: string;
	description: string;
	albumThumbnailAssetId: string | null;
	assetCount: number;
}

export type AssetOrder = 'asc' | 'desc';

export interface AlbumDetails extends Album {
	order: AssetOrder;
}

// The empty scope is the main library timeline.
export interface TimelineScope {
	albumId?: string;
	personId?: string;
	order?: AssetOrder;
}

export const MAIN_TIMELINE: TimelineScope = {};

export interface Place {
	city: string;
	country: string | null;
	thumbnailAssetId: string;
}

export interface Person {
	id: string;
	name: string;
	assetCount: number;
}
