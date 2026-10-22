'use strict';
// WebDAV (Nextcloud, Synology, rclone and others): PROPFIND with Depth 1 lists a folder, GET with a Range header reads
// a file. Authentication is Basic, sent with every request (HTTPS when the address says so). Redirects are followed on
// the same host only, so that the password never leaves it. As mobile/lib/infrastructure/network/webdav_file_system.dart.

const urlLib = require('url');
const httpx = require('./httpx');
const xml = require('./xml');
const media = require('./media');

const MAX_REDIRECTS = 5;
const PROPFIND_BODY =
	'<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/>' +
	'<d:getcontenttype/><d:getlastmodified/></d:prop></d:propfind>';

function authHeader(source) {
	if (!source.user && !source.password) return {};
	return {Authorization: 'Basic ' + Buffer.from(source.user + ':' + source.password, 'utf8').toString('base64')};
}

/** The path of a folder or file of the share as a list of names ("a/b c" -> ["a", "b c"]) */
function segments(path) {
	return String(path || '')
		.split('/')
		.filter((part) => part && part !== '.' && part !== '..');
}

/** The URL of that path under the source's address, each name percent encoded */
function davUrl(source, path, folder) {
	const base = source.url.replace(/\/+$/, '');
	const parts = segments(path).map(encodeURIComponent);
	return base + (parts.length ? '/' + parts.join('/') : '') + (folder ? '/' : '');
}

function percentDecode(text) {
	try {
		return decodeURIComponent(text);
	} catch (e) {
		return text.replace(/(?:%[0-9a-f]{2})+/gi, (run) => {
			try {
				return decodeURIComponent(run);
			} catch (x) {
				return run;
			}
		});
	}
}

/** The decoded path of an href, without scheme and host, without its last slash */
function hrefPath(href, requestedPath) {
	let path = href.trim();
	const scheme = path.indexOf('://');
	if (scheme >= 0) {
		const slash = path.indexOf('/', scheme + 3);
		path = slash < 0 ? '/' : path.slice(slash);
	}
	path = percentDecode(path.split('?')[0]);
	if (path.charAt(0) !== '/') path = requestedPath.replace(/\/+$/, '') + '/' + path;
	path = path.replace(/\/{2,}/g, '/');
	return path.length > 1 ? path.replace(/\/+$/, '') : path;
}

/** Sends the request with the password, following the redirects that stay on the same host */
function send(source, method, target, headers, body) {
	const first = urlLib.parse(target);
	const go = (current, left) =>
		httpx.request(current, {method: method, headers: Object.assign({}, authHeader(source), headers || {}), body: body}).then((res) => {
			if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
				res.resume();
				const next = urlLib.resolve(current, res.headers.location);
				const parsed = urlLib.parse(next);
				if (left <= 0) throw new Error('Too many redirects');
				if (parsed.host !== first.host || parsed.protocol !== first.protocol) throw new Error('The server redirects to another host');
				return go(next, left - 1);
			}
			return res;
		});
	return go(target, MAX_REDIRECTS);
}

function statusError(status) {
	if (status === 401 || status === 403) return Object.assign(new Error('The server refused the user name or the password'), {status: status, code: 'auth'});
	if (status === 404) return Object.assign(new Error('This folder does not exist on the server'), {status: status, code: 'not_found'});
	if (status === 405 || status === 501) return Object.assign(new Error('This address is not a WebDAV folder'), {status: status, code: 'not_webdav'});
	return Object.assign(new Error('The server answered ' + status), {status: status});
}

/** The resources of a multistatus answer: {path, dir, size, type, modified} */
function parseMultistatus(text, requestedPath) {
	return xml.elements(text, 'response').map((response) => {
		const href = xml.childText(response.body, 'href') || '';
		const propstats = xml.elements(response.body, 'propstat').filter((p) => /\s2\d\d\s/.test(' ' + (xml.childText(p.body, 'status') || 'HTTP/1.1 200 OK') + ' '));
		const props = (propstats.length ? propstats : [response]).map((p) => p.body).join('');
		const type = xml.elements(props, 'resourcetype')[0];
		const isCollection = (!!type && xml.elements(type.body, 'collection').length > 0) || /^(1|true)$/i.test(xml.childText(props, 'iscollection') || '');
		const size = Number(xml.childText(props, 'getcontentlength') || 0);
		const modified = Date.parse(xml.childText(props, 'getlastmodified') || '');
		return {
			path: hrefPath(href, requestedPath),
			dir: isCollection,
			size: isCollection ? null : Number.isFinite(size) ? size : null,
			type: xml.childText(props, 'getcontenttype'),
			modified: Number.isFinite(modified) ? modified : null
		};
	});
}

function parentOf(path) {
	const slash = path.lastIndexOf('/');
	return slash <= 0 ? '/' : path.slice(0, slash);
}

/** The folders and files of the folder at path (relative to the source's address), as the page lists them */
function list(source, path) {
	const target = davUrl(source, path, true);
	const requestedPath = hrefPath(urlLib.parse(target).pathname || '/', '/');
	return send(source, 'PROPFIND', target, {Depth: '1', 'Content-Type': 'application/xml; charset=utf-8'}, PROPFIND_BODY)
		.then((res) =>
			httpx.readBody(res, 32 * 1024 * 1024).then((body) => {
				if (res.statusCode !== 207) throw statusError(res.statusCode);
				return parseMultistatus(body.toString('utf8'), requestedPath);
			})
		)
		.then((resources) => {
			const lower = requestedPath.toLowerCase();
			const children = resources.filter((r) => r.path.toLowerCase() !== lower && parentOf(r.path).toLowerCase() === lower);
			// A server behind a proxy may answer with other paths than the one asked: then every entry but the folder
			const entries = children.length || resources.length <= 1 ? children : resources.slice(1);
			const base = segments(path);
			const folders = [];
			const files = [];
			entries.forEach((entry) => {
				const name = entry.path.slice(entry.path.lastIndexOf('/') + 1);
				if (!name || media.isHiddenName(name)) return;
				const ref = base.concat([name]).join('/');
				if (entry.dir) {
					folders.push({ref: ref, name: name});
					return;
				}
				const what = media.classify(name, entry.type);
				files.push({ref: ref, name: name, size: entry.size, mime: what.mime, kind: what.kind, modified: entry.modified});
			});
			return media.shapeListing(folders, files);
		});
}

/** Pipes the file at path to the player, with the Range of its request */
function pipeFile(source, path, req, res) {
	return send(source, 'GET', davUrl(source, path, false), httpx.rangeHeaders(req)).then((upstream) => {
		if (upstream.statusCode >= 400) {
			upstream.resume();
			throw statusError(upstream.statusCode);
		}
		const extra = upstream.headers['content-type'] ? {} : {'Content-Type': media.mimeOf(path)};
		httpx.pipeResponse(upstream, res, extra);
	});
}

/** The first bytes of the file at path */
function readHead(source, path, bytes) {
	return send(source, 'GET', davUrl(source, path, false), {Range: 'bytes=0-' + (bytes - 1)}).then((res) => {
		if (res.statusCode >= 400) {
			res.resume();
			throw statusError(res.statusCode);
		}
		// A server that ignores Range sends the whole file: only the head is read, then the answer is closed
		return new Promise((resolve, reject) => {
			const parts = [];
			let size = 0;
			let done = false;
			const finish = () => {
				if (done) return;
				done = true;
				resolve(Buffer.concat(parts).slice(0, bytes));
			};
			res.on('data', (chunk) => {
				parts.push(chunk);
				size += chunk.length;
				if (size >= bytes) {
					finish();
					res.destroy();
				}
			});
			res.on('end', finish);
			res.on('error', (err) => (done ? null : reject(err)));
		});
	});
}

module.exports = {list, pipeFile, readHead, davUrl, parseMultistatus, hrefPath, segments};
