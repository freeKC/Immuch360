#!/usr/bin/env node
// Immuch360: builds the media bridge of the JS service (webos/bridge/, see bridge/src/index.js) into the service:
//
//   service/bridge/base.js      the bridge, for Node 8 (webOS 5 and 6) and later: core modules only
//   service/bridge/smb.js       the SMB client, for Node 12 (webOS 22) and later, loaded by base.js on demand
//   service/bridge/LICENSES.txt the licences of the third party code in smb.js
//
//   node tools/build-bridge.mjs [--check]   --check also loads both bundles and fails if they do not
//
// service.js loads base.js on Node 8 and later only: webOS 4 runs Node 0.12, which keeps the phone sign in alone.

import {build} from 'esbuild';
import {mkdirSync, readFileSync, writeFileSync, existsSync} from 'node:fs';
import {dirname, join, relative, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createRequire} from 'node:module';

const WEBOS = join(dirname(fileURLToPath(import.meta.url)), '..');
const OUT = join(WEBOS, 'service', 'bridge');
const VENDOR = join(WEBOS, 'bridge', 'vendor');
const SHIMS = {
	'fs/promises': join(WEBOS, 'bridge', 'shims', 'fs-promises.cjs'),
	'stream/promises': join(WEBOS, 'bridge', 'shims', 'stream-promises.cjs')
};
const BANNER =
	'/* Immuch360 media bridge for the LG webOS app (https://github.com/freeKC/Immuch360, webos/bridge/), GNU AGPL v3.\n' +
	'   Built by webos/tools/build-bridge.mjs; the licences of the third party code are in LICENSES.txt. */';

function fail(message) {
	console.error(`[build-bridge] FAILED: ${message}`);
	process.exit(1);
}

// What the TV's Node lacks, and the des.js loader of @winlinux/auth (see bridge/vendor/README.md)
const tvNodePlugin = {
	name: 'tv-node',
	setup(b) {
		b.onResolve({filter: /^(node:)?(fs|stream)\/promises$/}, (args) => ({path: SHIMS[args.path.replace(/^node:/, '')]}));
		b.onLoad({filter: /[\\/]@winlinux[\\/]auth[\\/]dist[\\/]src[\\/]auth[\\/]ntlm[\\/]crypto\.js$/}, (args) => {
			const source = readFileSync(args.path, 'utf8');
			const loader = "const require = createRequire(import.meta.url);\nconst { DES } = require('des.js');";
			if (!source.includes(loader)) fail(`${args.path}: the des.js loader changed, see bridge/vendor/README.md`);
			const patched = source
				.replace("import { createRequire } from 'node:module';\n", '')
				.replace(loader, "import desModule from 'des.js';\nconst { DES } = desModule;");
			return {contents: patched, loader: 'js'};
		});
	}
};

mkdirSync(OUT, {recursive: true});

await build({
	entryPoints: [join(WEBOS, 'bridge', 'src', 'entry-base.js')],
	bundle: true,
	platform: 'node',
	target: 'node8',
	format: 'cjs',
	outfile: join(OUT, 'base.js'),
	banner: {js: BANNER},
	legalComments: 'none',
	logLevel: 'error'
}).catch(() => fail('base.js'));

const smb = await build({
	entryPoints: [join(WEBOS, 'bridge', 'src', 'smb', 'entry.js')],
	bundle: true,
	platform: 'node',
	target: 'node12',
	format: 'cjs',
	outfile: join(OUT, 'smb.js'),
	banner: {js: BANNER},
	legalComments: 'none',
	nodePaths: [VENDOR],
	external: ['kerberos', '@winlinux/krb-session-key'],
	plugins: [tvNodePlugin],
	metafile: true,
	logLevel: 'error'
}).catch(() => fail('smb.js'));

// The packages whose code went into smb.js, with their licence texts
const packages = new Map();
for (const input of Object.keys(smb.metafile.inputs)) {
	const path = resolve(WEBOS, input);
	let dir = dirname(path);
	while (dir.startsWith(WEBOS) && !existsSync(join(dir, 'package.json'))) dir = dirname(dir);
	if (dir === WEBOS || !dir.startsWith(WEBOS)) continue;
	const manifest = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8'));
	if (!manifest.name || packages.has(manifest.name)) continue;
	const licenceFiles = ['LICENSE', 'LICENSE.md', 'LICENSE.txt', 'LICENCE', 'license', 'LICENSE-MIT', 'LICENSE.node-smb2.md'].filter((name) => existsSync(join(dir, name)));
	const texts = licenceFiles.map((name) => `--- ${name} ---\n${readFileSync(join(dir, name), 'utf8').trim()}\n`);
	// A package without a licence file (des.js) states it in its README
	if (!texts.length && existsSync(join(dir, 'README.md'))) {
		const readme = readFileSync(join(dir, 'README.md'), 'utf8');
		const section = /^#+\s*licen[cs]e\s*\n([\s\S]*?)(?=^#+\s|(?![\s\S]))/im.exec(readme);
		if (section && /permission is hereby granted/i.test(section[1])) texts.push(`--- README.md, licence section ---\n${section[1].trim()}\n`);
	}
	if (!texts.length) fail(`${manifest.name} has no licence text`);
	packages.set(manifest.name, {version: manifest.version, licence: manifest.license, where: relative(WEBOS, dir), texts});
}
const names = [...packages.keys()].sort();
for (const needed of ['@winlinux/smb2', '@winlinux/auth', 'des.js']) if (!packages.has(needed)) fail(`${needed} is not in smb.js`);
let notices =
	'Third party code in smb.js, the SMB client of the Immuch360 media bridge (service/bridge/smb.js).\n' +
	'base.js holds only the code of Immuch360 (GNU AGPL v3).\n\n';
for (const name of names) {
	const p = packages.get(name);
	notices += `=== ${name} ${p.version} (${p.licence}) ===\n\n${p.texts.join('\n')}\n`;
}
writeFileSync(join(OUT, 'LICENSES.txt'), notices);

if (process.argv.includes('--check')) {
	const require = createRequire(import.meta.url);
	const base = require(join(OUT, 'base.js'));
	if (typeof base.createBridge !== 'function') fail('base.js does not export createBridge');
	const bridge = base.createBridge({});
	const started = await bridge.start();
	if (!started.port || !/^[0-9a-f]{32}$/.test(started.token)) fail('base.js did not start');
	bridge.stop();
	const smbModule = require(join(OUT, 'smb.js'));
	if (typeof smbModule.createSmbDriver !== 'function') fail('smb.js does not export createSmbDriver');
	smbModule.createSmbDriver();
}

const size = (file) => `${Math.round(readFileSync(join(OUT, file)).length / 1024)} KB`;
console.log(`[build-bridge] base.js ${size('base.js')}, smb.js ${size('smb.js')} (${names.join(', ')})`);
