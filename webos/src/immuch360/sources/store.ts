// Immuch360: the sources of the TV, kept in localStorage as the inherited app keeps the Immich tokens (a known limit of
// webOS apps: there is no keystore). The bridge gets them at each start, over Luna.

import type {SourceConfig, SourceKind} from './types';

const SOURCES_KEY = 'immuch360_sources';
const CLIENT_ID_KEY = 'immuch360_plex_client_id';
const KINDS: SourceKind[] = ['smb', 'webdav', 'dlna', 'plex', 'tapo'];

type Listener = () => void;

/** The kept sources, the invalid ones left out */
export function parseSources(text: string | null): SourceConfig[] {
	if (!text) return [];
	try {
		const list: unknown = JSON.parse(text);
		if (!Array.isArray(list)) return [];
		return list.filter(
			(s): s is SourceConfig =>
				!!s && typeof s === 'object' && typeof (s as SourceConfig).id === 'string' && KINDS.indexOf((s as SourceConfig).kind) >= 0 && typeof (s as SourceConfig).name === 'string'
		);
	} catch {
		return [];
	}
}

function randomHex(bytes: number): string {
	const values = new Uint8Array(bytes);
	if (typeof crypto !== 'undefined' && crypto.getRandomValues) crypto.getRandomValues(values);
	else for (let i = 0; i < bytes; i++) values[i] = Math.floor(Math.random() * 256);
	return Array.prototype.map.call(values, (v: number) => (v < 16 ? '0' : '') + v.toString(16)).join('');
}

/** A new source id: letters and digits the bridge accepts */
export const newSourceId = (): string => randomHex(8);

export interface SourceStore {
	list(): SourceConfig[];
	get(id: string): SourceConfig | null;
	save(source: SourceConfig): void;
	remove(id: string): void;
	subscribe(listener: Listener): () => void;
	plexClientId(): string;
}

/** The store over a Storage (localStorage on the TV, a fake in the tests) */
export function createSourceStore(storage: Pick<Storage, 'getItem' | 'setItem'> | null): SourceStore {
	let cache: SourceConfig[] | null = null;
	const listeners = new Set<Listener>();
	const read = (): SourceConfig[] => {
		if (cache === null) {
			try {
				cache = parseSources(storage ? storage.getItem(SOURCES_KEY) : null);
			} catch {
				cache = [];
			}
		}
		return cache;
	};
	const write = (next: SourceConfig[]) => {
		cache = next;
		try {
			storage?.setItem(SOURCES_KEY, JSON.stringify(next));
		} catch {
			// No storage: the sources last until the app closes
		}
		listeners.forEach((listener) => listener());
	};
	let clientId: string | null = null;
	return {
		list: read,
		get: (id) => read().find((s) => s.id === id) ?? null,
		save(source) {
			const list = read();
			const at = list.findIndex((s) => s.id === source.id);
			write(at >= 0 ? list.map((s, i) => (i === at ? source : s)) : list.concat([source]));
		},
		remove(id) {
			write(read().filter((s) => s.id !== id));
		},
		subscribe(listener) {
			listeners.add(listener);
			return () => listeners.delete(listener);
		},
		plexClientId() {
			if (clientId) return clientId;
			try {
				clientId = storage?.getItem(CLIENT_ID_KEY) ?? null;
			} catch {
				clientId = null;
			}
			if (!clientId || !/^[0-9a-f]{32}$/.test(clientId)) {
				clientId = randomHex(16);
				try {
					storage?.setItem(CLIENT_ID_KEY, clientId);
				} catch {
					// Kept for this run only
				}
			}
			return clientId;
		},
	};
}

let shared: SourceStore | null = null;

/** The store of the app */
export function sourceStore(): SourceStore {
	if (!shared) shared = createSourceStore(typeof localStorage === 'undefined' ? null : localStorage);
	return shared;
}
