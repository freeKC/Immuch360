#!/usr/bin/env node
// Immuch360: writes the version of a build into the files webOS reads it from.
//
//   node tools/set-version.mjs 0.1.0
//
// webos-meta/appinfo.json (the version the TV shows and the name of the .ipk) and service/package.json. The versions
// of webOS apps are three numbers; the CI takes them from the tag (webos-v0.1.0) or from the version of appinfo.json.

import {readFileSync, writeFileSync} from 'node:fs';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';

const WEBOS = join(dirname(fileURLToPath(import.meta.url)), '..');
const version = process.argv[2];

if (!version || !/^(0|[1-9]\d{0,4})\.(0|[1-9]\d{0,4})\.(0|[1-9]\d{0,4})$/.test(version)) {
	console.error(`[set-version] a version of three numbers is needed (0.1.0), not "${version ?? ''}"`);
	process.exit(1);
}

for (const file of ['webos-meta/appinfo.json', 'service/package.json']) {
	const path = join(WEBOS, file);
	const text = readFileSync(path, 'utf8');
	const json = JSON.parse(text);
	json.version = version;
	const indent = /^\t/m.test(text) ? '\t' : 2;
	writeFileSync(path, JSON.stringify(json, null, indent) + '\n');
	console.log(`[set-version] ${file}: ${version}`);
}
