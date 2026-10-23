// The time limit of the requests to the server and the causes of a failure without an answer (src/api/network.ts):
// the self assessment of 23 October 2026, fix F3 (6.2 "Loading…" for over 60 s, 6.3 a CORS message without network).

import {test, describe, afterEach} from 'node:test';
import assert from 'node:assert/strict';
import {REQUEST_TIMEOUT_MS, TimeoutError, classifyFailure, withTimeout} from '../../src/api/network.ts';

const setOnline = (value) => Object.defineProperty(globalThis.navigator, 'onLine', {value, configurable: true});

describe('every request has a time limit', () => {
	afterEach(() => setOnline(true));

	test('15 seconds by default', () => {
		assert.equal(REQUEST_TIMEOUT_MS, 15000);
	});

	test('a request without an answer fails with TimeoutError, and its fetch is aborted', async () => {
		let seen;
		const started = Date.now();
		await assert.rejects(
			withTimeout(
				(signal) =>
					new Promise((resolve, reject) => {
						seen = signal;
						signal.addEventListener('abort', () => reject(new Error('aborted')));
					}),
				{timeoutMs: 50},
			),
			TimeoutError,
		);
		assert.ok(Date.now() - started >= 45);
		assert.equal(seen.aborted, true);
	});

	test('an answer in time comes through; done() lifts the limit for a long body', async () => {
		assert.equal(await withTimeout(async () => 'answer', {timeoutMs: 50}), 'answer');
		const value = await withTimeout(
			(signal, done) =>
				new Promise((resolve) => {
					done();
					setTimeout(() => resolve(signal.aborted ? 'aborted' : 'body'), 120);
				}),
			{timeoutMs: 50},
		);
		assert.equal(value, 'body');
	});

	test('bodyTimeoutMs: once the answer is in, the body has its own limit, from the answer on', async () => {
		const slowBody = (bodyMs) => (signal, done) =>
			new Promise((resolve, reject) => {
				signal.addEventListener('abort', () => reject(new Error('aborted')));
				setTimeout(() => {
					done();
					setTimeout(() => resolve('body'), bodyMs);
				}, 30);
			});
		// The answer at 30 ms, the body 80 ms later: past the 50 ms of the answer, within its own 200 ms
		assert.equal(await withTimeout(slowBody(80), {timeoutMs: 50, bodyTimeoutMs: 200}), 'body');
		// A body that takes longer than its limit fails as a timeout, its fetch aborted
		const started = Date.now();
		await assert.rejects(withTimeout(slowBody(500), {timeoutMs: 50, bodyTimeoutMs: 60}), TimeoutError);
		const took = Date.now() - started;
		assert.ok(took >= 85 && took < 400, `failed after ${took} ms`);
	});

	test("the caller's own abort reaches the request and is not a timeout", async () => {
		const outer = new AbortController();
		const pending = withTimeout(
			(signal) =>
				new Promise((resolve, reject) => {
					signal.addEventListener('abort', () => reject(Object.assign(new Error('The user aborted a request.'), {name: 'AbortError'})));
				}),
			{timeoutMs: 1000, signal: outer.signal},
		);
		outer.abort();
		await assert.rejects(pending, (error) => error.name === 'AbortError');
	});
});

describe('why a request got no answer', () => {
	afterEach(() => setOnline(true));
	const answers = () => Promise.resolve({type: 'opaque'});
	const silent = () => Promise.reject(new TypeError('Failed to fetch'));

	test('the TV is offline', async () => {
		setOnline(false);
		assert.equal(await classifyFailure(new TypeError('Failed to fetch'), 'http://server/api/server/ping', answers), 'offline');
	});

	test('the time ran out', async () => {
		assert.equal(await classifyFailure(new TimeoutError(15000), 'http://server/api/server/ping', answers), 'timeout');
	});

	test('the server answers a no-cors request: it refuses the app (CORS)', async () => {
		assert.equal(await classifyFailure(new TypeError('Failed to fetch'), 'http://server/api/server/ping', answers), 'cors');
	});

	test('nothing answers: the server cannot be reached', async () => {
		assert.equal(await classifyFailure(new TypeError('Failed to fetch'), 'http://server/api/server/ping', silent), 'unreachable');
	});

	test('the network dropped while probing: offline', async () => {
		const dropping = () => {
			setOnline(false);
			return Promise.reject(new TypeError('Failed to fetch'));
		};
		assert.equal(await classifyFailure(new TypeError('Failed to fetch'), 'http://server/api/server/ping', dropping), 'offline');
	});
});
