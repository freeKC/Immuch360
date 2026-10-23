#!/usr/bin/env node
// Immuch360: the two .ipk of a build, one per resolution LG distributes (after npm run pack-p; npm run ipk runs both).
//
//   node tools/package-ipk.mjs
//
// * build/com.aprogsys.immuch360_<version>_all.ipk: dist/ as it is, no "resolution" in appinfo.json, which webOS reads
//   as 1920x1080: the package of the UHD TVs.
// * build-1280x720/com.aprogsys.immuch360_<version>_all.ipk: a copy of dist/ (build-1280x720/dist/) whose appinfo.json says
//   "resolution": "1280x720": the package of the Full HD TVs, and of the UHD ones LG gives only 1280x720 apps (LG staff,
//   26 May 2025: "All FHD TV models support 1280x720 apps"; LG's Supported App Resolution page recommends submitting
//   both). The same code runs in both: Enact picks its "hd" screen type from the window, 16 px per rem instead of 24,
//   and the app's tokens keep LG's 14 px minimum text and 20 px safe area there (src/styles/tokens.less).
//
// Each package is made by ares-package (the service with it, without its development files) and checked by
// tools/check-package.mjs, which also lists its files.

import {cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';

const WEBOS = join(dirname(fileURLToPath(import.meta.url)), '..');

/** The packages, and where each is made from and to */
export const PACKAGES = [
	{resolution: '1920x1080', dist: 'dist', out: 'build'},
	{resolution: '1280x720', dist: 'build-1280x720/dist', out: 'build-1280x720'},
];

/** appinfo.json of a package: the 1280x720 one gets "resolution" after "type", the 1920x1080 one stays as it is */
export function appinfoFor(appinfo, resolution) {
	const out = {};
	for (const [key, value] of Object.entries(appinfo)) {
		if (key === 'resolution') continue;
		out[key] = value;
		if (key === 'type' && resolution !== '1920x1080') out.resolution = resolution;
	}
	if (resolution !== '1920x1080' && !out.resolution) out.resolution = resolution;
	return out;
}

function run(command, args) {
	const result = spawnSync(command, args, {cwd: WEBOS, stdio: 'inherit'});
	if (result.status !== 0) {
		console.error(`[package-ipk] FAILED: ${command} ${args.join(' ')}`);
		process.exit(result.status || 1);
	}
}

function main() {
	if (!existsSync(join(WEBOS, 'dist', 'appinfo.json'))) {
		console.error('[package-ipk] FAILED: no dist/appinfo.json, run npm run pack-p first');
		process.exit(1);
	}
	const aresPackage = join(WEBOS, 'node_modules', '.bin', process.platform === 'win32' ? 'ares-package.cmd' : 'ares-package');
	for (const pkg of PACKAGES) {
		rmSync(join(WEBOS, pkg.out), {recursive: true, force: true});
		mkdirSync(join(WEBOS, pkg.out), {recursive: true});
		if (pkg.dist !== 'dist') {
			cpSync(join(WEBOS, 'dist'), join(WEBOS, pkg.dist), {recursive: true});
			const path = join(WEBOS, pkg.dist, 'appinfo.json');
			const appinfo = JSON.parse(readFileSync(path, 'utf8'));
			writeFileSync(path, JSON.stringify(appinfoFor(appinfo, pkg.resolution), null, '\t') + '\n');
		}
		console.log(`[package-ipk] ${pkg.resolution}: ${pkg.dist}/ and service/ → ${pkg.out}/`);
		run(aresPackage, [`${pkg.dist}/`, 'service/', '-o', `./${pkg.out}/`, '-n', '-e', '*dev.js', '-e', '*test.js']);
		run(process.execPath, ['tools/check-package.mjs', pkg.out, '--list', `${pkg.out}/ipk-files.json`, '--resolution', pkg.resolution]);
	}
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) main();
