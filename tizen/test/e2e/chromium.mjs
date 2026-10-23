#!/usr/bin/env node
// The engine of the end to end test, from chromium.json: downloaded once into the cache folder, its size and SHA256
// checked after every download and every restore of the cache (a file that does not match is fetched again, never
// run), then unpacked. Prints the path of the binary.
//
//   node tizen/test/e2e/chromium.mjs <label> <cache folder>      labels: 69, 76, 94, cft

import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {createReadStream, createWriteStream, existsSync, mkdirSync, readFileSync, rmSync, statSync} from 'node:fs';
import {dirname, join, resolve} from 'node:path';
import {Readable} from 'node:stream';
import {pipeline} from 'node:stream/promises';
import {fileURLToPath} from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const [label, cacheArg] = process.argv.slice(2);
const engine = JSON.parse(readFileSync(join(HERE, 'chromium.json'), 'utf8')).engines.find((entry) => entry.label === label);
if (!engine || !cacheArg) {
	console.error('[chromium] usage: chromium.mjs <69|76|94|cft> <cache folder>');
	process.exit(2);
}
const folder = resolve(cacheArg, `${label}-${engine.sha256.slice(0, 12)}`);
const zip = join(folder, 'engine.zip');
const say = (line) => console.error(`[chromium ${label}] ${line}`);

async function sha256(path) {
	const hash = createHash('sha256');
	await pipeline(createReadStream(path), hash);
	return hash.digest('hex');
}

const good = async () => existsSync(zip) && statSync(zip).size === engine.size && (await sha256(zip)) === engine.sha256;

mkdirSync(folder, {recursive: true});
if (await good()) say(`${engine.version} from the cache, size and SHA256 checked`);
else {
	rmSync(folder, {recursive: true, force: true});
	mkdirSync(folder, {recursive: true});
	say(`downloading ${engine.url}`);
	for (let attempt = 1; ; attempt++) {
		try {
			const response = await fetch(engine.url);
			if (!response.ok) throw new Error(`HTTP ${response.status}`);
			await pipeline(Readable.fromWeb(response.body), createWriteStream(zip));
			break;
		} catch (error) {
			if (attempt >= 3) throw error;
			say(`attempt ${attempt}: ${error.message}; again`);
		}
	}
	if (!(await good())) {
		rmSync(zip, {force: true});
		say('FAILED: the download does not have the size and SHA256 of chromium.json');
		process.exit(1);
	}
	say(`${engine.version} downloaded, size and SHA256 checked`);
}
const binary = join(folder, engine.binary);
if (!existsSync(binary)) execFileSync('unzip', ['-q', '-o', zip, '-d', folder]);
console.log(binary);
