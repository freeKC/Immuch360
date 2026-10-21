import {useCallback, useReducer} from 'react';
import {getRotation, rotateBy, type Rotation} from '../utils/rotationStore';

// Immuch360: the rotation of the photo shown, and a quarter turn either way (1 clockwise, -1 counterclockwise). The
// turn is kept for that photo on this TV (rotationStore) and the slideshow shows it too.
export const useAssetRotation = (assetId: string | undefined): [Rotation, (quarterTurns?: 1 | -1) => void] => {
	const [, rerender] = useReducer((n: number) => n + 1, 0);
	const rotate = useCallback(
		(quarterTurns: 1 | -1 = 1) => {
			if (!assetId) return;
			rotateBy(assetId, quarterTurns === -1 ? -1 : 1);
			rerender();
		},
		[assetId]
	);
	return [assetId ? getRotation(assetId) : 0, rotate];
};
