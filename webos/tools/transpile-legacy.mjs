#!/usr/bin/env node
// Transpiles dist/main.js down to webOS-compatible syntax (Chromium 53 / webOS 4.0+) and
// lowers dist/main.css for the same engine. Enact CLI excludes most node_modules from
// babel-loader, so dependencies like @tanstack/query-core ship modern syntax (??=, ??, ?.,
// #privateField, …) into the bundle, which older webOS versions cannot parse. Combined with
// the runtime polyfills in src/polyfills.ts, this brings the supported floor down to LG TVs
// from 2018 onward (webOS 4.0). webOS 3.x (Chromium 38) is out of reach: esbuild cannot
// lower let/const/classes to ES5.

import { build, transform } from 'esbuild';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { lowerForChromium53, findChromium53Unsupported } from './legacy-css.mjs';

const TARGET = 'chrome53';
const BUNDLE = 'dist/main.js';
const STYLESHEET = 'dist/main.css';

// Needed before any bundle code runs, which src/polyfills.ts can't do: webpack's runtime reads
// globalThis (Chrome 71) first thing, and the object-spread helpers esbuild emits for chrome53
// capture Object.getOwnPropertyDescriptors (Chrome 54) in a top-level var. ES5, and it opens
// with "use strict" because a banner would otherwise demote the bundle's own directive.
const STARTUP_POLYFILLS =
	'"use strict";window.globalThis=window.globalThis||window;' +
	'Object.getOwnPropertyDescriptors||(Object.getOwnPropertyDescriptors=function(o){var d={};' +
	'Reflect.ownKeys(o).forEach(function(k){d[k]=Object.getOwnPropertyDescriptor(o,k)});return d});';

function fail(message, code = 1) {
	console.error(`[transpile-legacy] FAILED: ${message}`);
	process.exit(code);
}

for (const input of [BUNDLE, STYLESHEET]) {
	if (!existsSync(input)) fail(`missing input: ${input}`);
}

await build({
	entryPoints: [BUNDLE],
	outfile: BUNDLE,
	target: TARGET,
	banner: { js: STARTUP_POLYFILLS },
	bundle: false,
	minify: true,
	sourcemap: false,
	allowOverwrite: true,
	legalComments: 'none',
	logLevel: 'warning',
});

// Round-trip parse: re-feed the output to esbuild with the same target.
// If unsupported syntax slipped through (or was reintroduced), this errors.
try {
	await transform(readFileSync(BUNDLE, 'utf8'), { target: TARGET, loader: 'js' });
} catch (err) {
	fail(`bundle does not parse cleanly under ${TARGET}\n${err.message || err}`, 2);
}

console.log(`[transpile-legacy] ${BUNDLE} → ${TARGET} (parse-validated)`);

// package.json's cssnano override keeps the minifier from emitting #RRGGBBAA colors; esbuild
// lowers the ones Sandstone writes itself and adds the -webkit- prefixes Chromium 53 needs.
const { code: css } = await transform(lowerForChromium53(readFileSync(STYLESHEET, 'utf8')), {
	loader: 'css',
	target: TARGET,
	minifyWhitespace: true,
	logLevel: 'warning',
});
const unsupported = findChromium53Unsupported(css);
if (unsupported.length) {
	fail(`${unsupported.length} declaration(s) Chromium 53 cannot parse remain in ${STYLESHEET}:\n${[...new Set(unsupported)].slice(0, 10).join('\n')}`, 2);
}
writeFileSync(STYLESHEET, css);

console.log(`[transpile-legacy] ${STYLESHEET} → ${TARGET} (lowered, checked)`);
