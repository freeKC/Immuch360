// Immuch360: one video through Samsung's AVPlay player against a stand in that keeps AVPlay's states (fakeAvplay.ts):
// the order of the calls, the rotation value per turn, the rect, the seeks, the end, the failures and the cleanup
// (issue 17, avplaySession.ts). The real player could not be tried here: no Samsung TV, and the emulator has no AVPlay.
import {AvplaySession, type AvplayFailure, type AvplaySessionOptions} from './avplaySession';
import {avplayDisplay, playerRect, resolveAvplayTurn, videoStreamOf} from './avplayTurn';
import {fakeAvplay, type FakeAvplay, type FakeAvplayOptions} from './fakeAvplay';
import {lastVideoTurnLine, resetVideoTurnNotes} from './orientation';
import {avplayErrorName} from '../../platform/avplay';

const URL = 'http://nas:2283/api/assets/v1/video/playback?apiKey=SECRET-KEY';
// The reporter's video: filmed upright, stored as 3840 x 2160 frames with the orientation 6 (issue 17)
const UPRIGHT_4K = {orientation: '6', width: 3840, height: 2160};

let tv: FakeAvplay;
let failures: AvplayFailure[];
let events: string[];
let shown: {degrees: number; fit: string; fitMatters: boolean}[];

function session(options: Partial<AvplaySessionOptions> = {}, fake: FakeAvplayOptions = {}): AvplaySession {
	tv = fakeAvplay(fake);
	return new AvplaySession({
		api: tv.api,
		url: URL,
		startAt: 0,
		autoplay: true,
		turn: {info: UPRIGHT_4K, manual: null},
		area: () => ({left: 0, top: 0, width: 1920, height: 1080}),
		viewportWidth: () => 1920,
		onChange: () => {},
		onEvent: (type) => events.push(type),
		onFailed: (failure) => failures.push(failure),
		onTurnShown: (turn) => shown.push(turn),
		...options,
	});
}

beforeEach(() => {
	jest.useFakeTimers();
	failures = [];
	events = [];
	shown = [];
	resetVideoTurnNotes();
});

afterEach(() => {
	jest.useRealTimers();
});

test("Samsung's order: open, listener, a display, prepare; once prepared the rotation, the method and the rect again, then play", () => {
	const player = session({hasPlayerObject: () => true});
	player.start();
	expect(tv.names()).toEqual(['open', 'setListener', 'setTimeoutForBuffering', 'setDisplayMethod', 'setDisplayRect', 'prepareAsync']);
	expect(tv.calls[0]).toEqual(['open', URL]);
	expect(player.paused).toBe(false);
	expect(player.loading).toBe(true);
	tv.prepareOk();
	expect(tv.names().slice(6)).toEqual(['setDisplayRotation', 'setDisplayMethod', 'setDisplayRect', 'play']);
	expect(tv.calls.slice(6, 9)).toEqual([
		['setDisplayRotation', 'PLAYER_DISPLAY_ROTATION_90'],
		['setDisplayMethod', 'PLAYER_DISPLAY_MODE_LETTER_BOX'],
		['setDisplayRect', 0, 0, 1920, 1080],
	]);
	expect(tv.state).toBe('PLAYING');
	expect(player.duration).toBe(60);
	expect(player.readyState).toBe(4);
	expect(events).toEqual(['loadedmetadata', 'playing']);
	expect(shown).toEqual([{degrees: 90, fit: 'player', fitMatters: true}]);
	tv.tick(1500);
	expect(player.currentTime).toBe(1.5);
	expect(player.loading).toBe(false);
	// The line of the About page: what was asked, what each call did, how far it went; never the URL nor its key
	expect(lastVideoTurnLine()).toBe(
		'tizen AVPlay, TV ?, Tizen ?, firmware ?, orientation 6, stored 3840 x 2160, stream 3840 x 2160 HEVC, object yes, auto 90, fit player, ' +
			'PLAYER_DISPLAY_ROTATION_90 ok, letterbox ok, rect 0,0,1920,1080 ok, reached frames at 1.5 s'
	);
	expect(lastVideoTurnLine()).not.toContain('SECRET');
});

test('the rotation value of each turn: 6 is 90, 8 is 270, a turn by hand stands, a transcode already upright is left alone', () => {
	const rotationSent = (turn: AvplaySessionOptions['turn'], fake: FakeAvplayOptions = {}) => {
		const player = session({turn}, fake);
		player.start();
		tv.prepareOk();
		player.close();
		return tv.calls.filter((call) => call[0] === 'setDisplayRotation').map((call) => call[1]);
	};
	expect(rotationSent({info: UPRIGHT_4K, manual: null})).toEqual(['PLAYER_DISPLAY_ROTATION_90']);
	expect(rotationSent({info: {...UPRIGHT_4K, orientation: 8}, manual: null})).toEqual(['PLAYER_DISPLAY_ROTATION_270']);
	expect(rotationSent({info: UPRIGHT_4K, manual: {degrees: 180}})).toEqual(['PLAYER_DISPLAY_ROTATION_180']);
	expect(rotationSent({info: UPRIGHT_4K, manual: {degrees: 0}})).toEqual(['PLAYER_DISPLAY_ROTATION_NONE']);
	// A 1080 x 1920 stream of a 3840 x 2160 file: Immich's software transcode turned it already
	expect(rotationSent({info: UPRIGHT_4K, manual: null}, {stream: {Width: 1080, Height: 1920, fourCC: 'H264'}})).toEqual(['PLAYER_DISPLAY_ROTATION_NONE']);
	expect(lastVideoTurnLine()).toContain('stream 1080 x 1920 H264, object no, not turned, fit player, PLAYER_DISPLAY_ROTATION_NONE ok');
	// A video with no flag, turned by hand from the start of the session
	expect(rotationSent({info: {orientation: '1', width: 1920, height: 1080}, manual: {degrees: 90}})).toEqual(['PLAYER_DISPLAY_ROTATION_90']);
});

test('"Turn the picture" while it plays: the new rotation, then the method and the rect again; "Fit the picture" gives the turned shape', () => {
	const player = session();
	player.start();
	tv.prepareOk();
	const before = tv.calls.length;
	player.setTurn({info: UPRIGHT_4K, manual: {degrees: 180}});
	expect(tv.calls.slice(before)).toEqual([
		['setDisplayRotation', 'PLAYER_DISPLAY_ROTATION_180'],
		['setDisplayMethod', 'PLAYER_DISPLAY_MODE_LETTER_BOX'],
		['setDisplayRect', 0, 0, 1920, 1080],
	]);
	expect(shown[shown.length - 1]).toEqual({degrees: 180, fit: 'player', fitMatters: false});
	const next = tv.calls.length;
	// 3840 x 2160 turned: 2160 x 3840, the largest of that shape in 1920 x 1080 is 608 x 1080, centred
	player.setTurn({info: UPRIGHT_4K, manual: {degrees: 270, fit: 'file'}});
	expect(tv.calls.slice(next)).toEqual([
		['setDisplayRotation', 'PLAYER_DISPLAY_ROTATION_270'],
		['setDisplayMethod', 'PLAYER_DISPLAY_MODE_FULL_SCREEN'],
		['setDisplayRect', 656, 0, 608, 1080],
	]);
	expect(shown[shown.length - 1]).toEqual({degrees: 270, fit: 'file', fitMatters: true});
	expect(lastVideoTurnLine()).toContain('by hand 270, fit file, PLAYER_DISPLAY_ROTATION_270 ok, full screen ok, rect 656,0,608,1080 ok');
	expect(tv.state).toBe('PLAYING');
});

test('the rect is given on the 1920 x 1080 screen whatever the size of the page (a 1280 x 720 app)', () => {
	expect(playerRect({left: 0, top: 0, width: 1280, height: 720}, 1280)).toEqual({x: 0, y: 0, width: 1920, height: 1080});
	expect(playerRect({left: 100, top: 50, width: 640, height: 360}, 1280)).toEqual({x: 150, y: 75, width: 960, height: 540});
	// Unknown: the whole screen
	expect(playerRect(null, 1920)).toEqual({x: 0, y: 0, width: 1920, height: 1080});
	expect(playerRect({left: 0, top: 0, width: 0, height: 0}, 1920)).toEqual({x: 0, y: 0, width: 1920, height: 1080});
	expect(avplayDisplay({x: 0, y: 0, width: 1920, height: 1080}, {source: 'auto', degrees: 0, fit: 'file'}, {width: 1440, height: 1080})).toEqual({
		method: 'PLAYER_DISPLAY_MODE_FULL_SCREEN',
		rect: {x: 240, y: 0, width: 1440, height: 1080},
	});
});

test('a rotation the TV refuses is noted, and the video still plays', () => {
	const player = session({}, {throws: {setDisplayRotation: 'NotSupportedError'}});
	player.start();
	tv.prepareOk();
	expect(tv.state).toBe('PLAYING');
	expect(failures).toEqual([]);
	expect(lastVideoTurnLine()).toContain('PLAYER_DISPLAY_ROTATION_90 NotSupportedError, letterbox ok, rect 0,0,1920,1080 ok');
	const older = session({}, {noRotation: true});
	older.start();
	tv.prepareOk();
	expect(lastVideoTurnLine()).toContain('PLAYER_DISPLAY_ROTATION_90 missing');
});

test('a switch from the HTML element starts at its time: seek once prepared, play once it landed', () => {
	const player = session({startAt: 12.5});
	player.start();
	tv.prepareOk();
	expect(tv.calls[tv.calls.length - 1]).toEqual(['seekTo', 12500]);
	expect(tv.state).toBe('READY');
	expect(player.currentTime).toBe(12.5);
	tv.seekOk();
	expect(tv.state).toBe('PLAYING');
	tv.tick(500);
	expect(player.currentTime).toBe(13);
});

test('seeks: the time asked for shows at once, one seek at a time, the latest asked for goes next; play pressed meanwhile plays after', () => {
	const player = session();
	player.start();
	tv.prepareOk();
	tv.tick(5000);
	player.seek(30);
	expect(player.currentTime).toBe(30);
	player.seek(40);
	player.seek(20);
	expect(player.currentTime).toBe(20);
	expect(tv.calls.filter((call) => call[0] === 'seekTo')).toEqual([['seekTo', 30000]]);
	// Time reported during the seek does not move the knob
	tv.tick(500);
	expect(player.currentTime).toBe(20);
	tv.seekOk();
	expect(tv.calls.filter((call) => call[0] === 'seekTo')).toEqual([
		['seekTo', 30000],
		['seekTo', 20000],
	]);
	tv.seekOk();
	expect(player.currentTime).toBe(20);
	// Past the end: the end
	player.seek(500);
	expect(tv.calls[tv.calls.length - 1]).toEqual(['seekTo', 60000]);
	// A seek that fails leaves the time where the player says it is
	tv.seekFail();
	expect(player.currentTime).toBe(20);
	expect(failures).toEqual([]);
	// Paused, a seek, play pressed while it is on its way
	player.pause();
	expect(tv.state).toBe('PAUSED');
	expect(player.paused).toBe(true);
	player.seek(10);
	player.play();
	expect(tv.state).toBe('PAUSED');
	tv.seekOk();
	expect(tv.state).toBe('PLAYING');
});

test('Pause during a 10 s jump: no call until the seek lands, then AVPlay is paused (Samsung: pause throws meanwhile)', () => {
	const player = session();
	player.start();
	tv.prepareOk();
	tv.tick(4000);
	player.seek(14);
	const before = tv.calls.length;
	player.pause();
	// Nothing sent while the seek is on its way (the stand in would throw InvalidAccessError), the viewer shows paused
	expect(tv.calls.slice(before)).toEqual([]);
	expect(player.paused).toBe(true);
	expect(events[events.length - 1]).toBe('pause');
	expect(tv.state).toBe('PLAYING');
	tv.seekOk();
	expect(tv.names().slice(-1)).toEqual(['pause']);
	expect(tv.state).toBe('PAUSED');
	expect(player.paused).toBe(true);
	expect(player.currentTime).toBe(14);
	// A failed seek too: paused where the player is
	player.play();
	expect(tv.state).toBe('PLAYING');
	player.seek(30);
	player.pause();
	tv.seekFail();
	expect(tv.state).toBe('PAUSED');
	// Pause then Play during a seek: it plays on, no pause sent
	player.play();
	player.seek(40);
	player.pause();
	player.play();
	const during = tv.calls.length;
	tv.seekOk();
	expect(tv.names().slice(during)).not.toContain('pause');
	expect(tv.state).toBe('PLAYING');
	expect(player.paused).toBe(false);
	expect(failures).toEqual([]);
});

test('"Turn the picture" during a seek: sent once it lands, after the last seek queued', () => {
	const player = session();
	player.start();
	tv.prepareOk();
	tv.tick(4000);
	player.seek(14);
	player.seek(24);
	const before = tv.calls.length;
	player.setTurn({info: UPRIGHT_4K, manual: {degrees: 180}});
	expect(tv.calls.slice(before)).toEqual([]);
	tv.seekOk();
	// The queued seek goes first, the turn waits for it too
	expect(tv.calls.slice(before)).toEqual([['seekTo', 24000]]);
	tv.seekOk();
	expect(tv.calls.slice(before + 1)).toEqual([
		['setDisplayRotation', 'PLAYER_DISPLAY_ROTATION_180'],
		['setDisplayMethod', 'PLAYER_DISPLAY_MODE_LETTER_BOX'],
		['setDisplayRect', 0, 0, 1920, 1080],
	]);
	expect(shown[shown.length - 1]).toEqual({degrees: 180, fit: 'player', fitMatters: false});
	expect(lastVideoTurnLine()).toContain('by hand 180, fit player, PLAYER_DISPLAY_ROTATION_180 ok, letterbox ok, rect 0,0,1920,1080 ok');
	// During the seek to the start time of a switch from the HTML element: the turn comes before play
	const switched = session({startAt: 12.5});
	switched.start();
	tv.prepareOk();
	const start = tv.calls.length;
	switched.setTurn({info: UPRIGHT_4K, manual: {degrees: 270}});
	expect(tv.calls.slice(start)).toEqual([]);
	tv.seekOk();
	expect(tv.names().slice(start)).toEqual(['setDisplayRotation', 'setDisplayMethod', 'setDisplayRect', 'play']);
	expect(tv.calls[start]).toEqual(['setDisplayRotation', 'PLAYER_DISPLAY_ROTATION_270']);
	expect(failures).toEqual([]);
});

test('the end: stop (else the last frame stays), paused at the end; play again starts it over', () => {
	const player = session();
	player.start();
	tv.prepareOk();
	tv.tick(1000);
	tv.complete();
	expect(tv.names().slice(-1)).toEqual(['stop']);
	expect(tv.state).toBe('IDLE');
	expect(player.paused).toBe(true);
	expect(player.ended).toBe(true);
	expect(player.currentTime).toBe(60);
	expect(events.slice(-2)).toEqual(['pause', 'ended']);
	expect(lastVideoTurnLine()).toContain('reached end at 60.0 s');
	player.play();
	expect(tv.names().slice(-7)).toEqual(['close', 'open', 'setListener', 'setTimeoutForBuffering', 'setDisplayMethod', 'setDisplayRect', 'prepareAsync']);
	tv.prepareOk();
	expect(tv.state).toBe('PLAYING');
	expect(player.currentTime).toBe(0);
});

test('an error before the first frame: the player is stopped and closed, the viewer told where; never the message of the error', () => {
	const player = session();
	player.start();
	tv.prepareFail(Object.assign(new Error(`cannot open ${URL}`), {name: 'PLAYER_ERROR_CONNECTION_FAILED'}));
	expect(failures).toEqual([{stage: 'prepare', error: 'PLAYER_ERROR_CONNECTION_FAILED', at: 0, sessionWide: true}]);
	expect(tv.state).toBe('NONE');
	expect(tv.names().slice(-1)).toEqual(['close']);
	expect(lastVideoTurnLine()).toBe(
		'tizen AVPlay, TV ?, Tizen ?, firmware ?, orientation 6, stored 3840 x 2160, stream ?, object no, reached opened, failed at prepare: PLAYER_ERROR_CONNECTION_FAILED, HTML player instead'
	);
	expect(lastVideoTurnLine()).not.toContain('SECRET');
	// Nothing more once failed
	player.play();
	player.close();
	expect(failures).toHaveLength(1);
});

test('open refused, play refused, an error while it plays, and the decoder taken by another app', () => {
	const refused = session({}, {throws: {open: 'NotSupportedError'}});
	refused.start();
	expect(failures.pop()).toEqual({stage: 'open', error: 'NotSupportedError', at: 0, sessionWide: true});
	const noPlay = session({}, {throws: {play: 'InvalidStateError'}});
	noPlay.start();
	tv.prepareOk();
	expect(failures.pop()).toEqual({stage: 'play', error: 'InvalidStateError', at: 0, sessionWide: false});
	expect(tv.state).toBe('NONE');
	const midway = session();
	midway.start();
	tv.prepareOk();
	tv.tick(8000);
	tv.error('PLAYER_ERROR_NOT_SUPPORTED_FORMAT');
	expect(failures.pop()).toEqual({stage: 'playback', error: 'PLAYER_ERROR_NOT_SUPPORTED_FORMAT', at: 8, sessionWide: false});
	expect(tv.state).toBe('NONE');
	const conflicted = session();
	conflicted.start();
	tv.prepareOk();
	tv.listener?.onresourceconflicted?.();
	expect(failures.pop()).toMatchObject({stage: 'play', error: 'RESOURCE_CONFLICTED'});
});

test('no frame time within the delay: it gives up and closes; a pause by the user stops the clock', () => {
	const player = session({startTimeoutMs: 12000});
	player.start();
	tv.prepareOk();
	jest.advanceTimersByTime(11999);
	expect(failures).toEqual([]);
	jest.advanceTimersByTime(1);
	expect(failures).toEqual([{stage: 'start', error: 'no frame within 12 s', at: 0, sessionWide: false}]);
	expect(tv.state).toBe('NONE');
	const paused = session({startTimeoutMs: 12000});
	paused.start();
	paused.pause();
	tv.prepareOk();
	jest.advanceTimersByTime(20000);
	expect(failures).toHaveLength(1);
	expect(tv.state).toBe('READY');
	expect(paused.paused).toBe(true);
	// Frames that come in time stop the clock
	const playing = session({startTimeoutMs: 12000});
	playing.start();
	tv.prepareOk();
	tv.tick(400);
	jest.advanceTimersByTime(20000);
	expect(failures).toHaveLength(1);
});

test('a callback that comes after Back is ignored (the next video, or the viewer closed during prepare)', () => {
	const player = session();
	let late: (() => void) | undefined;
	const prepare = tv.api.prepareAsync;
	tv.api.prepareAsync = (ok, fail) => {
		late = ok;
		prepare.call(tv.api, ok, fail);
	};
	player.start();
	player.close();
	expect(tv.names().slice(-1)).toEqual(['close']);
	late?.();
	expect(tv.names().indexOf('play')).toBe(-1);
	expect(events).toEqual([]);
});

test('the app hidden: the player stops and closes; shown again it opens at the same time, paused', () => {
	const player = session();
	player.start();
	tv.prepareOk();
	tv.tick(7000);
	player.hide();
	expect(tv.names().slice(-2)).toEqual(['stop', 'close']);
	expect(tv.state).toBe('NONE');
	expect(player.paused).toBe(true);
	expect(events[events.length - 1]).toBe('pause');
	player.show();
	tv.prepareOk();
	expect(tv.calls[tv.calls.length - 1]).toEqual(['seekTo', 7000]);
	tv.seekOk();
	expect(tv.state).toBe('READY');
	expect(player.paused).toBe(true);
	expect(failures).toEqual([]);
	player.play();
	expect(tv.state).toBe('PLAYING');
});

test('leaving: stop and close in every state', () => {
	const preparing = session();
	preparing.start();
	preparing.close();
	expect(tv.names().slice(-1)).toEqual(['close']);
	expect(tv.state).toBe('NONE');
	const playing = session();
	playing.start();
	tv.prepareOk();
	playing.close();
	expect(tv.names().slice(-2)).toEqual(['stop', 'close']);
	const paused = session();
	paused.start();
	tv.prepareOk();
	paused.pause();
	paused.close();
	paused.close();
	expect(tv.names().slice(-2)).toEqual(['stop', 'close']);
	expect(tv.names().filter((name) => name === 'close')).toHaveLength(1);
});

test('the stream of getCurrentStreamInfo, the turn rule and the error names', () => {
	expect(videoStreamOf([{type: 'VIDEO', extra_info: '{"fourCC":"H264","Width":"1920","Height":"1080","Bit_rate":" 477000"}'}])).toEqual({width: 1920, height: 1080, codec: 'H264'});
	expect(videoStreamOf([{type: 'AUDIO', extra_info: '{}'}, {type: 'VIDEO', extra_info: 'not json'}])).toBeNull();
	expect(videoStreamOf(undefined)).toBeNull();
	expect(resolveAvplayTurn(UPRIGHT_4K, null, null)).toEqual({source: 'auto', degrees: 90, fit: 'player'});
	expect(resolveAvplayTurn({orientation: 1, width: 1920, height: 1080}, null, null)).toEqual({source: 'none', degrees: 0, fit: 'player'});
	expect(resolveAvplayTurn({orientation: 6, width: 1080, height: 1080}, {width: 1080, height: 1080, codec: null}, null).source).toBe('none');
	expect(resolveAvplayTurn(null, null, {degrees: 270, fit: 'file'})).toEqual({source: 'manual', degrees: 270, fit: 'file'});
	expect(avplayErrorName('PLAYER_ERROR_INVALID_URI')).toBe('PLAYER_ERROR_INVALID_URI');
	expect(avplayErrorName(`failed ${URL}`)).toBe('error');
	expect(avplayErrorName({name: 'InvalidStateError', message: URL})).toBe('InvalidStateError');
	expect(avplayErrorName({code: 9})).toBe('code 9');
	expect(avplayErrorName(null)).toBe('error');
});
