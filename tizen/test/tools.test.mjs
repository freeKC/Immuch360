// The tools of the Samsung shell: tizen/tools/build-wgt.mjs (the package folder made from webos/dist) and
// tizen/tools/check-wgt.mjs (the .wgt checked before it is offered), on a stand in of webos/dist.
//
//   node --test tizen/test/*.test.mjs

import {after, describe, test} from 'node:test';
import assert from 'node:assert/strict';
import {existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join, relative} from 'node:path';
import {fileURLToPath} from 'node:url';
import {crc32, deflateRawSync} from 'node:zlib';
import {WEBAPIS_TAG, buildWgt, checkVersion, configXml, templateVersion, withWebapis, withoutRemoteFonts} from '../tools/build-wgt.mjs';
import {APPLICATION_ID, PRIVILEGES, checkWgt, configProblems, zipEntries, zipRead} from '../tools/check-wgt.mjs';

const TIZEN = join(dirname(fileURLToPath(import.meta.url)), '..');
const TEMPLATE = readFileSync(join(TIZEN, 'config.xml'), 'utf8');
const scratch = mkdtempSync(join(tmpdir(), 'immuch360-tizen-tools-'));
after(() => rmSync(scratch, {recursive: true, force: true}));

const INDEX_HTML =
	'<!doctype html><html><head><title>Immuch360</title><link href="./main.css" rel="stylesheet"/></head>' +
	'<body><div id="root"></div><script defer="defer" src="./main.js"></script></body></html>';

// Two of Sandstone's font faces, as the bundle has them
const SANDSTONE_FONTS =
	'@font-face{font-family:Sandstone Miso;font-weight:400;src:local("LG Smart UI AR HE TH Regular"),local("LGSmartUIARHETH-Regular"),url(https://fonts.gstatic.com/s/notosansthai/v13/x.woff2) format("woff2")}' +
	'@font-face{font-family:Sandstone Museo;src:url(node_modules/@enact/sandstone/fonts/MuseoSans/MuseoSans-Medium.ttf) format("truetype")}body{background:url(data:image/png;base64,AAAA)}';

/** A stand in of webos/dist after npm run pack-p */
function fakeDist(name, {probe = true, locales = 88} = {}) {
	const dist = join(scratch, name);
	const put = (path, content) => {
		mkdirSync(dirname(join(dist, path)), {recursive: true});
		writeFileSync(join(dist, path), content);
	};
	put('index.html', INDEX_HTML);
	put('main.js', 'console.log("app");');
	put('main.css', SANDSTONE_FONTS);
	put('appinfo.json', '{"id":"com.aprogsys.immuch360"}');
	for (const icon of ['icon.png', 'icon-large.png', 'icon-mini.png', 'splash.png']) put(icon, `webOS ${icon}`);
	put('LICENSE.txt', 'GNU Affero General Public License, https://github.com/freeKC/Immuch360, immich-tv-webos');
	put('LICENSE-AGPL-3.0.txt', 'GNU AFFERO GENERAL PUBLIC LICENSE');
	put('LICENSE-immich-tv-webos.txt', 'Copyright (c) 2026 Quentin Jean-Amans');
	for (let i = 0; i < locales; i++) put(`i18n/l${i}.json`, '{}');
	if (probe) put('src/immuch360/diagnostics/probe.mp4', 'clip');
	put('src/assets/immuch360-icon.png', 'the ring of the welcome page');
	put('node_modules/@enact/sandstone/fonts/Miso/Miso-Regular.ttf', 'font');
	return dist;
}

function filesOf(dir) {
	const found = [];
	for (const name of readdirSync(dir)) {
		const path = join(dir, name);
		if (statSync(path).isDirectory()) found.push(...filesOf(path));
		else found.push(path);
	}
	return found;
}

/** A zip of a folder plus extra entries, as the Tizen tools write one (deflate) */
function zipOf(dir, extra = {}, drop = []) {
	const entries = filesOf(dir)
		.map((path) => [relative(dir, path).split('\\').join('/'), readFileSync(path)])
		.filter(([name]) => drop.indexOf(name) < 0)
		.concat(Object.entries(extra).map(([name, content]) => [name, Buffer.from(content)]));
	const locals = [];
	const centrals = [];
	let offset = 0;
	for (const [name, content] of entries) {
		const nameBytes = Buffer.from(name);
		const data = deflateRawSync(content);
		const local = Buffer.alloc(30);
		local.writeUInt32LE(0x04034b50, 0);
		local.writeUInt16LE(20, 4);
		local.writeUInt16LE(8, 8);
		local.writeUInt32LE(crc32(content), 14);
		local.writeUInt32LE(data.length, 18);
		local.writeUInt32LE(content.length, 22);
		local.writeUInt16LE(nameBytes.length, 26);
		const central = Buffer.alloc(46);
		central.writeUInt32LE(0x02014b50, 0);
		central.writeUInt16LE(20, 4);
		central.writeUInt16LE(20, 6);
		central.writeUInt16LE(8, 10);
		central.writeUInt32LE(crc32(content), 16);
		central.writeUInt32LE(data.length, 20);
		central.writeUInt32LE(content.length, 24);
		central.writeUInt16LE(nameBytes.length, 28);
		central.writeUInt32LE(offset, 42);
		locals.push(local, nameBytes, data);
		centrals.push(central, nameBytes);
		offset += 30 + nameBytes.length + data.length;
	}
	const directory = Buffer.concat(centrals);
	const end = Buffer.alloc(22);
	end.writeUInt32LE(0x06054b50, 0);
	end.writeUInt16LE(entries.length, 8);
	end.writeUInt16LE(entries.length, 10);
	end.writeUInt32LE(directory.length, 12);
	end.writeUInt32LE(offset, 16);
	return Buffer.concat([...locals, directory, end]);
}

const SIGNATURES = {'author-signature.xml': '<Signature/>', 'signature1.xml': '<Signature/>'};

describe('build-wgt', () => {
	test('versions: three numbers within 255.255.65535', () => {
		for (const good of ['0.1.0', '1.0.0', '255.255.65535', '0.0.0']) assert.equal(checkVersion(good), good);
		for (const bad of ['256.0.0', '0.256.0', '0.0.65536', '1.2', '1.2.3.4', 'v0.1.0', '', null, undefined]) {
			assert.throws(() => checkVersion(bad), /three numbers|at most/, String(bad));
		}
	});

	test('config.xml: the version of the build in the widget element only, the default read from the template', () => {
		assert.equal(templateVersion(TEMPLATE), checkVersion(templateVersion(TEMPLATE)));
		const xml = configXml(TEMPLATE, '1.2.3');
		assert.match(xml, /^<\?xml version="1\.0" encoding="UTF-8"\?>/);
		assert.equal(templateVersion(xml), '1.2.3');
		assert.throws(() => configXml(TEMPLATE, '1.2.300000'), /at most/);
		assert.throws(() => configXml('<widget id="x"/>', '1.0.0'), /no widget version/);
	});

	test('the Product API loaded once, before main.js', () => {
		const html = withWebapis(INDEX_HTML);
		assert.equal(html.split(WEBAPIS_TAG).length, 2);
		assert.ok(html.indexOf(WEBAPIS_TAG) < html.indexOf('src="./main.js"'));
		assert.equal(withWebapis(html), html);
		assert.throws(() => withWebapis('<html><body></body></html>'), /no main\.js/);
		assert.throws(() => withWebapis(INDEX_HTML.replace('</body>', `${WEBAPIS_TAG}</body>`)), /after main\.js/);
	});

	test('no font from Google: the remote sources of the font faces left out, local and packaged fonts kept', () => {
		const {css, removed} = withoutRemoteFonts(SANDSTONE_FONTS);
		assert.equal(removed, 1);
		assert.equal(css.indexOf('gstatic'), -1);
		assert.ok(css.includes('src:local("LG Smart UI AR HE TH Regular"),local("LGSmartUIARHETH-Regular")}'));
		assert.ok(css.includes('url(node_modules/@enact/sandstone/fonts/MuseoSans/MuseoSans-Medium.ttf) format("truetype")'));
		assert.ok(css.includes('url(data:image/png;base64,AAAA)'));
		// A face whose only source was remote keeps no source at all
		assert.equal(withoutRemoteFonts('@font-face{font-family:X;src:url("https://example.com/x.woff2") format("woff2")}').css, '@font-face{font-family:X;src:}');
	});

	test('the folder: webOS files out, config.xml, the Samsung icon, the locales, licences and clip kept', () => {
		const out = join(scratch, 'wgt-good');
		const {files} = buildWgt({dist: fakeDist('dist-good'), version: '0.2.1', out});
		for (const gone of ['appinfo.json', 'icon-large.png', 'icon-mini.png', 'splash.png']) assert.equal(existsSync(join(out, gone)), false, gone);
		assert.deepEqual(readFileSync(join(out, 'icon.png')), readFileSync(join(TIZEN, 'icon.png')));
		assert.equal(templateVersion(readFileSync(join(out, 'config.xml'), 'utf8')), '0.2.1');
		assert.ok(readFileSync(join(out, 'index.html'), 'utf8').includes(WEBAPIS_TAG));
		assert.equal(readFileSync(join(out, 'main.css'), 'utf8').indexOf('gstatic'), -1);
		for (const kept of ['i18n/l0.json', 'src/immuch360/diagnostics/probe.mp4', 'src/assets/immuch360-icon.png', 'LICENSE-immich-tv-webos.txt', 'node_modules/@enact/sandstone/fonts/Miso/Miso-Regular.ttf']) {
			assert.ok(existsSync(join(out, kept)), kept);
		}
		assert.equal(files, filesOf(out).length);
	});

	test('a bundle without its clip or its locales, or a bad version, makes no folder', () => {
		assert.throws(() => buildWgt({dist: fakeDist('dist-noclip', {probe: false}), version: '0.1.0', out: join(scratch, 'wgt-noclip')}), /probe\.mp4/);
		assert.throws(() => buildWgt({dist: fakeDist('dist-nolocales', {locales: 3}), version: '0.1.0', out: join(scratch, 'wgt-nolocales')}), /3 locale files/);
		assert.throws(() => buildWgt({dist: fakeDist('dist-version'), version: '0.1', out: join(scratch, 'wgt-version')}), /three numbers/);
		assert.throws(() => buildWgt({dist: join(scratch, 'nowhere'), version: '0.1.0', out: join(scratch, 'wgt-nowhere')}), /npm run pack-p/);
	});

	test('the icon is 512 x 423, as Samsung asks', () => {
		const png = readFileSync(join(TIZEN, 'icon.png'));
		assert.equal(png.toString('latin1', 1, 4), 'PNG');
		assert.deepEqual([png.readUInt32BE(16), png.readUInt32BE(20)], [512, 423]);
	});
});

describe('check-wgt', () => {
	const out = join(scratch, 'wgt-check');
	buildWgt({dist: fakeDist('dist-check'), version: '0.3.0', out});

	test('a signed package of the folder passes', () => {
		const result = checkWgt(zipOf(out, SIGNATURES), {version: '0.3.0'});
		assert.deepEqual(result.problems, []);
		assert.equal(result.version, '0.3.0');
		assert.ok(result.files.some((file) => file.path === 'config.xml'));
	});

	test('the zip reader gives back what went in', () => {
		const zip = zipOf(out, SIGNATURES);
		const entries = zipEntries(zip);
		assert.equal(zipRead(zip, entries['config.xml']).toString('utf8'), readFileSync(join(out, 'config.xml'), 'utf8'));
		assert.throws(() => zipEntries(Buffer.from('not a zip at all, not even close to one')), /not a zip/);
	});

	test('names what is wrong', () => {
		const cases = [
			[zipOf(out), {}, /not signed: no author-signature\.xml.*not signed: no signature1\.xml/],
			[zipOf(out, SIGNATURES), {version: '0.4.0'}, /config\.xml version 0\.3\.0, not 0\.4\.0/],
			[zipOf(out, {...SIGNATURES, 'appinfo.json': '{}'}), {}, /webOS only file in the package: appinfo\.json/],
			[zipOf(out, {...SIGNATURES, 'service/service.js': ''}), {}, /webOS only file in the package: service\/service\.js/],
			[zipOf(out, SIGNATURES, ['config.xml']), {}, /no config\.xml at the root/],
			[zipOf(out, SIGNATURES, ['LICENSE-immich-tv-webos.txt']), {}, /missing LICENSE-immich-tv-webos\.txt/],
			[zipOf(out, SIGNATURES, ['src/immuch360/diagnostics/probe.mp4']), {}, /probe\.mp4/],
			[zipOf(out, {...SIGNATURES, 'index.html': INDEX_HTML}, ['index.html']), {}, /webapis\.js before main\.js/],
			[zipOf(out, {...SIGNATURES, 'main.css': SANDSTONE_FONTS}, ['main.css']), {}, /main\.css loads something from another server/],
		];
		for (const [zip, options, expected] of cases) {
			assert.match(checkWgt(zip, options).problems.join('; '), expected);
		}
		assert.deepEqual(checkWgt(zipOf(out), {unsigned: true}).problems, []);
	});

	test('config.xml: ids, Tizen 5.5, profile, exactly three privileges, access and policy', () => {
		assert.deepEqual(configProblems(TEMPLATE, templateVersion(TEMPLATE)), []);
		assert.ok(TEMPLATE.includes(`id="${APPLICATION_ID}"`));
		const broken = [
			[TEMPLATE.replace('</widget>', '<tizen:privilege name="http://developer.samsung.com/privilege/network.public"/></widget>'), /privileges .*network\.public/],
			[TEMPLATE.replace('required_version="5.5"', 'required_version="2.3"'), /required_version 2\.3/],
			[TEMPLATE.replace('tv-samsung', 'tv'), /profile is not tv-samsung/],
			[TEMPLATE.replace('Immuch360T.Immuch360', 'Other1234.App'), /application id Other1234\.App/],
			[TEMPLATE.replace('<access origin="*" subdomains="true"/>', ''), /access policy/],
			[TEMPLATE.replace("script-src 'self'", "script-src 'self' 'unsafe-eval'"), /unsafe-eval or unsafe-inline/],
			[TEMPLATE.replace(/<tizen:content-security-policy>.*<\/tizen:content-security-policy>/, ''), /no content security policy/],
		];
		for (const [xml, expected] of broken) assert.match(configProblems(xml, null).join('; '), expected);
		assert.equal(PRIVILEGES.length, 3);
	});
});
