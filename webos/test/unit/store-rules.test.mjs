// The files LG's store reads in the package (webos-meta/), against tools/store-rules.mjs: the self assessment of
// 23 October 2026, fixes F1 (icons), F5 (screen saver) and F6 (requiredACG).

import {test, describe} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, readdirSync, statSync} from 'node:fs';
import {deflateSync} from 'node:zlib';
import {Buffer} from 'node:buffer';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {
	FORBIDDEN_SERVICES,
	ICONS,
	LUNA_CALLS,
	OWN_SERVICE,
	REQUIRED_ACG,
	TILE_COLOR,
	acgProblems,
	iconProblems,
	lunaServices,
	pngInfo,
	screenSaverProblems,
	unknownLunaServices,
} from '../../tools/store-rules.mjs';

const WEBOS = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const appinfo = JSON.parse(readFileSync(join(WEBOS, 'webos-meta', 'appinfo.json'), 'utf8'));
const icons = Object.fromEntries(Object.keys(ICONS).map((name) => [name, readFileSync(join(WEBOS, 'webos-meta', name))]));

// A PNG of one row of size pixels, of the given colour type (2 RGB, 6 RGBA), with or without a tRNS chunk
function png(size, colorType, withTrns = false) {
	const chunk = (type, data) => {
		const head = Buffer.alloc(8);
		head.writeUInt32BE(data.length, 0);
		head.write(type, 4, 'latin1');
		return Buffer.concat([head, data, Buffer.alloc(4)]);
	};
	const ihdr = Buffer.alloc(13);
	ihdr.writeUInt32BE(size, 0);
	ihdr.writeUInt32BE(size, 4);
	ihdr[8] = 8;
	ihdr[9] = colorType;
	const channels = colorType === 6 ? 4 : 3;
	const rows = Buffer.alloc(size * (1 + size * channels));
	return Buffer.concat([
		Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
		chunk('IHDR', ihdr),
		...(withTrns ? [chunk('tRNS', Buffer.alloc(6))] : []),
		chunk('IDAT', deflateSync(rows)),
		chunk('IEND', Buffer.alloc(0)),
	]);
}

describe('the icons (F1)', () => {
	test('pngInfo reads the size and tells an alpha channel or a tRNS chunk', () => {
		assert.deepEqual(pngInfo(png(80, 2)), {width: 80, height: 80, colorType: 2, transparent: false});
		assert.equal(pngInfo(png(80, 6)).transparent, true);
		assert.equal(pngInfo(png(80, 2, true)).transparent, true);
		assert.throws(() => pngInfo(Buffer.from('GIF89a, not a PNG at all, long enough')), /not a PNG/);
	});

	test('the icons of webos-meta are opaque squares of 80, 130 and 60 pixels on the tile colour', () => {
		assert.deepEqual(iconProblems(appinfo, icons), []);
		assert.equal(appinfo.iconColor, TILE_COLOR);
		assert.equal(appinfo.bgColor, TILE_COLOR);
	});

	test('a transparent icon, a wrong size, a missing tile colour are refused', () => {
		const problems = iconProblems({...appinfo, iconColor: undefined}, {...icons, 'icon.png': png(80, 6), 'icon-large.png': png(128, 2)});
		assert.ok(problems.some((p) => /iconColor/.test(p)));
		assert.ok(problems.some((p) => /icon\.png can hold transparency/.test(p)));
		assert.ok(problems.some((p) => /icon-large\.png is 128x128/.test(p)));
	});
});

// Every source file of the app and of its service, tests aside
function sources(dir) {
	return readdirSync(dir).flatMap((name) => {
		const path = join(dir, name);
		if (statSync(path).isDirectory()) return name === 'node_modules' || name === 'generated' ? [] : sources(path);
		return /\.(ts|tsx|js|cjs|mjs)$/.test(name) && !/\.test\./.test(name) && name !== 'test.js' ? [path] : [];
	});
}

describe('the screen saver (F5)', () => {
	test('appinfo.json asks for the Type 3 screen saver of gallery apps, both keys at the top', () => {
		assert.deepEqual(screenSaverProblems(appinfo), []);
		assert.deepEqual(appinfo.screenSaverProperties, {preferredType: 3});
		assert.equal(appinfo.useGalleryMode, true);
		assert.ok(screenSaverProblems({...appinfo, useGalleryMode: undefined}).length > 0);
		assert.ok(screenSaverProblems({...appinfo, screenSaverProperties: {preferredType: 2}}).length > 0);
	});

	test('no code calls the undocumented tvpower service any more', () => {
		const files = [...sources(join(WEBOS, 'src')), ...sources(join(WEBOS, 'service')), ...sources(join(WEBOS, 'bridge', 'src'))];
		assert.ok(files.length > 50);
		for (const file of files) {
			const text = readFileSync(file, 'utf8');
			for (const service of FORBIDDEN_SERVICES) assert.ok(!text.includes(service), `${file} names ${service}`);
		}
	});
});

describe('requiredACG (F6)', () => {
	test('appinfo.json lists the ACG groups of the Luna methods the app and its service call, exactly', () => {
		assert.deepEqual(REQUIRED_ACG, ['activity.operation', 'application.launcher', 'settings.query', 'systemconfig.query']);
		assert.deepEqual(acgProblems(appinfo), []);
		assert.deepEqual(appinfo.requiredACG.slice().sort(), REQUIRED_ACG);
		assert.ok(acgProblems({...appinfo, requiredACG: undefined}).length > 0);
		assert.ok(acgProblems({...appinfo, requiredACG: ['systemconfig.query']}).length > 0);
		assert.ok(acgProblems({...appinfo, requiredACG: [...REQUIRED_ACG, 'database.operation']}).length > 0);
	});

	test('the page calls only its own service, the system property service and the application manager; the service, the activity manager', () => {
		const page = sources(join(WEBOS, 'src'))
			.map((file) => readFileSync(file, 'utf8'))
			.join('\n');
		assert.deepEqual(lunaServices(page), [OWN_SERVICE, 'com.webos.applicationManager', 'com.webos.service.tv.systemproperty']);
		assert.ok(LUNA_CALLS.some((call) => call.service === 'com.webos.applicationManager' && call.method === 'launch' && call.group === 'application.launcher'));
		assert.deepEqual(unknownLunaServices(page), []);
		const service = readFileSync(join(WEBOS, 'service', 'service.js'), 'utf8');
		assert.match(service, /activityManager\.create/);
		assert.ok(LUNA_CALLS.some((call) => call.service === 'com.palm.activitymanager' && call.group === 'activity.operation'));
	});

	test('a Luna service that requiredACG does not cover is found in a bundle', () => {
		assert.deepEqual(unknownLunaServices('a("luna://com.webos.service.tts");b("luna://com.palm.db/put")'), ['com.palm.db']);
	});
});
