'use strict';
// Plex Media Server: GDM finds the servers of the network, the JSON API lists the libraries and their folders, and the
// media go through the bridge with the token in a header, never in a URL the page or the player sees.
//
// The trust of a claimed server is its plex.direct certificate, as in mobile/lib/infrastructure/network/plex/
// plex_direct.dart: the bridge connects to the address written in the name "<a>-<b>-<c>-<d>.<hash>.plex.direct" (no
// DNS, so routers that block DNS rebinding do not matter), lets TLS check the chain against the system roots and the
// name, then checks that the subject is the wildcard of the stored hash. The token only ever goes to that server. A
// server without such a certificate (not claimed, on the home network) is read over plain HTTP, and without a token.

const https = require('https');
const tls = require('tls');
const urlLib = require('url');
const httpx = require('./httpx');
const udp = require('./udp');
const media = require('./media');

const GDM_PORT = 32414;
const GDM_GROUP = '239.0.0.250';
const PAGE = 300;
const MAX_CHILDREN = 10000;
const HASH = /^[0-9a-f]{32}$/;

// The server picks the profile of its transcoder by platform: "Chrome" gets the Web profile (H.264 and AAC in HLS), which
// LG TVs play; an unknown platform gets none, and the transcoder answers 400
const PRODUCT = {'X-Plex-Product': 'Immuch360', 'X-Plex-Platform': 'Chrome', 'X-Plex-Device': 'LG TV', 'X-Plex-Device-Name': 'Immuch360 on LG TV'};

// The paths of a server the bridge forwards for the player (the media, their pictures, the HLS transcoder)
const FORWARDED = [/^\/library\/parts\//, /^\/library\/metadata\/\d+\/(thumb|art)\b/, /^\/photo\/:\/transcode\b/, /^\/video\/:\/transcode\/universal\//];

/** The plex.direct host name of address for hash */
function directHost(address, hash) {
	return address.replace(/\./g, '-') + '.' + hash + '.plex.direct';
}

/** {address, hash} of a plex.direct host name, null for any other name */
function parseDirectHost(host) {
	const match = /^(\d{1,3})-(\d{1,3})-(\d{1,3})-(\d{1,3})\.([0-9a-f]{32})\.plex\.direct\.?$/.exec(String(host || '').toLowerCase());
	if (!match) return null;
	const octets = match.slice(1, 5);
	if (octets.some((o) => Number(o) > 255 || (o.length > 1 && o[0] === '0'))) return null;
	return {address: octets.join('.'), hash: match[5]};
}

/** The hash of a certificate subject CN "*.<hash>.plex.direct", null for any other */
function hashOfSubject(cn) {
	const match = /^\*\.([0-9a-f]{32})\.plex\.direct$/.exec(String(cn || ''));
	return match ? match[1] : null;
}

const agents = {};
// Certificates trusted besides the system's, for the tests only (a test server's own certificate)
let testCa = null;

function setTestCa(ca) {
	testCa = ca || null;
	Object.keys(agents).forEach((key) => delete agents[key]);
}

function agentFor(hash) {
	if (!agents[hash]) agents[hash] = new https.Agent({keepAlive: true, maxSockets: 6});
	return agents[hash];
}

/** The base URL and the request options of a source: pinned HTTPS for a server with a hash, plain HTTP otherwise */
function endpoint(source) {
	if (!source.hash) return {base: 'http://' + source.address + ':' + source.port, options: {}};
	const name = directHost(source.address, source.hash);
	return {
		base: 'https://' + source.address + ':' + source.port,
		options: {
			agent: agentFor(source.hash),
			servername: name,
			ca: testCa || undefined,
			headers: {Host: name + ':' + source.port},
			checkServerIdentity: (host, cert) => {
				const error = tls.checkServerIdentity(name, cert);
				if (error) return error;
				if (hashOfSubject(cert && cert.subject && cert.subject.CN) !== source.hash) return new Error('The certificate is not the one of this Plex server');
				return undefined;
			}
		}
	};
}

function headersFor(source, clientId, extra) {
	const headers = Object.assign({Accept: 'application/json', 'X-Plex-Client-Identifier': clientId || 'immuch360-webos'}, PRODUCT, extra || {});
	if (source.token) headers['X-Plex-Token'] = source.token;
	return headers;
}

/** A request to the server of the source, on its pinned connection, with its token */
function call(source, path, options) {
	const opts = options || {};
	const ep = endpoint(source);
	const params = Object.assign({}, ep.options, {method: opts.method || 'GET', timeoutMs: opts.timeoutMs});
	params.headers = Object.assign({}, ep.options.headers || {}, headersFor(source, opts.clientId, opts.headers));
	return httpx.request(ep.base + path, params);
}

function statusError(status) {
	if (status === 401) return Object.assign(new Error('The Plex server refused the token'), {status: status, code: 'token_refused'});
	if (status === 403) return Object.assign(new Error('This token cannot read the libraries of the server'), {status: status, code: 'token_forbidden'});
	return Object.assign(new Error('The Plex server answered ' + status), {status: status});
}

function getJson(source, path, options) {
	return call(source, path, options).then((res) =>
		httpx.readBody(res, 32 * 1024 * 1024).then((body) => {
			if (res.statusCode < 200 || res.statusCode >= 300) throw statusError(res.statusCode);
			try {
				return JSON.parse(body.toString('utf8'));
			} catch (e) {
				throw new Error('The Plex server answered something else than JSON');
			}
		})
	);
}

function container(json) {
	return json && typeof json === 'object' && json.MediaContainer && typeof json.MediaContainer === 'object' ? json.MediaContainer : null;
}

function elementsOf(json, names) {
	const c = container(json);
	if (!c) return [];
	const out = [];
	(names || ['Directory', 'Metadata']).forEach((name) => {
		if (Array.isArray(c[name])) c[name].forEach((e) => e && typeof e === 'object' && out.push(e));
	});
	return out;
}

const SHOWN_SECTIONS = ['photo', 'movie', 'show'];

/** The libraries the app shows: photos, movies, shows (music aside) */
function parseSections(json) {
	return elementsOf(json, ['Directory'])
		.filter((e) => e.key !== undefined && SHOWN_SECTIONS.indexOf(e.type) >= 0)
		.map((e) => ({key: String(e.key), title: String(e.title || e.key), type: e.type}));
}

const EXTENSIONS = {jpeg: 'jpg', mpegts: 'ts', matroska: 'mkv'};

function baseName(path) {
	if (!path) return null;
	const name = String(path).split(/[/\\]/).pop().trim();
	return name || null;
}

function isListingKey(key) {
	const path = String(key).split('?')[0];
	return /\/(folder|children)$/.test(path);
}

/**
 * The folders and the files of one page of a listing (folder view, album list, album children): a file per Media Part,
 * a folder per listing key, relative keys resolved against the listing's path
 */
function parseListing(json, listingPath) {
	const folders = [];
	const files = [];
	const elements = elementsOf(json);
	elements.forEach((element) => {
		const medias = Array.isArray(element.Media) ? element.Media : [];
		const title = String(element.title || '').trim();
		let gotPart = false;
		medias.forEach((m) => {
			(Array.isArray(m && m.Part) ? m.Part : []).forEach((part) => {
				if (!part || !part.key) return;
				gotPart = true;
				const containerName = String(part.container || m.container || '').toLowerCase();
				const fileName = baseName(part.file) || (title && containerName ? title + '.' + (EXTENSIONS[containerName] || containerName) : null);
				if (!fileName) return;
				const what = media.classify(fileName);
				const kind = what.kind || (element.type === 'photo' ? 'image' : element.type === 'movie' || element.type === 'episode' || element.type === 'clip' ? 'video' : null);
				files.push({
					ref: urlLib.resolve(listingPath, String(part.key)),
					name: fileName,
					title: title || fileName,
					kind: kind,
					mime: what.mime,
					size: Number(part.size) || null,
					width: Number(m.width) || null,
					height: Number(m.height) || null,
					duration: Number(part.duration || m.duration) / 1000 || null,
					thumb: element.thumb ? String(element.thumb) : null,
					ratingKey: element.ratingKey ? String(element.ratingKey) : null,
					container: containerName || null,
					videoCodec: m.videoCodec ? String(m.videoCodec).toLowerCase() : null,
					audioCodec: m.audioCodec ? String(m.audioCodec).toLowerCase() : null,
					modified: Number(element.addedAt) ? Number(element.addedAt) * 1000 : null
				});
			});
		});
		if (!gotPart && element.key !== undefined && isListingKey(element.key)) {
			folders.push({ref: urlLib.resolve(listingPath, String(element.key)), name: String(element.title || element.key)});
		}
	});
	const c = container(json) || {};
	return {folders: folders, files: files, count: elements.length, total: typeof c.totalSize === 'number' ? c.totalSize : null};
}

function listAll(source, path, clientId) {
	const folders = [];
	const files = [];
	const page = (start) =>
		getJson(source, path, {clientId: clientId, headers: {'X-Plex-Container-Start': String(start), 'X-Plex-Container-Size': String(PAGE)}}).then((json) => {
			const parsed = parseListing(json, path);
			Array.prototype.push.apply(folders, parsed.folders);
			Array.prototype.push.apply(files, parsed.files);
			const next = start + parsed.count;
			const more = parsed.total === null ? parsed.count >= PAGE : next < parsed.total;
			if (parsed.count > 0 && more && next < MAX_CHILDREN) return page(next);
			return null;
		});
	return page(0).then(() => ({folders: folders, files: files}));
}

/**
 * The listing of ref: '' is the root (a folder per library), else a listing path of the server. A photo library whose
 * folder view does not answer shows its albums.
 */
function list(source, ref, clientId) {
	if (!ref) {
		return getJson(source, '/library/sections', {clientId: clientId}).then((json) => ({
			folders: parseSections(json).map((s) => ({ref: '/library/sections/' + encodeURIComponent(s.key) + '/folder', name: s.title, section: s.type})),
			files: []
		}));
	}
	if (!/^\/library\//.test(ref)) return Promise.reject(Object.assign(new Error('Not a listing of this server'), {status: 400}));
	return listAll(source, ref, clientId).catch((error) => {
		const folderView = /^\/library\/sections\/([^/]+)\/folder$/.exec(ref);
		if (folderView && (error.status === 400 || error.status === 404 || error.status === 410)) {
			return listAll(source, '/library/sections/' + folderView[1] + '/all', clientId);
		}
		throw error;
	}).then((listing) => ({folders: listing.folders, files: listing.files.filter((f) => f.kind)}));
}

/** Whether the bridge forwards that path of the server for the player */
function isForwardable(path) {
	const p = String(path || '');
	if (p.indexOf('..') >= 0) return false;
	return FORWARDED.some((re) => re.test(p));
}

/** Forwards a GET of the player to the server (media, pictures, HLS), its Range passed, the token added */
function forward(source, path, req, res, clientId) {
	if (!isForwardable(path)) return Promise.reject(Object.assign(new Error('Not a path the bridge forwards'), {status: 403}));
	return call(source, path, {clientId: clientId, headers: Object.assign({Accept: '*/*'}, httpx.rangeHeaders(req))}).then((upstream) => {
		httpx.pipeResponse(upstream, res);
	});
}

/** The path of a picture of the server at that size, from its photo transcoder */
function photoPath(url, width, height) {
	return (
		'/photo/:/transcode?width=' + Math.round(width) + '&height=' + Math.round(height) + '&minSize=1&upscale=0&url=' + encodeURIComponent(url)
	);
}

/** The query of the HLS transcode of an item, for a video the TV does not play as it is */
function hlsQuery(ratingKey, session, clientId) {
	return [
		'hasMDE=1',
		'path=' + encodeURIComponent('/library/metadata/' + ratingKey),
		'mediaIndex=0',
		'partIndex=0',
		'protocol=hls',
		'fastSeek=1',
		'directPlay=0',
		'directStream=1',
		'directStreamAudio=1',
		'videoQuality=100',
		'maxVideoBitrate=20000',
		'videoResolution=1920x1080',
		'audioBoost=100',
		'location=lan',
		'session=' + encodeURIComponent(session),
		'X-Plex-Session-Identifier=' + encodeURIComponent(session),
		'X-Plex-Client-Identifier=' + encodeURIComponent(clientId || 'immuch360-webos'),
		'X-Plex-Product=Immuch360',
		'X-Plex-Platform=Chrome'
	].join('&');
}

/** The path of the HLS playlist of a transcode, once its decision was asked (startHls) */
function hlsPath(ratingKey, session, clientId) {
	return '/video/:/transcode/universal/start.m3u8?' + hlsQuery(ratingKey, session, clientId);
}

const hlsSessions = {};

/**
 * Asks the server's decision for a transcode (recent servers refuse start.m3u8 without it), after stopping the
 * previous transcode of this source: resolves with the path of the playlist
 */
function startHls(source, ratingKey, session, clientId) {
	const previous = hlsSessions[source.id];
	hlsSessions[source.id] = session;
	const stop = previous
		? call(source, '/video/:/transcode/universal/stop?session=' + encodeURIComponent(previous), {clientId: clientId}).then((res) => res.resume(), () => null)
		: Promise.resolve();
	return stop
		.then(() => getJson(source, '/video/:/transcode/universal/decision?' + hlsQuery(ratingKey, session, clientId), {clientId: clientId}))
		.then(() => hlsPath(ratingKey, session, clientId));
}

/** Whether the TV plays the file of a listing as it is (else the HLS transcode is used) */
function playsDirectly(file) {
	const containerName = String(file.container || media.extensionOf(file.name)).toLowerCase();
	const video = String(file.videoCodec || '').toLowerCase();
	const audio = String(file.audioCodec || '').toLowerCase();
	const containerOk = ['mp4', 'm4v', 'mov', 'mkv', 'webm', 'mpegts', 'ts'].indexOf(containerName) >= 0;
	const videoOk = !video || ['h264', 'hevc', 'h265', 'vp9', 'av1'].indexOf(video) >= 0;
	const audioOk = !audio || ['aac', 'ac3', 'eac3', 'mp3', 'opus', 'vorbis', 'pcm', 'flac'].indexOf(audio) >= 0;
	return containerOk && videoOk && audioOk;
}

/** The GDM answer of a Plex Media Server in a datagram, null for anything else (the players answer GDM too) */
function parseGdmAnswer(text, from) {
	const parsed = udp.parseHeaders(text);
	if (!/^HTTP\/1\.\d\s+200(\s|$)/i.test(parsed.status)) return null;
	const h = parsed.headers;
	if (String(h['content-type'] || '').toLowerCase() !== 'plex/media-server') return null;
	const port = Number(h.port);
	const id = String(h['resource-identifier'] || '').toLowerCase();
	if (!(port > 0 && port < 65536) || !/^[0-9a-f]{8,64}$/.test(id)) return null;
	const hashMatch = /(?:^|\.)([0-9a-f]{32})\.plex\.direct\.?$/.exec(String(h.host || '').toLowerCase());
	return {kind: 'plex', name: h.name || '', address: from, port: port, machineId: id, hash: hashMatch ? hashMatch[1] : null, version: h.version || null};
}

/** The Plex servers that answer GDM within ms */
function discover(ms, options) {
	const opts = options || {};
	return udp
		.search('M-SEARCH * HTTP/1.1\r\n\r\n', GDM_PORT, ms, {groups: [GDM_GROUP, '255.255.255.255'], sweep: opts.sweep !== false, addresses: opts.addresses})
		.then((answers) => {
			const seen = {};
			const out = [];
			answers.forEach((answer) => {
				const server = parseGdmAnswer(answer.text, answer.from);
				if (!server || seen[server.machineId + '@' + server.address]) return;
				seen[server.machineId + '@' + server.address] = true;
				out.push(server);
			});
			return out;
		});
}

/**
 * The plex.direct hash of the certificate the server at address:port shows, read during a TLS handshake that is
 * closed as soon as the certificate is seen (nothing is sent); null when it is not a plex.direct one or no TLS answers
 */
function probeHash(address, port, timeoutMs) {
	return new Promise((resolve) => {
		let done = false;
		const finish = (value) => {
			if (done) return;
			done = true;
			clearTimeout(timer);
			try {
				socket.destroy();
			} catch (e) {
				// closed
			}
			resolve(value);
		};
		const socket = tls.connect({host: address, port: port, rejectUnauthorized: false, servername: undefined}, () => {
			const cert = socket.getPeerCertificate();
			finish(hashOfSubject(cert && cert.subject && cert.subject.CN));
		});
		socket.on('error', () => finish(null));
		const timer = setTimeout(() => finish(null), timeoutMs || 6000);
	});
}

/** Who answers at the address of a source: {machineId, version, claimed, name}; the name needs the token */
function identify(source, clientId) {
	return getJson(source, '/identity', {clientId: clientId, timeoutMs: 8000}).then((json) => {
		const c = container(json) || {};
		const out = {machineId: c.machineIdentifier ? String(c.machineIdentifier) : null, version: c.version || null, claimed: c.claimed === undefined ? null : !!c.claimed, name: null};
		if (!out.machineId) throw new Error('This address is not a Plex Media Server');
		return getJson(source, '/', {clientId: clientId, timeoutMs: 8000})
			.then((root) => {
				const r = container(root) || {};
				out.name = r.friendlyName ? String(r.friendlyName) : null;
				return out;
			})
			.catch(() => out);
	});
}

module.exports = {
	HASH,
	directHost,
	parseDirectHost,
	hashOfSubject,
	endpoint,
	parseSections,
	parseListing,
	list,
	forward,
	isForwardable,
	photoPath,
	hlsPath,
	startHls,
	playsDirectly,
	parseGdmAnswer,
	discover,
	probeHash,
	identify,
	getJson,
	setTestCa
};
