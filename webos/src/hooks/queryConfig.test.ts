import {QueryClient} from '@tanstack/react-query';
import {APIError} from '../api/client';
import {REQUEST_TIMEOUT_MS} from '../api/network';
import {ASSETS_QUERY_CONFIG} from './queryConfig';

// Immuch360: how long a page waits before it says why it failed (LG: no lockup, a clear message)
const {retry} = ASSETS_QUERY_CONFIG;
const failure = (kind: 'offline' | 'timeout' | 'cors' | 'unreachable') => new APIError(`Network error (${kind})`, undefined, kind);

describe('the retries of a page query', () => {
	afterEach(() => jest.useRealTimers());

	test('none offline, after a CORS refusal or a 401; one after a timeout; two otherwise', () => {
		expect(retry(0, new APIError('Unauthorized', 401))).toBe(false);
		expect(retry(0, failure('offline'))).toBe(false);
		expect(retry(0, failure('cors'))).toBe(false);
		expect(retry(0, failure('timeout'))).toBe(true);
		expect(retry(1, failure('timeout'))).toBe(false);
		expect(retry(1, failure('unreachable'))).toBe(true);
		expect(retry(2, failure('unreachable'))).toBe(false);
		expect(retry(1, new APIError('Server error', 500))).toBe(true);
	});

	// A query that gets no answer fails after REQUEST_TIMEOUT_MS each time (src/api/client.ts)
	const run = async (error: () => APIError, afterMs: number) => {
		jest.useFakeTimers();
		const client = new QueryClient();
		const start = Date.now();
		let calls = 0;
		let failedAfter: number | null = null;
		client
			.fetchQuery({
				queryKey: ['page'],
				queryFn: () =>
					new Promise<never>((_resolve, reject) => {
						calls += 1;
						setTimeout(() => reject(error()), afterMs);
					}),
				retry,
			})
			.catch(() => {
				failedAfter = Date.now() - start;
			});
		await jest.advanceTimersByTimeAsync(60000);
		client.clear();
		return {calls, failedAfter};
	};

	test('a server that drops the packets: the message after about 31 s, not 48', async () => {
		const {calls, failedAfter} = await run(() => failure('timeout'), REQUEST_TIMEOUT_MS);
		expect(calls).toBe(2);
		expect(failedAfter).toBeGreaterThanOrEqual(2 * REQUEST_TIMEOUT_MS + 1000);
		expect(failedAfter).toBeLessThan(2 * REQUEST_TIMEOUT_MS + 2000);
	});

	test('offline: the message at once, no retry', async () => {
		const {calls, failedAfter} = await run(() => failure('offline'), 10);
		expect(calls).toBe(1);
		expect(failedAfter).toBeLessThan(100);
	});

	test('a server that is down: two quick retries (1 s, then 2 s)', async () => {
		const {calls, failedAfter} = await run(() => failure('unreachable'), 300);
		expect(calls).toBe(3);
		expect(failedAfter).toBeGreaterThanOrEqual(3 * 300 + 3000);
		expect(failedAfter).toBeLessThan(3 * 300 + 3500);
	});
});
