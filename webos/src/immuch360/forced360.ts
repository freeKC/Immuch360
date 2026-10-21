// Immuch360: the assets the user chose to view as 360° although the server does not flag them ("View as 360°"), and
// the 3D layout and coverage chosen for an asset. Kept on the TV only (localStorage), the latest 1000 choices, as
// ForcedPanoramaAssets does on the phones.

import type {SphereCoverage, StereoLayout} from './sphere/rules';

const FORCED_KEY = 'immuch360_forced_360';
const CHOICES_KEY = 'immuch360_sphere_choices';
const MAX_ENTRIES = 1000;

export interface SphereChoice {
	layout?: StereoLayout;
	coverage?: SphereCoverage;
}

function read<T>(key: string, fallback: T): T {
	try {
		const raw = window.localStorage.getItem(key);
		return raw ? (JSON.parse(raw) as T) : fallback;
	} catch {
		return fallback;
	}
}

function write(key: string, value: unknown): void {
	try {
		window.localStorage.setItem(key, JSON.stringify(value));
	} catch {
		// a full or missing storage only loses the choice
	}
}

// Read once: every tile of the timeline asks
let forcedCache: string[] | null = null;

function forcedList(): string[] {
	if (!forcedCache) {
		const list = read<string[]>(FORCED_KEY, []);
		forcedCache = Array.isArray(list) ? list : [];
	}
	return forcedCache;
}

export function isForced360(assetId: string): boolean {
	return forcedList().indexOf(assetId) >= 0;
}

export function setForced360(assetId: string, forced: boolean): void {
	const list = forcedList().filter((id) => id !== assetId);
	if (forced) list.push(assetId);
	forcedCache = list.slice(-MAX_ENTRIES);
	write(FORCED_KEY, forcedCache);
}

export function sphereChoice(assetId: string): SphereChoice {
	const all = read<Record<string, SphereChoice>>(CHOICES_KEY, {});
	return (all && all[assetId]) || {};
}

export function setSphereChoice(assetId: string, choice: SphereChoice): void {
	const all = read<Record<string, SphereChoice>>(CHOICES_KEY, {});
	delete all[assetId];
	all[assetId] = choice;
	const keys = Object.keys(all);
	for (const key of keys.slice(0, Math.max(0, keys.length - MAX_ENTRIES))) delete all[key];
	write(CHOICES_KEY, all);
}
