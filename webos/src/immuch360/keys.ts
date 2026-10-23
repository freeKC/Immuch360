// Immuch360: the keys of an LG or Samsung remote, and what the app does with them on a video.
//
// The key map of the Flutter app (mobile/lib/presentation/widgets/tv/remote_keys.dart and the TvShell) for the codes
// webOS sends, and those a Samsung TV sends once src/platform/tizen.ts has asked for them (Samsung's "Remote Control"
// guide). Documented in webos/README.md, "Remote control".
//
// | Remote key              | webOS keyCode (key)            | Samsung keyCode | Action                                     |
// |-------------------------|--------------------------------|-----------------|--------------------------------------------|
// | Arrows                  | 37 38 39 40                    | same            | move the focus; viewer: previous and next  |
// | OK                      | 13 (Enter)                     | same            | open; photo: controls; video: controls     |
// | Back                    | 461 (GoBack), 1536, 8, 10009, 27 | 10009         | close the overlay, then the page           |
// | Channel up and down     | 33 34 (PageUp, PageDown)       | 427 428         | timeline: a page; viewers: zoom by 1.25    |
// | Play, Pause, Play/Pause | 415, 19, 179                   | 415, 19, 10252  | play plays, pause pauses, the toggle toggles |
// | Rewind, Fast forward    | 412, 417                       | same            | 10 s back or forward                       |
// | Stop                    | 413                            | same            | close the video                            |
// | Previous, Next track    | 177, 176                       | 10232, 10233    | previous and next item, where the remote has them |
// | Info                    | 457 (and I of a keyboard)      | same            | the details of the item; Back closes them  |
// | Yellow                  | 405 (and R of a keyboard)      | same            | photo: turn 90° clockwise                  |
// | Blue                    | 406 (and Shift R)              | same            | photo: turn 90° counterclockwise           |
// | Red, Green              | 403, 404                       | same            | left free                                  |
//
// The turn keys are those of the Android TV app (isRemoteRotateClockwise of remote_keys.dart). A Magic Remote without
// colour keys shows them on screen (its ... or 123 button); the turn button of the photo's controls does the same. The
// turn is kept on the server as an edit, or on the TV (src/immuch360/rotation/).
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
	shiftKey?: boolean;
	ctrlKey?: boolean;
	altKey?: boolean;
	metaKey?: boolean;
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
	427: 'channelUp',
	428: 'channelDown',
	415: 'play',
	19: 'pause',
	179: 'playPause',
	10252: 'playPause',
	412: 'rewind',
	417: 'fastForward',
	413: 'stop',
	177: 'previousTrack',
	176: 'nextTrack',
	10232: 'previousTrack',
	10233: 'nextTrack',
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
	if (event.key === 'r' || event.key === 'R') {
		// R of a keyboard turns the photo, Shift R the other way; with Control, Alt or Meta it is a shortcut of another
		if (editingText || event.ctrlKey || event.altKey || event.metaKey) return null;
		return event.shiftKey ? 'rotateLeft' : 'rotateRight';
	}
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
// the details; the volume keys never reach the app on webOS, nor on Samsung TVs (src/platform/tizen.ts leaves them out)
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

/**
 * The quarter turns a key gives a flat photo: 1 clockwise (yellow, R), -1 counterclockwise (blue, Shift R), null for a
 * key that does not turn it. The arrows never turn it: Up is pressed by habit, to bring the controls back or to leave
 * the pointer of the Magic Remote, and a turn is saved on the server.
 */
export function photoRotationStep(action: RemoteAction | null): 1 | -1 | null {
	if (action === 'yellow' || action === 'rotateRight') return 1;
	if (action === 'blue' || action === 'rotateLeft') return -1;
	return null;
}
