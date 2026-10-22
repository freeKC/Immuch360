#!/usr/bin/env node
// Immuch360: the texts of the webOS app, taken from the fork's i18n/ files at build time.
//
//   node tools/build-i18n.mjs              writes src/immuch360/i18n/generated/{en,locales,names}.json
//   node tools/build-i18n.mjs --dist dist  also writes dist/i18n/<locale>.json for the 88 other locales
//
// The keys are those the code asks for: every t('key') and i18nKey('key') of src/ (tests aside). Their English comes
// from ../i18n/en.json, where the few texts only the TV app has are the webos_* keys, translated with the others at a
// release. A key missing from it fails the build. Each other locale file keeps the keys it translates; the app falls
// back to English for the rest.
//
// A t() whose key is not written out is not seen here, and its text would be missing from the app (the key would show
// instead). So the build fails on any t() whose first argument is neither a quoted key nor a plain name (label,
// item.label, NAMES[layout]) in a file that holds its keys through i18nKey('key').

import {Buffer} from 'node:buffer';
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

// The first argument of each t( call of code, as written: from the opening parenthesis to the comma or the closing
// parenthesis at the same depth (strings and template literals skipped)
const T_CALL = /(?<![\w$.])t\(/g;
export function tArguments(code) {
	const found = [];
	for (const match of code.matchAll(T_CALL)) {
		if (/function\s+$/.test(code.slice(Math.max(0, match.index - 20), match.index))) continue;
		let depth = 0;
		let quote = null;
		let end = match.index + match[0].length;
		for (; end < code.length; end++) {
			const c = code[end];
			if (quote) {
				if (c === '\\') end++;
				else if (c === quote) quote = null;
			} else if (c === "'" || c === '"' || c === '`') quote = c;
			else if (c === '(' || c === '[' || c === '{') depth++;
			else if (c === ')' || c === ']' || c === '}') {
				if (depth === 0) break;
				depth--;
			} else if (c === ',' && depth === 0) break;
		}
		found.push(code.slice(match.index + match[0].length, end).trim());
	}
	return found;
}

const QUOTED_KEY = /^(['"])[A-Za-z0-9_.]+\1$/;
const PLAIN_NAME = /^[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*|\[[\w$.]+\])*$/;
/** Why the first argument of a t() call is not one the build can follow, null when it is */
export function unfollowedKey(argument, fileHasI18nKey) {
	if (QUOTED_KEY.test(argument)) return null;
	if (PLAIN_NAME.test(argument)) return fileHasI18nKey ? null : `t(${argument}) in a file without any i18nKey('key')`;
	return `t(${argument})`;
}

// Comments aside (whole comment lines and blocks), so that a comment quoting a call adds no key
const withoutComments = (code) => code.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');

function collectKeys() {
	const keys = new Set();
	const unfollowed = [];
	for (const file of sourceFiles(join(WEBOS, 'src'))) {
		const code = withoutComments(readFileSync(file, 'utf8'));
		for (const match of code.matchAll(KEY_CALL)) keys.add(match[1]);
		const hasI18nKey = /(?<![\w$.])i18nKey\(/.test(code);
		for (const argument of tArguments(code)) {
			const why = unfollowedKey(argument, hasI18nKey);
			if (why) unfollowed.push(`${relative(WEBOS, file)}: ${why}`);
		}
	}
	if (unfollowed.length) {
		fail(`t() calls whose key the build cannot read (write the key out, or hold it with i18nKey('key')):\n  ${unfollowed.join('\n  ')}`);
	}
	return keys;
}

// Imported by the tests of the tool: only the functions above
const isMain = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isMain) build();

function build() {
	const keys = collectKeys();

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

	// The name of each language in itself, for the Language choice of the About page. Written here, with the ICU data of
	// Node, because the Chromium of a webOS 4 to 6 TV has no Intl.DisplayNames. Immich's web app names a few that ICU
	// does not know the same way (web/src/lib/utils/i18n.ts).
	const NAMES_ICU_LACKS = {bi: 'Bislama', kxm: 'Khmer Surin', mfa: 'Malay (Pattani)', swg: 'Schwäbisch', tl: 'Tagalog'};
	function nativeName(locale) {
		if (NAMES_ICU_LACKS[locale]) return NAMES_ICU_LACKS[locale];
		const tag = locale.replace(/_/g, '-');
		let name = locale;
		try {
			name = new Intl.DisplayNames([tag], {type: 'language'}).of(tag) ?? locale;
		} catch {
			// A code ICU rejects keeps its own name
		}
		return name.charAt(0).toLocaleUpperCase(tag) + name.slice(1);
	}
	const names = Object.fromEntries(['en', ...locales].map((locale) => [locale, nativeName(locale)]));

	mkdirSync(GENERATED, {recursive: true});
	writeFileSync(join(GENERATED, 'en.json'), JSON.stringify(sorted(english), null, '\t') + '\n');
	writeFileSync(join(GENERATED, 'locales.json'), JSON.stringify(locales) + '\n');
	writeFileSync(join(GENERATED, 'names.json'), JSON.stringify(names, null, '\t') + '\n');
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
}
