'use strict';
// Signing in to Plex from a TV: the service asks plex.tv for a PIN, the user types its four characters on
// plex.tv/link with a phone or a computer, and the service reads the token once the PIN is linked. Then the account's
// servers come from clients.plex.tv, each with its own access token and its plex.direct addresses. Everything over
// HTTPS with the system's certificate checks. The bases are parameters for the tests.

const httpx = require('./httpx');
const plex = require('./plex');

const DEFAULTS = {plexTv: 'https://plex.tv', clients: 'https://clients.plex.tv'};

function headers(clientId, token) {
	const h = {
		Accept: 'application/json',
		'X-Plex-Product': 'Immuch360',
		'X-Plex-Platform': 'webOS',
		'X-Plex-Device': 'LG TV',
		'X-Plex-Device-Name': 'Immuch360 on LG TV',
		'X-Plex-Client-Identifier': clientId
	};
	if (token) h['X-Plex-Token'] = token;
	return h;
}

function checkClientId(clientId) {
	if (!/^[A-Za-z0-9_-]{8,64}$/.test(String(clientId || ''))) throw new Error('bad client identifier');
}

/** A new PIN: {id, code, expiresAt} */
function createPin(clientId, bases) {
	return Promise.resolve().then(() => createPinNow(clientId, bases));
}

function createPinNow(clientId, bases) {
	checkClientId(clientId);
	const base = (bases && bases.plexTv) || DEFAULTS.plexTv;
	return httpx
		.fetchJson(base + '/api/v2/pins?strong=false', {method: 'POST', headers: Object.assign(headers(clientId), {'Content-Type': 'application/x-www-form-urlencoded'}), body: ''})
		.then((pin) => {
			if (!pin || !pin.id || !pin.code) throw new Error('plex.tv gave no code');
			return {id: Number(pin.id), code: String(pin.code), expiresAt: pin.expiresAt ? String(pin.expiresAt) : null};
		});
}

/** The token of a PIN once it is linked, null before */
function checkPin(clientId, id, bases) {
	return Promise.resolve().then(() => checkPinNow(clientId, id, bases));
}

function checkPinNow(clientId, id, bases) {
	checkClientId(clientId);
	if (!/^\d+$/.test(String(id))) return Promise.reject(new Error('bad PIN id'));
	const base = (bases && bases.plexTv) || DEFAULTS.plexTv;
	return httpx.fetchJson(base + '/api/v2/pins/' + id, {headers: headers(clientId)}).then((pin) => (pin && pin.authToken ? String(pin.authToken) : null));
}

/**
 * The best address of a server among its connections: a local plex.direct one first, then any plex.direct one that is
 * not a relay; {address, port, hash, local} or null
 */
function pickConnection(connections) {
	const usable = (connections || [])
		.filter((c) => c && c.protocol === 'https' && !c.relay && !c.IPv6)
		.map((c) => {
			let host = null;
			try {
				host = require('url').parse(String(c.uri)).hostname;
			} catch (e) {
				host = null;
			}
			const direct = plex.parseDirectHost(host);
			return direct ? {address: direct.address, port: Number(c.port) || 32400, hash: direct.hash, local: !!c.local} : null;
		})
		.filter(Boolean);
	return usable.filter((c) => c.local)[0] || usable[0] || null;
}

/** The Plex Media Servers of the account: [{name, machineId, token, address, port, hash, owned}] */
function servers(clientId, token, bases) {
	return Promise.resolve().then(() => serversNow(clientId, token, bases));
}

function serversNow(clientId, token, bases) {
	checkClientId(clientId);
	const base = (bases && bases.clients) || DEFAULTS.clients;
	return httpx.fetchJson(base + '/api/v2/resources?includeHttps=1&includeRelay=0&includeIPv6=0', {headers: headers(clientId, token)}).then((list) =>
		(Array.isArray(list) ? list : [])
			.filter((r) => r && String(r.provides || '').split(',').indexOf('server') >= 0)
			.map((r) => {
				const connection = pickConnection(r.connections);
				if (!connection) return null;
				return {
					name: String(r.name || ''),
					machineId: String(r.clientIdentifier || ''),
					token: String(r.accessToken || token),
					address: connection.address,
					port: connection.port,
					hash: connection.hash,
					local: connection.local,
					owned: !!r.owned
				};
			})
			.filter(Boolean)
	);
}

module.exports = {createPin, checkPin, servers, pickConnection};
