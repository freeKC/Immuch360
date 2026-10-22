'use strict';
// SMB 2 and 3 shares (Windows, Samba on a NAS) through @winlinux/smb2 1.1.0: one session per source, kept open and
// made again after an error; listings, the shares of a server, and reads of byte ranges, which the bridge turns into
// ranged HTTP answers for the player. Bundled for Node 12 (webOS 22 and later) by tools/build-bridge.mjs: the client
// needs BigInt, which the Node 8 of webOS 5 and 6 does not have.

const CHUNK = 1024 * 1024;

function toSmbPath(path) {
	return String(path || '')
		.split('/')
		.filter((part) => part && part !== '.' && part !== '..')
		.join('\\');
}

function sessionKey(source) {
	return [source.host, source.port, source.domain, source.user, source.password].join('\u0000');
}

/** An SMB error as the page shows it: a code it knows ('auth', 'not_found', 'access', 'unreachable') and a message */
function describeError(error) {
	const name = (error && (error.name || error.constructor && error.constructor.name)) || '';
	const message = String((error && error.message) || error);
	let code = null;
	if (/Auth|LOGON_FAILURE/i.test(name + message)) code = 'auth';
	else if (/NotFound|OBJECT_NAME_NOT_FOUND|OBJECT_PATH_NOT_FOUND|BAD_NETWORK_NAME/i.test(name + message)) code = 'not_found';
	else if (/AccessDenied|ACCESS_DENIED/i.test(name + message)) code = 'access';
	else if (/Connection|ECONNREFUSED|EHOSTUNREACH|ETIMEDOUT|Timeout/i.test(name + message)) code = 'unreachable';
	return Object.assign(new Error(message), {code: code, status: code === 'not_found' ? 404 : code === 'auth' || code === 'access' ? 403 : 502});
}

/**
 * The SMB driver of the bridge. lib is {connect, createAuthProvider} (the bundled @winlinux packages, or fakes in the
 * tests).
 */
function createSmbDriver(lib) {
	const sessions = {};

	function sessionFor(source) {
		const key = sessionKey(source);
		const known = sessions[source.id];
		if (known && known.key === key) return known.promise;
		if (known) known.promise.then((s) => s.close()).catch(() => {});
		const promise = lib.connect({
			host: source.host,
			port: source.port || 445,
			authProvider: lib.createAuthProvider('ntlm'),
			credentials: {username: source.user || 'guest', password: source.password || '', domain: source.domain || ''},
			connectTimeoutMs: 8000,
			requestTimeoutMs: 20000
		});
		sessions[source.id] = {key: key, promise: promise};
		promise.catch(() => {
			if (sessions[source.id] && sessions[source.id].promise === promise) delete sessions[source.id];
		});
		return promise;
	}

	/** Runs fn(session), once more on a new session when the first one failed (a server that dropped it) */
	function withSession(source, fn) {
		return sessionFor(source)
			.then(fn)
			.catch((error) => {
				const described = describeError(error);
				if (described.code === 'auth' || described.code === 'not_found' || described.code === 'access') throw described;
				const known = sessions[source.id];
				if (known) {
					delete sessions[source.id];
					known.promise.then((s) => s.close()).catch(() => {});
				}
				return sessionFor(source)
					.then(fn)
					.catch((again) => {
						throw describeError(again);
					});
			});
	}

	function fullPath(source, path) {
		return toSmbPath((source.root ? source.root + '/' : '') + (path || ''));
	}

	return {
		/** [{name, dir, size, modified}] of a folder (path relative to the source's root) */
		list(source, path) {
			return withSession(source, (s) => s.list(source.share, fullPath(source, path))).then((entries) =>
				entries
					.filter((e) => e.name !== '.' && e.name !== '..')
					.map((e) => ({name: e.name, dir: !!e.isDirectory, size: e.isDirectory ? null : Number(e.sizeBytes), modified: e.mtime ? e.mtime.getTime() : null}))
			);
		},
		/** The size of a file */
		size(source, path) {
			return withSession(source, (s) => s.stat(source.share, fullPath(source, path))).then((stat) => Number(stat.sizeBytes));
		},
		/** length bytes of a file from offset */
		read(source, path, offset, length) {
			return withSession(source, (s) => s.readRange(source.share, fullPath(source, path), offset, length));
		},
		/** The disk shares of a server, for the page that adds one: [name] */
		shares(source) {
			return withSession(Object.assign({}, source, {id: '__shares__' + source.host}), (s) => s.listShares()).then((list) =>
				list.filter((share) => !/\$$/.test(share.name) && !/IPC|PRINT/i.test(String(share.type || ''))).map((share) => share.name)
			);
		},
		forget(sourceId) {
			const known = sessions[sourceId];
			delete sessions[sourceId];
			if (known) known.promise.then((s) => s.close()).catch(() => {});
		},
		closeAll() {
			Object.keys(sessions).forEach((id) => this.forget(id));
		},
		CHUNK: CHUNK
	};
}

module.exports = {createSmbDriver, toSmbPath, describeError};
