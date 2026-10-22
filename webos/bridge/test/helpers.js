'use strict';
// Shared pieces of the bridge tests: local servers standing in for the sources, and a client of the bridge.

const http = require('http');
const bridgeLib = require('../src/index');

function listen(server) {
	return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server.address().port)));
}

/** An HTTP server on 127.0.0.1 with that handler: {port, url, close, requests} */
async function startServer(handler) {
	const requests = [];
	const server = http.createServer((req, res) => {
		const chunks = [];
		req.on('data', (c) => chunks.push(c));
		req.on('end', () => {
			req.body = Buffer.concat(chunks).toString('utf8');
			requests.push({method: req.method, url: req.url, headers: req.headers, body: req.body});
			handler(req, res);
		});
	});
	const port = await listen(server);
	return {port, url: `http://127.0.0.1:${port}`, requests, close: () => new Promise((r) => server.close(r)), server};
}

/** GET (or another method) of a URL: {status, headers, body} with the body as a Buffer */
function fetchRaw(url, options) {
	const opts = options || {};
	return new Promise((resolve, reject) => {
		const req = http.request(url, {method: opts.method || 'GET', headers: opts.headers || {}}, (res) => {
			const chunks = [];
			res.on('data', (c) => chunks.push(c));
			res.on('end', () => resolve({status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks)}));
		});
		req.on('error', reject);
		req.end(opts.body);
	});
}

async function fetchJson(url, options) {
	const answer = await fetchRaw(url, options);
	return {status: answer.status, headers: answer.headers, json: JSON.parse(answer.body.toString('utf8'))};
}

/** A running bridge with these sources: {bridge, base (http://127.0.0.1:port/token), stop} */
async function startBridge(sources, options) {
	const bridge = bridgeLib.createBridge(Object.assign({loadSmb: () => {
		throw new Error('no SMB in this test');
	}}, options || {}));
	const info = await bridge.start();
	const result = bridge.setSources(sources || []);
	return {bridge, info, result, base: `http://127.0.0.1:${info.port}/${info.token}`, stop: () => bridge.stop()};
}

module.exports = {startServer, fetchRaw, fetchJson, startBridge, listen};
