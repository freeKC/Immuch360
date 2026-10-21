'use strict';
/* eslint-disable no-var -- runs on webOS 4.x's Node 0.12.2 (see lib/pairing.js) */

// webOS 4.x runs JS services on Node 0.12.2, which has no WHATWG URL class. Newer
// runtimes keep using it: url.parse() is deprecated there.

var url = require('url');

// Same fields as a URL instance, or null where `new URL()` would throw.
function parseUrl(text) {
	if (typeof url.URL === 'function') {
		try {
			return new url.URL(text);
		} catch (e) {
			return null;
		}
	}
	var parsed = url.parse(String(text));
	if (!parsed.protocol || !parsed.hostname) return null;
	return {
		protocol: parsed.protocol,
		hostname: parsed.hostname,
		port: parsed.port || '',
		pathname: parsed.pathname || '/',
		search: parsed.search || ''
	};
}

module.exports = {parseUrl: parseUrl};
