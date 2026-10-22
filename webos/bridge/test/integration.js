'use strict';
// Integration test of the bundled bridge (service/bridge/base.js and smb.js) against real servers: run on the build
// host inside the Node images of the TVs (8.12.0, 12.21.0, 16.19.1, 20.12.2), on the Docker network of the fixtures
// (a WebDAV server, minidlna, an unclaimed Plex Media Server, three Samba setups, mediamtx with camera shaped streams).
// Plain Node 8 JavaScript: no test runner. Prints one JSON line per check and exits 1 when one fails.
//
//   node bridge/test/integration.js            env: BUNDLE (base.js), SMB_HOSTS, MEDIA (the Samba share's files),
//                                               LIVE_OUT (where to write the live stream), WEBDAV, PLEX_HOST, RTSP_HOST

const http = require('http');
const fs = require('fs');
const path = require('path');

const BUNDLE = process.env.BUNDLE || path.join(__dirname, '..', '..', 'service', 'bridge', 'base.js');
const major = Number(process.versions.node.split('.')[0]);
const results = [];

function get(url, headers, limit) {
	return new Promise((resolve, reject) => {
		// http.get(url, options, callback) needs Node 10.9: the TVs' Node 8 takes one options object
		const options = Object.assign(require('url').parse(url), {headers: headers || {}});
		const req = http.get(options, (res) => {
			const parts = [];
			let size = 0;
			res.on('data', (d) => {
				parts.push(d);
				size += d.length;
				if (limit && size >= limit) {
					req.abort();
					resolve({status: res.statusCode, headers: res.headers, body: Buffer.concat(parts)});
				}
			});
			res.on('end', () => resolve({status: res.statusCode, headers: res.headers, body: Buffer.concat(parts)}));
		});
		req.on('error', (e) => (limit ? null : reject(e)));
	});
}

function json(url) {
	return get(url).then((r) => {
		const value = JSON.parse(r.body.toString('utf8'));
		if (r.status !== 200) throw new Error('HTTP ' + r.status + ' ' + (value.error || ''));
		return value;
	});
}

async function check(name, fn) {
	const started = Date.now();
	try {
		const detail = await fn();
		results.push({check: name, ok: true, ms: Date.now() - started, detail: detail});
	} catch (e) {
		results.push({check: name, ok: false, ms: Date.now() - started, error: String((e && e.message) || e)});
	}
	console.log(JSON.stringify(Object.assign({node: process.version}, results[results.length - 1])));
}

function assert(cond, message) {
	if (!cond) throw new Error(message);
}

function boxes(buf) {
	const out = [];
	let at = 0;
	while (at + 8 <= buf.length) {
		const size = buf.readUInt32BE(at);
		if (size < 8) break;
		out.push(buf.toString('ascii', at + 4, at + 8));
		at += size;
	}
	return out;
}

async function walkDlna(base, id, depth, found) {
	const listing = await json(base + '/list?s=dlna&r=' + encodeURIComponent(id));
	listing.files.forEach((f) => {
		if (f.kind === 'image' && !found.image) found.image = f;
		if (f.kind === 'video' && !found.video) found.video = f;
	});
	if (found.image && found.video) return found;
	for (const folder of listing.folders) {
		if (depth > 0) await walkDlna(base, folder.ref, depth - 1, found);
		if (found.image && found.video) break;
	}
	return found;
}

async function main() {
	const lib = require(BUNDLE);
	const bridge = lib.createBridge({log: () => {}});
	const info = await bridge.start();
	const base = 'http://127.0.0.1:' + info.port + '/' + info.token;
	const smbHosts = (process.env.SMB_HOSTS || 'soon-samba-default,soon-samba-signing,soon-samba-smb3enc').split(',').filter(Boolean);
	const sources = [
		{id: 'dav', kind: 'webdav', url: process.env.WEBDAV || 'http://soon-webdav:8080', user: 'tester', password: 'testpass'},
		{id: 'cam', kind: 'tapo', host: process.env.RTSP_HOST || 'soon-webos-mtx', port: 8554, user: 'camuser', password: 'campass1'},
		{id: 'camwrong', kind: 'tapo', host: process.env.RTSP_HOST || 'soon-webos-mtx', port: 8554, user: 'camuser', password: 'wrong'}
	].concat(smbHosts.map((host, i) => ({id: 'smb' + i, kind: 'smb', host: host, share: 'media', user: 'tester', password: 'testpass'})));
	bridge.setSources(sources);

	await check('token refused', async () => {
		const r = await get('http://127.0.0.1:' + info.port + '/status');
		assert(r.status === 404, 'status ' + r.status);
	});

	await check('webdav list and range', async () => {
		const root = await json(base + '/list?s=dav&r=');
		assert(root.folders.some((f) => f.name === 'Photos'), 'no Photos folder');
		const photos = await json(base + '/list?s=dav&r=Photos');
		const theta = photos.files.filter((f) => f.name === 'theta 360.jpg')[0];
		assert(theta && photos.files.some((f) => f.name === 'équirect 360.jpg'), 'files ' + photos.files.map((f) => f.name));
		const meta = await json(base + '/meta?s=dav&r=' + encodeURIComponent(theta.ref));
		assert(meta.projection === 'equirectangular' && meta.width === 6080, JSON.stringify(meta));
		const thumb = await get(base + '/thumb?s=dav&r=' + encodeURIComponent(theta.ref));
		assert(thumb.status === 200 && thumb.body.length === 4112, 'thumb ' + thumb.status + ' ' + thumb.body.length);
		const videos = await json(base + '/list?s=dav&r=Videos');
		const video = videos.files.filter((f) => f.kind === 'video')[0];
		const r = await get(base + '/file?s=dav&r=' + encodeURIComponent(video.ref), {Range: 'bytes=1000000-1065535'});
		assert(r.status === 206 && r.body.length === 65536, 'range ' + r.status + ' ' + r.body.length);
		const direct = await get('http://' + (process.env.WEBDAV_HOSTPORT || 'soon-webdav:8080') + '/Videos/' + encodeURIComponent(video.name), {
			Range: 'bytes=1000000-1065535',
			Authorization: 'Basic ' + Buffer.from('tester:testpass').toString('base64')
		});
		assert(direct.body.equals(r.body), 'bytes differ');
		const cpu0 = process.cpuUsage();
		const whole = await get(base + '/file?s=dav&r=' + encodeURIComponent(video.ref));
		const cpu = process.cpuUsage(cpu0);
		return {videoBytes: whole.body.length, cpuMsPerMiB: +((cpu.user + cpu.system) / 1000 / (whole.body.length / 1048576)).toFixed(2), note: 'cpu of client and bridge together'};
	});

	await check('dlna discovery, browse and range', async () => {
		const found = await bridge.control('discover', {kind: 'dlna', ms: 2500});
		const server = found.servers.filter((s) => s.name === 'SoonDLNA')[0];
		assert(server, 'not found: ' + JSON.stringify(found.servers));
		bridge.setSources(sources.concat([{id: 'dlna', kind: 'dlna', location: server.location}]));
		const media = await walkDlna(base, '0', 4, {});
		assert(media.image && media.video, 'no media found');
		const r = await get(base + '/file?s=dlna&r=' + encodeURIComponent(media.video.ref), {Range: 'bytes=0-65535'});
		assert(r.status === 206 && r.body.length === 65536, 'range ' + r.status);
		const thumb = media.image.thumb ? await get(base + '/thumb?s=dlna&r=x&t=' + encodeURIComponent(media.image.thumb)) : {status: 'none'};
		return {location: server.location, image: media.image.name, video: media.video.name, thumb: thumb.status};
	});

	await check('plex discovery, libraries, media, photo transcode, hls', async () => {
		const found = await bridge.control('discover', {kind: 'plex', ms: 2500});
		const server = found.servers[0];
		assert(server, 'no Plex server answered GDM');
		const probe = await bridge.control('plexProbe', {address: server.address, port: server.port});
		bridge.setSources(sources.concat([{id: 'plex', kind: 'plex', address: server.address, port: server.port, hash: null, token: null}]));
		const root = await json(base + '/list?s=plex&r=');
		assert(root.folders.length >= 1, 'no library');
		let image = null;
		let video = null;
		for (const section of root.folders) {
			const listing = await json(base + '/list?s=plex&r=' + encodeURIComponent(section.ref));
			const files = listing.files.slice();
			for (const folder of listing.folders.slice(0, 3)) {
				const inner = await json(base + '/list?s=plex&r=' + encodeURIComponent(folder.ref));
				Array.prototype.push.apply(files, inner.files);
			}
			image = image || files.filter((f) => f.kind === 'image')[0];
			video = video || files.filter((f) => f.kind === 'video')[0];
		}
		assert(image && video, 'image ' + !!image + ' video ' + !!video);
		const r = await get(base + '/file?s=plex&r=' + encodeURIComponent(video.ref), {Range: 'bytes=0-65535'});
		assert(r.status === 206 && r.body.length === 65536, 'range ' + r.status);
		const photo = await get(base + '/photo?s=plex&r=' + encodeURIComponent(image.ref) + '&w=1280&h=720');
		assert(photo.status === 200 && photo.body[0] === 0xff, 'photo ' + photo.status);
		const thumb = await get(base + '/thumb?s=plex&r=x&t=' + encodeURIComponent(image.thumb || image.ref));
		assert(thumb.status === 200, 'thumb ' + thumb.status);
		let hls = 'skipped';
		if (video.ratingKey) {
			const redirect = await get(base + '/hls?s=plex&k=' + video.ratingKey);
			assert(redirect.status === 302, 'hls ' + redirect.status);
			const master = await get('http://127.0.0.1:' + info.port + redirect.headers.location);
			hls = master.status + ' ' + master.body.toString('utf8').split('\n').filter((l) => l && l[0] !== '#')[0];
		}
		return {server: server.name, gdmHash: server.hash, probeHash: probe.hash, version: probe.identity && probe.identity.version, image: image.name, video: video.name, direct: video.direct, hls: hls};
	});

	if (major >= 12) {
		const expectedFd = fs.existsSync(process.env.MEDIA || '/media/video.bin') ? fs.openSync(process.env.MEDIA || '/media/video.bin', 'r') : null;
		for (let i = 0; i < smbHosts.length; i++) {
			await check('smb ' + smbHosts[i], async () => {
				const root = await json(base + '/list?s=smb' + i + '&r=');
				const names = root.folders.map((f) => f.name);
				assert(names.indexOf('été 2026') >= 0 && names.indexOf('many') >= 0, 'root ' + names);
				const manyStart = Date.now();
				const many = await json(base + '/list?s=smb' + i + '&r=many');
				const manyMs = Date.now() - manyStart;
				const unicode = await json(base + '/list?s=smb' + i + '&r=' + encodeURIComponent('été 2026'));
				const off = 200 * 1024 * 1024 + 12345;
				const r = await get(base + '/file?s=smb' + i + '&r=video.bin', {Range: 'bytes=' + off + '-' + (off + 65535 + 7)});
				assert(r.status === 206 && r.body.length === 65543, 'range ' + r.status + ' ' + r.body.length);
				if (expectedFd !== null) {
					const want = Buffer.alloc(65543);
					fs.readSync(expectedFd, want, 0, want.length, off);
					assert(want.equals(r.body), 'bytes differ');
				}
				const t0 = Date.now();
				const cpu0 = process.cpuUsage();
				const seq = await get(base + '/file?s=smb' + i + '&r=video.bin', {Range: 'bytes=0-' + (64 * 1048576 - 1)});
				const cpu = process.cpuUsage(cpu0);
				const sec = (Date.now() - t0) / 1000;
				assert(seq.body.length === 64 * 1048576, 'seq ' + seq.body.length);
				if (expectedFd !== null) {
					const want = Buffer.alloc(1048576);
					fs.readSync(expectedFd, want, 0, want.length, 63 * 1048576);
					assert(want.equals(seq.body.slice(63 * 1048576)), 'seq bytes differ');
				}
				const shares = await bridge.control('smbShares', {host: smbHosts[i], user: 'tester', password: 'testpass'});
				return {manyListMs: manyMs, manyMedia: many.files.length, unicode: unicode.files.map((f) => f.name).concat(unicode.folders.map((f) => f.name)).length, mibPerS: +(64 / sec).toFixed(1), cpuMsPerMiB: +((cpu.user + cpu.system) / 1000 / 64).toFixed(2), shares: shares.shares};
			});
		}
	} else {
		await check('smb refused below Node 12', async () => {
			const r = await get(base + '/list?s=smb0&r=');
			const body = JSON.parse(r.body.toString('utf8'));
			assert(r.status === 501 && body.code === 'smb_needs_node12', r.status + ' ' + body.code);
		});
	}

	await check('live view fMP4 for MSE, HD and SD', async () => {
		const out = {};
		for (const q of ['hd', 'sd']) {
			const t0 = Date.now();
			const r = await get(base + '/live/cam/' + q + '/stream.mp4', {}, q === 'hd' ? 2500000 : 500000);
			assert(r.status === 200, 'status ' + r.status);
			const types = boxes(r.body);
			assert(types[0] === 'ftyp' && types[1] === 'moov' && types[2] === 'moof', 'boxes ' + types.slice(0, 4));
			if (process.env.LIVE_OUT) fs.writeFileSync(path.join(process.env.LIVE_OUT, 'live-' + q + '-' + process.versions.node + '.mp4'), r.body);
			out[q] = {codec: r.headers['x-immuch-codec'], fragments: types.filter((t) => t === 'moof').length, ms: Date.now() - t0};
		}
		const playlist = await get(base + '/live/cam/hd/index.m3u8');
		assert(playlist.status === 200 && /seg\d+\.m4s/.test(playlist.body.toString()), 'playlist ' + playlist.status);
		const wrong = await get(base + '/live/camwrong/hd/stream.mp4');
		const wrongBody = JSON.parse(wrong.body.toString('utf8'));
		assert(wrong.status === 502 && wrongBody.code === 'auth', 'wrong password ' + wrong.status + ' ' + wrongBody.code);
		out.status = bridge.status().live;
		return out;
	});

	const status = bridge.status();
	results.push({check: 'process', ok: true, detail: {rssMiB: Math.round(status.rss / 1048576), cpuMs: status.cpuMs}});
	console.log(JSON.stringify({node: process.version, check: 'process', rssMiB: Math.round(status.rss / 1048576)}));
	bridge.stop();
	const failed = results.filter((r) => !r.ok).length;
	console.log(JSON.stringify({node: process.version, summary: failed ? failed + ' failed' : 'all passed', checks: results.length}));
	process.exit(failed ? 1 : 0);
}

main().catch((e) => {
	console.log(JSON.stringify({node: process.version, fatal: String((e && e.stack) || e)}));
	process.exit(1);
});
