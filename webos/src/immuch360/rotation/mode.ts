// Immuch360: where the one-key rotation of a flat photo is kept, as the Flutter app decides it
// (rotationModeFamily, mobile/lib/providers/asset_viewer/view_rotation.provider.dart on branch feat-rotate).
//
// - server: an edit of Immich's photo editor (PUT /api/assets/{id}/edits), so the photo shows turned everywhere, on
//   the web and on the other devices: a photo of the signed-in user, on a server that takes edits (2.6.0 and later),
//   that the server can edit (not a motion photo, a GIF, an SVG, a 360° photo, nor one in the trash);
// - device: kept on this TV only (src/utils/rotationStore.ts): a photo of a partner or of a shared album, an older
//   server, or one the server refuses.
// The viewer never turns a video nor a photo it shows on the 360° sphere.

export type RotationMode = 'server' | 'device';

/** Who is signed in and which server, as GET /api/users/me and GET /api/server/version say; null when unknown */
export interface RotationContext {
	userId: string | null;
	serverVersion: {major: number; minor: number; patch: number} | null;
}

/** What the rule reads of an asset (GET /api/assets/{id}) */
export interface RotationAsset {
	ownerId: string | null;
	type: 'IMAGE' | 'VIDEO';
	originalFileName: string;
	livePhotoVideoId: string | null;
	isTrashed: boolean;
	projectionType: string | null;
}

/** The first version of Immich whose edits the apps of Immuch360 write (the Flutter app's syncAssetEditsV1) */
export const EDITS_SINCE = {major: 2, minor: 6, patch: 0};

/** Whether a server of that version takes the edits of the photo editor */
export function takesEdits(version: RotationContext['serverVersion']): boolean {
	if (!version) return false;
	if (version.major !== EDITS_SINCE.major) return version.major > EDITS_SINCE.major;
	if (version.minor !== EDITS_SINCE.minor) return version.minor > EDITS_SINCE.minor;
	return version.patch >= EDITS_SINCE.patch;
}

/** Where the rotation of that photo is kept */
export function rotationMode(context: RotationContext, asset: RotationAsset): RotationMode {
	const name = asset.originalFileName.toLowerCase();
	const editable =
		asset.type === 'IMAGE' &&
		!asset.livePhotoVideoId &&
		!asset.isTrashed &&
		!name.endsWith('.gif') &&
		!name.endsWith('.svg') &&
		// The server's isPanorama
		!name.endsWith('.insp') &&
		(asset.projectionType ?? '').toUpperCase() !== 'EQUIRECTANGULAR';
	const owned = !!context.userId && asset.ownerId === context.userId;
	return editable && owned && takesEdits(context.serverVersion) ? 'server' : 'device';
}
