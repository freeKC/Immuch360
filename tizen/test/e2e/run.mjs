#!/usr/bin/env node
// The end to end test of Immuch360 for Samsung TVs, in a headless Chromium standing in for the TV's web engine.
//
//   node tizen/test/e2e/run.mjs --chrome <binary> [--label 69] [--wgt tizen/build/wgt] [--out tizen/build/e2e/69]
//                               [--server http://127.0.0.1:2283]
//
// It loads a copy of the package folder (tizen/tools/build-wgt.mjs) from file:// as the TV does, with the content
// security policy of config.xml as a meta tag, the stand ins of tizen and webapis (fake-tizen.js) injected before the
// page, at 1920 x 1080. Chromium runs with --allow-file-access-from-files (the app reads its locale files from the
// package) and --disable-web-security, which stands in for the access policy of config.xml that lifts CORS on a TV
// (to be confirmed on a real TV). It drives the app with the key codes of a Samsung remote through the DevTools
// protocol, with Node's own WebSocket: current Playwright does not drive Chromium 69.
//
// Without --server it starts the fake Immich server (server.mjs) and signs in with its account. With --server it
// signs in to that server with E2E_EMAIL and E2E_PASSWORD from the environment (never printed).
//
// Steps, each with a screenshot in --out: the sign in page (no Phone tab; server, email and password typed, the
// keyboard's Done key), Back with the keyboard popup open (it closes the popup, not the form), the timeline
// (ChannelDown pages down), a 360° photo (the sphere is drawn, the arrows turn it, ChannelUp zooms), a video (it plays
// and holds the screen saver where the engine has H.264, else the "could not play" message shows), a flat photo (Up
// zooms it in, Back out) and a slideshow started from its controls (the Play/Pause key of a Samsung remote pauses and
// resumes it, the screen saver held), the rail (no Network shares), the
// About page (Tizen lines, no policy block, no DUID), a locale file read under the policy, the remote keys asked for,
// and Back on the first screen closing the app. An uncaught exception in the page fails the run too, unless
// KNOWN_EXCEPTIONS names it. results.json lists the steps; the exit code is 1 when one failed.

import {execFileSync, spawn} from 'node:child_process';
import {cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {createServer} from 'node:net';
import {tmpdir} from 'node:os';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {setTimeout as sleep} from 'node:timers/promises';
import {decodePng} from './png.mjs';
import {E2E_EMAIL, E2E_PASSWORD, startFakeImmich} from './server.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const TIZEN = resolve(HERE, '..', '..');

const args = process.argv.slice(2);
const option = (name, fallback = null) => (args.indexOf(name) >= 0 ? args[args.indexOf(name) + 1] : fallback);
const CHROME = option('--chrome');
const LABEL = option('--label', 'chromium');
const WGT = resolve(option('--wgt', join(TIZEN, 'build', 'wgt')));
const OUT = resolve(option('--out', join(TIZEN, 'build', 'e2e', LABEL)));
const SERVER = option('--server');
if (!CHROME) {
	console.error('[e2e] usage: run.mjs --chrome <binary> [--label 69] [--wgt <folder>] [--out <folder>] [--server <url>]');
	process.exit(2);
}

const KEY = {enter: 13, left: 37, up: 38, right: 39, down: 40, back: 10009, channelUp: 427, channelDown: 428, playPause: 10252, imeDone: 65376};
// Uncaught exceptions of the page that do not fail the run, each with the reason (none known today)
const KNOWN_EXCEPTIONS = [];
// A viewer, a video or a slideshow is open over the timeline
const OVERLAY_OPEN = `!!document.querySelector('canvas, video[data-immuch360-video], [data-spotlight-id="media-viewer"], [data-spotlight-id="slideshow"]')`;
const KEY_NAME = {13: 'Enter', 37: 'ArrowLeft', 38: 'ArrowUp', 39: 'ArrowRight', 40: 'ArrowDown'};

mkdirSync(OUT, {recursive: true});
const results = [];
const log = (line) => console.log(`[e2e ${LABEL}] ${line}`);

function freePort() {
	return new Promise((done, fail) => {
		const server = createServer();
		server.on('error', fail);
		server.listen(0, '127.0.0.1', () => {
			const {port} = server.address();
			server.close(() => done(port));
		});
	});
}

/** The page as the TV gets it: a copy of the folder, the policy of config.xml as a meta tag */
function preparePage() {
	const page = mkdtempSync(join(tmpdir(), 'immuch360-e2e-page-'));
	cpSync(WGT, page, {recursive: true});
	const config = readFileSync(join(page, 'config.xml'), 'utf8');
	const policy = /<tizen:content-security-policy>([^<]+)<\/tizen:content-security-policy>/.exec(config);
	if (!policy) throw new Error('config.xml has no content security policy');
	const version = /<widget\b[^>]*\sversion="([^"]+)"/.exec(config)?.[1] ?? '?';
	const html = readFileSync(join(page, 'index.html'), 'utf8');
	if (!html.includes('<head>')) throw new Error('index.html has no <head>');
	writeFileSync(join(page, 'index.html'), html.replace('<head>', `<head><meta http-equiv="Content-Security-Policy" content="${policy[1]}">`));
	return {page, policy: policy[1], version};
}

class DevTools {
	constructor(url) {
		this.socket = new WebSocket(url);
		this.next = 0;
		this.pending = new Map();
		this.listeners = [];
	}

	open() {
		return new Promise((done, fail) => {
			this.socket.onopen = () => done();
			this.socket.onerror = (event) => fail(new Error(`DevTools socket: ${event.message ?? 'error'}`));
			this.socket.onmessage = (event) => {
				const message = JSON.parse(event.data);
				if (message.id && this.pending.has(message.id)) {
					const {resolveCall, rejectCall, method} = this.pending.get(message.id);
					this.pending.delete(message.id);
					if (message.error) rejectCall(new Error(`${method}: ${message.error.message}`));
					else resolveCall(message.result);
				} else for (const listener of this.listeners) listener(message);
			};
		});
	}

	send(method, params = {}) {
		const id = ++this.next;
		this.socket.send(JSON.stringify({id, method, params}));
		return new Promise((resolveCall, rejectCall) => this.pending.set(id, {resolveCall, rejectCall, method}));
	}

	on(listener) {
		this.listeners.push(listener);
	}

	close() {
		this.socket.close();
	}
}

async function launch(profile) {
	const version = execFileSync(CHROME, ['--version'], {encoding: 'utf8'}).trim();
	const major = Number(/(\d+)\.\d+\.\d+/.exec(version)?.[1] ?? 0);
	const port = await freePort();
	const flags = [
		'--headless',
		`--remote-debugging-port=${port}`,
		`--user-data-dir=${profile}`,
		'--no-sandbox',
		'--no-first-run',
		'--no-default-browser-check',
		'--window-size=1920,1080',
		'--hide-scrollbars',
		'--mute-audio',
		'--lang=en-US',
		'--autoplay-policy=no-user-gesture-required',
		'--allow-file-access-from-files',
		'--disable-web-security',
		'--disable-dev-shm-usage',
		'--disable-background-timer-throttling',
		'--disable-renderer-backgrounding',
		// WebGL without a GPU: SwiftShader, named differently before and after ANGLE took over
		...(major >= 100 ? ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'] : ['--use-gl=swiftshader']),
		'about:blank',
	];
	// Headless Chromium takes its language from the environment, not from --lang: English, whatever the host's
	const child = spawn(CHROME, flags, {stdio: ['ignore', 'ignore', 'pipe'], env: {...process.env, LANG: 'en_US.UTF-8', LANGUAGE: 'en_US:en'}});
	let stderr = '';
	child.stderr.on('data', (part) => (stderr = (stderr + part).slice(-4000)));
	const deadline = Date.now() + 30000;
	while (Date.now() < deadline) {
		if (child.exitCode !== null) throw new Error(`${version} exited (${child.exitCode}): ${stderr.trim().split('\n').slice(-3).join(' | ')}`);
		try {
			const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
			const page = targets.find((target) => target.type === 'page');
			if (page) return {child, version, major, socketUrl: page.webSocketDebuggerUrl};
		} catch {
			// not listening yet
		}
		await sleep(250);
	}
	child.kill('SIGKILL');
	throw new Error(`${version} did not open its DevTools port in 30 s: ${stderr.trim().split('\n').slice(-3).join(' | ')}`);
}

async function main() {
	const {page, policy, version: appVersion} = preparePage();
	const profile = mkdtempSync(join(tmpdir(), 'immuch360-e2e-profile-'));
	const fake = SERVER ? null : await startFakeImmich();
	const server = SERVER ?? fake.url;
	const email = SERVER ? process.env.E2E_EMAIL : E2E_EMAIL;
	const password = SERVER ? process.env.E2E_PASSWORD : E2E_PASSWORD;
	if (!email || !password) throw new Error('--server needs E2E_EMAIL and E2E_PASSWORD in the environment');
	const secrets = [password];

	const browser = await launch(profile);
	log(`${browser.version}, app ${appVersion}, server ${SERVER ? server : 'fake Immich'}`);
	const devtools = new DevTools(browser.socketUrl);
	await devtools.open();
	const exceptions = [];
	const blocked = [];
	devtools.on((message) => {
		if (message.method === 'Runtime.exceptionThrown') {
			const details = message.params.exceptionDetails;
			exceptions.push((details.exception && details.exception.description) || details.text);
		}
		const text = message.method === 'Log.entryAdded' ? message.params.entry.text : message.method === 'Runtime.consoleAPICalled' ? message.params.args.map((arg) => arg.value ?? arg.description ?? '').join(' ') : '';
		if (/Content Security Policy|Refused to (load|connect|execute|apply)/.test(text)) blocked.push(text.slice(0, 300));
	});
	await devtools.send('Page.enable');
	await devtools.send('Runtime.enable');
	await devtools.send('Log.enable');
	await devtools.send('Page.addScriptToEvaluateOnNewDocument', {source: `window.__e2eVersion = ${JSON.stringify(appVersion)};\n${readFileSync(join(HERE, 'fake-tizen.js'), 'utf8')}`});
	await devtools.send('Emulation.setDeviceMetricsOverride', {width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false});

	const evaluate = async (expression) => {
		const reply = await devtools.send('Runtime.evaluate', {expression, returnByValue: true, awaitPromise: true});
		if (reply.exceptionDetails) throw new Error(`in the page: ${(reply.exceptionDetails.exception && reply.exceptionDetails.exception.description) || reply.exceptionDetails.text}`);
		return reply.result.value;
	};
	const waitFor = async (expression, what, timeoutMs = 30000) => {
		const deadline = Date.now() + timeoutMs;
		let last = null;
		while (Date.now() < deadline) {
			try {
				last = await evaluate(expression);
				if (last) return last;
			} catch (error) {
				last = error.message;
			}
			await sleep(250);
		}
		throw new Error(`waited ${timeoutMs / 1000} s for ${what}${last ? ` (last: ${String(last).slice(0, 200)})` : ''}`);
	};
	const key = async (keyCode, {repeat = 1, gapMs = 60} = {}) => {
		const name = KEY_NAME[keyCode] ?? '';
		for (let i = 0; i < repeat; i++) {
			await devtools.send('Input.dispatchKeyEvent', {type: 'rawKeyDown', windowsVirtualKeyCode: keyCode, nativeVirtualKeyCode: keyCode, key: name, code: name, autoRepeat: i > 0});
			if (i + 1 < repeat) await sleep(gapMs);
		}
		await devtools.send('Input.dispatchKeyEvent', {type: 'keyUp', windowsVirtualKeyCode: keyCode, nativeVirtualKeyCode: keyCode, key: name, code: name});
		await sleep(150);
	};
	const click = async ({x, y}) => {
		for (const type of ['mouseMoved', 'mousePressed', 'mouseReleased']) {
			await devtools.send('Input.dispatchMouseEvent', {type, x, y, button: type === 'mouseMoved' ? 'none' : 'left', clickCount: type === 'mouseMoved' ? 0 : 1});
		}
		await sleep(200);
	};
	// The centre of the first visible element whose own text is text (plain ES2017: the page may be Chromium 69)
	const leafByText = (text) => `(function () {
		var all = document.querySelectorAll('body *');
		for (var i = 0; i < all.length; i++) {
			var e = all[i];
			if (e.children.length === 0 && e.textContent.trim() === ${JSON.stringify(text)}) {
				var r = e.getBoundingClientRect();
				if (r.width > 0 && r.height > 0 && r.left >= 0 && r.left < window.innerWidth) return {x: r.left + r.width / 2, y: r.top + r.height / 2};
			}
		}
		return null;
	})()`;
	const centreOf = (selector) => `(function () {
		var e = document.querySelector(${JSON.stringify(selector)});
		if (!e) return null;
		e.scrollIntoView({block: 'center'});
		var r = e.getBoundingClientRect();
		return r.width > 0 ? {x: r.left + r.width / 2, y: r.top + r.height / 2} : null;
	})()`;
	const hasText = (text) => `document.body.innerText.indexOf(${JSON.stringify(text)}) >= 0`;
	const shot = async (name, clip) => {
		const {data} = await devtools.send('Page.captureScreenshot', clip ? {format: 'png', clip: {...clip, scale: 1}} : {format: 'png'});
		const png = Buffer.from(data, 'base64');
		if (name) writeFileSync(join(OUT, `${name}.png`), png);
		return png;
	};
	const pixel = async (x, y) => decodePng(await shot(null, {x, y, width: 1, height: 1})).rgba(0, 0);
	// A square of the screen as 8 x 8 cells of mean colour, and how far two such squares are (0 to 255)
	const region = async (x, y, size) => {
		const image = decodePng(await shot(null, {x: x - size / 2, y: y - size / 2, width: size, height: size}));
		const cell = size / 8;
		const cells = [];
		for (let row = 0; row < 8; row++) {
			for (let column = 0; column < 8; column++) {
				const mean = [0, 0, 0];
				for (let j = 0; j < cell; j += 2) for (let i = 0; i < cell; i += 2) image.rgba(column * cell + i, row * cell + j).slice(0, 3).forEach((value, c) => (mean[c] += value));
				cells.push(...mean.map((value) => value / ((cell / 2) * (cell / 2))));
			}
		}
		return cells;
	};
	const distance = (a, b) => a.reduce((sum, value, index) => sum + Math.abs(value - b[index]), 0) / a.length;
	// Text into the focused field: insertText, or a key event a character where the protocol lacks it (Chromium 69)
	const typeText = async (value) => {
		try {
			await devtools.send('Input.insertText', {text: value});
			return;
		} catch (error) {
			if (!/wasn't found|not found/i.test(error.message)) throw error;
		}
		for (const character of value) {
			await devtools.send('Input.dispatchKeyEvent', {type: 'keyDown', text: character, unmodifiedText: character, key: character});
			await devtools.send('Input.dispatchKeyEvent', {type: 'keyUp', key: character});
		}
	};
	// The text fields of Sandstone are buttons that open a keyboard popup; those of the open tab, in order
	const fieldAt = (index) => `(function () {
		var all = document.querySelectorAll('[role="button"][aria-label$="Input field"]');
		var shown = [];
		for (var i = 0; i < all.length; i++) {
			var r = all[i].getBoundingClientRect();
			if (r.width > 0 && r.height > 0 && r.left >= 0 && r.left < window.innerWidth) shown.push({x: r.left + r.width / 2, y: r.top + r.height / 2});
		}
		return shown[${index}] || null;
	})()`;
	const typeInto = async (index, value, what) => {
		const at = await waitFor(fieldAt(index), `the ${what} field`);
		await click(at);
		await waitFor(`document.activeElement && document.activeElement.tagName === 'INPUT'`, `the keyboard of the ${what} field`, 10000);
		await typeText(value);
		// The Done key of the Samsung keyboard (65376) takes the text and closes the popup
		await key(KEY.imeDone);
		await waitFor(`!document.activeElement || document.activeElement.tagName !== 'INPUT'`, `the ${what} popup to close on Done`, 10000);
	};
	const calls = () => evaluate('window.__tizenCalls');

	let signedIn = false;
	const step = async (name, run, {needsSignIn = true} = {}) => {
		const started = Date.now();
		if (needsSignIn && !signedIn) {
			results.push({step: name, ok: false, detail: 'not run: the sign in failed'});
			log(`FAIL ${name}: not run, the sign in failed`);
			return;
		}
		try {
			const detail = await run();
			results.push({step: name, ok: true, detail, ms: Date.now() - started});
			log(`ok   ${name}${detail ? `: ${JSON.stringify(detail)}` : ''}`);
		} catch (error) {
			let message = String(error.message ?? error);
			for (const secret of secrets) if (secret) message = message.split(secret).join('<hidden>');
			results.push({step: name, ok: false, detail: message, ms: Date.now() - started});
			log(`FAIL ${name}: ${message}`);
			await shot(`fail-${name.replace(/\W+/g, '-')}`).catch(() => {});
			// A viewer left open would fail the next steps too: Back closes it (never Back on the first screen)
			for (let i = 0; i < 4; i++) {
				const open = await evaluate(OVERLAY_OPEN).catch(() => false);
				if (!open) break;
				await key(KEY.back).catch(() => {});
				await sleep(600);
			}
		}
	};

	// The text of Sandstone's floating layer: the tooltip of the focused or hovered button
	const floatingText = `(function () { var l = document.getElementById('floatLayer'); return l ? l.textContent.trim() : ''; })()`;
	// The text a field of the open tab shows, or null
	const fieldText = (index) => `(function () {
		var all = document.querySelectorAll('[role="button"][aria-label$="Input field"]');
		var shown = [];
		for (var i = 0; i < all.length; i++) {
			var r = all[i].getBoundingClientRect();
			if (r.width > 0 && r.height > 0 && r.left >= 0 && r.left < window.innerWidth) shown.push(all[i].textContent.trim());
		}
		return shown.length > ${index} ? shown[${index}] : null;
	})()`;
	// Back with the keyboard popup of a field open: on a Samsung TV it closes the popup and leaves the form, with what
	// was typed; the field is then cleared with its clear button for the sign in
	const backInPopup = async () => {
		await click(await waitFor(fieldAt(0), 'the server field'));
		await waitFor(`document.activeElement && document.activeElement.tagName === 'INPUT'`, 'the keyboard of the server field', 10000);
		await typeText('x');
		await key(KEY.back);
		await waitFor(`!document.activeElement || document.activeElement.tagName !== 'INPUT'`, 'Back to close the keyboard popup', 10000);
		await sleep(400);
		const form = await evaluate(`[${hasText('API Key')}, ${fieldAt(0)} !== null]`);
		const result = {formKept: form[0] && form[1], typedKept: (await evaluate(fieldText(0))) === 'x', exits: (await calls()).exits};
		if (result.formKept && (await evaluate(fieldText(0)))) {
			await click(await waitFor(centreOf('[aria-label="Clear value"]'), 'the clear button of the server field'));
			await waitFor(`${fieldText(0)} !== 'x'`, 'the server field to be cleared', 5000);
		}
		return result;
	};
	let popupBack = null;

	await devtools.send('Page.navigate', {url: pathToFileURL(join(page, 'index.html')).href});

	await step(
		'sign in page: no Phone tab, typed sign in with the Samsung keyboard',
		async () => {
			await waitFor(hasText('Add account'), 'the welcome page', 60000);
			await shot('00-welcome');
			// OK on the focused "Add account" button
			await key(KEY.enter);
			await waitFor(hasText('API Key'), 'the sign in tabs');
			const tabs = await evaluate(`[${leafByText('Phone')} !== null, ${leafByText('Email')} !== null, ${leafByText('API Key')} !== null]`);
			if (tabs[0]) throw new Error('a Phone tab is offered');
			if (!tabs[1] || !tabs[2]) throw new Error(`the Email and API Key tabs are not both there (${tabs})`);
			// Reported as a step of its own below; the form is opened again when Back closed it
			try {
				popupBack = await backInPopup();
			} catch (error) {
				popupBack = {error: error.message};
			}
			if (!popupBack.formKept && popupBack.exits === 0 && !(await evaluate(hasText('API Key')))) {
				await click(await waitFor(leafByText('Add account'), 'the Add account button, to open the form again'));
				await waitFor(hasText('API Key'), 'the sign in tabs, again');
			}
			await typeInto(0, server, 'server');
			await typeInto(1, email, 'email');
			await typeInto(2, password, 'password');
			const shown = await evaluate(`[${hasText(server)}, ${hasText(email)}]`);
			if (!shown[0] || !shown[1]) throw new Error(`the typed values do not show (server ${shown[0]}, email ${shown[1]})`);
			await shot('01-sign-in');
			await click(await waitFor(leafByText('Connect'), 'the Connect button'));
			await waitFor(`document.querySelectorAll('[data-asset-id]').length > 0`, 'the timeline after Connect', 60000);
			signedIn = true;
			return {tabs: 'Email, API Key'};
		},
		{needsSignIn: false}
	);

	await step(
		'sign in page: Back with the keyboard popup open closes the popup, not the form, nor the app',
		async () => {
			if (!popupBack) throw new Error('not run: the sign in page did not open');
			if (popupBack.error) throw new Error(popupBack.error);
			if (popupBack.exits !== 0) throw new Error('Back in the popup closed the app');
			if (!popupBack.formKept) throw new Error('Back in the popup closed the sign in form too');
			return popupBack;
		},
		{needsSignIn: false}
	);

	await step('timeline: tiles shown, ChannelDown pages down', async () => {
		await waitFor(`(function () {
			var images = document.querySelectorAll('[data-asset-id] img');
			var loaded = 0;
			for (var i = 0; i < images.length; i++) if (images[i].complete && images[i].naturalWidth > 0) loaded++;
			return loaded >= Math.min(4, images.length) && images.length > 0;
		})()`, 'the first thumbnails', 60000);
		await sleep(800);
		await shot('02-timeline');
		const tiles = await evaluate(`document.querySelectorAll('[data-asset-id]').length`);
		// The focus goes into the grid (Right from the rail), then a channel key pages
		const inGrid = `(function () { var a = document.activeElement; return !!(a && a.closest && a.closest('[data-asset-id]')); })()`;
		if (!(await evaluate(inGrid))) await key(KEY.right);
		const topBefore = await evaluate(`document.querySelector('[data-asset-id]').getBoundingClientRect().top`);
		await key(KEY.channelDown);
		await sleep(700);
		const topAfter = await evaluate(`document.querySelector('[data-asset-id]') ? document.querySelector('[data-asset-id]').getBoundingClientRect().top : null`);
		const moved = topAfter === null ? 'first tile unmounted' : Math.round(topBefore - topAfter);
		if (moved !== 'first tile unmounted' && moved < 100) throw new Error(`ChannelDown did not page (${moved} px)`);
		await shot('02b-timeline-after-channel-down');
		await key(KEY.channelUp);
		await sleep(500);
		return {tiles, channelDownMovedPx: moved};
	});

	await step('360° photo: drawn on the sphere, turned with the arrows, zoomed with ChannelUp', async () => {
		const tile = await waitFor(`(function () {
			var tiles = document.querySelectorAll('[data-asset-id]');
			for (var i = 0; i < tiles.length; i++) if (tiles[i].textContent.indexOf('360°') >= 0) return tiles[i].getAttribute('data-asset-id');
			return null;
		})()`, 'a tile with the 360° badge');
		await click(await waitFor(centreOf(`[data-asset-id="${tile}"]`), 'the 360° tile'));
		await waitFor(`!!document.querySelector('canvas')`, 'the sphere canvas', 30000);
		await waitFor(`!(${hasText('Loading the 360° view')})`, 'the 360° picture to load', 60000);
		await sleep(2000);
		const failure = await evaluate(`${hasText('could not be shown')} || ${hasText('cannot draw the 360')}`);
		if (failure) throw new Error(`the app says: ${await evaluate(`document.body.innerText.slice(0, 300)`)}`);
		const centre = await pixel(960, 540);
		if (centre[0] + centre[1] + centre[2] < 30) throw new Error(`the centre of the sphere is black (${centre.slice(0, 3)})`);
		await shot('03-360-photo');
		const before = await region(960, 540, 256);
		await key(KEY.right, {repeat: 12, gapMs: 80});
		await sleep(600);
		const turned = await region(960, 540, 256);
		const turn = distance(before, turned);
		if (turn < 3) throw new Error(`Right did not turn the view (the centre changed by ${turn.toFixed(1)} of 255)`);
		await shot('03b-360-photo-turned');
		// The zoom is read on a wider square, where the lines of the picture move most
		const wide = await region(960, 540, 512);
		await key(KEY.channelUp, {repeat: 4, gapMs: 120});
		await sleep(600);
		const zoom = distance(wide, await region(960, 540, 512));
		if (zoom < 3) throw new Error(`ChannelUp did not zoom the view (the centre changed by ${zoom.toFixed(1)} of 255)`);
		await shot('03c-360-photo-zoomed');
		await key(KEY.back);
		await waitFor(`!document.querySelector('canvas')`, 'Back to close the viewer', 10000);
		return {asset: tile, centre: centre.slice(0, 3), turnChange: Number(turn.toFixed(1)), zoomChange: Number(zoom.toFixed(1))};
	});

	await step('video: plays and holds the screen saver, or says it cannot play', async () => {
		const h264 = await evaluate(`document.createElement('video').canPlayType('video/mp4; codecs="avc1.42E01E"')`);
		// A video tile shows its duration (0:12)
		const tile = await waitFor(`(function () {
			var tiles = document.querySelectorAll('[data-asset-id]');
			for (var i = 0; i < tiles.length; i++) if (/\\d+:\\d\\d/.test(tiles[i].textContent)) return tiles[i].getAttribute('data-asset-id');
			return null;
		})()`, 'a video tile');
		const callsBefore = (await calls()).screenSaver.length;
		await click(await waitFor(centreOf(`[data-asset-id="${tile}"]`), 'the video tile'));
		await waitFor(`!!document.querySelector('video[data-immuch360-video]')`, 'the video element of the viewer', 20000);
		let outcome;
		if (h264) {
			await waitFor(`(function () { var v = document.querySelector('video[data-immuch360-video]'); return v && v.currentTime > 0; })()`, 'the video to play', 30000);
			const held = (await calls()).screenSaver.slice(callsBefore);
			if (held[0] !== 0) throw new Error(`the screen saver was not turned off while the video played (${JSON.stringify(held)})`);
			outcome = 'played, screen saver off';
		} else {
			await waitFor(hasText('could not play this video'), 'the "could not play" message', 30000);
			outcome = 'no H.264 in this engine: the "could not play" message shows';
		}
		await sleep(500);
		await shot('04-video');
		// A video that cannot play closes its player and leaves its message in the viewer: Back closes the viewer
		for (let i = 0; i < 3 && (await evaluate(OVERLAY_OPEN)); i++) {
			await key(KEY.back);
			await sleep(600);
		}
		if (await evaluate(OVERLAY_OPEN)) throw new Error('Back did not close the video');
		const after = (await calls()).screenSaver.slice(callsBefore);
		if (h264 && after[after.length - 1] !== 1) throw new Error(`the screen saver did not come back after the video (${JSON.stringify(after)})`);
		return {asset: tile, h264: h264 || 'no', outcome, screenSaver: after};
	});

	await step('flat photo and slideshow: Up zooms in, Back out; the Play/Pause key of a Samsung remote (10252) pauses and resumes the slideshow, the screen saver held', async () => {
		// A flat photo: no 360° badge, no duration
		const tile = await waitFor(`(function () {
			var tiles = document.querySelectorAll('[data-asset-id]');
			for (var i = 0; i < tiles.length; i++) {
				var text = tiles[i].textContent;
				if (text.indexOf('360°') < 0 && !/\\d+:\\d\\d/.test(text)) return tiles[i].getAttribute('data-asset-id');
			}
			return null;
		})()`, 'a flat photo tile');
		const callsBefore = (await calls()).screenSaver.length;
		await click(await waitFor(centreOf(`[data-asset-id="${tile}"]`), 'the photo tile'));
		await waitFor(`!!document.querySelector('[data-spotlight-id="media-viewer"]')`, 'the viewer', 20000);
		await sleep(500);
		// Up zooms the photo in at once (discussion 8), Back zooms it out and leaves the viewer open
		const zoomOf = `(function () {
			var img = document.querySelector('[data-spotlight-id="media-viewer"] img');
			return img && img.parentNode ? img.parentNode.style.transform : null;
		})()`;
		await key(KEY.up);
		await waitFor(`(${zoomOf} || '').indexOf('scale(1.25)') === 0`, 'Up to zoom the photo in (scale 1.25)', 5000);
		await key(KEY.back);
		await waitFor(`${zoomOf} === ''`, 'Back to zoom the photo out', 5000);
		if (!(await evaluate(OVERLAY_OPEN))) throw new Error('Back closed the viewer instead of zooming the photo out');
		// OK shows the controls of a photo with Zoom in focused (a first OK only brings them back once they hid), Right moves
		// along the bar until the tooltip of the focused button says Slideshow, OK starts it: as with a remote
		const barShown = `(function () {
			var bar = document.querySelector('[data-spotlight-id="media-viewer-actions"]');
			return !!bar && getComputedStyle(bar).visibility === 'visible' && getComputedStyle(bar.parentNode.parentNode).opacity === '1';
		})()`;
		const inBar = `(function () {
			var bar = document.querySelector('[data-spotlight-id="media-viewer-actions"]');
			return !!bar && bar.contains(document.activeElement);
		})()`;
		await key(KEY.enter);
		await waitFor(barShown, 'the controls of the photo', 10000);
		if (!(await evaluate(inBar))) await key(KEY.enter);
		await waitFor(inBar, 'the focus in the bar of the controls', 5000);
		const seen = [];
		let found = false;
		for (let i = 0; i < 12 && !found; i++) {
			const label = await waitFor(floatingText, 'the tooltip of the focused button', 3000).catch(() => '');
			seen.push(label);
			if (label === 'Slideshow') found = true;
			else await key(i < 10 ? KEY.right : KEY.left);
		}
		if (!found) throw new Error(`no Slideshow button in the photo controls (tooltips: ${seen.join(', ')})`);
		await key(KEY.enter);
		await waitFor(`!!document.querySelector('[data-spotlight-id="slideshow"]')`, 'the slideshow', 10000);
		const held = (await calls()).screenSaver.slice(callsBefore);
		if (held[held.length - 1] !== 0) throw new Error(`the screen saver was not turned off for the slideshow (${JSON.stringify(held)})`);
		// The play and pause button shows the pause icon while the slideshow plays, the play icon while it is paused
		const icon = `(function () { var b = document.querySelector('[data-spotlight-id="slideshow-play"]'); return b ? b.textContent : null; })()`;
		const playing = await waitFor(icon, 'the play and pause button of the slideshow');
		await sleep(300);
		await key(KEY.playPause);
		await waitFor(`(function () { var t = ${icon}; return t !== null && t !== ${JSON.stringify(playing)}; })()`, 'the slideshow to pause on 10252', 5000);
		await shot('04b-slideshow-paused');
		await key(KEY.playPause);
		await waitFor(`${icon} === ${JSON.stringify(playing)}`, 'the slideshow to play again on 10252', 5000);
		// Back closes the slideshow (the screen saver comes back), then the photo it returns to
		for (let i = 0; i < 4 && (await evaluate(OVERLAY_OPEN)); i++) {
			await key(KEY.back);
			await sleep(700);
		}
		if (await evaluate(OVERLAY_OPEN)) throw new Error('Back did not close the slideshow and the photo');
		const after = (await calls()).screenSaver.slice(callsBefore);
		if (after[after.length - 1] !== 1) throw new Error(`the screen saver did not come back after the slideshow (${JSON.stringify(after)})`);
		return {asset: tile, screenSaver: after};
	});

	await step('rail: no Network shares; About page: Tizen lines, what Samsung TVs lack, no policy block, no DUID', async () => {
		if (await evaluate(leafByText('Network shares'))) throw new Error('the rail offers Network shares');
		await click(await waitFor(leafByText('About'), 'the About item of the rail'));
		await waitFor(hasText('Not yet on Samsung TVs'), 'the About page', 30000);
		await sleep(1500);
		// Each line of the page is a label and a value, two spans side by side
		const lines = await evaluate(`(function () {
			var out = {};
			var spans = document.querySelectorAll('span + span');
			for (var i = 0; i < spans.length; i++) {
				var label = spans[i].previousElementSibling;
				if (spans[i].parentNode.children.length === 2) out[label.textContent.trim()] = spans[i].textContent.trim();
			}
			return out;
		})()`);
		const want = {Immuch360: /^\d+\.\d+\.\d+ \(Immuch360T\.Immuch360\)$/, TV: /E2E-HEADLESS/, Tizen: /^6\.0$/, Panel: /^UHD, HDR no$/, AVPlay: /^no$/};
		for (const [label, pattern] of Object.entries(want)) {
			if (!pattern.test(lines[label] ?? '')) throw new Error(`About line ${label}: "${lines[label]}"`);
		}
		if (/policy:/.test(lines['Last errors'] ?? '')) throw new Error(`a policy block: ${lines['Last errors']}`);
		if (await evaluate(hasText('E2EDUIDNEVERSHOWN'))) throw new Error('the DUID shows');
		await shot('05-about');
		return {Tizen: lines.Tizen, Chromium: lines.Chromium, WebGL: lines.WebGL, 'Smart View': lines['Smart View'], 'JS memory': lines['JS memory'], 'Last errors': lines['Last errors']};
	});

	await step('policy: a locale file read from the package, no block during the run', async () => {
		const french = await evaluate(`new Promise(function (done) {
			var x = new XMLHttpRequest();
			x.open('GET', 'i18n/fr.json');
			x.onload = function () { try { done(Object.keys(JSON.parse(x.responseText)).length); } catch (e) { done('parse: ' + e.message); } };
			x.onerror = function () { done('error'); };
			x.send();
		})`);
		if (typeof french !== 'number' || french < 10) throw new Error(`i18n/fr.json: ${french}`);
		if (blocked.length) throw new Error(`blocked by the policy: ${blocked.join(' | ')}`);
		return {frenchKeys: french, policy};
	});

	await step('remote keys asked for, Back on the first screen closes the app', async () => {
		const {registered, exits} = await calls();
		for (const name of ['ChannelUp', 'ChannelDown', 'MediaPlayPause', 'ColorF2Yellow', 'ColorF3Blue', 'Info']) {
			if (registered.indexOf(name) < 0) throw new Error(`${name} was not asked for (${registered.join(', ')})`);
		}
		for (const name of ['VolumeUp', '0', 'Exit']) if (registered.indexOf(name) >= 0) throw new Error(`${name} was asked for`);
		if (exits !== 0) throw new Error('the app closed before Back');
		await key(KEY.back);
		await waitFor(`window.__tizenCalls.exits === 1`, 'Back to close the app', 5000);
		return {registered: registered.length};
	});

	const known = (text) => KNOWN_EXCEPTIONS.some(({pattern}) => pattern.test(text));
	const unexpected = exceptions.filter((text) => !known(text));
	results.push({
		step: 'no uncaught exception in the page',
		ok: unexpected.length === 0,
		detail: unexpected.length ? unexpected.slice(0, 5) : exceptions.length ? `${exceptions.length} known` : undefined,
	});
	log(`${unexpected.length ? 'FAIL' : 'ok  '} no uncaught exception in the page${unexpected.length ? `: ${JSON.stringify(unexpected.slice(0, 5))}` : ''}`);
	devtools.close();
	browser.child.kill('SIGKILL');
	if (fake) await fake.close();
	rmSync(page, {recursive: true, force: true});
	rmSync(profile, {recursive: true, force: true});
	return browser.version;
}

let engine = '?';
try {
	engine = await main();
} catch (error) {
	results.push({step: 'start', ok: false, detail: String(error.message ?? error)});
	log(`FAIL start: ${error.message ?? error}`);
}
const failed = results.filter((result) => !result.ok);
writeFileSync(join(OUT, 'results.json'), JSON.stringify({label: LABEL, engine, server: SERVER ? 'given' : 'fake', results}, null, 1) + '\n');
log(`${results.length - failed.length} of ${results.length} steps passed; screenshots and results.json in ${OUT}`);
process.exit(failed.length ? 1 : 0);
