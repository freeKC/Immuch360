'use strict';
/* global Buffer */
// An RTSP client for camera streams: TCP interleaved transport (no UDP port to open on the TV), Digest or Basic
// authentication, DESCRIBE, SETUP of the video track, PLAY, and GET_PARAMETER every 25 s to keep the session. The RTP
// packets of the video come out through onRtp(packet). Core modules only, from Node 8.

const net = require('net');
const crypto = require('crypto');
const urlLib = require('url');

const md5 = (text) => crypto.createHash('md5').update(text).digest('hex');

function parseChallenge(header) {
	const value = String(header || '');
	const field = (name) => {
		const match = new RegExp(name + '\\s*=\\s*"([^"]*)"').exec(value) || new RegExp(name + '\\s*=\\s*([^,\\s]+)').exec(value);
		return match ? match[1] : null;
	};
	if (/^Digest/i.test(value)) return {scheme: 'digest', realm: field('realm') || '', nonce: field('nonce') || '', qop: /qop\s*=\s*"?[^"]*auth/i.test(value), opaque: field('opaque')};
	if (/^Basic/i.test(value)) return {scheme: 'basic'};
	return null;
}

/** The Authorization header of a request, from the camera's challenge */
function authorization(challenge, user, password, method, uri, nc) {
	if (!challenge) return null;
	if (challenge.scheme === 'basic') return 'Basic ' + Buffer.from(user + ':' + password, 'utf8').toString('base64');
	const ha1 = md5(user + ':' + challenge.realm + ':' + password);
	const ha2 = md5(method + ':' + uri);
	let header = 'Digest username="' + user + '", realm="' + challenge.realm + '", nonce="' + challenge.nonce + '", uri="' + uri + '"';
	if (challenge.qop) {
		const count = ('0000000' + nc.toString(16)).slice(-8);
		const cnonce = crypto.randomBytes(8).toString('hex');
		header += ', qop=auth, nc=' + count + ', cnonce="' + cnonce + '", response="' + md5(ha1 + ':' + challenge.nonce + ':' + count + ':' + cnonce + ':auth:' + ha2) + '"';
	} else {
		header += ', response="' + md5(ha1 + ':' + challenge.nonce + ':' + ha2) + '"';
	}
	if (challenge.opaque) header += ', opaque="' + challenge.opaque + '"';
	return header;
}

/** The video track of an SDP: {codec, control, payloadType, sprop: [sps, pps] | null}, null without video */
function parseSdp(sdp) {
	const sections = ('\n' + String(sdp)).split(/\r?\nm=/);
	const video = sections.slice(1).filter((s) => /^video\s/.test(s))[0];
	if (!video) return null;
	const payloadType = Number((/^video\s+\d+\s+\S+\s+(\d+)/.exec(video) || [])[1]);
	const rtpmap = new RegExp('a=rtpmap:' + payloadType + '\\s+([^/\\s]+)').exec(video) || /a=rtpmap:\d+\s+([^/\s]+)/.exec(video);
	const control = (/a=control:\s*(\S+)/.exec(video) || [])[1] || null;
	const sprop = (/sprop-parameter-sets=([^;\s]+)/.exec(video) || [])[1];
	const sets = sprop ? sprop.split(',').map((p) => Buffer.from(p, 'base64')).filter((b) => b.length) : null;
	return {codec: rtpmap ? rtpmap[1].toUpperCase() : null, control: control, payloadType: payloadType, sprop: sets && sets.length >= 2 ? sets : null};
}

function trackUrl(base, control) {
	if (!control || control === '*') return base;
	if (/^rtsp:\/\//i.test(control)) return control;
	return base.replace(/\/?$/, '/') + control;
}

class RtspClient {
	/** url without credentials (rtsp://host:554/stream1), user and password of the camera account */
	constructor(url, user, password, options) {
		this.url = url;
		this.user = user || '';
		this.password = password || '';
		this.options = options || {};
		this.cseq = 0;
		this.nc = 0;
		this.challenge = null;
		this.session = null;
		this.pending = null;
		this.buffer = Buffer.alloc(0);
		this.onRtp = () => {};
		this.onClose = () => {};
		this.closed = false;
		this.keepAlive = null;
		this.bytesIn = 0;
	}

	connect() {
		const parsed = urlLib.parse(this.url);
		return new Promise((resolve, reject) => {
			const socket = net.connect(Number(parsed.port || 554), parsed.hostname);
			this.socket = socket;
			const timer = setTimeout(() => {
				socket.destroy();
				reject(Object.assign(new Error('The camera does not answer'), {code: 'unreachable'}));
			}, this.options.connectTimeoutMs || 8000);
			socket.once('connect', () => {
				clearTimeout(timer);
				socket.setNoDelay(true);
				resolve();
			});
			socket.on('data', (data) => {
				this.bytesIn += data.length;
				this.buffer = this.buffer.length ? Buffer.concat([this.buffer, data]) : data;
				this.drain();
			});
			socket.on('error', (err) => {
				clearTimeout(timer);
				if (this.pending) this.pending.reject(err);
				this.pending = null;
				reject(err);
			});
			socket.on('close', () => {
				this.closed = true;
				if (this.keepAlive) clearInterval(this.keepAlive);
				if (this.pending) this.pending.reject(new Error('The camera closed the connection'));
				this.pending = null;
				this.onClose();
			});
		});
	}

	drain() {
		for (;;) {
			if (this.buffer.length < 4) return;
			if (this.buffer[0] === 0x24) {
				const size = this.buffer.readUInt16BE(2);
				if (this.buffer.length < 4 + size) return;
				const channel = this.buffer[1];
				const packet = this.buffer.slice(4, 4 + size);
				this.buffer = this.buffer.slice(4 + size);
				if (channel === 0) this.onRtp(packet);
				continue;
			}
			const end = this.buffer.indexOf('\r\n\r\n');
			if (end < 0) {
				if (this.buffer.length > 65536) this.buffer = Buffer.alloc(0);
				return;
			}
			const head = this.buffer.slice(0, end).toString('utf8').split('\r\n');
			if (!/^RTSP\/1\.0\s/.test(head[0])) {
				// Not an answer nor a packet: resynchronise on the next '$' or 'RTSP'
				const next = this.buffer.indexOf(0x24, 1);
				this.buffer = next > 0 ? this.buffer.slice(next) : Buffer.alloc(0);
				continue;
			}
			const headers = {};
			head.slice(1).forEach((line) => {
				const colon = line.indexOf(':');
				if (colon > 0) headers[line.slice(0, colon).trim().toLowerCase()] = line.slice(colon + 1).trim();
			});
			const length = Number(headers['content-length'] || 0);
			if (this.buffer.length < end + 4 + length) return;
			const body = this.buffer.slice(end + 4, end + 4 + length).toString('utf8');
			this.buffer = this.buffer.slice(end + 4 + length);
			const pending = this.pending;
			this.pending = null;
			if (pending) pending.resolve({status: Number(head[0].split(' ')[1]), headers: headers, body: body});
		}
	}

	send(method, uri, extra) {
		return new Promise((resolve, reject) => {
			if (this.closed) {
				reject(new Error('The camera closed the connection'));
				return;
			}
			this.pending = {resolve: resolve, reject: reject};
			let message = method + ' ' + uri + ' RTSP/1.0\r\nCSeq: ' + ++this.cseq + '\r\nUser-Agent: Immuch360 webOS\r\n';
			const auth = authorization(this.challenge, this.user, this.password, method, uri, ++this.nc);
			if (auth) message += 'Authorization: ' + auth + '\r\n';
			if (this.session) message += 'Session: ' + this.session + '\r\n';
			Object.keys(extra || {}).forEach((name) => {
				message += name + ': ' + extra[name] + '\r\n';
			});
			this.socket.write(message + '\r\n');
		});
	}

	/** A request, answered once more with the credentials when the camera asks for them */
	request(method, uri, extra) {
		return this.send(method, uri, extra).then((answer) => {
			if (answer.status === 401 && !answer.retried) {
				const challenge = parseChallenge(answer.headers['www-authenticate']);
				if (!challenge || (this.challenge && this.challenge.nonce === challenge.nonce && !/stale\s*=\s*true/i.test(answer.headers['www-authenticate'] || ''))) {
					throw Object.assign(new Error('The camera refused the user name or the password'), {code: 'auth'});
				}
				this.challenge = challenge;
				return this.send(method, uri, extra).then((second) => {
					if (second.status === 401) throw Object.assign(new Error('The camera refused the user name or the password'), {code: 'auth'});
					return second;
				});
			}
			return answer;
		}).then((answer) => {
			if (answer.status !== 200) throw Object.assign(new Error(method + ' answered ' + answer.status), {code: 'rtsp_' + answer.status});
			return answer;
		});
	}

	/** OPTIONS, DESCRIBE, SETUP of the video track and PLAY: resolves with the track of the SDP */
	start() {
		return this.connect()
			.then(() => this.request('OPTIONS', this.url))
			.then(() => this.request('DESCRIBE', this.url, {Accept: 'application/sdp'}))
			.then((answer) => {
				const base = answer.headers['content-base'] || answer.headers['content-location'] || this.url;
				const track = parseSdp(answer.body);
				if (!track) throw Object.assign(new Error('The camera sends no video'), {code: 'no_video'});
				this.base = base;
				this.track = track;
				return this.request('SETUP', trackUrl(base, track.control), {Transport: 'RTP/AVP/TCP;unicast;interleaved=0-1'});
			})
			.then((answer) => {
				this.session = String(answer.headers.session || '').split(';')[0] || null;
				return this.request('PLAY', this.base, {Range: 'npt=0.000-'});
			})
			.then(() => {
				this.keepAlive = setInterval(() => {
					this.request('GET_PARAMETER', this.base).catch(() => {});
				}, this.options.keepAliveMs || 25000);
				return this.track;
			});
	}

	close() {
		if (this.keepAlive) clearInterval(this.keepAlive);
		this.keepAlive = null;
		if (!this.socket || this.closed) return;
		try {
			if (this.session) this.socket.write('TEARDOWN ' + (this.base || this.url) + ' RTSP/1.0\r\nCSeq: ' + ++this.cseq + '\r\nSession: ' + this.session + '\r\n\r\n');
		} catch (e) {
			// The camera may have gone
		}
		this.socket.destroy();
	}
}

module.exports = {RtspClient, parseSdp, parseChallenge, authorization, trackUrl};
