'use strict';
// The sources the page hands over (Luna setSources), kept in the service's memory only: their passwords and tokens
// never appear in a URL the page or the TV's player sees. A source is a flat object; what each kind reads:
//
//   webdav  url (http or https, the folder to start in), user, password
//   smb     host, port (445), share, root (a folder of the share, optional), user, password, domain
//   dlna    location (the device description URL), control (its ContentDirectory control URL, found if absent)
//   plex    address (IPv4), port (32400), hash (the plex.direct certificate, absent for a server without one), token
//   tapo    host, port (554), user and password of the camera account
//
// Plus id (the page's), name and kind.

const KINDS = ['webdav', 'smb', 'dlna', 'plex', 'tapo'];

function text(value) {
	return typeof value === 'string' ? value : value === undefined || value === null ? '' : String(value);
}

function port(value, fallback) {
	const n = Number(value);
	return Number.isInteger(n) && n > 0 && n < 65536 ? n : fallback;
}

/** The source as the bridge keeps it, or an Error saying what is wrong */
function normalizeSource(input) {
	if (!input || typeof input !== 'object') return new Error('not a source');
	const id = text(input.id);
	const kind = text(input.kind);
	if (!/^[A-Za-z0-9_-]{1,64}$/.test(id)) return new Error('bad source id');
	if (KINDS.indexOf(kind) < 0) return new Error('unknown kind ' + kind);
	const source = {id: id, kind: kind, name: text(input.name) || id};
	if (kind === 'webdav') {
		const url = text(input.url).trim();
		if (!/^https?:\/\/[^/]+/i.test(url)) return new Error('webdav: bad url');
		source.url = url;
		source.user = text(input.user);
		source.password = text(input.password);
	} else if (kind === 'smb') {
		source.host = text(input.host).trim();
		if (!source.host) return new Error('smb: no host');
		source.port = port(input.port, 445);
		source.share = text(input.share).replace(/^[\\/]+|[\\/]+$/g, '');
		if (!source.share) return new Error('smb: no share');
		source.root = text(input.root).replace(/\\/g, '/').replace(/^\/+|\/+$/g, '');
		source.user = text(input.user);
		source.password = text(input.password);
		source.domain = text(input.domain);
	} else if (kind === 'dlna') {
		const location = text(input.location).trim();
		if (!/^http:\/\/[^/]+/i.test(location)) return new Error('dlna: bad location');
		source.location = location;
		source.control = text(input.control).trim() || null;
	} else if (kind === 'plex') {
		source.address = text(input.address).trim();
		if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(source.address) && !/^[a-z0-9.-]+$/i.test(source.address)) return new Error('plex: bad address');
		source.port = port(input.port, 32400);
		source.hash = /^[0-9a-f]{32}$/.test(text(input.hash)) ? text(input.hash) : null;
		source.token = text(input.token) || null;
		// A token only ever goes to the server that holds the certificate of the hash: never in clear
		if (source.token && !source.hash) return new Error('plex: a token needs the plex.direct certificate');
	} else if (kind === 'tapo') {
		source.host = text(input.host).trim();
		if (!source.host) return new Error('tapo: no host');
		source.port = port(input.port, 554);
		source.user = text(input.user);
		source.password = text(input.password);
	}
	return source;
}

/** A registry of the sources: replace(list) keeps the valid ones and says which were refused */
function createRegistry() {
	let byId = {};
	return {
		replace(list) {
			const next = {};
			const refused = [];
			(Array.isArray(list) ? list : []).forEach((input) => {
				const source = normalizeSource(input);
				if (source instanceof Error) refused.push({id: input && input.id, error: source.message});
				else next[source.id] = source;
			});
			byId = next;
			return {count: Object.keys(next).length, refused: refused};
		},
		get(id) {
			return Object.prototype.hasOwnProperty.call(byId, id) ? byId[id] : null;
		},
		ids() {
			return Object.keys(byId);
		}
	};
}

module.exports = {normalizeSource, createRegistry, KINDS};
