// Immuch360: the one-key rotation wired to the Immich server of the signed-in account, and to the turns kept on this
// TV. One controller per account (per repository), for the whole app: a photo turned and left at once is still saved.

import type {PhotoRepository} from '../../domain/PhotoRepository';
import {getRotation, setRotation} from '../../utils/rotationStore';
import {RotationController, type DeviceRotations, type RotationServer, type Timers} from './controller';

/** How long the new picture is given to load before it is shown anyway */
const PRELOAD_TIMEOUT_MS = 15000;

export function rotationServerFor(repository: PhotoRepository): RotationServer {
	return {
		context: () => repository.getRotationContext(),
		asset: async (assetId) => {
			const details = await repository.getAssetDetails(assetId);
			return {
				ownerId: details.ownerId,
				type: details.type,
				originalFileName: details.originalFileName,
				livePhotoVideoId: details.livePhotoVideoId,
				isTrashed: details.isTrashed,
				projectionType: details.projectionType,
				thumbhash: details.thumbhash,
			};
		},
		edits: (assetId) => repository.getAssetEdits(assetId),
		replaceEdits: (assetId, edits) => repository.replaceAssetEdits(assetId, edits),
		pictureKey: (assetId) => repository.pictureKey(assetId),
		// The new preview is loaded first, so it takes the place of the turned one without a blank
		showPicture: (assetId, key) =>
			new Promise<void>((resolve) => {
				let settled = false;
				const show = () => {
					if (settled) return;
					settled = true;
					repository.setPictureKey(assetId, key);
					resolve();
				};
				const image = new Image();
				image.onload = show;
				image.onerror = show;
				image.src = repository.previewUrl(assetId, key);
				window.setTimeout(show, PRELOAD_TIMEOUT_MS);
			}),
	};
}

const deviceRotations: DeviceRotations = {
	turns: (assetId) => getRotation(assetId) / 90,
	setTurns: (assetId, turns) => {
		setRotation(assetId, turns * 90);
	},
};

const windowTimers: Timers = {
	set: (callback, ms) => window.setTimeout(callback, ms),
	clear: (handle) => window.clearTimeout(handle as number),
};

const controllers = new WeakMap<PhotoRepository, RotationController>();

/** The rotation controller of the account of this repository */
export function rotationControllerFor(repository: PhotoRepository): RotationController {
	let controller = controllers.get(repository);
	if (!controller) {
		controller = new RotationController(rotationServerFor(repository), deviceRotations, windowTimers);
		controllers.set(repository, controller);
	}
	return controller;
}
