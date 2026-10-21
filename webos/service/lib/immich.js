'use strict';
/* eslint-disable no-var -- runs on webOS 4.x's Node 0.12.2 (see lib/pairing.js) */

// Proxy login through the TV because the phone page's origin is subject to CORS.
// Self-signed Immich certificates are accepted for private LAN servers.

var http = require('http');
var https = require('https');
var Buffer = require('buffer').Buffer;
var compat = require('./compat');

var REQUEST_TIMEOUT_MS = 15000;

function normalizeBaseUrl(raw) {
	return String(raw || '').trim().replace(/\/+$/, '');
}

// Keep phone-paired accounts aligned with APIClient's base-URL normalization.
function apiUrl(base) {
	var b = normalizeBaseUrl(base);
	return /\/api$/.test(b) ? b : b + '/api';
}

function postJson(urlString, body) {
	return new Promise(function (resolve, reject) {
		var u = compat.parseUrl(urlString);
		if (!u) {
			reject(new Error('invalid_url'));
			return;
		}
		var isHttps = u.protocol === 'https:';
		if (!isHttps && u.protocol !== 'http:') {
			reject(new Error('invalid_url'));
			return;
		}
		var payload = JSON.stringify(body);
		var options = {
			hostname: u.hostname,
			port: u.port ? Number(u.port) : isHttps ? 443 : 80,
			path: u.pathname + u.search,
			method: 'POST',
			headers: {
				'Content-Type': 'application/json',
				'Content-Length': Buffer.byteLength(payload, 'utf8'),
				Accept: 'application/json'
			}
		};
		if (isHttps) options.rejectUnauthorized = false;
		var req = (isHttps ? https : http).request(options, function (res) {
			var data = '';
			res.setEncoding('utf8');
			res.on('data', function (chunk) {
				data += chunk;
			});
			res.on('end', function () {
				var json = null;
				try {
					json = data ? JSON.parse(data) : null;
				} catch (e) {
					// Proxy error pages may be non-JSON; the status is still sufficient.
				}
				resolve({status: res.statusCode, json: json});
			});
		});
		req.on('error', reject);
		req.setTimeout(REQUEST_TIMEOUT_MS, function () {
			req.destroy(new Error('timeout'));
		});
		req.write(payload, 'utf8');
		req.end();
	});
}

// Failures resolve to user-facing errors; the password is never retained.
function login(serverUrl, email, password) {
	var base = normalizeBaseUrl(serverUrl);
	if (!/^https?:\/\//.test(base)) {
		return Promise.resolve({ok: false, error: 'Server URL must start with http:// or https://'});
	}
	return postJson(apiUrl(base) + '/auth/login', {email: email, password: password}).then(
		function (res) {
			if (res.status === 200 || res.status === 201) {
				var token = res.json && res.json.accessToken;
				if (token) return {ok: true, accessToken: token};
				return {ok: false, error: 'Unexpected response from the Immich server'};
			}
			if (res.status === 401) return {ok: false, error: 'Invalid email or password'};
			return {ok: false, error: 'Immich server returned ' + res.status};
		},
		function (err) {
			if (err && err.message === 'timeout') {
				return {ok: false, error: 'The Immich server did not respond in time'};
			}
			if (err && err.message === 'invalid_url') {
				return {ok: false, error: 'Invalid server URL'};
			}
			return {ok: false, error: "Couldn't reach the Immich server from the TV. Check the URL."};
		}
	);
}

module.exports = {login: login, normalizeBaseUrl: normalizeBaseUrl, apiUrl: apiUrl, postJson: postJson};
