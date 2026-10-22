'use strict';
// A small XML reader, enough for WebDAV multistatus answers, UPnP device descriptions, SOAP envelopes and DIDL-Lite.
// Namespace prefixes are ignored (d:href, D:href and href are the same element), which is what these servers need:
// they disagree on prefixes, never on local names. No DTD, no external entity: nothing in the answer is fetched.

const NAMED = {lt: '<', gt: '>', amp: '&', quot: '"', apos: "'"};

/** The text with its five named entities and its numeric references replaced */
function decodeEntities(text) {
	return String(text).replace(/&(lt|gt|amp|quot|apos|#\d+|#x[0-9a-f]+);/gi, (match, name) => {
		const named = NAMED[name.toLowerCase()];
		if (named !== undefined) return named;
		const code = name[1] === 'x' || name[1] === 'X' ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10);
		if (!(code > 0 && code <= 0x10ffff)) return match;
		return String.fromCodePoint(code);
	});
}

/** The text with the characters XML gives a meaning to escaped, for an element body or an attribute */
function escapeXml(text) {
	return String(text)
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;')
		.replace(/'/g, '&apos;');
}

function escapeRegExp(text) {
	return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Every element of that local name in xml, outermost first, as {attrs, body}: attrs is the raw attribute text, body the
 * raw inner XML (empty for a self closing element). Nested elements of the same name are not split: the outer one
 * holds the inner one in its body, which is enough for these answers.
 */
function elements(xml, name) {
	const local = escapeRegExp(name);
	const re = new RegExp(
		'<(?:[\\w.-]+:)?' + local + '(?=[\\s/>])([^>]*?)(?:/>|>([\\s\\S]*?)</(?:[\\w.-]+:)?' + local + '\\s*>)',
		'g'
	);
	const out = [];
	let match;
	while ((match = re.exec(xml)) !== null) {
		out.push({attrs: match[1] || '', body: match[2] || ''});
	}
	return out;
}

function stripCdata(text) {
	return text.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, (m, inner) => inner);
}

/** The decoded text of the first element of that name, trimmed; null when there is none */
function childText(xml, name) {
	const found = elements(xml, name)[0];
	if (!found) return null;
	const body = found.body;
	if (body.indexOf('<![CDATA[') >= 0) return stripCdata(body).trim();
	return decodeEntities(body.trim());
}

/** The decoded value of an attribute in raw attribute text, null when it is not there */
function attribute(attrs, name) {
	const re = new RegExp('(?:^|\\s)(?:[\\w.-]+:)?' + escapeRegExp(name) + '\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\')');
	const match = re.exec(attrs);
	if (!match) return null;
	return decodeEntities(match[1] !== undefined ? match[1] : match[2]);
}

module.exports = {decodeEntities, escapeXml, elements, childText, attribute};
