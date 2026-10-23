#!/usr/bin/env node
// Immuch360 for Samsung TVs: checks the .wgt before it is offered.
//
//   node tizen/tools/check-wgt.mjs <file.wgt> [--version 0.1.0] [--list wgt-files.json] [--unsigned]
//
// A .wgt is a zip. The check reads it with Node alone and fails when config.xml is not at its root or does not say
// what tizen/config.xml says (the package and application ids, Tizen 5.5, the tv-samsung profile, exactly the three
// privileges, the access policy, a content security policy without eval), when the version differs from the one given,
// when the author and distributor signatures are missing (--unsigned for a folder zipped without the Tizen tools),
// when something only webOS reads went in (appinfo.json, its icons, the JS service), when index.html does not load
// Samsung's Product API before main.js, when the licences, the locale files or the clip of the video test of the About
// page are missing, or when the package grew past 20 MB. --list writes every file and its size, to compare builds.

import {createHash} from 'node:crypto';
import {readFileSync, writeFileSync} from 'node:fs';
import {basename, resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {inflateRawSync} from 'node:zlib';

export const PACKAGE_ID = 'Immuch360T';
export const APPLICATION_ID = `${PACKAGE_ID}.Immuch360`;
export const REQUIRED_VERSION = '5.5';
export const PRIVILEGES = [
	'http://developer.samsung.com/privilege/productinfo',
	'http://tizen.org/privilege/internet',
	'http://tizen.org/privilege/tv.inputdevice',
];
export const MAX_WGT_BYTES = 20 * 1024 * 1024;
const WEBAPIS_TAG = '<script src="$WEBAPIS/webapis/webapis.js"></script>';
const LICENCES = {
	'LICENSE.txt': ['GNU Affero General Public License', 'https://github.com/freeKC/Immuch360'],
	'LICENSE-AGPL-3.0.txt': ['GNU AFFERO GENERAL PUBLIC LICENSE'],
	'LICENSE-immich-tv-webos.txt': ['Quentin Jean-Amans'],
};
const WEBOS_ONLY = /^(appinfo\.json|icon-large\.png|icon-mini\.png|splash\.png|services\.json|service\/.*|.*\.ipk)$/;

/** The entries of a zip, by name: {method, size, compressedSize, offset} (central directory, no ZIP64) */
export function zipEntries(zip) {
	let end = -1;
	for (let at = zip.length - 22; at >= Math.max(0, zip.length - 65557); at--) {
		if (zip.readUInt32LE(at) === 0x06054b50) {
			end = at;
			break;
		}
	}
	if (end < 0) throw new Error('not a zip file (no end of central directory)');
	const count = zip.readUInt16LE(end + 10);
	let at = zip.readUInt32LE(end + 16);
	const entries = {};
	for (let index = 0; index < count; index++) {
		if (zip.readUInt32LE(at) !== 0x02014b50) throw new Error('broken central directory');
		const nameLength = zip.readUInt16LE(at + 28);
		const name = zip.toString('utf8', at + 46, at + 46 + nameLength);
		entries[name] = {
			method: zip.readUInt16LE(at + 10),
			compressedSize: zip.readUInt32LE(at + 20),
			size: zip.readUInt32LE(at + 24),
			offset: zip.readUInt32LE(at + 42),
		};
		at += 46 + nameLength + zip.readUInt16LE(at + 30) + zip.readUInt16LE(at + 32);
	}
	return entries;
}

/** The bytes of one entry */
export function zipRead(zip, entry) {
	if (zip.readUInt32LE(entry.offset) !== 0x04034b50) throw new Error('broken local header');
	const start = entry.offset + 30 + zip.readUInt16LE(entry.offset + 26) + zip.readUInt16LE(entry.offset + 28);
	const data = zip.subarray(start, start + entry.compressedSize);
	if (entry.method === 0) return data;
	if (entry.method === 8) return inflateRawSync(data);
	throw new Error(`compression method ${entry.method}`);
}

const attribute = (tag, name) => {
	const found = new RegExp(`\\s${name}="([^"]*)"`).exec(tag ?? '');
	return found ? found[1] : null;
};

/** What is wrong with config.xml; [] when nothing */
export function configProblems(xml, version) {
	const problems = [];
	const widget = /<widget\b[^>]*>/.exec(xml)?.[0];
	const application = /<tizen:application\b[^>]*>/.exec(xml)?.[0];
	if (!widget) return ['config.xml has no widget element'];
	if (version && attribute(widget, 'version') !== version) problems.push(`config.xml version ${attribute(widget, 'version')}, not ${version}`);
	if (attribute(application, 'id') !== APPLICATION_ID) problems.push(`application id ${attribute(application, 'id')}, not ${APPLICATION_ID}`);
	if (attribute(application, 'package') !== PACKAGE_ID) problems.push(`package ${attribute(application, 'package')}, not ${PACKAGE_ID}`);
	if (attribute(application, 'required_version') !== REQUIRED_VERSION) problems.push(`required_version ${attribute(application, 'required_version')}, not ${REQUIRED_VERSION}`);
	if (!/<tizen:profile\s+name="tv-samsung"\s*\/>/.test(xml)) problems.push('the profile is not tv-samsung');
	if (!/<content\s+src="index\.html"\s*\/>/.test(xml)) problems.push('the content is not index.html');
	if (!/<icon\s+src="icon\.png"\s*\/>/.test(xml)) problems.push('the icon is not icon.png');
	if (!/<access\s+origin="\*"\s+subdomains="true"\s*\/>/.test(xml)) problems.push('the access policy does not let the app reach the Immich server typed by the user');
	const privileges = [...xml.matchAll(/<tizen:privilege\s+name="([^"]+)"\s*\/>/g)].map((match) => match[1]).sort();
	if (JSON.stringify(privileges) !== JSON.stringify(PRIVILEGES)) problems.push(`privileges ${privileges.join(', ') || 'none'}, not exactly ${PRIVILEGES.join(', ')}`);
	const policy = /<tizen:content-security-policy>([^<]*)<\/tizen:content-security-policy>/.exec(xml)?.[1];
	if (!policy) problems.push('no content security policy');
	else {
		const script = /(?:^|;)\s*script-src([^;]*)/.exec(policy)?.[1] ?? '';
		if (!/'self'/.test(script)) problems.push("the policy has no script-src 'self'");
		if (/unsafe-(eval|inline)/.test(script)) problems.push('the policy lets scripts run from text (unsafe-eval or unsafe-inline)');
		if (!/object-src\s+'none'/.test(policy)) problems.push("the policy has no object-src 'none'");
	}
	return problems;
}

/** Checks a .wgt; returns the problems found and its file list */
export function checkWgt(wgt, {version = null, unsigned = false} = {}) {
	const problems = [];
	const entries = zipEntries(wgt);
	const names = Object.keys(entries).filter((name) => !name.endsWith('/'));
	const text = (name) => (entries[name] ? zipRead(wgt, entries[name]).toString('utf8') : null);

	const config = text('config.xml');
	if (config === null) problems.push('no config.xml at the root');
	else problems.push(...configProblems(config, version));
	if (!unsigned) {
		for (const name of ['author-signature.xml', 'signature1.xml']) if (!entries[name]) problems.push(`not signed: no ${name}`);
	}
	for (const name of names) if (WEBOS_ONLY.test(name)) problems.push(`webOS only file in the package: ${name}`);
	for (const name of ['index.html', 'main.js', 'main.css', 'icon.png']) if (!entries[name]) problems.push(`missing ${name}`);
	const html = text('index.html');
	if (html !== null) {
		const tag = html.indexOf(WEBAPIS_TAG);
		const main = html.search(/<script\b[^>]*\bsrc="(?:\.\/)?main\.js"/);
		if (tag < 0 || main < 0 || tag > main) problems.push("index.html does not load Samsung's webapis.js before main.js");
		if (html.split(WEBAPIS_TAG).length > 2) problems.push('index.html loads webapis.js twice');
	}
	for (const [name, phrases] of Object.entries(LICENCES)) {
		const content = text(name);
		if (content === null) problems.push(`missing ${name}`);
		else for (const phrase of phrases) if (!content.includes(phrase)) problems.push(`${name} does not say "${phrase}"`);
	}
	const locales = names.filter((name) => /^i18n\/[\w-]+\.json$/.test(name));
	if (locales.length < 80) problems.push(`${locales.length} locale files in i18n/, 80 at least`);
	if (!names.some((name) => /(^|\/)probe[^/]*\.mp4$/.test(name))) problems.push('missing the clip of the video test of the About page (probe.mp4)');
	if (wgt.length > MAX_WGT_BYTES) problems.push(`${wgt.length} bytes, more than ${MAX_WGT_BYTES}`);

	const files = names.sort().map((path) => ({path, size: entries[path].size}));
	const found = config ? attribute(/<widget\b[^>]*>/.exec(config)?.[0], 'version') : null;
	return {problems, files, version: found};
}

function main(args) {
	const file = args.find((arg, index) => !arg.startsWith('--') && (index === 0 || !['--version', '--list'].includes(args[index - 1])));
	const option = (name) => (args.indexOf(name) >= 0 ? args[args.indexOf(name) + 1] : null);
	if (!file) {
		console.error('[check-wgt] usage: check-wgt.mjs <file.wgt> [--version x.y.z] [--list out.json] [--unsigned]');
		process.exit(2);
	}
	const wgt = readFileSync(file);
	let result;
	try {
		result = checkWgt(wgt, {version: option('--version'), unsigned: args.indexOf('--unsigned') >= 0});
	} catch (error) {
		console.error(`[check-wgt] FAILED: ${basename(file)}: ${error.message}`);
		process.exit(1);
	}
	const sha256 = createHash('sha256').update(wgt).digest('hex');
	const total = result.files.reduce((sum, entry) => sum + entry.size, 0);
	console.log(`[check-wgt] ${basename(file)}: ${wgt.length} bytes, sha256 ${sha256}`);
	console.log(`[check-wgt] ${result.files.length} files, ${total} bytes unpacked, version ${result.version}`);
	for (const entry of result.files.slice().sort((a, b) => b.size - a.size).slice(0, 8)) console.log(`  ${String(entry.size).padStart(9)}  ${entry.path}`);
	const list = option('--list');
	if (list) writeFileSync(list, JSON.stringify({wgt: basename(file), bytes: wgt.length, sha256, files: result.files}, null, 1) + '\n');
	if (result.problems.length) {
		console.error(`[check-wgt] FAILED: ${result.problems.join('; ')}`);
		process.exit(1);
	}
	console.log('[check-wgt] OK');
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) main(process.argv.slice(2));
