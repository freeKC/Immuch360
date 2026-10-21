// The one-key rotation of the viewer (src/immuch360/rotation/): where a turn is kept, the requests it makes to the
// server, and what the viewer draws meanwhile. The server, the turns kept on the TV and the clock are fakes.

import {test, describe} from 'node:test';
import assert from 'node:assert/strict';
import {DEBOUNCE_MS, NOTICE_MS, PICTURE_WAIT_MS, RotationController} from '../../src/immuch360/rotation/controller.ts';
import {rotationMode, takesEdits} from '../../src/immuch360/rotation/mode.ts';

const settle = async () => {
	for (let i = 0; i < 30; i++) await new Promise((resolve) => setImmediate(resolve));
};

function fakeTimers() {
	let now = 0;
	let seq = 0;
	const queue = new Map();
	return {
		set(callback, ms) {
			const id = ++seq;
			queue.set(id, {at: now + ms, callback});
			return id;
		},
		clear(id) {
			queue.delete(id);
		},
		async advance(ms) {
			const end = now + ms;
			for (;;) {
				await settle();
				let next = null;
				for (const [id, timer] of queue) if (timer.at <= end && (!next || timer.at < next[1].at)) next = [id, timer];
				if (!next) break;
				queue.delete(next[0]);
				now = next[1].at;
				next[1].callback();
			}
			now = end;
			await settle();
		},
	};
}

const ME = 'user-me';
const ASSET = 'asset-1';

function fakeServer(options = {}) {
	const state = {
		edits: options.edits ?? [],
		thumbhash: 'T0',
		key: 'T0',
		ownerId: options.ownerId ?? ME,
		version: options.version ?? {major: 3, minor: 2, patch: 4},
		requests: [],
		jobsDone: 0,
		failWith: options.failWith,
		neverReady: options.neverReady ?? false,
		shown: [],
	};
	let pendingJob = null;
	const server = {
		context: async () => ({userId: ME, serverVersion: state.version}),
		asset: async () => {
			if (pendingJob && !state.neverReady) {
				state.thumbhash = pendingJob;
				pendingJob = null;
				state.jobsDone++;
			}
			return {
				ownerId: state.ownerId,
				type: 'IMAGE',
				originalFileName: 'IMG_0001.JPG',
				livePhotoVideoId: null,
				isTrashed: false,
				projectionType: null,
				thumbhash: state.thumbhash,
			};
		},
		edits: async () => state.edits,
		replaceEdits: async (_id, edits) => {
			if (state.failWith) throw state.failWith;
			state.requests.push(edits);
			state.edits = edits;
			pendingJob = `T${state.requests.length}`;
		},
		pictureKey: () => state.key,
		showPicture: async (_id, key) => {
			state.shown.push(key);
			state.key = key;
		},
	};
	return {server, state};
}

function fakeDevice(initial = {}) {
	const turns = {...initial};
	return {
		turns: (id) => turns[id] ?? 0,
		setTurns: (id, value) => {
			if (value) turns[id] = value;
			else delete turns[id];
		},
		all: turns,
	};
}

function setup(options = {}) {
	const {server, state} = fakeServer(options);
	const device = fakeDevice(options.device);
	const timers = fakeTimers();
	const controller = new RotationController(server, device, timers);
	return {controller, server, state, device, timers};
}

describe('a photo of the user on a server that takes edits', () => {
	test('one press turns it on screen at once, then on the server, and the new picture takes its place', async () => {
		const {controller, state, timers} = setup();
		controller.rotate(ASSET, 1);
		assert.equal(controller.displayTurns(ASSET), 1);
		assert.equal(controller.isSaving(ASSET), true);
		await timers.advance(DEBOUNCE_MS - 1);
		assert.deepEqual(state.requests, []);
		await timers.advance(1);
		assert.deepEqual(state.requests, [[{action: 'rotate', parameters: {angle: 90}}]]);
		await timers.advance(1000);
		assert.deepEqual(state.shown, ['T1']);
		assert.equal(state.key, 'T1');
		// The new picture carries the turn: nothing more is drawn on it
		assert.equal(controller.displayTurns(ASSET), 0);
		assert.equal(controller.isSaving(ASSET), false);
		assert.equal(controller.notice(ASSET), null);
	});

	test('quick presses make one request, four make none', async () => {
		const {controller, state, timers} = setup();
		controller.rotate(ASSET, 1);
		await timers.advance(300);
		controller.rotate(ASSET, 1);
		await timers.advance(300);
		controller.rotate(ASSET, 1);
		assert.equal(controller.displayTurns(ASSET), 3);
		await timers.advance(DEBOUNCE_MS + 1000);
		assert.deepEqual(state.requests, [[{action: 'rotate', parameters: {angle: 270}}]]);
		assert.equal(controller.displayTurns(ASSET), 0);

		const other = setup();
		for (let i = 0; i < 4; i++) other.controller.rotate(ASSET, 1);
		await other.timers.advance(DEBOUNCE_MS + 1000);
		assert.deepEqual(other.state.requests, []);
		assert.equal(other.controller.displayTurns(ASSET), 0);
	});

	test('a press while a request runs is sent after it, with the whole list', async () => {
		const {controller, state, timers} = setup();
		controller.rotate(ASSET, 1);
		await timers.advance(DEBOUNCE_MS);
		assert.equal(state.requests.length, 1);
		// The server has not made the picture yet
		controller.rotate(ASSET, 1);
		assert.equal(controller.displayTurns(ASSET), 2);
		await timers.advance(DEBOUNCE_MS);
		await timers.advance(1000);
		await timers.advance(DEBOUNCE_MS + 1000);
		assert.deepEqual(state.requests, [[{action: 'rotate', parameters: {angle: 90}}], [{action: 'rotate', parameters: {angle: 180}}]]);
		assert.equal(state.key, 'T2');
		assert.equal(controller.displayTurns(ASSET), 0);
	});

	test('counterclockwise from no edit is 270, and back to none removes the edits', async () => {
		const {controller, state, timers} = setup({edits: [{action: 'rotate', parameters: {angle: 90}}]});
		controller.rotate(ASSET, -1);
		await timers.advance(DEBOUNCE_MS + 1000);
		assert.deepEqual(state.requests, [[]]);

		const other = setup();
		other.controller.rotate(ASSET, -1);
		await other.timers.advance(DEBOUNCE_MS + 1000);
		assert.deepEqual(other.state.requests, [[{action: 'rotate', parameters: {angle: 270}}]]);
	});

	test('the edits made in the editor are kept: the crop as it is, the mirror folded with the turn', async () => {
		const crop = {action: 'crop', parameters: {x: 10, y: 20, width: 300, height: 200}};
		const {controller, state, timers} = setup({edits: [crop, {action: 'mirror', parameters: {axis: 'horizontal'}}]});
		controller.rotate(ASSET, 1);
		await timers.advance(DEBOUNCE_MS + 1000);
		assert.deepEqual(state.requests, [[crop, {action: 'mirror', parameters: {axis: 'vertical'}}, {action: 'rotate', parameters: {angle: 270}}]]);
	});

	test('a turn kept on the TV before is folded into the first request, then forgotten', async () => {
		const {controller, state, device, timers} = setup({device: {[ASSET]: 1}});
		assert.equal(controller.displayTurns(ASSET), 1);
		controller.rotate(ASSET, 1);
		assert.equal(controller.displayTurns(ASSET), 2);
		await timers.advance(DEBOUNCE_MS + 1000);
		assert.deepEqual(state.requests, [[{action: 'rotate', parameters: {angle: 180}}]]);
		assert.deepEqual(device.all, {});
		assert.equal(controller.displayTurns(ASSET), 0);
	});

	test('the session ends once idle, and the picture shown keeps the turn', async () => {
		const {controller, timers} = setup();
		controller.rotate(ASSET, 1);
		await timers.advance(DEBOUNCE_MS + 1000);
		await timers.advance(120000);
		assert.equal(controller.displayTurns(ASSET), 0);
		assert.equal(controller.isSaving(ASSET), false);
	});

	test('a picture the server does not make in time is asked for afresh and shown as it is', async () => {
		const {controller, state, timers} = setup({neverReady: true});
		controller.rotate(ASSET, 1);
		await timers.advance(DEBOUNCE_MS + PICTURE_WAIT_MS + 5000);
		assert.equal(state.requests.length, 1);
		assert.equal(state.shown.length, 1);
		assert.match(state.shown[0], /^edit\d+$/);
		assert.equal(controller.displayTurns(ASSET), 0);
	});
});

describe('a turn the server does not keep stays on the TV', () => {
	test("a partner's photo: kept on the TV, said once", async () => {
		const {controller, state, device, timers} = setup({ownerId: 'someone-else'});
		controller.rotate(ASSET, 1);
		await timers.advance(DEBOUNCE_MS);
		assert.deepEqual(state.requests, []);
		assert.deepEqual(device.all, {[ASSET]: 1});
		assert.equal(controller.displayTurns(ASSET), 1);
		assert.equal(controller.notice(ASSET), 'keptOnDevice');
		await timers.advance(NOTICE_MS);
		assert.equal(controller.notice(ASSET), null);
		// The next turns of that photo go to the TV at once, without a word
		controller.rotate(ASSET, 1);
		assert.deepEqual(device.all, {[ASSET]: 2});
		assert.equal(controller.displayTurns(ASSET), 2);
		controller.rotate('asset-2', -1);
		await timers.advance(DEBOUNCE_MS);
		assert.equal(device.all['asset-2'], 3);
		assert.equal(controller.notice('asset-2'), null);
	});

	test('a server older than 2.6.0', async () => {
		const {controller, state, device, timers} = setup({version: {major: 2, minor: 5, patch: 6}});
		controller.rotate(ASSET, 1);
		await timers.advance(DEBOUNCE_MS);
		assert.deepEqual(state.requests, []);
		assert.deepEqual(device.all, {[ASSET]: 1});
	});

	test('a photo the server refuses to edit, or an API key without the permission', async () => {
		for (const status of [400, 403]) {
			const {controller, device, timers} = setup({failWith: Object.assign(new Error('refused'), {status})});
			controller.rotate(ASSET, 1);
			await timers.advance(DEBOUNCE_MS);
			assert.deepEqual(device.all, {[ASSET]: 1}, String(status));
			assert.equal(controller.displayTurns(ASSET), 1);
			assert.equal(controller.notice(ASSET), 'keptOnDevice');
		}
	});
});

test('a request that fails otherwise brings the photo back, with a message', async () => {
	const {controller, device, timers} = setup({failWith: Object.assign(new Error('Network error'), {status: undefined})});
	controller.rotate(ASSET, 1);
	assert.equal(controller.displayTurns(ASSET), 1);
	await timers.advance(DEBOUNCE_MS);
	assert.deepEqual(device.all, {});
	assert.equal(controller.displayTurns(ASSET), 0);
	assert.equal(controller.notice(ASSET), 'failed');
});

test('listeners hear every change of what the viewer draws', async () => {
	const {controller, timers} = setup();
	let heard = 0;
	const stop = controller.subscribe(() => heard++);
	const before = controller.snapshot();
	controller.rotate(ASSET, 1);
	assert.ok(heard > 0);
	assert.notEqual(controller.snapshot(), before);
	stop();
	const after = heard;
	await timers.advance(DEBOUNCE_MS + 1000);
	assert.equal(heard, after);
});

describe('rotationMode', () => {
	const context = {userId: ME, serverVersion: {major: 3, minor: 2, patch: 4}};
	const photo = {ownerId: ME, type: 'IMAGE', originalFileName: 'IMG_0001.JPG', livePhotoVideoId: null, isTrashed: false, projectionType: null};

	test('server for a photo of the user on a server that takes edits', () => {
		assert.equal(rotationMode(context, photo), 'server');
	});

	test("device for what the server would refuse, or what is not the user's", () => {
		assert.equal(rotationMode(context, {...photo, ownerId: 'partner'}), 'device');
		assert.equal(rotationMode({...context, userId: null}, photo), 'device');
		assert.equal(rotationMode({...context, serverVersion: null}, photo), 'device');
		assert.equal(rotationMode(context, {...photo, livePhotoVideoId: 'v1'}), 'device');
		assert.equal(rotationMode(context, {...photo, isTrashed: true}), 'device');
		assert.equal(rotationMode(context, {...photo, originalFileName: 'anim.GIF'}), 'device');
		assert.equal(rotationMode(context, {...photo, originalFileName: 'logo.svg'}), 'device');
		assert.equal(rotationMode(context, {...photo, originalFileName: 'IMG_1.insp'}), 'device');
		assert.equal(rotationMode(context, {...photo, projectionType: 'EQUIRECTANGULAR'}), 'device');
		assert.equal(rotationMode(context, {...photo, type: 'VIDEO'}), 'device');
	});

	test('edits from Immich 2.6.0', () => {
		assert.equal(takesEdits({major: 2, minor: 6, patch: 0}), true);
		assert.equal(takesEdits({major: 2, minor: 5, patch: 9}), false);
		assert.equal(takesEdits({major: 3, minor: 0, patch: 0}), true);
		assert.equal(takesEdits({major: 1, minor: 140, patch: 0}), false);
		assert.equal(takesEdits(null), false);
	});
});
