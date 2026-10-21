import {APIError, type APIClient} from './client';
import type {
	ColumnarAssetResponse,
	ImmichAlbum,
	ImmichAlbumDetails,
	ImmichAsset,
	ImmichAssetEdits,
	ImmichPerson,
	ImmichServerAbout,
	ImmichServerVersion,
	ImmichUser,
	PeopleResponse,
} from './types';
import type {PhotoRepository} from '../domain/PhotoRepository';
import {editsFromServer, type AssetEdit} from '../immuch360/rotation/edits';
import type {RotationContext} from '../immuch360/rotation/mode';
import {MAIN_TIMELINE, type Album, type AlbumDetails, type AssetDetails, type Person, type Place, type TimelineAsset, type TimelineBucket, type TimelineScope} from '../domain/types';
import {toDurationSeconds} from '../utils/FormattingService';

interface ImmichSearchResponse {
	assets: {items: ImmichAsset[]; nextPage?: string | null};
}

const PEOPLE_LIMIT = 50;
const SEARCH_PAGE_SIZE = 500;
// Pages are fetched sequentially and laid out in one go (cities have no timeline scope): keep it TV-sized.
const METADATA_SEARCH_PAGE_SIZE = 1000;
const METADATA_SEARCH_MAX_PAGES = 3;
// Matches the official web client's main timeline: without visibility=timeline the server
// defaults to ('archive','timeline') and archived assets leak in.
const TIMELINE_FILTER_PARAMS = 'visibility=timeline&withPartners=true&withStacked=true';

function timelineScopeParams(scope: TimelineScope): string {
	// Unfiltered like the web client: archived assets stay visible inside albums.
	if (scope.albumId) return `albumId=${scope.albumId}&order=${scope.order ?? 'desc'}`;
	if (scope.personId) return `personId=${scope.personId}&visibility=timeline`;
	return TIMELINE_FILTER_PARAMS;
}

// Immuch360: the cache keys of the pictures of this many assets are kept (the latest seen); past it, a picture's URL
// goes without one, as before
const MAX_PICTURE_KEYS = 20000;

const pad2 = (n: number): string => (n < 10 ? '0' + n : '' + n);
const pad3 = (n: number): string => (n < 10 ? '00' + n : n < 100 ? '0' + n : '' + n);

// ISO-8601 UTC string, byte-identical to Date.toISOString for years 0000–9999. Hand-formatted via
// getUTC* (not toISOString) because this runs per asset on every month load and the timeline only
// reads it back as YYYY-MM / YYYY-MM-DD — skipping sub-second formatting drops ~27%/asset.
function utcMillisToIso(ms: number): string {
	const d = new Date(ms);
	return (
		String(d.getUTCFullYear()).padStart(4, '0') +
		'-' + pad2(d.getUTCMonth() + 1) +
		'-' + pad2(d.getUTCDate()) +
		'T' + pad2(d.getUTCHours()) +
		':' + pad2(d.getUTCMinutes()) +
		':' + pad2(d.getUTCSeconds()) +
		'.' + pad3(d.getUTCMilliseconds()) + 'Z'
	);
}

// Immich v3 omits the zone on UTC timestamps, which Date would parse as TV-local time.
function parseUtcMillis(iso: string): number {
	const zoned = iso.endsWith('Z') || iso.indexOf('+', 19) >= 0 || iso.indexOf('-', 19) >= 0;
	return new Date(zoned ? iso : iso + 'Z').getTime();
}

// The server buckets months on localDateTime but its columnar payload only carries UTC
// fileCreatedAt (+ localOffsetHours on recent servers, localDateTime array on older ones).
function columnarLocalDateTime(columnar: ColumnarAssetResponse, i: number): string {
	const fileCreatedAt = columnar.fileCreatedAt[i]!;
	const offsetHours = columnar.localOffsetHours?.[i];
	if (typeof offsetHours === 'number') {
		return utcMillisToIso(parseUtcMillis(fileCreatedAt) + offsetHours * 3600 * 1000);
	}
	return columnar.localDateTime?.[i] ?? fileCreatedAt;
}

// Immich's bucket timeline returns assets column-wise (parallel arrays).
function transformColumnarResponse(columnar: ColumnarAssetResponse): TimelineAsset[] {
	const len = columnar.id.length;
	const ratios = columnar.ratio?.length === len ? columnar.ratio : null;
	return columnar.id.map((id, i) => ({
		id,
		type: columnar.isImage[i]! ? 'IMAGE' : 'VIDEO',
		ratio: ratios ? ratios[i]! : 1,
		localDateTime: columnarLocalDateTime(columnar, i),
		durationSeconds: toDurationSeconds(columnar.duration[i]),
		city: columnar.city?.[i],
		country: columnar.country?.[i],
		projectionType: columnar.projectionType?.[i],
	}));
}

export class ImmichRepository implements PhotoRepository {
	private client: APIClient;
	// Immuch360: the thumbhash of each asset seen in a timeline or a search, the cache key of its pictures
	private readonly thumbhashes = new Map<string, string>();
	// Immuch360: the key a turn made on this TV gave the pictures of an asset, ahead of the thumbhash seen before it
	private readonly turnedKeys = new Map<string, string>();
	private rotationContext: Promise<RotationContext> | null = null;

	constructor(client: APIClient) {
		this.client = client;
	}

	private rememberThumbhash(id: string, thumbhash: string | null | undefined): void {
		if (!thumbhash) return;
		this.thumbhashes.delete(id);
		this.thumbhashes.set(id, thumbhash);
		if (this.thumbhashes.size > MAX_PICTURE_KEYS) {
			const oldest = this.thumbhashes.keys().next();
			if (!oldest.done) this.thumbhashes.delete(oldest.value);
		}
	}

	private mapAlbum(a: ImmichAlbum): Album {
		return {
			id: a.id,
			albumName: a.albumName,
			description: a.description,
			albumThumbnailAssetId: a.albumThumbnailAssetId,
			assetCount: a.assetCount,
		};
	}

	private mapPerson(p: ImmichPerson): Person {
		return {id: p.id, name: p.name, assetCount: p.assetCount ?? 0};
	}

	public async getBuckets(scope: TimelineScope = MAIN_TIMELINE): Promise<TimelineBucket[]> {
		return this.client.fetch<TimelineBucket[]>(`/timeline/buckets?${timelineScopeParams(scope)}`);
	}

	public async getBucketAssets(timeBucket: string, scope: TimelineScope = MAIN_TIMELINE, signal?: AbortSignal): Promise<TimelineAsset[]> {
		const columnar = await this.client.fetch<ColumnarAssetResponse>(
			`/timeline/bucket?timeBucket=${timeBucket}&${timelineScopeParams(scope)}`,
			{signal}
		);
		const thumbhashes = Array.isArray(columnar.thumbhash) && columnar.thumbhash.length === columnar.id.length ? columnar.thumbhash : null;
		if (thumbhashes) columnar.id.forEach((id, i) => this.rememberThumbhash(id, thumbhashes[i]));
		return transformColumnarResponse(columnar);
	}

	public async getAlbums(): Promise<Album[]> {
		const albums = await this.client.fetch<ImmichAlbum[]>('/albums');
		return albums.map((a) => this.mapAlbum(a));
	}

	// Assets load through the album-scoped timeline; withoutAssets stops pre-v3 servers embedding them.
	public async getAlbum(albumId: string): Promise<AlbumDetails> {
		const details = await this.client.fetch<ImmichAlbumDetails>(`/albums/${albumId}?withoutAssets=true`);
		return {
			...this.mapAlbum(details),
			order: details.order ?? 'desc',
		};
	}

	private assetFromImmichAsset(a: ImmichAsset): TimelineAsset {
		const w = a.exifInfo?.exifImageWidth ?? a.width;
		const h = a.exifInfo?.exifImageHeight ?? a.height;
		return {
			id: a.id,
			type: a.type === 'VIDEO' ? 'VIDEO' : 'IMAGE',
			ratio: w && h ? w / h : 1,
			localDateTime: a.localDateTime ?? a.fileCreatedAt,
			durationSeconds: toDurationSeconds(a.duration),
			city: a.exifInfo?.city,
			country: a.exifInfo?.country,
			projectionType: a.exifInfo?.projectionType,
		};
	}

	public async getPeople(): Promise<Person[]> {
		const response = await this.client.fetch<PeopleResponse>('/people');
		return response.people
			.filter((p) => !p.isHidden)
			.sort((a, b) => (b.assetCount ?? 0) - (a.assetCount ?? 0))
			.slice(0, PEOPLE_LIMIT)
			.map((p) => this.mapPerson(p));
	}

	public async getPlaces(): Promise<Place[]> {
		// One representative asset per city, exifInfo populated on every server version
		const assets = await this.client.fetch<ImmichAsset[]>('/search/cities');
		if (!Array.isArray(assets)) return [];
		return assets
			.flatMap((a) => {
				const city = a.exifInfo?.city;
				if (!city) return [];
				return [{city, country: a.exifInfo?.country ?? null, thumbnailAssetId: a.id}];
			})
			.sort((a, b) => a.city.localeCompare(b.city));
	}

	public async searchSmart(query: string): Promise<TimelineAsset[]> {
		const response = await this.client.fetch<ImmichSearchResponse>('/search/smart', {
			method: 'POST',
			body: JSON.stringify({query, size: SEARCH_PAGE_SIZE}),
		});
		return this.searchItemsToAssets(response);
	}

	public async searchByCity(city: string): Promise<TimelineAsset[]> {
		const assets: TimelineAsset[] = [];
		let page: string | null | undefined = '1';
		for (let i = 0; page && i < METADATA_SEARCH_MAX_PAGES; i++) {
			const response: ImmichSearchResponse = await this.client.fetch<ImmichSearchResponse>('/search/metadata', {
				method: 'POST',
				body: JSON.stringify({city, page: Number(page), size: METADATA_SEARCH_PAGE_SIZE}),
			});
			assets.push(...this.searchItemsToAssets(response));
			page = response.assets?.nextPage;
		}
		return assets;
	}

	public async searchRandomImages(scope: TimelineScope, size: number): Promise<TimelineAsset[]> {
		// Same visibility rules as timelineScopeParams.
		const filter = scope.albumId
			? {albumIds: [scope.albumId]}
			: {visibility: 'timeline', personIds: scope.personId ? [scope.personId] : undefined};
		const items = await this.client.fetch<ImmichAsset[]>('/search/random', {
			method: 'POST',
			body: JSON.stringify({...filter, type: 'IMAGE', size}),
		});
		return this.visibleAssets(items);
	}

	private searchItemsToAssets(response: ImmichSearchResponse): TimelineAsset[] {
		return this.visibleAssets(response.assets?.items);
	}

	private visibleAssets(items: ImmichAsset[] | undefined): TimelineAsset[] {
		if (!Array.isArray(items)) return [];
		return items
			// Search returns hidden assets (live-photo companion videos) whose thumbnails 404
			.filter((a) => a.visibility !== 'hidden' && a.visibility !== 'locked')
			.map((a) => {
				this.rememberThumbhash(a.id, a.thumbhash);
				return this.assetFromImmichAsset(a);
			});
	}

	public thumbnailUrl(assetId: string, pictureKey?: string | null): string {
		return this.client.getThumbnailUrl(assetId, 'thumbnail', pictureKey ?? this.pictureKey(assetId));
	}

	public previewUrl(assetId: string, pictureKey?: string | null): string {
		return this.client.getThumbnailUrl(assetId, 'preview', pictureKey ?? this.pictureKey(assetId));
	}

	// Immuch360: the full-size picture when the server generates one, else it redirects to the preview
	public fullsizeUrl(assetId: string, pictureKey?: string | null): string {
		return this.client.getThumbnailUrl(assetId, 'fullsize', pictureKey ?? this.pictureKey(assetId));
	}

	// Immuch360: the cache key of the pictures of an asset: the one a turn on this TV gave them, else its thumbhash
	public pictureKey(assetId: string): string | null {
		return this.turnedKeys.get(assetId) ?? this.thumbhashes.get(assetId) ?? null;
	}

	public setPictureKey(assetId: string, key: string): void {
		this.turnedKeys.set(assetId, key);
	}

	public videoPlaybackUrl(assetId: string): string {
		return this.client.getVideoPlaybackUrl(assetId);
	}

	public faceUrl(personId: string): string {
		return this.client.getFaceThumbnailUrl(personId);
	}

	// Immuch360: the name, size, camera and 360° flag the viewer decides with
	public async getAssetDetails(assetId: string): Promise<AssetDetails> {
		const a = await this.client.fetch<ImmichAsset>(`/assets/${assetId}`);
		const width = a.exifInfo?.exifImageWidth ?? a.width ?? null;
		const height = a.exifInfo?.exifImageHeight ?? a.height ?? null;
		return {
			id: a.id,
			type: a.type === 'VIDEO' ? 'VIDEO' : 'IMAGE',
			originalFileName: a.originalFileName ?? '',
			originalMimeType: a.originalMimeType ?? null,
			width: width || null,
			height: height || null,
			make: a.exifInfo?.make ?? null,
			model: a.exifInfo?.model ?? null,
			projectionType: a.exifInfo?.projectionType ?? null,
			fileSize: a.exifInfo?.fileSizeInByte ?? null,
			ownerId: a.ownerId ?? null,
			livePhotoVideoId: a.livePhotoVideoId ?? null,
			isTrashed: a.isTrashed ?? false,
			thumbhash: a.thumbhash ?? null,
		};
	}

	// Immuch360: the preview the sphere is drawn from, and where its GPano tags are read
	public fetchPreviewBytes(assetId: string, signal?: AbortSignal): Promise<ArrayBuffer> {
		return this.client.fetchMediaBytes(this.previewUrl(assetId), signal);
	}

	// Immuch360: the version the diagnostics page shows; null when the server does not say
	public async getServerVersion(): Promise<string | null> {
		try {
			const about = await this.client.fetch<ImmichServerAbout>('/server/about');
			return about.version ?? null;
		} catch {
			return null;
		}
	}

	public serverUrl(): string {
		return this.client.getBaseUrl();
	}

	// Immuch360: who is signed in, on which version of Immich; asked once, again after a failure. A part the server
	// does not give (an API key without the user.read permission) is null, and the rotation then stays on the TV.
	public getRotationContext(): Promise<RotationContext> {
		if (!this.rotationContext) {
			const asked = Promise.all([
				this.client.fetch<ImmichUser>('/users/me').then((user) => user.id || null, () => null),
				this.client.fetch<ImmichServerVersion>('/server/version').then(
					(version) => (typeof version.major === 'number' ? {major: version.major, minor: version.minor ?? 0, patch: version.patch ?? 0} : null),
					() => null
				),
			]).then(([userId, serverVersion]) => {
				if (!userId || !serverVersion) this.rotationContext = null;
				return {userId, serverVersion};
			});
			this.rotationContext = asked;
		}
		return this.rotationContext;
	}

	// Immuch360: the edits of a photo in Immich's photo editor, null when one is of a kind this app does not know
	public async getAssetEdits(assetId: string): Promise<AssetEdit[] | null> {
		const response = await this.client.fetch<ImmichAssetEdits>(`/assets/${assetId}/edits`);
		return editsFromServer(Array.isArray(response.edits) ? response.edits : []);
	}

	// Immuch360: replaces the edits of a photo (the server then makes its pictures again); an empty list removes them
	public async replaceAssetEdits(assetId: string, edits: AssetEdit[]): Promise<void> {
		if (edits.length) {
			await this.client.fetch(`/assets/${assetId}/edits`, {method: 'PUT', body: JSON.stringify({edits})});
		} else {
			await this.client.fetch(`/assets/${assetId}/edits`, {method: 'DELETE'});
		}
	}
}

export async function validateAuth(client: APIClient): Promise<boolean> {
	try {
		await client.fetch('/users/me');
		return true;
	} catch (error) {
		if (error instanceof APIError && error.status === 401) return false;
		throw error;
	}
}
