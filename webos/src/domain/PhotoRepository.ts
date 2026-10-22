import type {Album, AlbumDetails, AssetDetails, Person, Place, TimelineAsset, TimelineBucket, TimelineScope} from './types';
import type {AssetEdit} from '../immuch360/rotation/edits';
import type {RotationContext} from '../immuch360/rotation/mode';

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

	// Immuch360: the pictures carry the cache key of the asset (pictureKey), or the one given
	thumbnailUrl(assetId: string, pictureKey?: string | null): string;
	previewUrl(assetId: string, pictureKey?: string | null): string;
	// Immuch360: the picture of a photo zoomed in past 2x (src/immuch360/photoSize.ts)
	fullsizeUrl(assetId: string, pictureKey?: string | null): string;
	videoPlaybackUrl(assetId: string): string;
	faceUrl(personId: string): string;

	// Immuch360: the 360° viewer and the diagnostics page
	getAssetDetails(assetId: string): Promise<AssetDetails>;
	// Immuch360: the details of every photo opened are read (a network share: its listing tells no size, so a 360°
	// photo is only known by the GPano tags of its head); Immich tells the 360° flag in its timeline instead
	readonly detailsForEveryPhoto?: boolean;
	fetchPreviewBytes(assetId: string, signal?: AbortSignal): Promise<ArrayBuffer>;
	getServerVersion(): Promise<string | null>;
	serverUrl(): string;

	// Immuch360: the one-key rotation (src/immuch360/rotation/): who is signed in on which server, the edits of a photo
	// in Immich's photo editor, and the cache key of the pictures of an asset (its thumbhash, or the one a turn gave it)
	getRotationContext(): Promise<RotationContext>;
	getAssetEdits(assetId: string): Promise<AssetEdit[] | null>;
	replaceAssetEdits(assetId: string, edits: AssetEdit[]): Promise<void>;
	pictureKey(assetId: string): string | null;
	setPictureKey(assetId: string, key: string): void;
}
