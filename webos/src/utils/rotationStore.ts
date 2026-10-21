export type Rotation = 0 | 90 | 180 | 270;

// Immuch360: the turns kept on this TV, per photo: those of photos whose rotation the server does not keep (a partner's,
// a shared album's, an older server's), and, until the server holds them, those of the photos it does keep
// (src/immuch360/rotation/controller.ts).
const STORAGE_KEY = 'immich_rotations';
const MAX_ENTRIES = 1000;

let rotations: Record<string, Rotation> | null = null;

function load(): Record<string, Rotation> {
	if (!rotations) {
		try {
			rotations = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? '{}') ?? {};
		} catch {
			rotations = {};
		}
	}
	return rotations!;
}

export function getRotation(assetId: string): Rotation {
	return load()[assetId] ?? 0;
}

export function rotateClockwise(assetId: string): Rotation {
	return rotateBy(assetId, 1);
}

// Immuch360: one quarter turn either way, 1 clockwise and -1 counterclockwise
export function rotateBy(assetId: string, quarterTurns: 1 | -1): Rotation {
	return setRotation(assetId, getRotation(assetId) + 90 * quarterTurns);
}

// Immuch360: sets the turn of a photo, in degrees (any multiple of 90; 0 forgets it)
export function setRotation(assetId: string, degrees: number): Rotation {
	const map = load();
	const next = ((((Math.round(degrees / 90) % 4) + 4) % 4) * 90) as Rotation;
	// Re-inserting keeps keys in recency order (UUID keys preserve insertion order), so the
	// oldest entries are the ones trimmed.
	delete map[assetId];
	if (next) map[assetId] = next;
	const ids = Object.keys(map);
	for (let i = 0; i < ids.length - MAX_ENTRIES; i++) delete map[ids[i]!];
	try {
		localStorage.setItem(STORAGE_KEY, JSON.stringify(map));
	} catch {
		// Storage unavailable: the rotation still applies for this session.
	}
	return next;
}
