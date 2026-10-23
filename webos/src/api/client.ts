import {AuthMethod, type AuthConfig} from './types';
import {classifyFailure, withTimeout, type FailureKind} from './network';

export class APIError extends Error {
	public status?: number;
	// Immuch360: why a request without an answer failed (no status then): offline, timeout, cors or unreachable
	public kind?: FailureKind;

	constructor(message: string, status?: number, kind?: FailureKind) {
		super(message);
		this.name = 'APIError';
		this.status = status;
		this.kind = kind;
	}
}

const isAbort = (error: unknown) => error instanceof Error && error.name === 'AbortError';

export class APIClient {
	private baseUrl: string;
	private authConfig: AuthConfig;

	constructor(config: AuthConfig) {
		let normalized = config.baseUrl.trim();
		normalized = normalized.replace(/\/+$/, '');
		if (!normalized.endsWith('/api')) {
			normalized = `${normalized}/api`;
		}

		this.baseUrl = normalized;
		this.authConfig = config;
	}

	private getHeaders(): HeadersInit {
		const headers: Record<string, string> = {
			'Content-Type': 'application/json',
			Accept: 'application/json',
		};
		switch (this.authConfig.method) {
			case AuthMethod.USER_CREDENTIALS:
				if (this.authConfig.accessToken) headers.Authorization = `Bearer ${this.authConfig.accessToken}`;
				break;
			case AuthMethod.API_KEY:
				headers['x-api-key'] = this.authConfig.apiKey;
				break;
		}
		return headers;
	}

	private getMediaAuthParam(): {name: string; value: string} {
		return this.authConfig.method === AuthMethod.USER_CREDENTIALS ? {name: 'sessionKey', value: this.authConfig.accessToken || ''} : {name: 'apiKey', value: this.authConfig.apiKey};
	}

	// Media URLs carry auth as a query param so <img>/<video> tags load them directly.
	private buildMediaUrl(path: string): string {
		const {name, value} = this.getMediaAuthParam();
		const sep = path.includes('?') ? '&' : '?';
		return `${this.baseUrl}${path}${sep}${name}=${value}`;
	}

	// Immuch360: the server's ping, which needs no sign in: what the no-cors probe of a failed request asks for
	private probeUrl(): string {
		return `${this.baseUrl}/server/ping`;
	}

	// Immuch360: the error of a request that got no answer, told apart (src/api/network.ts)
	private async failure(error: unknown, method: string, url: string): Promise<APIError> {
		const kind = await classifyFailure(error, this.probeUrl());
		console.error(`[API] ${method} ${url} failed without an answer (${kind}):`, error);
		return new APIError(`Network error (${kind}): ${error instanceof Error ? error.message : 'Unknown error'}`, undefined, kind);
	}

	// Immuch360: every request has 15 s (REQUEST_TIMEOUT_MS) for its answer and its body
	public async fetch<T>(endpoint: string, options: RequestInit = {}): Promise<T> {
		const url = `${this.baseUrl}${endpoint}`;
		const method = options.method || 'GET';

		let text: string;
		try {
			text = await withTimeout(
				async (signal) => {
					const response = await fetch(url, {
						...options,
						signal,
						headers: {...this.getHeaders(), ...options.headers},
					});
					if (!response.ok) {
						console.error(`[API] ${method} ${url} failed with ${response.status}: ${response.statusText}`);
						throw new APIError(`API request failed: ${response.statusText}`, response.status);
					}
					return response.text();
				},
				{signal: options.signal},
			);
		} catch (error) {
			if (error instanceof APIError || (isAbort(error) && options.signal?.aborted)) throw error;
			throw await this.failure(error, method, url);
		}
		return text ? JSON.parse(text) : ({} as T);
	}

	// Immich v3 serves the unedited original (ignoring crops/rotations) unless edited=true.
	// Immuch360: 'fullsize' is the full-size picture the server generates (Image settings), the preview otherwise. The
	// cache key (the asset's thumbhash, as Immich's web app sends it in c) changes when the picture does, after an edit:
	// the TV then fetches the new one rather than the copy it kept (the server lets it keep them a day).
	public getThumbnailUrl(assetId: string, size: 'preview' | 'thumbnail' | 'fullsize' = 'thumbnail', cacheKey?: string | null): string {
		const key = cacheKey ? `&c=${encodeURIComponent(cacheKey)}` : '';
		return this.buildMediaUrl(`/assets/${assetId}/thumbnail?size=${size}&edited=true${key}`);
	}

	public getFaceThumbnailUrl(personId: string): string {
		return this.buildMediaUrl(`/people/${personId}/thumbnail`);
	}

	public getVideoPlaybackUrl(assetId: string): string {
		return this.buildMediaUrl(`/assets/${assetId}/video/playback`);
	}

	// Immuch360: the server address the account was added with, /api included
	public getBaseUrl(): string {
		return this.baseUrl;
	}

	// Immuch360: the bytes of a media URL (credentials in the query, as for <img>), for the WebGL sphere, which needs
	// pixels of the app's own origin. No header is added, so the request needs no CORS preflight.
	public async fetchMediaBytes(url: string, signal?: AbortSignal): Promise<ArrayBuffer> {
		// The 15 s run until the answer comes; a large photo then takes the time its download needs
		let response: Response;
		try {
			response = await withTimeout(
				async (timedSignal, answered) => {
					const answer = await fetch(url, {signal: timedSignal});
					answered();
					return answer;
				},
				{signal},
			);
		} catch (error) {
			if (isAbort(error) && signal?.aborted) throw error;
			throw await this.failure(error, 'GET', url.replace(/(sessionKey|apiKey)=[^&]*/, '$1=…'));
		}
		if (!response.ok) throw new APIError(`API request failed: ${response.statusText}`, response.status);
		return response.arrayBuffer();
	}
}
