// The files LG's store reads in the package (webos-meta/), against tools/store-rules.mjs: the self assessment of
// 23 October 2026, fixes F1 (icons), F5 (screen saver) and F6 (requiredACG).

import {test, describe} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {deflateSync} from 'node:zlib';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {ICONS, TILE_COLOR, iconProblems, pngInfo} from '../../tools/store-rules.mjs';

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
