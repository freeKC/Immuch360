#!/usr/bin/env node
// Immuch360: checks the .ipk ares-package made, before it is installed or released.
//
//   node tools/check-package.mjs build [--list build/ipk-files.json]
//
// An .ipk is an ar archive (debian-binary, control.tar.gz, data.tar.gz). The check reads it with node alone and
// fails when the app or its service is not where webOS looks for them, when appinfo.json does not name Immuch360,
// when the version of the .ipk name, of appinfo.json and of the service differ, when development files of the service
// went in, when the clip of the video test of the diagnostics page is missing, when the licences are missing (the AGPL
// of Immuch360 and the MIT notice of immich-tv-webos, which must be in every copy, see tools/licence-files.mjs), when
// the media bridge of the service or the notices of the third party code in it are missing (tools/build-bridge.mjs),
// when the icons are not the opaque squares LG's store asks for, when the Type 3 screen saver of gallery apps is not
// declared, when requiredACG does not list exactly the groups of the Luna calls or a Luna service outside it is
// called (tools/store-rules.mjs), or when the package grew past 10 MB. --list writes every file and its size, to compare two builds.

import {readFileSync, readdirSync, writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {gunzipSync} from 'node:zlib';
import {createHash} from 'node:crypto';
import {FORBIDDEN_SERVICES, ICONS, acgProblems, iconProblems, screenSaverProblems, unknownLunaServices} from './store-rules.mjs';

const APP_ID = 'com.aprogsys.immuch360';
const SERVICE_ID = `${APP_ID}.service`;
const MAX_IPK_BYTES = 10 * 1024 * 1024;

const dir = process.argv[2] ?? 'build';
const listIndex = process.argv.indexOf('--list');
const problems = [];

function fail(message) {
	console.error(`[check-package] FAILED: ${message}`);
	process.exit(1);
}

const ipks = readdirSync(dir).filter((name) => name.endsWith('.ipk'));
if (ipks.length !== 1) fail(`one .ipk expected in ${dir}, found ${ipks.length}`);
const ipkName = ipks[0];
const ipk = readFileSync(join(dir, ipkName));

// ar: "!<arch>\n", then 60 byte headers (name 16, size at 48, 10 digits) and their data, padded to even offsets
function arMembers(buffer) {
	if (buffer.toString('latin1', 0, 8) !== '!<arch>\n') fail(`${ipkName} is not an ar archive`);
	const found = {};
	let offset = 8;
	while (offset + 60 <= buffer.length) {
		const name = buffer.toString('latin1', offset, offset + 16).trim().replace(/\/$/, '');
		const size = parseInt(buffer.toString('latin1', offset + 48, offset + 58).trim(), 10);
		found[name] = buffer.subarray(offset + 60, offset + 60 + size);
		offset += 60 + size + (size % 2);
	}
	return found;
}

// tar (ustar): 512 byte headers, name 100 + prefix 155, size in octal, type flag
function tarFiles(buffer) {
	const found = {};
	let offset = 0;
	let longName = null;
	while (offset + 512 <= buffer.length) {
		const header = buffer.subarray(offset, offset + 512);
		if (header.every((byte) => byte === 0)) break;
		const field = (start, length) => header.toString('latin1', start, start + length).replace(/\0.*$/s, '');
		const size = parseInt(field(124, 12).trim() || '0', 8);
		const type = field(156, 1) || '0';
		const prefix = field(345, 155);
		let name = longName ?? (prefix ? `${prefix}/${field(0, 100)}` : field(0, 100));
		longName = null;
		const content = buffer.subarray(offset + 512, offset + 512 + size);
		if (type === 'L') longName = content.toString('latin1').replace(/\0.*$/s, '');
		else if (type === '0' || type === '\0') found[name.replace(/^\.\//, '')] = content;
		offset += 512 + Math.ceil(size / 512) * 512;
	}
	return found;
}

const members = arMembers(ipk);
for (const name of ['debian-binary', 'control.tar.gz', 'data.tar.gz']) {
	if (!members[name]) fail(`${ipkName} has no ${name}`);
}
const control = tarFiles(gunzipSync(members['control.tar.gz']));
const data = tarFiles(gunzipSync(members['data.tar.gz']));

const appDir = `usr/palm/applications/${APP_ID}/`;
const serviceDir = `usr/palm/services/${SERVICE_ID}/`;
const need = (path) => {
	if (!data[path]) problems.push(`missing ${path}`);
	return data[path];
};

const appinfoBytes = need(`${appDir}appinfo.json`);
for (const file of ['index.html', 'main.js', 'main.css', 'icon.png', 'icon-large.png', 'i18n/fr.json', 'i18n/de.json']) need(appDir + file);
for (const file of ['service.js', 'services.json', 'package.json', 'lib/bridge-host.js', 'bridge/base.js', 'bridge/smb.js']) need(serviceDir + file);
// The clip of the video test of the diagnostics page, which the bundler copies (0.1.0 shipped without it)
if (!Object.keys(data).some((path) => path.startsWith(appDir) && /(^|\/)probe[^/]*\.mp4$/.test(path))) {
	problems.push('missing the clip of the video test of the diagnostics page (probe.mp4)');
}
// Immuch360: the SMB bundle carries MIT and ISC code, whose notices must go with it
const bridgeLicences = need(`${serviceDir}bridge/LICENSES.txt`);
if (bridgeLicences) {
	const text = bridgeLicences.toString('utf8');
	for (const name of ['@winlinux/smb2', '@winlinux/auth', 'des.js', 'hash-wasm', 'Permission is hereby granted']) {
		if (!text.includes(name)) problems.push(`bridge/LICENSES.txt does not name ${name}`);
	}
}
const licenceText = (file, ...phrases) => {
	const bytes = need(appDir + file);
	if (!bytes) return;
	const text = bytes.toString('utf8');
	for (const phrase of phrases) if (!text.includes(phrase)) problems.push(`${file} does not say "${phrase}"`);
};
licenceText('LICENSE.txt', 'GNU Affero General Public License', 'https://github.com/freeKC/Immuch360', 'immich-tv-webos');
licenceText('LICENSE-AGPL-3.0.txt', 'GNU AFFERO GENERAL PUBLIC LICENSE', 'Version 3, 19 November 2007');
licenceText(
	'LICENSE-immich-tv-webos.txt',
	'Copyright (c) 2026 Quentin Jean-Amans',
	'The above copyright notice and this permission notice shall be included in all'
);
for (const path of Object.keys(data)) {
	if (path.startsWith(serviceDir) && /(^|\/)(dev|test)\.js$/.test(path)) problems.push(`development file in the service: ${path}`);
}

let version = null;
if (appinfoBytes) {
	const appinfo = JSON.parse(appinfoBytes.toString('utf8'));
	version = appinfo.version;
	if (appinfo.id !== APP_ID) problems.push(`appinfo.json id ${appinfo.id}, not ${APP_ID}`);
	if (appinfo.title !== 'Immuch360') problems.push(`appinfo.json title ${appinfo.title}`);
	if (ipkName !== `${APP_ID}_${appinfo.version}_all.ipk`) problems.push(`${ipkName} does not carry the version ${appinfo.version}`);
	// LG's store rules on the icons and the tile colour (tools/store-rules.mjs)
	const icons = Object.fromEntries(Object.keys(ICONS).map((name) => [name, data[appDir + name]]).filter(([, bytes]) => bytes));
	problems.push(...iconProblems(appinfo, icons), ...screenSaverProblems(appinfo), ...acgProblems(appinfo));
}
const servicePackage = data[`${serviceDir}package.json`];
if (servicePackage && version && JSON.parse(servicePackage.toString('utf8')).version !== version) {
	problems.push('the service and the app have different versions');
}
const servicesJson = data[`${serviceDir}services.json`];
if (servicesJson && JSON.parse(servicesJson.toString('utf8')).id !== SERVICE_ID) problems.push(`services.json does not name ${SERVICE_ID}`);
const controlText = Object.values(control).map((bytes) => bytes.toString('utf8')).join('\n');
if (!controlText.includes(`Package: ${APP_ID}`)) problems.push('control does not name the package');
if (ipk.length > MAX_IPK_BYTES) problems.push(`${ipk.length} bytes, more than ${MAX_IPK_BYTES}`);

const mainJs = data[`${appDir}main.js`];
// Luna services outside LG's ACG list must not be called (tools/store-rules.mjs)
for (const [path, bytes] of Object.entries(data)) {
	if (!/\.(js|html)$/.test(path)) continue;
	const text = bytes.toString('latin1');
	for (const service of FORBIDDEN_SERVICES) if (text.includes(service)) problems.push(`${path} calls ${service}`);
	// requiredACG must cover every Luna service the code names
	for (const service of unknownLunaServices(text)) problems.push(`${path} calls luna://${service}, which requiredACG does not cover`);
}
const lookbehinds = mainJs ? (mainJs.toString('latin1').match(/\(\?<[=!]/g) ?? []).length : 0;

const files = Object.keys(data).sort().map((path) => ({path, size: data[path].length}));
const total = files.reduce((sum, file) => sum + file.size, 0);
console.log(`[check-package] ${ipkName}: ${ipk.length} bytes, sha256 ${createHash('sha256').update(ipk).digest('hex')}`);
console.log(`[check-package] ${files.length} files, ${total} bytes unpacked, version ${version}`);
for (const file of files.slice().sort((a, b) => b.size - a.size).slice(0, 8)) console.log(`  ${String(file.size).padStart(9)}  ${file.path}`);
console.log(`[check-package] main.js: ${lookbehinds} lookbehind assertion(s) in regular expressions (Chromium 53 has none)`);
if (listIndex > 0) {
	writeFileSync(process.argv[listIndex + 1], JSON.stringify({ipk: ipkName, bytes: ipk.length, files}, null, 1) + '\n');
}
if (problems.length) fail(problems.join('; '));
console.log('[check-package] OK');
