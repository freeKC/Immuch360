'use strict';
/* global Buffer */
const test = require('node:test');
const assert = require('node:assert');
const net = require('node:net');
const crypto = require('node:crypto');
const h264 = require('../src/live/h264');
const fmp4 = require('../src/live/fmp4');
const rtsp = require('../src/live/rtsp');
const {LiveSession} = require('../src/live/session');
const {fetchRaw, startBridge} = require('./helpers');

// Real parameter sets of libx264 (ffmpeg testsrc2), 640x360 and 2304x1296 (a Tapo C510W's HD stream)
const SPS_360 = Buffer.from('67640016acb405017fcb8088000003000800000300f478b175', 'hex');
const SPS_1296 = Buffer.from('67640032acb40120051d8088000003000800000300f478c195', 'hex');
const PPS = Buffer.from('68ef0fcb', 'hex');

function rtpPacket(seq, ts, marker, payload) {
	const header = Buffer.alloc(12);
	header[0] = 0x80;
	header[1] = (marker ? 0x80 : 0) | 96;
	header.writeUInt16BE(seq & 0xffff, 2);
	header.writeUInt32BE(ts >>> 0, 4);
	header.writeUInt32BE(0x1234, 8);
	return Buffer.concat([header, payload]);
}

/** The RTP packets of one frame: an IDR split in FU-A (with SPS and PPS before it in a STAP-A), or a P slice */
function framePackets(seqStart, ts, key) {
	const packets = [];
	let seq = seqStart;
	if (key) {
		const stap = Buffer.concat([Buffer.from([24]), Buffer.from([0, SPS_360.length]), SPS_360, Buffer.from([0, PPS.length]), PPS]);
		packets.push(rtpPacket(seq++, ts, false, stap));
		const idr = Buffer.concat([Buffer.from([0x65]), crypto.randomBytes(3000)]);
		const body = idr.slice(1);
		for (let at = 0; at < body.length; at += 1000) {
			const start = at === 0 ? 0x80 : 0;
			const end = at + 1000 >= body.length ? 0x40 : 0;
			packets.push(rtpPacket(seq++, ts, !!end, Buffer.concat([Buffer.from([(0x65 & 0xe0) | 28, start | end | 5]), body.slice(at, at + 1000)])));
		}
	} else {
		packets.push(rtpPacket(seq++, ts, true, Buffer.concat([Buffer.from([0x41]), crypto.randomBytes(400)])));
	}
	return packets;
}

/** A camera shaped RTSP server: Digest only, one H.264 track with sprop, frames at 15 fps, a key frame every 10 */
function startCamera(options) {
	const opts = options || {};
	const state = {auth: [], methods: []};
	const realm = 'IP Camera';
	const nonce = 'abc123';
	const server = net.createServer((socket) => {
		let buffer = '';
		let timer = null;
		socket.on('data', (data) => {
			buffer += data.toString('latin1');
			let end;
			while ((end = buffer.indexOf('\r\n\r\n')) >= 0) {
				const head = buffer.slice(0, end).split('\r\n');
				buffer = buffer.slice(end + 4);
				const [method, uri] = head[0].split(' ');
				const headers = {};
				head.slice(1).forEach((l) => {
					const i = l.indexOf(':');
					headers[l.slice(0, i).toLowerCase()] = l.slice(i + 1).trim();
				});
				state.methods.push(method);
				const cseq = headers.cseq;
				const reply = (status, extra, body) => {
					let text = `RTSP/1.0 ${status}\r\nCSeq: ${cseq}\r\n`;
					Object.keys(extra || {}).forEach((k) => (text += `${k}: ${extra[k]}\r\n`));
					if (body) text += `Content-Length: ${Buffer.byteLength(body)}\r\n`;
					socket.write(text + '\r\n' + (body || ''));
				};
				const auth = headers.authorization;
				if (auth) state.auth.push(auth);
				const user = /username="([^"]*)"/.exec(auth || '');
				const response = /response="([^"]*)"/.exec(auth || '');
				const md5 = (s) => crypto.createHash('md5').update(s).digest('hex');
				const expected = md5(md5(`camuser:${realm}:${opts.password || 'campass1'}`) + `:${nonce}:` + md5(`${method}:${uri}`));
				if (!user || !response || response[1] !== expected) {
					reply('401 Unauthorized', {'WWW-Authenticate': `Digest realm="${realm}", nonce="${nonce}"`});
					continue;
				}
				if (method === 'OPTIONS') reply('200 OK', {Public: 'OPTIONS, DESCRIBE, SETUP, PLAY, GET_PARAMETER, TEARDOWN'});
				else if (method === 'DESCRIBE') {
					const sdp = `v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=Session\r\nt=0 0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 ${opts.codec || 'H264'}/90000\r\na=fmtp:96 packetization-mode=1;profile-level-id=640016;sprop-parameter-sets=${SPS_360.toString('base64')},${PPS.toString('base64')}\r\na=control:track1\r\nm=audio 0 RTP/AVP 8\r\na=rtpmap:8 PCMA/8000\r\na=control:track2\r\n`;
					reply('200 OK', {'Content-Type': 'application/sdp', 'Content-Base': uri + '/'}, sdp);
				} else if (method === 'SETUP') {
					state.setup = uri;
					reply('200 OK', {Session: '12345678;timeout=60', Transport: 'RTP/AVP/TCP;unicast;interleaved=0-1'});
				} else if (method === 'PLAY') {
					reply('200 OK', {Session: '12345678'});
					let frame = 0;
					let seq = 1;
					timer = setInterval(() => {
						const packets = framePackets(seq, frame * 6000, frame % 10 === 0);
						seq += packets.length;
						frame++;
						packets.forEach((p) => {
							const head = Buffer.from([0x24, 0, 0, 0]);
							head.writeUInt16BE(p.length, 2);
							socket.write(Buffer.concat([head, p]));
						});
					}, 1000 / 60);
				} else reply('200 OK', {Session: '12345678'});
			}
		});
		socket.on('close', () => clearInterval(timer));
		socket.on('error', () => clearInterval(timer));
	});
	return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({port: server.address().port, state, close: () => new Promise((r) => server.close(r)), server})));
}

test('the SPS gives the picture size and the codec string', () => {
	assert.deepStrictEqual(h264.spsSize(SPS_360), {width: 640, height: 360});
	assert.deepStrictEqual(h264.spsSize(SPS_1296), {width: 2304, height: 1296});
	assert.strictEqual(h264.codecString(SPS_360), 'avc1.640016');
});

test('single NAL units, STAP-A and FU-A become access units; a lost packet drops the frame being cut', () => {
	const units = [];
	const d = new h264.Depacketizer((au) => units.push(au));
	framePackets(1, 0, true).forEach((p) => d.push(p));
	framePackets(5, 6000, false).forEach((p) => d.push(p));
	assert.strictEqual(units.length, 2);
	assert.deepStrictEqual(units[0].nals.map(h264.nalType), [7, 8, 5]);
	assert.strictEqual(units[0].nals[2].length, 3001);
	assert.deepStrictEqual(units[1].nals.map(h264.nalType), [1]);
	const key = framePackets(6, 12000, true);
	key.splice(2, 1);
	key.forEach((p) => d.push(p));
	assert.strictEqual(d.lost, 1);
	assert.deepStrictEqual(units[2].nals.map(h264.nalType), [7, 8]);
});

test('the init segment and the fragments are well formed boxes', () => {
	const init = fmp4.initSegment(SPS_360, PPS, {width: 640, height: 360});
	assert.deepStrictEqual(fmp4.topBoxes(init).map((b) => b.type), ['ftyp', 'moov']);
	assert.ok(init.indexOf('avcC') > 0);
	const frag = fmp4.fragment(1, 9000, 6000, true, [Buffer.from([0x65, 1, 2, 3])]);
	assert.deepStrictEqual(fmp4.topBoxes(frag).map((b) => b.type), ['moof', 'mdat']);
	const moofSize = frag.readUInt32BE(0);
	// trun's data offset points at the first byte of the sample, right after the mdat header
	const trun = frag.indexOf('trun');
	assert.strictEqual(frag.readUInt32BE(trun + 12), moofSize + 8);
	assert.strictEqual(frag.readUInt32BE(moofSize + 8), 4);
});

test('SDP and Digest answers are read', () => {
	const track = rtsp.parseSdp(`v=0\r\nm=audio 0 RTP/AVP 8\r\na=control:track2\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H265/90000\r\na=control:rtsp://h/x/track1\r\n`);
	assert.deepStrictEqual(track, {codec: 'H265', control: 'rtsp://h/x/track1', payloadType: 96, sprop: null});
	assert.strictEqual(rtsp.trackUrl('rtsp://h/s/', 'track1'), 'rtsp://h/s/track1');
	assert.strictEqual(rtsp.trackUrl('rtsp://h/s', 'rtsp://h/s/t'), 'rtsp://h/s/t');
	const challenge = rtsp.parseChallenge('Digest realm="r", nonce="n", qop="auth"');
	assert.deepStrictEqual(challenge, {scheme: 'digest', realm: 'r', nonce: 'n', qop: true, opaque: null});
	assert.match(rtsp.authorization(challenge, 'u', 'p', 'DESCRIBE', 'rtsp://h/', 1), /qop=auth, nc=00000001, cnonce="[0-9a-f]{16}", response="[0-9a-f]{32}"/);
});

test('a live session turns the camera stream into an init segment, fragments and an HLS playlist', async (t) => {
	const camera = await startCamera();
	const session = new LiveSession({url: `rtsp://127.0.0.1:${camera.port}/stream1`, user: 'camuser', password: 'campass1'});
	t.after(() => {
		session.end(null);
		return camera.close();
	});
	session.start();
	await session.ready();
	assert.strictEqual(session.codec, 'avc1.640016');
	assert.deepStrictEqual(session.size, {width: 640, height: 360});
	assert.strictEqual(camera.state.setup, `rtsp://127.0.0.1:${camera.port}/stream1/track1`);
	const frames = [];
	const remove = session.addViewer((f) => frames.push(f));
	await new Promise((r) => setTimeout(r, 700));
	remove();
	assert.ok(frames.length >= 20, `frames ${frames.length}`);
	frames.forEach((f) => assert.deepStrictEqual(fmp4.topBoxes(f).map((b) => b.type), ['moof', 'mdat']));
	const playlist = session.playlist();
	assert.match(playlist, /#EXT-X-MAP:URI="init.mp4"/);
	assert.match(playlist, /seg\d+\.m4s/);
	assert.ok(camera.state.auth.every((a) => !a.includes('campass1')), 'the password never goes in clear');
});

test('a wrong password is said once, without trying again and again', async (t) => {
	const camera = await startCamera({password: 'other'});
	const session = new LiveSession({url: `rtsp://127.0.0.1:${camera.port}/stream1`, user: 'camuser', password: 'campass1'});
	t.after(() => camera.close());
	session.start();
	await assert.rejects(session.ready(), (e) => e.code === 'auth');
	assert.ok(camera.state.methods.length <= 2, camera.state.methods.join(','));
});

test('an H.265 camera is told apart', async (t) => {
	const camera = await startCamera({codec: 'H265'});
	const session = new LiveSession({url: `rtsp://127.0.0.1:${camera.port}/stream1`, user: 'camuser', password: 'campass1'});
	t.after(() => camera.close());
	session.start();
	await assert.rejects(session.ready(), (e) => e.code === 'h265');
});

test('the bridge streams fragmented MP4 to MSE, with the codec in a header, and HLS', async (t) => {
	const camera = await startCamera();
	const b = await startBridge([{id: 'cam', kind: 'tapo', host: '127.0.0.1', port: camera.port, user: 'camuser', password: 'campass1'}]);
	t.after(() => {
		b.stop();
		return camera.close();
	});
	const http = require('node:http');
	const got = await new Promise((resolve, reject) => {
		const req = http.get(`${b.base}/live/cam/hd/stream.mp4`, (res) => {
			const chunks = [];
			let size = 0;
			res.on('data', (c) => {
				chunks.push(c);
				size += c.length;
				if (size > 60000) {
					req.destroy();
					resolve({status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks)});
				}
			});
		});
		req.on('error', reject);
	});
	assert.strictEqual(got.status, 200);
	assert.strictEqual(got.headers['x-immuch-codec'], 'avc1.640016');
	assert.strictEqual(got.headers['access-control-allow-origin'], '*');
	const types = fmp4.topBoxes(got.body).map((x) => x.type);
	assert.deepStrictEqual(types.slice(0, 4), ['ftyp', 'moov', 'moof', 'mdat']);
	const playlist = await fetchRaw(`${b.base}/live/cam/hd/index.m3u8`);
	assert.strictEqual(playlist.status, 200);
	const seg = /seg(\d+)\.m4s/.exec(playlist.body.toString());
	assert.ok(seg);
	const segment = await fetchRaw(`${b.base}/live/cam/hd/seg${seg[1]}.m4s`);
	assert.strictEqual(segment.status, 200);
	assert.strictEqual(fmp4.topBoxes(segment.body)[0].type, 'moof');
	const init = await fetchRaw(`${b.base}/live/cam/hd/init.mp4`);
	assert.strictEqual(fmp4.topBoxes(init.body)[1].type, 'moov');
});
