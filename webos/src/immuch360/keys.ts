// Immuch360: the keys of an LG remote, and what the app does with them on a video.
//
// The key map of the Flutter app (mobile/lib/presentation/widgets/tv/remote_keys.dart and the TvShell) for the codes
// webOS sends. Documented in webos/README.md, "Remote control".
//
// | Remote key              | webOS keyCode (key)            | Action                                                     |
// |-------------------------|--------------------------------|------------------------------------------------------------|
// | Arrows                  | 37 38 39 40                    | move the focus; viewer: Left and Right previous and next   |
// | OK                      | 13 (Enter)                     | open; photo: show or hide the controls; video: controls    |
// | Back                    | 461 (GoBack), 1536, 8, 10009, 27 | close the overlay, then the page (see useWebOSKeys)      |
// | Channel up and down     | 33 34 (PageUp, PageDown)       | zoom in and out by 1.25 in the viewers                     |
// | Play, Pause, Play/Pause | 415, 19, 179                   | play always plays, pause always pauses, the toggle toggles |
// | Rewind, Fast forward    | 412, 417                       | 10 s back or forward                                       |
// | Stop                    | 413                            | close the video                                            |
// | Previous, Next track    | 177, 176                       | previous and next item, where the remote has them          |
// | Info                    | 457 (and I of a keyboard)      | show or hide the details of the item; Back closes them     |
// | Red Green Yellow Blue   | 403 404 405 406                | left free                                                  |
//
// A flat photo turns by 90° with one key, and the turn is kept for that photo on the TV (src/utils/rotationStore.ts):
//
// | Key                     | webOS keyCode (key)            | Action                                                     |
// |-------------------------|--------------------------------|------------------------------------------------------------|
// | Up                      | 38                             | turn 90° clockwise, when the photo is not zoomed and the   |
// |                         |                                | focus is on it (Up from the action bar goes back to it)    |
// | R or ] of a keyboard    | 82 or 221 (r, R, ])            | turn 90° clockwise                                         |
// | [ of a keyboard         | 219 ([)                        | turn 90° counterclockwise                                  |
//
// Every LG remote has Up, the Magic Remote included, which has no colour keys of its own. The [ and ] keys are those
// of the photo editor of Immich's web app.
//
// 1536 is Back on webOS 25 and later, but the wheel of the Magic Remote sends 1536 too, with key "Unidentified":
// that pair is not Back (immich-tv-webos found it on a TV). 8 is Back on a few firmwares, except in a text field.

export type RemoteAction =
	| 'left'
	| 'right'
	| 'up'
	| 'down'
	| 'ok'
	| 'back'
	| 'channelUp'
	| 'channelDown'
	| 'play'
	| 'pause'
	| 'playPause'
	| 'rewind'
	| 'fastForward'
	| 'stop'
	| 'previousTrack'
	| 'nextTrack'
	| 'info'
	| 'red'
	| 'green'
	| 'yellow'
	| 'blue'
	| 'rotateRight'
	| 'rotateLeft';

/** The parts of a keydown event the map reads */
export interface KeyLike {
	keyCode: number;
	key?: string;
}

const BY_CODE: Record<number, RemoteAction> = {
	37: 'left',
	38: 'up',
	39: 'right',
	40: 'down',
	13: 'ok',
	461: 'back',
	10009: 'back',
	27: 'back',
	33: 'channelUp',
	34: 'channelDown',
	415: 'play',
	19: 'pause',
	179: 'playPause',
	412: 'rewind',
	417: 'fastForward',
	413: 'stop',
	177: 'previousTrack',
	176: 'nextTrack',
	457: 'info',
	403: 'red',
	404: 'green',
	405: 'yellow',
	406: 'blue',
};

const BY_KEY: Record<string, RemoteAction> = {
	ArrowLeft: 'left',
	ArrowUp: 'up',
	ArrowRight: 'right',
	ArrowDown: 'down',
	Enter: 'ok',
	GoBack: 'back',
	BrowserBack: 'back',
	PageUp: 'channelUp',
	PageDown: 'channelDown',
	ChannelUp: 'channelUp',
	ChannelDown: 'channelDown',
	MediaPlay: 'play',
	MediaPause: 'pause',
	MediaPlayPause: 'playPause',
	MediaRewind: 'rewind',
	MediaFastForward: 'fastForward',
	MediaStop: 'stop',
	MediaTrackPrevious: 'previousTrack',
	MediaTrackNext: 'nextTrack',
	Info: 'info',
	i: 'info',
	I: 'info',
	r: 'rotateRight',
	R: 'rotateRight',
	']': 'rotateRight',
	'[': 'rotateLeft',
};

const WHEEL_OR_BACK = 1536;
const BACKSPACE = 8;

/**
 * The action of a key, or null for a key the app leaves alone. editingText: the focus is in a text field, where 8
 * deletes a character.
 */
export function remoteAction(event: KeyLike, editingText = false): RemoteAction | null {
	if (event.keyCode === WHEEL_OR_BACK) return event.key === 'Unidentified' ? null : 'back';
	if (event.keyCode === BACKSPACE) return editingText ? null : 'back';
	return BY_CODE[event.keyCode] ?? (event.key ? BY_KEY[event.key] ?? null : null);
}

/** One step of the 10 s seek of the rewind and fast forward keys and of a video alone with Left and Right */
export const SEEK_STEP_SECONDS = 10;

/** How long the controls of a viewer stay after they show or after the last key */
export const CONTROLS_HIDE_AFTER_MS = 5000;

/** A video that has not started this long after it opened, without being paused, does not play on this TV */
export const VIDEO_STALL_MS = 20000;

/**
 * What Left and Right do on a video while the viewer has the focus: on a TV they go to the previous or next item
 * whatever the video does (it plays, loads, is paused or ended); only a video without neighbours seeks with them.
 * Same policy as remoteVideoArrows of the Flutter app with tvMode on.
 */
export function videoArrows(hasNeighbours: boolean): 'navigate' | 'seek' {
	return hasNeighbours ? 'navigate' : 'seek';
}

// Left, Right and the track keys go to another item and leave the controls as they are, Back goes back, Info opens
// the details; the volume keys never reach the app on webOS
const KEEP_CONTROLS_HIDDEN: RemoteAction[] = ['left', 'right', 'previousTrack', 'nextTrack', 'back', 'info'];

/** Whether a key brings back the controls of a video: any key but those that go elsewhere */
export function keyShowsVideoControls(action: RemoteAction | null): boolean {
	return action !== null && KEEP_CONTROLS_HIDDEN.indexOf(action) < 0;
}

/** What a play or pause key asks of a player: true to play, false to pause, null for another key */
export function playPauseWantsPlay(action: RemoteAction | null, isPlaying: boolean): boolean | null {
	if (action === 'play') return true;
	if (action === 'pause') return false;
	if (action === 'playPause') return !isPlaying;
	return null;
}

/** Where a key is pressed in the viewer of a flat photo */
export interface PhotoKeyContext {
	/** The photo is zoomed in: the arrows move it */
	zoomed: boolean;
	/** The focus is on the action bar: the arrows move between its buttons */
	inActionBar: boolean;
}

/**
 * The quarter turns a key gives a flat photo: 1 clockwise, -1 counterclockwise, null for a key that does not turn it.
 * Up turns it only when it is not zoomed and the focus is on the photo; the keyboard keys turn it anywhere.
 */
export function photoRotationStep(action: RemoteAction | null, where: PhotoKeyContext): 1 | -1 | null {
	if (action === 'rotateRight') return 1;
	if (action === 'rotateLeft') return -1;
	if (action === 'up' && !where.zoomed && !where.inActionBar) return 1;
	return null;
}
