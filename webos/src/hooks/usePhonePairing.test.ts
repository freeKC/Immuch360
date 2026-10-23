import {act, renderHook} from '@testing-library/react';
import {usePhonePairing} from './usePhonePairing';
import type {PairingDriver, PairingPollResult} from '../pairing/types';
import {PairingServiceError} from '../pairing/serviceResponse';
import {t} from '../immuch360/i18n';

const INFO = {url: 'http://192.168.1.42:8788/?c=ABCD2345', code: 'ABCD2345'};

class FakeDriver implements PairingDriver {
	public startCalls = 0;
	public cancelCalls = 0;
	public startError: Error | null = null;
	public pollQueue: PairingPollResult[] = [];

	async start(): Promise<typeof INFO> {
		this.startCalls += 1;
		if (this.startError) throw this.startError;
		return INFO;
	}

	async status(): Promise<PairingPollResult> {
		return this.pollQueue.shift() ?? {state: 'pending'};
	}

	async cancel(): Promise<void> {
		this.cancelCalls += 1;
	}
}

// Non-empty body keeps testing-library/no-unnecessary-act happy (empty act is flagged).
const flush = () =>
	act(async () => {
		await Promise.resolve();
	});
const tick = (ms: number) =>
	act(async () => {
		jest.advanceTimersByTime(ms);
	});

beforeEach(() => {
	jest.useFakeTimers();
});

afterEach(() => {
	jest.useRealTimers();
});

test('start → waiting with url and code', async () => {
	const driver = new FakeDriver();
	const onPaired = jest.fn();
	const {result} = renderHook(() => usePhonePairing(driver, '', onPaired));
	expect(result.current.state.phase).toBe('starting');
	await flush();
	expect(result.current.state).toEqual({phase: 'waiting', ...INFO});
});

test('approved poll hands the result to onPaired', async () => {
	const driver = new FakeDriver();
	driver.pollQueue = [
		{state: 'pending'},
		{state: 'approved', result: {baseUrl: 'http://x', email: 'q@e.fr', accessToken: 't'}},
	];
	const onPaired = jest.fn(async () => ({success: true as const}));
	const {result} = renderHook(() => usePhonePairing(driver, '', onPaired));
	await flush();
	await tick(2000);
	expect(onPaired).not.toHaveBeenCalled();
	expect(result.current.state.phase).toBe('waiting');
	await tick(2000);
	expect(onPaired).toHaveBeenCalledWith({baseUrl: 'http://x', email: 'q@e.fr', accessToken: 't'});
	expect(result.current.state.phase).toBe('finalizing');
});

test('failed paired login surfaces the error', async () => {
	const driver = new FakeDriver();
	driver.pollQueue = [{state: 'approved', result: {baseUrl: 'http://x', email: 'q@e.fr', accessToken: 't'}}];
	const onPaired = jest.fn(async () => ({success: false as const, errorMessage: 'Server said no'}));
	const {result} = renderHook(() => usePhonePairing(driver, '', onPaired));
	await flush();
	await tick(2000);
	expect(result.current.state).toEqual({phase: 'error', message: 'Server said no', atStart: false});
});

test('start failure reports an atStart error; restart tries again', async () => {
	const driver = new FakeDriver();
	driver.startError = new Error('no service');
	const onPaired = jest.fn();
	const warn = jest.spyOn(console, 'warn').mockImplementation(() => undefined);
	const {result} = renderHook(() => usePhonePairing(driver, '', onPaired));
	await flush();
	expect(result.current.state).toEqual({phase: 'error', message: t('webos_pairing_start_failed'), atStart: true});
	expect(warn).toHaveBeenCalled();
	warn.mockRestore();

	driver.startError = null;
	act(() => result.current.restart());
	expect(result.current.state.phase).toBe('starting');
	await flush();
	expect(result.current.state).toEqual({phase: 'waiting', ...INFO});
	expect(driver.startCalls).toBe(2);
});

test('expired session becomes a retryable error', async () => {
	const driver = new FakeDriver();
	driver.pollQueue = [{state: 'expired'}];
	const onPaired = jest.fn();
	const {result} = renderHook(() => usePhonePairing(driver, '', onPaired));
	await flush();
	await tick(2000);
	expect(result.current.state).toMatchObject({phase: 'error', atStart: false});
});

test('unmount cancels the session', async () => {
	const driver = new FakeDriver();
	const onPaired = jest.fn();
	const {unmount} = renderHook(() => usePhonePairing(driver, '', onPaired));
	await flush();
	unmount();
	expect(driver.cancelCalls).toBe(1);
});

// Immuch360: the service's English stays in the log, the screen shows the app's texts
describe('the text of a start that failed', () => {
	let warn: jest.SpyInstance;
	beforeEach(() => {
		warn = jest.spyOn(console, 'warn').mockImplementation(() => undefined);
	});
	afterEach(() => warn.mockRestore());

	test('a TV without a network address says it is offline, as the rest of the app does', async () => {
		const driver = new FakeDriver();
		driver.startError = new PairingServiceError('TV has no network address', 'no_address');
		const {result} = renderHook(() => usePhonePairing(driver, '', jest.fn()));
		await flush();
		expect(result.current.state).toEqual({phase: 'error', message: t('webos_error_offline'), atStart: true});
	});

	test('a phone page that could not listen gets its own text, never the raw error', async () => {
		const driver = new FakeDriver();
		driver.startError = new PairingServiceError('Could not start pairing server: listen EADDRNOTAVAIL 192.168.1.20', 'listen_failed');
		const {result} = renderHook(() => usePhonePairing(driver, '', jest.fn()));
		await flush();
		const state = result.current.state;
		expect(state).toEqual({phase: 'error', message: t('webos_pairing_start_failed'), atStart: true});
		expect(state.phase === 'error' && /EADDRNOTAVAIL/.test(state.message)).toBe(false);
		expect(warn).toHaveBeenCalledWith('[pairing] the phone page did not start:', driver.startError);
	});

	test('offline, whatever the service says', async () => {
		const online = jest.spyOn(navigator, 'onLine', 'get').mockReturnValue(false);
		const driver = new FakeDriver();
		driver.startError = new PairingServiceError('Pairing service did not respond', 'no_answer');
		const {result} = renderHook(() => usePhonePairing(driver, '', jest.fn()));
		await flush();
		expect(result.current.state).toEqual({phase: 'error', message: t('webos_error_offline'), atStart: true});
		online.mockRestore();
	});
});
