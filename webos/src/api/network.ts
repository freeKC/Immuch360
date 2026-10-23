// Immuch360: how a request to the server ends when it gets no answer, so that the TV never waits without an end and
// says why (LG's self checklist: no lockup; Jellyfin's P2 defect of January 2024 for a vague error).
//
// * Every request has REQUEST_TIMEOUT_MS to get its answer (withTimeout): a server whose address drops the packets
//   used to leave "Loading…" on screen for minutes.
// * A request that fails without an answer is told apart (classifyFailure): the TV is offline (navigator.onLine), the
//   server answers but refuses the app's origin (CORS, webOS 5 to 24 apply it to the file:// page), or the server
//   cannot be reached at all (wrong address, server down). A request in "no-cors" mode tells the last two apart: the
//   browser lets it reach a server that sends no CORS headers (the answer stays opaque), and it fails like the real
//   request only when nothing answers.

/** How long a request waits for the server's answer */
export const REQUEST_TIMEOUT_MS = 15000;

/** How long the no-cors probe of classifyFailure waits */
export const PROBE_TIMEOUT_MS = 5000;

export type FailureKind = 'offline' | 'timeout' | 'cors' | 'unreachable';

/** Whether the TV has a network connection, as the browser engine knows it */
export function isOnline(): boolean {
	return typeof navigator === 'undefined' || navigator.onLine !== false;
}

/** The error of a request whose time ran out */
export class TimeoutError extends Error {
	constructor(ms: number) {
		super(`No answer within ${Math.round(ms / 1000)} s`);
		this.name = 'TimeoutError';
	}
}

/**
 * Runs a request with a time limit. run gets the signal to give fetch, and done, to call once the answer is in when
 * the rest (a large body) may take longer than the limit. Rejects with TimeoutError when the time runs out first; an
 * abort of the caller's own signal rejects as fetch does.
 */
export function withTimeout<T>(
	run: (signal: AbortSignal | undefined, done: () => void) => Promise<T>,
	options: {timeoutMs?: number; signal?: AbortSignal | null} = {},
): Promise<T> {
	const timeoutMs = options.timeoutMs ?? REQUEST_TIMEOUT_MS;
	const outer = options.signal ?? null;
	const controller = typeof AbortController === 'function' ? new AbortController() : null;
	let timedOut = false;
	let timer: ReturnType<typeof setTimeout> | null = null;
	const done = () => {
		if (timer !== null) clearTimeout(timer);
		timer = null;
	};
	const onOuterAbort = () => controller?.abort();
	if (outer) {
		if (outer.aborted) controller?.abort();
		else outer.addEventListener('abort', onOuterAbort);
	}
	const cleanUp = () => {
		done();
		if (outer) outer.removeEventListener('abort', onOuterAbort);
	};
	return new Promise<T>((resolve, reject) => {
		timer = setTimeout(() => {
			timer = null;
			timedOut = true;
			controller?.abort();
			if (outer) outer.removeEventListener('abort', onOuterAbort);
			// Without AbortController (none on the TVs the app supports, but cheap to cover) the request is left behind
			reject(new TimeoutError(timeoutMs));
		}, timeoutMs);
		run(controller ? controller.signal : outer ?? undefined, done).then(
			(value) => {
				cleanUp();
				if (!timedOut) resolve(value);
			},
			(error) => {
				cleanUp();
				if (!timedOut) reject(error);
			},
		);
	});
}

/** A request in no-cors mode: resolves when anything answers at url, rejects when nothing does */
export type Probe = (url: string) => Promise<unknown>;

const defaultProbe: Probe = (url) =>
	withTimeout((signal) => fetch(url, {mode: 'no-cors', cache: 'no-store', signal}), {timeoutMs: PROBE_TIMEOUT_MS});

/**
 * Why a request to a server failed without an answer from it (fetch rejected): offline, timeout (error is a
 * TimeoutError), cors (something answers at probeUrl, but the browser hid the answer from the app), else unreachable.
 */
export async function classifyFailure(error: unknown, probeUrl: string, probe: Probe = defaultProbe): Promise<FailureKind> {
	if (!isOnline()) return 'offline';
	if (error instanceof TimeoutError) return 'timeout';
	try {
		await probe(probeUrl);
		return 'cors';
	} catch {
		return isOnline() ? 'unreachable' : 'offline';
	}
}
