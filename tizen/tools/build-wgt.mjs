#!/usr/bin/env node
// Immuch360 for Samsung TVs: turns the webOS bundle into the folder of a Tizen web app.
//
//   node tizen/tools/build-wgt.mjs --dist webos/dist [--version 0.1.0] [--out tizen/build/wgt]
//   node tizen/tools/build-wgt.mjs --print-version      the version of tizen/config.xml
//
// The bundle npm run pack-p makes for webOS (webos/dist, Chromium 53 syntax) runs as it is on Samsung TVs from Tizen
// 5.5 (Chromium 69); the app finds the TV at run time (webos/src/platform/). This copies it without what only webOS
// reads (appinfo.json, its icons and splash), adds tizen/config.xml with the version and tizen/icon.png, and loads
// Samsung's Product API ($WEBAPIS/webapis/webapis.js, the screen saver, the TV model) before main.js. A plain browser
// fails to load that script and goes on. The Tizen command line tools then sign the folder into a .wgt
// (tizen/tools/package-ci.sh in CI); tizen/tools/check-wgt.mjs checks the result.
//
// Plain Node, built in modules only.

import {copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync} from 'node:fs';
import {dirname, join, relative, resolve} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';

const TIZEN = resolve(dirname(fileURLToPath(import.meta.url)), '..');

/** What webos/dist holds for webOS only, left out of the Samsung package */
export const WEBOS_ONLY = ['appinfo.json', 'icon.png', 'icon-large.png', 'icon-mini.png', 'splash.png'];

/** The script tag of Samsung's Product API, which the TV's web runtime resolves */
export const WEBAPIS_TAG = '<script src="$WEBAPIS/webapis/webapis.js"></script>';

/** The licence files every copy carries (webos/tools/licence-files.mjs) */
export const LICENCE_FILES = ['LICENSE.txt', 'LICENSE-AGPL-3.0.txt', 'LICENSE-immich-tv-webos.txt'];

/** The fewest locale files the bundle has (88 at the time of writing; English is in main.js) */
export const MIN_LOCALE_FILES = 80;

/** A Tizen version: three numbers, at most 255.255.65535 (Samsung's "Configuring Web Applications") */
export function checkVersion(version) {
	const match = /^(\d+)\.(\d+)\.(\d+)$/.exec(String(version ?? ''));
	if (!match) throw new Error(`version "${version}": three numbers expected, as 0.1.0`);
	const [major, minor, patch] = match.slice(1).map(Number);
	if (major > 255 || minor > 255 || patch > 65535) throw new Error(`version ${version}: Tizen takes at most 255.255.65535`);
	return version;
}

const WIDGET_VERSION = /(<widget\b[^>]*?\sversion=")([^"]*)(")/;

/** The version written in config.xml, the default of a build without a tag nor an input */
export function templateVersion(template) {
	const found = WIDGET_VERSION.exec(template);
	if (!found) throw new Error('config.xml has no widget version');
	return found[2];
}

/** config.xml with the version of the build */
export function configXml(template, version) {
	if (!WIDGET_VERSION.test(template)) throw new Error('config.xml has no widget version');
	return template.replace(WIDGET_VERSION, `$1${checkVersion(version)}$3`);
}

/** index.html with the Product API loaded once, before main.js */
export function withWebapis(html) {
	const main = /<script\b[^>]*\bsrc="(?:\.\/)?main\.js"[^>]*>/.exec(html);
	if (!main) throw new Error('index.html loads no main.js');
	if (html.includes(WEBAPIS_TAG)) {
		if (html.indexOf(WEBAPIS_TAG) > main.index) throw new Error('index.html loads webapis.js after main.js');
		return html;
	}
	return html.slice(0, main.index) + WEBAPIS_TAG + html.slice(main.index);
}

function copyTree(from, to, skip) {
	mkdirSync(to, {recursive: true});
	for (const name of readdirSync(from)) {
		const source = join(from, name);
		if (statSync(source).isDirectory()) copyTree(source, join(to, name), () => false);
		else if (!skip(name)) copyFileSync(source, join(to, name));
	}
}

function filesUnder(dir) {
	const found = [];
	for (const name of readdirSync(dir)) {
		const path = join(dir, name);
		if (statSync(path).isDirectory()) found.push(...filesUnder(path));
		else found.push(path);
	}
	return found;
}

/** What the folder must hold for the app to start and to carry its licences; [] when all is there */
export function missingParts(out) {
	const missing = [];
	for (const file of ['index.html', 'main.js', 'main.css', 'config.xml', 'icon.png', ...LICENCE_FILES]) {
		if (!existsSync(join(out, file))) missing.push(file);
	}
	const locales = existsSync(join(out, 'i18n')) ? readdirSync(join(out, 'i18n')).filter((name) => name.endsWith('.json')) : [];
	if (locales.length < MIN_LOCALE_FILES) missing.push(`i18n/*.json (${locales.length} locale files, ${MIN_LOCALE_FILES} at least)`);
	if (!filesUnder(out).some((path) => /(^|[\\/])probe[^\\/]*\.mp4$/.test(path))) missing.push('the clip of the video test of the About page (probe.mp4)');
	for (const file of WEBOS_ONLY) {
		if (file !== 'icon.png' && existsSync(join(out, file))) missing.push(`${file} should not be there`);
	}
	return missing;
}

/** Builds the folder; returns its file count and size */
export function buildWgt({dist, version, out, template = join(TIZEN, 'config.xml'), icon = join(TIZEN, 'icon.png')}) {
	checkVersion(version);
	if (!existsSync(join(dist, 'index.html'))) throw new Error(`${dist} has no index.html: run npm run pack-p in webos/ first`);
	rmSync(out, {recursive: true, force: true});
	copyTree(dist, out, (name) => WEBOS_ONLY.indexOf(name) >= 0);
	writeFileSync(join(out, 'config.xml'), configXml(readFileSync(template, 'utf8'), version));
	copyFileSync(icon, join(out, 'icon.png'));
	writeFileSync(join(out, 'index.html'), withWebapis(readFileSync(join(out, 'index.html'), 'utf8')));
	const missing = missingParts(out);
	if (missing.length) throw new Error(`the package folder lacks: ${missing.join('; ')}`);
	const files = filesUnder(out);
	return {files: files.length, bytes: files.reduce((sum, path) => sum + statSync(path).size, 0)};
}

function argument(args, name, fallback) {
	const index = args.indexOf(name);
	return index >= 0 && index + 1 < args.length ? args[index + 1] : fallback;
}

function main(args) {
	const dist = resolve(argument(args, '--dist', join(TIZEN, '..', 'webos', 'dist')));
	const out = resolve(argument(args, '--out', join(TIZEN, 'build', 'wgt')));
	try {
		const fromTemplate = templateVersion(readFileSync(join(TIZEN, 'config.xml'), 'utf8'));
		if (args.indexOf('--print-version') >= 0) {
			console.log(checkVersion(fromTemplate));
			return;
		}
		const version = argument(args, '--version', '') || fromTemplate;
		const {files, bytes} = buildWgt({dist, version, out});
		console.log(`[build-wgt] ${relative(process.cwd(), out) || '.'}: version ${version}, ${files} files, ${bytes} bytes`);
	} catch (error) {
		console.error(`[build-wgt] FAILED: ${error.message}`);
		process.exit(1);
	}
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) main(process.argv.slice(2));
