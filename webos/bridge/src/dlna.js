'use strict';
// DLNA media servers (minidlna, Jellyfin, Plex's DLNA, NAS and TV boxes): SSDP finds them, the device description
// names them and gives the control URL of their ContentDirectory, SOAP Browse lists a container, and DIDL-Lite
// describes its children. Their media are plain HTTP without a password. As mobile/lib/infrastructure/network/upnp/.

const urlLib = require('url');
const httpx = require('./httpx');
const xml = require('./xml');
const udp = require('./udp');
const media = require('./media');

const SSDP_GROUP = '239.255.255.250';
const SSDP_PORT = 1900;
const TARGETS = ['urn:schemas-upnp-org:device:MediaServer:1', 'urn:schemas-upnp-org:service:ContentDirectory:1'];
const PAGE = 500;
const MAX_CHILDREN = 10000;

function searchRequest(target) {
	return (
		'M-SEARCH * HTTP/1.1\r\nHOST: ' + SSDP_GROUP + ':' + SSDP_PORT + '\r\nMAN: "ssdp:discover"\r\nMX: 2\r\nST: ' + target +
		'\r\nUSER-AGENT: webOS/1 UPnP/1.1 Immuch360/1\r\n\r\n'
	);
}

/** The name and the ContentDirectory control URL of a device description, null when it has no ContentDirectory */
function parseDescription(text, location) {
	const service = xml
		.elements(text, 'service')
		.map((s) => s.body)
		.filter((body) => /urn:schemas-upnp-org:service:ContentDirectory:/.test(xml.childText(body, 'serviceType') || ''))[0];
	if (!service) return null;
	const base = xml.childText(text, 'URLBase') || location;
	const control = xml.childText(service, 'controlURL');
	if (!control) return null;
	const device = xml.elements(text, 'device')[0];
	return {
		name: xml.childText(device ? device.body : text, 'friendlyName') || urlLib.parse(location).hostname,
		udn: xml.childText(device ? device.body : text, 'UDN'),
		control: urlLib.resolve(base, control)
	};
}

function describe(location) {
	return httpx.fetchText(location, {timeoutMs: 4000, limit: 1024 * 1024}).then((answer) => {
		const parsed = parseDescription(answer.text, location);
		if (!parsed) throw new Error('This device has no media library (no ContentDirectory)');
		parsed.location = location;
		return parsed;
	});
}

/** The DLNA servers that answer within ms: [{kind: 'dlna', name, location, control, host}] */
function discover(ms, options) {
	const opts = options || {};
	const message = TARGETS.map(searchRequest);
	return Promise.all(message.map((m, i) => udp.search(m, SSDP_PORT, ms, {groups: [SSDP_GROUP], sweep: i === 0 && opts.sweep !== false, addresses: opts.addresses})))
		.then((lists) => {
			const locations = [];
			lists.forEach((answers) =>
				answers.forEach((answer) => {
					const parsed = udp.parseHeaders(answer.text);
					const location = parsed.headers.location;
					if (/^HTTP\/1\.\d\s+200/i.test(parsed.status) && location && /^http:\/\//i.test(location) && locations.indexOf(location) < 0) {
						locations.push(location);
					}
				})
			);
			return Promise.all(locations.map((location) => describe(location).catch(() => null)));
		})
		.then((devices) => {
			const seen = {};
			return devices.filter((device) => {
				if (!device) return false;
				const key = device.udn || device.location;
				if (seen[key]) return false;
				seen[key] = true;
				return true;
			}).map((device) => ({kind: 'dlna', name: device.name, location: device.location, control: device.control, host: urlLib.parse(device.location).hostname}));
		});
}

function browseEnvelope(objectId, start, count) {
	return (
		'<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" ' +
		's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>' +
		'<u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1"><ObjectID>' + xml.escapeXml(objectId) +
		'</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter><StartingIndex>' + start +
		'</StartingIndex><RequestedCount>' + count + '</RequestedCount><SortCriteria></SortCriteria></u:Browse></s:Body></s:Envelope>'
	);
}

// "0:01:02.500" -> 62.5
function parseDuration(text) {
	const match = /^(\d+):(\d{1,2}):(\d{1,2}(?:\.\d+)?)/.exec(String(text || ''));
	return match ? Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]) : null;
}

function resInfo(res) {
	const protocol = xml.attribute(res.attrs, 'protocolInfo') || '';
	const parts = protocol.split(':');
	const resolution = /^(\d+)x(\d+)$/.exec(xml.attribute(res.attrs, 'resolution') || '');
	return {
		url: xml.decodeEntities(res.body.trim()),
		mime: (parts[2] || '').toLowerCase() || null,
		profile: (/DLNA\.ORG_PN=([^;]+)/.exec(parts[3] || '') || [])[1] || null,
		size: Number(xml.attribute(res.attrs, 'size')) || null,
		width: resolution ? Number(resolution[1]) : null,
		height: resolution ? Number(resolution[2]) : null,
		duration: parseDuration(xml.attribute(res.attrs, 'duration'))
	};
}

/** The children of a DIDL-Lite document: {folders: [{ref, name}], files: [{ref, name, kind, mime, size, thumb, ...}]} */
function parseDidl(didl) {
	const folders = xml.elements(didl, 'container').map((c) => ({
		ref: xml.attribute(c.attrs, 'id'),
		name: xml.childText(c.body, 'title') || xml.attribute(c.attrs, 'id')
	}));
	const files = [];
	xml.elements(didl, 'item').forEach((item) => {
		const title = xml.childText(item.body, 'title') || '';
		const upnpClass = xml.childText(item.body, 'class') || '';
		const resources = xml.elements(item.body, 'res').map(resInfo).filter((r) => /^https?:\/\//i.test(r.url));
		const thumbnails = resources.filter((r) => r.profile === 'JPEG_TN' || r.profile === 'PNG_TN');
		const originals = resources.filter((r) => thumbnails.indexOf(r) < 0 && !/^(JPEG_SM|JPEG_MED)$/.test(r.profile || ''));
		const main = originals[0] || resources[0];
		if (!main) return;
		let kind = /imageItem/.test(upnpClass) ? 'image' : /videoItem/.test(upnpClass) ? 'video' : null;
		const byType = media.classify(title, main.mime);
		if (!kind || byType.kind === 'unsupported') kind = byType.kind;
		const albumArt = xml.childText(item.body, 'albumArtURI');
		const thumb = thumbnails[0] ? thumbnails[0].url : albumArt && /^https?:\/\//i.test(albumArt) ? albumArt : null;
		files.push({
			ref: main.url,
			id: xml.attribute(item.attrs, 'id'),
			name: title,
			kind: kind,
			mime: main.mime || byType.mime,
			size: main.size,
			width: main.width,
			height: main.height,
			duration: main.duration,
			thumb: thumb,
			modified: Date.parse(xml.childText(item.body, 'date') || '') || null
		});
	});
	return {folders: folders, files: files};
}

function controlOf(source) {
	if (source.control) return Promise.resolve(source.control);
	return describe(source.location).then((device) => {
		source.control = device.control;
		return device.control;
	});
}

function browsePage(control, objectId, start) {
	return httpx
		.fetchText(control, {
			method: 'POST',
			headers: {'Content-Type': 'text/xml; charset="utf-8"', SOAPACTION: '"urn:schemas-upnp-org:service:ContentDirectory:1#Browse"'},
			body: browseEnvelope(objectId, start, PAGE),
			limit: 32 * 1024 * 1024
		})
		.then((answer) => {
			const result = xml.childText(answer.text, 'Result') || '';
			return {didl: result, returned: Number(xml.childText(answer.text, 'NumberReturned') || 0), total: Number(xml.childText(answer.text, 'TotalMatches') || 0)};
		});
}

/** The children of the container objectId ("0" is the root), every page of them up to MAX_CHILDREN */
function list(source, objectId) {
	return controlOf(source).then((control) => {
		const folders = [];
		const files = [];
		const page = (start) =>
			browsePage(control, objectId || '0', start).then((answer) => {
				const parsed = parseDidl(answer.didl);
				Array.prototype.push.apply(folders, parsed.folders);
				Array.prototype.push.apply(files, parsed.files);
				const next = start + (answer.returned || parsed.folders.length + parsed.files.length);
				if (answer.returned > 0 && next < answer.total && next < MAX_CHILDREN) return page(next);
				return null;
			});
		return page(0).then(() => ({folders: folders, files: files.filter((f) => f.kind)}));
	});
}

/** Whether url is on the host of the source's description: the bridge only reads media of the servers it was given */
function ownsUrl(source, url) {
	const a = urlLib.parse(source.location);
	const b = urlLib.parse(String(url || ''));
	return b.protocol === 'http:' && a.hostname === b.hostname;
}

function pipeMedia(source, url, req, res) {
	if (!ownsUrl(source, url)) return Promise.reject(Object.assign(new Error('Not a media of this server'), {status: 403}));
	return httpx.request(url, {headers: httpx.rangeHeaders(req)}).then((upstream) => httpx.pipeResponse(upstream, res));
}

module.exports = {discover, describe, parseDescription, parseDidl, parseDuration, list, ownsUrl, pipeMedia, browseEnvelope};
