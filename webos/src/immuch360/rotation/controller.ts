// Immuch360: the one-key rotation of the viewer: one quarter turn per press, kept on the server as an edit of Immich's
// photo editor, or on this TV (see mode.ts). Port of ViewRotationController of the Flutter app
// (mobile/lib/providers/asset_viewer/view_rotation.provider.dart on branch feat-rotate).
//
// A press turns the picture on screen at once and restarts a short wait (DEBOUNCE_MS); then the edits of the photo as
// the session started, turned by all the presses so far (composeQuarterTurns), replace those on the server, one
// request at a time, each carrying the whole list: the last one alone is right whatever happened before. Several quick
// presses make one request, four make none.
//
// The server makes the turned picture in the background and gives the photo a new thumbhash. The session asks for it
// until it changes, loads the new picture under that thumbhash (the cache key of its URL), and maps the key to the
// turns that picture carries: the viewer draws the turns asked for beyond those (displayTurns), so the new picture
// takes the place of the turned one at once. A turn the server refuses (another user's photo, an API key without the
// edit permission, a format it cannot edit) stays on this TV, and the viewer says so once. A request that fails
// otherwise brings the photo back as it was, with a message.

import {composeQuarterTurns, normalizeQuarterTurns, type AssetEdit} from './edits';
import {rotationMode, type RotationAsset, type RotationContext, type RotationMode} from './mode';

/** What the rotation needs of the Immich server, see src/immuch360/rotation/server.ts */
export interface RotationServer {
	context(): Promise<RotationContext>;
	asset(assetId: string): Promise<RotationAsset & {thumbhash: string | null}>;
	/** The edits of the photo, null when one is of a kind this app does not know (composing would drop it) */
	edits(assetId: string): Promise<AssetEdit[] | null>;
	/** Replaces the edits of the photo; an empty list removes them */
	replaceEdits(assetId: string, edits: AssetEdit[]): Promise<void>;
	/** The key of the picture of the photo the app shows now (the thumbhash its URL carries), null when none */
	pictureKey(assetId: string): string | null;
	/** Loads the picture of the photo under that key, then makes it the one the app shows */
	showPicture(assetId: string, key: string): Promise<void>;
}

/** The quarter turns kept on this TV, per photo (src/utils/rotationStore.ts) */
export interface DeviceRotations {
	turns(assetId: string): number;
	setTurns(assetId: string, turns: number): void;
}

export interface Timers {
	set(callback: () => void, ms: number): unknown;
	clear(handle: unknown): void;
}

/** What the viewer says after a turn: kept on this TV only, or not saved */
export type RotationNotice = 'keptOnDevice' | 'failed';

/**
 * Where the turn of a photo stands, for the viewer: 'turning' from the press until the server's turned picture is
 * shown (the viewer shows that it works), 'notice' while it says that the turn stays on this TV or was not saved,
 * 'shown' once the turned picture took the place of the photo (while the session lasts), 'idle' otherwise.
 */
export type RotationPhase = 'idle' | 'turning' | 'shown' | 'notice';

/** How long the presses gather before a request */
export const DEBOUNCE_MS = 700;
/** How long an idle session lasts after its last request */
export const SESSION_LIFETIME_MS = 120000;
/** How long the server is given to make the turned picture */
export const PICTURE_WAIT_MS = 120000;
/** How long a notice shows */
export const NOTICE_MS = 6000;

const pollDelay = (elapsed: number): number => (elapsed < 10000 ? 1000 : 3000);

const statusOf = (error: unknown): number | undefined =>
	typeof error === 'object' && error !== null ? (error as {status?: number}).status : undefined;

/** The server will not edit this photo for this user or this key: Bad Request (its format) or Forbidden */
const isRefusal = (error: unknown): boolean => statusOf(error) === 400 || statusOf(error) === 403;

interface Session {
	assetId: string;
	/** Quarter turns asked for, from the edits the server had when the session started, those kept on the TV included */
	pending: number;
	/** The turns kept on this TV when the session started: folded into the first request, then forgotten */
	deviceTurns: number;
	deviceTurnsCleared: boolean;
	/** The turns the server holds now, from the same start */
	serverTurns: number;
	/** The turns each picture of the photo carries, by its key ('' for a URL without one) */
	carried: Record<string, number>;
	mode: RotationMode | null;
	base: AssetEdit[] | null | undefined;
	/** The photo's thumbhash as the last request left it */
	thumbhash: string | null;
	debounce: unknown;
	expiry: unknown;
	saving: boolean;
	flushAgain: boolean;
}

export class RotationController {
	private readonly sessions = new Map<string, Session>();
	private readonly modes = new Map<string, RotationMode>();
	private readonly notices = new Map<string, {kind: RotationNotice; handle: unknown}>();
	private readonly listeners = new Set<() => void>();
	private keptNoticeShown = false;
	private version = 0;

	constructor(
		private readonly server: RotationServer,
		private readonly device: DeviceRotations,
		private readonly timers: Timers
	) {}

	/** Calls the listener after each change of what the viewer draws; returns the unsubscribe function */
	subscribe = (listener: () => void): (() => void) => {
		this.listeners.add(listener);
		return () => this.listeners.delete(listener);
	};

	/** A number that changes with what the viewer draws (for useSyncExternalStore) */
	snapshot = (): number => this.version;

	/** The quarter turns clockwise to draw on top of the picture the app shows of the photo, 0 to 3 */
	displayTurns(assetId: string): number {
		const session = this.sessions.get(assetId);
		if (!session) return normalizeQuarterTurns(this.device.turns(assetId));
		const carried = session.carried[this.server.pictureKey(assetId) ?? ''];
		// A picture the session does not know (made elsewhere meanwhile) is shown as it is
		return carried === undefined ? 0 : normalizeQuarterTurns(session.pending - carried);
	}

	/** Whether a turn of the photo is being saved on the server */
	isSaving(assetId: string): boolean {
		const session = this.sessions.get(assetId);
		return !!session && (session.saving || session.debounce !== undefined) && session.mode !== 'device';
	}

	/** Where the turn of the photo stands; a turn kept on this TV is drawn at once and never 'turning' */
	phase(assetId: string): RotationPhase {
		if (this.isSaving(assetId)) return 'turning';
		if (this.notices.has(assetId)) return 'notice';
		return this.sessions.has(assetId) ? 'shown' : 'idle';
	}

	/** What the viewer says about the last turn of the photo, null when nothing */
	notice(assetId: string): RotationNotice | null {
		return this.notices.get(assetId)?.kind ?? null;
	}

	/** Turns the photo by quarterTurns clockwise (negative: counterclockwise). Returns at once. */
	rotate(assetId: string, quarterTurns: number): void {
		if (this.modes.get(assetId) === 'device') {
			this.device.setTurns(assetId, normalizeQuarterTurns(this.device.turns(assetId) + quarterTurns));
			this.publish();
			return;
		}
		let session = this.sessions.get(assetId);
		if (session && this.isIdle(session) && !((this.server.pictureKey(assetId) ?? '') in session.carried)) {
			// The picture shown is none the session made (edited elsewhere meanwhile): start again from its edits
			this.end(session);
			session = undefined;
		}
		if (!session) session = this.start(assetId);
		session.pending += quarterTurns;
		this.clearTimer(session, 'expiry');
		this.clearTimer(session, 'debounce');
		const current = session;
		session.debounce = this.timers.set(() => {
			current.debounce = undefined;
			void this.flush(current);
		}, DEBOUNCE_MS);
		this.publish();
	}

	private start(assetId: string): Session {
		const deviceTurns = normalizeQuarterTurns(this.device.turns(assetId));
		const session: Session = {
			assetId,
			pending: deviceTurns,
			deviceTurns,
			deviceTurnsCleared: false,
			serverTurns: 0,
			carried: {[this.server.pictureKey(assetId) ?? '']: 0},
			mode: null,
			base: undefined,
			thumbhash: null,
			debounce: undefined,
			expiry: undefined,
			saving: false,
			flushAgain: false,
		};
		this.sessions.set(assetId, session);
		return session;
	}

	private isCurrent(session: Session): boolean {
		return this.sessions.get(session.assetId) === session;
	}

	private isIdle(session: Session): boolean {
		return session.debounce === undefined && !session.saving;
	}

	private async flush(session: Session): Promise<void> {
		if (!this.isCurrent(session)) return;
		if (session.saving) {
			session.flushAgain = true;
			return;
		}
		const {assetId} = session;
		session.saving = true;
		this.publish();
		try {
			if (session.mode === null) {
				const [context, asset] = await Promise.all([this.server.context(), this.server.asset(assetId)]);
				session.mode = rotationMode(context, asset);
				session.thumbhash = asset.thumbhash;
				this.modes.set(assetId, session.mode);
			}
			if (session.mode === 'server' && session.base === undefined) session.base = await this.server.edits(assetId);
			if (!this.isCurrent(session)) return;
			if (session.mode === 'device' || !session.base) {
				this.keepOnDevice(session);
				return;
			}
			const target = normalizeQuarterTurns(session.pending);
			const sent = target !== session.serverTurns;
			const before = session.thumbhash;
			if (sent) {
				await this.server.replaceEdits(assetId, composeQuarterTurns(session.base, target));
				session.serverTurns = target;
			}
			if (session.deviceTurns !== 0 && !session.deviceTurnsCleared) {
				// The server holds them now (or the presses undid them)
				session.deviceTurnsCleared = true;
				this.device.setTurns(assetId, 0);
			}
			if (sent) {
				const after = await this.waitForPicture(session, before);
				if (!this.isCurrent(session)) return;
				if (after === null) {
					// The server did not make the picture in time: the app asks for it afresh, and shows it as it is
					await this.server.showPicture(assetId, `edit${Date.now()}`);
					this.end(session);
					return;
				}
				await this.server.showPicture(assetId, after);
				session.thumbhash = after;
				session.carried[after] = target;
			}
		} catch (error) {
			if (this.isCurrent(session)) {
				if (isRefusal(error) && session.serverTurns === 0 && !session.deviceTurnsCleared) {
					this.keepOnDevice(session);
				} else {
					this.end(session);
					this.showNotice(assetId, 'failed');
				}
			}
			return;
		} finally {
			session.saving = false;
		}
		if (!this.isCurrent(session)) return;
		if (session.debounce !== undefined) {
			// More presses: their own flush follows the wait
		} else if (session.flushAgain) {
			session.flushAgain = false;
			void this.flush(session);
		} else {
			session.expiry = this.timers.set(() => {
				session.expiry = undefined;
				if (this.isCurrent(session) && this.isIdle(session)) this.end(session);
			}, SESSION_LIFETIME_MS);
		}
		this.publish();
	}

	/** The photo's new thumbhash once the server made its turned picture, null when it did not in time */
	private async waitForPicture(session: Session, before: string | null): Promise<string | null> {
		let elapsed = 0;
		while (elapsed < PICTURE_WAIT_MS) {
			const delay = pollDelay(elapsed);
			await new Promise<void>((resolve) => this.timers.set(resolve, delay));
			elapsed += delay;
			if (!this.isCurrent(session)) return null;
			try {
				const {thumbhash} = await this.server.asset(session.assetId);
				if (thumbhash && thumbhash !== before) return thumbhash;
			} catch {
				// Asked again at the next round
			}
		}
		return null;
	}

	private keepOnDevice(session: Session): void {
		this.modes.set(session.assetId, 'device');
		// Beyond what the server already holds from this session; set before the session ends, so the photo does not move
		this.device.setTurns(session.assetId, normalizeQuarterTurns(session.pending - session.serverTurns));
		this.end(session);
		if (!this.keptNoticeShown) {
			this.keptNoticeShown = true;
			this.showNotice(session.assetId, 'keptOnDevice');
		}
		this.publish();
	}

	private showNotice(assetId: string, kind: RotationNotice): void {
		const previous = this.notices.get(assetId);
		if (previous) this.timers.clear(previous.handle);
		const handle = this.timers.set(() => {
			if (this.notices.get(assetId)?.handle === handle) this.notices.delete(assetId);
			this.publish();
		}, NOTICE_MS);
		this.notices.set(assetId, {kind, handle});
		this.publish();
	}

	private end(session: Session): void {
		if (this.isCurrent(session)) this.sessions.delete(session.assetId);
		this.clearTimer(session, 'debounce');
		this.clearTimer(session, 'expiry');
		this.publish();
	}

	private clearTimer(session: Session, which: 'debounce' | 'expiry'): void {
		if (session[which] !== undefined) this.timers.clear(session[which]);
		session[which] = undefined;
	}

	private publish(): void {
		this.version++;
		for (const listener of Array.from(this.listeners)) listener();
	}
}
