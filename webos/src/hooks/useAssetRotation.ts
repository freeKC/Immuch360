import {useCallback, useSyncExternalStore} from 'react';
import {useRepository} from '../domain/RepositoryContext';
import type {Rotation} from '../utils/rotationStore';
import type {RotationNotice, RotationPhase} from '../immuch360/rotation/controller';
import {rotationControllerFor} from '../immuch360/rotation/server';

export interface AssetRotation {
	/** The turn to draw on top of the picture shown, in degrees */
	rotation: Rotation;
	/** A quarter turn, clockwise unless -1 is given (an event passed by onClick counts as clockwise) */
	rotate: (quarterTurns?: unknown) => void;
	/** What the viewer says about the last turn of this photo */
	notice: RotationNotice | null;
	/** Where the turn of this photo stands: 'turning' while the viewer shows that it works */
	phase: RotationPhase;
}

// Immuch360: the one-key rotation of the photo shown: kept on the server as an edit for the user's own photos on a
// server that takes them, on this TV otherwise (src/immuch360/rotation/). The slideshow shows the turns kept on the
// TV; those on the server are in the pictures themselves.
export const useAssetRotation = (assetId: string | undefined): AssetRotation => {
	const repository = useRepository();
	const controller = rotationControllerFor(repository);
	useSyncExternalStore(controller.subscribe, controller.snapshot);
	const rotate = useCallback(
		(quarterTurns?: unknown) => {
			if (assetId) controller.rotate(assetId, quarterTurns === -1 ? -1 : 1);
		},
		[controller, assetId]
	);
	return {
		rotation: (assetId ? controller.displayTurns(assetId) * 90 : 0) as Rotation,
		rotate,
		notice: assetId ? controller.notice(assetId) : null,
		phase: assetId ? controller.phase(assetId) : 'idle',
	};
};
