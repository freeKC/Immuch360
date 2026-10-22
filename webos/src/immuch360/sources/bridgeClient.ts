// Immuch360: the page's side of the media bridge. It starts the bridge in the app's JS service (Luna, or the HTTP
// stand-in of service/dev.js on a computer), hands it the sources, keeps the service alive while a source screen is
// shown (bridgeStatus every few seconds, besides the ActivityManager activity the service holds), restarts it when it
// went away (a new port and token: every URL changes, hence the generation the screens follow), and builds the URLs the
// page and the TV's player read.

import {BridgeError, type BridgeInfo, type Listing, type SourceConfig} from './types';
import type {SourceStore} from './store';

export interface BridgeTransport {
	call(method: string, params: Record<string, unknown>): Promise<Record<string, unknown>>;
}

type FetchLike = (url: string) => Promise<{ok: boolean; status: number; json(): Promise<unknown>}>;

interface ClientOptions {
	pollMs?: number;
	fetch?: FetchLike;
}

type Listener = () => void;

const POLL_MS = 3000;

function toError(value: unknown): BridgeError {
	if (value instanceof BridgeError) return value;
	if (value && typeof value === 'object') {
		const v = value as {message?: string; errorText?: string; errorCode?: string; code?: string};
		return new BridgeError(v.errorText || v.message || String(value), v.errorCode || v.code || null, null);
	}
	return new BridgeError(String(value), null, null);
}

/** A URL of the bridge: route and query parameters, under its port and token */
export function bridgeUrl(info: BridgeInfo, route: string, params?: Record<string, string | number | null | undefined>): string {
	const query = Object.keys(params || {})
		.filter((key) => params![key] !== null && params![key] !== undefined)
		.map((key) => `${encodeURIComponent(key)}=${encodeURIComponent(String(params![key]))}`)
		.join('&');
	return `http://127.0.0.1:${info.port}/${info.token}/${route}${query ? `?${query}` : ''}`;
}

export class BridgeClient {
	private transport: BridgeTransport;
	private store: SourceStore;
	private info: BridgeInfo | null = null;
	private starting: Promise<BridgeInfo> | null = null;
	private holders = 0;
	private timer: ReturnType<typeof setInterval> | null = null;
	private listeners = new Set<Listener>();
	private pollMs: number;
	private fetchImpl: FetchLike;
	private generation = 0;
	private lastError: BridgeError | null = null;

	constructor(transport: BridgeTransport, store: SourceStore, options?: ClientOptions) {
		this.transport = transport;
		this.store = store;
		this.pollMs = options?.pollMs ?? POLL_MS;
		this.fetchImpl = options?.fetch ?? ((url: string) => fetch(url));
		store.subscribe(() => {
			if (this.info) this.pushSources().catch(() => this.restart());
		});
	}

	/** Changes each time the bridge (re)starts: the URLs built before no longer work */
	version(): number {
		return this.generation;
	}

	current(): BridgeInfo | null {
		return this.info;
	}

	error(): BridgeError | null {
		return this.lastError;
	}

	subscribe(listener: Listener): () => void {
		this.listeners.add(listener);
		return () => this.listeners.delete(listener);
	}

	private notify(): void {
		this.listeners.forEach((listener) => listener());
	}

	private async call(method: string, params: Record<string, unknown>): Promise<Record<string, unknown>> {
		let answer: Record<string, unknown>;
		try {
			answer = await this.transport.call(method, params);
		} catch (error) {
			throw toError(error);
		}
		if (answer.returnValue === false) throw toError(answer);
		return answer;
	}

	private async pushSources(): Promise<void> {
		await this.call('bridgeSetSources', {sources: this.store.list()});
	}

	/** The running bridge, started with the sources if needed */
	ensure(): Promise<BridgeInfo> {
		if (this.info) return Promise.resolve(this.info);
		if (this.starting) return this.starting;
		this.starting = (async () => {
			try {
				const answer = await this.call('bridgeStart', {clientId: this.store.plexClientId()});
				const info: BridgeInfo = {
					port: Number(answer.port),
					token: String(answer.token),
					host: String(answer.host || '127.0.0.1'),
					node: String(answer.node || ''),
					smb: answer.smb === true,
				};
				this.info = info;
				await this.pushSources();
				this.lastError = null;
				this.generation++;
				this.notify();
				return info;
			} catch (error) {
				this.info = null;
				this.lastError = toError(error);
				this.notify();
				throw this.lastError;
			} finally {
				this.starting = null;
			}
		})();
		return this.starting;
	}

	/** Forgets the bridge and starts it again (the service was stopped, or it restarted with another token) */
	restart(): Promise<BridgeInfo> {
		this.info = null;
		return this.ensure();
	}

	/** Keeps the bridge alive while a screen needs it; returns the release */
	hold(): () => void {
		this.holders++;
		if (this.timer === null) this.timer = setInterval(() => void this.poll(), this.pollMs);
		void this.ensure().catch(() => undefined);
		let released = false;
		return () => {
			if (released) return;
			released = true;
			this.holders--;
			if (this.holders <= 0 && this.timer !== null) {
				clearInterval(this.timer);
				this.timer = null;
			}
		};
	}

	private async poll(): Promise<void> {
		if (!this.info) {
			await this.ensure().catch(() => undefined);
			return;
		}
		const port = this.info.port;
		try {
			const status = await this.call('bridgeStatus', {});
			if (status.running !== true || Number(status.port) !== port) await this.restart();
		} catch {
			await this.restart().catch(() => undefined);
		}
	}

	/** A URL of the running bridge, null before it runs */
	url(route: string, params?: Record<string, string | number | null | undefined>): string | null {
		return this.info ? bridgeUrl(this.info, route, params) : null;
	}

	/** The folders and files of a folder of a source ('' is its root) */
	async list(sourceId: string, ref: string): Promise<Listing> {
		const read = async (info: BridgeInfo): Promise<Listing> => {
			const response = await this.fetchImpl(bridgeUrl(info, 'list', {s: sourceId, r: ref}));
			const body = (await response.json()) as Listing & {error?: string; code?: string};
			if (!response.ok) throw new BridgeError(body.error || `HTTP ${response.status}`, body.code || null, response.status);
			return {folders: body.folders || [], files: body.files || []};
		};
		const info = await this.ensure();
		try {
			return await read(info);
		} catch (error) {
			if (error instanceof BridgeError) throw error;
			// The bridge did not answer at all: it was stopped; once more on a new one
			return read(await this.restart());
		}
	}

	/** Discovery, tests and the Plex sign in (bridgeCall) */
	async control<T>(op: string, args: Record<string, unknown>): Promise<T> {
		await this.ensure();
		return (await this.call('bridgeCall', {op, args})) as unknown as T;
	}

	/** Whether the SMB part runs on this TV (webOS 22 and later) */
	smbAvailable(): boolean {
		return !!this.info?.smb;
	}

	/** Stops the bridge (nothing holds it) */
	async stop(): Promise<void> {
		this.info = null;
		await this.call('bridgeStop', {}).catch(() => undefined);
	}

	/** The source of an id, from the store */
	source(id: string): SourceConfig | null {
		return this.store.get(id);
	}
}
