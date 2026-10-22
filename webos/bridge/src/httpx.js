'use strict';
/* global Buffer */
// HTTP helpers of the bridge: requests to the sources, and the answers to the page and to the TV's player. Every
// answer to the page carries Access-Control-Allow-Origin, so that fetch reads it and WebGL takes its pixels.

const http = require('http');
const https = require('https');
const urlLib = require('url');

const CORS = {
	'Access-Control-Allow-Origin': '*',
	'Access-Control-Expose-Headers': 'Content-Range, Content-Length, Accept-Ranges, Content-Type, X-Immuch-Codec'
};

// Headers of a media answer that the player needs to seek and to know what it reads
const PASSED_HEADERS = ['content-type', 'content-length', 'content-range', 'accept-ranges', 'etag', 'last-modified'];

const httpAgent = new http.Agent({keepAlive: true, maxSockets: 6});
const DEFAULT_TIMEOUT_MS = 20000;

class HttpError extends Error {
	constructor(status, message) {
		super(message || 'HTTP ' + status);
		this.status = status;
	}
}

/**
 * A request to a source: resolves with the response (not read), rejects on a network error or a timeout. options:
 * method, headers, body (string or Buffer), timeoutMs, agent, and for https the TLS options (servername,
 * checkServerIdentity, ca, rejectUnauthorized) given as they are to https.request.
 */
function request(target, options) {
	const opts = options || {};
	return new Promise((resolve, reject) => {
		const parsed = urlLib.parse(target);
		const secure = parsed.protocol === 'https:';
		if (!secure && parsed.protocol !== 'http:') {
			reject(new Error('Unsupported address: ' + parsed.protocol));
			return;
		}
		const params = {
			method: opts.method || 'GET',
			hostname: parsed.hostname,
			port: parsed.port || (secure ? 443 : 80),
			path: parsed.path,
			headers: Object.assign({}, opts.headers || {})
		};
		if (opts.body !== undefined && opts.body !== null && params.headers['Content-Length'] === undefined) {
			params.headers['Content-Length'] = Buffer.byteLength(opts.body);
		}
		if (secure) {
			params.agent = opts.agent || undefined;
			['servername', 'checkServerIdentity', 'ca', 'rejectUnauthorized'].forEach((key) => {
				if (opts[key] !== undefined) params[key] = opts[key];
			});
		} else {
			params.agent = opts.agent || httpAgent;
		}
		const mod = secure ? https : http;
		let settled = false;
		const req = mod.request(params, (res) => {
			settled = true;
			resolve(res);
		});
		const timer = setTimeout(() => {
			if (settled) return;
			settled = true;
			req.abort();
			reject(new Error('The server did not answer in time'));
		}, opts.timeoutMs || DEFAULT_TIMEOUT_MS);
		req.on('response', () => clearTimeout(timer));
		req.on('error', (err) => {
			clearTimeout(timer);
			if (!settled) {
				settled = true;
				reject(err);
			}
		});
		req.end(opts.body === undefined || opts.body === null ? undefined : opts.body);
	});
}

/** The whole body of a response, refused past limit bytes */
function readBody(res, limit) {
	const max = limit || 8 * 1024 * 1024;
	return new Promise((resolve, reject) => {
		const parts = [];
		let size = 0;
		res.on('data', (chunk) => {
			size += chunk.length;
			if (size > max) {
				res.destroy();
				reject(new Error('Answer too large'));
				return;
			}
			parts.push(chunk);
		});
		res.on('end', () => resolve(Buffer.concat(parts)));
		res.on('error', reject);
	});
}

/** A request whose answer is read whole as text; rejects with an HttpError outside 2xx */
function fetchText(target, options) {
	return request(target, options).then((res) =>
		readBody(res, options && options.limit).then((body) => {
			const text = body.toString('utf8');
			if (res.statusCode < 200 || res.statusCode >= 300) throw new HttpError(res.statusCode);
			return {status: res.statusCode, headers: res.headers, text: text};
		})
	);
}

function fetchJson(target, options) {
	const opts = Object.assign({}, options || {});
	opts.headers = Object.assign({Accept: 'application/json'}, opts.headers || {});
	return fetchText(target, opts).then((answer) => {
		try {
			return JSON.parse(answer.text);
		} catch (e) {
			throw new Error('The server answered something else than JSON');
		}
	});
}

function sendJson(res, status, value) {
	const body = Buffer.from(JSON.stringify(value));
	res.writeHead(status, Object.assign({'Content-Type': 'application/json; charset=utf-8', 'Content-Length': body.length, 'Cache-Control': 'no-store'}, CORS));
	res.end(body);
}

function sendError(res, status, message, code) {
	if (res.headersSent) {
		res.destroy();
		return;
	}
	sendJson(res, status, {error: message || 'error', code: code || null});
}

function sendBuffer(res, status, type, body, extra) {
	res.writeHead(status, Object.assign({'Content-Type': type, 'Content-Length': body.length}, CORS, extra || {}));
	res.end(body);
}

/**
 * The byte range a Range header asks of a file of that size: {start, end} (end included), null when the header asks
 * for the whole file or cannot be read (the whole file is then sent, as RFC 9110 allows), 'unsatisfiable' when it
 * starts past the end. One range only; a list of ranges is answered with its first.
 */
function parseRange(header, size) {
	if (!header) return null;
	const match = /^bytes\s*=\s*(\d*)\s*-\s*(\d*)\s*(?:,.*)?$/i.exec(String(header).trim());
	if (!match) return null;
	const first = match[1];
	const last = match[2];
	if (first === '' && last === '') return null;
	let start;
	let end;
	if (first === '') {
		const suffix = Number(last);
		if (suffix === 0) return 'unsatisfiable';
		start = Math.max(0, size - suffix);
		end = size - 1;
	} else {
		start = Number(first);
		end = last === '' ? size - 1 : Math.min(Number(last), size - 1);
		if (start >= size) return 'unsatisfiable';
		if (end < start) return null;
	}
	return {start: start, end: end};
}

/**
 * Copies the answer of a source to the page or the player: status, the headers a player needs, CORS. The source's
 * answer is closed when the player goes away, so a seek does not leave a download running.
 */
function pipeResponse(upstream, res, extraHeaders) {
	const headers = Object.assign({}, CORS, extraHeaders || {});
	PASSED_HEADERS.forEach((name) => {
		if (upstream.headers[name] !== undefined) headers[name] = upstream.headers[name];
	});
	res.writeHead(upstream.statusCode, headers);
	upstream.pipe(res);
	const stop = () => upstream.destroy();
	res.on('close', stop);
	upstream.on('error', () => res.destroy());
}

/** The Range and If-Range headers of the player's request, to pass to the source */
function rangeHeaders(req) {
	const headers = {};
	if (req.headers.range) headers.Range = req.headers.range;
	if (req.headers['if-range']) headers['If-Range'] = req.headers['if-range'];
	return headers;
}

module.exports = {
	CORS,
	HttpError,
	request,
	readBody,
	fetchText,
	fetchJson,
	sendJson,
	sendError,
	sendBuffer,
	parseRange,
	pipeResponse,
	rangeHeaders
};
