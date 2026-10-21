#!/usr/bin/env node
// Immuch360: the texts of the webOS app, taken from the fork's i18n/ files at build time.
//
//   node tools/build-i18n.mjs              writes src/immuch360/i18n/generated/{en,locales}.json
//   node tools/build-i18n.mjs --dist dist  also writes dist/i18n/<locale>.json for the 88 other locales
//
// The keys are those the code asks for: every t('key') and i18nKey('key') of src/ (tests aside). Their English comes
// from ../i18n/en.json, where the few texts only the TV app has are the webos_* keys, translated with the others at a
// release. A key missing from it fails the build. Each other locale file keeps the keys it translates; the app falls
// back to English for the rest.

import {mkdirSync, readFileSync, readdirSync, statSync, writeFileSync} from 'node:fs';
import {dirname, join, relative} from 'node:path';
import {fileURLToPath} from 'node:url';

const WEBOS = join(dirname(fileURLToPath(import.meta.url)), '..');
const FORK_I18N = process.env.IMMUCH360_I18N_DIR ?? join(WEBOS, '..', 'i18n');
const GENERATED = join(WEBOS, 'src', 'immuch360', 'i18n', 'generated');
const KEY_CALL = /\b(?:t|i18nKey)\(\s*['"]([A-Za-z0-9_.]+)['"]/g;

function fail(message) {
	console.error(`[build-i18n] FAILED: ${message}`);
	process.exit(1);
}

function sourceFiles(dir) {
	const files = [];
	for (const name of readdirSync(dir)) {
		const path = join(dir, name);
		if (statSync(path).isDirectory()) {
			if (name !== 'generated' && name !== 'node_modules') files.push(...sourceFiles(path));
		} else if (/\.(ts|tsx)$/.test(name) && !/\.test\.(ts|tsx)$/.test(name)) {
			files.push(path);
		}
	}
	return files;
}

// i18n/*.json nest a few groups ("errors": {...}); the app reads them as "errors.something_went_wrong"
function flatten(object, prefix = '', out = {}) {
	for (const [key, value] of Object.entries(object)) {
		if (value && typeof value === 'object') flatten(value, `${prefix}${key}.`, out);
		else if (typeof value === 'string') out[prefix + key] = value;
	}
	return out;
}

const readJson = (path) => JSON.parse(readFileSync(path, 'utf8'));
const sorted = (object) => Object.fromEntries(Object.keys(object).sort().map((key) => [key, object[key]]));

const keys = new Set();
// Comments aside (whole comment lines and blocks), so that a comment quoting a call adds no key
const withoutComments = (code) => code.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
for (const file of sourceFiles(join(WEBOS, 'src'))) {
	for (const match of withoutComments(readFileSync(file, 'utf8')).matchAll(KEY_CALL)) keys.add(match[1]);
}

const forkEn = flatten(readJson(join(FORK_I18N, 'en.json')));
const english = {};
const missing = [];
for (const key of keys) {
	const text = forkEn[key];
	if (text === undefined) missing.push(key);
	else english[key] = text;
}
if (missing.length) fail(`keys missing from i18n/en.json: ${missing.sort().join(', ')}`);
const unused = Object.keys(forkEn).filter((key) => key.startsWith('webos_') && !keys.has(key));
if (unused.length) console.warn(`[build-i18n] webos_* keys of i18n/en.json the code does not use: ${unused.join(', ')}`);

const locales = readdirSync(FORK_I18N)
	.filter((name) => name.endsWith('.json') && name !== 'en.json')
	.map((name) => name.slice(0, -5))
	.sort();

mkdirSync(GENERATED, {recursive: true});
writeFileSync(join(GENERATED, 'en.json'), JSON.stringify(sorted(english), null, '\t') + '\n');
writeFileSync(join(GENERATED, 'locales.json'), JSON.stringify(locales) + '\n');
const webosOnly = Object.keys(english).filter((key) => key.startsWith('webos_')).length;
console.log(`[build-i18n] ${keys.size} keys (${webosOnly} webos_* ones), ${locales.length + 1} locales → ${relative(WEBOS, GENERATED)}`);

const distIndex = process.argv.indexOf('--dist');
if (distIndex > 0) {
	const out = join(WEBOS, process.argv[distIndex + 1] ?? 'dist', 'i18n');
	mkdirSync(out, {recursive: true});
	let bytes = 0;
	const coverage = [];
	for (const locale of locales) {
		const all = flatten(readJson(join(FORK_I18N, `${locale}.json`)));
		const picked = {};
		for (const key of keys) {
			const text = all[key];
			if (typeof text === 'string' && text.trim() && text !== english[key]) picked[key] = text;
		}
		const json = JSON.stringify(sorted(picked));
		writeFileSync(join(out, `${locale}.json`), json);
		bytes += Buffer.byteLength(json);
		coverage.push(`${locale} ${Object.keys(picked).length}`);
	}
	console.log(`[build-i18n] ${locales.length} locale files, ${Math.round(bytes / 1024)} KB → ${relative(WEBOS, out)}`);
	console.log(`[build-i18n] translated keys per locale: ${coverage.join(', ')}`);
}
