// Immuch360: a stand in for Samsung's webapis.avplay, for the tests only (nothing of the app imports it). It keeps
// AVPlay's states as Samsung's reference gives them (NONE, IDLE, READY, PLAYING, PAUSED), throws InvalidStateError
// where a call is not allowed, records every call, and lets a test drive what the TV would do: prepare, time going on,
// the end, a seek landing, an error.

import type {AvplayApi} from '../../platform/avplay';
import type {WebapisAvplayListener} from '../../platform/tizen-api';

export interface FakeAvplayOptions {
	durationMs?: number;
	/** The video stream getCurrentStreamInfo gives, null for none */
	stream?: {Width: number | string; Height: number | string; fourCC?: string} | null;
	/** The exception name a call throws, by method name */
	throws?: Record<string, string>;
	/** No setDisplayRotation at all (an older AVPlay) */
	noRotation?: boolean;
}

export interface FakeAvplay {
	api: AvplayApi;
	calls: unknown[][];
	readonly state: string;
	readonly time: number;
	listener: WebapisAvplayListener | null;
	/** prepareAsync ends well, or with the error given */
	prepareOk: () => void;
	prepareFail: (error: unknown) => void;
	/** The time goes on by ms while it plays, as oncurrentplaytime tells it */
	tick: (ms: number) => void;
	complete: () => void;
	error: (name: string) => void;
	/** The seek on its way lands, or fails */
	seekOk: () => void;
	seekFail: () => void;
	/** The names of the calls made, in order */
	names: () => string[];
}

const exception = (name: string) => Object.assign(new Error(`${name} (the URL and its key could be in here)`), {name});

export function fakeAvplay(options: FakeAvplayOptions = {}): FakeAvplay {
	const durationMs = options.durationMs ?? 60000;
	let state = 'NONE';
	let time = 0;
	let prepare: {ok?: () => void; fail?: (error: unknown) => void} | null = null;
	let seek: {ms: number; ok?: () => void; fail?: (error: unknown) => void} | null = null;
	const calls: unknown[][] = [];
	const fake: Partial<FakeAvplay> & {listener: WebapisAvplayListener | null} = {listener: null};

	const call = (name: string, args: unknown[], allowed: string[] | null, run: () => unknown = () => undefined): unknown => {
		calls.push([name, ...args]);
		const thrown = options.throws?.[name];
		if (thrown) throw exception(thrown);
		if (allowed && allowed.indexOf(state) < 0) throw exception('InvalidStateError');
		return run();
	};
	const DISPLAY = ['IDLE', 'READY', 'PLAYING', 'PAUSED'];

	const api: Record<string, unknown> = {
		open: (url: string) =>
			call('open', [url], ['NONE', 'IDLE'], () => {
				state = 'IDLE';
				time = 0;
			}),
		close: () =>
			call('close', [], null, () => {
				state = 'NONE';
				fake.listener = null;
				prepare = null;
				seek = null;
			}),
		setListener: (listener: WebapisAvplayListener) =>
			call('setListener', [], ['IDLE', 'READY', 'PLAYING', 'PAUSED'], () => {
				fake.listener = listener;
			}),
		setDisplayRect: (x: number, y: number, width: number, height: number) => call('setDisplayRect', [x, y, width, height], DISPLAY),
		setDisplayMethod: (method: string) => call('setDisplayMethod', [method], DISPLAY),
		setTimeoutForBuffering: (seconds: number) => call('setTimeoutForBuffering', [seconds], DISPLAY),
		prepareAsync: (ok?: () => void, fail?: (error: unknown) => void) =>
			call('prepareAsync', [], ['IDLE', 'READY'], () => {
				prepare = {ok, fail};
			}),
		play: () =>
			call('play', [], ['READY', 'PLAYING', 'PAUSED'], () => {
				state = 'PLAYING';
			}),
		pause: () =>
			call('pause', [], ['PLAYING', 'PAUSED'], () => {
				state = 'PAUSED';
			}),
		stop: () =>
			call('stop', [], ['READY', 'PLAYING', 'PAUSED'], () => {
				state = 'IDLE';
			}),
		seekTo: (ms: number, ok?: () => void, fail?: (error: unknown) => void) =>
			call('seekTo', [ms], ['IDLE', 'READY', 'PLAYING', 'PAUSED'], () => {
				seek = {ms, ok, fail};
			}),
		getState: () => state,
		getDuration: () => (state === 'NONE' || state === 'IDLE' ? 0 : durationMs),
		getCurrentTime: () => time,
		getCurrentStreamInfo: () =>
			options.stream === null
				? []
				: [
						{index: 0, type: 'AUDIO', extra_info: '{"language":"und"}'},
						{index: 1, type: 'VIDEO', extra_info: JSON.stringify(options.stream ?? {fourCC: 'HEVC', Width: '3840', Height: '2160'})},
					],
	};
	if (!options.noRotation) api.setDisplayRotation = (rotation: string) => call('setDisplayRotation', [rotation], DISPLAY);

	// Getters defined, not copied: Object.assign would read them once
	Object.defineProperties(fake, {
		state: {get: () => state},
		time: {get: () => time},
	});
	return Object.assign(fake, {
		api: api as unknown as AvplayApi,
		calls,
		prepareOk: () => {
			const pending = prepare;
			prepare = null;
			if (!pending) throw new Error('no prepareAsync on its way');
			state = 'READY';
			pending.ok?.();
		},
		prepareFail: (error: unknown) => {
			const pending = prepare;
			prepare = null;
			if (!pending) throw new Error('no prepareAsync on its way');
			pending.fail?.(error);
		},
		tick: (ms: number) => {
			if (state !== 'PLAYING') return;
			time = Math.min(durationMs, time + ms);
			fake.listener?.oncurrentplaytime?.(time);
		},
		complete: () => {
			time = durationMs;
			fake.listener?.onstreamcompleted?.();
		},
		error: (name: string) => fake.listener?.onerror?.(name),
		seekOk: () => {
			const pending = seek;
			seek = null;
			if (!pending) throw new Error('no seek on its way');
			time = pending.ms;
			pending.ok?.();
		},
		seekFail: () => {
			const pending = seek;
			seek = null;
			if (!pending) throw new Error('no seek on its way');
			pending.fail?.(exception('InvalidValuesError'));
		},
		names: () => calls.map((entry) => String(entry[0])),
	}) as FakeAvplay;
}
