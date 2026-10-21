// The Immich client of src/api against responses shaped after the server's schemas (test/fixtures/immich): the URLs
// and headers it sends, and what the 360° layer reads from the answers.

import {test, describe, beforeEach, afterEach} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {APIClient} from '../../src/api/client.ts';
import {ImmichRepository} from '../../src/api/ImmichRepository.ts';
import {AuthMethod} from '../../src/api/types.ts';
import {isShownAs360, resolveSphereView} from '../../src/immuch360/sphere/rules.ts';

const fixture = (name) => readFileSync(new URL(`../fixtures/immich/${name}`, import.meta.url), 'utf8');

const ROUTES = {
	'/api/timeline/buckets?visibility=timeline&withPartners=true&withStacked=true': 'timeline-buckets.json',
	'/api/timeline/bucket?timeBucket=2024-06-01&visibility=timeline&withPartners=true&withStacked=true': 'timeline-bucket-2024-06-01.json',
	'/api/assets/7f1c2b8e-0d4f-4d1e-9a51-2a5b7c3e9f10': 'asset-360.json',
	'/api/assets/9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d': 'asset-vr180.json',
	'/api/server/about': 'server-about.json',
};

let calls;
let realFetch;

beforeEach(() => {
	calls = [];
	realFetch = globalThis.fetch;
	globalThis.fetch = async (url, options = {}) => {
		calls.push({url, headers: options.headers ?? {}});
		const {pathname, search} = new URL(url);
		if (pathname.endsWith('/thumbnail')) return new Response(new Uint8Array([0xff, 0xd8, 0xff, 0xd9]), {status: 200});
		const name = ROUTES[pathname + search];
		return name ? new Response(fixture(name), {status: 200}) : new Response('', {status: 404, statusText: 'Not Found'});
	};
});

afterEach(() => {
	globalThis.fetch = realFetch;
});

const repository = (baseUrl = 'https://photos.example.org/') =>
	new ImmichRepository(new APIClient({method: AuthMethod.API_KEY, baseUrl, apiKey: 'k3y'}));

describe('ImmichRepository with recorded responses', () => {
	test('the timeline: buckets, then one month with its 360° flags', async () => {
		const repo = repository();
		const buckets = await repo.getBuckets();
		assert.deepEqual(buckets, [{timeBucket: '2024-06-01', count: 3}, {timeBucket: '2023-12-01', count: 1}]);
		assert.equal(calls[0].url, 'https://photos.example.org/api/timeline/buckets?visibility=timeline&withPartners=true&withStacked=true');
		assert.equal(calls[0].headers['x-api-key'], 'k3y');

		const assets = await repo.getBucketAssets('2024-06-01');
		assert.equal(assets.length, 3);
		assert.deepEqual(assets.map((a) => a.type), ['IMAGE', 'IMAGE', 'VIDEO']);
		assert.deepEqual(assets.map((a) => a.projectionType), ['EQUIRECTANGULAR', null, null]);
		assert.equal(assets[0].localDateTime, '2024-06-15T10:10:00.000Z', 'local time from the offset');
		assert.equal(assets[2].durationSeconds, 12.5);
		assert.deepEqual(
			assets.map((a) => isShownAs360({isVideo: a.type === 'VIDEO', projectionType: a.projectionType})),
			[true, false, false]
		);
	});

	test('the details of a 360° photo, and how the viewer shows it', async () => {
		const details = await repository().getAssetDetails('7f1c2b8e-0d4f-4d1e-9a51-2a5b7c3e9f10');
		assert.deepEqual(details, {
			id: '7f1c2b8e-0d4f-4d1e-9a51-2a5b7c3e9f10',
			type: 'IMAGE',
			originalFileName: 'IMG_20240615_101000_00_042.jpg',
			originalMimeType: 'image/jpeg',
			width: 11904,
			height: 5952,
			make: 'Arashi Vision',
			model: 'Insta360 X4',
			projectionType: 'EQUIRECTANGULAR',
			fileSize: 18734512,
		});
		assert.deepEqual(resolveSphereView({fileName: details.originalFileName, width: details.width, height: details.height}), {
			layout: 'mono',
			coverage: 'full',
			coverageGuess: 'full',
		});
	});

	test('a VR180 photo the server does not flag: shown as 360° once chosen, as a half sphere', async () => {
		const details = await repository().getAssetDetails('9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d');
		assert.equal(isShownAs360({isVideo: false, projectionType: details.projectionType, name: details.originalFileName, make: details.make, model: details.model, width: details.width, height: details.height}), false);
		assert.equal(isShownAs360({isVideo: false, forced: true, projectionType: details.projectionType}), true);
		assert.deepEqual(resolveSphereView({fileName: details.originalFileName, width: details.width, height: details.height}), {
			layout: 'leftRight',
			coverage: 'half',
			coverageGuess: 'half',
		});
	});

	test('media URLs carry the credentials, the preview bytes come without headers', async () => {
		const repo = repository('https://photos.example.org/api');
		assert.equal(repo.previewUrl('abc'), 'https://photos.example.org/api/assets/abc/thumbnail?size=preview&edited=true&apiKey=k3y');
		assert.equal(repo.videoPlaybackUrl('abc'), 'https://photos.example.org/api/assets/abc/video/playback?apiKey=k3y');
		const bytes = new Uint8Array(await repo.fetchPreviewBytes('abc'));
		assert.deepEqual(Array.from(bytes), [0xff, 0xd8, 0xff, 0xd9]);
		assert.deepEqual(calls.at(-1).headers, {});
		assert.equal(repo.serverUrl(), 'https://photos.example.org/api');
	});

	test('the server version, and null when the server does not answer it', async () => {
		assert.equal(await repository().getServerVersion(), 'v3.3.0');
		globalThis.fetch = async () => new Response('', {status: 500, statusText: 'Server Error'});
		assert.equal(await repository().getServerVersion(), null);
	});

	test('an unknown asset is an API error with its status', async () => {
		await assert.rejects(repository().getAssetDetails('nope'), (error) => error.name === 'APIError' && error.status === 404);
	});
});
