// Immuch360: the media component Sandstone's VideoPlayer plays through on a Samsung TV for a video that needs a turn
// (its videoComponent, in place of @enact/ui Media and its <video>). It has what Sandstone reads and calls on a media
// element (play, pause, load, currentTime, duration, paused, loading, error, playbackRate, proportionLoaded,
// proportionPlayed, onLoadStart and onUpdate), backed by Samsung's AVPlay player through AvplaySession, so the
// transport bar, the time slider, the jumps and the viewer's buttons work as with the HTML element.
//
// Its element is a transparent div with the viewer's video mark: AVPlay draws under the page, which is cleared over
// the video plane while it plays (avplayPage.ts). Inside it, while the player is open, the <object
// type="application/avplayer"> of step 1 of Samsung's "Using AVPlay" guide, filling the player's area as the rect given
// to setDisplayRect does: on some TVs the picture stays black without it (the sound plays). It needs object-src 'self'
// in the policy of tizen/config.xml. The media events the screen saver and the viewer
// listen to (playing, pause, ended, loadedmetadata) are raised on it with their HTML names.
//
// Dropped while AVPlay plays: the playback speed (rewind and fast forward are 10 s jumps in the viewer anyway), the
// loaded part of the time bar (AVPlay does not tell it: the bar shows the played part only). The viewer has no audio
// track, subtitle or speed menu to hide.

import React from 'react';
import {avplayApi} from '../../platform/avplay';
import {AvplaySession, type AvplayFailure, type AvplayMediaEvent, type AvplayTurnRequest, type AvplayTurnShown} from '../../immuch360/video/avplaySession';
import {clearPageForVideoPlane} from '../../immuch360/video/avplayPage';

export interface AvplayMediaProps {
	/** The <source> elements Sandstone hands its media component (the first src is played) */
	source?: React.ReactNode;
	autoPlay?: boolean;
	className?: string;
	onLoadStart?: (event: unknown) => void;
	onUpdate?: (event: unknown) => void;
	/** The orientation and stored size of the video, and the turn chosen by hand */
	avplayTurn?: AvplayTurnRequest;
	/** Where to start, in seconds */
	avplayStartAt?: number;
	/** Delay before the player opens, so that a video element just closed frees the decoder first */
	avplayOpenDelayMs?: number;
	onAvplayFailed?: (failure: AvplayFailure) => void;
	onAvplayTurnShown?: (shown: AvplayTurnShown) => void;
	/** The viewer's video mark (VideoPlayer.tsx, VIDEO_MARK) */
	'data-immuch360-video'?: string;
}

const NO_TURN: AvplayTurnRequest = {info: null, manual: null};

/** The type of the element Samsung's guide puts on the page for AVPlay */
export const AVPLAYER_OBJECT_TYPE = 'application/avplayer';

// The element of Samsung's guide, over the player's whole area, never in the way of the remote's keys
function playerObject(): HTMLObjectElement {
	const object = document.createElement('object');
	object.setAttribute('type', AVPLAYER_OBJECT_TYPE);
	object.setAttribute('aria-hidden', 'true');
	object.tabIndex = -1;
	object.style.cssText = 'display: block; width: 100%; height: 100%; border: 0; pointer-events: none;';
	return object;
}

/** The URL of the first <source> of the media's source (as @enact/ui Media reads it), or the string given */
export function sourceUrl(source: React.ReactNode): string | null {
	if (typeof source === 'string') return source || null;
	let found: string | null = null;
	React.Children.forEach(source, (child) => {
		if (found === null && React.isValidElement(child)) {
			const src = (child.props as {src?: unknown}).src;
			if (typeof src === 'string' && src) found = src;
		}
	});
	return found;
}

const sameTurn = (a: AvplayTurnRequest | undefined, b: AvplayTurnRequest | undefined): boolean => {
	const x = a ?? NO_TURN;
	const y = b ?? NO_TURN;
	return (
		x.info?.orientation === y.info?.orientation &&
		x.info?.width === y.info?.width &&
		x.info?.height === y.info?.height &&
		x.manual?.degrees === y.manual?.degrees &&
		x.manual?.fit === y.manual?.fit
	);
};

export class AvplayMedia extends React.Component<AvplayMediaProps> {
	private node: HTMLDivElement | null = null;
	private session: AvplaySession | null = null;
	private restorePage: (() => void) | null = null;
	private object: HTMLObjectElement | null = null;
	private openTimer: ReturnType<typeof setTimeout> | null = null;

	componentDidMount(): void {
		document.addEventListener('visibilitychange', this.onVisibilityChange);
		window.addEventListener('pagehide', this.onPageHide);
		this.open();
	}

	componentDidUpdate(previous: AvplayMediaProps): void {
		if (sourceUrl(previous.source) !== sourceUrl(this.props.source)) {
			this.shut();
			this.open();
			return;
		}
		if (!sameTurn(previous.avplayTurn, this.props.avplayTurn)) this.session?.setTurn(this.props.avplayTurn ?? NO_TURN);
	}

	componentWillUnmount(): void {
		document.removeEventListener('visibilitychange', this.onVisibilityChange);
		window.removeEventListener('pagehide', this.onPageHide);
		this.shut();
	}

	// What Sandstone calls and reads, as on @enact/ui Media
	play(): void {
		this.session?.play();
	}

	pause(): void {
		this.session?.pause();
	}

	load(): void {
		this.shut();
		this.open();
	}

	get currentTime(): number {
		return this.session?.currentTime ?? 0;
	}

	set currentTime(seconds: number) {
		this.session?.seek(seconds);
	}

	get duration(): number {
		return this.session?.duration ?? NaN;
	}

	/** A failure goes back to the HTML element (onAvplayFailed) rather than to Sandstone's error state */
	get error(): boolean {
		return false;
	}

	get loading(): boolean {
		return this.session?.loading ?? true;
	}

	get paused(): boolean {
		return this.session?.paused ?? true;
	}

	get playbackRate(): number {
		return 1;
	}

	set playbackRate(_rate: number) {
		// AVPlay plays at normal speed here: no speed in this mode
	}

	get proportionPlayed(): number {
		const duration = this.duration;
		return Number.isFinite(duration) && duration > 0 ? Math.min(1, this.currentTime / duration) : 0;
	}

	get proportionLoaded(): number {
		return this.proportionPlayed;
	}

	/** As HTMLMediaElement.readyState: 4 once prepared (the viewer's start check reads it through getVideoNode) */
	get readyState(): number {
		return this.session?.readyState ?? 0;
	}

	// The player opens on a timer, never during React's commit: Sandstone takes this component's ref after its
	// componentDidMount, and reads it on the first update
	private open(): void {
		if (this.openTimer !== null) clearTimeout(this.openTimer);
		this.openTimer = setTimeout(() => {
			this.openTimer = null;
			this.begin();
		}, Math.max(0, this.props.avplayOpenDelayMs ?? 0));
	}

	private begin(): void {
		const url = sourceUrl(this.props.source);
		const api = avplayApi();
		if (!url || !api || !this.node) {
			this.props.onAvplayFailed?.({stage: 'open', error: api ? 'no source' : 'no AVPlay', at: this.props.avplayStartAt ?? 0, sessionWide: !api});
			return;
		}
		const node = this.node;
		this.session = new AvplaySession({
			api,
			url,
			startAt: this.props.avplayStartAt ?? 0,
			autoplay: this.props.autoPlay !== false,
			turn: this.props.avplayTurn ?? NO_TURN,
			area: () => {
				const rect = node.getBoundingClientRect();
				return {left: rect.left, top: rect.top, width: rect.width, height: rect.height};
			},
			viewportWidth: () => document.documentElement.clientWidth || window.innerWidth || 0,
			onChange: this.update,
			onEvent: this.raise,
			onFailed: this.failed,
			onTurnShown: (shown) => this.props.onAvplayTurnShown?.(shown),
			hasPlayerObject: () => this.object !== null && this.object.isConnected,
		});
		this.restorePage = clearPageForVideoPlane(node);
		// Samsung's guide: the object first, then open
		this.removeObject();
		this.object = playerObject();
		node.appendChild(this.object);
		this.props.onLoadStart?.({type: 'loadstart'});
		this.session.start();
		this.update();
	}

	// Stop and close the player, put the page back
	private shut(): void {
		if (this.openTimer !== null) clearTimeout(this.openTimer);
		this.openTimer = null;
		this.session?.close();
		this.session = null;
		this.restorePage?.();
		this.restorePage = null;
		this.removeObject();
	}

	private removeObject(): void {
		this.object?.remove();
		this.object = null;
	}

	private readonly update = (): void => {
		if (this.node && this.session) this.node.setAttribute('data-immuch360-avplay', this.session.state);
		this.props.onUpdate?.({type: 'update'});
	};

	private readonly raise = (type: AvplayMediaEvent): void => {
		this.node?.dispatchEvent(new Event(type));
	};

	private readonly failed = (failure: AvplayFailure): void => {
		this.restorePage?.();
		this.restorePage = null;
		this.removeObject();
		this.node?.setAttribute('data-immuch360-avplay', 'failed');
		this.props.onAvplayFailed?.(failure);
	};

	private readonly onVisibilityChange = (): void => {
		if (document.hidden) this.session?.hide();
		else this.session?.show();
	};

	private readonly onPageHide = (): void => {
		this.shut();
	};

	private readonly setNode = (node: HTMLDivElement | null): void => {
		this.node = node;
	};

	render(): React.ReactNode {
		const {className} = this.props;
		return (
			<div
				ref={this.setNode}
				className={className}
				data-immuch360-video={this.props['data-immuch360-video'] ?? ''}
				data-immuch360-avplay="idle"
				style={{width: '100%', height: '100%', background: 'transparent'}}
			/>
		);
	}
}
