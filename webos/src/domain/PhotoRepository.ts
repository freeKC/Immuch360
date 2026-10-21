import type {Album, AlbumDetails, AssetDetails, Person, Place, TimelineAsset, TimelineBucket, TimelineScope} from './types';

export interface PhotoRepository {
	getBuckets(scope?: TimelineScope): Promise<TimelineBucket[]>;
	getBucketAssets(timeBucket: string, scope?: TimelineScope, signal?: AbortSignal): Promise<TimelineAsset[]>;

	getAlbums(): Promise<Album[]>;
	getAlbum(albumId: string): Promise<AlbumDetails>;

	getPeople(): Promise<Person[]>;

	getPlaces(): Promise<Place[]>;

	searchSmart(query: string): Promise<TimelineAsset[]>;
	searchByCity(city: string): Promise<TimelineAsset[]>;
	searchRandomImages(scope: TimelineScope, size: number): Promise<TimelineAsset[]>;

	thumbnailUrl(assetId: string): string;
	previewUrl(assetId: string): string;
	// Immuch360: the picture of a photo zoomed in past 2x (src/immuch360/photoSize.ts)
	fullsizeUrl(assetId: string): string;
	videoPlaybackUrl(assetId: string): string;
	faceUrl(personId: string): string;

	// Immuch360: the 360° viewer and the diagnostics page
	getAssetDetails(assetId: string): Promise<AssetDetails>;
	fetchPreviewBytes(assetId: string, signal?: AbortSignal): Promise<ArrayBuffer>;
	getServerVersion(): Promise<string | null>;
	serverUrl(): string;
}
