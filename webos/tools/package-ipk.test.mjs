// The two packages of a build (tools/package-ipk.mjs): the self assessment of 23 October 2026, fix F10
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {PACKAGES, appinfoFor} from './package-ipk.mjs';
import {resolutionProblems} from './store-rules.mjs';

const appinfo = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'webos-meta', 'appinfo.json'), 'utf8'));

test('two packages: 1920x1080 in build/, 1280x720 in build-1280x720/', () => {
	assert.deepEqual(
		PACKAGES.map((p) => [p.resolution, p.out]),
		[
			['1920x1080', 'build'],
			['1280x720', 'build-1280x720'],
		]
	);
});

test('the 1920x1080 appinfo.json has no resolution (the default), the 1280x720 one says it', () => {
	assert.equal('resolution' in appinfo, false);
	assert.deepEqual(appinfoFor(appinfo, '1920x1080'), appinfo);
	const hd = appinfoFor(appinfo, '1280x720');
	assert.equal(hd.resolution, '1280x720');
	assert.deepEqual(Object.keys(hd).slice(Object.keys(hd).indexOf('type'), Object.keys(hd).indexOf('type') + 2), ['type', 'resolution']);
	const {resolution, ...rest} = hd;
	assert.equal(resolution, '1280x720');
	assert.deepEqual(rest, appinfo);
	assert.deepEqual(resolutionProblems(appinfo, '1920x1080'), []);
	assert.deepEqual(resolutionProblems(hd, '1280x720'), []);
	assert.ok(resolutionProblems(appinfo, '1280x720').length > 0);
	assert.ok(resolutionProblems(hd, '1920x1080').length > 0);
});
