// Immuch360: the photos and videos of one folder of a source as a PhotoRepository, so that the grid, the viewer (360°
// sphere, zoom, details, the one-key turn kept on the TV) and the slideshow of the Immich screens show them unchanged.
// Every picture and video comes through the bridge, which sends the CORS header WebGL needs: 360° photos of a share turn
// on every webOS from 5, unlike Immich photos before webOS 25.

import type {PhotoRepository} from '../../domain/PhotoRepository';
import type {AssetDetails, TimelineAsset} from '../../domain/types';
import type {RotationContext} from '../rotation/mode';
import {bridgeUrl} from './bridgeClient';
import type {BridgeInfo, ListedFile, SourceConfig} from './types';

/** The id of a file of a source in the viewer, the rotation store and the 360° choices */
export const assetIdOf = (sourceId: string, ref: string): string => `src~${sourceId}~${ref}`;

// The tiles of what has no picture of its own: a video of a share, a photo this TV cannot decode
function tile(symbol: string, caption: string): string {
	const escape = (text: string) => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
	const svg =
		'<svg xmlns="http://www.w3.org/2000/svg" width="320" height="240" viewBox="0 0 320 240">' +
		'<rect width="320" height="240" fill="#2a2d33"/>' +
		`<text x="160" y="125" font-size="64" text-anchor="middle" fill="#9aa0a6" font-family="sans-serif">${escape(symbol)}</text>` +
		(caption ? `<text x="160" y="190" font-size="18" text-anchor="middle" fill="#9aa0a6" font-family="sans-serif">${escape(caption)}</text>` : '') +
		'</svg>';
	return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}

/** The shape of a file before its picture is read: the size the server told, else a 3:2 photo or a 16:9 video */
function ratioOf(file: ListedFile): number {
	if (file.width && file.height) return file.width / file.height;
	return file.kind === 'video' ? 16 / 9 : 3 / 2;
}

function localDateTime(file: ListedFile): string {
	return new Date(file.modified && Number.isFinite(file.modified) ? file.modified : 0).toISOString();
}

interface Options {
	/** The text of the tile of a photo the TV cannot decode */
	unsupportedCaption: string;
	/** The TV's screen, for the photos Plex makes at its size */
	screen?: {width: number; height: number};
	fetch?: (url: string, init?: {signal?: AbortSignal}) => Promise<{ok: boolean; status: number; arrayBuffer(): Promise<ArrayBuffer>; json(): Promise<unknown>}>;
}

export class SourceRepository implements PhotoRepository {
	readonly assets: TimelineAsset[];
	// The listing of SMB and WebDAV tells no size: the head of each photo opened says whether it is a 360° photo
	readonly detailsForEveryPhoto = true;
	private files = new Map<string, ListedFile>();
	private keys = new Map<string, string>();
	private info: BridgeInfo;
	private source: SourceConfig;
	private options: Options;

	constructor(info: BridgeInfo, source: SourceConfig, files: ListedFile[], options: Options) {
		this.info = info;
		this.source = source;
		this.options = options;
		this.assets = files.map((file) => {
			const id = assetIdOf(source.id, file.ref);
			this.files.set(id, file);
			return {
				id,
				type: file.kind === 'video' ? 'VIDEO' : 'IMAGE',
				ratio: ratioOf(file),
				localDateTime: localDateTime(file),
				durationSeconds: file.kind === 'video' && file.duration ? file.duration : null,
				projectionType: null,
				fileName: file.name,
			};
		});
	}

	private file(id: string): ListedFile {
		const file = this.files.get(id);
		if (!file) throw new Error('Not a file of this folder');
		return file;
	}

	private url(route: string, file: ListedFile, extra?: Record<string, string | number | null | undefined>): string {
		return bridgeUrl(this.info, route, {s: this.source.id, r: file.ref, ...(extra || {})});
	}

	thumbnailUrl(assetId: string): string {
		const file = this.file(assetId);
		if (file.kind === 'unsupported') return tile('HEIC', this.options.unsupportedCaption);
		const kind = this.source.kind;
		if (kind === 'plex' || kind === 'dlna') {
			if (file.thumb) return this.url('thumb', file, {t: file.thumb});
			return file.kind === 'video' ? tile('▶', '') : this.previewUrl(assetId);
		}
		// SMB and WebDAV: the EXIF thumbnail of a JPEG (the grid falls back on the photo when there is none)
		if (file.kind === 'video') return tile('▶', '');
		return this.url('thumb', file);
	}

	previewUrl(assetId: string): string {
		const file = this.file(assetId);
		if (file.kind === 'unsupported') return this.thumbnailUrl(assetId);
		if (this.source.kind === 'plex' && file.kind === 'image') {
			const screen = this.options.screen ?? {width: 1920, height: 1080};
			return this.url('photo', file, {w: screen.width, h: screen.height});
		}
		return this.url('file', file);
	}

	fullsizeUrl(assetId: string): string {
		const file = this.file(assetId);
		return file.kind === 'unsupported' ? this.thumbnailUrl(assetId) : this.url('file', file);
	}

	videoPlaybackUrl(assetId: string): string {
		const file = this.file(assetId);
		if (this.source.kind === 'plex' && file.direct === false && file.ratingKey) {
			return bridgeUrl(this.info, 'hls', {s: this.source.id, k: file.ratingKey});
		}
		// A DLNA server serves its media over plain HTTP without a password: the player reads them straight
		if (this.source.kind === 'dlna' && /^http:\/\//.test(file.ref)) return file.ref;
		return this.url('file', file);
	}

	faceUrl(): string {
		return '';
	}

	async getAssetDetails(assetId: string): Promise<AssetDetails> {
		const file = this.file(assetId);
		const details: AssetDetails = {
			id: assetId,
			type: file.kind === 'video' ? 'VIDEO' : 'IMAGE',
			originalFileName: file.name,
			originalMimeType: file.mime,
			width: file.width ?? null,
			height: file.height ?? null,
			make: null,
			model: null,
			projectionType: null,
			fileSize: file.size,
			ownerId: null,
			livePhotoVideoId: null,
			isTrashed: false,
			thumbhash: null,
		};
		// The head of a JPEG tells its size, its camera and whether it is a 360° photo (GPano)
		if (file.kind === 'image' && (file.mime === 'image/jpeg' || /\.jpe?g$/i.test(file.name)) && this.options.fetch) {
			try {
				const response = await this.options.fetch(this.url('meta', file));
				if (response.ok) {
					const meta = (await response.json()) as {width?: number; height?: number; make?: string; model?: string; projection?: string};
					details.width = meta.width ?? details.width;
					details.height = meta.height ?? details.height;
					details.make = meta.make ?? null;
					details.model = meta.model ?? null;
					if (meta.projection === 'equirectangular') details.projectionType = 'EQUIRECTANGULAR';
				}
			} catch {
				// The details of the listing stay
			}
		}
		return details;
	}

	async fetchPreviewBytes(assetId: string, signal?: AbortSignal): Promise<ArrayBuffer> {
		const file = this.file(assetId);
		if (!this.options.fetch) throw new Error('no fetch');
		// The original: it keeps the GPano tags, and the sphere scales it to the TV's texture size
		const response = await this.options.fetch(this.url('file', file), {signal});
		if (!response.ok) throw new Error(`HTTP ${response.status}`);
		return response.arrayBuffer();
	}

	async getServerVersion(): Promise<string | null> {
		return null;
	}

	serverUrl(): string {
		return this.source.name;
	}

	// The one-key turn of a share's photo stays on this TV
	async getRotationContext(): Promise<RotationContext> {
		return {userId: null, serverVersion: null};
	}

	async getAssetEdits(): Promise<null> {
		return null;
	}

	async replaceAssetEdits(): Promise<void> {
		throw new Error('A share keeps no edits');
	}

	pictureKey(assetId: string): string | null {
		return this.keys.get(assetId) ?? null;
	}

	setPictureKey(assetId: string, key: string): void {
		this.keys.set(assetId, key);
	}

	// What a folder has none of
	async getBuckets() {
		return [];
	}

	async getBucketAssets() {
		return [];
	}

	async getAlbums() {
		return [];
	}

	async getAlbum(): Promise<never> {
		throw new Error('A share has no albums');
	}

	async getPeople() {
		return [];
	}

	async getPlaces() {
		return [];
	}

	async searchSmart() {
		return [];
	}

	async searchByCity() {
		return [];
	}

	/** The photos of the folder in a random order, for the shuffled slideshow */
	async searchRandomImages(_scope: unknown, size: number): Promise<TimelineAsset[]> {
		const images = this.assets.filter((asset) => asset.type === 'IMAGE' && this.files.get(asset.id)?.kind === 'image');
		for (let i = images.length - 1; i > 0; i--) {
			const j = Math.floor(Math.random() * (i + 1));
			[images[i], images[j]] = [images[j]!, images[i]!];
		}
		return images.slice(0, size);
	}
}
