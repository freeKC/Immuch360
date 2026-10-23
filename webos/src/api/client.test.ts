// Immuch360: the requests of the API client end within 15 s and say why they failed (src/api/network.ts)
import {APIClient, APIError} from './client';
import {AuthMethod} from './types';

const client = () => new APIClient({method: AuthMethod.API_KEY, baseUrl: 'http://immich.local:2283', apiKey: 'key'});
const setOnline = (value: boolean) => Object.defineProperty(window.navigator, 'onLine', {value, configurable: true});

describe('APIClient requests without an answer', () => {
	const realFetch = global.fetch;
	afterEach(() => {
		global.fetch = realFetch;
		setOnline(true);
		jest.useRealTimers();
	});

	test('a server that never answers fails after 15 s with the timeout cause', async () => {
		jest.useFakeTimers();
		const signals: AbortSignal[] = [];
		global.fetch = jest.fn((_url: RequestInfo | URL, init?: RequestInit) => {
			if (init?.signal) signals.push(init.signal);
			return new Promise<Response>(() => {});
		}) as typeof fetch;
		const settled = client()
			.fetch('/users/me')
			.catch((error: unknown) => error);
		await jest.advanceTimersByTimeAsync(14999);
		expect(signals[0]?.aborted).toBe(false);
		await jest.advanceTimersByTimeAsync(1);
		expect(await settled).toMatchObject({name: 'APIError', kind: 'timeout', status: undefined});
		expect(signals[0]?.aborted).toBe(true);
	});

	test('a server that answers the no-cors probe but not the request refuses the app: cors', async () => {
		global.fetch = jest.fn((_url: RequestInfo | URL, init?: RequestInit) =>
			init?.mode === 'no-cors' ? Promise.resolve({type: 'opaque'} as Response) : Promise.reject(new TypeError('Failed to fetch'))
		) as typeof fetch;
		await expect(client().fetch('/users/me')).rejects.toMatchObject({kind: 'cors'});
		const probe = (global.fetch as jest.Mock).mock.calls.find(([, init]) => init?.mode === 'no-cors');
		expect(probe[0]).toBe('http://immich.local:2283/api/server/ping');
	});

	test('nothing answers at all: unreachable', async () => {
		global.fetch = jest.fn(() => Promise.reject(new TypeError('Failed to fetch'))) as typeof fetch;
		await expect(client().fetch('/users/me')).rejects.toMatchObject({kind: 'unreachable'});
	});

	test('the TV is offline: offline, without a probe', async () => {
		setOnline(false);
		global.fetch = jest.fn(() => Promise.reject(new TypeError('Failed to fetch'))) as typeof fetch;
		await expect(client().fetch('/users/me')).rejects.toMatchObject({kind: 'offline'});
		expect(global.fetch).toHaveBeenCalledTimes(1);
	});

	test('an HTTP error keeps its status and has no cause', async () => {
		global.fetch = jest.fn(() => Promise.resolve({ok: false, status: 401, statusText: 'Unauthorized'} as Response)) as typeof fetch;
		const error = await client().fetch('/users/me').catch((e: unknown) => e);
		expect(error).toBeInstanceOf(APIError);
		expect((error as APIError).status).toBe(401);
		expect((error as APIError).kind).toBeUndefined();
	});

	test("the caller's abort is passed on as it is", async () => {
		global.fetch = jest.fn(
			(_url: RequestInfo | URL, init?: RequestInit) =>
				new Promise<Response>((_resolve, reject) => {
					init?.signal?.addEventListener('abort', () => reject(Object.assign(new Error('aborted'), {name: 'AbortError'})));
				})
		) as typeof fetch;
		const controller = new AbortController();
		const pending = client().fetch('/timeline/bucket', {signal: controller.signal});
		controller.abort();
		await expect(pending).rejects.toMatchObject({name: 'AbortError'});
	});

	test('media bytes: the limit holds until the answer, not for the whole download', async () => {
		jest.useFakeTimers();
		global.fetch = jest.fn(() =>
			Promise.resolve({
				ok: true,
				status: 200,
				arrayBuffer: () => new Promise<ArrayBuffer>((resolve) => setTimeout(() => resolve(new ArrayBuffer(4)), 30000)),
			} as unknown as Response)
		) as typeof fetch;
		const pending = client().fetchMediaBytes('http://immich.local:2283/api/assets/a/thumbnail?apiKey=key');
		await jest.advanceTimersByTimeAsync(30000);
		await expect(pending).resolves.toBeInstanceOf(ArrayBuffer);
	});
	// R12 of the review: the 15 s are for the answer; a slow body on a remote link has BODY_TIMEOUT_MS
	test('a JSON answer whose body is slow: the 15 s stop at the answer, the body has 60 s', async () => {
		jest.useFakeTimers();
		const answer = (bodyMs: number) =>
			jest.fn(() =>
				Promise.resolve({
					ok: true,
					status: 200,
					statusText: 'OK',
					text: () => new Promise<string>((resolve) => setTimeout(() => resolve('{"months":12}'), bodyMs)),
				} as unknown as Response)
			) as typeof fetch;
		global.fetch = answer(30000);
		const slow = client().fetch<{months: number}>('/timeline/buckets');
		await jest.advanceTimersByTimeAsync(30000);
		await expect(slow).resolves.toEqual({months: 12});

		global.fetch = answer(10 * 60000);
		const stalled = client()
			.fetch('/timeline/buckets')
			.catch((error: unknown) => error);
		await jest.advanceTimersByTimeAsync(59999);
		let done = false;
		void stalled.then(() => {
			done = true;
		});
		await jest.advanceTimersByTimeAsync(0);
		expect(done).toBe(false);
		await jest.advanceTimersByTimeAsync(1);
		expect(await stalled).toMatchObject({name: 'APIError', kind: 'timeout'});
	});

	test('a web page at the address (not JSON) reads as a server that cannot be reached there', async () => {
		global.fetch = jest.fn(() => Promise.resolve({ok: true, status: 200, statusText: 'OK', text: () => Promise.resolve('<html>router</html>')} as Response)) as typeof fetch;
		await expect(client().fetch('/users/me')).rejects.toMatchObject({name: 'APIError', kind: 'unreachable'});
	});
});
