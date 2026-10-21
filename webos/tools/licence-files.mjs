#!/usr/bin/env node
// Immuch360: the licences that go into the .ipk, next to index.html, so that every copy of the app carries them.
//
//   node tools/licence-files.mjs dist
//
// - LICENSE.txt: what the package is, its licence (GNU AGPL v3) and where its source is;
// - LICENSE-AGPL-3.0.txt: the licence of Immuch360 (the fork's ../LICENSE, word for word);
// - LICENSE-immich-tv-webos.txt: the MIT notice of immich-tv-webos (webos/LICENSE, word for word), which its licence
//   asks to keep in all copies or substantial portions of it.
// The notices of the bundled npm packages are in main.js.LICENSE.txt, written by the build.

import {copyFileSync, existsSync, readFileSync, writeFileSync} from 'node:fs';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';

const WEBOS = join(dirname(fileURLToPath(import.meta.url)), '..');
const FORK_LICENSE = process.env.IMMUCH360_LICENSE ?? join(WEBOS, '..', 'LICENSE');
const out = join(WEBOS, process.argv[2] ?? 'dist');

function fail(message) {
	console.error(`[licence-files] FAILED: ${message}`);
	process.exit(1);
}

const LICENCE_FILES = ['LICENSE.txt', 'LICENSE-AGPL-3.0.txt', 'LICENSE-immich-tv-webos.txt'];

if (!existsSync(out)) fail(`${out} does not exist: run the build first`);
if (!existsSync(FORK_LICENSE)) fail(`${FORK_LICENSE} not found (the fork's licence)`);
if (!/GNU AFFERO GENERAL PUBLIC LICENSE/.test(readFileSync(FORK_LICENSE, 'utf8'))) fail(`${FORK_LICENSE} is not the GNU AGPL`);
const mit = readFileSync(join(WEBOS, 'LICENSE'), 'utf8');
if (!/Quentin Jean-Amans/.test(mit) || !/Permission is hereby granted/.test(mit)) fail('webos/LICENSE is not the MIT notice of immich-tv-webos');

const version = JSON.parse(readFileSync(join(WEBOS, 'webos-meta', 'appinfo.json'), 'utf8')).version;

copyFileSync(FORK_LICENSE, join(out, 'LICENSE-AGPL-3.0.txt'));
copyFileSync(join(WEBOS, 'LICENSE'), join(out, 'LICENSE-immich-tv-webos.txt'));
writeFileSync(
	join(out, 'LICENSE.txt'),
	`Immuch360 for LG webOS TVs, version ${version}
https://github.com/freeKC/Immuch360

Immuch360 is an unofficial fork of Immich (https://immich.app). It is not affiliated with Immich nor with LG.

This program is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General
Public License as published by the Free Software Foundation, version 3. It is distributed in the hope that it will be
useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
PURPOSE. See the GNU Affero General Public License for more details: LICENSE-AGPL-3.0.txt, next to this file.

Source code: https://github.com/freeKC/Immuch360/tree/webos-v${version}/webos (the tag webos-v${version} of a release),
and the latest at https://github.com/freeKC/Immuch360/tree/immuch360/webos.

This app is built on immich-tv-webos 1.7.0 (https://github.com/Seeky91/immich-tv-webos), by Quentin Jean-Amans, under
the MIT licence. Its copyright and permission notice is in LICENSE-immich-tv-webos.txt, next to this file.

The notices of the open source packages bundled in main.js are in main.js.LICENSE.txt.
`
);
console.log(`[licence-files] ${LICENCE_FILES.join(', ')} → ${out}`);
