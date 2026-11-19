// Immuch360: one video played through Samsung's AVPlay player (src/platform/avplay.ts), for the viewer's AvplayMedia
// (issue 17). It keeps what Sandstone's player reads of a media element (time, duration, paused, loading) and turns
// its calls into AVPlay's, which are asynchronous and allowed in some states only (Samsung's AVPlay API reference, read
// 16 November 2026):
//
//   open(url), setListener, setTimeoutForBuffering, setDisplayMethod and setDisplayRect (a display must be set, or the
//   sound plays with no picture), prepareAsync; once prepared: setDisplayRotation, setDisplayMethod and setDisplayRect
//   again ("this API call will change the origin of coordinates"), seekTo the start when there is one, play.
//   Leaving: stop, then close. At the end: stop, or the last frame stays on screen. After seekTo, no other call until
//   one of its callbacks (pause throws InvalidAccessError meanwhile): a pause or a turn asked for during a seek is sent
//   once it lands.
//
// Every callback carries the generation of the open it belongs to: a Back or the next video during prepareAsync, or a
// seek, finds its callbacks ignored. Anything that fails before or during playback (open, prepare or play throwing, an
// error event, no frame time within AVPLAY_START_MS) closes the player and hands the failure to the viewer, which plays
// the video in the HTML element instead. When the app is hidden the player is closed (the decoder freed for other
// apps); shown again, it opens at the same time, paused, as the HTML video is.
//
// What it was asked and what it did goes into the "Video turn" line of the About page (noteAvplayTurn): the TV, the
// stream, the rotation value sent and its outcome, the rect, how far it went and the error name. Never the URL, whose
// query holds the key.

import {AVPLAY_LETTER_BOX, AVPLAY_ROTATION, avplayErrorName, type AvplayApi} from '../../platform/avplay';
import type {WebapisAvplayListener} from '../../platform/tizen-api';
import {tizenInfo} from '../../platform/tizen';
import {avplayDisplay, playerRect, resolveAvplayTurn, videoStreamOf, type AvplayDisplay, type AvplayStream, type AvplayTurn, type PageArea} from './avplayTurn';
import {noteAvplayTurn, type VideoFit, type TurnDegrees, type VideoOrientationInfo, type VideoTurnChoice} from './orientation';

/** How long AVPlay has to show a first frame time once opened, below the viewer's own 20 s (keys.ts, VIDEO_STALL_MS) */
export const AVPLAY_START_MS = 12000;
/** AVPlay's buffering timeout, in seconds (Samsung: 20 by default, 3 to 10 recommended) */
export const AVPLAY_BUFFERING_TIMEOUT_S = 10;

/** Where AVPlay failed: open (it refused the URL or threw), prepare, play, start (no frame time in time), playback */
export type AvplayStage = 'open' | 'prepare' | 'play' | 'start' | 'playback';

export interface AvplayFailure {
	stage: AvplayStage;
	/** The name of the error (AVPlayError or exception), never its message */
	error: string;
	/** The time it had reached, in seconds, where the HTML element takes over */
	at: number;
	/** Whether every video would fail the same way (the player refused to open, the server cannot be reached by it) */
	sessionWide: boolean;
}

/** What the viewer knows of the video's turn: its orientation and stored size, and the turn chosen by hand */
export interface AvplayTurnRequest {
	info: VideoOrientationInfo | null;
	manual: VideoTurnChoice | null;
}

/** What the player shows, for the viewer's "Turn the picture" and "Fit the picture" */
export interface AvplayTurnShown {
	degrees: TurnDegrees;
	fit: VideoFit;
	fitMatters: boolean;
}

/** The media events the session raises, with the names of the HTML ones (the screen saver listens to them) */
export type AvplayMediaEvent = 'loadedmetadata' | 'playing' | 'pause' | 'ended' | 'waiting';

export interface AvplaySessionOptions {
	api: AvplayApi;
	url: string;
	/** Where to start, in seconds (the time the HTML element had reached when the video was switched) */
	startAt: number;
	autoplay: boolean;
	turn: AvplayTurnRequest;
	/** The player's area on the page, null when unknown */
	area: () => PageArea | null;
	/** The page's width in CSS pixels, for AVPlay's 1920 wide screen */
	viewportWidth: () => number;
	onChange: () => void;
	onEvent: (type: AvplayMediaEvent) => void;
	onFailed: (failure: AvplayFailure) => void;
	onTurnShown: (shown: AvplayTurnShown) => void;
	/** Whether the page has the <object type="application/avplayer"> of Samsung's guide, for the diagnostics line */
	hasPlayerObject?: () => boolean;
	startTimeoutMs?: number;
}

type Phase = 'idle' | 'preparing' | 'ready' | 'playing' | 'paused' | 'ended' | 'hidden' | 'closed' | 'failed';

// How far the video went, for the diagnostics line
const MILESTONES = ['nothing', 'opened', 'prepared', 'playing', 'frames', 'end'] as const;
type Milestone = (typeof MILESTONES)[number];

const SESSION_WIDE_ERRORS = /CONNECTION_FAILED|INVALID_URI|NotSupportedError|TypeMismatchError/;

/** The outcome of one call: 'ok', or the name of what it threw */
function attempt(call: () => void): string {
	try {
		call();
		return 'ok';
	} catch (error) {
		return avplayErrorName(error);
	}
}

const positive = (value: number | null | undefined): value is number => typeof value === 'number' && Number.isFinite(value) && value > 0;

export class AvplaySession {
	private readonly options: AvplaySessionOptions;
	private phase: Phase = 'idle';
	private generation = 0;
	private time: number;
	private durationSeconds = NaN;
	private buffering = false;
	private wantPlay: boolean;
	private playFrom = 0;
	private advanced = false;
	private seekTarget: number | null = null;
	private queuedSeek: number | null = null;
	/** A turn asked for while a seek was on its way: sent once it lands */
	private pendingTurn = false;
	private startTimer: ReturnType<typeof setTimeout> | null = null;
	private stream: AvplayStream | null = null;
	private request: AvplayTurnRequest;
	private shown: AvplayTurn | null = null;
	private display: AvplayDisplay | null = null;
	private outcome = {rotation: '', method: '', rect: ''};
	private reached: Milestone = 'nothing';
	private failure: string | null = null;
	private tv: string | null = null;

	constructor(options: AvplaySessionOptions) {
		this.options = options;
		this.time = Math.max(0, options.startAt || 0);
		this.wantPlay = options.autoplay;
		this.request = options.turn;
	}

	// What Sandstone's player reads, as a media element gives it (seconds)
	get currentTime(): number {
		if (this.seekTarget !== null) return this.queuedSeek ?? this.seekTarget;
		return this.time;
	}

	get duration(): number {
		return this.durationSeconds;
	}

	get paused(): boolean {
		return this.phase !== 'playing' && !(this.phase === 'preparing' && this.wantPlay);
	}

	get loading(): boolean {
		return this.phase === 'idle' || this.phase === 'preparing' || this.buffering || this.seekTarget !== null;
	}

	/** As HTMLMediaElement.readyState: 4 once prepared, 0 before (the viewer's start check reads it) */
	get readyState(): number {
		return this.phase === 'ready' || this.phase === 'playing' || this.phase === 'paused' || this.phase === 'ended' ? 4 : 0;
	}

	get ended(): boolean {
		return this.phase === 'ended';
	}

	/** The phase, for the element's data attribute and the tests */
	get state(): string {
		return this.phase;
	}

	/** Opens the video */
	start(): void {
		this.openAt(this.time, this.wantPlay);
	}

	play(): void {
		switch (this.phase) {
			case 'ready':
			case 'paused':
				this.wantPlay = true;
				if (this.seekTarget === null) this.startPlaying();
				return;
			case 'preparing':
				this.wantPlay = true;
				return;
			case 'ended':
				this.reopen(0, true);
				return;
			case 'hidden':
				this.reopen(this.time, true);
				return;
			default:
		}
	}

	pause(): void {
		if (this.phase === 'preparing') {
			this.wantPlay = false;
			this.armStartTimer(this.generation);
			this.options.onChange();
			return;
		}
		if (this.phase === 'ready') {
			this.wantPlay = false;
			return;
		}
		if (this.phase !== 'playing') return;
		this.wantPlay = false;
		// Samsung: no other call until a seek's callback (pause() throws InvalidAccessError meanwhile): the seek's end
		// pauses it (runSeek)
		if (this.seekTarget === null) attempt(() => this.options.api.pause());
		this.phase = 'paused';
		this.options.onEvent('pause');
		this.options.onChange();
	}

	/** Seeks to a time in seconds; one seek at a time, the latest asked for goes next */
	seek(seconds: number): void {
		if (!Number.isFinite(seconds)) return;
		const target = Math.max(0, positive(this.durationSeconds) ? Math.min(seconds, this.durationSeconds) : seconds);
		switch (this.phase) {
			case 'preparing':
				this.time = target;
				return;
			case 'ended':
			case 'hidden':
				this.reopen(target, false);
				return;
			case 'ready':
			case 'playing':
			case 'paused':
				if (this.seekTarget !== null) {
					this.queuedSeek = target;
					this.options.onChange();
					return;
				}
				this.runSeek(target, false);
				return;
			default:
		}
	}

	/** A new turn asked for (the viewer's buttons): applied at once when the player is prepared, after a seek on its way */
	setTurn(request: AvplayTurnRequest): void {
		this.request = request;
		if (this.phase !== 'ready' && this.phase !== 'playing' && this.phase !== 'paused') return;
		if (this.seekTarget === null) this.applyTurn();
		else this.pendingTurn = true;
	}

	/** The app is hidden: the player closes, the time is kept */
	hide(): void {
		if (this.phase === 'closed' || this.phase === 'failed' || this.phase === 'hidden' || this.phase === 'idle') return;
		this.time = this.currentTime;
		this.closePlayer();
		this.phase = 'hidden';
		this.buffering = false;
		this.options.onEvent('pause');
		this.options.onChange();
	}

	/** The app is shown again: the video opens at the same time, paused */
	show(): void {
		if (this.phase === 'hidden') this.openAt(this.time, false);
	}

	/** Leaves the video: stop and close, whatever the state */
	close(): void {
		if (this.phase === 'closed') return;
		this.closePlayer();
		this.phase = 'closed';
	}

	private openAt(at: number, play: boolean): void {
		const gen = ++this.generation;
		const {api, url} = this.options;
		this.time = at;
		this.playFrom = at;
		this.wantPlay = play;
		this.advanced = false;
		this.seekTarget = null;
		this.queuedSeek = null;
		this.pendingTurn = false;
		this.phase = 'preparing';
		this.buffering = true;
		this.failure = null;
		if (this.tv === null) this.tv = describeTv();
		try {
			api.open(url);
		} catch (error) {
			this.fail('open', error);
			return;
		}
		this.reach('opened');
		try {
			api.setListener(this.listener(gen));
		} catch (error) {
			this.fail('open', error);
			return;
		}
		attempt(() => api.setTimeoutForBuffering?.(AVPLAY_BUFFERING_TIMEOUT_S));
		// A display before prepare: the whole player, kept whole; the turn comes once prepared
		const rect = this.playerRect();
		attempt(() => api.setDisplayMethod(AVPLAY_LETTER_BOX));
		attempt(() => api.setDisplayRect(rect.x, rect.y, rect.width, rect.height));
		this.armStartTimer(gen);
		try {
			api.prepareAsync(
				() => this.prepared(gen),
				(error) => {
					if (gen === this.generation) this.fail('prepare', error);
				}
			);
		} catch (error) {
			this.fail('prepare', error);
			return;
		}
		this.note();
		this.options.onChange();
	}

	private reopen(at: number, play: boolean): void {
		this.closePlayer();
		this.openAt(at, play);
	}

	private listener(gen: number): WebapisAvplayListener {
		const current = () => gen === this.generation;
		return {
			onbufferingstart: () => {
				if (!current()) return;
				this.buffering = true;
				this.options.onEvent('waiting');
				this.options.onChange();
			},
			onbufferingcomplete: () => {
				if (!current()) return;
				this.buffering = false;
				this.options.onChange();
			},
			oncurrentplaytime: (milliseconds: number) => {
				if (!current() || typeof milliseconds !== 'number' || !Number.isFinite(milliseconds)) return;
				if (this.seekTarget === null) this.time = milliseconds / 1000;
				if (!this.advanced && this.phase === 'playing' && Math.abs(milliseconds / 1000 - this.playFrom) >= 0.05) {
					this.advanced = true;
					this.buffering = false;
					this.clearStartTimer();
					this.reach('frames');
					this.note();
				}
				this.options.onChange();
			},
			onstreamcompleted: () => {
				if (current()) this.completed();
			},
			onerror: (error: unknown) => {
				if (current()) this.fail(this.phase === 'preparing' ? 'prepare' : this.advanced ? 'playback' : 'play', error);
			},
			onresourceconflicted: () => {
				if (current()) this.fail(this.advanced ? 'playback' : 'play', 'RESOURCE_CONFLICTED');
			},
			onevent: () => {},
		};
	}

	private prepared(gen: number): void {
		if (gen !== this.generation || this.phase !== 'preparing') return;
		const {api} = this.options;
		this.phase = 'ready';
		this.buffering = false;
		this.reach('prepared');
		let duration = NaN;
		try {
			duration = api.getDuration() / 1000;
		} catch {
			// unknown until it plays
		}
		this.durationSeconds = positive(duration) ? duration : NaN;
		try {
			this.stream = videoStreamOf(api.getCurrentStreamInfo?.());
		} catch {
			this.stream = null;
		}
		this.applyTurn();
		this.options.onEvent('loadedmetadata');
		if (this.time > 0) this.runSeek(this.time, true);
		else this.afterReady();
		this.options.onChange();
	}

	// Once prepared, and past the seek to the start time: play, or wait paused
	private afterReady(): void {
		if (this.wantPlay) {
			this.startPlaying();
			return;
		}
		this.phase = 'paused';
		this.options.onChange();
	}

	private startPlaying(): void {
		const outcome = attempt(() => this.options.api.play());
		if (outcome !== 'ok') {
			this.fail(this.advanced ? 'playback' : 'play', outcome);
			return;
		}
		this.phase = 'playing';
		this.playFrom = this.time;
		this.reach('playing');
		if (!this.advanced) this.armStartTimer(this.generation);
		this.note();
		this.options.onEvent('playing');
		this.options.onChange();
	}

	private runSeek(target: number, starting: boolean): void {
		const gen = this.generation;
		const {api} = this.options;
		this.seekTarget = target;
		this.queuedSeek = null;
		const done = (landed: boolean) => {
			if (gen !== this.generation || this.seekTarget === null) return;
			this.seekTarget = null;
			if (landed) this.time = target;
			else {
				try {
					this.time = api.getCurrentTime() / 1000;
				} catch {
					// keeps the time it had
				}
			}
			const next = this.queuedSeek;
			this.queuedSeek = null;
			if (next !== null && next !== target) {
				this.runSeek(next, starting);
				return;
			}
			this.playFrom = this.time;
			// What waited for the seek's end (Samsung: no other call until its callback)
			if (this.pendingTurn) {
				this.pendingTurn = false;
				this.applyTurn();
			}
			if (starting) this.afterReady();
			// Play pressed while the seek was on its way
			else if (this.wantPlay && this.phase === 'paused') this.startPlaying();
			// Pause pressed while it was on its way: AVPlay went on playing
			else if (!this.wantPlay && this.phase === 'paused' && this.avplayState() === 'PLAYING') attempt(() => api.pause());
			this.options.onChange();
		};
		try {
			api.seekTo(
				Math.round(target * 1000),
				() => done(true),
				() => done(false)
			);
		} catch {
			done(false);
		}
		this.options.onChange();
	}

	private avplayState(): string | null {
		try {
			return this.options.api.getState();
		} catch {
			return null;
		}
	}

	private completed(): void {
		if (this.phase !== 'playing' && this.phase !== 'paused') return;
		this.clearStartTimer();
		if (positive(this.durationSeconds)) this.time = this.durationSeconds;
		this.reach('end');
		// Samsung: without stop() the last frame stays on screen
		attempt(() => this.options.api.stop());
		this.phase = 'ended';
		this.wantPlay = false;
		this.buffering = false;
		this.note();
		this.options.onEvent('pause');
		this.options.onEvent('ended');
		this.options.onChange();
	}

	private playerRect() {
		let area: PageArea | null = null;
		let width = 0;
		try {
			area = this.options.area();
			width = this.options.viewportWidth();
		} catch {
			area = null;
		}
		return playerRect(area, width);
	}

	// The rotation asked for, then the method and the rect again (the rotation moves the origin of coordinates)
	private applyTurn(): void {
		const {api} = this.options;
		const turn = resolveAvplayTurn(this.request.info, this.stream, this.request.manual);
		const info = this.request.info;
		const picture = info && positive(info.width) && positive(info.height) ? {width: info.width, height: info.height} : this.stream;
		const display = avplayDisplay(this.playerRect(), turn, picture);
		const rotate = api.setDisplayRotation;
		this.outcome = {
			rotation: typeof rotate === 'function' ? attempt(() => rotate.call(api, AVPLAY_ROTATION[turn.degrees])) : 'missing',
			method: attempt(() => api.setDisplayMethod(display.method)),
			rect: attempt(() => api.setDisplayRect(display.rect.x, display.rect.y, display.rect.width, display.rect.height)),
		};
		this.shown = turn;
		this.display = display;
		this.note();
		this.options.onTurnShown({degrees: turn.degrees, fit: turn.fit, fitMatters: turn.degrees % 180 !== 0});
	}

	/** Closes the player and tells the viewer; reason: a text of the app's own instead of the error's name */
	private fail(stage: AvplayStage, error: unknown, reason?: string): void {
		if (this.phase === 'closed' || this.phase === 'failed') return;
		const name = reason ?? avplayErrorName(error);
		const at = this.currentTime;
		this.failure = `${stage}: ${name}`;
		this.closePlayer();
		this.phase = 'failed';
		this.note();
		this.options.onFailed({stage, error: name, at, sessionWide: stage === 'open' || SESSION_WIDE_ERRORS.test(name)});
	}

	private armStartTimer(gen: number): void {
		this.clearStartTimer();
		if (!this.wantPlay || this.advanced) return;
		const delay = this.options.startTimeoutMs ?? AVPLAY_START_MS;
		this.startTimer = setTimeout(() => {
			this.startTimer = null;
			if (gen !== this.generation || this.advanced || !this.wantPlay) return;
			if (this.phase === 'preparing' || this.phase === 'ready' || this.phase === 'playing') this.fail('start', null, `no frame within ${Math.round(delay / 1000)} s`);
		}, delay);
	}

	private clearStartTimer(): void {
		if (this.startTimer !== null) clearTimeout(this.startTimer);
		this.startTimer = null;
	}

	// Stop then close, each only where Samsung allows it, each caught
	private closePlayer(): void {
		this.generation += 1;
		this.clearStartTimer();
		this.seekTarget = null;
		this.queuedSeek = null;
		this.pendingTurn = false;
		const {api} = this.options;
		const state = this.avplayState();
		if (state === null || state === 'READY' || state === 'PLAYING' || state === 'PAUSED') attempt(() => api.stop());
		if (state !== 'NONE') attempt(() => api.close());
	}

	private reach(milestone: Milestone): void {
		if (MILESTONES.indexOf(milestone) > MILESTONES.indexOf(this.reached)) this.reached = milestone;
	}

	private hasPlayerObject(): boolean {
		try {
			return this.options.hasPlayerObject?.() === true;
		} catch {
			return false;
		}
	}

	private note(): void {
		const info = this.request.info;
		const parts = [
			'tizen AVPlay',
			`TV ${this.tv ?? '?'}`,
			`orientation ${String(info?.orientation ?? '?')}`,
			`stored ${info?.width ?? '?'} x ${info?.height ?? '?'}`,
			`stream ${this.stream ? `${this.stream.width} x ${this.stream.height}${this.stream.codec ? ` ${this.stream.codec}` : ''}` : '?'}`,
			`object ${this.hasPlayerObject() ? 'yes' : 'no'}`,
		];
		if (this.shown && this.display) {
			const {source, degrees, fit} = this.shown;
			const what = source === 'manual' ? `by hand ${degrees}` : source === 'auto' ? `auto ${degrees}` : 'not turned';
			const {x, y, width, height} = this.display.rect;
			parts.push(
				`${what}, fit ${fit}`,
				`${AVPLAY_ROTATION[degrees]} ${this.outcome.rotation}`,
				`${this.display.method === AVPLAY_LETTER_BOX ? 'letterbox' : 'full screen'} ${this.outcome.method}`,
				`rect ${x},${y},${width},${height} ${this.outcome.rect}`
			);
		}
		parts.push(`reached ${this.reached}${this.advanced || this.reached === 'end' ? ` at ${this.currentTime.toFixed(1)} s` : ''}`);
		if (this.failure) parts.push(`failed at ${this.failure}, HTML player instead`);
		noteAvplayTurn(parts.join(', '));
	}
}

// The model, Tizen version and firmware, as the About page shows them
function describeTv(): string {
	try {
		const {model, tizenVersion, firmware} = tizenInfo();
		return `${model ?? '?'}, Tizen ${tizenVersion ?? '?'}, firmware ${firmware ?? '?'}`;
	} catch {
		return '?';
	}
}
