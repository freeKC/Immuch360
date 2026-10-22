'use strict';
// The media bridge of the webOS app: a small HTTP server in the app's JS service, on 127.0.0.1, behind a random token
// in the path. The page lists the folders of a share and the TV's player reads the media through it; the passwords
// and tokens of the sources stay in the service (they arrive over Luna, setSources). Every answer carries the CORS
// header, so the page reads JSON with fetch and WebGL takes the pixels of a 360° photo from a share on any webOS.
//
// Written for Node 8 (webOS 5 and 6) and later, core modules only; tools/build-bridge.mjs bundles it for node8 as
// service/bridge/base.js. SMB comes from a second bundle (service/bridge/smb.js, Node 12 and later) loaded on demand.

const http = require('http');
const crypto = require('crypto');
const urlLib = require('url');
const httpx = require('./httpx');
const sourcesLib = require('./sources');
const media = require('./media');
const exif = require('./exif');
const webdav = require('./webdav');
const dlna = require('./dlna');
const plex = require('./plex');
const plextv = require('./plextv');
const liveLib = require('./live/session');

const THUMB_CACHE_BYTES = 24 * 1024 * 1024;
const META_CACHE_ENTRIES = 2000;
const SIZE_CACHE_MS = 60000;
const SMB_HEAD_CONCURRENCY = 4;

/** A cache of the most recent entries, bounded by the sum of their sizes */
function createCache(maxBytes, maxEntries) {
	const map = new Map();
	let bytes = 0;
	return {
		get(key) {
			if (!map.has(key)) return undefined;
			const value = map.get(key);
			map.delete(key);
			map.set(key, value);
			return value.value;
		},
		set(key, value, size) {
			if (map.has(key)) {
				bytes -= map.get(key).size;
				map.delete(key);
			}
			map.set(key, {value: value, size: size || 1});
			bytes += size || 1;
			while ((bytes > maxBytes || map.size > maxEntries) && map.size) {
				const oldest = map.keys().next().value;
				bytes -= map.get(oldest).size;
				map.delete(oldest);
			}
		},
		clear() {
			map.clear();
			bytes = 0;
		}
	};
}

/** At most n tasks at a time */
function createLimiter(n) {
	let running = 0;
	const queue = [];
	const next = () => {
		if (running >= n || !queue.length) return;
		running++;
		const job = queue.shift();
		Promise.resolve()
			.then(job.task)
			.then(
			(v) => {
				running--;
				job.resolve(v);
				next();
			},
			(e) => {
				running--;
				job.reject(e);
				next();
			}
		);
	};
	return (task) =>
		new Promise((resolve, reject) => {
			queue.push({task: task, resolve: resolve, reject: reject});
			next();
		});
}

function nodeMajor() {
	return Number(String(process.versions.node).split('.')[0]);
}

/**
 * options: loadSmb () => {createSmbDriver} (throws when SMB cannot load), plexTvBases (tests), log, createRtspClient
 * (tests), discoveryOptions (tests: {addresses, sweep})
 */
function createBridge(options) {
	const opts = options || {};
	const registry = sourcesLib.createRegistry();
	const thumbs = createCache(THUMB_CACHE_BYTES, 2000);
	const metas = createCache(Infinity, META_CACHE_ENTRIES);
	const sizes = createCache(Infinity, 2000);
	const hub = new liveLib.LiveHub({createClient: opts.createRtspClient});
	const smbLimiters = {};
	let server = null;
	let token = null;
	let port = null;
	let host = null;
	let smbDriver = null;
	let smbError = null;
	let lastRequestAt = Date.now();
	let clientId = opts.plexClientId || 'immuch360-webos';
	const plexClientId = () => clientId;

	function smb() {
		if (smbDriver) return smbDriver;
		if (smbError) throw smbError;
		if (nodeMajor() < 12) {
			smbError = Object.assign(new Error('SMB needs webOS 22 or later (Node 12)'), {code: 'smb_needs_node12', status: 501});
			throw smbError;
		}
		try {
			smbDriver = opts.loadSmb().createSmbDriver();
		} catch (e) {
			smbError = Object.assign(new Error('SMB could not load: ' + e.message), {code: 'smb_unavailable', status: 501});
			throw smbError;
		}
		return smbDriver;
	}

	function smbLimit(source) {
		if (!smbLimiters[source.id]) smbLimiters[source.id] = createLimiter(SMB_HEAD_CONCURRENCY);
		return smbLimiters[source.id];
	}

	function sourceOr404(id) {
		const source = registry.get(id);
		if (!source) throw Object.assign(new Error('Unknown source'), {status: 404, code: 'no_source'});
		return source;
	}

	/** The listing of a folder of a source: {folders: [{ref, name}], files: [{ref, name, kind, mime, size, ...}]} */
	function list(source, ref) {
		if (source.kind === 'webdav') return webdav.list(source, ref);
		if (source.kind === 'dlna') return dlna.list(source, ref || '0');
		if (source.kind === 'plex') {
			return plex.list(source, ref, plexClientId()).then((listing) => {
				listing.files.forEach((file) => {
					file.direct = file.kind !== 'video' || plex.playsDirectly(file);
				});
				return listing;
			});
		}
		if (source.kind === 'smb') {
			return smb()
				.list(source, ref)
				.then((entries) => {
					const base = webdav.segments(ref);
					const folders = [];
					const files = [];
					entries.forEach((entry) => {
						if (media.isHiddenName(entry.name)) return;
						const entryRef = base.concat([entry.name]).join('/');
						if (entry.dir) folders.push({ref: entryRef, name: entry.name});
						else {
							const what = media.classify(entry.name);
							files.push({ref: entryRef, name: entry.name, kind: what.kind, mime: what.mime, size: entry.size, modified: entry.modified});
							sizes.set(source.id + '\u0000' + entryRef, {size: entry.size, at: Date.now()});
						}
					});
					return media.shapeListing(folders, files);
				});
		}
		return Promise.reject(Object.assign(new Error('This source has no folders'), {status: 400}));
	}

	function smbSize(source, ref) {
		const key = source.id + '\u0000' + ref;
		const known = sizes.get(key);
		if (known && Date.now() - known.at < SIZE_CACHE_MS && known.size !== null) return Promise.resolve(known.size);
		return smb()
			.size(source, ref)
			.then((size) => {
				sizes.set(key, {size: size, at: Date.now()});
				return size;
			});
	}

	/** Serves a file of an SMB share with the Range of the request, reading it a chunk at a time */
	function serveSmb(source, ref, req, res) {
		const driver = smb();
		return smbSize(source, ref).then((size) => {
			const range = httpx.parseRange(req.headers.range, size);
			if (range === 'unsatisfiable') {
				res.writeHead(416, Object.assign({'Content-Range': 'bytes */' + size}, httpx.CORS));
				res.end();
				return null;
			}
			const start = range ? range.start : 0;
			const end = range ? range.end : size - 1;
			const headers = Object.assign({'Content-Type': media.mimeOf(ref), 'Accept-Ranges': 'bytes', 'Content-Length': Math.max(0, end - start + 1)}, httpx.CORS);
			if (range) headers['Content-Range'] = 'bytes ' + start + '-' + end + '/' + size;
			res.writeHead(range ? 206 : 200, headers);
			if (req.method === 'HEAD' || size === 0) {
				res.end();
				return null;
			}
			let position = start;
			let closed = false;
			res.on('close', () => {
				closed = true;
			});
			const pump = () => {
				if (closed) return null;
				if (position > end) {
					res.end();
					return null;
				}
				const length = Math.min(driver.CHUNK, end - position + 1);
				return driver.read(source, ref, position, length).then((chunk) => {
					if (closed) return null;
					if (!chunk.length) {
						res.end();
						return null;
					}
					position += chunk.length;
					if (res.write(chunk)) return pump();
					return new Promise((resolve) => res.once('drain', resolve)).then(pump);
				});
			};
			return pump().catch(() => res.destroy());
		});
	}

	/** Pipes a file of any source kind to the player */
	function serveFile(source, ref, req, res) {
		if (source.kind === 'webdav') return webdav.pipeFile(source, ref, req, res);
		if (source.kind === 'smb') return serveSmb(source, ref, req, res);
		if (source.kind === 'dlna') return dlna.pipeMedia(source, ref, req, res);
		if (source.kind === 'plex') return plex.forward(source, ref, req, res, plexClientId());
		return Promise.reject(Object.assign(new Error('This source has no files'), {status: 400}));
	}

	/** The first bytes of a file, for its EXIF thumbnail and its size, 360° flag and camera */
	function readHead(source, ref) {
		const bytes = exif.HEAD_BYTES;
		if (source.kind === 'webdav') return webdav.readHead(source, ref, bytes);
		if (source.kind === 'smb') return smbLimit(source)(() => smb().read(source, ref, 0, bytes));
		let target;
		let requestOptions = {headers: {Range: 'bytes=0-' + (bytes - 1)}};
		if (source.kind === 'dlna') {
			if (!dlna.ownsUrl(source, ref)) return Promise.reject(Object.assign(new Error('Not a media of this server'), {status: 403}));
			target = ref;
		} else if (source.kind === 'plex') {
			if (!plex.isForwardable(ref)) return Promise.reject(Object.assign(new Error('Not a path the bridge forwards'), {status: 403}));
			const ep = plex.endpoint(source);
			target = ep.base + ref;
			requestOptions = Object.assign({}, ep.options, {headers: Object.assign({}, ep.options.headers || {}, requestOptions.headers, source.token ? {'X-Plex-Token': source.token} : {})});
		} else return Promise.reject(Object.assign(new Error('No file here'), {status: 400}));
		return httpx.request(target, requestOptions).then(
			(res) =>
				new Promise((resolve, reject) => {
					const parts = [];
					let size = 0;
					let done = false;
					res.on('data', (chunk) => {
						parts.push(chunk);
						size += chunk.length;
						if (size >= bytes && !done) {
							done = true;
							res.destroy();
							resolve(Buffer.concat(parts).slice(0, bytes));
						}
					});
					res.on('end', () => {
						if (!done) {
							done = true;
							resolve(Buffer.concat(parts));
						}
					});
					res.on('error', (e) => (done ? null : reject(e)));
				})
		);
	}

	function headInfo(source, ref) {
		const key = source.id + '\u0000' + ref;
		const known = metas.get(key);
		if (known) return Promise.resolve(known);
		return readHead(source, ref).then((buf) => {
			const info = exif.readJpegHead(buf);
			const thumbnail = info.thumbnail;
			delete info.thumbnail;
			metas.set(key, info);
			if (thumbnail) thumbs.set(key, thumbnail, thumbnail.length);
			return info;
		});
	}

	/** The small picture of a file: the EXIF one for SMB and WebDAV, the server's for DLNA and Plex */
	function serveThumb(source, ref, thumbRef, req, res) {
		if (source.kind === 'plex') {
			const picture = thumbRef || ref;
			return plex.forward(source, plex.photoPath(picture, 360, 360), req, res, plexClientId());
		}
		if (source.kind === 'dlna') {
			if (!thumbRef) return Promise.reject(Object.assign(new Error('No thumbnail'), {status: 404}));
			return dlna.pipeMedia(source, thumbRef, req, res);
		}
		const key = source.id + '\u0000' + ref;
		const cached = thumbs.get(key);
		if (cached) {
			httpx.sendBuffer(res, 200, 'image/jpeg', cached, {'Cache-Control': 'max-age=3600'});
			return Promise.resolve();
		}
		if (media.classify(ref).mime !== 'image/jpeg') return Promise.reject(Object.assign(new Error('No thumbnail'), {status: 404}));
		return headInfo(source, ref).then(() => {
			const thumb = thumbs.get(key);
			if (!thumb) throw Object.assign(new Error('No thumbnail in this file'), {status: 404});
			httpx.sendBuffer(res, 200, 'image/jpeg', thumb, {'Cache-Control': 'max-age=3600'});
		});
	}

	/** A photo at the TV's size: Plex makes it on the server; the other sources send the original */
	function servePhoto(source, ref, query, req, res) {
		if (source.kind === 'plex') {
			const width = Math.min(3840, Math.max(320, Number(query.w) || 1920));
			const height = Math.min(2160, Math.max(240, Number(query.h) || 1080));
			return plex.forward(source, plex.photoPath(ref, width, height), req, res, plexClientId());
		}
		return serveFile(source, ref, req, res);
	}

	function serveLive(parts, query, req, res) {
		// live/<sourceId>/<hd|sd>/<file>
		const source = sourceOr404(parts[1]);
		if (source.kind !== 'tapo') throw Object.assign(new Error('Not a camera'), {status: 400});
		const quality = parts[2] === 'sd' ? 'sd' : 'hd';
		const file = parts[3] || 'stream.mp4';
		const session = hub.session(source, quality);
		if (file === 'stream.mp4') {
			return session.ready().then(() => {
				res.writeHead(200, Object.assign({'Content-Type': 'video/mp4', 'Cache-Control': 'no-store', 'X-Immuch-Codec': session.codec}, httpx.CORS));
				res.write(session.init);
				const remove = session.addViewer((frame) => res.write(frame));
				const done = () => remove();
				res.on('close', done);
				res.on('finish', done);
				const check = setInterval(() => {
					if (session.ended) {
						clearInterval(check);
						res.end();
					}
				}, 1000);
				res.on('close', () => clearInterval(check));
			});
		}
		if (file === 'info') {
			return session.ready().then(() => httpx.sendJson(res, 200, {codec: session.codec, size: session.size}));
		}
		if (file === 'index.m3u8') {
			session.touchHls();
			return session.ready().then(() => {
				const wait = (tries) => {
					if (session.segments.length >= 2 || tries <= 0) {
						httpx.sendBuffer(res, 200, 'application/vnd.apple.mpegurl', Buffer.from(session.playlist()), {'Cache-Control': 'no-store'});
						return null;
					}
					return new Promise((resolve) => setTimeout(resolve, 500)).then(() => wait(tries - 1));
				};
				return wait(20);
			});
		}
		if (file === 'init.mp4') {
			return session.ready().then(() => httpx.sendBuffer(res, 200, 'video/mp4', session.init));
		}
		const seg = /^seg(\d+)\.m4s$/.exec(file);
		if (seg) {
			const segment = session.segment(Number(seg[1]));
			if (!segment) throw Object.assign(new Error('Segment gone'), {status: 404});
			httpx.sendBuffer(res, 200, 'video/iso.segment', segment.data, {'Cache-Control': 'no-store'});
			return Promise.resolve();
		}
		throw Object.assign(new Error('No such live file'), {status: 404});
	}

	function route(req, res) {
		lastRequestAt = Date.now();
		if (req.method === 'OPTIONS') {
			res.writeHead(204, Object.assign({'Access-Control-Allow-Headers': 'Range, Content-Type', 'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS', 'Access-Control-Max-Age': '600'}, httpx.CORS));
			res.end();
			return Promise.resolve();
		}
		const parsed = urlLib.parse(req.url, true);
		const pathname = parsed.pathname || '/';
		const parts = pathname.split('/').filter(Boolean);
		// Compared in constant time: the token is the only lock of the bridge
		if (!parts.length || parts[0].length !== token.length || !crypto.timingSafeEqual(Buffer.from(parts[0]), Buffer.from(token))) {
			httpx.sendError(res, 404, 'not found');
			return Promise.resolve();
		}
		if (req.method !== 'GET' && req.method !== 'HEAD') {
			httpx.sendError(res, 405, 'method not allowed');
			return Promise.resolve();
		}
		const q = parsed.query;
		const name = parts[1];
		return Promise.resolve()
			.then(() => {
				if (name === 'status') return httpx.sendJson(res, 200, status());
				if (name === 'live') return serveLive(parts.slice(1), q, req, res);
				if (name === 'px') {
					// px/<sourceId>/<path of the Plex server>: the HLS transcoder and what its playlists name
					const source = sourceOr404(parts[2]);
					if (source.kind !== 'plex') throw Object.assign(new Error('Not a Plex server'), {status: 400});
					const prefix = '/' + parts[0] + '/px/' + parts[2];
					const rest = req.url.slice(req.url.indexOf(prefix) + prefix.length);
					return plex.forward(source, rest, req, res, plexClientId());
				}
				const source = sourceOr404(q.s);
				const ref = typeof q.r === 'string' ? q.r : '';
				if (name === 'list') return list(source, ref).then((listing) => httpx.sendJson(res, 200, listing));
				if (name === 'file') return serveFile(source, ref, req, res);
				if (name === 'thumb') return serveThumb(source, ref, typeof q.t === 'string' ? q.t : null, req, res);
				if (name === 'photo') return servePhoto(source, ref, q, req, res);
				if (name === 'meta') return headInfo(source, ref).then((info) => httpx.sendJson(res, 200, info));
				if (name === 'hls') {
					if (source.kind !== 'plex' || !/^\d+$/.test(String(q.k || ''))) throw Object.assign(new Error('No transcode here'), {status: 400});
					const session = crypto.randomBytes(8).toString('hex');
					res.writeHead(302, Object.assign({Location: '/' + token + '/px/' + source.id + plex.hlsPath(q.k, session, plexClientId())}, httpx.CORS));
					res.end();
					return null;
				}
				throw Object.assign(new Error('No such route'), {status: 404});
			})
			.catch((error) => {
				httpx.sendError(res, error.status || 502, error.message || String(error), error.code || null);
			});
	}

	function status() {
		const cpu = process.cpuUsage ? process.cpuUsage() : null;
		return {
			running: !!server,
			port: port,
			node: process.version,
			smb: nodeMajor() >= 12 && !smbError,
			sources: registry.ids().length,
			rss: process.memoryUsage().rss,
			cpuMs: cpu ? Math.round((cpu.user + cpu.system) / 1000) : null,
			uptimeS: Math.round(process.uptime()),
			live: hub.status()
		};
	}

	/** Starts the server (once): resolves with {port, token, node, smb} */
	function start(bindHost) {
		if (server) return Promise.resolve({port: port, token: token, host: host, node: process.version, smb: nodeMajor() >= 12 && !smbError});
		token = crypto.randomBytes(16).toString('hex');
		host = bindHost || '127.0.0.1';
		return new Promise((resolve, reject) => {
			const s = http.createServer((req, res) => {
				route(req, res);
			});
			s.on('error', reject);
			s.listen(0, host, () => {
				server = s;
				port = s.address().port;
				s.removeListener('error', reject);
				s.on('error', (e) => opts.log && opts.log('bridge server error ' + e.message));
				resolve({port: port, token: token, host: host, node: process.version, smb: nodeMajor() >= 12 && !smbError});
			});
		});
	}

	function stop() {
		hub.stopAll();
		if (smbDriver) smbDriver.closeAll();
		thumbs.clear();
		metas.clear();
		if (server) {
			try {
				server.close();
			} catch (e) {
				// already closed
			}
		}
		server = null;
		token = null;
		port = null;
	}

	/** What the page asks over Luna besides the media: discovery, tests, Plex sign in */
	function control(op, args) {
		return Promise.resolve().then(() => controlNow(op, args));
	}

	function controlNow(op, args) {
		const a = args || {};
		lastRequestAt = Date.now();
		const discovery = opts.discoveryOptions || {};
		if (op === 'discover') {
			const ms = Math.min(8000, Math.max(500, Number(a.ms) || 3000));
			if (a.kind === 'dlna') return dlna.discover(ms, discovery).then((servers) => ({servers: servers}));
			if (a.kind === 'plex') return plex.discover(ms, discovery).then((servers) => ({servers: servers}));
			return Promise.reject(new Error('unknown discovery'));
		}
		if (op === 'test') {
			const source = sourcesLib.normalizeSource(a.source);
			if (source instanceof Error) return Promise.reject(source);
			if (source.kind === 'tapo') {
				const session = hub.session(source, a.quality === 'sd' ? 'sd' : 'hd');
				return session.ready().then(() => ({ok: true, codec: session.codec, size: session.size}));
			}
			return list(source, '').then((listing) => ({ok: true, count: listing.folders.length + listing.files.length}));
		}
		if (op === 'smbShares') {
			const source = sourcesLib.normalizeSource(Object.assign({id: 'shares', kind: 'smb', share: 'IPC$'}, a));
			if (source instanceof Error) return Promise.reject(source);
			return Promise.resolve()
				.then(() => smb().shares(source))
				.then((shares) => ({shares: shares}));
		}
		if (op === 'plexPin') return plextv.createPin(a.clientId, opts.plexTvBases);
		if (op === 'plexPinCheck') return plextv.checkPin(a.clientId, a.id, opts.plexTvBases).then((t) => ({token: t}));
		if (op === 'plexServers') return plextv.servers(a.clientId, a.token, opts.plexTvBases).then((servers) => ({servers: servers}));
		if (op === 'plexProbe') {
			const address = String(a.address || '');
			const p = Number(a.port) || 32400;
			return plex.probeHash(address, p).then((hash) => {
				const source = {id: 'probe', kind: 'plex', address: address, port: p, hash: hash, token: null};
				return plex
					.identify(source, plexClientId())
					.then((identity) => ({hash: hash, identity: identity}))
					.catch((error) => ({hash: hash, identity: null, error: error.message}));
			});
		}
		return Promise.reject(new Error('unknown operation ' + op));
	}

	return {
		start: start,
		stop: stop,
		status: status,
		control: control,
		setSources(list) {
			const result = registry.replace(list);
			thumbs.clear();
			metas.clear();
			if (smbDriver) smbDriver.closeAll();
			hub.stopAll();
			return result;
		},
		/** The X-Plex-Client-Identifier of this TV (the page keeps it), for the Plex servers and plex.tv */
		setPlexClientId(id) {
			if (/^[A-Za-z0-9_-]{8,64}$/.test(String(id || ''))) clientId = String(id);
		},
		idleMs() {
			return Date.now() - lastRequestAt;
		},
		touch() {
			lastRequestAt = Date.now();
		},
		isRunning() {
			return !!server;
		}
	};
}

module.exports = {createBridge, createCache, createLimiter};
