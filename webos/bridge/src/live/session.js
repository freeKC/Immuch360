'use strict';
/* global Buffer */
// The live view of a camera: one RTSP session per camera and quality, shared by its viewers, made into fragmented
// MP4. A viewer through Media Source Extensions gets the init segment, the frames from the last key frame, then every
// new frame (stream.mp4); the HLS fallback gets a sliding playlist of segments of one GOP each (index.m3u8). The
// session ends a while after its last viewer.

const h264 = require('./h264');
const fmp4 = require('./fmp4');
const rtspLib = require('./rtsp');

const KEEP_SEGMENTS = 6;
const IDLE_STOP_MS = 15000;
const FIRST_FRAME_TIMEOUT_MS = 15000;

class LiveSession {
	constructor(options) {
		this.url = options.url;
		this.user = options.user;
		this.password = options.password;
		this.createClient = options.createClient || ((url, user, password) => new rtspLib.RtspClient(url, user, password));
		this.onEnd = options.onEnd || (() => {});
		this.viewers = [];
		this.waiting = [];
		this.init = null;
		this.codec = null;
		this.size = null;
		this.gop = [];
		this.segments = [];
		this.segmentSeq = 0;
		this.current = null;
		this.sequence = 0;
		this.firstTs = null;
		this.previous = null;
		this.wrap = 0;
		this.lastRaw = null;
		this.sps = null;
		this.pps = null;
		this.error = null;
		this.ended = false;
		this.lastHlsTouch = 0;
		this.idleTimer = null;
		this.stats = {frames: 0, keyFrames: 0, lost: 0, startedAt: Date.now()};
	}

	start() {
		this.client = this.createClient(this.url, this.user, this.password);
		this.client.onClose = () => this.end(this.error || new Error('The camera closed the connection'));
		const depacketizer = new h264.Depacketizer((au) => this.onAccessUnit(au));
		this.depacketizer = depacketizer;
		this.client.onRtp = (packet) => depacketizer.push(packet);
		this.firstFrameTimer = setTimeout(() => {
			if (!this.init) this.end(Object.assign(new Error('The camera sent no picture'), {code: 'no_picture'}));
		}, FIRST_FRAME_TIMEOUT_MS);
		this.client.start().then(
			(track) => {
				if (track.codec !== 'H264') {
					this.end(Object.assign(new Error('The camera sends ' + track.codec + ', not H.264'), {code: track.codec === 'H265' ? 'h265' : 'codec'}));
					return;
				}
				if (track.sprop) {
					this.sps = track.sprop[0];
					this.pps = track.sprop[1];
				}
			},
			(err) => this.end(err)
		);
		this.scheduleIdleCheck();
	}

	onAccessUnit(au) {
		au.nals.forEach((nal) => {
			const type = h264.nalType(nal);
			if (type === 7) this.sps = nal;
			if (type === 8) this.pps = nal;
		});
		if (this.lastRaw !== null && au.ts < this.lastRaw && this.lastRaw - au.ts > 0x80000000) this.wrap += 4294967296;
		this.lastRaw = au.ts;
		au.ts += this.wrap;
		if (this.firstTs === null) this.firstTs = au.ts;
		// A frame is written once the next one tells its duration
		if (this.previous) this.emit(this.previous, au.ts);
		this.previous = au;
	}

	emit(au, nextTs) {
		const key = au.nals.some((nal) => h264.nalType(nal) === 5);
		if (!this.init) {
			if (!key || !this.sps || !this.pps) return;
			try {
				this.size = h264.spsSize(this.sps);
			} catch (e) {
				this.size = {width: 1920, height: 1080};
			}
			this.codec = h264.codecString(this.sps);
			this.init = fmp4.initSegment(this.sps, this.pps, this.size);
			clearTimeout(this.firstFrameTimer);
			const waiting = this.waiting;
			this.waiting = [];
			waiting.forEach((w) => w.resolve(this));
		}
		const vcl = au.nals.filter((nal) => {
			const type = h264.nalType(nal);
			return type !== 7 && type !== 8 && type !== 9;
		});
		const duration = Math.max(1, Math.min(nextTs - au.ts, 90000));
		const decodeTime = au.ts - this.firstTs;
		const frame = fmp4.fragment(++this.sequence, decodeTime, duration, key, vcl);
		this.stats.frames++;
		if (key) {
			this.stats.keyFrames++;
			this.gop = [];
			this.closeSegment();
			this.current = {seq: this.segmentSeq++, parts: [], duration: 0};
		}
		this.gop.push(frame);
		if (this.current) {
			this.current.parts.push(frame);
			this.current.duration += duration / fmp4.TIMESCALE;
		}
		this.viewers.slice().forEach((viewer) => viewer(frame));
	}

	closeSegment() {
		if (!this.current || !this.current.parts.length) return;
		this.segments.push({seq: this.current.seq, duration: this.current.duration, data: Buffer.concat(this.current.parts)});
		while (this.segments.length > KEEP_SEGMENTS) this.segments.shift();
	}

	/** Resolves once the init segment is known (the first key frame), rejects when the session ends before */
	ready() {
		if (this.init) return Promise.resolve(this);
		if (this.ended) return Promise.reject(this.error || new Error('The live view ended'));
		return new Promise((resolve, reject) => this.waiting.push({resolve: resolve, reject: reject}));
	}

	/** Adds a viewer of the frames; returns the function that removes it. The current GOP is given first. */
	addViewer(onFrame) {
		this.gop.forEach(onFrame);
		this.viewers.push(onFrame);
		return () => {
			const at = this.viewers.indexOf(onFrame);
			if (at >= 0) this.viewers.splice(at, 1);
			this.scheduleIdleCheck();
		};
	}

	touchHls() {
		this.lastHlsTouch = Date.now();
	}

	playlist() {
		this.touchHls();
		const segments = this.segments;
		const target = Math.max(1, Math.ceil(segments.reduce((max, s) => Math.max(max, s.duration), 0)));
		const lines = ['#EXTM3U', '#EXT-X-VERSION:7', '#EXT-X-TARGETDURATION:' + target, '#EXT-X-MEDIA-SEQUENCE:' + (segments.length ? segments[0].seq : 0), '#EXT-X-MAP:URI="init.mp4"'];
		segments.forEach((s) => {
			lines.push('#EXTINF:' + s.duration.toFixed(3) + ',');
			lines.push('seg' + s.seq + '.m4s');
		});
		return lines.join('\n') + '\n';
	}

	segment(seq) {
		this.touchHls();
		return this.segments.filter((s) => s.seq === seq)[0] || null;
	}

	scheduleIdleCheck() {
		if (this.idleTimer) clearTimeout(this.idleTimer);
		this.idleTimer = setTimeout(() => {
			this.idleTimer = null;
			if (this.ended) return;
			if (this.viewers.length === 0 && Date.now() - this.lastHlsTouch >= IDLE_STOP_MS) this.end(null);
			else this.scheduleIdleCheck();
		}, IDLE_STOP_MS);
	}

	end(error) {
		if (this.ended) return;
		this.ended = true;
		this.error = error;
		clearTimeout(this.firstFrameTimer);
		if (this.idleTimer) clearTimeout(this.idleTimer);
		if (this.depacketizer) this.stats.lost = this.depacketizer.lost;
		try {
			if (this.client) this.client.close();
		} catch (e) {
			// already closed
		}
		const waiting = this.waiting;
		this.waiting = [];
		waiting.forEach((w) => w.reject(error || new Error('The live view ended')));
		this.viewers = [];
		this.onEnd(this);
	}
}

/** The live sessions of the bridge, one per camera and quality */
class LiveHub {
	constructor(options) {
		this.options = options || {};
		this.sessions = {};
		this.ended = {};
	}

	/** The running session of a camera source and quality ('hd' or 'sd'), started if needed */
	session(source, quality) {
		const key = source.id + ':' + quality;
		const running = this.sessions[key];
		if (running && !running.ended) return running;
		const path = quality === 'sd' ? '/stream2' : '/stream1';
		const session = new LiveSession({
			url: 'rtsp://' + source.host + ':' + source.port + path,
			user: source.user,
			password: source.password,
			createClient: this.options.createClient,
			onEnd: (s) => {
				if (this.sessions[key] === s) delete this.sessions[key];
				if (s.error) this.ended[key] = {error: s.error.message, code: s.error.code || null, at: Date.now()};
			}
		});
		this.sessions[key] = session;
		session.start();
		return session;
	}

	stopAll() {
		Object.keys(this.sessions).forEach((key) => this.sessions[key].end(null));
		this.sessions = {};
	}

	status() {
		return Object.keys(this.sessions).map((key) => {
			const s = this.sessions[key];
			return {key: key, viewers: s.viewers.length, frames: s.stats.frames, codec: s.codec, size: s.size};
		});
	}
}

module.exports = {LiveSession, LiveHub};
